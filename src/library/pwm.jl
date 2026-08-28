# A pulse train on a pin: a clock, a strobe, a gated burst, a level, depending on
# what the duty and count are. The settings are read at the start of each
# period, so they may be changed while it runs.

"""
    PWM(sim; out, rate, duty = 0.5, phase = 0, count = Inf)

A pulse train on net `out` at `rate`, high for `duty` of each period, starting
`phase` of a period late, for `count` periods. `duty = 0.5` is a clock; `count = 1`
a single pulse. `pwm.duty` and `pwm.rate` may be changed as it runs; `close(pwm)`
stops it with the output low.
"""
mutable struct PWM{S<:Simulation}
  sim::S
  out::String
  period::Rational{Int}
  duty::Float64
  count::Float64                   # periods to run, Inf for ever
  task::Union{Nothing,SimTask}
end

function PWM(sim::Simulation; out, rate, duty=0.5, phase=0.0, count=Inf)
  p = PWM(sim, out, 1 // Int(rate), float(duty), float(count), nothing)
  _setnet!(sim, out, false)
  setfield!(p, :task, spawn!(sim, () -> _pwm_run(p, float(phase)); persistent=true))
  p
end

Base.show(io::IO, p::PWM) = print(io, "PWM(", p.out, ", ", round(Int, 1 / p.period), " Hz, ", p.duty, ")")
Base.getproperty(p::PWM, f::Symbol) = f === :rate ? 1 / getfield(p, :period) : getfield(p, f)
Base.setproperty!(p::PWM, f::Symbol, v) =
  f === :rate ? setfield!(p, :period, 1 // Int(v)) :
  f in (:duty, :count) ? setfield!(p, f, float(v)) : error("a PWM's $f cannot be changed")
Base.propertynames(::PWM) = (:out, :rate, :duty, :count)
Base.isopen(p::PWM) = p.task !== nothing

function Base.close(p::PWM)
  p.task === nothing || stop!(p.sim, p.task)
  setfield!(p, :task, nothing)
  _setnet!(p.sim, p.out, false)
  nothing
end

function _pwm_run(p::PWM, phase)
  s = p.sim
  period = p.period
  t0 = time(s) + phase * period
  _at(s, t0)
  k = 0                                            # periods since t0
  n = 0                                            # periods run
  while n < p.count
    # the edges of a period are timed from t0 rather than accumulated, so the error
    # never grows; a change of rate rebases t0 to where it happened
    if p.period != period
      t0 += k * period
      period = p.period
      k = 0
    end
    duty = p.duty
    duty > 0 && _setnet!(s, p.out, true)
    _at(s, t0 + (k + duty) * period)
    duty < 1 && _setnet!(s, p.out, false)
    k += 1; n += 1
    _at(s, t0 + k * period)
  end
end
