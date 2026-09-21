# Where a design is likely to be slow, read off its source. The wiring of an FPGA
# costs more than its logic, and the paths that cost most have a shape the source
# shows: a condition of many bits that decides what a wide register takes, often
# computed in another module, or arithmetic that feeds arithmetic inside one cycle.
# This is no timing analysis -- it knows nothing of placement -- but it says where
# to look before a vendor build does, and in the names the design was written in.

const ADDERS = (:add, :sub, :mul, :neg)
const SHOWN = 12     # lines of each section of the printed report

# levels of logic, or missing where none were measured
const Depth = Union{Missing,Int}

const TimingPath = @NamedTuple{from::String, to::String, role::Symbol, read::Int, width::Int, inputs::Int,
  controls::Int,
  arithmetic::Vector{Tuple{Symbol,Int}}, crossings::Int, depth::Depth, connected::Union{Missing,Bool}, clock::Symbol,
  source::String, condition::String, flags::Vector{Symbol}, rejected::Vector{Symbol}, exempt::Bool}

const TimingCondition = @NamedTuple{condition::String, instance::String, inputs::Int, controls::Int, crossings::Int,
  reads::Vector{@NamedTuple{from::String, read::Int, crossings::Int}},
  decides::Vector{@NamedTuple{to::String, width::Int, source::String}},
  arithmetic::Vector{Tuple{Symbol,Int}}, depth::Depth, rejected::Vector{Symbol}, exempt::Union{Nothing,String}}

# the budget a design is held to; `custom` says a `reject` of the design's own was given
struct TimingBudget
  max_bits::Vector{Pair{Int,Int}}
  max_carry::Union{Nothing,Int}
  max_chain::Union{Nothing,Int}
  max_depth::Union{Nothing,Int}
  custom::Bool
end

_isgiven(b::TimingBudget) =
  !isempty(b.max_bits) || b.max_carry !== nothing || b.max_chain !== nothing || b.max_depth !== nothing || b.custom

"""
    TimingReport

The result of `timing`. It prints as a summary with the heaviest conditions, one
line each, and the registers with flagged arithmetic. Three calls print more:

- `show(r; top=20)` prints more lines of the summary
- `show(r; condition="adc.jl:204")` prints one condition in full, selected by the
  file and line of its `if`
- `show(r; register="adc1.data")` prints every path that ends at one register

If a budget was given, the summary shows what the budget rejects and leaves out
the list of heaviest conditions.

`paths` has one row for each pair of a start point and the register it reaches,
separately for data and for conditions:

- `from`, `to`: the start point and the register where the path ends, as full names
- `role`: `:condition` if `from` decides whether or what `to` is written, `:data`
  if `from` is part of the value written
- `read`: the number of bits of `from` that the path reads
- `width`: the number of bits in `to`
- `inputs`: for a condition, the number of bits the whole condition reads; for
  data, the number of bits the value is computed from
- `controls`: the number of register bits in the design that the condition controls
- `arithmetic`: the compares and adds in series between the two, with their widths
- `crossings`: the number of module boundaries the path crosses
- `depth`: the number of logic levels found by a synthesis tool, or `missing` if
  none was run
- `connected`: whether synthesis left any path between the two. If it left none,
  `depth` is 0. A depth of 0 with `connected` true means the two registers are
  wired directly together.
- `clock`: the net that clocks `to`
- `source`: the file and line of the write
- `condition`: the file and line of the innermost `if` of the condition
- `flags`: `:chained_arithmetic` or `:muxed_arithmetic`, if the row has that pattern
- `rejected`: the budget rules that the row breaks
- `exempt`: true if every write on the path is under a `@timing_exempt`

`conditions` has one entry for each `if` in the design, combined with the block's
`@only_when` and every `if` around it. An entry holds the line and instance of
the `if`, its `inputs` and `controls`, the full lists of what it `reads` and
`decides`, the compares in it, its `depth` (the deepest path from anything it
reads to anything it decides), the budget rules it breaks, and the reason given
by a `@timing_exempt`, if any. The arms of a long `elseif` chain read the same
registers and control similar ones, so the printed summary shows the heaviest arm
and counts the others.
"""
struct TimingReport
  top::Type
  paths::Vector{TimingPath}
  conditions::Vector{TimingCondition}
  rejected::Vector{TimingCondition}     # the conditions the budget rejects
  rejectedpaths::Vector{TimingPath}     # the paths whose arithmetic it rejects
  exempt::Vector{TimingCondition}       # what it was told to leave alone
  exemptpaths::Vector{TimingPath}
  excluded::Vector{String}        # the multicycle paths left out
  depth::Bool                     # whether `depth` was filled in
  ok::Union{Missing,Bool}         # the budget rejects nothing; missing when there is none
  lut_inputs::Int                 # the variable bits an operation had to exceed to count as arithmetic
  flow::String                    # the yosys flow the depths are from; empty for the generic one, or none
  budget::TimingBudget
