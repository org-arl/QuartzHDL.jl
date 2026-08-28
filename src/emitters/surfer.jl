# Showing a capture in Surfer, the waveform viewer, and keeping it current while a
# simulation runs. Surfer is driven over its control protocol (WCP): we listen, it
# connects, and from then on it takes JSON commands, each ended by a NUL byte. The
# waveform itself goes through a VCD file that is rewritten and reloaded.

"""
    Surfer()

The Surfer waveform viewer (https://surfer-project.org), as a viewer for `view`
and an `IO` a capture can be written to: what is written to it is what it shows,
through a scratch VCD file it is told to load again. One window per `Surfer()`.
"""
mutable struct Surfer <: Viewer
  proc::Union{Nothing,Base.Process}   # the viewer process, once launched
  sock::Union{Nothing,TCPSocket}      # its control connection
  file::String                        # the scratch VCD it shows
  scopes::Vector{String}              # the scopes already added to the display
  buffer::IOBuffer                    # a write in progress, until the format ends it
end

Surfer() = Surfer(nothing, nothing, joinpath(mktempdir(), "wave.vcd"), String[], IOBuffer())

Base.show(io::IO, v::Surfer) = print(io, "Surfer(", v.file, isopen(v) ? "" : ", closed", ")")
Base.isopen(v::Surfer) = v.proc !== nothing && process_running(v.proc) && v.sock !== nothing && isopen(v.sock)

# the IO side: bytes gather until the write of a capture ends, then Surfer loads them
Base.write(v::Surfer, b::UInt8) = write(v.buffer, b)
Base.unsafe_write(v::Surfer, p::Ptr{UInt8}, n::UInt) = unsafe_write(v.buffer, p, n)
Base.iswritable(::Surfer) = true
Base.isreadable(::Surfer) = false

function Base.write(v::Surfer, r::Capture, f::VCD)
  n = write(v.buffer, r, f)
  open(io -> write(io, take!(v.buffer)), v.file, "w")
  launching = !isopen(v)
  launching && _launch!(v)
  launching || _command(v, "reload", "", "ack")
  _show!(v, r)
  launching && _command(v, "zoom_to_fit", ""","viewport_idx":0""", "ack")
  n
end

function _launch!(v::Surfer)
  Sys.which("surfer") === nothing &&
    error("Surfer is not on the PATH; install it from https://surfer-project.org (brew install surfer)")
  server = listen(ip"127.0.0.1", 0)
  port = getsockname(server)[2]
  dir = _surferdir()
  proc = run(pipeline(Cmd(`surfer --wcp-initiate $port $(v.file)`; dir); stdout=devnull, stderr=devnull); wait=false)
  conn = @async accept(server)
  tries, pause = 100, 0.1
  for _ in 1:tries
    istaskdone(conn) && break
    process_running(proc) || error("Surfer exited before connecting")
    sleep(pause)
  end
  if !istaskdone(conn)
    kill(proc)
    error("Surfer did not connect within $(tries * pause)s")
  end
  v.proc = proc
  v.sock = fetch(conn)
  close(server)
  empty!(v.scopes)
  _send(v, """{"type":"greeting","version":"0","commands":[]}""")
  _expect(v, "greeting")
  v
end

# Surfer watches the file it shows and asks before reloading a changed one; the
# reloads here are explicit, so it is told not to, through a config in its working
# directory -- a scratch one, so no project picks the setting up
function _surferdir()
  dir = mktempdir()
  mkpath(joinpath(dir, ".surfer"))
  write(joinpath(dir, ".surfer", "config.toml"), "autoreload_files = \"Never\"\n")
  dir
end

_send(v::Surfer, msg::AbstractString) = (write(v.sock, msg, '\0'); flush(v.sock); nothing)

# the next message Surfer sends, checked for being what was asked for
function _expect(v::Surfer, what::AbstractString)
  reply = readuntil(v.sock, '\0')
  occursin("\"error\"", reply) && @warn "Surfer: $reply"
  occursin(what, reply) || @debug "Surfer replied $reply to $what"
  reply
end

# a command with its name and its arguments, given as the rest of a JSON object
_command(v::Surfer, name::AbstractString, args::AbstractString, what::AbstractString) =
  (_send(v, """{"type":"command","command":"$name"$args}"""); _expect(v, what))

# every scope the capture has, added whole, so the display starts full
function _show!(v::Surfer, r::Capture)
  scopes = unique(_vcdscope(s) for s in r.signals if s.net.kind !== :stub)
  for sc in scopes
    sc in v.scopes && continue
    _command(v, "add_scope", ""","scope":"$sc","recursive":true""", "add_scope")
    push!(v.scopes, sc)
  end
  nothing
end

_vcdscope(s::Signal) = join(_vcdpath(s)[1], ".")

function _update!(v::Surfer, s::Simulation, force::Bool)
  isopen(v) || (s.viewer = nothing; return nothing)
  force || time() - s.viewed > 0.5 || return nothing
  write(v, s.capture, VCD())
  s.viewed = time()
  nothing
end

function Base.close(v::Surfer)
  if isopen(v)
    try
      _send(v, """{"type":"command","command":"shutdown"}""")
    catch e
      @debug "Surfer did not take the shutdown command" exception=e
    end
    sleep(0.2)
  end
  v.proc !== nothing && process_running(v.proc) && kill(v.proc)
  v.sock !== nothing && isopen(v.sock) && close(v.sock)
  nothing
end
