# Contributing

Internals of this repo.

- Users: [stable docs](https://yamanori99.github.io/DistSSHQueue.jl/stable/) (`docs/`), [README.md](README.md), [README.ja.md](README.ja.md), [NEWS.md](NEWS.md)
- Dev docs: [dev](https://yamanori99.github.io/DistSSHQueue.jl/dev/) ([docs/README.md](docs/README.md))

This is a **separate** package from DistSSHKit: FIFO `serve` in front of one Kit `go` / `ride` / `drive`, not a bigger Kit. Placement tokens, `execute!`, `kit.pid` / `kit.result`, `terminate_run!`, demo argv, and rsync/collect are Kit's. Queue records table state and the path Kit already wrote.

CI names Julia versions in the job (`1.13`, `1.14-nightly`), same as DistSSHKit. SSH E2E is this repo's `testenv/docker-ssh` (Kit-shaped workers). CI is `Pkg.test` (unit + child CLI / `parent:1`), JETLS, Aqua, Linux SSH E2E on Julia **1.13** (`test/e2e.jl`: `serve` API, queue-host CLI, `qhost:` over loopback OpenSSH) on path-filtered PRs / **main** / a `Project.toml` version increase / weekly / dispatch, Gitleaks, light **Runic** `--check` (soft on PRs; monthly on `main`), schedule-only **E2E weekly** (Linux / macOS Intel / WSL), and schedule-only **CI weekly**.

## Requirements

macOS, Linux, or WSL2 Ubuntu. Not native Windows (the kit shells out to `ssh` / `rsync`).

| What | Need |
| --- | --- |
| Library, `Pkg.test()`, `julia -m DistSSHQueue`, docs | Julia **1.13+** |

Prefer [juliaup](https://github.com/JuliaLang/juliaup). Details: [Requirements](https://yamanori99.github.io/DistSSHQueue.jl/dev/requirements/).

## Setup

```bash
git clone https://github.com/yamanori99/DistSSHQueue.jl.git
cd DistSSHQueue.jl
julia --project=. -e 'using Pkg; Pkg.instantiate()'
```

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

Run this on Julia **1.13** (and **1.14-nightly** if you have it). Layout: [test/README.md](test/README.md). When adding a file under `test/runtests.jl` or an inner SSH E2E `@testset`, bump `_RUNTEST_N` / `_E2E_N` so `[i/N]` stays honest.

Checkout `Pkg.test()` is not a Registry tarball. After changing those gates (child CLI project, `ssh` spawn), and before a General cut, run the disposable copy in [test/README.md](test/README.md#registry-tree). CI runs that shape on **main** and a version increase (Julia 1.14-nightly; not a required check).

```bash
julia -e 'using Pkg; Pkg.Apps.add("Runic")'   # once
runic --inplace src test docs testenv   # before push; not `.` (markdown out of scope)
./.github/jetls-check.sh    # hint+; same files as CI
./.github/aqua-check.sh     # latest registry Aqua; not part of Pkg.test()
./testenv/docker-ssh/scripts/up.sh --e2e
julia --project=docs -e 'using Pkg; Pkg.instantiate()'
julia --project=docs --color=yes docs/make.jl
julia --project=docs/src/assets/logo -e 'using Pkg; Pkg.instantiate()'
julia --project=docs/src/assets/logo docs/src/assets/logo/draw.jl   # SVG; add --png for rasters
gitleaks detect --source .
```

[Runic](https://github.com/fredrikekre/Runic.jl) CI
(`fredrikekre/runic-action@v1`, `version: '1'`) runs `--check` on every
tracked `.jl`. Format `docs/*.jl` and `testenv/**/*.jl` too if you change
them. A Runic minor may make `--check` red: re-run
`runic --inplace src test docs testenv` and push.
Optional: after a bulk format squash, add the landed SHA to
[`.git-blame-ignore-revs`](.git-blame-ignore-revs) if blame is noisy.
Local blame:

```bash
git config blame.ignoreRevsFile .git-blame-ignore-revs
```

VS Code: recommend
[Custom Local Formatters](https://marketplace.visualstudio.com/items?itemName=jkillingsworth.custom-local-formatters)
(`.vscode/extensions.json`). User `settings.json` (do not commit):

```json
"customLocalFormatters.formatters": [
    {
      "command": "runic",
      "languages": ["julia"]
    }
]
```

JETLS CI uses [`.github/actions/jetls-check`](.github/actions/jetls-check/action.yml) (installs `JETLS.jl` `@release` after `julia-actions/cache`). After a bump, re-read [cli-check](https://aviatesk.github.io/JETLS.jl/dev/cli-check/) and keep failing on hint+.

JETLS is the type gate. Do not commit `.vscode/settings.json` to silence the Language Server.

[Fatou](https://fatou.dev) is local only. Do not add `fatou.toml` or Fatou to `.vscode/extensions.json`. After a Fatou bump, check it did not rewrite files you did not mean to touch.

### Julia versions

Workflows pass the version to `julia-actions/setup-julia`. The job name is that version.

| Version | Role | Required |
| --- | --- | --- |
| **1.13** | `Project.toml` julia floor. Pkg.test, Aqua, JETLS, Documenter, draw, E2E, Runic. Codecov `pkgtest` on **main push** only | yes |
| **1.14-nightly** | Next-minor nightly. Pkg.test, Aqua, registry tree. `continue-on-error` | no |

**1.13** runs on ordinary PRs (heavy gate). Ubuntu **1.14-nightly** runs on **main**, **CI weekly**, and a `Project.toml` version increase ([`.github/version-cut.sh`](.github/version-cut.sh)), not ordinary PRs. macOS and WSL2 nightly run on **CI weekly** only.

This package feels SSH hosts, Pkg, and lockfiles more than a compute-model
library does. When Julia announces that it has stopped maintaining the
previous minor, raise the floor to the new stable. The move from 1.12 to
1.13 is that case (1.12 became unmaintained when 1.13 shipped). Do not
track the LTS for its own sake. Other situations (a prerelease as the
floor, dropping a minor only for a language feature, and similar) are
decided one by one. Do not move the floor to nightly, or to a minor that
has only just shipped, as an automatic rule.

When the floor moves, rename the **1.13** jobs to the new version in the same PR as `Project.toml`, the worker Dockerfile `--default-channel`, and the WSL `julia_channel`. Ruleset `main` uses those job names, so update the required checks with the rename.

JETLS stays on a runtime it lists (today 1.12.2–1.13). Raise that job's version only after JETLS supports it. No JETLS on nightly.

When a new RC of the floor's minor lands, point **1.13** jobs at `~1.13.0-0` so setup-julia includes prereleases. When that minor GAs, drop the tilde. A new **major.minor** is a floor move, not a second stable job.

### PR CI

These run as jobs of the `Test` workflow
([`.github/workflows/CI.yml`](.github/workflows/CI.yml)). Ubuntu:
`Pkg.test` 1.13, JETLS 1.13, Aqua 1.13, Gitleaks
(also rejects `< 0.0.1` in `Project.toml`). macOS (`macos-latest`) and
WSL2 Ubuntu 24.04: `Pkg.test` 1.13, same heavy gate, no coverage upload.
macOS runs `enable --write-only` on LaunchAgent. Both are required.
Documenter 1.13 is
[`.github/workflows/Documentation.yml`](.github/workflows/Documentation.yml).
`Assets` (`draw SVG`) runs if `docs/src/assets/` or that workflow
changed. Linux E2E (1.13) uses the same **path filter** as **main** push
(`src/**`, `test/**`, `testenv/**` minus markdown under those trees,
`Project.toml`, `test/Project.toml`, `.github/workflows/CI.yml`). It also
runs on a **version increase**, **E2E weekly** (`ssh-e2e-weekly.yml`; `CI.yml` has no
`schedule`), and `workflow_dispatch`. **1.14-nightly** `Pkg.test` / Aqua
on Ubuntu stay on **main**, **CI weekly**, and a version increase, not
ordinary PRs. macOS and WSL2 nightly stay on **CI weekly** only. Registry tree stays on **main**
and a version increase, not ordinary PRs.

[Runic](https://github.com/fredrikekre/Runic.jl) is a separate light
workflow ([`.github/workflows/runic.yml`](.github/workflows/runic.yml)).
It is not a substitute for `Pkg.test`. Soft on PRs (not in the
required-name list). Monthly cron on `main` opens Issue
`Runic monthly failed` (`alert`) when `--check` is red.

These files **alone** skip the heavy jobs (UI: skipping; Pkg.test on
Ubuntu, macOS, and WSL2, plus JETLS / Aqua, do not start). Documenter
still runs when `docs/**`, README,
`src/**`, or `Project.toml` changed; otherwise it is skipped too.
Linux E2E is skipped on allowlisted markdown-only PRs (same skipping UI):

- `README.md`, `README.ja.md`, `CONTRIBUTING.md`, `NEWS.md`,
  `SECURITY.md`, `LICENSE`
- `.gitignore`, `.git-blame-ignore-revs`,
  `.github/pull_request_template.md`, `.coderabbit.yaml`
- `docs/**`, and markdown under `test/` / `testenv/`

A new root markdown file stays heavy until listed in
[`.github/actions/ci-heavy/action.yml`](.github/actions/ci-heavy/action.yml).
A `Project.toml` version increase skips none of this: Pkg.test (Ubuntu,
macOS, and WSL2), JETLS, Aqua, Documenter, and Linux E2E all run (E2E
Codecov too). macOS and WSL SSH E2E stay on `E2E weekly`, not the PR.
Register when the required checks below are green. Intel / WSL weekly are
watchers, not the register gate.

CI uploads Codecov on **main push** only (Ubuntu `Pkg.test` 1.13, flag `pkgtest`). The `macos-latest` job does not upload. PR E2E does not upload; a version-increase PR and **E2E weekly** Linux upload flag `e2e`. Public repo + Codecov OIDC (`id-token: write`). Status checks are informational (`codecov.yml`). Local coverage:

```bash
julia --project=. -e 'using Pkg; Pkg.test(; coverage=true)'
DISTSSHQUEUE_CODE_COVERAGE=1 ./testenv/docker-ssh/scripts/up.sh --e2e
```

Required to merge (ruleset `main` uses these names). **1.14-nightly** jobs are allow-failure. A job skipped by the heavy / E2E gate shows as skipping (not a green empty run). Ubuntu nightly runs on **main**, weekly, and a version increase, not ordinary PRs. macOS and WSL2 nightly run on CI weekly only. E2E weekly and CI weekly are not required.

- `Pkg.test (1.13, ubuntu-latest, x64)`
- `Pkg.test (1.13, macos-latest, aarch64)`
- `Pkg.test (1.13, WSL2 ubuntu-24.04, x64)`
- `JETLS (1.13, ubuntu-latest, x64)`
- `Aqua (1.13, ubuntu-latest, x64)`
- `Documenter (1.13, ubuntu-latest, x64)`
- `Gitleaks`
- `ubuntu-latest → ubuntu-24.04`
- `PR label`

| When | Workflow | What |
| --- | --- | --- |
| Sunday 04:00 JST, Run workflow, or a version-increase squash to `main` | `E2E weekly` | `ubuntu-latest`, `macos-15-intel`, WSL2 → `ubuntu-24.04`. Linux job uploads E2E Codecov. Not a PR check. Failure opens (or comments on) Issue `E2E weekly failed`; a later all-green run closes it. A red **Linux** job after a `cut` merge adds `cut-hold`. Intel / WSL red does not. Compat-only `Project.toml` edits start the workflow but skip the matrix. |
| Sunday 10:00 JST, or Run workflow | `CI weekly` | Same 1.13 `Pkg.test` / JETLS / Aqua versions as a PR, including `macos-latest` and WSL2 (no coverage). 1.14-nightly `Pkg.test` and Aqua on macOS and WSL2 run here only. Not a PR check. Catches 1.13 / Aqua / JETLS `@release` drift when nothing merged that week. Failure of the 1.13 jobs opens Issue `CI weekly failed` (`alert`); 1.14-nightly is omitted from that notify. `cache-gc` keeps one Actions cache per restore-key prefix. |
| 1st 10:00 JST, or Run workflow | `Runic` | `runic --check` on tracked `.jl` (`version: '1'`). Not a required PR check. Catches Runic minor drift when nothing formatted that month. Failure opens Issue `Runic monthly failed` (`alert`). |

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
| version cut | `Project.toml` `version` went up. CI compares that file with the base (`version-cut.sh`). Labels adds `cut` on that rise. Removing it sticks until the next rise. CI still reads the file, not the label. |
| `cut-hold` | Postpone register. CI adds this on Issue `E2E weekly failed` when weekly **Linux** is red after a `cut` merge. Intel / WSL red does not. Not a PR `area:*` label. Do not lower `version`. |

On a breaking line bump `x` in `0.x.y`; otherwise bump `y`. Do not ship an empty cut. Do not automate the bump or `@JuliaRegistrator register`.

### DistSSHKit cuts

Queue pins DistSSHRun **0.1**. Ordinary Queue work does not `Pkg.develop` Run and does not, by itself, trigger a DistSSHRun General patch. Docs, opt-in flags, and CI on Run wait.

If Queue cannot implement something without a kit hook, open a DistSSHKit Enhancement, land the small PR, then cut DistSSHKit so Queue can pin General. `Pkg.develop` a Kit checkout only until that cut is on General. Kit freeze and cut rules: [DistSSHKit CONTRIBUTING.md](https://github.com/yamanori99/DistSSHKit.jl/blob/main/CONTRIBUTING.md#when-to-cut).

FIFO enqueue is DistSSHKit `execute!` kinds only (`KIT_EXECUTE_KINDS` / `kit_parse_args`). A new execute kind is one row there plus the Queue CLI. Inspect verbs (`size` / `plan` / `pool`) do not enqueue; copy [src/client/size.jl](src/client/size.jl). Do not add `plan!` in Kit to queue `plan`.

### When to cut

Not a calendar. Cut when [NEWS.md](NEWS.md) **Unreleased** has something General users should get.

| Unreleased is… | Cut? |
| --- | --- |
| Happy-path bug (FIFO enqueue / `serve`) | Yes, that patch promptly |
| Opt-in flags, docs, CI | When someone needs it on General, **or** those items have sat in Unreleased for **two weeks** |

### After a cut merges

1. Register when the required checks on the version-increase PR are green. Do not wait for weekly Intel / WSL.
2. **E2E weekly** still starts on the merge commit (`Project.toml` version went up): Linux, `macos-15-intel`, WSL2. Watchers. Do not wait for Sunday cron. `workflow_dispatch` remains for a re-run.
3. Weekly **Linux** red after a cut: Issue `E2E weekly failed` gets `cut-hold`. Do not `@JuliaRegistrator register` while `cut-hold` is open. Do not lower `version`. Intel / WSL red comments on that Issue without `cut-hold`.
4. Weekly Linux green: CI removes `cut-hold` even if Intel / WSL are still red (the Issue stays open until the whole weekly run is green). Register on the merge commit (not the PR body). Paste the NEWS section under `Release notes:`.
5. Skip that version on General instead: keep `cut-hold` until a later cut (higher `version`) is ready, then register that later cut.
6. TagBot tags once General has the release.

TagBot uses SSH deploy key secret `DOCUMENTER_KEY` (write deploy key on this repo) so the `vX.Y.Z` tag starts Docs and `stable` updates. Docs still deploy with `GITHUB_TOKEN`. Do not add a `+doc1` tag unless that path failed. Manual rebuild: `gh workflow run Docs --ref vX.Y.Z`.

GitHub Releases need a token that can `POST /repos/.../releases` (`Contents: write`). Keep cut commits to `Project.toml` + `NEWS.md` (no workflow files). For Releases, set repo secret **`TAGBOT_PAT`**: fine-grained PAT (this repo, or the same token as DistSSHKit), Contents read/write, Issues read/write. Add Workflows read/write only when the tagged SHA changes `.github/workflows` (GitHub then requires it). TagBot reads General with `GITHUB_TOKEN` (`registry_token`); a this-repo-only PAT 401s on `GET JuliaRegistries/General`. Empty `TAGBOT_PAT` still falls back to `GITHUB_TOKEN` for `token`. Do not put `permissions:` on `.github/workflows/TagBot.yml` (TagBot defaults). If TagBot opens `TagBot: Manual intervention needed for releases`, the tag may already exist; create the Release only (`gh release create vX.Y.Z --verify-tag --notes "…"`), then close the Issue. `--verify-tag` fails if the tag is missing (plain `gh release create` would mint it from the default branch).

Repo Settings → Actions → Workflow permissions: **Read and write** (`GITHUB_TOKEN`).

## Issues

**Issues** (Bug / Enhancement forms only): `bug` or `enhancement`. The area dropdown is triage; add `area:*` if useful. Horizon (`when:*`) is **when**, not type or path: every open Issue gets exactly one of `when:current` / `when:next` / `when:later`. `julia-next` is optional and orthogonal: Julia tip / next stable Base or stdlib drift (keep `when:later` until that Julia is the package contract). This repo has no Discussions; usage questions that are not a bug or a committed feature can wait or be an Issue. Security: [SECURITY.md](SECURITY.md).

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

Every tracked path must match some `area:*` glob (`gen-labeler.sh --check`). Globs are positive paths; do not add `!` excludes (labeler ORs them as "not this path" and tags unrelated files). Path labeler syncs only `area:*`. After `setLabels` it restores type / other non-area labels so a concurrent Type job is not wiped.

| Paths | Label |
| --- | --- |
| `src/client/**` | `area:client` |
| `src/qhost/**` | `area:qhost` |
| Leftover queue (`src/DistSSHQueue.jl`, `src/DistSSHQueue/**`, matching unit tests, shared `test/integration/cli.jl`, package meta including `.git-blame-ignore-revs`) | `area:queue` |
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

Weekly Dependabot covers `github-actions` and Julia registry deps.
Stdlib names are `ignore` in [`.github/dependabot.yml`](.github/dependabot.yml)
(`Dates`, `Pkg`, `TOML`, `Test`). A new
third-party `[deps]` entry is picked up with no YAML change; a new
stdlib must be added to that ignore list. Stdlib `[compat]` stays with
the Julia floor. The Julia updater otherwise appends `< 0.0.1` for the
pre-1.10 Pkg.test 0.0.0 sandbox; this package is 1.13 and does not need
that union (comma is or, not and). Scan /
`./.github/pkg-compat-check.sh` rejects that token.

CI infers, in order:

1. A unique type on a closing issue (`Fixes #N`)
2. Else the branch prefix: `feat/` → enhancement, `fix/` → bug, `breaking/` → breaking, `chore/` / `docs/` / `ci/` / `test/` / anything else → chore

`fix/` plus `Fixes` an enhancement issue gets `enhancement`. `breaking` may sit next to the type label. After a cut, a human registers when the required checks are green (or holds with `cut-hold` if weekly Linux is red); TagBot tags.

Ruleset `main` requires check `PR label` (workflow `Type`). Type labels (`bug` / `enhancement` / `breaking` / `chore`) and each `area:*` must exist (`gh label create` if missing). `when:*` and `julia-next` are Issues only (not a PR type). Labels adds `cut` when the version rises above the base. Removing it sticks until the next rise. CI still reads Project.toml, not the label.

Colors match DistSSHKit: type is "what", area is "where". Do not give each `area:*` its own hue.

| Kind | Color | Labels |
| --- | --- | --- |
| Type | red / green / yellow / dark red / purple / mint | `bug` `enhancement` `chore` `breaking` `dependencies` |
| Path area | teal `#bfdadc` | `area:client` `area:qhost` `area:queue` `area:project-docs` |
| Documenter | blue `#0075ca` | `area:docs` (and leftover `docs`) |
| CI | black `#000000` | `area:ci` |
| Scheduled failure | orange `#ff4d00` | `alert` on bot Issues (`E2E weekly failed`, `CI weekly failed`, `Runic monthly failed`) |
| Hold | pale blue `#BFD4F2` | `cut-hold` on Issue `E2E weekly failed` after a red weekly Linux job |
| Test harness | pale blue `#c5def5` | `area:test` |
| Horizon | orange `#fdba74` / violet `#c4b5fd` / slate `#94a3b8` | `when:current` `when:next` `when:later` |
| Julia next | Julia purple `#9558b2` | `julia-next` (Issues: tip / next-stable API; not a PR type) |

| `when:*` | Use |
| --- | --- |
| `when:current` | Broken daily path or CLI that lies; same 0.4 contract |
| `when:next` | Same contract: chrome, copy, colors |
| `when:later` | Later cut: daemon, inventory, cwd, ids |

## Language

`.jl` comments, docstrings, and errors: English. Install or Docs links: `docs/src`, [README.md](README.md), and [README.ja.md](README.ja.md). User-visible behavior: NEWS. Generative AI is allowed; you own the diff. Keep docs plain.
