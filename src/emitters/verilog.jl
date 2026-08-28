# The Verilog a design is emitted as. A module is traced block by block, and the
# result written in one order: the port header, the declarations of every field,
# the continuous assigns of the @wire blocks, one always block per @on block, the
# settle counters of the multicycle wires, and the submodule instances. Pads enter
# as a value and an output enable that meet in a tristate assign, pipelines as the
# stage registers of their cut (stages.jl), and encodings as localparams a state
# name is written by.

# `$display` and `$error` from the design's log statements are emitted only when
# asked for, so what goes to synthesis carries none of them
const VDEBUG = :quartz_verilog_debug
_vdebug() = get(task_local_storage(), VDEBUG, false)::Bool

# which registers get initializers; see Verilog in formats.jl for what the two mean
const VINITS = :quartz_verilog_inits
_vinits() = get(task_local_storage(), VINITS, :static)::Symbol

function withveriloginits(f, mode::Symbol)
  old = get(task_local_storage(), VINITS, nothing)
  task_local_storage(VINITS, mode)
  try
    f()
  finally
    old === nothing ? delete!(task_local_storage(), VINITS) : task_local_storage(VINITS, old)
  end
end

function withverilogdebug(f, on::Bool)
  old = get(task_local_storage(), VDEBUG, nothing)
  task_local_storage(VDEBUG, on)
  try
    f()
  finally
    old === nothing ? delete!(task_local_storage(), VDEBUG) : task_local_storage(VDEBUG, old)
  end
end

function Base.write(io::IO, T::Type{<:QuartzModule}, f::Verilog)
  buf = IOBuffer()
  withverilogdebug(f.debug) do
    withportsuffix(f.suffix) do
      withveriloginits(f.inits) do
        _emitgraph(buf, T, something(f.name, nameof(T)), Dict{Type,Symbol}())
      end
    end
  end
  write(io, take!(buf))
end

### helpers

function _lit(v::Integer, W, signed=false)
  h = "$(W)'h$(string(reinterpret(UInt128, Int128(v)) & _mask(W); base=16))"
  signed ? "\$signed($h)" : h
end
_range(W) = W == 1 ? "" : "[$(W-1):0] "
_decl(kind, name, W; signed=false) = "$kind $(signed ? "signed " : "")$(_range(W))$name"

# what one module's emission carries along: the text so far, and the names the
# wires of the traced logic have been given
struct Emitter
  io::IOBuffer
  defined::Set{Int}                # wire ids already declared
  stage::Dict{Int,Int}             # wire id => the pipeline stage that computes it
  pipe::Dict{Tuple{Int,Int},String}   # (wire id, stage) => the register holding it there
  encs::Dict{Symbol,Any}           # field name => encoding, for registers that have one
end

Emitter(encs=Dict{Symbol,Any}()) = Emitter(IOBuffer(), Set{Int}(), Dict{Int,Int}(), Dict{Tuple{Int,Int},String}(), encs)

# a constant that meets an encoded register is written by its state's name
function _constref(e::Emitter, c::Wire, subject)
  c.op == :const || return nothing
  subject isa Wire && subject.op == :reg && haskey(e.encs, subject.name) || return nothing
  _statename(e.encs[subject.name], c)
end

function _statename(enc, c::Wire)
  name = encname(enc, Bits{bitwidth(enc)}(UInt128(c.args[1]) & _mask(bitwidth(enc))))
  name === nothing ? nothing : "$(encname(enc))_$name"
end

function _ref(e::Emitter, w::Wire, atstage::Int=-1)
  w.op == :const && return _lit(w.args[1], bitwidth(w), w.signed)
  if atstage ≥ 0 && haskey(e.stage, w.id) && e.stage[w.id] < atstage
    return e.pipe[(w.id, atstage)]
  end
  w.op == :input && return string(w.name)
  w.op == :reg && return string(w.name)
  w.op == :mgout && return w.args[2] == 1 ? string(w.name) : "$(w.name)[$(w.args[1])]"
  "w$(w.id)"
end

function _collect_nodes!(acc::Dict{Int,Wire}, w::Wire)
  haskey(acc, w.id) && return
  acc[w.id] = w
  for a in w.args
    a isa Wire && _collect_nodes!(acc, a)
  end
end
_collect_nodes!(acc, ::Any) = nothing   # a pad drive of a constant or of nothing at all

function _expr(e::Emitter, w::Wire)
  s = get(e.stage, w.id, -1)
  r(a) = a isa Wire ? _ref(e, a, s) : string(a)
  op, a = w.op, w.args
  W = bitwidth(w)
  op == :add && return "$(r(a[1])) + $(r(a[2]))"
  op == :sub && return "$(r(a[1])) - $(r(a[2]))"
  op == :mul && return "$(r(a[1])) * $(r(a[2]))"
  op == :and && return "$(r(a[1])) & $(r(a[2]))"
  op == :or && return "$(r(a[1])) | $(r(a[2]))"
  op == :xor && return "$(r(a[1])) ^ $(r(a[2]))"
  op == :neg && return "-$(r(a[1]))"
  op == :not && return "~$(r(a[1]))"
  if op in (:eq, :ne)
    l = something(_constref(e, a[1], a[2]), r(a[1]))
    rr = something(_constref(e, a[2], a[1]), r(a[2]))
    return "$l $(op == :eq ? "==" : "!=") $rr"
  end
  op == :lt && return "$(r(a[1])) < $(r(a[2]))"
  op == :le && return "$(r(a[1])) <= $(r(a[2]))"
  op == :gt && return "$(r(a[1])) > $(r(a[2]))"
  op == :ge && return "$(r(a[1])) >= $(r(a[2]))"
  op == :shl && return "$(r(a[1])) << $(r(a[2]))"
  op == :shr && return "$(r(a[1])) >> $(r(a[2]))"
  op == :sra && return "$(r(a[1])) >>> $(r(a[2]))"
  op == :rotl && (N = bitwidth(a[1]); n = a[2]; return "{$(r(a[1]))[$(N-n-1):0], $(r(a[1]))[$(N-1):$(N-n)]}")
  op == :mod && return "$(r(a[1])) % $(r(a[2]))"
  op == :div && return "$(r(a[1])) / $(r(a[2]))"
  op == :popcount && return join(("$(r(a[1]))[$i]" for i in 0:bitwidth(a[1])-1), " + ")
  op == :mux && return "$(r(a[1])) ? $(r(a[2])) : $(r(a[3]))"
  op == :bit && return bitwidth(a[1]) == 1 ? r(a[1]) : "$(r(a[1]))[$(a[2])]"
  op == :slice && return "$(r(a[1]))[$(a[3]):$(a[2])]"
  op == :dynslice && return _dynselect(r, a[1], a[2], a[3], a[4])
  op == :repeat && return "{$(a[2]){$(r(a[1]))}}"
  op == :concat && return "{$(r(a[1])), $(r(a[2]))}"
  op == :resize && (src = a[1]; return bitwidth(src) > W ? "$(r(src))[$(W-1):0]" : r(src))
  error("unknown wire op $op")
