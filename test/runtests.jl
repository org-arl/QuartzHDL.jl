using Test, Random, QuartzHDL

const HAVE_IVERILOG = Sys.which("iverilog") !== nothing
HAVE_IVERILOG || @warn "iverilog is not on the PATH: co-simulation checks are skipped"
cosim(args...; kwargs...) = HAVE_IVERILOG ? QuartzHDL.cosim(args...; kwargs...) : (ok = missing, mismatches = [])

# what a co-simulation disagreed on, where there is anything to see
showmismatches(r) = isempty(r.mismatches) || println("first mismatches: ", r.mismatches[1:min(5, end)])

@testset "Bits and SBits semantics" begin
  @test Bits{8}(255) + 1 == Bits{8}(0)
  @test Bits{8}(3) + 1 isa Bits{8}
  @test Bits{4}(15) + Bits{4}(1) == Bits{4}(0)
  @test Bits{4}(3) + Bits{8}(10) isa Bits{8}
  @test_throws InexactError Bits{8}(3) + 300
  @test_throws ArgumentError Bits{8}(3) + SBits{8}(1)
  @test SBits{8}(-1) < SBits{8}(1)
  @test Bits{8}(0xff) > Bits{8}(1)
  @test SBits{8}(-2) >> 1 == SBits{8}(-1)
  @test Bits{8}(0x80) >> 1 == Bits{8}(0x40)
  @test Bits{8}(0x81) << 1 == Bits{8}(0x02)
  @test abs(SBits{8}(-5)) == SBits{8}(5)
  @test count_ones(Bits{127}(7)) == 3
  @test bitwidth(count_ones(Bits{127}(0))) == 7
  @test Bits{8}(0xa5)[0] == true
  @test Bits{8}(0xa5)[1:4] == Bits{4}(0x2)
  @test bits(true, Bits{4}(0x5), false) == Bits{6}(0b101010)
  @test bitrotate(Bits{4}(0b0011), 1) == Bits{4}(0b0110)
  @test bitrotate(Bits{4}(0b1001), 1) == Bits{4}(0b0011)
  @test SBits{9}(Bits{8}(0xff)) == SBits{9}(255)
  # narrowing drops bits, so it has to say so
  @test trunc(Bits{4}, SBits{8}(-1)) == Bits{4}(0xf)
  @test_throws ArgumentError Bits{4}(SBits{8}(-1))
  @test Bits{16}(Bits{8}(0xab)) == 0xab              # widening is always safe
end

@quartz struct Acc
  @in d::SBits{8}
  @in g::Bool
  @in rst::Bool = false
  @in en::Bool = true
  a::SBits{8} = 0
  p0::Pipeline{0,Bits{4}} = Pipeline{0,Bits{4}}()
  p1::Pipeline{1,SBits{9}} = Pipeline{1,SBits{9}}()
  p4::Pipeline{4,Bits{16}} = Pipeline{4,Bits{16}}()
  g::MetaGuard{1} = MetaGuard{1}(0)
  @out y::Bits{5} = 0
  @out s::SBits{9} = 0
  @out q::Bits{16} = 0
  @out b::Bool = false
  @out r::Bool = false
end

sq(x) = x * x

@on Acc posedge(clk) begin
  @reset(rst)
  @only_when(en)
  a <= a + d
  if a < 0 && g
    p0 <= Bits{4}(count_ones(a))
  elseif a > 3
    p1 <= SBits{9}(a) * 2 - abs(d)
  end
  p4 <= sq(Bits{16}(Bits{8}(a))) + bitrotate(Bits{16}(d[0:3]), 3) ⊻ bits(a[7], a[0], Bits{14}(7))
  y <= bits(isnew(p0), coalesce(p0, Bits{4}(0)))
  s <= coalesce(p1, -1)
  q <= coalesce(p4, Bits{16}(0)) >> 2
  b <= ismissing(p4) | isnew(p4)
  r <= isready(p1)
end

@quartz struct Duo
  @in d::Bits{8}
  @in rst::Bool = false
  cnt::Bits{8} = 0
  acc::Bits{12} = 0
  p::Pipeline{2,Bits{12}} = Pipeline{2,Bits{12}}()
  @out count::Bits{8} = 0
  @out total::Bits{12} = 0
end

@on Duo posedge(clk) begin
  @reset(rst)
  cnt <= cnt + d
  count <= cnt
end

@on Duo posedge(clk) begin
  @reset(rst)
  acc <= acc + Bits{12}(cnt)
  p <= acc ⊻ Bits{12}(d)
  total <= coalesce(p, Bits{12}(0))
end

@quartz struct Chain
  @in d::Bits{8}
  a::Bits{8} = 0
  @out c::Bool = false
end

@on Chain posedge(clk) begin
  if a <= 5
    a <= a + d + 1
  else
    a <= a + d
  end
  c <= a + d < a
end

@quartz struct Shifty
  @in sel::Bits{3} = 0
  @in d::Bits{8} = 0
  @in s::SBits{8} = 0
  mask::Bits{8} = 0
  up::Bits{8} = 0
  down::SBits{8} = 0
  @out big::Bool = false
end

@on Shifty posedge(clk) begin
  mask ← Bits{8}(1) << sel                  # a constant shifted by a register
  up ← d << 0x1                             # a hex literal as the count
  down ← s >> 0x2
  big ← d == big"200"
end

@testset "a shift count or a literal of any integer type" begin
  @test Bits{8}(12) << 0x1 == 24 && Bits{8}(12) >>> 0x1 == 6 && Bits{8}(12) >> UInt(2) == 3
  @test SBits{8}(-12) >> 0x1 == -6 && SBits{8}(-12) << UInt16(1) == -24
  m = step(Shifty(); sel = Bits{3}(5), d = Bits{8}(200), s = SBits{8}(-100))
  @test m.mask == 0b100000 && m.up == 0b10010000 && m.down == -25 && m.big
  Random.seed!(19)
  stim = [(sel = Bits{3}(rand(0:7)), d = Bits{8}(rand(0:255)), s = SBits{8}(rand(-128:127))) for _ in 1:200]
  @test cosim(Shifty, stim).ok skip=!HAVE_IVERILOG
end

@testset "chained <= and comparison position" begin
  m = Chain()
  m = step(m; d = Bits{8}(250))
  @test m.a == 251 && !m.c           # `m.a <= 5` in the if is a comparison, not a write
  m = step(m; d = Bits{8}(100))
  @test m.a == 95 && m.c             # `m.c <= m.a + d < m.a` is a write of the carry
  Random.seed!(3)
  stim = [(d = Bits{8}(rand(0:255)),) for i in 1:500]
  r = cosim(Chain, stim)
  @test r.ok skip=!HAVE_IVERILOG
end

@testset "simulation basics" begin
  m = Acc()
  m = step(m; d = SBits{8}(5), g = true, rst = true)
  @test m.a == 0
  m = step(m; d = SBits{8}(5), g = true)
  @test m.a == 5
  m = step(m; d = SBits{8}(-7), g = true, en = false)
  @test m.a == 5
  @test_throws ErrorException step(m)
  # a pipeline is ready when it holds a result and nothing is on its way through
  @test !isready(m.p1)
  m = step(m; d = SBits{8}(5), g = false)          # a = 5 > 3: p1 is written
  @test !isready(m.p1)
  m = step(m; d = SBits{8}(-100), g = false)      # a = 10: written again, the first comes out
  @test !isready(m.p1) && isnew(m.p1)
  m = step(m; d = SBits{8}(0), g = false)         # a = -90: nothing written, the second comes out
  @test isready(m.p1) && m.p1[] == 20 - 100 && m.r == false
  m = step(m; d = SBits{8}(0), g = false)
  @test isready(m.p1) && m.r
  @test_throws Exception @eval @quartz struct Bad
    x::Vector{Int} = Int[]
  end
end

@testset "acc random co-simulation" begin
  Random.seed!(1)
  stim = [(d = SBits{8}(rand(-128:127)), g = rand(Bool), rst = i < 3 || rand() < 0.02, en = rand() < 0.9) for i in 1:2000]
  r = cosim(Acc, stim)
  @test r.ok skip=!HAVE_IVERILOG
  showmismatches(r)
end

@testset "duo two-block co-simulation" begin
  Random.seed!(2)
  stim = [(d = Bits{8}(rand(0:255)), rst = i < 3 || rand() < 0.02) for i in 1:2000]
  r = cosim(Duo, stim)
  @test r.ok skip=!HAVE_IVERILOG
  showmismatches(r)
end

@testset "correlator example" begin
  include(joinpath(@__DIR__, "correlator.jl"))
  Random.seed!(4)
  code = [BARKER[k] ? 1 : -1 for k in 0:TAPS-1]
  xs = [rand(-20:20) for _ in 1:60]
  xs[31:43] .+= 100 .* reverse(code)                      # the code, oldest chip first
  m = Correlator()
  out = Int[]
  for x in xs
    m = step(m; x = SBits{8}(x))
    m.valid && push!(out, Int(m.mf))
  end
  pad = [zeros(Int, TAPS); xs]                            # the window starts empty
  ref = [sum(pad[n - k] * code[k + 1] for k in 0:TAPS-1) for n in TAPS+1:length(pad)]
  @test length(out) == 57                                 # three cycles of latency, then one a cycle
  @test out[1] == 0 && out[2:end] == ref[1:56]            # one sample behind the reference
  @test maximum(out) == sum(xs[31:43] .* reverse(code)) && argmax(out) == 44
  stim = [(x = SBits{8}(rand(-128:127)),) for _ in 1:300]
  @test cosim(Correlator, stim).ok skip=!HAVE_IVERILOG
end

VERSION >= v"1.12" || @warn "Julia $VERSION has no -m option: the app is not tested"
VERSION >= v"1.12" && @testset "app mode" begin
  dir = mktempdir()
  design = joinpath(dir, "design.jl")
  write(design, """
    using QuartzHDL
    @quartz struct Blinker
      n::Bits{4} = 0
      @out led::Bool = false
    end
    @on Blinker posedge(clk) begin
      n <= n + 1
      led <= n[3]
    end
    """)
  proj = dirname(@__DIR__)
  julia = joinpath(Sys.BINDIR, "julia")
  # --startup-file=no: a user startup.jl may `using` a package the test env cannot see
  julia = `$julia --startup-file=no`
  run(`$julia --project=$proj -m QuartzHDL $design --outdir $dir`)
  @test isfile(joinpath(dir, "Blinker.v"))
  out = joinpath(dir, "b.v")
  run(`$julia --project=$proj -m QuartzHDL $design --top Blinker -o $out --name blink`)
  @test occursin("module blink", read(out, String))

  # the emitter is named, with its options spelt as QuartzHDL spells them
  run(`$julia --project=$proj -m QuartzHDL $design --top Blinker --emit "Verilog(suffix = false)" -o $out`)
  @test occursin("input wire clk,", read(out, String))
  @test !success(`$julia --project=$proj -m QuartzHDL $design --emit Nonsense --outdir $dir`)

  # a board in the design file gives the constraint file too, beside the Verilog
  boarded = joinpath(dir, "boarded.jl")
  write(boarded, read(design, String) * """
    @board Demo begin
      device = "LFE5U-45F"
      io     = :LVCMOS25
      clk => (pin = 92, osc = 48MHz)
      led => (pin = 17)
    end
    """)
  run(`$julia --project=$proj -m QuartzHDL $boarded --top Blinker --board Demo --outdir $dir`)
  text = read(joinpath(dir, "Demo.lpf"), String)
  @test occursin("LOCATE COMP \"led_o\" SITE \"17\" ;", text)
  @test occursin("FREQUENCY NET \"clk_i\" 48.000000 MHz ;", text)
  @test !success(`$julia --project=$proj -m QuartzHDL $boarded --board Demo --outdir $dir`)

  # a Diamond workspace goes to a directory named after the module, or the one given
  run(`$julia --project=$proj -m QuartzHDL $boarded --top Blinker --board Demo --emit Diamond --outdir $dir`)
  @test isfile(joinpath(dir, "Blinker", "Blinker.ldf")) && isfile(joinpath(dir, "Blinker", "src", "Blinker.v"))
  ws = joinpath(dir, "ws")
  run(`$julia --project=$proj -m QuartzHDL $boarded --top Blinker --board Demo --emit Diamond -o $ws --name blink`)
  @test isfile(joinpath(ws, "blink.ldf")) && isfile(joinpath(ws, "Demo.lpf")) && isfile(joinpath(ws, "Makefile"))
  @test occursin("module blink", read(joinpath(ws, "src", "blink.v"), String))
  @test !success(`$julia --project=$proj -m QuartzHDL $boarded --top Blinker --emit Diamond -o $ws`)

  # a design of any size is split over files
  write(joinpath(dir, "part.jl"), join([
    "@quartz struct Kid",
    "  @in d::Bits{4}",
    "  k::Bits{4} = 0",
    "  @out q::Bits{4} = 0",
    "end",
    "@on Kid posedge(clk) begin",
    "  k ← k + d",
    "  q ← k",
    "end"], "\n"))
  top = joinpath(dir, "top.jl")
  write(top, join([
    "using QuartzHDL",
    "include(joinpath(@__DIR__, \"part.jl\"))",
    "@quartz struct Boss",
    "  @in d::Bits{4}",
    "  kid::Kid = Kid()",
    "  @out y::Bits{4} = 0",
    "end",
    "@wire Boss begin",
    "  kid.clk ← clk",
    "  kid.d ← d",
    "end",
    "@on Boss posedge(clk) begin",
    "  y ← kid.q",
    "end"], "\n"))
  out2 = joinpath(dir, "boss.v")
  run(`$julia --project=$proj -m QuartzHDL $top --top Boss -o $out2`)
  v = read(out2, String)
  @test occursin("module Kid", v) && occursin("Kid kid(", v)
end

@testset "review regressions: Bits semantics" begin
  @test bits(Bits{4}(0), SBits{4}(-1)) == Bits{8}(0x0f)
  @test Bits{128}(typemax(UInt128)) != Bits{128}(0)
  @test Bits{128}(0) < Bits{128}(typemax(UInt128))
  @test Bits{8}(1) < typemax(UInt128)
  @test hash(Bits{128}(typemax(UInt128))) isa UInt
end

@quartz struct Wide
  @in d::Bool
  a::Bits{127} = 3
  b::Bits{128} = 0
  @out w::Bits{8} = 0
end

@on Wide posedge(clk) begin
  a <= a + 5
  b <= b + 3
  w <= bits(a == 21, b == 9, d, Bits{5}(a[0:4]))
end

@quartz struct LeafPipe
  @in d::Bits{8}
  @in g::Bool = false
  p::Pipeline{2,Bits{8}} = Pipeline{2,Bits{8}}()
  g::MetaGuard{2} = MetaGuard{2}(0)
  @out y::Bits{8} = 0
  @out guarded::Bool = false
end

@on LeafPipe posedge(clk) begin
  p <= d
  y <= coalesce(p, Bits{8}(0))
  guarded <= g
end

@testset "review regressions: co-simulation" begin
  Random.seed!(5)
  stim = [(d = rand(Bool),) for i in 1:200]
  r = cosim(Wide, stim)
  @test r.ok skip=!HAVE_IVERILOG

  stim = [(d = Bits{8}(rand(0:255)), g = rand(Bool)) for i in 1:500]
  r = cosim(LeafPipe, stim)
  @test r.ok skip=!HAVE_IVERILOG

  HAVE_IVERILOG && @test_throws "missing input d" cosim(LeafPipe, [(g = true,)])
