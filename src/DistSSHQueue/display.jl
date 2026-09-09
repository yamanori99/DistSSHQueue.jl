"""CLI chrome. Reuses DistSSHKit help helpers; job ids stay a bare line on stdout."""

_q_short(path::String)::String = DistSSHKit.short_path(path)
function _q_short(path::AbstractString)::String
    return DistSSHKit.short_path(string(path)::String)
end

function _q_cell(t::String, w::Int)::String
    n = length(t)
    n >= w && return t
    return string(t, " "^(w - n))
end

const _ID_PREFIX_MIN = 8

"""Path relative to `root`, or `nothing` if it is not inside."""
function _rel_under(path::AbstractString, root::AbstractString)::Union{Nothing,String}
    p = DistSSHKit.canonical_local_path(String(path))
    r = DistSSHKit.canonical_local_path(String(root))
    p == r && return "."
    pref = path_inside_prefix(r)
    startswith(p, pref) || return nothing
    return String(chopprefix(p, pref))
end

function _job_project_disp(j::Job)::String
    p = get(j.kwargs, "project", nothing)
    p isa AbstractString || return ""
    can = DistSSHKit.canonical_local_path(String(p))
    can == DistSSHKit.canonical_local_path(pwd()) && return "."
    return _q_short(String(p))
end

function _job_script_disp(j::Job)::String
    p = get(j.kwargs, "project", nothing)
    if p isa AbstractString
        rel = _rel_under(j.script, p)
        rel !== nothing && return rel
    end
    return _q_short(j.script)
end

function _job_id8(id::AbstractString)::String
    s = String(id)
    return first(s, min(8, length(s)))
end

function _job_phase_disp(j::Job)::String
    p = get(j.kwargs, "phase", nothing)
    p isa AbstractString || return ""
    s = strip(String(p))
    return s
end

function _job_state_disp(j::Job)::String
    if j.state === :running
        ph = _job_phase_disp(j)
        isempty(ph) || return ph
    end
    return String(j.state)
end

function _job_result_disp(j::Job; verbose::Bool=false)::String
    r = j.result_path
    r isa AbstractString || return ""
    verbose || return basename(rstrip(String(r), '/'))
    home = homedir()
    p = DistSSHKit.canonical_local_path(String(r))
    h = DistSSHKit.canonical_local_path(home)
    startswith(p, h) && return string("~", chopprefix(p, h))
    return _q_short(r)
end

function _tail_jobs(rows::Vector{Job}, tail::Union{Nothing,Int})
    tail === nothing && return rows, 0
    n = length(rows)
    n <= tail && return rows, 0
    return rows[(n - tail + 1):n], n - tail
end

function print_jobs_table(
    rows::Vector{Job};
    io::IO=stdout,
    present::Bool=true,
    quiet::Bool=false,
    hidden::Int=0,
    verbose::Bool=false,
)
    DistSSHKit.print_help_section("Jobs"; io=io)
    if !present
        DistSSHKit.print_colored(io, "  (none)", :light_black, false)
        println(io)
        return nothing
    end
    if isempty(rows)
        DistSSHKit.print_colored(io, "  (empty)", :light_black, false)
        println(io)
        return nothing
    end
    ids = _unique_prefixes(String[j.id for j in rows])
    states = String[_job_state_disp(j) for j in rows]
    kinds = String[String(j.kind) for j in rows]
    scripts = String[_job_script_disp(j) for j in rows]
    w_id = max(2, maximum(length, ids; init=2))
    w_st = max(5, maximum(length, states; init=5))
    w_k = max(4, maximum(length, kinds; init=4))
    w_sc = max(6, maximum(length, scripts; init=6))
    headers = String["ID", "STATE", "KIND", "SCRIPT"]
    widths = Int[w_id, w_st, w_k, w_sc]
    head = join((_q_cell(headers[i], widths[i]) for i in eachindex(headers)), "  ")
    DistSSHKit.print_colored(io, "  " * head, :light_black, false)
    println(io)
    for (i, j) in enumerate(rows)
        i > 1 && println(io)
        print(io, "  ", _q_cell(ids[i], w_id), "  ")
        DistSSHKit.print_colored(
            io, _q_cell(states[i], w_st),
            isempty(_job_phase_disp(j)) ? _q_state_color(j.state) : :cyan,
            false,
        )
        print(io, "  ", _q_cell(kinds[i], w_k), "  ", _q_cell(scripts[i], w_sc))
        println(io)
        quiet && continue
        hosts = join(j.hosts, "  ")
        isempty(hosts) || begin
            DistSSHKit.print_colored(io, "    hosts    ", :light_black, false)
            println(io, hosts)
        end
        proj = _job_project_disp(j)
        isempty(proj) || begin
            DistSSHKit.print_colored(io, "    project  ", :light_black, false)
            println(io, proj)
        end
        res = _job_result_disp(j; verbose=verbose)
        isempty(res) || begin
            DistSSHKit.print_colored(io, "    result   ", :light_black, false)
            println(io, res)
        end
        err = _job_error_disp(j)
        isempty(err) || begin
            DistSSHKit.print_colored(io, "    error    ", :light_black, false)
            DistSSHKit.print_colored(io, err, :red, false)
            println(io)
        end
    end
    if hidden > 0
        DistSSHKit.print_colored(
            io, "  ($hidden older jobs hidden; --tail full)", :light_black, false,
        )
        println(io)
    end
    return nothing
