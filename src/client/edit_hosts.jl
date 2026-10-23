# CLI `add-host` / `remove-host`: write Kit placement tokens into config `hosts`.

"""First line of `jobs.toml.pid.julia`, or `nothing` when it cannot be read."""
function _pid_julia_version(path::AbstractString)::Union{Nothing, VersionNumber}
    isfile(path) || return nothing
    text = try
        read(path, String)
    catch
        return nothing
    end
    line = ""
    for row in eachsplit(text, '\n'; keepempty = false)
        line = strip(String(row))
        isempty(line) || break
    end
    isempty(line) && return nothing
    try
        return VersionNumber(line)
    catch
        return nothing
    end
end

"""`julia --version` of `bin`, or `nothing` when that output cannot be read."""
function _bin_julia_version(bin::AbstractString)::Union{Nothing, VersionNumber}
    isempty(bin) && return nothing
    text = try
        read(`$bin --version`, String)
    catch
        return nothing
    end
    return parse_julia_version_full(text)
end

"""Serve Julia to compare, and the words that name that baseline.

A running serve uses `jobs.toml.pid.julia` and does not fall through.
No running serve uses the `enable` unit's Julia. Unreadable unit output
falls through to an unknown baseline.
"""
function _serve_julia_baseline(store::AbstractString, home::AbstractString)
    if serve_pid(store) !== nothing
        ver = _pid_julia_version(store_pid_julia_path(store))
        ver === nothing && return (nothing, "the running serve did not record its Julia")
        return (ver, "the running serve's Julia")
    end
    spec = enabled_serve_command(; home = home)
    if spec !== nothing
        ver = _bin_julia_version(spec.julia)
        ver !== nothing && return (ver, "the next serve's Julia")
    end
    return (nothing, "serve's Julia is not known")
end

"""`:minor`, `:patch`, `:prerelease`, or `:none`. A build-only difference is `:none`."""
function _julia_diff_kind(serve_v::VersionNumber, worker_v::VersionNumber)::Symbol
    serve_v = VersionNumber(serve_v.major, serve_v.minor, serve_v.patch, serve_v.prerelease, ())
    worker_v = VersionNumber(worker_v.major, worker_v.minor, worker_v.patch, worker_v.prerelease, ())
    if worker_v.major != serve_v.major || worker_v.minor != serve_v.minor
        return :minor
    elseif worker_v.patch != serve_v.patch
        return :patch
    elseif worker_v.prerelease != serve_v.prerelease
        return :prerelease
    end
    return :none
end

function _julia_diff_word(kind::Symbol)::String
    kind === :minor && return "major.minor"
    kind === :patch && return "patch"
    return "prerelease"
end

function _remote_julia_full(host::AbstractString)::Union{Nothing, VersionNumber}
    path = try
        resolve_remote_julia(String(host), "auto")
    catch
        nothing
    end
    path === nothing && return nothing
    return get_remote_julia_version_full(String(host), path)
end

function _print_cli_note(io::IO, head::AbstractString, bodies...; cols::Int = 0)
    n = cols > 0 ? cols : cli_cols(io)
    print_wrapped_tail(io, "  ! ", head; cols = n, prefix_color = :yellow)
    for body in bodies
        print_wrapped_tail(io, "    ", body; cols = n, prefix_color = :light_black)
    end
    return nothing
end

"""Warn when a worker's Julia differs from serve.

Silent when `DISTSSHKIT_QUIET` is set. An unreachable worker is skipped.
The baseline is the running serve's Julia, then the next serve's Julia.
When neither can be read, this says so and does not compare. No serve and
no `enable` unit also says to start serve, or enable, so a later `add-host`
or `pool` can compare. A major.minor difference, a patch-only difference,
and a prerelease-only difference warn. A build-only difference does not.
`add-host` and `pool` still exit 0.
"""
function warn_worker_julia(
        tokens;
        io::IO = stdout,
        store::AbstractString = store_path(),
        home::AbstractString = homedir(),
    )
    _queue_env_on("DISTSSHKIT_QUIET") && return nothing
    seen = Set{String}()
    kids = String[]
    for raw in tokens
        name = kit_ssh_name(String(raw))
        is_parent_host_name(name) && continue
        name in seen && continue
        push!(seen, name)
        push!(kids, name)
    end
    isempty(kids) && return nothing
    ver, note = _serve_julia_baseline(store, home)
    if ver === nothing
        println(io)
        if note == "serve's Julia is not known"
            _print_cli_note(
                io,
                String(note),
                "Worker Julias were not compared.",
                "Start serve, or enable, and the next add-host or pool will compare.",
            )
        else
            _print_cli_note(io, String(note), "Worker Julias were not compared.")
        end
        return nothing
    end
    first = true
    for name in kids
        remote = _remote_julia_full(name)
        remote === nothing && continue
        kind = _julia_diff_kind(ver, remote)
        kind === :none && continue
        first && println(io)
        first = false
        _print_cli_note(
            io,
            "$(name) Julia $(remote) differs in $(_julia_diff_word(kind)) from $(note) $(ver)",
            "$(cli_m()) $(cli_qhost())up",
        )
    end
    return nothing
end

"""Warn that `child:` inventory is reachable via DistSSHKit from this queue host.

Silent if quiet or the argv is parent-only. Not a confirm prompt.
"""
function warn_child_submit_reach(tokens; io::IO = stdout)
    _queue_env_on("DISTSSHKIT_QUIET") && return nothing
    kids = String[]
    seen = Set{String}()
    for raw in tokens
        name = kit_ssh_name(String(raw))
        is_parent_host_name(name) && continue
        name in seen && continue
        push!(seen, name)
        push!(kids, "child:$(name)")
    end
    isempty(kids) && return nothing
    listed = join(kids, ", ")
    them = length(kids) == 1 ? "this name" : "these names"
    println(io)
    reach = "DistSSHKit can reach $(them) from this queue host. " *
        "Anyone who can submit as this user (including qhost:) can use them."
    net = "Child instantiate needs outbound internet unless the depot already " *
        "has the registry and packages. SSH/rsync is not enough."
    _print_cli_note(io, listed, reach, net)
    return nothing
end

function add_host_cli(args::Vector{String})::Cint
    names = String[]
    for a in args
        if a in ("-h", "--help")
            show_usage(; command = "add-host")
            return 0
        end
        startswith(a, "-") && throw(ArgumentError("unknown add-host option: $(a)"))
        push!(names, a)
    end
    add_host_names!(config_path(), names)
    print_list_host(config_host_names(load_config()))
    warn_child_submit_reach(names)
    warn_worker_julia(names)
    return 0
end

function remove_host_cli(args::Vector{String})::Cint
    names = String[]
    for a in args
        if a in ("-h", "--help")
            show_usage(; command = "remove-host")
            return 0
        end
        startswith(a, "-") && throw(ArgumentError("unknown remove-host option: $(a)"))
        push!(names, a)
    end
    remove_host_names!(config_path(), names)
    print_list_host(config_host_names(load_config()))
    return 0
end
