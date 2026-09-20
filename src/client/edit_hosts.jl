"""CLI `add-host` / `remove-host`: write Kit placement tokens into config `hosts`."""

function _remote_julia_mm(host::AbstractString)::Union{Nothing, Tuple{Int, Int}}
    DistSSHKit.is_parent_host_name(host) && return (VERSION.major, VERSION.minor)
    path = try
        DistSSHKit.resolve_remote_julia(String(host), "auto")
    catch
        nothing
    end
    path === nothing && return nothing
    ver = try
        DistSSHKit.get_remote_julia_version(String(host), path)
    catch
        nothing
    end
    ver === nothing && return nothing
    return (ver.major, ver.minor)
end

function _print_cli_note(io::IO, head::AbstractString, bodies...; cols::Int = 0)
    n = cols > 0 ? cols : cli_cols(io)
    print_wrapped_tail(io, "  ! ", head; cols = n, prefix_color = :yellow)
    for body in bodies
        print_wrapped_tail(io, "    ", body; cols = n, prefix_color = :light_black)
    end
    return nothing
end

"""Warn when a worker's Julia major.minor differs. Silent if quiet or unreachable."""
function warn_julia_major_minor(tokens; io::IO = stdout)
    _queue_env_on("DISTSSHKIT_QUIET") && return nothing
    local_mm = (VERSION.major, VERSION.minor)
    seen = Set{String}()
    first = true
    for raw in tokens
        name = kit_ssh_name(String(raw))
        DistSSHKit.is_parent_host_name(name) && continue
        name in seen && continue
        push!(seen, name)
        mm = _remote_julia_mm(name)
        mm === nothing && continue
        mm == local_mm && continue
        first && println(io)
        first = false
        _print_cli_note(
            io,
            "$(name) Julia $(mm[1]).$(mm[2]) vs this process $(local_mm[1]).$(local_mm[2])",
            "julia -m DistSSHQueue setup --juliaup $(name)",
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
        DistSSHKit.is_parent_host_name(name) && continue
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
    warn_julia_major_minor(names)
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
