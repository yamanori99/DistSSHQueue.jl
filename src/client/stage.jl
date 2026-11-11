# Client `qhost:` submit: ship the job tree onto the queue host.
#
# Omit `qhost:` is unchanged (cwd / `DISTRIBUTED_PROJECT_ROOT` on this box).
# Kit still copies queue host → workers with `setup!(:ship_tree)`. Staging
# uses DistSSHRun `pack_ship_tree` and `pack_shipment` (same send rules as
# `setup --rsync` / `:ship_tree`). Out-of-tree scripts land under
# `_distsshrun_external/`. Pack runs before `ssh mkdir`, so a local error
# leaves no empty stage directory. Stderr gets `ship-tree → HOST:path` when
# the transfer starts (`DISTSSH_QUIET` hides it). Fetch still rsyncs.
# `DISTSSHQUEUE_NO_STAGE=1` skips (tests with a fake `ssh`).
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
            code = shell_status(proc)
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
    if _test_doubles_on() && !isempty(strip(get(ENV, "DISTSSH_TEST_SSH", "")))
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

function rsync_progress_on(args::Vector{String} = String[])::Bool
    _queue_env_on("DISTSSH_QUIET") && return false
    _queue_env_on("DISTSSH_PROGRESS") && return true
    return any(isequal("--progress"), args)
end

"""One stderr line when a `qhost:` ship-tree starts. `DISTSSH_QUIET` skips it."""
function print_ship_tree_start(
        host::AbstractString,
        remote_path::AbstractString;
        io::IO = stderr,
    )
    _queue_env_on("DISTSSH_QUIET") && return nothing
    println(io, "ship-tree → $(host):$(_q_short(remote_path))")
    return nothing
end

"""One stderr line when a `qhost:` rsync pull starts. `DISTSSH_QUIET` skips it."""
function print_rsync_start(
        host::AbstractString,
        remote_path::AbstractString;
        pulling::Bool = false,
        io::IO = stderr,
    )
    _queue_env_on("DISTSSH_QUIET") && return nothing
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

const _STAGE_EXTERNAL_DIR = "_distsshrun_external"

function _remote_stage_external_path(remote_root::AbstractString, script::AbstractString)::String
    return string(remote_root, "/", _STAGE_EXTERNAL_DIR, "/", basename(String(script)))
end

function _remote_julia_for_ship(rjulia::AbstractString)::Union{Nothing, String}
    spec = strip(String(rjulia))
    (isempty(spec) || spec == "auto") && return nothing
    return spec
end

"""Stdout/stderr lines from `pack_ship_tree` warnings (Run `print_warn`)."""
function _capture_pack_warnings(io::IO)::Vector{String}
    seekstart(io)
    out = String[]
    for line in eachline(io; keep = true)
        s = strip(String(line))
        isempty(s) && continue
        occursin("will not be shipped", s) || occursin("Warning:", s) || continue
        push!(out, s)
    end
    return out
end

function _pack_ship_tree_with_warnings(
        project::AbstractString;
        extra_files::Vector{String} = String[],
    )
    return mktemp() do _, cap_io
        pack = redirect_stdout(cap_io) do
            redirect_stderr(cap_io) do
                return DistSSHRun.pack_ship_tree(String(project); extra_files = extra_files)
            end
        end
        flush(cap_io)
        warnings = _capture_pack_warnings(cap_io)
        return pack, warnings
    end
end

function _ship_stage_error(host::AbstractString, result)::String
    lines = String[]
    for row in result.hosts
        ok = hasproperty(row, :ok) ? Bool(getproperty(row, :ok)) : true
        ok && continue
        h = hasproperty(row, :host) ? String(getproperty(row, :host)) : String(host)
        msg = if hasproperty(row, :message)
            String(getproperty(row, :message))
        else
            "ship failed"
        end
        push!(lines, string(h, ": ", msg))
    end
    isempty(lines) && push!(lines, "qhost submit: ship-tree failed on $(host)")
    return join(lines, "; ")
end

