# A simulation is a bench with a stimulus talking to it: nets that can be read and
# driven by name, a capture of what the watched nets did, and tasks that drive
# nets over time. `@run sim begin ... end` runs a stimulus; the same verbs work one
# line at a time from a REPL, so a board can be poked at interactively.
#
# A net is anything with a value: a register, pad or input of the design, a field
# of a stub, a clock of the plan. What the stimulus may drive is an input or a pad
# of the design that the wiring leaves alone -- what is driven by something else
# can only be read.

# One line of a waveform: where it sits, what it is, and how to read it. `T` and
# `read` stay abstract: a design's nets are one vector of every kind at once, so
# parameterizing them would only move the abstraction into the vector.
struct Net
  path::String
  kind::Symbol                 # :reg, :pad, :pipe, :wire, :guard, :fsm, :input, :stub or :clock
  width::Int
  T::Type                      # the type a read gives
  read::Function               # simulation -> value
  enc::Union{Nothing,Encoding} # the names of an :fsm register's values
  indut::Bool                  # part of the design, rather than of a stub or the plan
  bit::Int                     # a clock's place in the plan's tick mask
end

Net(path, kind, width, T, read, enc=nothing; indut=true, bit=0) = Net(path, kind, width, T, read, enc, indut, bit)

Base.show(io::IO, n::Net) = print(io, "Net(", n.path, "::", n.kind, "[", n.width, "])")

# What one net did: the slots where it changed, and what it changed to. Values are
# raw bits; `mask` marks the bits that were undriven (a pad) or not yet valid (a
# pipeline). A clock holds only the slots it ticked in. `stop` is the capture's
# last slot, shared with it, so a signal knows how long it was held after its
# last change. `V` is what a query of this signal returns -- fixed from the net
# when the signal is added, so `changes` and `signal[t]` are typed even though
# the capture holds signals of every kind in one vector.
struct Signal{V}
  net::Net
  grid::Rational{Int}
  slots::Vector{Int}
  vals::Vector{UInt128}
  mask::Vector{UInt128}
  stop::Base.RefValue{Int}
end

# what a query of a net's signal can return: the net's value type, plus `missing`
# for bits not yet valid, a string for a partly-driven pad, a name for an encoded state
_valuetype(n::Net) =
  n.kind === :clock ? Bool :
  n.kind === :pad ? Union{String,_fromrawtype(n.T)} :
  n.kind === :fsm && n.enc !== nothing ? Union{Missing,Symbol,_fromrawtype(n.T)} :
  Union{Missing,_fromrawtype(n.T)}

# What a run produced on the watched nets, queried by name or by path.
struct Capture
  grid::Rational{Int}
  signals::Vector{Signal}
  index::Dict{String,Int}
  short::Dict{Symbol,Int}        # a name that is unique among the leaves
  stop::Base.RefValue{Int}       # the last slot captured
end

# A stimulus task: what it waits for, and the channels the scheduler hands control
# over. `pred` is whatever closure the stimulus wrote, so it cannot be concrete
# without parameterizing the vector of tasks a simulation holds.
mutable struct SimTask
  const task::Task
  const resume::Channel{Nothing}
  const paused::Channel{Nothing}
  wake::Int                    # the slot to resume at; with a predicate, the deadline or -1
  pred::Union{Nothing,Function}
  done::Bool
  persistent::Bool             # outlives the @run that made it
  error::Any
end

