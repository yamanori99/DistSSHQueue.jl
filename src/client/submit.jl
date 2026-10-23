# Client `submit go` / `submit ride` / `submit drive` (Kit parsers). After `qhost:` ssh, on the staged tree.
function drop_nothing(d::Dict{String, Any})
    out = Dict{String, Any}()
    for (k, v) in d
        v === nothing && continue
        if v isa Symbol
            out[k] = String(v)
        elseif v isa AbstractVector && isempty(v)
            continue
        else
            out[k] = v
        end
    end
    return out
end

function submit_hosts(parsed; kind::Symbol)::Vector{String}
    return host_tokens(parsed; kind = kind)
end

function submit_kit_bag(parsed; kind::Symbol)::Dict{String, Any}
    raw = DistSSHRun.execute_kwargs_from_parsed(parsed; kind = kind)
    return drop_nothing(Dict{String, Any}(String(k) => v for (k, v) in raw))
end

"""Peel `pool:N` from Queue selector positions, not Kit option values.

`submit go --julia pool:8 …` keeps `pool:8` as `--julia`'s value.
After `--`, remaining tokens are script args.
"""
function peel_submit_pool(args::Vector{String})
    n = nothing
    out = String[]
    skip_value = false
    passthrough = false
    for a in args
        if passthrough
            push!(out, a)
            continue
        end
        if skip_value
            push!(out, a)
            skip_value = false
            continue
        end
        if a == "--"
            passthrough = true
            push!(out, a)
            continue
        end
        if a == "pool"
            throw(
                ArgumentError(
                    "`pool` is the inspect verb. For submit slots use `pool:N` " *
                        "(e.g. submit pool:8 drive SCRIPT.jl). Inspect: $(cli_m()) $(cli_qhost())pool",
                )
            )
        elseif startswith(a, "pool:")
            n === nothing || throw(ArgumentError("pool:N given twice"))
            raw = strip(chopprefix(a, "pool:"))
            slots = tryparse(Int, raw)
            (slots === nothing || slots < 1) && throw(
                ArgumentError(
                    "pool:N needs a positive integer (got $(repr(a)))",
                )
            )
            n = slots
        else
            push!(out, a)
            skip_value = _kit_flag_takes_value(a)
        end
    end
    return out, n
end

function _kit_flag_takes_value(a::AbstractString)::Bool
    startswith(a, "--") || startswith(a, "-") || return false
    occursin('=', a) && return false
    return a in (
        "--julia", "--output-dir", "--repeat", "--gb-per-worker", "--probe",
        "--mem-headroom", "--parent-gb", "--workers", "-w", "--hosts",
        "--hosts-file", "--n", "--log-dir", "--package", "--project",
    )
end

function expand_pool_submit_hosts(slots::Int)::Vector{String}
    allow = config_host_names(load_config())
    (allow === nothing || isempty(allow)) && throw(
        ArgumentError(
            "pool:N needs config hosts; add-host first",
        )
    )
    out = String[]
    for name in sorted_kit_ssh_names(allow)
        n = clamp_pool_slots(slots, allow, name)
        n < 1 && continue
        role = is_parent_host_name(name) ? :parent : :child
        push!(out, format_placement_token(role, String(name), n))
    end
    isempty(out) && throw(ArgumentError("pool:N: no hosts left after add-host max"))
    return out
end

"""Job `source` dict from `DISTSSHQUEUE_SOURCE_*`, or `nothing` when commit is unset."""
function _source_from_queue_env()::Union{Nothing, Dict{String, Any}}
    haskey(ENV, SOURCE_COMMIT_ENV) || return nothing
    out = Dict{String, Any}("commit" => String(ENV[SOURCE_COMMIT_ENV]))
    if haskey(ENV, SOURCE_DIRTY_ENV)
        out["dirty"] = ENV[SOURCE_DIRTY_ENV] == "true"
    end
    if haskey(ENV, SOURCE_DIFF_SHA256_ENV)
        out["diff_sha256"] = String(ENV[SOURCE_DIFF_SHA256_ENV])
    end
    if haskey(ENV, SOURCE_CAPTURED_ENV)
        out["captured"] = String(ENV[SOURCE_CAPTURED_ENV])
    end
    if haskey(ENV, SOURCE_UNTRACKED_ENV)
        n = tryparse(Int, strip(ENV[SOURCE_UNTRACKED_ENV]))
        n === nothing || (out["untracked"] = n)
    end
    return out
