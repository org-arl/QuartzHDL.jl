# The flattened design graph the timing report reads: modules joined where they
# are wired, and the logic in front of a register followed back bit by bit.

@quartz struct TimingLeaf
  @in word::Bits{16}
  @in strobe::Bool
  hits::Bits{8} = 0
  @out busy::Bool
  @out last::Bits{4} = 0
end

@wire TimingLeaf busy ← hits != 0

@on TimingLeaf posedge(clk) begin
  if strobe && word[12:15] == 5
    hits ← hits + 1
    last ← word[0:3]
  end
end

@quartz struct TimingTop
  @in go::Bool
  leaf::TimingLeaf = TimingLeaf()
  word::Bits{16} = 0
  strobe::Bool = false
  @out idle::Bits{8} = 0
  @out seen::Bits{4} = 0
end

@wire TimingTop begin
  leaf.clk ← clk
  leaf.word ← word
  leaf.strobe ← strobe & go
end

@on TimingTop posedge(clk) begin
  word ← word + 1
  strobe ← !strobe
  leaf.busy || (idle ← idle + 1)
  seen ← leaf.last
end

function flatcone(d, name)
  s = d.sinks[findfirst(s -> QuartzHDL._fullname(d.instances[s.inst], s.name) == name, d.sinks)]
  QuartzHDL._sinkcone(d, s)
end

@testset "the flattened design graph" begin
  d = QuartzHDL._flatten(TimingTop)
  @test [join(i.path, ".") for i in d.instances] == ["", "leaf"]
  @test all(s.clock == :clk for s in d.sinks)
  c = flatcone(d, "leaf.last")
  @test c.reach[("word", :condition)].bits == 0xf000
  @test c.reach[("word", :data)].bits == 0x000f
  @test c.reach[("word", :condition)].crossings == 1
  @test c.reach[("strobe", :condition)].kind == :reg
  @test c.reach[("go", :condition)].kind == :input
  @test !haskey(c.reach, ("leaf.hits", :data))
  c = flatcone(d, "idle")
  r = c.reach[("leaf.hits", :condition)]
  @test r.bits == 0xff && r.crossings == 1
  @test [c.arith[o] for o in r.ops] == [(:ne, 8)]
  @test c.reach[("idle", :data)].bits == 0xff
end

@testset "a write knows the line of the design it stands on" begin
  d = QuartzHDL._flatten(TimingTop)
  at(name) = d.sinks[findfirst(s -> QuartzHDL._fullname(d.instances[s.inst], s.name) == name, d.sinks)].drives[1].at
  @test basename(string(at("leaf.last").file)) == "timing.jl"
  @test at("leaf.last").line == at("leaf.hits").line + 1
  @test at("idle").line == at("word").line + 2
  @test QuartzHDL._sourcestr(at("word")) == "timing.jl:$(at("word").line)"
end

@testset "a flattened design with black boxes, made clocks and a multicycle path" begin
  d = QuartzHDL._flatten(Soc)
  @test [join(i.path, ".") for i in d.instances] == ["", "sub", "sub.leaf"]
  @test any(e -> (e.from, e.to, e.cycles) == ("sub.slowsum", "sub.slowcopy", 4), d.exceptions)
  @test flatcone(d, "sub.q").reach[("sub.ram.q", :data)].kind == :blackbox
  @test haskey(flatcone(d, "sub.ram.data").reach, ("d", :data))
  @test d.sinks[findfirst(s -> s.name == :addr, d.sinks)].clock == :fast
end

@quartz struct TimingSums
  @in a::Bits{8}
  @in b::Bits{8}
  @in up::Bool
  @out acc::Bits{8} = 0
  @out level::Bits{8} = 0
end

@on TimingSums posedge(clk) begin
  acc ← acc + ifelse(a < b, a, b)
  if up
    level ← level + 1
  else
    level ← level - 1
  end
end

timingrow(r, from, to, role) = r.paths[findfirst(p -> (p.from, p.to, p.role) == (from, to, role), r.paths)]

