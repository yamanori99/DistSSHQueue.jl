"""FIFO table: one DistSSHKit job at a time. Placement tokens are Kit's, not a Queue ceiling."""
mutable struct Queue
    lock::ReentrantLock
    jobs::Vector{Job}
    store::Union{Nothing,String}
    runner::Function
    live_id::Union{Nothing,String}
    allowed::Union{Nothing, HostAllow}
    follow_config::Bool
end

function Queue(;
    store::Union{Nothing,AbstractString}=nothing,
    runner::Function=run_kit,
    allowed::Union{Nothing,AbstractVector,AbstractSet,AbstractDict}=nothing,
    follow_config::Bool=false,
)
    follow_config && allowed !== nothing && throw(ArgumentError(
        "`follow_config` reads config hosts; omit `allowed`",
    ))
    st = store === nothing ? nothing : String(store)
    names = if follow_config
        config_host_names(load_config())
    else
        as_host_allow(allowed)
    end
    return Queue(ReentrantLock(), Job[], st, runner, nothing, names, follow_config)
end

function _index_id(jobs::Vector{Job}, id::AbstractString)
    for i in eachindex(jobs)
        jobs[i].id == id && return i
    end
    return nothing
end

function _index_state(jobs::Vector{Job}, state::Symbol)
    for i in eachindex(jobs)
        jobs[i].state === state && return i
    end
    return nothing
end

"""Exact id, or a unique `startswith` prefix. Ambiguous / unknown throw."""
function _resolve_id(jobs::Vector{Job}, token::AbstractString)::String
    t = String(token)
    isempty(t) && throw(ArgumentError("unknown job $(repr(t))"))
    i = _index_id(jobs, t)
    i !== nothing && return t
    hits = String[jobs[k].id for k in eachindex(jobs) if startswith(jobs[k].id, t)]
    isempty(hits) && throw(ArgumentError("unknown job $(repr(t))"))
    length(hits) > 1 && throw(ArgumentError("ambiguous job id $(repr(t))"))
    return hits[1]
end

"""Kit project: `DISTRIBUTED_PROJECT_ROOT`, else the `Project.toml` above `cwd`, else `cwd`.

Not the Julia `--project=` that loaded DistSSHQueue.
"""
function job_project(; cwd::AbstractString=pwd())::String
    env = strip(get(ENV, "DISTRIBUTED_PROJECT_ROOT", ""))
    isempty(env) || return DistSSHKit.canonical_local_path(env)
    host = DistSSHKit.resolve_pkg_project_dir(cwd)
    root = isfile(joinpath(host, "Project.toml")) ? String(host) : String(cwd)
    return DistSSHKit.canonical_local_path(root)
end

"""Worker path Kit would use for this queue-host project (`remote=` or Kit default / ENV).

Matches DistSSHKit 0.4.2 detached `execute!` (`remote_env_project_root`):
`~…` stays a remote-shell layout; an absolute path is canonical. Empty `remote=`
falls through to Kit's default / `DISTRIBUTED_REMOTE_PROJECT_ROOT`.
"""
function kit_worker_root(project::AbstractString, kw::AbstractDict)::String
    r = get(kw, "remote", nothing)
    raw = if r isa AbstractString
        s = strip(String(r))
        isempty(s) ? nothing : s
    else
        nothing
    end
    layout = if raw !== nothing
        raw
    else
        DistSSHKit.resolve_remote_project_root(DistSSHKit.canonical_local_path(project))
    end
    return DistSSHKit.remote_env_project_root(layout)
end

"""Refuse two different queue-host projects that Kit would place on the same worker path.

Does not rename. Does not `setup --delete`. Same project (re-submit) is fine.
"""
function reject_worker_root_collision!(jobs::Vector{Job}, project::AbstractString, kw::AbstractDict)
    proj = DistSSHKit.canonical_local_path(project)
    root = kit_worker_root(proj, kw)
    for j in jobs
        other = get(j.kwargs, "project", nothing)
        other isa AbstractString || continue
        op = DistSSHKit.canonical_local_path(String(other))
        op == proj && continue
        kit_worker_root(op, j.kwargs) == root || continue
        throw(ArgumentError(
            "project $(proj) and $(op) both deploy to $(root) on workers. " *
            "Use a unique ~/parent/Repo.jl; do not pin DISTRIBUTED_REMOTE_PROJECT_ROOT in shared config. " *
            "Queue does not rename or setup --delete.",
        ))
    end
    return nothing
