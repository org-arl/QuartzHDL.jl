# A design on a board Quartus builds for: the settings file and the timing
# constraints, and the workspace that holds them with the project. The checks
# mirror those of the Lattice flow in soc.jl, since the two are written from the
# same declarations.

@quartz struct Walker
  "DIP switches; a switch reads 0 when on"
  @in  sw::Bits{2} = 0  active=:low
  "red LEDs, lit when driven low"
  @out led::Bits{5} = 0b00001  active=:low
  n::Bits{8} = 0
end

@on Walker posedge(clk) begin
  n ← (sw[0] ? n + 2 : n + 1)
  n == 0 && (led ← bits(led[0:3], led[4]))
end

@board Max10 begin
  "the MAX 10 10M08S evaluation kit"
  device = "10M08SAE144C8G"
  io     = :LVCMOS33
  clk => (pin = 27, osc = 50MHz)
  sw  => (pins = [120, 124], ext_pull = :up)
  led => (pins = [132, 134, 135, 140, 141], drive = 8)
end

@testset "quartus: the settings file places the design on the board" begin
  @test isempty(QuartzHDL.problems(Max10, Walker))
  text = sprint(io -> write(io, Walker, QSF(Max10)))
  @test occursin("set_global_assignment -name FAMILY \"MAX 10\"", text)
  @test occursin("set_global_assignment -name DEVICE 10M08SAE144C8G", text)
  @test occursin("set_global_assignment -name STRATIX_DEVICE_IO_STANDARD \"3.3-V LVCMOS\"", text)
  @test occursin("set_location_assignment PIN_27 -to clk_i", text)
  @test occursin("set_location_assignment PIN_124 -to sw_ni[1]", text)
  @test occursin("set_location_assignment PIN_141 -to led_no[4]", text)
  @test occursin("set_instance_assignment -name IO_STANDARD \"3.3-V LVCMOS\" -to led_no[0]", text)
  @test occursin("set_instance_assignment -name CURRENT_STRENGTH_NEW 8MA -to led_no[2]", text)
  @test !occursin("CURRENT_STRENGTH_NEW 8MA -to clk_i", text)
  @test occursin("WEAK_PULL_UP_RESISTOR OFF -to sw_ni[0]", text)        # the board's resistor, not the FPGA's
  @test !occursin("create_clock", text)                                 # a rate is not a setting
  @test count("set_location_assignment", text) == 8
  sdc = sprint(io -> write(io, Walker, SDC(Max10)))
  @test occursin("create_clock -name {clk_i} -period 20.0 [get_ports {clk_i}]", sdc)
  @test occursin("derive_clock_uncertainty", sdc)
  @test !occursin("set_multicycle_path", sdc)
  sdc = sprint(io -> write(io, Walker, SDC(Max10; overconstrain = 1.25)))
  @test occursin("-period 16.0 ", sdc) && occursin("# clocks are constrained at 1.25 times", sdc)
  @test_throws ArgumentError SDC(Max10; overconstrain = 0)
  stim = [(sw = Bits{2}(rand(0:3)),) for _ in 1:600]
  @test cosim(Walker, stim).ok skip=!HAVE_IVERILOG
end

@board Max10Pulled begin
  device = "10M08SAE144C8G"
  clk => (pin = 27, osc = 50MHz)
  sw  => (pins = [120, 124], pull = :up, io = :LVTTL33)
  led => (pins = [132, 134, 135, 140, 141], io = "2.5 V")
end

@board Max10Down begin
  device = "10M08SAE144C8G"
  clk => (pin = 27, osc = 50MHz)
  sw  => (pins = [120, 124], pull = :down)
  led => (pins = [132, 134, 135, 140, 141])
end

@board Max10Odd begin
  device = "10M08SAE144C8G"
  clk => (pin = 27, osc = 50MHz)
  sw  => (pins = [120, 124], io = :SSTL15)
  led => (pins = [132, 134, 135, 140, 141])
end

