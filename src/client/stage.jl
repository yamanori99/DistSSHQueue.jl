# Client `qhost:` submit: rsync the job tree onto the queue host.
#
# Omit `qhost:` is unchanged (cwd / `DISTRIBUTED_PROJECT_ROOT` on this box).
# Kit still copies queue host → workers. Inside a git work tree the file list
# is DistSSHRun's `rsync_send_list` (the same list as `setup --rsync`). Outside
# one, rsync keeps its per-directory `.gitignore` filter. `.distsshqueue/`
# stays off the queue host either way. The send list and extra files are
# checked before `ssh mkdir`, so a local error leaves no empty stage directory.
# Stderr gets `rsync → HOST:path` when the copy starts (`DISTSSHKIT_QUIET`
# hides it). `DISTSSHQUEUE_NO_STAGE=1` skips (tests with a fake `ssh`).
const NO_STAGE_ENV = "DISTSSHQUEUE_NO_STAGE"

"""Queue-host dest for one client submit. Unique per job UUID.

`home` is that box's `homedir()` under the same Julia as `qhost:` (`--remote-julia`
wrapper included). Default `~` is for docs/tests without SSH.
"""
function remote_stage_root(id::AbstractString; home::AbstractString = "~")::String
    h = rstrip(String(home), '/')
    return string(h, "/.distsshqueue/stage/", id)
end

const _STAGE_UUID = r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"

function _regex_literal(s::AbstractString)::String
    return replace(String(s), r"([.^$*+?()\[\]{}|\\])" => s"\\\1")
end

"""`<home>/.distsshqueue/stage/<uuid>`, or `nothing` when `id` is not that shape."""
function orphan_stage_path(id::AbstractString; home::AbstractString = homedir())::Union{Nothing, String}
    sid = String(id)
    occursin(_STAGE_UUID, sid) || return nothing
    root = abspath(String(home))
    path = abspath(joinpath(root, ".distsshqueue", "stage", sid))
    posix_root = replace(root, '\\' => '/')
    posix = replace(path, '\\' => '/')
    pat = Regex("^" * _regex_literal(posix_root) * "/\\.distsshqueue/stage/" * _regex_literal(sid) * "\$")
    occursin(pat, posix) || return nothing
    return path
end

"""Remove `stage/<id>` only when `submit!` did not write that job row."""
function drop_unwritten_stage!(id::AbstractString, store::AbstractString; home::AbstractString = homedir())
    sid = strip(String(id))
    isempty(sid) && return nothing
    written = try
        any(j -> j.id == sid, read_jobs(store))
    catch
        return nothing
    end
    written && return nothing
    path = orphan_stage_path(sid; home = home)
    path === nothing && return nothing
    isdir(path) || return nothing
    rm(path; force = true, recursive = true)
    return nothing
end

"""Captured `ssh` + remote Julia `-e` stdout (not `maybe_remote` / `main`).

`queue_env === nothing`: `--startup-file=no` only (homedir). Else hop `--project=`.
"""
function hop_print(
        host::AbstractString,
        rjulia::AbstractString,
        expr::AbstractString;
        queue_env::Union{Nothing, AbstractString} = nothing,
    )::String
    spec = strip(String(rjulia))
    auto = isempty(spec) || spec == "auto"
    prefix = queue_env === nothing ? String["--startup-file=no"] : hop_julia_prefix(queue_env)
    argv = vcat(prefix, String["-e", String(expr)])
    return mktemp() do path, io
        redirect_stdout(io) do
            proc = run_on_host(
                host,
                argv;
                julia = auto ? nothing : spec,
                detect = auto,
                tty = false,
            )
            code = Int(something(proc.exitcode, 1))
            if code == 127
                throw(
                    ArgumentError(
                        "no Julia on $(host) (ssh PATH is often empty; Kit tries juliaup then Homebrew). " *
                            "Pass --remote-julia PATH or set JULIA_DISTRIBUTED_EXE, like Kit --julia.",
                    )
                )
            end
            code == 0 || throw(ArgumentError("qhost hop failed on $(host) (exit $(code))"))
        end
        flush(io)
        out = strip(read(path, String))
        isempty(out) && throw(ArgumentError("qhost hop: empty stdout on $(host)"))
        return out
    end
