# The same operations reg.jl gives hardware values, defined again over symbolic
# `Wire`s. Running a block's body with wires in place of values builds the graph
# the emitters read, so the Verilog and the simulation come from one source.
#
# The operator tables below mirror reg.jl's. An operation added there without its
# counterpart here compiles in simulation and fails at emission; one added with
# different semantics fails in neither place while the two worlds disagree.

mutable struct Wire{N} <: Integer
  op::Symbol
  args::Vector{Any}
  signed::Bool
  id::Int
  name::Symbol
end

const WIRE_COUNTER = Ref(0)

function Wire{N}(op::Symbol, args::Vector{Any}; signed=false, name=Symbol("")) where N
  N isa Int && N ≥ 0 || throw(ArgumentError("wire width must be a non-negative Int, got $N"))
  Wire{N}(op, args, signed, WIRE_COUNTER[] += 1, name)
end

bitwidth(::Type{Wire{N}}) where N = N
bitwidth(::Wire{N}) where N = N
issigned(w::Wire) = w.signed
isleaf(w::Wire) = w.op in (:input, :reg, :const, :mgout)

struct MaybeWire
  value::Wire
  hasout::Wire{1}
end

Base.show(io::IO, w::Wire{N}) where N = print(io, "Wire{", N, "}(", w.op, isleaf(w) ? " " * string(w.name) : "", ")")

const BIGLIT = Union{Bool,Base.BitInteger,BigInt,HWInt}

constant(x::Bool, N=1; signed=false) = Wire{N}(:const, Any[Int128(x)]; signed, name=:const)
constant(x::HWInt, N=bitwidth(x); signed=issigned(typeof(x))) = Wire{N}(:const, Any[Int128(x)]; signed, name=:const)
function constant(x::Integer, N; signed=x < 0)
  (signed ? _fits(SBits{N}, x) : _fits(Bits{N}, x)) || throw(InexactError(:constant, Wire{N}, x))
  Wire{N}(:const, Any[Int128(x)]; signed, name=:const)
end

function _binop(op, a, b)
  (a isa Wire || b isa Wire) || error("internal: no wire operand")
  if a isa Wire && b isa Wire
    issigned(a) == issigned(b) ||
      throw(ArgumentError("mixing signed and unsigned hardware integers needs an explicit conversion"))
    N = max(bitwidth(a), bitwidth(b))
    return Wire{N}(op, Any[a, b]; signed=issigned(a))
  end
  w, c = a isa Wire ? (a, b) : (b, a)
  cw = constant(c, bitwidth(w); signed=issigned(w))
  a isa Wire ? Wire{bitwidth(w)}(op, Any[a, cw]; signed=issigned(w)) :
    Wire{bitwidth(w)}(op, Any[cw, b]; signed=issigned(w))
end

# the mirror of reg.jl's operator table; keep the two in step
for (f, op) in ((:+, :add), (:-, :sub), (:*, :mul), (:&, :and), (:|, :or), (:⊻, :xor))
  @eval Base.$f(a::Wire, b::Wire) = _binop($(QuoteNode(op)), a, b)
  @eval Base.$f(a::Wire, b::BIGLIT) = _binop($(QuoteNode(op)), a, b)
  @eval Base.$f(a::BIGLIT, b::Wire) = _binop($(QuoteNode(op)), a, b)
end
Base.:-(a::Wire{N}) where N = Wire{N}(:neg, Any[a]; signed=a.signed)
Base.:~(a::Wire{N}) where N = Wire{N}(:not, Any[a]; signed=a.signed)
Base.:!(a::Wire{1}) = Wire{1}(:not, Any[a])

