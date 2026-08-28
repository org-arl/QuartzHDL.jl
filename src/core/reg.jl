# The value types the simulator runs: hardware integers of a fixed width, and the
# registers that carry behaviour of their own -- a pulse that clears itself, a
# timeout that counts down, an edge that remembers its last level, a pipeline, a
# multicycle wire, a metastability guard, and a pad. Every operation is defined to be
# the one the hardware performs, so a Julia run and the emitted Verilog agree bit for
# bit.
#
# trace.jl defines the same operations over symbolic `Wire`s. The two tables have to
# stay in step: an operation added here without its counterpart there compiles in
# simulation and fails at emission, and one added with different semantics fails in
# neither place while the two worlds disagree.

abstract type HWInt{N} <: Integer end

"""
    Bits{N}

An unsigned hardware integer `N` bits wide, the type most registers and ports have.
It wraps on overflow and truncates on a slice, as the wire does.

```julia
@quartz struct Ctr
  n::Bits{8} = 0
end
```
"""
struct Bits{N} <: HWInt{N}
  val::UInt128
  Bits{N}(x::UInt128) where N = (N isa Int && 0 ≤ N ≤ 128) ? new{N}(x & _mask(N)) :
    throw(ArgumentError("Bits width must be 0..128"))
end

"""
    SBits{N}

A signed (two's complement) hardware integer `N` bits wide. Signed and unsigned
values never mix in one expression: convert one of them first.
"""
struct SBits{N} <: HWInt{N}
  val::UInt128
  SBits{N}(x::UInt128) where N = (N isa Int && 0 ≤ N ≤ 128) ? new{N}(x & _mask(N)) :
    throw(ArgumentError("SBits width must be 0..128"))
end

Bits{N}() where N = Bits{N}(UInt128(0))
Bits(bits::AbstractVector{Bool}) = Bits{length(bits)}(foldr((b, v) -> UInt128(2) * v + b, bits; init=UInt128(0)))
SBits{N}() where N = SBits{N}(UInt128(0))
Bits{N}(x::Bool) where N = Bits{N}(UInt128(x))
SBits{N}(x::Bool) where N = SBits{N}(UInt128(x))
Bits{N}(x::Integer) where N = Bits{N}(_toraw(x))
SBits{N}(x::Integer) where N = SBits{N}(_toraw(x))
# Widening a hardware value keeps it; narrowing drops bits, which is sometimes meant
# and usually a mistake, so it has to say so. The rule is on the width, not the value:
# it fires the same way on every run rather than the first time the data goes high.
Bits{N}(x::HWInt) where N = (_checkwiden(Bits{N}, x); Bits{N}(_toraw(x)))
SBits{N}(x::HWInt) where N = (_checkwiden(SBits{N}, x); SBits{N}(_toraw(x)))

Base.trunc(::Type{T}, x::HWInt) where T<:HWInt = T(_toraw(x))

"""
    bitwidth(x)

How many bits a hardware value, or a hardware type, takes on the wire.

```julia
bitwidth(Bits{12})        # 12
bitwidth(SBits{8}(-1))    # 8
```
"""
bitwidth(::Type{<:HWInt{N}}) where N = N
bitwidth(x::HWInt) = bitwidth(typeof(x))
bitwidth(::Type{Bool}) = 1
bitwidth(::Bool) = 1
bitwidth(::Type{T}) where T<:Base.BitInteger = 8 * sizeof(T)
bitwidth(x::Base.BitInteger) = bitwidth(typeof(x))

issigned(::Type{<:SBits}) = true
issigned(::Type{<:Bits}) = false
issigned(::Type{Bool}) = false
issigned(::Type{<:Signed}) = true
issigned(::Type{<:Unsigned}) = false

Base.UInt128(r::Bits) = r.val
Base.Int128(r::Bits) = Int128(r.val)
Base.Int128(r::SBits{N}) where N = (v = reinterpret(Int128, r.val); N == 128 ? v : (v << (128 - N)) >> (128 - N))
Base.UInt128(r::SBits) = reinterpret(UInt128, Int128(r))
Base.BigInt(r::Bits) = BigInt(r.val)
Base.BigInt(r::SBits) = BigInt(Int128(r))
Base.Int(r::Bits) = Int(r.val)
Base.Int(r::SBits) = Int(Int128(r))
Base.Bool(r::HWInt) = Int128(r) != 0 && (Int128(r) == 1 || throw(InexactError(:Bool, Bool, r)))
(::Type{T})(r::HWInt) where T<:Base.BitInteger = T(Int128(r))

