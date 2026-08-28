# A pin map is a fact about a board, not about a design: a module has no pin, an
# instance does, and the same design may be built for more than one board. So the
# bindings live here, addressed by instance path, and the design declares only what
# it needs from whatever board it runs on.

struct PinBinding
  path::Vector{Symbol}                # instance path; the last element is the port
  sites::Vector{Union{Int,String,Nothing}}  # one per bit -- a number, a BGA site like
                                            # "G2", or `nothing` for a bit left unbonded
  attrs::Dict{Symbol,Any}
end

"""
    Board

What a board provides: the part it is built around, which pin each port of a design
lands on, and what the buffers there are told. Built by `@board`, and read by the
constraint emitters and by `QuartzHDL.problems`.
"""
struct Board
  name::Symbol
  device::String
  pins::Vector{PinBinding}
  raw::String
  defaults::Dict{Symbol,Any}          # pin attributes every binding starts from
end

# an oscillator is a rate on the pin it arrives at, so the board states it once,
# where it states that pin
oscillators(b::Board) =
  Pair{Symbol,Rational{Int}}[portof(p) => p.attrs[:osc] for p in b.pins if haskey(p.attrs, :osc)]

Base.show(io::IO, b::Board) =
  print(io, "Board(", b.name, ", ", b.device, ", ", length(b.pins), " pins, ",
        length(oscillators(b)), " oscillators)")

portof(p::PinBinding) = last(p.path)

