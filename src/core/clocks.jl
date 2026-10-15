# What a run's clocks do. Rates are absolute, so a log can say microseconds rather
# than slots, and the ratios follow from them instead of being maintained by hand.
#
# One slot is the finest grid every clock's period divides. A clock whose rate does
# not divide it can be marked `dithered`: it then ticks on the nearest slot, with the
# error never more than one slot and the long-run rate exactly what was asked for.
# A model of a chip around the design is given a rate the same way.

struct ClockEntry
  name::Symbol
  rate::Rational{Int}          # in Hz
  dithered::Bool               # ticks on the nearest slot, rather than dividing the grid
  offset::Rational{Int}        # seconds before its first edge: a clock made from a phased source
end
ClockEntry(name::Symbol, rate::Rational{Int}, dithered::Bool) = ClockEntry(name, rate, dithered, 0 // 1)

"""
    ClockPlan

What a run's clocks do: every clock's rate, and the slot grid they share. Built by
`@clocks` and handed to a `Bench`, which advances one slot at a time.
"""
struct ClockPlan
  grid::Rational{Int}          # seconds per slot
  entries::Vector{ClockEntry}
  every::Vector{Int}           # slots per edge, for the exact ones
  step::Vector{Rational{Int}}  # accumulator increment, for the dithered ones
  offset::Vector{Int}          # slots before the first edge, for the exact ones
  fixed::Bool                  # the grid was set by hand, and stays when clocks are added
end

Base.show(io::IO, p::ClockPlan) =
  print(io, "ClockPlan(", _ratestr(1 // p.grid), " grid, ",
        join(("$(e.name) " * _ratestr(e.rate) * (e.dithered ? " dithered" : "") for e in p.entries), ", "), ")")

_ratestr(r::Rational) = r ≥ 1000000 ? "$(float(r)/1e6)MHz" :
                        r ≥ 1000 ? "$(float(r)/1e3)kHz" : "$(float(r))Hz"

"""
    @clocks begin ... end

Names the rate of every clock a run has, in absolute units, and builds the
`ClockPlan` a `Bench` takes. A clock whose rate does not divide the slot grid may
be marked `dithered`; `grid` sets the slot rate by hand.

```julia
@clocks begin
  clk = 48MHz
  rtc = 32768Hz, dithered
end
```

A simple plan needs no macro: `Bench` and `Simulation` also take a named tuple of
rates, `clocks = (clk = 1MHz,)` (with `using QuartzHDL.Units`), with `(rate,
:dithered)` for a dithered clock and `grid` for the slot rate.
"""
macro clocks(block)
  esc(_clocks(block))
end

function _clocks(block)
  block isa Expr && block.head == :block || error("@clocks: expected a begin ... end block")
  grid = nothing
  entries = Expr[]
  for item in block.args
    item isa LineNumberNode && continue
    item isa Expr && item.head == :(=) && item.args[1] isa Symbol ||
      error("@clocks: expected `name = rate` or `name = rate, dithered`, got $item")
    name, rhs = item.args
    opts = rhs isa Expr && rhs.head == :tuple ? rhs.args[2:end] : Any[]
    val = rhs isa Expr && rhs.head == :tuple ? rhs.args[1] : rhs
    dithered = false
    for o in opts
      o === :dithered || error("@clocks: unexpected option $o; a clock may be `dithered`")
      dithered = true
    end
    val isa Symbol && error("@clocks: $name takes a rate, e.g. `$name = 48MHz`")
    if name === :grid
      grid = _units(val, FREQUNITS)
    else
      push!(entries, :($QuartzHDL.ClockEntry($(QuoteNode(name)), $(_units(val, FREQUNITS)), $dithered)))
    end
  end
  :($QuartzHDL._clockplan($QuartzHDL.ClockEntry[$(entries...)],
                          $(grid === nothing ? :nothing : grid)))
end

# how much finer than the fastest clock the grid has to be; past this an exact grid
# is almost always an accident rather than an intent
const GRIDLIMIT = 4

function _clockplan(entries::Vector{ClockEntry}, gridrate)
  isempty(entries) && error("@clocks: no clocks")
  exact = [e for e in entries if !e.dithered]
  isempty(exact) && error("@clocks: at least one clock must have an exact rate")
  fastest = maximum(e.rate for e in entries)
  grid = gridrate === nothing ? 1 // foldl(gcd, (1 // e.rate for e in exact)) :
         gridrate
  if gridrate === nothing
    cost = grid // fastest
    cost ≤ GRIDLIMIT || _gridtoofine(exact, grid, fastest, cost)
  end
  every = Int[]
  stepv = Rational{Int}[]
  offset = Int[]
  for e in entries
    if e.dithered
      push!(every, 0)
      push!(stepv, e.rate // grid)
      push!(offset, 0)
    else
      n = grid // e.rate
      isinteger(n) ||
        error("@clocks: $(e.name) at $(_ratestr(e.rate)) is not a multiple of the " *
              "$(_ratestr(grid)) grid; mark it `dithered` or set `grid`")
      o = e.offset * grid
      isinteger(o) || error("@clocks: $(e.name) starts $(float(e.offset)) s in, which is not a whole number of slots")
      push!(every, Int(n))
      push!(stepv, 0//1)
      push!(offset, Int(o))
    end
  end
  ClockPlan(1 // grid, entries, every, stepv, offset, gridrate !== nothing)
end

# The clocks a design's black boxes multiply, with the plan's entries: each gets
# the rate the tree makes for it from the plan's pin clocks, through whatever
# dividers and multipliers lie between, and a place on the grid, which is refined
# to fit it unless it was set by hand. The divided clocks on the way stay off the
# grid: the tree ticks them from their source's edges, and a phase among them
# delays the first edge of what is made from them. Only the top's recipes are
# followed, as only the top's multiplied clocks are scheduled: a submodule's net
# of the same name is another net. A rate the plan gives such a clock itself
# has to be the recipe's.
function _withmultiplied(p::ClockPlan, T::Type)
  made = _multiplied(T)
  isempty(made) && return p
  given = [e for e in p.entries if !any(x -> x[1] === e.name, made)]
  rates = _derivedrates!(Dict{Symbol,Rational{Int}}(e.name => e.rate for e in given), T; deep=false)
  offsets = _offsets(T, rates, [e.name for e in given])
  entries = copy(p.entries)
  for (net, src, _, _) in made
    haskey(rates, net) || error("$net is multiplied from $src, which has no rate in the clock plan")
    i = findfirst(e -> e.name === net, entries)
    entry = ClockEntry(net, rates[net], false, get(offsets, net, 0 // 1))
    if i === nothing
      push!(entries, entry)
    elseif entries[i].rate != rates[net]
      error("$net is made by a part at $(_ratestr(rates[net])), and the clock plan says $(_ratestr(entries[i].rate)); " *
            "a clock a part makes takes its rate from the recipe")
    else
      entries[i] = entry
    end
  end
  _clockplan(entries, p.fixed ? 1 // p.grid : nothing)
end

# when each clock the top's parts make has its first edge: a divided clock's
# first edge is its source's edge number `phase`, and a multiplied clock starts
# with its source
function _offsets(T::Type, rates, given)
  offsets = Dict{Symbol,Rational{Int}}(e => 0 // 1 for e in given)
  for _ in 1:16
    changed = false
    for (f, FT) in zip(fieldnames(T), fieldtypes(T))
      isblackbox(FT) || continue
      binds = _clockbind(T, f)
      for c in blackbox(FT).tree
        c.from === nothing && continue
        src, out = _boundnet(binds, c.from), _boundnet(binds, c.name)
        (src === nothing || out === nothing || !haskey(offsets, src) || !haskey(rates, src)) && continue
        o = offsets[src] + mod(c.phase, c.divide) // rates[src]
        (haskey(offsets, out) && offsets[out] == o) && continue
        haskey(offsets, out) && continue      # a mux names one output twice; the first wins
        offsets[out] = o
        changed = true
      end
    end
    changed || break
  end
  offsets
end

# A one-line plan needs no macro: `clocks = (clk = 1MHz,)` with the Units module
# loaded says the same as the block. A rate is a number; `(rate, :dithered)` marks
# a clock dithered, and `grid` sets the slot rate, as it does in the block.
_asplan(p::ClockPlan) = p
function _asplan(nt::NamedTuple)
  grid = nothing
  entries = ClockEntry[]
  for (name, v) in pairs(nt)
    if name === :grid
      grid = _exact(v)
    elseif v isa Real
      push!(entries, ClockEntry(name, _exact(v), false))
    elseif v isa Tuple && length(v) == 2 && v[1] isa Real && v[2] === :dithered
      push!(entries, ClockEntry(name, _exact(v[1]), true))
    else
      error("clocks: $name takes a rate, e.g. `$name = 1MHz` (with `using QuartzHDL.Units`), " *
            "or `(rate, :dithered)`; got $v")
    end
  end
  _clockplan(entries, grid)
end
_asplan(x) = error("clocks is an @clocks plan or a named tuple of rates, got $(typeof(x))")

function _gridtoofine(exact, grid, fastest, cost)
  worst = argmin(e -> gcd(1 // e.rate, 1 // fastest), exact)
  error("@clocks: $(worst.name) does not divide $(_ratestr(fastest)), so an exact grid " *
        "needs $(round(Int, float(cost))) slots per cycle; mark it `dithered` or set `grid`")
end

# which clocks have an edge in this slot; `acc` carries the dithered ones
function _tickers(p::ClockPlan, slot::Int, acc::NTuple{K,Rational{Int}}) where K
  mask = UInt64(0)
  for i in 1:K
    e = p.entries[i]
    if e.dithered
      a = acc[i] + p.step[i]
      if a ≥ 1
        a -= 1
        mask |= UInt64(1) << (i - 1)
      end
      acc = Base.setindex(acc, a, i)
    elseif slot ≥ p.offset[i] && (slot - p.offset[i]) % p.every[i] == 0
      mask |= UInt64(1) << (i - 1)
    end
  end
  (mask, acc)
end