Base.zero(::Type{T}) where T<:HWInt = T(false)
Base.one(::Type{T}) where T<:HWInt = T(true)
Base.typemax(::Type{Bits{N}}) where N = Bits{N}(_mask(N))
Base.typemin(::Type{Bits{N}}) where N = Bits{N}()
Base.typemax(::Type{SBits{N}}) where N = SBits{N}(_mask(N) >> 1)
Base.typemin(::Type{SBits{N}}) where N = SBits{N}(UInt128(1) << (N - 1))

Base.show(io::IO, r::Bits{N}) where N = print(io, "Bits{", N, "}(0x", string(r.val; base=16, pad=max(cld(N, 4), 1)), ")")
Base.show(io::IO, r::SBits{N}) where N = print(io, "SBits{", N, "}(", Int128(r), ")")

resulttype(::Type{Bits{N}}, ::Type{Bits{M}}) where {N,M} = Bits{max(N, M)}
resulttype(::Type{SBits{N}}, ::Type{SBits{M}}) where {N,M} = SBits{max(N, M)}
resulttype(::Type{Bits{N}}, ::Type{SBits{M}}) where {N,M} =
  throw(ArgumentError("mixing signed and unsigned hardware integers needs an explicit conversion"))
resulttype(::Type{SBits{N}}, ::Type{Bits{M}}) where {N,M} =
  throw(ArgumentError("mixing signed and unsigned hardware integers needs an explicit conversion"))
resulttype(::Type{T}, ::Type{Bool}) where T<:HWInt = T
resulttype(::Type{Bool}, ::Type{T}) where T<:HWInt = T
resulttype(::Type{T}, ::Type{<:Base.BitInteger}) where T<:HWInt = T
resulttype(::Type{<:Base.BitInteger}, ::Type{T}) where T<:HWInt = T

# the operator table, which trace.jl mirrors over `Wire`s; an entry added on one
# side without the other leaves simulation and emission unable to run the same design
for op in (:+, :-, :*, :&, :|, :⊻)
  @eval Base.$op(a::HWInt, b::HWInt) =
    (T = resulttype(typeof(a), typeof(b)); _rebuild(T, $op(_lift(T, a).val, _lift(T, b).val)))
  @eval Base.$op(a::HWInt, b::Union{Bool,Base.BitInteger}) = (T = resulttype(typeof(a), typeof(b)); $op(a, _lift(T, b)))
  @eval Base.$op(a::Union{Bool,Base.BitInteger}, b::HWInt) = (T = resulttype(typeof(a), typeof(b)); $op(_lift(T, a), b))
end
Base.:-(a::HWInt) = _rebuild(typeof(a), -a.val)
Base.:~(a::HWInt) = _rebuild(typeof(a), ~a.val)
Base.:!(a::Bits{1}) = Bits{1}(~a.val)

Base.:<<(a::T, n::Int) where T<:HWInt = n ≥ 0 ? _rebuild(T, a.val << _checkshift(T, n)) : a >> (-n)
Base.:>>(a::T, n::Int) where T<:HWInt = n ≥ 0 ? _rebuild(T, _shr(a, n)) : a << (-n)
_shr(a::Bits, n::Int) = a.val >> n
_shr(a::SBits, n::Int) = reinterpret(UInt128, Int128(a) >> n)
Base.:>>>(a::T, n::Int) where T<:HWInt = n ≥ 0 ? _rebuild(T, a.val >> n) : a << (-n)
Base.:<<(a::HWInt, n::Integer) = a << Int(n)
Base.:>>(a::HWInt, n::Integer) = a >> Int(n)
Base.:>>>(a::HWInt, n::Integer) = a >>> Int(n)
Base.:<<(a::HWInt, n::Unsigned) = a << Int(n)
Base.:>>(a::HWInt, n::Unsigned) = a >> Int(n)
Base.:>>>(a::HWInt, n::Unsigned) = a >>> Int(n)

function Base.bitrotate(a::T, n::Integer) where T<:HWInt
  N = bitwidth(T)
  n = mod(n, N)
  n == 0 ? a : _rebuild(T, (a.val << n) | (a.val >> (N - n)))
end

for op in (:(==), :<, :(<=))
  @eval Base.$op(a::HWInt, b::HWInt) =
    (T = resulttype(typeof(a), typeof(b)); $op(_cmpkey(_lift(T, a)), _cmpkey(_lift(T, b))))
  @eval Base.$op(a::HWInt, b::Union{Bool,Base.BitInteger}) = $op(_cmpkey(a), b)
  @eval Base.$op(a::Union{Bool,Base.BitInteger}, b::HWInt) = $op(a, _cmpkey(b))
