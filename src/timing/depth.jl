# How many levels of logic lie between two registers, asked of a synthesis tool.
# What the source shows is the shape of the logic; how deep it is once it has been
# optimised and packed into LUTs only a mapper knows. The design is written out as
# Verilog, yosys maps it, and the netlist it writes is walked from the inputs of
# every register back to the registers they start from. A register keeps its name
# through synthesis, so the depths join the rows of the report by name; nothing
# here depends on what a net between two registers is called.

# What maps a design when the user names no flow of their own: yosys's generic
# passes, to LUTs of the size the report was given, with every add and compare
# left as the one cell `alumacc` makes of it and not lowered to gates. It knows
# nothing of any device, so its depths are those of a plain LUT fabric with a carry
# chain; a vendor's flow, which the user names, packs its own cells.
_genericsynth(lut::Int) =
  "proc; flatten; opt_expr; opt_clean; opt -nodffe -nosdff; fsm; opt; wreduce; peepopt; opt_clean; alumacc; " *
  "share; opt; memory -nomap; opt_clean; opt -fast -full; memory_map; opt -full; " *
  "techmap t:\$alu t:\$lcu %u %n; opt -fast; abc -lut $lut; opt -fast; clean"

# what a path starts and ends at, beside the design's black boxes
const STORAGE = r"DFF|_FF|^FD|LATCH|RAM|^DP\d|DPR|^PDP"
# a carry chain is dedicated wiring from cell to cell, and is one level however long
const CARRY = r"CCU2|CARRY|\$alu|\$lcu"
const CARRYIN = r"^(CIN|CI|FCI)$"

# one cell of the mapped netlist
struct MappedCell
  name::String
  type::String
  inputs::Vector{Tuple{String,Vector{Int}}}     # port => the bits it reads; constants left out
  outputs::Vector{Tuple{String,Vector{Int}}}
  storage::Bool                                 # a path starts at its outputs and ends at its inputs
  box::Bool                                     # it is one of the design's black boxes
end

struct MappedDesign
  cells::Vector{MappedCell}
  driver::Dict{Int,Tuple{Int,String}}           # bit => the cell that drives it, and the port
  names::Dict{Int,Vector{String}}               # bit => the nets it is on, without the bit index
end

# The levels of logic between the registers of a module, as yosys maps it: from
# `(from, to)`, by the names the netlist has, to the longest path between the two,
# counted in LUTs with a carry chain as one level. `synth` is the yosys command
# that maps the design, which has to flatten it, or nothing for the generic one.
# Only the names in `known` are kept: yosys names the nets it makes after the
# cells around them, and a register's net has many such names beside its own.
function _designdepths(T::Type{<:QuartzModule}, synth, lut::Int, known)
  boxes = Set(string(blackbox(BB).verilogname) for BB in _blackboxes(T))
  m = mktempdir() do dir
    _mapped(_yosys(dir, T, something(synth, _genericsynth(lut))), boxes, known)
  end
  _depths(m)
end

# a row's two ends as the netlist may name them: a register by the net it is
# emitted as, a black-box output by the wire the module declares for it
function _netnames(d::FlatDesign)
  ends = Dict{String,Vector{String}}()
  for s in d.sinks
    full = _fullname(d.instances[s.inst], s.name)
    ends[full] = s.kind == :metaguard ? [full * "_mg"] : s.kind == :pipeline ? [full * "_out"] :
                 s.kind == :pad ? [full * "_padval", full * "_padoe"] : [full]
  end
  ends
end

# a top-level input starts at its pin, which is all that is left of it once an
# inverter or a rename behind the pin has been folded into the logic
function _startnames(from::String, pins)
  i = findlast('.', from)
  i === nothing ? unique([from, get(pins, from, from)]) : [from, from[1:i-1] * "_" * from[i+1:end]]
end

_pins(T::Type) = Dict(string(p.name) => string(p.vname) for p in _ports(T) if p.dir == :input)

# the deepest path between a row's two ends, or nothing where synthesis left none
function _rowdepth(found, ends, pins, p)
  best = nothing
  for f in _startnames(p.from, pins), t in get(ends, p.to, [p.to])
    n = get(found, (f, t), nothing)
    n === nothing || (best = best === nothing ? n : max(best, n))
  end
  best