end

function _emit_wires!(e::Emitter, nodes::Vector{Wire})
  for w in sort(nodes; by=n -> n.id)
    (isleaf(w) || w.id in e.defined) && continue
    push!(e.defined, w.id)
    println(e.io, "  ", _decl("wire", "w$(w.id)", bitwidth(w); signed=w.signed), " = ", _expr(e, w), ";")
  end
end

function _plan_pipeline!(e::Emitter, mod::Symbol, name::Symbol, root::Wire, K::Int)
  c = _cut(root, K)
  for w in c.order
    haskey(e.stage, w.id) && e.stage[w.id] != c.stage[w.id] &&
      error("wire w$(w.id) is shared between two pipelines; compute it once per pipeline")
    e.stage[w.id] = c.stage[w.id]
  end
  for s in _idle(c)
    @warn _idlemessage(mod, name, K, s)
  end
  regs = @NamedTuple{decl::String, name::String}[]; assigns = String[]
  for w in c.order
    w.op == :const && continue
    s = c.stage[w.id]
    for b in s+1:get(c.lastuse, w.id, 0)
      nm = "$(name)_p$(b)_w$(w.id)"
      e.pipe[(w.id, b)] = nm
      push!(regs, (decl=_decl("reg", nm, bitwidth(w); signed=w.signed) * " = 0", name=nm))
      push!(assigns, "$nm <= $(b == s + 1 ? _ref(e, w) : e.pipe[(w.id, b - 1)]);")
    end
  end
  (; regs, assigns, nodes=c.order)
end

_allones(N) = Wire{N}(:const, Any[reinterpret(Int128, _mask(N))]; name=:const)

# one enable for a whole bus turns the pad on or off as a unit, so it spreads over
# the width rather than being a width mismatch
_padenable(en, N::Int, fname::Symbol) =
  en isa Wire && bitwidth(en) == 1 && N > 1 ? Wire{N}(:repeat, Any[en, N]) :
    _aswire(en, N, false, fname)

# a pad drive folds into two networks of the same width: the value and the
# per-bit output enable, which is all the Verilog tristate assign needs. An
# active-low pin inverts the value once, where it reaches the pin; the enable is
# not a level on the wire and does not invert.
_padpair(v, N::Int, fname::Symbol, activelow::Bool) =
  ((val, en) = _padwires(v, N, fname); (activelow ? ~val : val, en))

# the same resolution the simulator's `_padfold` in core/reg.jl does, in wires
# rather than values: change one and the other has to follow
function _padwires(v, N::Int, fname::Symbol)
  v isa PadRelease && return (constant(0, N), constant(0, N))
  if v isa PadDrive
    val = v.val === missing ? constant(0, N) : _aswire(v.val, N, false, fname)
    en = v.en === missing ? _allones(N) :
         v.en isa Bool ? (v.en ? _allones(N) : constant(0, N)) : _padenable(v.en, N, fname)
    return (val, en)
  end
  v isa PadMux || return _padwires(drive(v), N, fname)
  (av, ae) = _padwires(v.a, N, fname)
  (bv, be) = _padwires(v.b, N, fname)
  c = v.cond isa Wire ? v.cond : error("a pad mux needs a hardware condition")
  (ifelse(c, av, bv), ifelse(c, ae, be))
end

# continuous logic has no register to hold a value, so every path through the
# block must drive every field it writes
function _combvalue(tree::Vector, f::Symbol, N, signed, ispad)
  v, wrote = _combwrites(tree, f, nothing, N, signed, ispad)
  wrote && v === nothing &&
    error("@wire leaves $f undriven on some path; every branch must write it")
  v
end

# the value and whether this piece of the tree wrote the field at all: a branch
# that writes nothing leaves `incoming`, the value on entry, alone, but a branch
# that writes while the other does not needs something for the other to fall back on
function _combwrites(tree::Vector, f::Symbol, incoming, N, signed, ispad)
  cur, wrote = incoming, false
  for n in tree
    if n isa WriteNode && n.field == f
      n.range === nothing || error("@wire cannot write part of $f; drive the whole field")
      cur, wrote = ispad ? n.value : _aswire(n.value, N, signed, f), true
    elseif n isa IfNode
      tv, tw = _combwrites(n.then, f, cur, N, signed, ispad)
      ev, ew = _combwrites(n.els, f, cur, N, signed, ispad)
      if tw || ew
        # driven on one path only so far: a later unconditional write may still
        # cover it, so the verdict waits until the whole block has been walked
        cur, wrote = (tv === nothing || ev === nothing) ? nothing :
                     tv === ev ? tv : ifelse(n.cond, tv, ev), true
      end
    end
  end
  (cur, wrote)
end

# the fields a @wire block of T drives from an input port or a pad, whose value
# therefore depends on the cycle's inputs and not only on the registers
function _combinputdeps(T::Type)
  out = Symbol[]
  fields = _fieldinfo(T)
  for def in blocks(T)
    def.kind == :comb || continue
    isempty(def.inputs) && !any(f.kind == :pad for f in fields) && continue
    args = [Wire{W}(:input, Any[]; signed=sg, name=an) for an in def.inputs for (W, sg) in (_inputinfo(T, def, an),)]
    params = _paramvalues(def, T)
    ctx = TraceCtx()
    Base.invokelatest(tracefunction(def), ctx, _tracestate(fields, T, def, args), params..., args...)
    # a pad read lowers to the same kind of leaf as a port, and is just as current
    live = Set{Symbol}(w.name for w in args)
    union!(live, (f.vname for f in fields if f.kind == :pad))
    for fn in def.owned
      f = _finfo(fields, fn)
      (f === nothing || f.kind in (:pad, :blackbox, :submodule)) && continue   # pads are nets, never read up
      v = _combvalue(ctx.stack[1], fn, f.width, f.signed, false)
      v === nothing && continue
      nodes = Dict{Int,Wire}()
      _collect_nodes!(nodes, v)
      any(isleaf(w) && w.op == :input && w.name in live for w in values(nodes)) &&
        push!(out, fn)
    end
  end
  out
end

# the wires to a part's inputs: a part sees its pins every cycle, so a wire to one
# cannot sit under a condition -- put the condition in the value with ifelse
function _findconns(tree::Vector, nested=false)
  conns = ConnNode[]
  for n in tree
    if n isa ConnNode
      nested && error("the wire to $(n.field).$(n.port) may not be inside an `if`: a part " *
                      "sees its input every cycle, so put the condition in the value with ifelse")
      push!(conns, n)
    elseif n isa IfNode
      append!(conns, _findconns(n.then, true))
      append!(conns, _findconns(n.els, true))
    end
  end
  conns
end