for (f, op) in ((:(==), :eq), (:!=, :ne), (:<, :lt), (:(<=), :le), (:>, :gt), (:(>=), :ge))
  @eval function Base.$f(a::Wire, b::Wire)
    a.signed == b.signed || throw(ArgumentError("signed/unsigned comparison needs a conversion"))
    Wire{1}($(QuoteNode(op)), Any[a, b])
  end
  @eval Base.$f(a::Wire, b::BIGLIT) = Wire{1}($(QuoteNode(op)), Any[a, constant(b, bitwidth(a); signed=a.signed)])
  @eval Base.$f(a::BIGLIT, b::Wire) = Wire{1}($(QuoteNode(op)), Any[constant(a, bitwidth(b); signed=b.signed), b])
  @eval Base.$f(a::Wire, b::BigInt) = Wire{1}($(QuoteNode(op)), Any[a, constant(b, bitwidth(a); signed=a.signed)])
  @eval Base.$f(a::BigInt, b::Wire) = Wire{1}($(QuoteNode(op)), Any[constant(a, bitwidth(b); signed=b.signed), b])
end

Base.:<<(a::Wire{N}, n::Int) where N =
  n ≥ 0 ? Wire{N}(:shl, Any[a, _checkshift(Bits{N}, n)]; signed=a.signed) : a >> (-n)
Base.:>>(a::Wire{N}, n::Int) where N = n ≥ 0 ? Wire{N}(a.signed ? :sra : :shr, Any[a, n]; signed=a.signed) : a << (-n)
Base.:>>>(a::Wire{N}, n::Int) where N = n ≥ 0 ? Wire{N}(:shr, Any[a, n]; signed=a.signed) : a << (-n)
Base.:<<(a::Wire{N}, n::Wire) where N = Wire{N}(:shl, Any[a, n]; signed=a.signed)
Base.:>>(a::Wire{N}, n::Wire) where N = Wire{N}(a.signed ? :sra : :shr, Any[a, n]; signed=a.signed)
Base.:>>>(a::Wire{N}, n::Wire) where N = Wire{N}(:shr, Any[a, n]; signed=a.signed)
Base.:<<(a::Wire, n::Integer) = a << Int(n)
Base.:>>(a::Wire, n::Integer) = a >> Int(n)
Base.:>>>(a::Wire, n::Integer) = a >>> Int(n)
Base.:<<(a::Wire, n::Unsigned) = a << Int(n)
Base.:>>(a::Wire, n::Unsigned) = a >> Int(n)
Base.:>>>(a::Wire, n::Unsigned) = a >>> Int(n)
Base.:<<(a::Integer, n::Wire) = error("shifting a constant by a hardware value is not supported")
Base.:<<(a::HWInt, n::Wire) = constant(a) << n
Base.bitrotate(a::Wire{N}, n::Integer) where N = (n = mod(n, N); n == 0 ? a : Wire{N}(:rotl, Any[a, n]))

Base.rem(a::Wire{N}, b::Integer) where N =
  Wire{N}(:mod, Any[a, constant(_divisor(b), N; signed=a.signed)]; signed=a.signed)
Base.div(a::Wire{N}, b::Integer) where N =
  Wire{N}(:div, Any[a, constant(_divisor(b), N; signed=a.signed)]; signed=a.signed)
Base.mod(a::Wire, b::Integer) = rem(a, b)

Base.count_ones(a::Wire{N}) where N = Wire{_clog2(N + 1)}(:popcount, Any[a])
function Base.ifelse(c::Wire{1}, a::Wire, b::Wire)
  a.signed == b.signed || throw(ArgumentError("mux arms must have the same signedness"))
  Wire{max(bitwidth(a), bitwidth(b))}(:mux, Any[c, a, b]; signed=a.signed)
