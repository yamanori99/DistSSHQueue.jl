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

# How often a child wait samples CPU time and output size.
const CHILD_POLL_S = 0.2

# A short poll can add one tick. The rate uses a fixed window of this much
# wall time, so that tick is not progress. `IDLE_MIN_RATE` is CPU seconds per
# wall second over that window, not over the whole quiet stretch.
const IDLE_MIN_WINDOW_S = 10.0
const IDLE_MIN_RATE = 0.05

# One child wait. `seconds` is how long the child may stay under `min_rate`
# with no output growth. CPU rate is judged on a fixed window of `min_window`.
# A long quiet stretch does not raise that bar, so a compile that starts late
# is still progress at the next window boundary. The first CPU sample in a
# window is a baseline. Output growth moves `idle_since` only. `nothing` CPU
# for the whole wait is the wall clock; output does not extend that wall. A
# full-CPU spin is not cut here.
mutable struct IdleWatch
    seconds::Float64
    min_window::Float64
    min_rate::Float64
    started::Float64
    idle_since::Float64
    rate_t::Float64
    rate_cpu::Union{Nothing, Float64}
    last_output::Int
end

function IdleWatch(
        seconds::Real;
        now::Real = time(),
        min_window::Real = IDLE_MIN_WINDOW_S,
        min_rate::Real = IDLE_MIN_RATE,
    )
    t = Float64(now)
    return IdleWatch(
        Float64(seconds),
        Float64(min_window),
        Float64(min_rate),
        t,
        t,
        t,
        nothing,
        0,
    )
end

# `:busy` keeps waiting. `:idle` means CPU time stayed under `min_rate` and
# output did not grow. `:wall` means CPU time could not be read and the wall
# clock ran out.
function observe_progress!(
        w::IdleWatch;
        cpu::Union{Nothing, Real},
        output::Integer,
        now::Float64,
    )::Symbol
    cpu_s = cpu === nothing ? nothing : Float64(cpu)
    rate_cpu = w.rate_cpu
    if rate_cpu === nothing && cpu_s === nothing
        return now - w.started >= w.seconds ? :wall : :busy
    end
    out = Int(output)
    output_grew = out > w.last_output
    if output_grew
        w.last_output = out
    end
    cpu_progress = false
    if cpu_s !== nothing
        if rate_cpu === nothing
            w.rate_t = now
            w.rate_cpu = cpu_s
        elseif now - w.rate_t >= w.min_window
            elapsed = now - w.rate_t
            cpu_progress = cpu_s - rate_cpu >= w.min_rate * elapsed
            w.rate_t = now
            w.rate_cpu = cpu_s
        end
    end
    if cpu_progress || output_grew
        w.idle_since = now
        return :busy
    end
    return now - w.idle_since >= w.seconds ? :idle : :busy
end

# utime + stime from a Linux `/proc/<pid>/stat` line. `comm` may contain spaces.
# This is the process itself, not a child it has spawned.
function proc_stat_cpu_ticks(text::AbstractString)::Union{Nothing, Int}
    close_at = findlast(==(')'), text)
    close_at === nothing && return nothing
    fields = split(chop(text[close_at:end]; head = 1, tail = 0))
    length(fields) < 13 && return nothing
    utime = tryparse(Int, fields[12])
    stime = tryparse(Int, fields[13])
    utime === nothing && return nothing
    stime === nothing && return nothing
    return utime + stime
end

# `ps -o time=` on macOS. Accepts `m:ss`, `m:ss.ss`, `h:mm:ss`, and `d-hh:mm:ss`.
# The unit is centiseconds. The idle watch converts that to seconds.
function ps_time_centiseconds(text::AbstractString)::Union{Nothing, Int}
    s = strip(text)
    isempty(s) && return nothing
    days = 0
    body = s
    if occursin('-', s)
        day_text, body = split(s, '-'; limit = 2)
        parsed_days = tryparse(Int, day_text)
        parsed_days === nothing && return nothing
        days = parsed_days
    end
    parts = split(body, ':')
    1 <= length(parts) <= 3 || return nothing
    nums = Float64[]
    for part in parts
        n = tryparse(Float64, part)
        n === nothing && return nothing
        push!(nums, n)
    end
    while length(nums) < 3
        pushfirst!(nums, 0.0)
    end
    hours, minutes, secs = nums
    total = days * 86400 + hours * 3600 + minutes * 60 + secs
    total < 0 && return nothing
    return round(Int, total * 100)
end

function linux_cpu_ticks(pid::Integer)::Union{Nothing, Int}
    path = "/proc/$(Int(pid))/stat"
    isfile(path) || return nothing
    text = try
        read(path, String)
    catch
        return nothing
    end
    return proc_stat_cpu_ticks(text)
end

function apple_cpu_ticks(pid::Integer)::Union{Nothing, Int}
    text = try
        read(`ps -o time= -p $(Int(pid))`, String)
    catch
        return nothing
    end
    return ps_time_centiseconds(text)
end

function process_cpu_ticks(pid::Integer)::Union{Nothing, Int}
    if Sys.islinux()
        return linux_cpu_ticks(pid)
    elseif Sys.isapple()
        return apple_cpu_ticks(pid)
    else
        return nothing
    end
end

