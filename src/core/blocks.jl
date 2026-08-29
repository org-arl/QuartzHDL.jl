# The @on/@wire compiler, and the machinery a step runs. A block is written as
# ordinary Julia over the module's fields; the macros here rewrite it three ways --
# into the function the simulator runs, into the expression tree the emitters read,
# and into the record of what it owns -- and register it against the module type.
# From that registration follow the per-type methods that advance a module: which
# blocks run on which clock edge, how their writes merge, how continuous logic
# settles, and how the instances below are stepped.

struct BlockDef
  kind::Symbol                  # :on or :comb
  clock::Symbol
  edge::Symbol
  typeexpr::Any                 # the module type as written, `Ctr{N}` or `Ctr`
  params::Vector{Symbol}        # the type parameters the body may use
  reset::Any
  reset_overrides::Vector{Expr}
  only_when::Any
  clockouts::Vector{Any}
  clockbinds::Vector{Tuple{Symbol,Symbol,Symbol}}   # (instance, clock port, net)
  body::Expr
  doc::Union{Nothing,String}
  mod::Module
  inputs::Vector{Symbol}        # the @in ports the block reads, in order of first use
  required::Vector{Symbol}      # those of them with no declared default
  owned::Vector{Symbol}
  simfn::Function              # the block's function, named in the module's own namespace
end

"""
    @on Module posedge(clk) begin ... end

Declares clocked logic: the body runs on every rising (or `negedge`, falling) edge
of clock net `clk`, and its register writes take effect together at the end of the
edge, as Verilog's non-blocking assignment does. Leading `@reset`, `@only_when` and
`@clockout` clauses say when it resets, when it runs, and which pin its clock
reaches.

```julia
@on Ctr posedge(clk) begin
  @reset(rst)
  n ← n + 1
end
```
"""
macro on(T, clock, block)
  esc(_on(T, clock, _asblock(block, __source__), __module__))
end

"""
    @wire Module begin ... end

Declares continuous logic: the body has no clock and no storage, so every path
through it must write every field it drives. It may write `@out` ports, pads,
`Multicycle` wires, and the inputs and clocks of the module's instances.

```julia
@wire Top begin
  ctr.en ← run
  led ← drive(ctr.n[7])
end
```
"""
macro wire(T, block)
  esc(_comb(T, _asblock(block, __source__), __module__))
end

mutable struct Clauses
  reset::Any
  overrides::Vector{Expr}
  only_when::Any
  clockouts::Vector{Any}
end
Clauses() = Clauses(nothing, Expr[], nothing, Any[])

function _resetclause!(c::Clauses, args)
  c.reset === nothing || error("@reset is given twice")
  if !isempty(args) && args[1] isa Expr && args[1].head == :parameters
    for a in args[1].args
      a isa Expr && a.head == :kw && a.args[1] isa Symbol ||
        error("@reset(cond; field = value) takes field names")
      push!(c.overrides, Expr(:kw, a.args[1], a.args[2]))
    end
    args = args[2:end]
  end
  length(args) == 1 || error("@reset(cond; overrides...) takes one condition")
  c.reset = args[1]
end

function _onlywhenclause!(c::Clauses, args)
  c.only_when === nothing || error("@only_when is given twice")
  length(args) == 1 || error("@only_when(sig) takes one argument")
  c.only_when = args[1]
end

function _clockoutclause!(c::Clauses, args)
  opts = Dict{Symbol,Any}(:invert => false, :gate => nothing)
  if !isempty(args) && args[1] isa Expr && args[1].head == :parameters
    for o in args[1].args
      o isa Expr && o.head == :kw && haskey(opts, o.args[1]) ||
        error("@clockout takes invert = true/false and gate = signal")
      opts[o.args[1]] = o.args[2]
    end
    args = args[2:end]
  end
  length(args) == 1 && args[1] isa Symbol ||
    error("@clockout(name; invert = ..., gate = ...) takes one output name")
  push!(c.clockouts, (name = args[1], invert = opts[:invert], gate = opts[:gate]))
end

function _on(T, clock, block, mod)
  clock isa Expr && clock.head == :call && clock.args[1] in (:posedge, :negedge) && length(clock.args) == 2 ||
    error("@on: expected posedge(sig) or negedge(sig), got $clock")
  edge, clk = clock.args[1], clock.args[2]
  _blockcode(:on, T, clk, edge, block, mod)
end

_comb(T, block, mod) = _blockcode(:comb, T, Symbol(""), Symbol(""), block, mod)

# a one-line block carries no line of its own, and the line is what tells two
# blocks apart when a file is included again
_asblock(x, src) = x isa Expr && x.head == :block ? x : Expr(:block, src, x)

# The clauses are the leading statements of the body, before any write, and a
# leading string is the block's summary. A clause below a statement is a mistake:
# it would read as running after the statement, and it does not.
const CLAUSES = Dict(Symbol("@reset") => _resetclause!, Symbol("@only_when") => _onlywhenclause!,
                     Symbol("@clockout") => _clockoutclause!)

_clausename(x) = x isa Expr && x.head == :macrocall ? _macroname(x.args[1]) : nothing

function _clauses!(body::Expr, kind)
  c = Clauses()
  out = Any[]
  doc = nothing
  head = true
  for x in body.args
    if x isa LineNumberNode
      push!(out, x)
      continue
    end
    d, item = _undoc(x)
    if d !== nothing || item isa String
      head && doc === nothing || error("a string documents the block, and belongs at its top")
      doc = something(d, item)
      item isa String && continue
    end
    name = _clausename(item)
    if head && haskey(CLAUSES, name)
      kind == :comb && error("@wire: $name is not allowed in a combinational block")
      CLAUSES[name](c, filter(a -> !(a isa LineNumberNode), item.args[2:end]))
    elseif haskey(CLAUSES, name)
      error("$name belongs at the top of the block, before any statement")
    else
      head = false
      push!(out, item)
    end
  end
  Expr(:block, out...), c, doc
end

"""
    @reset(cond)
    @reset(cond; field = value)

Says when the `@on` block it heads resets: while `cond` holds, every field with a
default goes back to it. A named override holds a field at a value of its own
instead. It belongs at the top of the body, before any statement.
"""
macro reset(args...)
  error("@reset says when a block resets, and belongs at the top of its body, " *
        "before any statement")
end

"""
    @only_when(sig)

Says when the `@on` block it heads runs: an edge on which `sig` is false leaves
every field the block owns alone. It belongs at the top of the body, before any
statement.
"""
macro only_when(args...)
  error("@only_when says when a block runs, and belongs at the top of its body, " *
        "before any statement")
end

"""
    @clockout(name; invert = false, gate = signal)

Forwards the clock of the `@on` block it heads out of the module as `name`, so it
can reach a pin -- an SPI clock, say. `invert` sends the opposite phase and `gate`
names a signal that must hold for the clock to leave. It belongs at the top of the
body, before any statement.
"""
macro clockout(args...)
  error("@clockout forwards a block's clock to a pin, and belongs at the top of the " *
        "block's body, before any statement")
end

# advance a module by one clock edge: run every @on block on this clock against
# the old state, then merge their writes and advance their pipelines and guards
function Base.step(m::QuartzModule; kwargs...)
  clocks = _clocks(typeof(m))
  length(clocks) ≤ 1 || error("module has several clocks ($(join(clocks, ", "))); use step(m, :clk; ...)")
  _stepwith(m, Val(isempty(clocks) ? Symbol("") : clocks[1]), values(kwargs))
end

Base.step(m::QuartzModule, clock::Symbol; kwargs...) = _stepnet(m, clock, values(kwargs))

# a clock named at run time picks its edge through a chain of comparisons over the
# module's clocks, so the module is not boxed to dispatch on the name
_stepnet(m::QuartzModule, clock::Symbol, kw::NamedTuple) = _stepnet(m, clock, kw, Val(_clocks(typeof(m))))
@generated _stepnet(m, clock::Symbol, kw, ::Val{clocks}) where clocks =
  foldr((c, rest) -> :(clock === $(QuoteNode(c)) ? _stepwith(m, Val($(QuoteNode(c))), kw) : $rest), clocks;
        init = :(error("no @on block on clock $clock")))

### helpers

function _typeparts(t, what)
  t isa Symbol && return (t, Symbol[])
  t isa Expr && t.head == :curly && t.args[1] isa Symbol &&
    return (t.args[1], Symbol[a for a in t.args[2:end] if a isa Symbol])
  error("$what: expected the module type first, e.g. `$what Adc ...`, got $t")
end

# a block written without the struct's parameters can only mean the struct's own
function _withstructparams(typeexpr, params, T)
  typeexpr isa Symbol || return (typeexpr, params)
  names = [p.name for p in Base.unwrap_unionall(T).parameters]
  isempty(names) && return (typeexpr, params)
  (Expr(:curly, typeexpr, names...), names)
end

function _resolvetype(structname, mod, what)
  isdefined(mod, structname) ||
    error("$what: $structname must be defined before the blocks that use it")
  T = getfield(mod, structname)
  T isa Type && T <: QuartzModule || error("$what: $structname is not a @quartz module")
  T
end

_isstorage(FT) = FT isa Type && (FT <: Pad || FT <: MetaGuard || FT <: Pipeline || FT <: Multicycle || FT === Edge)
_ismulticycle(FT) = FT isa Type && FT <: Multicycle
_isguard(T, f) = hasfield(T, f) && fieldtype(T, f) <: MetaGuard

