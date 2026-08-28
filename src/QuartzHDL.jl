# QuartzHDL describes digital hardware in Julia. A design is a plain struct whose
# fields are its registers, with blocks of ordinary Julia driving them; the same
# description is run as a cycle-accurate simulation and emitted as synthesisable
# Verilog, so the two cannot say different things about the same design.
#
# src/ is organised as:
#
#   core/      the language: value types, the @quartz struct, the @on/@wire
#              compiler, the tracer the emitters read, ports, black boxes, clocks,
#              benches and boards
#   sim/       running a design over time: the Simulation object and its REPL
#   emitters/  what a design is written out as: Verilog, simulation models, VCD,
#              constraints, and the tools that read them
#   library/   ready-made parts a design can instantiate or a bench can wire to
#   app.jl     the command-line entry point

module QuartzHDL

using Sockets
using REPL
using REPL: LineEdit
using Base.CoreLogging: @logmsg, LogLevel, Debug, Info, Warn, Error

export
  # types
  QuartzModule, Bits, SBits, Pulse, Timeout, Edge, MetaGuard, Pipeline, Multicycle, Pad,
  # struct and port declarations
  @quartz, @in, @out, @io, interface, portdoc,
  # blocks and their clauses
  @on, @wire, @reset, @only_when, @clockout, @method, @check,
  # values and what they do
  bits, ⊞, bitwidth, part, static, firstset, onehot, popcount, drive, release, padnet,
  netlevel, expired, rose, fell, isrising, isfalling, isnew,
  # encodings, state machines and sequences
  @encoding, encname, statedoc, @fsm, @state, @otherwise, @sequence, @then, @when, @delay, @repeat,
  # black boxes and clocks
  @blackbox, standin, clocklevel, @clocks, ClockPlan, @multicycle, @primary,
  # benches and boards
  Bench, history, @wiring, Wiring, @board, Board,
  # simulation
  Simulation, nets, watch!, unwatch!, capture, clear!, reset!, changes, sampled, slots,
  advance_by, advance_until, spawn!, stop!, run!, @run, @stimulus, simrepl, showlogs!,
  # formats and tools
  Verilog, VCD, LPF, Diamond, Surfer, Icarus, simmodels, stages, cosim, hook!, unhook!, on,
  # library
  UART, FT2232H, SPIMaster, SPISlave, transfer, I2CMaster, I2CSlave, PWM, RAM

"""
    QuartzModule

The supertype of every `@quartz` struct: a hardware module, whose fields are its
registers and instances and whose blocks are declared with `@on` and `@wire`.
"""
abstract type QuartzModule end
abstract type BlackBox <: QuartzModule end  # a module QuartzHDL does not define
abstract type Format end                    # what a design or a capture is written as
abstract type Viewer <: IO end              # a waveform viewer, written to like a file
abstract type Tool end                      # a simulator a co-simulation runs in

include("core/reg.jl")
include("core/encoding.jl")
include("core/quartz.jl")
include("core/fsm.jl")
include("core/sequence.jl")
include("core/blocks.jl")
include("core/method.jl")
include("core/trace.jl")
include("core/ports.jl")
include("core/blackbox.jl")
include("core/clocks.jl")
include("core/wiring.jl")
include("core/bench.jl")
include("core/board.jl")
include("sim/sim.jl")
include("sim/simlog.jl")
include("sim/simrepl.jl")
include("emitters/formats.jl")
include("emitters/verilog.jl")
include("emitters/stages.jl")
include("emitters/multicycle.jl")
include("emitters/simmodel.jl")
include("emitters/vcd.jl")
include("emitters/lpf.jl")
include("emitters/diamond.jl")
include("emitters/surfer.jl")
include("emitters/icarus.jl")
include("app.jl")
include("library/links.jl")
include("library/uart.jl")
include("library/ft2232h.jl")
include("library/spi.jl")
include("library/i2c.jl")
include("library/pwm.jl")
include("library/ram.jl")

end
