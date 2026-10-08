# juliaup verbs on config hosts. `default` changes the host default.
function up_main(args::Vector{String})::Cint
    config = config_path()
    verb = ""
    channel = nothing
    i = 1
    verbs = ("add", "default", "update", "status")
    while i <= length(args)
        a = args[i]
        if a in ("-h", "--help")
            print_up_usage()
            return 0
        elseif a == "--config" && i < length(args)
            config = args[i + 1]
            i += 2
        elseif a in verbs && isempty(verb)
            verb = a
            i += 1
        elseif a in ("--juliaup", "--juliaup-update")
            gone = a == "--juliaup-update" ? "up update" : "up add CHANNEL"
            throw(ArgumentError("$(cli_qhost())setup $a is now: $(cli_m()) $(cli_qhost())$gone"))
        elseif a == "--force"
            throw(ArgumentError("$(cli_qhost())up does not take --force"))
        elseif startswith(a, "-")
            throw(ArgumentError("unknown up option: $(a)"))
        elseif isempty(verb)
            throw(ArgumentError("$(cli_qhost())up needs add, default, update, or status"))
        elseif channel === nothing && !startswith(a, "child:") && a != "parent" && !startswith(a, "parent:")
            channel = a
            i += 1
        else
            throw(ArgumentError("$(cli_qhost())up does not take host tokens; targets are config hosts"))
        end
    end
    isempty(verb) && throw(ArgumentError("$(cli_qhost())up needs add, default, update, or status"))
    if verb in ("add", "default") && channel === nothing
        throw(ArgumentError("$verb needs a channel: $(cli_m()) $(cli_qhost())up $verb 1.13"))
    end
    cfg = load_config(; path = config)
    apply_config_env!(cfg)
    allow = config_host_names(cfg)
    (allow === nothing || isempty(allow)) && throw(
        ArgumentError("$(cli_qhost())up needs add-host first"),
    )
    names = sorted_kit_ssh_names(allow)
    confirm = verb == "default" && !_queue_env_on("DISTSSHKIT_YES")
    return _up_run_on_hosts(names; verb = verb, channel = channel, confirm = confirm)
end

"""Run one juliaup verb on config hosts. `default` confirms unless `confirm` is false."""
function _up_run_on_hosts(
        names::Vector{String};
        verb::AbstractString,
        channel::Union{Nothing, AbstractString},
        confirm::Bool,
    )::Cint
    v = String(verb)
    ch = channel === nothing ? nothing : String(channel)
    if v == "default" && confirm
        println(stderr, "  This will run juliaup default $ch on each target.")
        println(stderr, "  That changes the host default Julia.")
        println(stderr, "  Targets: $(join(names, ", "))")
        println(stderr, "  The running process keeps its current Julia until restart.")
        DistSSHRun.kit_confirm("Type 'default' to confirm: "; keyword = "default") || return Cint(0)
    end
    failed = 0
    for host in names
        label = is_parent_host_name(host) ? PARENT_HOST_NAME : host
        try
            if v == "status"
                lines = juliaup_status_lines(host; channel = ch)
                if isempty(lines)
                    println(stdout, "  $label: (none)")
                else
                    for line in lines
                        println(stdout, "  $label: $line")
                    end
                end
            elseif v == "add"
                juliaup_add_host!(host, something(ch, ""))
                println(stdout, "✓ juliaup add$(ch === nothing ? "" : " $ch")")
            elseif v == "default"
                juliaup_default_host!(host, something(ch, ""))
                println(stdout, "✓ juliaup default$(ch === nothing ? "" : " $ch")")
            elseif v == "update"
                juliaup_update_host!(host; channel = ch)
                println(stdout, "✓ juliaup update")
            else
                error("unknown juliaup verb: $v")
            end
        catch e
            failed += 1
            detail = e isa ErrorException ? e.msg : sprint(showerror, e)
            println(stderr, "  $label: $detail")
        end
    end
    return failed > 0 ? Cint(1) : Cint(0)
end