function _blockcode(kind, typeexpr, clk, edge, body, mod)
  what = kind == :on ? "@on" : "@wire"
  structname, params = _typeparts(typeexpr, what)
  T = _resolvetype(structname, mod, what)
  typeexpr, params = _withstructparams(typeexpr, params, T)
  fields = setdiff(Set(fieldnames(T)), (INPUTS,))
  :this in fields && error("`this` is reserved for the module state and cannot be a field")
  inports = Set(p.name for p in interface(T) if p.dir === :in)
  # a method is inlined before expansion, so its body expands with the block's
  body = _inlinemethods(body, mod, encodings(T))
  body, c, doc = _clauses!(body, kind)
  body = _logcalls(body, T)
  body, seqs = _sequences!(body, T, kind, fields, inports)
  body = _fsmsubjects(body, T)
  body = _thislevel(macroexpand(mod, body))
  bound = Set{Symbol}(params)
  push!(bound, :this)
  _boundnames!(bound, body)
  for n in intersect(bound, fields)
    error("$n is both a field of $(nameof(T)) and a local here; rename one")
  end
  for n in intersect(bound, inports)
    error("$n is both an input of $(nameof(T)) and a local here; rename one")
  end
  # a state name that is also a field, an input or a local would mean two things
  for (f, enc) in encodings(T), k in keys(enc)
    (k in fields || k in inports || k in bound) &&
      error("$k is a state of $(encname(enc)), which $f holds, and also a " *
            (k in fields ? "field" : k in inports ? "input" : "local") * " of $(nameof(T)); rename one")
  end
  bf(x) = x === nothing ? nothing : _barenames(x, fields, bound)
  body = bf(body)
  body, clockbinds = _clockbinds(body, T, what)
  reset = bf(c.reset)
  only_when = bf(c.only_when)
  clockouts = [(name = x.name, invert = x.invert, gate = bf(x.gate)) for x in c.clockouts]
  overrides = [Expr(:kw, o.args[1], bf(o.args[2])) for o in c.overrides]
  enc(x) = x === nothing ? nothing : _encodednames(x, T)
  body = enc(_guardfeeds(_splitwrites(_sugarwrites(body), what), T, inports))
  reset = enc(reset)
  only_when = enc(only_when)
  clockouts = [(name = x.name, invert = x.invert, gate = enc(x.gate)) for x in clockouts]
  overrides = [Expr(:kw, o.args[1], enc(o.args[2])) for o in overrides]
  inputs = Symbol[]
  exprs = Any[body, reset, only_when, (o.args[2] for o in overrides)..., (x.gate for x in clockouts)...]
  for ex in exprs
    ex === nothing && continue
    for s in _freesyms(ex, bound)
      s in inports && (s in inputs || push!(inputs, s))
      s in inports || Base.isgensym(s) || s in (:end, :begin) || isdefined(mod, s) || any(q -> q[1] === s, seqs) ||
        error("$what $(nameof(T)): `$s` is not a field, an input, a local, or anything " *
              "defined in $(nameof(mod))")
    end
  end
  # a block that hands `this` to a function may read any input through it
  any(_passesthis, exprs) && foreach(s -> s in inputs || push!(inputs, s),
                                     (p.name for p in interface(T) if p.dir === :in && !(p.name in _clocks(T))))
  required = [n for n in inputs if !_hasdefault(T, n)]
  val(x) = x === nothing ? nothing : _valuereads(x, T; stmt=false)
  body = _valuereads(body, T)
  reset = val(reset)
  only_when = val(only_when)
  clockouts = [(name = x.name, invert = x.invert, gate = val(x.gate)) for x in clockouts]
  overrides = [Expr(:kw, o.args[1], val(o.args[2])) for o in overrides]
  owned = Symbol[]
  _rewrite_sim(body, :this, nothing; acc=owned)
  body = _advance(body, T, kind, owned, what)
  kw = gensym(:kw)
  slots = Dict(f => gensym(f) for f in owned)
  # an input is read from the keyword tuple by name, so the lookup is resolved when
  # the step compiles; the declared type is asserted, as a keyword argument's would be
  function input(name)
    fallback = _hasdefault(T, name) ?
      :($QuartzHDL._asinput($(port(T, name).typeexpr),
                            $QuartzHDL._indefault($structname, Val($(QuoteNode(name)))))) :
      :(error($("missing input $name")))
    v = :(haskey($kw, $(QuoteNode(name))) ? $(Expr(:., kw, QuoteNode(name))) : $fallback)
    :(local $name = $v::$(port(T, name).typeexpr))
  end
  names = Tuple(owned)
  flags = Dict(f => gensym(Symbol(f, "_written")) for f in owned)
  # A slot starts as the field's current value and a flag says whether the block
  # wrote it, so every slot has one concrete type on every path: a marker in the
  # slot would make a union, and a record of unions is passed boxed.
  result(isreset, value, written) =
    :((reset = $isreset, writes = NamedTuple{$names}($(Expr(:tuple, (value(f) for f in owned)...))),
       written = $(Expr(:tuple, (written(f) for f in owned)...))))
  overridden = Dict(o.args[1] => o.args[2] for o in overrides)
  override(f) = :($QuartzHDL._written(this, Val($(QuoteNode(f))), $(overridden[f])))
  collbody = quote
    $((input(n) for n in inputs)...)
    this = $QuartzHDL._wirepresent(this, $kw)
    $((:(local $(slots[f]) = $QuartzHDL._slotinit(this, Val($(QuoteNode(f))))) for f in owned)...)
    $(reset === nothing ? nothing :
      :($reset && return $(result(true, f -> haskey(overridden, f) ? override(f) : slots[f],
                                  f -> haskey(overridden, f)))))
    $(only_when === nothing ? nothing : :($only_when || return nothing))
    $((:(local $(flags[f]) = false) for f in owned)...)
    $(_rewrite_sim(_gatherports(_levelvals(body)), :this, (slots, flags)))
    return $(result(false, f -> slots[f], f -> flags[f]))
  end
  # The block is a named function of the module's own namespace, so a reload
  # redefines it in place and the compiled step follows; the slot it fills, and what
  # it is, are methods on the slot number that the generic step folds over.
  slot = _slotfor(T, kind, clk, edge, owned, body, mod)
  fname = Symbol("#", kind, "#", structname, "#", slot)
  withparams(sig) = foldl((s, p) -> Expr(:where, s, p), params; init=sig)
  collfn = Expr(:function, withparams(:($fname(this::$typeexpr, $kw::NamedTuple))), collbody)
  binds = [(f, p, net, _isclockinput(T, f, p) ? :in : :out) for (f, p, net) in clockbinds]
  meta = (kind, clk, edge, Tuple(owned), Tuple(required), Tuple(binds))
  # a block reloaded with only its body changed redefines its function and nothing
  # else, so the slot's methods are written once
  sameslot = slot ≤ length(blocks(T)) && _metaof(T, blocks(T)[slot]) == meta
  slotdefs = sameslot ? Any[] : Any[
    :($QuartzHDL._blockfn(::Type{<:$structname}, ::Val{$slot}) = $fname),
    :($QuartzHDL._blockmeta(::Type{<:$structname}, ::Val{$slot}) = Val{$(QuoteNode(meta))}()),
    _slotsettledef(T, typeexpr, withparams, slot, fname, kind, owned, required),
    _slotstepdefs(T, structname, typeexpr, withparams, slot, binds)...,
    _slotedgedef(T, typeexpr, withparams, slot, binds),
    (:($QuartzHDL._clockoutnet(::Type{<:$structname}, ::Val{$(QuoteNode(f))}, ::Val{$(QuoteNode(p))}) =
         Val($(QuoteNode(net)))) for (f, p, net, _) in binds)...]
  def = gensym(:def)
  quote
    $((:(const $n = $enc) for (n, f, enc) in seqs)...)
    $((:($QuartzHDL.sequences($structname)[$(QuoteNode(f))] = $n) for (n, f, enc) in seqs)...)
    $collfn
    $(slotdefs...)
    local $def = $QuartzHDL.BlockDef($(QuoteNode(kind)), $(QuoteNode(clk)), $(QuoteNode(edge)),
      $(QuoteNode(typeexpr)), $params, $(QuoteNode(reset)),
      $(Expr(:vect, (QuoteNode(o) for o in overrides)...)), $(QuoteNode(only_when)),
      $(Expr(:vect, (:((name = $(QuoteNode(x.name)), invert = $(x.invert),
                        gate = $(QuoteNode(x.gate)))) for x in clockouts)...)),
      $clockbinds, $(QuoteNode(body)), $doc, $mod, $inputs, $required, $owned, $fname)
    $QuartzHDL._register!($structname, $def, $slot)
    nothing
  end
end

_metaof(T::Type, d::BlockDef) =
  (d.kind, d.clock, d.edge, Tuple(d.owned), Tuple(d.required),
   Tuple((f, p, net, _isclockinput(T, f, p) ? :in : :out) for (f, p, net) in d.clockbinds))

# the slot a block fills: the one it filled before, when it is the same block
# reloaded -- same kind and clock, and the same fields, body or place -- else a new one
function _slotfor(T::Type, kind, clk, edge, owned, body, mod)
  ln = _firstline(body)
  here = ln === nothing ? (mod, :unknown, 0) : (mod, ln.file, ln.line)
  for (i, d) in enumerate(blocks(T))
    d.kind == kind && d.clock == clk || continue
    (Set(d.owned) == Set(owned) || d.body == body || _blockline(d) == here) && return i
  end
  length(blocks(T)) < MAXSLOTS || error("$(nameof(T)) has $MAXSLOTS blocks already, which is the most a module can have")
  length(blocks(T)) + 1
end

# One settle pass of a @wire block, with its merge written out: an instance's
# inputs settle the instance, and a field the block left unwritten is an error.
# It is a method of the design's module rather than generated code, since a
# generated pass that settles the instances below was entered with its arguments
# boxed, the compiler having declined to inline it.
function _slotsettledef(T::Type, typeexpr, withparams, slot, fname, kind, owned, required)
  kind === :comb || return nothing
  present = foldl((a, p) -> :($a && haskey(kw, $(QuoteNode(p)))), required; init=true)
  Expr(:function, withparams(:($QuartzHDL._settleslot(acc::$typeexpr, m::$typeexpr, kw::NamedTuple, strict::Bool, ::Val{$slot}))),
       quote
         $(Expr(:meta, :inline))
         strict || $present || return acc
         r = $fname(m, kw)
         r === nothing && return acc
         $(_applycombexpr(T, owned, :acc, :m, :r))
       end)
end

