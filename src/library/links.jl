# What the library's components share. A link is one end of a connection to the
# design, talked to the way a host talks to hardware: bytes are queued with `put!`
# and collected with `take!` without time passing, or read and written as an IO,
# which lets the simulation run until the bytes have gone out or come in. A
# closure given with `on` answers each unit as it arrives, the way a device would.
#
# A component reads and drives nets by path, as a stimulus does; it needs no
# wiring and no entry in the clock plan. What runs it is a task, where it acts at
# its own pace, or a hook, where it must look at the bus every slot.

abstract type Link <: IO end

# a master makes the transfers itself, so it has nothing to run and nothing to close
abstract type BusMaster <: Link end

# The queues and the settings every link has, held by each concrete link in a
# field. `sim` stays abstract: a simulation's type is the design's, and every
# component would carry it as a parameter to no gain.
mutable struct LinkState
  sim::Simulation
  outq::Vector{UInt8}                        # to send
  inq::Vector{UInt8}                         # received, not yet taken
  frame::Union{Nothing,Int,Vector{UInt8}}    # a byte count, or the bytes that end a frame
  timeout::Rational{Int}                     # for a blocking read or write, in seconds
  on::Union{Nothing,Function}                # answers each unit received
  tasks::Vector{SimTask}
  hook::Union{Nothing,Function}              # what the component does every slot
  busy::Bool                                 # a transfer is on the wire
end

LinkState(sim, frame, timeout) =
  LinkState(sim, UInt8[], UInt8[], _frame(frame), Rational{Int}(rationalize(Int, float(timeout))),
            nothing, SimTask[], nothing, false)

_frame(::Nothing) = nothing
_frame(n::Integer) = Int(n)
_frame(b::UInt8) = [b]
_frame(s::AbstractString) = Vector{UInt8}(codeunits(s))
_frame(v::AbstractVector{UInt8}) = Vector{UInt8}(v)

_state(l::Link) = getfield(l, :link)::LinkState
_sim(l::Link) = _state(l).sim

### queues

"""
    put!(link, bytes)

Queue bytes for the link to send; they go out as the simulation runs.
"""
Base.put!(l::Link, bytes) = (append!(_state(l).outq, _bytes(bytes)); l)

_bytes(b::UInt8) = [b]
_bytes(b::Integer) = [UInt8(b)]
_bytes(s::AbstractString) = Vector{UInt8}(codeunits(s))
_bytes(v::AbstractVector) = collect(UInt8, v)

"""
    take!(link)

What the link has received and not yet handed over: every byte, or, with a
frame set, the next whole frame (empty if none is complete yet).
"""
function Base.take!(l::Link)
  st = _state(l)
  st.frame === nothing && return (out = copy(st.inq); empty!(st.inq); out)
  n = _framelength(st.inq, st.frame)
  n == 0 && return UInt8[]
  out = st.inq[1:n]
  deleteat!(st.inq, 1:n)
  out
end

# the length of the first whole frame in a queue, or 0
_framelength(q, n::Int) = length(q) ≥ n ? n : 0
function _framelength(q, delim::Vector{UInt8})
  k = length(delim)
  for i in 1:length(q)-k+1
    q[i:i+k-1] == delim && return i + k - 1
  end
  0
end

Base.isready(l::Link) =
  (st = _state(l); st.frame === nothing ? !isempty(st.inq) : _framelength(st.inq, st.frame) > 0)
Base.bytesavailable(l::Link) = length(_state(l).inq)
Base.readavailable(l::Link) = (st = _state(l); out = copy(st.inq); empty!(st.inq); out)
Base.eof(::Link) = false
Base.isopen(l::Link) = !isempty(_state(l).tasks) || _state(l).hook !== nothing
Base.isopen(::BusMaster) = true
Base.iswritable(::Link) = true
Base.isreadable(::Link) = true

"""
    on(f, link)

Answer what the link receives: `f(unit)` is called with each frame (each byte,
with no frame set; each transaction, for a bus), and what it returns is sent
back -- bytes, a string, or nothing. A unit given to `f` is not queued for `take!`.
"""
on(f, l::Link) = (_state(l).on = f; l)
on(::Nothing, l::Link) = (_state(l).on = nothing; l)