end

"""
    timing(T; lut_inputs=4)
    timing(T; max_bits, max_carry, max_chain, max_depth, reject, except=String[])
    timing(T; depth=true, board=nothing, synth=nothing)

Report the logic in module `T`, and everything below it, that is most likely to
limit the clock speed. The design is analysed as one graph, so a path that leaves
one module through a wire and ends at a register in another module is followed
like any other path. Multicycle paths are left out.

Wiring delay is highest for a condition that reads many bits and controls many
register bits, especially when it is computed in another module. The report does
not decide which conditions are a problem. It sorts them by `inputs * controls`,
multiplied by one more than the number of module boundaries crossed, and shows
the heaviest.

A compare or an add that reads `lut_inputs` variable bits or fewer fits in one
LUT, and is treated like any other small piece of logic. One that reads more
needs several LUT levels or a carry chain, and only these count as arithmetic.
Four inputs is the smallest LUT in common use. On an FPGA with larger LUTs the
default may count an operation that would have fit in one LUT, but it will not
miss any. Two arithmetic patterns are flagged:

- `:chained_arithmetic`: two or more arithmetic operations in series
- `:muxed_arithmetic`: the register takes one of several sums, which synthesis may
  build as adders in series

The report is a guide to where to look. It is not a timing measurement, because
it has no information about placement.

With `depth=true` the design is also mapped by yosys. Every row and every
condition then gets a `depth`: the number of LUT levels on the longest path
between its two ends, with a carry chain counted as one level. If synthesis
leaves no path between the two ends, the depth is 0 and the row's `connected`
field is false. This happens, for example, when a register does not reach any
output and is removed. A depth that was not measured is `missing`, so a rule
that uses it raises an error and cannot pass by mistake.

By default yosys maps to generic LUTs with `lut_inputs` inputs and uses no
device information. If `board` is given, yosys runs the flow for the board's
FPGA when one is known. `synth` names a yosys flow directly, for example
`"synth_lattice -family xo2"` for a MachXO2. It takes priority over `board`, and
the flow must flatten the design. If yosys is not installed, there is a warning
and no depths.

If limits are given, a test can check the design against them:

```julia
@test timing(Main; max_bits = 8 => 128, max_carry = 48).ok
```

- `max_bits = 8 => 128`: a condition with more than 8 inputs may control at most
  128 register bits. Several pairs can be given: `(4 => 512, 8 => 128)`.
- `max_carry`: the maximum total width of compares and adds in series on a path
- `max_chain`: the maximum number of compares and adds in series on a path
- `max_depth`: the maximum number of logic levels on a path, as mapped by yosys
- `reject = c -> c.crossings > 0 && c.depth > 6`: your own rule. It receives a
  condition, in the form held in `conditions`, and returns true to reject it.

`rejected` holds the conditions the budget rejects. `rejectedpaths` holds the
paths it rejects because of their arithmetic or depth. Each entry lists the rules
it breaks in its own `rejected` field, and so does every row under a rejected
condition. `ok` is true when nothing is rejected.

A condition marked `@timing_exempt` in the design is not rejected. The same
applies to the conditions nested in it and the paths through it. `except` lists
registers, and the paths that end at them are not rejected. Exempt items are in
`exempt` and `exemptpaths`.

If no budget is given, `ok` is `missing`, so a test with no limits raises an
error and cannot pass by mistake. `ok` is also `missing` if `max_depth` is given
and yosys is not installed. When limits are given, the printed report ends with
the design's current worst values, written as a budget.
"""
function timing(T::Type{<:QuartzModule}; lut_inputs=4, depth=false, board=nothing, synth=nothing, max_bits=(), max_carry=nothing,
    max_chain=nothing, max_depth=nothing, reject=nothing, except=String[]
)
  budget = TimingBudget(_pairs(max_bits), max_carry, max_chain, max_depth, reject !== nothing)
  _isgiven(budget) || isempty(except) || throw(ArgumentError("`except` exempts from a budget, and none is given"))
  d = _flatten(T)
  conditions = _conditions(d, lut_inputs)
  paths = TimingPath[]
  excluded = String[]
  for (si, s) in enumerate(d.sinks)
    _sinkpaths!(paths, excluded, d, conditions, si, s, lut_inputs)
  end
  sort!(paths; by = p -> (-_weight(p), -_chainsum(p.arithmetic), p.to, p.from))
  mapped = (depth || max_depth !== nothing) && _hasyosys()
  found = sort!([_timingcondition(c) for c in values(conditions)]; by = c -> (-_weight(c), c.condition))
  flow = mapped ? _flow(synth, board) : nothing
  mapped && ((paths, found) = _withdepths(T, d, paths, found, flow, lut_inputs))
  found = TimingCondition[merge(c, (rejected=_rejected(c, budget, reject),)) for c in found]
  broken = Dict((c.condition, c.instance, c.inputs, c.controls) => c.rejected for c in found if !isempty(c.rejected))
  paths = TimingPath[merge(p, (rejected=_rejected(p, budget, broken),)) for p in paths]
  badconditions = filter(c -> !isempty(c.rejected), found)
  badpaths = filter(p -> any(in(p.rejected), (:max_carry, :max_chain, :max_depth)), paths)
  exempt = filter(c -> c.exempt !== nothing, badconditions)
  isexempt(p) = p.to in except || p.exempt
  exemptpaths = filter(isexempt, badpaths)
  rejected = filter(c -> c.exempt === nothing, badconditions)
  rejectedpaths = filter(!isexempt, badpaths)
  unknown = !_isgiven(budget) || max_depth !== nothing && !mapped
  ok = unknown ? missing : isempty(rejected) && isempty(rejectedpaths)
  TimingReport(T, paths, found, rejected, rejectedpaths, exempt, exemptpaths, sort!(unique!(excluded)), mapped, ok,
               lut_inputs, something(flow, ""), budget)
