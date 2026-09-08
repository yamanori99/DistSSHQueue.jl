"""Write `config.toml` if missing. Re-run is a no-op unless `--force`. OS unit: `enable`."""

function default_bindir(; home::AbstractString=homedir())::String
    return joinpath(home, ".local", "bin")
end

"""Path of a leftover `dskq` shim (no longer installed). `teardown` still removes it."""
function wrapper_path(; bindir::AbstractString=default_bindir())::String
    return joinpath(bindir, "dskq")
end

function setup(;
    config::AbstractString=config_path(),
    force::Bool=false,
)
    if force && isfile(config)
        rm(config; force=true)
    end
    wrote = write_config_template(config)
    wrote ? print_wrote(config) : print_present(config)
    return 0
end

function setup_main(args::Vector{String})::Cint
    config = config_path()
    force = false
    juliaup = false
    hosts = String[]
    i = 1
    while i <= length(args)
        a = args[i]
        if a in ("-h", "--help")
            show_usage()
            return 0
        elseif a == "--config" && i < length(args)
            config = args[i+1]
            i += 2
        elseif a == "--force"
            force = true
            i += 1
        elseif a == "--juliaup"
            juliaup = true
            i += 1
        elseif a == "--service"
            throw(ArgumentError("setup --service is gone; run: julia -m DistSSHQueue enable"))
        elseif a == "--write-only"
            throw(ArgumentError("setup --write-only is gone; setup only writes config.toml"))
        elseif startswith(a, "-")
            throw(ArgumentError("unknown setup option: $(a)"))
        else
            push!(hosts, a)
            i += 1
        end
    end
    if juliaup
        force && throw(ArgumentError("setup --juliaup cannot combine with --force"))
        cfg = load_config(; path=config)
        apply_config_env!(cfg)
        names = if isempty(hosts)
            allow = config_host_names(cfg)
            (allow === nothing || isempty(allow)) && throw(ArgumentError(
                "setup --juliaup needs hosts on the command line or add-host first",
            ))
            sorted_kit_ssh_names(allow)
        else
            String[kit_ssh_name(h) for h in hosts]
        end
        confirm = !_queue_env_on("DISTSSHKIT_YES")
        result = DistSSHKit.juliaup_align_remotes(names; confirm=confirm)
        return result.failed > 0 ? Cint(1) : Cint(0)
    end
    isempty(hosts) || throw(ArgumentError("unknown setup option: $(hosts[1])"))
    return setup(; config=config, force=force)
end
