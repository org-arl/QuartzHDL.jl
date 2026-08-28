# What crosses a module's boundary, as facts of the type: its ports, how wide and
# which way, what each pin is called and whether it is asserted low, which clocks
# come from pins and which a black box makes. The emitters, the boards and the
# simulator all read these; none of them decides them.

struct Port
  name::Symbol
  dir::Symbol
  width::Int
  signed::Bool
  wire::Bool
  vname::Symbol            # what the port is called in Verilog, when that differs
  activelow::Bool          # the pin is asserted low; Julia values always mean asserted
end
Port(name, dir, width, signed, wire) = Port(name, dir, width, signed, wire, name, false)
Port(name, dir, width, signed, wire, vname) = Port(name, dir, width, signed, wire, vname, false)

# A port declared `active=:low` is inverted where it meets the pin, and nowhere else:
# inside the module, and in the Julia model, the value always means asserted.
# an output that reaches its pin unchanged is the port register itself; one that is
# renamed or inverted is an internal register with a wire port over it
_isplainoutput(T::Type, name::Symbol) =
  isport(T, name, :out) && ((vn, al) = _portattrs(T, name); !al && vn === name)

# The pin's name is the port's name with the direction on the end -- `_i`, `_o`,
# `_io`, or `_ni`, `_no`, `_nio` for a pin asserted low -- unless the declaration
# names the pin itself. A clock that comes from a pin is an input like any other
# and a forwarded clock an output; a clock a black box makes is a net and keeps
# its name. The suffixes are an option of the emission, on by default;
# `withportsuffix(f, false)` turns them off.
const PORTSUFFIX = :quartz_port_suffix
_portsuffix() = get(task_local_storage(), PORTSUFFIX, true)::Bool

withportsuffix(f, on::Bool) = _withtasklocal(f, PORTSUFFIX, on)

# an option of the emission, not of the design: it is set for the duration of a
# call and restored after it, so a nested call sees what it was given
function _withtasklocal(f, key, value)
  old = get(task_local_storage(), key, nothing)
  task_local_storage(key, value)
  try
    f()
  finally
    old === nothing ? delete!(task_local_storage(), key) : task_local_storage(key, old)
  end
end

_isclock(T::Type, name::Symbol) = name in _clocks(T)
_isclockout(T::Type, name::Symbol) =
  any(c.name === name for d in blocks(T) for c in d.clockouts) ||
  any(p.name === name for p in _clockoutports(T))

# A child's forwarded clock, read by a parent that wires it to a pad -- the way a
# power domain releases a clock pin the child still shapes. Traced, it is the net
# the instantiation connects; live, it is the level of the net the child's clock
# rides, inverted and gated as the clockout declares.
_clockoutread(::TraceState, ::Val{f}, ::Val{p}, _, _, _) where {f,p} =
  Wire{1}(:reg, Any[]; name=Symbol(f, "_", p))

function _clockoutread(this::QuartzModule, ::Val{f}, ::Val{p}, ::Val{cp}, ::Val{inv}, gate) where {f,p,cp,inv}
  net = _clockoutnet(typeof(this), Val(f), Val(cp))
  net === nothing &&
    error("nothing wires $f.$cp to a net, so $f.$p has no level in $(nameof(typeof(this)))")
  lvl = clocklevel(this, net)
  (inv ? !lvl : lvl) & gate()
end

_substthis(ex, sub) = ex === :this ? sub :
  ex isa Expr ? Expr(ex.head, (_substthis(a, sub) for a in ex.args)...) : ex

function _portattrs(T::Type, name::Symbol)
  p = port(T, name)
  if p === nothing
    _portsuffix() || return (name, false)
    _isclock(T, name) && !(name in _internalclocks(T)) && return (Symbol(name, "_i"), false)
    _isclockout(T, name) && return (Symbol(name, "_o"), false)
    return (name, false)
  end
  al = get(p.attrs, :active, :high) === :low
  haskey(p.attrs, :verilog) && return (Symbol(p.attrs[:verilog]), al)
  # a pin asserted low is bridged by an inverter, so it cannot share the name of
  # the value behind it: with the suffixes off it still takes `_n`
  _portsuffix() || return (al ? Symbol(name, "_n") : name, al)
  (Symbol(name, "_", al ? "n" : "", p.dir === :in ? "i" : p.dir === :out ? "o" : "io"), al)
