"""Client `qhost:NAME` / `--remote-julia` / `--queue-env`: peel flags and `run_on_host`.

Kit `--hosts` / `--julia` stay on `go` / `ride` / `drive`. `setup` / `serve` /
`enable` / `disable` / `add-host` / `remove-host` are not forwarded.
Not a Kit placement token. Queue-host Julia is `julia --startup-file=no
--project=<queue-env> -m DistSSHQueue` (not the client's `--project=`).
"""

function default_remote_julia()::String
    envj = strip(get(ENV, "JULIA_DISTRIBUTED_EXE", ""))
    return isempty(envj) ? "auto" : envj
end

"""SSH name from a `qhost:NAME` token."""
function parse_qhost_token(raw::AbstractString)::String
    s = strip(String(raw))
    startswith(s, "qhost:") || throw(ArgumentError("queue host is `qhost:NAME`, not $(repr(s))"))
    name = strip(chopprefix(s, "qhost:"))
    isempty(name) && throw(ArgumentError("`qhost:` needs an SSH name"))
    return String(name)
end

"""SSH name shown on `status` / `watch`. Set by `qhost:`; not a CLI flag."""
const QHOST_DISPLAY_ENV = "DISTSSHQUEUE_QHOST"

"""Client default queue host (SSH name). Not `DISTSSHKIT_HOSTS` (workers).

Not forwarded on `qhost:` (`DISTSSHQUEUE_QHOST` is display only). Set on the
client; do not put this in the queue host `config.toml` `[env]`.
"""
const QHOST_DEFAULT_ENV = "DISTSSHQUEUE_HOST"

"""Harness only: finite `watch` frames. Not a product flag (tests / E2E)."""
const WATCH_TICKS_ENV = "DISTSSHQUEUE_WATCH_TICKS"

"""Client default `--queue-env` on `qhost:` (`julia --project=` there). Not forwarded."""
const QUEUE_ENV_ENV = "DISTSSHQUEUE_QUEUE_ENV"

"""Usual dedicated env on the queue host (same as `enable --queue-env` default)."""
const HOP_QUEUE_ENV_DEFAULT = "~/.distsshqueue/env"

"""`--queue-env @`: remote default Julia env (no `--project=`)."""
const HOP_QUEUE_ENV_NONE = "@"

function qhost_default_from_env()::Union{Nothing,String}
    v = strip(get(ENV, QHOST_DEFAULT_ENV, ""))
    isempty(v) && return nothing
    startswith(v, "qhost:") && return parse_qhost_token(v)
    return String(v)
end

function qhost_display_from_env()::Union{Nothing,String}
    v = strip(get(ENV, QHOST_DISPLAY_ENV, ""))
    return isempty(v) ? nothing : String(v)
end

function _set_qhost(cur::Union{Nothing,String}, next::AbstractString)::String
    n = String(next)
    if cur !== nothing && cur != n
        throw(ArgumentError("queue host given twice ($cur and $n)"))
    end
    return n
end

function _set_queue_env(cur::Union{Nothing,String}, next::AbstractString)::String
    n = String(next)
    if cur !== nothing && cur != n
        throw(ArgumentError("queue env given twice ($cur and $n)"))
    end
    return n
end

"""Peel leading `qhost:NAME` / `--remote-julia PATH` / `--queue-env DIR`."""
function extract_remote_opts(args::Vector{String})
    host = nothing
    rjulia = nothing
    qenv = nothing
    i = 1
    while i <= length(args)
        a = args[i]
        if a == "--qhost"
            throw(ArgumentError("use `qhost:NAME`, not `--qhost`"))
        elseif a == "--project" || startswith(a, "--project=")
            throw(ArgumentError(
                "queue-host julia --project= is --queue-env DIR. " *
                "Client julia --project= loads Queue locally; it is not forwarded.",
            ))
        elseif startswith(a, "qhost:")
            host = _set_qhost(host, parse_qhost_token(a))
            i += 1
        elseif a == "--remote-julia" && i < length(args)
            rjulia = args[i+1]
            i += 2
        elseif a == "--queue-env" && i < length(args)
            qenv = _set_queue_env(qenv, args[i+1])
            i += 2
        else
            break
        end
    end
    host === nothing && (host = qhost_default_from_env())
    return host, rjulia, qenv, args[i:end]
