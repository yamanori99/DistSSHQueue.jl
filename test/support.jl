import DistSSHRun

# Seconds live here. DistSSHBase resolves the name and any environment override.
const WAIT_SECONDS = Dict{Symbol, Float64}(
    :child_reply => 300.0,
    :go_job => 120.0,
    :drive_job => 360.0,
    :stop_grace => 5.0,
    :sigint_grace => 20.0,
    :e2e_stop => 10.0,
)

function wait_seconds(name::Symbol)::Float64
    return DistSSHRun.DistSSHBase.wait_seconds(name, WAIT_SECONDS[name])
end

# Polls of `sleep_s` that fit in the named budget. A name with no finite
# budget (`:until_exit`) is not a poll.
function wait_tries(name::Symbol, sleep_s::Real)::Int
    seconds = wait_seconds(name)
    isfinite(seconds) || throw(ArgumentError("$name has no finite budget"))
    return max(1, round(Int, seconds / Float64(sleep_s)))
end

# Capture CLI stdio the way DistSSHKit tests do.
#
# `redirect_stdout` does not accept `IOBuffer`. Kit uses `mktemp`
# (`test/unit/DistSSHKit/main_dispatch.jl`). `stdout` is not a TTY, so help
# chrome stays plain and ANSI does not leak into `Pkg.test()` output.
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
    ENV["DISTSSHKIT_TEST"] = "1"
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

# Poll until `id` is terminal. `step!` runs only while that row is still
# `:queued`. Calling `step!` while it is `:running` can read a just-finished
# disk row and start the next queued job. The default `tries` is the e2e
# `:go_job` budget.
function drive_until_terminal!(q, id; tries::Integer = wait_tries(:go_job, 0.2), sleep_s::Real = 0.2)
    terminal = (:done, :failed, :cancelled)
    for _ in 1:tries
        st = job(q, id).state
        st in terminal && return st
        st === :queued && step!(q)
        sleep(sleep_s)
    end
    return job(q, id).state
end