end

# a clock as the module's Verilog refers to it: the port's pin name, or the net
_clockref(T::Type, c::Symbol) = string(_portattrs(T, c)[1])

function _fieldinfo(T::Type, default=T())
  info = []
  for (i, f) in enumerate(fieldnames(T))
    f === INPUTS && continue
    FT = fieldtype(T, i)
    if isblackbox(FT)
      push!(info, (name=f, kind=:blackbox, T=FT))
    elseif FT <: QuartzModule
      push!(info, (name=f, kind=:submodule, T=FT))
    elseif FT <: Pad
      push!(info, (name=f, kind=:pad, width=padwidth(FT), pull=getfield(default, f).pull,
                   activelow=getfield(default, f).activelow, vname=_portattrs(T, f)[1]))
    elseif FT <: Pipeline
      push!(info, (name=f, kind=:pipeline, K=FT.parameters[1], T=FT.parameters[2]))
    elseif FT <: Multicycle
      ET = FT.parameters[2]
      push!(info, (name=f, kind=:multicycle, K=FT.parameters[1], T=ET, width=bitwidth(ET), signed=issigned(ET)))
    elseif FT <: MetaGuard
      push!(info, (name=f, kind=:metaguard, K=FT.parameters[1]))
    elseif FT === Edge
      push!(info, (name=f, kind=:edge))
    elseif FT == Bool || FT <: HWInt || FT <: Base.BitInteger
      push!(info, (name=f, kind=:reg, width=bitwidth(FT), signed=issigned(FT)))
    else
      error("field $f has type $FT, which is not a hardware type")
    end
  end
  info
end

function _porttype(t, mod, wherevals)
  t === nothing && error("every port needs a hardware type annotation")
  binds = Expr(:block, (:($p = $v) for (p, v) in wherevals)...)
  Core.eval(mod, Expr(:let, binds, t))
end

function _intypeexpr(T::Type, name::Symbol)
  p = port(T, name)
  p === nothing && error("$name is not a declared input of $(nameof(T))")
  p.typeexpr
end

# the width and signedness of an input, for the instantiation the block runs in
_inputinfo(T::Type, def::BlockDef, name::Symbol) =
  _portinfo(_porttype(_intypeexpr(T, name), def.mod, tracewheres(def, T)))

# `Int` and `UInt` are BitIntegers, so the width check has to come first: their
# width is the machine's, which is not a fact about the hardware
function _portinfo(t::Type)
  t == Bool && return (1, false)
  t <: HWInt && return (bitwidth(t), issigned(t))
  t in (Int, UInt, Integer) && error("port type $t has no fixed width; use Bits{N}/SBits{N}")
  t <: Base.BitInteger && return (bitwidth(t), issigned(t))
  error("port type $t is not a hardware type")
end

# the port of that name, or nothing
_finfoport(ports, name) = (i = findfirst(p -> p.name == name, ports); i === nothing ? nothing : ports[i])

function _ports(T::Type, default=T())
  defs = blocks(T)
  fields = _fieldinfo(T, default)
  combfields = Set{Symbol}(f for d in defs if d.kind == :comb for f in d.owned)
  internal = _internalclocks(T)
  ports = Port[]
  for c in _clocksof(T)
    push!(ports, Port(c, :input, 1, false, true, _portattrs(T, c)[1]))
  end
  for def in defs
    for an in def.inputs
      W, sg = _inputinfo(T, def, an)
      vn, al = _portattrs(T, an)
      push!(ports, Port(an, :input, W, sg, true, vn, al))
    end
  end
  for def in defs, c in def.clockouts
    push!(ports, Port(c.name, :clockout, 1, false, true, _portattrs(T, c.name)[1]))
  end
  append!(ports, _padports(T, default))
  append!(ports, _clockoutports(T, default))
  for f in fields
    isport(T, f.name, :out) || continue
    f.kind == :reg || error("output field $(f.name) must be a plain register")
    vn, al = _portattrs(T, f.name)
    push!(ports, Port(f.name, :output, f.width, f.signed,
                      f.name in combfields || al || vn !== f.name, vn, al))
  end
  seen = Dict{Symbol,Port}()
  out = Port[]
  for p in ports
    q = get(seen, p.name, nothing)
    if q === nothing
      seen[p.name] = p
      push!(out, p)
    elseif q.width != p.width || q.signed != p.signed || q.dir != p.dir
      error("port $(p.name) of $(nameof(T)) is declared twice with different types")
    end
  end
  out