end
Base.ifelse(c::Wire{1}, a::Wire, b::BIGLIT) = ifelse(c, a, constant(b, bitwidth(a); signed=a.signed))
Base.ifelse(c::Wire{1}, a::BIGLIT, b::Wire) = ifelse(c, constant(a, bitwidth(b); signed=b.signed), b)
Base.ifelse(c::Wire{1}, a::Bool, b::Bool) = ifelse(c, constant(a), constant(b))
Base.ifelse(c::Wire{1}, a::BIGLIT, b::BIGLIT) = ifelse(c, constant(a), constant(b))
Base.max(a::Wire, b::Wire) = ifelse(a < b, b, a)
Base.min(a::Wire, b::Wire) = ifelse(a < b, a, b)
Base.max(a::Wire, b::BIGLIT) = max(a, constant(b, bitwidth(a); signed=a.signed))
Base.max(a::BIGLIT, b::Wire) = max(constant(a, bitwidth(b); signed=b.signed), b)
Base.min(a::Wire, b::BIGLIT) = min(a, constant(b, bitwidth(a); signed=a.signed))
Base.min(a::BIGLIT, b::Wire) = min(constant(a, bitwidth(b); signed=b.signed), b)
Base.abs(a::Wire) = a.signed ? ifelse(a < 0, -a, a) : a
Base.zero(::Wire{N}) where N = constant(0, N)
Base.zero(::Type{Wire{N}}) where N = constant(0, N)
Base.one(::Wire{N}) where N = constant(1, N)
Base.isodd(a::Wire) = a[0]
Base.iseven(a::Wire) = !a[0]
Base.ismissing(::Wire) = false
Base.coalesce(a::Wire, _) = a
Base.coalesce(m::MaybeWire, d) = ifelse(m.hasout, m.value, d)
Base.ismissing(m::MaybeWire) = !m.hasout

Base.getindex(a::Wire{N}, i::Integer) where N = (0 ≤ i < N || throw(BoundsError(a, i)); Wire{1}(:bit, Any[a, Int(i)]))
function Base.getindex(a::Wire{N}, r::AbstractUnitRange{<:Integer}) where N
  (0 ≤ first(r) && last(r) < N) || throw(BoundsError(a, r))
  Wire{length(r)}(:slice, Any[a, Int(first(r)), Int(last(r))])
end
Base.firstindex(::Wire) = 0
Base.lastindex(::Wire{N}) where N = N - 1

Base.broadcasted(::typeof(+), b::Wire, r::AbstractUnitRange{<:Integer}) =
  DynRange(first(r) == 0 ? b : b + first(r), length(r))
Base.getindex(a::Wire, d::DynRange) = Wire{d.width}(:dynslice, Any[a, d.base, d.width, d.stride])

Base.split(x::Wire, widths::Integer...) = _splitwidths(x, widths)

# leading/trailing zeros have no Verilog operator, so they are built from ones that
# do. Both agree with the simulator's direct versions, zero input included: an
# all-zero input gives N in each case.
Base.trailing_zeros(a::Wire) = count_ones(firstset(a) - 1)
Base.leading_zeros(a::Wire{N}) where N = N - count_ones(_smear(a))
onehot(::Type{Bits{N}}, i::Wire) where N = Wire{N}(:shl, Any[constant(1, N), i])

bits(x::Wire) = x
_concat(a::Wire, b::Wire) = Wire{bitwidth(a) + bitwidth(b)}(:concat, Any[a, b])
_concat(a::Wire, b::HWInt) = _concat(a, constant(b))
_concat(a::HWInt, b::Wire) = _concat(constant(a), b)

resize(::Type{Bits{N}}, a::Wire) where N = Wire{N}(:resize, Any[a])
resize(::Type{SBits{N}}, a::Wire) where N = Wire{N}(:resize, Any[a]; signed=true)
Bits{N}(a::Wire) where N = (_checkwiden(Bits{N}, a); resize(Bits{N}, a))
SBits{N}(a::Wire) where N = (_checkwiden(SBits{N}, a); resize(SBits{N}, a))
Base.trunc(::Type{T}, a::Wire) where T<:HWInt = resize(T, a)
Base.Bool(a::Wire{1}) = a

(::Type{T})(::Wire) where T<:Base.BitInteger = error("cannot convert a hardware value to $T; use Bits{N}/SBits{N}")

function _nonbool(x)
  error("a branch condition depends on a hardware value ($x); " *
        "use ifelse/min/max/abs, or `&`, `|` instead of `&&`, `||`")