end

@quartz struct NoInput
  n::Bits{4} = 0
  @out led::Bool = false
end

@on NoInput posedge(clk) begin
  n <= n + 1
  led <= n[3]
end

@testset "review regressions: no-input cosim" begin
  r = cosim(NoInput, [NamedTuple() for _ in 1:40])
  @test r.ok skip=!HAVE_IVERILOG
end

@quartz struct Combo
  @in d::Bits{8}
  @in rst::Bool = false  active=:low
  state::Bits{3} = 4
  busy::Bool = false
  cnt::Bits{20} = 0
  @out active::Bool = false
  @out rem::Bits{20} = 0
  @out quot::Bits{20} = 0
  @out sel::Bits{8} = 0
end

@on Combo posedge(clk) begin
  @reset(rst)
  cnt <= cnt + 1
  state <= state + d[0:2]
  busy <= d[7]
end

@wire Combo active <= busy | (state != 4)

@wire Combo begin
  rem <= cnt % 1000
  quot <= cnt ÷ 1000
  if busy
    sel <= d
  else
    sel <= Bits{8}(cnt[0:7])
  end
end

@testset "combinational outputs" begin
  m = Combo()
  @test m.active == false                    # struct default until the first step
  m = step(m; d = Bits{8}(0))
  @test m.active == false                    # state still 4, busy still false
  m = step(m; d = Bits{8}(0x81))
  @test m.state == 5 && m.active == true     # comb sees the state this edge produced
  @test m.rem == Bits{20}(2) && m.quot == Bits{20}(0)
  Random.seed!(31)
  r = cosim(Combo, [(d = Bits{8}(rand(0:255)), rst = i <= 2) for i in 1:500])
  @test r.ok skip=!HAVE_IVERILOG
  showmismatches(r)

  @test_throws Exception @eval @wire Combo cnt ← Bits{20}(0)
  @test_throws Exception @eval @wire Combo state ← Bits{3}(0)
  @test_throws Exception @eval @wire Combo begin
    @reset(x)
    active ← true
  end
end

@quartz struct HalfWrite
  @in d::Bits{8}
  @in sel::Bits{2}
  acc::Bits{32} = 0
  @out top::Bool = false
  @out data::Bits{32} = 0
end

@on HalfWrite posedge(clk) begin
  if sel == 0
    data[24:31] <= d
  elseif sel == 1
    data[16:23] <= d
  elseif sel == 2
    data[0:7] <= d
    data[8:15] <= d
  else
    data <= data << 1
  end
  data[3] <= d[0]                        # later write wins on bit 3 only
  acc <= acc + 1
  top <= data[31]
end

@testset "partial register writes" begin
  m = HalfWrite()
  m = step(m; d = Bits{8}(0xff), sel = Bits{2}(2))
  @test m.data == Bits{32}(0x0000ffff)
  m = step(m; d = Bits{8}(0xa0), sel = Bits{2}(0))
  @test m.data == Bits{32}(0xa000fff7)        # bit 3 cleared by d[0] == 0
  Random.seed!(32)
  r = cosim(HalfWrite, [(d = Bits{8}(rand(0:255)), sel = Bits{2}(rand(0:3))) for i in 1:500])
  @test r.ok skip=!HAVE_IVERILOG
  showmismatches(r)
end

@quartz struct Pads
  @in d::Bits{8}
  @in drv::Bool
  @in g::Bits{4}
  @in rst::Bool = false  active=:low
  @io  sda::Pad{1} = Pad{1}(:pullup)
  @io  bus::Pad{8} = Pad{8}()
  @io  gpio::Pad{4} = Pad{4}(:pulldown)
  dir::Bits{4} = 0
  val::Bits{4} = 0
  tx::Bits{8} = 0
  txmode::Bool = false
  @out seen::Bits{8} = 0
  @out sdain::Bool = false
  @out gpioin::Bits{4} = 0
end

@on Pads posedge(clk) begin
  @reset(rst)
  txmode <= drv
  tx <= d
  dir <= g
  val <= Bits{4}(d[0:3])
  seen <= bus
  sdain <= sda
  gpioin <= gpio
  if drv
    sda <= drive(false)                    # open drain: pull low or let go
  else
    sda <= release()
  end
  for i in 0:3
    gpio[i] <= ifelse(dir[i], drive(val[i]), release())
  end
end

@wire Pads bus <= ifelse(txmode, drive(tx), release())

@testset "pads" begin
  m = Pads()
  @test m.sda[] == true                        # undriven, pulled up
  @test m.gpio[] == Bits{4}(0)                  # undriven, pulled down
  @test_throws ErrorException m.bus[]          # undriven with no pull is not a value
  m = step(m; d = Bits{8}(0), drv = true, g = Bits{4}(0), bus = Bits{8}(0x5a))
  @test m.sda[] == false && string(m.sda) == "Pad{1}(0, pullup)"
  # bus has no pull, so two drivers disagreeing on it is a short; sda is pulled up,
  # where several drivers holding the line low is how the bus works
  m2 = step(Pads(); d = Bits{8}(0xff), drv = true, g = Bits{4}(0), bus = Bits{8}(0))
  @test_throws ErrorException step(m2; d = Bits{8}(0), drv = true, g = Bits{4}(0),
                                  bus = Bits{8}(0))
  @test step(m; d = Bits{8}(0), drv = true, g = Bits{4}(0), bus = Bits{8}(0),
             sda = true).sda[] == false

  Random.seed!(33)
  raw = [(d = Bits{8}(rand(0:255)), drv = rand(Bool), g = Bits{4}(rand(0:15)), rst = i <= 2,
          b = Bits{8}(rand(0:255)), gv = Bits{4}(rand(0:15))) for i in 1:500]
  stim = @NamedTuple{d::Bits{8}, drv::Bool, g::Bits{4}, rst::Bool,
                     bus::Tuple{Bits{8},Bits{8}}, gpio::Tuple{Bits{4},Bits{4}}}[]
  let m = Pads()
    for s in raw
      e = (d = s.d, drv = s.drv, g = s.g, rst = s.rst,
           bus = (s.b, Bits{8}(~m.bus.oe.val)), gpio = (s.gv, Bits{4}(~m.gpio.oe.val)))
      push!(stim, e)
      m = step(m; e...)
    end
  end
  r = cosim(Pads, stim)
  @test r.ok skip=!HAVE_IVERILOG
  showmismatches(r)
end

@quartz struct Edges
  @in d::Bits{8}
  half::Bits{8} = 0
  @out full::Bits{8} = 0
  @out n::Bits{8} = 0
end

@on Edges negedge(clk) begin
  half <= d
end

@on Edges posedge(clk) begin
  full <= half
  n <= n + 1
end

@quartz struct TwoClock
  @in d::Bits{8}
  fast::Bits{8} = 0
  slow::Bits{8} = 0
  @out fast_q::Bits{8} = 0
  @out slow_q::Bits{8} = 0
end

@on TwoClock posedge(clk) begin
  fast <= fast + d
  fast_q <= fast
end

@on TwoClock posedge(clk_slow) begin
  slow <= slow + 1
  slow_q <= fast
end

@testset "clock edges and clock domains" begin
  m = Edges()
  m = step(m; d = Bits{8}(7))
  @test m.half == 7 && m.full == 0           # the falling edge follows the rising one
  m = step(m; d = Bits{8}(9))
  @test m.half == 9 && m.full == 7
  Random.seed!(34)
  r = cosim(Edges, [(d = Bits{8}(rand(0:255)),) for i in 1:200])
  @test r.ok skip=!HAVE_IVERILOG

  @test_throws ErrorException step(TwoClock(); d = Bits{8}(1))
  r = cosim(TwoClock, [(d = Bits{8}(rand(0:255)),) for i in 1:400]; clocks = (clk = 4, clk_slow = 1))
  @test r.ok skip=!HAVE_IVERILOG
  showmismatches(r)
end

@testset "division and modulo by a constant" begin
  @test Bits{20}(123456) % 1000 == Bits{20}(456)
  @test Bits{20}(123456) ÷ 1000 == Bits{20}(123)
  @test SBits{16}(-7) % 2 == SBits{16}(-1)
  @test SBits{16}(-7) ÷ 2 == SBits{16}(-3)
  @test_throws ArgumentError Bits{8}(5) % 0
  @test_throws ArgumentError mod(SBits{8}(-5), 3)
end

@quartz struct Child
  @in d::Bits{8}
  @in rst::Bool = false  active=:low
  @in en::Bool = true
  n::Bits{8} = 0
  @out acc::Bits{8} = 0
  @out half::Bits{4} = 0
end

@on Child posedge(clk) begin
  @reset(rst)
  if en
    n <= n + d
    acc <= n
  end
end

@wire Child half <= Bits{4}(n[4:7])

@quartz struct Parent
  @in d::Bits{8}
  @in rst::Bool = false  active=:low
  a::Child = Child()
  b::Child = Child()
  t::Bits{8} = 0
  @out sum::Bits{8} = 0
  @out h::Bits{4} = 0
end

@on Parent posedge(clk) begin
  @reset(rst)
  t <= t + 1
  sum <= a.acc + b.acc
  h <= a.half
end

@wire Parent begin
  a.clk ← clk
  a.d ← d
  a.rst ← rst
  b.clk ← clk
  b.d ← a.acc
  b.rst ← rst
  b.en ← d[0]
end

@quartz struct PadChild
  @in hold::Bool
  @io  scl::Pad{1} = Pad{1}(:pullup)
  q::Bits{4} = 0
  @out seen::Bool = false
end

@on PadChild posedge(clk) begin
  q <= q + 1
  seen <= scl & !hold
end

@wire PadChild scl <= ifelse(q[0] & seen, drive(false), release())

@quartz struct SlowChild
  @in k::Bits{6}
  c::Bits{6} = 0
  @out out::Bits{6} = 0
end

@on SlowChild posedge(clk_slow) begin
  c <= c + k
  out <= c
end

@quartz struct Top
  @in hold::Bool
  kid::PadChild = PadChild()
  slow::SlowChild = SlowChild()
  z::Bits{6} = 0
  @out y::Bool = false
  @out s::Bits{6} = 0
end

@wire Top begin
  kid.clk ← clk
  kid.hold ← hold
  slow.clk_slow ← clk_slow
  slow.k ← z
end

@on Top posedge(clk) begin
  y <= kid.seen
  z <= z + 1
end

@on Top posedge(clk_slow) begin
  s <= slow.out
end

@testset "hierarchy" begin
  m = Parent()
  m = step(m; d = Bits{8}(3))
  @test m.a.n == 3 && m.b.n == 0                 # b is enabled by d[0] of this cycle
  @test m.sum == 0                             # parent read the children's old outputs
  m = step(m; d = Bits{8}(5))
  @test m.a.n == 8 && m.a.acc == 3
  @test m.a.acc == 3                           # submodule outputs read as fields
  Random.seed!(43)
  r = cosim(Parent, [(d = Bits{8}(rand(0:255)), rst = i <= 2) for i in 1:600])
  @test r.ok skip=!HAVE_IVERILOG
  showmismatches(r)

  v = sprint(io -> write(io, Parent, Verilog()))
  @test count("endmodule", v) == 2               # Child emitted once, then Parent
  @test occursin("Child a(", v) && occursin("Child b(", v)
  @test occursin(".en_i(1'h1)", v)                 # an unconnected input takes its default
end

@quartz struct Peeker
  @in d::Bits{8}
  a::Child = Child()
  @out y::Bits{8} = 0
end

@wire Peeker begin
  a.clk ← clk
  a.d ← d
end

@on Peeker posedge(clk) begin
  y <= a.n                               # reading a submodule's internal register
end

@testset "hierarchy: rules" begin
  @test_throws ErrorException sprint(io -> write(io, Peeker, Verilog()))
  @test_throws Exception @eval @on Peeker posedge(clk) begin
    @reset(rst)
    a ← step(a; d = d)
  end
end

@testset "hierarchy: pads and clock domains" begin
  Random.seed!(44)
  r = cosim(Top, [(hold = rand(Bool), scl = missing) for i in 1:400];
            clocks = (clk = 4, clk_slow = 1))
  @test r.ok skip=!HAVE_IVERILOG
  showmismatches(r)
  v = sprint(io -> write(io, Top, Verilog()))
  @test occursin("inout wire scl_io", v)         # the child's pad surfaces on the parent
  @test occursin(".scl_io(scl_io)", v)

  m = Top()
  m = step(m, :clk; hold = false, scl = false) # an external drive reaches the child
  @test m.kid.seen == false
  m = step(m, :clk; hold = false, scl = true)
  @test m.kid.seen == true
end

@quartz struct Forward
  @in d::Bool
  en::Bool = false
  @out n::Bits{8} = 0
end

@on Forward posedge(clk) begin
  @clockout(dac_sclk; invert = true)
  @clockout(adc_dclk; gate = en)
  en <= d
  n <= n + 1
end

@testset "clock forwarding" begin
  v = sprint(io -> write(io, Forward, Verilog()))
  @test occursin("output wire dac_sclk_o", v)
  @test occursin("assign dac_sclk_o = ~clk_i;", v)
  @test occursin("assign adc_dclk_o = clk_i & en;", v)
  Random.seed!(62)
  r = cosim(Forward, [(d = rand(Bool),) for i in 1:100])
  @test r.ok skip=!HAVE_IVERILOG                                     # forwarded clocks are not cycle values
end

@quartz struct Domain
  @in d::Bool
  @in on::Bool
  fw::Forward = Forward()
  live::Bool = false
  @io dac_sclk::Pad{1} = Pad{1}()
  @io adc_dclk::Pad{1} = Pad{1}()
end

@wire Domain begin
  fw.clk ← clk
  fw.d ← d
  dac_sclk ← ifelse(live, drive(fw.dac_sclk), release())
  adc_dclk ← ifelse(live, drive(fw.adc_dclk), release())
end

@on Domain posedge(clk) begin
  live ← on
end

@testset "a pad releases a child's forwarded clock with its power domain" begin
  v = sprint(io -> write(io, Domain, Verilog()))
  # the clockout stops lifting at the pad that absorbs it: the child keeps its
  # port, the parent wires it to the pad's tristate, the pin is the pad's
  @test occursin("inout wire dac_sclk_io", v)
  @test occursin("wire fw_dac_sclk;", v) && occursin(".dac_sclk_o(fw_dac_sclk)", v)
  @test occursin("assign dac_sclk_io = dac_sclk_padoe ? dac_sclk_padval : 1'bz;", v)
  @test count("output wire dac_sclk_o", v) == 1   # the child's own port, not a lifted copy
  Random.seed!(63)
  r = cosim(Domain, [(d = rand(Bool), on = rand(Bool)) for i in 1:200])
  @test r.ok skip=!HAVE_IVERILOG
end

struct Ram256
  mem::Vector{UInt16}
  q::Bits{16}
end
Ram256() = Ram256(zeros(UInt16, 256), Bits{16}(0))