function _noinstancewrites(tree::Vector, fields)
  for n in tree
    if n isa WriteNode
      f = _finfo(fields, n.field)
      f !== nothing && f.kind in (:submodule, :blackbox) &&
        error("$(n.field) is an instance and cannot be written; wire its inputs, `$(n.field).port ← value`")
    elseif n isa IfNode
      _noinstancewrites(n.then, fields); _noinstancewrites(n.els, fields)
    end
  end
end

_paramvalues(def::BlockDef, T::Type) = (wv = tracewheres(def, T); [get(wv, p, nothing) for p in def.params])

# every declared input is reachable through the state, as `this.name`, whether or
# not the block names it bare
function _tracestate(fields, T::Type, def::BlockDef, args)
  state = TraceState(Dict{Symbol,Any}())
  for n in fieldnames(fieldtype(T, INPUTS))
    i = findfirst(==(n), def.inputs)
    W, sg = _inputinfo(T, def, n)
    getfield(state, :fields)[n] = i === nothing ? Wire{W}(:input, Any[]; signed=sg, name=n) : args[i]
  end
  for f in fields
    if f.kind == :reg
      getfield(state, :fields)[f.name] = Wire{f.width}(:reg, Any[]; signed=f.signed, name=f.name)
    elseif f.kind == :metaguard
      getfield(state, :fields)[f.name] = TMetaGuard(f.name, f.K)
    elseif f.kind == :edge
      getfield(state, :fields)[f.name] = TEdge(f.name)
    elseif f.kind == :pipeline
      getfield(state, :fields)[f.name] = TPipeline(f.name, f.K, f.T)
    elseif f.kind == :multicycle
      getfield(state, :fields)[f.name] = TMulticycle(f.name, f.K, f.T)
    elseif f.kind == :pad
      getfield(state, :fields)[f.name] = TPad(f.name, f.vname, f.width, f.pull, f.activelow)
    elseif f.kind in (:submodule, :blackbox)
      getfield(state, :fields)[f.name] = TSubmodule(f.name, f.T)
    end
  end
  state
end

_finfo(fields, name) = (i = findfirst(x -> x.name == name, fields); i === nothing ? nothing : fields[i])

# a pad drive folded into what the tristate assign needs
struct PadPair
  val::Wire      # what the module drives
  oe::Wire       # where it drives it, bit by bit
end

function _lowerpads!(tree::Vector, fields)
  for n in tree
    if n isa WriteNode
      f = _finfo(fields, n.field)
      (f === nothing || f.kind != :pad) && continue
      n.value = PadPair(_padpair(n.value, n.range === nothing ? f.width : length(n.range),
                                 n.field, f.activelow)...)
    elseif n isa IfNode
      _lowerpads!(n.then, fields)
      _lowerpads!(n.els, fields)
    end
  end
end

function _emitgraph(io::IO, T::Type, name::Symbol, emitted::Dict{Type,Symbol})
  haskey(emitted, T) && return
  emitted[T] = name                      # claim the name before the children pick theirs
  for FT in fieldtypes(T)
    FT <: QuartzModule && !isblackbox(FT) && _emitgraph(io, FT, _modname(FT, emitted), emitted)
  end
  _emitmodule(io, T, name, emitted)
end

# two instantiations of a parametric module are two Verilog modules, so the name
# has to say which one
function _modname(T::Type, emitted)
  used = Set(values(emitted))
  base = string(nameof(T))
  Symbol(base) in used || return Symbol(base)
  ps = T isa DataType ? T.parameters : ()
  cand = isempty(ps) ? base : base * "_" * join(string.(ps), "_")
  n = Symbol(cand)
  i = 1
  while n in used
    i += 1
    n = Symbol(cand, "_", i)
  end
  n
end

# a field or port name is a net inside the emitted module, so it cannot be a word
# Verilog keeps for itself
const VERILOG_KEYWORDS = Set(Symbol.(split("""
  always and assign automatic begin bit break buf byte case casex casez class const context
  continue cover default disable do edge else end endcase endclass endfunction endgenerate
  endinterface endmodule endpackage endprogram endproperty endsequence endtask enum event
  export extern final for force foreach fork forever function generate genvar highz0 highz1
  if iff import initial inout input inside int integer interface join localparam logic
  longint matches module nand negedge new nor not or output package parameter posedge
  priority program property protected pull0 pull1 pulldown pullup pure rand randc real
  realtime ref reg release repeat return sequence shortint shortreal signed static string
  struct super supply0 supply1 table tagged task this time timeprecision timeunit tri tri0
  tri1 triand trior trireg type typedef union unique unsigned var vectored virtual void wait
  wand weak0 weak1 while wire with wor xnor xor""")))

function _checknames(T::Type, ports)
  for n in vcat(collect(fieldnames(T)), [p.name for p in ports], [p.vname for p in ports])
    n in VERILOG_KEYWORDS &&
      error("$n of $(nameof(T)) is a Verilog keyword and cannot name a net; rename it")
  end
end

# one block as traced: what it wrote, and the conditions it wrote under
const TracedBlock = @NamedTuple{def::BlockDef, tree::Vector{Any}, resetw::Any,
  enablew::Any, overrides::Dict{Symbol,Any}, state::TraceState, params::Vector{Any},
  args::Vector{Wire}}

function _traceblocks(T::Type)
  default = T()
  fields = _fieldinfo(T, default)
  blks = TracedBlock[]
  conns = ConnNode[]
  for def in blocks(T)
    args = Wire[]
    for an in def.inputs
      W, sg = _inputinfo(T, def, an)
      push!(args, Wire{W}(:input, Any[]; signed=sg, name=an))
    end
    params = _paramvalues(def, T)
    state = _tracestate(fields, T, def, args)
    ctx = TraceCtx()
    tf = tracefunction(def)
    Base.invokelatest(tf, ctx, state, params..., args...)
    def.kind == :on && _lowerpads!(ctx.stack[1], fields)
    _noinstancewrites(ctx.stack[1], fields)
    append!(conns, _findconns(ctx.stack[1]))
    resetw = def.reset === nothing ? nothing : _trace_expr(def, def.reset, state, params, args)
    enablew = def.only_when === nothing ? nothing : _trace_expr(def, def.only_when, state, params, args)
    overrides = Dict{Symbol,Any}(o.args[1] => _trace_expr(def, o.args[2], state, params, args)
                                 for o in def.reset_overrides)
    push!(blks, (; def, tree=ctx.stack[1], resetw, enablew, overrides, state, params, args))
  end
  (; default, fields, blks, conns)
end

