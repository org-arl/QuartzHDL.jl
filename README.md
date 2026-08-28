[![doc-stable](https://img.shields.io/badge/docs-stable-blue.svg)](https://org-arl.github.io/QuartzHDL.jl) [![CI](https://github.com/org-arl/QuartzHDL.jl/workflows/CI/badge.svg)](https://github.com/org-arl/QuartzHDL.jl/actions) [![Aqua QA](https://raw.githubusercontent.com/JuliaTesting/Aqua.jl/master/badge.svg)](https://github.com/JuliaTesting/Aqua.jl) [![Codecov](https://codecov.io/gh/org-arl/QuartzHDL.jl/branch/master/graph/badge.svg)](https://codecov.io/gh/org-arl/QuartzHDL.jl) [![ColPrac](https://img.shields.io/badge/ColPrac-contributing-blueviolet)](CONTRIBUTING.md)

# QuartzHDL.jl

**Write FPGA logic in Julia, simulate it in Julia, compile it to Verilog.**

## Why

The logic in an instrument's FPGA is usually a port: an algorithm that already exists, in Julia or Python or MATLAB, rewritten as hardware. The port is where the bugs live, and Verilog gives you little to find them with — no types to speak of, no REPL, no test framework, no plots, and a simulator that tells you a waveform is wrong but not why.

QuartzHDL keeps the design in the language the reference is written in. A module is a `struct` whose fields are the registers, with a block that says what those registers become on each clock edge. The same source runs as ordinary Julia — one function call per clock, values you can inspect and test — and compiles to Verilog. A co-simulation drives both with the same stimulus and checks that they agree, cycle for cycle, so the Verilog is the design and not a second copy of it.

It is not a Julia-to-hardware compiler and not a replacement for Verilog. It is Verilog's subset of synchronous logic, written in a language with types, a REPL, a test framework and a plotting library, so that a design can be debugged like software, ported from a reference one step at a time, tested against models of the chips around it, and checked on every push.

## What is in the box

- **A design is a `struct`** — fields are registers, `@in`/`@out` are ports, with widths, signedness and polarity checked when the design is built
- **Verilog's bit semantics** — `Bits{N}` and `SBits{N}` slice, concatenate and overflow the way the hardware will
- **Hardware idioms as types and macros** — self-clearing pulses, countdowns, edge detectors, named state machines, multi-step sequences
- **Hierarchy** — submodules, clock domains, power-gated pads, and vendor black boxes with Julia stand-ins
- **Runs as plain Julia** — one function call per clock edge, so a design is tested with `@test` and debugged at the REPL
- **Simulation with the chips around it** — real clock rates, models of a USB FIFO, UART, SPI, I2C and RAM, waveforms in Surfer or Plots, a `sim>` prompt
- **Verilog out, and proof it matches** — co-simulation under Icarus Verilog compares Julia and Verilog cycle for cycle
- **Board to bitstream** — `@board` describes the pins, and the constraint file and a Lattice Diamond workspace are generated from it

## Installation

```julia
using Pkg
Pkg.add("QuartzHDL")           # Julia 1.11 or later
Pkg.Apps.add("QuartzHDL")      # the `quartz` command; Julia 1.12 or later
```

Co-simulation needs [Icarus Verilog](https://steveicarus.github.io/iverilog/) on the path; live waveforms need [Surfer](https://surfer-project.org).

## A taste

A UART transmitter: a byte in, a serial frame out with a parity bit. The frame is a sequence of steps, each one clock, and the bit timing is a countdown register that does its own bookkeeping.

```julia
using QuartzHDL

const BIT_TIME = 103                 # clocks per bit, less one: 9600 baud from 1 MHz

@quartz struct UartTx
  @in  send::Bool = false
  @in  data::Bits{8} = 0
  @out tx::Bool = true
  @out busy::Bool
  step::Bits{5} = 0
  shift::Bits{8} = 0
  parity::Bool = false
  baud_timer::Timeout{7}
end

@on UartTx posedge(clk) begin
  @sequence Frame step begin
    @when send                       # wait for send, then
    shift ← data
    parity ← isodd(popcount(data))   # a Julia function, computed in hardware
    tx ← false                       # start bit
    baud_timer ← BIT_TIME
    @repeat 8 begin
      @when expired(baud_timer)      # one bit time later
      tx ← shift[0]                  # a data bit, LSB first
      shift ← shift >> 1
      baud_timer ← BIT_TIME
    end
    @then @when expired(baud_timer)
    tx ← parity                      # even parity
    baud_timer ← BIT_TIME
    @then @when expired(baud_timer)
    tx ← true                        # stop bit
    baud_timer ← BIT_TIME
    @then @when expired(baud_timer)  # hold it, then back to waiting for send
  end
  busy ← step != Frame.START
end
```

It is ordinary Julia, so it runs as such. A simulation clocks it at a real rate, records the pins you ask for, and hands back signals you can index by time, test, and plot:

```julia
using QuartzHDL.Units, Plots

sim = Simulation(UartTx(); clocks = (clk = 1MHz,), watch = "tx")
out = @run sim begin
  sim.data = Bits{8}('A')
  sim.send = true
  advance_by(1.2ms)
end
plot(out.tx)
```

<img src="assets/uart-tx.png" width="640">

The same file compiles to Verilog from the command line — a `case` over the sequence's steps, the state machine you would have written by hand:

```
$ quartz uart.jl --top UartTx -o uart.v
```

## Documentation

The [manual](https://org-arl.github.io/QuartzHDL.jl) starts with a [worked example](https://org-arl.github.io/QuartzHDL.jl/quickstart.html) and builds the language up a construct at a time, with notes for readers who know Verilog, and ends with a reference of every public name.