end

const MANIFEST_ABSENT_MESSAGE =
    "no Manifest.toml in the job tree; the queue host and each worker resolve packages on their own"
const MANIFEST_ABSENT_HINT =
    "commit Manifest.toml, or stop ignoring it. A later minor will refuse this submit."

"""True when `Project.toml` `[deps]` names at least one package.

A missing file, a TOML error, a missing `[deps]`, or an empty table is false.
`[weakdeps]` and `[extras]` are not read. A false result does not fail submit.
"""
function _project_has_deps(project_dir::AbstractString)::Bool
    path = joinpath(String(project_dir), "Project.toml")
    isfile(path) || return false
    raw = try
        TOML.parsefile(path)
    catch
        return false
    end
    raw isa AbstractDict || return false
    deps = get(raw, "deps", nothing)
    return deps isa AbstractDict && !isempty(deps)
end

"""Job project whose `[deps]` need a Manifest, or `nothing` when submit should stay quiet.

`resolve_pkg_env` follows a workspace member to the parent Manifest. A directory
with no `Project.toml` also has `manifest === nothing`; that tree is not warned.
`Base.active_manifest` picks a versioned Manifest with the Julia that runs submit.
"""
function _manifest_absent_project(kw::Dict{String, Any})::Union{Nothing, String}
    raw = get(kw, "project", nothing)
    proj = if raw isa AbstractString && !isempty(strip(String(raw)))
        String(raw)
    else
        job_project()
    end
    env = resolve_pkg_env(proj)
    isfile(joinpath(env.project_dir, "Project.toml")) || return nothing
    _project_has_deps(env.project_dir) || return nothing
    env.manifest === nothing || return nothing
    return env.project_dir
end

function _record_manifest_absent!(kw::Dict{String, Any})
    _manifest_absent_project(kw) === nothing && return nothing
    entry = Dict{String, Any}(
        "kind" => "manifest_absent",
        "message" => MANIFEST_ABSENT_MESSAGE,
    )
    prev = get(kw, "warnings", nothing)
    kw["warnings"] = prev isa AbstractVector ? Any[prev..., entry] : Any[entry]
    return nothing
end

function _print_manifest_absent!(io::IO, kw::Dict{String, Any})
    raw = get(kw, "warnings", nothing)
    raw isa AbstractVector || return nothing
    found = false
    for w in raw
        w isa AbstractDict || continue
        get(w, "kind", "") == "manifest_absent" || continue
        found = true
        break
    end
    found || return nothing
    _print_cli_note(io, MANIFEST_ABSENT_MESSAGE, MANIFEST_ABSENT_HINT)
    return nothing
end

function submit_cli(store::AbstractString, kind::Symbol, script::AbstractString, hosts, kw::Dict{String, Any})
    kw = Dict{String, Any}(String(k) => v for (k, v) in kw)
    src = _source_from_queue_env()
    src === nothing || (kw["source"] = src)
    _record_manifest_absent!(kw)
    q = Queue(; store = store, follow_config = true)
    nt = isempty(kw) ? NamedTuple() : (; (Symbol(k) => v for (k, v) in kw)...)
    forced = strip(get(ENV, JOB_ID_ENV, ""))
    id = try
        if isempty(forced)
            submit!(q, String(script), String[String(x) for x in hosts]; kind = kind, nt...)
        else
            submit!(q, String(script), String[String(x) for x in hosts]; kind = kind, id = forced, nt...)
        end
    catch
        drop_unwritten_stage!(forced, store)
        rethrow()
    end
    println(id)
    if !_kit_env_on("DISTSSHKIT_QUIET")
        qh = qhost_display_from_env()
        if qh !== nothing && !isempty(strip(qh))
            println(stderr, "qhost: local ($(gethostname()))")
        else
            println(stderr, "queue: local ($(gethostname()))")
        end
        _print_manifest_absent!(stderr, kw)
        nq = count(j -> j.state === :queued, q.jobs)
        nr = count(j -> j.state === :running, q.jobs)
        if nr > 0
            println(stderr, "Queued  $(nq)  ($(nr) running)")
        else
            println(stderr, "Queued  $(nq)  (no running)")
        end
    end
    ensure_serve!(store)
    return 0
