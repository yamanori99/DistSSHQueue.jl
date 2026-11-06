# Remove queue-host state: serve, OS unit, store, `~/.distsshqueue`.
#
# A leftover `dskq` shim from older `setup` is removed if present.
# Leftover DistSSHKitQueue `~/.distsshkitqueue` and old OS units are removed too.
#
# Does not `Pkg.rm` or delete a git clone. Kit `.distsshkit/` next to a clone stays.
# Deletion needs every existing target in `confirm_paths` (CLI `--confirm-path`).
# `-y` / `--yes` / `DISTSSHKIT_YES` do not authorize it. `up default` still honors
# `DISTSSHKIT_YES`. A live `kit.pid` blocks deletion unless `stop_jobs` is set
# with that same confirm set. `--stop-jobs` with `--write-only` signals nothing.
function teardown_yes()::Bool
    v = strip(get(ENV, "DISTSSHKIT_YES", ""))
    return v in ("1", "true", "yes", "on")
end

const _TEARDOWN_YES_REFUSAL =
    "  -y, --yes, and DISTSSHKIT_YES do not authorize teardown. Nothing deleted. Pass --confirm-path PATH."

function teardown_store(; home::AbstractString = homedir(), config::AbstractString = config_path(; home = home))::String
    env = _process_env_value("DISTSSHQUEUE_STORE")
    if !isempty(env)
        _warn_tilde_store!(env)
        return env
    end
    st = config_store_path(load_config(; path = config))
    st === nothing || return st
    return default_store_path(; home = home)
end

function _teardown_config_file(;
        home::AbstractString,
        config::Union{Nothing, AbstractString},
    )::String
    config !== nothing && return String(config)
    env = _process_env_value("DISTSSHQUEUE_CONFIG")
    return isempty(env) ? default_config_path(; home = home) : env
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
    out = String[
        wrap,
        st,
        store_pid_path(st),
        store_pid_start_path(st),
        store_pid_julia_path(st),
        store_stop_path(st),
        string(st, ".log"),
        string(st, ".lock"),
        store_flock_path(st),
        config,
        data,
        legacy,
    ]
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

function _print_would_remove(existing; io::IO = stdout)
    print_help_section("Would remove"; io = io)
    if isempty(existing)
        print_help_lines(io, "  (nothing)")
    else
        for p in existing
            print_help_lines(io, "  $(_confirm_path_quote(_q_short(p)))")
        end
    end
    return nothing
end

"""A directory store is not a jobs file. Refuse before any path is listed or removed."""
function _refuse_directory_store!(st::AbstractString)
    isdir(st) || return nothing
    throw(ArgumentError("teardown: store is a directory: $(st)"))
end

function _teardown_roots(; home::AbstractString, bindir::AbstractString)::Vector{String}
    roots = String[queue_data_dir(; home = home), String(bindir)]
    if Sys.isapple()
        push!(roots, joinpath(home, "Library", "LaunchAgents"))
    elseif Sys.islinux()
        push!(roots, joinpath(home, ".config", "systemd", "user"))
    end
    return roots
end

function _teardown_path_under(path::AbstractString, root::AbstractString)::Bool
    p = canonical_local_path(path)
    r = canonical_local_path(root)
    p == r && return true
    sep = "/"
    prefix = endswith(r, sep) ? r : r * sep
    return startswith(p, prefix)
end

"""True when `path` is a symlink whose real path leaves the teardown roots."""
function _teardown_symlink_escapes(path::AbstractString, roots)::Bool
    islink(path) || return false
    rp = try
        canonical_local_path(realpath(path))
    catch
        return true
    end
    return !any(root -> _teardown_path_under(rp, root), roots)
end

function _teardown_escape_paths(existing, roots)::Vector{String}
    return String[p for p in existing if _teardown_symlink_escapes(p, roots)]
end

function _print_live_jobs(ids; lead::AbstractString)
    print_help_lines(stderr, lead)
    for id in ids
        print_help_lines(stderr, "  $(id)")
    end
    return nothing
end

function _teardown_blocking_jobs(store::AbstractString)::Vector{Job}
    isfile(store) || return Job[]
    jobs = with_store_lock(store) do
        read_jobs(store)
    end
    return Job[j for j in jobs if j.state === :running && kit_child_alive(j)]
end

function _teardown_still_alive(store::AbstractString, ids)::Vector{String}
    jobs = _teardown_blocking_jobs(store)
    live = Set(j.id for j in jobs)
    return String[id for id in ids if id in live]
end

"""`terminate_run!` each live job. Returns ids that are still alive or that threw."""
function _teardown_stop_live!(jobs::Vector{Job})::Vector{String}
    still = String[]
    for j in jobs
        side = kit_sidecar_dir(j)
        if side === nothing
            push!(still, j.id)
            continue
        end
        try
            DistSSHRun.terminate_run!(side; kind = j.kind)
        catch
            push!(still, j.id)
        end
    end
    return still
end

function _teardown_mark_cancelled!(store::AbstractString, ids)
    isempty(ids) && return nothing
    q = Queue(; store = store, runner = Returns(nothing))
    for id in ids
        _finish!(q, id, :cancelled, nothing)
    end
    return nothing
end

function _confirm_path_quote(path::AbstractString)::String
    return "'" * replace(String(path), "'" => "'\\''") * "'"
end

function _teardown_same_path(given::AbstractString, target::AbstractString)::Bool
    a = canonical_local_path(strip(String(given)))
    b = canonical_local_path(strip(String(target)))
    a == b && return true
    try
        return Base.Filesystem.samefile(a, b)
    catch
        return false
    end