end

### helpers

function _yosys(dir, T::Type, synth)
  name = nameof(T)
  write(joinpath(dir, "design.v"), T, Verilog(; name))
  write(joinpath(dir, "stubs.v"), join((_stub(BB) for BB in _blackboxes(T)), "\n"))
  log = joinpath(dir, "yosys.log")
  script = "read_verilog design.v stubs.v; hierarchy -top $name; $synth; write_json netlist.json"
  ok = success(pipeline(Cmd(`yosys -q -p $script`; dir); stdout=log, stderr=log))
  ok || error("yosys could not map $name:\n" * last(read(log, String), 2000))
  JSON.parsefile(joinpath(dir, "netlist.json"))["modules"][string(name)]
end

# a black box as yosys needs it: its ports and which way they go, and nothing inside
function _stub(BB::Type)
  bb = blackbox(BB)
  dirs = Dict(:input => "input", :clock => "input", :output => "output", :clockout => "output", :inout => "inout")
  ports = join(("$(dirs[p.dir]) $(_range(p.width))$(p.vname)" for p in bb.ports), ", ")
  "(* blackbox *) module $(bb.verilogname)($ports);\nendmodule\n"
end

function _mapped(netlist, boxes, known)
  cells = MappedCell[]
  driver = Dict{Int,Tuple{Int,String}}()
  for (name, c) in netlist["cells"]
    type = string(c["type"])
    inputs = Tuple{String,Vector{Int}}[]
    outputs = Tuple{String,Vector{Int}}[]
    for (port, bits) in c["connections"]
      wired = Int[b for b in bits if b isa Integer]
      push!(get(c["port_directions"], port, "input") == "input" ? inputs : outputs, (string(port), wired))
    end
    box = type in boxes
    push!(cells, MappedCell(string(name), type, inputs, outputs, box || occursin(STORAGE, type), box))
    for (port, bits) in outputs, b in bits
      driver[b] = (length(cells), port)
    end
  end
  names = Dict{Int,Vector{String}}()
  for (name, n) in netlist["netnames"]
    string(name) in known || continue
    for b in n["bits"]
      b isa Integer && push!(get!(names, b, String[]), string(name))
    end
  end
  MappedDesign(cells, driver, names)
end

_cost(c::MappedCell, port::String) = occursin(CARRY, c.type) && occursin(CARRYIN, port) ? 0 : 1

# the longest way from the inputs of each storage cell back to every place a path
# starts, by the names the two ends have
function _depths(m::MappedDesign)
  found = Dict{Tuple{String,String},Int}()
  for c in m.cells, (port, bits) in c.inputs
    c.storage || continue
    tos = _endnames(m, c, port)
    far = Dict{Int,Int}()
    for b in bits
      _walkback!(far, m, b, 0)
    end
    for (b, d) in far
      _isstart(m, b) || continue
      for from in get(m.names, b, String[]), to in tos
        found[(from, to)] = max(get(found, (from, to), 0), d)
      end
    end
  end
  found
end

_isstart(m::MappedDesign, b::Int) = !haskey(m.driver, b) || m.cells[m.driver[b][1]].storage

# a flop is named after the net it drives; a black box after itself and the pin
function _endnames(m::MappedDesign, c::MappedCell, port::String)
  c.box && return String[string(c.name, ".", lowercase(port))]
  unique(n for (_, bits) in c.outputs for b in bits for n in get(m.names, b, String[]))
end

function _walkback!(far::Dict{Int,Int}, m::MappedDesign, b::Int, d::Int)
  get(far, b, -1) ≥ d && return
  d > length(m.cells) && error("the mapped netlist has a combinational loop through $(get(m.names, b, ["an unnamed net"])[1])")
  far[b] = d
  _isstart(m, b) && return
  c, _ = m.driver[b]
  cell = m.cells[c]
  for (port, bits) in cell.inputs, i in bits
    _walkback!(far, m, i, d + _cost(cell, port))
  end
end
