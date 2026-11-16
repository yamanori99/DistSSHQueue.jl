# Read-only `list-host`: registry machine tokens from config `hosts`, plus `ssh -G` connect.
#
# Head is always listed first (not in config). Remote rows use Run machine tokens.
# One row per host: NAME / TOKEN / WORKERS / JULIA / SSH.
# SSH is `this machine` / `queue host` for the head row, else `user@hostname:port`
# (`:port` omitted when 22). No private keys or IdentityFile.
# JULIA is that host's `juliaup default` patch (`juliaup status` `*` row
# Version column, e.g. `1.12.7`), or `-` if missing, SSH/`status` fails,
# or there is no Version on the `*` row.
const _SSH_G_KEYS = ("host", "hostname", "user", "port")

function ssh_g_connect(name::AbstractString)::Dict{String, String}
    out = Dict{String, String}()
    h = String(name)
    try
        dump = read(pipeline(Cmd(["ssh", "-n", ssh_opts()..., "-G", _ssh_host_args(h)...]); stderr = devnull))
        for line in eachsplit(String(dump), '\n'; keepempty = false)
            sp = findfirst(isspace, line)
            sp === nothing && continue
            key = lowercase(String(SubString(line, 1, prevind(line, sp))))
            key in _SSH_G_KEYS || continue
            haskey(out, key) && continue
            val = strip(SubString(line, nextind(line, sp)))
            isempty(val) || (out[key] = String(val))
        end
    catch
    end
    return out
end

"""NAME column for a registry SSH host."""
function _host_name_disp(name::AbstractString)::String
    return String(name)
end

function _ssh_disp(name::AbstractString; hopped::Bool, head::Bool = false)::String
    if head
        return hopped ? "queue host" : "this machine"
    end
    g = ssh_g_connect(name)
    isempty(g) && return "(ssh -G failed)"
    hostn = get(g, "hostname", get(g, "host", String(name)))
    user = get(g, "user", "")
    port = get(g, "port", "22")
    dest = isempty(user) ? hostn : "$(user)@$(hostn)"
    return port == "22" || isempty(port) ? dest : "$(dest):$(port)"
end

function _host_token(name::AbstractString, workers::Int)::String
    return format_machine_token(workers, String(name))
end

function _juliaup_default_disp(name::AbstractString)::String
    return juliaup_default_patch(name)
end

"""
Fit NAME / TOKEN so the row stays within `cols`.

TOKEN keeps its width. A long hostname clips in NAME. SSH gets the remainder (min 8).
"""
function _list_host_fit(nw::Int, tw::Int, mw::Int, jw::Int, cols::Int)
    gap = 10
    min_n, min_t, min_s = 4, 5, 8
    room = cols - gap - mw - jw
    pack(n, t) = (n, t, mw, jw, max(min_s, room - n - t))
    if room < min_n + min_t + min_s
        return pack(min_n, min_t)
    end
    budget = room - min_s
    if nw + tw <= budget
        return pack(nw, tw)
    end
    t2 = min(max(tw, min_t), budget - min_n)
    n2 = max(min_n, min(nw, budget - t2))
    return pack(n2, t2)
end

function print_list_host(
        names::Union{Nothing, HostAllow};
        io::IO = stdout,
        qhost::Union{Nothing, AbstractString} = qhost_display_from_env(),
        cols::Int = 0,
    )
    print_help_chrome(cli_heading("list-host"); io = io)
    if names === nothing
        println(io, "  (no hosts= in config; add-host first)")
        return nothing
    end
    hopped = !(qhost === nothing || isempty(String(qhost)))
    rows = sorted_registry_hosts(names)
    head_name = gethostname()
    head_token = "head"
    head_workers = "-"
    head_julia = juliaup_default_patch(head_name)
    head_ssh = _ssh_disp(head_name; hopped = hopped, head = true)
    labels = String[vcat([head_name], [_host_name_disp(n) for n in rows])...]
    nw = max(4, maximum(textwidth, labels))
    tokens = String[vcat([head_token], [_host_token(n, names[n]) for n in rows])...]
    tw = max(5, maximum(textwidth, tokens))
    maxs = String[vcat([head_workers], [string(names[n]) for n in rows])...]
    mw = max(3, maximum(textwidth, maxs))
    julias = String[vcat([head_julia], [_juliaup_default_disp(n) for n in rows])...]
    jw = max(5, maximum(textwidth, julias))
    sshes = String[vcat([head_ssh], [_ssh_disp(n; hopped = hopped) for n in rows])...]
    n = cols > 0 ? max(24, cols) : cli_cols(io)
    nw, tw, mw, jw, _ssh_w = _list_host_fit(nw, tw, mw, jw, n)
    print_wrapped_row(
        io, ["NAME", "TOKEN", "WORKERS", "JULIA"], Int[nw, tw, mw, jw], "SSH";
        cols = n, prefix_color = :light_black, tail_color = :light_black,
    )
    for i in eachindex(labels)
        print_wrapped_row(
            io,
            [labels[i], tokens[i], maxs[i], julias[i]],
            Int[nw, tw, mw, jw],
            sshes[i];
            cols = n,
        )
    end
    isempty(rows) && println(io, "  (registry accepts none)")
    return nothing
end

function list_host_cli(args::Vector{String})::Cint
    i = 1
    while i <= length(args)
        a = args[i]
        if a in ("-h", "--help")
            show_usage(; command = "list-host")
            return 0
        end
        throw(ArgumentError("unknown list-host option: $(a)"))
    end
    print_list_host(config_host_names(load_config()))
    return 0
end