# The instances this block wires a clock to, stepped on that clock's net: one method
# per net, and a black box takes its edge where a module takes a step.
function _slotstepdefs(T::Type, structname, typeexpr, withparams, slot, binds)
  bynet = Dict{Symbol,Vector{Expr}}()
  for (f, p, net, dir) in binds
    dir === :in || continue
    x = isblackbox(fieldtype(T, f)) ? :($QuartzHDL._stepbb(x, $(QuoteNode(p)))) :
        :($QuartzHDL._stepinner(x, Val($(QuoteNode(p))), $QuartzHDL._inputsof(x), ctx))
    push!(get!(bynet, net, Expr[]),
          :(x = getfield(m, $(QuoteNode(f))); x = $x;
            m = $QuartzHDL._merge(m, $(Expr(:tuple, Expr(:parameters, Expr(:kw, f, :x)))))))
  end
  [Expr(:function, withparams(:($QuartzHDL._blocksteps(m::$typeexpr, ::Val{$(QuoteNode(net))}, ::Val{$slot}, ctx))),
        Expr(:block, stmts..., :m)) for (net, stmts) in bynet]
end

# the clock outputs this block wires, as (net, divide, ticked this slot), in the
# order the black box declares them
function _slotedgedef(T::Type, typeexpr, withparams, slot, binds)
  parts = Any[]
  for (f, FT) in zip(fieldnames(T), fieldtypes(T))
    isblackbox(FT) || continue
    bb = blackbox(FT)
    for (i, c) in enumerate(bb.outs)
      k = findfirst(b -> b[1] === f && b[2] === c, binds)
      k === nothing && continue
      recipes = [t for t in bb.tree if t.name === c]
      div = foldl((a, t) -> :($QuartzHDL._divide($FT, $t)), recipes; init=1)
      push!(parts, :(($(QuoteNode(binds[k][3])), $div,
                      $QuartzHDL._hasbit(getfield(getfield(m, $(QuoteNode(f))), :ticked), $(i - 1)))))
    end
  end
  isempty(parts) && return nothing
  Expr(:function, withparams(:($QuartzHDL._blockedges(m::$typeexpr, ::Val{$slot}))), Expr(:tuple, parts...))
end

_hasdefault(T::Type, name::Symbol) = (p = port(T, name); p !== nothing && p.default !== NOPORTDEFAULT)

# A Pulse clears, a Timeout counts down: each is a write the owning block makes
# first, so a write of the block's own wins the cycle. An Edge needs nothing here:
# its history settles in the merge, by dispatch on the field's type.
function _advance(body, T, kind, owned, what)
  kinds = advancing(T)
  mine = [f for f in owned if get(kinds, f, nothing) in (:pulse, :timeout)]
  isempty(mine) && return body
  kind == :comb && error("$what $(nameof(T)): $(mine[1]) is a $(kinds[mine[1]]), " *
                         "which advances on a clock; only an @on block can write it")
  first = Any[]
  for f in mine
    ref = Expr(:., :this, QuoteNode(f))
    k = kinds[f]
    k === :pulse && push!(first, Expr(:call, :←, ref, false))
    k === :timeout && push!(first, Expr(:call, :←, ref, :(Base.ifelse($ref == 0, $ref, $ref - 1))))
  end
  Expr(:block, first..., body.args...)
end
_asinput(::Type{T}, v) where T = v isa T ? v : T(v)

# A clock is a net, not a value: `inst.clk ← net` binds an instance's clock input to
# a net of this module, and `net ← part.clkout` names the net a part's clock output
# drives. Both are taken out of the body here -- the simulator watches the nets for
# edges and the emitter wires them -- so what is left in the body is values only.
function _clockbinds(body, T, what)
  binds = Tuple{Symbol,Symbol,Symbol}[]
  out = Any[]
  for ex in body.args
    b = _clockbind(ex, T)
    if b === nothing
      _nestedbind(ex, T) && error("$what $(nameof(T)): a clock is wired unconditionally, not inside an `if`")
      push!(out, ex)
    else
      what == "@wire" || error("$what $(nameof(T)): a clock is wired in a @wire block, `$(b[1]).$(b[2]) ← net`")
      push!(binds, b)
    end
  end
  Expr(:block, out...), binds
end

function _clockbind(ex, T)
  ex isa Expr && ex.head == :call && length(ex.args) == 3 && ex.args[1] in WRITEOPS || return nothing
  lhs, rhs = ex.args[2], ex.args[3]
  if _isportref(lhs, :this)
    f, p = lhs.args[1].args[2].value, lhs.args[2].value
    _isclockinput(T, f, p) || return nothing
    rhs isa Symbol || error("$(f).$(p) is a clock input and takes a net name, got $rhs")
    return (f, p, rhs)
  elseif lhs isa Symbol && _isportref(rhs, :this)
    f, p = rhs.args[1].args[2].value, rhs.args[2].value
    _isclockoutput(T, f, p) || return nothing
    return (f, p, lhs)
  end
  nothing
end

_nestedbind(ex, T) = ex isa Expr && (ex.head != :call && any(a -> _nestedbind(a, T), ex.args) ||
                                     ex.head == :call && _clockbind(ex, T) !== nothing)

function _isclockinput(T, f, p)
  hasfield(T, f) || return false
  FT = fieldtype(T, f)
  isblackbox(FT) && return (q = _bbport(FT, p); q !== nothing && q.dir === :clock)
  FT <: QuartzModule && return p in _clocksof(FT)
  false
end

function _isclockoutput(T, f, p)
  hasfield(T, f) && isblackbox(fieldtype(T, f)) || return false
  q = _bbport(fieldtype(T, f), p)
  q !== nothing && q.dir === :clockout
end

# the nets an instance's clocks are on, in wiring order, since two clock inputs on
# one net take their edges in that order
function _clockbind(T::Type, f::Symbol)
  binds = Pair{Symbol,Symbol}[]
  T <: QuartzModule && !isblackbox(T) || return binds
  for def in blocks(T), (g, p, net) in def.clockbinds
    g === f && push!(binds, p => net)
  end
  binds
end
function _boundnet(binds::Vector, p::Symbol)
  i = findfirst(b -> b.first === p, binds)
  i === nothing ? nothing : binds[i].second
end
_boundnet(T::Type, f::Symbol, p::Symbol) = _boundnet(_clockbind(T, f), p)

# the same binding as a `Val` a settle pass can read; the block that wires a clock
# output defines the method for it
_clockoutnet(::Type, ::Val, ::Val) = nothing

function _checkbinds(T::Type, v::Vector{BlockDef})
  d = Dict{Symbol,Vector{Pair{Symbol,Symbol}}}()
  driven = Dict{Symbol,String}()
  for def in v, (f, p, net) in def.clockbinds
    binds = get!(d, f, Pair{Symbol,Symbol}[])
    _boundnet(binds, p) === nothing || error("$f.$p is wired twice")
    push!(binds, p => net)
    if _isclockoutput(T, f, p)
      haskey(driven, net) && error("net $net is driven by both $(driven[net]) and $f.$p")
      driven[net] = "$f.$p"
    end
  end
end

function _register!(T::Type, def::BlockDef, slot::Int)
  v = blocks(T)
  slot ≤ length(v) ? (v[slot] = def) : push!(v, def)
  empty!(MCINFO)      # the emitters cache multicycle facts read off this block list
  _checkbinds(T, v)
  _checkblocks(T, v)
  def
end

# a field is driven either by clocked logic or by continuous logic, never both;
# continuous logic drives only ports (outputs and pads), since it has no register
function _checkblocks(T::Type, v::Vector{BlockDef})
  for def in v
    def.kind == :comb || continue
    for f in def.owned
      hasfield(T, f) || continue
      isport(T, f, :out) || _ispadtype(fieldtype(T, f)) || fieldtype(T, f) <: QuartzModule ||
        _ismulticycle(fieldtype(T, f)) ||
        error("@wire writes $f, which is neither an @out port, a pad nor a multicycle wire")
      fieldtype(T, f) <: Pipeline && error("@wire cannot write the pipeline field $f")
      fieldtype(T, f) <: MetaGuard && error("@wire cannot write the metaguard field $f")
    end
  end
  # an instance is wired, never stepped: the simulator steps it on the nets its clocks
  # are wired to, after the blocks of this module
  for def in v, f in def.owned
    hasfield(T, f) && fieldtype(T, f) <: QuartzModule && def.kind == :on &&
      error("$f is an instance, and is stepped by the simulator on the nets its clocks " *
            "are wired to; wire its clocks and inputs in a @wire block, `$f.port ← value`")
    hasfield(T, f) && _ismulticycle(fieldtype(T, f)) && def.kind == :on &&
      error("$f is a multicycle wire, and is driven continuously; write it in a @wire block")
  end
  combfields = Set{Symbol}(f for d in v if d.kind == :comb for f in d.owned)
  for def in v, f in def.owned
    def.kind == :on && f in combfields &&
      error("field $f is written by both an @on and a @wire block")
  end
  # an override names a field to hold at reset; anything else (a typo, or an option
  # this compiler does not have) would otherwise be accepted and quietly ignored
  for def in v, o in def.reset_overrides
    hasfield(T, o.args[1]) ||
      error("reset override $(o.args[1]) is not a field of $(nameof(T))")
    o.args[1] in statics(T) &&
      error("$(o.args[1]) is static: its value comes from the bitstream and reset leaves it alone")
  end
  # one writer per register
  writers = Dict{Symbol,Int}()
  for (i, def) in enumerate(v), f in def.owned
    hasfield(T, f) && fieldtype(T, f) <: QuartzModule && continue   # an instance may be wired from several blocks
    get(writers, f, i) == i ||
      error("field $f is written by two blocks; a register has one writer" *
            (_isguard(T, f) ? " (a guard read by two blocks is fed by both; feed it with `$f ← v` in one)" : ""))
    writers[f] = i
  end
  v
end

_ispadtype(FT) = FT isa Type && FT <: Pad

# where a block was written, which is what makes it the same block across a reload
function _blockline(def::BlockDef)
  ln = _firstline(def.body)
  ln === nothing ? (def.mod, :unknown, 0) : (def.mod, ln.file, ln.line)
