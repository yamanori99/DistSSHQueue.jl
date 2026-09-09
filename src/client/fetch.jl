"""Client `fetch <id>`: inverse of stage. Copy one finished Kit leaf onto this job tree."""

const FETCH_SOURCE_SEP = '\t'
const FETCH_READY = (:done, :failed, :cancelled)

function posix_dir(path::AbstractString)::String
    return rstrip(replace(String(path), '\\' => '/'), '/')
end

function path_has_distsshkit(path::AbstractString)::Bool
    return any(p -> p == ".distsshkit", split(posix_dir(path), '/'; keepempty=false))
end

function path_has_queue_leaf(path::AbstractString)::Bool
    parts = split(posix_dir(path), '/'; keepempty=false)
    length(parts) >= 2 || return false
    return parts[end-1] in ("go", "ride", "drive")
end

"""`result_path` relative to `root`. Refuses `..` and off-tree paths."""
function fetch_relpath(
    result_path::AbstractString,
    root::AbstractString;
    canonicalize::Bool=false,
)::String
    raw_p = canonicalize ? DistSSHKit.canonical_local_path(result_path) : String(result_path)
    raw_r = canonicalize ? DistSSHKit.canonical_local_path(root) : String(root)
    p = posix_dir(raw_p)
    r = posix_dir(raw_r)
    (p == r || startswith(p, path_inside_prefix(r))) || throw(ArgumentError(
        "result is not under the queue store directory",
    ))
    rel = p == r ? "." : String(chopprefix(p, path_inside_prefix(r)))
    any(part -> part == ".." || part == ".", split(rel, '/'; keepempty=false)) && throw(ArgumentError(
        "fetch: refused relative path $(repr(rel))",
    ))
    return rel
end

"""Leaf must sit under the store directory or the job `project` (Kit `relpath`)."""
function require_fetch_in_known_root(j::Job, result_path::AbstractString, store::AbstractString)
    roots = String[dirname(store)]
    proj = get(j.kwargs, "project", nothing)
    if proj isa AbstractString
        s = strip(String(proj))
        !isempty(s) && push!(roots, s)
    end
    last = nothing
    seen = Set{String}()
    for r in roots
        r in seen && continue
        push!(seen, r)
        try
            fetch_relpath(result_path, r)
            return nothing
        catch e
            e isa ArgumentError || rethrow()
            last = e
        end
    end
    throw(something(last, ArgumentError(
        "result is not under the queue store directory or the job project",
    )))
end

function fetch_dest(local_proj::AbstractString, kind::AbstractString, leaf::AbstractString)::String
    k = String(kind)
    k in ("go", "ride", "drive") || throw(ArgumentError("fetch: bad kind $(repr(k))"))
    dest = DistSSHKit.canonical_local_path(joinpath(local_proj, ".distsshqueue", k, String(leaf)))
    path_under_project(dest, local_proj) || throw(ArgumentError(
        "fetch dest escapes the job project",
    ))
    return dest
end

function require_fetchable_leaf(id::AbstractString, result_path::AbstractString)
    leaf = basename(posix_dir(result_path))
    needle = _job_id8(id)
    occursin(needle, leaf) || throw(ArgumentError(
        "result leaf does not contain the job id (submit --output-dir is not fetchable)",
    ))
    path_has_queue_leaf(result_path) || throw(ArgumentError(
        "fetch only copies Queue leaves under go/ride/drive",
    ))
    return nothing
end

"""One machine line: `state<TAB>abs-path`. Used by `hop_print`, not `main`."""
function fetch_source(id::AbstractString; store::AbstractString=store_path())::String
    q = Queue(; store=store)
    load!(q)
    j = job(q, id)
    j.state === :queued && throw(ArgumentError("job $(repr(id)) is still queued"))
    j.state === :running && throw(ArgumentError("job $(repr(id)) is still running"))
    p = j.result_path
    (p === nothing || isempty(strip(p))) && throw(ArgumentError(
        "job $(repr(id)) has no result_path",
    ))
    j.state in FETCH_READY || throw(ArgumentError(
        "job $(repr(id)) is $(j.state)",
    ))
    require_fetchable_leaf(id, p)
    require_fetch_in_known_root(j, p, store)
    return string(j.state, FETCH_SOURCE_SEP, p)
end

function parse_fetch_source(line::AbstractString)
    s = String(line)
    i = findfirst(==(FETCH_SOURCE_SEP), s)
    i === nothing && throw(ArgumentError("fetch: bad source line"))
    st = Symbol(s[1:prevind(s, i)])
    path = s[nextind(s, i):end]
    isempty(path) && throw(ArgumentError("fetch: bad source line"))
    return st, path
end

"""Client-only marker after `qhost:` submit. Not a Kit leaf (`go/` / `drive/`)."""
const SUBMIT_TICKET_UUID =
    r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"

function job_id_from_submit_stdout(out::AbstractString)::Union{Nothing,String}
    for line in eachsplit(String(out), '\n'; keepempty=false)
        s = strip(line)
        occursin(SUBMIT_TICKET_UUID, s) && return s
    end
    return nothing
