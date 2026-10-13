# A design on a board, and the files Lattice Diamond reads, written from the two:
# the constraint file, the Synplify constraints and the workspace. The board checks
# that belong to no vendor live here too, since the boards they use are these. The
# Quartus side is quartus.jl, and the two read the same way.

@quartz struct Chip
  @in clk_ref::Bool
  @in d::Bits{4}
  @io  io::Pad{3} = Pad{3}(:pullup)
  @out q::Bits{2}
end

@on Chip posedge(clk_ref) begin
  q ← d[0:1]
  io ← drive(d[0:2])
end

@board Rev2 begin
  device = "LFE5U-45F"
  io     = :LVCMOS25                 # every pin below, unless it says otherwise

  clk_ref => (pin = "G2", osc = 48MHz)     # a BGA site is a string, beside numbered pins
  d       => (pins = 10:13)
  io      => (pins = [20, 21, "F1"], drive = 8, ext_pull = :up)
  q     => (pins = 30:31, io = nothing)   # this one is left to the tool

  raw = """
        BLOCK RESETPATHS ;
        """
end

@board Wrong begin
  device = "X"
  clk_ref => (pin = 92,)
  d       => (pins = 10:12,)
  io      => (pins = [20, 21, 92],)
  ghost   => (pin = 5,)
end

@board Flipped begin
  device = "X"
  clk_ref => (pin = 1,)
  d       => (pins = 10:13,)
  io      => (pins = [20, 21, 22], pull = (0:1 => :up,), ext_pull = (2:2 => :down,))
  q       => (pins = 30:31,)
end

@testset "diamond: a board binds a design to pins" begin
  @test Rev2.device == "LFE5U-45F"
  @test QuartzHDL.oscillators(Rev2) == [:clk_ref => 48000000]
  @test occursin("BLOCK RESETPATHS", Rev2.raw)
  @test isempty(QuartzHDL.problems(Rev2, Chip))

  # a width that does not match its pins, a port that does not exist, two ports on
  # one site, a port with no pin, and a pull the design needs but the board lacks
  ps = QuartzHDL.problems(Wrong, Chip)
  @test length(ps) == 5
  @test any(p -> occursin("4 bits and Wrong gives it 3", p), ps)
  @test any(p -> occursin("ghost", p), ps)
  @test any(p -> occursin("site 92", p), ps)
  @test any(p -> occursin("q has no pin", p), ps)
  @test any(p -> occursin("relies on a pull-up", p), ps)

  # a pull the board provides the other way round, on one bit
  ps = QuartzHDL.problems(Flipped, Chip)
  @test ps == ["io is pulled up in the design and Flipped pulls it down (bit 2)"]

  # rates are exact, and the units mean nothing outside the block
  @test :MHz ∉ names(QuartzHDL)
  @test QuartzHDL._exact(32.768) == 32768//1000
end

@quartz struct Timed
  @in clk_ref::Bool
  pll::PLLT = PLLT()
  a::Bits{8}
  b::Bits{8}
  @out y::Bits{8}
end

@wire Timed begin
  pll.clki ← clk_ref
  fast ← pll.clkop
  slow ← pll.clkos
  odd ← pll.clkos2
  pll.stdby ← false
end

@on Timed posedge(fast) begin
  a ← b + 1
  b ← a
  y ← a
end

@multicycle Timed 4 a => b
@primary Timed fast

@quartz struct Shadowed
  @in d::Bits{8}
  utime::Bits{8}
  utime_frac::Bits{8}
  @out y::Bits{8}
end

@on Shadowed posedge(clk) begin
  utime ← utime + d
  utime_frac ← utime_frac + 1
  y ← utime
end

@board Lab begin
  device  = "LFE5U-45F"
  io      = :LVCMOS25
  clk_ref => (pin = 1, osc = 48MHz)
  y     => (pins = 10:17, pull = (0:1 => :down,))
end

