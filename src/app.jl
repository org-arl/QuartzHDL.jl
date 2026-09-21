# The `quartz` command: it reads the arguments, evaluates the design file in a
# module of its own, and writes each top module out in the format asked for --
# with the board's constraint file beside it where a board is named. `quartz timing`
# prints the timing report of a module instead, and is the budget a build can hold
# a design to.

const USAGE = """
usage: quartz <design.jl> [options]
       quartz timing <design.jl> [options]        (quartz timing --help)

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

const TIMING_USAGE = """
usage: quartz timing <design.jl> [options]

Print where a @quartz module, with everything below it, is likely to be slow: the
conditions that read many bits and decide many register bits, and arithmetic in
series. With --budget the exit status says whether the design is within it.

options:
  --top T           the module, as a Julia expression evaluated in the design file's
                    scope; may be left out when the file has one module to compile
  --budget B        the limits, as `timing` takes them, evaluated in the design
                    file's scope: 'max_bits = 8 => 128, max_carry = 48'

  --lut-inputs N    the variable bits an operation must exceed to count as
                    arithmetic (default 4)
  --depth           map the design with yosys too, for the levels of logic of
                    every path; a budget with max_depth does so by itself
  --board B         a @board in the design file: yosys runs the flow of its part
  --synth CMD       the yosys flow outright, 'synth_lattice -family xo2' for a MachXO2;
                    with neither, yosys maps to plain LUTs
  --count N         how many lines of each table to print (default 12)
  --condition LINE  print one condition in full, by the line of its `if`: adc.jl:204
  --register NAME   print everything that ends at one register: adc1.data
  --json            write the whole report as JSON instead
  -h, --help        show this help

The exit status is 0 when there is no budget or the design is within it, 1 when the
budget rejects anything, and 2 when the report could not be made.
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
  !isempty(argv) && argv[1] == "timing" && return _timingmain(argv[2:end])
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

# what `quartz timing` was asked for
mutable struct TimingOptions
  file::Union{Nothing,String}
  top::Union{Nothing,String}
  budget::String
  lut_inputs::String
  count::String
  depth::Bool
  board::Union{Nothing,String}
  synth::Union{Nothing,String}
  condition::Union{Nothing,String}
  register::Union{Nothing,String}
  json::Bool
end

TimingOptions() = TimingOptions(nothing, nothing, "", "4", string(SHOWN), false, nothing, nothing, nothing, nothing, false)

# 1 is the budget's answer, so whatever stops the report from being made is 2
const TIMING_FAILED = 2

function _timingmain(argv)
  opt = _timingoptions(argv)
  opt isa TimingOptions || return opt == 0 ? 0 : TIMING_FAILED
  opt.file === nothing && return _fail("no design file given", TIMING_FAILED)
  isfile(opt.file) || return _fail("no such file: $(opt.file)", TIMING_FAILED)
  lut_inputs = tryparse(Int, opt.lut_inputs)
  count = tryparse(Int, opt.count)
  lut_inputs === nothing && return _fail("--lut-inputs takes a whole number", TIMING_FAILED)
  count === nothing && return _fail("--count takes a whole number", TIMING_FAILED)
  design = _designmodule(opt.file)
  design isa Module || return TIMING_FAILED
  Base.invokelatest(_timing, design, opt, lut_inputs, count)
end

function _timingoptions(argv)
  opt = TimingOptions()
  i = 0
  while i < length(argv)
    a = argv[i += 1]
    if a in ("-h", "--help")
      print(TIMING_USAGE)
      return 0
    elseif a == "--json"
      opt.json = true
    elseif a == "--depth"
      opt.depth = true
    elseif a in ("--top", "--budget", "--lut-inputs", "--count", "--board", "--synth", "--condition", "--register")
      i += 1
      i ≤ length(argv) || return _fail("$a needs an argument")
      setfield!(opt, Symbol(replace(lstrip(a, '-'), "-" => "_")), argv[i])
    elseif startswith(a, "-")
      return _fail("unknown option $a")
    elseif opt.file === nothing
      opt.file = a
    else
      return _fail("only one design file may be given")
    end
  end
  opt
end

function _timing(design, opt::TimingOptions, lut_inputs::Int, count::Int)
  types = opt.top === nothing ? _alltops(design, opt.file) : _namedtops(design, [opt.top])
  types isa Vector{Type} || return TIMING_FAILED
  length(types) == 1 ||
    return _fail("$(opt.file) has $(length(types)) modules to compile; name one with --top", TIMING_FAILED)
  budget = try
    Core.eval(design, Meta.parse("(; $(opt.budget))"))
  catch e
    return _fail("cannot evaluate --budget $(opt.budget): " * sprint(showerror, e), TIMING_FAILED)
  end
  board = opt.board === nothing ? nothing : _board(design, opt.board)
  board isa Union{Nothing,Board} || return TIMING_FAILED
  r = try
    Base.invokelatest(timing, types[1]; lut_inputs, opt.depth, board, opt.synth, budget...)
  catch e
    return _fail(sprint(showerror, e), TIMING_FAILED)
  end
  try
    opt.json ? _writejson(stdout, r) :
    opt.condition !== nothing ? show(stdout, r; condition=opt.condition) :
    opt.register !== nothing ? show(stdout, r; register=opt.register) : show(stdout, r; top=count)
  catch e
    e isa ArgumentError || rethrow()
    return _fail(e.msg, TIMING_FAILED)
  end
  opt.json || println()
  r.ok === false ? 1 : 0
end

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
    format = _onboard(format, board)
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

_fail(msg, status=1) = (println(stderr, "quartz: ", msg); status)

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