# a unit has arrived: to the closure if there is one, else to the queue
function _received!(l::Link, bytes::AbstractVector{UInt8})
  st = _state(l)
  st.on === nothing && return (append!(st.inq, bytes); nothing)
  reply = Base.invokelatest(st.on, bytes)
  reply === nothing || put!(l, reply)
  nothing
end

# bytes arrive one at a time; with a frame set they are held back until it is whole
function _receivedbyte!(l::Link, b::UInt8)
  st = _state(l)
  st.on === nothing && return (push!(st.inq, b); nothing)
  st.frame === nothing && return _received!(l, [b])
  push!(st.inq, b)
  n = _framelength(st.inq, st.frame)
  n == 0 && return nothing
  unit = st.inq[1:n]
  deleteat!(st.inq, 1:n)
  _received!(l, unit)
end

### blocking reads and writes

# run a stimulus function now: in a task, directly; at top level, as a run
_run(s::Simulation, f) = _intask(s) ? f() : run!(s, f)

# run the simulation until `cond()` holds; `what` names the wait in a timeout
_blockuntil(l::Link, cond, what) =
  (s = _sim(l); _run(s, () -> advance_until(s, cond; timeout=_state(l).timeout, what)); nothing)

function _intask(s::Simulation)
  t = current_task()
  any(st -> st.task === t, s.tasks)
end

function Base.unsafe_write(l::Link, p::Ptr{UInt8}, n::UInt)
  put!(l, unsafe_wrap(Vector{UInt8}, p, n))
  st = _state(l)
  _blockuntil(l, () -> isempty(st.outq) && !st.busy, "to write")
  Int(n)
end

"""
    write(link, bytes)

Send bytes, letting the simulation run until they have gone out. Any of Base's
writers works: `write(u, "AT\r\n")`, `print(u, x)`, `write(u, 0x55)`.
"""
Base.write(l::Link, b::UInt8) = unsafe_write(l, Ref(b), UInt(1))

"""
    read(link, n)

The next `n` bytes, letting the simulation run until they have arrived.
"""
function Base.read(l::Link, n::Integer)
  st = _state(l)
  _blockuntil(l, () -> length(st.inq) ≥ n, "to read")
  out = st.inq[1:n]
  deleteat!(st.inq, 1:n)
  out
end
Base.read(l::Link, ::Type{UInt8}) = read(l, 1)[1]

"""
    read(link)

The next whole frame, letting the simulation run until one has arrived; with no
frame set, the next byte.
"""
function Base.read(l::Link)
  st = _state(l)
  st.frame === nothing && return read(l, 1)
  _blockuntil(l, () -> _framelength(st.inq, st.frame) > 0, "to read")
  take!(l)
end

Base.close(::BusMaster) = nothing

function Base.close(l::Link)
  st = _state(l)
  foreach(t -> stop!(st.sim, t), copy(st.tasks))
  empty!(st.tasks)
  st.hook === nothing || unhook!(st.sim, st.hook)
  st.hook = nothing
  nothing
end

### running a component

# a task of the component, kept so close can end it
function _task!(l::Link, f)
  st = _state(l)
  t = spawn!(st.sim, f; persistent=true)
  push!(st.tasks, t)
  t
end

# a hook of the component, called every slot
function _hook!(l::Link, f)
  st = _state(l)
  st.hook = hook!(st.sim, f)
  f
end

# the edge times of a transfer are taken from its start, never accumulated, so the
# error never exceeds half a slot however long the transfer
_at(sim::Simulation, t) = advance_until(sim, () -> t)

# drive a level on a net whichever kind it is: a pad takes a drive, an input the value
function _setnet!(s::Simulation, path, v::Integer)
  s[path] = _ispad(s, path) ? drive(v) : v
  nothing
end
_setnet!(s::Simulation, path, v::PadValue) = (s[path] = v; nothing)

# release a net, or leave it where it is if it is an input and cannot be released
function _release!(s::Simulation, path)
  _ispad(s, path) && (s[path] = release())
  nothing
end

# whether a net a component means to drive is a pad rather than an input; asked of
# the drive record's type, so a hook does not box the value it holds every slot
function _ispad(s::Simulation, path)
  name = Symbol(path)
  D = typeof(s.drives)
  hasfield(D, name) || error("$path cannot be driven")
  fieldtype(D, name) <: Tuple
end
