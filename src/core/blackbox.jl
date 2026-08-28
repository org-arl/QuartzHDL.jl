# A black box is a Verilog module QuartzHDL does not define: a vendor PLL, a RAM
# block, an oscillator. The declaration gives the ports, so the compiler can
# instantiate it, and the design wires it: clock nets in the constructor, data
# inputs from @wire blocks. What the part does on an edge is not the design's to
# say -- the simulator acts out a clock tree from the clockout recipes, and a
# harness supplies a stand-in for anything else. Nothing is emitted for the module.

# What a clock output is made of: which of the part's clock inputs it divides, by
# how much, with what phase, and under what condition it runs at all. This is the
# only description of the clock tree -- the simulator computes the edges from it, and
# the behavioural Verilog used in place of the vendor netlist is generated from it,
# so the two cannot say different things.
struct ClockOut
  name::Symbol
  from::Union{Nothing,Symbol,Expr}
  divide::Int
  phase::Int                  # in source-clock edges
  hasenable::Bool
  bit::Int                    # the output's place in the part's tick and level masks
end

struct BlackboxDef
  verilogname::Symbol
  ports::Vector{Port}
  pragma::String
  tree::Vector{ClockOut}
  outs::Vector{Symbol}
  docs::Dict{Symbol,String}
end

# A vendor part names its ports the way its datasheet does. The declaration keeps
# those names; Julia sees the lowercase of each, so a design reads as Julia and the
# emitted instance still says `.CLKI(...)`.
_juliaport(v::Symbol) = Symbol(lowercase(String(v)))

blackbox(::Type) = nothing
_clockenable(::Type{T}, ::Val{i}, ::NamedTuple) where {T,i} =
  error("clock output $i of $(nameof(T)) has no enable condition")
isblackbox(T) = T isa Type && T <: BlackBox

"""
    QuartzHDL.standin(::Type{Part}) = Model()

What a black box does in simulation, supplied by the harness rather than the
design. The model is stepped by the simulator on every edge of each clock input,
as `step(model, :clockport; inputs...)`, and must return the model after the edge;
an output of the part reads as the model's property of the same (lowercase) name. A
part whose outputs are all `clockout`s needs none: its recipes are its behaviour.
"""
standin(::Type) = nothing

"""
    @blackbox Name verilog="VNAME" begin ... end

Declares a Verilog module QuartzHDL does not define -- a vendor PLL, a RAM block,
an oscillator. The body lists its ports (`input`, `output`, `clock`, `clockout`)
using the datasheet's names; a `clockout` also says which clock input it divides,
by how much, and under what condition it runs. Nothing is emitted for the module
itself, and `QuartzHDL.standin` supplies whatever behaviour a simulation needs.

```julia
@blackbox PLL verilog="EHXPLLL" begin
  clock(CLKI)
  clockout(CLKOP, from=CLKI, divide=2)
end
```
"""
macro blackbox(name, args...)
  esc(_blackbox(name, args, __module__))
end

"""
    clocklevel(m, net)

The level a clock net is resting at, for a design that samples a slow clock as
data -- a microsecond tick, say. In Verilog this is the net name in an expression;
here it is the square wave the tree produces.
"""
clocklevel(m::QuartzModule, net::Symbol) = clocklevel(m, Val(net))

# A @wire block asks on every settle pass, so the walk -- which instance, down
# which path, holds the level -- is plain code: one method per type and net,
# evaluated when the bindings are registered. A net the bindings cannot place is
# resolved when first asked for, and the error says why.
function clocklevel(m::T, ::Val{net}) where {T<:QuartzModule,net}
  r = _resolvelevel(T, net, Symbol[])
  # a full-rate clock has no wave the cycle world can track: read as data it is
  # its resting pre-edge level, which is also what a testbench samples
  r === nothing ? false : _levelat(m, r...)
end

