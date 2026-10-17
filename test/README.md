# Tests

How this repo tests DistSSHQueue. Maintainer checklist: [CONTRIBUTING.md](../CONTRIBUTING.md).

## Run

From the Queue checkout root:

```bash
julia --project=. -e 'using Pkg; Pkg.test()'
```

That is `test/runtests.jl` (unit + integration). Each included file prints `[i/N]` at start (update `_RUNTEST_N` when adding one). It tags autoserve `serve` pids and SIGTERMs them on exit or if `Pkg.test`'s parent dies, so Ctrl-C does not leave `nohup` `serve` on this machine. `Pkg.test()` on this checkout is not the PkgEval sandbox. Real `ssh` spawn runs only when that binary is on `PATH` (tests inject a fake `ssh` when they need `-G`); real SSH clusters stay in `e2e.jl`. Reproduce that sandbox: [PkgEval](#pkgeval). Real SSH:

```bash
testenv/docker-ssh/scripts/up.sh --e2e
```

Apple silicon without Compose: [`testenv/apple-container-ssh`](../testenv/apple-container-ssh) (`./scripts/up.sh --e2e`, not CI). JETLS is `./.github/jetls-check.sh`. Aqua is `./.github/aqua-check.sh` (not `Pkg.test()`; CI job `Aqua`). Documenter is `docs/make.jl` (CI deploys).

## Layout

```text
test/
  runtests.jl           # Pkg.test() — unit + integration
  e2e.jl                # real OpenSSH; not Pkg.test()
  support.jl
  unit/
  integration/          # child julia and/or local DistSSHKit workers
  Project.toml
```

## Layers

Green on one layer does not imply the others. `Pkg.test()` does not run `e2e.jl`.

| Layer | Proves | Not |
| --- | --- | --- |
| JETLS | types / hints on entry files | runtime |
| Aqua | ambiguities, exports, compat | CLI / workers |
| unit | in-process queue / config | child julia, SSH |
| integration | child CLI (`-m DistSSHQueue`) and **parent:1** | real SSH / rsync |
| e2e | docker-ssh workers, `serve` API, and `-m DistSSHQueue` (`qhost:` over loopback OpenSSH). Prints `[i/N]` at the start of each inner `@testset` (SSH can sit silent for minutes otherwise); update `_E2E_N` when adding a case | local-only CLI wiring |
| e2e weekly | same `e2e.jl` from Linux, macOS Intel, or WSL2 (not a PR check; Intel / WSL watchers). Register when the required checks are green | macOS workers |

`enable` / `disable` / `teardown` in SSH E2E use `--write-only` (no runner systemd / LaunchAgent). Coverage: `Pkg.test` max slot flag `pkgtest` on main push; `DISTSSHQUEUE_CODE_COVERAGE=1` on `up.sh --e2e` flag `e2e` (version-increase PRs and E2E weekly Linux).

`watch` is `status --interval` (TTY table, Ctrl-C). A pipe without `-q` is a compact serve/running/queued line; `-q` stays table-only. Finite frames in tests use `DISTSSHQUEUE_WATCH_TICKS` (not `--ticks`). A later monitor package may take the name `watch` ([#35](https://github.com/yamanori99/DistSSHQueue.jl/issues/35)).

## SSH E2E roles

The product path is three **roles**, not three CI jobs and not two kinds of docker worker.

| Role | In `e2e.jl` today | Not |
| --- | --- | --- |
| **client** | loopback OpenSSH (`qhost:distsshqueue-qh`) | a docker box |
| **qhost** | the machine that runs `--e2e` (`serve` + Kit controller) | a worker container |
| **child** | docker-ssh / Apple boxes (`child:child-1`, …) | the queue host |

Keep one `up.sh --e2e`. Do not split client↔qhost vs qhost↔child into two suites. Do not name a worker `qhost`. Kit child SSH stays DistSSHKit's E2E; Queue only needs `execute!` through `serve`.

`parent:1` in this suite occupies FIFO on the queue host. It is not a third worker topology.

SSH Host, container name, and hostname are `child-1` / `child-2`. Do not run beside DistSSHKit's workers (same names; Docker also shares ports `2222` / `2223`). Loopback client is `distsshqueue-qh`. Three physical hosts is dedicated-host smoke ([#46](https://github.com/yamanori99/DistSSHQueue.jl/issues/46)), not this file.

## PkgEval

[PkgEval](https://github.com/JuliaCI/PkgEval.jl) runs the daily ecosystem check. The sandbox is Debian bookworm without `tzdata`, with `LANG=C.UTF-8`, a pipe for stdout, and a 45 minute test limit. Daily uses the General tarball. This recipe mounts this checkout read-only, and dependencies resolve from General, so an unreleased DistSSHKit or DistSSHRun change is not in the sandbox. This package: [DistSSHQueue PkgEval](https://juliaci.github.io/NanosoldierReports/pkgeval_badges/D/DistSSHQueue.html). Latest ecosystem report: [NanosoldierReports](https://juliaci.github.io/NanosoldierReports/pkgeval_badges/report.html). Run it on Linux with cgroup v2 and unprivileged user namespaces, before a General cut. The host Julia is 1.12 or newer. The tested Julia is nightly. CI: `PkgEval (nightly, ubuntu-latest, x64)` on **main** and a `Project.toml` version increase (`continue-on-error`; not a required check). Not ordinary PRs.

From this checkout:

```bash
julia -e '
  using Pkg
  Pkg.activate(temp=true)
  Pkg.add("PkgEval")
  using PkgEval
  config = Configuration(; julia="nightly")
  pkg = Package(; name="DistSSHQueue", url="/package")
  result = PkgEval.evaluate_package(config, pkg; echo=true,
      mounts=Dict("/package:ro" => pwd()))
  exit(result.status == :test ? 0 : 1)
'
```
