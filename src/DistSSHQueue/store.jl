using TOML

"""Jobs file for a queue host: `~/.distsshqueue/jobs.toml` under `home`."""
function default_store_path(; home::AbstractString = homedir())::String
    return joinpath(home, ".distsshqueue", "jobs.toml")
end

const _STORE_LOCK_STALE_SEC = 30.0

function _store_lock_pid_path(lockdir::AbstractString)::String
    return joinpath(lockdir, "pid")
end

function _store_lock_start_path(lockdir::AbstractString)::String
    return joinpath(lockdir, "start")
end

function _missing_path_io(e)::Bool
    if e isa Base.SystemError
        return e.errnum == Base.Libc.ENOENT || e.errnum == Base.Libc.ENOTDIR
    end
    return e isa Base.IOError && (e.code == Base.UV_ENOENT || e.code == Base.UV_ENOTDIR)
end

"""`(pid, start)` from pid text. `start` is `nothing` when the text is only a pid.

A second line is accepted so a file written before the start key moved to its
own file still compares. New writes are one line. The pid line stays a single
integer so an older DistSSHQueue can `tryparse` it.
"""
function _parse_pid_text(raw::AbstractString)
    s = strip(String(raw))
    isempty(s) && return nothing
    lines = split(s, '\n')
    pid = tryparse(Int, strip(String(lines[1])))
    pid === nothing && return nothing
    start = nothing
    if length(lines) >= 2
        st = strip(String(lines[2]))
        !isempty(st) && (start = String(st))
    end
    return (pid = Int(pid), start = start)
end

"""Start key beside a pid. Blank text is `nothing`."""
function _start_text(raw::AbstractString)::Union{Nothing, String}
    s = strip(String(raw))
    return isempty(s) ? nothing : s
end

"""Pid record. A sidecar start key wins over a second line in the pid text."""
function _pid_record_from(pid_text::AbstractString, start_text::AbstractString)
    rec = _parse_pid_text(pid_text)
    rec === nothing && return nothing
    side = _start_text(start_text)
    side === nothing && return rec
    return (pid = rec.pid, start = side)
end

"""OS start key.

macOS `ps -o lstart=` follows the process locale and timezone. That `ps` is
started with `addenv` (`LC_ALL=C`, `TZ=UTC0`), so this process's `ENV` is
unchanged and a job task cannot inherit those values. Linux reads `/proc`
through `DistSSHRun.kit_process_start_key` and does not run `ps`. A `.start`
written by the previous `withenv` call is the same `ps` text.
"""
function _process_start_key(pid::Integer)::Union{Nothing, String}
    pid <= 0 && return nothing
    Sys.isapple() && return _macos_ps_start_key(pid)
    return DistSSHRun.kit_process_start_key(pid)
end

function _macos_ps_start_key(pid::Integer)::Union{Nothing, String}
    try
        cmd = addenv(`ps -o lstart= -p $(Int(pid))`, "LC_ALL" => "C", "TZ" => "UTC0")
        s = strip(read(cmd, String))
        return isempty(s) ? nothing : s
    catch
        return nothing
    end
end

"""Start key of this process, read once. `serve!` polls the pid file every tick."""
const _OWN_START = Ref{Union{Nothing, String}}(nothing)
const _OWN_START_READY = Ref(false)

function _own_start_key()::Union{Nothing, String}
    _OWN_START_READY[] && return _OWN_START[]
    _OWN_START[] = _process_start_key(getpid())
    _OWN_START_READY[] = true
    return _OWN_START[]
end

"""Start key for `pid`. This process uses the cached value."""
function _start_key(pid::Integer)::Union{Nothing, String}
    return pid == getpid() ? _own_start_key() : _process_start_key(pid)
end

"""Alive, and the start key matches when one was stored and can be read.

No stored key keeps the old `process_alive` check. `EPERM` still counts as
alive there. A stored key that cannot be read also counts as alive, so a
failed `ps` does not drop a lock or a serve. A key that is read and differs
is a reused pid.
"""
function _pid_record_running(rec; current::Function = _start_key)::Bool
    process_alive(rec.pid) || return false
    rec.start === nothing && return true
    cur = current(rec.pid)
    cur === nothing && return true
    return cur == rec.start
end

