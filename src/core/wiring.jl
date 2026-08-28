# What a bench connects to what, with the arrow the design itself uses: the left
# side is an input of a model (or of the design), the right side a value computed
# from the others' outputs. A pad of the design names its net: wiring a value to it
# is what the outside drives on the net, and reading it is the level the net
# resolves to -- the design's drive, the outside's, and the pull.
#
#   @wiring begin
#     dut.usb_rxf ← !ft.rxf_no
#     ft.rd_ni    ← !dut.usb1.usb_rd
#     dut.sda     ← drive(0, rtc.pull)     # the slave pulls the line low, or lets go
#     rtc.sda     ← dut.sda                # and reads what the net settles to
#   end
#
# An input the block does not mention is undriven: a pad then reads its pull, a
# port its declared default. A net with no pull that nobody drives reads zero.

"""
    Wiring

What a `@wiring` block compiles to: the function that computes each model's
inputs, and which inputs of the design it drives -- so a stimulus knows what is
left for it to drive. `Wiring()` is the empty wiring, with nothing connected,
and is what a bench or simulation uses when no `wiring` is given.
"""
struct Wiring{F,K}
  f::F
  driven::NTuple{K,Symbol}
end
(w::Wiring)(dut, stubs) = w.f(dut, stubs)

Wiring() = Wiring((dut, stubs) -> NamedTuple(), ())

"""
    @wiring begin ... end

Says what a bench connects to what, with the same arrow a block uses: the left side
is an input of a model (or of the design), the right side a value computed from the
others' outputs. A pad of the design names its net, so writing to it is what the
outside drives and reading it is what the net settles to.

```julia
@wiring begin
  dut.rx ← uart.tx
  dut.sda ← drive(0, rtc.pull)
end
```
"""
macro wiring(block)
  esc(_wiring(block))
end

function _wiring(block)
  block isa Expr && block.head == :block || error("@wiring: expected a begin ... end block")
  conns = Dict{Symbol,Vector{Pair{Symbol,Any}}}()
  order = Symbol[]
  drives = Dict{Symbol,Any}()
  items = Tuple{Symbol,Symbol,Any}[]
  for item in block.args
    item isa LineNumberNode && continue
    item isa Expr && item.head == :call && length(item.args) == 3 && item.args[1] in WRITEOPS ||
      error("@wiring: expected `model.port ← value`, got $item")
    m, p = _wirelhs(item.args[2])
    push!(items, (m, p, item.args[3]))
    m === :dut && (drives[p] = item.args[3])
  end
  dut = gensym(:dut); stubs = gensym(:stubs)
  for (m, p, v) in items
    m in order || push!(order, m)
    val = _wireval(v, dut, stubs, drives)
    push!(get!(conns, m, Pair{Symbol,Any}[]),
          p => (m === :dut ? :($QuartzHDL._dutinput($dut, Val($(QuoteNode(p))), $val)) : val))
  end
  body = isempty(order) ? :(NamedTuple()) :
         Expr(:tuple, (Expr(:(=), m, Expr(:tuple, (Expr(:(=), p, v) for (p, v) in conns[m])...))
                       for m in order)...)
  driven = Tuple(unique(p for (m, p, _) in items if m === :dut))
  :($QuartzHDL.Wiring(($dut, $stubs) -> $body, $driven))
end

function _wirelhs(ex)
  ex isa Expr && ex.head == :. && ex.args[1] isa Symbol && ex.args[2] isa QuoteNode ||
    error("@wiring: expected `model.port`, got $ex")
  (ex.args[1], ex.args[2].value)
end

# `dut` and each stub name resolve to the model; `dut.x` for a pad `x` is the net it
# resolves to, with whatever this block drives on it; everything else is ordinary Julia
function _wireval(ex, dut, stubs, drives)
  ex isa Symbol && return ex === :dut ? dut : ex
  ex isa Expr || return ex
  rec(a) = _wireval(a, dut, stubs, drives)
  if ex.head == :. && ex.args[1] === :dut && ex.args[2] isa QuoteNode
    p = ex.args[2].value
    drv = haskey(drives, p) ? rec(drives[p]) : :missing
    return :($QuartzHDL._dutread($dut, Val($(QuoteNode(p))), $drv))
  end
  ex.head == :. && ex.args[1] isa Symbol && return Expr(:., Expr(:., stubs, QuoteNode(ex.args[1])), ex.args[2])
  ex.head == :. && return Expr(:., rec(ex.args[1]), ex.args[2])
  ex.head == :quote && return ex
  Expr(ex.head, (a isa Expr && a.head == :(=) && a.args[1] isa Symbol ?
                 Expr(:(=), a.args[1], rec(a.args[2])) : rec(a) for a in ex.args)...)
end

# a value wired to the design: an input as it is, a pad as the outside's drive on
# it. Which of the two, and how wide, is a fact of the type, found when this compiles.
_dutinput(dut::D, v::Val{name}, x) where {D,name} = _dutinput(_padtype(D, v), name, x)
_dutinput(::Nothing, name, x) = x
_dutinput(::Type{Pad{N}}, name, x) where N = _extdrive(Pad{N}, x)

# a value read from the design: an output as it is, a pad as the net it resolves to
_dutread(dut::D, v::Val, drv) where D = _dutread(_padtype(D, v), dut, v, drv)
_dutread(::Nothing, dut, ::Val{name}, drv) where name = getproperty(dut, name)
_dutread(::Type{Pad{N}}, dut, v::Val, drv) where N = netlevel(dut, v, drv)

@generated function _padtype(::Type{T}, ::Val{name}) where {T,name}
  find(T) = begin
    for (f, FT) in zip(fieldnames(T), fieldtypes(T))
      FT <: Pad && f === name && return FT
      if FT <: QuartzModule && !isblackbox(FT)
        r = find(FT)
        r === nothing || return r
      end
    end
    nothing
  end
  find(T)
end

# what the outside puts on a pad, as the (value, enable) pair a step takes
_extdrive(::Type{Pad{N}}, drv) where N = _padfold(Bits{N}, _aspadvalue(drv))
_extdrive(::Type{Pad{N}}, ::Missing) where N = _padfold(Bits{N}, release())

"""
    netlevel(dut, pad, drive)

What a shared net reads: what the design drives on `pad`, resolved against what the
outside drives, with the pad's pull deciding any bit neither of them holds. A net
with no pull reads zero where nobody holds it.
"""
netlevel(dut, name::Symbol, drv) = netlevel(dut, Val(name), drv)
function netlevel(dut, v::Val, drv)
  val, oe = padnet(dut, v)
  N = bitwidth(val)
  ev, en = _extdrive(Pad{N}, drv)
  pull = _padvalue(dut, v).pull
  if pull === :none
    r = (val.val & oe.val) | (ev.val & en.val)
    return N == 1 ? isodd(r) : Bits{N}(r)
  end
  Pad{N}(val, oe, ev, en, pull)[]
end
