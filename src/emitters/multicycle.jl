# A multicycle wire's path, read off the traced logic: the registers it starts
# from, the registers it ends at, the clock they are on, and the condition under
# which a source is being written. The constraint file, the Verilog settle counter
# and the simulator's settle count all come from this one reading, so the promise
# the timing tool is given, the signal the design reads and the check the
# simulator makes cannot disagree.

# the path of one multicycle wire, as read off the traced logic
struct MulticycleInfo
  name::Symbol
  K::Int                          # cycles the path is allowed to settle over
  sources::Vector{Symbol}         # the registers it starts from, that are written
  sinks::Vector{Symbol}           # the registers it ends at
  clock::Symbol                   # the clock the sources are written on
  edge::Symbol                    # and its edge
  restart::Union{Bool,Wire{1}}    # when a source is written, so the count starts over
end

# a block that is registered or replaced invalidates this, in core/blocks.jl
const MCINFO = IdDict{Type,Dict{Symbol,MulticycleInfo}}()

function _mcinfo(T::Type, f::Symbol)
  d = get!(MCINFO, T) do
    (; fields, blks) = _traceblocks(T)
    _multicycleinfo(T, fields, blks)
  end
  d[f]
end

function _multicycleinfo(T::Type, fields, blks)
  out = Dict{Symbol,MulticycleInfo}()
  for f in fields
    f.kind == :multicycle || continue
    out[f.name] = _onemulticycle(T, f, fields, blks)
  end
  out
end

function _onemulticycle(T::Type, f, fields, blks)
  name = f.name
  who = "multicycle wire $name of $(nameof(T))"
  i = findfirst(b -> b.def.kind == :comb && name in b.def.owned, blks)
  i === nothing && error("$who is driven by no @wire block")
  v = _combvalue(blks[i].tree, name, f.width, f.signed, false)
  v === nothing && error("@wire block writes nothing to $name")
  nodes = Dict{Int,Wire}()
  _collect_nodes!(nodes, v)
  reads = Symbol[]
  for w in sort(collect(values(nodes)); by = n -> n.id)
    isleaf(w) && w.op != :const || continue
    src = _finfo(fields, w.name)
    w.op == :reg && src !== nothing && src.kind == :reg ||
      error("$who reads $(w.name), which is not a register of the module; a multicycle " *
            "path starts at a register, so copy it into one first")
    w.name in reads || push!(reads, w.name)
  end
  isempty(reads) && error("$who reads no register, so its logic has nothing to settle from")
  writers = [b for b in blks if b.def.kind == :on && any(s in b.def.owned for s in reads)]
  isempty(writers) &&
    error("nothing writes the sources of $who ($(join(reads, ", "))), so it would never settle")
  clocks = unique((b.def.clock, b.def.edge) for b in writers)
  length(clocks) == 1 ||
    error("the sources of $who are written on $(join(("$(c[2])($(c[1]))" for c in clocks), " and ")); " *
          "a multicycle path stays in one clock domain")
  written = [s for s in reads if any(s in b.def.owned for b in writers)]
  sinks = _sinksof(T, name, blks, who)
  for s in sinks
    dst = _finfo(fields, s)
    dst !== nothing && dst.kind == :reg ||
      error("$who feeds $s, which is not a plain register; a multicycle path ends at a register")
  end
  MulticycleInfo(name, f.K, written, sinks, clocks[1][1], clocks[1][2],
                 _restartcond(writers, written))
end

# the settle count starts over whenever a source is written: any of the writing
# blocks, under its enable, or in reset. Two writes under the same condition are
# one term, so the condition is compared by structure and counted once.
function _restartcond(writers, written)
  restart = false
  for b in writers
    conds = false
    seen = Set{Any}()
    for s in written
      s in b.def.owned || continue
      c = _writecond(b.tree, s)
      key = c isa Wire ? _wirekey(c) : c
      key in seen && continue
      push!(seen, key)
      conds = _wor(conds, c)
    end
    r = _wand(b.enablew === nothing ? true : b.enablew, conds)
    b.resetw === nothing || (r = _wor(b.resetw, r))
    restart = _wor(restart, r)
  end
  restart
