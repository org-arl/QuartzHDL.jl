# A prompt for talking to one simulation: every line is a `@run` body, and a net can
# be named bare -- `reset = true`, `advance_until(busy)`, `count` -- since the prompt
# knows which simulation it speaks for. Backspace on an empty line returns to Julia.

const SIMREPL = Ref{Any}(nothing)

"""
    simrepl(sim; key = ')')

Switch the REPL to a `sim>` prompt that drives `sim`. Lines are `@run` bodies with
bare net names: `reset = true`, `advance_by(1ms)`, `advance_until(busy)`, `result`.
Backspace on an empty line returns to the Julia prompt, and `key` at the start of
an empty Julia line comes back, as `]` does for Pkg.

A bare name is a net, read or written; `sim.name` always is. A name that is not a
net becomes a variable of the session, gone when `simrepl` is next called, and a
variable of the session shadows a net of the same name; `global x = 1` (or
`Main.x = 1` for one that exists) makes a variable of Main instead.
Ambiguous net names are written with their path, `ctrl.state`.
"""
function simrepl(s::Simulation; key::Char=')')
  isdefined(Base, :active_repl) && Base.active_repl isa REPL.LineEditREPL ||
    error("simrepl needs the interactive REPL")
  SIMREPL[] = s
  _newsession!()
  repl = Base.active_repl
  mode = _simmode(repl)
  _enterkey!(repl, mode, key)
  LineEdit.transition(repl.mistate, mode)
  nothing
end

const SIMKEY = Ref{Union{Nothing,Char}}(nothing)

function _enterkey!(repl, mode, key::Char)
  SIMKEY[] === key && return
  main = repl.interface.modes[1]
  enter = function (s, o...)
    if isempty(s) || LineEdit.position(LineEdit.buffer(s)) == 0
      buf = copy(LineEdit.buffer(s))
      LineEdit.transition(s, mode) do
        LineEdit.state(s, mode).input_buffer = buf
      end
    else
      LineEdit.edit_insert(s, key)
    end
  end
  main.keymap_dict = LineEdit.keymap_merge(main.keymap_dict, Dict{Any,Any}(key => enter))
  SIMKEY[] = key
  nothing
end

_simrepl() = (s = SIMREPL[]; s === nothing ? error("no simulation at the prompt; call simrepl(sim)") : s)

function _simmode(repl)
  mi = repl.interface
  main = mi.modes[1]
  for m in mi.modes
    m isa LineEdit.Prompt && m.prompt isa Function && m.prompt === _simprompt && return m
  end
  color = repl.options.hascolor
  mode = LineEdit.Prompt(_simprompt;
    prompt_prefix = color ? Base.text_colors[:cyan] : "",
    prompt_suffix = color ? (repl.envcolors ? Base.input_color : repl.input_color) : "",
    keymap_dict = LineEdit.default_keymap_dict,
    on_enter = REPL.return_callback,
    complete = REPL.REPLCompletionProvider(),
    sticky = true)
  mode.on_done = REPL.respond(_simline, repl, mode)
  hp = main.hist
  hp.mode_mapping[:sim] = mode
  mode.hist = hp
  _, skeymap = LineEdit.setup_search_keymap(hp)
  _, prefix_keymap = LineEdit.setup_prefix_keymap(hp, mode)
  mode.keymap_dict = LineEdit.keymap(Dict{Any,Any}[skeymap, REPL.mode_keymap(main), prefix_keymap,
                                                   LineEdit.history_keymap, LineEdit.default_keymap,
                                                   LineEdit.escape_defaults])
  push!(mi.modes, mode)
  mode
end

_simprompt() = (s = SIMREPL[]; s === nothing ? "sim> " : "sim " * _timestr(time(s)) * "> ")

# A session's own variables live in a module of their own, where the lines are
# evaluated, and are gone when the next `simrepl` starts. A name the session holds
# stands for the variable even where a net has the name; `Main.x` reaches Main.
const SESSION = Ref{Module}(Module(Symbol("sim>")))

_newsession!() = (SESSION[] = Module(Symbol("sim>")); nothing)

