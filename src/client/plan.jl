"""CLI `plan`: DistSSHKit `plan` on the queue host (cwd / project).

Inspect a script. Does not enqueue. From a client: `qhost:HOST plan …`.
"""

function print_queue_plan_submit(kp)
    kind = String(kp.suggest)
    parts = String[]
    slots = kp.slots
    if slots !== nothing
        append!(parts, DistSSHRun.resolved_placement_tokens(slots))
    end
    print_inspect_submit_template(kind, parts)
    return nothing
end

function plan_cli(args::Vector{String})::Cint
    opts = DistSSHRun.parse_plan_args(args)
    if opts.show_help
        DistSSHRun.show_plan_usage()
        DistSSHRun.print_help_blank()
        DistSSHRun.print_help_section("Queue"; io = stdout)
        DistSSHRun.print_help_lines(
            stdout,
            "  Same flags as DistSSHKit plan. Runs on the queue host (cwd / project).",
            "  julia -m DistSSHQueue [qhost:HOST] plan [parent] [child:NAME...] SCRIPT.jl",
            "  Does not enqueue.",
        )
        return 0
    end
    opts.show_version && (DistSSHRun.println_kit_version(); return 0)
    opts.script_path === nothing && (DistSSHRun.show_plan_usage(); return 0)
    script = script_arg(opts.script_path, "plan")
    project = job_project()
    DistSSHRun.print_header("DistSSHQueue plan")
    DistSSHRun.writeln_field("Project", DistSSHRun.short_path(project))
    DistSSHRun.kit_println()
    kp = DistSSHRun.plan(
        script;
        workers = opts.tokens,
        project = project,
        gb_per_worker = opts.gb_per_worker,
        probe = opts.probe,
        mem_headroom = opts.mem_headroom,
        parent_gb = opts.parent_gb,
    )
    DistSSHRun.print_plan(kp)
    kp.ok && print_queue_plan_submit(kp)
    return kp.ok ? 0 : 1
end
