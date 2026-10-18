# The command table is the dispatch. Help pages and the table stay the same set,
# plus the verbs that have no page (`size`, `plan`, `pool`, `service`).

using Test
using DistSSHQueue

@testset "command table" begin
    pages = Set(String.(DistSSHQueue.QUEUE_COMMAND_HELP))
    names = Set(keys(DistSSHQueue.QUEUE_COMMANDS))
    @test pages ⊆ names
    @test setdiff(names, pages) == Set(["size", "plan", "pool", "service"])
    status = DistSSHQueue.QUEUE_COMMANDS["status"]
    @test status.hop === :forward
    @test status.label_qhost
    @test status.watch_tty
    @test DistSSHQueue.QUEUE_COMMANDS["fetch"].hop === :own
    @test DistSSHQueue.QUEUE_COMMANDS["serve"].hop === :local
    @test DistSSHQueue.QUEUE_COMMANDS["teardown"].hop === :forward
end