function _emitmodule(io::IO, T::Type{<:QuartzModule}, name::Symbol, emitted::Dict{Type,Symbol})
  (; default, fields, blks, conns) = _traceblocks(T)
  e = Emitter(_emitencodings(T))
  ports = _ports(T, default)
  _preflight(T, fields, blks, ports)
  out = e.io
  println(out, "module $name (")
  println(out, join((_portlines(T, p, default) for p in ports), ",\n"))
  println(out, ");\n")
  _emitlocalparams(out, e.encs)
  _emitdecls(out, T, default, fields, blks, ports)
  println(out)
  for b in blks
    b.def.kind == :comb && _emitcomb(out, e, T, fields, b)
  end
  _emitpaddrives(out, fields, blks)
  for b in blks
    b.def.kind == :on && _emitalways(out, e, T, default, fields, b)
  end
  _emitmulticycles(out, e, T, fields, blks)
  _emitinstances(out, e, T, conns, emitted)
  for p in ports
    _needsbridge(p) && p.dir == :output &&
      println(out, "  assign $(p.vname) = $(_bridge(p, p.name));")
  end
  println(out, "endmodule")
  print(io, String(take!(out)))
  nothing
end

# what has to hold before a line is emitted: no net is named by a Verilog keyword,
# and no submodule wire read here is one the submodule computes from its own inputs
function _preflight(T::Type, fields, blks, ports)
  reads = Dict{Int,Wire}()
  for b in blks
    _collect_tree!(reads, b.tree)
    b.resetw isa Wire && _collect_nodes!(reads, b.resetw)
    b.enablew isa Wire && _collect_nodes!(reads, b.enablew)
  end
  readnames = Set{Symbol}(w.name for w in values(reads) if isleaf(w))
  for f in fields
    f.kind == :submodule || continue
    for x in _combinputdeps(f.T)
      Symbol(f.name, "_", x) in readnames &&
        error("$(f.name).$x is driven by a @wire block of $(nameof(f.T)) that reads " *
              "an input port or a pad, so reading it here would be one cycle late in " *
              "simulation while the Verilog wire is current; compute it from the " *
              "submodule's registers alone and do the rest here")
    end
  end
  _checknames(T, ports)
end

# A port whose pin is named differently, or asserted low, is bridged where it meets
# the outside, and nowhere else. Inside the module there is one name and one polarity.
_needsbridge(p) = p.activelow || p.vname !== p.name
_bridge(p, from) = "$(p.activelow ? "~" : "")$from"

# an encoded register's states, as the names its constants are written by
# the encodings as the Verilog states them: a Step's at the width its steps need,
# since that is the width its register is emitted at
function _emitencodings(T::Type)
  encs = allencodings(T)
  for (f, enc) in encs
    get(advancing(T), f, nothing) === :step || continue
    encs[f] = _mkencoding(encname(enc), :binary, Tuple(keys(enc)), ntuple(_ -> nothing, length(enc)),
                          _stepwidth(enc), getfield(enc, :docs))
  end
  encs
end

function _emitlocalparams(out, encs)
  for (f, enc) in sort(collect(encs); by=first)
    any(x -> x !== f && encs[x] === enc && x < f, keys(encs)) && continue
    for (k, v) in pairs(getfield(enc, :values))
      println(out, "  localparam ", _range(bitwidth(enc)), "$(encname(enc))_$k = ", _lit(Int128(v), bitwidth(enc)), ";")
    end
  end
  isempty(encs) || println(out)
end

function _emitdecls(out, T::Type, default, fields, blks, ports)
  for p in ports
    _needsbridge(p) && p.dir == :input &&
      println(out, "  ", _decl("wire", p.name, p.width; signed=p.signed), " = ", _bridge(p, p.vname), ";")
  end
  padfields = Set{Symbol}(f.name for f in fields if f.kind == :pad)
  for f in fields
    f.kind in (:submodule, :blackbox) || continue
    for p in (f.kind == :blackbox ? blackbox(f.T).ports : _ports(f.T))
      if f.kind == :submodule && p.dir == :clockout && p.name in padfields
        println(out, "  wire $(f.name)_$(p.name);")
      elseif p.dir == :output && _needsbridge(p)
        println(out, "  ", _decl("wire", "$(f.name)_$(p.name)_pin", p.width; signed=p.signed), ";")
        println(out, "  ", _decl("wire", "$(f.name)_$(p.name)", p.width; signed=p.signed),
                " = ", _bridge(p, "$(f.name)_$(p.name)_pin"), ";")
      elseif p.dir == :output
        println(out, "  ", _decl("wire", "$(f.name)_$(p.name)", p.width; signed=p.signed), ";")
      end
    end
  end
  for c in _internalclocks(T)
    println(out, "  wire $c;")
  end
  _emitfielddecls(out, T, default, fields, blks)
end

# an initializer makes the synthesiser guarantee the power-up value, which costs it
# the flip-flops' enable and clear pins -- the reason a register a reset restores
# does not get one. See Verilog in formats.jl for what :static and :all mean.
_init(v, W; restored=false) =
  _vinits() === :all || (v != 0 && !restored) ? string(" = ", _lit(v, W)) : ""

# the power-up value of a field, as the declaration initializes it and as the reset
# arm restores it, so the two cannot disagree
_regvalue(default, f) = _toint(getfield(default, f.name))
_mgvalue(default, f) = Int(getfield(default, f.name).reg.val)
_edgevalues(default, f) = (v = getfield(default, f.name); (Int(v.cur), Int(v.prev)))

function _emitfielddecls(out, T::Type, default, fields, blks)
  combfields = Set{Symbol}(f for b in blks if b.def.kind == :comb for f in b.def.owned)
  resetcov = Set{Symbol}(f for b in blks if b.resetw !== nothing for f in b.def.owned)
  reset_restores(f) = f.name in resets(T) && f.name in resetcov
  for f in fields
    if f.kind == :reg
      if f.name in combfields
        # a renamed or inverted output is assigned inside and bridged at the pin, so
        # it needs a wire of its own; one that reaches its pin unchanged is the port
        isport(T, f.name, :out) && !_isplainoutput(T, f.name) &&
          println(out, "  ", _decl("wire", f.name, f.width; signed=f.signed), ";")
        continue
      end
      _isplainoutput(T, f.name) && continue
      println(out, "  ", _decl("reg", f.name, f.width; signed=f.signed),
              _init(_regvalue(default, f), f.width; restored=reset_restores(f)), ";")
    elseif f.kind == :pad
      f.name in combfields && continue
      any(f.name in b.def.owned for b in blks) || continue
      p = getfield(default, f.name)
      println(out, "  ", _decl("reg", "$(f.name)_padval", f.width), _init(Int128(p.val), f.width), ";")
      println(out, "  ", _decl("reg", "$(f.name)_padoe", f.width), _init(Int128(p.oe), f.width), ";")
    elseif f.kind == :metaguard
      println(out, "  ", _decl("reg", "$(f.name)_mg", f.K),
              _init(_mgvalue(default, f), f.K; restored=f.name in resetcov), ";")
    elseif f.kind == :edge
      cur, prev = _edgevalues(default, f)
      restored = reset_restores(f)
      println(out, "  ", _decl("reg", string(f.name), 1), _init(cur, 1; restored), ";")
      println(out, "  ", _decl("reg", "$(f.name)_prev", 1), _init(prev, 1; restored), ";")
    elseif f.kind == :pipeline
      W = bitwidth(f.T); sg = issigned(f.T)
      restored = f.name in resetcov
      f.K > 0 && println(out, "  ", _decl("reg", "$(f.name)_valid", f.K), _init(0, f.K; restored), ";")
      f.K > 0 && println(out, "  ", _decl("reg", "$(f.name)_s$(f.K)", W; signed=sg), _init(0, W; restored), ";")
      println(out, "  ", _decl("reg", "$(f.name)_out", W; signed=sg), _init(0, W; restored), ";")
      println(out, "  reg $(f.name)_hasout", _init(0, 1; restored), ";")
      println(out, "  reg $(f.name)_isnew", _init(0, 1; restored), ";")
      println(out, "  reg $(f.name)_wr;")
      println(out, "  wire $(f.name)_ready = $(f.name)_hasout", f.K > 0 ? " & ~|$(f.name)_valid;" : ";")
    elseif f.kind == :multicycle
      Wc = _settlewidth(f.K)
      println(out, "  ", _decl("wire", f.name, f.width; signed=f.signed), ";")
      println(out, "  ", _decl("reg", "$(f.name)_settle", Wc), _init(0, Wc), ";")
      println(out, "  wire $(f.name)_ready = $(f.name)_settle == $(_lit(f.K - 1, Wc));")
    end
  end
