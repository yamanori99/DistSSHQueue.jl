"""One table row. `hosts` are DistSSHKit placement tokens (`parent[:N]` / `child:NAME[:N]`).
`kwargs` is an opaque bag for DistSSHRun `execute!` (`project` is the Kit project).
`cancel` true means a running job was asked to stop and is still in setup.
"""
mutable struct Job
    id::String
    kind::Symbol
    script::String
    hosts::Vector{String}
    state::Symbol
    queued_at::DateTime
    started_at::Union{Nothing, DateTime}
    finished_at::Union{Nothing, DateTime}
    error::Union{Nothing, String}
    result_path::Union{Nothing, String}
    kwargs::Dict{String, Any}
end

"""DistSSHRun `execute!` kinds this package can enqueue. `KIT_EXECUTE_KINDS` is Queue's constant. Inspect verbs (`size` / `plan` / `pool`) are not this list."""
const KIT_EXECUTE_KINDS = (:go, :drive, :ride)

is_kit_execute_kind(k::Symbol)::Bool = k === :go || k === :drive || k === :ride

new_job_id()::String = string(Base.UUID(rand(UInt128)))

"""Hop ENV: stage dir UUID must match `jobs.toml`."""
const JOB_ID_ENV = "DISTSSHQUEUE_JOB_ID"

"""Client git snapshot for a `qhost:` submit. Not Run's `DISTSSHKIT_SOURCE_*`."""
const SOURCE_COMMIT_ENV = "DISTSSHQUEUE_SOURCE_COMMIT"
const SOURCE_DIRTY_ENV = "DISTSSHQUEUE_SOURCE_DIRTY"
const SOURCE_DIFF_SHA256_ENV = "DISTSSHQUEUE_SOURCE_DIFF_SHA256"
const SOURCE_CAPTURED_ENV = "DISTSSHQUEUE_SOURCE_CAPTURED"
const SOURCE_UNTRACKED_ENV = "DISTSSHQUEUE_SOURCE_UNTRACKED"

"""Kwarg set while a `:running` job is waiting to stop. Not passed to `execute!`."""
const _CANCEL_KW = "cancel"

function _job_cancel_flag(j::Job)::Bool
    return get(j.kwargs, _CANCEL_KW, nothing) === true
end
function Job(;
        id::AbstractString = new_job_id(),
        kind::Symbol,
        script::AbstractString,
        hosts::AbstractVector{<:AbstractString},
        state::Symbol = :queued,
        queued_at::DateTime = now(UTC),
        started_at = nothing,
        finished_at = nothing,
        error = nothing,
        result_path = nothing,
        kwargs::Dict{String, Any} = Dict{String, Any}(),
    )
    is_kit_execute_kind(kind) || throw(ArgumentError("kind must be one of $KIT_EXECUTE_KINDS"))
    state in (:queued, :running, :done, :failed, :cancelled) ||
        throw(ArgumentError("bad job state $state"))
    isempty(hosts) && throw(ArgumentError("job needs at least one host token"))
    return Job(
        String(id),
        kind,
        String(script),
        String[String(h) for h in hosts],
        state,
        queued_at,
        started_at,
        finished_at,
        error === nothing ? nothing : String(error),
        result_path === nothing ? nothing : String(result_path),
        kwargs,
    )
end

function Base.copy(j::Job)
    return Job(
        j.id,
        j.kind,
        j.script,
        copy(j.hosts),
        j.state,
        j.queued_at,
        j.started_at,
        j.finished_at,
        j.error,
        j.result_path,
        copy(j.kwargs),
    )
end