end

function Base.show(io::IO, r::TimingReport; condition=nothing, register=nothing, top=nothing)
  condition === nothing || return _showcondition(io, r, condition)
  register === nothing || return _showregister(io, r, register)
  top === nothing || return _showsummary(io, r, top)
  print(io, "TimingReport(", nameof(r.top), ", ", length(r.paths), " paths, ", length(r.conditions), " conditions)")
end

Base.show(r::TimingReport; kwargs...) = show(stdout, r; kwargs...)
Base.show(io::IO, ::MIME"text/plain", r::TimingReport) = _showsummary(io, r, SHOWN)

function _showsummary(io::IO, r::TimingReport, top::Int)
  println(io, "Timing report for ", nameof(r.top))
  print(io, length(r.paths), " paths, ", length(r.conditions), " conditions, ", length(r.excluded), " multicycle paths excluded")
  r.depth && print(io, "\ndepths from yosys, ", isempty(r.flow) ? "mapped to LUTs of $(r.lut_inputs) inputs" : r.flow)
  _showbudget(io, r)
  _isgiven(r.budget) || _showheaviest(io, r, top)
  _isgiven(r.budget) && print(io, "\n\nPresent worst, as a budget\n  ", _worstbudget(r))
end

function _showheaviest(io::IO, r::TimingReport, top::Int)
  rows = [r.depth ? insert!(_conditionrow(g), 5, _depthstr(g[1])) : _conditionrow(g) for g in _alike(r.conditions)]
  header = ["condition", "inputs", "bits", "crossings", "from", "to"]
  r.depth && insert!(header, 5, "depth")
  _table(io, "Heaviest conditions", header, rows, r.depth ? (2:5) : (2:4); limit=top)
  sums = sort!(_grouped(filter(p -> !isempty(p.flags), r.paths), p -> p.to);
               by = g -> -maximum(p -> _chainsum(p.arithmetic), g))
  rows = [(p = argmax(q -> _chainsum(q.arithmetic), g);
           [p.to, _arithstr(p.arithmetic), p.source, _checkstr(g)]) for g in sums]
  _table(io, "Arithmetic", ["register", "operations", "source", "check"], rows, 1:0; limit=top)
  r.depth || return
  deep = sort(filter(p -> p.connected === true, r.paths); by = p -> -p.depth)
  pairs = _grouped(deep, p -> (p.from, p.to))
  rows = [[g[1].from, g[1].to, string(g[1].depth), g[1].source] for g in pairs]
  _table(io, "Deepest paths", ["from", "to", "depth", "source"], rows, 3:3; limit=top)
