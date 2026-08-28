# What leaves the package, and in what form. A format or a tool is a value, so
# `write(path, x, Verilog())` and `view(Surfer(), capture)` dispatch on it, and a
# new one is a type and its methods -- in another package if need be.

"""
    Verilog(; name=nothing, suffix=true, debug=false, inits=:static)

Verilog for a design: `write(path, T, Verilog())`. `name` is the module's name,
the type's if not given, and `suffix` puts `_i`/`_o` on the ports. `debug` emits
the design's log statements as `\$display`. `inits = :static` initializes only
the registers whose value the bitstream delivers -- what synthesis needs, and
nothing that would cost it a flip-flop's enable pin; `:all` initializes every
register, for a simulator that would otherwise start them at x.
"""
struct Verilog <: Format
  name::Union{Nothing,Symbol}  # the module's name, or the type's
  suffix::Bool                 # `_i`/`_o` on the ports
  debug::Bool                  # emit the design's log statements
  inits::Symbol                # which registers get an initializer, :static or :all
end

Verilog(; name=nothing, suffix=_portsuffix(), debug=false, inits=:static) =
  (inits in (:static, :all) || throw(ArgumentError("inits is :static or :all, got $inits"));
   Verilog(name, suffix, debug, inits))

"""
    VCD()

A capture as a value change dump: `write(path, capture, VCD())`, the format a
waveform viewer reads.
"""
struct VCD <: Format end

"""
    LPF(board)

Lattice constraints for a design on a board: `write(path, T, LPF(board))`. Pin
sites, buffer options, clock rates and timing exceptions come from the same
declarations the Verilog does, so the two agree.
"""
struct LPF <: Format
  board::Board               # the board the design is placed on
end

"""
    Diamond(board; vendor = String[], implementation = "impl")

A Lattice Diamond workspace for a design on a board: `write(dir, T, Diamond(board))`
fills `dir` with the Verilog under `src/`, the constraint file, a project file
(`.ldf`) with a default strategy (`.sty`), and a `build.sh` and `Makefile` that run
Diamond from synthesis to the bitstream -- and the JEDEC file on a MachXO part --
so `make` there builds the design where Diamond is installed. `vendor` lists the
netlists of the design's black boxes, copied into `src/` and added to the project;
a black box with no netlist is listed as `src/<Name>.v` for the user to supply.
"""
struct Diamond <: Format
  board::Union{Nothing,Board}  # the board the design is placed on; the app fills it in from --board
  vendor::Vector{String}       # netlists of the black boxes, to copy into src/
  implementation::String       # Diamond's implementation name, and its directory
  name::Union{Nothing,Symbol}  # the module's name, or the type's
end

Diamond(board::Union{Nothing,Board}=nothing; vendor=String[], implementation="impl") =
  Diamond(board, collect(String, vendor), implementation, nothing)

"""
    Icarus()

Icarus Verilog (`iverilog`/`vvp`) as the simulator a `cosim` runs the generated
Verilog in. It is the default, and needs `iverilog` on the PATH.
"""
struct Icarus <: Tool end

"""
    extension(format)

The file extension a format is written with; a new `Format` defines it so the
command line can name its output.
"""
extension(::Verilog) = "v"
extension(::VCD) = "vcd"
extension(::LPF) = "lpf"
extension(::Diamond) = ""

# where the command line writes a format that is not given a path: a file named
# after the module, or for a workspace a directory named after it
outputpath(f::Format, dir::AbstractString, name::Symbol) = joinpath(dir, "$name.$(extension(f))")
outputpath(::Diamond, dir::AbstractString, name::Symbol) = joinpath(dir, string(name))

# the format with a module name put on it, where a format carries one
_named(f::Verilog, name::Symbol) = Verilog(name, f.suffix, f.debug, f.inits)
_named(f::Diamond, name::Symbol) = Diamond(f.board, f.vendor, f.implementation, name)
_named(f::Format, ::Symbol) = f

"""
    write(path_or_io, x, format)

Write `x` in a format: a design as `Verilog()`, a capture as `VCD()`, a design on
a board as `LPF(board)`. Returns the path when given one.
"""
Base.write(path::AbstractString, x, f::Format) = (open(io -> write(io, x, f), path, "w"); path)
Base.write(dir::AbstractString, T::Type{<:QuartzModule}, f::Diamond) = _diamond(dir, T, f)

"""
    view([viewer], capture_or_sim)

Show a capture in a waveform viewer, `Surfer()` unless another is given. Given a
simulation, the viewer follows it: refreshed after every `@run`, and now and
then during a long one. `close(viewer)` closes it.
"""
Base.view(x::Union{Capture,Simulation}) = view(Surfer(), x)
Base.view(v::Viewer, r::Capture) = (write(v, r, VCD()); v)

function Base.view(v::Viewer, s::Simulation)
  s.viewer === nothing || s.viewer === v || close(s.viewer)
  view(v, s.capture)
  s.viewer = v
  s.viewed = time()
  v
end
