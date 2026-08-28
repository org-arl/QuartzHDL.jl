# The `quartz` command: it reads the arguments, evaluates the design file in a
# module of its own, and writes each top module out in the format asked for --
# with the board's constraint file beside it where a board is named.

const USAGE = """
usage: quartz <design.jl> [options]

Write @quartz modules in a Julia design file out in an emitter's format --
Verilog unless another is named -- and a design on a board to its constraint file.

options:
  --top T         module to compile, as a Julia expression evaluated in the design
                  file's scope (e.g. --top 'MF{127}'); may be repeated; without it,
                  every non-parametric @quartz module in the file is compiled
  --emit E        the format, as QuartzHDL spells it: Verilog (the default),
                  or with options, 'Verilog(debug = true, suffix = false)';
                  Diamond, with --board, writes a Lattice Diamond workspace
  --board B       a @board in the design file: also write the Lattice constraint
                  file for the --top on it, as <B>.lpf beside the output
  -o FILE         output file (single --top only; default <name>.<extension>);
                  for Diamond the workspace directory (default <name>/)
  --outdir DIR    output directory (default .)
  --name NAME     module name in the output (single --top only; default the struct name)
  -h, --help      show this help
"""

# what the command line asked for, once it has been read
mutable struct Options
  file::Union{Nothing,String}
  tops::Vector{String}
  out::Union{Nothing,String}
  outdir::String
  name::Union{Nothing,String}
  board::Union{Nothing,String}
  emit::String
end

Options() = Options(nothing, String[], nothing, ".", nothing, nothing, "Verilog")

function (@main)(argv)
  opt = _options(argv)
  opt isa Options || return opt
  opt.file === nothing && return _fail("no design file given")
  isfile(opt.file) || return _fail("no such file: $(opt.file)")
  (opt.out !== nothing || opt.name !== nothing || opt.board !== nothing) && length(opt.tops) != 1 &&
    return _fail("-o, --name and --board need exactly one --top")
  design = _designmodule(opt.file)
  design isa Module || return design
  format = _format(opt.emit)
  format isa Format || return _fail(format)
  Base.invokelatest(_compile, design, opt, format)
end

### helpers

# the arguments as options, or the status a bad argument exits with
function _options(argv)
  opt = Options()
  i = 0
  while i < length(argv)
    a = argv[i += 1]
    if a in ("-h", "--help")
      print(USAGE)
      return 0
    elseif a in ("--top", "-o", "--outdir", "--name", "--board", "--emit")
      i += 1
      i ≤ length(argv) || return _fail("$a needs an argument")
      a == "--top" ? push!(opt.tops, argv[i]) : setfield!(opt, _optfield(a), argv[i])
    elseif startswith(a, "-")
      return _fail("unknown option $a")
    elseif opt.file === nothing
      opt.file = argv[i]
    else
      return _fail("only one design file may be given")
    end
  end
  opt
end

_optfield(a) = a == "-o" ? :out : Symbol(lstrip(a, '-'))

# the design file evaluated in a module of its own, or the status it failed with
function _designmodule(file)
  design = Module(:QuartzDesign)
  Core.eval(design, :(using QuartzHDL))
  # a fresh module has no `include`, and a design of any size is split over files
  Core.eval(design, :(include(p::AbstractString) = Base.include(@__MODULE__, p)))
  try
    Base.include(design, abspath(file))
  catch e
    return _fail(sprint(showerror, e))
  end
  design
end

# the format named on the command line, as QuartzHDL spells it: a type's name,
# or a call with its options
function _format(emit::AbstractString)
  ex = try
    Meta.parse(emit)
  catch e
    return "--emit $emit: " * sprint(showerror, e)
  end
  f = try
    Core.eval(QuartzHDL, ex)
  catch e
    return "--emit $emit: " * sprint(showerror, e)
  end
  f isa Type && f <: Format && (f = f())
  f isa Format ? f : "--emit $emit is not a format QuartzHDL writes"
end

function _compile(design, opt::Options, format)
  types = isempty(opt.tops) ? _alltops(design, opt.file) : _namedtops(design, opt.tops)
  types isa Vector{Type} || return types
  board = opt.board === nothing ? nothing : _board(design, opt.board)
  board isa Union{Nothing,Board} || return board
  _write(types, opt, format, board)
end

# every concrete @quartz module the design file defines, with a word about the
# parametric ones, which need naming before they can be compiled
function _alltops(design, file)
  types = Type[]
  for n in names(design; all=true)
    isdefined(design, n) || continue
    T = getproperty(design, n)
    T isa DataType && T <: QuartzModule && isconcretetype(T) && _hasblocks(T) && push!(types, T)
    if T isa UnionAll && T.body isa DataType && T.body.name.wrapper == T && supertype(T.body) == QuartzModule
      @warn "$n is parametric; give a concrete instantiation with --top '$n{...}' to compile it"
    end
  end
  isempty(types) && return _fail("no compilable @quartz modules found in $file")
  types
end

# the modules the --tops name, each evaluated in the design file's scope
function _namedtops(design, tops)
  types = Type[]
  for t in tops
    T = try
      Core.eval(design, Meta.parse(t))
    catch e
      return _fail("cannot evaluate --top $t: " * sprint(showerror, e))
    end
    T isa Type && T <: QuartzModule || return _fail("--top $t is not a QuartzModule")
    isconcretetype(T) || return _fail("--top $t is not concrete; give values for its type parameters")
    _hasblocks(T) || return _fail("--top $t has no @on blocks")
    push!(types, T)
  end
  types
end

function _board(design, board)
  b = try
    Core.eval(design, Meta.parse(board))
  catch e
    return _fail("cannot evaluate --board $board: " * sprint(showerror, e))
  end
  b isa Board ? b : _fail("--board $board is not a @board")
end

function _write(types, opt::Options, format, board)
  if format isa Diamond
    board === nothing && return _fail("--emit Diamond needs --board")
    format = Diamond(board; vendor = format.vendor, implementation = format.implementation)
  end
  for T in types
    mname = length(types) == 1 && opt.name !== nothing ? Symbol(opt.name) : nameof(T)
    path = length(types) == 1 && opt.out !== nothing ? opt.out : outputpath(format, opt.outdir, mname)
    try
      write(path, T, _named(format, mname))
    catch e
      return _fail(sprint(showerror, e))
    end
    println(path)
    (board === nothing || format isa Diamond) && continue
    lpfpath = joinpath(dirname(path), "$(board.name).lpf")
    try
      write(lpfpath, T, LPF(board))
    catch e
      return _fail(sprint(showerror, e))
    end
    println(lpfpath)
  end
  0
end

_fail(msg) = (println(stderr, "quartz: ", msg); 1)

# whether a module has anything to compile: a type that never went through @quartz
# has no `blocks` method at all, which is a MethodError and not an error to report
function _hasblocks(T)
  try
    !isempty(blocks(T))
  catch e
    e isa MethodError || rethrow()
    false
  end
end