# A line at the prompt: rewritten so bare names mean nets, then run as a stimulus
# -- evaluated at the top level of the session's module from inside the run, so
# what it assigns or defines stays in the module.
function _simline(line::AbstractString)
  s = _simrepl()
  ex = Meta.parse(line)
  ex === nothing && return nothing
  ex isa Expr && ex.head == :toplevel && (ex = Expr(:block, ex.args...))
  mod = SESSION[]
  sim = gensym(:sim)
  body = _barenets(ex, s, sim, mod)
  code = _subst(_stimulus(_allunits(body), sim, Symbol[], _istask(body)), sim, s)
  :($QuartzHDL.run!($s, () -> $Core.eval($mod, $(QuoteNode(code)))))
end

# A bare name is a net unless the session holds a variable of that name. A read of
# a net is `sim.name`; a write drives it, whether or not it can be driven, so that
# writing to a net the design owns is an error rather than a new variable. A name
# that is Main's own is reached there.
function _barenets(ex, s::Simulation, sim, mod::Module)
  isvar(x) = isdefined(mod, x)
  isnet(x) = x isa Symbol && !isvar(x) && (haskey(s.short, x) || _drivable(s, x))
  name(x) = isnet(x) ? Expr(:., sim, QuoteNode(x)) : _mainsown(x) && !isvar(x) ? Expr(:., Main, QuoteNode(x)) : x
  callee(x) = _mainsown(x) && !isvar(x) ? Expr(:., Main, QuoteNode(x)) : x      # a net is never callable
  rec(a) = _barenets(a, s, sim, mod)
  ex isa Symbol && return name(ex)
  ex isa Expr || return ex
  if ex.head == :(=) && ex.args[1] isa Symbol
    x = ex.args[1]
    return Expr(:(=), isnet(x) ? Expr(:., sim, QuoteNode(x)) : x, rec(ex.args[2]))
  end
  if ex.head == :(=) && ex.args[1] isa Expr && ex.args[1].head == :tuple && all(x -> x isa Symbol, ex.args[1].args)
    # `reply, ft = drain(ft)`: each name is assigned on its own, so a net among them is driven
    tmp = gensym(:rhs)
    return Expr(:block, Expr(:(=), tmp, rec(ex.args[2])),
                (Expr(:(=), isnet(x) ? Expr(:., sim, QuoteNode(x)) : x, :($tmp[$i]))
                 for (i, x) in enumerate(ex.args[1].args))..., tmp)
  end
  ex.head == :call &&
    return Expr(:call, ex.args[1] isa Symbol ? callee(ex.args[1]) : rec(ex.args[1]), map(rec, ex.args[2:end])...)
  ex.head == :kw && return Expr(:kw, ex.args[1], rec(ex.args[2]))
  if ex.head == :.
    root = _chainroot(ex)
    root isa Symbol && !isvar(root) && _isscope(s, string(root)) && return _prefix(ex, sim)
    return Expr(:., rec(ex.args[1]), ex.args[2])
  end
  if ex.head == :global
    return Expr(:block, (a isa Expr && a.head == :(=) && a.args[1] isa Symbol ?
                         :($QuartzHDL._setglobal!(Main, $(QuoteNode(a.args[1])), $(rec(a.args[2])))) :
                         error("global takes `name = value` at the sim> prompt") for a in ex.args)...)
  end
  ex.head in (:quote, :meta, :function, :->, :local) && return ex
  Expr(ex.head, map(rec, ex.args)...)
end

_setglobal!(m::Module, x::Symbol, v) = (Core.eval(m, Expr(:(=), x, QuoteNode(v))); v)

# a name Main has, defined or imported, other than Base's own and the verbs the
# stimulus rewriting has to see bare
_mainsown(x::Symbol) = isdefined(Main, x) && !isdefined(Base, x) && !(x in (:advance_by, :advance_until))

_drivable(s::Simulation, x::Symbol) = haskey(s.drives, x) || haskey(s.bench.stubs, x)

# `usb1.usb_rd`: a chain that starts at a scope of the design is a net's path
_chainroot(ex) = ex isa Expr && ex.head == :. ? _chainroot(ex.args[1]) : ex
_prefix(ex, sim) = ex isa Symbol ? Expr(:., sim, QuoteNode(ex)) : Expr(:., _prefix(ex.args[1], sim), ex.args[2])