@testset "the timing report ranks conditions by what they read and decide" begin
  r = timing(TimingTop)
  p = timingrow(r, "word", "leaf.last", :condition)
  @test (p.inputs, p.controls, p.crossings) == (6, 12, 1)
  @test isempty(p.arithmetic) && timingrow(timing(TimingTop; lut_inputs=3), "word", "leaf.last", :condition).arithmetic == [(:eq, 4)]
  @test isempty(p.flags)
  @test p.clock == :clk && endswith(p.source, string(":", parse(Int, split(p.condition, ":")[2]) + 2))
  @test r.paths[1].condition == p.condition && r.conditions[1].condition == p.condition
  @test r.ok === missing && isempty(r.rejected) && isempty(r.rejectedpaths) && !r.depth
  @test all(p -> p.depth === missing && p.connected === missing, r.paths) && all(c -> c.depth === missing, r.conditions)
  @test_throws TypeError timing(TimingTop; reject = c -> c.crossings > 0 && c.depth > 1)
  c = r.conditions[findfirst(c -> c.condition == p.condition, r.conditions)]
  @test (c.instance, c.inputs, c.controls, c.crossings) == ("leaf", 6, 12, 1)
  @test [(x.from, x.read) for x in c.reads] == [("word", 4), ("go", 1), ("strobe", 1)]
  @test [(x.to, x.width) for x in c.decides] == [("leaf.hits", 8), ("leaf.last", 4)]
  @test isempty(c.arithmetic)
  summary = sprint(show, MIME"text/plain"(), r)
  @test occursin("Heaviest conditions", summary) && occursin("leaf (2 registers)", summary)
  @test count("timing.jl:", sprint(io -> show(io, r; top=1))) == 1
  @test occursin("6 inputs, controls 12 register bits in 2 registers, crosses 1 module boundary",
                 sprint(io -> show(io, r; condition=p.condition)))
  @test occursin("4 bits, clock clk", sprint(io -> show(io, r; register="leaf.last")))
  @test_throws ArgumentError show(devnull, r; condition="nowhere.jl:1")
  @test_throws ArgumentError show(devnull, r; register="leaf.none")
  @test (@inferred timing(TimingTop)) isa TimingReport
end

@testset "the timing report flags arithmetic in series and sums muxed into a register" begin
  r = timing(TimingSums)
  p = timingrow(r, "a", "acc", :condition)
  @test p.arithmetic == [(:lt, 8), (:add, 8)] && p.flags == [:chained_arithmetic]
  @test isempty(timingrow(r, "acc", "acc", :data).flags)
  @test timingrow(r, "level", "level", :data).flags == [:muxed_arithmetic]
end

@testset "an operation that fits one LUT is not arithmetic" begin
  w = QuartzHDL.Wire{16}(:reg, Any[]; name=:w)
  @test QuartzHDL._varbits(w + 1) == 16
  @test QuartzHDL._varbits(w[0:3] == 5) == 4
  @test QuartzHDL._varbits(w[0:3] == w[4:7]) == 8
  @test QuartzHDL._varbits(count_ones(w & 0x8888)) == 4
end

@testset "the timing report leaves multicycle paths out" begin
  r = timing(Soc)
  @test "sub.slowsum → sub.slowcopy (4 cycles)" in r.excluded
  @test !any(p -> (p.from, p.to) == ("sub.slowsum", "sub.slowcopy"), r.paths)
  @test any(p -> (p.from, p.to) == ("sub.ram.q", "sub.q"), r.paths)
end

