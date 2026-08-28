# Logging from inside a design. `@info`, `@debug`, `@warn` and `@error` in a block
# go to Julia's logger with the simulation time and the module's name added, and
# `@check cond` stops a simulation where a design's own assumption fails. What is
# seen is chosen from outside with `showlogs!`, so the design says what is worth
# noting and the person running it says when. In Verilog the same statements
# become `$display` and `$error`, and only when asked for: synthesis output has none.

const LOGMACROS = Dict(Symbol("@debug") => Debug, Symbol("@info") => Info,
                       Symbol("@warn") => Warn, Symbol("@error") => Error)

"""
    showlogs!(sim; from = nothing, to = nothing, modules = nothing, when = nothing)

Choose which of `sim`'s log messages are shown: only between times `from` and `to`
(seconds), only from the named module types, or only while `when()` holds. With
nothing given, every message of `sim` is shown again. Each simulation has its own
choice, and one simulation's choice says nothing about another's.
"""
function showlogs!(s::Simulation; from=nothing, to=nothing, modules=nothing, when=nothing)
  s.logfilter = LogFilter(from === nothing ? -Inf : float(from), to === nothing ? Inf : float(to),
                          modules === nothing ? Symbol[] : collect(Symbol, modules), when)
  LOGFILTER[] = s.logfilter
  nothing
end

# whether a message from a module is wanted now: cheap, and asked before it is built
function _logon(level::LogLevel, mod::Symbol)
  level ≥ Base.CoreLogging._min_enabled_level[] || return false
  f = LOGFILTER[]
  t = float(SIMTIME[])
  f.from ≤ t ≤ f.to || return false
  isempty(f.modules) || mod in f.modules || return false
  f.pred === nothing || f.pred() === true
end

function simlog(level::LogLevel, msg, kw::NamedTuple, mod::Symbol)
  @logmsg level msg _group=mod time=_timestr(SIMTIME[]) kw...
  nothing
end

# a design's own assumption, broken: where it was, and when
struct CheckFailed <: Exception
  cond::String
  mod::Symbol
  time::Rational{Int}
end
Base.showerror(io::IO, e::CheckFailed) =
  print(io, "check failed in ", e.mod, " at ", _timestr(e.time), ": ", e.cond)

simcheck(cond::String, mod::Symbol) = throw(CheckFailed(cond, mod, SIMTIME[]))

"""
    @check cond

In a block: the design's own assumption, checked every time the block runs. A
simulation stops where it fails; Verilog emitted with `debug = true` raises `\$error`.
"""
macro check(args...)
  error("@check is only valid inside an @on or @wire block")
end

# the log statements of a block body, turned into plain calls before the body
# expands, so the rest of the compiler sees function calls and nothing else
function _logcalls(ex, T)
  ex isa Expr || return ex
  # `cond && @info ...` is the same one-line `if` a guarded write is, so it becomes
  # the `if` here, where the macro is still recognisable
  if ex.head in (:&&, :||) && _islogmacro(_unblock(ex.args[2]))
    cond = _logcalls(ex.args[1], T)
    body = _logcalls(_unblock(ex.args[2]), T)
    return ex.head == :&& ? Expr(:if, cond, Expr(:block, body)) :
                            Expr(:if, Expr(:call, :!, cond), Expr(:block, body))
  end
  if ex.head == :macrocall
    name = _macroname(ex.args[1])
    args = filter(a -> !(a isa LineNumberNode), ex.args[2:end])
    if haskey(LOGMACROS, name)
      isempty(args) && error("$name needs a message")
      level = LOGMACROS[name]
      kw = Expr(:tuple, Expr(:parameters, (a isa Expr && a.head == :(=) ? Expr(:kw, a.args[1], a.args[2]) :
                                           a isa Symbol ? Expr(:kw, a, a) :
                                           error("$name: expected `name` or `name = value`, got $a")
                                           for a in args[2:end])...))
      return Expr(:if, :($QuartzHDL._logon($level, $(QuoteNode(nameof(T))))),
                  Expr(:block, :($QuartzHDL.simlog($level, $(args[1]), $kw, $(QuoteNode(nameof(T)))))))
    elseif name === Symbol("@check")
      length(args) == 1 || error("@check takes one condition")
      return Expr(:if, :(!($(args[1]))),
                  Expr(:block, :($QuartzHDL.simcheck($(string(args[1])), $(QuoteNode(nameof(T)))))))
    end
  end
  ex.head == :quote && return ex
  Expr(ex.head, map(a -> _logcalls(a, T), ex.args)...)
end

_islogmacro(ex) = ex isa Expr && ex.head == :macrocall &&
  (haskey(LOGMACROS, _macroname(ex.args[1])) || _macroname(ex.args[1]) === Symbol("@check"))