end

# one @wire block: the logic it computes, then the continuous assign of each field
# it drives, a pad as the value and output enable its tristate assign takes
function _emitcomb(out, e::Emitter, T::Type, fields, b)
  vals = Tuple{Any,Union{Wire,PadPair}}[]
  for fn in b.def.owned
    f = _finfo(fields, fn)
    f === nothing && error("@wire writes $fn, which is not a field of $(nameof(T))")
    f.kind in (:blackbox, :submodule) && continue     # wired at the instance
    v = _combvalue(b.tree, fn, f.width, f.kind == :pad ? false : f.signed, f.kind == :pad)
    v === nothing && error("@wire block writes nothing to $fn")
    w = f.kind == :pad ? PadPair(_padpair(v, f.width, fn, f.activelow)...) : v
    loop = Dict{Int,Wire}()
    w isa PadPair ? (_collect_nodes!(loop, w.val); _collect_nodes!(loop, w.oe)) :
                    _collect_nodes!(loop, w)
    any(isleaf(x) && x.op == :reg && x.name == fn for x in values(loop)) &&
      error("@wire block of $(nameof(T)) drives $fn from itself, which is a " *
            "combinational loop")
    push!(vals, (f, w))
  end
  nodes = Dict{Int,Wire}()
  _collect_tree!(nodes, b.tree)
  for (f, v) in vals
    v isa PadPair ? (_collect_nodes!(nodes, v.val); _collect_nodes!(nodes, v.oe)) : _collect_nodes!(nodes, v)
  end
  _emit_wires!(e, collect(values(nodes)))
  for (f, v) in vals
    if v isa PadPair
      println(out, "  ", _decl("wire", "$(f.name)_padval", f.width), " = ", _ref(e, v.val), ";")
      println(out, "  ", _decl("wire", "$(f.name)_padoe", f.width), " = ", _ref(e, v.oe), ";")
    else
      println(out, "  assign $(f.name) = $(_ref(e, v));")
    end
  end
  println(out)
end

# a pad is driven bit by bit: its value where its output enable is set, and the
# high impedance the outside can drive against where it is not
function _emitpaddrives(out, fields, blks)
  for f in fields
    f.kind == :pad || continue
    any(f.name in b.def.owned for b in blks) || continue
    if f.width == 1
      println(out, "  assign $(f.vname) = $(f.name)_padoe ? $(f.name)_padval : 1'bz;")
    else
      for i in 0:f.width-1
        println(out, "  assign $(f.vname)[$i] = $(f.name)_padoe[$i] ? $(f.name)_padval[$i] : 1'bz;")
      end
    end
  end
  any(f.kind == :pad for f in fields) && println(out)
end

function _emitalways(out, e::Emitter, T::Type, default, fields, b)
  allnodes = Dict{Int,Wire}()
  _collect_tree!(allnodes, b.tree)
  b.resetw isa Wire && _collect_nodes!(allnodes, b.resetw)
  b.enablew isa Wire && _collect_nodes!(allnodes, b.enablew)
  for v in values(b.overrides)
    v isa Wire && _collect_nodes!(allnodes, v)
  end
  pipes = _blockpipes(e, T, fields, b, allnodes)
  for p in values(pipes)
    p.plan === nothing && continue
    for r in p.plan.regs; println(out, "  $(r.decl);"); end
  end
  gates = Dict{Symbol,Any}(c.name => _trace_expr(b.def, c.gate, b.state, b.params, b.args)
                           for c in b.def.clockouts if c.gate !== nothing)
  for g in values(gates)
    g isa Wire && _collect_nodes!(allnodes, g)
  end
  _emit_wires!(e, collect(values(allnodes)))
  for c in b.def.clockouts
    g = c.gate === nothing ? "" : " & " * _condstr(e, gates[c.name])
    println(out, "  assign $(_portattrs(T, c.name)[1]) = $(c.invert ? "~" : "")$(_clockref(T, b.def.clock))$g;")
  end
  println(out)
  println(out, "  always @($(b.def.edge) $(_clockref(T, b.def.clock))) begin")
  ind = "    "
  if b.resetw !== nothing
    println(out, ind, "if ($(_condstr(e, b.resetw))) begin")
    _emitresetarm(out, e, T, default, fields, b, pipes, ind * "  ")
    print(out, ind, "end else ")
    b.enablew !== nothing && print(out, "if ($(_condstr(e, b.enablew))) ")
    println(out, "begin")
  elseif b.enablew !== nothing
    println(out, ind, "if ($(_condstr(e, b.enablew))) begin")
  else
    println(out, ind, "begin")
  end
  ind2 = ind * "  "
  for p in values(pipes)
    println(out, ind2, "$(p.f.name)_wr = 1'b0;")
  end
  # an edge's history follows its level on every enabled cycle, so an event
  # deasserts by itself a cycle after the sample that made it
  for f in fields
    f.kind == :edge && f.name in b.def.owned && println(out, ind2, "$(f.name)_prev <= $(f.name);")
  end
  _emit_tree(out, e, b.tree, ind2, fields, pipes)
  for p in values(pipes)
    _emitpipetail(out, e, p, ind2)
  end
  println(out, ind, "end")
  println(out, "  end\n")
end