end

### helpers

_deepest(depths) = maximum((n for n in depths if n isa Int); init=0)

_hasyosys() = Sys.which("yosys") !== nothing || (@warn "yosys not found; the report has no depths"; false)

function _withdepths(T::Type, d::FlatDesign, paths, conditions, synth, lut::Int)
  ends = _netnames(d)
  pins = _pins(T)
  known = Set{String}()
  for p in paths
    union!(known, _startnames(p.from, pins))
    union!(known, get(ends, p.to, [p.to]))
  end
  found = _designdepths(T, synth, lut, known)
  depthof(from, to) = _rowdepth(found, ends, pins, (; from, to))
  (TimingPath[(n = depthof(p.from, p.to); merge(p, (depth=something(n, 0), connected=n !== nothing))) for p in paths],
   TimingCondition[merge(c, (depth=_deepest(depthof(x.from, y.to) for x in c.reads for y in c.decides),)) for c in conditions])
end

# the conditions of one module that read the same registers, the heaviest first:
# the arms of one `if`, as a rule, and one line of a summary
_alike(conditions) = _grouped(conditions, c -> (c.instance, sort!([x.from for x in c.reads])))

function _conditionrow(g)
  c = g[1]
  [c.condition * (length(g) > 1 ? " (+$(length(g) - 1))" : ""), string(c.inputs), string(c.controls),
   string(c.crossings), _fromsummary(c), _tosummary(c)]
end

_pairs(p::Pair) = Pair{Int,Int}[p]
_pairs(ps) = Pair{Int,Int}[p for p in ps]

_instanceof(to::String) = join(split(to, ".")[1:end-1], ".")

# what tells the condition over a row from every other
_conditionkey(p) = (p.condition, _instanceof(p.to), p.inputs, p.controls)

# the rules of the budget a condition breaks
function _rejected(c::TimingCondition, b::TimingBudget, reject)
  rules = Symbol[]
  any(((n, bits),) -> c.inputs > n && c.controls > bits, b.max_bits) && push!(rules, :max_bits)
  reject !== nothing && reject(c) && push!(rules, :reject)
  rules
end

# and a path: those of the condition over it, and those its own arithmetic breaks
function _rejected(p::TimingPath, b::TimingBudget, broken)
  rules = p.role == :condition ? copy(get(broken, _conditionkey(p), Symbol[])) : Symbol[]
  b.max_carry !== nothing && _chainsum(p.arithmetic) > b.max_carry && push!(rules, :max_carry)
  b.max_chain !== nothing && length(p.arithmetic) > b.max_chain && push!(rules, :max_chain)
  b.max_depth !== nothing && p.depth !== missing && p.depth > b.max_depth && push!(rules, :max_depth)
  rules
end

function _budgetstr(b::TimingBudget)
  parts = String[]
  isempty(b.max_bits) || push!(parts, "max_bits=" * (length(b.max_bits) == 1 ? string(b.max_bits[1]) : "($(join(b.max_bits, ", ")))"))
  b.max_carry === nothing || push!(parts, "max_carry=$(b.max_carry)")
  b.max_chain === nothing || push!(parts, "max_chain=$(b.max_chain)")
  b.max_depth === nothing || push!(parts, "max_depth=$(b.max_depth)")
  b.custom && push!(parts, "reject")
  join(parts, ", ")
