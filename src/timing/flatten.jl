# The design as one graph. Tracing reads a module at a time, and the logic of one
# module stops at its ports: an input is a leaf, and so is an instance's output.
# Here the modules of a design are joined where they are wired, so the logic in
# front of a register can be followed back to the registers, pins and black boxes
# it starts from, through every module on the way.

const ARITHMETIC = (:add, :sub, :mul, :neg, :eq, :ne, :lt, :le, :gt, :ge, :popcount, :mod, :div)

# the traced logic of one module type, indexed for the walk
struct ModuleTrace
  fields::Vector{Any}
  blks::Vector{TracedBlock}
  conns::Vector{ConnNode}
  comb::Dict{Symbol,Any}                        # field a @wire block drives => its value
  childouts::Dict{Symbol,Tuple{Symbol,Symbol}}  # leaf name => (instance field, its port)
  inputs::Set{Symbol}                           # the data inputs of the module
end

# one instance of a module in the design
struct FlatInstance
  path::Vector{String}      # the fields that lead to it from the top
  T::Type
  parent::Int               # the instance above, 0 for the top
  field::Symbol             # the field of the parent that holds it
  trace::ModuleTrace
end

# one write a register may take
struct Drive
  value::Any                                      # a Wire, a PadPair or a constant
  range::Union{Nothing,UnitRange{Int},DynRange}   # the bits it lands on
  guards::Vector{Wire{1}}                         # the conditions it sits under, outermost first
  guardlines::Vector{SourceLine}                  # where each of them is written
  exempt::Vector{Union{Nothing,String}}           # why the budget leaves each alone, if it does
  reset::Bool                                     # the value a reset gives, under the reset alone
  at::SourceLine                                  # where the design writes it
end

# where a path ends: a register, or a data input of a black box
struct Sink
  inst::Int
  name::Symbol
  kind::Symbol              # :reg, :pad, :metaguard, :edge, :pipeline or :blackbox
  width::Int
  clock::Symbol             # the top-level net that clocks it; none for a black box
  edge::Symbol
  drives::Vector{Drive}
  at::SourceLine            # the block that writes it
end

# a timing exception the design carries, by the full names of its two registers
struct FlatException
  from::String
  to::String
  cycles::Int
end

struct FlatDesign
  top::Type
  instances::Vector{FlatInstance}
  children::Dict{Tuple{Int,Symbol},Int}   # (instance, field) => the instance in that field
  sinks::Vector{Sink}
  exceptions::Vector{FlatException}
end

# what a cone reads from one place it starts at
mutable struct Reach
  kind::Symbol                  # :reg, :input, :pin or :blackbox
  width::Int
  bits::UInt128                 # the bits of it that are read
  ops::Set{Tuple{Int,Int}}      # the arithmetic between it and the root, as keys of Cone.arith
  chain::Vector{Tuple{Int,Int}} # the widest run of it in series, root first
  crossings::Int                # module boundaries on the way, at most
  multicycle::Bool              # every way to it runs through a multicycle wire
end

# the logic in front of one or more roots, followed back to where it starts
struct Cone
  reach::Dict{Tuple{String,Symbol},Reach}                 # (start, :data or :condition)
  arith::Dict{Tuple{Int,Int},Tuple{Symbol,Int}}           # (instance, wire id) => (op, width)
  seen::Dict{Tuple{Int,Int,Symbol,Bool},Tuple{UInt128,Set{Tuple{Int,Int}}}}
  lut::Int      # an operation of no more variable bits fits one LUT, and is not arithmetic
end

Cone(lut::Int=0) = Cone(Dict{Tuple{String,Symbol},Reach}(), Dict{Tuple{Int,Int},Tuple{Symbol,Int}}(),
                        Dict{Tuple{Int,Int,Symbol,Bool},Tuple{UInt128,Set{Tuple{Int,Int}}}}(), lut)

function _flatten(T::Type{<:QuartzModule})
  traces = IdDict{Type,ModuleTrace}()
  instances = FlatInstance[]
  children = Dict{Tuple{Int,Symbol},Int}()
  _addinstance!(instances, children, traces, T, String[], 0, Symbol(""))
  sinks = Sink[]
  exceptions = FlatException[]
  for (i, inst) in enumerate(instances)
    _addsinks!(sinks, T, i, inst)
    _addexceptions!(exceptions, inst)
  end
  FlatDesign(T, instances, children, sinks, exceptions)
end

_fullname(inst::FlatInstance, name) = join(vcat(inst.path, string(name)), ".")