end

"""True when each existing target pairs with one confirm path (string or `samefile`)."""
function _teardown_granted(confirm_paths, existing)::Bool
    isempty(existing) && return false
    given = String[strip(String(p)) for p in confirm_paths if !isempty(strip(String(p)))]
    length(given) == length(existing) || return false
    used = falses(length(given))
    for target in existing
        idx = findfirst(i -> !used[i] && _teardown_same_path(given[i], target), eachindex(given))
        idx === nothing && return false
        used[idx] = true
    end
    return all(used)
end

"""0.9.x still removes an in-tree symlink. A later release will refuse it."""
function _warn_teardown_symlinks!(paths)
    for p in paths
        islink(p) || continue
        _warn_plan_once!(
            "teardown-link:" * String(p),
            "teardown removes a symlink. DistSSHQueue 0.10 will refuse it: $(p)",
        )
    end
    return nothing
end

function _teardown_remove!(;
        home::AbstractString,
        bindir::AbstractString,
        config::AbstractString,
        store::AbstractString,
        existing,
        apply::Bool,
        io::IO,
    )::Cint
    apply && stop_serve!(store)
    again = _teardown_blocking_jobs(store)
    if !isempty(again)
        _print_live_jobs((j.id for j in again); lead = "  teardown refused: live kit.pid:")
        return 1
    end
    try
        service_uninstall(; apply = apply, home = home, announce = false)
    catch
    end
    wrap = wrapper_path(; bindir = bindir)
    ispath(wrap) && rm(wrap; force = true)
    # The store path is a file. `recursive` would remove a directory store.
    ispath(store) && rm(store; force = true)
    for extra in (
            store_pid_path(store),
            store_pid_start_path(store),
            store_pid_julia_path(store),
            store_stop_path(store),
            string(store, ".log"),
            string(store, ".lock"),
            store_flock_path(store),
        )
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

function teardown(;
        home::AbstractString = homedir(),
        bindir::AbstractString = default_bindir(; home = home),
        config::AbstractString = config_path(; home = home),
        confirm_paths::AbstractVector{<:AbstractString} = String[],
        apply::Bool = true,
        stop_jobs::Bool = false,
        yes_attempt::Bool = false,
        io::IO = stdout,
    )::Cint
    if stop_jobs && !apply
        print_help_lines(stderr, "  --stop-jobs cannot be combined with --write-only.")
        return 1
    end
    st0 = teardown_store(; home = home, config = config)
    _refuse_directory_store!(st0)
    targets = teardown_targets(; home = home, bindir = bindir, config = config)
    existing = String[p for p in targets if ispath(p)]
    _warn_teardown_symlinks!(existing)
    roots = _teardown_roots(; home = home, bindir = bindir)
    escapes = _teardown_escape_paths(existing, roots)
    granted = _teardown_granted(confirm_paths, existing)
    blocking = _teardown_blocking_jobs(st0)
    if !isempty(blocking) && !stop_jobs
        _print_live_jobs((j.id for j in blocking); lead = "  teardown refused: live kit.pid:")
        return 1
    end
    if !isempty(blocking) && !granted
        _print_live_jobs((j.id for j in blocking); lead = "  teardown refused: live kit.pid:")
        return 1
    end
    if !granted
        if !isempty(confirm_paths)
            print_help_lines(io, "  confirm_paths does not match the paths that would be removed.")
            return 1
        end
        if yes_attempt
            print_help_lines(stderr, _TEARDOWN_YES_REFUSAL)
            return 1
        end
        _print_would_remove(existing; io = io)
        print_help_lines(io, "  Pass --confirm-path for each quoted path above.")
        return 0
    end
    if !isempty(escapes)
        print_help_lines(stderr, "  teardown refused: path leaves the teardown root:")
        for p in escapes
            print_help_lines(stderr, "  $(p)")
        end
        return 1
    end
    if stop_jobs && !isempty(blocking)
        failed = _teardown_stop_live!(blocking)
        ids = String[j.id for j in blocking]
        still = unique(vcat(failed, _teardown_still_alive(st0, ids)))
        if !isempty(still)
            _print_live_jobs(still; lead = "  teardown refused: job still alive:")
            return 1
        end
        _teardown_mark_cancelled!(st0, ids)
    end
    return _teardown_remove!(;
        home = home,
        bindir = bindir,
        config = config,
        store = st0,
        existing = existing,
        apply = apply,
        io = io,
    )
end

function teardown_main(args::Vector{String})::Cint
    home = homedir()
    bindir = nothing
    config = nothing
    confirm_paths = String[]
    saw_yes = false
    apply = true
    stop_jobs = false
    i = 1
    while i <= length(args)
        a = args[i]
        if a in ("-h", "--help")
            print_teardown_usage()
            return 0
        elseif a in ("-y", "--yes")
            saw_yes = true
            i += 1
        elseif a == "--stop-jobs"
            stop_jobs = true
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
    # `_main` may already have applied the default config `[env]`.
    _drop_config_env!()
    bd = bindir === nothing ? default_bindir(; home = home) : String(bindir)
    cfg = _teardown_config_file(; home = home, config = config)
    apply_config_env!(load_config(; path = cfg))
    return teardown(;
        home = home,
        bindir = bd,
        config = cfg,
        confirm_paths = confirm_paths,
        apply = apply,
        stop_jobs = stop_jobs,
        yes_attempt = saw_yes || teardown_yes(),
    )
end
