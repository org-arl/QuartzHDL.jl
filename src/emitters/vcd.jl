# A capture as a value change dump. Time is real: the unit is chosen so a slot of
# the clock grid is at least 100 units. A clock is a square wave, falling half a
# slot after it rose. An encoded register is written twice, as its bits and as a
# string with the state's name.

Base.write(io::IO, s::Simulation, f::VCD) = write(io, s.capture, f)

const VCDUNITS = (1//1 => "s", 1//10^3 => "ms", 1//10^6 => "us", 1//10^9 => "ns", 1//10^12 => "ps", 1//10^15 => "fs")

function _vcdunit(grid::Rational{Int})
  for (u, name) in VCDUNITS
    grid / u ≥ 100 && return (u, name)
  end
  last(VCDUNITS)
end

Base.write(io::IO, r::Capture, ::VCD) = (buf = IOBuffer(); _vcd(buf, r); write(io, take!(buf)))

function _vcd(io::IO, r::Capture)
  unit, uname = _vcdunit(r.grid)
  sigs = r.signals
  ids = _vcdids(2length(sigs))
  println(io, "\$timescale 1", uname, " \$end")
  opened = String[]
  for (k, s) in enumerate(sigs)
    s.net.kind === :stub && continue
    scopes, name = _vcdpath(s)
    _scopes!(io, opened, scopes)
    println(io, "\$var wire ", s.net.width, " ", ids[2k-1], " ", name, " \$end")
    s.net.kind === :fsm && println(io, "\$var string 1 ", ids[2k], " ", name, "_name \$end")
  end
  _scopes!(io, opened, String[])
  println(io, "\$enddefinitions \$end")
  # (time in units, half of the slot, signal, sample index); the sort below puts the
  # dump in time order and relies on that field order
  evs = Tuple{Int,Int,Int,Int}[]
  for (k, s) in enumerate(sigs)
    s.net.kind === :stub && continue
    for i in eachindex(s.slots)
      t = s.slots[i]
      push!(evs, (_vcdtime(t, r.grid, unit), 0, k, i))
      s.net.kind === :clock && push!(evs, (_vcdtime(t + 1//2, r.grid, unit), 1, k, i))
    end
  end
  sort!(evs)
  t = -1
  for (ti, half, k, i) in evs
    ti == t || (println(io, "#", ti); t = ti)
    s = sigs[k]
    n = s.net
    if n.kind === :clock
      println(io, half == 0 ? "1" : "0", ids[2k-1])
    elseif n.width == 1 && n.kind !== :pad
      println(io, isodd(s.vals[i]) ? "1" : "0", ids[2k-1])
    else
      println(io, "b", _bitchars(s, i), " ", ids[2k-1])
    end
    if n.kind === :fsm
      v = _value(s, i)
      println(io, "s", v isa Symbol ? v : "?", " ", ids[2k])
    end
  end
  println(io, "#", _vcdtime(r.stop[] + 1, r.grid, unit))
  nothing
end

_vcdtime(slot, grid, unit) = round(Int, slot * grid / unit)
_vcdids(n) = [String(Char.('!' .+ digits(k; base=94))) for k in 0:n-1]

function _bitchars(s::Signal, i::Int)
  n = s.net
  v, m = s.vals[i], s.mask[i]
  c = n.kind === :pad ? 'z' : 'x'
  String(map(j -> isodd(m >> j) ? c : isodd(v >> j) ? '1' : '0', n.width-1:-1:0))
end

# where a signal sits in the VCD hierarchy: the scopes above it, then its name
function _vcdpath(s::Signal)
  parts = split(s.net.path, ".")
  scopes = String[String(p) for p in parts[1:end-1]]
  s.net.indut && pushfirst!(scopes, "dut")
  (scopes, replace(String(parts[end]), "." => "_"))
end

function _scopes!(io, opened, scopes)
  common = 0
  while common < min(length(scopes), length(opened)) && scopes[common+1] == opened[common+1]
    common += 1
  end
  for _ in common+1:length(opened)
    println(io, "\$upscope \$end")
  end
  for sc in scopes[common+1:end]
    println(io, "\$scope module ", sc, " \$end")
  end
  resize!(opened, length(scopes))
  opened[common+1:end] = scopes[common+1:end]
  nothing
end
