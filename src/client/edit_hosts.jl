"""CLI `add-host` / `remove-host`: write Kit placement tokens into config `hosts`."""

function _remote_julia_mm(host::AbstractString)::Union{Nothing,Tuple{Int,Int}}
    DistSSHKit.is_parent_host_name(host) && return (VERSION.major, VERSION.minor)
    ver = try
        DistSSHKit.get_remote_julia_version(String(host), "julia")
    catch
        nothing
    end
    ver === nothing && return nothing
    return (ver.major, ver.minor)
end

"""Warn when a worker's Julia major.minor differs. Silent if quiet or unreachable."""
function warn_julia_major_minor(tokens)
    _queue_env_on("DISTSSHKIT_QUIET") && return nothing
    local_mm = (VERSION.major, VERSION.minor)
    seen = Set{String}()
    for raw in tokens
        name = kit_ssh_name(String(raw))
        DistSSHKit.is_parent_host_name(name) && continue
        name in seen && continue
        push!(seen, name)
        mm = _remote_julia_mm(name)
        mm === nothing && continue
        mm == local_mm && continue
        DistSSHKit.print_err(
            "  Warning: $(name) Julia $(mm[1]).$(mm[2]) vs this process $(local_mm[1]).$(local_mm[2]).\n",
        )
        DistSSHKit.print_err(
            "  Fix: julia -m DistSSHQueue setup --juliaup $(name)\n",
        )
    end
    return nothing
end

function add_host_cli(args::Vector{String})::Cint
    names = String[]
    for a in args
        if a in ("-h", "--help")
            show_usage()
            return 0
        end
        startswith(a, "-") && throw(ArgumentError("unknown add-host option: $(a)"))
        push!(names, a)
    end
    add_host_names!(config_path(), names)
    print_list_host(config_host_names(load_config()))
    warn_julia_major_minor(names)
    return 0
end

function remove_host_cli(args::Vector{String})::Cint
    names = String[]
    for a in args
        if a in ("-h", "--help")
            show_usage()
            return 0
        end
        startswith(a, "-") && throw(ArgumentError("unknown remove-host option: $(a)"))
        push!(names, a)
    end
    remove_host_names!(config_path(), names)
    print_list_host(config_host_names(load_config()))
    return 0
end