end
Base.isless(a::HWInt, b::HWInt) = a < b
Base.hash(a::HWInt, h::UInt) = hash(BigInt(a), h)

Base.count_ones(a::HWInt) = Bits{_clog2(bitwidth(a) + 1)}(count_ones(a.val))
Base.leading_zeros(a::HWInt) = Bits{_clog2(bitwidth(a) + 1)}(leading_zeros(a.val) - (128 - bitwidth(a)))
Base.trailing_zeros(a::HWInt) = Bits{_clog2(bitwidth(a) + 1)}(min(trailing_zeros(a.val), bitwidth(a)))

# both operands are widened first, so the result width does not depend on which
# of them wins -- the hardware has one adder-width either way
Base.max(a::HWInt, b::HWInt) = (T = resulttype(typeof(a), typeof(b));
  x = _lift(T, a); y = _lift(T, b); ifelse(x < y, y, x))
Base.min(a::HWInt, b::HWInt) = (T = resulttype(typeof(a), typeof(b));
  x = _lift(T, a); y = _lift(T, b); ifelse(x < y, x, y))
Base.abs(a::SBits) = ifelse(a < 0, -a, a)
Base.abs(a::Bits) = a

Base.isodd(a::HWInt) = isodd(a.val)
Base.iseven(a::HWInt) = iseven(a.val)
Base.convert(::Type{T}, x::HWInt) where T<:HWInt = T(x)
# a plain integer converts only if it fits: `x::Bits{5} = 99` is a mistake, while
# `Bits{5}(99)` still truncates for anyone who means it
Base.convert(::Type{T}, x::Integer) where T<:HWInt = _lift(T, x)
Base.promote_rule(::Type{T}, ::Type{<:Union{Bool,Base.BitInteger}}) where T<:HWInt = T
Base.promote_rule(::Type{Bits{N}}, ::Type{Bits{M}}) where {N,M} = Bits{max(N, M)}
Base.promote_rule(::Type{SBits{N}}, ::Type{SBits{M}}) where {N,M} = SBits{max(N, M)}

Base.getindex(a::HWInt, i::Integer) = (0 ≤ i < bitwidth(a) || throw(BoundsError(a, i)); isodd(a.val >> i))
# the width of a slice is its range's length, which is a constant when the range is
# written out; the compiler only sees that if the call is inlined with its arguments
Base.@constprop :aggressive @inline function Base.getindex(a::HWInt, r::AbstractUnitRange{<:Integer})
  (0 ≤ first(r) && last(r) < bitwidth(a)) || throw(BoundsError(a, r))
  Bits{length(r)}(a.val >> first(r))
end
Base.firstindex(::HWInt) = 0
Base.lastindex(a::HWInt) = bitwidth(a) - 1

# A slice at a computed position. With stride 1 the base is a bit position,
# written `x[base .+ (0:width-1)]` (broadcasting is intercepted so the range
# never becomes a vector of indices) and emitted as Verilog's `x[base +: width]`.
# With stride == width the base is a part number from `part`, and the emitter
# decodes it instead: the alignment is what makes the hardware cheap, and a
# multiplied-out base would hide it from the synthesiser.
struct DynRange{B}
  base::B            # bit position, or part number when stride is the width
  width::Int         # how many bits the slice takes
  stride::Int        # 1 for a bit position, the width for a part number
end

DynRange(base, width) = DynRange(base, width, 1)
Base.length(d::DynRange) = d.width
Base.broadcasted(::typeof(+), b::HWInt, r::AbstractUnitRange{<:Integer}) =
  DynRange(first(r) == 0 ? b : b + first(r), length(r))
Base.getindex(a::HWInt, d::DynRange) = Bits{d.width}(a.val >> _dynbase(d, bitwidth(a), "value"))

"""
    static(v)

Marks a field's default as delivered by the bitstream rather than by reset:
`x::Bits{8} = static(5)` powers up at 5 and is left alone by `@reset`. A field
whose block has no `@reset` is static without saying so; `static` is how a field
opts out of a reset its block does have. In the emitted Verilog a static field
keeps its initializer; reset-delivered fields lose theirs, which frees the
synthesiser to use the flip-flops' enable and clear pins.
"""
static(v) = v

