"""Like Kit `go!`/`drive!`: no separate "start the server" step. If no `serve` is
watching `store`, spawn one detached (log next to the store). Opt out with
`DISTSSHQUEUE_NO_AUTOSERVE=1` (tests, or a harness that manages `serve` itself).
A prior `stop` also holds it off until an explicit `serve` clears the latch.
"""
function ensure_serve!(store::AbstractString)::Bool
    get(ENV, "DISTSSHQUEUE_NO_AUTOSERVE", "") == "1" && return false
    serve_stopped(store) && return false
    serve_alive(store) && return false
    julia = default_julia_bin()
    project = default_queue_env()
    log = string(store, ".log")
    mkpath(dirname(log))
    spawn_detached_serve!(julia, project, log)
    print_serve_started(log)
    return true
end

"""Start `serve` so this Julia process can still exit.

`run(...; wait=false)` keeps a libuv handle. `submit` then never exits, so
client `qhost:HOST` ssh hangs after `Started serve`. A short-lived `sh -c ... &`
lets serve outlive `submit` without that handle. Windows has no serve
unit; keep the Julia spawn there.
"""
function serve_tag()::String
    return String(get(ENV, "DISTSSHQUEUE_SERVE_TAG", ""))
end

function with_serve_tag(cmd::Cmd)::Cmd
    tag = serve_tag()
    isempty(tag) && return cmd
    return addenv(cmd, "DISTSSHQUEUE_SERVE_TAG" => tag)
end

"""Unix `sh -c` body for autoserve. `DISTSSHQUEUE_SERVE_TAG` is copied onto
the child via `env` so a test reaper can `ps` / `kill` it after Ctrl-C.
Production leaves the env unset; the script is then plain `nohup julia … &`.
"""
function detached_serve_script(julia::AbstractString, project::AbstractString, log::AbstractString)::String
    jl = sh_single_quote(julia)
    proj = sh_single_quote(project)
    lg = sh_single_quote(log)
    inner = "$jl --startup-file=no --project=$proj -m DistSSHQueue serve </dev/null >>$lg 2>&1"
    tag = serve_tag()
    if !isempty(tag)
        inner = "env DISTSSHQUEUE_SERVE_TAG=$(sh_single_quote(tag)) $inner"
    end
    return "nohup $inner &"
end

function spawn_detached_serve!(julia::AbstractString, project::AbstractString, log::AbstractString)
    if Sys.iswindows()
        io = open(log, "a")
        cmd = with_serve_tag(`$julia --startup-file=no --project=$project -m DistSSHQueue serve`)
        run(pipeline(detach(cmd); stdin=devnull, stdout=io, stderr=io); wait=false)
        close(io)
        return nothing
    end
    run(`/bin/sh -c $(detached_serve_script(julia, project, log))`)
    return nothing
end

"""SIGTERM processes that carry `DISTSSHQUEUE_SERVE_TAG` or a test pid list.

Does not kill the caller. Used by the test harness after interrupt / parent death.
No-op when `tag` is empty.
"""
function reap_serve_tag!(tag::AbstractString)
    isempty(tag) && return nothing
    Sys.iswindows() && return nothing
    self = getpid()
    needle = "DISTSSHQUEUE_SERVE_TAG=" * tag
    try
        for line in eachline(`ps axeww`)
            occursin(needle, line) || continue
            pid = tryparse(Int, first(split(strip(line); limit=2)))
            pid === nothing && continue
            pid == self && continue
            try
                run(pipeline(`kill $pid`; stdout=devnull, stderr=devnull))
            catch
            end
        end
    catch
    end
    list = String(get(ENV, "DISTSSHQUEUE_TEST_PIDS", ""))
    if !isempty(list) && isfile(list)
        for line in eachline(list)
            pid = tryparse(Int, strip(line))
            pid === nothing && continue
            pid == self && continue
            try
                run(pipeline(`kill $pid`; stdout=devnull, stderr=devnull))
            catch
            end
        end
    end
    return nothing
end

function serve_cli(args::Vector{String})::Cint
    interval = 0.2
    i = 1
    while i <= length(args)
        if args[i] == "--interval" && i < length(args)
            interval = parse(Float64, args[i+1])
            i += 2
        elseif args[i] in ("-h", "--help")
            show_usage(; command="serve")
            return 0
        else
            throw(ArgumentError("unknown serve option: $(args[i])"))
        end
    end
    serve(; store=store_path(), interval=interval)
    return 0
end

"""Stop serve and latch it off. Keeps config / store / OS unit.
`submit` will not auto-serve until an explicit `serve` clears the latch."""
function stop_cli(args::Vector{String})::Cint
    for a in args
        a in ("-h", "--help") && (show_usage(; command="stop"); return 0)
        throw(ArgumentError("unknown stop option: $(a)"))
    end
    store = store_path()
    was_running = stop_serve!(store)
    set_stopped!(store)
    print_serve_stopped(store, was_running)
    return 0
end