end

resolve_script(path::AbstractString) = DistSSHKit.canonical_local_path(path)

function as_host_allow(allowed)::Union{Nothing, HostAllow}
    allowed === nothing && return nothing
    if allowed isa AbstractDict
        out = HostAllow()
        for (k, v) in allowed
            n = String(k)
            if n == "parent" || startswith(n, "parent:") || startswith(n, "child:")
                n = kit_ssh_name(n)
            elseif isempty(n)
                continue
            end
            cap = if v === nothing
                nothing
            else
                _positive_n(Int(v), string(n, ":", v))
            end
            out[n] = cap
        end
        return out
    end
    return parse_host_caps(allowed)
end

function reject_host_token!(allow::Union{Nothing, HostAllow}, t::AbstractString)
    parsed = DistSSHKit.parse_placement_token(t)
    allow === nothing && return parsed
    if !haskey(allow, parsed.name)
        throw(ArgumentError(
            "Kit name $(repr(parsed.name)) is not allowed (token $(repr(t)))",
        ))
    end
    cap = allow[parsed.name]
    cap === nothing && return parsed
    jobn = parsed.n
    if jobn === nothing
        throw(ArgumentError(
            "Kit name $(repr(parsed.name)) needs :N (max $(cap); token $(repr(t)))",
        ))
    end
    if jobn > cap
        throw(ArgumentError(
            "Kit :N $(jobn) exceeds max $(cap) for $(repr(parsed.name)) (token $(repr(t)))",
        ))
    end
    return parsed
end


function kit_kwargs(d::Dict{String,Any})
    isempty(d) && return NamedTuple()
    acc = Pair{Symbol,Any}[]
    for (k, v) in d
        key = Symbol(k)
        val = if key === :sync && v isa AbstractString && (v == "sync" || v == "rsync")
            Symbol(v)
        elseif key === :verbosity && v isa AbstractString
            Symbol(v)
        elseif key === :args && v isa AbstractVector
            String[String(x) for x in v]
        else
            v
        end
        push!(acc, key => val)
    end
    return (; acc...)
end

function kit_result_path(result)::Union{Nothing,String}
    hasproperty(result, :output_dir) || return nothing
    p = getproperty(result, :output_dir)
    p === nothing && return nothing
    s = strip(String(p))
    return isempty(s) ? nothing : s
end

function kit_result_path(j::Job, result)::Union{Nothing,String}
    p = kit_result_path(result)
    p !== nothing && return p
    od = get(j.kwargs, "output_dir", nothing)
    od === nothing && return nothing
    s = strip(String(od))
    return isempty(s) ? nothing : s
end

"""Throw with the richest detail the result carries (`KitRunResult`: `failed_step`
/ `exit_code`), so `Job.error` and the status `ERROR` column are actionable."""
function require_kit_ok(result)
    hasproperty(result, :ok) || return nothing
    getproperty(result, :ok) && return nothing
    kind = hasproperty(result, :kind) ? getproperty(result, :kind) : :run
    step = hasproperty(result, :failed_step) ? getproperty(result, :failed_step) : nothing
    code = hasproperty(result, :exit_code) ? getproperty(result, :exit_code) : nothing
    msg = "DistSSHKit $kind failed"
    step === nothing || (msg *= " at $(step)")
    (code === nothing || code == 0) || (msg *= " (exit $(code))")
    throw(ErrorException(msg))
end

"""Keywords DistSSHKit `execute!(...; detached=true)` accepts, from the job bag.

`yes` is always `true` (unattended child). `path_anchor` and other names are dropped.
`job_id` is not taken from the bag; `run_kit` passes `Job.id`.
Allow-list is DistSSHKit `execute_detached_accepts`.
"""
function execute_kwargs(j::Job)
    raw = kit_kwargs(j.kwargs)
    acc = Pair{Symbol,Any}[]
    for (k, v) in pairs(raw)
        k === :yes && continue
        k === :job_id && continue
        v === nothing && continue
        DistSSHKit.execute_detached_accepts(k; kind=j.kind) || continue
        push!(acc, k => v)
    end
    push!(acc, :yes => true)
    return (; acc...)
end

"""`output_dir` already recorded, else the job bag (Kit may still pick a default)."""
function kit_output_dir(j::Job)::Union{Nothing,String}
    p = j.result_path
    p !== nothing && return p
    od = get(j.kwargs, "output_dir", nothing)
    od === nothing && return nothing
    s = strip(String(od))
    return isempty(s) ? nothing : s
