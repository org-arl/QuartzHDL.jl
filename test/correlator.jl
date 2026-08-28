# A passband matched filter for a 13-chip Barker code: the last thirteen samples of
# an 8-bit signal, each added or subtracted as the code says, through a two-stage
# pipeline. One chip per sample, so the window is the code's length.

using QuartzHDL

const TAPS = 13
const BARKER = Bits{13}(0b1111100110101)

@quartz struct Correlator
  @in  x::SBits{8} = 0
  window::Bits{8 * TAPS} = 0
  y::Pipeline{2,SBits{16}}
  @out mf::SBits{16} = 0
  @out valid::Bool = false
end

tap(window, k) = SBits{16}(SBits{8}(window[8k:8k+7]))
correlate(window) = sum(BARKER[k] ? tap(window, k) : -tap(window, k) for k in 0:TAPS-1)

@on Correlator posedge(clk) begin
  window ← window << 8 | Bits{8}(x)
  y ← correlate(window)
  mf ← coalesce(y, 0)
  valid ← isnew(y)
end
