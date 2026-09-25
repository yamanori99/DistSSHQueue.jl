"""CLI chrome. Reuses DistSSHKit help helpers; job ids stay a bare line on stdout."""

_q_short(path::String)::String = DistSSHKit.short_path(path)
function _q_short(path::AbstractString)::String
    return DistSSHKit.short_path(string(path)::String)
end

function _q_cell(t::String, w::Int)::String
    n = textwidth(t)
    n >= w && return t
    return string(t, " "^(w - n))
end

"""TTY columns for CLI tables and notes. Non-TTY (tests, pipes) is 72."""
function cli_cols(io::IO)::Int
    io isa Base.TTY || return 72
    return max(24, displaysize(io)[2])
end

function _break_run(s::AbstractString, wmax::Int)::Vector{String}
    out = String[]
    buf = IOBuffer()
    used = 0
    for c in s
        cw = textwidth(c)
        if used > 0 && used + cw > wmax
            push!(out, String(take!(buf)))
            used = 0
        end
        print(buf, c)
        used += cw
    end
    used > 0 && push!(out, String(take!(buf)))
    return isempty(out) ? String[""] : out
end

function _wrap_words(s::AbstractString, width::Int)::Vector{String}
    wmax = max(8, width)
    raw = String(s)
    textwidth(raw) <= wmax && return String[raw]
    words = split(s)
    isempty(words) && return String[""]
    lines = String[]
    cur = ""
    for w in words
        piece = String(w)
        if textwidth(piece) > wmax
            isempty(cur) || (push!(lines, cur); cur = "")
            append!(lines, _break_run(piece, wmax))
            continue
        end
        if isempty(cur)
            cur = piece
            continue
        end
        if textwidth(cur) + 1 + textwidth(piece) <= wmax
            cur *= " " * piece
        else
            push!(lines, cur)
            cur = piece
        end
    end
    isempty(cur) || push!(lines, cur)
    return lines
end

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

function _padded_clip(s::AbstractString, w::Int)::String
    return _q_cell(_clip_cols(String(s), w), w)
end

function _write_span(io::IO, s::AbstractString, color::Union{Nothing, Symbol})
    color === nothing && return print(io, s)
    DistSSHKit.print_colored(io, s, color, false)
    return nothing
end

"""Wrap `tail` after `prefix` to `cols`. Continuation hangs under the tail column."""
function print_wrapped_tail(
        io::IO,
        prefix::AbstractString,
        tail::AbstractString;
        cols::Int,
        prefix_color::Union{Nothing, Symbol} = nothing,
        tail_color::Union{Nothing, Symbol} = nothing,
        write_prefix::Bool = true,
    )
    n = cols
    left = textwidth(prefix)
    hang_n = left >= n - 8 ? 4 : left
    wrap_w = max(8, n - hang_n)
    chunks = _wrap_words(tail, wrap_w)
    overflow = left > n || left + textwidth(first(chunks)) > n
    if overflow
        if write_prefix
            _write_span(io, left > n ? _clip_cols(prefix, n) : prefix, prefix_color)
            println(io)
        else
            println(io)
        end
        pad = "    "
        for line in _wrap_words(tail, max(8, n - 4))
            print(io, pad)
            _write_span(io, line, tail_color)
            println(io)
        end
        return nothing
    end
    write_prefix && _write_span(io, prefix, prefix_color)
    if hang_n == left
        _write_span(io, first(chunks), tail_color)
        println(io)
        pad = repeat(" ", hang_n)
        for line in chunks[2:end]
            print(io, pad)
            _write_span(io, line, tail_color)
            println(io)
        end
    else
        println(io)
        pad = repeat(" ", hang_n)
        for line in chunks
            print(io, pad)
            _write_span(io, line, tail_color)
            println(io)
        end
    end
    return nothing
end