"""
    part(i, Bits{N})

Part number `i` of a word, `N` bits wide, numbered like bits: from zero at the
least significant end, so `x[part(0, Bits{8})]` is the low byte of `x` and
`x[part(1, Bits{8})]` the one above it. A computed index is kept as the part
number rather than multiplied out, so the emitter can decode it over the parts
that fit.
"""
function part(i::Union{Bool,Base.BitInteger}, ::Type{Bits{N}}) where N
  i ≥ 0 || throw(ArgumentError("a part number cannot be negative, got $i"))
  (Int(i) * N):(Int(i) * N + N - 1)
end
part(i, ::Type{Bits{N}}) where N = DynRange(i, N, N)

"""
    bits(x...)

Join hardware values into one word, most significant piece first, as Verilog's
`{a, b}` does. Every piece must have a known width, so a plain `Int` is refused.

```julia
bits(true, Bits{4}(0x5), false)    # Bits{6}(0b101010)
```
"""
bits(x::Bool) = Bits{1}(x)
bits(x::HWInt) = x
bits(x::Integer) = throw(ArgumentError("bits needs values of known width (Bool, Bits, SBits); got $x"))
bits(hi, rest...) = _concat(bits(hi), bits(rest...))

"""
    a ⊞ b

`bits(a, b)`: the two values side by side, `a` in the more significant half.
"""
⊞(a, b) = bits(a, b)

# the inverse of bits: take a word apart, most significant field first
Base.split(x::HWInt, widths::Integer...) = _splitwidths(x, widths)

# Idioms that hardware has and Julia does not. Each is written in terms of
# operations both the simulator and the tracer already have, so there is one
# definition and no chance of the two worlds drifting apart.

"""
    firstset(a)

The lowest set bit of `a`, as a value of the same width; zero if `a` is zero.
"""
firstset(a) = a & -a

"""
    onehot(Bits{N}, i)

An `N`-bit value with bit `i` set and the rest clear.
"""
onehot(::Type{Bits{N}}, i::Integer) where N = Bits{N}(UInt128(1) << Int(i))

"""
    popcount(a)

How many bits of `a` are set. The result is just wide enough to hold the count.
"""
popcount(a) = count_ones(a)

# A Pulse and a Timeout are stored as the plain register the struct macro
# substitutes, and the owning block advances each before its own statements. The
# names exist so that they are spelled the same everywhere and so a misuse can be
# named; a struct never holds one of these values.

"""
    Pulse

A one-cycle flag: a field declared `Pulse` is a `Bool` its own block clears at the
top of every cycle, so a write of `true` is high for exactly one cycle.

```julia
@quartz struct Rx
  got::Pulse
end
```
"""
struct Pulse end

"""
    Timeout{N}

A countdown: a field declared `Timeout{N}` is a `Bits{N}` its own block decrements
each cycle and holds at zero. Write it to arm it and ask `expired` when it is done.

```julia
@quartz struct Rx
  wait::Timeout{4} = 0
end
```
"""
struct Timeout{N} end

"""
    Step

The step of a `@sequence`: a field declared `Step` is sixteen bits in the Julia
model, starts at `START` and goes back to it on a `@reset`; the emitted register is
as wide as the steps need. It takes no default and no width.

```julia
@quartz struct Tx
  step::Step
end
```
"""
struct Step end

"""
    expired(t)

Whether a `Timeout` field has counted down to zero.
"""
expired(t) = t == 0

"""
    Edge

A `Bool` register that also remembers the level it held before, so its transitions
can be asked about. Write it like any register, `e ← x`, and read it bare for the
level; `rose(e)` and `fell(e)` are then true for exactly one cycle.

```julia
@quartz struct Sync
  sck::Edge
end
```
"""
struct Edge
  cur::Bool        # the level now
  prev::Bool       # the level before the last clock edge
end

# `rose`/`fell` report the transition the last edge registered -- one cycle after
# the sample that made it, glitch-free. `isrising`/`isfalling` compare an incoming
# sample with the level instead, and see the transition as it happens; keep those
# to signals already on this clock.

Edge(level::Bool=false) = Edge(level, level)
Base.convert(::Type{Edge}, x::Bool) = Edge(x)
Base.convert(::Type{Edge}, x::Union{HWInt,Base.BitInteger,BigInt}) =
  error("an Edge starts from a Bool, the level it has seen so far; got $x")
Base.getindex(e::Edge) = e.cur
Base.Bool(e::Edge) = e.cur
bitwidth(::Type{Edge}) = 1
bitwidth(::Edge) = 1