end

function _firstline(ex)
  ex isa LineNumberNode && return ex
  ex isa Expr || return nothing
  for a in ex.args
    l = _firstline(a)
    l === nothing || return l
  end
  nothing
end

_isfieldref(ex, state) = ex isa Expr && ex.head == :. && ex.args[1] == state
_isindexedfieldref(ex, state) = ex isa Expr && ex.head == :ref && length(ex.args) == 2 && _isfieldref(ex.args[1], state)
# `inst.port ← v` wires a data input of a black box
_isportref(ex, state) = ex isa Expr && ex.head == :. && _isfieldref(ex.args[1], state) && ex.args[2] isa QuoteNode
_iswritelhs(ex, state) = _isfieldref(ex, state) || _isindexedfieldref(ex, state) ||
  _isportref(ex, state) || _issplitlhs(ex, state)

# `a ⊞ b ← x` takes x apart into its pieces, most significant first; `_` skips one
_issplitlhs(ex, state) = ex isa Expr && ex.head == :call && ex.args[1] === :⊞ && length(ex.args) == 3 &&
  all(a -> a === :_ || _iswritelhs(a, state), ex.args[2:3])

# `x <= v` is Verilog's non-blocking assignment and `x ← v` says the same thing
# without the comparison operator; `=` stays a local variable, deliberately
const WRITEOPS = (:<=, :←)

_iswrite(ex, state) = ex isa Expr && ex.head == :call && length(ex.args) == 3 && ex.args[1] in WRITEOPS &&
  _iswritelhs(ex.args[2], state)

# `m.x <= a < b` parses as a comparison chain, not a call; in statement position it
# is still a write whose value is the rest of the chain
_ischainwrite(ex, state) = ex isa Expr && ex.head == :comparison && length(ex.args) ≥ 5 &&
  ex.args[2] == :(<=) && _iswritelhs(ex.args[1], state)

_writelhs(ex) = ex.head == :call ? ex.args[2] : ex.args[1]
_writefield(ex) = _lhsfield(_writelhs(ex))
_lhsfield(l) = l.head == :ref ? _lhsfield(l.args[1]) : l.args[1] === :this ? l.args[2].value : _lhsfield(l.args[1])
_writeindex(ex) = (l = _writelhs(ex); l.head == :ref ? l.args[2] : nothing)
_writeport(ex) = (l = _writelhs(ex); l.head == :. && l.args[1] !== :this ? l.args[2].value : nothing)
_writevalue(ex) = ex.head == :call ? ex.args[3] :
  length(ex.args) == 5 ? Expr(:call, ex.args[4], ex.args[3], ex.args[5]) : Expr(:comparison, ex.args[3:end]...)

# rewrites statement-position register writes into slot assignments; with `acc` it
# also records the written field names, which is how a block learns its owned
# registers without a second walker
function _rewrite_sim(ex, state, w; stmt=true, acc=nothing, line=nothing)
  ex isa Expr || return ex
  iswrite = stmt && (_iswrite(ex, state) || _ischainwrite(ex, state))
  # `←` binds tighter than `? :`, so `x ← c ? a : b` parses as `(x ← c) ? a : b` and
  # the write disappears. It is never a comparison, so anywhere but a statement it is
  # a mistake.
  !iswrite && ex.head == :call && !isempty(ex.args) && ex.args[1] === :← &&
    error("`←` is a register write and cannot be used as a value" *
          (stmt ? "; its left side must be a field of the module" :
                  ". Did you mean `x ← (cond ? a : b)`?"))
  stmt && !iswrite && _warndiscarded(ex, line)
  if iswrite
    acc !== nothing && _writefield(ex) ∉ acc && push!(acc, _writefield(ex))
    w === nothing && return ex
    slots, flags = w
    f = QuoteNode(_writefield(ex))
    slot, flag, idx = slots[_writefield(ex)], flags[_writefield(ex)], _writeindex(ex)
    _writeport(ex) === nothing ||
      error("a wire to an instance input cannot be conditional: `$(ex.args[2]) ← ...` " *
            "must be a statement of the block itself")
    value = idx === nothing ? :($QuartzHDL._written($state, Val($f), $(_writevalue(ex)))) :
                              :($QuartzHDL._writepart($state, Val($f), $slot, $idx, $(_writevalue(ex))))
    return :($slot = $value; $flag = true)
  elseif ex.head == :(=) && _iswritelhs(ex.args[1], state)
    error("use `x ← value`, not `=`, to write a register")
  elseif ex.head == :block
    out = Any[]
    for a in ex.args
      a isa LineNumberNode && (line = a)
      push!(out, _rewrite_sim(a, state, w; stmt, acc, line))
    end
    return Expr(:block, out...)
  elseif ex.head in (:if, :elseif)
    return Expr(ex.head, _rewrite_sim(ex.args[1], state, w; stmt=false, acc, line),
                map(a -> _rewrite_sim(a, state, w; stmt, acc, line), ex.args[2:end])...)
  elseif ex.head in (:for, :let)
    return Expr(ex.head, ex.args[1], _rewrite_sim(ex.args[2], state, w; stmt, acc, line))
  elseif ex.head == :while
    error("`while` is not allowed in a block")
  end
  _nowrites(ex)
  ex
end

function _nowrites(ex)
  ex isa Expr || return
  ex.head == :quote && return
  ex.head == :call && !isempty(ex.args) && ex.args[1] === :← &&
    error("`←` is a register write and cannot be used as a value; a method that " *
          "writes is called as a statement")
  foreach(_nowrites, ex.args)
end

# `cond && (x ← v)` is the Julia idiom for a one-line `if`, and `cond || (x ← v)`
# for `unless`. The write is the rightmost operand and everything to its left is the
# condition, so a chain like `a && b && (x ← v)` reads the way it does in Julia.
function _sugarwrites(ex; stmt=true)
  ex isa Expr || return ex
  if stmt
    guarded = _guardedwrite(ex)
    guarded === nothing || return guarded
  end
  ex.head == :block && return Expr(:block, map(a -> _sugarwrites(a; stmt), ex.args)...)
  ex.head in (:if, :elseif) && return Expr(ex.head, _sugarwrites(ex.args[1]; stmt=false),
                                           map(a -> _sugarwrites(a; stmt), ex.args[2:end])...)
  ex.head in (:for, :let) && return Expr(ex.head, ex.args[1], _sugarwrites(ex.args[2]; stmt))
  ex
end

function _guardedwrite(ex)
  ex isa Expr && ex.head in (:&&, :||) || return nothing
  write = _unblock(ex.args[2])
  inner = _guardedwrite(write)
  if inner === nothing
    _iswrite(write, :this) || _ischainwrite(write, :this) || _haswrite(write) || return nothing
    inner = write
  end
  cond = _unblock(ex.args[1])
  ex.head == :&& ? Expr(:if, cond, Expr(:block, inner)) :
                   Expr(:if, Expr(:call, :!, cond), Expr(:block, inner))
end

# an inlined method is a block; one that writes is guarded as a write is
_haswrite(ex) = ex isa Expr && ex.head == :block &&
  any(a -> _iswrite(a, :this) || _ischainwrite(a, :this) || _haswrite(a) ||
           (a isa Expr && a.head == :if && any(_haswrite, a.args[2:end])), ex.args)

function _unblock(ex)
  ex isa Expr && ex.head == :block || return ex
  stmts = filter(x -> !(x isa LineNumberNode), ex.args)
  length(stmts) == 1 ? _unblock(stmts[1]) : ex
end

# a statement-walker: `f(stmt_expr)` is applied to every statement, and the result
# stands in its place; statement positions are the items of a block, the branches
# of an `if`, and the bodies of `for` and `let`
function _mapstmts(f, ex)
  ex isa Expr || return ex
  ex.head == :block && return Expr(:block, map(a -> _mapstmts(f, a), ex.args)...)
  ex.head in (:if, :elseif) && return Expr(ex.head, ex.args[1], map(a -> _mapstmts(f, a), ex.args[2:end])...)
  ex.head in (:for, :let) && return Expr(ex.head, ex.args[1], _mapstmts(f, ex.args[2]))
  f(ex)
end

function _splitwrites(body, what)
  _mapstmts(body) do ex
    _iswrite(ex, :this) && _issplitlhs(_writelhs(ex), :this) || return ex
    pieces = _splitpieces(_writelhs(ex))
    count(p -> p === :_, pieces) ≤ 1 || error("$what: `_` may skip one piece of a split write")
    tmp, ws = gensym(:word), gensym(:widths)
    widths = [p === :_ ? :nothing : _piecewidth(p) for p in pieces]
    out = Any[:(local $tmp = $(_writevalue(ex))), :(local $ws = $(Expr(:tuple, widths...)))]
    for (i, p) in enumerate(pieces)
      p === :_ && continue
      push!(out, Expr(:call, :←, p, :($QuartzHDL._piece($tmp, $ws, $i))))
    end
    Expr(:block, out...)
  end
end

_splitpieces(lhs) = _issplitlhs(lhs, :this) ? vcat(_splitpieces(lhs.args[2]), _splitpieces(lhs.args[3])) : Any[lhs]

_piecewidth(p) = p.head == :ref ? :(length($(p.args[2]))) :
                 :($QuartzHDL._fieldwidth(this, Val($(p.args[2]))))

# a guard with an input of its own name is fed by it, from the block that reads the
# guard: the feed is an ordinary write, so a guard read by two blocks is two writers
function _guardfeeds(body, T, inports)
  guards = [f for f in fieldnames(T) if _isguard(T, f) && f in inports]
  isempty(guards) && return body
  written = _writtenfields(body)
  feeds = [g for g in guards if g ∉ written && _mentions(body, g)]
  isempty(feeds) && return body
  Expr(:block, body.args..., (Expr(:call, :←, Expr(:., :this, QuoteNode(g)), g) for g in feeds)...)
end

