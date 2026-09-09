"""Client `qhost:` submit: rsync the job tree onto the queue host.

Omit `qhost:` is unchanged (cwd / `DISTRIBUTED_PROJECT_ROOT` on this box).
Kit still copies queue host → workers. Same excludes as Kit `setup --rsync`
(`.git/` / `.distsshkit/` / `.distsshqueue/` plus `.gitignore`).
`DISTSSHQUEUE_NO_STAGE=1` skips (tests with a fake `ssh`).
"""

const NO_STAGE_ENV = "DISTSSHQUEUE_NO_STAGE"

"""Queue-host dest for one client submit. Unique per hop.

`home` is that box's `homedir()` under the same Julia as `qhost:` (`--remote-julia`
wrapper included). Default `~` is for docs/tests without SSH.
"""
function remote_stage_root(id::AbstractString; home::AbstractString="~")::String
    h = rstrip(String(home), '/')
    return string(h, "/.distsshqueue/stage/", id)
end

"""Captured `ssh` + remote Julia `-e` stdout (not `maybe_remote` / `main`).

`queue_env === nothing`: `--startup-file=no` only (homedir). Else hop `--project=`.
"""
function hop_print(
    host::AbstractString,
    rjulia::AbstractString,
    expr::AbstractString;
    queue_env::Union{Nothing,AbstractString}=nothing,
)::String
    spec = strip(String(rjulia))
    auto = isempty(spec) || spec == "auto"
    prefix = queue_env === nothing ? String["--startup-file=no"] : hop_julia_prefix(queue_env)
    argv = vcat(prefix, String["-e", String(expr)])
    mktemp() do path, io
        redirect_stdout(io) do
            proc = DistSSHKit.run_on_host(
                host,
                argv;
                julia=auto ? nothing : spec,
                detect=auto,
                tty=false,
            )
            code = Int(something(proc.exitcode, 1))
            if code == 127
                throw(ArgumentError(
                    "no Julia on $(host) (ssh PATH is often empty; Kit tries juliaup then Homebrew). " *
                    "Pass --remote-julia PATH or set JULIA_DISTRIBUTED_EXE, like Kit --julia.",
                ))
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

"""Stable dir name for one client job tree (canonical path). Same tree re-submits here.

Not a job UUID: two trees that Kit would pin to the same worker path must stay
one queue-host project, or `submit` refuses the second.
"""
function client_stage_key(local_proj::AbstractString)::String
    p = DistSSHKit.canonical_local_path(local_proj)
    h = 0xcbf29ce484222325
    for b in codeunits(p)
        h = (h ⊻ UInt64(b)) * 0x100000001b3
    end
    return string(h; base=16)
end

function staging_enabled()::Bool
    get(ENV, NO_STAGE_ENV, "") == "1" && return false
    isempty(strip(get(ENV, "DISTSSHKIT_TEST_SSH", ""))) || return false
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
    return "ssh " * join(DistSSHKit.ssh_opts(), " ")
end

function _ssh_mkdir!(host::AbstractString, remote_dir::AbstractString)
    inner = string("mkdir -p ", sh_single_quote(remote_dir))
    cmd = Cmd(vcat(["ssh"], DistSSHKit.ssh_opts(), [String(host), inner]))
    run(pipeline(cmd; stderr=stderr))
    return nothing
end

"""rsync flags for laptop → queue-host stage (Kit `setup --rsync` plus `.distsshqueue/`)."""
function stage_rsync_push_opts(transport::AbstractString)::Vector{String}
    return String[
        "-az",
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
end

function rsync_to_qhost!(
    host::AbstractString,
    local_root::AbstractString,
    remote_root::AbstractString,
    extra_files::Vector{String},
)
    src = DistSSHKit.canonical_local_path(local_root)
    isdir(src) || throw(ArgumentError("qhost submit: job project is not a directory: $(repr(src))"))
    _ssh_mkdir!(host, remote_root)
    dest = string(host, ":", remote_root, "/")
    rsync = _rsync_bin()
    transport = _ssh_transport()
    run(
        pipeline(
            Cmd(vcat(rsync, stage_rsync_push_opts(transport), String[src * "/", dest]));
            stdout=stderr,
            stderr=stderr,
        ),
    )
    for f in extra_files
        p = DistSSHKit.canonical_local_path(f)
        isfile(p) || throw(ArgumentError("qhost submit: extra file missing: $(repr(p))"))
        run(
            pipeline(
                Cmd(
                    vcat(
                        rsync,
                        String["-az", "-e", transport, p, string(host, ":", remote_root, "/", basename(p))],
                    ),
                );
                stdout=stderr,
                stderr=stderr,
            ),
        )
    end
    return nothing
end

"""Pull one remote directory into `local_dest` (`--delete` stays inside that leaf)."""
function rsync_from_qhost!(
    host::AbstractString,
    remote_abs::AbstractString,
    local_dest::AbstractString,
)
    remote = rstrip(replace(String(remote_abs), '\\' => '/'), '/')
    dest = DistSSHKit.canonical_local_path(local_dest)
    mkpath(dest)
    src = string(host, ":", remote, "/")
    run(
        pipeline(
            Cmd(
                vcat(
                    _rsync_bin(),
                    String["-az", "--delete", "-e", _ssh_transport(), src, dest * "/"],
                ),
            );
            stderr=stderr,
        ),
    )
    return nothing
end

function path_under_project(path::AbstractString, proj::AbstractString)::Bool
    p = DistSSHKit.canonical_local_path(path)
    r = DistSSHKit.canonical_local_path(proj)
    return p == r || startswith(p, path_inside_prefix(r))
end

"""Rsync cwd / `DISTRIBUTED_PROJECT_ROOT` to `~/.distsshqueue/stage/<id>` on `host`."""
function stage_job_tree!(
    host::AbstractString,
    rjulia::AbstractString,
    sub::AbstractString,
    payload::Vector{String},
)::Tuple{Vector{String},Dict{String,String}}
    kit, kitargs = kit_verb_and_args(sub, payload)
    parsed = kit_parse_args(kit_kind_from_cli(kit), kitargs)
    parsed.help && return (String[String(a) for a in payload], Dict{String,String}())
    parsed.show_version && return (String[String(a) for a in payload], Dict{String,String}())
    local_script = script_arg(parsed.script_path, kit)
    local_proj = job_project()
    key = client_stage_key(local_proj)
    remote_root = remote_stage_root(key; home=queue_host_homedir(host, rjulia))
    extras = String[]
    if !path_under_project(local_script, local_proj)
        push!(extras, local_script)
    end
    rsync_to_qhost!(host, local_proj, remote_root, extras)
    staged = rewrite_payload_paths(payload, local_proj, remote_root)
    if !isempty(extras)
        want = string(remote_root, "/", basename(local_script))
        staged = String[a == local_script || a == basename(local_script) ? want : a for a in staged]
        # relative extra: rewrite_one_path left it; replace parsed token
        raw = String(parsed.script_path)
        staged = String[a == raw ? want : a for a in staged]
    end
    env = Dict{String,String}("DISTRIBUTED_PROJECT_ROOT" => remote_root)
    return staged, env
end
