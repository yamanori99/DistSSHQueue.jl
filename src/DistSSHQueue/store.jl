using TOML

function default_store_path(; home::AbstractString = homedir())::String
    return joinpath(home, ".distsshqueue", "jobs.toml")
end

function with_store_lock(f, path::AbstractString)
    return with_store_lock(f, String(path))
end

function with_store_lock(f, path::String)
    lockdir = string(path, ".lock")
    mkpath(dirname(path))
    while true
        try
            mkdir(lockdir)
        catch e
            # Holder still has it, or they just `rm`'d it (EEXIST then !isdir). Retry.
            if e isa Base.IOError && e.code == Base.UV_EEXIST
                sleep(0.05)
                continue
            end
            rethrow()
        end
        try
            return f()
        finally
            rm(lockdir; force = true, recursive = true)
        end
    end
    return
end

function _dt(x)::Union{Nothing, DateTime}
    x === nothing && return nothing
    x isa DateTime && return x
    return DateTime(String(x))
end

function job_to_toml(j::Job)::Dict{String, Any}
    return Dict{String, Any}(
        "id" => j.id,
        "kind" => String(j.kind),
        "script" => j.script,
        "hosts" => copy(j.hosts),
        "state" => String(j.state),
        "queued_at" => string(j.queued_at),
        "started_at" => j.started_at === nothing ? "" : string(j.started_at),
        "finished_at" => j.finished_at === nothing ? "" : string(j.finished_at),
        "error" => j.error === nothing ? "" : j.error,
        "result_path" => j.result_path === nothing ? "" : j.result_path,
        "kwargs" => Dict{String, Any}(j.kwargs),
    )
end

function job_from_toml(d::AbstractDict)::Job
    err = String(get(d, "error", ""))
    result_path = String(get(d, "result_path", ""))
    started = String(get(d, "started_at", ""))
    finished = String(get(d, "finished_at", ""))
    kw = get(d, "kwargs", Dict{String, Any}())
    return Job(;
        id = String(d["id"]),
        kind = Symbol(d["kind"]),
        script = String(d["script"]),
        hosts = String[String(h) for h in d["hosts"]],
        state = Symbol(d["state"]),
        queued_at = _dt(d["queued_at"]),
        started_at = isempty(started) ? nothing : _dt(started),
        finished_at = isempty(finished) ? nothing : _dt(finished),
        error = isempty(err) ? nothing : err,
        result_path = isempty(result_path) ? nothing : result_path,
        kwargs = Dict{String, Any}(String(k) => v for (k, v) in kw),
    )
end

function save_jobs(path::AbstractString, jobs::AbstractVector{Job})
    p = String(path)
    mkpath(dirname(p))
    data = Dict{String, Any}("jobs" => [job_to_toml(j) for j in jobs])
    open(p, "w") do io
        TOML.print(io, data)
    end
    return nothing
end

function read_jobs(path::AbstractString)::Vector{Job}
    isfile(path) || return Job[]
    raw = TOML.parsefile(String(path))
    rows = get(raw, "jobs", nothing)
    rows isa AbstractVector || return Job[]
    return Job[job_from_toml(r) for r in rows]
end

store_pid_path(store::AbstractString)::String = string(store, ".pid")

"""Store file mtime (seconds), or `-1.0` when it does not exist yet.
`serve!` uses this to skip re-locking / re-parsing an unchanged store."""
_store_mtime(store::AbstractString)::Float64 = isfile(store) ? mtime(store) : -1.0

"""Whether OS `pid` is live, without forking a `kill` subprocess.

`serve!` polls this every `interval` (default 0.2s), so a fork/exec per tick is
wasteful; use the same non-killing `kill(pid, 0)` syscall DistSSHKit's own
`kit.pid` liveness check uses. `EPERM` means the pid exists but is owned by
another user — still alive."""
function process_alive(pid::Integer)::Bool
    pid > 0 || return false
    Sys.isunix() || return _process_alive_fallback(pid)
    try
        Base.Libc.errno(0)
        rc = ccall(:kill, Cint, (Cint, Cint), pid, 0)
        rc == 0 && return true
        return Base.Libc.errno() == Cint(1) # EPERM: exists, owned by someone else
    catch
        return _process_alive_fallback(pid)
    end
end

function _process_alive_fallback(pid::Integer)::Bool
    try
        return success(run(pipeline(`kill -0 $pid`; stdout = devnull, stderr = devnull)))
    catch
        return false
    end
end

"""Live serve pid from the store pidfile, or `nothing`."""
function serve_pid(store::AbstractString)::Union{Nothing, Int}
    p = store_pid_path(store)
    isfile(p) || return nothing
    pid = tryparse(Int, strip(read(p, String)))
    pid === nothing && return nothing
    process_alive(pid) || return nothing
    return pid
end

"""Is a `serve` for `store` already running (pidfile + live process)?"""
serve_alive(store::AbstractString)::Bool = serve_pid(store) !== nothing

function write_pid_file(store::AbstractString)
    mkpath(dirname(store))
    write(store_pid_path(store), string(getpid()))
    record_test_serve_pid!(getpid())
    return nothing
end

"""If tests set `DISTSSHQUEUE_TEST_PIDS`, append this serve pid.

Harness `atexit` / parent-death reaper reads that list. Production leaves the
env unset, so this is a no-op.
"""
function record_test_serve_pid!(pid::Integer)
    path = String(get(ENV, "DISTSSHQUEUE_TEST_PIDS", ""))
    isempty(path) && return nothing
    try
        open(path, "a") do io
            println(io, Int(pid))
        end
    catch
    end
    return nothing
end

remove_pid_file(store::AbstractString) = rm(store_pid_path(store); force = true)

"""Latch that `stop` leaves next to the store so `submit` will not auto-serve.
An explicit `serve` clears it; that is the only thing that resumes serve."""
store_stop_path(store::AbstractString)::String = string(store, ".stopped")

serve_stopped(store::AbstractString)::Bool = isfile(store_stop_path(store))

function set_stopped!(store::AbstractString)
    mkpath(dirname(store))
    write(store_stop_path(store), "")
    return nothing
end

clear_stopped!(store::AbstractString) = rm(store_stop_path(store); force = true)

"""SIGTERM a serve recorded in the store pidfile. Does not kill this process."""
function stop_serve!(store::AbstractString)::Bool
    p = store_pid_path(store)
    isfile(p) || return false
    pid = tryparse(Int, strip(read(p, String)))
    if pid === nothing
        remove_pid_file(store)
        return false
    end
    pid == getpid() && return false
    if process_alive(pid)
        try
            run(pipeline(`kill $pid`; stdout = devnull, stderr = devnull))
        catch
        end
        for _ in 1:40
            process_alive(pid) || break
            sleep(0.05)
        end
    end
    remove_pid_file(store)
    return true
end

function fail_stale_running!(jobs::Vector{Job})
    for j in jobs
        j.state === :running || continue
        kit_child_alive(j) && continue
        settle_lost_kit_child!(j)
    end
    return jobs
end

function load_jobs(path::AbstractString)::Vector{Job}
    return fail_stale_running!(read_jobs(path))
end
