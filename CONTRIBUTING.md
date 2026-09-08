# Contributing

Internals of this repo.

- Users: [stable docs](https://yamanori99.github.io/DistSSHQueue.jl/stable/) (`docs/`), [README.md](README.md), [README.ja.md](README.ja.md), [NEWS.md](NEWS.md)
- Dev docs: [dev](https://yamanori99.github.io/DistSSHQueue.jl/dev/) ([docs/README.md](docs/README.md))

This is a **separate** package from DistSSHKit: FIFO `serve` in front of one Kit `go` / `ride` / `drive`, not a bigger Kit. Placement tokens, `execute!`, `kit.pid` / `kit.result`, `terminate_run!`, demo argv, and rsync/collect are Kit's. Queue records table state and the path Kit already wrote.

Julia slots match Kit (`min` / `max` / `tip` in `.github/julia-slots.env`). SSH E2E is this repo's `testenv/docker-ssh` (Kit-shaped workers). CI is `Pkg.test` (unit + child CLI / `parent:1`), JETLS, Aqua, Linux SSH E2E on slot **max** (`test/e2e.jl`: `serve` API, queue-host CLI, `qhost:` over loopback OpenSSH) on path-filtered PRs / **main** / `cut` / weekly / dispatch, Gitleaks, schedule-only **E2E weekly** (Linux / macOS Intel / WSL), and schedule-only **CI weekly**.

## Requirements

macOS, Linux, or WSL2 Ubuntu. Not native Windows (the kit shells out to `ssh` / `rsync`).

| What | Need |
| --- | --- |
| Library, `Pkg.test()`, `julia -m DistSSHQueue`, docs | Julia **1.12+** |
| DistSSHKit | **0.7.x** from General (`execute!`, `job_id`, `kit.pid` / `kit.result`). Not a git sibling. |

Prefer [juliaup](https://github.com/JuliaLang/juliaup). Details: [Requirements](https://yamanori99.github.io/DistSSHQueue.jl/dev/requirements/).

## Setup

```bash
git clone https://github.com/yamanori99/DistSSHQueue.jl.git
cd DistSSHQueue.jl
julia --project=. -e 'using Pkg; Pkg.instantiate()'
```

That pulls DistSSHKit from General. Do not add a `[sources]` path to a Kit checkout unless you are landing an unreleased kit hook.

From another app (a **separate** env, not a job whose Manifest is copied to workers):

```bash
julia --project=/path/to/QueueDevEnv.jl -e 'using Pkg; Pkg.develop(path="/path/to/DistSSHQueue.jl")'
```

Do not `Pkg.develop` Queue or Kit from a project you actually run
distributed jobs from — the Manifest records an absolute path the
workers do not have. Keep a separate environment for package work.

## Test

```bash
julia --project=. -e 'using Pkg; Pkg.test()'
```

Run this on slot **min** and **max** (and **tip** if you have nightly). Layout: [test/README.md](test/README.md). When adding a file under `test/runtests.jl` or an inner SSH E2E `@testset`, bump `_RUNTEST_N` / `_E2E_N` so `[i/N]` stays honest.

Checkout `Pkg.test()` is not a Registry tarball. After changing those gates (child CLI project, `ssh` spawn), and before a General cut, run the disposable copy in [test/README.md](test/README.md#registry-tree). CI runs that shape on **main** and **cut** (slot tip; not a required check).

```bash
./.github/jetls-check.sh    # hint+; same files as CI
./.github/aqua-check.sh     # latest registry Aqua; not part of Pkg.test()
./testenv/docker-ssh/scripts/up.sh --e2e
julia --project=docs -e 'using Pkg; Pkg.instantiate()'
julia --project=docs --color=yes docs/make.jl
julia --project=docs/src/assets/logo -e 'using Pkg; Pkg.instantiate()'
julia --project=docs/src/assets/logo docs/src/assets/logo/draw.jl   # SVG; add --png for rasters
gitleaks detect --source .
```

JETLS CI uses [`.github/actions/jetls-check`](.github/actions/jetls-check/action.yml) (installs `JETLS.jl` `@release` after `julia-actions/cache`). After a bump, re-read [cli-check](https://aviatesk.github.io/JETLS.jl/dev/cli-check/) and keep failing on hint+.

JETLS is the type gate. Do not commit `.vscode/settings.json` to silence the Language Server.

[Fatou](https://fatou.dev) is local only. Do not add `fatou.toml` or Fatou to `.vscode/extensions.json`. After a Fatou bump, check it did not rewrite files you did not mean to touch.

### Julia slots

Exactly three pins, in [`.github/julia-slots.env`](.github/julia-slots.env). Do not add a fourth version job. Slide the pin; keep job names `min` / `max` / `tip`.

| Slot | Role | Required |
| --- | --- | --- |
| **min** | `Project.toml` julia floor. Pkg.test (no coverage), Aqua, JETLS, Documenter | yes |
| **max** | Newest tagged or prerelease (`versions.json`). Pkg.test, Aqua, **main** / weekly / `cut` E2E, GHCR worker. Codecov `pkgtest` on **main push** only | yes |
| **tip** | Next-minor nightly. Pkg.test, Aqua. `continue-on-error` | no |

JETLS is min plus `JULIA_SLOT_JETLS_MAX` (job name still `JETLS - max`). That pin lags when `max` / `tip` move past what JETLS lists (today 1.12.2–1.13). Raise it only after JETLS supports that runtime. No JETLS **tip**.

When a new RC lands, change `JULIA_SLOT_MAX` only. If that RC is a new **major.minor**, bump the worker Dockerfile / WSL `--default-channel` in the same PR (E2E pair). When bumping compat, raise `JULIA_SLOT_MIN` only.

### PR CI

These run as jobs of the `Test` workflow
([`.github/workflows/CI.yml`](.github/workflows/CI.yml)). Ubuntu:
`Pkg.test` min / max, JETLS min / max, Aqua min / max, Gitleaks.
Documenter min is
[`.github/workflows/Documentation.yml`](.github/workflows/Documentation.yml).
`Assets` (`draw SVG`) runs if `docs/src/assets/` or that workflow
changed. Linux E2E (max) uses the same **path filter** as **main** push
(`src/**`, `test/**`, `testenv/**` minus markdown under those trees,
`Project.toml`, `test/Project.toml`, `.github/workflows/CI.yml`). It also
runs on **`cut`**, **E2E weekly** (`ssh-e2e-weekly.yml`; `CI.yml` has no
`schedule`), and `workflow_dispatch`. Tip `Pkg.test` / Aqua
stay on **main**, **CI weekly**, and `cut`. Registry tree stays on **main**
and `cut` (ci-cut), not ordinary PRs.

These files **alone** skip the heavy jobs (UI: skipping; Pkg.test /
JETLS / Aqua do not start). Documenter still runs when `docs/**`, README,
`src/**`, or `Project.toml` changed; otherwise it is skipped too.
Linux E2E is skipped on allowlisted markdown-only PRs (same skipping UI):

- `README.md`, `README.ja.md`, `CONTRIBUTING.md`, `NEWS.md`,
  `SECURITY.md`, `LICENSE`
- `.gitignore`, `.github/pull_request_template.md`, `.coderabbit.yaml`
- `docs/**`, and markdown under `test/` / `testenv/`

A new root markdown file stays heavy until listed in
[`.github/actions/ci-heavy/action.yml`](.github/actions/ci-heavy/action.yml).
A `cut` label skips none of this: Pkg.test, JETLS, Aqua, Documenter,
and Linux E2E all run (E2E Codecov too). macOS / WSL stay on `E2E weekly`,
not the PR. A `cut` squash to `main` starts Full on that SHA. Register only after
that matrix is green (or wait out `cut-hold`).

CI uploads Codecov on **main push** only (`Pkg.test` max slot, flag `pkgtest`). PR E2E does not upload; `cut` PRs and **E2E weekly** Linux upload flag `e2e`. Public repo + Codecov OIDC (`id-token: write`). Status checks are informational (`codecov.yml`). Local coverage:

```bash
julia --project=. -e 'using Pkg; Pkg.test(; coverage=true)'
DISTSSHQUEUE_CODE_COVERAGE=1 ./testenv/docker-ssh/scripts/up.sh --e2e
```

Required to merge (ruleset `main` uses these names). Tip jobs are allow-failure. A job skipped by the heavy / E2E gate shows as skipping (not a green empty run). E2E weekly and CI weekly are not required.

- `Pkg.test - min - ubuntu-latest`
- `Pkg.test - max - ubuntu-latest`
- `JETLS - min - ubuntu-latest`
- `JETLS - max - ubuntu-latest`
- `Aqua - min - ubuntu-latest`
- `Aqua - max - ubuntu-latest`
- `Documenter - min - ubuntu-latest`
- `Gitleaks`
- `ubuntu-latest → ubuntu-24.04`
- `PR label`

| When | Workflow | What |
| --- | --- | --- |
| Sunday 04:00 JST, Run workflow, or a `cut` squash to `main` | `E2E weekly` | `ubuntu-latest`, `macos-15-intel`, WSL2 → `ubuntu-24.04`. Linux job uploads E2E Codecov. Not a PR check. Failure opens (or comments on) Issue `E2E weekly failed`; a later green run closes it. A red Full after a `cut` merge adds `cut-hold`. Compat-only `Project.toml` edits start the workflow but skip Full. |
| Sunday 10:00 JST, or Run workflow | `CI weekly` | Same `Pkg.test` / JETLS / Aqua slots as a PR (no coverage). Not a PR check. Catches max / Aqua / JETLS `@release` drift when nothing merged that week. Failure of min/max jobs opens Issue `CI weekly failed` (`ci`); tip is omitted from that notify. `cache-gc` keeps one Actions cache per restore-key prefix. |

## Pull requests

- Branch from `main`. Squash-merge only. Merged heads are deleted.
- One reviewable change per PR. Split unless `main` would be broken in between.
- Large plans: discuss in an issue first, then small PRs.

### CodeRabbit (experimental)

Open PRs may get an optional [CodeRabbit](https://docs.coderabbit.ai) pass.
Config is [`.coderabbit.yaml`](.coderabbit.yaml) on the **PR head** (not a
merge gate). JETLS / tests / e2e stay the gate. Treat inline comments as
hints; do not apply Autofix or generated tests unless you want that change.
`@coderabbitai pause` / `review` as needed. Settings will move as we learn
what is useful.

## Release

| Label | Meaning |
| --- | --- |
| `breaking` | Incompatible behavior. May land **without** a version bump. |
| `cut` | `Project.toml` `version` went up. |
| `cut-hold` | Postpone register. CI adds this on Issue `E2E weekly failed` when Full is red after a `cut` merge. Not a PR `area:*` label. Do not lower `version`. |

On a breaking line bump `x` in `0.x.y`; otherwise bump `y`. Do not ship an empty cut. Do not automate the bump or `@JuliaRegistrator register`.

### DistSSHKit cuts

Queue pins DistSSHKit **0.7.x** from General. Ordinary Queue work does not `Pkg.develop` Kit and does not, by itself, trigger a DistSSHKit General patch. Docs, opt-in flags, and CI on the kit wait.

If Queue cannot implement something without a kit hook, open a DistSSHKit Enhancement, land the small PR, then cut DistSSHKit (`0.7.y`) so Queue can pin General. `Pkg.develop` a Kit checkout only until that cut is on General. Kit freeze and cut rules: [DistSSHKit CONTRIBUTING.md](https://github.com/yamanori99/DistSSHKit.jl/blob/main/CONTRIBUTING.md#when-to-cut).

FIFO enqueue is DistSSHKit `execute!` kinds only (`KIT_EXECUTE_KINDS` / `kit_parse_args`). A new execute kind is one row there plus the Queue CLI. Inspect verbs (`size` / `plan` / `pool`) do not enqueue; copy [src/client/size.jl](src/client/size.jl). Do not add `plan!` in Kit to queue `plan`.

### When to cut

Not a calendar. Cut when [NEWS.md](NEWS.md) **Unreleased** has something General users should get.

| Unreleased is… | Cut? |
| --- | --- |
| Happy-path bug (FIFO enqueue / `serve`) | Yes, that patch promptly |
| Opt-in flags, docs, CI | When someone needs it on General, **or** those items have sat in Unreleased for **two weeks** |

### After a cut merges

1. **E2E weekly** starts on the **merge commit** (`Project.toml` version went up). Do not register until Linux, macOS Intel, and WSL are green. Path-filtered PRs already run Linux E2E; `cut` still forces it (with Codecov) on the version-bump PR. Full covers macOS / WSL after squash. Do not wait for Sunday cron. `workflow_dispatch` remains for a re-run.
2. Full red: Issue `E2E weekly failed` gets `cut-hold`. Do not `@JuliaRegistrator register` while `cut-hold` is open. Do not lower `version`.
3. Full green: CI removes `cut-hold` and closes the Issue. Register on that merge commit (not the PR body). Paste the NEWS section under `Release notes:`.
4. Skip that version on General instead: keep `cut-hold` until a later cut (higher `version`) is ready, then register that later cut.
5. TagBot tags once General has the release.

TagBot uses SSH deploy key secret `DOCUMENTER_KEY` (write deploy key on this repo) so the `vX.Y.Z` tag starts Docs and `stable` updates. Docs still deploy with `GITHUB_TOKEN`. Do not add a `+doc1` tag unless that path failed. Manual rebuild: `gh workflow run Docs --ref vX.Y.Z`.

Repo Settings → Actions → Workflow permissions: **Read and write** (`GITHUB_TOKEN`).

## Issues

**Issues** (Bug / Enhancement forms only): `bug` or `enhancement`. The area dropdown is triage; add `area:*` if useful. This repo has no Discussions; usage questions that are not a bug or a committed feature can wait or be an Issue. Security: [SECURITY.md](SECURITY.md).

A Queue failure is not automatically a Queue bug. Decide the repo first:

- Queue lagged Kit's contract (demo argv, translating `terminate_run!` wait into `:cancelled`, collect under a gitignored path): fix Queue. Do not open DistSSHKit.
- Queue cannot land the feature without a Kit hook: DistSSHKit Enhancement, Kit PR, Kit cut, then pin here ([DistSSHKit cuts](#distsshkit-cuts)).
- Reproduced Kit defect (`execute!` `ok` with empty collect, wait/cancel that contradicts Kit docs): open a [DistSSHKit issue](https://github.com/yamanori99/DistSSHKit.jl/issues) with the Kit log / `kit.result` / `failed_step`. Link it from the Queue issue or PR. A Queue-only workaround is temporary and must say so.

Do not file DistSSHKit on speculation. Reproduce against Kit (or this E2E with Kit artifacts) first.

Every PR needs one type label (`bug` / `enhancement` / `chore`) when labels exist.

## Labels

```bash
./.github/gen-labeler.sh          # rewrite
./.github/gen-labeler.sh --check  # CI drift
```

Every tracked path must match some `area:*` glob (`gen-labeler.sh --check`). Globs are positive paths; do not add `!` excludes (labeler ORs them as "not this path" and tags unrelated files). Path labeler syncs only `area:*`. After `setLabels` it restores type / `cut` / other non-area labels so a concurrent Type job is not wiped.

| Paths | Label |
| --- | --- |
| `src/client/**` | `area:client` |
| `src/qhost/**` | `area:qhost` |
| Leftover queue (`src/DistSSHQueue.jl`, `src/DistSSHQueue/**`, matching unit tests, shared `test/integration/cli.jl`, package meta) | `area:queue` |
| Harness under `test/` (not `unit/` / `integration/`) and `testenv/**` | `area:test` |
| `test/e2e.jl` | `area:client` and `area:qhost` as well |
| `docs/**` | `area:docs` |
| `README.md`, `README.ja.md`, `NEWS.md`, `CONTRIBUTING.md`, `SECURITY.md` | `area:project-docs` |
| `.github/**`, `codecov.yml`, `.coderabbit.yaml` | `area:ci` |

New leftover queue test file: edit the script, regenerate, create the GitHub label.

Backfill every PR after a vocabulary change:

```bash
./.github/retag-pr-areas.sh           # dry-run
./.github/retag-pr-areas.sh --apply
```

### Type labels

Every PR needs one of `bug` / `enhancement` / `chore`. Dependabot skips the type check (`dependencies` only). Override with `gh pr edit N --add-label …`.

CI infers, in order:

1. A unique type on a closing issue (`Fixes #N`)
2. Else the branch prefix: `feat/` → enhancement, `fix/` → bug, `breaking/` → breaking, `chore/` / `docs/` / `ci/` / `test/` / anything else → chore

`fix/` plus `Fixes` an enhancement issue gets `enhancement`. `breaking` may sit next to the type label. After a `cut` merge, Full runs; a human registers when green (or holds with `cut-hold`); TagBot tags.

Ruleset `main` requires check `PR label` (workflow `Type`). Type labels (`bug` / `enhancement` / `breaking` / `chore` / `cut`) and each `area:*` must exist (`gh label create` if missing).

Colors match DistSSHKit: type is "what", area is "where". Do not give each `area:*` its own hue.

| Kind | Color | Labels |
| --- | --- | --- |
| Type | red / green / yellow / dark red / purple / mint | `bug` `enhancement` `chore` `breaking` `cut` `dependencies` |
| Path area | teal `#bfdadc` | `area:client` `area:qhost` `area:queue` `area:project-docs` |
| Documenter | blue `#0075ca` | `area:docs` (and leftover `docs`) |
| CI | black `#000000` | `area:ci` (and `ci` on weekly failure issues) |
| Hold | pale blue `#BFD4F2` | `cut-hold` on Issue `E2E weekly failed` after a red Full |
| Test harness | pale blue `#c5def5` | `area:test` |

## Language

`.jl` comments, docstrings, and errors: English. Install or Docs links: `docs/src`, [README.md](README.md), and [README.ja.md](README.ja.md). User-visible behavior: NEWS. Generative AI is allowed; you own the diff. Keep docs plain.