function _writtenfields(body)
  acc = Symbol[]
  _mapstmts(body) do ex
    (_iswrite(ex, :this) || _ischainwrite(ex, :this)) && _writefield(ex) ∉ acc && push!(acc, _writefield(ex))
    ex
  end
  acc
end

_mentions(ex, f) = ex isa Expr &&
  (_isfieldref(ex, :this) && ex.args[2].value === f || any(a -> _mentions(a, f), ex.args))

# `en && (x <= y)` compiles and does nothing: in expression position the `<=` is a
# comparison, and its value is thrown away. Nothing else computes a value as a
# statement and discards it, so the shape alone is enough to flag.
const _PUREOPS = Set([:(==), :!=, :<, :(<=), :>, :(>=), :+, :-, :*, :&, :|, :⊻, :⊞,
                      :~, :!, :<<, :>>, :>>>])

function _warndiscarded(ex, line)
  ex isa Expr || return
  bad = ex.head in (:&&, :||, :comparison) ||
        (ex.head == :call && ex.args[1] isa Symbol && ex.args[1] in _PUREOPS)
  bad || return
  where = line === nothing ? "" : " at $(line.file):$(line.line)"
  @warn "block$where: statement computes a value and discards it; a write needs `x ← v`"
end

# the value a slot holds before the block writes it, in the type a write resolves to
_slotinit(this::T, ::Val{f}) where {T,f} = _slotinit(fieldtype(T, f), getfield(this, f))
_slotinit(::Type{Pipeline{K,ET}}, cur) where {K,ET} = zero(ET)
_slotinit(::Type{<:Multicycle}, cur) = cur
_slotinit(::Type{<:MetaGuard}, cur) = false
_slotinit(::Type{Edge}, cur) = cur.cur
_slotinit(::Type{<:QuartzModule}, cur) = _inputsof(cur)
_slotinit(::Type, cur) = cur

_slottype(::Type{Pipeline{K,ET}}) where {K,ET} = ET
_slottype(::Type{<:MetaGuard}) = Bool
_slottype(::Type{Edge}) = Bool
_slottype(::Type{M}) where M<:QuartzModule = fieldtype(M, INPUTS)
_slottype(::Type{FT}) where FT = FT

# a value takes the field's type where it is written, so the slot holding it has
# one type on every path through the block
_written(this::T, ::Val{f}, v) where {T,f} =
  _resolve(fieldtype(T, f), getfield(this, f), v)::_slottype(fieldtype(T, f))

# inside a block `clocklevel(:net)` reads the block's own module
function _thislevel(ex)
  ex isa Expr || return ex
  ex.head == :call && length(ex.args) == 2 && ex.args[1] === :clocklevel && ex.args[2] isa QuoteNode &&
    return Expr(:call, :clocklevel, :this, ex.args[2])
  Expr(ex.head, map(_thislevel, ex.args)...)
end

# a clock net read as data is named by a literal, so the read dispatches to the
# method evaluated for that net rather than looking the net up on every pass
function _levelvals(ex)
  ex isa Expr || return ex
  if ex.head == :call && length(ex.args) == 3 && ex.args[1] === :clocklevel && ex.args[3] isa QuoteNode
    return Expr(:call, :clocklevel, _levelvals(ex.args[2]), :(Val($(ex.args[3]))))
  end
  Expr(ex.head, map(_levelvals, ex.args)...)
end

# The wires to an instance's inputs are gathered, for the simulator, into one
# named tuple per instance at the end of the block -- a wire to an input is never
# conditional, so the values are all there -- and land on the instance in one
# write. The names are literal, so the tuple's type is known where the block
# compiles.
function _gatherports(body::Expr)
  out = Any[]
  ports = Dict{Symbol,Vector{Tuple{Symbol,Symbol}}}()
  order = Symbol[]
  for ex in body.args
    if ex isa Expr && ex.head == :call && length(ex.args) == 3 &&
        ex.args[1] in WRITEOPS && _isportref(ex.args[2], :this)
      f, p = ex.args[2].args[1].args[2].value, ex.args[2].args[2].value
      tmp = gensym(Symbol(f, "_", p))
      f in order || push!(order, f)
      push!(get!(ports, f, Tuple{Symbol,Symbol}[]), (p, tmp))
      push!(out, :(local $tmp = $(ex.args[3])))
    else
      push!(out, ex)
    end
  end
  for f in order
    names = Tuple(p for (p, _) in ports[f])
    push!(out, Expr(:call, :←, Expr(:., :this, QuoteNode(f)),
                    :(NamedTuple{$names}($(Expr(:tuple, (t for (_, t) in ports[f])...))))))
  end
  Expr(:block, out...)
end

function _wireinputs(x::T, nt::NamedTuple) where T<:QuartzModule
  isblackbox(T) && return _wireboxinputs(x, nt)
  new = _setinputs(getfield(x, INPUTS), nt)
  new === getfield(x, INPUTS) ? x : _merge(x, NamedTuple{(INPUTS,)}((new,)))
end

# the wired values take their places in the instance's record, each coerced to the
# type the input declares; an input the block does not wire keeps what it had
@generated function _setinputs(old::NamedTuple{N,T}, nt::NamedTuple{M}) where {N,T,M}
  for m in M
    m in N || return :(error($("no input called $m; the inputs are " * join(N, ", "))))
  end
  vals = [m in M ? :(_coerce($(fieldtype(T, i)), getfield(nt, $(QuoteNode(m))))) : :(getfield(old, $(QuoteNode(m))))
          for (i, m) in enumerate(N)]
  :(NamedTuple{N}($(Expr(:tuple, vals...))))
end

_inputsof(x) = getfield(x, INPUTS)

# An input reads as a property of the state, so a helper handed `this` sees the
# inputs of the step along with the registers. The inputs a step supplies are
# wired in before the block runs; one it leaves out reads as its default, or as
# what the last step supplied.
@generated function _wirepresent(m::T, kw::NamedTuple{K}) where {T,K}
  names = Tuple(k for k in K if k in fieldnames(fieldtype(T, INPUTS)))
  isempty(names) && return :m
  :(_wireinputs(m, NamedTuple{$names}(($((:(getfield(kw, $(QuoteNode(n)))) for n in names)...),))))
end
Base.getproperty(m::QuartzModule, f::Symbol) =
  hasfield(typeof(m), f) ? getfield(m, f) : getfield(getfield(m, INPUTS), f)
Base.propertynames(m::QuartzModule) =
  (filter(!=(INPUTS), fieldnames(typeof(m)))..., keys(getfield(m, INPUTS))...)

# a partial write leaves the bits it does not name alone, on top of whatever the
# block wrote before it, or the current value if it wrote nothing
_writepart(this::T, ::Val{f}, cur, idx, v) where {T,f} =
  _setbits(fieldtype(T, f), cur, _asrange(idx), v)::_slottype(fieldtype(T, f))

function _setbits(::Type{FT}, base, r, x) where FT
  lo, n = _partbits(r, bitwidth(FT), "register")
  msk = _mask(n) << lo
  raw = (_toraw(base) & ~msk) | ((_toraw(_coerce(n == 1 ? Bool : Bits{n}, x)) << lo) & msk)
  FT === Bool ? isodd(raw) : FT(raw)
end

function _setbits(::Type{Pad{N}}, p::Pad{N}, r, x) where N
  lo, n = _partbits(r, N, "pad")
  msk = _mask(n) << lo
  (bv, be) = _padfold(Bits{n}, _aspadvalue(x))
  bv = p.activelow ? ~bv : bv
  val = (p.val.val & ~msk) | ((bv.val << lo) & msk)
  oe = (p.oe.val & ~msk) | ((be.val << lo) & msk)
  Pad{N}(Bits{N}(val), Bits{N}(oe), p.ext, p.exten, p.pull, p.activelow)
end

_asrange(d::DynRange) = d
_asrange(i::Integer) = (i ≥ 0 || throw(ArgumentError("a bit index cannot be negative, got $i")); Int(i):Int(i))
function _asrange(r::AbstractUnitRange{<:Integer})
  0 ≤ first(r) ≤ last(r) ||
    throw(ArgumentError("a partial write needs an ascending range of bit indices, got $r"))
  Int(first(r)):Int(last(r))
end

# the pieces of a split write, most significant first; one piece may take what the
# others leave, and the widths have to add up to the word
function _piece(x, widths::Tuple, i::Int)
  b = bits(x)
  total = bitwidth(b)
  known = sum(w for w in widths if w !== nothing; init=0)
  rest = total - known
  if any(w -> w === nothing, widths)
    rest ≥ 0 || throw(ArgumentError("the pieces of a split write need $known bits and the word has $total"))
  else
    rest == 0 || throw(ArgumentError("the pieces of a split write add up to $known bits and the word has $total"))
  end
  hi = total - 1
  for j in 1:i-1
    hi -= something(widths[j], rest)
  end
  w = something(widths[i], rest)
  w ≥ 1 || throw(ArgumentError("a piece of a split write has no bits"))
  b[hi-w+1:hi]
end

_fieldwidth(m::QuartzModule, ::Val{f}) where f = bitwidth(fieldtype(typeof(m), f))

_runclock(m, ::Val, ::Val, kw) = m
_settlepasses(m, kw, strict::Bool) = m

# The blocks of a module are its slots. Each `@on` or `@wire` defines, in the
# module's own namespace, the block's function and what the block is -- kind, clock,
# edge, the fields it owns, the inputs it needs, the clocks it wires -- as methods on
# its slot number. What follows is generic code folded over the slots, which the
# compiler unrolls into the same straight-line step a hand-written method would be:
# nothing is ever evaluated into QuartzHDL, so a design precompiles in the package
# that holds it, and a block reloaded in place is followed by the step.
_blockfn(::Type, ::Val) = nothing
_blockmeta(::Type, ::Val) = nothing
_blocksteps(m, ::Val, ::Val, ctx) = m
_blockedges(m, ::Val) = ()

