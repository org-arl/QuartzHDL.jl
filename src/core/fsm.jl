# Dispatch on an encoded register. `@fsm state begin ... end` expands to the
# if/elseif chain a person would otherwise write by hand, so nothing new reaches
# the simulator, the tracer or the emitter. What it adds is the checking that the
# hand-written chain cannot have: every state accounted for, no state named twice,
# and no name that the encoding does not define. The register's encoding is the
# one its declaration gives it; the block annotates the subject before this
# expands, since only the block knows the struct.

"""
    @fsm reg begin ... end

Dispatches on an encoded register, expanding to the if/elseif chain a person would
otherwise write by hand. What it adds is the checking that chain cannot have: every
state accounted for, no state named twice, and no name the encoding does not
define. Branches are labelled `@state NAME`, and `@otherwise` takes the rest.

```julia
@fsm state begin
  @state IDLE
    go && (state ← RUN)
  @state RUN
    state ← IDLE
end
```
"""
macro fsm(subject, block)
  esc(_fsm(subject, block, __module__))
end

"""
    @state NAME

Labels a branch of an `@fsm` block: the statements after it run while the register
holds `NAME`.
"""
macro state(args...)
  error("@state labels a branch of an @fsm block and is only valid inside one")
end

"""
    @otherwise

Labels the default branch of an `@fsm` block, covering every state that has no
`@state` branch of its own.
"""
macro otherwise(args...)
  error("@otherwise labels the default branch of an @fsm block and is only valid inside one")
end

function _fsm(subject, block, mod)
  subject isa Expr && subject.head == :(::) && length(subject.args) == 2 ||
    error("@fsm: $subject has no encoding; declare it in the struct as `$subject::Enc`")
  reg, encsym = subject.args
  block isa Expr && block.head == :block || error("@fsm: expected a begin ... end block")
  enc = _resolveencoding(encsym, mod)
  labels, bodies = _fsmbranches(block)
  _checkstates(encsym, enc, labels)
  _fsmchain(reg, enc, labels, bodies)
end

# the branches of the body, as labels (a state name, or nothing for @otherwise) and
# the statements under each
function _fsmbranches(block)
  labels = Any[]
  bodies = Vector{Any}[]
  for item in block.args
    if item isa LineNumberNode
      isempty(bodies) || push!(bodies[end], item)
      continue
    end
    m = item isa Expr && item.head == :macrocall ? _macroname(item.args[1]) : nothing
    if m == Symbol("@state")
      rest = filter(a -> !(a isa LineNumberNode), item.args[2:end])
      length(rest) == 1 && rest[1] isa Symbol ||
        error("@fsm: expected `@state <name>`, got $item")
      push!(labels, rest[1])
      push!(bodies, Any[])
    elseif m == Symbol("@otherwise")
      push!(labels, nothing)
      push!(bodies, Any[])
    else
      isempty(bodies) && error("@fsm: a statement appears before the first @state")
      push!(bodies[end], item)
    end
  end
  isempty(labels) && error("@fsm: no @state branches")
  (labels, bodies)
end

function _fsmchain(reg, enc, labels, bodies)
  out = nothing
  for i in length(labels):-1:1
    body = Expr(:block, bodies[i]...)
    out = labels[i] === nothing ? body :
          Expr(:if, :($reg == $(getproperty(enc, labels[i]))), body,
               out === nothing ? Expr(:block) : out)
  end
  out
end

function _resolveencoding(name, mod)
  name isa Encoding && return name
  isdefined(mod, name) ||
    error("@fsm: the encoding $name must be defined before the block that uses it")
  enc = getfield(mod, name)
  enc isa Encoding || error("@fsm: $name is not an @encoding")
  enc
end

function _checkstates(name, enc, labels)
  named = [l for l in labels if l !== nothing]
  allunique(named) || error("@fsm: a state has two branches")
  for l in named
    l in keys(enc) || error("@fsm: $(encname(enc)) has no state $l")
  end
  if !any(l -> l === nothing, labels)
    missed = setdiff(collect(keys(enc)), named)
    isempty(missed) ||
      error("@fsm: $(join(missed, ", ")) " * (length(missed) == 1 ? "has" : "have") *
            " no branch; add one, or `@otherwise` for the rest")
  end
end
