# SSH E2E helpers: align the example job's DistSSHRun lock with the runner.
# Included from `test/e2e.jl` and `test/unit/e2e_distsshrun_lock.jl` (no SSH).

using TOML

const DISTSSHRUN_REPO_URL = "https://github.com/yamanori99/DistSSHRun.jl"
const EXAMPLE_DISTSSHRUN_UUID = "b568025c-2759-4ef1-8b14-17d00e2cd000"
const _DISTSSHRUN_HEAD_SHA = r"^[0-9a-f]{40}$"

"""True when `DISTSSHQUEUE_DEV_RUN` developed Run into the test project before E2E."""
function e2e_dev_run_active()::Bool
    return !isempty(get(ENV, "DISTSSHQUEUE_DEV_RUN", ""))
end

function distsshrun_manifest_entry(manifest::AbstractString)
    data = TOML.parsefile(String(manifest))
    deps = get(data, "deps", nothing)
    deps isa AbstractDict || return nothing
    raw = get(deps, "DistSSHRun", nothing)
    raw === nothing && return nothing
    raw isa AbstractVector || return raw
    length(raw) == 1 || return nothing
    return first(raw)
end

"""DistSSHRun `git-tree-sha1` recorded in `manifest`, or `nothing`."""
function distsshrun_git_tree_sha1(manifest::AbstractString)::Union{Nothing, String}
    entry = distsshrun_manifest_entry(manifest)
    entry isa AbstractDict || return nothing
    tree = get(entry, "git-tree-sha1", nothing)
    return tree isa String && !isempty(strip(tree)) ? strip(tree) : nothing
end

function _nonempty_git_line(cmd)::String
    out = try
        strip(read(cmd, String))
    catch e
        throw(
            ArgumentError(
                "git command failed: $(sprint(print, cmd)) ($(sprint(showerror, e)))",
            ),
        )
    end
    isempty(out) &&
        throw(ArgumentError("git command produced empty output: $(sprint(print, cmd))"))
    return out
end

function _distsshrun_repo_url(entry::AbstractDict)::String
    url = get(entry, "repo-url", nothing)
    if url isa String && !isempty(strip(url))
        return strip(url)
    end
    return DISTSSHRUN_REPO_URL
end

function _ensure_head_reachable_from_remote!(
        path::AbstractString,
        remote::AbstractString,
        head::AbstractString,
    )
    # Probe in an empty repo so a local ODB hit cannot mask an unpushed commit.
    probe = mktempdir()
    try
        run(`git -C $probe init -q`)
        stderr_buf = IOBuffer()
        fetch_cmd = `git -C $probe fetch --quiet --no-tags $remote $head`
        proc = run(pipeline(ignorestatus(fetch_cmd); stdout = devnull, stderr = stderr_buf))
        develop = String(strip(abspath(String(path))))
        if proc.exitcode != 0
            detail = strip(String(take!(stderr_buf)))
            msg =
                "commit $head from $develop is not reachable from $remote (push it first)"
            !isempty(detail) && (msg *= ": $detail")
            throw(ArgumentError(msg))
        end
        fetched = strip(read(`git -C $probe rev-parse FETCH_HEAD`, String))
        fetched == head || throw(
            ArgumentError(
                "commit $head from $develop is not reachable from $remote (push it first)",
            ),
        )
    finally
        rm(probe; recursive = true, force = true)
    end
    return nothing
end