end

function print_status_table(
    store::AbstractString,
    rows::Vector{Job};
    io::IO=stdout,
    qhost::Union{Nothing,AbstractString}=nothing,
    quiet::Bool=false,
    live::Bool=false,
    hidden::Int=0,
    verbose::Bool=false,
)
    present = isfile(store)
    if !quiet
        DistSSHKit.print_help_section("Store"; io=io)
        DistSSHKit.print_help_lines(io,
            "  path   $(_store_path_disp(store, present, qhost))",
            "  serve  $(_serve_disp(store))",
            "  enable $(_enable_disp())",
            "  qhost  $(_qhost_disp(qhost))",
        )
        DistSSHKit.print_help_blank(io)
    end
    print_jobs_table(rows; io=io, present=present, quiet=quiet, hidden=hidden, verbose=verbose)
    if live && !quiet
        DistSSHKit.print_help_blank(io)
        DistSSHKit.print_help_lines(io, "Ctrl-C stops watch; serve stays.")
    end
    return nothing
end

function print_watch_frame(
    store::AbstractString,
    rows::Vector{Job};
    io::IO=stdout,
    qhost::Union{Nothing,AbstractString}=nothing,
    quiet::Bool=false,
    hidden::Int=0,
    verbose::Bool=false,
)
    return print_status_table(
        store, rows; io=io, qhost=qhost, quiet=quiet, live=true, hidden=hidden, verbose=verbose,
    )
end

"""Shortest unique prefixes (`minlen` or more) for `ids`, same order."""
function _unique_prefixes(
    ids::AbstractVector{<:AbstractString};
    minlen::Int=_ID_PREFIX_MIN,
)::Vector{String}
    n = length(ids)
    out = Vector{String}(undef, n)
    for i in 1:n
        id = String(ids[i])
        L = min(max(minlen, 1), length(id))
        while L < length(id)
            p = first(id, L)
            amb = false
            for j in 1:n
                j == i && continue
                startswith(String(ids[j]), p) && (amb = true; break)
            end
            amb || break
            L += 1
        end
        out[i] = first(id, L)
    end
    return out
end

function _id_chrome(id::AbstractString, ids::AbstractVector{<:AbstractString})::String
    ps = _unique_prefixes(ids)
    for i in eachindex(ids)
        String(ids[i]) == String(id) && return ps[i]
    end
    return first(String(id), min(_ID_PREFIX_MIN, length(id)))
end

const _ERROR_CELL_MAX = 60

function _job_error_disp(j::Job)::String
    e = j.error
    e isa AbstractString || return ""
    firstline = first(split(e, '\n'; limit=2))
    length(firstline) > _ERROR_CELL_MAX && return string(firstline[1:_ERROR_CELL_MAX], "…")
    return firstline
end

function _q_state_color(state::Symbol)
    state === :running && return :cyan
    state === :done && return :green
    state === :failed && return :red
    state === :cancelled && return :yellow
    return :light_black
end

function println_queue_version(io::IO=stdout)
    println(io, "DistSSHQueue $(pkgversion(DistSSHQueue))")
    DistSSHKit.println_kit_version(io)
    return nothing