@testset "the timing report as a budget" begin
  @test timing(TimingTop).ok === missing
  @test timing(TimingTop; max_bits = 6 => 12).ok
  @test timing(TimingTop; max_bits = 5 => 12).ok
  r = timing(TimingTop; max_bits = 5 => 8)
  @test r.ok === false
  @test [(c.instance, c.inputs, c.controls, c.rejected) for c in r.rejected] == [("leaf", 6, 12, [:max_bits])]
  @test sort([(p.from, p.to) for p in r.paths if :max_bits in p.rejected]) ==
        [("go", "leaf.hits"), ("go", "leaf.last"), ("strobe", "leaf.hits"), ("strobe", "leaf.last"),
         ("word", "leaf.hits"), ("word", "leaf.last")]
  @test isempty(r.rejectedpaths) && isempty(r.exempt)
  @test timing(TimingTop; max_bits = (2 => 100, 5 => 8)).ok === false
  @test timing(TimingTop; max_bits = (2 => 100, 5 => 12)).ok
  text = sprint(show, MIME"text/plain"(), r)
  @test occursin("1 conditions and 0 paths rejected", text) && occursin("Rejected conditions", text)
  @test occursin("timing(TimingTop; max_bits=5 => 12, max_carry=16, max_chain=1)", text)
  @test timing(TimingTop; max_bits = 5 => 12, max_carry = 16, max_chain = 1).ok
  @test !occursin("Present worst", sprint(show, MIME"text/plain"(), timing(TimingTop)))
  r = timing(TimingTop; reject = c -> c.crossings > 0 && c.inputs > 5)
  @test !r.ok && r.rejected[1].rejected == [:reject]
  @test timing(TimingTop; reject = c -> c.instance == "nowhere").ok
  r = timing(TimingSums; max_chain = 1)
  @test !r.ok && [(p.from, p.to, p.rejected) for p in r.rejectedpaths] == [("a", "acc", [:max_chain]), ("b", "acc", [:max_chain])]
  @test timing(TimingSums; max_chain = 2).ok
  @test timing(TimingSums; max_carry = 16).ok && !timing(TimingSums; max_carry = 15).ok
  @test timing(TimingSums; max_chain = 1, lut_inputs = 16).ok
  r = timing(TimingSums; max_chain = 1, except = ["acc"])
  @test r.ok && length(r.exemptpaths) == 2
  @test_throws MethodError timing(TimingTop; depth_limit = 3)
  @test_throws ArgumentError timing(TimingTop; except = ["leaf.hits"])
end

@quartz struct TimingExcused
  @in cmd::Bits{8}
  @in go::Bool
  big::Bits{32} = 0
  other::Bits{32} = 0
  n::Bits{4} = 0
end

@on TimingExcused posedge(clk) begin
  if go && cmd[4:7] == 9
    @timing_exempt "commands are rare and held for many cycles"
    if cmd[0:3] == 2
      big ← big + 1
    end
  elseif cmd == 0
    other ← other + 1
  end
  n ← n + 1
end

@testset "a condition the design marks is exempt, with those inside it" begin
  r = timing(TimingExcused; max_bits = 4 => 16)
  @test r.ok === false
  @test sort([(c.inputs, c.exempt) for c in r.exempt]) ==
        [(5, "commands are rare and held for many cycles"), (9, "commands are rare and held for many cycles")]
  @test all(c -> c.exempt === nothing, r.rejected) && length(r.rejected) == 1 && r.rejected[1].inputs == 9
  text = sprint(show, MIME"text/plain"(), r)
  @test occursin("commands are rare", text) && occursin("max_bits=4 => 32", text)
  r = timing(TimingExcused; max_chain = 0, lut_inputs = 3)    # so that the four-bit compares count
  @test all(p -> p.role == :condition && p.to == "big", r.exemptpaths) && !isempty(r.exemptpaths)
  @test any(p -> p.to == "other", r.rejectedpaths) && !any(p -> p.role == :condition && p.to == "big", r.rejectedpaths)
  m = step(TimingExcused(); cmd = Bits{8}(0x92), go = true)
  @test m.big == 1 && m.n == 1
  v = sprint(io -> write(io, TimingExcused, Verilog()))
  @test !occursin("exempt", v) && occursin("big <= ", v)
  Random.seed!(7)
  @test cosim(TimingExcused, [(cmd = Bits{8}(rand((0x00, 0x92, 0x91, 0x12))), go = rand(Bool)) for _ in 1:200]).ok skip=!HAVE_IVERILOG
  @test_throws "only valid inside" @eval @timing_exempt "nowhere"
end

