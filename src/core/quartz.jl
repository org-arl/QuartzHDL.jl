# each @quartz struct owns its own block list, found by dispatch; QuartzHDL holds
# no global registry, so downstream packages precompile cleanly
function blocks end

# A module's interface: what crosses its boundary. `@out` and `@io` are storage as
# ordinary fields are; `@in` is declaration only -- an input is still received as a
# block argument and is not part of the struct.
struct PortDecl
  name::Symbol
  dir::Symbol                  # :in, :out or :pad
  typeexpr::Any                # kept as an expression, so Bits{N} resolves per instantiation
  default::Any
  attrs::Dict{Symbol,Any}
end

const NOPORTDEFAULT = gensym(:noportdefault)

# What a parent wires to an instance's inputs is held on the instance itself, under a
# name no field can have: the parent's @wire blocks write it, and the simulator hands
# it to the instance at its next edge. The record's type is fixed by the module's own
# @in declarations, so the struct stays a plain value and a step allocates nothing.
const INPUTS = Symbol("#inputs")

const PORTMACROS = Dict(Symbol("@in") => :in, Symbol("@out") => :out, Symbol("@io") => :pad)

# What a port is called on the pin, which way round it is, and what the board
# holds it at: facts about the pin rather than about the value, and the only ones
# there are. A name outside this set is a typo, and a typo that was quietly
# accepted would leave the port active-high with nothing said.
const PORTATTRS = Dict(:verilog => "a name for the emitted Verilog port",
                       :active => ":low or :high",
                       :ext_pull => ":up or :down, a pull the board provides")

# A multicycle path is a fact about how the logic works -- this register only
# changes every so often, so the tool may take longer routing to it -- so it belongs
# with the design, not the board. Written by hand it is a wildcard over
# post-synthesis cell names, which silently matches nothing when a register is
# renamed; here the names are checked against the module and the pattern generated.
struct MultiCycle
  from::Symbol
  to::Symbol
  cycles::Int
end

"""
    interface(T)

The declared ports of module `T`, in declaration order, as `PortDecl` values.
"""
interface(::Type) = PortDecl[]

function port(T::Type, name::Symbol)
  i = findfirst(p -> p.name === name, interface(T))
  i === nothing ? nothing : interface(T)[i]
end
isport(T::Type, name::Symbol, dir::Symbol) = (p = port(T, name); p !== nothing && p.dir === dir)
outputs(T::Type) = [p.name for p in interface(T) if p.dir === :out]

# the fields a reset restores: those declared with a default. The rest power up
# at zero and hold through a reset, as a data register with no reset does.
resets(::Type) = ()
statics(::Type) = ()

# A register declared with an encoding as its type is a `Bits` of the encoding's
# width, and knows its encoding: a bare state name then resolves wherever the
# register is assigned or compared, and the emitted Verilog can name the states.
encodings(::Type) = Dict{Symbol,Any}()

# A sequence's encoding is made by the block that holds it, after the struct, so
# it is registered here rather than declared; a bare state name does not resolve
# through it, since only the sequence's body knows its labels
sequences(::Type) = Dict{Symbol,Any}()
allencodings(T::Type) = merge(encodings(T), sequences(T))

# A Pulse and a Timeout{N} are a Bool and a Bits{N} that the owning block advances
# before its own statements; the field is stored as the plain register, and the
# kind is kept here for the block to find. An Edge is not among them: it is a
# struct of its own, and its history settles by dispatch when a cycle leaves it
# unwritten.
advancing(::Type) = Dict{Symbol,Symbol}()

multicycles(::Type) = MultiCycle[]

# Which clocks ride the chip's global distribution is a choice about the design --
# these nets matter enough for low-skew routing, the rest do not -- so it is stated
# once, on the top module, and nowhere else.
primarynets(::Type) = Symbol[]