function _read_lock_record(lockdir::AbstractString)
    p = _store_lock_pid_path(lockdir)
    text = try
        read(p, String)
    catch e
        # The holder removes the lock directory between the existence check and this open.
        _missing_path_io(e) && return nothing
        rethrow()
    end
    start = try
        read(_store_lock_start_path(lockdir), String)
    catch e
        _missing_path_io(e) && return _pid_record_from(text, "")
        rethrow()
    end
    return _pid_record_from(text, start)
end

function _read_lock_pid(lockdir::AbstractString)::Union{Nothing, Int}
    rec = _read_lock_record(lockdir)
    rec === nothing && return nothing
    return rec.pid
end

"""Whether a leftover lock directory can be taken.

A live pid is never stale when its start key matches or cannot be read. A
dead pid, or a live pid whose start key was read and differs, is stale. A
lock with no pid is stale only after [`_STORE_LOCK_STALE_SEC`](@ref) seconds.
The holder writes the pid just after `mkdir`, so a fresh directory is left
alone.
"""
function _store_lock_stale(lockdir::AbstractString; now::Float64 = time())::Bool
    # `stat` does not throw when the path is gone. It returns a zero `StatStruct`,
    # so one call is both the existence check and the mtime.
    st = stat(lockdir)
    isdir(st) || return false
    rec = _read_lock_record(lockdir)
    if rec !== nothing
        return !_pid_record_running(rec)
    end
    return now - st.mtime > _STORE_LOCK_STALE_SEC
end

"""Move `lockdir` aside and delete it. `false` when another process took it."""
function _steal_store_lock(lockdir::AbstractString)::Bool
    _store_lock_stale(lockdir) || return false
    trash = string(lockdir, ".stale.", getpid(), ".", time_ns())
    try
        mv(lockdir, trash)
    catch
        return false
    end
    rm(trash; force = true, recursive = true)
    return true
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
            # Holder still has it, or they just released it (EEXIST then !isdir).
            if e isa Base.IOError && e.code == Base.UV_EEXIST
                if _store_lock_stale(lockdir) && _steal_store_lock(lockdir)
                    continue
                end
                sleep(0.05)
                continue
            end
            rethrow()
        end
        try
            write(_store_lock_pid_path(lockdir), string(getpid()))
            key = _own_start_key()
            if key === nothing
                rm(_store_lock_start_path(lockdir); force = true)
            else
                write(_store_lock_start_path(lockdir), key)
            end
        catch e
            # ENOENT means this directory is already gone. `rm` could delete a
            # lock another process created in its place.
            _missing_path_io(e) && continue
            rm(lockdir; force = true, recursive = true)
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

const _JOBS_NOT_LIST_WARNED = Set{String}()
const _JOBS_NOT_LIST_LOCK = ReentrantLock()

"""One parse: `:absent`, `:list` plus rows, `:not_list`, or `:bad_toml`."""
function _jobs_table(path::AbstractString)::Tuple{Symbol, Any}
    isfile(path) || return (:absent, nothing)
    raw = try
        TOML.parsefile(String(path))
    catch e
        e isa TOML.ParserError && return (:bad_toml, nothing)
        rethrow()
    end
    raw isa AbstractDict || return (:not_list, nothing)
    haskey(raw, "jobs") || return (:absent, nothing)
    rows = raw["jobs"]
    return rows isa AbstractVector ? (:list, rows) : (:not_list, nothing)
end

function _warn_jobs_not_list(path::AbstractString)
    p = abspath(String(path))
    fresh = lock(_JOBS_NOT_LIST_LOCK) do
        p in _JOBS_NOT_LIST_WARNED && return false
        push!(_JOBS_NOT_LIST_WARNED, p)
        return true
    end
    fresh || return nothing
    DistSSHRun.print_warn(
        "jobs store has a jobs value that is not a list; leaving the file unchanged: $p. DistSSHQueue 0.10 will reject this file.",
    )
    return nothing
end

function _jobs_store_bad_toml(path::AbstractString)
    return ArgumentError("jobs store is not valid TOML: $path")
end

function _jobs_store_not_list(path::AbstractString)
    return ArgumentError("jobs store has a jobs value that is not a list: $path")
end

