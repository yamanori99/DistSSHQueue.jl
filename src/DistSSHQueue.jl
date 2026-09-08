"""
DistSSHQueue — FIFO `serve` for DistSSHKit (`go` / `ride` / `drive`).

Package entry: exports, `include`s, `main` (`@main` on Julia 1.12+).
FIFO: `src/DistSSHQueue/`. Client CLI: `src/client/`. Queue host CLI: `src/qhost/`.
`serve` runs DistSSHKit `execute!(...; detached=true)`.
`--project=<queue-env>` loads this package; the Kit project is `job_project()`.
Config: `~/.distsshqueue/config.toml`.

Concept: [docs](https://yamanori99.github.io/DistSSHQueue.jl/stable/).
"""
module DistSSHQueue

using Dates
using DistSSHKit
using TOML

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
include("qhost/teardown.jl")
include("qhost/serve.jl")

show_usage(; io::IO=stdout) = print_queue_usage(io)

"""CLI entry. Prefer `julia -m DistSSHQueue` (client `qhost:HOST` / queue-host `setup`)."""
function main(args::Vector{String}=copy(ARGS))::Cint
    apply_config_env!(load_config())
    try
        qhost, gjulia, gqenv, after = extract_remote_opts(args)
        if isempty(after) || after[1] in ("-h", "--help", "help")
            show_usage()
            return 0
        end
        if length(after) == 1 && after[1] in ("--version", "-v", "-V")
            println_queue_version()
            return 0
        end
        sub, rest = String(after[1]), String[String(a) for a in after[2:end]]
        reject_qhost_on_local(sub, qhost)
        if sub == "serve"
            return serve_cli(rest)
        elseif sub == "stop"
            r = maybe_remote(qhost, gjulia, "stop", rest; queue_env=gqenv)
            r === nothing || return r
            _, _, _, payload = extract_remote_opts(rest)
            return stop_cli(payload)
        elseif sub == "status"
            r = maybe_remote(
                qhost, gjulia, "status", rest;
                tty=any(isequal("--interval"), rest) && stdout isa Base.TTY,
                label_qhost=true, queue_env=gqenv,
            )
            r === nothing || return r
            _, _, _, payload = extract_remote_opts(rest)
            return status_cli(payload)
        elseif sub == "list-host"
            r = maybe_remote(
                qhost, gjulia, "list-host", rest; label_qhost=true, queue_env=gqenv,
            )
            r === nothing || return r
            _, _, _, payload = extract_remote_opts(rest)
            return list_host_cli(payload)
        elseif sub == "size"
            r = maybe_remote(qhost, gjulia, "size", rest; queue_env=gqenv)
            r === nothing || return r
            _, _, _, payload = extract_remote_opts(rest)
            return size_cli(payload)
        elseif sub == "plan"
            r = maybe_remote(qhost, gjulia, "plan", rest; queue_env=gqenv)
            r === nothing || return r
            _, _, _, payload = extract_remote_opts(rest)
            return plan_cli(payload)
        elseif sub == "pool"
            r = maybe_remote(qhost, gjulia, "pool", rest; queue_env=gqenv)
            r === nothing || return r
            _, _, _, payload = extract_remote_opts(rest)
            return pool_cli(payload)
        elseif sub == "add-host"
            return add_host_cli(rest)
        elseif sub == "remove-host"
            return remove_host_cli(rest)
        elseif sub == "watch"
            r = maybe_remote(qhost, gjulia, "watch", rest; tty=stdout isa Base.TTY, label_qhost=true, queue_env=gqenv)
            r === nothing || return r
            _, _, _, payload = extract_remote_opts(rest)
            return watch_cli(payload)
        elseif sub == "submit"
            r = maybe_remote(qhost, gjulia, "submit", rest; queue_env=gqenv)
            r === nothing || return r
            _, _, _, payload = extract_remote_opts(rest)
            return submit_main(payload)
        elseif is_kit_execute_kind(Symbol(sub))
            r = maybe_remote(qhost, gjulia, sub, rest; queue_env=gqenv)
            r === nothing || return r
            return submit_kind(Symbol(sub), rest)
        elseif sub == "fetch"
            return fetch_cli(qhost, gjulia, gqenv, rest)
        elseif sub == "cancel"
            r = maybe_remote(qhost, gjulia, "cancel", rest; queue_env=gqenv)
            r === nothing || return r
            _, _, _, payload = extract_remote_opts(rest)
            return cancel_cli(payload)
        elseif sub == "teardown"
            r = maybe_remote(qhost, gjulia, "teardown", rest; queue_env=gqenv)
            r === nothing || return r
            _, _, _, payload = extract_remote_opts(rest)
            return teardown_main(payload)
        elseif sub == "enable"
            return enable_main(rest)
        elseif sub == "disable"
            return disable_main(rest)
        elseif sub == "service"
            return service_main(rest)
        elseif sub == "setup"
            return setup_main(rest)
        else
            DistSSHKit.print_cli_error("unknown subcommand: $sub")
            show_usage(io=stderr)
            return 1
        end
    catch e
        e isa ArgumentError || rethrow()
        DistSSHKit.print_cli_error(e.msg)
        return 1
    end
end

if VERSION >= v"1.12"
    Base.eval(@__MODULE__, :(@main))
end

end # module DistSSHQueue