end

"""Set Kit `output_dir` before spawn so `:running` cancel and restart adopt need no submitter path.

Default leaf is `{project}/.distsshqueue/{kind}/{stem}_{id8}/` (same
layout as `fetch` dest). Kit remote slots use `relpath(output, project)`,
so a leaf next to `jobs.toml` (outside the job tree) makes `child:` `go`
exit 1. No-op if the bag already has `output_dir`.
"""
function ensure_kit_output_dir!(j::Job; store::Union{Nothing,AbstractString}=nothing)
    kit_output_dir(j) !== nothing && return nothing
    isfile(j.script) || return nothing
    proj = get(j.kwargs, "project", nothing)
    root = if proj isa AbstractString && !isempty(strip(String(proj)))
        String(proj)
    elseif store === nothing
        dirname(default_store_path())
    else
        dirname(String(store))
    end
    stem = splitext(basename(j.script))[1]
    isempty(stem) && (stem = "job")
    leaf = "$(stem)_$(_job_id8(j.id))"
    dir = joinpath(root, ".distsshqueue", String(j.kind), leaf)
    mkpath(dir)
    j.kwargs["output_dir"] = dir
    j.result_path = dir
    return nothing
end

"""Whether DistSSHKit's detached `kit.pid` still names this run (pid + start key)."""
function kit_child_alive(j::Job)::Bool
    dir = kit_output_dir(j)
    dir === nothing && return false
    return DistSSHKit.kit_pid_file_running(dir)
end

function kit_run_error_text(result)::String
    try
        require_kit_ok(result)
        return ""
    catch e
        e isa ErrorException || rethrow()
        return e.msg
    end
end

kit_run_error_text(::Job, result) = kit_run_error_text(result)

"""Pid gone: prefer `kit.result`, else `:failed` (`serve` lost `KitProcess`)."""
function settle_lost_kit_child!(j::Job)
    dir = kit_output_dir(j)
    rec = dir === nothing ? nothing : DistSSHKit.kit_result_from_dir(dir)
    j.finished_at = now(UTC)
    if rec === nothing
        j.state = :failed
        j.error = "serve restarted; running job marked failed"
        return j
    end
    rec.output_dir !== nothing && (j.result_path = String(rec.output_dir))
    try
        require_kit_ok(rec)
        j.state = :done
        j.error = nothing
    catch e
        e isa ErrorException || rethrow()
        j.state = :failed
        j.error = e.msg
    end
    return j
end

function _job_still_running(q::Queue, id::AbstractString)::Bool
    running = Ref(false)
    _with_store(q) do
        lock(q.lock) do
            reload_keep_live!(q)
            i = _index_id(q.jobs, id)
            running[] = i !== nothing && q.jobs[i].state === :running
            return nothing
        end
    end
    return running[]
end

function run_kit(j::Job, on_spawn; on_phase=Returns(nothing), still_running=Returns(true))
    _queue_kit_setup!(j, on_phase)
    on_phase(nothing)
    still_running() || return something(kit_output_dir(j), "")
    kp = DistSSHKit.execute!(
        j.kind,
        j.script,
        j.hosts;
        detached=true,
        job_id=j.id,
        execute_kwargs(j)...,
    )::DistSSHKit.KitProcess
    spawned = kit_result_path(kp)
    on_spawn(spawned)
    result = wait(kp)
    require_kit_ok(result)
    return kit_result_path(j, result)
end
run_kit(j::Job) = run_kit(j, Returns(nothing))

const NO_KIT_SETUP_ENV = "DISTSSHQUEUE_NO_KIT_SETUP"

function _set_job_phase!(q::Queue, id::AbstractString, ph)
    _with_store(q) do
        lock(q.lock) do
            reload_keep_live!(q)
            i = _index_id(q.jobs, id)
            i === nothing && return nothing
            if ph === nothing
                delete!(q.jobs[i].kwargs, "phase")
            else
                q.jobs[i].kwargs["phase"] = String(ph)
            end
            _persist!(q)
            return nothing
        end
    end
    return nothing
end

"""Kit session for per-job `setup!`. Same `remote` as `execute_kwargs` → `execute!`."""
function _kit_setup_session(j::Job, proj::AbstractString; workers=j.hosts)
    r = get(j.kwargs, "remote", nothing)
    remote = r isa AbstractString && !isempty(strip(String(r))) ? String(r) : nothing
    return DistSSHKit.KitSession(;
        project=String(proj),
        workers=workers,
        remote=remote,
        yes=true,
    )