# how many slots a module has, as a constant: a recursion over the slot number is
# widened by the compiler, so the count is a straight line of tests it folds instead
const MAXSLOTS = 64
@generated _slotcount(::Type{T}) where T =
  foldr((i, rest) -> :(_blockmeta(T, Val($i)) === nothing ? $(Val(i - 1)) : $rest), 1:MAXSLOTS;
        init = Val(MAXSLOTS))

_combcount(::Val{meta}) where meta = meta[1] === :comb ? length(meta[4]) : 0

# the clocks of a module: the ones its blocks run on, then the nets its instances
# take a clock from
_clocks(::Type{T}) where T = _clocksval(T, _slotcount(T))
@generated _clocksval(::Type{T}, ::Val{n}) where {T,n} =
  :(_metaclocks($((:(_blockmeta(T, Val($i))) for i in 1:n)...)))
# the metas arrive as types, so the tuple is computed here, not at run time
@generated function _metaclocks(metas::Vararg{Val})
  out = Symbol[]
  for M in metas
    meta = M.parameters[1]
    meta[1] === :on && !(meta[2] in out) && push!(out, meta[2])
  end
  for M in metas, (f, p, net, dir) in M.parameters[1][6]
    dir === :in && !(net in out) && push!(out, net)
  end
  QuoteNode(Tuple(out))
end

# The simulator steps every instance of a module on an edge of a net one of its
# clocks is wired to, after the module's own blocks: the inputs an instance sees are
# the ones the wires held before the edge, as in hardware. Each block steps the
# instances it wired, in slot order.
_stepinstances(m::T, net::Val, ctx) where T<:QuartzModule = _stepinstances(m, net, ctx, _slotcount(T))
@generated function _stepinstances(m::T, net::Val, ctx, ::Val{n}) where {T,n}
  steps = [:(m = _blocksteps(m, net, Val($i), ctx)) for i in 1:n]
  Expr(:block, steps..., :m)
end

# Every clock output in the module tree that is wired to a net, as (net, divide,
# ticked this slot): the ones this module's blocks wired, in slot order, then the
# ones below. A clock that divides is settled before the faster clock beside it, so
# a design sampling a slow clock as data reads the new level. The emitted Verilog
# orders its delays the same way; the two have to agree or a crossing lands a cycle
# apart.
_treeedges(m::T) where T<:QuartzModule = _treeedges(m, _slotcount(T))
@generated function _treeedges(m::T, ::Val{n}) where {T,n}
  isblackbox(T) && return :(())
  parts = Any[:(_blockedges(m, Val($i))...) for i in 1:n]
  for (f, FT) in zip(fieldnames(T), fieldtypes(T))
    FT <: QuartzModule && !isblackbox(FT) && push!(parts, :(_treeedges(getfield(m, $(QuoteNode(f))))...))
  end
  Expr(:tuple, parts...)
end

# A submodule's pads are the enclosing module's pads too, so what the outside
# drives, and what the rest of the design drives on each net, travel down the tree
# with the step as one typed record: snapshotted once at the top, from the settled
# state, and read by the module that owns the pad.
struct PadContext{D<:NamedTuple,N<:NamedTuple}
  drives::D
  nets::N
end

function _stepwith(m::T, clk::Val, kw::NamedTuple) where T
  m = _presettle(_wirepresent(m, kw), kw)
  _stepinner(m, clk, kw, PadContext(kw, _netdrives(m)))
end

# one clock edge of a module and of every instance on the net
function _stepinner(m::T, clk::Val, kw, ctx) where T
  m = _driveexternal(m, kw, ctx)
  m = _presettle(m, kw)
  m = _settled(_stepinstances(_runclock(m, clk, Val(:posedge), kw), clk, ctx), m, kw)
  _settled(_runclock(m, clk, Val(:negedge), kw), m, kw)    # the falling edge sees settled logic too
end

# an edge that moved nothing left the wires as they were
_settled(new, old, kw) = new === old ? new : _settlepasses(new, kw, true)

# the new state is the old one with some fields replaced; building it positionally
# keeps every field typed, where a keyword splat would box them all
@generated function _merge(m::T, new::NamedTuple{names}) where {T,names}
  args = [f in names ? :(getfield(new, $(QuoteNode(f)))) : :(getfield(m, $(QuoteNode(f))))
          for f in fieldnames(T)]
  :($T($(args...)))
end

@generated function _applyblock(new::T, old::T, ::Val{owned}, r) where {T,owned}
  q(f) = QuoteNode(f)
  vals = [Expr(:kw, f, :(getfield(r.written, $i) ?
                           _newvalue($T, Val($(q(f))), getfield(old, $(q(f))), getfield(r.writes, $(q(f))), r.reset) :
                           _unwritten($T, Val($(q(f))), getfield(old, $(q(f))), r.reset)))
          for (i, f) in enumerate(owned)]
  :(_merge(new, $(Expr(:tuple, Expr(:parameters, vals...)))))
end

_newvalue(::Type{T}, ::Val{f}, cur::Pipeline, w, reset) where {T,f} =
  reset ? _resetval(T, Val(f), cur) : _advance(cur, w, true)
_newvalue(::Type{T}, ::Val{f}, cur::MetaGuard, w, reset) where {T,f} =
  reset ? _resetval(T, Val(f), cur) : _shiftguard(cur, w)
# a reset override sets the level without manufacturing an event
_newvalue(::Type{T}, ::Val{f}, cur::Edge, w, reset) where {T,f} = reset ? Edge(w) : Edge(w, cur.cur)
_newvalue(::Type{T}, ::Val{f}, cur, w, reset) where {T,f} = w

_unwritten(::Type{T}, ::Val{f}, cur::Pipeline{K,ET}, reset) where {T,f,K,ET} =
  reset ? _resetval(T, Val(f), cur) : _advance(cur, zero(ET), false)
# an unwritten Edge settles: the history catches up, so an event lasts one cycle
_unwritten(::Type{T}, ::Val{f}, cur::Edge, reset) where {T,f} =
  reset ? _resetval(T, Val(f), cur) : Edge(cur.cur, cur.cur)
_unwritten(::Type{T}, ::Val{f}, cur, reset) where {T,f} = reset ? _resetval(T, Val(f), cur) : cur

# The struct defaults are what a reset restores and what an unsettled field still
# holds. Constructing them costs a whole default tree (black boxes included), so a
# type's default instance is built once and its fields read from it.
const DEFAULTS = IdDict{Type,Any}()
_defaults(::Type{T}) where T = get!(DEFAULTS, T) do
  T()
end
_default(::Type{T}, ::Val{f}) where {T,f} = getfield(_defaults(T)::T, f)::fieldtype(T, f)

# Continuous logic runs before the clocked blocks as well as after them, over the
# whole module tree, so the values read during the cycle are settled even on the
# first step, when the fields still hold the struct defaults.
_presettle(m::T, kw) where T = _settlepasses(m, kw, false)

# One edge: every @on block on this clock and edge runs against the old state, and
# the writes merge in slot order. A multicycle wire's settle count moves with the
# names the edge wrote.
function _runclock(m::T, clk::Val, edge::Val, kw) where T<:QuartzModule
  _runclock(m, clk, edge, kw, _slotcount(T), _hasmulticycle(T) ? Symbol[] : nothing)
end
@generated _hasmulticycle(::Type{T}) where T = any(_ismulticycle(FT) for FT in fieldtypes(T))
@generated _runclock(m::T, clk::Val, edge::Val, kw, ::Val{n}, written) where {T,n} =
  :(_runedge(m, kw, written, clk, edge, $((:(_blockmeta(T, Val($i))) for i in 1:n)...)))
@generated function _runedge(m::T, kw, written, ::Val{clk}, ::Val{edge}, metas::Vararg{Val}) where {T,clk,edge}
  body = Any[:(acc = m)]
  for (i, M) in enumerate(metas)
    kind, c, e, owned = M.parameters[1]
    kind === :on && c === clk && e === edge || continue
    push!(body, quote
      let r = _blockfn(T, Val($i))(m, kw)
        if r !== nothing
          acc = _applyblock(acc, m, $(Val(owned)), r)
          written === nothing || _writtennames!(written, $(Val(owned)), r)
        end
      end
    end)
  end
  push!(body, :(written === nothing ? acc : _advancemulticycles(acc, Val(clk), Val(edge), written)))
  Expr(:block, body...)
end

# A block may read what another block drives, so the pass repeats until nothing
# moves: each pass resolves at least one more field of a chain, whether the chain
# runs between blocks or between fields of one block, so more passes than there are
# fields means the blocks depend on each other.
# settling takes its mode positionally: a keyword call on this path allocated
@inline function _settlepasses(m::T, kw, strict::Bool) where T<:QuartzModule
  passes = _combpasses(T, _slotcount(T))
  passes == 0 && return m
  for _ in 1:passes
    settled = _settleonce(m, kw, strict, _slotcount(T))
    _same(settled, m) && return m
    m = settled
  end
  _same(_settleonce(m, kw, strict, _slotcount(T)), m) ||
    error("@wire blocks of $(nameof(T)) depend on each other in a loop")
  m
end

# the same state: by value, since a mutable module is a new object every pass
@generated function _same(a::T, b::T) where T
  ismutabletype(T) || return :(a === b)
  foldl((acc, f) -> :($acc && _same(getfield(a, $(QuoteNode(f))), getfield(b, $(QuoteNode(f))))), fieldnames(T); init=true)
end
_same(a, b) = a === b
@generated _combpasses(::Type{T}, ::Val{n}) where {T,n} =
  Expr(:call, :+, 0, (:(_combcount(_blockmeta(T, Val($i)))) for i in 1:n)...)

# one settle pass: every @wire block's slot, in order; a settled state that differs
# from the one handed in is what "moved" means
_settleslot(acc, m, kw, strict::Bool, ::Val) = acc
@generated _settleonce(m::T, kw, strict, ::Val{n}) where {T,n} =
  Expr(:block, :(acc = m), (:(acc = _settleslot(acc, m, kw, strict, Val($i))) for i in 1:n)..., :acc)

# the fields a block wrote on this edge; a reset writes everything the block owns
function _writtennames!(acc::Vector{Symbol}, ::Val{owned}, r) where owned
  for (i, f) in enumerate(owned)
    (r.reset || r.written[i]) && push!(acc, f)
  end
  acc
