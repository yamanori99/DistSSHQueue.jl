"""Client `submit go` / `submit ride` / `submit drive` (Kit parsers). After `qhost:` ssh, on the staged tree."""

function drop_nothing(d::Dict{String,Any})
    out = Dict{String,Any}()
    for (k, v) in d
        v === nothing && continue
        if v isa Symbol
            out[k] = String(v)
        elseif v isa AbstractVector && isempty(v)
            continue
        else
            out[k] = v
        end
    end
    return out
end

function submit_hosts(parsed; kind::Symbol)::Vector{String}
    return DistSSHKit.host_tokens(parsed; kind=kind)
end

function submit_kit_bag(parsed; kind::Symbol)::Dict{String,Any}
    raw = DistSSHKit.execute_kwargs_from_parsed(parsed; kind=kind)
    return drop_nothing(Dict{String,Any}(String(k) => v for (k, v) in raw))
end

"""Peel `pool:N` from Queue selector positions, not Kit option values.

`submit go --julia pool:8 …` keeps `pool:8` as `--julia`'s value.
After `--`, remaining tokens are script args.
"""
function peel_submit_pool(args::Vector{String})
    n = nothing
    out = String[]
    skip_value = false
    passthrough = false
    for a in args
        if passthrough
            push!(out, a)
            continue
        end
        if skip_value
            push!(out, a)
            skip_value = false
            continue
        end
        if a == "--"
            passthrough = true
            push!(out, a)
            continue
        end
        if a == "pool"
            throw(ArgumentError(
                "`pool` is the inspect verb. For submit slots use `pool:N` " *
                "(e.g. submit pool:8 drive SCRIPT.jl). Inspect: julia -m DistSSHQueue pool",
            ))
        elseif startswith(a, "pool:")
            n === nothing || throw(ArgumentError("pool:N given twice"))
            raw = strip(chopprefix(a, "pool:"))
            slots = tryparse(Int, raw)
            (slots === nothing || slots < 1) && throw(ArgumentError(
                "pool:N needs a positive integer (got $(repr(a)))",
            ))
            n = slots
        else
            push!(out, a)
            skip_value = _kit_flag_takes_value(a)
        end
    end
    return out, n
end

function _kit_flag_takes_value(a::AbstractString)::Bool
    startswith(a, "--") || startswith(a, "-") || return false
    occursin('=', a) && return false
    a in (
        "--julia", "--output-dir", "--repeat", "--gb-per-worker", "--probe",
        "--mem-headroom", "--parent-gb", "--workers", "-w", "--hosts",
        "--hosts-file", "--n", "--log-dir", "--package", "--project",
    )
end

function expand_pool_submit_hosts(slots::Int)::Vector{String}
    allow = config_host_names(load_config())
    (allow === nothing || isempty(allow)) && throw(ArgumentError(
        "pool:N needs config hosts; add-host first",
    ))
    out = String[]
    for name in sorted_kit_ssh_names(allow)
        n = clamp_pool_slots(slots, allow, name)
        n < 1 && continue
        role = DistSSHKit.is_parent_host_name(name) ? :parent : :child
        push!(out, DistSSHKit.format_placement_token(role, String(name), n))
    end
    isempty(out) && throw(ArgumentError("pool:N: no hosts left after add-host max"))
    return out
end

function submit_cli(store::AbstractString, kind::Symbol, script::AbstractString, hosts, kw::Dict{String,Any})
    q = Queue(; store=store, follow_config=true)
    nt = isempty(kw) ? NamedTuple() : (; (Symbol(k) => v for (k, v) in kw)...)
    forced = strip(get(ENV, JOB_ID_ENV, ""))
    id = if isempty(forced)
        submit!(q, String(script), String[String(x) for x in hosts]; kind=kind, nt...)
    else
        submit!(q, String(script), String[String(x) for x in hosts]; kind=kind, id=forced, nt...)
    end
    println(id)
    if !_kit_env_on("DISTSSHKIT_QUIET")
        qh = qhost_display_from_env()
        if qh !== nothing && !isempty(strip(qh))
            println(stderr, "queue: qhost:$(strip(qh))")
        else
            println(stderr, "queue: local ($(gethostname()))")
        end
        nq = count(j -> j.state === :queued, q.jobs)
        nr = count(j -> j.state === :running, q.jobs)
        if nr > 0
            println(stderr, "Queued  $(nq)  ($(nr) running)")
        else
            println(stderr, "Queued  $(nq)")
        end
    end
    ensure_serve!(store)
    return 0