end

"""`child:NAME[:N]` tokens only. Kit `setup!` refuses `parent` except `--juliaup`."""
function _kit_setup_child_tokens(hosts::AbstractVector{<:AbstractString})::Vector{String}
    out = String[]
    for raw in hosts
        DistSSHKit.is_parent_host_name(kit_ssh_name(raw)) && continue
        push!(out, String(raw))
    end
    return out
end

"""`Pkg.instantiate` the job tree on this host (Kit parent / queue host).

Uses `DEPOT_PATH` entries that are real depots. A path with `Project.toml`
(queue-env, the job tree) is skipped. Empty `JULIA_DEPOT_PATH` does not
install into the active `--project=`.
"""
function pkg_depots_for_instantiate()::Vector{String}
    out = String[]
    for p in DEPOT_PATH
        s = String(p)
        isempty(s) && continue
        isfile(joinpath(s, "Project.toml")) && continue
        push!(out, s)
    end
    isempty(out) && push!(out, joinpath(homedir(), ".julia"))
    return out
end

const _PKG_DEPOT_LOCK = ReentrantLock()

function _with_pkg_depots(f)
    lock(_PKG_DEPOT_LOCK) do
        old = copy(DEPOT_PATH)
        depots = pkg_depots_for_instantiate()
        empty!(DEPOT_PATH)
        append!(DEPOT_PATH, depots)
        try
            return f()
        finally
            empty!(DEPOT_PATH)
            append!(DEPOT_PATH, old)
        end
    end
end

function _queue_local_instantiate!(proj::AbstractString)
    root = DistSSHKit.canonical_local_path(proj)
    isfile(joinpath(root, "Project.toml")) || return nothing
    _with_pkg_depots() do
        Pkg.activate(root) do
            Pkg.instantiate()
            return nothing
        end
        return nothing
    end
    return nothing
end

"""Throw unless Kit `setup!` reported `ok` (instantiate / check)."""
function _require_kit_setup_ok!(result, step::AbstractString)
    hasproperty(result, :ok) || return nothing
    getproperty(result, :ok) && return nothing
    throw(ErrorException("DistSSHKit setup! $(step) failed"))
end

function _queue_kit_setup!(j::Job, on_phase)
    _queue_env_on(NO_KIT_SETUP_ENV) && return nothing
    proj = get(j.kwargs, "project", nothing)
    proj isa AbstractString || (proj = job_project())
    isdir(String(proj)) || return nothing
    children = _kit_setup_child_tokens(j.hosts)
    session = isempty(children) ? nothing : _kit_setup_session(j, String(proj); workers=children)
    if session !== nothing
        on_phase("rsync")
        # Kit rsync refuses a nonempty remote. Later jobs still instantiate.
        DistSSHKit.setup!(session, :rsync)
    end
    on_phase("instantiate")
    _queue_local_instantiate!(String(proj))
    if session !== nothing
        _require_kit_setup_ok!(DistSSHKit.setup!(session, :instantiate), "instantiate")
        on_phase("check")
        _require_kit_setup_ok!(DistSSHKit.setup!(session, :check), "check")
    end
    return nothing
end

function _persist!(q::Queue)
    return _persist!(q, q.store)
end
_persist!(::Queue, ::Nothing) = nothing
_persist!(q::Queue, store::String) = save_jobs(store, q.jobs)

function _with_store(f, q::Queue)
    return _with_store(f, q.store)
end
_with_store(f, ::Nothing) = f()
_with_store(f, store::String) = with_store_lock(f, store)

function _running(q::Queue)::Bool
    return any(j -> j.state === :running, q.jobs)
end

"""Load `store` (stale `:running` → `:failed`)."""
function load!(q::Queue)
    _with_store(q) do
        lock(q.lock) do
            _load_from_store!(q, q.store)
            return nothing
        end
    end
end
_load_from_store!(::Queue, ::Nothing) = nothing
function _load_from_store!(q::Queue, store::String)
    q.jobs = load_jobs(store)
    _persist!(q)
    return nothing
end

function _live_running(q::Queue)::Union{Nothing,Job}
    live = q.live_id
    live === nothing && return nothing
    i = _index_id(q.jobs, live)
    i === nothing && return nothing
    j = q.jobs[i]
    return j.state === :running ? j : nothing
