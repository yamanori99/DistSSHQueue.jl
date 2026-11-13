# CLI `pool`: DistSSHKit `pool!` on the queue host (cwd / project).
#
# Cores / RAM / reachability. No slot estimate. Does not enqueue.
# No tokens: pool every name on config `hosts`. From a client: `qhost:HOST pool …`.
function clamp_pool_slots(slots::Int, allow::Union{Nothing, HostAllow}, host::AbstractString)::Int
    allow === nothing && return slots
    name = is_parent_host_name(host) ? PARENT_HOST_NAME : String(host)
    cap = get(allow, name, nothing)
    cap === nothing && return slots
    return min(slots, cap)
end

function pool_hosts_from_allow(
        include_parent::Bool,
        hosts::Vector{String},
        allow::Union{Nothing, HostAllow},
    )::Tuple{Bool, Vector{String}}
    isempty(hosts) || return include_parent, String[String(h) for h in hosts]
    include_parent && return include_parent, String[String(h) for h in hosts]
    allow === nothing && throw(
        ArgumentError(
            "pool: pass `parent` / `child:NAME`, or add-host first",
        )
    )
    isempty(allow) && throw(ArgumentError("pool: hosts = []; add-host first"))
    out = String[]
    parent = false
    for n in sorted_kit_ssh_names(allow)
        if is_parent_host_name(n)
            parent = true
        else
            push!(out, n)
        end
    end
    return parent, out
end

function pool_cli(args::Vector{String})::Cint
    opts = DistSSHRun.parse_pool_args(args)
    if opts.show_help
        DistSSHRun.show_pool_usage()
        print_help_blank()
        print_help_section("Queue"; io = stdout)
        print_help_lines(
            stdout,
            "  Same flags as DistSSHKit pool. Runs on the queue host (cwd / project).",
            "  $(cli_m()) [qhost:HOST] pool [parent] [child:NAME...]",
            "  Omit tokens to pool config hosts. Does not enqueue.",
            "  Does not recommend a worker count. Submit with parent:N / child:NAME:N or pool:N.",
        )
        return 0
    end
    opts.show_version && (DistSSHRun.println_kit_version(); return 0)
    allow = config_host_names(load_config())
    include_parent, hosts = pool_hosts_from_allow(
        opts.include_parent,
        opts.hosts,
        allow,
    )
    tokens = String[]
    include_parent && push!(tokens, format_placement_token(:parent, PARENT_HOST_NAME))
    for h in hosts
        if startswith(h, "child:") || is_parent_host_name(h)
            push!(tokens, h)
        else
            push!(tokens, format_placement_token(:child, h))
        end
    end
    if isempty(tokens)
        DistSSHRun.show_pool_usage()
        return 0
    end
    project = job_project()
    DistSSHRun.print_header(cli_heading("pool"))
    DistSSHRun.writeln_field("Project", short_path(project))
    DistSSHRun.kit_println()
    session = DistSSHRun.DistSSHSession(;
        project = project,
        workers = tokens,
        quiet = opts.cli_session.quiet,
        verbosity = opts.cli_session.verbosity,
        yes = opts.cli_session.yes,
    )
    result = DistSSHRun.pool!(session)
    DistSSHRun.print_pool(result)
    print_pool_inventory_notes!()
    warn_worker_julia(tokens)
    return result.ok ? 0 : 1
end