@board Max10Short begin
  device = "10M08SAE144C8G"
  clk => (pin = 27, osc = 50MHz)
  sw  => (pins = [120, 124])
  led => (pins = [132, 134, 135, 140])
end

@board Lattice begin
  device = "LCMXO2-7000HE-4TG144I"
  clk => (pin = 27, osc = 50MHz)
  sw  => (pins = [120, 124])
  led => (pins = [132, 134, 135, 140, 141])
end

@testset "quartus: what is spelt for Quartus, and what is refused" begin
  text = sprint(io -> write(io, Walker, QSF(Max10Pulled)))
  @test occursin("WEAK_PULL_UP_RESISTOR ON -to sw_ni[1]", text)
  @test occursin("IO_STANDARD \"3.3-V LVTTL\" -to sw_ni[0]", text)
  @test occursin("IO_STANDARD \"2.5 V\" -to led_no[3]", text)          # Quartus's own words pass through
  @test !occursin("IO_STANDARD", split(text, "-to clk_i")[1])          # no board default: left to the tool
  @test !occursin("STRATIX_DEVICE_IO_STANDARD", text)
  @test_throws "Quartus has no weak pull-down" write(devnull, Walker, QSF(Max10Down))
  @test_throws "no Quartus spelling is known for the I/O standard :SSTL15" write(devnull, Walker, QSF(Max10Odd))
  @test_throws "do not agree" write(devnull, Walker, QSF(Max10Short))
  @test_throws "do not agree" write(devnull, Walker, SDC(Max10Short))
  @test_throws "not a part Quartus builds for" write(devnull, Walker, QSF(Lattice))
  @test_throws "not a part Quartus builds for" write(devnull, Walker, SDC(Lattice))
  @test_throws "not a part Quartus builds for" write(mktempdir(), Walker, Quartus(Lattice))
  @test_throws "a MAX 10 part that Quartus builds for" write(devnull, Walker, LPF(Max10))
  @test_throws "a MAX 10 part that Quartus builds for" write(mktempdir(), Walker, Diamond(Max10))
  @test QuartzHDL._quartusfamily("5CSEBA6U23I7") == "Cyclone V"
  @test QuartzHDL._quartusfamily("EP4CE22F17C6") == "Cyclone IV E"
  @test QuartzHDL._quartusfamily("LFE5U-45F") === nothing
end

# the Soc of soc.jl on a MAX 10, for the clock tree and the multicycle paths
@board SocMax begin
  device  = "10M08SAE144C8G"
  io      = :LVCMOS33
  clk_ref => (pin = 27, osc = 48MHz)
  clk_aux => (pin = 28, osc = 10MHz)
  sb      => (pin = 1,)
  aux     => (pin = 2,)
  en      => (pin = 3,)
  we      => (pin = 4,)
  d       => (pins = 10:17)
  gp      => (pins = 30:33, ext_pull = :down)
  lsb     => (pin = 40,)
  q       => (pins = 50:57)
  n_q     => (pins = 60:67)
end

@testset "quartus: constraints reach into a submodule and through the clock tree" begin
  sdc = sprint(io -> write(io, Soc, SDC(SocMax)))
  @test occursin("create_clock -name {clk_ref_i} -period 20.833 [get_ports {clk_ref_i}]", sdc)
  @test occursin("create_clock -name {fast} -period 20.833 [get_pins {pll|CLKOP}]", sdc)
  @test occursin("[get_pins {pll|CLKOS}]", sdc)
  @test occursin("set_multicycle_path -setup 4 -from [get_registers {sub|slowsum*}] -to [get_registers {sub|slowcopy*}]", sdc)
  @test occursin("set_multicycle_path -hold 3 -from [get_registers {sub|slowsum*}] -to [get_registers {sub|slowcopy*}]", sdc)
  @test count("set_multicycle_path", sdc) == 2
  qsf = sprint(io -> write(io, Soc, QSF(SocMax)))
  @test occursin("set_location_assignment PIN_33 -to gp_io[3]", qsf)
  @test occursin("WEAK_PULL_UP_RESISTOR OFF -to gp_io[0]", qsf)
