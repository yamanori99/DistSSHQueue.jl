"""
DistSSHQueue — FIFO `serve` for DistSSHKit (`go` / `ride` / `drive`).

Package entry: exports, `include`s, `main` (`@main` on Julia 1.13+).
FIFO: `src/DistSSHQueue/`. Client CLI: `src/client/`. Queue host CLI: `src/qhost/`.
`serve` runs DistSSHRun `execute!(...; detached=true)` for kinds in `KIT_EXECUTE_KINDS`.
`--project=<queue-env>` loads this package; the Kit project is `job_project()`.
Autoserve uses the Julia and `--project=` from the `enable` unit when that file exists.
Config: `~/.distsshqueue/config.toml`.

Concept: [docs](https://yamanori99.github.io/DistSSHQueue.jl/stable/).
"""
module DistSSHQueue

using Dates
using Pkg
using TOML

import DistSSHRun
using DistSSHRun.DistSSHBase
using DistSSHRun.DistSSHBase: PARENT_HOST_NAME, _ssh_host_args, _test_doubles_on,
    cli_entry, cli_heading, cli_m, cli_m_project, cli_qhost, cli_qhost_heading,
    format_placement_token, get_remote_julia_version_full,
    is_sigint, julia_project_rel, parse_julia_version_full,
    parse_placement_token, remote_env_project_root, resolve_remote_julia,
    resolve_remote_project_root, shield_sigint, with_cli_entry, without_cancel
using DistSSHRun.DistSSHUp: juliaup_add_host!, juliaup_default_host!,
    juliaup_default_patch, juliaup_status_lines, juliaup_update_host!

export Queue
export Job
export submit!
export cancel!
export jobs
export job
export step!
export load!
export serve!
export serve
export job_project
export default_store_path

include("DistSSHQueue/job.jl")
include("DistSSHQueue/store.jl")
include("DistSSHQueue/paths.jl")
include("DistSSHQueue/config.jl")
include("DistSSHQueue/display.jl")
include("DistSSHQueue/queue.jl")
include("client/qhost.jl")
include("client/submit.jl")
include("client/stage.jl")
include("client/fetch.jl")
include("client/status.jl")
include("client/list_host.jl")
include("client/inspect.jl")
include("client/size.jl")
include("client/plan.jl")
include("client/pool.jl")
include("client/edit_hosts.jl")
include("client/cancel.jl")
include("qhost/service.jl")
include("qhost/setup.jl")
include("qhost/up.jl")
include("qhost/teardown.jl")
include("qhost/serve.jl")

function show_usage(;
        io::IO = stdout,
        topic::Union{Nothing, AbstractString} = nothing,
        command::Union{Nothing, AbstractString} = nothing,
    )
    command !== nothing && return print_queue_command_usage(io, command)
    return print_queue_usage(io; topic = topic)
end

"""What `main` knows before it hands argv to one command."""
struct CliContext
    qhost::Union{Nothing, String}
    julia::Union{Nothing, String}
    queue_env::Union{Nothing, String}
    explicit::Bool
    process_yes::Bool
end

"""How one subcommand is reached. The callable stays in `_QUEUE_CALLS`, not here, so this stays concrete."""
struct QueueCommand
    hop::Symbol
    label_qhost::Bool
    watch_tty::Bool
end

function _argv(f::Function)
    return (_ctx, rest) -> f(rest)::Cint
end

function _fetch(ctx::CliContext, rest::Vector{String})::Cint
    hop = ctx.explicit ? ctx.qhost : nothing
    return fetch_cli(hop, ctx.julia, ctx.queue_env, rest; explicit = ctx.explicit)
end

function _teardown(ctx::CliContext, rest::Vector{String})::Cint
    return teardown_main(rest; process_yes = ctx.process_yes)
end

function _payload(rest::Vector{String})::Vector{String}
    _, _, _, payload, _ = extract_remote_opts(rest)
    return payload
end

function _forward(
        sub::String,
        run::Function,
        ctx::CliContext,
        rest::Vector{String};
        label_qhost::Bool,
        watch_tty::Bool,
    )::Cint
    hop = ctx.explicit ? ctx.qhost : nothing
    tty = watch_tty ? status_watch_hop_tty(rest) : false
    remote = maybe_remote(
        hop, ctx.julia, sub, rest;
        tty = tty,
        label_qhost = label_qhost,
        queue_env = ctx.queue_env,
        explicit = ctx.explicit,
    )
    remote === nothing || return remote::Cint
    return run(ctx, _payload(rest))::Cint
end

function _entry_forward(call::Function, sub::String, label_qhost::Bool, watch_tty::Bool)
    return (ctx, rest) -> _forward(
        sub, call, ctx, rest; label_qhost = label_qhost, watch_tty = watch_tty,
    )
end

function _entry_direct(call::Function)
    return (ctx, rest) -> call(ctx, rest)::Cint
end

function _queue_command(
        hop::Symbol,
        call::Function,
        sub::String;
        label_qhost::Bool = false,
        watch_tty::Bool = false,
    )::Tuple{QueueCommand, Function}
    body = if hop === :forward
        _entry_forward(call, sub, label_qhost, watch_tty)
    elseif hop === :local || hop === :own
        _entry_direct(call)
    else
        error("unhandled hop: $(repr(hop))")
    end
    return (QueueCommand(hop, label_qhost, watch_tty), body)