# the simulation time, for log lines; kept by the run loop, not by a step
const SIMTIME = Ref{Rational{Int}}(0//1)

# what the person running the simulation wants to see, of what the design logs
struct LogFilter
  from::Float64                # simulation time the window opens, in seconds
  to::Float64                  # and closes
  modules::Vector{Symbol}      # design types, or empty for all
  pred::Union{Nothing,Function}   # a predicate asked before each line; set at the REPL, so left untyped
end

LogFilter() = LogFilter(-Inf, Inf, Symbol[], nothing)

# the filter of the simulation now running: the run loop puts it here every slot,
# so a log statement inside a design finds it without knowing its simulation
const LOGFILTER = Ref{LogFilter}(LogFilter())

"""
    Simulation(dut; clocks, wiring = Wiring(), watch = nothing, stubs...)

A design with the models around it, ready to be driven. Takes what `Bench` takes:
`clocks` is an `@clocks` plan or, for a simple plan, a named tuple of rates
(`clocks = (clk = 1MHz,)` with `using QuartzHDL.Units`), and `wiring` defaults to
nothing connected, which is all a single-module simulation needs. `watch` names
the nets to record, as a path or pattern (`"usb1.*"`, `"*"` for every net) or a
list of them; nothing is recorded until something is watched. See `watch!` and
`unwatch!`.

`sim["name"]` and `sim.name` read a net, `sim.name = v` drives one, and
`@run sim begin ... end` runs a stimulus against it.
"""
mutable struct Simulation{B<:Bench,D<:NamedTuple}
  bench::B
  drives::D                    # what the stimulus holds on each drivable net
  const initial::B             # the bench as built, for reset!
  const initialdrives::D
  const nets::Vector{Net}
  const index::Dict{String,Int}
  const short::Dict{Symbol,Int}
  const capture::Capture
  watched::Vector{Int}         # indices into nets
  const sigof::Vector{Int}     # each net's signal in the capture, or 0
  const curval::Vector{UInt128}
  const curmask::Vector{UInt128}
  const lastval::Vector{UInt128}
  const lastmask::Vector{UInt128}
  const tasks::Vector{SimTask}
  const hooks::Vector{Any}     # called after every slot: models that react every cycle
  logfilter::LogFilter         # what showlogs! chose to show
  viewer::Union{Nothing,Viewer}
  viewed::Float64              # wall-clock time of the last live update
  tickmask::UInt64             # the clocks that ticked in the last slot
  function Simulation(bench::B, drives::D, nets, index, short, capture) where {B<:Bench,D<:NamedTuple}
    n = length(nets)
    new{B,D}(bench, drives, bench, drives, nets, index, short, capture, Int[], zeros(Int, n),
             zeros(UInt128, n), zeros(UInt128, n), zeros(UInt128, n), zeros(UInt128, n),
             SimTask[], Any[], LogFilter(), nothing, 0.0, UInt64(0))
  end
end

Base.show(io::IO, s::Simulation) =
  print(io, "Simulation(", nameof(typeof(s.bench.dut)), ", ", length(s.nets), " nets, ",
        length(s.watched), " watched, t = ", _timestr(time(s)), ")")

function Simulation(dut; clocks, wiring=Wiring(), watch=nothing, stubs...)
  b = Bench(dut; clocks, wiring, stubs...)
  nets = _nets(b)
  index = Dict(n.path => i for (i, n) in enumerate(nets))
  rec = Capture(b.plan.grid, Signal[], Dict{String,Int}(), Dict{Symbol,Int}(), Ref(0))
  s = Simulation(b, _initialdrives(b, wiring), nets, index, _shortnames(nets), rec)
  watch === nothing || watch!(s, (watch isa AbstractString ? [watch] : watch)...)
  s
end

"the time a simulation has run for, in seconds"
Base.time(s::Simulation) = time(s.bench)

# `sim.x` reads a net and `sim.x = v` drives one, outside a `@run` as well as in
# it; `sim.usb1.usb_rd` walks a scope of the design to the net
struct NetScope{S<:Simulation}
  sim::S
  path::String
end
Base.getproperty(s::Simulation, f::Symbol) =
  f in fieldnames(Simulation) ? getfield(s, f) :
  haskey(getfield(s, :short), f) || haskey(getfield(s, :drives), f) ||
    haskey(getfield(s, :bench).stubs, f) ? s[f] :
  _isscope(s, string(f)) ? NetScope(s, string(f)) : error("no net named $f")
Base.setproperty!(s::Simulation, f::Symbol, v) =
  f in fieldnames(Simulation) ? setfield!(s, f, v) : setindex!(s, v, Val(f))
Base.propertynames(s::Simulation) =
  Tuple(union(keys(getfield(s, :short)), keys(getfield(s, :drives)),
              keys(getfield(s, :bench).stubs), _scopes(s)))

# the names that stand for a scope of the design, `sim.usb1` to `sim.usb1.usb_rd`
_scopes(s::Simulation) = unique(Symbol(first(split(n.path, "."))) for n in getfield(s, :nets) if occursin(".", n.path))

function Base.getproperty(sc::NetScope, f::Symbol)
  s, path = getfield(sc, :sim), getfield(sc, :path) * "." * string(f)
  haskey(s.index, path) ? s[path] : _isscope(s, path) ? NetScope(s, path) : error("no net named $path")
end
Base.setproperty!(sc::NetScope, f::Symbol, v) =
  error("$(getfield(sc, :path)).$f is driven by the design, so can only be read")
Base.show(io::IO, sc::NetScope) = print(io, "NetScope(", getfield(sc, :path), ")")

_isscope(s::Simulation, path::AbstractString) = (p = path * "."; any(n -> startswith(n.path, p), s.nets))

"""
    nets(sim, patterns...)

The nets of a simulation: its design's registers, pads and inputs, the fields of
its stubs, and its clocks. A pattern is a path, a bare name (matching any net
that ends in it, the way `sim["name"]` reads it), or a prefix ending in `*`.
"""
nets(s::Simulation) = s.nets
nets(s::Simulation, pats...) = [n for n in s.nets if _selected(n.path, pats)]

"""
    watch!(sim, patterns...)

Record these nets from now on, as well as those already watched. A pattern is a
path, a bare name, or a prefix ending in `*`; `"*"` is every net. Capture costs
time in proportion to the nets watched, so a large design runs faster with fewer.
"""
function watch!(s::Simulation, pats...)
  isempty(pats) && error("watch! takes the nets to watch; \"*\" is all of them")
  sel = findall(n -> _selected(n.path, pats), s.nets)
  isempty(sel) && error("no net matches $(join(pats, ", "))")
  for i in sel
    i in s.watched && continue
    push!(s.watched, i)
    _addsignal!(s, i)
  end
  sort!(s.watched)
  s
end

"""
    unwatch!(sim, patterns...)

Stop capturing these nets. What they did so far stays in the capture.
"""
function unwatch!(s::Simulation, pats...)
  filter!(i -> !_selected(s.nets[i].path, pats), s.watched)
  s
end

"""
    capture(sim)

What a simulation has captured so far, queried by name: `capture(sim).x` is the
signal net `x` recorded.
"""
capture(s::Simulation) = s.capture

"""
    clear!(sim)

Forget the capture so far; the design keeps its state and the time keeps counting.
"""
function clear!(s::Simulation)
  r = s.capture
  empty!(r.signals); empty!(r.index); empty!(r.short)
  r.stop[] = s.bench.slot
  fill!(s.sigof, 0)
  for i in s.watched
    _addsignal!(s, i)
  end
  s
end

"""
    reset!(sim)

Back to time zero: the design and its stubs as they were built, nothing driven,
every task stopped, and the capture cleared.
"""
function reset!(s::Simulation)
  stop!(s)
  empty!(s.hooks)
  s.bench = s.initial
  s.drives = s.initialdrives
  s.tickmask = UInt64(0)
  clear!(s)
  _view!(s, true)
  s
end

### reading and driving nets

"""
    sim["name"]

The value of a net, by its path, or by its name alone where that is unique. A pad
reads the level its net resolves to; an input reads what is driven on it; a stub
reads as the model itself. `sim.name` and `sim.scope.name` read the same way.
"""
function Base.getindex(s::Simulation, path::AbstractString)
  i = _lookup(s.index, s.short, path)
  i == 0 || return _level(s.nets[i].read(s))
  parts = split(path, ".")
  i = get(s.index, parts[1], 0)
  i == 0 && error("no net named $path")
  foldl((v, f) -> getproperty(v, Symbol(f)), parts[2:end]; init=s.nets[i].read(s))
end

Base.getindex(s::Simulation, n::Net) = _level(n.read(s))
Base.getindex(s::Simulation, name::Symbol) = s[string(name)]
Base.getindex(s::Simulation, ::Val{name}) where name = _level(_net(s, name).read(s))

# what a name stands for: a full path, else a leaf name no other leaf has, else 0
_lookup(index, short, path) = (i = get(index, path, 0); i == 0 ? get(short, Symbol(path), 0) : i)

_level(p::Pad) = p[]
_level(v) = v

"""
    sim["name"] = value

Hold `value` on an input or a pad of the design from the next slot on. A net the
wiring drives, or that the design drives, cannot be driven. Naming a stub
replaces the stub's state. `sim.name = value` does the same.
"""
Base.setindex!(s::Simulation, v, name::AbstractString) = Base.setindex!(s, v, Val(Symbol(name)))
Base.setindex!(s::Simulation, v, n::Net) = Base.setindex!(s, v, Val(Symbol(n.path)))
function Base.setindex!(s::Simulation, v, ::Val{name}) where name
  if haskey(s.drives, name)
    s.drives = merge(s.drives, NamedTuple{(name,)}((_drivevalue(getfield(s.drives, name), v),)))
  elseif haskey(s.bench.stubs, name)
    s.bench = setstub(s.bench, name, v)
  else
    _undrivable(s, name)
  end
  v
end

_drivevalue(::Tuple{Bits{N},Bits{N}}, v) where N = _extdrive(Pad{N}, v)
_drivevalue(old::T, v) where T = convert(T, v)::T

function _undrivable(s::Simulation, name::Symbol)
  n = get(s.nets, _lookup(s.index, s.short, string(name)), nothing)
  n === nothing && error("no net named $name")
  n.kind in (:input, :pad) && error("$name is driven by the wiring")
  error("$name is driven by the design, so can only be read")
end

_net(s::Simulation, name::Symbol) =
  (i = get(s.short, name, 0); i == 0 ? _net(s, String(name)) : s.nets[i])
function _net(s::Simulation, path::AbstractString)
  i = _lookup(s.index, s.short, path)
  i == 0 && error("no net named $path")
  s.nets[i]
end

### running

"the task the stimulus is in, which is what a delay suspends"
function _current(s::Simulation)
  t = current_task()
  for st in s.tasks
    st.task === t && return st
  end
  error("advance_by and advance_until are only valid inside @run")
end

"""
    advance_by(sim, t)

Let the simulation run for `t` seconds before the stimulus continues.
"""
function advance_by(s::Simulation, t::Real)
  n = _nslots(s, t)
  n == 0 && return nothing
  _suspend!(s, s.bench.slot + n, nothing)
  nothing
end

"""
    advance_until(sim, f; timeout = nothing, what = "for a condition")

Let the simulation run until `f()` holds, or until the time it gives if it is a
number. A predicate is looked at every slot; with a `timeout` in seconds, an
error naming `what` was waited for is raised if it never held.
"""
function advance_until(s::Simulation, f; timeout=nothing, what="for a condition")
  v = Base.invokelatest(f)
  if v isa Real && !(v isa Bool)
    v ≤ time(s) || _suspend!(s, _slotat(s, v), nothing)
    return nothing
  end
  v === true && return nothing
  deadline = timeout === nothing ? -1 : s.bench.slot + _nslots(s, timeout)
  held = _suspend!(s, deadline, f)
  held || error("timed out after $(_timestr(timeout)) waiting $what")
  nothing
end

# how many slots a stretch of time is
function _nslots(s::Simulation, t::Real)
  n = round(Int, t / s.bench.plan.grid)
  n == 0 && t > 0 && @warn "$(_timestr(t)) is less than a slot of $(_timestr(s.bench.plan.grid)), so no time passes"
  n
end

# the slot a moment in time falls in
_slotat(s::Simulation, t::Real) = round(Int, t / s.bench.plan.grid)

function _suspend!(s::Simulation, wake::Int, pred)
  st = _current(s)
  st.wake = wake
  st.pred = pred
  put!(st.paused, nothing)
  take!(st.resume)
  st.pred = nothing
  st.wake ≥ 0
end

"""
    spawn!(sim, f; persistent = false)

Start `f()` as a task of the stimulus, advancing with the simulation. A task made
inside a `@run` block ends with the block; a persistent one keeps going until
`stop!(sim, task)`.
"""
function spawn!(s::Simulation, f; persistent=false)
  resume = Channel{Nothing}(1)
  paused = Channel{Nothing}(1)
  box = Ref{SimTask}()
  t = Task() do
    try
      take!(resume)
      Base.invokelatest(f)
    catch e
      box[].error = e
    finally
      box[].done = true
      put!(paused, nothing)
    end
  end
  st = SimTask(t, resume, paused, s.bench.slot, nothing, false, persistent, nothing)
  box[] = st
  push!(s.tasks, st)
  schedule(t)
  st
end

"""
    stop!(sim, task)

End a task of the stimulus. `stop!(sim)` ends every one.
"""
function stop!(s::Simulation, st::SimTask)
  st.done || close(st.resume)
  st.done = true
  filter!(t -> t !== st, s.tasks)
  nothing
end
stop!(s::Simulation) = (foreach(st -> stop!(s, st), copy(s.tasks)); nothing)

"""
    run!(sim, f) -> value

Run `f()` as the stimulus: the simulation advances while it delays, alongside the
tasks it and earlier stimuli started. Returns what `f` returned, or the capture
when that is nothing.
"""
function run!(s::Simulation, f)
  value = Ref{Any}(nothing)
  main = spawn!(s, () -> (value[] = f()))
  _schedule!(s, main)
  _view!(s, true)
  main.error === nothing || throw(main.error)
  for st in s.tasks
    st.error === nothing || (filter!(t -> t !== st, s.tasks); throw(st.error))
  end
  value[] === nothing ? s.capture : value[]
end

function _schedule!(s::Simulation, main::SimTask)
  while true
    for st in s.tasks
      st.done && continue
      if _ready(st, s.bench.slot)
        put!(st.resume, nothing)
        take!(st.paused)
      end
    end
    if main.done
      for st in filter(t -> !t.persistent && t !== main, s.tasks)
        stop!(s, st)
      end
      filter!(t -> t !== main, s.tasks)
      return
    end
    n = _nextwake(s)
    for i in 1:n
      _step!(s)
      i % 4096 == 0 && _view!(s, false)
    end
  end
end

function _ready(st::SimTask, slot::Int)
  st.pred === nothing && return st.wake ≤ slot
  if Base.invokelatest(st.pred) === true
    st.wake = slot
    return true
  end
  if st.wake ≥ 0 && st.wake ≤ slot
    st.wake = -1
    return true
  end
  false
end

# how far the simulation can run before a task needs looking at
function _nextwake(s::Simulation)
  n = typemax(Int)
  for st in s.tasks
    st.done && continue
    st.pred === nothing || return 1
    n = min(n, st.wake - s.bench.slot)
  end
  max(n, 1)
end

function _step!(s::Simulation)
  b = s.bench
  SIMTIME[] = time(b)
  LOGFILTER[] = s.logfilter
  mask, acc = _tickers(b.plan, b.slot, b.acc)
  s.bench = _stepbench(b, s.drives, mask, acc)
  s.tickmask = mask
  _sample!(s)
  for h in s.hooks
    h()
  end
  nothing
end

"""
    hook!(sim, f)

Call `f()` after every slot, for a model that must react every cycle (a bus
peripheral) and would be too slow as a task. `f` reads nets and drives them like
any stimulus; what it drives applies at the next slot. `unhook!(sim, f)` removes it.
"""
hook!(s::Simulation, f) = (push!(s.hooks, f); f)

"""
    unhook!(sim, f)

Stop calling `f` after every slot; it undoes `hook!(sim, f)`.
"""
unhook!(s::Simulation, f) = (filter!(h -> h !== f, s.hooks); nothing)

### the @run and @stimulus macros

"""
    @run sim begin ... end
    @run sim expr

Run a stimulus against `sim`. Inside it `sim.x` reads a net and `sim.x = v`
drives one, `advance_by(t)` and `advance_until(cond)` let time pass, `@task expr`
starts a concurrent stimulus, and times are written with units: `1ms`, `10us`.
A `@task` given on its own keeps running after the call returns.
"""
macro run(sim, body)
  esc(_runexpr(sim, body))
end

# a run's body is rewritten around the simulation it names
function _runexpr(sim, body)
  sim isa Symbol && return :($QuartzHDL.run!($sim, () -> $(_stimulus(_allunits(body), sim, Symbol[], _istask(body)))))
  # `@run dam.sim ...`: the simulation is bound to a name for the body
  g = gensym(:sim)
  :(let $g = $sim
      $QuartzHDL.run!($g, () -> $(_stimulus(_allunits(_subst(body, sim, g)), g, Symbol[], _istask(body))))
    end)
end

_subst(ex, from, to) = ex == from ? to : ex isa Expr ? Expr(ex.head, map(a -> _subst(a, from, to), ex.args)...) : ex

_istask(ex) = ex isa Expr && ex.head == :macrocall && _macroname(ex.args[1]) === Symbol("@task")

"""
    @stimulus function name(sim, net::Net, args...) ... end

Define a reusable stimulus. Its first argument is the simulation; an argument
declared `::Net` names a net (as a path, or a `Net`) that the body reads and
drives by that name. The body is written as a `@run` body.
"""
macro stimulus(def)
  esc(_stimulusdef(def))
end

function _stimulusdef(def)
  def isa Expr && def.head in (:function, :(=)) || error("@stimulus: expected a function definition")
  sig, body = def.args
  sig isa Expr && sig.head == :where && (sig = sig.args[1])
  sig isa Expr && sig.head == :call && length(sig.args) ≥ 2 ||
    error("@stimulus: a stimulus takes the simulation as its first argument")
  args = sig.args[2:end]
  first(args) isa Expr && first(args).head == :parameters && (args = args[2:end])
  sim = first(args)
  sim isa Symbol || error("@stimulus: the first argument is the simulation, got $sim")
  netargs = Symbol[]
  for (i, a) in enumerate(sig.args)
    a isa Expr && a.head == :(::) && a.args[2] === :Net || continue
    push!(netargs, a.args[1])
    sig.args[i] = a.args[1]
  end
  Expr(def.head, sig, _stimulus(_allunits(body), sim, netargs, false))
end

_allunits(ex) = _units(_units(ex, TIMEUNITS), FREQUNITS)

# `sim.x` reads, `sim.x = v` drives, advances name the simulation, tasks are spawned
function _stimulus(ex, sim, netargs, persistent)
  ex isa Symbol && return ex in netargs ? :($sim[$ex]) : ex
  ex isa Expr || return ex
  rec(a) = _stimulus(a, sim, netargs, persistent)
  if ex.head == :(=) && length(ex.args) == 2
    lhs, rhs = ex.args
    lhs isa Symbol && lhs in netargs && return :($sim[$lhs] = $(rec(rhs)))
    if lhs isa Expr && lhs.head == :. && lhs.args[1] === sim
      return :($sim[$(string(lhs.args[2].value))] = $(rec(rhs)))
    end
  end
  if ex.head == :. && ex.args[2] isa QuoteNode
    path = _netpath(ex, sim)
    path === nothing || return :($sim[$(join(path, "."))])
  end
  if ex.head == :call && ex.args[1] in (:advance_by, :advance_until) && !(length(ex.args) > 1 && ex.args[2] === sim)
    args = ex.args[2:end]
    kws = filter(a -> a isa Expr && a.head == :parameters, args)
    pos = filter(a -> !(a isa Expr && a.head == :parameters), args)
    length(pos) == 1 || error("$(ex.args[1]) takes one argument")
    arg = ex.args[1] === :advance_until ? :(() -> $(rec(pos[1]))) : rec(pos[1])
    return Expr(:call, GlobalRef(QuartzHDL, ex.args[1]), map(rec, kws)..., sim, arg)
  end
  if _istask(ex)
    body = ex.args[end]
    return :($QuartzHDL.spawn!($sim, () -> $(rec(body)); persistent=$persistent))
  end
  ex.head in (:quote, :meta) && return ex
  Expr(ex.head, map(rec, ex.args)...)
end

# `sim.a.b` as the path (:a, :b), or nothing if the chain does not start at the simulation
function _netpath(ex, sim)
  ex === sim && return Symbol[]
  ex isa Expr && ex.head == :. && ex.args[2] isa QuoteNode || return nothing
  p = _netpath(ex.args[1], sim)
  p === nothing ? nothing : push!(p, ex.args[2].value)
end

### the nets of a bench

# A leaf of a struct tree: the chain of fields down to it, and what it is. One
# walk serves both the nets (with their readers) and the sampler a run uses. `T`
# is abstract for the same reason a net's is: one walk sees every hardware type.
struct LeafSpec
  chain::Vector{Symbol}
  kind::Symbol
  width::Int
  T::Type
  enc::Union{Nothing,Encoding}
  part::Symbol                 # :val, :out, :new, :ready or :level -- what of the field is read
end

function _leafspecs(::Type{T}, chain=Symbol[]) where T
  out = LeafSpec[]
  encs = T <: QuartzModule ? allencodings(T) : Dict{Symbol,Any}()
  for (f, FT) in zip(fieldnames(T), fieldtypes(T))
    f === INPUTS && continue
    c = [chain; f]
    if FT === Bool || FT <: HWInt || FT <: Base.BitInteger
      enc = get(encs, f, nothing)
      push!(out, LeafSpec(c, enc === nothing ? :reg : :fsm, bitwidth(FT), FT, enc, :val))
    elseif FT <: Pad
      push!(out, LeafSpec(c, :pad, padwidth(FT), FT, nothing, :val))
    elseif FT <: Pipeline
      ET = FT.parameters[2]
      push!(out, LeafSpec(c, :pipe, bitwidth(ET), ET, nothing, :out))
      push!(out, LeafSpec(c, :reg, 1, Bool, nothing, :new))
      push!(out, LeafSpec(c, :reg, 1, Bool, nothing, :ready))
    elseif FT <: Multicycle
      ET = FT.parameters[2]
      push!(out, LeafSpec(c, :wire, bitwidth(ET), ET, nothing, :out))
      push!(out, LeafSpec(c, :reg, 1, Bool, nothing, :ready))
    elseif FT <: MetaGuard
      push!(out, LeafSpec(c, :guard, 1, Bool, nothing, :out))
    elseif FT === Edge
      push!(out, LeafSpec(c, :reg, 1, Bool, nothing, :level))
    elseif FT <: QuartzModule && !isblackbox(FT)
      append!(out, _leafspecs(FT, c))
    end
  end
  out
end

_leafpath(l::LeafSpec, prefix) = prefix * join(l.chain, ".") * (l.part in (:val, :level) ? "" : "." * string(l.part))

# the reader of a leaf, for reads by name; a run samples through generated code instead.
# The chain is carried as a `Val` so a read walks typed fields: folded over a vector
# of symbols instead, every step of the walk would box the module it lands in.
function _leafreader(l::LeafSpec, root)
  chain = Val(Tuple(l.chain))
  get = s -> _chainget(root(s), chain)
  l.part in (:out, :level) ? (s -> _outof(get(s))) : l.part === :new ? (s -> isnew(get(s))) :
  l.part === :ready ? (s -> isready(get(s))) : get
end

@generated _chainget(x, ::Val{chain}) where chain =
  foldl((e, f) -> :(getfield($e, $(QuoteNode(f)))), chain; init=:x)

# what is on a net's output right now, ready or not
_outof(x) = x[]
_outof(m::Multicycle) = m.val

function _nets(b::Bench)
  out = Net[]
  _inputnets!(out, b.dut)
  for l in _leafspecs(typeof(b.dut))
    push!(out, Net(_leafpath(l, ""), l.kind, l.width, l.T, _leafreader(l, s -> s.bench.dut), l.enc))
  end
  for (k, v) in pairs(b.stubs)
    kv = Val((k,))
    getstub = s -> _chainget(s.bench.stubs, kv)
    push!(out, Net(string(k), :stub, 0, typeof(v), getstub; indut=false))
    for l in _leafspecs(typeof(v))
      push!(out, Net(_leafpath(l, string(k) * "."), l.kind, l.width, l.T, _leafreader(l, getstub), l.enc; indut=false))
    end
  end
  for (i, e) in enumerate(b.plan.entries)
    haskey(b.stubs, e.name) && continue
    bit = i - 1
    push!(out, Net("clocks." * string(e.name), :clock, 1, Bool, s -> _hasbit(s.tickmask, bit); indut=false, bit))
  end
  out
end

function _inputnets!(out, dut::T) where T
  hasfield(T, INPUTS) || return
  for (f, FT) in zip(fieldnames(fieldtype(T, INPUTS)), fieldtypes(fieldtype(T, INPUTS)))
    v = Val(f)
    push!(out, Net(string(f), :input, bitwidth(FT), FT, s -> _inputvalue(s, v)))
  end
end

_inputvalue(s::Simulation, ::Val{f}) where f =
  haskey(s.drives, f) ? getfield(s.drives, f) : getfield(getfield(s.bench.dut, INPUTS), f)

# a leaf name that no other leaf has can stand for its path
function _shortnames(nets)
  counts = Dict{Symbol,Int}()
  for n in nets
    s = Symbol(last(split(n.path, ".")))
    counts[s] = get(counts, s, 0) + 1
  end
  d = Dict{Symbol,Int}()
  for (i, n) in enumerate(nets)
    s = Symbol(last(split(n.path, ".")))
    (counts[s] == 1 || !occursin(".", n.path)) && !haskey(d, s) && (d[s] = i)
  end
  d
end

# a pattern matches a net's full path, or its bare name (the way sim["name"] reads
# it too, so a name that works for one works for the other)
_selected(path, pats) = isempty(pats) || any(p -> _matches(path, string(p)), pats)
_matches(path, p) = endswith(p, "*") ? startswith(path, p[1:end-1]) :
                    path == p || endswith(path, "." * p)

# every input and pad of the design that the wiring does not drive, released
function _initialdrives(b::Bench, wiring)
  driven = _driven(wiring)
  dut = b.dut
  names = Symbol[]
  vals = Any[]
  if hasfield(typeof(dut), INPUTS)
    ins = getfield(dut, INPUTS)
    for (f, v) in pairs(ins)
      f in driven && continue
      push!(names, f); push!(vals, v)
    end
  end
  for (f, (w, _)) in _padinfo(typeof(dut))
    f in driven && continue
    push!(names, f); push!(vals, (Bits{w}(), Bits{w}()))
  end
  NamedTuple{Tuple(names)}(Tuple(vals))
end

_driven(w::Wiring) = w.driven
_driven(w) = Symbol[]

### sampling

function _addsignal!(s::Simulation, i::Int)
  r = s.capture
  n = s.nets[i]
  sig = Signal{_valuetype(n)}(n, r.grid, Int[], UInt128[], UInt128[], r.stop)
  push!(r.signals, sig)
  r.index[n.path] = length(r.signals)
  s.sigof[i] = length(r.signals)
  short = Symbol(last(split(n.path, ".")))
  get(s.short, short, 0) == i && (r.short[short] = length(r.signals))
  v, m = _raw(n, n.read(s))
  s.lastval[i] = v; s.lastmask[i] = m
  push!(sig.slots, s.bench.slot); push!(sig.vals, v); push!(sig.mask, m)
  sig
end

# Every net's value is read into `curval`/`curmask` in one typed pass over the
# bench -- generated per design, so a slot costs a field read per net rather than a
# call -- and only the watched ones are compared with what they were.
function _sample!(s::Simulation)
  r = s.capture
  slot = s.bench.slot
  r.stop[] = slot
  b = s.bench
  k = _rawinputs!(s.curval, s.curmask, getfield(b.dut, INPUTS), s.drives, 0)
  k = _rawtree!(s.curval, s.curmask, b.dut, k)
  k = _rawstubs!(s.curval, s.curmask, b.stubs, k)
  for i in s.watched
    n = s.nets[i]
    if n.kind === :clock
      _hasbit(s.tickmask, n.bit) || continue
      sig = r.signals[s.sigof[i]]
      push!(sig.slots, slot); push!(sig.vals, UInt128(1)); push!(sig.mask, UInt128(0))
      continue
    end
    v, m = s.curval[i], s.curmask[i]
    v == s.lastval[i] && m == s.lastmask[i] && continue
    s.lastval[i] = v; s.lastmask[i] = m
    sig = r.signals[s.sigof[i]]
    push!(sig.slots, slot); push!(sig.vals, v); push!(sig.mask, m)
  end
  nothing
end

@generated function _rawinputs!(vals, masks, ins::NamedTuple{names}, drives::NamedTuple{dnames}, k) where {names,dnames}
  body = [:(_rawinto!(vals, masks, k + $i, $(f in dnames ? :(getfield(drives, $(QuoteNode(f)))) :
                                                  :(getfield(ins, $(QuoteNode(f)))))))
          for (i, f) in enumerate(names)]
  :($(body...); k + $(length(names)))
end
_rawinputs!(vals, masks, ins, drives, k) = k

@generated function _rawtree!(vals, masks, m::T, k) where T
  specs = _leafspecs(T)
  body = Any[]
  for (i, l) in enumerate(specs)
    ex = foldl((e, f) -> :(getfield($e, $(QuoteNode(f)))), l.chain; init=:m)
    ex = l.part in (:out, :level) ? :(_outof($ex)) :
      l.part === :new ? :(isnew($ex)) :
      l.part === :ready ? :(isready($ex)) : ex
    push!(body, :(_rawinto!(vals, masks, k + $i, $ex, $(l.width))))
  end
  :($(body...); k + $(length(specs)))
end

@generated function _rawstubs!(vals, masks, stubs::NamedTuple{names}, k) where names
  body = [:(k = _rawtree!(vals, masks, getfield(stubs, $(QuoteNode(f))), k + 1)) for f in names]
  :($(body...); k)
end

_rawinto!(vals, masks, i, x, N=0) = ((vals[i], masks[i]) = _rawbits(x, N); nothing)

# a value as raw bits and a mask of the bits that have none
_rawbits(x::Bool, N) = (UInt128(x), UInt128(0))
_rawbits(x::HWInt, N) = (x.val, UInt128(0))
_rawbits(x::Base.BitInteger, N) = (UInt128(reinterpret(unsigned(typeof(x)), x)), UInt128(0))
_rawbits(::Missing, N) = (UInt128(0), _mask(N))
_rawbits(p::Pad{N}, _) where N = (r = _resolvebits(p); (r[1], ~r[2] & _mask(N)))
_rawbits(x::Tuple{Bits{N},Bits{N}}, _) where N = (x[1].val, ~x[2].val & _mask(N))
_rawbits(x, N) = (UInt128(0), _mask(N))

_raw(n::Net, x) = _rawbits(x, n.width)

### querying a capture

Base.show(io::IO, r::Capture) =
  print(io, "Capture(", length(r.signals), " signals, ", _timestr(r.stop[] * r.grid), ")")

Base.getproperty(r::Capture, f::Symbol) = f in fieldnames(Capture) ? getfield(r, f) : r[string(f)]
"""
    slots(capture)

The last slot a capture holds, so `slots(c) * c.grid` is how long it is in seconds.
"""
slots(r::Capture) = getfield(r, :stop)[]
Base.propertynames(r::Capture) = Tuple(keys(getfield(r, :short)))
function Base.getindex(r::Capture, path::AbstractString)
  i = _lookup(getfield(r, :index), getfield(r, :short), path)
  i == 0 && error("no signal named $path")
  getfield(r, :signals)[i]
end
Base.getindex(r::Capture, n::Net) = r[n.path]

Base.show(io::IO, s::Signal) =
  print(io, "Signal(", s.net.path, ", ", length(s.slots), " changes)")

"""
    changes(signal)

When a signal changed and what it changed to, as `time => value` pairs with the
time in seconds.
"""
changes(s::Signal{V}) where V =
  Pair{Float64,V}[float(s.slots[i] * s.grid) => _value(s, i) for i in eachindex(s.slots)]

Base.length(s::Signal) = length(s.slots)

# the value a signal held at a time
function Base.getindex(s::Signal{V}, t::Real)::V where V
  i = searchsortedlast(s.slots, _slotat(s, t))
  i == 0 && error("nothing recorded at $(_timestr(t))")
  _value(s, i)
end
_slotat(s::Signal, t::Real) = floor(Int, t / s.grid + 1e-9)

function _value(s::Signal{V}, i::Int)::V where V
  n = s.net
  n.kind === :clock && return true
  s.mask[i] == 0 || return n.kind === :pad ? _padstr(s.vals[i], s.mask[i], n.width) : missing
  n.kind === :fsm && n.enc !== nothing && return something(encname(n.enc, n.T(s.vals[i])), n.T(s.vals[i]))
  _fromraw(n.T, s.vals[i])
end

_fromraw(::Type{Bool}, v) = isodd(v)
_fromraw(::Type{T}, v) where T<:HWInt = T(v)
_fromraw(::Type{T}, v) where T<:Base.BitInteger = reinterpret(T, unsigned(T)(v & _mask(8sizeof(T))))
_fromraw(::Type{Pad{N}}, v) where N = N == 1 ? isodd(v) : Bits{N}(v)
_fromraw(::Type, v) = v

# what _fromraw gives for a net of type T, for typing that net's signal
_fromrawtype(::Type{Bool}) = Bool
_fromrawtype(::Type{T}) where T<:HWInt = T
_fromrawtype(::Type{T}) where T<:Base.BitInteger = T
_fromrawtype(::Type{Pad{N}}) where N = N == 1 ? Bool : Bits{N}
_fromrawtype(::Type) = UInt128

_padstr(v, m, N) = String(map(i -> isodd(m >> i) ? 'z' : isodd(v >> i) ? '1' : '0', N-1:-1:0))

"""
    sampled(signal)

A signal as frames, one per slot of the clock grid, from the first slot captured
to the last: the value held in each, as a number (`NaN` where there was none).
Reads from the changes as it goes, so nothing is built until it is asked for;
`collect` gives the plain vector. With SignalBase loaded it has a frame rate.
"""
sampled(s::Signal) = Sampled(s, s.stop[] + 1)

# a signal read frame by frame, one frame per slot, without building the vector
struct Sampled{S<:Signal} <: AbstractVector{Float64}
  signal::S
  n::Int
end
Base.size(x::Sampled) = (x.n,)
Base.IndexStyle(::Type{<:Sampled}) = IndexLinear()
# the return is declared: a signal's type is only known at run time, so without it
# every frame of a sampled signal would come back as `Any`
function Base.getindex(x::Sampled, i::Int)::Float64
  @boundscheck checkbounds(x, i)
  s = x.signal
  k = searchsortedlast(s.slots, i - 1)
  k == 0 && return NaN
  s.net.kind === :clock && return Float64(s.slots[k] == i - 1)
  s.mask[k] == 0 || return NaN
  v = _fromraw(s.net.T, s.vals[k])
  v isa Bool ? Float64(v) : Float64(Int128(v))
end
"the seconds per frame of a sampled signal"
frametime(x::Sampled) = x.signal.grid

_timestr(t::Real) = t == 0 ? "0s" :
  abs(t) ≥ 1 ? "$(round(float(t); sigdigits=4))s" :
  abs(t) ≥ 1e-3 ? "$(round(float(t) * 1e3; sigdigits=4))ms" :
  abs(t) ≥ 1e-6 ? "$(round(float(t) * 1e6; sigdigits=4))us" :
  abs(t) ≥ 1e-9 ? "$(round(float(t) * 1e9; sigdigits=4))ns" : "$(round(float(t) * 1e12; sigdigits=4))ps"

# hook for the viewer: called after a run, and now and then during one
_view!(s::Simulation, force::Bool) = s.viewer === nothing ? nothing : _update!(s.viewer, s, force)

# Units as plain numbers for code outside the macros, where `out.x[3ms]` still has to
# read well. Opt in with `using QuartzHDL.Units`; seconds is left out, since `s` is
# too useful a name to take.
module Units
export ms, µs, us, ns, ps, fs, Hz, kHz, MHz, GHz
const ms = 1//1000
const µs = 1//1000000
const us = µs
const ns = 1//1000000000
const ps = 1//1000000000000
const fs = 1//1000000000000000
const Hz = 1//1
const kHz = 1000//1
const MHz = 1000000//1
const GHz = 1000000000//1
end