end

# a pad belongs to the module that drives it and surfaces, under the same name, as
# an inout port of every module above it
function _padports(T::Type, default=T())
  ports = Port[]
  for f in _fieldinfo(T, default)
    if f.kind == :pad
      vn, al = _portattrs(T, f.name)
      push!(ports, Port(f.name, :inout, f.width, false, true, vn, al))
    elseif f.kind == :submodule
      for p in _padports(f.T)
        q = _finfoport(ports, p.name)
        if q === nothing
          push!(ports, p)
        else
          # the same name is the same net; several modules may sit on it
          q.width == p.width ||
            error("pad $(p.name) is $(q.width) bits here and $(p.width) bits in submodule $(f.name)")
          # a pad propagates up the hierarchy by name, so one pin cannot be called
          # two things on the way
          q.vname === p.vname ||
            error("pad $(p.name) is called $(q.vname) here and $(p.vname) in submodule " *
                  "$(f.name); a pad is one pin and takes one Verilog name")
        end
      end
    end
  end
  ports
end

# a pad net of a name already seen is the same net, and the two declarations of it
# have to agree
function _addpad!(out, p)
  q = findfirst(x -> x.name == p.name, out)
  q === nothing && return push!(out, p)
  (out[q].width == p.width && out[q].pull == p.pull) ||
    error("pad $(p.name) is declared with a different width or pull in two modules")
  out
end

# Clock nets a black box in this module produces: internal wires, not input ports.
# In declaration order, not the order a Dict happens to iterate in -- the emitted
# Verilog has to be the same every time it is generated.
function _internalclocks(T::Type)
  nets = Symbol[]
  for (f, FT) in zip(fieldnames(T), fieldtypes(T))
    isblackbox(FT) || continue
    binds = _clockbind(T, f)
    for p in blackbox(FT).ports
      net = p.dir === :clockout ? _boundnet(binds, p.name) : nothing
      net === nothing || net in nets || push!(nets, net)
    end
  end
  nets
end

# every pad net in the tree, once per name: a pad several modules declare is one net
function _allpads(T::Type)
  out = NamedTuple{(:name, :width, :pull, :vname),Tuple{Symbol,Int,Symbol,Symbol}}[]
  default = T()
  for (f, FT) in zip(fieldnames(T), fieldtypes(T))
    if FT <: Pad
      _addpad!(out, (name=f, width=padwidth(FT), pull=getfield(default, f).pull,
                     vname=_portattrs(T, f)[1]))
    elseif FT <: QuartzModule && !isblackbox(FT)
      for p in _allpads(FT)
        _addpad!(out, p)
      end
    end
  end
  out
end

# the value on a pad net: everything the design drives on it, resolved against
# what the outside drives and the net's pull
function netpad(m, name::Symbol, N::Int, pull::Symbol, ext)
  nv, nm = get(_netdrives(m), name, (UInt128(0), UInt128(0)))
  e, em = _extpair(Pad{N}, ext)
  Pad{N}(Bits{N}(nv), Bits{N}(nm), e, em, pull)
end

# a forwarded clock, like a pad, belongs to a pin: it surfaces on every module
# above the one that declares it -- until a module absorbs it into a pad of the
# same name, whose drive then owns the pin
function _clockoutports(T::Type, default=T())
  ports = Port[]
  pads = Set{Symbol}(f for (f, FT) in zip(fieldnames(T), fieldtypes(T)) if FT <: Pad)
  for f in _fieldinfo(T, default)
    f.kind == :submodule || continue
    for def in blocks(f.T), c in def.clockouts
      c.name in pads && continue
      push!(ports, Port(c.name, :clockout, 1, false, true, _portattrs(f.T, c.name)[1]))
    end
    for q in _clockoutports(f.T)
      q.name in pads || push!(ports, q)
    end
  end
  ports
end

_portdefaults(T::Type) =
  Dict{Symbol,Any}(p.name => _indefault(T, Val(p.name)) for p in interface(T)
                   if p.dir === :in && p.default !== NOPORTDEFAULT)

_clocksof(T::Type) = (internal = _internalclocks(T); [c for c in _clocks(T) if !(c in internal)])
