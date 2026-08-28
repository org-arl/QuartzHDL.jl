# Co-simulation: drive the same per-cycle inputs into the Julia model (via step) and
# into the Verilog generated from it (via iverilog/vvp), and compare every output
# after every clock.

# one field of the stimulus word, or one output compared after every clock
struct CoPort
  name::Symbol
  width::Int
  signed::Bool
end

"""
    cosim(T, stimulus; kwargs...)

Run the Julia model of module `T` and the Verilog generated from it on the same
per-cycle inputs, and compare every output after every clock.

`stimulus` is a vector of NamedTuples, one per cycle, with one entry per input of
the module and per pad the outside world drives. A pad entry is a value, or a
`(value, enable)` pair for driving part of a bus.

  * `clocks` gives the edges per cycle of each clock of a multi-clock module,
    e.g. `clocks = (clk_i = 4, clk_slow_i = 1)`: one stimulus entry is one slot,
    `clk_i` is pulsed in every slot, `clk_slow_i` in every fourth. Each count
    must divide the largest; clocks scheduled in the same slot are pulsed in the
    order given.
  * `reference` co-simulates against a hand-written Verilog file instead of the
    generated one -- the way a ported design is checked against its original.
  * `ref_init` puts that original in the state the struct defaults put the Julia
    model in, as hierarchical assignments (`"tx_data64" => "64'd0"`), since its
    registers power up undefined.
  * `scale` divides a black box's clock faster than the board would, so a few
    thousand cycles cover many periods of a slow domain.
  * `debug` emits the design's log statements as `\$display` in the Verilog.
  * `name`, `dir`, `suffix`, `extra_sources` and `timeout` name the module, say
    where the files go, put `_i`/`_o` on the ports, add Verilog sources to
    compile, and bound the run in seconds.

Returns `(; ok, mismatches, julia, verilog, dir)`: whether the two agree, the
differing cycles as `(cycle, julia line, verilog line)`, the two sets of output
lines, and the directory the files were written to.

```julia
r = cosim(Blinker, [(en_i = true,) for _ in 1:100])
r.ok || println(r.mismatches[1])
```
"""
cosim(T::Type, stimulus::AbstractVector; scale=NamedTuple(), tool::Tool=Icarus(), kwargs...) =
  withclockscale(scale) do
    _cosim(tool, T, stimulus; kwargs...)
  end

function _cosim(::Icarus, T::Type, stimulus::AbstractVector; name=nameof(T), dir=mktempdir(),
    timeout=300, clocks=nothing, extra_sources=String[], reference=nothing,
    ref_init=Pair{String,String}[], suffix=_portsuffix(), debug=false
)
  withverilogdebug(debug) do
    withportsuffix(suffix) do
      _cosim_suffixed(T, stimulus; name, dir, timeout, clocks, extra_sources, reference, ref_init)
    end
  end
end

function _cosim_suffixed(T::Type, stimulus::AbstractVector; name, dir, timeout, clocks,
    extra_sources, reference, ref_init
)
  clks, every, internal, L = clockschedule(T, clocks)
  ports = _coports(T)
  pads = _allpads(T)
  outs = [CoPort(fn, bitwidth(fieldtype(T, fn)), issigned(fieldtype(T, fn))) for fn in outputs(T)]
  jl = _juliarun(T, stimulus, clks, every, internal, L, pads, outs)
  vfile = reference === nothing ? joinpath(dir, "$name.v") : reference
  reference === nothing && write(vfile, T, Verilog(; name, inits=:all))
  stimfile = joinpath(dir, "stim.hex")
  stimports = _stimports(ports, pads)
  _writestim(stimfile, stimulus, T, ports, pads, stimports)
  tbfile = joinpath(dir, "tb.v")
  write(tbfile, _testbench(T, name, length(stimulus), clks, every, internal,
                           ports, pads, outs, stimports, stimfile, ref_init))
  vlines = _runsim(dir, tbfile, vfile, extra_sources, timeout)
  mism = [(i, jl[i], vlines[i]) for i in 1:min(length(jl), length(vlines)) if jl[i] != vlines[i]]
  (; ok=isempty(mism) && length(jl) == length(vlines), mismatches=mism, julia=jl, verilog=vlines, dir)
