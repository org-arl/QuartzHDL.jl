using Aqua

@testset "Aqua" begin
  # the internal methods on Type{<:X} for several X meet only at Type{Union{}}
  Aqua.test_all(QuartzHDL; ambiguities = (exclude = [QuartzHDL._slotinit, QuartzHDL._resolve, QuartzHDL._dutinput],))
end
