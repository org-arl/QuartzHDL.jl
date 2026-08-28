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
end

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
  for e in entries
    if e.dithered
      push!(every, 0)
      push!(stepv, e.rate // grid)
    else
      n = grid // e.rate
      isinteger(n) ||
        error("@clocks: $(e.name) at $(_ratestr(e.rate)) is not a multiple of the " *
              "$(_ratestr(grid)) grid; mark it `dithered` or set `grid`")
      push!(every, Int(n))
      push!(stepv, 0//1)
    end
  end
  ClockPlan(1 // grid, entries, every, stepv)
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
    elseif slot % p.every[i] == 0
      mask |= UInt64(1) << (i - 1)
    end
  end
  (mask, acc)
end

