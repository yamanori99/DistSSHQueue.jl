"""juliaup verbs on config hosts. `default` changes the host default."""

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
            throw(ArgumentError("$(DistSSHBase.cli_qhost())setup $a is now: $(DistSSHBase.cli_m()) $(DistSSHBase.cli_qhost())$gone"))
        elseif a == "--force"
            throw(ArgumentError("$(DistSSHBase.cli_qhost())up does not take --force"))
        elseif startswith(a, "-")
            throw(ArgumentError("unknown up option: $(a)"))
        elseif isempty(verb)
            throw(ArgumentError("$(DistSSHBase.cli_qhost())up needs add, default, update, or status"))
        elseif channel === nothing && !startswith(a, "child:") && a != "parent" && !startswith(a, "parent:")
            channel = a
            i += 1
        else
            throw(ArgumentError("$(DistSSHBase.cli_qhost())up does not take host tokens; targets are config hosts"))
        end
    end
    isempty(verb) && throw(ArgumentError("$(DistSSHBase.cli_qhost())up needs add, default, update, or status"))
    if verb in ("add", "default") && channel === nothing
        throw(ArgumentError("$verb needs a channel: $(DistSSHBase.cli_m()) $(DistSSHBase.cli_qhost())up $verb 1.13"))
    end
    cfg = load_config(; path = config)
    apply_config_env!(cfg)
    allow = config_host_names(cfg)
    (allow === nothing || isempty(allow)) && throw(
        ArgumentError("$(DistSSHBase.cli_qhost())up needs add-host first"),
    )
    names = sorted_kit_ssh_names(allow)
    confirm = verb == "default" && !_queue_env_on("DISTSSHKIT_YES")
    result = DistSSHRun.juliaup_verb_remotes(names; verb = verb, channel = channel, confirm = confirm)
    return result.failed > 0 ? Cint(1) : Cint(0)
end