end

struct TMetaGuard
  name::Symbol
  K::Int
end
Base.getindex(g::TMetaGuard) = Wire{1}(:mgout, Any[g.K - 1, g.K]; name=Symbol(g.name, "_mg"))

# an edge reads as its level register; its history is the shadow register the
# emitter shifts every enabled cycle. The suffixes these companion nets take are
# the ones quartz.jl's derived-cell check knows about; adding one here without
# adding it there lets a multicycle pattern match cells it should not.
struct TEdge
  name::Symbol
end
Base.getindex(e::TEdge) = Wire{1}(:reg, Any[]; name=e.name)
_edgeprev(e::TEdge) = Wire{1}(:reg, Any[]; name=Symbol(e.name, "_prev"))
rose(e::TEdge) = e[] & !_edgeprev(e)
fell(e::TEdge) = !e[] & _edgeprev(e)
isrising(e::TEdge, x) = x & !e[]
isfalling(e::TEdge, x) = !x & e[]

struct TPad
  name::Symbol
  vname::Symbol
  N::Int
  pull::Symbol
  activelow::Bool
end
# reading a pad reads the pin itself, under the name the pin has, inverted for an
# active-low one -- the mirror of what a drive does on the way out
Base.getindex(p::TPad) = (w = Wire{p.N}(:input, Any[]; name=p.vname); p.activelow ? ~w : w)
Base.getindex(p::TPad, i) = p[][i]

# an instance field: its outputs read as wires, and it is never stepped by a block
struct TSubmodule
  name::Symbol
  T::Type
end

Base.step(s::TSubmodule, args...; kwargs...) =
  error("$(getfield(s, :name)) is an instance, and is stepped by the simulator; wire its " *
        "clocks and inputs in a @wire block")

function Base.getproperty(s::TSubmodule, f::Symbol)
  f in (:name, :T) && return getfield(s, f)
  ST = getfield(s, :T)
  bb = blackbox(ST)
  if bb !== nothing
    i = findfirst(p -> p.name == f, bb.ports)
    i === nothing && error("black box $(bb.verilogname) has no port $f")
    bb.ports[i].dir == :output || error("port $f of black box $(bb.verilogname) is not an output")
    return Wire{bb.ports[i].width}(:reg, Any[]; signed=bb.ports[i].signed,
                                   name=Symbol(getfield(s, :name), "_", f))
  end
  hasfield(ST, f) ||
    error("submodule $(getfield(s, :name))::$(nameof(ST)) has no field $f")
  isport(ST, f, :out) ||
    error("only the @out ports of submodule $(getfield(s, :name)) may be read, not $f")
  FT = fieldtype(ST, f)
  Wire{bitwidth(FT)}(:reg, Any[]; signed=issigned(FT), name=Symbol(getfield(s, :name), "_", f))
end

struct TPipeline
  name::Symbol
  K::Int
  T::Type
end
Base.getindex(p::TPipeline) =
  MaybeWire(Wire{bitwidth(p.T)}(:reg, Any[]; signed=issigned(p.T), name=Symbol(p.name, "_out")),
            Wire{1}(:reg, Any[]; name=Symbol(p.name, "_hasout")))
isnew(p::TPipeline) = Wire{1}(:reg, Any[]; name=Symbol(p.name, "_isnew"))
Base.isready(p::TPipeline) = Wire{1}(:reg, Any[]; name=Symbol(p.name, "_ready"))

# a multicycle wire reads as the net of its own name, which the comb section assigns
struct TMulticycle
  name::Symbol
  K::Int
  T::Type
end
Base.getindex(m::TMulticycle, ::Symbol) = Wire{bitwidth(m.T)}(:reg, Any[]; signed=issigned(m.T), name=m.name)
Base.isready(m::TMulticycle) = Wire{1}(:reg, Any[]; name=Symbol(m.name, "_ready"))

struct TraceState
  fields::Dict{Symbol,Any}