end

"""Merge disk into `q.jobs`.

`serve` overlays its in-memory live row whenever disk still has that
id and the disk row is not `:cancelled` (stale `load!` may have written
`:failed` without `kit.pid`; a later `_finish!(:done)` must still land).
Client `cancel!` persists `:cancelled`: that row wins, and `live_id` is
dropped so `_finish!(:done)` after `terminate_run!` cannot resurrect the
run.
"""
function reload_keep_live!(q::Queue)
    return reload_keep_live!(q, q.store)
end
reload_keep_live!(::Queue, ::Nothing) = nothing
function reload_keep_live!(q::Queue, store::String)
    disk = read_jobs(store)
    live = _live_running(q)
    out = Job[]
    seen = false
    for d in disk
        if live !== nothing && d.id == live.id
            seen = true
            if d.state === :cancelled
                push!(out, d)
                q.live_id = nothing
                live = nothing
            else
                push!(out, live)
            end
        else
            push!(out, d)
        end
    end
    if live !== nothing && !seen
        push!(out, live)
    end
    q.jobs = out
    return nothing
end

"""Copy of the table."""
function jobs(q::Queue)::Vector{Job}
    lock(q.lock) do
        return Job[copy(j) for j in q.jobs]
    end
end

"""Copy of one row. `id` may be a unique prefix of the stored UUID."""
function job(q::Queue, id::AbstractString)::Job
    lock(q.lock) do
        full = _resolve_id(q.jobs, id)
        i = _index_id(q.jobs, full)
        return copy(q.jobs[i])
    end
end

function _submit!(q::Queue, kind::Symbol, script::AbstractString, hosts; kwargs...)
    toks = String[String(x) for x in hosts]
    fresh = q.follow_config ? config_host_names(load_config()) : nothing
    kw = Dict{String,Any}(String(k) => v for (k, v) in pairs(kwargs))
    haskey(kw, "project") || (kw["project"] = job_project())
    script_path = resolve_script(script)
    _with_store(q) do
        lock(q.lock) do
            q.follow_config && (q.allowed = fresh)
            allow = q.allowed
            for t in toks
                reject_host_token!(allow, t)
            end
            reload_keep_live!(q)
            reject_worker_root_collision!(q.jobs, String(kw["project"]), kw)
            raw_id = pop!(kw, "id", nothing)
            if raw_id !== nothing && _index_id(q.jobs, String(raw_id)) !== nothing
                throw(ArgumentError("job id already exists: $(repr(String(raw_id)))"))
            end
            j = if raw_id === nothing
                Job(; kind=kind, script=script_path, hosts=toks, kwargs=kw)
            else
                Job(; id=String(raw_id), kind=kind, script=script_path, hosts=toks, kwargs=kw)
            end
            push!(q.jobs, j)
            _persist!(q)
            return j.id
        end
    end
end

"""Enqueue. `kind` is a DistSSHKit `execute!` kind (`:go`, `:ride`, `:drive`).

`hosts` must be DistSSHKit 0.4 placement tokens (`parent[:N]` / `child:NAME[:N]`).
Missing `project` uses `job_project()` (cwd / `DISTRIBUTED_PROJECT_ROOT`), not the
serve env (`enable --queue-env` / Julia `--project=` that loaded Queue). Same verb as CLI `submit`.

`q.allowed` is the inventory (`Queue(; allowed=…)`), names plus optional max `:N`.
It does not read `config.toml`. CLI `submit` uses `Queue(; follow_config=true)` so each
enqueue re-reads `hosts` without restarting `serve`. `step!` does not
drop `:queued` rows when a name is later removed, and does not stop a
Kit job that is already `:running`.
"""
function submit!(q::Queue, script::AbstractString, hosts::AbstractString...; kind::Symbol=:go, kwargs...)
    return _submit!(q, kind, script, hosts; kwargs...)
end

function submit!(q::Queue, script::AbstractString, hosts::AbstractVector{<:AbstractString}; kind::Symbol=:go, kwargs...)
    return _submit!(q, kind, script, hosts; kwargs...)
end

