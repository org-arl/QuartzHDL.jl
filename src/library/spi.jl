# SPI, from either end. The master drives the clock and chip select and exchanges
# a byte per eight clocks; the slave follows the design's clock. Bits go MSB first.
# `mode` is the usual 0-3 (CPOL, CPHA). Chip select is asserted as `true`: a pin
# declared `active=:low` is inverted where it meets the pin, not here.

"""
    SPIMaster(sim; sclk, mosi = nothing, miso = nothing, cs = nothing, rate = 1MHz,
              mode = 0, timeout = 1)

An SPI master on the design's pins, driving `sclk`, `mosi` and `cs` and reading
`miso`. `transfer(m, bytes)` exchanges bytes, holding `cs` for the whole
transfer, and returns what came back; `write` and `read` are one-way forms of it.
"""
mutable struct SPIMaster <: BusMaster
  link::LinkState
  sclk::String
  mosi::Union{Nothing,String}
  miso::Union{Nothing,String}
  cs::Union{Nothing,String}
  half::Rational{Int}              # half a clock period, in seconds
  cpol::Bool
  cpha::Bool
end

function SPIMaster(sim::Simulation; sclk, mosi=nothing, miso=nothing, cs=nothing, rate=1000000,
    mode=0, timeout=1
)
  0 ≤ mode ≤ 3 || error("SPI mode is 0 to 3")
  m = SPIMaster(LinkState(sim, nothing, timeout), sclk, mosi, miso, cs, 1 // (2 * Int(rate)),
                mode ≥ 2, isodd(mode))
  _setnet!(sim, sclk, m.cpol)
  mosi === nothing || _setnet!(sim, mosi, false)
  cs === nothing || _setnet!(sim, cs, false)
  m
end

Base.show(io::IO, m::SPIMaster) = print(io, "SPIMaster(", m.sclk, ", ", round(Int, 1 / (2m.half)), " Hz)")

"""
    transfer(master, bytes) -> bytes

Clock `bytes` out and return the bytes that came in, one per byte sent.
"""
transfer(m::SPIMaster, bytes) = _run(_sim(m), () -> _spi_transfer(m, _bytes(bytes)))

function _spi_transfer(m::SPIMaster, out::Vector{UInt8})
  s = _sim(m)
  st = _state(m)
  st.busy = true
  m.cs === nothing || _setnet!(s, m.cs, true)
  t0 = time(s)
  k = 0                                            # half periods elapsed
  back = UInt8[]
  for b in out
    r = UInt8(0)
    for i in 7:-1:0
      # The first edge of a bit is the sampling edge in mode 0/2 and the shifting
      # edge in 1/3, so the two arms are deliberate mirrors of each other: the same
      # four steps in the other order.
      if !m.cpha
        m.mosi === nothing || _setnet!(s, m.mosi, (b >> i) & 1 == 1)
        _at(s, t0 + (k += 1) * m.half)
        _setnet!(s, m.sclk, !m.cpol)
        m.miso === nothing || (s[m.miso] && (r |= UInt8(1) << i))
        _at(s, t0 + (k += 1) * m.half)
        _setnet!(s, m.sclk, m.cpol)
      else
        _at(s, t0 + (k += 1) * m.half)
        _setnet!(s, m.sclk, !m.cpol)
        m.mosi === nothing || _setnet!(s, m.mosi, (b >> i) & 1 == 1)
        _at(s, t0 + (k += 1) * m.half)
        _setnet!(s, m.sclk, m.cpol)
        m.miso === nothing || (s[m.miso] && (r |= UInt8(1) << i))
      end
    end
    push!(back, r)
  end
  _at(s, t0 + (k += 1) * m.half)
  m.cs === nothing || _setnet!(s, m.cs, false)
  _at(s, t0 + (k += 1) * m.half)
  st.busy = false
  append!(st.inq, back)
  back
end

# an SPI master's write is a transfer whose reply is dropped; its read sends zeros
function Base.unsafe_write(m::SPIMaster, p::Ptr{UInt8}, n::UInt)
  transfer(m, unsafe_wrap(Vector{UInt8}, p, n))
  empty!(_state(m).inq)
  Int(n)
