# `plot(signal)` for a recorded net: a step plot against time in seconds, with an
# encoded register's values labelled by state name. Loaded with Plots.

module QuartzHDLPlotsExt

using QuartzHDL
using QuartzHDL: Signal, Capture, _value
using Plots: RecipesBase

RecipesBase.@recipe function f(s::Signal)
  t = [float(t * s.grid) for t in s.slots]
  states = s.net.enc === nothing ? Symbol[] : collect(keys(s.net.enc))
  v = [_plotvalue(s, i, states) for i in eachindex(s.slots)]
  tend = (s.slots[end] + 1) * s.grid
  push!(t, float(tend)); push!(v, v[end])
  seriestype := :steppost
  label --> s.net.path
  xguide --> "time (s)"
  if s.net.kind === :fsm && !isempty(states)
    yticks --> (0:length(states)-1, string.(states))
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
      s
    end
  end
end

# a value as a number to plot: a state as its place in the encoding, and anything
# without a level -- a pad's "0z1", a missing sample, a state no encoding names -- as NaN
function _plotvalue(s::Signal, i::Int, states)
  v = _value(s, i)
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