"""Cancel `:queued`, or `:running` via DistSSHKit `terminate_run!` when the Kit output dir is known."""
function cancel!(q::Queue, id::AbstractString)::Bool
    action = _with_store(q) do
        lock(q.lock) do
            reload_keep_live!(q)
            full = _resolve_id(q.jobs, id)
            i = _index_id(q.jobs, full)
            j = q.jobs[i]
            if j.state === :queued
                j.state = :cancelled
                j.finished_at = now(UTC)
                _persist!(q)
                return :queued
            end
            j.state === :running || return :no
            out_dir = kit_output_dir(j)
            out_dir === nothing && return :no
            return (out_dir, j.kind, j.id)
        end
    end
    if action isa Tuple{String,Symbol,String}
        running_dir, running_kind, running_id = action
        DistSSHKit.terminate_run!(running_dir; kind=running_kind)
        _finish!(q, running_id, :cancelled, nothing; result_path=running_dir)
        return true
    end
    return action === :queued
end

function _set_running_result_path!(q::Queue, id::AbstractString, path::AbstractString)
    _with_store(q) do
        lock(q.lock) do
            reload_keep_live!(q)
            i = _index_id(q.jobs, id)
            i === nothing && return nothing
            j = q.jobs[i]
            j.state === :running || return nothing
            j.result_path = String(path)
            _persist!(q)
            return nothing
        end
    end
end

function _finish!(q::Queue, id::AbstractString, state::Symbol, err; result_path=nothing)
    _with_store(q) do
        lock(q.lock) do
            reload_keep_live!(q)
            i = _index_id(q.jobs, id)
            i === nothing && return nothing
            j = q.jobs[i]
            # `:cancelled` must win a race with the spawn `_finish!(:failed)`
            # or `:done` after `terminate_run!` (wait can look successful).
            if state === :cancelled
                (j.state === :running || j.state === :failed || j.state === :done) ||
                    return nothing
            else
                j.state === :running || return nothing
            end
            j.state = state
            j.finished_at = now(UTC)
            j.error = err === nothing ? nothing : String(err)
            delete!(j.kwargs, "phase")
            if result_path !== nothing
                j.result_path = String(result_path)
            end
            q.live_id == id && (q.live_id = nothing)
            _persist!(q)
            return nothing
        end
    end
end

function _start!(q::Queue, j::Job)
    j.state = :running
    j.started_at = now(UTC)
    q.live_id = j.id
    ensure_kit_output_dir!(j; store=q.store)
    _persist!(q)
    runner = q.runner
    id = j.id
    snap = copy(j)
    on_spawn = function (p)
        p isa AbstractString && _set_running_result_path!(q, id, p)
        return nothing
    end
    Threads.@spawn begin
        try
            out = if runner === run_kit
                run_kit(
                    snap, on_spawn;
                    on_phase=ph -> _set_job_phase!(q, id, ph),
                    still_running=() -> _job_still_running(q, id),
                )
            else
                runner(snap)
            end
            path = out isa AbstractString ? String(out) : nothing
            if path === nothing
                od = get(snap.kwargs, "output_dir", nothing)
                path = od === nothing ? nothing : String(od)
            end
            _finish!(q, id, :done, nothing; result_path=path)
        catch e
            _finish!(q, id, :failed, sprint(showerror, e))
        end
    end
    return nothing
end

const _ADOPT_LOST =
    "serve restarted; kit child exited (KitProcess lost; inspect RESULT / kit.result)"

"""If load kept a `:running` row because `kit.pid` is live, poll until it dies.

Does not spawn a second DistSSHKit child. Outcome from `kit.result` when present.
"""
function adopt_running!(q::Queue)
    snap = lock(q.lock) do
        i = _index_state(q.jobs, :running)
        i === nothing && return nothing
        j = q.jobs[i]
        kit_child_alive(j) || return nothing
        q.live_id = j.id
        return copy(j)
    end
    snap === nothing && return nothing
    id = snap.id
    dir = kit_output_dir(snap)
    Threads.@spawn begin
        while true
            live = lock(q.lock) do
                i = _index_id(q.jobs, id)
                i === nothing && return nothing
                copy(q.jobs[i])
            end
            live === nothing && return
            live.state === :running || return
            kit_child_alive(live) || break
            sleep(0.2)
        end
        rec = dir === nothing ? nothing : DistSSHKit.kit_result_from_dir(dir)
        path = if rec !== nothing && rec.output_dir !== nothing
            rec.output_dir
        else
            dir
        end
        if rec === nothing
            _finish!(q, id, :failed, _ADOPT_LOST; result_path=path)
        else
            try
                require_kit_ok(rec)
                _finish!(q, id, :done, nothing; result_path=path)
            catch e
                msg = e isa ErrorException ? e.msg : sprint(showerror, e)
                _finish!(q, id, :failed, msg; result_path=path)
            end
        end
    end
    return nothing