@testset "diamond: constraints are generated, not maintained" begin
  text = sprint(io -> write(io, Timed, LPF(Lab)))
  @test occursin("LOCATE COMP \"clk_ref_i\" SITE \"1\" ;", text)
  @test occursin("LOCATE COMP \"y_o[7]\" SITE \"17\" ;", text)
  @test occursin("IOBUF PORT \"y_o[0]\" PULLMODE=DOWN IO_TYPE=LVCMOS25 ;", text)
  @test occursin("IOBUF PORT \"y_o[2]\" PULLMODE=NONE IO_TYPE=LVCMOS25 ;", text)
  @test occursin("USE PRIMARY NET \"fast\" ;", text)
  @test QuartzHDL.primarynets(Timed) == [:fast]
  @primary Timed fast, nope                        # a net the design does not have
  @test_throws ErrorException sprint(io -> write(io, Timed, LPF(Lab)))
  @primary Timed fast

  # every rate follows from the oscillator and the dividers; nothing is retyped. A
  # clock on a pin is named by its port, and a clock nothing runs on is left out
  @test occursin("FREQUENCY PORT \"clk_ref_i\" 48.000000 MHz ;", text)
  @test occursin("FREQUENCY NET \"fast\" 48.000000 MHz ;", text)
  @test !occursin("\"slow\"", text) && !occursin("\"odd\"", text)

  # a timing exception carries the clock net, not the field's own clock name; the
  # cell patterns come anchored, and in a bare and a `.`-prefixed form, one for
  # each way synthesis decorates a name
  @test occursin("MULTICYCLE FROM CELL \"a*\" CLKNET \"fast\" TO CELL \"b*\" " *
                 "CLKNET \"fast\" 4.000000 X ;", text)
  @test occursin("MULTICYCLE FROM CELL \"*.a*\" CLKNET \"fast\" TO CELL \"*.b*\" " *
                 "CLKNET \"fast\" 4.000000 X ;", text)
  @test count("MULTICYCLE", text) == 4

  # a field that is not a field of the module is a mistake worth stopping for
  @test_throws Exception @eval @multicycle Timed 4 a => ghost
  @test_throws Exception write(devnull, Timed, LPF(Wrong))

  # a name that extends an endpoint's name would ride its wildcard: refused before
  # anything is emitted, since synthesis decorations are exactly such extensions
  @test_throws Exception @eval @multicycle Shadowed 4 utime => y
  @test occursin("utime_frac",
                 try @eval @multicycle Shadowed 4 utime => y; "" catch e; sprint(showerror, e) end)
end

@quartz struct Pinned
  n::Bits{8}
  @out y::Bits{8}
end

@on Pinned posedge(clk) begin
  n ← n + 1
  y ← n
end

@primary Pinned clk

@board PinBoard begin
  device = "LCMXO2-4000HC-4MG132C"
  clk => (pin = "C1", osc = 12MHz)
  y   => (pins = ["N13", "M12", "P12", "M11", "P11", "N10", "N9", "P9"])
end

@quartz struct InnerPll
  n::Bits{8}
  @out y::Bits{8}
  pll::PLLT = PLLT()
end

@wire InnerPll begin
  pll.clki ← clk
  fast ← pll.clkop
  pll.stdby ← false
end

@on InnerPll posedge(fast) begin
  n ← n + 1
  y ← n
end

@quartz struct OuterPll
  inner::InnerPll = InnerPll()
  @out y::Bits{8}
end

@wire OuterPll inner.clk ← clk
@on OuterPll posedge(clk) y ← inner.y

@testset "diamond: a clock on a pin is constrained by its port" begin
  # synthesis renames the net behind a clock pin, so the rate names the port and the
  # global buffer names the buffered net
  text = sprint(io -> write(io, Pinned, LPF(PinBoard)))
  @test occursin("FREQUENCY PORT \"clk_i\" 12.000000 MHz ;", text)
  @test occursin("USE PRIMARY NET \"clk_i_c\" ;", text)
  @test !occursin("NET \"clk_i\"", text)
end