# Every clock output in the module tree that is wired to a net, as (net, divide,
# ticked this slot): one entry per output, in tree order, from a method evaluated
# per type when its bindings are registered. A clock that divides is settled
# before the faster clock beside it, so a design sampling a slow clock as data
# reads the new level. The emitted Verilog orders its delays the same way; the two
# have to agree or a crossing lands a cycle apart.
_treeedges(::QuartzModule) = ()

# every clock net that had an edge in the module tree this step, slowest first
function clockedges(m::QuartzModule)
  edges = _treeedges(m)
  order = sort(collect(1:length(edges)); by = i -> -edges[i][2], alg = Base.Sort.MergeSort)
  out = Symbol[]
  for i in order
    net, _, ticked = edges[i]
    ticked && !(net in out) && push!(out, net)
  end
  out
end

# One slot of a run: the clocks that come from pins tick on their declared schedule,
# and every clock a black box makes ticks when its tree says so -- in topological
# order, since a part cannot produce an edge until its source has had one.
stepslot(m::QuartzModule, clks, every, internal, slot; kwargs...) =
  _slotstep(m, [c for (c, ev) in zip(clks, every) if !(c in internal) && slot % ev == 0],
            clks, values(kwargs))

# The schedule of a run: only the clocks that come from pins need a ratio, and they
# are given one relative to each other. Every clock a black box makes is added
# unscheduled -- the tree says when it ticks.
function clockschedule(T::Type, clocks)
  internal = _internalclocks(T)
  pinned = [c for c in _clocks(T) if !(c in internal)]
  clks = clocks === nothing ? copy(pinned) : collect(keys(clocks))
  counts = clocks === nothing ? fill(1, length(clks)) : collect(values(clocks))
  if clocks === nothing
    length(pinned) ≤ 1 ||
      error("this design has several clocks from pins, so it needs a ratio for each: " *
            join(pinned, ", "))
  else
    missed = setdiff(Set(pinned), Set(clks))
    isempty(missed) ||
      error("every clock of $(nameof(T)) that comes from a pin needs a ratio: " *
            join(sort(collect(missed)), ", "))
  end
  for c in _clocks(T)
    c in clks || (push!(clks, c); push!(counts, 1))
  end
  L = isempty(counts) ? 1 : maximum(counts)
  all(L % n == 0 for n in counts) || error("each clock count must divide the largest ($L)")
  (clks, [L ÷ n for n in counts], internal, L)
end

### helpers

# The state of a part's clock tree is three words: a counter per recipe, and a bit
# per clock output for "ticked this slot" and for the level it holds. Nothing in
# it is a pointer, so a part -- and every module holding one -- stays inline.
_hasbit(mask::UInt64, bit::Int) = (mask >> bit) & 1 == 1
_setbit(mask::UInt64, bit::Int, on::Bool) = on ? mask | (UInt64(1) << bit) : mask & ~(UInt64(1) << bit)

function _bbport(T::Type, f::Symbol)
  i = findfirst(p -> p.name === f, blackbox(T).ports)
  i === nothing ? nothing : blackbox(T).ports[i]
end

# An output reads from the model, or as zero when there is none to read from. The
# declaration defines one method per output, and the value read is asserted to the
# port's width, so a design reading a stand-in -- which the design cannot know the
# type of -- still knows what it read.
function _bboutput(x::T, ::Val{f}) where {T,f}
  p = _bbport(T, f)
  error("$(nameof(T)) has no output $f" *
        (p === nothing ? "" : "; $f is $(p.dir == :input ? "an input" : "a clock")"))
end

function _modeloutput(x::T, ::Val{f}, ::Type{RT}) where {T,f,RT}
  m = getfield(x, :model)
  m === nothing && return RT(0)
  hasproperty(m, f) ||
    error("the stand-in $(nameof(typeof(m))) for $(nameof(T)) has no property $f to read output $f from")
  getproperty(m, f)::RT
end

_bbouttype(::Type{T}) where T = (W = _portinfo(T)[1]; W == 1 ? Bool : Bits{W})

_stepmodel(::Nothing, port, inputs) = nothing
_stepmodel(m, port, inputs) = step(m, port; inputs...)