end

"""Home the hop Julia sees (`--remote-julia` wrapper ENV), not only SSH login `\$HOME`."""
function queue_host_homedir(host::AbstractString, rjulia::AbstractString)::String
    return hop_print(host, rjulia, "print(homedir())")
end

function staging_enabled()::Bool
    get(ENV, NO_STAGE_ENV, "") == "1" && return false
    if _test_doubles_on() && !isempty(strip(get(ENV, "DISTSSHKIT_TEST_SSH", "")))
        return false
    end
    return true
end

"""`qhost:` `submit` (not help). Ticket even when staging is off."""
function should_submit_ticket(sub::AbstractString, payload::Vector{String})::Bool
    sub == "submit" || return false
    any(a -> a in ("-h", "--help", "-v", "--version", "-V"), payload) && return false
    isempty(payload) && return false
    payload[1] in ("-h", "--help") && return false
    return true
end

function should_stage(sub::AbstractString, payload::Vector{String})::Bool
    staging_enabled() || return false
    return should_submit_ticket(sub, payload)
end

function kit_verb_and_args(sub::AbstractString, payload::Vector{String})
    if sub == "submit"
        isempty(payload) && throw(ArgumentError("submit: need `go`, `ride`, or `drive`"))
        kit = String(payload[1])
        kit_kind_from_cli(kit)
        return kit, String[String(a) for a in payload[2:end]]
    end
    return String(sub), String[String(a) for a in payload]
end

function looks_like_host_token(s::AbstractString)::Bool
    a = String(s)
    occursin(':', a) || return false
    startswith(a, "/") && return false
    startswith(a, "~") && return false
    startswith(a, ".") && return false
    return true
end

"""Map a client path under `local_proj` to `remote_root/...` (POSIX). Else unchanged."""
function rewrite_one_path(arg::AbstractString, local_proj::AbstractString, remote_root::AbstractString)::String
    a = String(arg)
    startswith(a, "-") && return a
    a in ("go", "drive", "ride", "submit") && return a
    looks_like_host_token(a) && return a
    lp = abspath(local_proj)
    in_proj = joinpath(lp, a)
    cand = if isabspath(a) || startswith(a, ".") || occursin('/', a) || occursin('\\', a)
        abspath(a)
    elseif isfile(in_proj) || isdir(in_proj)
        in_proj
    elseif endswith(a, ".jl")
        abspath(a)
    else
        return a
    end
    (cand == lp || startswith(cand, lp * "/")) || return a
    rel = relpath(cand, lp)
    rel == "." && return String(remote_root)
    posix = replace(rel, '\\' => '/')
    return string(remote_root, "/", posix)
end

function rewrite_payload_paths(
        payload::Vector{String},
        local_proj::AbstractString,
        remote_root::AbstractString,
    )::Vector{String}
    out = String[String(a) for a in payload]
    i = 1
    while i <= length(out)
        if out[i] in ("--output-dir", "--project") && i < length(out)
            out[i + 1] = rewrite_one_path(out[i + 1], local_proj, remote_root)
            i += 2
            continue
        end
        out[i] = rewrite_one_path(out[i], local_proj, remote_root)
        i += 1
    end
    return out
end

function _rsync_bin()::Vector{String}
    w = Sys.which("rsync")
    w === nothing && throw(ArgumentError("qhost submit: rsync not found on PATH (client)"))
    return String[w]
end

function _ssh_transport()::String
    return join(Base.shell_escape.(["ssh"; ssh_opts()]), " ")
end

function _ssh_mkdir!(host::AbstractString, remote_dir::AbstractString)
    inner = string("mkdir -p ", sh_single_quote(remote_dir))
    cmd = Cmd(vcat(["ssh"], ssh_opts(), _ssh_host_args(String(host), inner)))
    run(pipeline(cmd; stderr = stderr))
    return nothing