end

script_arg(::Nothing, verb::AbstractString) = throw(ArgumentError("$verb: missing SCRIPT.jl"))
function script_arg(path::AbstractString, ::AbstractString)::String
    resolved = resolve_script(path)
    isfile(resolved) && return resolved
    throw(ArgumentError(
        DistSSHKit.explain_script_not_found(resolved, job_project(); surface=:cli),
    ))
end

"""Parse Kit execute argv. One table: add a kind here, in `KIT_EXECUTE_KINDS`, and in `main`."""
function kit_parse_args(kind::Symbol, args::Vector{String})
    kind === :go && return DistSSHKit.parse_go_args(args)
    kind === :drive && return DistSSHKit.parse_drive_args(args)
    kind === :ride && return DistSSHKit.parse_ride_args(args)
    throw(ArgumentError("submit: unknown kit command $(repr(kind))"))
end

function kit_show_usage(kind::Symbol)
    kind === :go && return DistSSHKit.show_go_usage()
    kind === :drive && return DistSSHKit.show_drive_usage()
    kind === :ride && return DistSSHKit.show_ride_usage()
    throw(ArgumentError("submit: unknown kit command $(repr(kind))"))
end

function kit_kind_from_cli(name::AbstractString)::Symbol
    k = Symbol(String(name))
    is_kit_execute_kind(k) || throw(ArgumentError(
        "submit: unknown kit command $(repr(name)) (want go, ride, or drive)",
    ))
    return k
end

function submit_kind(kind::Symbol, args::Vector{String}; pool_slots::Union{Nothing,Int}=nothing)::Cint
    rest, peeled = peel_submit_pool(args)
    slots = if pool_slots !== nothing && peeled !== nothing
        throw(ArgumentError("pool:N given twice"))
    elseif pool_slots !== nothing
        pool_slots
    else
        peeled
    end
    parsed = kit_parse_args(kind, rest)
    if parsed.help
        DistSSHKit.print_help_section("Queue"; io=stdout)
        DistSSHKit.print_help_lines(stdout,
            "  `submit $(kind)` enqueues. `qhost:HOST` is the SSH name of the queue machine, not a Kit slot.",
        )
        DistSSHKit.print_help_blank(stdout)
        DistSSHKit.print_help_section("DistSSHKit"; io=stdout)
        DistSSHKit.print_help_lines(stdout,
            "  Same argv as `julia -m DistSSHKit $(kind) …` (`parent:N` / `child:NAME:N`).",
        )
        DistSSHKit.print_help_blank(stdout)
        kit_show_usage(kind)
        return 0
    end
    parsed.show_version && (DistSSHKit.println_kit_version(); return 0)
    verb = String(kind)
    hosts = submit_hosts(parsed; kind=kind)
    if slots !== nothing
        isempty(hosts) || throw(ArgumentError(
            "pool:N cannot mix with parent / child tokens",
        ))
        hosts = expand_pool_submit_hosts(slots)
    end
    return submit_cli(
        store_path(),
        kind,
        script_arg(parsed.script_path, verb),
        hosts,
        submit_kit_bag(parsed; kind=kind),
    )
end

function submit_main(args::Vector{String})::Cint
    isempty(args) && throw(ArgumentError("submit: need `go`, `ride`, or `drive`"))
    rest, slots = peel_submit_pool(args)
    isempty(rest) && throw(ArgumentError("submit: need `go`, `ride`, or `drive`"))
    kit, rest2 = String(rest[1]), String[String(a) for a in rest[2:end]]
    kit in ("-h", "--help") && (show_usage(); return 0)
    return submit_kind(kit_kind_from_cli(kit), rest2; pool_slots=slots)
end