# which clock a field runs on: the block that writes it
function clockof(T::Type, f::Symbol)
  for d in blocks(T)
    d.kind == :on && f in d.owned && return d.clock
  end
  nothing
end

"""
    portdoc(T, name)

The string that documents port `name` of module `T`, or `nothing` if it has none.
A string written above an `@in`/`@out`/`@io` line documents that port.
"""
function portdoc(T::Type, name::Symbol)
  isblackbox(T) && return get(blackbox(T).docs, name, nothing)
  p = port(T, name)
  p === nothing ? nothing : get(p.attrs, :doc, nothing)
end

"""
    @quartz struct Name ... end

Declares a hardware module: a plain Julia struct whose fields are its registers,
with `@in`, `@out` and `@io` lines declaring what crosses its boundary. The blocks
that drive it are written separately, with `@on` and `@wire`.

```julia
@quartz struct Ctr
  @in en::Bool
  @out n::Bits{8} = 0
end
```
"""
macro quartz(structdef)
  esc(_quartz(structdef, __module__))
end

# The three port macros are read by `@quartz`; called anywhere else, each says so.

"""
    @in name::T = default

Declares an input of a `@quartz` module. An input has no storage: the blocks
receive it as an argument, and a parent wires it from a `@wire` block.

```julia
@in en::Bool = false
```
"""
macro in(args...)
  error("@in declares a port and is only valid inside a @quartz struct")
end

"""
    @out name::T = default

Declares an output of a `@quartz` module. The field is an ordinary register that
also reaches a pin. Attributes follow the declaration: `active=:low` for a pin
asserted low, `verilog="name"` for the name the emitted port takes.

```julia
@out ready::Bool = false  active=:low
```
"""
macro out(args...)
  error("@out declares a port and is only valid inside a @quartz struct")
end

"""
    @io name::Pad{N} = Pad(:pullup)

Declares an inout pin, or a bus of them, of a `@quartz` module. The field is a
`Pad`, written with `drive`/`release` and read for the level the net settles to.

```julia
@io sda::Pad{1} = Pad(:pullup)
```
"""
macro io(args...)
  error("@io declares a port and is only valid inside a @quartz struct")
end

"""
    @multicycle Module n from => to

Declares that the logic between two registers of `Module` may take `n` clock cycles
to settle, so the tool need not route it for one. The endpoint names are checked
against the module and the cell pattern generated, which a hand-written constraint
cannot do.

```julia
@multicycle Corr 3 acc => out
```
"""
macro multicycle(T, cycles, path)
  path isa Expr && path.head == :call && path.args[1] === :(=>) ||
    error("@multicycle: expected `@multicycle Module n from => to`")
  from, to = path.args[2], path.args[3]
  (from isa Symbol && to isa Symbol) ||
    error("@multicycle: expected field names either side of =>")
  store = _mcname(T)
  esc(quote
    if !@isdefined($store)
      const $store = $QuartzHDL.MultiCycle[]
    end
    $QuartzHDL.multicycles(::Type{<:$T}) = $store
    push!($store, $QuartzHDL._mkmulticycle($T, $(QuoteNode(from)), $(QuoteNode(to)), $cycles))
    $store
  end)
end

"""
    @primary Module net, net, ...

Names the clock nets of `Module` that ride the chip's global low-skew distribution.
Stated once, on the top module.
"""
macro primary(T, nets...)
  names = Symbol[]
  for n in nets
    if n isa Symbol
      push!(names, n)
    elseif n isa Expr && n.head == :tuple && all(a -> a isa Symbol, n.args)
      append!(names, n.args)
    else
      error("@primary: expected `@primary Module net, net, ...`, got $n")
    end
  end
  isempty(names) && error("@primary: expected `@primary Module net, net, ...`")
  esc(quote
    $QuartzHDL.primarynets(::Type{<:$T}) = $names
    $names
  end)
end

### helpers

_blocksname(name::Symbol) = Symbol("#quartz_blocks#", name)

