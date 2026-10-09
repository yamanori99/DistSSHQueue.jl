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