end
Base.getproperty(s::TraceState, f::Symbol) = getfield(s, :fields)[f]

# reading a clock net as data is just the net name in an expression
clocklevel(::TraceState, net::Symbol) = Wire{1}(:input, Any[]; name=net)

mutable struct WriteNode
  field::Symbol
  value::Any
  range::Union{Nothing,UnitRange{Int},DynRange}
end
WriteNode(field::Symbol, value) = WriteNode(field, value, nothing)
struct IfNode
  cond::Wire{1}
  then::Vector{Any}
  els::Vector{Any}
end
# a log statement of the design: its level, message and the values it names
struct LogNode
  level::LogLevel
  msg::Any
  args::Vector{Pair{Symbol,Any}}
  mod::Symbol
end
# a `@check` that failed on this path
struct CheckNode
  cond::String
  mod::Symbol
end
# a wire to a data input of a black box
struct ConnNode
  field::Symbol
  port::Symbol
  value::Any
end

mutable struct TraceCtx
  stack::Vector{Vector{Any}}
end
TraceCtx() = TraceCtx([Any[]])
current(ctx::TraceCtx) = ctx.stack[end]

function trace_write!(ctx::TraceCtx, f::Symbol, v)
  push!(current(ctx), WriteNode(f, v))
  nothing
end

function trace_writepart!(ctx::TraceCtx, f::Symbol, idx, v)
  push!(current(ctx), WriteNode(f, v, _asrange(idx)))
  nothing
end

function trace_conn!(ctx::TraceCtx, f::Symbol, port::Symbol, v)
  push!(current(ctx), ConnNode(f, port, v))
  nothing
end

trace_log!(ctx::TraceCtx, level, msg, kw, mod::Symbol) =
  (push!(current(ctx), LogNode(level, msg, [k => v for (k, v) in pairs(kw)], mod)); nothing)
trace_check!(ctx::TraceCtx, cond::String, mod::Symbol) = (push!(current(ctx), CheckNode(cond, mod)); nothing)

function trace_if!(ctx::TraceCtx, c, thenf, elsef)
  c isa Bool && return (c ? thenf() : elsef(); nothing)
  c isa Wire{1} || _nonbool(c)
  node = IfNode(c, Any[], Any[])
  push!(current(ctx), node)
  push!(ctx.stack, node.then); thenf(); pop!(ctx.stack)
  push!(ctx.stack, node.els); elsef(); pop!(ctx.stack)
  nothing
end