"""
    rose(e)

Whether the `Edge` field `e` went from low to high at the last clock edge. True for
exactly one cycle.
"""
rose(e::Edge) = e.cur & !e.prev

"""
    fell(e)

Whether the `Edge` field `e` went from high to low at the last clock edge. True for
exactly one cycle.
"""
fell(e::Edge) = !e.cur & e.prev

"""
    isrising(e, x)

Whether the incoming sample `x` is high while the `Edge` field `e` still holds low,
so the rise is seen in the cycle it happens rather than the one after.
"""
isrising(e::Edge, x) = _coerce(Bool, x) & !e.cur

"""
    isfalling(e, x)

Whether the incoming sample `x` is low while the `Edge` field `e` still holds high,
so the fall is seen in the cycle it happens rather than the one after.
"""
isfalling(e::Edge, x) = !_coerce(Bool, x) & e.cur

for f in (:rose, :fell)
  @eval $f(x) = error($(string(f)) * " reads the history of an Edge; declare the field as `name::Edge`")
end
for f in (:isrising, :isfalling)
  @eval $f(e, x) = error($(string(f)) *
    "(e, x) compares a sample with the level of an Edge; declare `e` as `name::Edge`")
end
Base.show(io::IO, e::Edge) =
  print(io, "Edge(", e.cur, rose(e) ? ", rose" : fell(e) ? ", fell" : "", ")")

"""
    MetaGuard{K}

A `K`-stage synchroniser for a signal that crosses into this clock domain. Feed it
with `g ← x` and read it bare for the value that has settled through all `K` stages.

```julia
@quartz struct Top
  @in async::Bool
  sync::MetaGuard{2}
end
```
"""
struct MetaGuard{K}
  reg::Bits{K}        # the shift register; the top bit is what the design reads
  MetaGuard{K}(r::Bits{K}) where K = new{K}(r)
end

MetaGuard{K}(x::Integer=false) where K = MetaGuard{K}(Bits{K}(isodd(x) ? _mask(K) : UInt128(0)))
Base.getindex(g::MetaGuard{K}) where K = g.reg[K-1]
bitwidth(::Type{<:MetaGuard}) = 1
bitwidth(g::MetaGuard) = 1
Base.show(io::IO, g::MetaGuard{K}) where K = print(io, "MetaGuard{", K, "}(", string(g.reg.val; base=2, pad=K), ")")

"""
    Pipeline{K,T}

A `K`-deep pipeline of `T` values. A write pushes a value in; reading it bare gives
what has come out the far end, or `missing` before anything has. `isnew` says a
fresh result arrived this cycle and `isready` says nothing is still inside.

```julia
@quartz struct Mac
  acc::Pipeline{3,Bits{16}}
end
```
"""
struct Pipeline{K,T}
  stages::NTuple{K,T}    # what is in flight, oldest last
  valid::Bits{K}         # which stages hold a real value
  out::T                 # the last value to come out
  hasout::Bool           # whether anything has come out yet
  isnew::Bool            # whether `out` arrived on the last edge
end

Pipeline{K,T}() where {K,T} = Pipeline{K,T}(ntuple(_ -> zero(T), K), Bits{K}(), zero(T), false, false)
Pipeline{K,T}(x::Pipeline) where {K,T} = x
Base.getindex(p::Pipeline) = p.hasout ? p.out : missing
bitwidth(::Type{Pipeline{K,T}}) where {K,T} = bitwidth(T)
bitwidth(p::Pipeline) = bitwidth(typeof(p))

"""
    isnew(p)

Whether the `Pipeline` field `p` delivered a fresh result at the last clock edge,
as opposed to still holding the previous one.
"""
isnew(p::Pipeline) = p.isnew

Base.show(io::IO, p::Pipeline{K,T}) where {K,T} =
  print(io, "Pipeline{", K, ",", T, "}(", p.hasout ? p.out : "-", p.isnew ? ", new" : "", ")")

"""
    Multicycle{K,T}

A combinational value whose logic is allowed `K` clock cycles to settle, on the
promise that its sources hold still that long. Drive it from a `@wire` block, read
it bare, and guard the read with `isready`; the tool is told to relax the path.

```julia
@quartz struct Corr
  sum::Multicycle{3,Bits{32}}
end
```
"""
struct Multicycle{K,T}
  val::T          # what the logic computes
  settle::Int     # edges since a source moved, saturating at K-1
end

function Multicycle{K,T}() where {K,T}
  K isa Int && K ≥ 2 ||
    throw(ArgumentError("a Multicycle path of $K cycles is not an exception; K must be at least 2"))
  Multicycle{K,T}(zero(T), 0)