end

script_arg(::Nothing, verb::AbstractString) = throw(ArgumentError("$verb: missing SCRIPT.jl"))
function script_arg(path::AbstractString, ::AbstractString)::String
    resolved = resolve_script(path)
    isfile(resolved) && return resolved
    throw(
        ArgumentError(
            DistSSHRun.explain_script_not_found(resolved, job_project(); surface = :cli),
        )
    )
end

"""Parse Kit execute argv. One table: add a kind here, in `KIT_EXECUTE_KINDS`, and in `main`."""
function kit_parse_args(kind::Symbol, args::Vector{String})
    kind === :go && return DistSSHRun.parse_go_args(args)
    kind === :drive && return DistSSHRun.parse_drive_args(args)
    kind === :ride && return DistSSHRun.parse_ride_args(args)
    throw(ArgumentError("submit: unknown kit command $(repr(kind))"))
end

function kit_show_usage(kind::Symbol)
    kind === :go && return DistSSHRun.show_go_usage()
    kind === :drive && return DistSSHRun.show_drive_usage()
    kind === :ride && return DistSSHRun.show_ride_usage()
    throw(ArgumentError("submit: unknown kit command $(repr(kind))"))
end

function kit_kind_from_cli(name::AbstractString)::Symbol
    k = Symbol(String(name))
    is_kit_execute_kind(k) || throw(
        ArgumentError(
            "submit: unknown kit command $(repr(name)) (want go, ride, or drive)",
        )
    )
    return k
end

function submit_kind(kind::Symbol, args::Vector{String}; pool_slots::Union{Nothing, Int} = nothing)::Cint
    rest, peeled = peel_submit_pool(args)
    slots = if pool_slots !== nothing && peeled !== nothing
        throw(ArgumentError("pool:N given twice"))
    elseif pool_slots !== nothing
        pool_slots
    else
        peeled
    end
    parsed = kit_parse_args(kind, rest)
    if parsed.help
        print_help_section("Queue"; io = stdout)
        print_help_lines(
            stdout,
            "  submit $(kind) enqueues. qhost:HOST is the SSH name of the queue machine, not a Kit slot.",
        )
        print_help_blank(stdout)
        print_help_section("DistSSHKit"; io = stdout)
        print_help_lines(
            stdout,
            "  Same argv as $(cli_m()) $(kind) … (parent:N / child:NAME:N).",
        )
        print_help_blank(stdout)
        kit_show_usage(kind)
        return 0
    end
    parsed.show_version && (DistSSHRun.println_kit_version(); return 0)
    verb = String(kind)
    hosts = submit_hosts(parsed; kind = kind)
    if slots !== nothing
        isempty(hosts) || throw(
            ArgumentError(
                "pool:N cannot mix with parent / child tokens",
            )
        )
        hosts = expand_pool_submit_hosts(slots)
    end
    return submit_cli(
        store_path(),
        kind,
        script_arg(parsed.script_path, verb),
        hosts,
        submit_kit_bag(parsed; kind = kind),
    )
end

function _stage_cleanup_store()::String
    try
        return store_path()
    catch
        return default_store_path()
    end
end

function submit_main(args::Vector{String})::Cint
    try
        isempty(args) && throw(ArgumentError("submit: need `go`, `ride`, or `drive`"))
        rest, slots = peel_submit_pool(args)
        isempty(rest) && throw(ArgumentError("submit: need `go`, `ride`, or `drive`"))
        kit, rest2 = String(rest[1]), String[String(a) for a in rest[2:end]]
        kit in ("-h", "--help") && (show_usage(; command = "submit"); return 0)
        return submit_kind(kit_kind_from_cli(kit), rest2; pool_slots = slots)
    catch
        drop_unwritten_stage!(strip(get(ENV, JOB_ID_ENV, "")), _stage_cleanup_store())
        rethrow()
    end
end
