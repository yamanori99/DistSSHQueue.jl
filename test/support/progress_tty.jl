# Queue-owned pseudo-TTY (`script`) helpers. Guard for JETLS include leaves.

if !isdefined(Main, :_queue_tty_strip_ansi)

    # Literals (not `const` inside this guard): JETLS analyzes the include leaf
    # and would otherwise report undef-global on default kwargs.
    _QUEUE_PSEUDOTTY_HANG_S() = 300.0
    _QUEUE_PSEUDOTTY_COLS() = 80
    _QUEUE_PSEUDOTTY_ROWS() = 24

    function _queue_tty_strip_ansi(s::AbstractString)
        return replace(String(s), r"\e\[[0-9;?]*[A-Za-z]" => "")
    end

    # Log-style view: each `\r` redraw becomes its own line.
    function _queue_tty_lines(s::AbstractString)
        return split(_queue_tty_strip_ansi(replace(String(s), "\r" => "\n")), '\n')
    end

    function _queue_tty_has_csi(s::AbstractString)::Bool
        return occursin('\e', String(s)) || occursin("\e[", String(s))
    end

    function _queue_tty_has_screen_clear(s::AbstractString)::Bool
        raw = String(s)
        return occursin("\e[H\e[J", raw) || occursin("\e[2J", raw) || occursin(r"\e\[[0-9]*J", raw)
    end

    function _queue_tty_spinner_char(line::AbstractString)::Bool
        return any(c -> occursin(c, line), "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏")
    end

    # Apply `\r`, erase-line, cursor-up, and screen-clear to model the visible buffer.
    # Returns the final screen text (lines joined by `\n`) after processing `raw`.
    # Later bars that print below a message stay; a cursor-up redraw can erase it.
    function _queue_tty_visible_screen(raw::AbstractString)::String
        lines = Ref(String[""])
        row = Ref(1)
        col = Ref(0)
        ensure_row! = function (r::Int)
            while length(lines[]) < r
                push!(lines[], "")
            end
            return nothing
        end
        write_ch! = function (ch::AbstractChar)
            ensure_row!(row[])
            s = lines[][row[]]
            if col[] >= length(s)
                lines[][row[]] = s * string(ch)
            else
                chars = collect(s)
                idx = col[] + 1
                if idx <= length(chars)
                    chars[idx] = ch
                    lines[][row[]] = String(join(chars))
                else
                    lines[][row[]] = s * string(ch)
                end
            end
            col[] += 1
            return nothing
        end
        erase_line! = function ()
            ensure_row!(row[])
            if col[] <= 0
                lines[][row[]] = ""
            else
                chars = collect(lines[][row[]])
                if col[] < length(chars)
                    lines[][row[]] = String(join(chars[1:col[]]))
                end
            end
            return nothing
        end
        i = firstindex(raw)
        while i <= lastindex(raw)
            ch = raw[i]
            if ch == '\r'
                col[] = 0
                i = nextind(raw, i)
            elseif ch == '\n'
                row[] += 1
                col[] = 0
                ensure_row!(row[])
                i = nextind(raw, i)
            elseif ch == '\e'
                j = nextind(raw, i)
                if j <= lastindex(raw) && raw[j] == '['
                    k = nextind(raw, j)
                    while k <= lastindex(raw) && !isletter(raw[k])
                        k = nextind(raw, k)
                    end
                    k <= lastindex(raw) || break
                    params = SubString(raw, nextind(raw, j), prevind(raw, k))
                    final = raw[k]
                    if final == 'K'
                        erase_line!()
                    elseif final == 'H'
                        parts = split(params, ';'; keepempty = false)
                        if isempty(parts)
                            row[] = 1
                            col[] = 0
                        elseif length(parts) == 1
                            r = tryparse(Int, parts[1])
                            row[] = something(r, 1)
                            col[] = 0
                        else
                            r = tryparse(Int, parts[1])
                            c = tryparse(Int, parts[2])
                            row[] = something(r, 1)
                            col[] = max(0, something(c, 1) - 1)
                        end
                        ensure_row!(row[])
                    elseif final == 'J'
                        mode = isempty(params) ? 0 : something(tryparse(Int, params), 0)
                        if mode == 2 || (mode == 0 && row[] == 1 && col[] == 0)
                            lines[] = String[""]
                            row[] = 1
                            col[] = 0
                        elseif mode == 0
                            ensure_row!(row[])
                            chars = collect(lines[][row[]])
                            lines[][row[]] =
                                col[] <= 0 ? "" : String(join(chars[1:min(col[], length(chars))]))
                            resize!(lines[], row[])
                        end
                    elseif final == 'A'
                        n = isempty(params) ? 1 : something(tryparse(Int, params), 1)
                        row[] = max(1, row[] - n)
                        ensure_row!(row[])
                    elseif final == 'B'
                        n = isempty(params) ? 1 : something(tryparse(Int, params), 1)
                        row[] += n
                        ensure_row!(row[])
                    end
                    i = nextind(raw, k)
                else
                    i = j
                end
            else
                write_ch!(ch)
                i = nextind(raw, i)
            end
        end
        return join(lines[], "\n")
    end

    # True when `needle` remains on the modeled screen after `raw` finishes.
    function _queue_tty_message_visible(raw::AbstractString, needle::AbstractString)::Bool
        return occursin(String(needle), _queue_tty_strip_ansi(_queue_tty_visible_screen(raw)))
    end

    # True when a cursor-up sequence appears after the last occurrence of `needle`.
    function _queue_tty_cursor_up_after(raw::AbstractString, needle::AbstractString)::Bool
        at = findlast(String(needle), String(raw))
        at === nothing && return false
        after = SubString(String(raw), nextind(String(raw), last(at)))
        return occursin(r"\e\[[0-9]*A", after)
    end

    function _queue_pty_tool_status()::Tuple{Bool, String}
        Sys.iswindows() && return false, "Windows has no script(1) pseudo-TTY path used by this suite"
        path = Sys.which("script")
        path === nothing && return false, "script(1) is required for pseudo-TTY tests on $(Sys.KERNEL)"
        return true, path
    end

    function _queue_require_pty_tool!()
        ok, detail = _queue_pty_tool_status()
        ok && return detail
        # Supported CI platforms (macOS / Linux / WSL) ship script(1). Do not skip.
        error("pseudo-TTY suite cannot run: $detail")
    end

    function _queue_sh_quote(s::AbstractString)::String
        return "'" * replace(String(s), "'" => "'\\''") * "'"
    end

    function _queue_argv_line(cmd::Cmd)::String
        return join(_queue_sh_quote.(String.(cmd.exec)), " ")
    end

    function _queue_cli_project()::String
        p = Base.active_project()
        return p === nothing ? dirname(@__DIR__) : dirname(p)
    end

    function _queue_julia_exe()::String
        return joinpath(Sys.BINDIR, Base.julia_exename())
    end

    function _queue_cli_cmd(args::AbstractVector{<:AbstractString})::Cmd
        proj = _queue_cli_project()
        julia = _queue_julia_exe()
        argv = String[String(a) for a in args]
        return `$julia --startup-file=no --project=$proj -m DistSSHQueue $argv`
    end

    # ENV for a pseudo-TTY or pipe child. Does not mutate the parent process ENV.
    # Unsets NO_COLOR and Kit verbosity vars so a TTY child gets the product
    # default (`:progress`). Sets TERM and fixed COLUMNS/LINES; runners also
    # `stty` the PTY for `displaysize`.
    function _queue_child_env(extra::AbstractDict = Dict{String, String}())
        drop = Set(
            (
                "NO_COLOR",
                "DISTSSH_QUIET",
                "DISTSSH_PROGRESS",
                "DISTSSH_VERBOSE",
                "JULIA_LOAD_PATH",
                "JULIA_PROJECT",
                "DISTSSH_CLI_SUBCOMMAND_DONE",
                "DIST_SSH_KIT_CLI_INCLUDE",
                "COLUMNS",
                "LINES",
            )
        )
        env = Dict{String, String}(
            String(k) => String(v) for (k, v) in ENV if !isempty(v) && !(String(k) in drop)
        )
        env["TERM"] = "xterm-256color"
        env["COLUMNS"] = string(_QUEUE_PSEUDOTTY_COLS())
        env["LINES"] = string(_QUEUE_PSEUDOTTY_ROWS())
        env["JULIA_LOAD_PATH"] = Sys.iswindows() ? "@;@stdlib" : "@:@stdlib"
        env["JULIA_PKG_PRECOMPILE_AUTO"] = get(ENV, "JULIA_PKG_PRECOMPILE_AUTO", "0")
        env["DISTSSHQUEUE_NO_AUTOSERVE"] = "1"
        env["DISTSSH_TEST"] = "1"
        for (k, v) in extra
            env[String(k)] = String(v)
        end
        return env
    end

    # Linux util-linux: `-f` flushes the typescript while the child runs
    # (serve polls the file before exit). `-e` / `--return` is the inner
    # command status. Apple/BSD: `-t 0` flushes each character; there is no
    # `-e`. Do not signal PIDs outside this detached process group.
    function _queue_script_cmd(script_path::AbstractString, dest::AbstractString)::Cmd
        return if Sys.isapple()
            `script -q -t 0 $dest /bin/sh $script_path`
        else
            `script -q -f -e -c $script_path $dest`
        end
    end

    function _queue_kill_capture_tree!(proc::Base.Process; sig = Base.SIGTERM)
        process_running(proc) || return nothing
        pid = Int(getpid(proc))
        if Sys.isunix()
            ccall(:kill, Cint, (Cint, Cint), Cint(-pid), sig)
            timedwait(() -> !process_running(proc), 5.0; pollint = 0.2)
            if process_running(proc)
                ccall(:kill, Cint, (Cint, Cint), Cint(-pid), Base.SIGKILL)
                timedwait(() -> !process_running(proc), 5.0; pollint = 0.2)
            end
        else
            kill(proc, sig)
            timedwait(() -> !process_running(proc), 5.0; pollint = 0.2)
            process_running(proc) && kill(proc, Base.SIGKILL)
            timedwait(() -> !process_running(proc), 5.0; pollint = 0.2)
        end
        process_running(proc) || try
            wait(proc)
        catch
        end
        return nothing
    end

    function _queue_start_script(
            script_path::AbstractString,
            dest::AbstractString;
            env::AbstractDict = _queue_child_env(),
        )::Base.Process
        _queue_require_pty_tool!()
        rm(dest; force = true)
        cmd = _queue_script_cmd(script_path, dest)
        launched = Cmd(setenv(cmd, env); detach = true)
        return run(ignorestatus(launched); wait = false)::Base.Process
    end

    # Run `script_path` under `script(1)`. Returns `(raw, elapsed, exitcode)`.
    # `exitcode` is the wrapper status (`-e` on Linux). Hang cleanup is the
    # detached process group only. Elapsed time is diagnostic, not a gate.
    function _queue_pty_capture(
            script_path::AbstractString,
            dest::AbstractString;
            hang_s::Real = 300.0,
            env::AbstractDict = _queue_child_env(),
        )::NamedTuple{(:raw, :elapsed, :exitcode), Tuple{String, Float64, Int}}
        hang = Float64(hang_s)
        t0 = time()
        proc = _queue_start_script(script_path, dest; env = env)
        timed_out = false
        try
            done = timedwait(() -> !process_running(proc), hang; pollint = 0.5)
            if done !== :ok
                timed_out = true
                _queue_kill_capture_tree!(proc; sig = Base.SIGTERM)
                error("pseudo-TTY script exceeded $(hang)s (wrapper still running)")
            end
            wait(proc)
            elapsed = time() - t0
            raw = isfile(dest) ? read(dest, String) : ""
            return (raw = raw, elapsed = elapsed, exitcode = Int(proc.exitcode))
        finally
            if process_running(proc)
                _queue_kill_capture_tree!(proc; sig = Base.SIGKILL)
            elseif timed_out
                try
                    wait(proc)
                catch
                end
            end
        end
    end

    function _queue_pipe_capture(
            cmd::Cmd;
            env::AbstractDict = _queue_child_env(),
            hang_s::Real = 300.0,
        )::NamedTuple{(:stdout, :stderr, :elapsed, :exitcode), Tuple{String, String, Float64, Int}}
        out = IOBuffer()
        err = IOBuffer()
        t0 = time()
        # Not detached: `kill(-pid)` would be this test process group.
        proc = run(ignorestatus(setenv(cmd, env)), devnull, out, err; wait = false)
        timed_out = false
        try
            done = timedwait(() -> !process_running(proc), Float64(hang_s); pollint = 0.5)
            if done !== :ok
                timed_out = true
                process_running(proc) && kill(proc, Base.SIGTERM)
                timedwait(() -> !process_running(proc), 5.0; pollint = 0.2)
                process_running(proc) && kill(proc, Base.SIGKILL)
                timedwait(() -> !process_running(proc), 5.0; pollint = 0.2)
                error("pipe child exceeded $(hang_s)s")
            end
            wait(proc)
            elapsed = time() - t0
            return (
                stdout = String(take!(out)),
                stderr = String(take!(err)),
                elapsed = elapsed,
                exitcode = Int(proc.exitcode),
            )
        finally
            if process_running(proc)
                kill(proc, Base.SIGKILL)
                timedwait(() -> !process_running(proc), 5.0; pollint = 0.2)
            elseif timed_out
                try
                    wait(proc)
                catch
                end
            end
        end
    end

    # Body and optional `___EC:N___` marker from one shared-script section.
    function _queue_section_exit(part::AbstractString)::Tuple{String, Union{Nothing, Int}}
        s = String(part)
        m = match(r"___EC:(-?\d+)___", s)
        m === nothing && return s, nothing
        body = s[1:(m.offset - 1)]
        cap = m.captures[1]
        cap === nothing && return body, nothing
        return body, parse(Int, cap)
    end

    # Host failure on the same stripped line (`fail` / `✗` / Permission denied).
    function _queue_host_fail_line(line::AbstractString, host::AbstractString)::Bool
        s = String(line)
        occursin(String(host), s) || return false
        return occursin("fail", s) || occursin("✗", s) ||
            occursin("Permission denied", s) || occursin("publickey", s)
    end

    function _queue_stty_prefix()::String
        return "stty cols $(_QUEUE_PSEUDOTTY_COLS()) rows $(_QUEUE_PSEUDOTTY_ROWS()) 2>/dev/null || true\n"
    end

    # Skip only the pseudo-TTY suite under PkgEval or an explicit Registry opt-out.
    function _queue_skip_pseudotty(rel::AbstractString)::Bool
        flag = lowercase(strip(get(ENV, "DISTSSHQUEUE_SKIP_PSEUDOTTY", "")))
        if flag in ("1", "true", "yes", "on")
            println("  skip $rel (DISTSSHQUEUE_SKIP_PSEUDOTTY)")
            flush(stdout)
            return true
        end
        if strip(get(ENV, "JULIA_PKGEVAL", "")) == "true"
            println("  skip $rel (JULIA_PKGEVAL)")
            flush(stdout)
            return true
        end
        return false
    end

end