end

function _showbudget(io::IO, r::TimingReport)
  _isgiven(r.budget) || return
  n = length(r.exempt) + length(r.exemptpaths)
  print(io, "\nBudget ", _budgetstr(r.budget), ": ",
        r.ok ? "within budget" : "$(length(r.rejected)) conditions and $(length(r.rejectedpaths)) paths rejected",
        n == 0 ? "" : ", $n exempt")
  rows = [vcat(_conditionrow(g), join(unique(x for c in g for x in c.rejected), " ")) for g in _alike(r.rejected)]
  _table(io, "Rejected conditions", ["condition", "inputs", "bits", "crossings", "from", "to", "rule"], rows, 2:4)
  rows = [[p.from, p.to, _arithstr(p.arithmetic), string(_chainsum(p.arithmetic)), _depthstr(p), p.source,
           join(filter(in((:max_carry, :max_chain, :max_depth)), p.rejected), " ")] for p in r.rejectedpaths]
  _table(io, "Rejected paths", ["from", "to", "operations", "carry", "depth", "source", "rule"], rows, 4:5)
  rows = [vcat(_conditionrow(g)[1:3], g[1].exempt) for g in _alike(r.exempt)]
  _table(io, "Exempt conditions", ["condition", "inputs", "bits", "reason"], rows, 2:3)
  rows = [[p.from, p.to, _arithstr(p.arithmetic), p.source] for p in r.exemptpaths]
  _table(io, "Exempt paths", ["from", "to", "operations", "source"], rows, 1:0)
end

# the budget that would hold the design where it is now, in the steps that were
# given; what is exempt does not count towards it
function _worstbudget(r::TimingReport)
  steps = isempty(r.budget.max_bits) ? Pair{Int,Int}[] :
    [n => maximum((c.controls for c in r.conditions if c.inputs > n && c.exempt === nothing); init=0)
     for (n, _) in r.budget.max_bits]
  excused = Set(p.to for p in r.exemptpaths)
  carry = maximum((_chainsum(p.arithmetic) for p in r.paths if !(p.to in excused)); init=0)
  chain = maximum((length(p.arithmetic) for p in r.paths if !(p.to in excused)); init=0)
  deepest = r.depth ? maximum((p.depth for p in r.paths if p.depth !== missing && !p.exempt && !(p.to in excused)); init=0) : nothing
  worst = TimingBudget(steps, carry, chain, deepest, false)
  "timing($(nameof(r.top)); $(_budgetstr(worst)))"
end

# a condition of the design: an `if`, with the enable and every `if` around it
struct Condition
  reads::Dict{String,Int}       # where it starts => how many bits it reads there
  crossings::Dict{String,Int}   # and how many module boundaries lie between
  controls::Int                 # the register bits written under it, in the whole design
  decides::Vector{@NamedTuple{to::String, width::Int, source::String}}
  arithmetic::Vector{Tuple{Symbol,Int}}
  instance::String
  at::SourceLine                # the `if` it ends at
  exempt::Union{Nothing,String}
end

_inputs(c::Condition) = sum(values(c.reads); init=0)
_weight(p) = p.inputs * p.controls * (1 + p.crossings)

# rows that are one thing to fix, in the order the rows came in
function _grouped(rows, key)
  groups = Vector{eltype(rows)}[]
  index = Dict{Any,Int}()
  for p in rows
    i = get!(index, key(p)) do
      push!(groups, eltype(rows)[])
      length(groups)
    end
    push!(groups[i], p)
  end
  groups
end

# the conditions of some rows, heaviest first; two conditions may stand on one line
_conditiongroups(rows) =
  sort!(_grouped(rows, p -> (p.condition, p.inputs, p.controls)); by = g -> -maximum(_weight, g))

_checkstr(rows) = join(unique(replace(string(f), "_arithmetic" => "") for p in rows for f in p.flags), " ")

# what a condition reads, as the summary names it: the registers of other modules
# when there are any, since those are the ones that cost wiring
_fromsummary(c) = _names([x.from for x in c.reads if x.crossings > 0], [x.from for x in c.reads])