end

"""Client history of `qhost:` submits. One file per UUID; nothing prunes it."""
function submit_ticket_dir(root::AbstractString)::String
    return joinpath(String(root), ".distsshqueue", "tickets")
end

function submit_ticket_path(root::AbstractString, id::AbstractString)::String
    return joinpath(submit_ticket_dir(root), String(id))
end

const SUBMIT_TICKET_ID_LINE =
    r"^id\s*=\s*\"([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})\""m

function job_id_from_ticket_text(text::AbstractString)::Union{Nothing,String}
    m = match(SUBMIT_TICKET_ID_LINE, String(text))
    cap = m === nothing ? nothing : m.captures[1]
    cap === nothing && return nothing
    return String(cap)
end

"""UUID for `fetch`: ticket path, or the id / prefix as today."""
function resolve_fetch_job_id(arg::AbstractString; root::AbstractString=job_project())::String
    raw = String(arg)
    cands = String[raw]
    if !isabspath(raw)
        push!(cands, joinpath(root, raw))
        push!(cands, joinpath(submit_ticket_dir(root), basename(raw)))
    end
    seen = Set{String}()
    for p in cands
        p in seen && continue
        push!(seen, p)
        isfile(p) || continue
        id = job_id_from_ticket_text(read(p, String))
        id !== nothing && return id
        if startswith(posix_dir(p), posix_dir(submit_ticket_dir(root)))
            throw(ArgumentError("fetch: not a submit ticket $(repr(p))"))
        end
    end
    return raw
end

function write_submit_ticket(
    root::AbstractString,
    stdout_text::AbstractString;
    script::Union{Nothing,AbstractString}=nothing,
    qhost::Union{Nothing,AbstractString}=nothing,
)::Union{Nothing,String}
    id = job_id_from_submit_stdout(stdout_text)
    id === nothing && return nothing
    dest = submit_ticket_path(root, id)
    mkpath(dirname(dest))
    lines = String["id = $(repr(id))"]
    if script !== nothing && !isempty(strip(String(script)))
        sp = String(script)
        rel = try
            replace(
                relpath(
                    DistSSHKit.canonical_local_path(sp),
                    DistSSHKit.canonical_local_path(root),
                ),
                '\\' => '/',
            )
        catch
            replace(sp, '\\' => '/')
        end
        push!(lines, "script = $(repr(rel))")
    end
    if qhost !== nothing && !isempty(strip(String(qhost)))
        push!(lines, "qhost = $(repr(String(qhost)))")
    end
    write(dest, join(lines, '\n') * '\n')
    return dest
end

function local_fetch_dest(
    id::AbstractString,
    result_path::AbstractString,
    store_root::AbstractString;
    canonicalize::Bool=false,
)::String
    require_fetchable_leaf(id, result_path)
    fetch_relpath(result_path, store_root; canonicalize=canonicalize)
    kind = basename(dirname(posix_dir(result_path)))
    leaf = basename(posix_dir(result_path))
    return fetch_dest(job_project(), kind, leaf)
end

function fetch_cli(
    qhost::Union{Nothing,AbstractString},
    gjulia::Union{Nothing,AbstractString},
    gqenv::Union{Nothing,AbstractString},
    rest::Vector{String};
    explicit::Bool=false,
)::Cint
    host, rjulia, qenv, payload, rest_explicit = extract_remote_opts(rest)
    dest, spec = coalesce_remote(qhost, gjulia, host, rjulia)
    hop = (explicit || rest_explicit) ? dest : nothing
    qe = coalesce_queue_env(gqenv, qenv)
    isempty(payload) && throw(ArgumentError("fetch: need a job id"))
    payload[1] in ("-h", "--help") && (show_usage(); return 0)
    length(payload) == 1 || throw(ArgumentError("fetch: extra arguments"))
    id = resolve_fetch_job_id(String(payload[1]))
    length(id) < 8 && throw(ArgumentError(
        "fetch: job id needs 8 characters (status prefix) or the full UUID",
    ))
    if hop === nothing
        st, path = parse_fetch_source(fetch_source(id))
        st in FETCH_READY || throw(ArgumentError("job $(repr(id)) is $(st)"))
        println(path)
        return 0
    end
    staging_enabled() || throw(ArgumentError(
        "qhost fetch needs rsync (unset DISTSSHQUEUE_NO_STAGE / DISTSSHKIT_TEST_SSH)",
    ))
    expr = "using DistSSHQueue; print(DistSSHQueue.fetch_source($(repr(id))))"
    st, path = parse_fetch_source(hop_print(hop, spec, expr; queue_env=qe))
    st in FETCH_READY || throw(ArgumentError("job $(repr(id)) is $(st)"))
    qroot = dirname(dirname(posix_dir(path)))
    out = local_fetch_dest(id, path, qroot)
    rsync_from_qhost!(hop, path, out)
    println(out)
    return 0
end