end

# the registers the wire ends at, over every block that reads it
function _sinksof(T::Type, name::Symbol, blks, who)
  sinks = Symbol[]
  for b in blks
    if b.def.kind == :comb
      b.def.owned == [name] && continue
      tree = Dict{Int,Wire}()
      _collect_tree!(tree, b.tree)
      any(isleaf(w) && w.op == :reg && w.name == name for w in values(tree)) &&
        error("$who is read by a @wire block, so its path would leave the module or feed " *
              "another wire; a multicycle path ends at a register of $(nameof(T))")
      continue
    end
    wholeblock = _readsnet(b.resetw, name) || _readsnet(b.enablew, name)
    for (fld, v) in b.overrides
      (wholeblock || _readsnet(v, name)) && push!(sinks, fld)
    end
    _sinks!(sinks, b.tree, name, wholeblock, T)
  end
  unique(sinks)
end

# the condition under which a block writes a field: the paths through its ifs that
# reach a write, as one boolean
function _writecond(tree::Vector, f::Symbol)
  c = false
  for n in tree
    if n isa WriteNode && n.field == f
      c = true
    elseif n isa IfNode
      c = _wor(c, _wor(_wand(n.cond, _writecond(n.then, f)),
                       _wand(_wnot(n.cond), _writecond(n.els, f))))
    end
  end
  c
end

_wand(a::Bool, b::Bool) = a && b
_wand(a::Bool, b) = a ? b : false
_wand(a, b::Bool) = b ? a : false
_wand(a, b) = a & b
_wor(a::Bool, b::Bool) = a || b
_wor(a::Bool, b) = a ? true : b
_wor(a, b::Bool) = b ? true : a
_wor(a, b) = a | b
_wnot(a::Bool) = !a
_wnot(a::Wire{1}) = !a

# every register written from the value, or under a condition that reads it
function _sinks!(acc, tree::Vector, name::Symbol, under::Bool, T::Type)
  for n in tree
    if n isa WriteNode
      (under || _readsnet(n.value, name)) && push!(acc, n.field)
    elseif n isa IfNode
      u = under || _readsnet(n.cond, name)
      _sinks!(acc, n.then, name, u, T)
      _sinks!(acc, n.els, name, u, T)
    elseif n isa ConnNode
      (under || _readsnet(n.value, name)) &&
        error("multicycle wire $name of $(nameof(T)) reaches $(n.field).$(n.port), an instance " *
              "input; a multicycle path ends at a register of $(nameof(T))")
    end
  end
end

function _readsnet(v::Wire, name::Symbol)
  nodes = Dict{Int,Wire}()
  _collect_nodes!(nodes, v)
  any(isleaf(w) && w.op == :reg && w.name == name for w in values(nodes))
end
_readsnet(v::PadPair, name::Symbol) = _readsnet(v.val, name) || _readsnet(v.oe, name)
_readsnet(v::MaybeWire, name::Symbol) = _readsnet(v.value, name) || _readsnet(v.hasout, name)
_readsnet(::Any, ::Symbol) = false

# the timing exceptions of a module: the ones declared by hand, and one per source
# and sink of each multicycle wire
function _allmulticycles(M::Type)
  out = copy(multicycles(M))
  any(FT isa Type && FT <: Multicycle for FT in fieldtypes(M)) || return out
  (; fields, blks) = _traceblocks(M)
  infos = _multicycleinfo(M, fields, blks)
  for name in sort(collect(keys(infos))), s in infos[name].sources, t in infos[name].sinks
    _mcnamecheck(M, s, t)
    push!(out, MultiCycle(s, t, infos[name].K))
  end
  out
end