function _wireboxinputs(x::T, nt::NamedTuple) where T
  new = _setinputs(_inputsof(x), nt)
  new === _inputsof(x) ? x :
    T(new, getfield(x, :counts), getfield(x, :ticked), getfield(x, :levels), getfield(x, :model))
end

# A test may run a slow domain faster than the board does, so that a few thousand
# cycles cover many of its periods. The override is per black box and per clock
# output, and it is a property of the run, not of the design: the design states the
# rates the board actually produces.
const CLOCKSCALE = gensym(:clockscale)

_scaletable() = get(task_local_storage(), CLOCKSCALE, nothing)::Union{Nothing,Dict{Symbol,Dict{Symbol,Int}}}

function _divide(T::Type, c::ClockOut)
  t = _scaletable()
  t === nothing && return c.divide
  part = get(t, nameof(T), nothing)
  (part === nothing ? c.divide : get(part, c.name, c.divide))::Int
end

withclockscale(f, scale) = _withtasklocal(f, CLOCKSCALE, _asscale(scale))

_asscale(::Nothing) = Dict{Symbol,Dict{Symbol,Int}}()
_asscale(d::Dict{Symbol,Dict{Symbol,Int}}) = d
_asscale(nt::NamedTuple) =
  Dict{Symbol,Dict{Symbol,Int}}(k => Dict{Symbol,Int}(pairs(v)) for (k, v) in pairs(nt))

# One edge on clock input `port`: the recipes tick, and the stand-in is stepped.
# A part's clock outputs are counted in source edges -- the instance is stepped once
# per edge of the clock input it divides, so the counter lives with the instance --
# and `phase` is the offset within a divide period, so `divide = 4, phase = 1` ticks
# on the second of every four.
function _stepbb(x::T, port::Symbol) where T
  bb = blackbox(T)
  inputs = _inputsof(x)
  m = getfield(x, :model)
  model = m === nothing ? nothing : _stepmodel(m, port, inputs)
  counts = getfield(x, :counts)
  ticked = getfield(x, :ticked)
  levels = getfield(x, :levels)
  for (i, c) in enumerate(bb.tree)
    c.from === port || continue
    c.hasenable && !Bool(_clockenable(T, Val(i), inputs)) && continue
    d = _divide(T, c)
    n = counts[i]
    k = mod(n - c.phase, d)
    if k == 0
      ticked = _setbit(ticked, c.bit, true)
      levels = _setbit(levels, c.bit, true)
    elseif k == cld(d, 2)
      levels = _setbit(levels, c.bit, false)   # a proper square wave, so it reads as data
    end
    counts = Base.setindex(counts, n + 1, i)
  end
  T(inputs, counts, ticked, levels, model)
end

# A part holds the edges it produced until it is stepped again, so the record is
# cleared at the start of a slot: a source that does not tick this slot must not
# leave last slot's edges behind. The walk to every part is one flat expression
# over the type tree, so no method is re-entered level by level.
@generated function _clearticks(m::T) where T
  ex = _clearexpr(:m, T)
  ex === nothing ? :m : ex
end

function _clearexpr(x, T)
  isblackbox(T) && return :(_cleared($x))
  vals = Any[]
  for (f, FT) in zip(fieldnames(T), fieldtypes(T))
    FT <: QuartzModule || continue
    e = _clearexpr(:(getfield($x, $(QuoteNode(f)))), FT)
    e === nothing || push!(vals, Expr(:kw, f, e))
  end
  isempty(vals) ? nothing : :(_merge($x, $(Expr(:tuple, Expr(:parameters, vals...)))))
end

_cleared(x::T) where T =
  getfield(x, :ticked) == 0 ? x :
  T(_inputsof(x), getfield(x, :counts), UInt64(0), getfield(x, :levels), getfield(x, :model))

function _levelat(m, path::Vector{Symbol}, bit::Int)
  x = m
  for f in path
    x = getfield(x, f)
  end
  _hasbit(getfield(x, :levels)::UInt64, bit)
