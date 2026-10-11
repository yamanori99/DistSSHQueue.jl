# Remove queue-host state: serve, OS unit, store, `~/.distsshqueue`.
#
# A leftover `dskq` shim from older `setup` is removed if present.
# Leftover DistSSHKitQueue `~/.distsshkitqueue` and old OS units are removed too.
#
# Does not `Pkg.rm` or delete a git clone. Kit `.distsshkit/` next to a clone stays.
# Deletion needs every existing target in `confirm_paths` (CLI `--confirm-path`).
# `-y` / `--yes` and `DISTSSHKIT_YES` (process or config `[env]`) do not authorize it.
function teardown_yes()::Bool
    _yes_from_config() && return false
    v = strip(get(ENV, "DISTSSHKIT_YES", ""))
    return v in ("1", "true", "yes", "on")
end

function teardown_store(; home::AbstractString = homedir(), config::AbstractString = config_path(; home = home))::String
    env = strip(get(ENV, "DISTSSHQUEUE_STORE", ""))
    isempty(env) || return env
    st = config_store_path(load_config(; path = config))
    st === nothing || return st
    return default_store_path(; home = home)
end

function teardown_targets(;
        home::AbstractString = homedir(),
        bindir::AbstractString = default_bindir(; home = home),
        config::AbstractString = config_path(; home = home),
    )::Vector{String}
    st = teardown_store(; home = home, config = config)
    data = queue_data_dir(; home = home)
    legacy = joinpath(home, ".distsshkitqueue")
    wrap = wrapper_path(; bindir = bindir)
    out = String[wrap, st, store_pid_path(st), store_stop_path(st), string(st, ".log"), string(st, ".lock"), config, data, legacy]
    if Sys.isapple()
        push!(out, launch_agent_path(; home = home))
        push!(out, legacy_launch_agent_path(; home = home))
    elseif Sys.islinux()
        push!(out, systemd_user_path(; home = home))
        push!(out, legacy_systemd_user_path(; home = home))
    end
    seen = Set{String}()
    uniq = String[]
    for p in out
        canonical_local_path(p) in seen && continue
        push!(seen, canonical_local_path(p))
        push!(uniq, p)
    end
    return uniq
end

function teardown(;
        home::AbstractString = homedir(),
        bindir::AbstractString = default_bindir(; home = home),
        config::AbstractString = config_path(; home = home),
        confirm_paths::AbstractVector{<:AbstractString} = String[],
        apply::Bool = true,
        io::IO = stdout,
    )::Cint
    targets = teardown_targets(; home = home, bindir = bindir, config = config)
    existing = String[p for p in targets if ispath(p)]
    if !_teardown_granted(confirm_paths, existing)
        if !isempty(confirm_paths)
            print_help_lines(io, "  confirm_paths does not match the paths that would be removed.")
            return 1
        end
        print_help_section("Would remove"; io = io)
        if isempty(existing)
            print_help_lines(io, "  (nothing)")
        else
            for p in existing
                print_help_lines(io, "  $(_confirm_path_quote(_q_short(p)))")
            end
        end
        print_help_lines(io, "  Pass --confirm-path for each quoted path above.")
        return 0
    end
    st = teardown_store(; home = home, config = config)
    apply && stop_serve!(st)
    try
        service_uninstall(; apply = apply, home = home, announce = false)
    catch
    end
    wrap = wrapper_path(; bindir = bindir)
    ispath(wrap) && rm(wrap; force = true)
    for extra in (st, store_pid_path(st), store_stop_path(st), string(st, ".log"), string(st, ".lock"))
        ispath(extra) && rm(extra; force = true, recursive = true)
    end
    ispath(config) && rm(config; force = true)
    data = queue_data_dir(; home = home)
    isdir(data) && rm(data; force = true, recursive = true)
    legacy = joinpath(home, ".distsshkitqueue")
    isdir(legacy) && rm(legacy; force = true, recursive = true)
    for p in existing
        print_removed(p; io = io)
    end
    return 0
end

function _confirm_path_quote(path::AbstractString)::String
    return "'" * replace(String(path), "'" => "'\\''") * "'"
end

function _teardown_confirm_set(paths)::Set{String}
    return Set(canonical_local_path(strip(String(p))) for p in paths if !isempty(strip(String(p))))
end

"""True when `confirm_paths` names every existing target and nothing else."""
function _teardown_granted(confirm_paths, existing)::Bool
    return !isempty(existing) &&
        _teardown_confirm_set(confirm_paths) == _teardown_confirm_set(existing)
end

function teardown_main(args::Vector{String}; process_yes::Bool = teardown_yes())::Cint
    # Sampled by `_main` before config `[env]` is applied. Not a delete grant.
    _ = process_yes
    home = homedir()
    bindir = nothing
    config = nothing
    confirm_paths = String[]
    saw_yes = false
    apply = true
    i = 1
    while i <= length(args)
        a = args[i]
        if a in ("-h", "--help")
            print_teardown_usage()
            return 0
        elseif a in ("-y", "--yes")
            saw_yes = true
            i += 1
        elseif a == "--confirm-path" && i < length(args)
            raw = strip(args[i + 1])
            isempty(raw) && throw(ArgumentError("--confirm-path needs a non-empty path"))
            push!(confirm_paths, String(raw))
            i += 2
        elseif a == "--write-only"
            apply = false
            i += 1
        elseif a == "--home" && i < length(args)
            home = args[i + 1]
            i += 2
        elseif a == "--bindir" && i < length(args)
            bindir = args[i + 1]
            i += 2
        elseif a == "--config" && i < length(args)
            config = args[i + 1]
            i += 2
        else
            throw(ArgumentError("unknown teardown option: $(a)"))
        end
    end
    bd = bindir === nothing ? default_bindir(; home = home) : String(bindir)
    cfg = config === nothing ? config_path(; home = home) : String(config)
    apply_config_env!(load_config(; path = cfg))
    targets = teardown_targets(; home = home, bindir = bd, config = cfg)
    existing = String[p for p in targets if ispath(p)]
    granted = _teardown_granted(confirm_paths, existing)
    if saw_yes && !granted
        print_help_lines(stderr, "  -y / --yes does not delete. Pass --confirm-path.")
    end
    if !isempty(confirm_paths) && !granted
        print_help_lines(stderr, "  --confirm-path does not match the paths that would be removed.")
        return 1
    end
    return teardown(;
        home = home,
        bindir = bd,
        config = cfg,
        confirm_paths = confirm_paths,
        apply = apply,
    )
end