end

# A multicycle wire's settle count moves once per edge of the clock its sources are
# on: back to zero when one of them was written, up by one otherwise. Which fields
# those are is read off the traced logic, once per type.
@generated function _advancemulticycles(m::T, ::Val{clk}, ::Val{edge}, written) where {T,clk,edge}
  fs = [f for (f, FT) in zip(fieldnames(T), fieldtypes(T)) if _ismulticycle(FT)]
  isempty(fs) && return :m
  vals = [Expr(:kw, f, :(_settleedge(getfield(m, $(QuoteNode(f))), _mcinfo(T, $(QuoteNode(f))), clk, edge, written)))
          for f in fs]
  :(_merge(m, $(Expr(:tuple, Expr(:parameters, vals...)))))
end

function _settleedge(mc::Multicycle, info, clk::Symbol, edge::Symbol, written::Vector{Symbol})
  info.clock === clk && info.edge === edge || return mc
  _settlestep(mc, any(s in written for s in info.sources))
end

# the state `new` with a @wire block's writes `r` merged in, an instance's inputs
# settling the instance; a field the block left unwritten this cycle is an error
function _applycombexpr(T, owned, new, old, r)
  q(f) = QuoteNode(f)
  value(f) = fieldtype(T, f) <: QuartzModule ?
    :($QuartzHDL._combinst(getfield($old, $(q(f))), getfield($r.writes, $(q(f))))) : :(getfield($r.writes, $(q(f))))
  vals = [Expr(:kw, f, :(getfield($r.written, $i) ? $(value(f)) : $QuartzHDL._undriven($(q(f)))))
          for (i, f) in enumerate(owned)]
  :($QuartzHDL._merge($new, $(Expr(:tuple, Expr(:parameters, vals...)))))
end

# continuous logic has nothing to hold a value with, so a path that leaves a field
# unwritten is an error here exactly as it is when emitting Verilog
_undriven(f::Symbol) = error("@wire left $f undriven this cycle; every path through the block must write it")

# A block writes an instance's inputs, not the instance: the record of inputs has
# no pointers in it, so the write set stays inline. An instance's wires have settled
# when the inputs are what they were; new ones settle the instance's own wires in
# turn, so a value can travel down and back up. A black box has no wires to settle.
function _combinst(cur::T, w::NamedTuple) where T
  w === _inputsof(cur) && return cur
  new = _wireinputs(cur, w)
  isblackbox(T) ? new : _settlepasses(new, w, false)
end

# the outside world drives a pad through a step keyword of the pad's own name:
# `missing` (or an absent keyword) leaves it undriven, a value drives every bit,
# and a (value, mask) pair drives only the masked bits
@generated function _driveexternal(m::T, kw, ctx) where T
  pads = [f for (f, FT) in zip(fieldnames(T), fieldtypes(T)) if FT <: Pad]
  isempty(pads) && return :m
  vals = [Expr(:kw, f, :(_drivepad($(QuoteNode(f)), getfield(m, $(QuoteNode(f))),
                                   _outerdrive(kw, ctx.drives, Val($(QuoteNode(f)))),
                                   _netdrive(ctx.nets, Val($(QuoteNode(f)))))))
          for f in pads]
  :(_merge(m, $(Expr(:tuple, Expr(:parameters, vals...)))))
end

_outerdrive(kw, drives, ::Val{f}) where f =
  haskey(kw, f) ? getfield(kw, f) : haskey(drives, f) ? getfield(drives, f) : missing
_netdrive(nets, ::Val{f}) where f = haskey(nets, f) ? getfield(nets, f) : (UInt128(0), UInt128(0))

function _drivepad(f::Symbol, p::Pad{N}, v, net::Tuple{UInt128,UInt128}) where N
  ext, exten = _extpair(Pad{N}, v)
  # what the *rest* of the design drives: a module never fights itself, and its
  # own drive is what it reads back on the bits it drives (`padnet` gives the
  # whole net, which is what a bench or a co-simulation compares)
  nv, nm = net
  nm &= ~p.oe.val
  if p.pull == :none
    clash = ((p.oe.val & (p.val.val ⊻ ext.val)) | (nm & (nv ⊻ ext.val))) & exten.val
    clash == 0 || error("pad $f is driven to conflicting values by the design and " *
                        "from outside on bit(s) $(string(clash; base=2))")
  end
  Pad{N}(p.val, p.oe, Bits{N}((ext.val & exten.val) | (nv & nm)), Bits{N}(exten.val | nm), p.pull, p.activelow)
end

# Several modules of one design may name the same pad: it is one net, and each of
# them sees what the others drive on it. At most one may drive a given bit. The
# design's combined drive on each net, in (value, mask) form, keyed by pad name;
# on a pulled net a bit held low by any module reads low whatever the others do.
# The walk to every pad is one flat expression over the type tree.
@generated function _netdrives(m::T) where T
  names = Symbol[]
  pads = Dict{Symbol,Vector{Any}}()
  walk(x, T) = for (f, FT) in zip(fieldnames(T), fieldtypes(T))
    e = :(getfield($x, $(QuoteNode(f))))
    if FT <: Pad
      f in names || push!(names, f)
      push!(get!(pads, f, Any[]), e)
    elseif FT <: QuartzModule && !isblackbox(FT)
      walk(e, FT)
    end
  end
  walk(:m, T)
  body = Any[]
  vals = Any[]
  for f in names
    acc = gensym(f)
    push!(body, :($acc = (UInt128(0), UInt128(0), UInt128(0))))
    for e in pads[f]
      push!(body, :($acc = _accpad($(QuoteNode(f)), $e, $acc)))
    end
    push!(vals, :(_netdrive($(pads[f][end]), $acc)))
  end
  quote
    $(body...)
    NamedTuple{$(Tuple(names))}($(Expr(:tuple, vals...)))
  end
end

function _accpad(f::Symbol, p::Pad, acc::NTuple{3,UInt128})
  low, high, oe = acc
  plow = p.oe.val & ~p.val.val
  phigh = p.oe.val & p.val.val
  if p.pull == :none
    clash = (low & phigh) | (high & plow)
    clash == 0 ||
      error("pad $f is driven to conflicting values by two modules on bit(s) $(string(clash; base=2))")
  end
  (low | plow, high | phigh, oe | p.oe.val)
end

function _netdrive(p::Pad{N}, acc::NTuple{3,UInt128}) where N
  low, high, oe = acc
  val = p.pull == :pullup ? (_mask(N) & ~low) : p.pull == :pulldown ? high : (high & ~low)
  (val, oe)
end

_extpair(::Type{Pad{N}}, v) where N =
  v === missing ? (Bits{N}(), Bits{N}()) :
  v isa Tuple ? (_coerce(Bits{N}, v[1]), _coerce(Bits{N}, v[2])) :
  (_coerce(Bits{N}, v), Bits{N}(_mask(N)))

# A reset restores the default of a field that has one. A field declared without
# a default powers up at zero and is not reset, as a data register in an FPGA is
# not. A pipeline and a guard flush; a pad is a pin, and keeps what it drives.
_resetval(::Type{T}, v::Val{f}, cur) where {T,f} = _resetval(fieldtype(T, f), f in resets(T), _default(T, v), cur)
_resetval(::Type{FT}, has, default, cur) where FT = has ? default : cur
_resetval(::Type{<:Pipeline}, has, default, cur) = default
_resetval(::Type{<:MetaGuard}, has, default, cur) = default
_resetval(::Type{<:Pad}, has, default, cur) = cur

_partbits(r::UnitRange{Int}, W, what) =
  (last(r) < W || throw(ArgumentError("a partial write to bits $r does not fit a $(W)-bit $what"));
   (first(r), length(r)))
_partbits(d::DynRange, W, what) = (_dynbase(d, W, what), d.width)

_resolve(::Type{FT}, cur, v) where FT = _coerce(FT, v)
_resolve(::Type{FT}, cur::QuartzModule, v::NamedTuple) where FT = _setinputs(_inputsof(cur), v)
_resolve(::Type{Pipeline{K,ET}}, cur, v) where {K,ET} = _coerce(ET, v)
_resolve(::Type{Multicycle{K,ET}}, cur::Multicycle{K,ET}, v) where {K,ET} = Multicycle{K,ET}(_coerce(ET, v), cur.settle)
_resolve(::Type{MetaGuard{K}}, cur, v) where K = _coerce(Bool, v)
_resolve(::Type{Edge}, cur, v) = _coerce(Bool, v)
_resolve(::Type{Pad{N}}, p::Pad{N}, v) where N = _resolvepad(p, _aspadvalue(v))
_resolve(::Type{Pad{N}}, p::Pad{N}, v::Pad{N}) where N = v

# a plain value written to a pad drives every bit of it
_aspadvalue(v::PadValue) = v
_aspadvalue(v) = drive(v)

function _resolvepad(p::Pad{N}, v::PadValue) where N
  vo = _padfold(Bits{N}, v)
  Pad{N}(_padinvert(p, vo[1]), vo[2], p.ext, p.exten, p.pull, p.activelow)
end

_coerce(::Type{T}, v::T) where T = v
_coerce(::Type{Bool}, v::Bits{1}) = Bool(v)
_coerce(::Type{Bool}, v::HWInt) = throw(ArgumentError(
  "writing a $(bitwidth(v))-bit value to a 1-bit register needs an explicit conversion"))
_coerce(::Type{Bool}, v::Integer) = Bool(v)
_coerce(::Type{T}, v::Bool) where T<:HWInt = T(v)
_coerce(::Type{T}, v::Union{Base.BitInteger,BigInt}) where T<:HWInt = _lift(T, v)
_coerce(::Type{T}, v::HWInt) where T<:HWInt = bitwidth(T) == bitwidth(v) ? T(v) :
  throw(ArgumentError("writing a $(bitwidth(v))-bit value to a $(bitwidth(T))-bit " *
                      "register needs an explicit conversion"))