end

_levelbit(x, ::Val{bit}) where bit = _hasbit(getfield(x, :levels), bit)

function _definelevels(T::Type)
  exprs = Expr[]
  for net in _derivednets(T)
    r = try
      _resolvelevel(T, net, Symbol[])
    catch
      continue
    end
    if r === nothing
      push!(exprs, :(clocklevel(m::$T, ::Val{$(QuoteNode(net))}) = false))
      continue
    end
    path, bit = r
    x = foldl((acc, f) -> :(getfield($acc, $(QuoteNode(f)))), path; init=:m)
    push!(exprs, :(clocklevel(m::$T, ::Val{$(QuoteNode(net))}) = _levelbit($x, Val($bit))))
  end
  Core.eval(QuartzHDL, Expr(:block, exprs...))
end

function _derivednets(T::Type)
  nets = Symbol[]
  for (f, FT) in zip(fieldnames(T), fieldtypes(T))
    FT <: QuartzModule || continue
    if isblackbox(FT)
      for c in blackbox(FT).tree
        net = _boundnet(_clockbind(T, f), c.name)
        net === nothing || net in nets || push!(nets, net)
      end
    else
      for net in _derivednets(FT)
        net in nets || push!(nets, net)
      end
    end
  end
  nets
end

function _resolvelevel(T::Type, net::Symbol, seen::Vector{Symbol})
  net in seen && error("clock net $net is derived from itself")
  net in _clocksof(T) && return nothing        # a clock pin of the design: full rate
  found = _findlevel(T, net)
  found === nothing && error("no black box in this design drives a clock net called $net")
  path, FT, c, binds = found
  # a clock that divides by one is its source under another name, so its level is
  # the source's -- it has none of its own to track. A chain that ends at one of
  # the design's own clock pins is full rate, with no level holder at all
  src = c.from === nothing ? nothing : _boundnet(binds, c.from)
  _divide(FT, c) == 1 && src !== nothing &&
    return src in _clocksof(T) ? nothing : _resolvelevel(T, src, push!(seen, net))
  (path, c.bit)
end

function _findlevel(T::Type, net::Symbol)
  for (f, FT) in zip(fieldnames(T), fieldtypes(T))
    FT <: QuartzModule || continue
    if isblackbox(FT)
      binds = _clockbind(T, f)
      for c in blackbox(FT).tree
        _boundnet(binds, c.name) === net && return (Symbol[f], FT, c, binds)
      end
    else
      r = _findlevel(FT, net)
      r === nothing || return (pushfirst!(r[1], f), r[2], r[3], r[4])
    end
  end
  nothing
end

function _treeedgesexpr(T::Type, d)
  parts = Any[]
  for (f, FT) in zip(fieldnames(T), fieldtypes(T))
    FT <: QuartzModule || continue
    x = :(getfield(m, $(QuoteNode(f))))
    if isblackbox(FT)
      bb = blackbox(FT)
      binds = get(d, f, Pair{Symbol,Symbol}[])
      for (i, c) in enumerate(bb.outs)
        net = _boundnet(binds, c)
        net === nothing && continue
        recipes = [t for t in bb.tree if t.name === c]
        div = foldl((a, t) -> :(_divide($FT, $t)), recipes; init=1)
        push!(parts, :(($(QuoteNode(net)), $div, _hasbit(getfield($x, :ticked), $(i - 1)))))
      end
    else
      push!(parts, :(_treeedges($x)...))
    end
  end
  Expr(:tuple, parts...)
end

function _bbport(name::Symbol, dir::Symbol, t)
  W, sg = _portinfo(t)
  Port(_juliaport(name), dir, W, sg, true, name)
end