function _inputsfield(ins)
  names = Tuple(n for (n, _, _) in ins)
  types = [t for (_, t, _) in ins]
  vals = [d === nothing ? :($QuartzHDL._zerodefault($t)) : d for (_, t, d) in ins]
  Expr(:(=), Expr(:(::), INPUTS, :(NamedTuple{$names,Tuple{$(types...)}})),
       :(NamedTuple{$names}($(Expr(:tuple, vals...)))))
end

_ifacename(name::Symbol) = Symbol("#quartz_iface#", name)
_seqname(name::Symbol) = Symbol("#quartz_sequences#", name)

_macroname(f) = f isa Symbol ? f :
                f isa GlobalRef ? f.name :
                f isa Expr && f.head == :. ? _macroname(f.args[2]) :
                f isa QuoteNode ? _macroname(f.value) : f

# a string before an item parses as `Core.@doc "..." item`; the macros that read
# a body see the item and keep the string
_isdoc(x) = x isa Expr && x.head == :macrocall && _macroname(x.args[1]) === Symbol("@doc") && length(x.args) == 4
_undoc(x) = _isdoc(x) ? (x.args[3], x.args[4]) : (nothing, x)
# the items of a body as (doc, item) pairs: a string is the documentation of the
# item after it, whether the parser wrapped the two together or left them apart
function _docitems(args)
  items = Any[]
  pending = nothing
  for x in args
    x isa LineNumberNode && continue
    if x isa String
      pending = x
      continue
    end
    doc, item = _undoc(x)
    push!(items, (something(doc, pending, Some(nothing)), item))
    pending = nothing
  end
  items
end

# A string at the top of a block documents the block, and is taken off; the items
# after it keep whatever string documents each of them. A bare string anywhere else
# documents nothing, so it is refused.
function _blockdoc(args, what)
  doc = nothing
  out = Any[]
  pending = nothing                 # a block string the parser attached to the next one
  head = true
  for x in args
    x isa LineNumberNode && (push!(out, x); continue)
    pending === nothing || (x = _withdoc(pending, x); pending = nothing)
    d, item = _undoc(x)
    if head && (x isa String || d !== nothing)
      doc = x isa String ? x : d
      if x isa String
      elseif item isa String
        pending = item
      else
        push!(out, item)
      end
    elseif x isa String
      error("a string documents the $what, and belongs at its top")
    else
      push!(out, x)
    end
    head = false
  end
  pending === nothing || error("a string documents the $what, and belongs at its top")
  doc, out
end

_withdoc(doc, x) = Expr(:macrocall, GlobalRef(Core, Symbol("@doc")), LineNumberNode(0), doc, x)

# `@out a::Bits{8} = 1  active=:low  verilog="a_no"`: the first argument declares,
# the rest are attributes that apply to every declaration in it
function _portdecls(dir, args)
  isempty(args) && error("@$dir: expected a declaration")
  attrs = Expr[]
  for a in args[2:end]
    a isa Expr && a.head in (:(=), :kw) && a.args[1] isa Symbol ||
      error("@$dir: expected an attribute of the form name=value, got $a" *
            (a === :active_low ? "; write `active=:low`" : ""))
    name = a.args[1]
    haskey(PORTATTRS, name) ||
      error("@$dir: $name is not a port attribute. Known: " *
            join(("$k ($v)" for (k, v) in sort(collect(PORTATTRS); by=first)), ", "))
    name === :active && !(a.args[2] isa QuoteNode && a.args[2].value in (:low, :high)) &&
      error("@$dir: active takes :low or :high, got $(a.args[2])")
    push!(attrs, :($(QuoteNode(name)) => $(a.args[2])))
  end
  items = args[1] isa Expr && args[1].head in (:tuple, :block) ? args[1].args : Any[args[1]]
  out = Tuple{Symbol,Any,Any,Expr}[]
  for item in items
    item isa LineNumberNode && continue
    decl, default = item isa Expr && item.head == :(=) ? (item.args[1], item.args[2]) :
                    (item, nothing)
    decl isa Expr && decl.head == :(::) && length(decl.args) == 2 ||
      error("@$dir: expected name::Type, got $item")
    push!(out, (decl.args[1], decl.args[2], default, Expr(:call, :(Dict{Symbol,Any}), attrs...)))
  end
  out
