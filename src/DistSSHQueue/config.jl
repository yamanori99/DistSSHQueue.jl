"""User config: `~/.distsshqueue/config.toml`. Override: `DISTSSHQUEUE_CONFIG`.

Resolution: CLI / ENV > config.toml > built-in defaults.
`[env]` keys are applied with `get!` so a real ENV value wins.
"""

function default_config_path(; home::AbstractString=homedir())::String
    return joinpath(home, ".distsshqueue", "config.toml")
end

queue_data_dir(; home::AbstractString=homedir())::String = joinpath(home, ".distsshqueue")

function config_path(; home::AbstractString=homedir())::String
    env = strip(get(ENV, "DISTSSHQUEUE_CONFIG", ""))
    return isempty(env) ? default_config_path(; home=home) : env
end

function load_config(; path::Union{Nothing,AbstractString}=nothing)::Dict{String,Any}
    p = path === nothing ? config_path() : String(path)
    isfile(p) || return Dict{String,Any}()
    raw = TOML.parsefile(p)
    return Dict{String,Any}(String(k) => v for (k, v) in raw)
end

"""Apply `cfg["env"]` into `ENV` without overwriting keys already set."""
function apply_config_env!(cfg::AbstractDict)
    env = get(cfg, "env", nothing)
    env isa AbstractDict || return nothing
    for (k, v) in env
        v === nothing && continue
        get!(ENV, String(k), v isa AbstractString ? String(v) : string(v))
    end
    return nothing
end

function config_store_path(cfg::AbstractDict)::Union{Nothing,String}
    st = get(cfg, "store", nothing)
    st isa AbstractString || return nothing
    s = strip(String(st))
    return isempty(s) ? nothing : String(expanduser(s))
end

"""Inventory: Kit SSH name → optional max `:N` (`nothing` = no cap)."""
const HostAllow = Dict{String, Union{Nothing, Int}}

function _positive_n(n::Int, raw::AbstractString)::Int
    n < 1 && throw(ArgumentError("max :N must be a positive integer, not $(repr(raw))"))
    return n
end

"""`parent[:N]` / `child:NAME[:N]` (same as Kit) → `(name, optional max :N)`."""
function parse_host_cap(raw::AbstractString)::Pair{String, Union{Nothing, Int}}
    s = strip(String(raw))
    isempty(s) && throw(ArgumentError("Kit SSH name is empty"))
    p = DistSSHKit.parse_placement_token(s)
    maxn = p.n === nothing ? nothing : _positive_n(p.n, s)
    return p.name => maxn
end

"""Kit SSH name from a Kit placement token."""
function kit_ssh_name(raw::AbstractString)::String
    return first(parse_host_cap(raw))
end

function host_allow_item(name::AbstractString, cap::Union{Nothing, Int})::String
    role = DistSSHKit.is_parent_host_name(name) ? :parent : :child
    return DistSSHKit.format_placement_token(role, String(name), cap)
end

"""Kit placement tokens in `hosts`, with optional max `:N`.

Missing `hosts`: CLI submit with a placement token errors (`add-host first`).
Empty array: allow none. Library `Queue(; allowed=nothing)` still skips the list.
Same tokens as DistSSHKit: `parent[:N]` / `child:NAME[:N]`. Not a bare SSH name.
A leftover `allowed` key is read the same way until `add-host` rewrites it to `hosts`.
"""
function config_host_names(cfg::AbstractDict)::Union{Nothing, HostAllow}
    has_hosts = haskey(cfg, "hosts")
    has_old = haskey(cfg, "allowed")
    has_hosts && has_old && throw(ArgumentError("use `hosts`, not both `hosts` and `allowed`"))
    raw = has_hosts ? cfg["hosts"] : get(cfg, "allowed", nothing)
    raw === nothing && return nothing
    key = has_hosts ? "hosts" : "allowed"
    raw isa AbstractVector || throw(ArgumentError("`$(key)` must be an array of Kit SSH names"))
    out = HostAllow()
    for x in raw
        n, cap = parse_host_cap(String(x))
        isempty(n) && continue
        out[n] = cap
    end
    return out
end

function sorted_kit_ssh_names(names::AbstractSet{<:AbstractString})::Vector{String}
    v = String[String(n) for n in names]
    sort!(v; by=n -> (DistSSHKit.is_parent_host_name(n) ? 0 : 1, n))
    return v
end

sorted_kit_ssh_names(allow::HostAllow) = sorted_kit_ssh_names(Set{String}(keys(allow)))

