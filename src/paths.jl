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

function _xml_unescape(s::AbstractString)::String
    t = replace(String(s), "&quot;" => "\"")
    t = replace(t, "&gt;" => ">")
    t = replace(t, "&lt;" => "<")
    return replace(t, "&amp;" => "&")
end

"""`<string>` values inside the plist `ProgramArguments` array."""
function _plist_program_args(text::AbstractString)::Vector{String}
    s = String(text)
    key = findfirst("<key>ProgramArguments</key>", s)
    key === nothing && return String[]
    rest = s[nextind(s, last(key)):end]
    stop = findfirst("</array>", rest)
    stop === nothing && return String[]
    block = rest[1:prevind(rest, first(stop))]
    out = String[]
    for m in eachmatch(r"<string>(.*?)</string>"s, block)
        cap = m.captures[1]
        cap isa AbstractString || continue
        push!(out, _xml_unescape(cap))
    end
    return out
end

"""Split a systemd `ExecStart=` body. Single quotes match the unit writer, including `'\\''`."""
function _split_posix_words(s::AbstractString)::Vector{String}
    out = String[]
    buf = IOBuffer()
    in_quote = false
    started = false
    i = firstindex(s)
    while i <= lastindex(s)
        c = s[i]
        if in_quote
            if c == '\''
                in_quote = false
            else
                print(buf, c)
                started = true
            end
            i = nextind(s, i)
        elseif c == '\\' && i < lastindex(s) && s[nextind(s, i)] == '\''
            print(buf, '\'')
            started = true
            i = nextind(s, nextind(s, i))
        elseif c == '\''
            in_quote = true
            started = true
            i = nextind(s, i)
        elseif c == ' ' || c == '\t'
            if started
                push!(out, String(take!(buf)))
                started = false
            end
            i = nextind(s, i)
        else
            print(buf, c)
            started = true
            i = nextind(s, i)
        end
    end
    started && push!(out, String(take!(buf)))
    return out
end

function _serve_from_args(args::AbstractVector{<:AbstractString})
    isempty(args) && return nothing
    proj = nothing
    for a in args
        startswith(a, "--project=") || continue
        proj = chopprefix(String(a), "--project=")
        break
    end
    (proj === nothing || isempty(proj)) && return nothing
    return (julia = String(args[1]), project = String(proj))
end

"""Julia and `--project=` from an `enable` unit body, or `nothing`."""
function serve_command_from_unit(text::AbstractString)
    s = String(text)
    if occursin("<key>ProgramArguments</key>", s)
        return _serve_from_args(_plist_program_args(s))
    end
    for line in eachsplit(s, '\n')
        row = strip(String(line))
        startswith(row, "ExecStart=") || continue
        return _serve_from_args(_split_posix_words(chopprefix(row, "ExecStart=")))
    end
    return nothing
end

"""The `enable` unit's Julia and queue env, when that file exists and parses.

Autoserve uses this so a later `submit` starts the same process `enable` registered.
No unit file, or a file without `--project=`, is `nothing` (caller uses the defaults).
"""
function enabled_serve_command(; home::AbstractString = homedir())
    path = _enable_unit_path(; home = home)
    path === nothing && return nothing
    text = try
        read(path, String)
    catch
        return nothing
    end
    return serve_command_from_unit(text)
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