# Frequencies are written the way a datasheet writes them. The names mean nothing
# outside the block -- they are substituted here, so nothing is exported and nothing
# can clash with a package that has its own `MHz`.
const FREQUNITS = Dict(:Hz => 1//1, :kHz => 1000//1, :MHz => 1000000//1, :GHz => 1000000000//1)
const TIMEUNITS = Dict(:s => 1//1, :ms => 1//1000, :µs => 1//1000000, :us => 1//1000000,
                       :ns => 1//1000000000, :ps => 1//1000000000000)

_units(ex, table) = ex isa Expr ?
  (ex.head == :call && length(ex.args) == 3 && ex.args[1] === :* &&
   ex.args[3] isa Symbol && haskey(table, ex.args[3]) ?
     :($QuartzHDL._exact($(ex.args[2])) * $(table[ex.args[3]])) :
     Expr(ex.head, map(a -> _units(a, table), ex.args)...)) : ex

# 32.768kHz reaches the macro as a Float64; recover the rational a person meant, and
# refuse rather than guess if it cannot be recovered exactly enough
_exact(x::Integer) = Rational{Int}(x)
_exact(x::Rational) = x
function _exact(x::AbstractFloat)
  r = rationalize(Int, x; tol = 1e-12)
  abs(float(r) - x) ≤ 1e-9 * max(1.0, abs(x)) ||
    throw(ArgumentError("$x is not an exact rate; write it as an integer with a " *
                        "smaller unit, e.g. 32768Hz"))
  r
end

"""
    @board Name begin ... end

Declares a board: the settings it has (`device`, `raw`, and any pin attribute that
applies to every pin) and a binding of each port of a design to its site. A port
below the top is named by its instance path.

```julia
@board Rev2 begin
  device = "LFE5U-25F-6BG381C"
  clk => (pin = "P3", osc = 25MHz, io = :LVCMOS33)
end
```
"""
macro board(name, block)
  esc(_board(name, block, __module__))
end

# What a buffer is told about a pin. A block writes any of these once and a binding
# overrides it, `nothing` included: an explicit `io = nothing` says this pin is to
# be left to the tool, which is different from forgetting to mention it.
const PINATTRS = Dict(:io => "an I/O standard, e.g. :LVCMOS25",
                      :pull => ":up, :down or :none",
                      :drive => "a drive strength in mA",
                      :ext_pull => ":up, :down or :none, a pull the board provides")
const BOARDSETTINGS = Dict(:device => "the part number",
                           :raw => "text passed through to the constraint file")

# Everything here is either a setting -- `key = value` -- or a binding of a port to
# its pin; a rate belongs with the pin the oscillator arrives on, so `osc` is a pin
# attribute rather than a form of its own.
function _board(name, block, mod)
  name isa Symbol || error("@board: expected a name, got $name")
  block isa Expr && block.head == :block || error("@board: expected a begin ... end block")
  doc, items = _blockdoc(block.args, "board")
  device = ""
  pins = Expr[]
  raw = ""
  defaults = Expr[]
  for x in items
    x isa LineNumberNode && continue
    d, item = _undoc(x)
    if item isa Expr && item.head == :call && item.args[1] === :(=>)
      push!(pins, _pinbinding(item.args[2], item.args[3], d))
      continue
    end
    d === nothing || error("@board: only a pin takes a docstring, got $item")
    item isa Expr && item.head in (:(=), :kw) && item.args[1] isa Symbol ||
      error("@board: expected `setting = value` or `port => (pin = ..., ...)`, got $item")
    key, val = item.args[1], item.args[2]
    if key === :device
      device = val
    elseif key === :raw
      raw = val
    elseif haskey(PINATTRS, key)
      push!(defaults, :($(QuoteNode(key)) => $(_pinattr(key, val))))
    else
      error("@board: $key is not a board setting. Known: " *
            join(sort(vcat(collect(string.(keys(BOARDSETTINGS))),
                           collect(string.(keys(PINATTRS))))), ", "))
    end
  end
  def = :(const $name = $QuartzHDL.Board($(QuoteNode(name)), $device,
                                         $QuartzHDL.PinBinding[$(pins...)],
                                         $raw,
                                         Dict{Symbol,Any}($(defaults...))))
  doc === nothing ? def : :(Core.@doc $doc $def)
end

# `pull = :up`, or `pull = (0:2 => :down,)` where it differs bit by bit
function _pinattr(key, val)
  key in (:pull, :ext_pull) || return val
  _checkpull(val)
  val
end

_checkpull(v::QuoteNode) = v.value in (:up, :down, :none) ||
  error("@board: a pull is :up, :down or :none, got :$(v.value)")
_checkpull(v::Expr) = v.head == :tuple ?
  foreach(e -> (e isa Expr && e.head == :call && e.args[1] === :(=>) &&
                _checkpull(e.args[3])), v.args) : nothing
_checkpull(::Any) = nothing

function _pinbinding(lhs, rhs, doc=nothing)
  path = _dotpath(lhs)
  attrs = Expr[]
  doc === nothing || push!(attrs, :(:doc => $doc))
  sites = nothing
  items = rhs isa Expr && rhs.head == :tuple ? rhs.args : Any[rhs]
  for a in items
    a isa Expr && a.head in (:(=), :kw) && a.args[1] isa Symbol ||
      error("@board: expected attribute = value, got $a")
    key, val = a.args[1], a.args[2]
    if key === :pin
      sites = :([$val])
    elseif key === :pins
      sites = :(collect($val))
    elseif key === :osc
      push!(attrs, :(:osc => $(_units(val, FREQUNITS))))
    elseif haskey(PINATTRS, key)
      push!(attrs, :($(QuoteNode(key)) => $(_pinattr(key, val))))
    else
      error("@board: $(join(path, ".")) has no attribute $key. Known: pin, pins, " *
            "osc (the rate of an oscillator arriving here), " *
            join(sort(collect(string.(keys(PINATTRS)))), ", "))
    end
  end
  sites === nothing && error("@board: $(join(path, ".")) has no pin or pins")
  :($QuartzHDL.PinBinding(Symbol[$((QuoteNode(p) for p in path)...)],
                          Union{Int,String,Nothing}[$sites...], Dict{Symbol,Any}($(attrs...))))
end

_dotpath(x::Symbol) = [x]
_dotpath(x::Expr) = x.head == :. ? vcat(_dotpath(x.args[1]), _dotpath(x.args[2])) :
                    error("@board: expected a port or instance.port, got $x")
_dotpath(x::QuoteNode) = [x.value]

# The design says what it needs of a board; the board says what it provides. A
# binding that names no port, a port nothing binds, two ports on one site, or a
# width that does not match its pin count are all mistakes worth stopping for.
function problems(b::Board, T::Type)
  out = String[]
  ports = _boardports(T)
  bound = Set{Symbol}()
  sites = Dict{Union{Int,String},Vector{Symbol}}()
  for p in b.pins
    name = portof(p)
    W = get(ports, name, nothing)
    if W === nothing
      push!(out, "$(b.name) binds $(join(p.path, ".")), which is not a port of $(nameof(T))")
      continue
    end
    push!(bound, name)
    length(p.sites) == W ||
      push!(out, "$name is $W bits and $(b.name) gives it $(length(p.sites)) pin(s)")
    for s in p.sites
      s === nothing && continue
      push!(get!(sites, s, Symbol[]), name)
    end
  end
  for (s, names) in sites
    length(names) == 1 ||
      push!(out, "site $s is given to " * join(sort(unique(string.(names))), " and "))
  end
  for (name, _) in ports
    name in bound || push!(out, "$name has no pin on $(b.name)")
  end
  append!(out, _pullproblems(b, T))
  out
end

# A pad that relies on a pull -- an open-drain bus, say -- needs the board to provide
# one the same way, whether the FPGA's own (`pull`) or a resistor on the board
# (`ext_pull`); a board that provides neither, or pulls the other way, is the wrong
# board for this design
function _pullproblems(b::Board, T::Type)
  out = String[]
  pads = Dict(pad.name => pad for pad in _allpads(T))
  for p in b.pins
    pad = get(pads, portof(p), nothing)
    pad === nothing && continue
    want = pad.pull == :pullup ? :up : pad.pull == :pulldown ? :down : nothing
    want === nothing && continue
    against = want === :up ? :down : :up
    missing = Int[]
    flipped = Int[]
    for bit in 0:pad.width-1
      given = [something(_bitattr(b, p, k, bit, :none), :none) for k in (:pull, :ext_pull)]
      against in given ? push!(flipped, bit) : want in given || push!(missing, bit)
    end
    bits(v) = pad.width == 1 ? "" : " (bit" * (length(v) == 1 ? " " : "s ") * join(v, ", ") * ")"
    isempty(flipped) ||
      push!(out, "$(portof(p)) is pulled $want in the design and $(b.name) pulls it $against$(bits(flipped))")
    isempty(missing) ||
      push!(out, "$(portof(p)) relies on a pull-$want and $(b.name) provides none$(bits(missing)), " *
                 "neither its own (pull) nor one on the board (ext_pull)")
  end
  out
end

# a forwarded clock reaches a pin like any other output, so it needs a site too
_boardports(T::Type) =
  Dict(p.name => p.width for p in _ports(T)
       if p.dir in (:input, :output, :inout, :clockout))

### constraint emission

# Every clock's rate, worked out from the oscillators the board provides and the
# dividers the black boxes declare. The design says nothing about frequency; the
# board says nothing about the tree.
function clockrates(T::Type, b::Board)
  rates = Dict{Symbol,Rational{Int}}(oscillators(b)...)
  default = T()
  for _ in 1:16                      # deep enough for any tree; it settles in one or two
    _walkrates!(rates, T, default) || break
  end
  rates
end

function _walkrates!(rates, T::Type, default)
  changed = false
  for (f, FT) in zip(fieldnames(T), fieldtypes(T))
    FT <: QuartzModule || continue
    v = getfield(default, f)
    if isblackbox(FT)
      binds = _clockbind(T, f)
      for c in blackbox(FT).tree
        c.from === nothing && continue
        src = _boundnet(binds, c.from)
        out = _boundnet(binds, c.name)
        (src === nothing || out === nothing || !haskey(rates, src)) && continue
        haskey(rates, out) && continue    # a mux names one output twice; the first wins
        rates[out] = rates[src] // c.divide
        changed = true
      end
    else
      _walkrates!(rates, FT, v) && (changed = true)
    end
  end
  changed
end

# a net named for a global buffer has to be a clock the design has, or the line
# would quietly constrain nothing
function _checkedprimary(T::Type)
  known = _allclocknets(T)
  for net in primarynets(T)
    net in known || error("@primary: $(nameof(T)) has no clock net $net; its clocks are " *
                          join(sort(known), ", "))
  end
  primarynets(T)
end

function _allclocknets(T::Type)
  nets = collect(_clocks(T))
  for c in _internalclocks(T)
    c in nets || push!(nets, c)
  end
  nets
end

# the tool sees the emitted Verilog, so a constraint names the pin as that file
# does, which is not the design's name for it wherever the two were made to differ
function _bitname(T::Type, p::PinBinding, i::Int)
  n = _pinname(T, portof(p))
  length(p.sites) == 1 ? string(n) : "$n[$(i-1)]"
end

# a pad may belong to a module well below the top, and takes its pin name from there
function _pinname(T::Type, name::Symbol)
  for pad in _allpads(T)
    pad.name === name && return pad.vname
  end
  _portattrs(T, name)[1]
end

function _iobufopts(b::Board, p::PinBinding, bit::Int)
  parts = String[]
  # PULLMODE is written even when it is NONE: a buffer's pull is worth stating, and
  # leaving it out means trusting a tool default
  pull = _bitattr(b, p, :pull, bit, :none)
  push!(parts, "PULLMODE=$(uppercase(string(pull === nothing ? :none : pull)))")
  io = _bitattr(b, p, :io, bit, nothing)
  io === nothing || push!(parts, "IO_TYPE=$io")
  dr = _bitattr(b, p, :drive, bit, nothing)
  dr === nothing || push!(parts, "DRIVE=$dr")
  join(parts, " ") * " "
end

# An attribute may differ bit by bit -- three of a power bus pulled down, the rest
# not -- so a value may be a list of `range => value` instead of one value. A
# binding that says nothing takes the board's setting; one that says `nothing` has
# said something, and leaves the pin to the tool.
function _bitattr(b::Board, p::PinBinding, key::Symbol, bit::Int, default)
  haskey(p.attrs, key) || return get(b.defaults, key, default)
  v = p.attrs[key]
  v isa Union{Tuple,AbstractVector} || return v
  for e in v
    e isa Pair || error("@board: $key takes a value or a list of range => value")
    bit in e.first && return e.second
  end
  default
end

# a rate in Hz is already MHz to six decimals, with the point moved
function _mhz(r::Rational)
  hz = round(Int, float(r))
  d = lpad(string(abs(hz)), 7, '0')
  (hz < 0 ? "-" : "") * d[1:end-6] * "." * d[end-5:end]
end

# The instance paths a module appears at, so a module used twice yields two
# constraints -- which the hand-written form cannot express at all.
function _instancepaths(T::Type, M::Type, prefix=String[])
  out = Vector{String}[]
  T === M && push!(out, copy(prefix))
  for (f, FT) in zip(fieldnames(T), fieldtypes(T))
    FT <: QuartzModule && !isblackbox(FT) || continue
    append!(out, _instancepaths(FT, M, vcat(prefix, string(f))))
  end
  out
end

# Which net of the top module drives a submodule's clock port. The block that steps
# the instance names both: its own clock, and the port it steps. Walking the path
# turns the child's `clk_i` into the top's `clk`, which is the name a constraint
# has to use.
function _topclock(T::Type, path::Vector{String}, childclock::Symbol)
  isempty(path) && return childclock
  parent = T
  for f in path[1:end-1]
    parent = fieldtype(parent, Symbol(f))
  end
  field = Symbol(path[end])
  net = _boundnet(parent, field, childclock)
  net === nothing && error("nothing in $(nameof(parent)) wires $field.$childclock to a net")
  _topclock(T, path[1:end-1], net)
end

function _multicyclestr(T::Type, M::Type, m::MultiCycle)
  own = clockof(M, m.to)
  own === nothing && error("@multicycle: nothing writes $(m.to) of $(nameof(M))")
  join(map(_instancepaths(T, M)) do path
         clk = _pinname(T, _topclock(T, path, own))
         # synthesis decorates a register's cells -- a bit index, a replication
         # suffix (pps_pause_10[3]), a grouping prefix with its dot
         # (w534.pps_utime_pipe_29) -- but never another name in front without
         # the dot: one pattern for each side of that dot, and _mkmulticycle
         # refuses any design where a different register could complete either
         p = _prefix(path)
         join(("MULTICYCLE FROM CELL \"$p$f$(m.from)*\" CLKNET \"$clk\" " *
               "TO CELL \"$p$t$(m.to)*\" CLKNET \"$clk\" $(m.cycles).000000 X ;"
               for f in ("", "*."), t in ("", "*.")), "\n")
       end, "\n")
end

_prefix(path) = isempty(path) ? "" : join(path, "/") * "/"

function _allmodules(T::Type, acc=Type[])
  T in acc || push!(acc, T)
  for FT in fieldtypes(T)
    FT <: QuartzModule && !isblackbox(FT) && !(FT in acc) && _allmodules(FT, acc)
  end
  acc
end