function toml_string_array(xs::AbstractVector{<:AbstractString})::String
    return "[" * join((repr(String(x)) for x in xs), ", ") * "]"
end

function hosts_toml_line(allow::HostAllow)::String
    items = String[host_allow_item(n, allow[n]) for n in sorted_kit_ssh_names(allow)]
    return "hosts = " * toml_string_array(items)
end

function _is_host_list_toml_line(row::String)::Bool
    t = lstrip(row)
    if !isempty(t) && t[1] == '#'
        t = lstrip(SubString(t, nextind(t, firstindex(t))))
    end
    for key in ("hosts", "allowed")
        startswith(t, key) || continue
        rest = lstrip(chopprefix(t, key))
        startswith(rest, "=") && return true
    end
    return false
end

function replace_or_insert_hosts_line(text::String, line::String)::String
    s = String(text)
    ln = String(line)
    rows = String[String(r) for r in split(s, '\n'; keepempty=true)]
    idx = findfirst(_is_host_list_toml_line, rows)
    if idx isa Int
        rows[idx] = ln
        return join(rows, '\n')
    end
    env = findfirst(r -> startswith(lstrip(r), "[env]"), rows)
    if env isa Int
        insert!(rows, env, ln)
        return join(rows, '\n')
    end
    return rstrip(s) * "\n" * ln * "\n"
end

function write_host_names!(path::AbstractString, allow::HostAllow)
    p = String(path)
    isfile(p) || write_config_template(p)
    body = replace_or_insert_hosts_line(read(p, String), hosts_toml_line(allow))
    tmp = string(p, ".tmp")
    write(tmp, body)
    mv(tmp, p; force=true)
    return allow
end

function parse_host_caps(raws)::HostAllow
    out = HostAllow()
    for r in raws
        n, cap = parse_host_cap(String(r))
        isempty(n) && throw(ArgumentError("Kit SSH name is empty"))
        out[n] = cap
    end
    return out
end

"""First `add-host` creates `hosts` (CLI submit can name those tokens).

Tokens are Kit's (`parent[:N]` / `child:NAME[:N]`). `:N` is an optional max.
"""
function add_host_names!(path::AbstractString, raws)
    extra = parse_host_caps(raws)
    isempty(extra) && throw(ArgumentError("add-host needs a Kit token (`parent` / `child:NAME`)"))
    cur = isfile(path) ? config_host_names(load_config(; path=path)) : nothing
    names = cur === nothing ? extra : merge(HostAllow(), cur, extra)
    return write_host_names!(path, names)
end

function remove_host_names!(path::AbstractString, raws)
    extra = parse_host_caps(raws)
    isempty(extra) && throw(ArgumentError("remove-host needs a Kit token (`parent` / `child:NAME`)"))
    isfile(path) || throw(ArgumentError("no config.toml; add-host first"))
    cur = config_host_names(load_config(; path=path))
    cur === nothing && throw(ArgumentError("no hosts= in config; add-host first"))
    for n in keys(extra)
        haskey(cur, n) || throw(ArgumentError("Kit name $(repr(n)) is not on hosts"))
    end
    keep = HostAllow()
    for (n, cap) in cur
        haskey(extra, n) && continue
        keep[n] = cap
    end
    return write_host_names!(path, keep)
end

function default_config_body(; store::AbstractString=default_store_path())::String
    return """
# DistSSHQueue. Override with DISTSSHQUEUE_CONFIG / DISTSSHQUEUE_STORE.
store = $(repr(String(store)))
# hosts = ["parent", "child:host1:4"]   # Kit tokens; optional max :N

[env]
# DISTRIBUTED_SSH_OPTS = "-F /path/to/ssh_config"
# DISTSSHKIT_YES = "1"
# Do not set DISTRIBUTED_REMOTE_PROJECT_ROOT here on a shared queue host:
# every job would deploy to that one worker path. Kit default is
# ~/basename(parent)/basename(project) from the queue-host clone.
"""
end

function write_config_template(path::AbstractString; store::AbstractString=default_store_path())::Bool
    isfile(path) && return false
    mkpath(dirname(path))
    write(path, default_config_body(; store=store))
    return true
end

function store_path()::String
    env = strip(get(ENV, "DISTSSHQUEUE_STORE", ""))
    isempty(env) || return env
    st = config_store_path(load_config())
    st === nothing || return st
    return default_store_path()
end