end
Multicycle{K,T}(x::Multicycle{K,T}) where {K,T} = x
Base.getindex(m::Multicycle{K}, name::Symbol) where K = isready(m) ? m.val :
  error("$name is read $(m.settle + 1) cycle$(m.settle == 0 ? "" : "s") after its sources moved, " *
        "and its path is declared $K cycles; guard the read with isready($name)")
bitwidth(::Type{Multicycle{K,T}}) where {K,T} = bitwidth(T)
bitwidth(m::Multicycle) = bitwidth(typeof(m))
Base.show(io::IO, m::Multicycle{K,T}) where {K,T} =
  print(io, "Multicycle{", K, ",", T, "}(", m.val, isready(m) ? ", ready" : ", settling", ")")

"""
    isready(x)

Whether nothing is in flight, so that what `x` gives now is the result of its
latest input: a `Pipeline` that has a result out and no write still inside it, or
a `Multicycle` whose sources have been still for the cycles its path is declared.
"""
Base.isready(p::Pipeline) = p.hasout && p.valid.val == 0
Base.isready(m::Multicycle{K}) where K = m.settle ≥ K - 1

# a Pad is an inout pin (or bus): the module drives (val, oe), the outside world
# drives (ext, exten), and reading the pad resolves the two with the pull
@enum Pull NOPULL PULLUP PULLDOWN

const PULLNAMES = (NOPULL => :none, PULLUP => :pullup, PULLDOWN => :pulldown)

"""
    Pad{N}

An inout pin, or a bus of `N` of them, declared with `@io`. Write `drive(x)` or
`release()` to it and read it bare for the level the net settles to -- the design's
drive, the outside world's, and the pull together.

```julia
@quartz struct I2C
  @io sda::Pad{1} = Pad(:pullup)
end
```
"""
struct Pad{N}
  val::Bits{N}        # what this module drives
  oe::Bits{N}         # which bits it drives
  ext::Bits{N}        # what the outside world drives
  exten::Bits{N}      # which bits the outside world drives
  pullmode::Pull      # the pull on the net, as an enum so a pad stays inline
  activelow::Bool     # the pin is asserted low; the value always means asserted
  Pad{N}(val::Bits{N}, oe::Bits{N}, ext::Bits{N}, exten::Bits{N}, pull::Union{Pull,Symbol},
         activelow::Bool=false) where N =
    new{N}(val, oe, ext, exten, _aspull(pull), activelow)
end

Pad{N}(pull::Symbol=:none) where N = Pad{N}(Bits{N}(), Bits{N}(), Bits{N}(), Bits{N}(), pull)
Pad(pull::Symbol=:none) = Pad{1}(pull)
# the pull reads as the symbol the pad was declared with; storing an enum is what
# keeps a pad free of pointers, so it lives inline wherever it is held
Base.getproperty(p::Pad, f::Symbol) =
  f === :pull ? PULLNAMES[Int(getfield(p, :pullmode)) + 1].second : getfield(p, f)
Base.propertynames(::Pad) = (:val, :oe, :ext, :exten, :pull, :activelow)
padwidth(::Type{Pad{N}}) where N = N
bitwidth(::Type{Pad{N}}) where N = N
bitwidth(::Pad{N}) where N = N

function Base.getindex(p::Pad{N}) where N
  r, defined = _resolvebits(p)
  defined == _mask(N) ||
    throw(ErrorException("pad read with undriven bit(s) and no pull; drive the pad or give it a pull"))
  v = _padinvert(p, Bits{N}(r))
  N == 1 ? isodd(v.val) : v
end

Base.getindex(p::Pad, i::Integer) = bits(p[])[i]
Base.getindex(p::Pad, r::AbstractUnitRange{<:Integer}) = bits(p[])[r]
Base.getindex(p::Pad, d::DynRange) = bits(p[])[d]

function padchars(p::Pad{N}) where N
  r, defined = _resolvebits(p)
  String(map(i -> isodd(defined >> i) ? (isodd(r >> i) ? '1' : '0') : 'z', N-1:-1:0))
end

Base.show(io::IO, p::Pad{N}) where N =
  print(io, "Pad{", N, "}(", padchars(p), p.pull == :none ? "" : ", $(p.pull)", ")")

abstract type PadValue end
struct PadDrive{V,E} <: PadValue
  val::V
  en::E
end
struct PadRelease <: PadValue end
struct PadMux{C,A<:PadValue,B<:PadValue} <: PadValue
  cond::C
  a::A
  b::B
