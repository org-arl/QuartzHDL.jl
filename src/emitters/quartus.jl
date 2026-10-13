# A Quartus Prime workspace: everything Quartus needs to take the design to its
# programming files, laid out the way the tool expects and driven by a script, so a
# build is `make` and not a session in the GUI. Quartus names the settings file
# after the project's revision, so the project's own settings and the board's
# assignments share one file named for the design; the timing constraints keep the
# board's name. The build ends with the files openFPGALoader sends to the board,
# since Quartus's own programmer runs only where Quartus does.

function _quartus(dir::AbstractString, T::Type{<:QuartzModule}, f::Quartus)
  b = f.board
  b === nothing && throw(ArgumentError("Quartus needs a board: Quartus(board)"))
  family = _checkedquartus(b, T)
  name = something(f.name, nameof(T))
  mkpath(joinpath(dir, "src"))
  write(joinpath(dir, "src", "$name.v"), T, Verilog(; name))
  sources = vcat("src/$name.v", _netlists(dir, T, f.vendor))
  open(joinpath(dir, "$name.qsf"), "w") do io
    _qsfproject(io, name, b, family, sources)
    _qsf(io, T, b)
  end
  open(io -> _sdc(io, T, b, f.overconstrain), joinpath(dir, "$(b.name).sdc"), "w")
  write(joinpath(dir, "$name.qpf"), "PROJECT_REVISION = \"$name\"\n")
  write(joinpath(dir, "build.sh"), _quartusbuildsh(name))
  chmod(joinpath(dir, "build.sh"), 0o755)
  write(joinpath(dir, "Makefile"), _quartusmakefile(name, b, family, f.cable))
  dir
end

# a MAX 10 configures itself from its own flash, which the assembler writes a
# programming file for once the settings say the flash holds one image
_internalflash(family) = family == "MAX 10"

# the project's part of the settings: the top, the sources, the constraints, and
# what becomes of the pins the design leaves alone
function _qsfproject(io::IO, name, b::Board, family, sources)
  println(io, "# $name on $(b.name), set up by QuartzHDL; the board's assignments follow the project's settings")
  println(io, "set_global_assignment -name TOP_LEVEL_ENTITY $name")
  println(io, "set_global_assignment -name PROJECT_OUTPUT_DIRECTORY output_files")
  for s in sources
    println(io, "set_global_assignment -name VERILOG_FILE $s")
  end
  println(io, "set_global_assignment -name SDC_FILE $(b.name).sdc")
  println(io, "set_global_assignment -name RESERVE_ALL_UNUSED_PINS_WEAK_PULLUP \"AS INPUT TRI-STATED WITH WEAK PULL-UP\"")
  println(io, "set_global_assignment -name NUM_PARALLEL_PROCESSORS ALL")
  _internalflash(family) && println(io, "set_global_assignment -name INTERNAL_FLASH_UPDATE_MODE \"SINGLE COMP IMAGE\"")
  nothing
end

# the whole flow, then the SRAM image as the serial vector openFPGALoader plays
# into the JTAG port
function _quartusbuildsh(name)
  io = IOBuffer()
  println(io, "#!/bin/bash")
  println(io, "# Runs Quartus Prime on this workspace, from synthesis to the programming files.")
  println(io, "# QUARTUS_BIN points at Quartus's bin directory where it is not on the PATH.")
  println(io, "set -e")
  println(io, "[ -z \"\$QUARTUS_BIN\" ] || export PATH=\"\$QUARTUS_BIN:\$PATH\"")
  println(io, "quartus_sh --flow compile $name")
  println(io, "quartus_cpf -c -q 12.0MHz -g 3.3 -n p output_files/$name.sof output_files/$name.svf")
  String(take!(io))
end

function _quartusmakefile(name, b::Board, family, cable)
  flash = _internalflash(family)
  io = IOBuffer()
  println(io, "# Builds $name for $(b.name) with Quartus Prime: `make` for the programming files, `make load`",
          " to load the FPGA over JTAG", flash ? ", `make flash` to write its flash" : "", ", `make clean` to start over.")
  println(io, "all: output_files/$name.svf")
  println(io)
  println(io, "output_files/$name.svf: src/*.v $name.qsf $name.qpf $(b.name).sdc build.sh")
  println(io, "\t./build.sh")
  println(io)
  println(io, "load: all")
  println(io, "\topenFPGALoader -c $cable output_files/$name.svf")
  println(io)
  if flash
    println(io, "flash: all")
    println(io, "\topenFPGALoader -c $cable output_files/$name.pof")
    println(io)
  end
  println(io, "clean:")
  println(io, "\trm -rf output_files db incremental_db")
  println(io)
  println(io, ".PHONY: all load", flash ? " flash" : "", " clean")
  String(take!(io))
end
