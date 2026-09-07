"""CLI `pool`: DistSSHKit `pool!` on the queue host (cwd / project).

Cores / RAM / slot hint. No RSS (`size` does that). Does not enqueue.
No tokens: pool every name on config `hosts`. From a client: `qhost:HOST pool …`.
"""

function print_queue_pool_submit(pool)
    parts = String[]
    for row in pool.hosts
        row.ok && row.slots > 0 || continue
        if DistSSHKit.is_parent_host_name(row.host)
            push!(parts, "parent:$(row.slots)")
        else
            push!(parts, "child:$(row.host):$(row.slots)")
        end
    end
    println("Queue submit:")
    if isempty(parts)
        println("  julia --project=. -m DistSSHQueue submit drive SCRIPT.jl")
    else
        println("  julia --project=. -m DistSSHQueue submit drive ", join(parts, " "), " SCRIPT.jl")
    end
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
    include_parent, hosts = size_hosts_from_allow(
        opts.include_parent,
        opts.hosts,
        config_host_names(load_config()),
    )
    tokens = String[]
    include_parent && push!(tokens, "parent")
    for h in hosts
        push!(tokens, startswith(h, "child:") || DistSSHKit.is_parent_host_name(h) ? h : "child:$h")
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
    any(row -> row.ok && row.slots > 0, result.hosts) && print_queue_pool_submit(result)
    return result.ok ? 0 : 1
end
