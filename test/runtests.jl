#!/usr/bin/env julia
# DistSSHQueue Pkg.test() entry: unit + integration.
# Does not include test/e2e.jl (real SSH; DISTSSHQUEUE_SSH_E2E=1 / up.sh --e2e).
# From a checkout of this directory as the active project:
#   julia --project=. -e 'using Pkg; Pkg.test()'
#
# Top-level `include`s (inside `@testset`s, not functions) so JETLS follows them.
# Each file already has a `@testset`; do not wrap another around `include`.
# Keep `include(joinpath(@__DIR__, …))` at this top level (JETLS). Only the
# banner is counted. Update `_RUNTEST_N` when adding a file below.

using Test
using DistSSHQueue

include(joinpath(@__DIR__, "support.jl"))
get!(ENV, DistSSHQueue.LOCAL_QUEUE_ENV, "1")
get!(ENV, DistSSHQueue.NO_KIT_SETUP_ENV, "1")
get!(ENV, DistSSHQueue.NO_STOP_BOOTOUT_ENV, "1")
install_serve_reaper!()

const _RUNTEST_N = 12
const _RUNTEST_I = Ref(0)
function _runtest_announce(rel::AbstractString)
    _RUNTEST_I[] += 1
    println("[$(_RUNTEST_I[])/$_RUNTEST_N]  $rel")
    flush(stdout)
    return nothing
end

@testset "DistSSHQueue" verbose = true begin
    @testset "unit" verbose = true begin
        _runtest_announce("unit/idle.jl")
        include(joinpath(@__DIR__, "unit", "idle.jl"))
        _runtest_announce("unit/queue.jl")
        include(joinpath(@__DIR__, "unit", "queue.jl"))
        _runtest_announce("unit/snapshot.jl")
        include(joinpath(@__DIR__, "unit", "snapshot.jl"))
        _runtest_announce("unit/config.jl")
        include(joinpath(@__DIR__, "unit", "config.jl"))
        _runtest_announce("unit/stage.jl")
        include(joinpath(@__DIR__, "unit", "stage.jl"))
        _runtest_announce("unit/fetch.jl")
        include(joinpath(@__DIR__, "unit", "fetch.jl"))
        _runtest_announce("unit/local_queue.jl")
        include(joinpath(@__DIR__, "unit", "local_queue.jl"))
        _runtest_announce("unit/commands.jl")
        include(joinpath(@__DIR__, "unit", "commands.jl"))
        _runtest_announce("unit/downstream_public.jl")
        include(joinpath(@__DIR__, "unit", "downstream_public.jl"))
        _runtest_announce("unit/e2e_distsshrun_lock.jl")
        include(joinpath(@__DIR__, "unit", "e2e_distsshrun_lock.jl"))
    end
    @testset "integration" verbose = true begin
        _runtest_announce("integration/cli.jl")
        include(joinpath(@__DIR__, "integration", "cli.jl"))
        _runtest_announce("integration/messages/progress_tty.jl")
        if !_queue_skip_pseudotty("integration/messages/progress_tty.jl")
            include(joinpath(@__DIR__, "integration", "messages", "progress_tty.jl"))
        end
    end
end