end

function coalesce_remote(
    ahost::Union{Nothing,AbstractString},
    ajulia::Union{Nothing,AbstractString},
    bhost::Union{Nothing,AbstractString},
    bjulia::Union{Nothing,AbstractString},
)
    if ahost !== nothing && bhost !== nothing && String(ahost) != String(bhost)
        throw(ArgumentError("queue host given twice ($(ahost) and $(bhost))"))
    end
    host = ahost !== nothing ? String(ahost) : (bhost === nothing ? nothing : String(bhost))
    spec = ajulia !== nothing ? String(ajulia) :
           (bjulia !== nothing ? String(bjulia) : default_remote_julia())
    return host, spec
end

"""CLI `--queue-env` wins, then `DISTSSHQUEUE_QUEUE_ENV`, then the dedicated dir.

`@` means no `--project=` (remote default Julia env).
"""
function coalesce_queue_env(
    a::Union{Nothing,AbstractString},
    b::Union{Nothing,AbstractString},
)::String
    if a !== nothing && b !== nothing && String(a) != String(b)
        throw(ArgumentError("queue env given twice ($(a) and $(b))"))
    end
    picked = a !== nothing ? String(a) : (b === nothing ? nothing : String(b))
    if picked === nothing
        v = strip(get(ENV, QUEUE_ENV_ENV, ""))
        picked = isempty(v) ? HOP_QUEUE_ENV_DEFAULT : String(v)
    end
    return picked
end

"""Julia flags for `run_on_host` before `-m` / `-e`. `~` expands on the queue host."""
function hop_julia_prefix(queue_env::AbstractString)::Vector{String}
    prefix = String["--startup-file=no"]
    q = strip(String(queue_env))
    q == HOP_QUEUE_ENV_NONE && return prefix
    isempty(q) && (q = HOP_QUEUE_ENV_DEFAULT)
    push!(prefix, "--project=$q")
    return prefix
end

const QHOST_LOCAL_VERBS = ("setup", "serve", "enable", "disable", "service", "add-host", "remove-host")

function reject_qhost_on_local(sub::AbstractString, host::Union{Nothing,AbstractString})
    host === nothing && return nothing
    sub in QHOST_LOCAL_VERBS || return nothing
    throw(ArgumentError(
        "`qhost:NAME` is a client token; `$sub` runs on the queue host. " *
        "Log in there and run it, or omit `qhost:` if this machine is the queue host.",
    ))
end

function remote_dispatch(
    host::AbstractString,
    rjulia::AbstractString,
    sub::AbstractString,
    payload::Vector{String};
    tty::Bool=false,
    qhost_display::Union{Nothing,AbstractString}=nothing,
    queue_env::AbstractString=HOP_QUEUE_ENV_DEFAULT,
    extra_env::Dict{String,String}=Dict{String,String}(),
)::Cint
    label = qhost_display === nothing ? nothing : strip(String(qhost_display))
    assigns = String[]
    if label !== nothing && !isempty(label)
        push!(assigns, "ENV[$(repr(QHOST_DISPLAY_ENV))] = $(repr(label))")
    end
    for (k, v) in extra_env
        push!(assigns, "ENV[$(repr(k))] = $(repr(v))")
    end
    ticks = strip(get(ENV, WATCH_TICKS_ENV, ""))
    if !isempty(ticks)
        push!(assigns, "ENV[$(repr(WATCH_TICKS_ENV))] = $(repr(ticks))")
    end
    for name in ("DISTSSHKIT_QUIET", "DISTSSHKIT_PROGRESS", "DISTSSHKIT_VERBOSE")
        v = strip(get(ENV, name, ""))
        isempty(v) && continue
        push!(assigns, "ENV[$(repr(name))] = $(repr(v))")
    end
    if !isempty(assigns)
        args = String[String(sub)]
        append!(args, String[String(a) for a in payload])
        expr = join(assigns, "; ") * "; exit(Int(DistSSHQueue.main($(repr(args)))))"
        core = String["-e", "using DistSSHQueue; " * expr]
    else
        core = String["-m", "DistSSHQueue", String(sub)]
        append!(core, payload)
    end
    argv = append!(hop_julia_prefix(queue_env), core)
    spec = strip(String(rjulia))
    auto = isempty(spec) || spec == "auto"
    proc = DistSSHKit.run_on_host(
        host,
        argv;
        julia=auto ? nothing : spec,
        detect=auto,
        tty=tty,
    )
    code = Int(something(proc.exitcode, 1))
    if code == 127
        throw(ArgumentError(
            "no Julia on $(host) (ssh PATH is often empty; Kit tries juliaup then Homebrew). " *
            "Pass --remote-julia PATH or set JULIA_DISTRIBUTED_EXE, like Kit --julia.",
        ))
    end
    return Cint(code)
