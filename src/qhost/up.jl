"""Align config hosts with juliaup. `up update` leaves the default."""

function up_main(args::Vector{String})::Cint
    config = config_path()
    update = false
    i = 1
    while i <= length(args)
        a = args[i]
        if a in ("-h", "--help")
            print_up_usage()
            return 0
        elseif a == "--config" && i < length(args)
            config = args[i + 1]
            i += 2
        elseif a == "update" && !update
            update = true
            i += 1
        elseif a == "update"
            throw(ArgumentError("`update` comes first: $(DistSSHRun.cli_m()) $(DistSSHRun.cli_qhost())up update"))
        elseif a in ("--juliaup", "--juliaup-update")
            gone = a == "--juliaup-update" ? "up update" : "up"
            throw(ArgumentError("$(DistSSHRun.cli_qhost())setup $a is now: $(DistSSHRun.cli_m()) $(DistSSHRun.cli_qhost())$gone"))
        elseif a == "--force"
            throw(ArgumentError("$(DistSSHRun.cli_qhost())up does not take --force"))
        elseif startswith(a, "-")
            throw(ArgumentError("unknown up option: $(a)"))
        else
            throw(ArgumentError("$(DistSSHRun.cli_qhost())up does not take host tokens; targets are config hosts"))
        end
    end
    cfg = load_config(; path = config)
    apply_config_env!(cfg)
    allow = config_host_names(cfg)
    (allow === nothing || isempty(allow)) && throw(
        ArgumentError("$(DistSSHRun.cli_qhost())up needs add-host first"),
    )
    names = sorted_kit_ssh_names(allow)
    confirm = !_queue_env_on("DISTSSHKIT_YES")
    result = if update
        DistSSHRun.juliaup_update_remotes(names; confirm = confirm)
    else
        DistSSHRun.juliaup_align_remotes(names; confirm = confirm)
    end
    return result.failed > 0 ? Cint(1) : Cint(0)
end
