# A small chip, three modules deep, with the parts of a real design that the
# single-module tests do not reach: a clock tree of black boxes, a RAM the vendor
# supplies, a pad that surfaces two levels up, a multicycle path inside a
# submodule, and a board with a directive of its own.

@blackbox CPLL begin
  clock(CLKI)
  input(STDBY::Bool)
  clockout(CLKOP, from = CLKI, divide = 1, enable = !stdby)
  clockout(CLKOS, from = CLKI, divide = 8, enable = !stdby)
end

@blackbox CMUX begin
  clock(CLK0, CLK1)
  input(SEL::Bool)
  clockout(DCMOUT, from = CLK0, enable = !sel)
  clockout(DCMOUT, from = CLK1, enable = sel)
end

@blackbox CRAM verilog="CHIP_RAM" begin
  input(WrAddress::Bits{8}, RdAddress::Bits{8}, Data::Bits{8}, WE::Bool)
  clock(RdClock, WrClock)
  output(Q::Bits{8})
end

QuartzHDL.standin(::Type{CRAM}) =
  RAM(256, 8; read = (clock = :rdclock, addr = :rdaddress, data = :q),
              write = (clock = :wrclock, addr = :wraddress, data = :data, we = :we))

@quartz struct SocLeaf
  @in en::Bool
  @in tick::Bool
  count::Bits{4} = 0
  @io  gp::Pad{4} = Pad{4}(:pulldown)
  @out seen::Bits{4} = 0
end

@on SocLeaf posedge(clk) begin
  tick && (count ← count + 1)
  seen ← gp
end

@wire SocLeaf gp ← ifelse(en, drive(count), release())

@quartz struct SocSub
  @in en::Bool
  @in tick::Bool
  @in d::Bits{8}
  @in we::Bool
  leaf::SocLeaf = SocLeaf()
  ram::CRAM = CRAM()
  addr::Bits{8} = 0
  slowsum::Bits{8} = 0
  slowcopy::Bits{8} = 0
  @out q::Bits{8} = 0
  @out leafseen::Bits{4} = 0
end

@wire SocSub begin
  leaf.clk ← clk
  leaf.en ← en
  leaf.tick ← tick
  ram.rdclock ← clk
  ram.wrclock ← clk
  ram.rdaddress ← addr
  ram.wraddress ← addr
  ram.data ← d
  ram.we ← we
end

@on SocSub posedge(clk) begin
  addr ← addr + 1
  slowsum ← slowsum + d
  slowcopy ← slowsum
  q ← ram.q
  leafseen ← leaf.seen
end

@multicycle SocSub 4 slowsum => slowcopy

@quartz struct Soc
  @in clk_ref::Bool
  @in clk_aux::Bool
  @in sb::Bool
  @in aux::Bool
  @in en::Bool
  @in d::Bits{8}
  @in we::Bool
  pll::CPLL = CPLL()
  mux::CMUX = CMUX()
  sub::SocSub = SocSub()
  tick::Bool = false
  n::Bits{8} = 0
  @io  gp::Pad{4} = Pad{4}(:pulldown)
  @out lsb::Bool = false
  @out q::Bits{8} = 0
  @out n_q::Bits{8} = 0
end

@wire Soc begin
  pll.clki ← clk_ref
  pll.stdby ← sb
  fast ← pll.clkop
  slow ← pll.clkos
  mux.clk0 ← slow
  mux.clk1 ← clk_aux
  mux.sel ← aux
  picked ← mux.dcmout
  sub.clk ← fast
  sub.en ← en
  sub.tick ← tick
  sub.d ← d
  sub.we ← we
end

@on Soc posedge(fast) begin
  tick ← clocklevel(:slow)                     # a derived clock, read as data, handed down
  lsb ← gp[0]                                  # the grandchild's pad, read at the top
  q ← sub.q
end

@on Soc posedge(picked) begin
  n ← n + 1
  n_q ← n
end

@board SocBoard begin
  device  = "LFE5U-45F"
  io      = :LVCMOS33
  clk_ref => (pin = "G2", osc = 48MHz)
  clk_aux => (pin = "H2", osc = 10MHz)
  sb      => (pin = 1,)
  aux     => (pin = 2,)
  en      => (pin = 3,)
  we      => (pin = 4,)
  d       => (pins = 10:17)
  gp      => (pins = 20:23, pull = :down)
  lsb     => (pin = 30,)
  q       => (pins = 40:47)
  n_q     => (pins = 50:57)
  raw = """
        BLOCK RESETPATHS ;
        BLOCK ASYNCPATHS ;
        """