end

@testset "quartus: a workspace is the whole build" begin
  dir = mktempdir()
  ram = joinpath(@__DIR__, "ref", "chip_ram.v")
  @test_logs (:warn, r"^CPLL has no netlist") (:warn, r"^CMUX has no netlist") begin
    write(dir, Soc, Quartus(SocMax; vendor = [ram]))
  end
  files = Set(relpath(joinpath(r, f), dir) for (r, _, fs) in walkdir(dir) for f in fs)
  @test files == Set(["Makefile", "Soc.qpf", "Soc.qsf", "SocMax.sdc", "build.sh", "src/Soc.v", "src/chip_ram.v"])
  @test occursin("module Soc (", read(joinpath(dir, "src", "Soc.v"), String))
  @test read(joinpath(dir, "Soc.qpf"), String) == "PROJECT_REVISION = \"Soc\"\n"
  qsf = read(joinpath(dir, "Soc.qsf"), String)
  @test occursin("set_global_assignment -name TOP_LEVEL_ENTITY Soc", qsf)
  @test occursin("set_global_assignment -name FAMILY \"MAX 10\"", qsf)
  @test occursin("set_global_assignment -name VERILOG_FILE src/Soc.v", qsf)
  @test occursin("set_global_assignment -name VERILOG_FILE src/chip_ram.v", qsf)     # the netlist given, by its file
  @test occursin("VERILOG_FILE src/CPLL.v", qsf) && !occursin("CHIP_RAM.v", qsf)    # the missing ones by their module
  @test occursin("set_global_assignment -name SDC_FILE SocMax.sdc", qsf)
  @test occursin("INTERNAL_FLASH_UPDATE_MODE \"SINGLE COMP IMAGE\"", qsf)
  @test occursin("NUM_PARALLEL_PROCESSORS ALL", qsf)
  @test occursin("set_location_assignment PIN_27 -to clk_ref_i", qsf)
  @test occursin("create_clock -name {clk_ref_i}", read(joinpath(dir, "SocMax.sdc"), String))
  sh = read(joinpath(dir, "build.sh"), String)
  @test occursin("quartus_sh --flow compile Soc", sh)
  @test occursin("quartus_cpf -c -q 12.0MHz -g 3.3 -n p output_files/Soc.sof output_files/Soc.svf", sh)
  @test uperm(joinpath(dir, "build.sh")) & 0x01 != 0
  mk = read(joinpath(dir, "Makefile"), String)
  @test occursin("all: output_files/Soc.svf", mk) && occursin("\t./build.sh", mk)
  @test occursin("\topenFPGALoader -c usb-blaster output_files/Soc.svf", mk)
  @test occursin("\topenFPGALoader -c usb-blaster output_files/Soc.pof", mk)

  # the workspace can be named, and the cable chosen
  dir2 = mktempdir()
  Test.@test_logs match_mode = :any (:warn, r"") write(dir2, Soc, QuartzHDL._named(Quartus(SocMax; cable = "usb-blasterII"), :soc))
  @test isfile(joinpath(dir2, "src", "soc.v")) && isfile(joinpath(dir2, "soc.qsf")) && isfile(joinpath(dir2, "soc.qpf"))
  @test occursin("TOP_LEVEL_ENTITY soc", read(joinpath(dir2, "soc.qsf"), String))
  @test occursin("-c usb-blasterII output_files/soc.svf", read(joinpath(dir2, "Makefile"), String))
  f = QuartzHDL._onboard(QuartzHDL._named(Quartus(; overconstrain = 1.2), :blink), SocMax)
  @test (f.board, f.name, f.overconstrain, f.cable) == (SocMax, :blink, 1.2, "usb-blaster")

  @test_throws ArgumentError write(mktempdir(), Soc, Quartus())
  @test_throws ArgumentError Quartus(SocMax; overconstrain = 0)
  @test_throws "no such vendor netlist" write(mktempdir(), Soc, Quartus(SocMax; vendor = ["nope.v"]))
end