@testset "diamond: a clock is made at the top" begin
  @test QuartzHDL.problems(PinBoard, Pinned) == String[]
  @test QuartzHDL.problems(PinBoard, OuterPll) ==
    ["inner.pll makes a clock below the top; declare it in OuterPll and pass the clock in"]
  @test_throws ErrorException write(devnull, OuterPll, LPF(PinBoard))
  @test_throws ErrorException write(mktempdir(), OuterPll, Diamond(PinBoard))
end

@testset "diamond: a multicycle wire's constraint names every source and sink" begin
  text = sprint(io -> write(io, Timed2, LPF(Lab)))
  @test occursin("MULTICYCLE FROM CELL \"a*\" CLKNET \"fast\" TO CELL \"y*\" CLKNET \"fast\" 4.000000 X ;", text)
  @test count("MULTICYCLE", text) == 4
end

@testset "diamond: a board setting is checked where it is written" begin
  # a pin attribute nothing reads is a wrong buffer on a real pin: no IO_TYPE means
  # the tool picks a default I/O standard, which on a mixed-voltage board is a bank
  # at the wrong level
  @test_throws Exception @eval @board B1 begin
    device = "X"
    clk_ref => (pin = 1, iostandard = :LVCMOS33)     # the Xilinx spelling of `io`
  end
  @test_throws Exception @eval @board B2 begin
    device = "X"
    clk_ref => (pin = 1, puII = :up)                 # a capital I for an l
  end
  @test_throws Exception @eval @board B3 begin
    devise = "X"                                     # not a board setting
  end
  @test_throws Exception @eval @board B4 begin
    pull = :sideways
  end
  @test_throws Exception @eval @board B5 begin
    clk_ref => (io = :LVCMOS25)                      # no pin
  end

  # the block says it once and a pin overrides it, `nothing` included; a site is
  # printed verbatim, a BGA name the same way as a number
  text = sprint(io -> write(io, Chip, LPF(Rev2)))
  @test occursin("LOCATE COMP \"clk_ref_i\" SITE \"G2\" ;", text)
  @test occursin("LOCATE COMP \"io_io[2]\" SITE \"F1\" ;", text)
  @test occursin("IOBUF PORT \"d_i[0]\" PULLMODE=NONE IO_TYPE=LVCMOS25 ;", text)
  @test occursin("IOBUF PORT \"q_o[0]\" PULLMODE=NONE ;", text)   # io = nothing
  @test occursin("IOBUF PORT \"io_io[0]\" PULLMODE=NONE IO_TYPE=LVCMOS25 DRIVE=8 ;", text)
  @test occursin("FREQUENCY PORT \"clk_ref_i\" 48.000000 MHz ;", text)
end

@testset "diamond: constraints reach into a submodule" begin
  @test isempty(QuartzHDL.problems(SocBoard, Soc))
  text = sprint(io -> write(io, Soc, LPF(SocBoard)))
  @test occursin("BLOCK RESETPATHS ;", text) && occursin("BLOCK ASYNCPATHS ;", text)
  @test occursin("LOCATE COMP \"clk_ref_i\" SITE \"G2\" ;", text)
  @test occursin("LOCATE COMP \"gp_io[3]\" SITE \"23\" ;", text)
  @test occursin("FREQUENCY PORT \"clk_ref_i\" 48.000000 MHz ;", text)
  @test occursin("FREQUENCY NET \"slow\" 6.000000 MHz ;", text)
  # the cell patterns carry the instance path, in every pairing of the bare and the
  # `.`-prefixed form
  @test occursin("MULTICYCLE FROM CELL \"sub/slowsum*\" CLKNET \"fast\" TO CELL \"sub/slowcopy*\" " *
                 "CLKNET \"fast\" 4.000000 X ;", text)
  @test occursin("MULTICYCLE FROM CELL \"sub/*.slowsum*\" CLKNET \"fast\" TO CELL \"sub/*.slowcopy*\" " *
                 "CLKNET \"fast\" 4.000000 X ;", text)
  @test count("MULTICYCLE", text) == 4
