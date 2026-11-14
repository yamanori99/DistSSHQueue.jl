# Store format, enqueue fingerprints, and controller gates aligned with DistSSHRun PR2.

"""`jobs.toml` top-level `store_format_version` written by this release."""
const JOBS_STORE_FORMAT_VERSION = 1

"""Per-job `job_format_version` on each row."""
const JOB_RECORD_FORMAT_VERSION = 1

const _JOB_FORMAT_KW = "job_format_version"
const _ENQUEUE_PROJECT_KW = "enqueue_project"
const _ENQUEUE_TREE_HASH_KW = "enqueue_content_tree_hash"

function _jobs_store_format_mismatch(path::AbstractString, found)::ArgumentError
    p = abspath(String(path))
    got = found === nothing ? "(none)" : string(found)
    return ArgumentError(
        join(
            [
                "what: jobs store format version does not match this DistSSHQueue",
                "where: queue directory $(p); store has store_format_version=$(got); this binary expects $(JOBS_STORE_FORMAT_VERSION)",
                "why: a newer client and an older serve (or the reverse) must not share one queue directory",
                "fix: drain or cancel all jobs, stop serve, upgrade client and queue-host DistSSHQueue to the same version, then submit again",
            ],
            "\n",
        ),
    )
end

function _jobs_store_legacy_job(path::AbstractString, id::AbstractString)::ArgumentError
    p = abspath(String(path))
    return ArgumentError(
        join(
            [
                "what: job row has no job_format_version (Queue 0.9 or older)",
                "where: queue store $(p); job id $(id)",
                "why: this release records enqueue project resolution and source tree hash and refuses legacy rows",
                "fix: remove or finish the job, then submit again with the upgraded Queue",
            ],
            "\n",
        ),
    )
end

function _require_store_format_version!(raw::AbstractDict, path::AbstractString)
    rows = get(raw, "jobs", nothing)
    has_jobs = rows isa AbstractVector && !isempty(rows)
    found = get(raw, "store_format_version", nothing)
    if !has_jobs
        return nothing
    end
    found === nothing && throw(_jobs_store_format_mismatch(path, nothing))
    try
        v = Int(found)
        v == JOBS_STORE_FORMAT_VERSION ||
            throw(_jobs_store_format_mismatch(path, v))
    catch e
        e isa ArgumentError && rethrow()
        throw(_jobs_store_format_mismatch(path, found))
    end
    return nothing
end

function _job_record_format_version(row::AbstractDict, path::AbstractString)::Int
    raw = get(row, _JOB_FORMAT_KW, nothing)
    raw === nothing && throw(_jobs_store_legacy_job(path, string(get(row, "id", "?"))))
    try
        v = Int(raw)
        v == JOB_RECORD_FORMAT_VERSION ||
            throw(_jobs_store_legacy_job(path, string(get(row, "id", "?"))))
        return v
    catch e
        e isa ArgumentError && rethrow()
        throw(_jobs_store_legacy_job(path, string(get(row, "id", "?"))))
    end
end

"""Fail closed before submit or serve runs a Kit job (DistSSHRun PR2)."""
function _assert_controller_for_queue!(project::AbstractString)
    isdefined(DistSSHRun, :assert_controller_environment_for_verify!) || throw(
        ErrorException(
            "DistSSHRun.assert_controller_environment_for_verify! is required; lockstep with DistSSHRun PR 444",
        ),
    )
    DistSSHRun.assert_controller_environment_for_verify!(String(project))
    return nothing
end

function _resolve_enqueue_project(kw::Dict{String, Any}, script::AbstractString)::String
    raw = get(kw, "project", nothing)
    start = if raw isa AbstractString && !isempty(strip(String(raw)))
        String(raw)
    else
        job_project(; cwd = dirname(resolve_script(script)))
    end
    root = resolve_pkg_project_dir(start)
    return canonical_local_path(root)
end

function _pack_enqueue_tree(project::AbstractString, script::AbstractString)
    _ = (script, resolve_script(script))
    isdefined(DistSSHRun, :pack_ship_tree) || throw(
        ErrorException(
            "DistSSHRun.pack_ship_tree is required; lockstep with DistSSHRun PR 444",
        ),
    )
    return DistSSHRun.pack_ship_tree(String(project))
end

"""Record resolved project and `content_tree_hash` at enqueue. Caller holds the store lock."""
function _record_enqueue_fingerprint!(kw::Dict{String, Any}, project::AbstractString, script::AbstractString)
    proj = canonical_local_path(project)
    _assert_controller_for_queue!(proj)
    pack = _pack_enqueue_tree(proj, script)
    try
        kw["project"] = proj
        kw[_JOB_FORMAT_KW] = JOB_RECORD_FORMAT_VERSION
        kw[_ENQUEUE_PROJECT_KW] = proj
        kw[_ENQUEUE_TREE_HASH_KW] = String(pack.content_tree_hash)
    finally
        rm(pack.directory; recursive = true, force = true)
    end
    return nothing
end

function _current_enqueue_tree_hash(project::AbstractString, script::AbstractString)::String
    pack = _pack_enqueue_tree(project, script)
    try
        return String(pack.content_tree_hash)
    finally
        rm(pack.directory; recursive = true, force = true)
    end
end

function _tree_hash_changed_error(j::Job, stored::AbstractString, current::AbstractString)::ErrorException
    return ErrorException(
        join(
            [
                "what: project source tree changed since enqueue",
                "where: job $(j.id); enqueue hash=$(stored); current hash=$(current)",
                "why: execution must use the same sources that were recorded at submit",
                "fix: cancel the job and submit again",
            ],
            "\n",
        ),
    )
end

"""Re-hash at execution; fail closed when the tree drifted."""
function _assert_enqueue_tree_unchanged!(j::Job)
    stored = get(j.kwargs, _ENQUEUE_TREE_HASH_KW, nothing)
    stored isa AbstractString || throw(
        ArgumentError(
            "job $(j.id) has no enqueue_content_tree_hash; submit again with Queue $(JOB_RECORD_FORMAT_VERSION)",
        ),
    )
    proj = get(j.kwargs, _ENQUEUE_PROJECT_KW, nothing)
    if !(proj isa AbstractString) || isempty(strip(String(proj)))
        proj = get(j.kwargs, "project", nothing)
    end
    proj isa AbstractString || throw(
        ErrorException("job $(j.id) has no enqueue project path"),
    )
    _assert_controller_for_queue!(String(proj))
    current = _current_enqueue_tree_hash(String(proj), j.script)
    stored == current || throw(_tree_hash_changed_error(j, stored, current))
    return nothing
end
