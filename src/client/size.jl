"""CLI `size`: DistSSHKit `size` / `size!` on the queue host (cwd / project).

Same argv as Kit (`parent` / `child:NAME`, `--gb-per-worker`, `--probe`, …).
No tokens: size every name on config `hosts`. Does not enqueue.
From a client: `qhost:HOST size …`.
"""

function size_hosts_from_allow(
        include_parent::Bool,
        hosts::Vector{String},
        allow::Union{Nothing, HostAllow},
    )::Tuple{Bool, Vector{String}}
    isempty(hosts) || return include_parent, String[String(h) for h in hosts]
    include_parent && return include_parent, String[String(h) for h in hosts]
    allow === nothing && throw(
        ArgumentError(
            "size: pass `parent` / `child:NAME`, or add-host first",
        )
    )
    isempty(allow) && throw(ArgumentError("size: hosts = []; add-host first"))
    out = String[]
    parent = false
    for n in sorted_kit_ssh_names(allow)
        if DistSSHBase.is_parent_host_name(n)
            parent = true
        else
            push!(out, n)
        end
    end
    return parent, out
end

function print_queue_size_submit(include_parent::Bool, hosts::Vector{String}, plan)
    local_n = plan.parent_workers
    parts = String[]
    include_parent && local_n > 0 && push!(parts, "parent:$local_n")
    for h in hosts
        n = get(plan.child_workers, h, 0)
        n > 0 && push!(parts, "child:$h:$n")
    end
    print_inspect_submit_template("drive", parts)
    return nothing
end

function size_cli(args::Vector{String})::Cint
    opts = DistSSHRun.parse_size_args(args)
    if opts.show_help
        DistSSHRun.show_size_usage()
        DistSSHBase.print_help_blank()
        DistSSHBase.print_help_section("Queue"; io = stdout)
        DistSSHBase.print_help_lines(
            stdout,
            "  Same flags as DistSSHKit size. Runs on the queue host (cwd / project).",
            "  $(DistSSHBase.cli_m()) [qhost:HOST] size [parent] [child:NAME...]",
            "  Omit tokens to size config hosts. Does not enqueue.",
        )
        return 0
    end
    opts.show_version && (DistSSHRun.println_kit_version(); return 0)
    include_parent, hosts = size_hosts_from_allow(
        opts.include_parent,
        opts.hosts,
        config_host_names(load_config()),
    )
    all_hosts = include_parent ? [DistSSHBase.PARENT_HOST_NAME; hosts] : copy(hosts)
    if isempty(all_hosts)
        DistSSHRun.show_size_usage()
        return 0
    end
    project = job_project()
    DistSSHRun.print_header(DistSSHBase.cli_heading("size"))
    DistSSHRun.writeln_field("Project", DistSSHBase.short_path(project))
    DistSSHRun.kit_println()
    samples = DistSSHRun.resolve_worker_memory_samples(project, all_hosts, hosts, opts)
    samples === nothing && return 1
    DistSSHRun.kit_println()
    DistSSHRun.print_size_report(
        all_hosts,
        hosts,
        samples,
        opts;
        show_peak = (opts.probe !== nothing && opts.gb_per_worker === nothing),
    )
    plan = DistSSHRun.compute_worker_plan(
        all_hosts,
        hosts,
        DistSSHRun.per_worker_gb_dict(samples);
        mem_headroom = opts.mem_headroom,
        parent_gb = opts.parent_gb,
    )
    print_queue_size_submit(include_parent, hosts, plan)
    return 0
end