function _names(far, all)
  names = isempty(far) ? all : far
  rest = length(all) - min(length(names), 2)
  join(names[1:min(end, 2)], ", ") * (rest > 0 ? ", +$rest" : "")
end

_tosummary(c::NamedTuple) = _tosummary([x.to for x in c.decides])

function _tosummary(tos::Vector)
  length(tos) == 1 && return tos[1]
  owners = unique(join(split(t, ".")[1:end-1], ".") for t in tos)
  count = "$(length(tos)) registers"
  length(owners) == 1 && !isempty(owners[1]) ? "$(owners[1]) ($count)" : count
end

# a titled table of text, its numbers set to the right
function _table(io::IO, title, header, rows, numeric; limit=typemax(Int))
  isempty(rows) && return
  shown = rows[1:min(end, limit)]
  widths = [maximum(textwidth(r[k]) for r in vcat([header], shown)) for k in eachindex(header)]
  print(io, "\n\n", title)
  for r in vcat([header], shown)
    cells = [k in numeric ? lpad(r[k], widths[k]) : rpad(r[k], widths[k]) for k in eachindex(r)]
    print(io, "\n  ", rstrip(join(cells, "  ")))
  end
  length(rows) > limit && print(io, "\n  ... ", length(rows) - limit, " more")
  nothing
end

function _showcondition(io::IO, r::TimingReport, at::AbstractString)
  found = filter(c -> c.condition == at, r.conditions)
  isempty(found) && throw(ArgumentError("the report has no condition at $at"))
  for (k, c) in enumerate(found)
    k > 1 && print(io, "\n\n")
    println(io, "Condition at ", at)
    print(io, c.inputs, " inputs, controls ", c.controls, " register bits in ", length(c.decides), " registers, crosses ",
          c.crossings, " module ", c.crossings == 1 ? "boundary" : "boundaries")
    isempty(c.arithmetic) || print(io, "\noperations: ", _arithstr(c.arithmetic))
    c.depth === missing || print(io, "\ndepth: ", c.depth)
    _table(io, "Reads", ["from", "bits read", "crossings"], [[x.from, string(x.read), string(x.crossings)] for x in c.reads], 2:3)
    _table(io, "Decides", ["to", "width", "written at"], [[x.to, string(x.width), x.source] for x in c.decides], 2:2)
  end
end

function _showregister(io::IO, r::TimingReport, name::AbstractString)
  rows = filter(p -> p.to == name, r.paths)
  isempty(rows) && throw(ArgumentError("the report has no path that ends at $name"))
  println(io, "Register ", name)
  print(io, rows[1].width, " bits, clock ", rows[1].clock)
  lines = Vector{String}[]
  for g in _conditiongroups(filter(p -> p.role == :condition, rows)), (k, p) in enumerate(g)
    lead = k == 1 ? [p.condition, string(p.inputs), string(p.controls)] : ["", "", ""]
    push!(lines, vcat(lead, [p.from, string(p.read), string(p.crossings), _depthstr(p), _arithstr(p.arithmetic), p.source,
                             _checkstr([p])]))
  end
  _table(io, "Conditions", _measured(r, ["condition", "inputs", "bits", "from", "bits read", "crossings", "depth",
                                         "operations", "written at", "check"], 7), _measured.(Ref(r), lines, 7),
         r.depth ? [2, 3, 5, 6, 7] : [2, 3, 5, 6])
  data = sort(filter(p -> p.role == :data, rows); by = p -> -_chainsum(p.arithmetic))
  _table(io, "Data", _measured(r, ["from", "bits read", "crossings", "depth", "operations", "written at", "check"], 4),
         [_measured(r, [p.from, string(p.read), string(p.crossings), _depthstr(p), _arithstr(p.arithmetic), p.source,
                        _checkstr([p])], 4) for p in data], r.depth ? (2:4) : (2:3))
end

# a line of a table without its depth column, where no depths were measured
_measured(r::TimingReport, cells, k::Int) = r.depth ? cells : deleteat!(copy(cells), k)