end

"""True when `rel` is `.distsshqueue` or a file under it."""
function _stage_rel_is_queue(rel::AbstractString)::Bool
    r = replace(String(rel), '\\' => '/')
    return ".distsshqueue" in split(r, '/')
end

"""
Send list for `local_root`'s Manifest directory.

`nothing` outside a git work tree: the caller keeps rsync's dir-merge filter.
Inside one, the same paths as `setup --rsync`, without `.distsshqueue/`.
An empty list throws `ArgumentError`.
"""
function stage_send_list(local_root::AbstractString)::Union{Nothing, Vector{String}}
    env = resolve_pkg_env(local_root)
    listed = DistSSHRun.rsync_send_list(env.env_dir, env; warn = true)
    listed === nothing && return nothing
    filtered = String[String(rel) for rel in listed if !_stage_rel_is_queue(rel)]
    isempty(filtered) && throw(
        ArgumentError(
            "qhost submit: nothing to send from $(env.env_dir) after dropping .distsshqueue",
        ),
    )
    return filtered
end

"""rsync flags for a non-git stage (dir-merge `.gitignore`, plus `.distsshqueue/`)."""
function stage_rsync_push_opts(transport::AbstractString; progress::Bool = false)::Vector{String}
    opts = String["-az"]
    progress && push!(opts, "--info=progress2")
    append!(
        opts, String[
            "--delete",
            "-e",
            String(transport),
            "--exclude",
            ".git/",
            "--exclude",
            ".distsshkit/",
            "--exclude",
            ".distsshqueue/",
            "--filter",
            ":- .gitignore",
        ]
    )
    return opts
end

"""rsync flags for a git send list. `.distsshqueue/` is still excluded."""
function stage_rsync_files_from_opts(transport::AbstractString; progress::Bool = false)::Vector{String}
    opts = String["-az"]
    progress && push!(opts, "--info=progress2")
    append!(
        opts, String[
            "-e",
            String(transport),
            "--exclude",
            ".git/",
            "--exclude",
            ".distsshkit/",
            "--exclude",
            ".distsshqueue/",
        ]
    )
    return opts
end

function _stage_rsync_files_from!(
        rsync::Vector{String},
        opts::Vector{String},
        src::AbstractString,
        dest::AbstractString,
        files::Vector{String},
    )
    mktemp() do path, io
        for rel in files
            entry = !isempty(rel) && first(rel) in ('#', ';') ? string("./", rel) : rel
            write(io, entry, '\0')
        end
        close(io)
        cmd = Cmd(vcat(rsync, opts, String["--from0", "--files-from=$path", src * "/", dest]))
        run(
            pipeline(cmd; stdout = stderr, stderr = stderr),
        )
    end
    return nothing
end

function rsync_progress_on(args::Vector{String} = String[])::Bool
    _queue_env_on("DISTSSHKIT_QUIET") && return false
    _queue_env_on("DISTSSHKIT_PROGRESS") && return true
    return any(isequal("--progress"), args)
end

"""One stderr line when a `qhost:` rsync starts. `DISTSSHKIT_QUIET` skips it."""
function print_rsync_start(
        host::AbstractString,
        remote_path::AbstractString;
        pulling::Bool = false,
        io::IO = stderr,
    )
    _queue_env_on("DISTSSHKIT_QUIET") && return nothing
    arrow = pulling ? "←" : "→"
    println(io, "rsync $(arrow) $(host):$(_q_short(remote_path))")
    return nothing
end

function _stage_extra_paths(extra_files)::Vector{String}
    out = String[]
    for f in extra_files
        p = canonical_local_path(f)
        isfile(p) || throw(ArgumentError("qhost submit: extra file missing: $(repr(p))"))
        push!(out, p)
    end
    return out
end

const _RSYNC_SHELL_SPECIAL = r"[[:space:]'\"\\$`;&|<>()*?\[]"
const _RSYNC_VER = Ref{Union{Nothing, VersionNumber}}(nothing)
const _RSYNC_VER_READY = Ref(false)