end

"""If a queue host is set, ssh `sub` + `rest` and return the exit code; else `nothing`.

`label_qhost` sets `DISTSSHQUEUE_QHOST` to the client token (not a CLI flag;
re-passing `qhost:` would recurse). `status` / `watch` print that token on the
Store `qhost` line and prefix `path`. `list-host` only uses it to say
`queue host (hostname)` instead of `this machine`; NAME is `gethostname()`.
"""
function maybe_remote(
    qhost::Union{Nothing,AbstractString},
    gjulia::Union{Nothing,AbstractString},
    sub::AbstractString,
    rest::Vector{String};
    tty::Bool=false,
    label_qhost::Bool=false,
    queue_env::Union{Nothing,AbstractString}=nothing,
)::Union{Nothing,Cint}
    host, rjulia, qenv, payload = extract_remote_opts(rest)
    dest, spec = coalesce_remote(qhost, gjulia, host, rjulia)
    dest === nothing && return nothing
    disp = label_qhost ? dest : nothing
    q = coalesce_queue_env(queue_env, qenv)
    extra = Dict{String,String}()
    hop = payload
    if should_stage(sub, payload)
        hop, extra = stage_job_tree!(dest, spec, sub, payload)
        return _remote_submit_ticket(
            dest, spec, sub, hop, extra, payload; tty=tty, qhost_display=disp, queue_env=q,
        )
    end
    should_submit_ticket(sub, payload) && return _remote_submit_ticket(
        dest, spec, sub, payload, extra, payload; tty=tty, qhost_display=disp, queue_env=q,
    )
    return remote_dispatch(
        dest, spec, sub, hop; tty=tty, qhost_display=disp, queue_env=q, extra_env=extra,
    )
end

"""`qhost:` submit hop: capture stdout, reprint it, write `.distsshkit/queue/<id>`."""
function _remote_submit_ticket(
    dest::AbstractString,
    spec::AbstractString,
    sub::AbstractString,
    hop::Vector{String},
    extra::Dict{String,String},
    payload::Vector{String};
    tty::Bool,
    qhost_display::Union{Nothing,AbstractString},
    queue_env::AbstractString,
)::Cint
    code, text = mktemp() do path, io
        c = redirect_stdout(io) do
            remote_dispatch(
                dest, spec, sub, hop;
                tty=tty, qhost_display=qhost_display, queue_env=queue_env, extra_env=extra,
            )
        end
        flush(io)
        return c, read(path, String)
    end
    print(text)
    if Int(code) == 0
        script = nothing
        try
            kit, kitargs = kit_verb_and_args(sub, payload)
            parsed = kit_parse_args(kit_kind_from_cli(kit), kitargs)
            parsed.script_path !== nothing && (script = String(parsed.script_path))
        catch
        end
        write_submit_ticket(job_project(), text; script=script, qhost=dest)
    end
    return Cint(code)
end