_depthstr(p) = p.depth === missing ? "" : get(p, :connected, true) === false ? "-" : string(p.depth)
_chainsum(arithmetic) = sum((w for (_, w) in arithmetic); init=0)
_arithstr(arithmetic) = join((string(op, w) for (op, w) in arithmetic), " ")

_drivebits(s::Sink, x::Drive) = x.range isa UnitRange ? (_mask(length(x.range)) << first(x.range)) : _mask(s.width)

# every condition, by the instance it is in and the wire of its innermost `if`
function _conditions(d::FlatDesign, lut::Int)
  chains = Dict{Tuple{Int,Int},Vector{Wire{1}}}()
  lines = Dict{Tuple{Int,Int},SourceLine}()
  excuses = Dict{Tuple{Int,Int},Union{Nothing,String}}()
  written = Dict{Tuple{Int,Int},Dict{Int,UInt128}}()
  writes = Dict{Tuple{Int,Int},Dict{Int,Vector{String}}}()
  for (si, s) in enumerate(d.sinks), x in s.drives, k in eachindex(x.guards)
    key = (s.inst, x.guards[k].id)
    get!(chains, key, x.guards[1:k])
    lines[key] = x.guardlines[k]
    excuses[key] = x.exempt[k]
    bits = get!(written, key, Dict{Int,UInt128}())
    bits[si] = get(bits, si, UInt128(0)) | _drivebits(s, x)
    at = get!(get!(writes, key, Dict{Int,Vector{String}}()), si, String[])
    _sourcestr(x.at) in at || push!(at, _sourcestr(x.at))
  end
  out = Dict{Tuple{Int,Int},Condition}()
  for (key, chain) in chains
    c = Cone(lut)
    for g in chain
      _reach!(c, d, key[1], g, :condition)
    end
    decides = [(to=_fullname(d.instances[d.sinks[si].inst], d.sinks[si].name), width=d.sinks[si].width,
                source=join(writes[key][si], " ")) for si in sort!(collect(keys(written[key])))]
    timed = [(name, r) for ((name, _), r) in c.reach
             if !r.multicycle && !all(x -> _excepted(d, name, x.to) !== nothing, decides)]
    reads = Dict{String,Int}(name => count_ones(r.bits) for (name, r) in timed)
    crossings = Dict{String,Int}(name => r.crossings for (name, r) in timed)
    arithmetic = sort!(unique(c.arith[o] for (_, r) in timed for o in r.ops); by = last, rev = true)
    out[key] = Condition(reads, crossings, sum(count_ones, values(written[key])), decides, arithmetic,
                         join(d.instances[key[1]].path, "."), lines[key], excuses[key])
  end
  out
end

function _timingcondition(c::Condition)
  reads = sort!([(from=f, read=n, crossings=c.crossings[f]) for (f, n) in c.reads]; by = x -> (-x.crossings, -x.read, x.from))
  TimingCondition((; condition=_sourcestr(c.at), instance=c.instance, inputs=_inputs(c), controls=c.controls,
                    crossings=maximum(values(c.crossings); init=0), reads, decides=c.decides,
                    arithmetic=c.arithmetic, depth=missing, rejected=Symbol[], exempt=c.exempt))
end

# what one write reads: its value, and the selects inside the value, which are a
# condition of their own that decides the bits the write lands on
function _drivecone(d::FlatDesign, s::Sink, x::Drive, lut::Int)
  c = Cone(lut)
  _reach!(c, d, s.inst, x.value, :data)
  x.range isa DynRange && _reach!(c, d, s.inst, x.range.base, :condition)
  c
end

_bitsread(c::Cone, role::Symbol) = sum((count_ones(r.bits) for ((_, ro), r) in c.reach if ro == role); init=0)

function _excepted(d::FlatDesign, from::String, to::String)
  i = findfirst(e -> startswith(from, e.from) && startswith(to, e.to), d.exceptions)
  i === nothing ? nothing : d.exceptions[i]
end

