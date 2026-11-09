category: fixed

- SSH E2E aligns the isolated example job's DistSSHRun lock with the `test` project and runs per-job `setup!` on loopback `qhost:` serve so staged rows get a ship snapshot id (Run #357 fail-closed). Fixes [#531](https://github.com/yamanori99/DistSSHQueue.jl/issues/531).
