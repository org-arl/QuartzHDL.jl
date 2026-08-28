# How a Pipeline{K,T} write is cut into K stages. The cut is what the Verilog
# emitter registers, and what stages(T) shows, from the same plan.

# how each wire op is written back as Julia source; a shift is `>>` or `>>>` by
# the signedness of what it shifts, which is what :sra and :shr already record
const INFIX = Dict(:add => "+", :sub => "-", :mul => "*", :and => "&", :or => "|", :xor => "⊻",
                   :eq => "==", :ne => "!=", :lt => "<", :le => "<=", :gt => ">", :ge => ">=",
                   :shl => "<<", :sra => ">>", :mod => "%", :div => "÷")

# one pipelined expression, with every node placed in a stage
struct Cut
  order::Vector{Wire}       # the nodes of the expression, in id order
  stage::Dict{Int,Int}      # node id => the stage that computes it, counting from 0
  lastuse::Dict{Int,Int}    # node id => the last stage that reads it
  depth::Dict{Int,Int}      # node id => cost of the longest path ending in it
  K::Int                    # how many stages the expression is cut into
end

# what one stage takes in, computes, and hands to the next
struct StagePlan
  in::Vector{String}        # values entering the stage, by name
  lines::Vector{@NamedTuple{name::String, expr::String, width::Int, cost::Int}}
  out::Vector{@NamedTuple{name::String, width::Int}}   # values it registers
  cost::Int                 # the longest path inside the stage
end

# the whole plan for one Pipeline field: its stages, and what they cost
struct PipelinePlan
  mod::Symbol               # the module the pipeline belongs to
  name::Symbol              # the field
  K::Int                    # stages asked for; 0 is a straight-through write
  T::Type                   # the value type of the pipeline
  pathcost::Int             # cost of the whole uncut path
  stages::Vector{StagePlan}
  idle::Vector{Int}         # stages that compute nothing
end

"""
    stages(T)
    stages(T, name)

How each `Pipeline` of module `T`, or the one called `name`, is cut into stages:
what each stage takes in, computes, and registers, with the cost of its longest
path, and the registers the whole pipeline costs. It is the plan the Verilog
emitter follows.
"""
function stages(T::Type{<:QuartzModule})
  (; fields, blks) = _traceblocks(T)
  plans = PipelinePlan[]
  for b in blks, f in fields
    b.def.kind == :on && f.kind == :pipeline || continue
    writes = _find_writes(b.tree, f.name)
    isempty(writes) && continue
    length(writes) == 1 || error("pipeline field $(f.name) is written in more than one place")
    root = _aswire(writes[1].value, bitwidth(f.T), issigned(f.T), f.name)
    push!(plans, _plan(nameof(T), f.name, f.K, f.T, root))
  end
  plans
end

function stages(T::Type{<:QuartzModule}, name::Symbol)
  plans = stages(T)
  i = findfirst(p -> p.name == name, plans)
  i === nothing && error("$(nameof(T)) has no pipeline $name that is written")
  plans[i]
end

function Base.show(io::IO, ::MIME"text/plain", p::PipelinePlan)
  W = bitwidth(p.T)
  println(io, "Pipeline ", p.name, " :: Pipeline{", p.K, ",", _tname(p.T), "} of ", p.mod, "     path cost ",
          p.pathcost, ", ", p.K == 0 ? "written straight through" : "cut into $(p.K) stage" * (p.K == 1 ? "" : "s"))
  col = maximum((length(l.name) + length(l.expr) for s in p.stages for l in s.lines); init = 20) + 3
  cuts = 0
  for (i, s) in enumerate(p.stages)
    println(io)
    idle = i in p.idle ? "   (computes nothing)" : ""
    println(io, rpad("stage $i$idle", col + 8), "cost ", lpad(s.cost, 4))
    isempty(s.in) || println(io, "  in    ", join(s.in, ", "))
    for l in s.lines
      println(io, "        ", rpad("$(l.name) = $(l.expr)", col), lpad("$(l.width)-bit", 8), "   [", l.cost, "]")
    end
    if !isempty(s.out)
      println(io, "  out   ", rpad(_reglist(s.out), col + 1), lpad(_flops(s.out), 5), " flops")
      cuts += _flops(s.out)
    end
  end
  fixed = [(name = "$(p.name)_out", width = W), (name = "$(p.name)_valid", width = p.K),
           (name = "$(p.name)_hasout", width = 1), (name = "$(p.name)_isnew", width = 1)]
  p.K == 0 && deleteat!(fixed, 2)
  println(io)
  println(io, "output  ", rpad(_reglist(fixed), col + 1), lpad(_flops(fixed), 5), " flops")
  println(io, "total   ", cuts, " + ", _flops(fixed), " = ", cuts + _flops(fixed), " flops")
  for s in p.idle
    println(io, "warning: ", _idlemessage(p.mod, p.name, p.K, s))
  end
end

Base.show(io::IO, p::PipelinePlan) = print(io, "stages(", p.mod, ", :", p.name, ")")

function Base.show(io::IO, m::MIME"text/plain", ps::Vector{PipelinePlan})
  for (i, p) in enumerate(ps)
    i > 1 && println(io)
    show(io, m, p)
  end
end

### helpers

_cost(w::Wire) = w.op in (:add, :sub, :lt, :le, :gt, :ge, :eq, :ne) ? bitwidth(w.args[1]) :
                 w.op == :mul ? 2 * bitwidth(w) :
                 w.op == :popcount ? _treecost(bitwidth(w.args[1])) :
                 w.op in (:and, :or, :xor, :not, :neg, :mux) ? 1 : 0

