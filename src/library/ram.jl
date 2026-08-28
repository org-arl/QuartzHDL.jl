# A memory behind a black box -- an EBR, an SRAM, a register file -- as the
# stand-in the design's declaration needs. Any number of read and write ports,
# each synchronous to its own clock: a read port holds the word its address
# named before the edge; a write port stores on the edge, and a read of the
# address being written sees the old word. The storage is one array the ports
# share, changed in place, so a write costs a write.

# one port of a memory: which of the part's pins play which role
struct RAMPort
  clock::Symbol
  addr::Symbol
  data::Symbol
  en::Union{Nothing,Symbol}
  we::Union{Nothing,Symbol}        # a write port's write enable, beside its clock enable
end

"""
    RAM(depth, width; read = (clock, addr, data, en), write = (clock, addr, data, we, en))

A memory of `depth` words of `width` bits as a black-box stand-in:
`QuartzHDL.standin(::Type{Part}) = RAM(8192, 16; read = (...), write = (...))`.
Each port names the part's pins by role, in lowercase as Julia sees them; `en`
and `we` may be left out. Several ports of a kind are given as a vector.
`ram[a]` reads a word, `ram[a] = v` stores one, `fill!(ram, 0)` clears it; an
address counts from zero, as the design's does. A read port's output is read
under the name its declaration gives it, `ram.q`.
"""
mutable struct RAM
  const mem::Vector{UInt128}
  const width::Int
  const reads::Vector{RAMPort}
  const writes::Vector{RAMPort}
  const held::Vector{UInt128}      # what each read port holds
end

function RAM(depth::Integer, width::Integer; read=(), write=())
  ports(x) = x isa NamedTuple ? [_ramport(x)] : [_ramport(p) for p in x]
  reads = ports(read)
  RAM(zeros(UInt128, depth), Int(width), reads, ports(write), zeros(UInt128, length(reads)))
end

_ramport(p::NamedTuple) = RAMPort(p.clock, p.addr, p.data, get(p, :en, nothing), get(p, :we, nothing))

Base.show(io::IO, r::RAM) = print(io, "RAM(", length(_mem(r)), "x", _width(r), ")")
Base.getindex(r::RAM, a::Integer) = Bits{_width(r)}(_mem(r)[a + 1])
Base.setindex!(r::RAM, v, a::Integer) = (_mem(r)[a + 1] = _toraw(v) & _mask(_width(r)); v)
Base.fill!(r::RAM, v) = (fill!(_mem(r), _toraw(v) & _mask(_width(r))); r)
Base.length(r::RAM) = length(_mem(r))

# a memory is read by the names of its read ports alone: `ram.q`, never `ram.mem`
function Base.getproperty(r::RAM, f::Symbol)
  i = findfirst(p -> p.data === f, getfield(r, :reads))
  i === nothing && error("RAM has no output named $f")
  W = _width(r)
  W == 1 ? isodd(getfield(r, :held)[i]) : Bits{W}(getfield(r, :held)[i])
end
Base.propertynames(r::RAM) = Tuple(p.data for p in getfield(r, :reads))

function Base.step(r::RAM, clock::Symbol; kw...)
  mem, width = _mem(r), _width(r)
  for (i, p) in enumerate(getfield(r, :reads))
    p.clock === clock || continue
    _enabled(p.en, kw) || continue
    getfield(r, :held)[i] = mem[Int(kw[p.addr]) + 1]
  end
  for p in getfield(r, :writes)
    p.clock === clock || continue
    _enabled(p.en, kw) && _enabled(p.we, kw) || continue
    mem[Int(kw[p.addr]) + 1] = _toraw(kw[p.data]) & _mask(width)
  end
  r
end

_mem(r::RAM) = getfield(r, :mem)
_width(r::RAM) = getfield(r, :width)

_enabled(::Nothing, kw) = true
_enabled(name::Symbol, kw) = Bool(kw[name])