function _jobs_store_bad_row(path::AbstractString)
    return ArgumentError(
        "jobs store has a job row that is missing a field or has the wrong type: $path",
    )
end

function _row_string(v, path::AbstractString)::String
    v isa AbstractString || throw(_jobs_store_bad_row(path))
    return String(v)
end

function _row_dt(v, path::AbstractString)::DateTime
    v isa DateTime && return v
    v isa AbstractString || throw(_jobs_store_bad_row(path))
    try
        return DateTime(String(v))
    catch e
        e isa ArgumentError || rethrow()
        throw(_jobs_store_bad_row(path))
    end
end

"""Field conversion only. A `MethodError` inside `Job` still propagates."""
function _job_row(row, path::AbstractString)::Job
    row isa AbstractDict || throw(_jobs_store_bad_row(path))
    try
        hosts = row["hosts"]
        hosts isa AbstractVector || throw(_jobs_store_bad_row(path))
        kw = get(row, "kwargs", Dict{String, Any}())
        kw isa AbstractDict || throw(_jobs_store_bad_row(path))
        cleaned_kw = Dict{String, Any}()
        for (k, v) in kw
            k isa AbstractString || throw(_jobs_store_bad_row(path))
            cleaned_kw[String(k)] = v
        end
        started = get(row, "started_at", "")
        finished = get(row, "finished_at", "")
        err = get(row, "error", "")
        result_path = get(row, "result_path", "")
        cleaned = Dict{String, Any}(
            "id" => _row_string(row["id"], path),
            "kind" => _row_string(row["kind"], path),
            "script" => _row_string(row["script"], path),
            "hosts" => String[_row_string(h, path) for h in hosts],
            "state" => _row_string(row["state"], path),
            "queued_at" => _row_dt(row["queued_at"], path),
            "started_at" => _row_dt_text(started, path),
            "finished_at" => _row_dt_text(finished, path),
            "error" => _row_text(err, path),
            "result_path" => _row_text(result_path, path),
            "kwargs" => cleaned_kw,
        )
        return job_from_toml(cleaned)
    catch e
        e isa KeyError && throw(_jobs_store_bad_row(path))
        if e isa ArgumentError && !startswith(e.msg, "jobs store has a job row")
            throw(_jobs_store_bad_row(path))
        end
        rethrow()
    end
end

function _row_text(v, path::AbstractString)::String
    v isa AbstractString || throw(_jobs_store_bad_row(path))
    return String(v)
end

"""Empty stays empty. A non-empty value must be a `DateTime` string."""
function _row_dt_text(v, path::AbstractString)::String
    text = _row_text(v, path)
    isempty(text) || _row_dt(text, path)
    return text
end

function save_jobs(path::AbstractString, jobs::AbstractVector{Job})
    p = String(path)
    shape, _ = _jobs_table(p)
    if shape === :bad_toml
        throw(_jobs_store_bad_toml(p))
    elseif shape === :not_list
        throw(_jobs_store_not_list(p))
    end
    mkpath(dirname(p))
    data = Dict{String, Any}("jobs" => [job_to_toml(j) for j in jobs])
    tmp = string(p, ".tmp.", getpid(), ".", time_ns())
    try
        open(tmp, "w") do io
            TOML.print(io, data)
        end
        mv(tmp, p; force = true)
    catch
        rm(tmp; force = true)
        rethrow()
    end
    return nothing
end

function read_jobs(path::AbstractString)::Vector{Job}
    shape, rows = _jobs_table(path)
    if shape === :bad_toml
        throw(_jobs_store_bad_toml(path))
    elseif shape === :not_list
        _warn_jobs_not_list(path)
        return Job[]
    elseif shape !== :list
        return Job[]
    end
    return Job[_job_row(r, String(path)) for r in rows]
end

store_pid_path(store::AbstractString)::String = string(store, ".pid")

"""Start key for [`store_pid_path`](@ref). Absent on a pidfile written by an
older DistSSHQueue. The pid file itself stays one integer.
"""
store_pid_start_path(store::AbstractString)::String = string(store_pid_path(store), ".start")

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