end

"""Start the FIFO head if nothing is `:running`. At most one Kit job."""
function step!(q::Queue)::Int
    return _with_store(q) do
        lock(q.lock) do
            reload_keep_live!(q)
            _running(q) && return 0
            i = _index_state(q.jobs, :queued)
            i === nothing && return 0
            _start!(q, q.jobs[i])
            return 1
        end
    end
end

function _running_copy(q::Queue)::Union{Nothing,Job}
    lock(q.lock) do
        i = _index_state(q.jobs, :running)
        i === nothing && return nothing
        return copy(q.jobs[i])
    end
end

function _serve_live_job(q::Queue)
    lock(q.lock) do
        ids = String[j.id for j in q.jobs]
        i = _index_state(q.jobs, :running)
        i === nothing && return nothing, ids
        return copy(q.jobs[i]), ids
    end
end

"""Load `store` (stale `:running` → `:failed`), then `step!` until interrupt. Ctrl-C stops serve, not Kit.

A second `serve` on the same store prints `Already running` and returns.
"""
function serve!(q::Queue; interval::Real=0.2)
    store = q.store
    if store isa String
        existing = serve_pid(store)
        if existing !== nothing && existing != getpid()
            print_serve_already(existing, store)
            return nothing
        end
        # Claim the pidfile before `load!`. Two autoserve processes otherwise both
        # pass `serve_alive` and the second `load_jobs` persists `:failed` on a
        # `:running` row that has no `kit.pid` yet.
        clear_stopped!(store)
        write_pid_file(store)
    end
    load!(q)
    adopt_running!(q)
    label = store isa String ? store : "(memory)"
    io = stdout
    print_serve_banner(getpid(), label)
    print_serve_idle_note(; io=io)
    draw = _serve_can_draw(io)
    flush(io)
    done = Ref(false)
    spin = if draw
        # SIGINT must hit the serve loop, not this sleep (else one Ctrl-C
        # only kills the spinner and a second is needed to exit).
        @async disable_sigint() do
            i = 1
            frames = DistSSHKit.SPINNER_FRAMES
            while !done[]
                j, ids = _serve_live_job(q)
                print_serve_live_line(frames[i], j, ids; io=io)
                i = i == length(frames) ? 1 : i + 1
                sleep(0.08)
            end
        end
    else
        nothing
    end
    owns() = store isa String ? (serve_pid(store) == getpid()) : true
    gone = false
    # Skip the dir-lock + TOML parse of `step!` while the store is unchanged: an
    # idle serve otherwise churns mkdir/rmdir + parse every `interval`. Any
    # client enqueue or our own persist bumps the mtime, so nothing is missed.
    last_mtime = Ref(typemin(Float64))
    try
        while true
            if !owns()
                gone = true
                break
            end
            if store isa String
                m = _store_mtime(store)
                # Kit writes kit.pid / kit.result without touching the table.
                # Skip only when idle; a running row still needs step!.
                if m != last_mtime[] || _running_copy(q) !== nothing
                    step!(q)
                    last_mtime[] = _store_mtime(store)
                end
            else
                step!(q)
            end
            sleep(interval)
        end
    catch e
        e isa InterruptException || rethrow()
        return nothing
    finally
        done[] = true
        _join_serve_spin!(spin)
        if draw
            print(io, "\r\e[K")
            flush(io)
        end
        if gone
            print_serve_gone(label; io=io)
        elseif store isa String && serve_pid(store) == getpid()
            remove_pid_file(store)
        end
    end
    return nothing
end

function serve(; store::AbstractString=default_store_path(), interval::Real=0.2, runner::Function=run_kit)
    return serve!(Queue(; store=store, runner=runner); interval=interval)
end

_is_interrupt(::InterruptException) = true
function _is_interrupt(e::TaskFailedException)
    t = e.task
    return istaskfailed(t) && _is_interrupt(t.exception)
end
_is_interrupt(::Any) = false

"""Wait out the TTY spinner. Ctrl-C also hits that task's `sleep`; do not surface it."""
function _join_serve_spin!(spin)
    spin isa Task || return
    try
        wait(spin)
    catch e
        _is_interrupt(e) || rethrow()
    end
    return
end