# the pipeline fields this block writes, each with the cut its value is emitted in
function _blockpipes(e::Emitter, T::Type, fields, b, allnodes)
  pipes = Dict{Symbol,Any}()
  for f in fields
    f.kind == :pipeline || continue
    writes = _find_writes(b.tree, f.name)
    isempty(writes) && continue
    length(writes) == 1 || error("pipeline field $(f.name) is written in more than one place")
    root = _aswire(writes[1].value, bitwidth(f.T), issigned(f.T), f.name)
    _collect_nodes!(allnodes, root)
    pipes[f.name] = (; plan=f.K > 1 ? _plan_pipeline!(e, nameof(T), f.name, root, f.K) : nothing, root, f)
  end
  pipes
end

# the reset arm: every field the block owns back to its power-up value, or to the
# value a @reset override gives it
function _emitresetarm(out, e::Emitter, T::Type, default, fields, b, pipes, ind)
  for f in fields
    f.name in b.def.owned || continue
    if f.kind == :reg
      f.name in resets(T) || haskey(b.overrides, f.name) || continue
      v = haskey(b.overrides, f.name) ? b.overrides[f.name] :
          constant(_regvalue(default, f), f.width; signed=f.signed)
      named = v isa Wire ? _constref(e, v, _regwire(f)) : nothing
      println(out, ind, "$(f.name) <= $(something(named, _valstr(e, v, f.width, f.signed)));")
    elseif f.kind == :metaguard
      println(out, ind, "$(f.name)_mg <= $(_lit(_mgvalue(default, f), f.K));")
    elseif f.kind == :edge
      f.name in resets(T) || haskey(b.overrides, f.name) || continue
      if haskey(b.overrides, f.name)
        v = b.overrides[f.name]
        s = v isa Wire ? _ref(e, v) : _valstr(e, v, 1, false)
        println(out, ind, "$(f.name) <= $s;")
        println(out, ind, "$(f.name)_prev <= $s;")
      else
        cur, prev = _edgevalues(default, f)
        println(out, ind, "$(f.name) <= $(_lit(cur, 1));")
        println(out, ind, "$(f.name)_prev <= $(_lit(prev, 1));")
      end
    elseif f.kind == :pipeline
      W = bitwidth(f.T)
      f.K > 0 && println(out, ind, "$(f.name)_valid <= $(_lit(0, f.K));")
      f.K > 0 && println(out, ind, "$(f.name)_s$(f.K) <= $(_lit(0, W));")
      println(out, ind, "$(f.name)_out <= $(_lit(0, W));")
      println(out, ind, "$(f.name)_hasout <= 1'b0;")
      println(out, ind, "$(f.name)_isnew <= 1'b0;")
      if haskey(pipes, f.name) && pipes[f.name].plan !== nothing
        for r in pipes[f.name].plan.regs
          println(out, ind, "$(r.name) <= 0;")
        end
      end
    end
  end
end

# what a pipeline does with the write the block just made: hand it straight to the
# output, or shift it and its valid bit down the stages
function _emitpipetail(out, e::Emitter, p, ind)
  f = p.f; K = f.K; nm = f.name
  if K == 0
    println(out, ind, "if ($(nm)_wr) $(nm)_out <= $(_ref(e, p.root));")
    println(out, ind, "$(nm)_isnew <= $(nm)_wr;")
    println(out, ind, "$(nm)_hasout <= $(nm)_hasout | $(nm)_wr;")
  else
    if p.plan !== nothing
      for a in p.plan.assigns; println(out, ind, a); end
    end
    println(out, ind, "$(nm)_s$(K) <= $(_ref(e, p.root, K - 1));")
    println(out, ind, "$(nm)_valid <= ", K == 1 ? "$(nm)_wr;" : "{$(nm)_valid[$(K-2):0], $(nm)_wr};")
    vlast = K == 1 ? "$(nm)_valid" : "$(nm)_valid[$(K-1)]"
    println(out, ind, "if ($vlast) $(nm)_out <= $(nm)_s$(K);")
    println(out, ind, "$(nm)_isnew <= $vlast;")
    println(out, ind, "$(nm)_hasout <= $(nm)_hasout | $vlast;")
  end
end

# A multicycle wire's settle counter: back to zero on the edge a source register is
# written, up by one otherwise, holding at K-1 -- which is when a register at the
# end of the path may capture, the K-th cycle after the sources moved.
_settlewidth(K) = max(1, _clog2(K))

function _emitmulticycles(out, e::Emitter, T::Type, fields, blks)
  any(f.kind == :multicycle for f in fields) || return
  infos = _multicycleinfo(T, fields, blks)
  for f in fields
    f.kind == :multicycle || continue
    info = infos[f.name]
    nodes = Dict{Int,Wire}()
    info.restart isa Wire && _collect_nodes!(nodes, info.restart)
    _emit_wires!(e, collect(values(nodes)))
    Wc = _settlewidth(f.K)
    nm = f.name
    println(out, "  wire $(nm)_restart = $(_condstr(e, info.restart));")
    println(out, "  always @($(info.edge) $(_clockref(T, info.clock))) begin")
    println(out, "    if ($(nm)_restart) $(nm)_settle <= $(_lit(0, Wc));")
    println(out, "    else if ($(nm)_settle != $(_lit(f.K - 1, Wc))) $(nm)_settle <= $(nm)_settle + $(_lit(1, Wc));")
    println(out, "  end\n")
  end
end

# two blocks may drive a submodule port with the same expression; the traced wires
# are then distinct objects, so they are compared by structure, not identity
_wirekey(w::Wire) = isleaf(w) ?
  (w.op, w.name, bitwidth(w), w.op == :const ? w.args[1] : nothing) :
  (w.op, bitwidth(w), Tuple(a isa Wire ? _wirekey(a) : a for a in w.args))

