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
    LPF(board; overconstrain = 1)

Lattice constraints for a design on a board: `write(path, T, LPF(board))`. Pin
sites, buffer options, clock rates and timing exceptions come from the same
declarations the Verilog does, so the two agree.

`overconstrain = 1.2` constrains every clock at 1.2 times its real rate. Place and
route stops optimising once a design meets its constraints, so a build at the
real rates does not show how much margin it has. A build with tighter constraints
does. Use it only for measurement, because a design that fails it may still meet
the real rates.
"""
struct LPF <: Format
  board::Board               # the board the design is placed on
  overconstrain::Float64     # what every clock rate is multiplied by
end

LPF(board::Board; overconstrain=1) =
  (overconstrain > 0 || throw(ArgumentError("overconstrain is a factor above zero, got $overconstrain"));
   LPF(board, overconstrain))

"""
    Diamond(board; vendor = String[], implementation = "impl", overconstrain = 1, paths = 100,
            pack = false, replicate = false)

A Lattice Diamond workspace for a design on a board: `write(dir, T, Diamond(board))`
fills `dir` with the Verilog under `src/`, the constraint file and the same
constraints in the form synthesis reads (`.fdc`), a project file
(`.ldf`) with a default strategy (`.sty`), and a `build.sh` and `Makefile` that run
Diamond from synthesis to the bitstream -- and the JEDEC file on a MachXO part --
so `make` there builds the design where Diamond is installed. `vendor` lists the
netlists of the design's black boxes, copied into `src/` and added to the project;
a black box with no netlist is listed as `src/<Name>.v` for the user to supply.
`overconstrain` scales the clock rates in the constraint file, as described under
`LPF`. `paths` sets how many paths the timing reports list for each constraint,
starting with the worst.

The strategy maps with timing in mind, and leaves timing-driven packing and node
replication off. On the one design these were measured on, over twenty placement
seeds, packing raised the median clock a little and made one seed in twenty fail,
and replication changed nothing. `pack = true` and `replicate = true` turn them on
for a design where a measurement shows a gain.
"""
struct Diamond <: Format
  board::Union{Nothing,Board}  # the board the design is placed on; the app fills it in from --board
  vendor::Vector{String}       # netlists of the black boxes, to copy into src/
  implementation::String       # Diamond's implementation name, and its directory
  name::Union{Nothing,Symbol}  # the module's name, or the type's
  overconstrain::Float64       # what the constraint file multiplies every clock rate by
  paths::Int                   # the paths of each constraint the timing report lists
  pack::Bool                   # timing-driven packing in map
  replicate::Bool              # timing-driven node replication in map
end

function Diamond(board::Union{Nothing,Board}=nothing; vendor=String[], implementation="impl", overconstrain=1, paths=100,
    pack=false, replicate=false
)
  overconstrain > 0 || throw(ArgumentError("overconstrain is a factor above zero, got $overconstrain"))
  paths > 0 || throw(ArgumentError("paths is a count above zero, got $paths"))
  Diamond(board, collect(String, vendor), implementation, nothing, overconstrain, paths, pack, replicate)
end

"""
    QSF(board)

Quartus settings for a design on a board: `write(path, T, QSF(board))`. The device
and its family, the pin of every port, and what each buffer is told -- I/O standard,
weak pull-up, drive strength -- and the clocks that ride the global network. Clock
rates and timing exceptions are not settings; they go in the `SDC`.

An I/O standard is written as the board writes it, `:LVCMOS33`, and spelt as Quartus
spells it, `"3.3-V LVCMOS"`; a standard QuartzHDL has no spelling for is given as a
string in Quartus's own words. Quartus has no weak pull-down, so a `pull = :down`
is refused; a resistor on the board is `ext_pull`.
"""
struct QSF <: Format
  board::Board               # the board the design is placed on
end

"""
    SDC(board; overconstrain = 1)

