# CLI `pool`: DistSSHKit `pool!` on the queue host (cwd / project).
#
# Cores / RAM / reachability. No slot estimate. Does not enqueue.
# No tokens: pool every name on config `hosts`. From a client: `qhost:HOST pool …`.
function clamp_pool_slots(slots::Int, allow::Union{Nothing, HostAllow}, host::AbstractString)::Int
    allow === nothing && return slots
    name = String(host)
    cap = get(allow, name, slots)
    return min(slots, cap)
end

function pool_hosts_from_allow(
        include_head::Bool,
        hosts::Vector{String},
        allow::Union{Nothing, HostAllow},
    )::Tuple{Bool, Vector{String}}
    isempty(hosts) || return include_head, String[String(h) for h in hosts]
    include_head && return include_head, String[String(h) for h in hosts]
    allow === nothing && throw(
        ArgumentError(
            "pool: pass SSH host names, or add-host first",
        )
    )
    isempty(allow) && throw(ArgumentError("pool: hosts = []; add-host first"))
    out = String[]
    for n in sorted_registry_hosts(allow)
        push!(out, n)
    end
    return true, out
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
            "  $(cli_m()) [qhost:HOST] pool [HOST...]",
            "  Omit hosts to pool config registry. Head is always listed first.",
            "  Does not enqueue or recommend a worker count (parent:N sizing was removed).",
            "  Submit with --head-workers and machine tokens (or pool:N).",
        )
        return 0
    end
    opts.show_version && (DistSSHRun.println_kit_version(); return 0)
    allow = config_host_names(load_config())
    include_head, hosts = pool_hosts_from_allow(
        opts.include_parent,
        opts.hosts,
        allow,
    )
    tokens = String[
        format_machine_token(allow === nothing ? 1 : get(allow, h, 1), h) for h in hosts
    ]
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
        include_head_for_size = include_head,
    )
    result = DistSSHRun.pool!(session)
    DistSSHRun.print_pool(result)
    print_pool_inventory_notes!()
    warn_worker_julia(tokens)
    return result.ok ? 0 : 1
end