end

@board SocXO begin
  device  = "LCMXO2-7000HE-4TG144I"
  io      = :LVCMOS33
  clk_ref => (pin = 20, osc = 48MHz)
  clk_aux => (pin = 21, osc = 10MHz)
  sb      => (pin = 1,)
  aux     => (pin = 2,)
  en      => (pin = 3,)
  we      => (pin = 4,)
  d       => (pins = 10:17)
  gp      => (pins = 30:33, pull = :down)
  lsb     => (pin = 40,)
  q       => (pins = 50:57)
  n_q     => (pins = 60:67)
end

@testset "diamond: a Diamond workspace is the whole build" begin
  dir = mktempdir()
  ram = joinpath(@__DIR__, "ref", "chip_ram.v")
  @test_logs (:warn, r"^CPLL has no netlist") (:warn, r"^CMUX has no netlist") begin
    write(dir, Soc, Diamond(SocBoard; vendor = [ram]))
  end
  files = Set(relpath(joinpath(r, f), dir) for (r, _, fs) in walkdir(dir) for f in fs)
  @test files == Set(["Makefile", "Soc.ldf", "Soc.sty", "SocBoard.lpf", "SocBoard.fdc", "build.sh", "src/Soc.v", "src/chip_ram.v"])
  @test occursin("module Soc (", read(joinpath(dir, "src", "Soc.v"), String))
  @test occursin("LOCATE COMP \"clk_ref_i\" SITE \"G2\" ;", read(joinpath(dir, "SocBoard.lpf"), String))
  ldf = read(joinpath(dir, "Soc.ldf"), String)
  @test occursin("title=\"Soc\" device=\"LFE5U-45F\" default_implementation=\"impl\"", ldf)
  @test occursin("<Options def_top=\"Soc\" top=\"Soc\"/>", ldf)
  @test occursin("<Source name=\"src/Soc.v\" type=\"Verilog\" type_short=\"Verilog\">\n            <Options top_module=\"Soc\"/>", ldf)
  @test occursin("<Source name=\"src/chip_ram.v\"", ldf)                # the netlist given, by its file
  @test occursin("<Source name=\"src/CPLL.v\"", ldf) && !occursin("CHIP_RAM.v", ldf)   # the missing ones by their module
  @test occursin("<Source name=\"SocBoard.lpf\" type=\"Logic Preference\"", ldf)
  @test occursin("<Strategy name=\"Strategy1\" file=\"Soc.sty\"/>", ldf)
  @test occursin("<Strategy version=\"1.0\"", read(joinpath(dir, "Soc.sty"), String))
  sh = read(joinpath(dir, "build.sh"), String)
  @test occursin("prj_project open \"Soc.ldf\"", sh) && occursin("prj_run PAR -impl impl", sh)
  @test occursin("-task Bitgen", sh) && !occursin("Jedecgen", sh)      # an ECP5 boots from the bitstream
  @test uperm(joinpath(dir, "build.sh")) & 0x01 != 0
  mk = read(joinpath(dir, "Makefile"), String)
  @test occursin("all: impl/Soc_impl.bit", mk) && occursin("\t./build.sh", mk)

  # a MachXO part takes a JEDEC file for its flash, and the workspace can be named
  dir2 = mktempdir()
  Test.@test_logs match_mode = :any (:warn, r"") write(dir2, Soc, QuartzHDL._named(Diamond(SocXO; implementation = "rev1"), :soc))
  @test isfile(joinpath(dir2, "src", "soc.v")) && isfile(joinpath(dir2, "soc.ldf"))
  @test occursin("-task Jedecgen", read(joinpath(dir2, "build.sh"), String))
  @test occursin("all: rev1/soc_rev1.jed", read(joinpath(dir2, "Makefile"), String))
  @test occursin("dir=\"rev1\"", read(joinpath(dir2, "soc.ldf"), String))

  @test_throws ArgumentError write(mktempdir(), Soc, Diamond())
  @test_throws "no such vendor netlist" write(mktempdir(), Soc, Diamond(SocBoard; vendor = ["nope.v"]))
