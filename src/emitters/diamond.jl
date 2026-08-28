# A Lattice Diamond workspace: everything Diamond needs to take the design to a
# bitstream, laid out the way the tool expects and driven by a script, so a build
# is `make` and not a session in the GUI. The project file lists the sources, the
# strategy is Diamond's default, and the constraint file comes from the board.

function _diamond(dir::AbstractString, T::Type{<:QuartzModule}, f::Diamond)
  b = f.board
  b === nothing && throw(ArgumentError("Diamond needs a board: Diamond(board)"))
  isempty(b.device) &&
    error("$(b.name) names no device; Diamond needs the part number, such as LCMXO2-7000HE-4TG144I")
  bad = problems(b, T)
  isempty(bad) || error("$(b.name) and $(nameof(T)) do not agree:\n  " * join(bad, "\n  "))
  name = something(f.name, nameof(T))
  mkpath(joinpath(dir, "src"))
  write(joinpath(dir, "src", "$name.v"), T, Verilog(; name))
  write(joinpath(dir, "$(b.name).lpf"), T, LPF(b))
  sources = ["src/$name.v"]
  supplied = Symbol[]
  for v in f.vendor
    isfile(v) || error("no such vendor netlist: $v")
    cp(v, joinpath(dir, "src", basename(v)); force=true)
    push!(sources, "src/" * basename(v))
    append!(supplied, _modulesin(read(v, String)))
  end
  for BB in _blackboxes(T)
    vname = blackbox(BB).verilogname
    vname in supplied && continue
    file = "src/$vname.v"
    @warn "$vname has no netlist in the workspace; put the vendor's at $(joinpath(dir, file))"
    push!(sources, file)
  end
  write(joinpath(dir, "$name.ldf"), _ldf(name, b, f.implementation, sources))
  cp(joinpath(@__DIR__, "diamond.sty"), joinpath(dir, "$name.sty"); force=true)
  write(joinpath(dir, "build.sh"), _buildsh(name, b, f.implementation))
  chmod(joinpath(dir, "build.sh"), 0o755)
  write(joinpath(dir, "Makefile"), _makefile(name, b, f.implementation))
  dir
end

# the modules a Verilog file defines, so a netlist is matched to its black box by
# what it holds and not by what it is called
_modulesin(text::AbstractString) = [Symbol(m.captures[1]) for m in eachmatch(r"^\s*module\s+(\w+)"m, text)]

# every black box the design instantiates, each once
function _blackboxes(T::Type, acc=Type[])
  for FT in fieldtypes(T)
    FT <: QuartzModule || continue
    if isblackbox(FT)
      FT in acc || push!(acc, FT)
    else
      _blackboxes(FT, acc)
    end
  end
  acc
end

function _ldf(name, b::Board, impl, sources)
  io = IOBuffer()
  println(io, "<?xml version=\"1.0\" encoding=\"UTF-8\"?>")
  println(io, "<BaliProject version=\"3.2\" title=\"$name\" device=\"$(b.device)\" default_implementation=\"$impl\">")
  println(io, "    <Options/>")
  println(io, "    <Implementation title=\"$impl\" dir=\"$impl\" description=\"$impl\" synthesis=\"synplify\" default_strategy=\"Strategy1\">")
  println(io, "        <Options def_top=\"$name\" top=\"$name\"/>")
  for (i, s) in enumerate(sources)
    println(io, "        <Source name=\"$s\" type=\"Verilog\" type_short=\"Verilog\">")
    println(io, i == 1 ? "            <Options top_module=\"$name\"/>" : "            <Options/>")
    println(io, "        </Source>")
  end
  println(io, "        <Source name=\"$(b.name).lpf\" type=\"Logic Preference\" type_short=\"LPF\">")
  println(io, "            <Options/>")
  println(io, "        </Source>")
  println(io, "    </Implementation>")
  println(io, "    <Strategy name=\"Strategy1\" file=\"$name.sty\"/>")
  println(io, "</BaliProject>")
  String(take!(io))
end

# a MachXO part boots from its own flash, which takes a JEDEC file; the others
# take the bitstream
_jedec(b::Board) = startswith(uppercase(b.device), "LCMXO")

function _buildsh(name, b::Board, impl)
  steps = ["Synthesis", "Translate", "Map", "PAR"]
  io = IOBuffer()
  println(io, "#!/bin/bash")
  println(io, "# Runs Lattice Diamond on this workspace, from synthesis to the bitstream. DIAMOND_BIN")
  println(io, "# points at Diamond's bin/lin64 directory where it is not at the default.")
  println(io, "set -e")
  println(io, "export bindir=\${DIAMOND_BIN:-/usr/local/lattice/bin/lin64}")
  println(io, "source \"\$bindir/diamond_env\"")
  println(io, "pnmainc <<EOF")
  println(io, "prj_project open \"$name.ldf\"")
  for s in steps
    println(io, "prj_run $s -impl $impl")
  end
  println(io, "prj_run Export -impl $impl -task Bitgen")
  _jedec(b) && println(io, "prj_run Export -impl $impl -task Jedecgen")
  println(io, "EOF")
  String(take!(io))
end

function _makefile(name, b::Board, impl)
  target = "$impl/$(name)_$impl." * (_jedec(b) ? "jed" : "bit")
  io = IOBuffer()
  println(io, "# Builds $name for $(b.name) with Lattice Diamond: `make` for the bitstream, `make clean` to start over.")
  println(io, "all: $target")
  println(io)
  println(io, "$target: src/*.v $(b.name).lpf $name.ldf $name.sty build.sh")
  println(io, "\t./build.sh")
  println(io)
  println(io, "clean:")
  println(io, "\trm -rf $impl")
  println(io)
  println(io, ".PHONY: all clean")
  String(take!(io))
end
