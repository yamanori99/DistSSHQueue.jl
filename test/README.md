# Tests

How this repo tests DistSSHQueue. Maintainer checklist: [CONTRIBUTING.md](../CONTRIBUTING.md).

## Run

From the Queue checkout root:

```bash
julia --project=. -e 'using Pkg; Pkg.test()'
```

That is `test/runtests.jl` (unit + integration). Each included file prints `[i/N]` at start (update `_RUNTEST_N` when adding one). It tags autoserve `serve` pids and SIGTERMs them on exit or if `Pkg.test`'s parent dies, so Ctrl-C does not leave `nohup` `serve` on the laptop. `Pkg.test()` must pass on a Registry install (no Queue `Manifest.toml`, often mode 444): real `ssh` spawn runs only when that binary is on `PATH` (tests inject a fake `ssh` when they need `-G`); real SSH clusters stay in `e2e.jl`. Occasional copy recipe: [Registry tree](#registry-tree). Real SSH:

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
| e2e weekly | same `e2e.jl` from Linux, macOS Intel, or WSL2 (not a PR check; Intel / WSL watchers). Register from cut PR Linux E2E | macOS workers |

`enable` / `disable` / `teardown` in SSH E2E use `--write-only` (no runner systemd / LaunchAgent). Coverage: `Pkg.test` max slot flag `pkgtest` on main push; `DISTSSHQUEUE_CODE_COVERAGE=1` on `up.sh --e2e` flag `e2e` (cut PRs and E2E weekly Linux).

`watch` is `status --interval` (TTY table, Ctrl-C). A pipe without `-q` is a compact serve/running/queued line; `-q` stays table-only. Finite frames in tests use `DISTSSHQUEUE_WATCH_TICKS` (not `--ticks`). A later monitor package may take the name `watch` ([#35](https://github.com/yamanori99/DistSSHQueue.jl/issues/35)).

## SSH E2E roles

The product path is three **roles**, not three CI jobs and not two kinds of docker worker.

| Role | In `e2e.jl` today | Not |
| --- | --- | --- |
| **client** | loopback OpenSSH (`qhost:distsshqueue-qh`) | a docker box |
| **qhost** | the machine that runs `--e2e` (`serve` + Kit controller) | a worker container |
| **child** | docker-ssh / Apple boxes (`child:distsshqueue-w1`, …) | the queue host |

Keep one `up.sh --e2e`. Do not split client↔qhost vs qhost↔child into two suites. Do not name a worker `qhost`. Kit child SSH stays DistSSHKit's E2E; Queue only needs `execute!` through `serve`.

`parent:1` in this suite occupies FIFO on the queue host. It is not a third worker topology.

SSH Host `distsshqueue-w1` / `distsshqueue-w2` is not Compose/DNS `child-1` / `child-2` (so Kit's stack can coexist). Loopback client is `distsshqueue-qh`. Three physical hosts is dedicated-host smoke ([#46](https://github.com/yamanori99/DistSSHQueue.jl/issues/46)), not this file.

## Registry tree

[PkgEval](https://github.com/JuliaCI/PkgEval.jl) (via [Nanosoldier](https://github.com/JuliaCI/Nanosoldier.jl)) and `Pkg.add` use a Registry tarball, not this checkout. This package: [DistSSHQueue PkgEval](https://juliaci.github.io/NanosoldierReports/pkgeval_badges/D/DistSSHQueue.html). Latest ecosystem report: [NanosoldierReports](https://juliaci.github.io/NanosoldierReports/pkgeval_badges/report.html). Reproduce that tree: copy without Queue `.git` / `Manifest.toml`, `Pkg.add` from a **bare** `file://` git (installed `pkgdir` has no `.git`), `chmod a-w` on `pkgdir`, then `Pkg.test`. DistSSHKit **0.7.x** comes from General in that env. Child CLI tests use the Pkg.test project, not `pkgdir`. Do this after changing those gates, and before a General cut. CI: `Pkg.test - registry tree` on **main** and **cut** (slot tip, no `ssh`; not a required check). Not ordinary PRs.

Copy without `Manifest.toml` (and without `.git`). On Linux, `mktemp -d` is enough. On macOS, put the copy under `$HOME`.

```bash
WORKDIR=$(mktemp -d "$HOME/distsshqueue.XXXXXX")
rsync -a \
  --exclude .git \
  --exclude Manifest.toml \
  --exclude docs/Manifest.toml \
  --exclude docs/build \
  --exclude test/artifacts \
  ./ "$WORKDIR/"
```

This machine (min / max / `+nightly`). Distro `ssh` / `git` stay on `PATH`. On Linux this is enough for the tree; it does not reproduce a missing `ssh`. Do not `git init` inside the copy. Use a bare repo, then `Pkg.add(; url=)`.

```bash
BARE=$(mktemp -d "$HOME/distsshqueue.git.XXXXXX")
git init --bare -q "$BARE"
git --git-dir="$BARE" --work-tree="$WORKDIR" add -A
git --git-dir="$BARE" --work-tree="$WORKDIR" \
  -c user.email=ci@distsshqueue -c user.name=ci commit -q -m tree
julia -e 'using Pkg; Pkg.activate(temp=true); Pkg.add(; url=ARGS[1]); using DistSSHQueue; run(Cmd(["chmod", "-R", "a-w", pkgdir(DistSSHQueue)])); Pkg.test("DistSSHQueue")' "file://$BARE"
```

Linux without `ssh`: CI removes `openssh-client` on the registry-tree job. Locally, prepend a fake `ssh` only inside tests that need `-G`; do not rely on the distro client.
