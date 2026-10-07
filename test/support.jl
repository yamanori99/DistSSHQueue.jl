# Capture CLI stdio the way DistSSHKit tests do.
#
# `redirect_stdout` does not accept `IOBuffer`. Kit uses `mktemp`
# (`test/unit/DistSSHKit/main_dispatch.jl`). Redirecting also makes
# `DistSSHQueue.use_colors()` false (`stdout isa TTY`), so ANSI does not leak
# into `Pkg.test()` output.
function capture_stdio(f)
    return mktemp() do out_path, out_io
        mktemp() do err_path, err_io
            value = redirect_stdout(out_io) do
                redirect_stderr(err_io) do
                    f()
                end
            end
            flush(out_io)
            flush(err_io)
            return value, read(out_path, String), read(err_path, String)
        end
    end
end

# True if `status` / `watch` chrome shows this job (unique prefix, not the full UUID).
function status_shows_id(text::AbstractString, id::AbstractString)::Bool
    return occursin(first(String(id), 8), text)
end

# Status wraps a long hostname at 72 columns. Compare the text with whitespace removed.
function shows_flat(text::AbstractString, needle::AbstractString)::Bool
    flat(s) = replace(String(s), r"\s+" => "")
    return occursin(flat(needle), flat(text))
end

# list-host clips NAME. The first 12 characters stay visible at the 72-column width.
function shows_hostname_prefix(text::AbstractString)::Bool
    hn = gethostname()
    n = min(12, length(hn))
    return n == 0 || occursin(first(hn, n), text)
end

# Tag autoserve `serve` for this Pkg.test process. nohup outlives submit
# (product); atexit / parent-death SIGTERM must still find them.
function install_serve_reaper!()
    Sys.iswindows() && return nothing
    tag = "distsshqueue-$(getpid())-$(time_ns())"
    ENV["DISTSSHQUEUE_SERVE_TAG"] = tag
    pids = tempname()
    ENV["DISTSSHQUEUE_TEST_PIDS"] = pids
    write(pids, "")
    reaped = Ref(false)
    function reap()
        reaped[] && return nothing
        reaped[] = true
        DistSSHQueue.reap_serve_tag!(tag)
        return nothing
    end
    atexit(reap)
    @async begin
        had_parent = false
        try
            while true
                pp = ccall(:getppid, Cint, ())
                if pp != 1
                    had_parent = true
                elseif had_parent
                    reap()
                    exit(1)
                end
                sleep(0.5)
            end
        catch
        end
    end
    return nothing
end
