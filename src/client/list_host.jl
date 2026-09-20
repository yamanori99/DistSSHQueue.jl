"""Read-only `list-host`: Kit names from config `hosts`, plus `ssh -G` connect.

Prints host tokens (`parent` / `child:NAME`) for `submit`. Not Kit `--hosts`.
One row per host: NAME / TOKEN / MAX / JULIA / SSH.
SSH is `this machine` / `queue host` for `parent`, else `user@hostname:port`
(`:port` omitted when 22). No private keys or IdentityFile.
JULIA is that host's `juliaup default` patch (`juliaup status` `*` row
Version column, e.g. `1.12.7`), or `-` if missing, SSH/`status` fails,
or there is no Version on the `*` row.
"""

const _SSH_G_KEYS = ("host", "hostname", "user", "port")

function ssh_g_connect(name::AbstractString)::Dict{String, String}
    out = Dict{String, String}()
    h = String(name)
    try
        dump = read(pipeline(Cmd(["ssh", "-n", DistSSHKit.ssh_opts()..., "-G", h]); stderr = devnull))
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

"""NAME column: queue-host hostname for `parent`, SSH Host for `child:`."""
function _host_name_disp(name::AbstractString)::String
    DistSSHKit.is_parent_host_name(name) && return gethostname()
    return String(name)
end

function _ssh_disp(name::AbstractString; hopped::Bool)::String
    if DistSSHKit.is_parent_host_name(name)
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

function _host_token(name::AbstractString)::String
    DistSSHKit.is_parent_host_name(name) && return "parent"
    return "child:$(name)"
end

function _juliaup_status_sh()::String
    words = join(
        DistSSHKit._juliaup_candidate_sh_word.(DistSSHKit.remote_juliaup_candidates()),
        " ",
    )
    return """
    JU=\"\"
    for c in $words; do
      if [ -x \"\$c\" ]; then
        JU=\"\$c\"
        break
      fi
    done
    [ -z \"\$JU\" ] && exit 0
    \"\$JU\" status 2>/dev/null
    """
end

"""Installed patch of the `juliaup status` `*` channel, or `-`.

`juliaup status` looks like `*  1.13     1.13.2+0.aarch64…`. Channel-only
`* 1.13` (no Version) is `-`. Named channels (`release`) still use the
Version column.
"""
function _juliaup_patch_from_status(status_out::AbstractString)::String
    for line in eachsplit(String(status_out), '\n'; keepempty = false)
        s = strip(line)
        isempty(s) && continue
        startswith(s, "Default") && continue
        startswith(s, "-") && continue
        m = match(r"^\*\s+\S+\s+(\S+)", s)
        m === nothing && continue
        cap = m.captures[1]
        cap isa AbstractString || continue
        return String(first(split(String(cap), '+'; limit = 2)))
    end
    return "-"
end

"""`juliaup` default patch (`*`), or `-` if missing, SSH/`status` fails, or no Version."""
function _juliaup_default_disp(name::AbstractString)::String
    if DistSSHKit.is_parent_host_name(name)
        ju = DistSSHKit.find_local_juliaup()
        ju === nothing && return "-"
        proc, out, _ = DistSSHKit._juliaup_run_captured(ju, ["status"])
        Int(something(proc.exitcode, 1)) == 0 || return "-"
        return _juliaup_patch_from_status(out)
    end
    try
        out = read(
            pipeline(
                DistSSHKit._host_sync_remote_shell_cmd(String(name), _juliaup_status_sh());
                stderr = devnull,
            ),
            String,
        )
        return _juliaup_patch_from_status(out)
    catch
        return "-"
    end
end

"""Fit NAME / TOKEN so the row stays within `cols`. SSH gets the remainder (min 8)."""
function _list_host_fit(nw::Int, tw::Int, mw::Int, jw::Int, cols::Int)
    gap = 10
    min_n, min_t, min_s = 4, 5, 8
    room = cols - gap - mw - jw
    pack(n, t) = (n, t, mw, jw, max(min_s, room - n - t))
    if room < min_n + min_t + min_s
        return pack(min_n, min_t)
    end
    if nw + tw + min_s <= room
        return pack(nw, tw)
    end
    budget = room - min_s
    tot = nw + tw
    n2 = max(min_n, round(Int, budget * nw / tot))
    t2 = budget - n2
    if t2 < min_t
        t2 = min_t
        n2 = max(min_n, budget - t2)
    end
    if n2 + t2 > budget
        n2 = max(min_n, budget - min_t)
        t2 = min_t
    end
    return pack(n2, t2)
end

function print_list_host(
        names::Union{Nothing, HostAllow};
        io::IO = stdout,
        qhost::Union{Nothing, AbstractString} = qhost_display_from_env(),
        cols::Int = 0,
    )
    DistSSHKit.print_help_chrome("DistSSHQueue list-host"; io = io)
    if names === nothing
        println(io, "  (no hosts= in config; add-host first)")
        return nothing
    end
    if isempty(names)
        println(io, "  (hosts = []; submit accepts none)")
        return nothing
    end
    hopped = !(qhost === nothing || isempty(String(qhost)))
    rows = sorted_kit_ssh_names(names)
    labels = String[_host_name_disp(n) for n in rows]
    nw = max(4, maximum(textwidth, labels))
    tw = max(5, maximum(textwidth ∘ _host_token, rows))
    maxs = String[names[n] === nothing ? "-" : string(names[n]) for n in rows]
    mw = max(3, maximum(textwidth, maxs))
    julias = String[_juliaup_default_disp(n) for n in rows]
    jw = max(5, maximum(textwidth, julias))
    sshes = String[_ssh_disp(n; hopped = hopped) for n in rows]
    n = cols > 0 ? max(24, cols) : cli_cols(io)
    nw, tw, mw, jw, _ssh_w = _list_host_fit(nw, tw, mw, jw, n)
    print_wrapped_row(
        io, ["NAME", "TOKEN", "MAX", "JULIA"], Int[nw, tw, mw, jw], "SSH";
        cols = n, prefix_color = :light_black, tail_color = :light_black,
    )
    for (i, host) in enumerate(rows)
        print_wrapped_row(
            io,
            [labels[i], _host_token(host), maxs[i], julias[i]],
            Int[nw, tw, mw, jw],
            sshes[i];
            cols = n,
        )
    end
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