end

const SOC_SCALE = (CPLL = (clkos = 2,),)

@testset "soc: three levels step as one" begin
  clks, every, internal, L = QuartzHDL.clockschedule(Soc, (clk_ref = 4, clk_aux = 1))
  @test internal == [:fast, :slow, :picked] && L == 4
  m = Soc()
  for i in 1:16
    m = QuartzHDL.stepslot(m, clks, every, internal, (i - 1) % L;
                           sb = false, aux = false, en = true, d = Bits{8}(i), we = true, gp = missing)
  end
  @test m.sub.addr == 16                             # the child ran on the PLL's clock
  @test m.sub.leaf.count == 8                        # the grandchild counted the fast edges the slow clock was high on
  @test m.sub.ram.model[0] == 1 && m.sub.ram.model[15] == 16   # the stand-in kept the writes
  @test m.n == 2 && m.n_q == 1                       # the muxed clock ran the counter at the top

  v = sprint(io -> write(io, Soc, Verilog()))
  @test count("endmodule", v) == 3
  @test occursin("SocSub sub(", v) && occursin("SocLeaf leaf(", v)
  @test occursin("CHIP_RAM ram(", v) && !occursin("CRAM ram(", v)   # the vendor's name, not ours
  @test occursin("inout wire [3:0] gp_io", v)                        # the pad surfaces at the top
  @test count("inout wire [3:0] gp_io", v) == 3                      # and at every level between
end

@testset "soc: co-simulated with a scaled clock tree and a vendor RAM" begin
  tree = joinpath(mktempdir(), "tree.v")
  simmodels(tree, Soc; scale = SOC_SCALE)
  t = read(tree, String)
  @test occursin("module CPLL (", t) && occursin("module CMUX (", t) && !occursin("CHIP_RAM", t)
  @test occursin("% 32'd2 == 32'd0", t) && !occursin("% 32'd8", t)  # scaled, on both sides
  sources = [tree, joinpath(@__DIR__, "ref", "chip_ram.v")]
  Random.seed!(81)
  stim(auxf) = [(sb = (i % 97) < 5, aux = auxf(i), en = rand(Bool), d = Bits{8}(rand(0:255)),
                 we = rand(Bool), gp = missing) for i in 1:1200]
  for auxf in (i -> false, i -> true)
    r = cosim(Soc, stim(auxf); clocks = (clk_ref = 4, clk_aux = 1), scale = SOC_SCALE,
              extra_sources = sources)
    @test r.ok skip=!HAVE_IVERILOG
    showmismatches(r)
  end
  # a switch of the mux is not an edge, whatever the two sources are doing at the
  # time: the counter on the muxed clock agrees over every slot of the sources'
  # cycle, going either way
  for k in 200:207, back in (false, true)
    r = cosim(Soc, stim(i -> (i >= k) != back); clocks = (clk_ref = 4, clk_aux = 1), scale = SOC_SCALE,
              extra_sources = sources)
    @test r.ok skip=!HAVE_IVERILOG
    showmismatches(r)
  end
end

@testset "soc: a simulation over the whole tree" begin
  clocks = @clocks begin
    clk_ref = 48MHz
    clk_aux = 10MHz, dithered
  end
  wiring = @wiring begin
    dut.en ← true                                      # an input bound to a constant
    dut.d  ← Bits{8}(0x5a)
  end
  sim = Simulation(Soc(); clocks, wiring, watch = "*")
  @test "sub.leaf.count" in [n.path for n in nets(sim)]
  @run sim begin
    sim.we = true
    advance_by(1us)                                    # 48 edges of the fast clock
  end
  @test sim["sub.addr"] == 48                          # dotted paths reach the child
  @test sim["sub.slowsum"] == Bits{8}(48 * 0x5a)       # fed by the wiring's constant
  @test sim["sub.leaf.count"] == 8                     # and the grandchild: 24 slow-high edges, in 4 bits
  @test sim["n"] == 6                                  # the muxed clock, divided by 8
  @test sim["gp"] == sim["sub.leaf.gp"] && sim["gp"][3] isa Bool   # one net, two names, a bit of it
  @run sim advance_by(5us)                             # the address wraps, so the RAM reads back
  @test sim["q"] == 0x5a
  before = sim["n"]
  @run sim begin
    sim.aux = true
    advance_by(1us)                                    # the mux hands the counter to the 10 MHz pin
  end
  @test 8 <= sim["n"] - before <= 12
  out = capture(sim)
  @test length(changes(out["sub.leaf.count"])) > 16
  @test out["n"][0.5us] == 3
end
