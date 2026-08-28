# Statements run across cycles. `@sequence Xfer step begin ... end` turns a body
# of steps into the if/elseif chain `@fsm` produces, over an encoding it makes for
# the steps, so nothing new reaches the simulator, the tracer or the emitter. The
# register that holds the step is a field the struct declares; the sequence only
# checks that it is wide enough. Inside the body a label is bare; anywhere else
# it is a value of the encoding, `Xfer.SEND`, since only the body knows the labels.

"""
    @sequence Name field begin ... end

Runs statements across cycles inside an `@on` block: `@then` divides the body into
steps, one per clock edge, and `field` is the register that holds which step is
next. `@when` guards a step, `@delay n` inserts idle steps, `@repeat n` unrolls a
group, and `@goto LABEL` jumps to a named step.

```julia
@sequence Xfer step begin
  cs ← false
  @then SEND
  shift ← data
end
```
"""
macro sequence(args...)
  error("@sequence runs statements across cycles, and is only valid inside an @on block")
end

"""
    @then
    @then NAME
    @then NAME @when cond

Divides one step of a `@sequence` from the next. `NAME` labels the step so `@goto`
can reach it, and `@when` guards it: the step holds until the condition is true.
"""
macro then(args...)
  error("@then divides the steps of a @sequence, and is only valid inside one")
end

"""
    @when cond

Guards the step of a `@sequence` it heads: the sequence holds there until `cond` is
true. It belongs at the head of the step, right after `@then`.
"""
macro when(args...)
  error("@when guards a step of a @sequence, and is only valid at the head of one")
end

"""
    @delay n

Inserts `n` idle steps into a `@sequence`, so the next step runs `n` cycles later.
`n` is a literal count.
"""
macro delay(args...)
  error("@delay adds idle steps to a @sequence, and is only valid inside one")
end

"""
    @repeat n begin ... end

Unrolls the steps in its body `n` times into a `@sequence`. `n` is a literal count,
and the steps inside cannot be named, since each copy would take the same name.
"""
macro repeat(args...)
  error("@repeat unrolls steps of a @sequence, and is only valid inside one")
end

const SEQMARKERS = (Symbol("@then"), Symbol("@when"), Symbol("@delay"), Symbol("@repeat"), Symbol("@sequence"))

mutable struct Step
  label::Union{Nothing,Symbol}
  guard::Any
  body::Vector{Any}
end

_ismacro(ex, name) = ex isa Expr && ex.head == :macrocall && _macroname(ex.args[1]) === Symbol(name)
_macroargs(ex) = filter(a -> !(a isa LineNumberNode), ex.args[2:end])

# every @sequence in a block body, replaced by its chain; returns the body and the
# (name, field, encoding) of each, for the block to define and register
function _sequences!(body, T, kind, fields, inports)
  found = Tuple{Symbol,Symbol,Encoding}[]
  body = _seqwalk(body, T, kind, fields, inports, found)
  body, found
end

function _seqwalk(ex, T, kind, fields, inports, found)
  ex isa Expr || return ex
  ex.head in (:quote, :meta) && return ex
  if _ismacro(ex, "@sequence")
    kind == :comb && error("@sequence needs a clock, and is not allowed in a @wire block")
    name, field, enc, chain = _sequence(ex, T, fields, inports)
    any(f -> f[2] === field, found) && error("@sequence: $field already holds a sequence in this block")
    push!(found, (name, field, enc))
    return chain
  end
  Expr(ex.head, map(a -> _seqwalk(a, T, kind, fields, inports, found), ex.args)...)
end

# the width the steps of a sequence need, which is what a Step register is emitted at
_stepwidth(enc) = max(1, ndigits(length(enc) - 1; base=2))

function _sequence(ex, T, fields, inports)
  args = _macroargs(ex)
  length(args) == 3 && args[1] isa Symbol && args[2] isa Symbol &&
    args[3] isa Expr && args[3].head == :block ||
    error("@sequence: expected `@sequence Name field begin ... end`, got $ex")
  name, field, block = args
  field in fields || error("@sequence $name: $field is not a field of $(nameof(T))")
  FT = fieldtype(T, field)
  FT isa Type && FT <: Bits || error("@sequence $name: $field must be a Step or a Bits{N} field, it is $FT")
  isstep = get(advancing(T), field, nothing) === :step
  steps = _seqsteps(block.args, false)
  k = length(steps)
  needed = max(1, ndigits(k - 1; base=2))
  k <= (Int128(1) << bitwidth(FT)) ||
    error(isstep ? "@sequence $name: $k steps is more than a Step counts ($(1 << STEPBITS))" :
                   "@sequence $name: $k steps need Bits{$needed}, $field is Bits{$(bitwidth(FT))}")
  W = bitwidth(FT)
  labels = Symbol[]
  for (i, s) in enumerate(steps)
    l = s.label === nothing ? (i == 1 ? :START : Symbol("step_", i - 1)) : s.label
    l in labels && error("@sequence $name: two steps are named $l")
    (l in fields || l in inports) &&
      error("@sequence $name: $l is a step and also " *
            (l in fields ? "a field" : "an input") * " of $(nameof(T)); rename one")
    push!(labels, l)
  end
  enc = _mkencoding(name, :binary, Tuple(labels), ntuple(_ -> nothing, k), W)
  vals = collect(values(enc))
  write(i) = Expr(:call, :←, field, vals[i])
  goto(l) = (i = findfirst(==(l), labels);
             i === nothing && error("@sequence $name: no step is named $l; the steps are $(join(labels, ", "))");
             write(i))
  arms = map(1:k) do i
    s = steps[i]
    body = Any[write(i == k ? 1 : i + 1); map(x -> _seqgotos(x, goto), s.body)]
    branch = s.guard === nothing ? Expr(:block, body...) :
             Expr(:block, Expr(:if, s.guard, Expr(:block, body...)))
    (vals[i], branch)
  end
  name, field, enc, _chain(field, arms, Expr(:block, write(1)))