function _sinkpaths!(paths, excluded, d::FlatDesign, conditions, si::Int, s::Sink, lut::Int)
  to = _fullname(d.instances[s.inst], s.name)
  whole = _sinkcone(d, s, lut)
  drivecones = [_drivecone(d, s, x, lut) for x in s.drives]
  sums = _sums(s, lut)
  for ((from, role), reach) in whole.reach
    e = _excepted(d, from, to)
    if reach.multicycle || e !== nothing
      push!(excluded, e === nothing ? "$from → $to" : "$from → $to ($(e.cycles) cycles)")
      continue
    end
    arithmetic = [whole.arith[o] for o in reverse(reach.chain)]
    inputs, controls, at, ifat = role == :condition ? _worstcondition(conditions, s, drivecones, from) :
                                                      _worstdata(s, drivecones, from)
    flags = _flags(s, role, arithmetic, sums)
    push!(paths, (; from, to, role, read=count_ones(reach.bits), width=s.width, inputs, controls, arithmetic, crossings=reach.crossings, depth=missing, connected=missing,
                  clock=s.clock, source=_sourcestr(at), condition=_sourcestr(ifat), flags, rejected=Symbol[],
                  exempt=role == :condition && _excused(conditions, s, from)))
  end
end

# whether every write of the sink that `from` decides stands under a tag: the tag
# of an `if` speaks for its own arm, so a write in a later arm of the chain is not
# excused by it, though the `if` is one of the conditions over it
function _excused(conditions, s::Sink, from::String)
  decided = [x for x in s.drives if any(g -> haskey(conditions[(s.inst, g.id)].reads, from), x.guards)]
  !isempty(decided) && all(x -> last(x.exempt) !== nothing, decided)
end

# of the conditions that stand over a write of the sink and read `from`, the one
# that reads most and decides most
function _worstcondition(conditions, s::Sink, drivecones, from::String)
  best = (0, 0, s.at, s.at)
  for (x, dc) in zip(s.drives, drivecones)
    for g in x.guards
      c = conditions[(s.inst, g.id)]
      haskey(c.reads, from) || continue
      cand = (_inputs(c), c.controls, x.at, c.at)
      cand[1] * cand[2] > best[1] * best[2] && (best = cand)
    end
    haskey(dc.reach, (from, :condition)) || continue
    cand = (_bitsread(dc, :condition), count_ones(_drivebits(s, x)), x.at, x.at)
    cand[1] * cand[2] > best[1] * best[2] && (best = cand)
  end
  best
end

function _worstdata(s::Sink, drivecones, from::String)
  best = (0, 0, s.at, nothing)
  width = -1
  for (x, dc) in zip(s.drives, drivecones)
    r = get(dc.reach, (from, :data), nothing)
    r === nothing && continue
    w = _chainwidth(dc, r.chain)
    w > width || continue
    width = w
    best = (_bitsread(dc, :data), 0, x.at, nothing)
  end
  best
end

# how many different sums may land on one bit of the register: more than one is a
# mux of arithmetic results, which synthesis is free to build as a chain. The same
# sum written in two places is one sum, so they are told apart by structure.
function _sums(s::Sink, lut::Int)
  landing = [Set{Any}() for _ in 1:s.width]
  for x in s.drives
    x.value isa Wire && _sums!(landing, x.value, x.range isa UnitRange ? first(x.range) : 0, lut)
  end
  maximum(length, landing)
end

function _sums!(landing, w::Wire, low::Int, lut::Int)
  if w.op in ADDERS
    _varbits(w) > lut || return
    key = _wirekey(w)
    for bit in low+1:min(low + bitwidth(w), length(landing))
      push!(landing[bit], key)
    end
  elseif w.op == :concat
    w.args[2] isa Wire && _sums!(landing, w.args[2], low, lut)
    w.args[1] isa Wire && _sums!(landing, w.args[1], low + bitwidth(w.args[2]), lut)
  elseif w.op in (:mux, :resize, :repeat)
    for a in (w.op == :mux ? w.args[2:3] : w.args)
      a isa Wire && _sums!(landing, a, low, lut)
    end
  end
end

function _flags(s::Sink, role, arithmetic, sums)
  flags = Symbol[]
  staged = s.kind == :pipeline && role == :data
  staged || length(arithmetic) < 2 || push!(flags, :chained_arithmetic)
  role == :data && sums > 1 && any(((op, _),) -> op in ADDERS, arithmetic) && push!(flags, :muxed_arithmetic)
  flags
end