@blackbox RAM256 begin
  input(WrAddress::Bits{8}, RdAddress::Bits{8}, Data::Bits{16}, WE::Bool)
  clock(WrClock, RdClock)
  output(Q::Bits{16})
end

# the harness says what the part does: a read on its read clock, a write on its
# write clock, so a read of the address being written sees the old word
QuartzHDL.standin(::Type{RAM256}) = Ram256()
function Base.step(r::Ram256, clock::Symbol; wraddress, rdaddress, data, we)
  clock === :rdclock && return Ram256(r.mem, Bits{16}(r.mem[Int(rdaddress) + 1]))
  we || return r
  mem = copy(r.mem)
  mem[Int(wraddress) + 1] = UInt16(Int(data))
  Ram256(mem, r.q)
end

@blackbox PLLX begin
  clock(CLKI)
  clockout(CLKOP, CLKOS)
  input(STDBY::Bool)
  pragma("syn_noprune=1")
end

@quartz struct Boxed
  @in sb::Bool
  @in d::Bits{16}
  @in we::Bool
  ram::RAM256 = RAM256()
  pll::PLLX = PLLX()
  addr::Bits{8} = 0
  @out q::Bits{16} = 0
end

@wire Boxed begin
  pll.clki ← clk_xtal
  clk ← pll.clkop
  clk_slow ← pll.clkos
  pll.stdby ← sb
  ram.wrclock ← clk
  ram.rdclock ← clk
  ram.wraddress ← addr
  ram.rdaddress ← addr
  ram.data ← d
  ram.we ← we
end

@on Boxed posedge(clk) begin
  addr <= addr + 1
  q <= ram.q
end

@testset "black boxes" begin
  m = Boxed()
  m = step(m, :clk; sb = false, d = Bits{16}(0x1234), we = true)
  m = step(m, :clk; sb = false, d = Bits{16}(0), we = false)
  @test m.ram.model.mem[1] == 0x1234
  m = step(m, :clk; sb = false, d = Bits{16}(0), we = false)
  @test m.q == 0                               # read of address 1, never written

  v = sprint(io -> write(io, Boxed, Verilog()))
  @test !occursin("module RAM256", v)            # a black box is instantiated, not defined
  @test occursin("RAM256 ram(", v)
  @test occursin(".WrClock(clk), .RdClock(clk)", v)
  @test occursin("wire clk;", v)                 # a clock a black box drives is internal
  @test occursin("wire clk_slow;", v)
  @test !occursin("input wire clk;", v)
  @test occursin(".CLKOP(clk), .CLKOS(clk_slow)", v)
  @test occursin("/* synthesis syn_noprune=1 */", v)
end

@quartz struct OpenDrain
  @in pull::Bool
  n::Bits{3} = 0
  @io  sda::Pad{1} = Pad{1}(:pullup)
  @out seen::Bool = false
end

@on OpenDrain posedge(clk) begin
  n <= n + 1
  seen <= sda
end

@wire OpenDrain sda <= ifelse(n[0], drive(false), release())

@testset "open-drain nets" begin
  m = OpenDrain()
  @test m.sda[] == true                          # released, pulled up
  m = step(m; pull = false, sda = missing)       # n becomes 1: the module pulls low
  @test m.sda[] == false
  @test step(m; pull = false, sda = false).sda[] == false   # both low is not a short
  m = step(m; pull = false, sda = missing)       # n becomes 2: the module lets go
  @test m.sda[] == true
  @test step(m; pull = false, sda = false).sda[] == false   # only the outside pulls
  Random.seed!(71)
  r = cosim(OpenDrain, [(pull = rand(Bool), sda = rand(Bool) ? missing : false) for i in 1:300])
  @test r.ok skip=!HAVE_IVERILOG
  showmismatches(r)
end

@quartz struct Gated
  @in d::Bits{8}
  @in sel::Bool = false
  v::Bits{8} = 7
  @out q::Bits{8} = 0
  @out r::Bits{8} = 0
end

@on Gated posedge(clk) begin
  v <= v + d
end

@wire Gated begin
  q <= ifelse(sel, v, Bits{8}(0))         # depends on an input port
  r <= v                                 # depends only on registers
end

@quartz struct ReadsGated
  @in d::Bits{8}
  g::Gated = Gated()
  @out y::Bits{8} = 0
end

@wire ReadsGated begin
  g.clk ← clk
  g.d ← d
  g.sel ← d[0]
end

@on ReadsGated posedge(clk) begin
  y <= g.q
end

@quartz struct ReadsPlain
  @in d::Bits{8}
  g::Gated = Gated()
  @out y::Bits{8} = 0
end

@wire ReadsPlain begin
  g.clk ← clk
  g.d ← d
  g.sel ← d[0]
end

@on ReadsPlain posedge(clk) begin
  y <= g.r
end

@testset "combinational outputs across a module boundary" begin
  # reading a submodule output that its @wire block computes from an input port
  # would be a cycle late in simulation while the Verilog wire is current
  @test_throws ErrorException sprint(io -> write(io, ReadsGated, Verilog()))
  v = sprint(io -> write(io, ReadsPlain, Verilog()))
  @test occursin("assign r_o = r;", v)
  Random.seed!(72)
  r = cosim(ReadsPlain, [(d = Bits{8}(rand(0:255)),) for i in 1:300])
  @test r.ok skip=!HAVE_IVERILOG
end

@quartz struct Echoer
  @in d::Bits{8}
  n::Bits{8} = 0
  @out out::Bits{8} = 0
end

@on Echoer posedge(clk) begin
  n <= n + 1
  out <= d + n
end

struct Doubler
  v::Bits{8}
end
Base.step(x::Doubler; d::Bits{8}) = Doubler(d + d)