# An instance is wired and nothing else: its clocks to the nets the @wire blocks
# bind them to, its data inputs to the values they give it. Outputs go to the wires
# the module declares for them; pads and forwarded clocks pass through by name.
function _emitinstances(out, e::Emitter, T::Type, conns, emitted)
  default = T()
  fields = _fieldinfo(T, default)
  any(f.kind in (:submodule, :blackbox) for f in fields) || return
  absorbed = Set{Symbol}(f.name for f in fields if f.kind == :pad)
  println(out)
  for f in fields
    f.kind in (:submodule, :blackbox) || continue
    bb = f.kind == :blackbox ? blackbox(f.T) : nothing
    ports = bb === nothing ? _ports(f.T) : bb.ports
    defaults = bb === nothing ? _portdefaults(f.T) : Dict{Symbol,Any}()
    binds = _clockbind(T, f.name)
    conn = Dict{Symbol,String}()
    for c in conns
      c.field === f.name || continue
      p = _finfoport(ports, c.port)
      p !== nothing && p.dir == :input || error("$(nameof(f.T)) has no input $(c.port)")
      haskey(conn, c.port) && error("input $(c.port) of $(f.name) is wired twice")
      w = _aswire(c.value, p.width, p.signed, c.port)
      # the parent holds the logical value; the child's pin wants it inverted
      conn[c.port] = p.activelow ? "~($(_ref(e, w)))" : _ref(e, w)
    end
    args = String[]
    for p in ports
      if p.dir == :output
        conn[p.name] = (p.activelow || p.vname !== p.name) ? "$(f.name)_$(p.name)_pin" : "$(f.name)_$(p.name)"
      elseif p.dir == :clock || (p.dir == :input && bb === nothing && p.name in _clocksof(f.T))
        net = _boundnet(binds, p.name)
        net === nothing &&
          error("clock $(p.name) of $(f.name) is on no net; wire it in a @wire block, " *
                "`$(f.name).$(p.name) ← clk`")
        conn[p.name] = _clockref(T, net)
      elseif p.dir == :clockout
        net = bb === nothing ? nothing : _boundnet(binds, p.name)
        conn[p.name] = bb !== nothing ? (net === nothing ? "" : _clockref(T, net)) :
                       p.name in absorbed ? "$(f.name)_$(p.name)" : string(p.vname)
      elseif p.dir == :inout
        conn[p.name] = string(p.vname)
      elseif !haskey(conn, p.name)
        haskey(defaults, p.name) ||
          error("input $(p.name) of $(f.name) is not wired; give it a value in a @wire block, " *
                "`$(f.name).$(p.name) ← value`")
        conn[p.name] = _lit(_toint(defaults[p.name]), p.width, p.signed)
      end
      push!(args, ".$(p.vname)($(conn[p.name]))")
    end
    mod = bb === nothing ? get(emitted, f.T, nameof(f.T)) : bb.verilogname
    pragma = bb === nothing || isempty(bb.pragma) ? "" : " /* synthesis $(bb.pragma) */"
    println(out, "  $mod $(f.name)($(join(args, ", ")))$pragma;")
  end
end

function _portdecl(p::Port, default)
  rng = _range(p.width); sg = p.signed ? "signed " : ""
  p.dir == :input && return "input wire $sg$rng$(p.vname)"
  p.dir == :inout && return "inout wire $rng$(p.vname)"
  p.dir == :clockout && return "output wire $(p.vname)"
  p.wire ? "output wire $sg$rng$(p.vname)" :
    "output reg $sg$rng$(p.vname) = " * _lit(_toint(getfield(default, p.name)), p.width)
end

_toint(x::Bool) = Int(x)
_toint(x::HWInt) = Int128(x)
_toint(x::Integer) = x

# a wire is written by reference; the width and sign only matter for a constant
_valstr(e::Emitter, w::Wire, W, signed) = _ref(e, w)
_valstr(e::Emitter, v, W, signed) = _lit(_toint(v), W, signed)

_condstr(e::Emitter, w::Wire) = _ref(e, w)
_condstr(e::Emitter, b::Bool) = b ? "1'b1" : "1'b0"

function _trace_expr(def::BlockDef, ex, state, params, args)
  f = Core.eval(def.mod, :((this, $(def.params...), $(def.inputs...)) -> $ex))
  Base.invokelatest(f, state, params..., args...)
end

# a port line of the module header, with the port's documentation above it
function _portlines(T::Type, p::Port, default)
  doc = p.dir == :input && p.name in _clocksof(T) ? nothing : portdoc(T, p.name)
  decl = "  " * _portdecl(p, default)
  doc === nothing ? decl : join(("  // " * l for l in split(strip(doc), '\n')), "\n") * "\n" * decl
end

# the register a write or a reset targets, as the leaf it reads as, so a constant
# assigned to an encoded register can be named
_regwire(f) = Wire{f.width}(:reg, Any[]; signed=f.signed, name=f.name)

_collectpad!(acc, v::PadDrive) = (_collect_nodes!(acc, v.val); _collect_nodes!(acc, v.en))
_collectpad!(acc, ::PadRelease) = nothing
_collectpad!(acc, v::PadMux) = (_collect_nodes!(acc, v.cond);
                                _collectpad!(acc, v.a); _collectpad!(acc, v.b))

function _collect_tree!(acc, tree::Vector)
  for n in tree
    _dead(n) && continue
    if n isa WriteNode
      n.range isa DynRange && _collect_nodes!(acc, n.range.base)
      n.value isa Wire && _collect_nodes!(acc, n.value)
      n.value isa PadValue && _collectpad!(acc, n.value)
      n.value isa PadPair && (_collect_nodes!(acc, n.value.val); _collect_nodes!(acc, n.value.oe))
    elseif n isa ConnNode
      n.value isa Wire && _collect_nodes!(acc, n.value)
    elseif n isa LogNode
      _vdebug() && foreach(a -> a.second isa Wire && _collect_nodes!(acc, a.second), n.args)
    elseif n isa IfNode
      _collect_nodes!(acc, n.cond)
      _collect_tree!(acc, n.then); _collect_tree!(acc, n.els)
    end
  end
end

function _find_writes(tree::Vector, f::Symbol)
  out = WriteNode[]
  for n in tree
    n isa WriteNode && n.field == f && push!(out, n)
    n isa IfNode && (append!(out, _find_writes(n.then, f)); append!(out, _find_writes(n.els, f)))
  end
  out
end

function _aswire(v, W, signed, fname)
  if v isa Wire
    bitwidth(v) == W ||
      error("writing a $(bitwidth(v))-bit value to $(W)-bit register $fname " *
            "needs an explicit conversion")
    return v
  end
  v isa MaybeWire && error("write the value of a pipeline read through coalesce, not the pipeline itself")
  v isa Bool && return constant(v, W)
  v isa Integer && return constant(v, W)
  error("cannot write a value of type $(typeof(v)) to register $fname")
end

# An if/elseif chain that tests one value against distinct constants is a case
# statement -- the same logic, but what a synthesiser recognises as a state machine.
# Anything else, including a chain that repeats a constant, keeps the if form.
function _casechain(n::IfNode)
  subject = nothing
  arms = Tuple{Wire,Vector{Any}}[]
  vals = Int128[]
  node = n
  while true
    s, v = _eqconst(node.cond)
    s === nothing && return nothing
    subject === nothing ? (subject = s) : (subject.id == s.id || return nothing)
    v.args[1] in vals && return nothing
    push!(vals, v.args[1])
    push!(arms, (v, node.then))
    els = node.els
    if length(els) == 1 && els[1] isa IfNode
      node = els[1]
    else
      length(arms) < 2 && return nothing
      return (subject, arms, isempty(els) ? nothing : els)
    end
  end
end

function _eqconst(c)
  c isa Wire && c.op === :eq && length(c.args) == 2 || return (nothing, nothing)
  a, b = c.args
  a isa Wire && b isa Wire || return (nothing, nothing)
  a.op === :const && !(b.op === :const) && return (b, a)
  b.op === :const && !(a.op === :const) && return (a, b)
  (nothing, nothing)
end

_selstr(::Emitter, ::Nothing) = ""
_selstr(::Emitter, r::UnitRange{Int}) =
  length(r) == 1 ? "[$(first(r))]" : "[$(last(r)):$(first(r))]"