function _rewrite_trace(ex, state, ctx; inbranch=false, stmt=true)
  ex isa Expr || return ex
  if stmt && (_iswrite(ex, state) || _ischainwrite(ex, state))
    val = _rewrite_trace(_writevalue(ex), state, ctx; inbranch, stmt=false)
    idx, port = _writeindex(ex), _writeport(ex)
    port === nothing ||
      return :($QuartzHDL.trace_conn!($ctx, $(QuoteNode(_writefield(ex))), $(QuoteNode(port)), $val))
    idx === nothing && return :($QuartzHDL.trace_write!($ctx, $(QuoteNode(_writefield(ex))), $val))
    return :($QuartzHDL.trace_writepart!($ctx, $(QuoteNode(_writefield(ex))), $idx, $val))
  elseif ex.head == :if && _islogif(ex)
    # a log statement is recorded whatever the run-time filter would say
    call = ex.args[2].args[end]
    rw(a) = _rewrite_trace(a, state, ctx; inbranch, stmt=false)
    return :($QuartzHDL.trace_log!($ctx, $(call.args[2]), $(rw(call.args[3])), $(rw(call.args[4])), $(call.args[5])))
  elseif ex.head == :call && _isqcall(ex.args[1], :simcheck)
    return :($QuartzHDL.trace_check!($ctx, $(ex.args[2]), $(ex.args[3])))
  elseif !stmt && ex.head == :if && length(ex.args) == 3
    # `c ? a : b` in a value position is a mux, not a branch: both arms are wires
    return :($(Base.ifelse)($(_rewrite_trace(ex.args[1], state, ctx; inbranch, stmt=false)),
                            $(_rewrite_trace(ex.args[2], state, ctx; inbranch, stmt=false)),
                            $(_rewrite_trace(ex.args[3], state, ctx; inbranch, stmt=false))))
  elseif ex.head == :if || ex.head == :elseif
    c = _rewrite_trace(ex.args[1], state, ctx; inbranch, stmt=false)
    thenb = _rewrite_trace(ex.args[2], state, ctx; inbranch=true, stmt)
    elseb = length(ex.args) == 3 ? _rewrite_trace(ex.args[3], state, ctx; inbranch=true, stmt) : nothing
    return :($QuartzHDL.trace_if!($ctx, $c, () -> $thenb, () -> $elseb))
  elseif ex.head == :(=) && inbranch && ex.args[1] isa Symbol && !Base.isgensym(ex.args[1])
    error("a local variable may not be assigned inside an `if` (hardware would evaluate both branches): $ex")
  elseif ex.head == :while
    error("`while` is not allowed in a block")
  elseif ex.head in (:block,)
    return Expr(ex.head, map(a -> _rewrite_trace(a, state, ctx; inbranch, stmt), ex.args)...)
  elseif ex.head in (:for, :let)
    return Expr(ex.head, ex.args[1], _rewrite_trace(ex.args[2], state, ctx; inbranch, stmt))
  elseif ex.head == :&&
    return :($QuartzHDL._and($(_rewrite_trace(ex.args[1], state, ctx; inbranch, stmt=false)),
                             $(_rewrite_trace(ex.args[2], state, ctx; inbranch, stmt=false))))
  elseif ex.head == :||
    return :($QuartzHDL._or($(_rewrite_trace(ex.args[1], state, ctx; inbranch, stmt=false)),
                            $(_rewrite_trace(ex.args[2], state, ctx; inbranch, stmt=false))))
  end
  Expr(ex.head, map(a -> _rewrite_trace(a, state, ctx; inbranch, stmt=false), ex.args)...)
end

_isqcall(f, name::Symbol) = f isa Expr && f.head == :. && f.args[1] === QuartzHDL && f.args[2] == QuoteNode(name)
_islogif(ex) = _isqcall(ex.args[1] isa Expr && ex.args[1].head == :call ? ex.args[1].args[1] : nothing, :_logon) &&
  length(ex.args) == 2 && ex.args[2] isa Expr && ex.args[2].head == :block

_and(a::Bool, b::Bool) = a && b
_and(a, b) = a & b
_or(a::Bool, b::Bool) = a || b
_or(a, b) = a | b

function tracefunction(def::BlockDef)
  ctx = gensym(:ctx)
  tbody = _rewrite_trace(def.body, :this, ctx)
  f = gensym(:blk)
  ex = :(function $f($ctx, this, $(def.params...), $(def.inputs...))
    $tbody
    nothing
  end)
  Core.eval(def.mod, ex)
end

# the values of the type parameters the block names, for this instantiation
function tracewheres(def::BlockDef, T::Type)
  t = def.typeexpr
  t isa Expr && t.head == :curly || return Dict{Symbol,Any}()
  Dict{Symbol,Any}(p => v for (p, v) in zip(t.args[2:end], T.parameters) if p isa Symbol)
end

_fieldwidth(s::TraceState, ::Val{f}) where f = _tracewidth(getfield(s, :fields)[f])
_tracewidth(w::Wire) = bitwidth(w)
_tracewidth(p::TPad) = p.N
_tracewidth(p::TPipeline) = bitwidth(p.T)
_tracewidth(m::TMulticycle) = bitwidth(m.T)
_tracewidth(::TMetaGuard) = 1
_tracewidth(::TEdge) = 1
bitwidth(x::Union{TPad,TPipeline,TMulticycle,TMetaGuard,TEdge}) = _tracewidth(x)