"""
Read `HEAD` and `HEAD^{tree}` from a clean `path` checkout and verify `HEAD` is on `repo_url`.

Dirty worktrees and unpushed commits are rejected so workers can `instantiate` the same tree.
"""
function git_dev_distsshrun_pin(path::AbstractString, repo_url::AbstractString)
    path = String(strip(abspath(String(path))))
    isdir(path) ||
        throw(ArgumentError("DistSSHRun develop path is not a directory: $path"))
    inside = try
        _nonempty_git_line(`git -C $path rev-parse --is-inside-work-tree`)
    catch
        throw(
            ArgumentError(
                "DistSSHRun develop path has no git metadata ($path); DISTSSHQUEUE_DEV_RUN must point at a DistSSHRun git checkout",
            ),
        )
    end
    inside == "true" ||
        throw(ArgumentError("DistSSHRun develop path is not a git work tree: $path"))
    dirty = strip(read(`git -C $path status --porcelain`, String))
    !isempty(dirty) && throw(
        ArgumentError(
            "DistSSHRun develop checkout has uncommitted changes under $path; commit or stash before SSH E2E so workers can reproduce the same tree (DISTSSHQUEUE_DEV_RUN)",
        ),
    )
    head = _nonempty_git_line(`git -C $path rev-parse HEAD`)
    tree = _nonempty_git_line(Cmd(["git", "-C", path, "rev-parse", "HEAD^{tree}"]))
    remote = strip(String(repo_url))
    try
        _ensure_head_reachable_from_remote!(path, remote, head)
    catch e
        if e isa ArgumentError
            throw(e)
        end
        throw(
            ArgumentError(
                "commit $head is not reachable from $remote (push it first): $(sprint(showerror, e))",
            ),
        )
    end
    return head, tree
end

function _portable_entry_dict(entry::AbstractDict)::Dict{String, Any}
    out = Dict{String, Any}()
    for (k, v) in entry
        k == "path" && continue
        out[k] = v
    end
    haskey(out, "git-tree-sha1") || throw(
        ArgumentError(
            "DistSSHRun manifest entry has no git-tree-sha1 and no develop path to synthesize one; run julia --project=test -e 'using Pkg; Pkg.instantiate()' first",
        ),
    )
    haskey(out, "path") && throw(ArgumentError("internal error: portable DistSSHRun lock still has path"))
    return out
end

"""
Build a worker-portable DistSSHRun Manifest entry from the runner lock at `manifest`.

Git url locks are copied without `path`. Path-only develop locks (DISTSSHQUEUE_DEV_RUN)
are synthesized with `repo-rev` = full `HEAD` and `git-tree-sha1` = `HEAD^{tree}`.
"""
function runner_distsshrun_portable_lock(manifest::AbstractString)::Dict{String, Any}
    entry = distsshrun_manifest_entry(manifest)
    entry isa AbstractDict ||
        throw(ArgumentError("runner Manifest has no DistSSHRun entry: $manifest"))
    path = get(entry, "path", nothing)
    if path isa String && !isempty(strip(path))
        repo_url = _distsshrun_repo_url(entry)
        dev_path = String(strip(path))
        if !isabspath(dev_path)
            dev_path = normpath(joinpath(dirname(abspath(String(manifest))), dev_path))
        end
        head, tree_sha = git_dev_distsshrun_pin(dev_path, repo_url)
        deps = get(entry, "deps", nothing)
        deps isa AbstractVector ||
            throw(ArgumentError("runner DistSSHRun manifest entry has no deps list"))
        ver = get(entry, "version", nothing)
        ver isa String && !isempty(ver) ||
            throw(ArgumentError("runner DistSSHRun manifest entry has no version"))
        uuid = get(entry, "uuid", nothing)
        uuid == EXAMPLE_DISTSSHRUN_UUID ||
            throw(ArgumentError("runner DistSSHRun uuid mismatch: $(repr(uuid))"))
        return Dict{String, Any}(
            "uuid" => EXAMPLE_DISTSSHRUN_UUID,
            "version" => ver,
            "deps" => deps,
            "repo-url" => repo_url,
            "repo-rev" => head,
            "git-tree-sha1" => tree_sha,
        )
    end
    tree = get(entry, "git-tree-sha1", nothing)
    if tree isa String && !isempty(strip(tree))
        return _portable_entry_dict(entry)
    end
    throw(
        ArgumentError(
            "E2E runner Manifest has no DistSSHRun git-tree-sha1 (instantiate test env first)",
        ),
    )