Timing constraints for a design on a board, in the form Quartus reads:
`write(path, T, SDC(board))`. The rate of every clock the logic runs on, from the
oscillators and the clock tree, and an exception for every multicycle path the
design declares. `overconstrain` scales the clock rates, as described under `LPF`.
"""
struct SDC <: Format
  board::Board               # the board the design is placed on
  overconstrain::Float64     # what every clock rate is multiplied by
end

SDC(board::Board; overconstrain=1) =
  (overconstrain > 0 || throw(ArgumentError("overconstrain is a factor above zero, got $overconstrain"));
   SDC(board, overconstrain))

"""
    Quartus(board; vendor = String[], overconstrain = 1, cable = "usb-blaster")

A Quartus Prime workspace for a design on a board: `write(dir, T, Quartus(board))`
fills `dir` with the Verilog under `src/`, the project file (`.qpf`), the settings
file (`.qsf`) holding the project and the board's assignments, the timing
constraints (`.sdc`), and a `build.sh` and `Makefile` that run Quartus from
synthesis to the programming files, so `make` there builds the design where
Quartus is installed. The build also writes an `.svf`, and on a MAX 10 a `.pof`,
which `make load` and `make flash` send to the board with openFPGALoader over the
`cable` named. `vendor` lists the netlists of the design's black boxes, copied
into `src/` and added to the project; a black box with no netlist is listed as
`src/<Name>.v` for the user to supply. `overconstrain` scales the clock rates in
the constraints, as described under `LPF`.
"""
struct Quartus <: Format
  board::Union{Nothing,Board}  # the board the design is placed on; the app fills it in from --board
  vendor::Vector{String}       # netlists of the black boxes, to copy into src/
  name::Union{Nothing,Symbol}  # the module's name, or the type's
  overconstrain::Float64       # what the constraints multiply every clock rate by
  cable::String                # the JTAG cable, as openFPGALoader names it
end

function Quartus(board::Union{Nothing,Board}=nothing; vendor=String[], overconstrain=1, cable="usb-blaster")
  overconstrain > 0 || throw(ArgumentError("overconstrain is a factor above zero, got $overconstrain"))
  Quartus(board, collect(String, vendor), nothing, overconstrain, String(cable))
end

# a format that fills a directory rather than a file
const Workspace = Union{Diamond,Quartus}

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
extension(::QSF) = "qsf"
extension(::SDC) = "sdc"
extension(::Workspace) = ""

# where the command line writes a format that is not given a path: a file named
# after the module, or for a workspace a directory named after it
outputpath(f::Format, dir::AbstractString, name::Symbol) = joinpath(dir, "$name.$(extension(f))")
outputpath(::Workspace, dir::AbstractString, name::Symbol) = joinpath(dir, string(name))

# the format with a module name put on it, where a format carries one
_named(f::Verilog, name::Symbol) = Verilog(name, f.suffix, f.debug, f.inits)
_named(f::Diamond, name::Symbol) =
  Diamond(f.board, f.vendor, f.implementation, name, f.overconstrain, f.paths, f.pack, f.replicate)
_onboard(f::Diamond, board::Board) =
  Diamond(board, f.vendor, f.implementation, f.name, f.overconstrain, f.paths, f.pack, f.replicate)
_named(f::Quartus, name::Symbol) = Quartus(f.board, f.vendor, name, f.overconstrain, f.cable)
_onboard(f::Quartus, board::Board) = Quartus(board, f.vendor, f.name, f.overconstrain, f.cable)
_named(f::Format, ::Symbol) = f

"""
    write(path_or_io, x, format)

Write `x` in a format: a design as `Verilog()`, a capture as `VCD()`, a design on
a board as `LPF(board)` or `QSF(board)`. Returns the path when given one.
"""
Base.write(path::AbstractString, x, f::Format) = (open(io -> write(io, x, f), path, "w"); path)
Base.write(dir::AbstractString, T::Type{<:QuartzModule}, f::Diamond) = _diamond(dir, T, f)
Base.write(dir::AbstractString, T::Type{<:QuartzModule}, f::Quartus) = _quartus(dir, T, f)

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