"""Fixed-width clipped cells, then a wrapping tail column."""
function print_wrapped_row(
        io::IO,
        cells::AbstractVector{<:AbstractString},
        widths::AbstractVector{Int},
        tail::AbstractString;
        cols::Int,
        indent::Int = 2,
        cell_colors::Union{Nothing, AbstractVector} = nothing,
        tail_color::Union{Nothing, Symbol} = nothing,
        prefix_color::Union{Nothing, Symbol} = nothing,
    )
    length(cells) == length(widths) ||
        throw(ArgumentError("print_wrapped_row cells/widths length"))
    buf = IOBuffer()
    print(buf, repeat(" ", indent))
    for i in eachindex(cells)
        i > 1 && print(buf, "  ")
        print(buf, _padded_clip(cells[i], widths[i]))
    end
    isempty(cells) || print(buf, "  ")
    prefix = String(take!(buf))
    if cell_colors === nothing
        return print_wrapped_tail(
            io, prefix, tail;
            cols = cols, prefix_color = prefix_color, tail_color = tail_color,
        )
    end
    length(cell_colors) == length(cells) ||
        throw(ArgumentError("print_wrapped_row cell_colors length"))
    print(io, repeat(" ", indent))
    for i in eachindex(cells)
        i > 1 && print(io, "  ")
        _write_span(io, _padded_clip(cells[i], widths[i]), cell_colors[i])
    end
    isempty(cells) || print(io, "  ")
    return print_wrapped_tail(
        io, prefix, tail;
        cols = cols, write_prefix = false, tail_color = tail_color,
    )
end

const _ID_PREFIX_MIN = 8

"""Path relative to `root`, or `nothing` if it is not inside."""
function _rel_under(path::AbstractString, root::AbstractString)::Union{Nothing, String}
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

function _job_result_disp(j::Job; verbose::Bool = false)::String
    r = j.result_path
    r isa AbstractString || return ""
    verbose || return basename(rstrip(String(r), '/'))
    home = homedir()
    p = DistSSHKit.canonical_local_path(String(r))
    h = DistSSHKit.canonical_local_path(home)
    startswith(p, h) && return string("~", chopprefix(p, h))
    return _q_short(r)
end

"""UTC `DateTime` as this host's local wall clock at that instant (DST at `dt`)."""
function _utc_to_local(dt::DateTime)::DateTime
    tm = Libc.TmStruct(floor(Int, datetime2unix(dt)))
    return DateTime(
        tm.year + 1900,
        tm.month + 1,
        tm.mday,
        tm.hour,
        tm.min,
        tm.sec,
        millisecond(dt),
    )
end

function _job_queued_disp(j::Job)::String
    return Dates.format(_utc_to_local(j.queued_at), dateformat"yyyy-mm-dd HH:MM")
end

function _human_span(from::DateTime, to::DateTime)::String
    s = max(0, Dates.value(Millisecond(to - from)) ÷ 1000)
    h, rem = divrem(s, 3600)
    m, _ = divrem(rem, 60)
    h > 0 && return string(h, "h", lpad(string(m), 2, '0'), "m")
    return string(m, "m")
end

function _job_elapsed_disp(j::Job)::String
    j.state === :running || return ""
    started = j.started_at
    started isa DateTime || return ""
    return _human_span(started, now(UTC))
end

function _job_wall_disp(j::Job)::String
    j.state in (:done, :failed, :cancelled) || return ""
    started = j.started_at
    started isa DateTime || return ""
    fin = something(j.finished_at, now(UTC))
    return _human_span(started, fin)
end

const _HOSTS_KEEP = 2

function _job_hosts_disp(j::Job; verbose::Bool = false)::String
    verbose && return join(j.hosts, "  ")
    n = length(j.hosts)
    n <= _HOSTS_KEEP && return join(j.hosts, "  ")
    return string(join(j.hosts[1:_HOSTS_KEEP], "  "), "  +", n - _HOSTS_KEEP)
end

function _tail_jobs(rows::Vector{Job}, tail::Union{Nothing, Int})
    tail === nothing && return rows, 0
    n = length(rows)
    n <= tail && return rows, 0
    return rows[(n - tail + 1):n], n - tail
end

"""Shrink leading widths so indent + cells + gaps + tail_min fit in `cols`."""
function _fit_leading_widths(
        natural::Vector{Int},
        mins::Vector{Int},
        cols::Int;
        indent::Int = 2,
        tail_min::Int = 8,
    )::Vector{Int}
    n = length(natural)
    n == length(mins) || throw(ArgumentError("_fit_leading_widths"))
    gap = indent + 2 * n
    room = cols - gap - tail_min
    w = copy(natural)
    sum(w) <= room && return w
    extra = sum(w) - room
    extra <= 0 && return w
    while extra > 0
        idx = 0
        best = 0
        for i in 1:n
            slack = w[i] - mins[i]
            if slack > best
                best = slack
                idx = i
            end
        end
        idx == 0 && break
        take = min(extra, best)
        w[idx] -= take
        extra -= take
    end
    return w