function _reach!(c::Cone, d::FlatDesign, inst::Int, root::Wire, role::Symbol)
  _walk!(c, d, inst, root, _mask(bitwidth(root)), role, Tuple{Int,Int}[], 0, false)
  c
end

function _reach!(c::Cone, d::FlatDesign, inst::Int, root::PadPair, role::Symbol)
  _reach!(c, d, inst, root.val, role)
  _reach!(c, d, inst, root.oe, role)
end

_reach!(c::Cone, ::FlatDesign, ::Int, ::Any, ::Symbol) = c

# everything in front of a sink: what its writes carry as data, and what decides
# which of them lands
function _sinkcone(d::FlatDesign, s::Sink, lut::Int=0)
  c = Cone(lut)
  for drive in s.drives
    _reach!(c, d, s.inst, drive.value, :data)
    drive.range isa DynRange && _reach!(c, d, s.inst, drive.range.base, :condition)
    for g in drive.guards
      _reach!(c, d, s.inst, g, :condition)
    end
  end
  c
end

### helpers

function _moduletrace(T::Type)
  (; fields, blks, conns) = _traceblocks(T)
  comb = Dict{Symbol,Any}()
  for b in blks
    b.def.kind == :comb || continue
    for fn in b.def.owned
      f = _finfo(fields, fn)
      f !== nothing && f.kind in (:reg, :multicycle) || continue
      comb[fn] = _combvalue(b.tree, fn, f.width, f.signed, false)
    end
  end
  childouts = Dict{Symbol,Tuple{Symbol,Symbol}}()
  for f in fields
    f.kind in (:submodule, :blackbox) || continue
    for p in (f.kind == :blackbox ? blackbox(f.T).ports : _ports(f.T))
      p.dir in (:output, :clockout) && (childouts[Symbol(f.name, "_", p.name)] = (f.name, p.name))
    end
  end
  ModuleTrace(fields, blks, conns, comb, childouts, Set{Symbol}(fieldnames(fieldtype(T, INPUTS))))
end

function _addinstance!(instances, children, traces, T::Type, path, parent::Int, field::Symbol)
  trace = get!(() -> _moduletrace(T), traces, T)
  push!(instances, FlatInstance(path, T, parent, field, trace))
  me = length(instances)
  parent == 0 || (children[(parent, field)] = me)
  for f in trace.fields
    f.kind == :submodule && _addinstance!(instances, children, traces, f.T, vcat(path, string(f.name)), me, f.name)
  end
end

function _addsinks!(sinks, top::Type, i::Int, inst::FlatInstance)
  trace = inst.trace
  for b in trace.blks
    if b.def.kind == :on
      clock = _sinkclock(top, inst, b.def.clock)
      for fn in b.def.owned
        f = _finfo(trace.fields, fn)
        (f === nothing || f.kind in (:submodule, :blackbox)) && continue
        drives = _blockdrives(inst.T, b, f)
        isempty(drives) ||
          push!(sinks, Sink(i, fn, f.kind, _sinkwidth(f), clock, b.def.edge, drives, _firstline(b.def.body)))
      end
    end
    for c in _findconns(b.tree)
      f = _finfo(trace.fields, c.field)
      f.kind == :blackbox || continue
      p = _finfoport(blackbox(f.T).ports, c.port)
      push!(sinks, Sink(i, Symbol(c.field, ".", c.port), :blackbox, p.width, Symbol(""), Symbol(""),
                        [Drive(c.value, nothing, Wire{1}[], SourceLine[], Union{Nothing,String}[], false, c.at)], _firstline(b.def.body)))
    end
  end
end

# "adc.jl:204", as a report names a line of the design
_sourcestr(at::LineNumberNode) = string(basename(string(at.file)), ":", at.line)
_sourcestr(::Nothing) = ""

# a clock a black box of the module makes is a net of that module, and has no name above it
_sinkclock(top::Type, inst::FlatInstance, clock::Symbol) =
  clock in _internalclocks(inst.T) ? Symbol(_fullname(inst, clock)) : _topclock(top, inst.path, clock)

_sinkwidth(f) = f.kind == :reg || f.kind == :pad ? f.width :
                f.kind == :pipeline ? bitwidth(f.T) : f.kind == :metaguard ? f.K : 1

