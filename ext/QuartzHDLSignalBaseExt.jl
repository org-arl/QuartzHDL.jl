# A sampled signal has a frame rate: the clock grid's. With this, SignalAnalysis
# and anything else built on SignalBase takes `sampled(out["x"])` as a signal.

module QuartzHDLSignalBaseExt

using QuartzHDL
using QuartzHDL: Sampled
using SignalBase

SignalBase.framerate(x::Sampled) = float(1 / QuartzHDL.frametime(x))
SignalBase.nframes(x::Sampled) = length(x)
SignalBase.nchannels(::Sampled) = 1
SignalBase.sampletype(::Sampled) = Float64
SignalBase.duration(x::Sampled) = float(length(x) * QuartzHDL.frametime(x))

end
