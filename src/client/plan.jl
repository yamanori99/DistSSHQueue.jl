"""CLI `plan`: DistSSHKit `plan` on the queue host (cwd / project).

Inspect a script. Does not enqueue. From a client: `qhost:HOST plan …`.
"""

function print_queue_plan_submit(kp)
    kind = String(kp.suggest)
    parts = String[]
    slots = kp.slots
    if slots !== nothing
        append!(parts, DistSSHKit.resolved_placement_tokens(slots))
    end
    print_inspect_submit_template(kind, parts)
    return nothing
end

function plan_cli(args::Vector{String})::Cint
    opts = DistSSHKit.parse_plan_args(args)
    if opts.show_help
        DistSSHKit.show_plan_usage()
        DistSSHKit.print_help_blank()
        DistSSHKit.print_help_section("Queue"; io=stdout)
        DistSSHKit.print_help_lines(stdout,
            "  Same flags as DistSSHKit plan. Runs on the queue host (cwd / project).",
            "  julia -m DistSSHQueue [qhost:HOST] plan [parent] [child:NAME...] SCRIPT.jl",
            "  Does not enqueue.",
        )
        return 0
    end
    opts.show_version && (DistSSHKit.println_kit_version(); return 0)
    opts.script_path === nothing && (DistSSHKit.show_plan_usage(); return 0)
    script = script_arg(opts.script_path, "plan")
    project = job_project()
    DistSSHKit.print_header("DistSSHQueue plan")
    DistSSHKit.writeln_field("Project", DistSSHKit.short_path(project))
    DistSSHKit.kit_println()
    kp = DistSSHKit.plan(
        script;
        workers=opts.tokens,
        project=project,
        gb_per_worker=opts.gb_per_worker,
        probe=opts.probe,
        mem_headroom=opts.mem_headroom,
        parent_gb=opts.parent_gb,
    )
    DistSSHKit.print_plan(kp)
    kp.ok && print_queue_plan_submit(kp)
    return kp.ok ? 0 : 1
end