end

"""
    drive(x)
    drive(x, en)

What a block writes to a pad to hold it at `x`. With `en` only the bits `en` marks
are driven; the rest are left to whatever else is on the net.
"""
drive(x) = PadDrive(x, missing)
drive(x, en) = PadDrive(x, en)

"""
    release()

What a block writes to a pad to let go of it, so the net is left to the outside
world and the pad's pull.
"""
release() = PadRelease()

Base.ifelse(c::Bool, a::PadValue, b::PadValue) = c ? a : b
Base.ifelse(c::Bits{1}, a::PadValue, b::PadValue) = Bool(c) ? a : b
Base.ifelse(c, a::PadValue, b::PadValue) = PadMux(c, a, b)
Base.ifelse(c, a, b::PadValue) = ifelse(c, drive(a), b)
Base.ifelse(c, a::PadValue, b) = ifelse(c, a, drive(b))
Base.ifelse(c::Bool, a, b::PadValue) = ifelse(c, drive(a), b)
Base.ifelse(c::Bool, a::PadValue, b) = ifelse(c, a, drive(b))

Base.rem(a::Bits{N}, b::Integer) where N = Bits{N}(rem(a.val, UInt128(_divisor(b))))
Base.rem(a::SBits{N}, b::Integer) where N = SBits{N}(reinterpret(UInt128, rem(Int128(a), _divisor(b))))
Base.div(a::Bits{N}, b::Integer) where N = Bits{N}(div(a.val, UInt128(_divisor(b))))
Base.div(a::SBits{N}, b::Integer) where N = SBits{N}(reinterpret(UInt128, div(Int128(a), _divisor(b))))
Base.mod(a::Bits, b::Integer) = rem(a, b)
Base.mod(a::SBits, b::Integer) = throw(ArgumentError("mod on an SBits differs from Verilog %; use rem"))

### helpers

_mask(N) = N == 128 ? typemax(UInt128) : (UInt128(1) << N) - 1

_checkwiden(::Type{T}, x) where T = bitwidth(x) ≤ bitwidth(T) ||
  throw(ArgumentError("$T(...) would drop bits from a $(bitwidth(x))-bit value; " *
                      "write trunc($T, x) if that is what you mean"))

_toraw(x::Unsigned) = UInt128(x)
_toraw(x::Signed) = reinterpret(UInt128, Int128(x))
_toraw(x::BigInt) = UInt128(mod(x, BigInt(1) << 128))
_toraw(x::Bits) = x.val
_toraw(x::SBits{N}) where N = reinterpret(UInt128, Int128(x))
_toraw(x::Bool) = UInt128(x)

_rebuild(::Type{Bits{N}}, v) where N = Bits{N}(v)
_rebuild(::Type{SBits{N}}, v) where N = SBits{N}(v)

_fits(::Type{Bits{N}}, x::Integer) where N = 0 ≤ x ≤ _mask(N)
_fits(::Type{SBits{N}}, x::Integer) where N = -(Int128(1) << (N - 1)) ≤ x < (Int128(1) << (N - 1))
_fits(::Type{Bits{N}}, x::Bool) where N = true
_fits(::Type{SBits{N}}, x::Bool) where N = true

function _lift(::Type{T}, x::Integer) where T<:HWInt
  _fits(T, x) || throw(InexactError(:convert, T, x))
  T(x)
end
_lift(::Type{T}, x::HWInt) where T<:HWInt = T(x)
_lift(::Type{T}, x::T) where T<:HWInt = x

# every bit shifted out and none shifted in: the result is zero whatever the input,
# which is a mistake stated as a shift rather than a shift worth making
_checkshift(::Type{T}, n) where T<:HWInt = n < bitwidth(T) ? n :
  throw(ArgumentError("shifting a $(bitwidth(T))-bit value left by $n leaves nothing; " *
                      "widen it first if that is what you mean"))

# a shift register takes a bit in at the bottom and drops the top one, which is the
# one shift where losing the whole width is the point
_shiftin(r::Bits{K}, x) where K = Bits{K}((r.val << 1) | UInt128(x))

_cmpkey(x::Bits) = x.val
_cmpkey(x::SBits) = Int128(x)

_clog2(n) = n ≤ 1 ? 1 : ceil(Int, log2(n))