end

"""Tree hash workers should resolve for the runner Manifest."""
function runner_distsshrun_tree_sha1(manifest::AbstractString)::String
    portable = runner_distsshrun_portable_lock(manifest)
    tree = get(portable, "git-tree-sha1", nothing)
    tree isa String && !isempty(strip(tree)) ||
        throw(ArgumentError("portable DistSSHRun lock has no git-tree-sha1"))
    return strip(tree)
end

function _write_distsshrun_entry!(data::AbstractDict, entry::AbstractDict)
    deps = get!(data, "deps", Dict{String, Any}())
    deps["DistSSHRun"] = [entry]
    return nothing
end

"""
Copy a portable DistSSHRun lock onto the isolated example job Manifest.

`runner_manifest` defaults to the workspace root Manifest used by `julia --project=test`.
"""
function align_example_job_distsshrun!(
        job_proj::AbstractString;
        runner_manifest::AbstractString,
    )
    isfile(runner_manifest) ||
        error("E2E runner Manifest missing: $runner_manifest (run with --project=test)")
    dst = joinpath(job_proj, "Manifest.toml")
    isfile(dst) || error("example job Manifest missing: $dst")
    portable = runner_distsshrun_portable_lock(runner_manifest)
    want = strip(string(portable["git-tree-sha1"]))
    have = distsshrun_git_tree_sha1(dst)
    if !e2e_dev_run_active() && have == want
        return nothing
    end
    dst_data = TOML.parsefile(dst)
    _write_distsshrun_entry!(dst_data, portable)
    open(dst, "w") do io
        TOML.print(io, dst_data)
    end
    return nothing
end

"""True when `job_manifest` locks DistSSHRun to the same tree as the runner."""
function example_job_distsshrun_aligned(
        job_manifest::AbstractString,
        runner_manifest::AbstractString,
    )::Bool
    isfile(runner_manifest) || return false
    want = try
        runner_distsshrun_tree_sha1(runner_manifest)
    catch
        return false
    end
    have = distsshrun_git_tree_sha1(job_manifest)
    return have == want
end

"""
True when `manifest` locks DistSSHRun the way SSH E2E expects on workers.

Outside DISTSSHQUEUE_DEV_RUN, `repo-rev` must be `main` (url source in Project.toml).
With DISTSSHQUEUE_DEV_RUN, `repo-rev` must be the lowercase 40-hex commit SHA
`align_example_job_distsshrun!` writes from `git rev-parse HEAD`, and `git-tree-sha1`
must match the runner's portable lock.
"""
function distsshrun_general_lock(
        manifest::AbstractString;
        runner_manifest::Union{Nothing, AbstractString} = nothing,
    )::Bool
    data = TOML.parsefile(String(manifest))
    deps = get(data, "deps", nothing)
    deps isa Dict || return false
    entries = get(deps, "DistSSHRun", nothing)
    entries isa Vector || return false
    length(entries) == 1 || return false
    entry = entries[1]
    entry isa Dict || return false
    haskey(entry, "path") && return false
    get(entry, "uuid", nothing) == EXAMPLE_DISTSSHRUN_UUID || return false
    get(entry, "repo-url", nothing) == DISTSSHRUN_REPO_URL || return false
    ver = get(entry, "version", nothing)
    ver isa String && !isempty(ver) || return false
    tree = get(entry, "git-tree-sha1", nothing)
    tree isa String && !isempty(strip(tree)) || return false
    rev = get(entry, "repo-rev", nothing)
    rev isa String && !isempty(strip(rev)) || return false
    if e2e_dev_run_active()
        runner = runner_manifest
        runner === nothing && return false
        rev = strip(String(rev))
        occursin(_DISTSSHRUN_HEAD_SHA, rev) || return false
        want_tree = try
            runner_distsshrun_tree_sha1(runner)
        catch
            return false
        end
        return strip(tree) == want_tree
    end
    return strip(rev) == "main"
end
