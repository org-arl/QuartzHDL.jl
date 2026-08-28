# A bench is a design plus the models of the things around it -- a USB controller,
# an I2C slave, an ADC chip -- advanced together. Everything is a value: one step
# returns a new bench, so a run is a list of states to inspect afterwards.
#
# All models are advanced from the same old state: the wiring function is given the
# state at the start of the cycle and returns each model's inputs for it. That is
# the same rule the design itself follows, and it means a combinational path
# through a peripheral and back arrives a cycle later, as it does on a board.
#
# Only the clocks that come from pins are scheduled, at their real rates; every
# clock a black box makes follows from the tree it declares.

"""
    Bench{D,S,W,K}

A design plus the models of the things around it -- a USB controller, an I2C
slave, an ADC chip -- advanced together. A bench is a value: `step` returns a new
one, so a run is a list of states to look through afterwards.

```julia
b = Bench(dut; clocks, wiring, rtc = I2CSlave())
b = step(b, 1000)
```
"""
struct Bench{D,S<:NamedTuple,W,K}
  dut::D
  stubs::S
  wiring::W
  plan::ClockPlan
  clks::Vector{Symbol}
  slot::Int
  period::Int
  names::NTuple{K,Symbol}            # the plan's entries, in order
  acc::NTuple{K,Rational{Int}}       # where each dithered clock is in its period
end

"""
    Bench(dut; clocks, wiring = Wiring(), stubs...)

`clocks` names the rate of every clock that comes from a pin, and of every stub:
an `@clocks` plan, or for a simple plan a named tuple, `clocks = (clk = 1MHz,)`
with `using QuartzHDL.Units`. `wiring` is an `@wiring` function, and defaults to
nothing connected. Each remaining keyword is a model of something the design is
wired to.
"""
function Bench(dut; clocks, wiring=Wiring(), stubs...)
  clocks = _asplan(clocks)
  nt = NamedTuple(stubs)
  clks = collect(_clocks(typeof(dut)))
  for e in clocks.entries
    e.name in clks || haskey(nt, e.name) ||
      error("$(e.name) is neither a clock of $(nameof(typeof(dut))) nor a stub")
  end
  internal = _internalclocks(typeof(dut))
  for c in clks
    c in internal || any(e -> e.name === c, clocks.entries) ||
      error("$c comes from a pin and needs a rate in @clocks")
  end
  for k in keys(nt)
    any(e -> e.name === k, clocks.entries) || error("stub $k needs a rate in @clocks")
  end
  ev = [e for e in clocks.every if e > 0]
  period = isempty(ev) ? 1 : lcm(ev)
  K = length(clocks.entries)
  Bench(dut, nt, wiring, clocks, unique(clks), 0, period,
        ntuple(i -> clocks.entries[i].name, K), ntuple(_ -> 0//1, K))
end

"the time a bench has run for, in seconds"
Base.time(b::Bench) = b.slot * b.plan.grid

Base.step(b::Bench) = _stepbench(b, NamedTuple(), _tickers(b.plan, b.slot, b.acc)...)

# one slot, with what a stimulus holds on the design's inputs under what the wiring gives
function _stepbench(b::Bench, drives::NamedTuple, mask::UInt64, acc)
  inputs = b.wiring(b.dut, b.stubs)
  dut = _stepslot(b.dut, b.names, mask, b.clks, merge(drives, get(inputs, :dut, NamedTuple())))
  stubs = _stepstubs(b.stubs, inputs, b.names, mask)
  Bench(dut, stubs, b.wiring, b.plan, b.clks, b.slot + 1, b.period, b.names, acc)
end

# each stub that ticks this slot is stepped with its inputs, by name, so the
# record of stubs keeps its type
@generated function _stepstubs(stubs::NamedTuple{S}, inputs, names, mask) where S
  vals = [:(_ticks(names, mask, $(QuoteNode(k))) ?
              step(getfield(stubs, $(QuoteNode(k))); get(inputs, $(QuoteNode(k)), NamedTuple())...) :
              getfield(stubs, $(QuoteNode(k))))
          for k in S]
  :(NamedTuple{$S}($(Expr(:tuple, vals...))))
end

function _ticks(names::NTuple{K,Symbol}, mask::UInt64, k::Symbol) where K
  for i in 1:K
    names[i] === k && return (mask >> (i - 1)) & 1 == 1
  end
  false
end

Base.step(b::Bench, n::Integer) = foldl((x, _) -> step(x), 1:n; init=b)

# replace one model's state, leaving the schedule where it is -- rebuilding the
# bench instead would restart the slot counter and shift every slower clock
setstub(b::Bench, name::Symbol, v) =
  Bench(b.dut, merge(b.stubs, NamedTuple{(name,)}((v,))), b.wiring, b.plan, b.clks,
        b.slot, b.period, b.names, b.acc)

"""
    history(b, n)

Run bench `b` for `n` slots and return every state along the way, the starting one
first, so a run can be looked through afterwards.
"""
function history(b::Bench, n::Integer)
  out = [b]
  for _ in 1:n
    b = step(b)
    push!(out, b)
  end
  out
end

"""
    padnet(m, name)

What the design as a whole drives on pad net `name`, as a `(value, enable)` pair,
so a peripheral model can resolve the net against its own drive.
"""
padnet(m::QuartzModule, name::Symbol) = padnet(m, Val(name))
padnet(m::M, v::Val{name}) where {M<:QuartzModule,name} = _padnet(_padtype(M, v), m, v)
_padnet(::Nothing, m, ::Val{name}) where name = error("$(nameof(typeof(m))) has no pad named $name")
function _padnet(::Type{Pad{N}}, m, v::Val) where N
  val, oe = _netdrive(_netdrives(m), v)
  (Bits{N}(val), Bits{N}(oe))
end

# the first pad of that name in the tree: its pull is the net's
@generated function _padvalue(m::T, ::Val{name}) where {T,name}
  find(x, T) = begin
    for (f, FT) in zip(fieldnames(T), fieldtypes(T))
      e = :(getfield($x, $(QuoteNode(f))))
      FT <: Pad && f === name && return e
      if FT <: QuartzModule && !isblackbox(FT)
        r = find(e, FT)
        r === nothing || return r
      end
    end
    nothing
  end
  something(find(:m, T), :(error($("$(nameof(T)) has no pad named $name"))))
end

# which pads a design has, how wide, and how pulled: fixed by the type and its
# defaults, so found once and looked up per net after that
const PADINFO = IdDict{Type,Dict{Symbol,Tuple{Int,Symbol}}}()
_padinfo(T::Type) = get!(PADINFO, T) do
  _padinfo!(Dict{Symbol,Tuple{Int,Symbol}}(), T, _defaults(T))
end

function _padinfo!(d, T::Type, default)
  for (f, FT) in zip(fieldnames(T), fieldtypes(T))
    if FT <: Pad
      haskey(d, f) || (d[f] = (padwidth(FT), getfield(default, f).pull))
    elseif FT <: QuartzModule && !isblackbox(FT)
      _padinfo!(d, FT, getfield(default, f))
    end
  end
  d
end