end

function _quartz(structdef, mod)
  structdef isa Expr && structdef.head == :struct || error("@quartz: expected a struct definition")
  decl = structdef.args[2]
  if decl isa Expr && decl.head == :(<:)
    decl.args[2] in (:QuartzModule, :(QuartzHDL.QuartzModule)) ||
      error("@quartz: a hardware struct cannot have supertype $(decl.args[2])")
  else
    structdef = Expr(:struct, structdef.args[1], Expr(:(<:), decl, :($QuartzHDL.QuartzModule)), structdef.args[3])
    decl = structdef.args[2].args[1]
  end
  name = decl isa Expr && decl.head == :curly ? decl.args[1] : decl
  store = _blocksname(name)
  iface = _ifacename(name)
  seqs = _seqname(name)
  encs = Pair{Symbol,Symbol}[]
  kinds = Pair{Symbol,Symbol}[]
  items = _docitems(structdef.args[3].args)
  ins = Tuple{Symbol,Any,Any}[]
  ports = _extractports!(items, mod, encs, ins, kinds)
  statics = _staticdefaults!(items)
  _selffields!(items, kinds)
  _encodedfields!(items, mod, encs)
  resets = setdiff(_resetfields(items), statics)
  _zerodefaults!(items)
  structdef.args[3] = Expr(:block, (y for (d, x) in items for y in (d === nothing ? (x,) : (d, x)))...,
                           _inputsfield(ins))
  quote
    Base.@kwdef $structdef
    if !@isdefined($store)
      const $store = $QuartzHDL.BlockDef[]
    end
    if !@isdefined($iface)
      const $iface = $QuartzHDL.PortDecl[]
    end
    if !@isdefined($seqs)
      const $seqs = Dict{Symbol,Any}()
    end
    $QuartzHDL.sequences(::Type{<:$name}) = $seqs
    empty!($seqs)
    $QuartzHDL.blocks(::Type{<:$name}) = $store
    $QuartzHDL.interface(::Type{<:$name}) = $iface
    $QuartzHDL.resets(::Type{<:$name}) = $(Tuple(resets))
    $QuartzHDL.statics(::Type{<:$name}) = $(Tuple(statics))
    $QuartzHDL.encodings(::Type{<:$name}) =
      $(Expr(:call, :(Dict{Symbol,Any}), (:($(QuoteNode(f)) => $e) for (f, e) in encs)...))
    $QuartzHDL.advancing(::Type{<:$name}) =
      $(Expr(:call, :(Dict{Symbol,Symbol}), (:($(QuoteNode(f)) => $(QuoteNode(k))) for (f, k) in kinds)...))
    empty!($iface)
    append!($iface, $QuartzHDL.PortDecl[$(ports...)])
    $(_indefaults(name, ports)...)
    $QuartzHDL._validate($name)
    $name
  end
end

# `x::Bits{8} = static(5)`: the default is delivered by the bitstream, not by
# reset. The wrapper is unwrapped here, before any other reading of the default,
# and the field's name recorded; `_resetfields` then leaves it out.
_isstaticcall(d) = d isa Expr && d.head == :call && length(d.args) == 2 &&
                   (d.args[1] === :static || d.args[1] == :(QuartzHDL.static))
function _staticdefaults!(items)
  out = Symbol[]
  for (i, (doc, item)) in enumerate(items)
    item isa Expr && item.head == :(=) && _isstaticcall(item.args[2]) || continue
    decl = item.args[1]
    decl isa Expr && decl.head == :(::) ||
      error("static: expected name::Type = static(value), got $item")
    push!(out, decl.args[1])
    items[i] = (doc, Expr(:(=), decl, item.args[2].args[2]))
  end
  out