@testset "bench" begin
  wiring = @wiring begin
    dut.d ← dbl.v
    dbl.d ← dut.out
  end
  clocks = @clocks begin
    clk = 48MHz
    dbl = 48MHz
  end
  b = Bench(Echoer(); clocks, wiring, dbl = Doubler(Bits{8}(1)))
  b = step(b)
  @test b.dut.out == 1 && b.stubs.dbl.v == 0   # both advanced from the old state
  b = step(b)
  @test b.dut.out == 1 && b.stubs.dbl.v == 2   # each saw the other's previous output
  t = history(b, 4)
  @test length(t) == 5 && t[1].dut.n < t[end].dut.n
  @test step(b, 3).dut.n == b.dut.n + 3

  # rates are absolute, so a run reports the time it covered
  @test time(step(b, 47)) == time(b) + 47//48000000

  # a stub may be a @quartz module, which then also emits Verilog for a Verilog bench
  qwiring = @wiring begin
    dut.d  ← echo.out
    echo.d ← dut.out
  end
  b2 = Bench(Echoer(); clocks = (@clocks begin clk = 48MHz; echo = 48MHz end),
             wiring = qwiring, echo = Echoer())
  b2 = step(b2, 5)
  @test b2.dut.n == 5 && b2.stubs.echo.n == 5
  @test occursin("module Echoer", sprint(io -> write(io, Echoer, Verilog())))

  # replacing a stub's state must not disturb where the schedule has got to, or
  # every clock slower than the fastest one would shift
  slow = @clocks begin
    clk = 48MHz
    dbl = 16MHz
  end
  b3 = Bench(Echoer(); clocks = slow, wiring, dbl = Doubler(Bits{8}(1)))
  b3 = step(b3, 2)
  b4 = QuartzHDL.setstub(b3, :dbl, Doubler(Bits{8}(9)))
  @test b4.stubs.dbl.v == 9
  @test b4.slot == b3.slot && b4.dut === b3.dut
  @test step(b4).stubs.dbl.v == 9                # the slow stub does not tick this slot

  # a clock whose rate does not divide the grid says so, and says what to do
  @test_throws Exception @clocks begin a = 48MHz; b = 10MHz end
  plan = @clocks begin a = 48MHz; b = 10MHz, dithered end
  let acc = ntuple(_ -> 0//1, length(plan.entries)), n = 0
    for slot in 0:4799
      mask, acc = QuartzHDL._tickers(plan, slot, acc)
      QuartzHDL._ticks((:a, :b), mask, :b) && (n += 1)
    end
    @test n == 1000                              # 10 MHz exactly, dithered onto a 48 MHz grid
  end

  # a simple plan needs no macro: a named tuple of rates says the same thing
  b5 = Bench(Echoer(); clocks = (clk = 48000000, dbl = 48000000), wiring,
             dbl = Doubler(Bits{8}(1)))
  @test b5.plan.grid == clocks.grid && [e.rate for e in b5.plan.entries] == [e.rate for e in clocks.entries]
  nt = QuartzHDL._asplan((a = 48000000, b = (10000000, :dithered), grid = 48000000))
  @test nt.entries[2].dithered && nt.grid == 1//48000000
  @test_throws ErrorException QuartzHDL._asplan((a = :fast,))
  @test_throws ErrorException Bench(Echoer(); clocks = "48MHz")
end

@quartz struct Latchy
  n::Bits{4} = 0
  @out y::Bits{4} = 0
end

@on Latchy posedge(clk) begin
  n <= n + 1
end

@wire Latchy begin
  if n[0]
    y <= n                               # no else: y would have to latch
  end
end

@testset "combinational blocks drive on every path" begin
  @test_throws ErrorException step(Latchy())
  @test_throws ErrorException sprint(io -> write(io, Latchy, Verilog()))
end

@quartz struct Chained
  @in d::Bits{8}
  v::Bits{8} = 1
  @out n::Bits{8} = 0
  @out a::Bits{8} = 0
  @out b::Bits{8} = 0
  @out z::Bits{8} = 0
end

@on Chained posedge(clk) begin
  v <= v + d
end

@on Chained negedge(clk) begin
  n <= a                               # the falling edge sees settled logic
end

@wire Chained a <= v + 1
@wire Chained b <= a + 1         # one block reads another's output

@wire Chained begin
  if v[0]
    z <= Bits{8}(1)
  else
    z <= Bits{8}(2)
  end
end

@testset "combinational settling" begin
  Random.seed!(81)
  r = cosim(Chained, [(d = Bits{8}(rand(0:255)),) for i in 1:300])
  @test r.ok skip=!HAVE_IVERILOG
  showmismatches(r)
  m = step(Chained(); d = Bits{8}(1))
  @test m.a == 3 && m.b == 4                 # settled in one step, not two
end

@quartz struct PadComb
  @io  sda::Pad{1} = Pad{1}(:pullup)
  @out seen::Bool = false
end

@on PadComb posedge(clk) begin
  sda <= release()
end

@wire PadComb seen <= sda

@quartz struct ReadsPad
  s::PadComb = PadComb()
  @out y::Bool = false
end

@wire ReadsPad s.clk ← clk

@on ReadsPad posedge(clk) begin
  y <= s.seen                          # continuous from a pad: a cycle late
end

@quartz struct Ctr{N}
  c::Bits{N} = 0
  @out q::Bits{N} = 0
end

@on Ctr{N} posedge(clk) begin
  c <= c + 1
  q <= c
end

@quartz struct TwoCtr
  a::Ctr{4} = Ctr{4}()
  b::Ctr{8} = Ctr{8}()
  @out y::Bits{8} = 0
end

@wire TwoCtr begin
  a.clk ← clk
  b.clk ← clk
end

@on TwoCtr posedge(clk) begin
  y <= b.q
end

@quartz struct FwdSub
  @out q::Bits{8} = 0
end

@on FwdSub posedge(clk) begin
  @clockout(dac_sclk; invert = true)
  q <= q + 1
end

@quartz struct FwdTop
  s::FwdSub = FwdSub()
  @out y::Bits{8} = 0
end

@wire FwdTop s.clk ← clk

@on FwdTop posedge(clk) begin
  y <= s.q
end

@testset "hierarchy: what a parent may read and emit" begin
  @test_throws ErrorException sprint(io -> write(io, ReadsPad, Verilog()))

  v = sprint(io -> write(io, TwoCtr, Verilog()))
  @test count("endmodule", v) == 3               # two widths, two modules
  @test occursin("module Ctr_8", v)
  r = cosim(TwoCtr, [NamedTuple() for i in 1:100])
  @test r.ok skip=!HAVE_IVERILOG

  v = sprint(io -> write(io, FwdTop, Verilog()))          # a forwarded clock reaches the pin
  @test occursin("output wire dac_sclk_o", v)
  @test occursin(".dac_sclk_o(dac_sclk_o)", v)
end

@quartz struct TwoWriters
  @in d::Bits{8}
  x::Bits{8} = 0
  @out y::Bits{8} = 0
end

@on TwoWriters posedge(clk) begin
  x <= d
end

@testset "one writer per register" begin
  # a block writing the same set of fields replaces the earlier one (re-including a
  # file must not duplicate blocks); a block that overlaps a different set is an error
  @test_throws Exception @eval @on TwoWriters posedge(clk) begin
    x ← d + 1
    y ← d
  end
  @test max(Bits{4}(15), Bits{8}(3)) isa Bits{8}    # width does not depend on the data
  @test max(Bits{4}(1), Bits{8}(3)) isa Bits{8}
  @test_throws ArgumentError QuartzHDL._asrange(-1)
  @test_throws ArgumentError QuartzHDL._asrange(-2:3)
end

@quartz mutable struct MutComb
  @in d::Bits{8}
  v::Bits{8} = 1
  @out y::Bits{8} = 0
end

@on MutComb posedge(clk) begin
  v <= v + d
end

@wire MutComb y <= v + 1

@quartz struct LateWrite
  @in d::Bits{8}
  v::Bits{8} = 0
  @out y::Bits{8} = 0
end

@on LateWrite posedge(clk) begin
  v <= v + d
end

@wire LateWrite begin
  if v[0]
    y <= Bits{8}(1)                         # covered by the write below
  end
  y <= Bits{8}(2)
end

@quartz struct SelfComb
  @in d::Bits{8}
  v::Bits{8} = 0
  @out y::Bits{8} = 0
end

@on SelfComb posedge(clk) begin
  v <= v + d
end

@wire SelfComb y <= y + 1

@quartz struct PadFromPort
  @in x::Bool
  @io  sda::Pad{1} = Pad{1}(:pullup)
  @out n::Bits{4} = 0
end

@on PadFromPort posedge(clk) begin
  n <= n + 1
end

@wire PadFromPort begin
  sda <= ifelse(x, drive(false), release())  # driven from a port, not a register
end

@quartz struct ConstReset
  @in d::Bits{8}
  @in rst::Bool = false  active=:low
  a::Bits{8} = 0
  @out y::Bits{8} = 0
end

@on ConstReset posedge(clk) begin
  @reset(rst; a = Bits{8}(7))
  a <= a + d
  y <= a
end

@testset "combinational corners" begin
  r = cosim(MutComb, [(d = Bits{8}(1),) for i in 1:50])
  @test r.ok skip=!HAVE_IVERILOG                                     # a mutable struct is not a loop
  r = cosim(LateWrite, [(d = Bits{8}(1),) for i in 1:50])
  @test r.ok skip=!HAVE_IVERILOG
  @test_throws ErrorException sprint(io -> write(io, SelfComb, Verilog()))
  @test_throws ErrorException step(SelfComb(); d = Bits{8}(1))
  r = cosim(PadFromPort, [(x = isodd(i),) for i in 1:50])
  @test r.ok skip=!HAVE_IVERILOG                                     # the pad follows the port this cycle
  r = cosim(ConstReset, [(d = Bits{8}(1), rst = i <= 3) for i in 1:50])
  @test r.ok skip=!HAVE_IVERILOG                                     # a reset override may be a constant
end

@quartz struct WriteOrder
  @in d::Bits{8}
  v::Bits{8} = 1
  @out a::Bits{8} = 0
  @out b::Bits{8} = 0
end

@on WriteOrder posedge(clk) begin
  v <= v + d
end

@wire WriteOrder begin
  b <= a + 1                           # reads a, which is written below
  a <= v + 1
end

@testset "combinational writes are not ordered" begin
  # a @wire block is a set of assigns, so a read sees the settled value whatever
  # order the writes appear in -- unlike Verilog's blocking `=`
  m = step(WriteOrder(); d = Bits{8}(0))
  @test m.v == 1 && m.a == 2 && m.b == 3
  Random.seed!(91)
  r = cosim(WriteOrder, [(d = Bits{8}(rand(0:255)),) for i in 1:200])
  @test r.ok skip=!HAVE_IVERILOG
end

@quartz struct BadOverride
  a::Bits{8} = 0
  @out y::Bits{8} = 0
end

@testset "reset overrides name fields" begin
  # an option this compiler does not have, or a typo, must not be taken for an
  # override of a field that does not exist and then quietly ignored
  @test_throws Exception @eval @on BadOverride posedge(clk) begin
    @reset(rst; async = true)
    a ← a + d
    y ← a
  end
end

@quartz struct Zeros
  a::Bits{5}
  b::Bool
  c::SBits{8} = -3
  p::Pipeline{2,Bits{4}}
  g::MetaGuard{2}
  @io  d::Pad{4}
  @out y::Bits{5}
end

@testset "field defaults and literal range" begin
  m = Zeros()
  @test m.a == 0 && m.b == false && m.c == -3 && ismissing(m.p[]) && m.g[] == false
  @test_throws Exception @eval @quartz struct TooBig
    x::Bits{5} = 99
  end
  @test convert(Bits{5}, 31) == 31
  @test_throws InexactError convert(Bits{5}, 32)
  @test Bits{5}(99) == 3                          # the explicit form still truncates
end

@testset "split is the inverse of bits" begin
  w = Bits{64}(0x1234_5678_9abc_def0)
  id, tag, pay = split(w, 4, 4, 56)
  @test id == 1 && tag == 2 && pay == 0x3456789abcdef0
  @test bits(id, tag, pay) == w
  @test_throws ArgumentError split(w, 4, 4)
end

@testset "hardware idioms" begin
  x = Bits{8}(0b00101100)
  @test firstset(x) == 0b100 && popcount(x) == 3
  @test leading_zeros(x) == 2 && trailing_zeros(x) == 2
  @test onehot(Bits{8}, Bits{3}(3)) == 8
  z = Bits{8}(0)
  @test firstset(z) == 0 && popcount(z) == 0
  @test leading_zeros(z) == 8 && trailing_zeros(z) == 8
end

@quartz struct Dyn
  @in d::Bits{8}
  @in w::Bits{64}
  @in sel::Bits{2}
  @out word::Bits{32}
  @out sl::Bits{8}
  @out fs::Bits{8}
  @out pc::Bits{4}
  @out lz::Bits{4}
  @out tz::Bits{4}
  @out oh::Bits{8}
  @out id::Bits{4}
  @out tag::Bits{4}
  @out pay::Bits{56}
end

@on Dyn posedge(clk) begin
  base = Bits{5}(sel) * 8
  word[base .+ (0:7)] <= d
  sl <= w[base .+ (0:7)]
  fs <= firstset(d)
  pc <= popcount(d)
  lz <= leading_zeros(d)
  tz <= trailing_zeros(d)
  oh <= onehot(Bits{8}, sel)
  i, t, body = split(w, 4, 4, 56)
  id <= i
  tag <= t
  pay <= body
end

@testset "dynamic part-selects and idioms match Verilog" begin
  # a base that runs off the end reads as zero here and as x in Verilog, so it is
  # refused rather than allowed to make the two worlds differ
  @test_throws ArgumentError Bits{32}(0)[Bits{6}(28) .+ (0:7)]
  Random.seed!(17)
  stim = [(d = Bits{8}(rand(0:255)), w = Bits{64}(rand(UInt64)), sel = Bits{2}(rand(0:3)))
          for i in 1:400]
  push!(stim, (d = Bits{8}(0), w = Bits{64}(0), sel = Bits{2}(0)))
  r = cosim(Dyn, stim)
  @test r.ok skip=!HAVE_IVERILOG
  @test occursin("+: 8", sprint(io -> write(io, Dyn, Verilog())))
end

@quartz struct Retained
  @in d::Bits{8}
  @in rst::Bool = false  active=:low
  @out keep::Bits{8}
  @out drop::Bits{8}
  @out set::Bits{8} = 7
end

@on Retained posedge(clk) begin
  @reset(rst; drop = Bits{8}(3))
  keep <= d
  drop <= d
  set <= d
end

@testset "a field with no default is not reset" begin
  m = step(Retained(); d = Bits{8}(42))
  m = step(m; d = Bits{8}(9), rst = true)
  @test m.keep == 42 && m.set == 7 && m.drop == 3
  Random.seed!(23)
  r = cosim(Retained, [(d = Bits{8}(rand(0:255)), rst = !(i > 2 && rand() > 0.1))
                       for i in 1:300])
  @test r.ok skip=!HAVE_IVERILOG
end

@quartz struct Discard
  @in d::Bits{8}
  @in en::Bool
  v::Bits{8}
  @out y::Bits{8}
end

@testset "a statement that discards its value is flagged" begin
  # a comparison as a statement computes something and throws it away; only a write
  # on the right of the `&&` makes the shape mean anything
  @test_logs (:warn, r"discards it") match_mode=:any @eval @on Discard posedge(clk) begin
    en && (v == d)
    y <= v
  end
  # a log statement or a @check on the right is a statement too, so the shape is
  # the same one-line `if` a guarded write is, and nothing is discarded
  @test_logs min_level = Base.CoreLogging.Warn @eval @on Discard posedge(clk) begin
    en && @info "enabled" d
    en || @debug "idle"
    en && @check v ≤ d
    y <= v
  end
end

@quartz struct Guarded
  @in d::Bits{8}
  @in en::Bool
  @in go::Bool
  a::Bits{8}
  b::Bits{8}
  c::Bits{8}
  @out y::Bits{8}
end

@on Guarded posedge(clk) begin
  en && (a ← d)
  en || (b ← d)
  en && go && (c ← c + 1)
  y ← a + b + c
end

@testset "a guarded write is an if" begin
  m = step(Guarded(); d = Bits{8}(7), en = true, go = true)
  @test m.a == 7 && m.b == 0 && m.c == 1
  m = step(m; d = Bits{8}(9), en = false, go = true)
  @test m.a == 7 && m.b == 9 && m.c == 1
  m = step(m; d = Bits{8}(3), en = true, go = false)
  @test m.a == 3 && m.b == 9 && m.c == 1
  Random.seed!(31)
  r = cosim(Guarded, [(d = Bits{8}(rand(0:255)), en = rand(Bool), go = rand(Bool)) for _ in 1:300])
  @test r.ok skip=!HAVE_IVERILOG
end

@quartz struct Declared
  @in d::Bits{8}
  @in en::Bool = true
  n::Bits{8}
  @out y::Bits{8}
  @io  p::Pad{4} = Pad{4}(:pullup)
end

@on Declared posedge(clk) begin
  if en
    n <= n + d
  end
  y <= n
  p <= ifelse(en, drive(n[0:3]), release())
end

@testset "the interface is declared, not inferred" begin
  ports = interface(Declared)
  @test [(p.name, p.dir) for p in ports] ==
        [(:d, :in), (:en, :in), (:y, :out), (:p, :pad)]
  @test QuartzHDL.outputs(Declared) == [:y]
  @test !hasfield(Declared, :d)                # an input is declaration only

  v = sprint(io -> write(io, Declared, Verilog()))
  @test occursin("input wire [7:0] d_i", v) && occursin("input wire en_i", v)
  @test occursin("output wire [7:0] y_o", v)

  Random.seed!(29)
  r = cosim(Declared, [(d = Bits{8}(rand(0:255)), en = rand(Bool), p = missing)
                       for i in 1:300])
  @test r.ok skip=!HAVE_IVERILOG

  # a name that is not declared would otherwise become a port nothing ever drives
  @test_throws Exception @eval @on Declared posedge(clk) begin
    n <= typo
  end
end

@quartz struct BadIface
  n::Bits{8}
  y::Bits{8}
end

@testset "declarations and fields must agree" begin
  # a mismarked port, a pad left undeclared, an input sharing a field name
  @test_throws Exception @eval @quartz struct WrongKind
    @io  n::Bits{8}
  end
  @test_throws Exception @eval @quartz struct BarePad
    p::Pad{4} = Pad{4}()
  end
  @test_throws Exception @eval @quartz struct Clash
    @in n::Bits{8}
    n::Bits{8}
  end
  # a metaguard is the exception: the argument that feeds it shares its name
  @test (@eval @quartz struct GuardedInput
    @in x::Bool
    x::MetaGuard{2}
    @out y::Bool
  end) isa Type
  # an output no longer follows from the name
  @test isempty(QuartzHDL.outputs(BadIface))
  # Int and UInt are the machine's width, which is not a fact about the hardware
  @test_throws Exception QuartzHDL._portinfo(Int)
  @test_throws Exception QuartzHDL._portinfo(UInt)
  @test_throws Exception QuartzHDL._portinfo(Integer)
  @test QuartzHDL._portinfo(UInt8) == (8, false)
  @test QuartzHDL._portinfo(Bits{12}) == (12, false)
end

@encoding Phase begin
  IDLE = 0
  RUN  = 1
  HOLD = 2
  DONE = 3
end

@encoding Onehot encoding = :onehot begin A; B; C end
@encoding Grey encoding = :gray begin P; Q; R; S end

@testset "named encodings" begin
  @test Phase.IDLE == 0 && Phase.DONE == 3 && bitwidth(Phase) == 2
  @test keys(Phase) == (:IDLE, :RUN, :HOLD, :DONE)
  @test encname(Phase, Bits{2}(2)) == :HOLD && encname(Phase, Bits{2}(3)) == :DONE
  @test [Onehot.A, Onehot.B, Onehot.C] == [1, 2, 4] && bitwidth(Onehot) == 3
  @test [Grey.P, Grey.Q, Grey.R, Grey.S] == [0, 1, 3, 2]
  @test_throws Exception Phase.NOPE
  @test_throws Exception @eval @encoding Dup begin A = 1; B = 1 end
  @test_throws Exception @eval @encoding TooNarrow::Bits{1} begin a = 0; b = 3 end
end

macro bump(field)                              # a user macro that writes a register
  esc(:($field ← $field + 1))
end

@quartz struct Fsm
  @in go::Bool
  state::Phase = IDLE
  n::Bits{8}
  @out y::Bits{8}
  @out st::Bits{2}
end

@on Fsm posedge(clk) begin
  @fsm state begin
    @state IDLE
      if go
        state ← RUN
        n ← 0
      end
    @state RUN
      @bump n
      if n == 5
        state ← HOLD
      end
    @otherwise
      state ← (go ? HOLD : IDLE)
  end
  y ← n
  st ← state
end

@testset "state machines" begin
  seq = Symbol[]
  m = Fsm()
  for i in 1:10
    m = step(m; go = i < 8)
    push!(seq, encname(Phase, m.state))
  end
  @test seq == [:RUN, :RUN, :RUN, :RUN, :RUN, :RUN, :HOLD, :IDLE, :IDLE, :IDLE]

  v = sprint(io -> write(io, Fsm, Verilog()))
  @test occursin("case (state)", v)            # a chain on one value emits as a case
  @test occursin("Phase_IDLE: begin", v) && occursin("default: begin", v)
  @test occursin("localparam [1:0] Phase_RUN = 2'h1;", v)   # the states are named
  @test occursin("state <= Phase_RUN;", v)

  Random.seed!(37)
  r = cosim(Fsm, [(go = rand(Bool),) for i in 1:400])
  @test r.ok skip=!HAVE_IVERILOG

  # the checks a hand-written if/elseif chain cannot have
  @test_throws Exception @eval @on Fsm posedge(clk2) begin
    @fsm state begin
      @state IDLE
        n ← 1
      @state NOPE                              # not a state of this encoding
        n ← 2
    end
  end
  @test_throws Exception @eval @on Fsm posedge(clk3) begin
    @fsm state begin
      @state IDLE                              # the other three have no branch
        n ← 1
    end
  end
  @test_throws Exception @eval @on Fsm posedge(clk4) begin
    @fsm state begin
      @state IDLE
        n ← 1
      @state IDLE                              # twice
        n ← 2
    end
  end
  @test_throws Exception @eval @on Fsm posedge(clk5) begin
    @fsm n begin                               # n has no encoding
      @state IDLE
        n ← 1
    end
  end
end

@quartz struct Writer
  @in go::Bool = false
  @in nack::Bool = false
  @in z::Bits{8} = 0
  step::Bits{4} = 0
  x::Bits{8} = 0
  y::Bits{8} = 0
  @out busy::Bool
end

@on Writer posedge(clk) begin
  @sequence Xfer step begin
    @when go
    x ← y
    @then SEND
    y ← z
    @repeat 4 begin
      y ← y + 1
      nack && @goto START
    end
    @delay 2
    @then @when z == 5
    x ← 4
  end
  busy ← step != Xfer.START
end

@testset "sequences" begin
  @test collect(keys(Xfer)) == [:START, :SEND, :step_2, :step_3, :step_4, :step_5, :step_6, :step_7, :step_8]
  @test QuartzHDL.sequences(Writer)[:step] === Xfer

  m = Writer()
  seq = Symbol[]
  busy = Bool[]
  for i in 1:14
    m = step(m; go = i == 2, z = Bits{8}(i == 12 ? 5 : 7))
    push!(seq, encname(Xfer, m.step)); push!(busy, m.busy)
  end
  @test seq == [:START, :SEND, :step_2, :step_3, :step_4, :step_5, :step_6, :step_7,
                :step_8, :step_8, :step_8, :START, :START, :START]   # START waits, step_8 waits
  @test busy == [i > 1 && seq[i-1] != :START for i in 1:14]   # busy is a register, a cycle behind
  @test m.x == 4 && m.y == 7 + 4

  m = Writer()
  seq = [(m = step(m; go = i == 1, nack = i == 4); encname(Xfer, m.step)) for i in 1:6]
  @test seq == [:SEND, :step_2, :step_3, :START, :START, :START]   # @goto START leaves the repeat

  v = sprint(io -> write(io, Writer, Verilog()))
  @test occursin("case (step)", v)
  @test occursin("localparam [3:0] Xfer_SEND = 4'h1;", v)
  @test occursin("Xfer_step_8: begin", v)
  @test occursin("default: begin\n          step <= Xfer_START;", v)   # an out-of-range value recovers

  Random.seed!(41)
  r = cosim(Writer, [(go = rand() < 0.2, nack = rand() < 0.1, z = Bits{8}(rand(0:8))) for _ in 1:2000])
  @test r.ok skip=!HAVE_IVERILOG

  @eval @quartz struct Narrow
    step::Bits{2} = 0
    n::Bits{8} = 0
  end
  @test_throws Exception @eval @on Narrow posedge(clk) begin
    @sequence Five step begin                    # five steps do not fit two bits
      n ← 1
      @delay 4
    end
  end
  @test_throws Exception @eval @on Writer posedge(clk2) begin
    @sequence Bad step begin
      @then START                                # START is the first step
      x ← 1
    end
  end
  @test_throws Exception @eval @on Writer posedge(clk3) begin
    @sequence Bad step begin
      @then SEND
      x ← 1
      @then SEND                                 # twice
      x ← 2
    end
  end
  @test_throws Exception @eval @on Writer posedge(clk4) begin
    @sequence Bad step begin
      x ← 1
      @when go                                   # not at the head of its step
      x ← 2
    end
  end
  @test_throws Exception @eval @on Writer posedge(clk5) begin
    @sequence Bad step begin
      if go
        @then                                    # a divider inside a statement
      end
    end
  end
  @test_throws Exception @eval @on Writer posedge(clk6) begin
    @sequence Bad step begin
      x ← 1
      @goto NOPE                                 # no such step
    end
  end
  @test_throws Exception @eval @on Writer posedge(clk7) begin
    @sequence Bad step begin
      @repeat 2 begin
        @then NAMED                              # unrolled steps have no names
        x ← 1
      end
    end
  end
  @test_throws Exception @eval @on Writer posedge(clk8) begin
    @sequence Bad x begin                        # x holds a sequence too, in another block
      x ← 1
    end
  end
  @test_throws Exception @eval @wire Writer begin
    @sequence Bad step begin                     # no clock
      x ← 1
    end
  end
end

@quartz struct Blink
  @in x::Bool = false
  @in period::Bits{4} = 3
  @out tick::Pulse
  @out n::Bits{8} = 0
  div::Timeout{4}
  hold::Timeout{4}
  xe::Edge
  @out rises::Bits{8} = 0
  @out falls::Bits{8} = 0
end

@on Blink posedge(clk) begin
  xe ← x
  rose(xe) && (rises ← rises + 1)
  fell(xe) && (falls ← falls + 1)
  if expired(div)
    div ← period                 # a divider: reload on expiry
    tick ← true
    n ← n + 1
  end
  rose(xe) && (hold ← 5)         # a one-shot: runs down and stays expired
end

@testset "fields that advance themselves" begin
  m = Blink()
  ticks = Bool[]; divs = Int[]; holds = Int[]
  for i in 1:12
    m = step(m; x = 4 <= i <= 8)
    push!(ticks, m.tick); push!(divs, Int(m.div)); push!(holds, Int(m.hold))
  end
  @test ticks == [true, false, false, false, true, false, false, false, true, false, false, false]
  @test divs == [3, 2, 1, 0, 3, 2, 1, 0, 3, 2, 1, 0]           # written 3, expired 4 edges later
  @test holds == [0, 0, 0, 0, 5, 4, 3, 2, 1, 0, 0, 0]          # holds at zero once run down
  @test m.rises == 1 && m.falls == 1                            # x rose once, fell once
  @test fieldtype(Blink, :tick) === Bool && fieldtype(Blink, :div) === Bits{4} && fieldtype(Blink, :xe) === Edge
  @test m.xe isa Edge && Bool(m.xe) == false && m.xe[] == false # the level, readable outside a block

  v = sprint(io -> write(io, Blink, Verilog()))
  @test occursin("tick <= 1'h0;", v) && occursin("tick <= 1'h1;", v)   # the clear, then the write that wins
  @test occursin("xe_prev <= xe;", v) && occursin("xe <= ", v)          # the history follows the level

  Random.seed!(3)
  r = cosim(Blink, [(x = rand(Bool), period = Bits{4}(rand(1:5))) for _ in 1:1500])
  @test r.ok skip=!HAVE_IVERILOG

  @test_throws Exception @eval @quartz struct NoInPulse
    @in p::Pulse                                   # an input has no storage
    y::Bool
  end
  @test_throws Exception @eval @quartz struct NoWidth
    t::Timeout                                       # needs a width
  end
  @eval @quartz struct Adv
    @in x::Bool
    t::Timeout{3}
    e::Edge
    @out y::Bool
  end
  @test_throws Exception @eval @wire Adv begin
    t ← 3                                          # a timer advances on a clock
    y ← expired(t)
  end
  @test_throws Exception @eval @on Adv posedge(clk) begin
    e[0] ← x                                       # an edge is written whole
  end
end

@quartz struct EdgeGate
  @in x::Bool = false
  @in en::Bool = true
  xe::Edge = false
  level::Bool = false
  @out nrose::Bits{8} = 0
  @out nfall::Bits{8} = 0
  @out now::Bool = false
end

@on EdgeGate posedge(clk) begin
  en && (xe ← x)                  # a gated sample: between samples the history still settles
  rose(xe) && (nrose ← nrose + 1)
  fell(xe) && (nfall ← nfall + 1)
  level ← xe                      # the bare name reads the level
  now ← isrising(xe, x)           # the same-cycle view of the sample being fed
end

@testset "an Edge is a register with history" begin
  m = EdgeGate()
  m = step(m; x=true, en=true);   @test m.now == true && m.nrose == 0
  m = step(m; x=true, en=false);  @test m.nrose == 1 && Bool(m.xe) && m.level == true
  m = step(m; x=true, en=false);  @test m.nrose == 1        # one cycle, gated feed or not
  m = step(m; x=false, en=false); @test m.nfall == 0        # the low sample is not taken yet
  m = step(m; x=false, en=true);  @test m.now == false
  m = step(m; x=false, en=false); @test m.nfall == 1
  m = step(m; x=false, en=false); @test m.nfall == 1 && m.level == false
  Random.seed!(7)
  @test cosim(EdgeGate, [(x = rand(Bool), en = rand(Bool)) for _ in 1:1500]).ok skip=!HAVE_IVERILOG

  @test m.xe isa Edge && m.xe[] == false
  @test Edge(true) == Edge(true, true) && rose(Edge(true, false)) && fell(Edge(false, true))
  @test_throws Exception rose(Bits{2}(1))                   # rose asks an Edge, not any register
  @test_throws Exception @eval @quartz struct NoInEdge
    @in e::Edge                                             # an input has no storage
    y::Bool
  end
  @test_throws Exception @eval @quartz struct NoOutEdge
    @out e::Edge                                            # a port carries a plain value
  end
  @test_throws Exception @eval @quartz struct BadEdgeStart
    e::Edge = 3                                             # an Edge starts from a Bool
  end
end

@quartz struct Bare
  @in d::Bits{8}
  n::Bits{8}
  @out y::Bits{8}
end

@on Bare posedge(clk) begin
  n ← n + d
  this.y ← n                          # both spellings mean the same field
end

@quartz struct ThisIn
  @in d::Bits{8}
  @in en::Bool
  n::Bits{8}
end

addend(m) = ifelse(m.en, m.d, Bits{8}(0))   # a helper reads an input through the state

@on ThisIn posedge(clk) begin
  n ← n + addend(this)
end

@testset "this and bare field names" begin
  m = step(step(Bare(); d = Bits{8}(3)); d = Bits{8}(4))
  @test m.n == 7 && m.y == 3
  Random.seed!(41)
  @test cosim(Bare, [(d = Bits{8}(rand(0:255)),) for i in 1:200]).ok skip=!HAVE_IVERILOG

  # an input read only through `this` is still a port, and still required
  m = step(step(ThisIn(); d = Bits{8}(3), en = true); d = Bits{8}(4), en = false)
  @test m.n == 3 && m.d == 4 && m.en == false
  @test_throws Exception step(ThisIn(); d = Bits{8}(1))
  @test occursin("input wire en_i", sprint(write, ThisIn, Verilog()))
  @test cosim(ThisIn, [(d = Bits{8}(i), en = isodd(i ÷ 3)) for i in 1:100]).ok skip=!HAVE_IVERILOG

  # a name that is both a field and a local would otherwise silently shadow, and
  # so would one that is both an input and a local
  @test_throws Exception @eval @on Bare posedge(clk9) begin
    n = d + 1
    y ← n
  end
  @test_throws Exception @eval @on Bare posedge(clk9) begin
    d = n + 1
    y ← d
  end
end

@quartz struct Leaf
  @in en::Bool  active=:low  verilog="en_ni"
  n::Bits{8}
  @out busy::Bool  active=:low  verilog="busy_no"
  @out q::Bits{8}
end

@on Leaf posedge(clk) begin
  if en
    n ← n + 1
  end
  busy ← n[0]
  q ← n
end

@quartz struct Holder
  @in go::Bool
  kid::Leaf = Leaf()
  @out y::Bool
  @out rd::Bool  active=:low  verilog="rd_no"
end

@wire Holder begin
  kid.clk ← clk
  kid.en ← go
end

@on Holder posedge(clk) begin
  y ← kid.busy
  rd ← go
end

@testset "active-low pins invert at the boundary" begin
  # in Julia the value always means asserted, whatever the pin does
  m = step(Leaf(); en = true)
  @test m.n == 1
  m = step(m; en = false)
  @test m.n == 1

  v = sprint(io -> write(io, Leaf, Verilog()))
  @test occursin("input wire en_ni", v) && occursin("wire en = ~en_ni;", v)
  @test occursin("output wire busy_no", v) && occursin("assign busy_no = ~busy;", v)
  @test !occursin("output reg busy", v)

  h = sprint(io -> write(io, Holder, Verilog()))
  @test occursin(".en_ni(~(go))", h)             # the parent holds the logical value
  @test occursin("wire kid_busy = ~kid_busy_pin;", h)

  Random.seed!(43)
  @test cosim(Leaf, [(en = rand(Bool),) for i in 1:200]).ok skip=!HAVE_IVERILOG
  Random.seed!(47)
  @test cosim(Holder, [(go = rand(Bool),) for i in 1:200]).ok skip=!HAVE_IVERILOG
end

@blackbox PLLT begin
  clock(CLKI)
  input(STDBY::Bool)
  clockout(CLKOP,  from = CLKI, divide = 1, enable = !stdby)
  clockout(CLKOS,  from = CLKI, divide = 4, enable = !stdby)
  clockout(CLKOS2, from = CLKI, divide = 4, phase = 2)
end

@blackbox MUX2 begin
  clock(CLK0, CLK1)
  input(SEL::Bool)
  clockout(DCMOUT, from = CLK0, enable = !sel)
  clockout(DCMOUT, from = CLK1, enable = sel)
end

@quartz struct Tree
  @in sb::Bool
  pll::PLLT = PLLT()
  a::Bits{8}
  b::Bits{8}
  c::Bits{8}
  @out a_q::Bits{8}
  @out b_q::Bits{8}
  @out c_q::Bits{8}
end

@wire Tree begin
  pll.clki ← clk
  fast ← pll.clkop
  slow ← pll.clkos
  odd ← pll.clkos2
  pll.stdby ← sb
end
@on Tree posedge(fast) begin
  a ← a + 1
  a_q ← a
end
@on Tree posedge(slow) begin
  b ← b + 1
  b_q ← b
end
@on Tree posedge(odd) begin
  c ← c + 1
  c_q ← c
end

@quartz struct Handstepped
  @in sb::Bool
  pll::PLLT = PLLT()
  @out q::Bits{8}
end

@testset "an instance is wired, never stepped" begin
  @test_throws ErrorException @eval @on Handstepped posedge(clk) begin
    pll ← step(pll; stdby = sb)
  end
  @test_throws ErrorException PLLT(clki = :clk)                 # a constructor does not wire
  @test_throws Exception @eval @wire Handstepped pll.clki ← !sb  # a clock is a net, not a value
  @test_throws Exception @eval @wire Handstepped begin           # and is wired unconditionally
    if sb
      pll.clki ← clk
    end
  end
  @test_throws Exception @eval @on Handstepped posedge(clk) begin
    pll.clki ← clk                                             # clocks are wired in @wire
  end
end

@testset "the clock tree is computed, not scheduled" begin
  t = QuartzHDL.blackbox(PLLT).tree
  @test [(c.name, c.from, c.divide, c.phase) for c in t] ==
        [(:clkop, :clki, 1, 0), (:clkos, :clki, 4, 0), (:clkos2, :clki, 4, 2)]

  edges = Vector{Symbol}[]
  m = Tree()
  for i in 1:10
    m = QuartzHDL._clearticks(m)
    m = step(m, :clk; sb = i in 4:6)
    push!(edges, QuartzHDL.clockedges(m))
  end
  # slower first: a clock that divides settles before the fast clock beside it, so a
  # design sampling it as data reads the new level
  @test edges[1] == [:slow, :fast]
  @test edges[3] == [:odd, :fast]
  @test edges[4] == Symbol[] && edges[6] == Symbol[]   # gated: no edges at all
  @test edges[7] == [:odd, :fast]                      # ungated phase keeps counting
  @test edges[8] == [:slow, :fast]                     # the gated counter held

  # the behavioural Verilog is generated from the same declarations, so the two
  # models of the tree are one description
  f = joinpath(mktempdir(), "tree.v")
  simmodels(f, Tree)
  v = read(f, String)
  @test occursin("module PLLT (", v) && occursin("n2_CLKOS % 32'd4 == 32'd0", v)
  # a part with no clock tree has no stand-in to generate, and is named in the message
  @test_throws "RAM256 declares no clock tree" QuartzHDL.simmodel(IOBuffer(), RAM256)
  r = cosim(Tree, [(sb = (i % 17) < 5,) for i in 1:300];
            clocks = (clk = 1,), extra_sources = [f])
  @test r.ok skip=!HAVE_IVERILOG
end

@quartz struct Muxed
  @in sel::Bool
  mux::MUX2 = MUX2()
  n::Bits{8}
  @out y::Bits{8}
end

@wire Muxed begin
  mux.clk0 ← clk
  mux.clk1 ← other_i
  picked ← mux.dcmout
  mux.sel ← sel
end
@on Muxed posedge(picked) begin
  n ← n + 1
  y ← n
end

@testset "a clock mux picks between two sources" begin
  m = QuartzHDL._clearticks(Muxed())
  m = step(m, :clk; sel = false)
  @test QuartzHDL.clockedges(m) == [:picked]
  m = QuartzHDL._clearticks(m)
  m = step(m, :other_i; sel = false)
  @test QuartzHDL.clockedges(m) == Symbol[]                      # the unselected source is dead
  m = QuartzHDL._clearticks(m)
  m = step(m, :other_i; sel = true)
  @test QuartzHDL.clockedges(m) == [:picked]
end

@quartz struct PadEn
  @in d::Bits{4}
  @in en::Bool
  n::Bits{4}
  @io  p::Pad{4} = Pad{4}(:pulldown)
  @out y::Bits{4}
end

@on PadEn posedge(clk) begin
  n ← d
  p ← drive(n, en)                          # one enable for the whole bus
  y ← p
end

@testset "a scalar pad enable spreads over the width" begin
  m = step(PadEn(); d = Bits{4}(0b1010), en = true, p = missing)
  for _ in 1:2
    m = step(m; d = Bits{4}(0b1010), en = true, p = missing)
  end
  @test m.y == 0b1010
  m = step(m; d = Bits{4}(0), en = false, p = missing)
  @test m.p[] == 0                            # released, and pulled down
  @test occursin("{4{en}}", sprint(io -> write(io, PadEn, Verilog())))
  Random.seed!(53)
  @test cosim(PadEn, [(d = Bits{4}(rand(0:15)), en = rand(Bool), p = missing)
                      for i in 1:200]).ok skip=!HAVE_IVERILOG
end

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

@testset "a board binds a design to pins" begin
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
  @test_throws Exception @eval MHz
  @test QuartzHDL._exact(32.768) == 32768//1000
end

@quartz struct Sampler
  pll::PLLT = PLLT()
  seen::Bits{8}
  @out y::Bits{8}
end

@wire Sampler begin
  pll.clki ← clk
  fast ← pll.clkop
  slow ← pll.clkos
  odd ← pll.clkos2
  pll.stdby ← false
end
@on Sampler posedge(fast) begin
  if clocklevel(:slow)                         # a clock net read as data
    seen ← seen + 1
  end
  y ← seen
end

@testset "a clock net can be read as data" begin
  # the tree makes a square wave, so a slow clock has a settled level between edges
  m = Sampler()
  levels = Bool[]
  for _ in 1:8
    m = QuartzHDL._clearticks(m)
    m = step(m, :clk)
    push!(levels, clocklevel(m, :slow))
  end
  @test levels == [true, true, false, false, true, true, false, false]

  f = joinpath(mktempdir(), "tree.v")
  simmodels(f, Sampler)
  Random.seed!(59)
  r = cosim(Sampler, [NamedTuple() for _ in 1:200];
            clocks = (clk = 1,), extra_sources = [f])
  @test r.ok skip=!HAVE_IVERILOG
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

@testset "constraints are generated, not maintained" begin
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

  # every rate follows from the oscillator and the dividers; nothing is retyped
  @test occursin("FREQUENCY NET \"clk_ref_i\" 48.000000 MHz ;", text)
  @test occursin("FREQUENCY NET \"fast\" 48.000000 MHz ;", text)
  @test occursin("FREQUENCY NET \"slow\" 12.000000 MHz ;", text)

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

@quartz struct Settling
  @in d::Bits{8}
  @in load::Bool
  @in rst::Bool = false
  a::Bits{8}
  b::Bits{8}
  prod::Multicycle{4,Bits{16}}
  @out y::Bits{16}
  @out ok::Bool
end

@wire Settling prod ← Bits{16}(a) * Bits{16}(b)

@on Settling posedge(clk) begin
  @reset(rst)
  if load
    a ← d
    b ← d + 1
  end
  ok ← isready(prod)
  isready(prod) && (y ← prod)
end

@quartz struct Hasty
  @in d::Bits{8}
  a::Bits{8}
  sq::Multicycle{3,Bits{16}}
  @out y::Bits{16}
end

@wire Hasty sq ← Bits{16}(a) * Bits{16}(a)

@on Hasty posedge(clk) begin
  a ← d
  y ← sq
end

@quartz struct Widths
  @in d::Bits{8}
  a::Bits{8}
  sq::Multicycle{3,Bits{16}}
  p::Pipeline{2,Bits{12}}
  @out w::Bits{8}
end

@wire Widths sq ← Bits{16}(a) * Bits{16}(a)

@on Widths posedge(clk) begin
  a ← d
  w ← bitwidth(sq) + bitwidth(p)
end

@quartz struct FromInput
  @in d::Bits{8}
  a::Bits{8}
  s::Multicycle{2,Bits{8}}
  @out y::Bits{8}
end

@wire FromInput s ← a + d

@on FromInput posedge(clk) begin
  a ← d
  isready(s) && (y ← s)
end

@quartz struct Timed2
  @in clk_ref::Bool
  pll::PLLT = PLLT()
  a::Bits{8}
  n::Bits{4}
  s::Multicycle{4,Bits{8}}
  @out y::Bits{8}
end

@wire Timed2 begin
  pll.clki ← clk_ref
  fast ← pll.clkop
  slow ← pll.clkos
  odd ← pll.clkos2
  pll.stdby ← false
end

@wire Timed2 s ← a * a

@on Timed2 posedge(fast) begin
  n ← n + 1
  n == 0 && (a ← a + 1)
  isready(s) && (y ← s)
end

@testset "a multicycle wire is a promise the simulator checks" begin
  m = Settling()
  m = step(m; d = Bits{8}(3), load = true)
  @test !isready(m.prod) && m.prod.val == 12
  for _ in 1:3
    m = step(m; d = Bits{8}(3), load = false)
  end
  @test isready(m.prod) && !m.ok           # ready after the fourth edge, seen by the block on the fifth
  m = step(m; d = Bits{8}(3), load = false)
  @test m.ok && m.y == 12
  # a write of the same value restarts the count, since that is what the Verilog counts
  @test !isready(step(m; d = Bits{8}(3), load = true).prod)
  @test isready(step(m; d = Bits{8}(3), load = false).prod)

  # the settle counter, the ready wire and the restart from the sources' writes
  v = sprint(io -> write(io, Settling, Verilog()))
  @test occursin("wire prod_ready = prod_settle == 2'h3;", v)
  @test occursin("assign prod = ", v)
  @test occursin("wire prod_restart = ", v) && occursin("if (prod_restart) prod_settle <= 2'h0;", v)
  @test occursin("wire p1_ready = p1_hasout & ~|p1_valid;", sprint(io -> write(io, Acc, Verilog())))
  Random.seed!(21)
  @test cosim(Settling, [(d = Bits{8}(rand(0:255)), load = rand() < 0.2, rst = i <= 2) for i in 1:300]).ok skip=!HAVE_IVERILOG

  # a read before its time is a design error, in the simulator only; asking the
  # width is not a read
  @test_throws ErrorException step(Hasty(); d = Bits{8}(1))
  @test step(Widths(); d = Bits{8}(1)).w == 16 + 12
  @test occursin("guard the read with isready(sq)", try step(Hasty(); d = Bits{8}(1)); "" catch e; e.msg end)

  # the path starts at a register of the module, so an input is refused
  @test_throws ErrorException sprint(io -> write(io, FromInput, Verilog()))
  @test occursin("reads d, which is not a register", try sprint(io -> write(io, FromInput, Verilog())); "" catch e; e.msg end)

  # a multicycle wire is driven continuously, never by a clocked block, and is not a port
  @test_throws Exception @eval @on Hasty posedge(clk) begin
    sq ← Bits{16}(a)
  end
  @test_throws Exception @eval @quartz struct Ported
    a::Bits{8}
    @out s::Multicycle{2,Bits{8}}
  end
  @test_throws ArgumentError Multicycle{1,Bits{8}}()

  # the constraint names every source and every sink, from the traced logic
  text = sprint(io -> write(io, Timed2, LPF(Lab)))
  @test occursin("MULTICYCLE FROM CELL \"a*\" CLKNET \"fast\" TO CELL \"y*\" CLKNET \"fast\" 4.000000 X ;", text)
  @test count("MULTICYCLE", text) == 4
end

@quartz struct Parts
  @in d::Bits{8}
  @in i::Bits{3}
  word::Bits{64}
  @out sel::Bits{8}
  @out top::Bits{8}
end

@on Parts posedge(clk) begin
  word[part(i, Bits{8})] ← d
  sel ← word[part(i, Bits{8})]
  top ← word[part(7, Bits{8})]
end

@testset "a part is numbered, not measured" begin
  m = Parts()
  for (k, v) in enumerate((0x11, 0x22, 0x33))
    m = step(m; d = Bits{8}(v), i = Bits{3}(k - 1))
  end
  @test m.word == 0x332211
  m = step(m; d = Bits{8}(0), i = Bits{3}(1))
  @test m.sel == 0x22

  # a part number known at compile time is an ordinary slice
  @test part(0, Bits{8}) == 0:7
  @test part(7, Bits{8}) == 56:63
  @test Bits{64}(0xfe00000000000000)[part(7, Bits{8})] == 0xfe

  @test Bits{64}(0xab00000000000000)[part(Bits{3}(7), Bits{8})] == 0xab

  # a computed part number is decoded over the parts, never multiplied into a +:
  # the synthesiser cannot see the alignment of
  text = sprint(io -> write(io, Parts, Verilog()))
  @test !occursin("+:", text)
  @test occursin("3'h6: word[55:48] <= d;", text)
  @test occursin("i == 3'h6 ? word[55:48] :", text)
  Random.seed!(37)
  r = cosim(Parts, [(d = Bits{8}(rand(0:255)), i = Bits{3}(rand(0:7))) for _ in 1:300])
  @test r.ok skip=!HAVE_IVERILOG
end

@quartz struct RawSlice
  @in b::Bits{3}
  @in d::Bits{8}
  word::Bits{16}
  @out y::Bits{4}
end

@on RawSlice posedge(clk) begin
  word ← d ⊞ d
  y ← word[b .+ (0:3)]
end

@testset "a base that is not a part number stays a +:" begin
  @test occursin("+: 4", sprint(io -> write(io, RawSlice, Verilog())))
  Random.seed!(38)
  r = cosim(RawSlice, [(d = Bits{8}(rand(0:255)), b = Bits{3}(rand(0:7))) for _ in 1:300])
  @test r.ok skip=!HAVE_IVERILOG
end

@quartz struct Ragged
  @in i::Bits{3}
  @in d::Bits{8}
  word::Bits{60}
  @out y::Bits{8}
end

@on Ragged posedge(clk) begin
  word[part(i, Bits{8})] ← d
  y ← word[part(i, Bits{8})]
end

@testset "a part that does not fit the word has no arm" begin
  text = sprint(io -> write(io, Ragged, Verilog()))
  @test occursin("3'h6: word[55:48] <= d;", text)
  @test !occursin("3'h7", text)
  @test_throws ArgumentError step(Ragged(); d = Bits{8}(1), i = Bits{3}(7))
  Random.seed!(39)
  r = cosim(Ragged, [(d = Bits{8}(rand(0:255)), i = Bits{3}(rand(0:6))) for _ in 1:300])
  @test r.ok skip=!HAVE_IVERILOG
end

@quartz struct Statics
  @in rst::Bool = false
  @in go::Bool = false
  count::Bits{8} = 5
  speed::Bits{8} = static(7)
  free::Bits{8}
  @out y::Bits{8} = 0
end

@on Statics posedge(clk) begin
  @reset(rst)
  go && (count ← count + 1; speed ← speed + 1; free ← free + 1)
  y ← count + speed + free
end

@quartz struct NoRst
  @in go::Bool = false
  lim::Bits{8} = 9
  @out y::Bits{8} = 0
end

@on NoRst posedge(clk) begin
  go && (lim ← lim + 1)
  y ← lim
end

@testset "a static default comes from the bitstream, not from reset" begin
  m = Statics()
  @test m.count == 5 && m.speed == 7 && m.free == 0
  m = step(m; go = true)
  m = step(m; rst = true)
  @test m.count == 5 && m.speed == 8 && m.free == 1

  t = sprint(io -> write(io, Statics, Verilog()))
  @test occursin("reg [7:0] speed = 8'h7;", t)   # the bitstream delivers it
  @test occursin("reg [7:0] count;", t)          # reset delivers this one
  @test occursin("reg [7:0] free;", t)           # zero needs no delivering
  arm = match(r"if \(rst\) begin(.*?)    end"s, t).captures[1]
  @test occursin("count <= 8'h5;", arm)
  @test !occursin("speed", arm) && !occursin("free", arm)

  # :all initializes everything, for a simulator that would otherwise start at x
  ta = sprint(io -> write(io, Statics, Verilog(; inits = :all)))
  @test occursin("reg [7:0] count = 8'h5;", ta) && occursin("reg [7:0] free = 8'h0;", ta)
  @test_throws ArgumentError Verilog(; inits = :sometimes)

  # a block with no @reset is static without saying so
  @test occursin("reg [7:0] lim = 8'h9;", sprint(io -> write(io, NoRst, Verilog())))

  Random.seed!(40)
  r = cosim(Statics, [(rst = i in 4:5, go = isodd(i)) for i in 1:60])
  @test r.ok skip=!HAVE_IVERILOG

  # what static refuses: a port, and a reset override
  @test_throws Exception @eval @quartz struct StaticPort
    @in a::Bits{8} = static(1)
  end
  @eval @quartz struct StaticOverride
    @in rst::Bool = false
    speed::Bits{8} = static(7)
    @out y::Bits{8} = 0
  end
  @test_throws Exception @eval @on StaticOverride posedge(clk) begin
    @reset(rst; speed = 1)
    y ← speed
  end
end

@testset "a shift that empties a value is a mistake" begin
  @test Bits{8}(1) << 7 == 0x80
  @test_throws ArgumentError Bits{8}(1) << 8
  @test_throws ArgumentError Bits{3}(1) << 3
  @test Bits{8}(1) >> 8 == 0        # a right shift of an unsigned value is not the same case
end

@quartz struct Clauses1
  @in d::Bits{8}
  @in en::Bool = true
  @in rst::Bool = false
  a::Bits{8}
  keep::Bits{8}
  @out y::Bits{8}
end

@on Clauses1 posedge(clk) begin
  @reset(rst; a = 3)
  @only_when en
  a ← a + d
  keep ← keep + 1
  y ← a
end

@testset "reset and enable are statements of the body" begin
  m = step(Clauses1(); d = Bits{8}(5))
  m = step(m; d = Bits{8}(5))
  @test m.a == 10 && m.keep == 2
  m = step(m; d = Bits{8}(5), en = false)
  @test m.a == 10 && m.keep == 2
  m = step(m; d = Bits{8}(5), rst = true)
  @test m.a == 3 && m.keep == 2      # keep has no default, so the reset leaves it
  Random.seed!(41)
  r = cosim(Clauses1, [(d = Bits{8}(rand(0:255)), en = rand(Bool), rst = rand() > 0.9)
                       for _ in 1:300])
  @test r.ok skip=!HAVE_IVERILOG

  # the clause is one thing, so saying it twice is a contradiction, not two clauses;
  # and a clause below a statement would read as running after it
  @test_throws Exception @eval @on Clauses1 posedge(clk) begin
    @reset rst
    @reset rst
    y ← d
  end
  @test_throws Exception @eval @on Clauses1 posedge(clk) begin
    y ← d
    @reset rst
  end
  @test_throws Exception @eval @wire Clauses1 begin
    @only_when true
    y ← 0
  end
  @test_throws Exception @eval @reset x
  @test_throws Exception @eval @on Clauses1 posedge(clk) begin
    @reset(rst; retain = (keep,))
    y ← d
  end
end

@quartz struct LowPad
  @in on::Bool = false
  @in listen::Bool = false
  @io  led::Pad{1} = Pad{1}(:pullup)  active=:low  verilog="led_no"
  @io  bus::Pad{4} = Pad{4}(:pulldown)  active=:low  verilog="bus_n"
  @io  btn::Pad{1} = Pad{1}(:pullup)  active=:low
  @out saw::Bool
end

@wire LowPad begin
  led ← drive(on)
  bus ← ifelse(listen, release(), drive(Bits{4}(5)))
  btn ← release()
end

@on LowPad posedge(clk) begin
  saw ← btn
end

@testset "an active-low pad inverts at the pin, and nowhere else" begin
  m = step(LowPad(); on = true, listen = false)
  @test m.led[]                                    # asserted, as the design sees it
  @test padnet(m, :led) == (Bits{1}(0), Bits{1}(1))  # a zero on the wire, as the board sees it
  @test m.bus[] == 5 && padnet(m, :bus)[1] == 10   # the driven value, inverted on the wire

  m = step(m; on = false, listen = false)
  @test !m.led[]
  @test padnet(m, :led) == (Bits{1}(1), Bits{1}(1))

  # released, the pullup holds the wire high, which for this pin means not asserted
  @test !m.btn[] && !m.saw
  m = step(m; on = false, listen = false, btn = (Bits{1}(0), Bits{1}(1)))
  @test m.btn[] && m.saw                         # someone pulled the pin down: asserted

  # a released pad on a pulled-down net reads all ones, since low is asserted here
  m = step(m; on = false, listen = true)
  @test m.bus[] == 15

  v = sprint(io -> write(io, LowPad, Verilog()))
  @test occursin("inout wire led_no", v)           # the pin keeps the name it has on the board
  @test occursin("inout wire [3:0] bus_n", v)
  @test occursin("assign led_no = led_padoe ? led_padval : 1'bz;", v)

  Random.seed!(43)
  r = cosim(LowPad, [(on = rand(Bool), listen = rand(Bool),
                      btn = (Bits{1}(rand(0:1)), Bits{1}(rand(0:1)))) for _ in 1:200])
  @test r.ok skip=!HAVE_IVERILOG
end

@quartz struct LowPins
  @in  en::Bool = false  active=:low
  @io  led::Pad{1} = Pad{1}(:pullup)  active=:low
  @out busy::Bool  active=:low
end

@wire LowPins begin
  led ← drive(en)
end

@on LowPins posedge(clk) begin
  busy ← en
end

@testset "a capture holds values and a waveform shows the wires" begin
  sim = Simulation(LowPins(); clocks = (clk = 1_000_000,), watch = "*")
  out = @run sim begin
    advance_by(2e-6)
    sim.en = true
    advance_by(2e-6)
  end
  wires(s) = [QuartzHDL._wirevalue(s, i) for i in eachindex(s.slots)]
  for name in ("en", "busy", "led")
    s = out[name]
    @test last.(changes(s)) == [false, true]      # asserted, as the design sees it
    @test wires(s) == [true, false]               # a zero on the wire, as a probe sees it
  end
  @test out.led[3e-6] && out.busy[3.5e-6] && sampled(out.busy)[end] == 1.0

  v = sprint(io -> write(io, out, VCD()))
  for (name, pat) in (("en", r"\$var wire 1 (\S+) en \$end"), ("busy", r"\$var wire 1 (\S+) busy \$end"),
                      ("led", r"\$var wire 1 (\S+) led \$end"))
    id = match(pat, v)[1]
    levels = [l[startswith(l, "b") ? 2 : 1] for l in split(v, '\n') if endswith(l, id) && !startswith(l, "\$")]
    @test levels[1] == '1' && levels[end] == '0'    # the dump is of the wires
  end

  # a clock is drawn as a square wave, falling halfway to its next tick, whatever its rate
  t, lv = QuartzHDL._clockwave(out.clk)
  @test lv[1:4] == [1, 0, 1, 0] && t[1:4] == [0, 1//2, 1, 3//2]
  @test count(==(1), lv) == 5 && t[end] == 4 + 1//2
  id = match(r"\$var wire 1 (\S+) clk \$end", v)[1]
  @test occursin("#500\n0$id", v) && occursin("#1000\n1$id", v)

  # a time axis is read in the unit that suits the span
  @test QuartzHDL._axisunit(2.5) == (1//1, "s") && QuartzHDL._axisunit(5e-3) == (1//10^3, "ms")
  @test QuartzHDL._axisunit(4e-6)[2] == "µs" && QuartzHDL._axisunit(300e-9)[2] == "ns"
  @test QuartzHDL._axisunit(1e-12)[2] == "ns"
  ms = QuartzHDL._axisunit(5e-3)
  @test QuartzHDL._ticklabel(0.01, ms) == "10ms" && QuartzHDL._ticklabel(0.00025, ms) == "0.25ms"
  @test QuartzHDL._ticklabel(0, ms) == "0ms" && QuartzHDL._ticklabel(1e-4, QuartzHDL._axisunit(1e-4)) == "100µs"
end

@quartz struct Continuous
  @in a::Bool = false
  @in b::Bits{8} = 0
  @io  io::Pad{1} = Pad{1}(:pullup)
  @out y::Bool
  @out z::Bits{8}
  @out saw::Bool
end

@wire Continuous begin
  y ← !a
  z ← b + 1
  io ← release()
  saw ← io
end

@testset "a module with no clock still settles every slot" begin
  # `step` and the slot the benches and co-simulation run on have to agree: a
  # module whose logic is all continuous has no edge to run, and used to come back
  # from a slot untouched, holding its defaults while the Verilog `assign` followed
  # its inputs
  clks, every, internal, _ = QuartzHDL.clockschedule(Continuous, nothing)
  for (a, b) in ((true, 7), (false, 0), (false, 255))
    direct = step(Continuous(); a = a, b = Bits{8}(b))
    slot = QuartzHDL.stepslot(Continuous(), clks, every, internal, 0; a = a, b = Bits{8}(b))
    @test direct.y == slot.y == !a
    @test direct.z == slot.z == Bits{8}(b) + 1
  end
  Random.seed!(47)
  r = cosim(Continuous, [(a = rand(Bool), b = Bits{8}(rand(0:255)),
                          io = (Bits{1}(rand(0:1)), Bits{1}(rand(0:1)))) for _ in 1:200])
  @test r.ok skip=!HAVE_IVERILOG
end

@quartz struct Polarities
  @in a::Bool = false
  @out low::Bool   active=:low  verilog="low_no"
  @out high::Bool  active=:high
end

@wire Polarities begin
  low ← a
  high ← a
end

@testset "a port attribute is checked where it is written" begin
  # the polarity used to be a bare word, and any bare word was accepted: one
  # letter wrong and the pin came out active-high with nothing said
  @test_throws Exception @eval @quartz struct BadAttr1
    @out y::Bool  active_lo = :low
  end
  @test_throws Exception @eval @quartz struct BadAttr2
    @out y::Bool  active = :lo
  end
  @test_throws Exception @eval @quartz struct BadAttr3
    @out y::Bool  active_low
  end

  v = sprint(io -> write(io, Polarities, Verilog()))
  @test occursin("assign low_no = ~low;", v)   # asserted low: bridged at the pin
  @test occursin("assign high_o = high;", v)                  # asserted high: the default, no bridge
  Random.seed!(53)
  r = cosim(Polarities, [(a = rand(Bool),) for _ in 1:100])
  @test r.ok skip=!HAVE_IVERILOG
end

@testset "a board setting is checked where it is written" begin
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
  @test occursin("FREQUENCY NET \"clk_ref_i\" 48.000000 MHz ;", text)
end

@quartz struct Methodical
  @in d::Bits{8}
  @in go::Bool
  a::Bits{8} = 0
  b::Bits{8} = 0
  @out y::Bits{8}
end

"adds `k` to `a` and takes it from `b`"
@method function both(k)
  a ← a + k
  b ← b - k
end
@method bump() = (a ← a + 1)
@method total() = a + b

@on Methodical posedge(clk) begin
  go && both(d)
  bump()
  y ← total()
end

@testset "a method is written as if inside the module" begin
  m = step(Methodical(); d = Bits{8}(5), go = true)
  @test m.a == 1 && m.b == 251 && m.y == 0   # both writes to a read the old a; the last wins
  m = step(m; d = Bits{8}(1), go = false)
  @test m.a == 2 && m.y == 252             # y saw the values before this edge
  @test occursin("adds `k`", string(@doc both))
  Random.seed!(61)
  r = cosim(Methodical, [(d = Bits{8}(rand(0:255)), go = rand(Bool)) for _ in 1:200])
  @test r.ok skip=!HAVE_IVERILOG

  # a method that writes has no value; a method the block cannot see yet is a
  # plain call, and says so when it runs
  @test_throws Exception @eval @on Methodical posedge(clk2) begin
    y ← bump()
  end
  @test_throws Exception both(Bits{8}(1))
end

@quartz struct Joined
  @in w::Bits{16}
  hi::Bits{4} = 0
  lo::Bits{8} = 0
  @out y::Bits{16}
  @out z::Bits{12}
  @io  p::Pad{4} = Pad{4}(:pulldown)
end

@on Joined posedge(clk) begin
  hi ⊞ _ ⊞ lo ← w                         # `_` takes what the others leave
  y ← hi ⊞ Bits{4}(0) ⊞ lo
  z[0:3] ⊞ z[4:11] ← w[4:15]
  p ← w[0:3]                               # a plain value drives every bit
end

@testset "⊞ joins on the right and splits on the left" begin
  @test Bits{4}(0xa) ⊞ true ⊞ Bits{3}(0b101) == Bits{8}(0b1010_1_101)
  m = step(Joined(); w = Bits{16}(0xabcd), p = missing)
  @test m.hi == 0xa && m.lo == 0xcd
  @test m.z[0:3] == 0xa && m.z[4:11] == 0xbc
  @test m.p[] == 0xd
  m = step(m; w = Bits{16}(0), p = missing)
  @test m.y == 0xa0cd
  Random.seed!(67)
  r = cosim(Joined, [(w = Bits{16}(rand(UInt16)), p = missing) for _ in 1:200])
  @test r.ok skip=!HAVE_IVERILOG
  @test_throws ArgumentError QuartzHDL._piece(Bits{16}(1), (4, 8), 1)       # 12 bits of 16
  @test_throws ArgumentError QuartzHDL._piece(Bits{8}(1), (4, nothing, 8), 2)
end

@quartz struct Valued
  @in x::Bool
  @in d::Bits{4}
  x::MetaGuard{2}
  g::MetaGuard{1}
  p::Pipeline{1,Bits{4}}
  @io  io::Pad{4} = Pad{4}(:pulldown)
  @out seen::Bits{4}
  @out b2::Bool
  @out synced::Bool
  @out fed::Bool
  @out q::Bits{4}
end

@on Valued posedge(clk) begin
  p ← d
  q ← coalesce(p, 0)
  io ← ifelse(d[0], drive(d), release())
  seen ← io
  b2 ← io[2]
  synced ← x                               # fed by the input of its own name
  g ← d[1]                                 # fed by hand
  fed ← g
end

@testset "a pad, a guard and a pipeline read as their value" begin
  m = Valued()
  for _ in 1:3
    m = step(m; x = true, d = Bits{4}(0b0111), io = missing)
  end
  @test m.seen == 0b0111 && m.b2 && m.synced && m.fed && m.q == 0b0111
  @test m.io[2] && m.io[0:1] == 0b11       # indexing a pad indexes the net
  Random.seed!(71)
  r = cosim(Valued, [(x = rand(Bool), d = Bits{4}(rand(0:15)), io = missing) for _ in 1:300])
  @test r.ok skip=!HAVE_IVERILOG
  @test_throws Exception @eval @on Valued posedge(clk2) begin
    q ← p[]                                # `[]` is not needed any more
  end
  v = sprint(io -> write(io, Valued, Verilog()))
  @test occursin("x_mg <= {x_mg[0:0], x};", v) && occursin("g_mg <= w", v)
end

"""
A counter with a named purpose.
"""
@quartz struct Documented
  "count up while high"
  @in en::Bool
  "the count"
  n::Bits{4} = 0
  "the count, a cycle late"
  @out q::Bits{4} = 0
  @out reg::Bool
end

@on Documented posedge(clk) begin
  "counts"
  en && (n ← n + 1)
  q ← n
  reg ← n[0]
end

@testset "documentation travels with the declaration" begin
  @test occursin("named purpose", string(@doc Documented))
  @test portdoc(Documented, :en) == "count up while high"
  @test portdoc(Documented, :q) == "the count, a cycle late"
  @test portdoc(Documented, :n) === nothing
  @test QuartzHDL.blocks(Documented)[1].doc == "counts"
  @test statedoc(Phase, :IDLE) === nothing

  # a port name is a net inside the module, so it cannot be a Verilog keyword
  @test_throws ErrorException sprint(io -> write(io, Documented, Verilog()))
end

@quartz struct Suffixed
  "goes in"
  @in a::Bool
  @out b::Bool
  @out c::Bool  active=:low
  @out d::Bool  verilog="dee"
end

@wire Suffixed begin
  b ← a
  c ← a
  d ← a
end

@testset "the pin carries the direction, unless it is named" begin
  v = sprint(io -> write(io, Suffixed, Verilog()))
  @test occursin("// goes in\n  input wire a_i", v)
  @test occursin("output wire b_o", v) && occursin("output wire c_no", v) && occursin("output wire dee", v)
  @test occursin("assign c_no = ~c;", v)
  v = sprint(io -> write(io, Suffixed, Verilog(; suffix = false)))
  @test occursin("input wire a,", v) && occursin("output wire b,", v) && occursin("output wire c_n,", v)
  @test occursin("output wire dee", v)
  Random.seed!(73)
  @test cosim(Suffixed, [(a = rand(Bool),) for _ in 1:50]; suffix = false).ok skip=!HAVE_IVERILOG
end

@encoding Mode begin idle; run; stop end

@quartz struct Driven
  @in enable::Bool = true
  @in rst::Bool = false
  @in limit::Bits{4} = 15
  cnt::Bits{4} = 0
  phase::Mode = idle
  @io sda::Pad{1} = Pad{1}(:pullup)
  @out led::Bool = false
end

@on Driven posedge(clk) begin
  @reset(rst; cnt = 0)
  @only_when(enable)
  cnt ← cnt + 1
  led ← cnt[3]
  cnt == 15 && @info "wrapped" cnt
  @check cnt ≤ limit
  @fsm phase begin
    @state idle
      phase ← run
    @state run
      if cnt == 15; phase ← stop; end
    @state stop
      phase ← idle
  end
end

# the unit names, for times written outside a @run body. Not at the top of the file:
# a test above checks that `MHz` means nothing where no macro has put it there.
using QuartzHDL.Units

@testset "a simulation is driven by name, and records what it is asked to" begin
  sim = Simulation(Driven(); clocks = (@clocks begin clk = 1MHz end), wiring = (@wiring begin end), watch = "*")
  @test Set(n.path for n in nets(sim)) == Set(["enable", "rst", "limit", "cnt", "phase", "sda", "led", "clocks.clk"])
  @test [n.kind for n in nets(sim, "phase", "sda", "clocks.*")] == [:fsm, :pad, :clock]
  @test sim["sda"] === true                      # pulled up, nobody driving
  @test sim.sda === true                         # and by name, outside a @run body
  out = @run sim begin
    sim.enable = true
    advance_by(20us)
    sim.enable = false
    advance_by(5us)
    sim.enable = true
    advance_until(sim.led)
    advance_by(3us)
  end
  @test out === capture(sim) && time(sim) == 33//1000000
  @test out.cnt[10us] == 10 && out.cnt[25us] == 4 && out.led[30us] === true
  @test changes(out.led) == [0.0 => false, 9e-6 => true, 1.7e-5 => false, 3e-5 => true]
  @test out.phase[0.5us] === :idle && out.phase[5us] === :run && out["phase"][16us] === :stop
  @test out.enable[22us] === false

  # a signal is typed by what its queries return, so changes and s[t] infer
  @test out.cnt isa QuartzHDL.Signal{Union{Missing,Bits{4}}}
  @test out.phase isa QuartzHDL.Signal{Union{Missing,Symbol,Bits{2}}}
  @test out.sda isa QuartzHDL.Signal{Union{Bool,String}}
  @test changes(out.led) isa Vector{Pair{Float64,Union{Missing,Bool}}}
  @test Base.infer_return_type(getindex, (typeof(out.cnt), Float64)) == Union{Missing,Bits{4}}
  x = sampled(out.led)
  @test length(x) == slots(out) + 1 && x[1] == 0.0 && x[10] == 1.0 && x[18] == 0.0 && QuartzHDL.frametime(x) == 1//1000000
  @test sampled(out.phase)[1:3] == [0.0, 1.0, 1.0] && isnan(sampled(out.sda)[1]) == false
  @test (@run sim sim.cnt) == 12                         # a value comes back as itself
  @test_throws ErrorException @run sim sim.led = true     # the design drives it
  @test_throws ErrorException @run sim sim.nothere = 1
  @run sim sim.sda = false
  @run sim advance_by(1us)
  @test sim["sda"] === false && out.sda[34us] === false

  # a task runs alongside the body and ends with it; a bare one outlives the call
  out = @run sim begin
    @task while true; advance_by(4us); sim.enable = !sim.enable; end
    advance_by(10us)
  end
  @test isempty(sim.tasks) && out.enable[40us] === false
  t = @run sim @task begin advance_by(100us); sim.rst = true; end
  @test length(sim.tasks) == 1
  @run sim advance_by(50us)
  @test sim["rst"] === false
  stop!(sim, t)
  @test isempty(sim.tasks)
  @test_throws ErrorException @run sim advance_until(sim.rst; timeout = 1us)

  # a check is the design's, and stops the run where it fails
  @run sim sim.limit = 10
  @test sim["limit"] == 10
  @test_throws QuartzHDL.CheckFailed @run sim begin sim.enable = true; advance_by(100us); end
  @run sim sim.limit = 15

  # the recording goes to a VCD with real time and named states
  io = IOBuffer()
  write(io, out, VCD())
  v = String(take!(io))
  @test occursin("\$timescale 1ns \$end", v) && occursin("\$scope module dut \$end", v)
  @test occursin("\$var string 1", v) && occursin("srun", v) && occursin("\$var wire 4", v)
  @test occursin("\$scope module clocks \$end", v) && occursin("#500\n0", v)
  # a scope holding nothing but stubs is never opened, so none is opened and closed
  @test !occursin(r"\$scope module \w+ \$end\n\$upscope", v)

  # nothing is watched unless asked; watch! adds, unwatch! takes away
  sim2 = Simulation(Driven(); clocks = (@clocks begin clk = 1MHz end))   # wiring defaults to nothing connected
  @test isempty(capture(sim2).signals)
  watch!(sim2, "led", "cnt")
  unwatch!(sim2, "cnt")
  @run sim2 advance_by(10us)
  @test length(capture(sim2)["cnt"]) == 1 && length(capture(sim2).led) == 2
  clear!(sim2)
  @test !haskey(capture(sim2).index, "cnt") && length(capture(sim2).led) == 1
  @test_throws ErrorException capture(sim2).cnt
  @test_throws ErrorException watch!(sim2)

  # reset! is the simulation as built
  t = @run sim2 @task advance_by(1s)
  reset!(sim2)
  @test time(sim2) == 0 && sim2["cnt"] == 0 && isempty(sim2.tasks) && length(capture(sim2).led) == 1

  # logging from the design is gated and carries the time, and the gate is the
  # simulation's own: what one hides, another still shows
  sim3 = Simulation(Driven(); clocks = (clk = 1MHz,))   # a named tuple is a one-line plan
  sim4 = Simulation(Driven(); clocks = (clk = 1MHz,))
  Test.@test_logs (:info, "wrapped") min_level = Base.CoreLogging.Info match_mode = :any begin
    @run sim3 advance_by(16us)
  end
  showlogs!(sim3; from = 1.0)
  Test.@test_logs min_level = Base.CoreLogging.Info begin
    @run sim3 advance_by(16us)
  end
  Test.@test_logs (:info, "wrapped") min_level = Base.CoreLogging.Info match_mode = :any begin
    @run sim4 advance_by(16us)
  end

  # the Verilog has the logs only when asked for
  v = sprint(io -> write(io, Driven, Verilog()))
  @test !occursin("\$display", v) && !occursin("\$error", v) && !occursin("wrapped", v)
  v = sprint(io -> write(io, Driven, Verilog(; debug = true)))
  @test occursin("\$display(\"%0t INFO Driven: wrapped cnt=%0d\", \$time, cnt);", v)
  @test occursin("\$error(\"Driven: check failed: cnt ≤ limit\");", v)
  @test cosim(Driven, [(enable = true, rst = false, limit = Bits{4}(15)) for _ in 1:40]).ok skip=!HAVE_IVERILOG
end

@quartz struct Mac
  @in a::Bits{16}, b::Bits{16}, c::Bits{16}, d::Bits{16}
  p::Pipeline{2,Bits{32}}
  wide::Pipeline{3,Bits{32}}
  @out y::Bits{32}
end

@on Mac posedge(clk) begin
  p ← Bits{32}(a) * Bits{32}(b) + Bits{32}(c) * Bits{32}(d)
  wide ← Bits{32}(a) * Bits{32}(b)
  y ← coalesce(p, 0) + coalesce(wide, 0)
end

@testset "pipeline stages" begin
  plan = stages(Mac, :p)
  @test plan.pathcost == 96 && [s.cost for s in plan.stages] == [64, 32] && isempty(plan.idle)
  @test [r.width for s in plan.stages for r in s.out] == [32, 32, 32]      # the products cross the cut, not the operands
  txt = sprint(show, MIME"text/plain"(), plan)
  @test occursin("t3 = t1 * t2", txt) && occursin("p = t3 + t6", txt) && occursin("total   96 + 36 = 132 flops", txt)
  wide = stages(Mac, :wide)
  @test wide.idle == [1, 2] && occursin("computes nothing", sprint(show, MIME"text/plain"(), wide))
  @test length(stages(Mac)) == 2
  @test_throws ErrorException stages(Mac, :nope)
  v = Test.@test_logs (:warn, r"wide of Mac: stage 1 of 3 computes nothing") (:warn, r"stage 2 of 3") sprint(io -> write(io, Mac, Verilog()))
  @test count("reg [31:0] p_p1_w", v) == 2
  Random.seed!(11)
  @test cosim(Mac, [(a = Bits{16}(rand(0:65535)), b = Bits{16}(rand(0:65535)), c = Bits{16}(rand(0:65535)), d = Bits{16}(rand(0:65535))) for _ in 1:100]).ok skip=!HAVE_IVERILOG
  @test stages(Acc, :p0).K == 0 && length(stages(Acc, :p1).stages) == 1 && length(stages(Acc, :p4).stages) == 4
end

@testset "inference" begin
  # what a run does every slot stays concretely typed; an instability here is a
  # design that allocates per slot, not just one that is slower
  m = Acc()
  @inferred step(m; d = SBits{8}(3), g = true)
  @inferred step(m, :clk; d = SBits{8}(3), g = true)
  @inferred step(Domain(); d = true, on = true)
  wiring = @wiring begin end
  clocks = @clocks begin clk = 1MHz end
  b = Bench(Driven(); clocks, wiring)
  @inferred step(b)
  @inferred step(b, 2)
  @inferred QuartzHDL._tickers(b.plan, 0, b.acc)
  sim = Simulation(Driven(); clocks, wiring, watch = "*")
  @inferred QuartzHDL._step!(sim)
  @inferred QuartzHDL._sample!(sim)
  @inferred QuartzHDL._nextwake(sim)
  @inferred QuartzHDL._chainget(sim.bench.dut, Val((:cnt,)))
  # a clockout is read through the net its bindings fix, not one looked up per pass
  @test @inferred(QuartzHDL._clockoutnet(Domain, Val(:fw), Val(:clk))) === Val(:clk)

  @inferred Bits{8}(3) + Bits{8}(4)
  @inferred SBits{8}(3) * SBits{9}(4)
  @inferred Bits{8}(3)[2]
  @inferred SBits{9}(-4) >> 2
  @inferred bits(true, Bits{4}(3))
  @inferred Bits{8}(3) ⊞ Bits{8}(4)
  @inferred part(3, Bits{4})
  @inferred static(Bits{8}(3))
  @inferred bitwidth(Bits{8}(3))
  @inferred firstset(Bits{8}(12))
  @inferred onehot(Bits{8}, 3)
  @inferred popcount(Bits{8}(12))

  a = step(step(m; d = SBits{8}(5), g = false); d = SBits{8}(5), g = false)
  @inferred Union{Missing,SBits{9}} a.p1[]
  @inferred isready(a.p1)
  @inferred isnew(a.p1)
  @inferred a.g[]
  @inferred Driven().sda[]
  @inferred padnet(Driven(), Val(:sda))
  @inferred netlevel(Driven(), Val(:sda), missing)
  @inferred clocklevel(Driven(), Val(:clk))

  out = capture(sim)
  # fetching a signal from the capture is the function barrier: the vector holds
  # every kind of net at once, so the fetch is abstract and all that follows is typed
  @test out["cnt"] isa QuartzHDL.Signal{Union{Missing,Bits{4}}}
  @inferred sampled(out.cnt)
  @inferred slots(out)
  @inferred sampled(out.cnt)[1]
  @inferred changes(out.cnt)
  @inferred Missing out.cnt[1.0e-6]
end

@quartz struct Reloaded
  n::Bits{4} = 0
end

@on Reloaded posedge(clk) begin
  n ← n + 1
end

@quartz struct TreeKid
  @in en::Bool = false
  @out y::Bool
  n::Bits{4} = 0
end

@on TreeKid posedge(clk) begin
  en && (n ← n + 1)
end

@wire TreeKid y <= n[0]

@quartz struct TreeTop
  @in go::Bool = false
  kid::TreeKid = TreeKid()
  @out z::Bool
  c::Bits{8} = 0
end

@wire TreeTop begin
  kid.clk ← clk
  kid.en ← go
  z <= kid.y
end

@on TreeTop posedge(clk) begin
  c ← c + 1
end

@testset "a design lives in its own module and precompiles there" begin
  # a block is a named function of the module's namespace, and its slot is a method
  # on the slot number; nothing is evaluated into QuartzHDL
  @test QuartzHDL._blockfn(Reloaded, Val(1)) === getfield(@__MODULE__, Symbol("#on#Reloaded#1"))
  @test QuartzHDL._blockfn(Reloaded, Val(2)) === nothing
  @test QuartzHDL._slotcount(Reloaded) === Val(1) && QuartzHDL._slotcount(TreeTop) === Val(2)
  @test QuartzHDL._clocks(TreeTop) == (:clk,)

  # the same block reloaded keeps its slot, and the step follows the new body
  @test step(Reloaded()).n == 1
  @eval @on Reloaded posedge(clk) begin
    n ← n + 2
  end
  @test length(QuartzHDL.blocks(Reloaded)) == 1
  @test Base.invokelatest(step, Reloaded()).n == 2

  # a tree steps as one inferred, static call chain
  m = TreeTop()
  for _ in 1:3
    m = @inferred QuartzHDL._stepwith(m, Val(:clk), (go = true,))
  end
  @test m.c == 3 && m.kid.n == 3 && m.z
  @inferred QuartzHDL._treeedges(m)

  # a package holding a two-block design precompiles, with no method overwritten
  dir = mktempdir()
  mkpath(joinpath(dir, "src"))
  write(joinpath(dir, "Project.toml"), """
    name = "HoldsADesign"
    uuid = "0f1e2d3c-4b5a-4c6d-8e7f-a0b1c2d3e4f5"
    version = "0.1.0"
    """)
  write(joinpath(dir, "src", "HoldsADesign.jl"), """
    module HoldsADesign
    using QuartzHDL
    @quartz struct Two
      @in go::Bool
      @out y::Bool
      @out z::Bool
      n::Bits{4} = 0
    end
    @on Two posedge(clk) begin
      n ← n + 1
      y ← n[0]
    end
    @wire Two z <= go
    end
    """)
  code = """
    using Pkg; Pkg.develop(path = $(repr(pkgdir(QuartzHDL))); io = devnull)
    using HoldsADesign
    m = step(HoldsADesign.Two(); go = true)
    print("stepped ", Int(m.n))
    """
  # the test environment's load path has no Pkg; the child gets the stdlibs back
  loadpath = join([dir, "@stdlib"], Sys.iswindows() ? ";" : ":")
  cmd = setenv(`$(Base.julia_cmd()) --startup-file=no --warn-overwrite=yes -e $code`,
               "JULIA_LOAD_PATH" => loadpath, "JULIA_DEPOT_PATH" => join(DEPOT_PATH, Sys.iswindows() ? ";" : ":"))
  out = IOBuffer()
  ok = success(pipeline(cmd; stdout = out, stderr = out))
  log = String(take!(out))
  @test ok
  @test occursin("stepped 1", log)
  @test !occursin("overwritten", log) && !occursin("closed module", log)
  ok || println(log)
end

@quartz struct Stepped
  @in go::Bool = false
  @in rst::Bool = false
  @out y::Bits{8}
  step::Step
end

@on Stepped posedge(clk) begin
  @reset(rst)
  @sequence Walk step begin
    @when go
    y ← 1
    @then
    y ← 2
    @then
    y ← 3
  end
end

@testset "a Step register takes the width its sequence needs" begin
  @test fieldtype(Stepped, :step) === Bits{16}                 # sixteen bits in the model
  @test QuartzHDL._stepwidth(QuartzHDL.sequences(Stepped)[:step]) == 2   # three steps need two bits
  @test Stepped().step == 0 && encname(Walk, Stepped().step) === :START
  m = step(Stepped(); go = true)
  m = step(m)
  @test m.y == 2 && encname(Walk, m.step) === :step_2
  @test step(m).y == 3 && encname(Walk, step(step(m)).step) === :START
  v = sprint(io -> write(io, Stepped, Verilog()))
  @test occursin("reg [1:0] step", v) && occursin("localparam [1:0] Walk_START = 2'h0;", v)
  @test !occursin("[15:0] step", v)
  # a Step is reset without a declared default: back to START, by name in the Verilog
  @test :step in QuartzHDL.resets(Stepped)
  r = step(m; rst = true)
  @test encname(Walk, r.step) === :START && r.y == m.y      # y has no default, so it keeps its value
  @test occursin("step <= Walk_START;", v)
  @test_throws Exception @eval @quartz struct BadStep
    step::Step = 3
  end
  Random.seed!(11)
  @test cosim(Stepped, [(go = rand(Bool), rst = rand() < 0.1) for i in 1:200]).ok skip=!HAVE_IVERILOG
end

include("aqua.jl")
include("soc.jl")
include("reference.jl")
include("library/runtests.jl")