end
Base.read(m::SPIMaster, n::Integer) = (empty!(_state(m).inq); transfer(m, zeros(UInt8, n)))

"""
    SPISlave(sim; sclk, mosi = nothing, miso = nothing, cs = nothing, mode = 0, idle = 0xff,
             frame = nothing, timeout = 1)

An SPI slave on the design's pins, following the design's `sclk` and `cs`. Bytes
queued with `put!` go out on `miso` as the master clocks, `idle` when none is
queued; what arrives on `mosi` is taken with `take!`, or answered by `on` -- per
byte, so a reply to a command byte goes out with the next byte, as a device does.
`close(sl)` takes it off the bus.
"""
Base.@kwdef mutable struct SPISlave <: Link
  link::LinkState
  sclk::String
  mosi::Union{Nothing,String} = nothing
  miso::Union{Nothing,String} = nothing
  cs::Union{Nothing,String} = nothing
  cpol::Bool = false
  cpha::Bool = false
  sclk_q::Bool = false
  cs_q::Bool = false
  shift::UInt8 = 0x00              # bits received so far
  nbits::Int = 0
  sending::UInt8 = 0xff            # the byte going out
  queued::Bool = false             # it came from the queue, not the idle value
  idle::UInt8 = 0xff               # what goes out when nothing is queued
end

function SPISlave(sim::Simulation; sclk, mosi=nothing, miso=nothing, cs=nothing, mode=0, idle=0xff,
    frame=nothing, timeout=1
)
  0 ≤ mode ≤ 3 || error("SPI mode is 0 to 3")
  sl = SPISlave(; link=LinkState(sim, frame, timeout), sclk, mosi, miso, cs, cpol=mode ≥ 2,
                cpha=isodd(mode), sclk_q=mode ≥ 2, sending=UInt8(idle), idle=UInt8(idle))
  miso === nothing || _release!(sim, miso)
  _hook!(sl, () -> _spi_slave_slot(sl))
  sl
end

Base.show(io::IO, sl::SPISlave) = print(io, "SPISlave(", sl.sclk, ")")

function _spi_slave_slot(sl::SPISlave)
  s, st = _sim(sl), _state(sl)
  sclk = s[sl.sclk]::Bool
  selected = sl.cs === nothing || s[sl.cs]::Bool
  if selected && !sl.cs_q                           # selected: a transfer starts
    sl.nbits = 0
    sl.shift = 0x00
    _spi_next!(sl, st)
    _spi_drive!(sl, s, 7)
  elseif !selected && sl.cs_q                       # deselected: a byte loaded but not clocked goes back
    sl.queued && sl.nbits == 0 && pushfirst!(st.outq, sl.sending)
    sl.queued = false
    sl.miso === nothing || _release!(s, sl.miso)
  end
  if selected && sclk != sl.sclk_q
    leading = sclk != sl.cpol                        # the first edge of a clock
    sample = leading != sl.cpha
    if sample
      sl.mosi === nothing || (s[sl.mosi]::Bool && (sl.shift |= UInt8(1) << (7 - sl.nbits)))
      sl.nbits += 1
      if sl.nbits == 8
        _receivedbyte!(sl, sl.shift)
        sl.nbits = 0
        sl.shift = 0x00
        _spi_next!(sl, st)
        sl.cpha && _spi_drive!(sl, s, 7)
      end
    else
      _spi_drive!(sl, s, 7 - sl.nbits)
    end
  end
  st.busy = !isempty(st.outq)
  sl.sclk_q, sl.cs_q = sclk, selected
  nothing
end

function _spi_next!(sl::SPISlave, st::LinkState)
  sl.queued = !isempty(st.outq)
  sl.sending = sl.queued ? popfirst!(st.outq) : sl.idle
end

_spi_drive!(sl::SPISlave, s::Simulation, bit::Int) =
  sl.miso === nothing || _setnet!(s, sl.miso, (sl.sending >> bit) & 1 == 1)