end
function _resetfields(items)
  out = Symbol[]
  for (_, item) in items
    item isa Expr && item.head == :(=) && item.args[1] isa Expr && item.args[1].head == :(::) || continue
    push!(out, item.args[1].args[1])
  end
  out
end

function _encoding(t, mod)
  t isa Symbol && isdefined(mod, t) || return nothing
  e = getfield(mod, t)
  e isa Encoding ? e : nothing
end

function _encoded(t, d, mod)
  e = _encoding(t, mod)
  e === nothing && return (t, d, nothing)
  d isa Symbol && d in keys(e) && (d = Expr(:., t, QuoteNode(d)))
  (:($QuartzHDL.Bits{$(bitwidth(e))}), d, t)
end

_typename(t) = t isa Symbol ? t : t isa Expr && t.head == :. ? _typename(t.args[2]) :
               t isa QuoteNode ? t.value : nothing

function _selfkind(t, d)
  base = t isa Expr && t.head == :curly ? _typename(t.args[1]) : _typename(t)
  base === :Pulse && return (:Bool, d, :pulse)
  if base === :Timeout
    t isa Expr && t.head == :curly && length(t.args) == 2 || error("@quartz: a Timeout needs a width, `Timeout{N}`")
    return (:($QuartzHDL.Bits{$(t.args[2])}), d, :timeout)
  end
  (t, d, nothing)
end

function _selffields!(items, kinds)
  for (i, (doc, item)) in enumerate(items)
    decl, default = item isa Expr && item.head == :(=) ? (item.args[1], item.args[2]) : (item, nothing)
    decl isa Expr && decl.head == :(::) && length(decl.args) == 2 || continue
    t, d, k = _selfkind(decl.args[2], default)
    k === nothing && continue
    push!(kinds, decl.args[1] => k)
    items[i] = (doc, d === nothing ? Expr(:(::), decl.args[1], t) : Expr(:(=), Expr(:(::), decl.args[1], t), d))
  end
end

function _encodedfields!(items, mod, encs)
  for (i, (doc, item)) in enumerate(items)
    decl, default = item isa Expr && item.head == :(=) ? (item.args[1], item.args[2]) : (item, nothing)
    decl isa Expr && decl.head == :(::) && length(decl.args) == 2 || continue
    t, d, e = _encoded(decl.args[2], default, mod)
    e === nothing && continue
    push!(encs, decl.args[1] => e)
    items[i] = (doc, d === nothing ? Expr(:(::), decl.args[1], t) : Expr(:(=), Expr(:(::), decl.args[1], t), d))
  end
end

# An input's default lives with the declaration, not repeated in every block that
# takes it. A method per input keeps the expression in the struct's own scope, so a
# default written in terms of the module's parameters still resolves.
_indefault(::Type{T}, ::Val{name}) where {T,name} =
  error("input $name of $(nameof(T)) has no default; give the block argument one, " *
        "or declare it as `@in $name::T = value`")

function _indefaults(name, ports)
  out = Expr[]
  for p in ports
    p.args[3].value === :in || continue
    d = p.args[5]
    d isa Expr && d.head == :. && continue          # NOPORTDEFAULT: no default given
    push!(out, :($QuartzHDL._indefault(::Type{<:$name}, ::Val{$(p.args[2])}) = $(d.value)))
  end
  out
end