function _read_local_rsync_version()::Union{Nothing, VersionNumber}
    text = try
        read(Cmd(vcat(_rsync_bin(), "--version")), String)
    catch
        return nothing
    end
    m = match(r"version\s+v?([0-9]+\.[0-9]+\.[0-9]+)", text)
    m === nothing && return nothing
    cap = m.captures[1]
    cap isa AbstractString || return nothing
    return tryparse(VersionNumber, cap)
end

"""Local `rsync --version`, cached. `nothing` when it cannot be read."""
function local_rsync_version()::Union{Nothing, VersionNumber}
    _RSYNC_VER_READY[] && return _RSYNC_VER[]
    _RSYNC_VER[] = _read_local_rsync_version()
    _RSYNC_VER_READY[] = true
    return _RSYNC_VER[]
end

"""Stop when this rsync is older than 3.2.4 and the remote `sh -c` would change `path`.

Whitespace, quotes, `\\`, `\$`, a backtick, `;`, `&`, `|`, `<`, `>`, `(`, `)`,
and the globs `*`, `?`, `[` are refused. `#`, `!`, `{`, and `}` in a word stay:
`#` does not start a comment there, history expansion is off, and `{x}` without
a comma or `..` is not expanded. rsync 3.2.4 protects arguments without
`--protect-args`. Older rsync, including macOS 2.6.9, does not.
`--protect-args` is not added: rsync before 3.0 does not know it, and the
remote rsync must be 3.0 or newer too.
"""
function _refuse_unprotected_rsync_path!(
        path::AbstractString;
        version::Union{Nothing, VersionNumber} = local_rsync_version(),
    )
    version === nothing && return nothing
    version >= v"3.2.4" && return nothing
    occursin(_RSYNC_SHELL_SPECIAL, String(path)) || return nothing
    throw(
        ArgumentError(
            "rsync $(version) does not protect arguments, and the remote shell would change this path: $(path)",
        )
    )
end

function rsync_to_qhost!(
        host::AbstractString,
        local_root::AbstractString,
        remote_root::AbstractString,
        extra_files::Vector{String};
        progress::Bool = false,
    )
    src = canonical_local_path(local_root)
    isdir(src) || throw(ArgumentError("qhost submit: job project is not a directory: $(repr(src))"))
    _refuse_unprotected_rsync_path!(remote_root)
    for f in extra_files
        _refuse_unprotected_rsync_path!(string(remote_root, "/", basename(String(f))))
    end
    listed = stage_send_list(src)
    extras = _stage_extra_paths(extra_files)
    _ssh_mkdir!(host, remote_root)
    dest = string(host, ":", remote_root, "/")
    rsync = _rsync_bin()
    transport = _ssh_transport()
    print_rsync_start(host, remote_root)
    if listed === nothing
        run(
            pipeline(
                Cmd(
                    vcat(
                        rsync,
                        stage_rsync_push_opts(transport; progress = progress),
                        String[src * "/", dest],
                    ),
                );
                stdout = stderr,
                stderr = stderr,
            ),
        )
    else
        _stage_rsync_files_from!(
            rsync,
            stage_rsync_files_from_opts(transport; progress = progress),
            src,
            dest,
            listed,
        )
    end
    extra_opts = String["-az"]
    progress && push!(extra_opts, "--info=progress2")
    append!(extra_opts, String["-e", transport])
    for p in extras
        run(
            pipeline(
                Cmd(
                    vcat(
                        rsync,
                        extra_opts,
                        String[p, string(host, ":", remote_root, "/", basename(p))],
                    ),
                );
                stdout = stderr,
                stderr = stderr,
            ),
        )
    end
    return nothing
end