_selstr(e::Emitter, d::DynRange) =
  (d.stride == 1 || error("an aligned dynamic slice is decoded, not written with +:");
   "[$(_ref(e, d.base)) +: $(d.width)]")

# the part numbers a strided access can reach: those whose slice fits the word
# and whose number fits the index
_partnumbers(W, width, stride, idxbits) = 0:min((1 << idxbits) - 1, (W - width) ÷ stride)

# an aligned dynamic read is a mux over its parts, keyed by the part number: the
# alignment is what makes the mux narrow, and a multiplied-out base would hide it
# from the synthesiser. An index past the last part cannot occur -- the simulator
# refuses it -- so the last part serves as the tail of the chain.
function _dynselect(r, x, idx, width, stride)
  stride == 1 && return "$(r(x))[$(r(idx)) +: $width]"
  slice(j) = "$(r(x))[$(j * stride + width - 1):$(j * stride)]"
  parts = _partnumbers(bitwidth(x), width, stride, bitwidth(idx))
  s = slice(last(parts))
  for j in reverse(parts)[2:end]
    s = "$(r(idx)) == $(_lit(j, bitwidth(idx))) ? $(slice(j)) : $s"
  end
  s
end

# an aligned dynamic write decodes the part number into one fixed slice per arm;
# an index past the last part writes nothing, as the simulator refuses it
function _emit_partwrite(out, e::Emitter, n::WriteNode, f, ind)
  d, idx = n.range, n.range.base
  parts = _partnumbers(f.width, d.width, d.stride, bitwidth(idx))
  println(out, ind, "case ($(_ref(e, idx)))")
  for j in parts
    sel = "[$(j * d.stride + d.width - 1):$(j * d.stride)]"
    if f.kind == :pad
      println(out, ind, "  $(_lit(j, bitwidth(idx))): begin")
      println(out, ind, "    $(n.field)_padval$sel <= $(_ref(e, n.value.val));")
      println(out, ind, "    $(n.field)_padoe$sel <= $(_ref(e, n.value.oe));")
      println(out, ind, "  end")
    else
      w = _aswire(n.value, d.width, false, n.field)
      println(out, ind, "  $(_lit(j, bitwidth(idx))): $(n.field)$sel <= $(_ref(e, w));")
    end
  end
  println(out, ind, "endcase")
end

# a log statement that is not being emitted, and an `if` that would hold nothing else
_dead(n) = (n isa LogNode || n isa CheckNode) ? !_vdebug() :
           n isa IfNode ? all(_dead, n.then) && all(_dead, n.els) : false

function _emit_tree(out, e::Emitter, tree::Vector, ind, fields, pipes)
  for n in tree
    _dead(n) && continue
    if n isa WriteNode
      if haskey(pipes, n.field)
        n.range === nothing || error("a pipeline field ($(n.field)) cannot be written in part")
        println(out, ind, "$(n.field)_wr = 1'b1;")
      elseif (f = fields[findfirst(x -> x.name == n.field, fields)];
              n.range isa DynRange && n.range.stride != 1 && !(f.kind in (:metaguard, :edge)))
        _emit_partwrite(out, e, n, f, ind)
      else
        sel = _selstr(e, n.range)
        W = f.kind in (:metaguard, :edge) ? 1 : n.range === nothing ? f.width : length(n.range)
        if f.kind == :pad
          println(out, ind, "$(n.field)_padval$sel <= $(_ref(e, n.value.val));")
          println(out, ind, "$(n.field)_padoe$sel <= $(_ref(e, n.value.oe));")
        elseif f.kind == :metaguard
          n.range === nothing || error("a guard ($(n.field)) takes one bit and cannot be written in part")
          w = _aswire(n.value, 1, false, n.field)
          println(out, ind, "$(n.field)_mg <= ",
                  f.K == 1 ? "$(_ref(e, w));" : "{$(n.field)_mg[$(f.K-2):0], $(_ref(e, w))};")
        elseif f.kind == :edge
          n.range === nothing || error("an Edge ($(n.field)) holds a single Bool and is written whole")
          w = _aswire(n.value, 1, false, n.field)
          println(out, ind, "$(n.field) <= $(_ref(e, w));")
        else
          w = _aswire(n.value, W, n.range === nothing && f.signed, n.field)
          named = n.range === nothing ? _constref(e, w, _regwire(f)) : nothing
          println(out, ind, "$(n.field)$sel <= $(something(named, _ref(e, w)));")
        end
      end
    elseif n isa IfNode
      c = _casechain(n)
      if c !== nothing
        subject, arms, default = c
        println(out, ind, "case ($(_ref(e, subject)))")
        for (val, branch) in arms
          println(out, ind, "  $(something(_constref(e, val, subject), _ref(e, val))): begin")
          _emit_tree(out, e, branch, ind * "    ", fields, pipes)
          println(out, ind, "  end")
        end
        if default !== nothing
          println(out, ind, "  default: begin")
          _emit_tree(out, e, default, ind * "    ", fields, pipes)
          println(out, ind, "  end")
        end
        println(out, ind, "endcase")
        continue
      end
      println(out, ind, "if ($(_ref(e, n.cond))) begin")
      _emit_tree(out, e, n.then, ind * "  ", fields, pipes)
      els = n.els
      while length(els) == 1 && els[1] isa IfNode      # an elseif chain stays flat
        println(out, ind, "end else if ($(_ref(e, els[1].cond))) begin")
        _emit_tree(out, e, els[1].then, ind * "  ", fields, pipes)
        els = els[1].els
      end
      if !isempty(els)
        println(out, ind, "end else begin")
        _emit_tree(out, e, els, ind * "  ", fields, pipes)
      end
      println(out, ind, "end")
    elseif n isa LogNode
      _vdebug() && println(out, ind, _vdisplay(e, n))
    elseif n isa CheckNode
      _vdebug() && println(out, ind, "\$error(\"", n.mod, ": check failed: ", _vstring(n.cond), "\");")
    end
  end
end

# `$display("%0t INFO Top: msg a=%0d", $time, a)`
function _vdisplay(e::Emitter, n::LogNode)
  level = n.level == Debug ? "DEBUG" : n.level == Info ? "INFO" : n.level == Warn ? "WARN" : "ERROR"
  fmt = "%0t " * level * " " * string(n.mod) * ": " * _vstring(n.msg isa String ? n.msg : "?") *
        join(" " * string(k) * "=%0d" for (k, _) in n.args)
  vals = join((a.second isa Wire ? _ref(e, a.second) : string(a.second) for a in n.args), ", ")
  "\$display(\"" * fmt * "\", \$time" * (isempty(vals) ? "" : ", " * vals) * ");"
end

_vstring(s::AbstractString) = replace(s, "\\" => "\\\\", "\"" => "\\\"", "%" => "%%")