# `@in`/`@out`/`@io` lines are pulled out of the struct body: outputs and pads stay
# as fields, inputs leave nothing behind but the declaration. A string before a
# port line documents the port; before a field, Julia keeps it as the field's.
function _extractports!(items, mod, encs, ins=Tuple{Symbol,Any,Any}[], kinds=Pair{Symbol,Symbol}[])
  ports = Expr[]
  keep = Any[]
  for (doc, item) in items
    if item isa Expr && item.head == :macrocall && haskey(PORTMACROS, _macroname(item.args[1]))
      dir = PORTMACROS[_macroname(item.args[1])]
      for (n, t, d, at) in _portdecls(dir, filter(a -> !(a isa LineNumberNode), item.args[2:end]))
        _isstaticcall(d) &&
          error("@$dir $n: static initialization applies to state fields, not ports")
        _typename(t) === :Edge &&
          error(dir === :in ?
                  "@in $n: an input has no storage, so it cannot be an Edge; " *
                  "declare it as Bool and feed a field of its own" :
                  "@$(String(_macroname(item.args[1]))[2:end]) $n: an Edge is a register " *
                  "with history, not a port value; declare the port as Bool and " *
                  "write the level to it")
        t, d, k = _selfkind(t, d)
        k === nothing || dir !== :in ||
          error("@in $n: an input has no storage, so it cannot be a " *
                "$(_typename(t) === :Bool ? "Pulse" : "Timeout"); declare it as its plain type")
        k === nothing || push!(kinds, n => k)
        t, d, e = _encoded(t, d, mod)
        e === nothing || push!(encs, n => e)
        doc === nothing || push!(at.args, :(:doc => $doc))
        push!(ports, :($QuartzHDL.PortDecl($(QuoteNode(n)), $(QuoteNode(dir)), $(QuoteNode(t)),
                                          $(d === nothing ? :($QuartzHDL.NOPORTDEFAULT) : QuoteNode(d)), $at)))
        # a pad's polarity travels with its value, so that reading and driving it
        # invert wherever the value goes, not only inside a block
        dir === :pad && _hasattr(at, :active, :low) &&
          (d = :($QuartzHDL._lowpad($(d === nothing ? :($QuartzHDL._zerodefault($t)) : d))))
        dir === :in && (push!(ins, (n, t, d)); continue)
        push!(keep, (doc, d === nothing ? Expr(:(::), n, t) : Expr(:(=), Expr(:(::), n, t), d)))
      end
    else
      push!(keep, (doc, item))
    end
  end
  empty!(items)
  append!(items, keep)
  ports
end

_hasattr(at::Expr, name::Symbol, want) =
  any(a -> a isa Expr && a.head == :call && a.args[1] == :(=>) &&
           a.args[2] == QuoteNode(name) && a.args[3] == QuoteNode(want), at.args)

# a field with no default starts at zero, so only the interesting defaults are
# written down
function _zerodefaults!(items)
  for (i, (doc, item)) in enumerate(items)
    item isa Expr && item.head == :(::) && length(item.args) == 2 || continue
    items[i] = (doc, Expr(:(=), item, :($QuartzHDL._zerodefault($(item.args[2])))))
  end
end

_zerodefault(::Type{Bool}) = false
_zerodefault(::Type{T}) where T<:HWInt = T(0)
_zerodefault(::Type{T}) where T = T()

function _validate(T::Type)
  isstructtype(T) || error("@quartz: $T is not a struct")
  isconcretetype(T) && T()      # force the defaults, so a bad one fails here
  _validateinterface(T)
  for (f, FT) in zip(fieldnames(T), fieldtypes(T))
    f === INPUTS && continue
    _hwfield(FT) ||
      error("field $f::$FT of $(nameof(T)) is not a hardware type; use Bool, Bits{N}, " *
            "SBits{N}, Pulse, Timeout{N}, Edge, MetaGuard{K}, Pipeline{K,T}, " *
            "Multicycle{K,T}, Pad{N} or a QuartzModule")
    FT <: Multicycle && isport(T, f, :out) &&
      error("$f of $(nameof(T)) is a multicycle wire and cannot be a port; latch it into a register and output that")
  end
  T
end

