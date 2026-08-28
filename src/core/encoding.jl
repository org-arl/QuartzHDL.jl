# A named set of values over a Bits{N}: FSM states, protocol tags, command codes.
# Pure sugar -- the values are ordinary registers, so nothing about simulation,
# tracing or emission changes.

struct Encoding{Name,NT<:NamedTuple}
  values::NT
  docs::NamedTuple
end

"""
    encname(e)
    encname(e, v)

With one argument, the name of encoding `e`. With two, the name `e` gives the value
`v`, or `nothing` if it names no such value -- which is what logs and waveform
dumps show in place of the number.

```julia
encname(State)          # :State
encname(State, s)       # :IDLE
```
"""
encname(::Encoding{Name}) where Name = Name
Base.keys(e::Encoding) = keys(getfield(e, :values))
Base.values(e::Encoding) = values(getfield(e, :values))
Base.length(e::Encoding) = length(getfield(e, :values))
bitwidth(e::Encoding) = bitwidth(first(values(e)))

function Base.getproperty(e::Encoding{Name}, s::Symbol) where Name
  v = getfield(e, :values)
  haskey(v, s) || error("$Name has no value named $s; it has $(join(keys(v), ", "))")
  v[s]
end

Base.show(io::IO, e::Encoding{Name}) where Name =
  print(io, Name, "(", join(("$k = $(v)" for (k, v) in pairs(getfield(e, :values))), ", "), ")")

"""
    statedoc(e, s)

What value `s` of encoding `e` was declared to mean -- the string written above its
line -- or `nothing` if it has none.
"""
statedoc(e::Encoding, s::Symbol) = (d = getfield(e, :docs); haskey(d, s) ? d[s] : nothing)

encname(e::Encoding, v) = (nt = getfield(e, :values);
                           i = findfirst(x -> x == v, values(nt)); i === nothing ? nothing : keys(nt)[i])

"""
    @encoding Name begin ... end
    @encoding Name::W encoding=:onehot begin ... end

Declares a named set of values over a `Bits` -- FSM states, protocol tags, command
codes. A field declared with the encoding as its type is a register of that width
that knows its names, so a bare name resolves where the field is written or
compared. `W` fixes the width and `encoding` picks `:binary`, `:onehot` or `:gray`.

```julia
@encoding State begin
  IDLE
  RUN
end
```
"""
macro encoding(args...)
  esc(_encoding(args))
end

function _encoding(args)
  length(args) ≥ 2 || error("@encoding: expected a name and a begin ... end block")
  name = args[1]
  block = args[end]
  scheme = :binary
  width = nothing
  if name isa Expr && name.head == :(::)
    width = name.args[2]
    name = name.args[1]
  end
  name isa Symbol || error("@encoding: expected a name, got $name")
  for a in args[2:end-1]
    a isa Expr && a.head == :(=) && a.args[1] == :encoding ||
      error("@encoding: unexpected argument $a")
    scheme = a.args[2] isa QuoteNode ? a.args[2].value : a.args[2]
  end
  scheme in (:binary, :onehot, :gray) ||
    error("@encoding: encoding must be :binary, :onehot or :gray, got $scheme")
  block isa Expr && block.head == :block || error("@encoding: expected a begin ... end block")
  names = Symbol[]
  vals = Any[]
  docs = Pair{Symbol,String}[]
  for (doc, item) in _docitems(block.args)
    if item isa Symbol
      push!(names, item); push!(vals, nothing)
    elseif item isa Expr && item.head == :(=) && item.args[1] isa Symbol
      push!(names, item.args[1]); push!(vals, item.args[2])
    else
      error("@encoding: expected `name` or `name = value`, got $item")
    end
    doc === nothing || push!(docs, names[end] => doc)
  end
  isempty(names) && error("@encoding: $name has no values")
  any(v -> v !== nothing, vals) && scheme != :binary &&
    error("@encoding: $name gives explicit values, so it cannot also ask for $scheme")
  quote
    const $name = $QuartzHDL._mkencoding($(QuoteNode(name)), $(QuoteNode(scheme)),
                                        $(Expr(:tuple, (QuoteNode(n) for n in names)...)),
                                        $(Expr(:tuple, (v === nothing ? :nothing : v for v in vals)...)),
                                        $(width === nothing ? :nothing : :($QuartzHDL.bitwidth($width))),
                                        $(Expr(:tuple, Expr(:parameters, (Expr(:kw, k, v) for (k, v) in docs)...))))
  end
end

_gray(i) = i ⊻ (i >> 1)

function _mkencoding(name::Symbol, scheme::Symbol, names::Tuple, vals::Tuple, width, docs::NamedTuple=NamedTuple())
  raw = scheme === :onehot ? [UInt128(1) << (i - 1) for i in eachindex(names)] :
        scheme === :gray ? [UInt128(_gray(i - 1)) for i in eachindex(names)] :
        [v === nothing ? UInt128(i - 1) : UInt128(v) for (i, v) in enumerate(vals)]
  W = width === nothing ? max(1, ndigits(maximum(raw); base=2)) : width
  all(r -> r < (UInt128(1) << W), raw) ||
    error("@encoding: $name needs more than $W bits")
  allunique(raw) || error("@encoding: $name gives two names the same value")
  Encoding{name,NamedTuple{names,NTuple{length(names),Bits{W}}}}(
    NamedTuple{names}(map(r -> Bits{W}(r), Tuple(raw))), docs)
end
