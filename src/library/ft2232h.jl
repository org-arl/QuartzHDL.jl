# An FT2232H in FT245 asynchronous FIFO mode, as the FPGA sees it: a byte bus
# with read and write strobes and two flags. Bytes the host sends are read by the
# design; bytes the design writes are read by the host -- which is the test. It
# looks at the strobes every slot, so it is a hook rather than a task.

"""
    FT2232H(sim; data, rd, wr, rxf = nothing, txe = nothing, frame = nothing, timeout = 1)

An FT2232H USB FIFO on the design's pins, in FT245 asynchronous mode. `data` is
the bus pad, `rd` and `wr` the design's strobes (as declared, so asserted means
true whatever the pin's polarity), `rxf` and `txe` the flags the design reads:
`rxf` holds while there is a byte to read, `txe` while there is room to write.
`write(ft, bytes)` is the host sending to the design; `read(ft, n)` is what the
design sent to the host. `frame = 8` makes `take!` and `on` work in 8-byte words.
`close(ft)` takes it off the bus.
"""
mutable struct FT2232H <: Link
  link::LinkState
  data::String                      # the bus, a pad of the design
  rxf::Union{Nothing,String}        # the design's "data to read" input
  txe::Union{Nothing,String}        # the design's "room to write" input
  rd::String                        # the design's read strobe, asserted to read
  wr::String                        # the design's write strobe, asserted to write
  rd_q::Bool
  wr_q::Bool
  bus_q::UInt8
end

function FT2232H(sim::Simulation; data, rd, wr, rxf=nothing, txe=nothing, frame=nothing, timeout=1)
  f = FT2232H(LinkState(sim, frame, timeout), data, rxf, txe, rd, wr, false, false, 0x00)
  _buswidth(sim, data) ≤ 8 || error("$data is wider than the chip's 8-bit bus")
  rxf === nothing || _setnet!(sim, rxf, false)
  txe === nothing || _setnet!(sim, txe, true)
  _release!(sim, data)
  _hook!(f, () -> _ft2232h_slot(f))
  f
end

Base.show(io::IO, f::FT2232H) = print(io, "FT2232H(", f.data, ")")

function _ft2232h_slot(f::FT2232H)
  s, st = _sim(f), _state(f)
  rd, wr = s[f.rd]::Bool, s[f.wr]::Bool
  bus = _buslevel(s, f.data)
  if f.rd_q && !rd && !isempty(st.outq)        # the read strobe ends: the byte is taken
    popfirst!(st.outq)
  end
  if f.wr_q && !wr                             # the write strobe ends: the byte is captured
    # the design releases the bus on the same edge, so what the chip captures is
    # the value that stood during the strobe
    _receivedbyte!(f, f.bus_q)
  end
  # the bus is driven for the whole read strobe, empty or not, as the chip does:
  # a read issued after the last byte returns stale data, not high impedance
  rd ? _setnet!(s, f.data, drive(isempty(st.outq) ? 0x00 : st.outq[1])) : _release!(s, f.data)
  f.rxf === nothing || _setnet!(s, f.rxf, !isempty(st.outq))
  st.busy = !isempty(st.outq)
  f.rd_q, f.wr_q, f.bus_q = rd, wr, bus
  nothing
end

# what stands on a bus pad, with a bit nobody drives read as zero
function _buslevel(s::Simulation, path)
  p = _net(s, path).read(s)
  p isa Pad ? UInt8(_resolvebits(p)[1] & 0xff) : UInt8(Int(p))
end

_buswidth(s::Simulation, path) = _net(s, path).width