function process_cpu_ticks(proc::Base.Process)::Union{Nothing, Int}
    process_running(proc) || return nothing
    pid = try
        getpid(proc)
    catch
        return nothing
    end
    return process_cpu_ticks(pid)
end

const _CLK_TCK = Ref(0)

function clock_ticks_per_second()::Int
    _CLK_TCK[] > 0 && return _CLK_TCK[]
    text = try
        read(`getconf CLK_TCK`, String)
    catch
        _CLK_TCK[] = 100
        return _CLK_TCK[]
    end
    n = tryparse(Int, strip(text))
    _CLK_TCK[] = n === nothing || n <= 0 ? 100 : n
    return _CLK_TCK[]
end

# Linux ticks are `CLK_TCK` per CPU second. macOS `ps` values are centiseconds.
function cpu_time_seconds(ticks::Integer)::Float64
    denom = Sys.islinux() ? Float64(clock_ticks_per_second()) : 100.0
    return Float64(ticks) / denom
end

function process_cpu_seconds(pid::Integer)::Union{Nothing, Float64}
    ticks = process_cpu_ticks(pid)
    ticks === nothing && return nothing
    return cpu_time_seconds(ticks)
end

function process_cpu_seconds(proc::Base.Process)::Union{Nothing, Float64}
    ticks = process_cpu_ticks(proc)
    ticks === nothing && return nothing
    return cpu_time_seconds(ticks)
end

# Per-pid highs in clock ticks (Linux) or centiseconds (macOS). The sum is
# converted to seconds once, the same unit as `process_cpu_seconds`. A child
# that exits keeps its last sample, so the total does not fall and the sibling
# can still show progress.
function monotonic_group_cpu!(
        last::Dict{Int, Int},
        procs::Vector{Base.Process},
    )::Union{Nothing, Float64}
    for proc in procs
        process_running(proc) || continue
        pid = try
            getpid(proc)
        catch
            return nothing
        end
        ticks = process_cpu_ticks(pid)
        ticks === nothing && return nothing
        prev = get(last, pid, 0)
        if ticks > prev
            last[pid] = ticks
        end
    end
    return isempty(last) ? 0.0 : cpu_time_seconds(sum(values(last)))
end

# `:exited` when every process has exited. `:idle` or `:wall` when the watch says so.
function wait_while_progressing(
        output_bytes::Function,
        procs::Vector{Base.Process};
        seconds::Real,
    )::Symbol
    watch = IdleWatch(seconds)
    seen = Dict{Int, Int}()
    while any(process_running, procs)
        mark = observe_progress!(
            watch;
            cpu = monotonic_group_cpu!(seen, procs),
            output = output_bytes(),
            now = time(),
        )
        mark === :busy || return mark
        sleep(CHILD_POLL_S)
    end
    return :exited
end

function wait_while_progressing(
        output_bytes::Function,
        proc::Base.Process;
        seconds::Real,
    )::Symbol
    return wait_while_progressing(output_bytes, Base.Process[proc]; seconds)
end

# SIGTERM, then SIGKILL after `:stop_grace` if the child is still running.
function terminate_child!(proc::Base.Process)
    if process_running(proc)
        try
            kill(proc)
        catch
        end
        deadline = time() + wait_seconds(:stop_grace)
        while process_running(proc) && time() < deadline
            sleep(0.05)
        end
        if process_running(proc)
            try
                kill(proc, Base.SIGKILL)
            catch
            end
        end
    end
    wait(proc)
    return nothing
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

const _REGISTRY_RUN_PROJECT = Ref{Union{Nothing, String}}(nothing)

# Detached `execute!` runs `julia -m` with `--project=` set to the job tree.
# Run #236 removes the fallback to serve's project, so empty `[deps]` cannot
# load DistSSHRun. `go` rejects an absolute `[sources]` path, so a developed
# checkout is not a job tree. Resolve the registry package once (0.1 floor,
# same as this test env) and copy that Project.toml and Manifest.
function copy_registry_distsshrun_project!(dir::AbstractString)
    src = _registry_run_project()
    mkpath(dir)
    for name in readdir(src)
        keep = name == "Project.toml" || (startswith(name, "Manifest") && endswith(name, ".toml"))
        keep || continue
        cp(joinpath(src, name), joinpath(dir, name); force = true)
    end
    isfile(joinpath(dir, "Project.toml")) || error("registry DistSSHRun project has no Project.toml")
    any(name -> startswith(name, "Manifest") && endswith(name, ".toml"), readdir(dir)) ||
        error("registry DistSSHRun project has no Manifest")
    return nothing
end

# The test project does not depend on Pkg. DistSSHQueue already loaded it.
function _loaded_pkg()::Module
    for (id, mod) in Base.loaded_modules
        id.name == "Pkg" && return mod
    end
    error("Pkg is not loaded")
end

function _registry_run_project()::String
    cached = _REGISTRY_RUN_PROJECT[]
    cached === nothing || return cached
    pkg = _loaded_pkg()
    dir = mktempdir(; prefix = "distsshqueue-run-project-")
    prev = Base.active_project()
    try
        pkg.activate(dir)
        pkg.add(pkg.PackageSpec(; name = "DistSSHRun", version = "0.1.14"))
    finally
        if prev === nothing
            pkg.activate()
        else
            pkg.activate(dirname(prev))
        end
    end
    _REGISTRY_RUN_PROJECT[] = dir
    return dir
end