_coerce(::Type{T}, v) where T = convert(T, v)

function _boundnames!(acc, ex)
  ex isa Expr || return
  if ex.head in (:(=), :local) && !isempty(ex.args)
    _lhsnames!(acc, ex.args[1])
  elseif ex.head == :for
    _lhsnames!(acc, ex.args[1] isa Expr && ex.args[1].head == :(=) ? ex.args[1].args[1] : ex.args[1])
  end
  for a in ex.args
    _boundnames!(acc, a)
  end
end

_lhsnames!(acc, x::Symbol) = push!(acc, x)
_lhsnames!(acc, x::Expr) = x.head in (:tuple, :(::)) ? foreach(a -> _lhsnames!(acc, a), x.args) : nothing
_lhsnames!(acc, ::Any) = nothing

# A bare name in a block body means the field of that name, so a design reads the
# way the Verilog it replaces does. A name that is both a field and a local is an
# error rather than a silent shadow.
function _barenames(ex, fields, bound)
  ex isa Symbol && return ex in fields && !(ex in bound) ? Expr(:., :this, QuoteNode(ex)) : ex
  ex isa Expr || return ex
  h = ex.head
  h in (:quote, :macrocall, :meta) && return ex
  rec(a) = _barenames(a, fields, bound)
  h == :. && return Expr(:., rec(ex.args[1]), ex.args[2])
  h == :kw && return Expr(:kw, ex.args[1], rec(ex.args[2]))
  h == :call && return Expr(:call, ex.args[1], map(rec, ex.args[2:end])...)
  Expr(h, map(rec, ex.args)...)
end

# the names a body refers to that it does not bind: after the fields have been
# qualified, what is left is inputs, globals, and mistakes
# `this` anywhere but as the object of `this.field` or `this[...]`, or as the state
# handle a package accessor like `clocklevel(this, :net)` takes
_passesthis(ex) = ex === :this ||
  (ex isa Expr && !_thisaccess(ex) && any(_passesthis, ex.args))
_thisaccess(ex) =
  (ex.head in (:., :ref) && ex.args[1] === :this && !any(_passesthis, ex.args[2:end])) ||
  (ex.head == :call && _macroname(ex.args[1]) === :clocklevel && ex.args[2] === :this &&
   !any(_passesthis, ex.args[3:end]))

function _freesyms(ex, bound)
  acc = Symbol[]
  _freesyms!(acc, ex, bound)
  acc
end

function _freesyms!(acc, ex, bound)
  ex isa Symbol && return (ex in bound || ex in acc || push!(acc, ex); nothing)
  ex isa Expr || return
  h = ex.head
  h in (:quote, :meta) && return
  h == :. && return _freesyms!(acc, ex.args[1], bound)
  h == :kw && return _freesyms!(acc, ex.args[2], bound)
  h == :call && return foreach(a -> _freesyms!(acc, a, bound), ex.args[2:end])
  foreach(a -> _freesyms!(acc, a, bound), ex.args)
end

# A bare state name is resolved where it meets the register that holds the
# encoding: assigned to it, or compared with it. Anywhere else it is a number,
# and written with its encoding's name.
function _encodednames(ex, T)
  encs = encodings(T)
  isempty(encs) && return ex
  _encwalk(ex, encs)
end

_encfield(ex, encs) = _isfieldref(ex, :this) && haskey(encs, ex.args[2].value) ? encs[ex.args[2].value] : nothing

function _encwalk(ex, encs)
  ex isa Expr || return ex
  rec(a) = _encwalk(a, encs)
  if ex.head == :call && length(ex.args) == 3 && ex.args[1] in (:←, :<=, :(==), :!=)
    a, b = ex.args[2], ex.args[3]
    ea, eb = _encfield(a, encs), _encfield(b, encs)
    ea !== nothing && return Expr(:call, ex.args[1], a, _encvalue(b, ea))
    eb !== nothing && ex.args[1] in (:(==), :!=) && return Expr(:call, ex.args[1], _encvalue(a, eb), b)
  end
  ex.head in (:quote, :meta) && return ex
  ex.head == :. && return Expr(:., rec(ex.args[1]), ex.args[2])
  Expr(ex.head, map(rec, ex.args)...)
end

# through a conditional, so `state ← go ? run : idle` resolves both arms
function _encvalue(ex, enc)
  ex isa Symbol && ex in keys(enc) && return getproperty(enc, ex)
  ex isa Expr || return ex
  ex.head == :if && length(ex.args) == 3 &&
    return Expr(:if, ex.args[1], _encvalue(ex.args[2], enc), _encvalue(ex.args[3], enc))
  ex.head == :call && ex.args[1] === :ifelse && length(ex.args) == 4 &&
    return Expr(:call, :ifelse, ex.args[2], _encvalue(ex.args[3], enc), _encvalue(ex.args[4], enc))
  ex.head == :block && return Expr(:block, map(a -> _encvalue(a, enc), ex.args)...)
  ex
end

# `@fsm state begin ... end` finds the register's encoding on the struct; the
# subject is annotated here, before the macro expands, since only the block knows
# the struct
function _fsmsubjects(ex, T)
  ex isa Expr || return ex
  if ex.head == :macrocall && _macroname(ex.args[1]) === Symbol("@fsm") && length(ex.args) ≥ 3
    subject = ex.args[3]
    name = subject isa Symbol ? subject :
           subject isa Expr && subject.head == :. && subject.args[1] === :this ? subject.args[2].value : nothing
    if name !== nothing && haskey(encodings(T), name)
      return Expr(:macrocall, ex.args[1], ex.args[2], Expr(:(::), subject, encodings(T)[name]), ex.args[4:end]...)
    end
  end
  ex.head == :quote && return ex
  Expr(ex.head, map(a -> _fsmsubjects(a, T), ex.args)...)
end

# A pad, a guard, a pipeline, a multicycle wire and an edge are storage with a
# value: read bare, they give the value. The object itself is needed only on the
# left of a write and by `isnew`, `isready`, `bitwidth`, `rose`, `fell`,
# `isrising` and `isfalling`, which ask about the storage rather than what it
# holds. A multicycle read carries its name, for the error a read before its time
# raises.
function _valuereads(ex, T; stmt=true)
  ex isa Expr || return ex
  if stmt && (_iswrite(ex, :this) || _ischainwrite(ex, :this))
    lhs = _writelhs(ex)
    lhs isa Expr && lhs.head == :ref && _isfieldref(lhs.args[1], :this) &&
      hasfield(T, lhs.args[1].args[2].value) && fieldtype(T, lhs.args[1].args[2].value) === Edge &&
      error("an Edge holds a single Bool; write it whole, `$(lhs.args[1].args[2].value) ← x`")
    lhs = lhs.head == :ref ? Expr(:ref, lhs.args[1], _valuereads(lhs.args[2], T; stmt=false)) : lhs
    ex.head == :call && return Expr(:call, ex.args[1], lhs, _valuereads(ex.args[3], T; stmt=false))
    return Expr(:comparison, lhs, map(a -> _valuereads(a, T; stmt=false), ex.args[2:end])...)
  end
  h = ex.head
  h in (:quote, :meta) && return ex
  h == :ref && length(ex.args) == 1 && _isfieldref(ex.args[1], :this) &&
    error("`$(ex.args[1].args[2].value)[]` is not needed: the bare name reads the value")
  if _isfieldref(ex, :this)
    f = ex.args[2].value
    hasfield(T, f) && _ismulticycle(fieldtype(T, f)) && return Expr(:ref, ex, QuoteNode(f))
    return hasfield(T, f) && _isstorage(fieldtype(T, f)) ? Expr(:ref, ex) : ex
  end
  h == :call && ex.args[1] in (:isnew, :isready, :bitwidth, :rose, :fell) &&
    length(ex.args) == 2 && _isfieldref(ex.args[2], :this) && return ex
  h == :call && ex.args[1] in (:isrising, :isfalling) && length(ex.args) == 3 && _isfieldref(ex.args[2], :this) &&
    return Expr(:call, ex.args[1], ex.args[2], _valuereads(ex.args[3], T; stmt=false))
  if h == :. && length(ex.args) == 2 && ex.args[2] isa QuoteNode && _isfieldref(ex.args[1], :this)
    f, p = ex.args[1].args[2].value, ex.args[2].value
    FT = hasfield(T, f) ? fieldtype(T, f) : Nothing
    if FT <: QuartzModule && !isblackbox(FT) && !hasfield(FT, p) && _isclockout(FT, p)
      # resolved here, where the child's blocks are known: the block whose clock
      # the clockout forwards, its shaping, and the gate as a thunk only the live
      # module evaluates (it reads the child's own registers)
      i = findfirst(d -> any(c -> c.name === p, d.clockouts), blocks(FT))
      i === nothing && error("$(nameof(FT)) forwards no clock called $p")
      d = blocks(FT)[i]
      c = d.clockouts[findfirst(c -> c.name === p, d.clockouts)]
      gate = c.gate === nothing ? :(() -> true) :
             :(() -> $(_substthis(c.gate, :(getfield(this, $(QuoteNode(f)))))))
      return :($QuartzHDL._clockoutread(this, Val($(QuoteNode(f))), Val($(QuoteNode(p))),
                                        Val($(QuoteNode(d.clock))), Val($(c.invert)), $gate))
    end
  end
  rec(a) = _valuereads(a, T; stmt=false)
  h == :block && return Expr(:block, map(a -> _valuereads(a, T; stmt), ex.args)...)
  h in (:if, :elseif) && return Expr(h, rec(ex.args[1]), map(a -> _valuereads(a, T; stmt), ex.args[2:end])...)
  h in (:for, :let) && return Expr(h, rec(ex.args[1]), _valuereads(ex.args[2], T; stmt))
  h == :. && return Expr(:., rec(ex.args[1]), ex.args[2])
  h == :kw && return Expr(:kw, ex.args[1], rec(ex.args[2]))
  h == :call && return Expr(:call, ex.args[1], map(rec, ex.args[2:end])...)
  Expr(h, map(rec, ex.args)...)
end