end

@testset "diamond: a Diamond workspace set up to close timing, and to measure it" begin
  text = sprint(io -> write(io, TimingBlinker, LPF(TimingDemo)))
  @test occursin("FREQUENCY PORT \"clk_i\" 48.000000 MHz ;", text) && !occursin("times their rate", text)
  text = sprint(io -> write(io, TimingBlinker, LPF(TimingDemo; overconstrain=1.25)))
  @test occursin("FREQUENCY PORT \"clk_i\" 60.000000 MHz ;", text)
  @test occursin("// clocks are constrained at 1.25 times their rates", text)
  @test_throws ArgumentError LPF(TimingDemo; overconstrain=0)
  dir = write(mktempdir(), TimingBlinker, Diamond(TimingDemo))
  sty = read(joinpath(dir, "TimingBlinker.sty"), String)
  @test occursin("<Property name=\"PROP_MAP_TimingDriven\" value=\"True\"", sty)
  for p in ("PROP_MAP_TimingDrivenNodeRep", "PROP_MAP_TimingDrivenPack")
    @test occursin("<Property name=\"$p\" value=\"False\"", sty)
  end
  sty = read(joinpath(write(mktempdir(), TimingBlinker, Diamond(TimingDemo; pack=true, replicate=true)), "TimingBlinker.sty"), String)
  for p in ("PROP_MAP_TimingDrivenNodeRep", "PROP_MAP_TimingDrivenPack")
    @test occursin("<Property name=\"$p\" value=\"True\"", sty)
  end
  @test occursin("<Property name=\"PROP_MAP_RegRetiming\" value=\"False\"", sty)
  @test occursin("\"PROP_PARSTA_WordCasePaths\" value=\"100\"", sty) && occursin("\"PROP_MAPSTA_WordCasePaths\" value=\"100\"", sty)
  @test occursin("48.000000 MHz", read(joinpath(dir, "TimingDemo.lpf"), String))
  fdc = read(joinpath(dir, "TimingDemo.fdc"), String)
  @test occursin("create_clock -name {clk_i} -period 20.833 [get_ports {clk_i}]", fdc)
  @test occursin("TimingDemo.fdc\" type=\"Synplify Design Constraints File\"", read(joinpath(dir, "TimingBlinker.ldf"), String))
  @test occursin("TimingDemo.fdc", read(joinpath(dir, "Makefile"), String))
  socfdc = sprint(io -> QuartzHDL._fdc(io, Soc, SocBoard, 1.0))
  @test occursin("set_multicycle_path 4 -from [get_cells {sub.slowsum[*]}] -to [get_cells {sub.slowcopy[*]}]", socfdc)
  @test occursin("create_clock -name {clk_ref_i}", socfdc) && occursin("-name {fast} -period 20.833 [get_nets {pll.CLKOP}]", socfdc)
  @test occursin("[get_nets {pll.CLKOS}]", socfdc)
  dir = write(mktempdir(), TimingBlinker, Diamond(TimingDemo; overconstrain=1.5, paths=250))
  @test occursin("72.000000 MHz", read(joinpath(dir, "TimingDemo.lpf"), String))
  @test occursin("-period 13.889", read(joinpath(dir, "TimingDemo.fdc"), String))
  @test occursin("\"PROP_PARSTA_WordCasePaths\" value=\"250\"", read(joinpath(dir, "TimingBlinker.sty"), String))
  @test_throws ArgumentError Diamond(TimingDemo; paths=0)
  f = QuartzHDL._onboard(QuartzHDL._named(Diamond(; overconstrain=1.2, paths=50, pack=true), :blink), TimingDemo)
  @test (f.board, f.name, f.overconstrain, f.paths, f.pack, f.replicate) == (TimingDemo, :blink, 1.2, 50, true, false)
end
