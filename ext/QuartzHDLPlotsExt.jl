# `plot(signal)` for a recorded net: a step plot of the wire against time in
# seconds, its ticks labelled in the unit that suits the span -- a pin asserted low
# drawn as the voltage on it, a clock as a square wave -- with a one-bit lane
# labelled L and H and an encoded register's values labelled by state name. Loaded
# with Plots.

module QuartzHDLPlotsExt

using QuartzHDL
using QuartzHDL: Signal, Capture, _wirevalue, _clockwave, _axisunit, _ticklabel
using Plots: RecipesBase, mm

RecipesBase.@recipe function f(s::Signal)
  unit = _axisunit((s.stop[] + 1) * s.grid)
  grid = float(s.grid)
  if s.net.kind === :clock
    ts, v = _clockwave(s)
    t = float.(ts) .* grid
  else
    t = [t * grid for t in s.slots]
    states = s.net.enc === nothing ? Symbol[] : collect(keys(s.net.enc))
    v = [_plotvalue(s, i, states) for i in eachindex(s.slots)]
  end
  push!(t, (s.stop[] + 1) * grid); push!(v, v[end])
  seriestype := :steppost
  legend --> false
  yguide --> s.net.path
  xguide --> "time"
  xformatter --> (t -> _ticklabel(t, unit))
  if s.net.kind === :fsm && s.net.enc !== nothing
    states = collect(keys(s.net.enc))
    yticks --> (0:length(states)-1, string.(states))
  elseif s.net.width == 1
    yticks --> ([0.0, 1.0], ["L", "H"])
    ylims --> (-0.1, 1.1)
  end
  t, v
end

RecipesBase.@recipe function f(r::Capture, names::AbstractString...)
  sigs = isempty(names) ? r.signals : [r[n] for n in names]
  layout := (length(sigs), 1)
  xlims --> (0.0, float((r.stop[] + 1) * r.grid))
  for (i, s) in enumerate(sigs)
    RecipesBase.@series begin
      subplot := i
      if i < length(sigs)
        xguide := ""
        xformatter := (_ -> "")
        bottom_margin := -4mm
      end
      s
    end
  end
end

# a wire as a number to plot: a state as its place in the encoding, and anything
# without a level -- a pad's "0z1", a missing sample, a state no encoding names -- as NaN
function _plotvalue(s::Signal, i::Int, states)
  v = _wirevalue(s, i)
  if v isa Symbol
    k = findfirst(==(v), states)
    return k === nothing ? NaN : Float64(k - 1)
  end
  v isa Bool && return Float64(v)
  v isa Integer && return Float64(Int(v))
  (v isa AbstractString || v === missing) && return NaN
  Float64(v)
end

end
