# A ported design is checked against its original: the same stimulus into the Julia
# model and into a Verilog file someone else wrote.

@quartz struct RefAcc
  @in d::Bits{8}
  @in rst::Bool
  acc::Bits{8} = 5
  @out y::Bits{8} = 0
end

@on RefAcc posedge(clk) begin
  @reset(rst)
  acc ← acc + d
  y ← acc
end

@testset "co-simulation against a hand-written reference" begin
  Random.seed!(91)
  stim = [(d = Bits{8}(rand(0:255)), rst = i in 40:42) for i in 1:200]
  ref = joinpath(@__DIR__, "ref", "refacc.v")
  r = cosim(RefAcc, stim; reference = ref, ref_init = ["acc" => "8'd5", "y" => "8'd0"])
  @test r.ok skip=!HAVE_IVERILOG
  showmismatches(r)
  if HAVE_IVERILOG
    r = cosim(RefAcc, stim; reference = ref)            # undefined until the reset, so it differs
    @test !r.ok && r.mismatches[1] == (1, "5", "x") && r.mismatches[end][1] < 42
    r = cosim(RefAcc, stim; reference = ref, ref_init = ["acc" => "8'd6"])
    @test !r.ok && r.mismatches[1] == (1, "5", "6") && r.mismatches[end][1] < 42   # a wrong start, until the reset
  end
end