VERSION >= v"1.12" && @testset "quartz timing, from the command line" begin
  dir = mktempdir()
  design = joinpath(dir, "counter.jl")
  write(design, """
    using QuartzHDL
    @quartz struct Counter
      @in cmd::Bits{8}
      total::Bits{32} = 0
    end
    @on Counter posedge(clk) begin
      if cmd == 7
        total <= total + 1
      end
    end
    """)
  julia = `$(joinpath(Sys.BINDIR, "julia")) --startup-file=no --project=$(dirname(@__DIR__)) -m QuartzHDL timing`
  text = read(`$julia $design`, String)
  @test occursin("Timing report for Counter", text) && occursin("counter.jl:7", text)
  @test success(`$julia $design --budget "max_bits = 8 => 16, reject = c -> c.instance == \"elsewhere\""`)
  @test occursin("8 inputs, controls 32 register bits", read(`$julia $design --condition counter.jl:7`, String))
  @test occursin("32 bits, clock clk", read(`$julia $design --top Counter --register total`, String))
  out = IOBuffer()
  status = run(pipeline(ignorestatus(`$julia $design --json --budget "max_bits = 4 => 16"`); stdout=out))
  json = String(take!(out))
  @test status.exitcode == 1
  @test startswith(json, "{\"version\":1,\"top\":\"Counter\",\"lut_inputs\":4,\"depth\":false,\"flow\":\"\",\"ok\":false,")
  @test occursin("\"budget\":{\"max_bits\":[[4,16]],\"max_carry\":null,\"max_chain\":null,\"max_depth\":null,\"reject\":false}", json)
  @test occursin("\"rejected\":[\"max_bits\"]", json) && occursin("\"arithmetic\":[[\"add\",32]]", json)
  @test run(ignorestatus(pipeline(`$julia $design --budget "max_bits = "`; stderr=devnull))).exitcode == 2
  @test occursin("usage: quartz timing", read(`$julia --help`, String))
end

@quartz struct TimingBlinker
  n::Bits{4} = 0
  @out led::Bool = false
end

@on TimingBlinker posedge(clk) begin
  n ← n + 1
  led ← n[3]
end

@board TimingDemo begin
  device = "LCMXO2-7000ZE-3TG144I"
  io     = :LVCMOS25
  clk => (pin = 92, osc = 48MHz)
  led => (pin = 17)
end

@testset "a Diamond workspace set up to close timing, and to measure it" begin
  text = sprint(io -> write(io, TimingBlinker, LPF(TimingDemo)))
  @test occursin("FREQUENCY PORT \"clk_i\" 48.000000 MHz ;", text) && !occursin("times their rate", text)
  text = sprint(io -> write(io, TimingBlinker, LPF(TimingDemo; overconstrain=1.25)))
  @test occursin("FREQUENCY PORT \"clk_i\" 60.000000 MHz ;", text)
  @test occursin("// clocks are constrained at 1.25 times their rates", text)
  @test_throws ArgumentError LPF(TimingDemo; overconstrain=0)
  dir = write(mktempdir(), TimingBlinker, Diamond(TimingDemo))
  sty = read(joinpath(dir, "TimingBlinker.sty"), String)
  for p in ("PROP_MAP_TimingDriven", "PROP_MAP_TimingDrivenNodeRep", "PROP_MAP_TimingDrivenPack")
    @test occursin("<Property name=\"$p\" value=\"True\"", sty)
  end
  @test occursin("<Property name=\"PROP_MAP_RegRetiming\" value=\"False\"", sty)
  @test occursin("\"PROP_PARSTA_WordCasePaths\" value=\"100\"", sty) && occursin("\"PROP_MAPSTA_WordCasePaths\" value=\"100\"", sty)
  @test occursin("48.000000 MHz", read(joinpath(dir, "TimingDemo.lpf"), String))
  dir = write(mktempdir(), TimingBlinker, Diamond(TimingDemo; overconstrain=1.5, paths=250))
  @test occursin("72.000000 MHz", read(joinpath(dir, "TimingDemo.lpf"), String))
  @test occursin("\"PROP_PARSTA_WordCasePaths\" value=\"250\"", read(joinpath(dir, "TimingBlinker.sty"), String))
  @test_throws ArgumentError Diamond(TimingDemo; paths=0)
  f = QuartzHDL._onboard(QuartzHDL._named(Diamond(; overconstrain=1.2, paths=50), :blink), TimingDemo)
  @test (f.board, f.name, f.overconstrain, f.paths) == (TimingDemo, :blink, 1.2, 50)
end

const HAVE_YOSYS = Sys.which("yosys") !== nothing
HAVE_YOSYS || @warn "yosys not found: the depths of the timing report are not tested"