"""Pull one remote directory into `local_dest`. Additive: dest-only files stay."""
function rsync_from_qhost!(
        host::AbstractString,
        remote_abs::AbstractString,
        local_dest::AbstractString;
        progress::Bool = false,
    )
    remote = rstrip(replace(String(remote_abs), '\\' => '/'), '/')
    _refuse_unprotected_rsync_path!(remote)
    dest = canonical_local_path(local_dest)
    mkpath(dest)
    src = string(host, ":", remote, "/")
    print_rsync_start(host, remote; pulling = true)
    flags = String["-az"]
    progress && push!(flags, "--info=progress2")
    append!(flags, String["-e", _ssh_transport()])
    run(
        pipeline(
            Cmd(vcat(_rsync_bin(), flags, String[src, dest * "/"]));
            stdout = stderr,
            stderr = stderr,
        ),
    )
    return nothing
end

"""Pull one remote file into `local_dest` (file path)."""
function rsync_from_qhost_file!(
        host::AbstractString,
        remote_abs::AbstractString,
        local_dest::AbstractString;
        progress::Bool = false,
    )
    remote = rstrip(replace(String(remote_abs), '\\' => '/'), '/')
    _refuse_unprotected_rsync_path!(remote)
    dest = canonical_local_path(local_dest)
    mkpath(dirname(dest))
    src = string(host, ":", remote)
    print_rsync_start(host, remote; pulling = true)
    flags = String["-az"]
    progress && push!(flags, "--info=progress2")
    append!(flags, String["-e", _ssh_transport()])
    run(
        pipeline(
            Cmd(vcat(_rsync_bin(), flags, String[src, dest]));
            stdout = stderr,
            stderr = stderr,
        ),
    )
    return nothing
end

function path_under_project(path::AbstractString, proj::AbstractString)::Bool
    p = canonical_local_path(path)
    r = canonical_local_path(proj)
    return p == r || startswith(p, path_inside_prefix(r))
end

"""Rsync root and the staged Kit project for `local_proj`.

`env_dir` is the Manifest directory (`Base.active_manifest`). `remote_proj`
is that project inside `remote_root` (the same path when there is no parent
Manifest).
"""
function stage_env_and_project(local_proj::AbstractString, remote_root::AbstractString)
    env = resolve_pkg_env(local_proj)
    rel = julia_project_rel(env)
    remote_proj = rel == "." ? String(remote_root) : string(remote_root, "/", replace(rel, '\\' => '/'))
    return (env_dir = env.env_dir, remote_proj = remote_proj)
end

"""Rsync the Manifest directory to `~/.distsshqueue/stage/<uuid>` on `host`.

`DISTRIBUTED_PROJECT_ROOT` is the staged project directory, which is a
subdirectory when the job project is a workspace member.
"""
function stage_job_tree!(
        host::AbstractString,
        rjulia::AbstractString,
        sub::AbstractString,
        payload::Vector{String},
    )::Tuple{Vector{String}, Dict{String, String}}
    kit, kitargs = kit_verb_and_args(sub, payload)
    parsed = kit_parse_args(kit_kind_from_cli(kit), kitargs)
    parsed.help && return (String[String(a) for a in payload], Dict{String, String}())
    parsed.show_version && return (String[String(a) for a in payload], Dict{String, String}())
    local_script = script_arg(parsed.script_path, kit)
    local_proj = job_project()
    key = new_job_id()
    remote_root = remote_stage_root(key; home = queue_host_homedir(host, rjulia))
    layout = stage_env_and_project(local_proj, remote_root)
    extras = String[]
    if !path_under_project(local_script, layout.env_dir)
        push!(extras, local_script)
    end
    rsync_to_qhost!(host, layout.env_dir, remote_root, extras; progress = rsync_progress_on(payload))
    staged = rewrite_payload_paths(payload, layout.env_dir, remote_root)
    if !isempty(extras)
        want = string(remote_root, "/", basename(local_script))
        staged = String[a == local_script || a == basename(local_script) ? want : a for a in staged]
        # relative extra: rewrite_one_path left it; replace parsed token
        raw = String(parsed.script_path)
        staged = String[a == raw ? want : a for a in staged]
    end
    env = Dict{String, String}(
        "DISTRIBUTED_PROJECT_ROOT" => layout.remote_proj,
        JOB_ID_ENV => key,
    )
    return staged, env
end