end

# the if/elseif chain over one register, the shape the emitter writes as a case
function _chain(reg, arms, default)
  out = default
  for (v, body) in reverse(arms)
    out = Expr(:if, :($reg == $v), body, out)
  end
  out
end

function _seqgotos(ex, goto)
  ex isa Expr || return ex
  if _ismacro(ex, "@goto")
    a = _macroargs(ex)
    length(a) == 1 && a[1] isa Symbol || error("@sequence: expected `@goto label`, got $ex")
    return goto(a[1])
  end
  Expr(ex.head, map(a -> _seqgotos(a, goto), ex.args)...)
end

_hasmarker(ex) = ex isa Expr && (ex.head == :macrocall && _macroname(ex.args[1]) in SEQMARKERS ||
                                  any(_hasmarker, ex.args))

# The steps of a body. A step starts open at its head, where `@when` may guard it,
# and closes at the next divider. `@delay` and `@repeat` close the step before them
# and leave none open, so what follows opens a fresh one, named by `@then` or not.
function _seqsteps(items, inrepeat)
  steps = Step[]
  cur = Step(nothing, nothing, Any[])
  athead() = cur !== nothing && all(x -> x isa LineNumberNode, cur.body)
  close!() = (cur === nothing || push!(steps, cur); cur = nothing)
  open!(label) = (close!(); cur = Step(label, nothing, Any[]))
  for item in items
    if item isa LineNumberNode
      cur === nothing || push!(cur.body, item)
    elseif _ismacro(item, "@then")
      label, guard = _thenargs(item)
      label !== nothing && inrepeat && error("@sequence: a step inside @repeat cannot be named; it is unrolled")
      open!(label)
      cur.guard = guard
    elseif _ismacro(item, "@when")
      a = _macroargs(item)
      length(a) == 1 || error("@sequence: expected `@when cond`, got $item")
      cur === nothing && open!(nothing)
      athead() && cur.guard === nothing ||
        error("@sequence: @when guards a step and belongs at its head, right after @then")
      cur.guard = a[1]
    elseif _ismacro(item, "@delay")
      a = _macroargs(item)
      length(a) == 1 && a[1] isa Integer && a[1] >= 1 ||
        error("@sequence: expected `@delay n` with n a literal count, got $item")
      close!()
      for _ in 1:a[1]
        push!(steps, Step(nothing, nothing, Any[]))
      end
    elseif _ismacro(item, "@repeat")
      a = _macroargs(item)
      length(a) == 2 && a[1] isa Integer && a[1] >= 1 && a[2] isa Expr && a[2].head == :block ||
        error("@sequence: expected `@repeat n begin ... end` with n a literal count, got $item")
      close!()
      inner = _seqsteps(a[2].args, true)
      for _ in 1:a[1], s in inner
        push!(steps, Step(nothing, s.guard, copy(s.body)))
      end
    elseif _ismacro(item, "@sequence")
      error("@sequence: a sequence cannot hold another")
    else
      _hasmarker(item) && error("@sequence: @then, @when, @delay and @repeat belong at the top level of the sequence, not inside $item")
      cur === nothing && open!(nothing)
      push!(cur.body, item)
    end
  end
  close!()
  steps
end

# `@then`, `@then NAME`, `@then @when cond` and `@then NAME @when cond`; the last
# two parse as a nested call, since a macro takes the rest of its line
function _thenargs(item)
  a = _macroargs(item)
  label = nothing
  guard = nothing
  if !isempty(a) && a[1] isa Symbol
    label = a[1]
    label === :START && error("@sequence: START is the first step, and cannot name another")
    a = a[2:end]
  end
  if length(a) == 1 && _ismacro(a[1], "@when")
    w = _macroargs(a[1])
    length(w) == 1 || error("@sequence: expected `@when cond`, got $(a[1])")
    guard = w[1]
    a = a[2:end]
  end
  isempty(a) || error("@sequence: expected `@then [NAME] [@when cond]`, got $item")
  label, guard
end