# The declarations and the fields have to agree: a port that is not a field, a pad
# left undeclared, or an input sharing a field's name would each be a quiet mistake.
function _validateinterface(T::Type)
  for p in interface(T)
    if p.dir === :in
      !hasfield(T, p.name) || fieldtype(T, p.name) <: MetaGuard ||
        error("@in $(p.name) of $(nameof(T)) is also a field; an input and a register " *
              "cannot share a name")
    else
      hasfield(T, p.name) || error("@$(p.dir) $(p.name) is not a field of $(nameof(T))")
      ispad = fieldtype(T, p.name) <: Pad
      ispad == (p.dir === :pad) ||
        error("$(p.name) of $(nameof(T)) is declared @$(p.dir) but is " *
              (ispad ? "a pad; use @io" : "not a pad; use @out"))
    end
  end
  for (f, FT) in zip(fieldnames(T), fieldtypes(T))
    FT <: Pad && !isport(T, f, :pad) &&
      error("pad $f of $(nameof(T)) is a pin and must be declared: add `@io $f::$FT`")
  end
  T
end

# a field of a module that is still parametric has no concrete type to check, and
# `@quartz` validates every concrete instantiation as it is built
_hwfield(T) = isblackbox(T) || T == Bool || T <: HWInt || T === Edge || T <: MetaGuard ||
              T <: Pipeline || T <: Multicycle || T <: QuartzModule || T <: Pad ||
              T <: Base.BitInteger || !isconcretetype(T)

_mcname(name::Symbol) = Symbol("#quartz_multicycle#", name)

function _mkmulticycle(T::Type, from::Symbol, to::Symbol, cycles::Integer)
  for f in (from, to)
    hasfield(T, f) || error("@multicycle: $f is not a field of $(nameof(T))")
  end
  cycles > 1 || error("@multicycle: a path of $cycles cycles is not an exception")
  _mcnamecheck(T, from, to)
  MultiCycle(from, to, Int(cycles))
end

# The emitted pattern is an endpoint's name and a trailing wildcard, so it must
# be provably unambiguous before it is emitted. Declared exceptions come here as
# they are declared; the ones a Multicycle wire derives come at emission.
function _mcnamecheck(T::Type, from::Symbol, to::Symbol)
  for f in (from, to), (path, n) in _cellnames(T)
    isempty(path) && n === f && continue
    sf, sn = string(f), string(n)
    at = isempty(path) ? "" : " (in $path)"
    # a name that extends the endpoint's puts its own cells inside the exception
    startswith(sn, sf) &&
      error("multicycle: the cell pattern for $f of $(nameof(T)) would also " *
            "match $n$at; synthesis extends a name it decorates, so no name " *
            "under $(nameof(T)) may extend a multicycle endpoint's. Rename one.")
    # and the other way round only through a name the tools derive: a register
    # named like another's derived cells is matched by their decorations. The
    # suffixes below are the ones trace.jl gives a register's companion nets --
    # adding one there without adding it here lets a pattern match cells it
    # should not, and nothing says so.
    startswith(sf, sn) &&
      occursin(r"^(_(p\d|s\d|pipe|valid|out|hasout|isnew|wr|ready|settle|prev)|_?\d)",
               sf[length(sn)+1:end]) &&
      error("multicycle: cells derived from $n$at are named like $f, so the " *
            "pattern for $f of $(nameof(T)) would match them. Rename one.")
  end
end

# every name synthesis can derive a cell name from, anywhere under T, with the
# instance path it sits at: the fields at every depth, and the instances between
function _cellnames(T::Type, path="", acc=Tuple{String,Symbol}[])
  for (f, FT) in zip(fieldnames(T), fieldtypes(T))
    f === INPUTS && continue
    push!(acc, (path, f))
    FT <: QuartzModule && !isblackbox(FT) &&
      _cellnames(FT, isempty(path) ? string(f) : "$path/$f", acc)
  end
  acc
end