"""Live serve pid from the store pidfile, or `nothing`.

[`store_pid_start_path`](@ref) is the OS start key. A reused pid whose key
was read and differs is `nothing`. A missing key, or a key that cannot be
read, keeps the old alive-pid check.
"""
function _read_serve_record(store::AbstractString)
    p = store_pid_path(store)
    isfile(p) || return nothing
    start = isfile(store_pid_start_path(store)) ? read(store_pid_start_path(store), String) : ""
    return _pid_record_from(read(p, String), start)
end

function serve_pid(store::AbstractString)::Union{Nothing, Int}
    rec = _read_serve_record(store)
    rec === nothing && return nothing
    _pid_record_running(rec) || return nothing
    return rec.pid
end

"""Is a `serve` for `store` already running (pidfile + live process)?"""
serve_alive(store::AbstractString)::Bool = serve_pid(store) !== nothing

function write_pid_file(store::AbstractString)
    mkpath(dirname(store))
    dest = store_pid_path(store)
    tmp = string(dest, ".tmp.", getpid(), ".", time_ns())
    try
        write(tmp, string(getpid()))
        mv(tmp, dest; force = true)
        key = _own_start_key()
        sp = store_pid_start_path(store)
        if key === nothing
            rm(sp; force = true)
        else
            write(sp, key)
        end
    catch
        rm(tmp; force = true)
        rethrow()
    end
    record_test_serve_pid!(getpid())
    return nothing
end

"""Claim the serve pid under the store lock.

Returns another live pid when one is already running, otherwise `nothing`
after this process owns the pidfile. A dead pidfile is replaced. The lock
closes the window where two processes both observe no live pid and both
enter `load!`.
"""
function claim_serve!(store::AbstractString)::Union{Nothing, Int}
    return with_store_lock(store) do
        existing = serve_pid(store)
        if existing !== nothing && existing != getpid()
            return existing
        end
        write_pid_file(store)
        return nothing
    end
end

"""If tests set `DISTSSHQUEUE_TEST_PIDS` and `DISTSSHKIT_TEST=1`, append this serve pid.

Harness `atexit` / parent-death reaper reads that list. Production leaves the
env unset, so this is a no-op.
"""
function record_test_serve_pid!(pid::Integer)
    _test_doubles_on() || return nothing
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

function remove_pid_file(store::AbstractString)
    rm(store_pid_path(store); force = true)
    rm(store_pid_start_path(store); force = true)
    return nothing
end

"""Remove the pidfile when it still names `pid` and `start`.

`start === nothing` matches a one-line file. A serve that rewrote the file
during the wait is left alone. Holds the store lock.
"""
function remove_pid_file_if!(store::AbstractString, pid::Integer; start = nothing)::Bool
    return with_store_lock(store) do
        path = store_pid_path(store)
        isfile(path) || return false
        rec = _read_serve_record(store)
        rec === nothing && return false
        rec.pid == pid || return false
        rec.start == start || return false
        remove_pid_file(store)
        return true
    end
end

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

"""SIGTERM a serve recorded in the store pidfile. Does not kill this process.

The pidfile is removed only when it still names that pid and start key, and
only under the store lock. A live pid with a different start key is not
signaled. A serve that claimed the file during the wait is left alone.
"""
function stop_serve!(store::AbstractString)::Bool
    target = with_store_lock(store) do
        path = store_pid_path(store)
        isfile(path) || return nothing
        rec = _read_serve_record(store)
        if rec === nothing
            remove_pid_file(store)
            return nothing
        end
        return rec
    end
    target === nothing && return false
    # This process. A readable start key that differs is not removed by signaling.
    if target.pid == getpid()
        own = _own_start_key()
        if target.start === nothing || own === nothing || target.start == own
            return false
        end
        remove_pid_file_if!(store, target.pid; start = target.start)
        return false
    end
    if _pid_record_running(target)
        try
            run(pipeline(`kill $(target.pid)`; stdout = devnull, stderr = devnull))
        catch
        end
        for _ in 1:40
            _pid_record_running(target) || break
            sleep(0.05)
        end
    elseif process_alive(target.pid)
        # Alive under a different start key. Do not signal that process.
        remove_pid_file_if!(store, target.pid; start = target.start)
        return false
    end
    # A replacement serve may have claimed the pidfile during the wait. The
    # targeted serve was still signaled, so report success; leave that file.
    remove_pid_file_if!(store, target.pid; start = target.start)
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
