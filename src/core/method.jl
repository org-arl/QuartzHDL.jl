# A method is a helper written as if inside the module: bare field names, inputs,
# register writes. It belongs to no one module -- the same method serves every
# module that calls it -- so it is kept as source and inlined where it is called,
# with its arguments bound once to locals of their own. A method that writes is a
# statement; one that only computes a value may be used as one.
struct MethodDef
  params::Vector{Symbol}
  body::Expr
end

struct QuartzMethod
  name::Symbol
  def::MethodDef
end
(m::QuartzMethod)(args...; kwargs...) =
  error("method $(m.name) is only callable inside a block of a @quartz module, and must " *
        "be defined before the block that calls it")

"""
    @method f(a, b) = ...

Declares a helper written as if inside a module: bare field names, inputs and
register writes all work. It belongs to no one module -- the same method serves
every module that calls it -- and is inlined where it is called. One that writes is
a statement; one that only computes a value may be used as one.

```julia
@method arm(t, n) = t ← n
```
"""
macro method(fdef)
  esc(_method(fdef))
end

# one `const` is the whole definition, so a docstring in front of it attaches
function _method(fdef)
  fdef isa Expr && (fdef.head == :function ||
      (fdef.head == :(=) && fdef.args[1] isa Expr && fdef.args[1].head == :call)) ||
    error("@method: expected `function name(args...) ... end` or `name(args...) = ...`")
  sig, body = fdef.args[1], fdef.args[2]
  sig isa Expr && sig.head == :call && sig.args[1] isa Symbol ||
    error("@method: expected a named function with plain arguments, got $sig")
  name = sig.args[1]
  params = sig.args[2:end]
  all(p -> p isa Symbol, params) ||
    error("@method $name: arguments are plain names; the caller supplies the values")
  body = body isa Expr && body.head == :block ? body : Expr(:block, body)
  :(const $name = $QuartzHDL.QuartzMethod($(QuoteNode(name)), $QuartzHDL.MethodDef($params, $(QuoteNode(body)))))
end

function _methoddef(mod, f)
  f isa Symbol && isdefined(mod, f) || return nothing
  m = getfield(mod, f)
  m isa QuartzMethod ? m.def : nothing
end

function _inlinemethods(ex, mod, encs, depth=0)
  depth > 32 && error("@method calls nest too deeply; does a method call itself?")
  ex isa Expr || return ex
  if ex.head == :call && ex.args[1] isa Symbol
    d = _methoddef(mod, ex.args[1])
    d !== nothing && return _inlinemethods(_inline(d, ex.args[1], ex.args[2:end], encs), mod, encs, depth + 1)
  end
  ex.head == :quote && return ex
  Expr(ex.head, map(a -> _inlinemethods(a, mod, encs, depth), ex.args)...)
end

function _inline(d::MethodDef, name, args, encs)
  any(a -> a isa Expr && a.head == :parameters, args) &&
    error("method $name takes positional arguments only")
  length(args) == length(d.params) ||
    error("method $name takes $(length(d.params)) argument(s), got $(length(args))")
  ren = Dict(p => gensym(p) for p in d.params)
  binds = [:(local $(ren[p]) = $(_stateargument(d, p, a, encs))) for (p, a) in zip(d.params, args)]
  Expr(:block, binds..., _subst(d.body, ren).args...)
end

# an argument the method writes straight into an encoded register meets that
# register, so a bare state name resolves there as it would in the block
function _stateargument(d::MethodDef, param, arg, encs)
  arg isa Symbol || return arg
  for st in d.body.args
    st isa Expr && st.head == :call && length(st.args) == 3 && st.args[1] in WRITEOPS &&
      st.args[2] isa Symbol && st.args[3] === param || continue
    enc = get(encs, st.args[2], nothing)
    enc !== nothing && arg in keys(enc) && return getproperty(enc, arg)
  end
  arg
end

function _subst(ex, ren)
  ex isa Symbol && return get(ren, ex, ex)
  ex isa Expr || return ex
  if ex.head == :quote
    ex
  elseif ex.head == :.
    Expr(:., _subst(ex.args[1], ren), ex.args[2])
  elseif ex.head == :kw
    Expr(:kw, ex.args[1], _subst(ex.args[2], ren))
  else
    Expr(ex.head, map(a -> _subst(a, ren), ex.args)...)
  end
end