# an adder tree over N bits: one level per doubling, each as wide as its sums
_treecost(N) = (L = _clog2(N + 1); L * (L + 1) ÷ 2)

# A node goes into the stage where it starts, by the cost of the longest path to
# its inputs, so the cuts fall between operations rather than after them; the
# result is pinned to the last stage.
function _cut(root::Wire, K::Int)
  nodes = Dict{Int,Wire}()
  _collect_nodes!(nodes, root)
  order = sort(collect(values(nodes)); by = n -> n.id)
  before = Dict{Int,Int}()
  depth = Dict{Int,Int}()
  for w in order
    before[w.id] = isleaf(w) ? 0 : maximum((depth[a.id] for a in w.args if a isa Wire); init = 0)
    depth[w.id] = before[w.id] + _cost(w)
  end
  D = depth[root.id]
  stage = Dict{Int,Int}()
  for w in order
    stage[w.id] = w === root && !isleaf(root) ? K - 1 :
                  D == 0 ? 0 : min(K - 1, before[w.id] * K ÷ D)
  end
  lastuse = Dict{Int,Int}()
  for w in order, a in w.args
    a isa Wire && (lastuse[a.id] = max(get(lastuse, a.id, 0), stage[w.id]))
  end
  isleaf(root) && root.op != :const && (lastuse[root.id] = K - 1)
  Cut(order, stage, lastuse, depth, K)
end

# the longest path inside each stage
function _stagecosts(c::Cut)
  within = Dict{Int,Int}()
  costs = zeros(Int, c.K)
  for w in c.order
    s = c.stage[w.id]
    within[w.id] = _cost(w) + maximum((within[a.id] for a in w.args if a isa Wire && c.stage[a.id] == s); init = 0)
    costs[s + 1] = max(costs[s + 1], within[w.id])
  end
  costs
end

_idle(c::Cut) = findall(==(0), _stagecosts(c))

_idlemessage(mod, name, K, s) =
  "pipeline $name of $mod: stage $s of $K computes nothing; $K stages is more than the computation can use"

_tname(T) = issigned(T) ? "SBits{$(bitwidth(T))}" : "Bits{$(bitwidth(T))}"

function _valuenames(c::Cut, root::Wire, name::Symbol)
  names = Dict{Int,String}()
  n = 0
  for w in sort(c.order; by = w -> (c.stage[w.id], w.id))
    names[w.id] = w.op == :const ? string(w.args[1]) :
                  isleaf(w) ? string(w.name) :
                  w === root ? string(name) : "t$(n += 1)"
  end
  names
end

function _source(w::Wire, names)
  r(a) = a isa Wire ? names[a.id] : string(a)
  op, a = w.op, w.args
  haskey(INFIX, op) && return "$(r(a[1])) $(INFIX[op]) $(r(a[2]))"
  op == :shr && return "$(r(a[1])) $(w.signed ? ">>>" : ">>") $(r(a[2]))"
  op == :neg && return "-$(r(a[1]))"
  op == :not && return (bitwidth(w) == 1 ? "!" : "~") * r(a[1])
  op == :rotl && return "bitrotate($(r(a[1])), $(a[2]))"
  op == :popcount && return "count_ones($(r(a[1])))"
  op == :mux && return "ifelse($(r(a[1])), $(r(a[2])), $(r(a[3])))"
  op == :bit && return "$(r(a[1]))[$(a[2])]"
  op == :slice && return "$(r(a[1]))[$(a[2]):$(a[3])]"
  op == :dynslice && return a[4] == 1 ? "$(r(a[1]))[$(r(a[2])) .+ (0:$(a[3] - 1))]" :
                            "$(r(a[1]))[part($(r(a[2])), Bits{$(a[3])})]"
  op == :repeat && return "repeat($(r(a[1])), $(a[2]))"
  op == :concat && return "$(r(a[1])) ⊞ $(r(a[2]))"
  op == :resize && return "$(w.signed ? "SBits" : "Bits"){$(bitwidth(w))}($(r(a[1])))"
  error("unknown wire op $op")
end

function _plan(mod::Symbol, name::Symbol, K::Int, T::Type, root::Wire)
  c = _cut(root, max(K, 1))
  names = _valuenames(c, root, name)
  costs = _stagecosts(c)
  entered(w) = isleaf(w) ? -1 : c.stage[w.id]
  stages = StagePlan[]
  for s in 0:c.K-1
    entering = [names[w.id] for w in c.order if w.op != :const && entered(w) < s <= get(c.lastuse, w.id, 0)]
    lines = [(name = names[w.id], expr = _source(w, names), width = bitwidth(w), cost = _cost(w))
             for w in c.order if !isleaf(w) && c.stage[w.id] == s]
    leaving = [(name = names[w.id], width = bitwidth(w))
               for w in c.order if w.op != :const && c.stage[w.id] <= s < get(c.lastuse, w.id, 0)]
    s == c.K - 1 && K > 0 && !isleaf(root) && push!(leaving, (name = names[root.id], width = bitwidth(root)))
    push!(stages, StagePlan(entering, lines, leaving, costs[s + 1]))
  end
  PipelinePlan(mod, name, K, T, c.depth[root.id], stages, K > 1 ? _idle(c) : Int[])
end

_flops(regs) = sum(r.width for r in regs; init = 0)
_reglist(regs) = join(("$(r.name) ($(r.width))" for r in regs), ", ")