@testset "the timing report with the depths yosys finds" begin
  if HAVE_YOSYS
    r = timing(TimingSums; depth=true)
    @test r.depth && r.ok === missing
    @test timingrow(r, "a", "acc", :condition).depth ≥ 2          # the compare, then the add it steers
    @test timingrow(r, "up", "level", :condition).depth in 1:2   # the select of the operand, then the add
    @test timingrow(r, "level", "level", :data).depth ≤ 2        # a carry chain is one level, however long
    text = sprint(show, MIME"text/plain"(), r)
    @test occursin("Deepest paths", text)
    @test occursin("depth", sprint(io -> show(io, r; register="acc")))
    deepest = maximum(p.depth for p in r.paths)
    @test timing(TimingSums; max_depth=deepest).ok
    r = timing(TimingSums; max_depth=deepest - 1)
    @test r.ok === false && all(p -> p.rejected == [:max_depth], r.rejectedpaths) && !isempty(r.rejectedpaths)
    @test occursin("max_depth=$deepest", sprint(show, MIME"text/plain"(), r))
    @test timing(TimingSums; max_depth=deepest - 1, except=["acc"]).ok
    # across modules, through a wire a submodule drives, and with black boxes stubbed
    r = timing(TimingTop; depth=true, reject = c -> c.crossings > 0 && c.depth ≥ 1)
    @test timingrow(r, "word", "leaf.last", :condition).depth ≥ 1
    @test r.ok === false && r.rejected[1].depth ≥ 1 && all(c -> c.crossings > 0, r.rejected)
    @test occursin("depth: ", sprint(io -> show(io, r; condition=r.rejected[1].condition)))
    r = timing(Soc; depth=true)
    @test timingrow(r, "sub.ram.q", "sub.q", :data).depth == 0 && timingrow(r, "sub.ram.q", "sub.q", :data).connected
    @test timingrow(r, "sub.addr", "sub.ram.rdaddress", :data).depth == 0
    @test_throws ErrorException timing(TimingSums; depth=true, synth="no_such_pass")
    r = timing(TimingBlinker; depth=true, board=TimingDemo)
    @test r.flow == "synth_lattice -family xo2" && occursin("depths from yosys, synth_lattice -family xo2", sprint(show, MIME"text/plain"(), r))
    @test timing(TimingBlinker; depth=true, board=TimingDemo, synth="synth_ice40").flow == "synth_ice40"
    @test isempty(timing(TimingBlinker; depth=true).flow)
    @test timingrow(timing(TimingSums; depth=true, synth="synth_lattice -family xo2"), "a", "acc", :condition).depth ≥ 2
  end
  withenv("PATH" => "") do
    r = @test_logs (:warn, r"yosys not found") timing(TimingSums; max_depth=3)
    @test r.ok === missing && !r.depth && all(p -> p.depth === missing, r.paths)
    text = sprint(show, MIME"text/plain"(), r)
    @test occursin("not measured, yosys is not installed", text) && !occursin("Present worst", text)
  end
  @test !timing(TimingSums).depth
  @test QuartzHDL._flow(nothing, nothing) === nothing && QuartzHDL._flow("synth_gowin", TimingDemo) == "synth_gowin"
  part(d) = Board(:B, d, QuartzHDL.PinBinding[], "", Dict{Symbol,Any}())
  @test [QuartzHDL._flow(nothing, part(d)) for d in ("LCMXO3D-9400HC", "LCMXO3LF-6900C", "LFE5U-25F-6BG381C", "iCE40UP5K")] ==
        ["synth_lattice -family xo3d", "synth_lattice -family xo3", "synth_lattice -family ecp5", "synth_ice40"]
  @test (@test_logs (:warn, r"no yosys flow is known for XC7A35T") QuartzHDL._flow(nothing, part("XC7A35T"))) === nothing
end

@quartz struct TimingArms
  @in cmd::Bits{4}
  @in busy::Bool
  a::Bits{8} = 0
  b::Bits{8} = 0
  c::Bits{8} = 0
end

@on TimingArms posedge(clk) begin
  if cmd == 1 && !busy
    a ← a + 1
  elseif cmd == 2
    b ← b + 1
  else
    c ← c + 1
  end
end

@testset "an arm of an elseif chain that another arm's test rules out is no condition over it" begin
  r = timing(TimingArms)
  @test !any(p -> (p.from, p.to) == ("busy", "b"), r.paths)     # cmd == 2 means cmd == 1 && !busy is false
  @test timingrow(r, "busy", "a", :condition).inputs == 5
  @test timingrow(r, "cmd", "b", :condition).inputs == 4
  @test timingrow(r, "busy", "c", :condition).inputs == 5       # the else stands under both arms
  first_arm = r.conditions[findfirst(c -> c.inputs == 5, r.conditions)]
  @test sort([x.to for x in first_arm.decides]) == ["a", "c"] && first_arm.controls == 16
end