end

function print_queue_usage(io::IO=stdout)
    DistSSHKit.print_help_chrome("DistSSHQueue"; io=io)
    DistSSHKit.print_help_section("Usage"; io=io)
    DistSSHKit.print_help_lines(io,
        "  julia -m DistSSHQueue [qhost:HOST] <command> [args...]",
        "  julia -m DistSSHQueue --version",
    )
    DistSSHKit.print_help_blank(io)
    DistSSHKit.print_help_section("Client"; io=io)
    DistSSHKit.print_help_lines(io,
        "  status [-q] [--tail N|full]  Snapshot; --interval is live",
        "  list-host             Host tokens on the queue host",
        "  size                  Kit size on the queue host",
        "  plan                  Kit plan on the queue host",
        "  pool                  Kit pool on the queue host",
        "  watch [-q] [--tail N|full]    Same as status --interval",
        "  submit go|ride|drive … Enqueue DistSSHKit (`pool:N` sets every host)",
        "  cancel <id>           Drop queued or stop running",
        "  fetch <id>            Copy a finished Kit leaf here",
        "  teardown -y           Stop serve and remove queue-host files",
    )
    DistSSHKit.print_help_blank(io)
    DistSSHKit.print_help_section("Queue host"; io=io)
    DistSSHKit.print_help_lines(io,
        "  setup [--force] [--juliaup]  Write config.toml; --juliaup aligns Julia",
        "  add-host TOKEN …      Add Kit tokens",
        "  remove-host TOKEN …   Drop Kit tokens",
        "  serve                 Run serve in this terminal",
        "  stop                  Stop serve, keep files",
        "  enable                Start serve after reboot",
        "  disable               Remove that OS registration",
        "  teardown -y           Same, locally",
    )
    DistSSHKit.print_help_blank(io)
    DistSSHKit.print_help_section("Examples"; io=io)
    DistSSHKit.print_help_lines(io,
        "  julia --project=. -m DistSSHQueue setup",
        "  julia --project=. -m DistSSHQueue qhost:HOST status",
        "  julia --project=. -m DistSSHQueue qhost:HOST plan SCRIPT.jl",
        "  julia --project=. -m DistSSHQueue qhost:HOST go parent SCRIPT.jl",
    )
    DistSSHKit.print_help_blank(io)
    println(io, "Run `julia -m DistSSHQueue <command> -h` for flags.")
    return nothing
end

function print_wrote(path::AbstractString; io::IO=stdout)
    DistSSHKit.print_colored(io, "Wrote  ", :green, false)
    println(io, _q_short(path))
    return nothing
end

function print_removed(path::AbstractString; io::IO=stdout)
    DistSSHKit.print_colored(io, "Removed  ", :green, false)
    println(io, _q_short(path))
    return nothing
end

function print_present(
    path::AbstractString;
    io::IO=stdout,
    note::AbstractString="  (unchanged; --force to rewrite)",
)
    DistSSHKit.print_colored(io, "Present  ", :light_black, false)
    print(io, _q_short(path))
    DistSSHKit.print_colored(io, note, :light_black, false)
    println(io)
    return nothing
end

function print_serve_banner(pid::Integer, store::AbstractString; io::IO=stdout)
    DistSSHKit.print_help_chrome("DistSSHQueue serve"; io=io)
    DistSSHKit.print_help_lines(io, "  pid $pid  store $(_q_short(store))")
    return nothing
end

_serve_can_draw(io::IO)::Bool = io isa Base.TTY && !haskey(ENV, "NO_COLOR")

const _SERVE_CTRLC = "Ctrl-C stops serve. A DistSSHKit job already running is not killed."

function _clip_cols(s::AbstractString, cols::Int)::String
    cols <= 0 && return String(s)
    tw = textwidth(s)
    tw <= cols && return String(s)
    cols <= 1 && return "…"
    buf = IOBuffer()
    used = 0
    for c in s
        w = textwidth(c)
        used + w > cols - 1 && break
        print(buf, c)
        used += w
    end
    print(buf, '…')
    return String(take!(buf))
end