end

### helpers

# every input any block of the module takes, once, in the order they are declared
function _coports(T::Type)
  ports = CoPort[]
  for d in blocks(T), an in d.inputs
    any(p -> p.name == an, ports) && continue
    push!(ports, CoPort(an, _inputinfo(T, d, an)...))
  end
  ports
end

# the stimulus word: the inputs, then the value and enable the outside drives on
# each pad
function _stimports(ports, pads)
  stimports = copy(ports)
  for p in pads
    push!(stimports, CoPort(Symbol(p.name, "_ext"), p.width, false))
    push!(stimports, CoPort(Symbol(p.name, "_exten"), p.width, false))
  end
  stimports
end

_stimwidth(stimports) = sum(p.width for p in stimports; init=0)

# the model's outputs, one line per cycle, in the form the testbench prints them
function _juliarun(T::Type, stimulus, clks, every, internal, L, pads, outs)
  m = T()
  jl = String[]
  for (i, s) in enumerate(stimulus)
    slot = (i - 1) % L
    # a pad's value belongs to the cycle: what the module drives entering the cycle,
    # resolved against what the outside drives during it -- sampled before the edge
    settled = _presettle(m, s)                  # this cycle's inputs, pre-edge state
    padstr = [padchars(netpad(settled, p.name, p.width, p.pull,
                              haskey(s, p.name) ? s[p.name] : missing)) for p in pads]
    m = stepslot(m, clks, every, internal, slot; s...)
    push!(jl, join(vcat([string(_toint(getfield(m, o.name))) for o in outs], padstr), " "))
  end
  jl
end

function _writestim(path, stimulus, T::Type, ports, pads, stimports)
  defaults = _portdefaults(T)
  portval(s, p) = haskey(s, p) ? s[p] :
                  haskey(defaults, p) ? defaults[p] : error("stimulus is missing input $p")
  W = _stimwidth(stimports)
  open(path, "w") do io
    for s in stimulus
      v = BigInt(0)
      for p in ports
        v = (v << p.width) | mod(BigInt(_toint(portval(s, p.name))), BigInt(1) << p.width)
      end
      for p in pads
        ev, en = _padstim(s, p)
        v = (v << p.width) | mod(ev, BigInt(1) << p.width)
        v = (v << p.width) | mod(en, BigInt(1) << p.width)
      end
      println(io, string(v; base=16, pad=cld(W, 4)))
    end
  end
end

# what the outside drives on a pad this cycle: a value with every bit enabled, a
# (value, enable) pair as given, or nothing at all
function _padstim(s, p)
  pv = haskey(s, p.name) ? s[p.name] : missing
  pv === missing && return (BigInt(0), BigInt(0))
  pv isa Tuple && return (BigInt(_toint(pv[1])), BigInt(_toint(pv[2])))
  (BigInt(_toint(pv)), (BigInt(1) << p.width) - 1)
end