function _blackbox(name, args, mod)
  name isa Symbol || error("@blackbox: expected a Verilog module name")
  block = nothing
  vname = name
  for a in args
    if a isa Expr && a.head == :(=) && a.args[1] == :verilog
      vname = Symbol(a.args[2])
    elseif a isa Expr && a.head == :block
      block = a
    else
      error("@blackbox: unexpected argument $a")
    end
  end
  block === nothing && error("@blackbox: expected a begin ... end block of port declarations")
  doc, items = _blockdoc(block.args, "black box")
  docs = Expr[]
  ports = Expr[]
  pragma = ""
  clockouts = Symbol[]
  tree = []
  inputnames = Symbol[]
  outs = Tuple{Symbol,Any}[]
  ins = Tuple{Symbol,Any,Any}[]
  seenports = Set{Symbol}()
  for x in items
    x isa LineNumberNode && continue
    d, item = _undoc(x)
    item isa Expr && item.head == :call || error("@blackbox: unexpected item $item")
    kind = item.args[1]
    d === nothing || kind in (:input, :output, :clock, :clockout) ||
      error("@blackbox: only a port takes a docstring, got $item")
    if kind in (:input, :output)
      for a in item.args[2:end]
        a isa Expr && a.head == :(::) && length(a.args) == 2 && a.args[1] isa Symbol ||
          error("@blackbox: port $a needs a type annotation, `name::Type`")
        n, t = a.args
        d === nothing || push!(docs, :($(QuoteNode(_juliaport(n))) => $d))
        kind === :input && (push!(inputnames, _juliaport(n)); push!(ins, (_juliaport(n), t, nothing)))
        kind === :output && push!(outs, (_juliaport(n), t))
        push!(seenports, _juliaport(n))
        push!(ports, :($QuartzHDL._bbport($(QuoteNode(n)), $(QuoteNode(kind)), $t)))
      end
    elseif kind in (:clock, :clockout)
      names = Symbol[]
      opts = Dict{Symbol,Any}()
      for a in item.args[2:end]
        if a isa Symbol
          push!(names, a)
        elseif a isa Expr && a.head in (:kw, :(=)) && a.args[1] isa Symbol
          kind == :clockout || error("@blackbox: $kind takes port names only")
          a.args[1] in (:from, :divide, :phase, :enable) ||
            error("@blackbox: clockout takes from, divide, phase and enable")
          opts[a.args[1]] = a.args[2]
        else
          error("@blackbox: $kind takes port names, got $a")
        end
      end
      isempty(opts) || length(names) == 1 ||
        error("@blackbox: a clockout with options declares one port at a time")
      for a in names
        d === nothing || push!(docs, :($(QuoteNode(_juliaport(a))) => $d))
        # a clock mux declares one output twice, once per source: one port, two entries
        _juliaport(a) in seenports ||
          (push!(seenports, _juliaport(a));
           push!(ports, :($QuartzHDL.Port($QuartzHDL._juliaport($(QuoteNode(a))),
                                          $(QuoteNode(kind)), 1, false, true, $(QuoteNode(a))))))
        kind == :clockout || continue
        _juliaport(a) in clockouts || push!(clockouts, _juliaport(a))
        push!(tree, (name = _juliaport(a),
                     from = haskey(opts, :from) ? _juliaport(opts[:from]) : nothing,
                     divide = get(opts, :divide, 1), phase = get(opts, :phase, 0),
                     enable = get(opts, :enable, nothing)))
      end
    elseif kind == :pragma
      pragma = item.args[2]
    else
      error("@blackbox: unexpected item $item")
    end
  end
  T = name
  store = Symbol("#quartz_blackbox#", name)
  treeexprs = [:($QuartzHDL.ClockOut($(QuoteNode(c.name)),
                                     $(c.from === nothing ? :nothing : QuoteNode(c.from)),
                                     $(c.divide), $(c.phase), $(c.enable !== nothing),
                                     $(findfirst(==(c.name), clockouts) - 1)))
               for c in tree]
  enablefns = [Expr(:function,
                    :($QuartzHDL._clockenable(::Type{<:$T}, ::Val{$k}, i::NamedTuple)),
                    Expr(:block, (:($n = i.$n) for n in inputnames)..., tree[k].enable))
               for k in eachindex(tree) if tree[k].enable !== nothing]
  stub = quote
    struct $name <: $QuartzHDL.BlackBox
      $(_inputsfield(ins).args[1])
      counts::NTuple{$(length(tree)),Int}
      ticked::UInt64
      levels::UInt64
      model::Any
    end
    function $name(; kwargs...)
      isempty(kwargs) || error($("$name takes no keywords: wire its clocks and inputs in a @wire block, " *
                                 "`inst.port ← net`"))
      $name($(_inputsfield(ins).args[2]), $(Expr(:tuple, zeros(Int, length(tree))...)), UInt64(0), UInt64(0),
            $QuartzHDL.standin($name))
    end
    Base.getproperty(x::$name, f::Symbol) = hasfield($name, f) ? getfield(x, f) : $QuartzHDL._bboutput(x, Val(f))
    $((:($QuartzHDL._bboutput(x::$name, v::Val{$(QuoteNode(n))}) =
          $QuartzHDL._modeloutput(x, v, $QuartzHDL._bbouttype($t))) for (n, t) in outs)...)
  end
  quote
    $stub
    $(doc === nothing ? nothing : :(Core.@doc $doc $T))
    const $store = $QuartzHDL.BlackboxDef($(QuoteNode(vname)), $QuartzHDL.Port[$(ports...)], $pragma,
                                          $QuartzHDL.ClockOut[$(treeexprs...)], $clockouts,
                                          Dict{Symbol,String}($(docs...)))
    $(enablefns...)
    $QuartzHDL.blackbox(::Type{<:$T}) = $store
    $T
  end
