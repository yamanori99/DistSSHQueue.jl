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

function submit_cli(store::AbstractString, kind::Symbol, script::AbstractString, hosts, kw::Dict{String,Any})
    q = Queue(; store=store, follow_config=true)
    nt = isempty(kw) ? NamedTuple() : (; (Symbol(k) => v for (k, v) in kw)...)
    id = submit!(q, String(script), String[String(x) for x in hosts]; kind=kind, nt...)
    println(id)
    if !_kit_env_on("DISTSSHKIT_QUIET")
        println(stderr, "queue: local ($(gethostname()))")
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

function submit_kind(kind::Symbol, args::Vector{String})::Cint
    parsed = kit_parse_args(kind, args)
    parsed.help && (kit_show_usage(kind); return 0)
    parsed.show_version && (DistSSHKit.println_kit_version(); return 0)
    verb = String(kind)
    return submit_cli(
        store_path(),
        kind,
        script_arg(parsed.script_path, verb),
        submit_hosts(parsed; kind=kind),
        submit_kit_bag(parsed; kind=kind),
    )
end

submit_go(args::Vector{String})::Cint = submit_kind(:go, args)
submit_drive(args::Vector{String})::Cint = submit_kind(:drive, args)
submit_ride(args::Vector{String})::Cint = submit_kind(:ride, args)

function submit_main(args::Vector{String})::Cint
    isempty(args) && throw(ArgumentError("submit: need `go`, `ride`, or `drive`"))
    kit, rest = String(args[1]), String[String(a) for a in args[2:end]]
    kit in ("-h", "--help") && (show_usage(); return 0)
    return submit_kind(kit_kind_from_cli(kit), rest)
end
