# Local paths shared by `serve`, `setup`, and `enable`.
#
# Not CLI parsing. `queue_data_dir` lives in `config.jl`.
function sh_single_quote(s::AbstractString)::String
    return string('\'', replace(String(s), "'" => "'\\''"), '\'')
end

"""Prefix such that `startswith(child, prefix)` means `child` is inside `root`.

`/` (and posix `""` after stripping a trailing slash) uses `"/"` so we do not
build `"//"`.
"""
function path_inside_prefix(root::AbstractString)::String
    r = string(root)::String
    (isempty(r) || r == "/") && return "/"
    return r * "/"
end

"""The Julia the serve unit (`enable` / autoserve `serve`) runs.

Delegates to DistSSHKit `resolve_controller_julia()` — the same controller-Julia
detection the detached child uses — so the OS unit and the Kit child agree on the
binary. Falls back to `julia_cmd` if Kit's usability check throws (never in a
process that is itself running Julia).
"""
function default_julia_bin()::String
    try
        return canonical_local_path(resolve_controller_julia())
    catch e
        e isa ArgumentError || rethrow()
        exe = Base.julia_cmd().exec[1]
        isfile(exe) && return canonical_local_path(exe)
        w = Sys.which("julia")
        w !== nothing && isfile(w) && return canonical_local_path(w)
        return joinpath(Sys.BINDIR, Sys.iswindows() ? "julia.exe" : "julia")
    end
end

"""`~/.distsshqueue/env`, a Queue environment independent of any dev checkout.

Not created automatically (that would mean running `Pkg` network operations as a
side effect of `setup`); one-time `Pkg.add` is in the Prepare tutorial.
"""
function default_queue_env_dir(; home::AbstractString = homedir())::String
    return joinpath(home, ".distsshqueue", "env")
end

"""The `--queue-env` `enable` bakes in by default: the dedicated env dir if
it has been set up, else the directory of the Manifest for the active project.

A workspace member uses that workspace root (`Base.active_manifest`), not
the member directory. The Kit job `--project` stays the member.
"""
function default_queue_env(; dedicated::AbstractString = default_queue_env_dir())::String
    isfile(joinpath(dedicated, "Project.toml")) && return dedicated
    proj = Base.active_project()
    proj === nothing && throw(ArgumentError("service: no active project; pass --queue-env"))
    return resolve_pkg_env(dirname(proj)).env_dir
end

"""`-m` package for a queue env on this machine.

Users add DistSSHKit. Main loads only a direct `[deps]` name, so a
transitive DistSSHQueue cannot be `-m`'d or `using`'d. DistSSHKit when
that name is in `[deps]`, otherwise DistSSHQueue. A missing or unreadable
Project.toml is DistSSHQueue. A `qhost:` hop does not use this: the env
path is expanded on the queue host (`remote_main_expr`).
"""
function m_package(project::AbstractString)::String
    path = joinpath(String(project), "Project.toml")
    isfile(path) || return "DistSSHQueue"
    raw = try
        TOML.parsefile(path)
    catch
        return "DistSSHQueue"
    end
    raw isa AbstractDict || return "DistSSHQueue"
    deps = get(raw, "deps", nothing)
    deps isa AbstractDict && haskey(deps, "DistSSHKit") && return "DistSSHKit"
    return "DistSSHQueue"
end

const _REMOTE_DOLLAR = '$'

"""`-e` prelude that sets `pkg` from the active project's direct `[deps]`.

The queue host expands `--project=`. The client must not read that
Project.toml (`~/.distsshqueue/env` is not a path here).
"""
function remote_pkg_prelude()::String
    return join(
        (
            "import TOML",
            "proj = Base.active_project()",
            "pkg = \"DistSSHQueue\"",
            "if proj !== nothing",
            "raw = try; TOML.parsefile(proj); catch; nothing; end",
            "if raw isa AbstractDict",
            "deps = get(raw, \"deps\", nothing)",
            "if deps isa AbstractDict && haskey(deps, \"DistSSHKit\")",
            "pkg = \"DistSSHKit\"",
            "end",
            "end",
            "end",
        ),
        "; ",
    )
end

"""Remote `-e` body: load the active project's package and call `main`."""
function remote_main_expr(args::AbstractVector{<:AbstractString})::String
    args_lit = repr(String[String(a) for a in args])
    d = _REMOTE_DOLLAR
    return remote_pkg_prelude() *
        "; @eval using $(d)(Symbol(pkg)); exit(Int(getfield(Main, Symbol(pkg)).main($args_lit)))"
end

"""Remote `-e` body that prints `fetch_source` for `id`.

`fetch_source` is not exported. After `using DistSSHKit` the name
`DistSSHQueue` is not in Main, so that branch goes through the loaded module.
The package is chosen on the queue host, not from a client-side path.
"""
function fetch_source_expr(id::AbstractString)::String
    id_lit = repr(String(id))
    d = _REMOTE_DOLLAR
    return remote_pkg_prelude() *
        "; @eval using $(d)(Symbol(pkg)); " *
        "call = pkg == \"DistSSHKit\" ? DistSSHKit.DistSSHQueue.fetch_source : DistSSHQueue.fetch_source; " *
        "print(call($id_lit))"
end