end

function _queue_tables()
    rows = (
        "serve" => _queue_command(:local, _argv(serve_cli), "serve"),
        "stop" => _queue_command(:forward, _argv(stop_cli), "stop"),
        "status" => _queue_command(:forward, _argv(status_cli), "status"; label_qhost = true, watch_tty = true),
        "list-host" => _queue_command(:forward, _argv(list_host_cli), "list-host"; label_qhost = true),
        "size" => _queue_command(:forward, _argv(size_cli), "size"),
        "plan" => _queue_command(:forward, _argv(plan_cli), "plan"),
        "pool" => _queue_command(:forward, _argv(pool_cli), "pool"),
        "add-host" => _queue_command(:local, _argv(add_host_cli), "add-host"),
        "remove-host" => _queue_command(:local, _argv(remove_host_cli), "remove-host"),
        "watch" => _queue_command(:forward, _argv(watch_cli), "watch"; label_qhost = true, watch_tty = true),
        "submit" => _queue_command(:forward, _argv(submit_main), "submit"; label_qhost = true),
        "fetch" => _queue_command(:own, _fetch, "fetch"),
        "cancel" => _queue_command(:forward, _argv(cancel_cli), "cancel"),
        "teardown" => _queue_command(:forward, _teardown, "teardown"),
        "enable" => _queue_command(:local, _argv(enable_main), "enable"),
        "disable" => _queue_command(:local, _argv(disable_main), "disable"),
        "service" => _queue_command(:local, _argv(service_main), "service"),
        "setup" => _queue_command(:local, _argv(setup_main), "setup"),
        "up" => _queue_command(:local, _argv(up_main), "up"),
    )
    hops = Dict{String, QueueCommand}()
    calls = Dict{String, Function}()
    for (name, (spec, call)) in rows
        hops[name] = spec
        calls[name] = call
    end
    return hops, calls
end

const QUEUE_COMMANDS, _QUEUE_CALLS = _queue_tables()

"""CLI entry. Prefer `julia -m DistSSHKit` (client `qhost:HOST` / queue-host `setup`)."""
function main(args::Vector{String} = copy(ARGS))::Cint
    return with_cli_entry(:DistSSHQueue) do
        _main(args)
    end
end

function _reject_subcommand(sub::AbstractString)::Cint
    if is_kit_execute_kind(Symbol(sub))
        DistSSHRun.print_cli_error(
            "$sub is DistSSHRun. Enqueue with submit: $(cli_m()) [qhost:HOST] submit $sub …",
        )
        return 1
    end
    DistSSHRun.print_cli_error("unknown subcommand: $sub")
    show_usage(io = stderr)
    return 1
end

"""`help <verb> …` becomes `<verb> --help …`. Topics stay on the topic pages.

`help submit go` becomes `submit go --help`, so `submit_kind` prints the Kit
flags. `command_help_argv` still only looks at `-h` / `--help`.
"""
function _help_command_argv(after::Vector{String})::Vector{String}
    if length(after) < 2 || !(after[1] in ("help", "-h", "--help"))
        return after
    end
    verb = String(after[2])
    verb in QUEUE_COMMAND_HELP || return after
    rest = String[String(a) for a in after[3:end]]
    if verb == "submit" && !isempty(rest) && rest[1] in ("go", "ride", "drive")
        return String[verb, rest[1], "--help", rest[2:end]...]
    end
    return String[verb, "--help", rest...]
end

function _main(args::Vector{String})::Cint
    # teardown YES is the process value. Config `[env]` is applied below.
    process_yes = teardown_yes()
    try
        apply_config_env!(load_config())
        qhost, gjulia, gqenv, after, explicit = extract_remote_opts(args)
        # `help`, `-h`, and `--help`, in any number and order, are the root page.
        # `help submit --help` is not: `submit` is a command, so the rewrite below still runs.
        if !isempty(args) && all(in(("help", "-h", "--help")), args)
            print_queue_usage()
            return 0
        end
        after = _help_command_argv(after)
        if isempty(after) || after[1] in ("-h", "--help", "help")
            topic = length(after) >= 2 ? String(after[2]) : nothing
            print_queue_usage(; topic = topic)
            return 0
        end
        if length(after) == 1 && after[1] in ("--version", "-v", "-V")
            println_queue_version()
            return 0
        end
        sub, rest = String(after[1]), String[String(a) for a in after[2:end]]
        if command_help_argv(sub, rest)
            print_queue_command_usage(stdout, sub)
            return 0
        end
        reject_qhost_on_local(sub, explicit ? qhost : nothing)
        require_queue_target!(sub; explicit = explicit)
        call = get(_QUEUE_CALLS, sub, nothing)
        call === nothing && return _reject_subcommand(sub)
        ctx = CliContext(qhost, gjulia, gqenv, explicit, process_yes)
        # `call` is a `Function` from the table, so this does not infer the other commands.
        return call(ctx, rest)::Cint
    catch e
        e isa ArgumentError || rethrow()
        DistSSHRun.print_cli_error(e.msg)
        return 1
    end
end

Base.eval(@__MODULE__, :(@main))

end # module DistSSHQueue