# every write the block makes to the field, each under the enable of the block and
# the ifs around it, and the value a reset gives the field. A reset reaches a
# register by a pin of its own, so it is a condition of its own and not one more
# term of every other.
function _blockdrives(T::Type, b, f)
  drives = Drive[]
  at = _firstline(b.def.body)
  if b.resetw isa Wire && (f.name in resets(T) || haskey(b.overrides, f.name))
    push!(drives, Drive(get(b.overrides, f.name, 0), nothing, Wire{1}[b.resetw], SourceLine[at], [nothing], true, at))
  end
  always = Wire{1}[]
  b.enablew isa Wire && push!(always, b.enablew)
  excuse = _excuse(b.tree, nothing)
  _treedrives!(drives, b.tree, f.name, always, SourceLine[at for _ in always],
               Union{Nothing,String}[excuse for _ in always], excuse, at)
  drives
end

# a write the block makes by itself, the step of a Timeout or a Pulse, stands on no
# line of the design and takes the block's
# the reason a branch gives for leaving its condition alone, or the one it inherits.
# A tag speaks for its `if` and for what is nested in its own arm: the arms of an
# `elseif` chain nest in one another's else, and one arm's tag is not the next's.
function _excuse(tree::Vector, inherited)
  i = findfirst(n -> n isa ExemptNode, tree)
  i === nothing ? inherited : tree[i].reason
end

function _treedrives!(drives, tree::Vector, name::Symbol, guards, lines, excuses, inherited, blockline)
  for n in tree
    if n isa WriteNode && n.field == name
      push!(drives, Drive(n.value, n.range, copy(guards), copy(lines), copy(excuses), false, something(n.at, Some(blockline))))
    elseif n isa IfNode
      inner = vcat(guards, n.cond)
      innerlines = vcat(lines, something(n.at, Some(blockline)))
      innerexcuses = vcat(excuses, _excuse(n.then, _excuse(n.els, inherited)))
      _treedrives!(drives, n.then, name, inner, innerlines, innerexcuses, _excuse(n.then, inherited), blockline)
      _treedrives!(drives, n.els, name, inner, innerlines, innerexcuses, _excuse(n.els, inherited), blockline)
    end
  end
end

function _addexceptions!(exceptions, inst::FlatInstance)
  trace = inst.trace
  for m in multicycles(inst.T)
    push!(exceptions, FlatException(_fullname(inst, m.from), _fullname(inst, m.to), m.cycles))
  end
  any(f.kind == :multicycle for f in trace.fields) || return
  for (_, info) in _multicycleinfo(inst.T, trace.fields, trace.blks), s in info.sources, t in info.sinks
    push!(exceptions, FlatException(_fullname(inst, s), _fullname(inst, t), info.K))
  end
end

# the bits an operation reads that are not constants, which is what decides
# whether it fits one LUT
_varbits(w::Wire) = sum((_livebits(a) for a in w.args if a isa Wire); init=0)

# the bits of a value that can differ from zero: none of a constant, and of a
# value masked by a constant only those the mask lets through
function _livebits(w::Wire)
  w.op == :const && return 0
  if w.op == :and
    k = findfirst(a -> a isa Wire && a.op == :const, w.args)
    k === nothing || return min(count_ones(reinterpret(UInt128, w.args[k].args[1]) & _mask(bitwidth(w))),
                                _livebits(w.args[3 - k]))
  end
  bitwidth(w)
end

_lowbits(d::UInt128) = d == 0 ? d : _mask(128 - leading_zeros(d))
_argmask(a, d::UInt128) = d & _mask(bitwidth(a))
_signbit(a::Wire) = UInt128(1) << (bitwidth(a) - 1)

# `demand` is the bits of `w` that matter to the root; what is asked of each
# argument follows from the operation, so a compare of four bits of a word reads
# four bits and not the word
function _walk!(c::Cone, d::FlatDesign, inst::Int, w::Wire, demand::UInt128, role::Symbol, above, crossings::Int, mc::Bool)
  demand == 0 && return
  w.op == :const && return
  key = (inst, w.id, role, mc)
  bits, ops = get!(() -> (UInt128(0), Set{Tuple{Int,Int}}()), c.seen, key)
  demand & ~bits == 0 && issubset(above, ops) && return
  c.seen[key] = (bits | demand, union!(ops, above))
  isleaf(w) && return _leaf!(c, d, inst, w, demand, role, above, crossings, mc)
  if w.op in ARITHMETIC && _varbits(w) > c.lut
    c.arith[(inst, w.id)] = (w.op, maximum(bitwidth(a) for a in w.args if a isa Wire))
    above = vcat(above, (inst, w.id))
  end
  for (a, ad, arole) in _argdemands(w, demand, role)
    _walk!(c, d, inst, a, ad, arole, above, crossings, mc)
  end
end