end

function _print_job_detail(
        io::IO,
        key::AbstractString,
        val::AbstractString;
        cols::Int,
        tail_color::Union{Nothing, Symbol} = nothing,
    )
    prefix = "    " * _q_cell(String(key), 8) * "  "
    return print_wrapped_tail(
        io, prefix, val;
        cols = cols, prefix_color = :light_black, tail_color = tail_color,
    )
end

function print_jobs_table(
        rows::Vector{Job};
        io::IO = stdout,
        present::Bool = true,
        quiet::Bool = false,
        hidden::Int = 0,
        verbose::Bool = false,
        cols::Int = 0,
    )
    n = cols > 0 ? max(24, cols) : cli_cols(io)
    DistSSHKit.print_help_section("Jobs"; io = io)
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
    w_id = max(2, maximum(textwidth, ids; init = 2))
    w_st = max(5, maximum(textwidth, states; init = 5))
    w_k = max(4, maximum(textwidth, kinds; init = 4))
    fitted = _fit_leading_widths(Int[w_id, w_st, w_k], Int[2, 5, 4], n)
    w_id, w_st, w_k = fitted[1], fitted[2], fitted[3]
    print_wrapped_row(
        io, ["ID", "STATE", "KIND"], Int[w_id, w_st, w_k], "SCRIPT";
        cols = n, prefix_color = :light_black, tail_color = :light_black,
    )
    for (i, j) in enumerate(rows)
        i > 1 && println(io)
        st_color = isempty(_job_phase_disp(j)) ? _q_state_color(j.state) : :cyan
        print_wrapped_row(
            io, [ids[i], states[i], kinds[i]], Int[w_id, w_st, w_k], scripts[i];
            cols = n, cell_colors = Union{Nothing, Symbol}[nothing, st_color, nothing],
        )
        quiet && continue
        _print_job_detail(io, "queued", _job_queued_disp(j); cols = n)
        el = _job_elapsed_disp(j)
        isempty(el) || _print_job_detail(io, "elapsed", el; cols = n)
        wall = _job_wall_disp(j)
        isempty(wall) || _print_job_detail(io, "wall", wall; cols = n)
        hosts = _job_hosts_disp(j; verbose = verbose)
        isempty(hosts) || _print_job_detail(io, "hosts", hosts; cols = n)
        proj = _job_project_disp(j)
        isempty(proj) || _print_job_detail(io, "project", proj; cols = n)
        res = _job_result_disp(j; verbose = verbose)
        isempty(res) || _print_job_detail(io, "result", res; cols = n)
        err = _job_error_disp(j)
        isempty(err) || _print_job_detail(io, "error", err; cols = n, tail_color = :red)
    end
    if hidden > 0
        print_wrapped_tail(
            io, "  ", "($hidden older jobs hidden; --tail full)";
            cols = n, prefix_color = :light_black,
        )
    end
    return nothing
end

function print_status_table(
        store::AbstractString,
        rows::Vector{Job};
        io::IO = stdout,
        qhost::Union{Nothing, AbstractString} = nothing,
        quiet::Bool = false,
        live::Bool = false,
        hidden::Int = 0,
        verbose::Bool = false,
        cols::Int = 0,
    )
    n = cols > 0 ? max(24, cols) : cli_cols(io)
    present = isfile(store)
    if !quiet
        DistSSHKit.print_help_section("Store"; io = io)
        print_wrapped_tail(
            io, "  path   ", _store_path_disp(store, present, qhost);
            cols = n, prefix_color = :light_black,
        )
        print_wrapped_tail(
            io, "  serve  ", _serve_disp(store);
            cols = n, prefix_color = :light_black,
        )
        print_wrapped_tail(
            io, "  enable ", _enable_disp();
            cols = n, prefix_color = :light_black,
        )
        print_wrapped_tail(
            io, "  qhost  ", _qhost_disp(qhost);
            cols = n, prefix_color = :light_black,
        )
        DistSSHKit.print_help_blank(io)
    end
    print_jobs_table(
        rows;
        io = io, present = present, quiet = quiet, hidden = hidden, verbose = verbose, cols = n,
    )
    if live && !quiet
        DistSSHKit.print_help_blank(io)
        print_wrapped_tail(io, "  ", "Ctrl-C stops watch; serve stays."; cols = n)
    end
    return nothing
