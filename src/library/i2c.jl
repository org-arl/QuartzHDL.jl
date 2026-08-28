# I2C, from either end, on an open-drain bus: a line is pulled low or let go,
# and the pads' pull-ups decide the rest. The master makes the clock and
# addresses a slave; the slave follows the design's master. Clock stretching is
# not modelled.

"""
    I2CMaster(sim; scl, sda, rate = 100kHz, timeout = 1)

An I2C master on the design's `scl` and `sda` pads. `write(m, address, bytes)`
sends a transaction and returns whether every byte was acknowledged;
`read(m, address, n)` returns `n` bytes. A register read is
`write(m, a, [reg]); read(m, a, n)`, with `stop = false` on the write for a
repeated start.
"""
mutable struct I2CMaster <: BusMaster
  link::LinkState
  scl::String
  sda::String
  quarter::Rational{Int}           # a quarter of the clock period, in seconds
end

function I2CMaster(sim::Simulation; scl, sda, rate=100000, timeout=1)
  m = I2CMaster(LinkState(sim, nothing, timeout), scl, sda, 1 // (4 * Int(rate)))
  _release!(sim, scl)
  _release!(sim, sda)
  m
end

Base.show(io::IO, m::I2CMaster) =
  print(io, "I2CMaster(", m.scl, ", ", m.sda, ", ", round(Int, 1 / (4m.quarter)), " Hz)")

# the bus is open drain: a line is pulled low, or let go
_pull!(s, path, low::Bool) = low ? _setnet!(s, path, drive(false)) : _release!(s, path)

"""
    write(master, address, bytes; stop = true) -> Bool

Write `bytes` to the slave at `address` (7 bits): start, address, the bytes,
stop. Returns whether everything was acknowledged.
"""
Base.write(m::I2CMaster, address::Integer, bytes; stop=true) =
  _run(_sim(m), () -> _i2c_write(m, UInt8(address), _bytes(bytes), stop))

"""
    read(master, address, n; stop = true) -> bytes

Read `n` bytes from the slave at `address`.
"""
Base.read(m::I2CMaster, address::Integer, n::Integer; stop=true) =
  _run(_sim(m), () -> _i2c_read(m, UInt8(address), Int(n), stop))

# a transaction is timed from its start: edge k is at t0 + k quarters
mutable struct I2CClock
  t0::Rational{Int}
  k::Int
end
_tick!(s, m::I2CMaster, c::I2CClock) = (c.k += 1; _at(s, c.t0 + c.k * m.quarter))

function _i2c_start(m::I2CMaster, s, c)
  _pull!(s, m.sda, false); _tick!(s, m, c)
  _pull!(s, m.scl, false); _tick!(s, m, c)
  _pull!(s, m.sda, true); _tick!(s, m, c)          # the start is SDA falling with SCL high
  _pull!(s, m.scl, true); _tick!(s, m, c)
end

function _i2c_stop(m::I2CMaster, s, c)
  _pull!(s, m.sda, true); _tick!(s, m, c)
  _pull!(s, m.scl, false); _tick!(s, m, c)
  _pull!(s, m.sda, false); _tick!(s, m, c)         # the stop is SDA rising with SCL high
  _tick!(s, m, c)
end

# A byte out, MSB first, and the acknowledge bit back. A bit is four quarter-ticks:
# SDA is set with SCL low, SCL is let go a quarter later and stays high for two,
# then is pulled low again -- so SDA only ever moves while SCL is low, which is
# what tells a start and a stop apart from data. The acknowledge is a ninth bit,
# clocked the same way with SDA let go for the slave to pull.
function _i2c_sendbyte(m::I2CMaster, s, c, b::UInt8)
  for i in 7:-1:0
    _pull!(s, m.sda, (b >> i) & 1 == 0); _tick!(s, m, c)
    _pull!(s, m.scl, false); _tick!(s, m, c); _tick!(s, m, c)
    _pull!(s, m.scl, true); _tick!(s, m, c)
  end
  _pull!(s, m.sda, false); _tick!(s, m, c)
  _pull!(s, m.scl, false); _tick!(s, m, c)
  ack = !s[m.sda]
  _tick!(s, m, c)
  _pull!(s, m.scl, true); _tick!(s, m, c)
  ack
end

# A byte in, and the acknowledge we give. Four quarter-ticks a bit as above, with
# SDA read in the middle of the two quarters SCL is high.
function _i2c_recvbyte(m::I2CMaster, s, c, ack::Bool)
  b = UInt8(0)
  _pull!(s, m.sda, false)
  for i in 7:-1:0
    _tick!(s, m, c)
    _pull!(s, m.scl, false); _tick!(s, m, c)
    s[m.sda] && (b |= UInt8(1) << i)
    _tick!(s, m, c)
    _pull!(s, m.scl, true); _tick!(s, m, c)
  end
  _pull!(s, m.sda, ack); _tick!(s, m, c)
  _pull!(s, m.scl, false); _tick!(s, m, c); _tick!(s, m, c)
  _pull!(s, m.scl, true); _tick!(s, m, c)
  _pull!(s, m.sda, false)
  b
end

# start, what the transaction does, and a stop unless a repeated start is to follow
function _i2c_transaction(f, m::I2CMaster, stop::Bool)
  s, st = _sim(m), _state(m)
  st.busy = true
  c = I2CClock(time(s), 0)
  _i2c_start(m, s, c)
  out = f(s, c)
  stop && _i2c_stop(m, s, c)
  st.busy = false
  out
end

_i2c_write(m::I2CMaster, address::UInt8, bytes::Vector{UInt8}, stop::Bool) =
  _i2c_transaction(m, stop) do s, c
    ok = _i2c_sendbyte(m, s, c, address << 1)
    for b in bytes
      ok || break
      ok &= _i2c_sendbyte(m, s, c, b)
    end
    ok
  end

_i2c_read(m::I2CMaster, address::UInt8, n::Int, stop::Bool) =
  _i2c_transaction(m, stop) do s, c
    out = UInt8[]
    if _i2c_sendbyte(m, s, c, address << 1 | 0x01)
      for i in 1:n
        push!(out, _i2c_recvbyte(m, s, c, i < n))
      end
    end
    out
  end

@enum I2CPhase I2C_IDLE I2C_ADDR I2C_ACKADDR I2C_WRITE I2C_ACKWRITE I2C_READ I2C_ACKREAD

"""
    I2CSlave(sim; scl, sda, address, frame = nothing, timeout = 1)

An I2C slave at `address` on the design's `scl` and `sda` pads. What the master
writes arrives as one unit per transaction, to `take!` or to `on`; what the
master reads comes from the bytes queued with `put!` (`0xff` when none), so a
register map is an `on` closure that answers a write with the bytes to read next.
`close(sl)` takes it off the bus.
"""
mutable struct I2CSlave <: Link
  link::LinkState
  scl::String
  sda::String
  address::UInt8
  phase::I2CPhase
  shift::UInt8
  nbits::Int
  writing::Bool                    # the master is writing to us
  got::Vector{UInt8}               # the bytes of the write under way
  scl_q::Bool
  sda_q::Bool
end

function I2CSlave(sim::Simulation; scl, sda, address, frame=nothing, timeout=1)
  sl = I2CSlave(LinkState(sim, frame, timeout), scl, sda, UInt8(address), I2C_IDLE, 0x00, 0, false,
                UInt8[], true, true)
  _release!(sim, sda)
  _hook!(sl, () -> _i2c_slave_slot(sl))
  sl
end

Base.show(io::IO, sl::I2CSlave) = print(io, "I2CSlave(", sl.scl, ", ", sl.sda, ", ", repr(sl.address), ")")

function _i2c_slave_slot(sl::I2CSlave)
  s, st = _sim(sl), _state(sl)
  scl, sda = s[sl.scl]::Bool, s[sl.sda]::Bool
  if sl.scl_q && scl && sl.sda_q && !sda
    isempty(sl.got) || _received!(sl, copy(sl.got))
    sl.phase = I2C_ADDR
    sl.nbits = 0
    sl.shift = 0x00
    empty!(sl.got)
    _release!(s, sl.sda)
  elseif sl.scl_q && scl && !sl.sda_q && sda
    isempty(sl.got) || _received!(sl, copy(sl.got))
    empty!(sl.got)
    sl.phase = I2C_IDLE
    _release!(s, sl.sda)
  elseif !sl.scl_q && scl
    _i2c_slave_sample!(sl, st, sda)
  elseif sl.scl_q && !scl                          # falling edge: drive
    if sl.phase in (I2C_ACKADDR, I2C_ACKWRITE)
      _pull!(s, sl.sda, true)                      # acknowledge
    elseif sl.phase == I2C_ACKREAD
      _release!(s, sl.sda)                         # let the master acknowledge
    elseif sl.phase == I2C_READ
      _pull!(s, sl.sda, (sl.shift >> (7 - sl.nbits)) & 0x01 == 0)
    else
      _release!(s, sl.sda)
    end
  end
  st.busy = !isempty(st.outq)
  sl.scl_q, sl.sda_q = scl, sda
  nothing
end

# the rising edge of SCL: the bit on SDA is the one the master means us to see
function _i2c_slave_sample!(sl::I2CSlave, st::LinkState, sda::Bool)
  if sl.phase == I2C_ADDR
    sl.shift = (sl.shift << 1) | UInt8(sda)
    sl.nbits += 1
    if sl.nbits == 8
      sl.writing = sl.shift & 0x01 == 0
      sl.phase = (sl.shift >> 1) == sl.address ? I2C_ACKADDR : I2C_IDLE
      sl.nbits = 0
    end
  elseif sl.phase == I2C_WRITE
    sl.shift = (sl.shift << 1) | UInt8(sda)
    sl.nbits += 1
    if sl.nbits == 8
      push!(sl.got, sl.shift)
      sl.phase = I2C_ACKWRITE
      sl.nbits = 0
    end
  elseif sl.phase == I2C_READ
    sl.nbits += 1
    if sl.nbits == 8
      sl.phase = I2C_ACKREAD
      sl.nbits = 0
    end
  elseif sl.phase in (I2C_ACKADDR, I2C_ACKWRITE, I2C_ACKREAD)
    sl.phase = sl.writing ? I2C_WRITE : I2C_READ
    sl.nbits = 0
    sl.writing || (sl.shift = isempty(st.outq) ? 0xff : popfirst!(st.outq))
  end
  nothing
end