end

# the clocks of a slot as a bench holds them: the plan's entries, with a mask
# picking out those that tick in this slot
_stepslot(m::QuartzModule, names::NTuple{K,Symbol}, mask::UInt64, clks, kw) where K =
  _slotstep(m, (names[i] for i in 1:K if _hasbit(mask, i - 1)), clks, kw)

# the roots of a slot are stepped in the order given, and then whatever the tree
# derives from them
function _slotstep(m::QuartzModule, roots, clks, kw)
  m = _clearticks(m)
  # a module with no clocked block still has continuous logic, and a slot is still
  # a slot: with no edge to run, the inputs of this slot must still reach the
  # outputs, as they do through the `assign` the same block emits
  isempty(_clocks(typeof(m))) && return _stepwith(m, Val(Symbol("")), kw)
  stepped = UInt64(0)
  for c in roots
    c in clks || continue
    m = _stepnet(m, c, kw)
    stepped |= _edgebits(_treeedges(m), c)
  end
  _stepedges(m, clks, kw, stepped)
end

# The edges a step produced are taken slowest first, as a batch: the batch is
# what the tree showed before any of it was stepped, and what those steps derive
# in turn is the next batch. `stepped` and `pending` are bit masks over the
# entries of `_treeedges`.
function _stepedges(m, clks, kw, stepped::UInt64)
  while true
    edges = _treeedges(m)
    pending = _pendingbits(edges, stepped)
    pending == 0 && return m
    while pending != 0
      i = _slowest(edges, pending)
      net = edges[i][1]
      b = _edgebits(edges, net)
      pending &= ~b
      stepped |= b
      net in clks && (m = _stepnet(m, net, kw))
    end
  end
end

function _pendingbits(edges, stepped::UInt64)
  out = UInt64(0)
  for (i, e) in enumerate(edges)
    e[3] && !_hasbit(stepped, i - 1) && (out |= UInt64(1) << (i - 1))
  end
  out
end

function _edgebits(edges, net::Symbol)
  out = UInt64(0)
  for (i, e) in enumerate(edges)
    e[1] === net && (out |= UInt64(1) << (i - 1))
  end
  out
end

function _slowest(edges, pending::UInt64)
  best, bestdiv = 0, 0
  for (i, e) in enumerate(edges)
    _hasbit(pending, i - 1) && e[2] > bestdiv && ((best, bestdiv) = (i, e[2]))
  end
  best
end