end

function print_watch_frame(
        store::AbstractString,
        rows::Vector{Job};
        io::IO = stdout,
        qhost::Union{Nothing, AbstractString} = nothing,
        quiet::Bool = false,
        hidden::Int = 0,
        verbose::Bool = false,
    )
    return print_status_table(
        store, rows; io = io, qhost = qhost, quiet = quiet, live = true, hidden = hidden, verbose = verbose,
    )
end

"""Shortest unique prefixes (`minlen` or more) for `ids`, same order."""
function _unique_prefixes(
        ids::AbstractVector{<:AbstractString};
        minlen::Int = _ID_PREFIX_MIN,
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

"""Queue wording in front of a known Kit line (status `error` and `Job.error`)."""
function queue_explain_error(msg::AbstractString)::String
    s = String(msg)
    startswith(s, "this job includes parent:N;") && return s
    if occursin("is only for --juliaup (kit parent machine)", s)
        return "this job includes parent:N; per-job setup! only rsyncs child: (the queue host is already here). " * s
    end
    return s
end

function _job_error_disp(j::Job)::String
    e = j.error
    e isa AbstractString || return ""
    explained = queue_explain_error(e)
    return first(split(explained, '\n'; limit = 2))
end

function _q_state_color(state::Symbol)
    state === :running && return :cyan
    state === :done && return :green
    state === :failed && return :red
    state === :cancelled && return :yellow
    return :light_black
end

function println_queue_version(io::IO = stdout)
    kv = DistSSHKit.dist_ssh_kit_version()
    println(io, "DistSSHQueue $(pkgversion(DistSSHQueue)) (DistSSHKit $(kv))")
    return nothing
end

"""Kit root help column: two spaces, verb padded to 19, then gloss."""
function help_verb_line(verb::AbstractString, gloss::AbstractString)
    return "  $(rpad(String(verb), 19))$(gloss)"
end

function print_queue_usage(
        io::IO = stdout;
        topic::Union{Nothing, AbstractString} = nothing,
    )
    t = topic === nothing ? "" : strip(String(topic))
    isempty(t) && return print_queue_root_usage(io)
    t == "client" && return print_queue_client_usage(io)
    t in ("qhost", "queue", "queue-host") && return print_queue_host_usage(io)
    throw(ArgumentError("unknown help topic: $(t) (client / qhost)"))
end

function print_queue_root_usage(io::IO = stdout)
    DistSSHKit.print_help_chrome("DistSSHQueue"; io = io)
    println_queue_version(io)
    DistSSHKit.print_help_blank(io)
    DistSSHKit.print_help_section("Client / qhost"; io = io)
    DistSSHKit.print_help_lines(
        io,
        help_verb_line("Client", "job `--project=.`; `qhost:HOST` is SSH to the queue"),
        help_verb_line("Queue host", "`serve`; `--queue-env` (`~/.distsshqueue/env`)"),
    )
    DistSSHKit.print_help_blank(io)
    DistSSHKit.print_help_section("Usage"; io = io)
    DistSSHKit.print_help_lines(
        io,
        help_verb_line("Client", "julia --project=. -m DistSSHQueue [qhost:HOST] …"),
        help_verb_line("Queue host", "julia -m DistSSHQueue …"),
    )
    DistSSHKit.print_help_blank(io)
    DistSSHKit.print_help_section("Help"; io = io)
    DistSSHKit.print_help_lines(
        io,
        "  --help client",
        "  --help qhost",
    )
    DistSSHKit.print_help_blank(io)
    println(io, "Run `<command> --help` (or `-h`) for flags.")
    return nothing
end

function print_queue_client_usage(io::IO = stdout)
    DistSSHKit.print_help_chrome("DistSSHQueue --help client"; io = io)
    DistSSHKit.print_help_section("Jobs"; io = io)
    DistSSHKit.print_help_lines(
        io,
        help_verb_line("submit", "Enqueue DistSSHKit"),
        help_verb_line("status", "Snapshot of the store"),
        help_verb_line("watch", "Live status"),
        help_verb_line("cancel", "Drop queued or stop running"),
        help_verb_line("fetch", "Copy a finished Kit leaf"),
    )
    DistSSHKit.print_help_blank(io)
    DistSSHKit.print_help_section("Hosts"; io = io)
    DistSSHKit.print_help_lines(
        io,
        help_verb_line("list-host", "Inventory (juliaup default + SSH)"),
        help_verb_line("size", "Kit size on the queue host"),
        help_verb_line("plan", "Kit plan on the queue host"),
        help_verb_line("pool", "Kit pool on the queue host"),
    )
    DistSSHKit.print_help_blank(io)
    DistSSHKit.print_help_section("Examples"; io = io)
    DistSSHKit.print_help_lines(
        io,
        "  julia --project=. -m DistSSHQueue qhost:HOST status",
        "  julia --project=. -m DistSSHQueue qhost:HOST submit drive parent:4 SCRIPT.jl",
    )
    DistSSHKit.print_help_blank(io)
    DistSSHKit.print_help_section("See DistSSHKit"; io = io)
    DistSSHKit.print_help_lines(
        io,
        "  Same argv as DistSSHKit (`go` / `ride` / `drive parent:4 child:NAME:N …`).",
        "  `julia --project=. -m DistSSHKit --help`",
    )
    DistSSHKit.print_help_blank(io)
    println(io, "Run `<command> --help` (or `-h`) for flags.")
    return nothing
end

function print_queue_host_usage(io::IO = stdout)
    DistSSHKit.print_help_chrome("DistSSHQueue --help qhost"; io = io)
    DistSSHKit.print_help_section("Setup"; io = io)
    DistSSHKit.print_help_lines(
        io,
        help_verb_line("setup", "Write config.toml if missing"),
        help_verb_line("add-host", "Add Kit tokens"),
        help_verb_line("remove-host", "Drop Kit tokens"),
    )
    DistSSHKit.print_help_blank(io)
    DistSSHKit.print_help_section("Serve"; io = io)
    DistSSHKit.print_help_lines(
        io,
        help_verb_line("serve", "Run serve in this terminal"),
        help_verb_line("stop", "Stop serve, keep files"),
        help_verb_line("enable", "Start serve after reboot"),
        help_verb_line("disable", "Remove that OS registration"),
    )
    DistSSHKit.print_help_blank(io)
    DistSSHKit.print_help_section("Examples"; io = io)
    DistSSHKit.print_help_lines(
        io,
        "  julia -m DistSSHQueue setup",
        "  julia -m DistSSHQueue add-host parent child:NAME",
        "  julia -m DistSSHQueue serve",
    )
    DistSSHKit.print_help_blank(io)
    DistSSHKit.print_help_section("Danger"; io = io)
    DistSSHKit.print_help_lines(
        io,
        help_verb_line("teardown", "Stop serve and remove `~/.distsshqueue`"),
        help_verb_line("", "Needs `-y`. Job trees stay."),
    )
    DistSSHKit.print_help_blank(io)
    println(io, "Run `<command> --help` (or `-h`) for flags.")
    return nothing
end

const QUEUE_COMMAND_HELP = (
    "status", "watch", "list-host", "cancel", "fetch", "submit",
    "add-host", "remove-host", "serve", "stop", "enable", "disable",
    "setup", "teardown",
)

"""True when `rest[1]` is `-h` / `--help` and `sub` has a Queue command page."""
function command_help_argv(sub::AbstractString, rest::Vector{String})::Bool
    isempty(rest) && return false
    rest[1] in ("-h", "--help") || return false
    return String(sub) in QUEUE_COMMAND_HELP
end

"""Short page for `<command> --help`. How to invoke DistSSHQueue is on root `--help`."""
function print_queue_command_usage(io::IO, verb::AbstractString)
    v = String(verb)
    v == "setup" && return print_setup_usage(io)
    v == "teardown" && return print_teardown_usage(io)
    usage, flags = queue_command_help(v)
    DistSSHKit.print_help_chrome("DistSSHQueue $v"; io = io)
    DistSSHKit.print_help_section("Usage"; io = io)
    DistSSHKit.print_help_lines(io, usage...)
    isempty(flags) && return nothing
    DistSSHKit.print_help_blank(io)
    DistSSHKit.print_help_section("Flags"; io = io)
    DistSSHKit.print_help_lines(io, [help_verb_line(f, g) for (f, g) in flags]...)
    return nothing
end

function queue_command_help(verb::AbstractString)
    v = String(verb)
    h = ("--help / -h", "This page")
    v == "status" && return (
        ("  status",), (
            ("-q / --quiet", "Table only"),
            ("--interval SEC", "Refresh like watch"),
            ("--tail N|full", "How many jobs to show"),
            h,
        ),
    )
    v == "watch" && return (
        ("  watch",), (
            ("-q / --quiet", "Table only"),
            ("--interval SEC", "Refresh interval (default 0.5)"),
            ("--tail N|full", "How many jobs to show"),
            h,
        ),
    )
    v == "list-host" && return (("  list-host",), (h,))
    v == "cancel" && return (("  cancel ID",), (h,))
    v == "fetch" && return (
        ("  fetch ID",), (
            ("--into PATH", "Dest directory (the leaf; may be outside the project)"),
            ("--force", "Copy even if dest already has this or another job (does not delete dest-only files)"),
            ("--progress", "rsync `--info=progress2` on `qhost:` pull"),
            h,
        ),
    )
    v == "submit" && return (
        (
            "  submit go|ride|drive …",
            "  `submit go --help` for DistSSHKit flags (same for ride / drive).",
        ), (h,),
    )
    v == "add-host" && return (("  add-host [parent] [child:NAME...]",), (h,))
    v == "remove-host" && return (("  remove-host [parent] [child:NAME...]",), (h,))
    v == "serve" && return (
        ("  serve",), (
            ("--interval SEC", "Poll the store (default 0.2)"),
            h,
        ),
    )
    v == "stop" && return (("  stop",), (h,))
    v == "enable" && return (
        ("  enable",), (
            ("--julia PATH", "Julia for the OS unit"),
            ("--queue-env DIR", "Queue env (not job `--project=`)"),
            ("--write-only", "Write the unit file; do not load it"),
            h,
        ),
    )
    v == "disable" && return (
        ("  disable",), (
            ("--write-only", "Do not unload the OS unit"),
            h,
        ),
    )
    throw(ArgumentError("no command help for $(v)"))
end

function print_setup_usage(io::IO = stdout)
    DistSSHKit.print_help_chrome("DistSSHQueue setup"; io = io)
    DistSSHKit.print_help_section("Usage"; io = io)
    DistSSHKit.print_help_lines(
        io,
        "  julia -m DistSSHQueue setup [--force]",
        "  julia -m DistSSHQueue setup --juliaup",
        "  julia -m DistSSHQueue setup --juliaup-update",
    )
    DistSSHKit.print_help_blank(io)
    DistSSHKit.print_help_section("Flags"; io = io)
    DistSSHKit.print_help_lines(
        io,
        help_verb_line("--force", "Rewrite config.toml (not with juliaup)"),
        help_verb_line("--juliaup", "Set config hosts to this major.minor"),
        help_verb_line("--juliaup-update", "Patch config hosts; leave default"),
        help_verb_line("--config PATH", "Config file"),
        help_verb_line("--help / -h", "This page"),
    )
    return nothing
end

function print_teardown_usage(io::IO = stdout)
    DistSSHKit.print_help_chrome("DistSSHQueue teardown"; io = io)
    DistSSHKit.print_help_section("Usage"; io = io)
    DistSSHKit.print_help_lines(
        io,
        "  teardown",
    )
    DistSSHKit.print_help_blank(io)
    DistSSHKit.print_help_section("Flags"; io = io)
    DistSSHKit.print_help_lines(
        io,
        help_verb_line("-y / --yes", "Required to delete (or DISTSSHKIT_YES)"),
        help_verb_line("--write-only", "Do not stop serve or unload the OS unit"),
        help_verb_line("--home DIR", "Home for ~/.distsshqueue"),
        help_verb_line("--bindir DIR", "Leftover dskq shim path"),
        help_verb_line("--config PATH", "Config file"),
        help_verb_line("--help / -h", "This page"),
    )
    return nothing
end

function print_wrote(path::AbstractString; io::IO = stdout)
    DistSSHKit.print_colored(io, "Wrote  ", :green, false)
    println(io, _q_short(path))
    return nothing
end

function print_removed(path::AbstractString; io::IO = stdout)
    DistSSHKit.print_colored(io, "Removed  ", :green, false)
    println(io, _q_short(path))
    return nothing
end

function print_present(
        path::AbstractString;
        io::IO = stdout,
        note::AbstractString = "  (unchanged; --force to rewrite)",
    )
    DistSSHKit.print_colored(io, "Present  ", :light_black, false)
    print(io, _q_short(path))
    DistSSHKit.print_colored(io, note, :light_black, false)
    println(io)
    return nothing
end

function print_serve_banner(pid::Integer, store::AbstractString; io::IO = stdout)
    DistSSHKit.print_help_chrome("DistSSHQueue serve"; io = io)
    DistSSHKit.print_help_lines(io, "  pid $pid  store $(_q_short(store))")
    return nothing
end

_serve_can_draw(io::IO)::Bool = io isa Base.TTY && !haskey(ENV, "NO_COLOR")

const _SERVE_CTRLC = "Ctrl-C stops serve. A DistSSHKit job already running is not killed."

function _serve_live_text(
        frame::Char,
        j::Union{Nothing, Job},
        ids::AbstractVector{<:AbstractString} = String[];
        cols::Int = 0,
    )::String
    j === nothing && return _clip_cols("  $frame  idle", cols)
    sid = isempty(ids) ? first(j.id, min(_ID_PREFIX_MIN, length(j.id))) : _id_chrome(j.id, ids)
    body = "  $frame  running  $sid  $(j.kind)  $(_job_script_disp(j))"
    return _clip_cols(body, cols)
end

function print_serve_live_line(
        frame::Char,
        j::Union{Nothing, Job},
        ids::AbstractVector{<:AbstractString} = String[];
        io::IO = stdout,
    )
    cols = cli_cols(io)
    s = _serve_live_text(frame, j, ids; cols = cols)
    print(io, '\r', s, "\e[K")
    flush(io)
    return nothing
end

function print_serve_idle_note(; io::IO = stdout)
    DistSSHKit.print_help_lines(io, _SERVE_CTRLC)
    return nothing
end

function print_serve_gone(store::AbstractString; io::IO = stdout)
    DistSSHKit.print_colored(io, "Stopping serve", :yellow, false)
    println(io)
    DistSSHKit.print_help_lines(
        io,
        "  store  $(_q_short(store)) (pidfile gone; removed or taken over)",
        "  A DistSSHKit job already running is not killed.",
    )
    return nothing
end

function print_serve_already(pid::Integer, store::AbstractString; io::IO = stdout)
    DistSSHKit.print_help_chrome("DistSSHQueue serve"; io = io)
    DistSSHKit.print_colored(io, "Already running", :cyan, false)
    println(io)
    DistSSHKit.print_help_lines(
        io,
        "  pid    $pid",
        "  store  $(_q_short(store))",
        "  Use status or watch. stop, then serve, to restart.",
    )
    return nothing
end

function print_serve_started(log::AbstractString; io::IO = stderr)
    DistSSHKit.print_colored(io, "Started serve", :cyan, false)
    println(io)
    DistSSHKit.print_help_lines(
        io,
        "  host  $(gethostname())",
        "  log   $(_q_short(log))",
    )
    return nothing
end

function print_serve_stopped(store::AbstractString, was_running::Bool; io::IO = stdout)
    DistSSHKit.print_colored(io, "Stopped serve", :yellow, false)
    println(io)
    DistSSHKit.print_help_lines(
        io,
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
function _enable_unit_path(; home::AbstractString = homedir())::Union{Nothing, String}
    paths = if Sys.isapple()
        (launch_agent_path(; home = home), legacy_launch_agent_path(; home = home))
    elseif Sys.islinux()
        (systemd_user_path(; home = home), legacy_systemd_user_path(; home = home))
    else
        return nothing
    end
    for p in paths
        isfile(p) && return p
    end
    return nothing
end

function _enable_disp(; home::AbstractString = homedir())::String
    p = _enable_unit_path(; home = home)
    p === nothing && return "none"
    return _q_short(p)
end

function _store_path_disp(
        store::AbstractString,
        present::Bool,
        qhost::Union{Nothing, AbstractString},
    )::String
    present || return "none"
    short = _q_short(store)
    if qhost === nothing || isempty(String(qhost))
        return short
    end
    return "$(String(qhost)):$short"
end

function _qhost_disp(qhost::Union{Nothing, AbstractString})::String
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
        io::IO = stdout,
    )
    nrun = count(j -> j.state === :running, rows)
    nq = count(j -> j.state === :queued, rows)
    println(io, "  serve $(_serve_disp(store))  running $nrun  queued $nq")
    flush(io)
    return nothing
end