function _argdemands(w::Wire, demand::UInt128, role::Symbol)
  op, a = w.op, w.args
  out = Tuple{Wire,UInt128,Symbol}[]
  ask(x, xd, r=role) = x isa Wire && push!(out, (x, xd & _mask(bitwidth(x)), r))
  if op in (:and, :or) && any(x -> x isa Wire && x.op == :const, a)
    k = a[1] isa Wire && a[1].op == :const ? 1 : 2
    fixed = reinterpret(UInt128, a[k].args[1])
    ask(a[3 - k], demand & (op == :and ? fixed : ~fixed))
  elseif op in (:and, :or, :xor, :not)
    foreach(x -> ask(x, demand), a)
  elseif op in (:add, :sub, :mul, :neg)
    foreach(x -> ask(x, _lowbits(demand)), a)
  elseif op == :mux
    ask(a[1], UInt128(1), :condition)
    ask(a[2], demand)
    ask(a[3], demand)
  elseif op == :bit
    ask(a[1], UInt128(1) << a[2])
  elseif op == :slice
    ask(a[1], demand << a[2])
  elseif op == :concat
    low = bitwidth(a[2])
    ask(a[2], demand)
    ask(a[1], demand >> low)
  elseif op == :resize
    widened = w.signed && demand & ~_mask(bitwidth(a[1])) != 0
    ask(a[1], widened ? demand | _signbit(a[1]) : demand)
  elseif op == :repeat
    ask(a[1], _mask(bitwidth(a[1])))
  elseif op in (:shl, :shr, :sra) && a[2] isa Int
    n = a[2]
    ask(a[1], op == :shl ? demand >> n : op == :shr ? demand << n : (demand << n) | _signbit(a[1]))
  elseif op == :rotl
    N, n = bitwidth(w), a[2]
    ask(a[1], (demand >> n) | (demand << (N - n)))
  elseif op == :dynslice
    ask(a[1], _mask(bitwidth(a[1])))
    ask(a[2], _mask(bitwidth(a[2])), :condition)
  else
    foreach(x -> x isa Wire && ask(x, _mask(bitwidth(x))), a)
  end
  out
end

function _leaf!(c::Cone, d::FlatDesign, i::Int, w::Wire, demand, role, above, crossings, mc)
  inst = d.instances[i]
  trace = inst.trace
  name = w.name
  if w.op == :input
    name in trace.inputs || return _start!(c, string(name), :pin, w, demand, role, above, crossings, mc)
    inst.parent == 0 && return _start!(c, string(name), :input, w, demand, role, above, crossings, mc)
    k = findfirst(x -> x.field === inst.field && x.port === name, d.instances[inst.parent].trace.conns)
    k === nothing && return
    v = d.instances[inst.parent].trace.conns[k].value
    v isa Wire && _walk!(c, d, inst.parent, v, demand, role, above, crossings + 1, mc)
  elseif w.op == :reg && haskey(trace.comb, name)
    v = trace.comb[name]
    v isa Wire && _walk!(c, d, i, v, demand, role, above, crossings, mc || _finfo(trace.fields, name).kind == :multicycle)
  elseif w.op == :reg && haskey(trace.childouts, name)
    field, port = trace.childouts[name]
    child = get(d.children, (i, field), 0)
    child == 0 && return _start!(c, _fullname(inst, "$field.$port"), :blackbox, w, demand, role, above, crossings, mc)
    ctrace = d.instances[child].trace
    if haskey(ctrace.comb, port)
      v = ctrace.comb[port]
      v isa Wire && _walk!(c, d, child, v, demand, role, above, crossings + 1, mc)
    else
      kind = _finfo(ctrace.fields, port) === nothing ? :pin : :reg
      _start!(c, _fullname(d.instances[child], port), kind, w, demand, role, above, crossings + 1, mc)
    end
  else
    _start!(c, _fullname(inst, name), :reg, w, demand, role, above, crossings, mc)
  end
end

_chainwidth(c::Cone, chain) = sum((c.arith[o][2] for o in chain); init=0)

function _start!(c::Cone, name::String, kind::Symbol, w::Wire, demand, role, above, crossings, mc)
  r = get!(() -> Reach(kind, bitwidth(w), UInt128(0), Set{Tuple{Int,Int}}(), Tuple{Int,Int}[], 0, true), c.reach, (name, role))
  r.bits |= demand
  union!(r.ops, above)
  _chainwidth(c, above) > _chainwidth(c, r.chain) && (r.chain = copy(above))
  r.crossings = max(r.crossings, crossings)
  r.multicycle &= mc
  nothing
end