"""
Pack and verified-ship `local_root` to `remote_root` on `host`.

Returns `(content_tree_hash, pack_warnings)`. The pack directory is removed
before return or throw.
"""
function ship_tree_to_qhost!(
        host::AbstractString,
        local_root::AbstractString,
        remote_root::AbstractString,
        extra_files::Vector{String},
        rjulia::AbstractString,
        transfer_id::AbstractString;
        write_record::Union{Nothing, Bool} = nothing,
    )::Tuple{String, Vector{String}}
    src = canonical_local_path(local_root)
    isdir(src) || throw(ArgumentError("qhost submit: job project is not a directory: $(repr(src))"))
    extras = _stage_extra_paths(extra_files)
    pack, warnings = _pack_ship_tree_with_warnings(src; extra_files = extras)
    record = if write_record === nothing
        !(_test_doubles_on() && !isempty(strip(get(ENV, "DISTSSH_TEST_SSH", ""))))
    else
        write_record
    end
    try
        _ssh_mkdir!(host, remote_root)
        print_ship_tree_start(host, remote_root)
        result = DistSSHRun.pack_shipment(
            pack, [String(host)], remote_root;
            julia = _remote_julia_for_ship(rjulia),
            transfer_id = String(transfer_id),
            write_record = record,
        )
        result.ok || throw(ArgumentError(_ship_stage_error(host, result)))
        return String(result.content_tree_hash), warnings
    finally
        isdir(pack.directory) && rm(pack.directory; force = true, recursive = true)
    end
end

const _RSYNC_SHELL_SPECIAL = r"[[:space:]'\"\\$`;&|<>()*?\[]"
const _RSYNC_BRACE_EXPAND = r"\{[^}]*(,|\.\.)[^}]*\}"
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
and the globs `*`, `?`, `[` are refused. `#`, `!`, and `{x}` without a comma
or `..` stay: `#` does not start a comment in a word, and history expansion is
off. `{a,b}` and `{a..b}` are refused because the remote shell expands them.
rsync 3.2.4 protects arguments without
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
    s = String(path)
    occursin(_RSYNC_SHELL_SPECIAL, s) || occursin(_RSYNC_BRACE_EXPAND, s) || return nothing
    throw(
        ArgumentError(
            "rsync $(version) does not protect arguments, and the remote shell would change this path: $(path)",
        )
    )
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

"""Git snapshot of `project`, or an empty dict when git is missing or this is not a work tree.

The record is `DistSSHRun.git_source_snapshot`. `captured` is `submit:` plus this
hostname, not Run's `"run"`. `dirty` is `"true"` or `"false"`. `untracked` is a
decimal string.
"""
function queue_source_env(project::AbstractString)::Dict{String, String}
    snap = DistSSHRun.git_source_snapshot(String(project))
    snap === nothing && return Dict{String, String}()
    return Dict{String, String}(
        SOURCE_COMMIT_ENV => String(snap["commit"]),
        SOURCE_DIRTY_ENV => snap["dirty"] ? "true" : "false",
        SOURCE_DIFF_SHA256_ENV => String(snap["diff_sha256"]),
        SOURCE_CAPTURED_ENV => "submit:" * gethostname(),
        SOURCE_UNTRACKED_ENV => string(snap["untracked"]),
    )
end

"""Ship the Manifest directory to `~/.distsshqueue/stage/<uuid>` on `host`.

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
    source_env = queue_source_env(local_proj)
    key = new_job_id()
    remote_root = remote_stage_root(key; home = queue_host_homedir(host, rjulia))
    layout = stage_env_and_project(local_proj, remote_root)
    extras = String[]
    if !path_under_project(local_script, layout.env_dir)
        push!(extras, local_script)
    end
    tree_hash, pack_warnings = ship_tree_to_qhost!(
        host, layout.env_dir, remote_root, extras, rjulia, key,
    )
    staged = rewrite_payload_paths(payload, layout.env_dir, remote_root)
    if !isempty(extras)
        want = _remote_stage_external_path(remote_root, local_script)
        staged = String[a == local_script || a == basename(local_script) ? want : a for a in staged]
        # relative extra: rewrite_one_path left it; replace parsed token
        raw = String(parsed.script_path)
        staged = String[a == raw ? want : a for a in staged]
    end
    env = Dict{String, String}(
        "DISTRIBUTED_PROJECT_ROOT" => layout.remote_proj,
        JOB_ID_ENV => key,
        STAGE_CONTENT_TREE_HASH_ENV => tree_hash,
    )
    merge!(env, source_env)
    if !isempty(pack_warnings)
        env[STAGE_PACK_WARNINGS_ENV] = join(pack_warnings, '\n')
    end
    return staged, env
end