# A base that runs off the end reads as zero here and as x in Verilog, so refuse it
# rather than let the two worlds disagree.
function _dynbase(d::DynRange, W::Int, what)
  b = Int(d.base) * d.stride
  0 ≤ b && b + d.width ≤ W ||
    throw(ArgumentError("bits $(b) +: $(d.width) do not fit a $(W)-bit $what"))
  b
end

_concat(a::HWInt, b::HWInt) = Bits{bitwidth(a) + bitwidth(b)}(
  ((_toraw(a) & _mask(bitwidth(a))) << bitwidth(b)) | (_toraw(b) & _mask(bitwidth(b))))

function _splitwidths(x, widths)
  sum(widths) == bitwidth(x) ||
    throw(ArgumentError("split widths $(widths) do not add up to $(bitwidth(x)) bits"))
  _splitparts(x, bitwidth(x), widths)
end

# taken most significant field first; written as a recursion rather than a loop
# over a captured `lo`, which Julia would box and leave the parts untyped
_splitparts(x, lo, ::Tuple{}) = ()
function _splitparts(x, lo, widths)
  w = Int(widths[1])
  (x[lo-w:lo-1], _splitparts(x, lo - w, Base.tail(widths))...)
end

_smear(a) = (N = bitwidth(a); v = a; k = 1; while k < N; v = v | (v >> k); k *= 2; end; v)

_shiftguard(g::MetaGuard{K}, x::Bool) where K = MetaGuard{K}(_shiftin(g.reg, x))

function _advance(p::Pipeline{K,T}, x, valid::Bool) where {K,T}
  if K == 0
    return Pipeline{K,T}((), Bits{0}(), valid ? x : p.out, p.hasout | valid, valid)
  end
  outv = p.valid[K-1]
  outx = p.stages[K]
  stages = (x, p.stages[1:K-1]...)
  v = _shiftin(p.valid, valid)
  Pipeline{K,T}(stages, v, outv ? outx : p.out, p.hasout | outv, outv)
end

_settlestep(m::Multicycle{K,T}, restart::Bool) where {K,T} =
  Multicycle{K,T}(m.val, restart ? 0 : min(m.settle + 1, K - 1))

_aspull(pull::Pull) = pull
_aspull(pull::Symbol) =
  (i = findfirst(q -> q.second === pull, PULLNAMES);
   i === nothing ? throw(ArgumentError("Pad pull must be :none, :pullup or :pulldown")) :
                   PULLNAMES[i].first)

# An active-low pin is asserted by a zero on the wire. The stored state is the wire,
# because that is what the board sees and what a co-simulation compares; the
# inversion sits at the two points where the design speaks: what it drives out, and
# what it reads back. The output enable and the pull are not levels on the wire, so
# neither of them inverts.
_lowpad(p::Pad{N}) where N = Pad{N}(p.val, p.oe, p.ext, p.exten, p.pull, true)
_padinvert(p::Pad{N}, v::Bits{N}) where N = p.activelow ? ~v : v

# A pulled net is wired-AND (pullup) or wired-OR (pulldown): several drivers may
# hold it at the same level, which is how open-drain buses work. A net with no pull
# is push-pull, where every bit must have exactly one driver.
function _resolvebits(p::Pad{N}) where N
  m = _mask(N)
  p.pull == :pullup && return (m & ~((p.oe.val & ~p.val.val) | (p.exten.val & ~p.ext.val)), m)
  p.pull == :pulldown && return (m & ((p.oe.val & p.val.val) | (p.exten.val & p.ext.val)), m)
  ((p.val.val & p.oe.val) | (p.ext.val & p.exten.val & ~p.oe.val), m & (p.oe.val | p.exten.val))
end

function _padfold(::Type{Bits{N}}, v::PadValue) where N
  v isa PadRelease && return (Bits{N}(), Bits{N}())
  if v isa PadDrive
    val = v.val === missing ? Bits{N}() : _coerce(Bits{N}, v.val)
    en = v.en === missing ? Bits{N}(_mask(N)) :
         v.en isa Bool ? (v.en ? Bits{N}(_mask(N)) : Bits{N}()) :
         (N > 1 && bitwidth(v.en) == 1) ? (Bool(v.en) ? Bits{N}(_mask(N)) : Bits{N}()) :
         _coerce(Bits{N}, v.en)
    return (val, en)
  end
  Bool(v.cond) ? _padfold(Bits{N}, v.a) : _padfold(Bits{N}, v.b)
end

function _divisor(b::Integer)
  b isa Union{Bool,Base.BitInteger,BigInt} && b > 0 ||
    throw(ArgumentError("division and modulo need a positive plain-integer constant divisor"))
  Int128(b)
end
