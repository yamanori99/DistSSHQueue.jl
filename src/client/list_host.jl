"""Read-only `list-host`: Kit names from config `hosts`, plus `ssh -G` connect fields.

Prints host tokens (`parent` / `child:NAME`) for `submit`. Not Kit `--hosts`.
JULIAUP is that host's `juliaup default` (`juliaup status` `*` row).
Does not print private keys or IdentityFile.
"""

const _SSH_G_KEYS = ("host", "hostname", "user", "port")

function ssh_g_connect(name::AbstractString)::Dict{String,String}
    out = Dict{String,String}()
    h = String(name)
    try
        dump = read(pipeline(Cmd(["ssh", "-n", DistSSHKit.ssh_opts()..., "-G", h]); stderr=devnull))
        for line in eachsplit(String(dump), '\n'; keepempty=false)
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

function _host_token_ssh_disp(
    name::AbstractString;
    hopped::Bool=false,
)::String
    if DistSSHKit.is_parent_host_name(name)
        hn = gethostname()
        return hopped ? "queue host ($hn)" : "this machine ($hn)"
    end
    g = ssh_g_connect(name)
    isempty(g) && return "(ssh -G failed)"
    parts = String[]
    haskey(g, "host") && push!(parts, "Host $(g["host"])")
    haskey(g, "hostname") && push!(parts, "HostName $(g["hostname"])")
    haskey(g, "user") && push!(parts, "User $(g["user"])")
    haskey(g, "port") && push!(parts, "Port $(g["port"])")
    return join(parts, "  ")
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

function _juliaup_channel_from_status(out::AbstractString)::String
    ch = DistSSHKit._juliaup_default_channel_from_status(out)
    return ch === nothing ? "-" : ch
end

"""`juliaup` default channel (`*`), or `-` if missing / unreachable."""
function _juliaup_default_disp(name::AbstractString)::String
    if DistSSHKit.is_parent_host_name(name)
        ju = DistSSHKit.find_local_juliaup()
        ju === nothing && return "-"
        proc, out, _ = DistSSHKit._juliaup_run_captured(ju, ["status"])
        Int(something(proc.exitcode, 1)) == 0 || return "-"
        return _juliaup_channel_from_status(out)
    end
    try
        out = read(
            pipeline(
                DistSSHKit._host_sync_remote_shell_cmd(String(name), _juliaup_status_sh());
                stderr=devnull,
            ),
            String,
        )
        return _juliaup_channel_from_status(out)
    catch
        return "-"
    end
end

function print_list_host(
    names::Union{Nothing, HostAllow};
    io::IO=stdout,
    qhost::Union{Nothing,AbstractString}=qhost_display_from_env(),
)
    DistSSHKit.print_help_chrome("DistSSHQueue list-host"; io=io)
    if names === nothing
        println(io, "  (no hosts= in config; submit accepts any Kit name)")
        return nothing
    end
    if isempty(names)
        println(io, "  (hosts = []; submit accepts none)")
        return nothing
    end
    hopped = !(qhost === nothing || isempty(String(qhost)))
    rows = sorted_kit_ssh_names(names)
    labels = String[_host_name_disp(n) for n in rows]
    nw = max(4, maximum(length, labels))
    tw = max(10, maximum(length ∘ _host_token, rows))
    maxs = String[names[n] === nothing ? "-" : string(names[n]) for n in rows]
    mw = max(3, maximum(length, maxs))
    julias = String[_juliaup_default_disp(n) for n in rows]
    jw = max(7, maximum(length, julias))
    println(
        io,
        "  ",
        rpad("NAME", nw),
        "  ",
        rpad("HOST TOKEN", tw),
        "  ",
        rpad("MAX", mw),
        "  ",
        rpad("JULIAUP", jw),
        "  SSH",
    )
    for (n, label, ju) in zip(rows, labels, julias)
        println(
            io,
            "  ",
            rpad(label, nw),
            "  ",
            rpad(_host_token(n), tw),
            "  ",
            rpad(names[n] === nothing ? "-" : string(names[n]), mw),
            "  ",
            rpad(ju, jw),
            "  ",
            _host_token_ssh_disp(n; hopped=hopped),
        )
    end
    return nothing
end

function list_host_cli(args::Vector{String})::Cint
    i = 1
    while i <= length(args)
        a = args[i]
        if a in ("-h", "--help")
            show_usage()
            return 0
        end
        throw(ArgumentError("unknown list-host option: $(a)"))
    end
    print_list_host(config_host_names(load_config()))
    return 0
end