function _testbench(T::Type, name, N::Int, clks, every, internal, ports, pads, outs,
    stimports, stimfile, ref_init
)
  # an active-low pin carries the inverted value; the model's value always means
  # asserted, so the testbench inverts where it meets the design
  vname(n) = _portattrs(T, n)[1]
  activelow(n) = _portattrs(T, n)[2]
  W = _stimwidth(stimports)
  tb = IOBuffer()
  println(tb, "`timescale 1ns/1ns\nmodule tb();")
  for c in clks
    c in internal || println(tb, "reg $c = 0;")   # a clock the design makes itself
  end
  # the bench's own names are prefixed, so a port may be called anything
  W > 0 && println(tb, "reg [$(W-1):0] qz_stim [0:$(N-1)];\nreg [$(W-1):0] qz_cur = 0;")
  lo = W
  conn = String[]
  for p in stimports
    lo -= p.width
    println(tb, "wire $(p.signed ? "signed " : "")" *
                "$(p.width == 1 ? "" : "[$(p.width-1):0] ")$(p.name) = " *
                "qz_cur[$(lo + p.width - 1):$lo];")
    any(x -> x.name == p.name, ports) &&
      push!(conn, ".$(vname(p.name))($(activelow(p.name) ? "~" : "")$(p.name))")
  end
  for o in outs
    rng = o.width == 1 ? "" : "[$(o.width-1):0] "
    if activelow(o.name)
      println(tb, "wire $rng$(o.name)_pin;")
      println(tb, "wire $(o.signed ? "signed " : "")$rng$(o.name) = ~$(o.name)_pin;")
      push!(conn, ".$(vname(o.name))($(o.name)_pin)")
    else
      println(tb, "wire $(o.signed ? "signed " : "")$rng$(o.name);")
      push!(conn, ".$(vname(o.name))($(o.name))")
    end
  end
  for p in pads
    println(tb, "wire $(p.width == 1 ? "" : "[$(p.width-1):0] ")$(p.name);")
    for i in 0:p.width-1
      sel = p.width == 1 ? "" : "[$i]"
      println(tb, "assign $(p.name)$sel = $(p.name)_exten$sel ? $(p.name)_ext$sel : 1'bz;")
      p.pull == :pullup && println(tb, "pullup($(p.name)$sel);")
      p.pull == :pulldown && println(tb, "pulldown($(p.name)$sel);")
    end
    println(tb, "reg $(p.width == 1 ? "" : "[$(p.width-1):0] ")$(p.name)_s;")
    push!(conn, ".$(p.vname)($(p.name))")
  end
  println(tb, "$name dut($(join(vcat([".$(vname(c))($c)" for c in clks if !(c in internal)], conn), ", ")));")
  println(tb, "integer qz_n;\ninitial begin")
  for (sig, v) in ref_init
    println(tb, "  dut.$sig = $v;")
  end
  W > 0 && println(tb, "  \$readmemh(\"$stimfile\", qz_stim);")
  println(tb, "  for (qz_n = 0; qz_n < $N; qz_n = qz_n + 1) begin")
  W > 0 && println(tb, "    qz_cur = qz_stim[qz_n];")
  println(tb, "    #10;")
  for p in pads
    println(tb, "    $(p.name)_s = $(p.name);")
  end
  for (c, ev) in zip(clks, every)
    c in internal && continue
    ind = ev == 1 ? "    " : "      "
    ev == 1 || println(tb, "    if (qz_n % $ev == 0) begin")
    println(tb, ind, "#10 $c = 1;")
    println(tb, ind, "#10 $c = 0;")
    ev == 1 || println(tb, "    end")
  end
  fmt = join(vcat(["%0d" for _ in outs], ["%b" for _ in pads]), " ")
  args = join(vcat([string(o.name) for o in outs], ["$(p.name)_s" for p in pads]), ", ")
  println(tb, "    #10 \$display(\"$fmt\"$(isempty(args) ? "" : ", " * args));\n  end\n  \$finish;\nend\nendmodule")
  String(take!(tb))
end

# compile and run, under a watchdog, and keep what the design printed
function _runsim(dir, tbfile, vfile, extra_sources, timeout)
  vvp = joinpath(dir, "tb.vvp")
  run(`iverilog -g2012 -o $vvp $tbfile $vfile $extra_sources`)
  outfile = joinpath(dir, "out.txt")
  p = run(pipeline(`vvp $vvp`, stdout=outfile); wait=false)
  t0 = time()
  while process_running(p)
    if time() - t0 > timeout
      kill(p)
      error("watchdog: vvp exceeded $timeout s")
    end
    sleep(0.1)
  end
  filter(l -> !occursin("finish", l) && !occursin("VCD", l), readlines(outfile))
end