function _serve_live_text(
    frame::Char,
    j::Union{Nothing,Job},
    ids::AbstractVector{<:AbstractString}=String[];
    cols::Int=0,
)::String
    j === nothing && return _clip_cols("  $frame  idle", cols)
    sid = isempty(ids) ? first(j.id, min(_ID_PREFIX_MIN, length(j.id))) : _id_chrome(j.id, ids)
    body = "  $frame  running  $sid  $(j.kind)  $(_job_script_disp(j))"
    return _clip_cols(body, cols)
end

function print_serve_live_line(
    frame::Char,
    j::Union{Nothing,Job},
    ids::AbstractVector{<:AbstractString}=String[];
    io::IO=stdout,
)
    cols = io isa Base.TTY ? displaysize(io)[2] : 0
    s = _serve_live_text(frame, j, ids; cols=cols)
    print(io, '\r', s, "\e[K")
    flush(io)
    return nothing
end

function print_serve_idle_note(; io::IO=stdout)
    DistSSHKit.print_help_lines(io, _SERVE_CTRLC)
    return nothing
end

function print_serve_gone(store::AbstractString; io::IO=stdout)
    DistSSHKit.print_colored(io, "Stopping serve", :yellow, false)
    println(io)
    DistSSHKit.print_help_lines(io,
        "  store  $(_q_short(store)) (pidfile gone; removed or taken over)",
        "  A DistSSHKit job already running is not killed.",
    )
    return nothing
end

function print_serve_already(pid::Integer, store::AbstractString; io::IO=stdout)
    DistSSHKit.print_help_chrome("DistSSHQueue serve"; io=io)
    DistSSHKit.print_colored(io, "Already running", :cyan, false)
    println(io)
    DistSSHKit.print_help_lines(io,
        "  pid    $pid",
        "  store  $(_q_short(store))",
        "  Use status or watch. stop, then serve, to restart.",
    )
    return nothing
end

function print_serve_started(log::AbstractString; io::IO=stderr)
    DistSSHKit.print_colored(io, "Started serve", :cyan, false)
    println(io)
    DistSSHKit.print_help_lines(io,
        "  host  $(gethostname())",
        "  log   $(_q_short(log))",
    )
    return nothing
end

function print_serve_stopped(store::AbstractString, was_running::Bool; io::IO=stdout)
    DistSSHKit.print_colored(io, "Stopped serve", :yellow, false)
    println(io)
    DistSSHKit.print_help_lines(io,
        "  store  $(_q_short(store))",
        was_running ? "  serve was running; sent SIGTERM" : "  no serve was running",
        "  submit will not auto-start; run serve to resume.",
    )
    return nothing
end

function _serve_disp(store::AbstractString)::String
    serve_alive(store) && return "running"
    serve_stopped(store) && return "stopped"
    return "none"
end

"""OS unit file from `enable`, if present on this host (queue host after `qhost:`)."""
function _enable_unit_path(; home::AbstractString=homedir())::Union{Nothing,String}
    paths = if Sys.isapple()
        (launch_agent_path(; home=home), legacy_launch_agent_path(; home=home))
    elseif Sys.islinux()
        (systemd_user_path(; home=home), legacy_systemd_user_path(; home=home))
    else
        return nothing
    end
    for p in paths
        isfile(p) && return p
    end
    return nothing
end

function _enable_disp(; home::AbstractString=homedir())::String
    p = _enable_unit_path(; home=home)
    p === nothing && return "none"
    return _q_short(p)
end

function _store_path_disp(
    store::AbstractString,
    present::Bool,
    qhost::Union{Nothing,AbstractString},
)::String
    present || return "none"
    short = _q_short(store)
    if qhost === nothing || isempty(String(qhost))
        return short
    end
    return "$(String(qhost)):$short"
end

function _qhost_disp(qhost::Union{Nothing,AbstractString})::String
    hn = gethostname()
    if qhost === nothing || isempty(String(qhost))
        return "local ($hn)"
    end
    v = String(qhost)
    return v == hn ? v : "$v ($hn)"
end

function print_watch_compact(
    store::AbstractString,
    rows::Vector{Job};
    io::IO=stdout,
)
    nrun = count(j -> j.state === :running, rows)
    nq = count(j -> j.state === :queued, rows)
    println(io, "  serve $(_serve_disp(store))  running $nrun  queued $nq")
    flush(io)
    return nothing
end
