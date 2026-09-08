"""CLI `pool`: DistSSHKit `pool!` on the queue host (cwd / project).

Cores / RAM / slot hint. No RSS (`size` does that). Does not enqueue.
No tokens: pool every name on config `hosts`. From a client: `qhost:HOST pool …`.
"""

function clamp_pool_slots(slots::Int, allow::Union{Nothing, HostAllow}, host::AbstractString)::Int
    allow === nothing && return slots
    name = DistSSHKit.is_parent_host_name(host) ? DistSSHKit.PARENT_HOST_NAME : String(host)
    cap = get(allow, name, nothing)
    cap === nothing && return slots
    return min(slots, cap)
end

function print_queue_pool_submit(pool, allow::Union{Nothing, HostAllow}=nothing)
    parts = String[]
    for row in pool.hosts
        row.ok || continue
        slots = clamp_pool_slots(row.slots, allow, row.host)
        slots > 0 || continue
        role = DistSSHKit.is_parent_host_name(row.host) ? :parent : :child
        name = role === :parent ? DistSSHKit.PARENT_HOST_NAME : String(row.host)
        push!(parts, DistSSHKit.format_placement_token(role, name, slots))
    end
    print_inspect_submit_template("drive", parts)
    return nothing
end

function pool_cli(args::Vector{String})::Cint
    opts = DistSSHKit.parse_pool_args(args)
    if opts.show_help
        DistSSHKit.show_pool_usage()
        DistSSHKit.print_help_blank()
        DistSSHKit.print_help_section("Queue"; io=stdout)
        DistSSHKit.print_help_lines(stdout,
            "  Same flags as DistSSHKit pool. Runs on the queue host (cwd / project).",
            "  julia -m DistSSHQueue [qhost:HOST] pool [parent] [child:NAME...]",
            "  Omit tokens to pool config hosts. Does not enqueue.",
        )
        return 0
    end
    opts.show_version && (DistSSHKit.println_kit_version(); return 0)
    allow = config_host_names(load_config())
    include_parent, hosts = size_hosts_from_allow(
        opts.include_parent,
        opts.hosts,
        allow,
    )
    tokens = String[]
    include_parent && push!(tokens, DistSSHKit.format_placement_token(:parent, DistSSHKit.PARENT_HOST_NAME))
    for h in hosts
        if startswith(h, "child:") || DistSSHKit.is_parent_host_name(h)
            push!(tokens, h)
        else
            push!(tokens, DistSSHKit.format_placement_token(:child, h))
        end
    end
    if isempty(tokens)
        DistSSHKit.show_pool_usage()
        return 0
    end
    project = job_project()
    DistSSHKit.print_header("DistSSHQueue pool")
    DistSSHKit.writeln_field("Project", DistSSHKit.short_path(project))
    DistSSHKit.kit_println()
    session = DistSSHKit.KitSession(;
        project=project,
        workers=tokens,
        quiet=opts.cli_session.quiet,
        verbosity=opts.cli_session.verbosity,
        yes=opts.cli_session.yes,
    )
    result = DistSSHKit.pool!(
        session;
        gb_per_worker=opts.gb_per_worker,
        mem_headroom=opts.mem_headroom,
        parent_gb=opts.parent_gb,
    )
    DistSSHKit.print_pool(result)
    print_pool_inventory_notes!(;
        gb_per_worker=opts.gb_per_worker,
        mem_headroom=opts.mem_headroom,
        parent_gb=opts.parent_gb,
    )
    any(row -> row.ok && clamp_pool_slots(row.slots, allow, row.host) > 0, result.hosts) &&
        print_queue_pool_submit(result, allow)
    return result.ok ? 0 : 1
end
