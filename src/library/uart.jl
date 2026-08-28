# A UART: 8 data bits, LSB first, a start bit, optional parity, stop bits. Its
# `tx` drives the design's receive pin and its `rx` listens to the design's
# transmit pin; either may be left unbound.

"""
    UART(sim; rx = nothing, tx = nothing, baud = 115200, stop = 1, parity = :none,
         frame = nothing, timeout = 1)

A UART on the design's pins: `rx` is the net it listens to (the design's
transmit), `tx` the net it drives (the design's receive). `frame` groups what is
received into units for `take!`, `read` and `on`: a byte count, or a delimiter
(`0x0a`, `"\\r\\n"`). `timeout` bounds a blocking `read` or `write`, in seconds.
`close(u)` stops it.
"""
mutable struct UART <: Link
  link::LinkState
  rx::Union{Nothing,String}
  tx::Union{Nothing,String}
  bit::Rational{Int}               # seconds per bit
  stop::Int
  parity::Symbol                   # :none, :even or :odd
end

function UART(sim::Simulation; rx=nothing, tx=nothing, baud=115200, stop=1, parity=:none,
    frame=nothing, timeout=1
)
  parity in (:none, :even, :odd) || error("parity is :none, :even or :odd")
  u = UART(LinkState(sim, frame, timeout), rx, tx, 1 // Int(baud), Int(stop), parity)
  if tx !== nothing
    _setnet!(sim, tx, true)
    _task!(u, () -> _uart_send(u))
  end
  rx === nothing || _task!(u, () -> _uart_receive(u))
  u
end

Base.show(io::IO, u::UART) =
  print(io, "UART(", something(u.rx, "-"), " ← design, design ← ", something(u.tx, "-"),
        ", ", round(Int, 1 / u.bit), " baud)")

_paritybit(b::UInt8, parity::Symbol) = parity === :even ? isodd(count_ones(b)) : !isodd(count_ones(b))

function _uart_send(u::UART)
  s, st, tx = _sim(u), _state(u), u.tx
  while true                                       # a model's task, alive until close
    advance_until(s, () -> !isempty(st.outq))
    st.busy = true
    while !isempty(st.outq)
      b = popfirst!(st.outq)
      t0 = time(s)
      _setnet!(s, tx, false)
      _at(s, t0 + u.bit)
      for i in 0:7
        _setnet!(s, tx, (b >> i) & 1 == 1)
        _at(s, t0 + (i + 2) * u.bit)
      end
      k = 9
      if u.parity !== :none
        _setnet!(s, tx, _paritybit(b, u.parity))
        _at(s, t0 + (k += 1) * u.bit)
      end
      _setnet!(s, tx, true)
      _at(s, t0 + (k + u.stop) * u.bit)
    end
    st.busy = false
  end
end

function _uart_receive(u::UART)
  s, rx = _sim(u), u.rx
  while true                                       # a model's task, alive until close
    advance_until(s, () -> !s[rx])
    t0 = time(s)
    b = UInt8(0)
    for i in 0:7
      _at(s, t0 + (2i + 3) * u.bit // 2)
      s[rx] && (b |= UInt8(1) << i)
    end
    k = 9
    if u.parity !== :none
      _at(s, t0 + (2k + 1) * u.bit // 2)
      s[rx] == _paritybit(b, u.parity) || @warn "UART $rx: parity error on byte $(repr(b))" time=_timestr(t0)
      k += 1
    end
    _at(s, t0 + (2k + 1) * u.bit // 2)
    s[rx] || @warn "UART $rx: framing error, no stop bit" time=_timestr(t0)
    _receivedbyte!(u, b)
  end
end
