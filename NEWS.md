# News

User-facing changes.
GitHub Releases may copy these sections (`Release notes:` on `@JuliaRegistrator register`).

- `serve` Kit `:check` only when the job project has `.git/`. A `qhost:`
  stage never has it (Kit rsync), so that hop skips `:check` instead of
  dying on `Could not get local git commit`
  ([#238](https://github.com/yamanori99/DistSSHQueue.jl/issues/238)).
  Interim until DistSSHKit has a no-git probe
  ([#370](https://github.com/yamanori99/DistSSHKit.jl/issues/370)).
  Checkout-backed local submits still run `:check`. Julia major.minor
  is not preflighted on a stage tree.

## 0.5.0

Breaking cut after `0.4.1`. DistSSHKit **0.7.1**.
Enqueue is `submit go` / `submit ride` / `submit drive` only.
Per-job `qhost:` stage; tickets under `.distsshqueue`.

- `add-host child:` warns that those SSH names are reachable via DistSSHKit
  from this queue host (`DISTSSHKIT_QUIET` hides it). Parent-only is quiet.
  Not a confirm prompt.
- `list-host` is a `status`-style card: NAME / TOKEN / MAX / JULIA
  on the first line, then indented `ssh` (parent) or `host` / `hostname` /
  `user` / `port` (`ssh -G`; no IdentityFile). Not one wide SSH column.
- `qhost:` submit/fetch prints `rsync → HOST:path` / `rsync ← HOST:path`
  on stderr when the transfer starts (`DISTSSHKIT_QUIET` hides it).
  `DISTSSHKIT_PROGRESS` / `--progress` adds rsync `--info=progress2`
  (`DISTSSHKIT_QUIET` skips that too). Not a size guess.
- Root `--help` defines Client vs Queue host (`qhost:HOST`), then Usage,
  then `--help client` / `--help qhost`. Version is
  `DistSSHQueue X (DistSSHKit Y)`. `--help client` is Jobs then Hosts;
  `--help qhost` is Setup, Serve, then Danger (`teardown`; needs `-y`;
  job trees stay). `<command> --help` is that verb's Usage and Flags,
  not how to invoke DistSSHQueue. Kit argv is on
  `--help client`. `setup --help` lists `--force` / `--juliaup`.
- `qhost:` snapshot `status` uses `ssh -t` when this stdout is a TTY
  (same Kit colors as a local `status`). `NO_COLOR` is copied onto the
  hop so Kit still drops ANSI; watch still gets a TTY to clear the
  screen. Watch TTY paint is `\e[H\e[J` then the frame so a shorter
  row does not leave leftover characters.
- Submit/status copy: missing config `hosts` plus a placement token is
  an error (`no add-host list; … add-host first`). Status `error` is the full first line (no
  60-character chop). Known Kit `--juliaup` / `parent` setup text is
  prefixed with Queue's `parent:N` vs `child:` rsync note. `qhost:4`
  is not a Kit slot (`Use parent:4`). After `qhost:`, submit chrome is
  `queue: qhost:HOST`, not `queue: local`. Root `--help` lists Queue
  `Commands` then a `DistSSHKit` section (`submit drive parent:4 …`).
  `qhost:HOST` is the SSH name of the queue machine, not a Kit slot.
  DistSSHKit argv replays with `julia --project=. -m DistSSHKit …`.
- After `teardown`, `status` (and other client verbs) without `qhost:`
  say `setup` first, or `qhost:HOST` if this is a client hop. Not
  “you forgot `qhost:`” on the box that just wiped `~/.distsshqueue`.
- `qhost:` stage is `~/.distsshqueue/stage/<uuid>/` (the job id). A
  second submit from the same client tree does not `rsync --delete`
  the running copy. Worker-root collision does not treat two of those
  stage dirs as different projects (a pinned
  `DISTRIBUTED_REMOTE_PROJECT_ROOT` is then allowed). `submit!` refuses
  a caller `id=` that is already in the table (first-row lookup would
  otherwise hit the wrong job).
- Job `Pkg.instantiate` skips a `DEPOT_PATH` entry that is a Julia
  project (queue-env). Empty `JULIA_DEPOT_PATH` uses `~/.julia`, not
  the serve `--project=`.
- DistSSHKit **0.7.1**. Detached `execute!` `--project=` is the job tree
  when that tree has DistSSHKit (after `serve` instantiate). Not
  `pkgdir(DistSSHKit)` of queue-env.
- `qhost:` submit tickets are `{project}/.distsshqueue/tickets/<uuid>`
  (every submit, no prune). Not `.distsshkit/queue/`. `fetch` takes
  that path, the UUID, or the 8-character prefix.
- `qhost:` submit rsync matches Kit `setup --rsync`: `.gitignore` plus
  `.git/` / `.distsshkit/` / `.distsshqueue/`. Ship Manifest (or
  `data/`) by editing gitignore, not a Queue exception. Stage rsync
  stdout stays off the job-id line.
- Before `execute!`, `serve` `Pkg.instantiate`s the job project on the
  queue host (Kit parent). Kit `setup!` (`rsync` → `instantiate` →
  `check`) still runs on `child:` only. `instantiate` / `check` failure
  fails the job (`rsync` onto a nonempty remote is skipped, Kit
  safety). `drive` / `parent:N` no longer need a hand `instantiate` on
  `~/.distsshqueue/stage/<id>`.
- Top-level `go` / `ride` / `drive` are DistSSHKit. Queue enqueue is
  `submit go` / `submit ride` / `submit drive` only.

## 0.4.1

Patch after `0.4.0`. DistSSHKit **0.7.x**.
`qhost:HOST`, Kit `:N`, status cards, Kit `setup!` before execute, `submit pool:N`.

> [!NOTE]
> Day to day you do not hand-run DistSSHKit `setup` / instantiate on the
> stage tree. `submit` starts `serve` if needed, and `serve` runs Kit
> `setup!` (`rsync` → `instantiate` → `check`) before `execute!`.
> `DISTSSHQUEUE_NO_KIT_SETUP=1` skips it.

- DistSSHKit **0.7.x**. Listed `parent` / `child:NAME` need `:N`. No
  host token is still one slot. Queue does not rewrite a bare token to
  `:1`. Empty `submit` hosts stay empty (`execute!` one slot).
- Client verbs need `qhost:HOST` on the command line. `DISTSSHQUEUE_HOST`
  alone does not hop. Queue host: omit `qhost:`. Local trial:
  `DISTSSHQUEUE_LOCAL=1`. Failed jobs are fetchable. Id may be the
  8-character status prefix.
- `setup --juliaup` wraps Kit `juliaup_align_remotes`. Do not combine with
  `--force`.
- `add-host` / `pool` warn on Julia major.minor mismatch. Quiet if
  `DISTSSHKIT_QUIET`. Fix: `setup --juliaup`.
- `status` / `watch` print job cards (`ID STATE KIND SCRIPT`). `--tail
  N|full`. Watch skips identical frames. Default Kit leaf is
  `{project}/.distsshqueue/{kind}/{stem}_{id8}/`. Fetch dest is the same
  layout on the client tree.
- `submit pool:N` expands config hosts to the same `:N` (clamped by
  add-host max). Do not mix with parent / child tokens.

- Inspect verbs (`size` / `plan` / `pool`) print `Suggested submit (template):`
  instead of `Queue submit:`. `pool` adds notes that counts are sizing hints
  (default GB/worker, no RSS) and that `parent` is the queue host token.

## 0.4.0

Breaking cut after `0.3.2`. DistSSHKit **0.6.x**.
`ride`, `plan`, and `pool` on the queue host.

- DistSSHKit **0.6.x**. A line with a `.jl` and no Queue verb is no
  longer implicit `go`. Use `go` / `submit go` (same as Kit).
- `submit ride` / `ride` (experimental DistSSHKit `execute!` kind).
- `plan` inspects a script on the queue host (same type as `size`). Does
  not enqueue.
- `pool` shows cores / RAM / slot hint on the queue host (same type as
  `size`). Does not enqueue.

## 0.3.2

Patch after `0.3.1`. DistSSHKit **0.5.x** (≥0.5.4).
Setup `child:` tokens, juliaup on the queue host, trust / FIFO / store docs.

- DistSSHKit **0.5.x** (≥0.5.4). Kit `setup` hosts are `child:NAME`
  (`parent` for `--juliaup`). Bare SSH names rejected. Align juliaup
  on the queue host; restart `serve` / re-`enable` after changing the
  default.
- Requirements: trust domain (`submit` as the queue-host user reaches
  workers). Introduction: single-FIFO day-to-day limits. `jobs.toml`
  writers use a directory lock (rewrite not atomic; `status`/`watch`
  unlocked).
- Runs need SSH (LAN/VPN). Constant internet is mainly for `Pkg` /
  `git clone` / `git pull` / installing Julia.

## 0.3.1

Patch after `0.3.0`. DistSSHKit **0.5.x** (≥0.5.1).
Walkthrough, unique drive leaf, status / watch, teardown dry-run.

- DistSSHKit **0.5.x** (≥0.5.1). `demo install` copies into
  `distsshkit_demos/`.

- Walkthrough: queue host `setup` / `add-host` / `serve`, client
  `demo install` / `qhost:` go / `fetch`, Kit setup from the stage tree
  before `child:NAME`, then drive, then teardown dry-run / `-y`.

- Queue `drive` (no `--output-dir`) uses DistSSHKit `allocate_output_dir`:
  `.distsshkit/drive/<stem>_<UTC>_<id>/`. That is the fetch leaf. Kit
  demos that write `output/` on a local `drive` do not use `output/`
  here.

- `qhost:` submit writes `.distsshkit/queue/<id>` on the client (script /
  qhost). The Kit leaf still appears only after `fetch`. Stage still
  excludes `.distsshkit/`.

- Prepare leads with `setup` / `add-host` / `serve`. Dedicated
  `~/.distsshqueue/env` is optional (`qhost:` / `enable`). `setup` still
  writes `config.toml` only.

- `list-host` NAME for `parent` is the queue-host hostname; HOST TOKEN
  stays `parent`. Via `qhost:`, parent SSH is `queue host`, not `this
  machine`. Store `path` is `HOST:~/.distsshqueue/jobs.toml` on that hop.

- Missing `jobs.toml` is Store `path none` and Jobs `(none)`, not a live
  empty table (`(empty)` is a store with zero rows).

- `status --interval` is live (`watch` is the same loop; default `0.5`).
  Snapshot `status` is unchanged. `qhost:` live uses `ssh -t` like `watch`.

- `status` / `watch` Store chrome includes `enable` (OS unit on this
  host, or `none`). Distinct from `serve` running / stopped / none.

- `watch` reprints the same Store table as `status` (including `serve`)
  when stdout is a TTY (`ssh -t` on `qhost:`). A pipe without `-q`
  prints one compact `serve` / `running` / `queued` line per tick.
  `watch -q` on a pipe is still the table.

- `teardown` without `-y` is a dry-run (`Would remove`, exit 0), not
  `Error:`. Still needs `-y` / `DISTSSHKIT_YES` to delete.

- `disable` prints `Removed` or `Present` (unchanged), like `enable` /
  `setup`. Teardown still lists those paths itself.

- Root `--help` matches Kit: command table, examples, then
  `<command> -h`. Notes stay in the Manual.

- README / README.ja: `<picture>` keeps GitHub light/dark SVGs; the
  fallback `img` is the paper PNG so JuliaHub dark mode still shows
  the footer mark. PkgEval badge. No Discussions badge (this repo has
  none).

## 0.3.0

Breaking cut after `0.2.1`. DistSSHKit **0.5.x**. Drive `:done` follows
Kit `ok`. `serve` Ctrl-C, unique job-id prefix, docs favicon.

## 0.2.1

Patch after `0.2.0`. DistSSHKit **0.4.x** (≥0.4.3).

- Collect / `go` SSH failures are not empty success. Missing `ssh` /
  `rsync` / `git` / `scp` prints a Requirements hint.
- E2E names are `distsshqueue-*` (not `dskq-*`).

## 0.2.0

First General release. DistSSHKit **0.4.x** (≥0.4.2). `fetch`.

## 0.2.0-beta.2

### Client `fetch`

- `fetch <id>` copies one finished Kit `.distsshkit` leaf onto this job
  tree (inverse of `qhost:` stage, which excludes that dir). Same
  `relpath` as the stage mapping. Exact UUID. Refuses queued / running /
  missing path / `--output-dir` leaves that do not contain the id.
  stdout is the dest path. Not forwarded as a whole (`maybe_remote`).

## 0.2.0-beta.1

**DistSSHQueue** (new UUID). First pin is git tag `v0.2.0-beta.1`. DistSSHKitQueue
stopped at `v0.1.0-beta.1` (old UUID / old module); do not pin that tag for this
package. Not on General.
[DistSSHKit](https://github.com/yamanori99/DistSSHKit.jl) **0.4.x** (≥0.4.2) comes from General.
Do not `Pkg.develop` Kit for ordinary Queue work.
Julia **1.12+**. `julia -m DistSSHQueue` (no `dskq` shim).
Home is `~/.distsshqueue`, ENV is `DISTSSHQUEUE_*`, OS unit is
`org.distsshqueue.serve`. `teardown` still removes leftover
`~/.distsshkitqueue`, old units, and `~/.local/bin/dskq`.

### Jobs

- FIFO one table job. `serve` is DistSSHKit `execute!(kind; detached=true)`.
  Chrome says `Started serve` / `Stopped serve`.
- `submit` starts `serve` if none is watching (`DISTSSHQUEUE_NO_AUTOSERVE=1`
  to opt out). `stop` writes `jobs.toml.stopped`; only an explicit `serve`
  resumes. `stop` keeps config / store / OS unit.
- `submit go` / `submit drive` check the script exists first. A Kit-shaped
  line with a `.jl` and no Queue verb is `go`. `--hosts` / `--julia` stay on
  Kit. Queued `go` with `job_id` runs the slot script (`-L`).
- Job ids are a bare stdout line. `submit` also prints `Queued  N` on
  stderr (`(R running)` when a job is already running). `DISTSSHKIT_QUIET`
  hides that line. `cancel` of `:running` records
  `allocate_output_dir` (or `--output-dir`) so `terminate_run!` has a path.
  `cannot be cancelled` for an unknown id, a finished row, or `:running`
  without a known output dir. `status` has an `ERROR` column on failure.
- `watch` reprints until Ctrl-C (`--interval`, default 0.5s). Does not stop
  `serve`. Kit `-q` / `--quiet` / `DISTSSHKIT_QUIET`: table only.

### Client `qhost:`

- Token is `qhost:NAME` (like Kit `child:NAME`). `--qhost` and `--via` are
  refused. `setup` / `serve` / `enable` / `disable` refuse `qhost:` (log in
  on the queue host).
- `qhost:` `submit` / `go` / `drive` rsync the client job tree to
  `~/.distsshqueue/stage/<uuid>/` (the job id, a new directory every
  submit) and set `DISTRIBUTED_PROJECT_ROOT` there. A second submit from
  the same client tree does not `rsync --delete` a running copy. Omit
  `qhost:` does not rsync. `DISTSSHQUEUE_NO_STAGE=1` skips (tests).
  Kit still copies queue host → workers.
- `qhost:` runs `julia --startup-file=no --project=~/.distsshqueue/env` (not the
  client's `--project=.`, not remote cwd `.`). `--queue-env DIR` /
  `DISTSSHQUEUE_QUEUE_ENV`; `@` is the remote default env. `--project` after
  `qhost:` is refused.
- Omitted `qhost:` uses `DISTSSHQUEUE_HOST` (SSH name). Token wins. Not
  `DISTSSHKIT_HOSTS`. Not forwarded on `qhost:`.
- `status` / `watch` print `qhost` from `DISTSSHQUEUE_QHOST` (set on
  `qhost:`), or `local (hostname)` when omitted. Not the job `HOSTS` column.

### Queue host

- Store is `~/.distsshqueue` (`config.toml`: `store` + `[env]`; ENV wins).
  `setup` writes config only.
- `enable --queue-env DIR` is `julia --project=` in the OS unit (`--project` refused).
  Project stays cwd / `DISTRIBUTED_PROJECT_ROOT`. One Kit clone per job
  on the queue host (`~/org/Repo.jl`); not a Queue job name. Do not pin
  `DISTRIBUTED_REMOTE_PROJECT_ROOT` in shared `config.toml`. Kit worker
  path is `~/parent/Repo.jl`. `submit` refuses a second project that Kit
  would deploy to the same worker path (`remote_env_project_root`: `~` is
  not expanduser on the queue host; no rename, no `setup --delete`).
  `enable --julia` is the unit binary.
  Queue-host Julia for jobs is `--remote-julia` /
  `JULIA_DISTRIBUTED_EXE`.
- `teardown` confirms like DistSSHKit (`-y` / `--yes` / `DISTSSHKIT_YES`).
  `[env]` in the target config still applies.
- `--version` (`-v`, `-V`) prints Queue then DistSSHKit. `submit go -v` stays
  Kit only. CLI chrome matches Kit (`--help` sections, `~` paths, colored
  `status`). `ArgumentError` is `Error: ...` on stderr.

### Hosts

- `add-host` / `remove-host` on the queue host. Tokens `parent[:N]` /
  `child:NAME[:N]`. Optional `:N` is a max. First add creates the list;
  missing key: CLI submit with a placement token errors (`add-host first`); empty array allows none. Leftover `allowed` is
  still read until rewritten. Next `submit` re-reads (do not restart
  `serve`). CLI `submit` follows config; library `submit!` uses
  `Queue(; allowed=…)` unless `follow_config=true`. `submit!` rejects
  pre-0.4 tokens (`parenthost`, bare `NAME:N`).
- `list-host`: tokens plus `ssh -G` Host / HostName / User / Port. No keys.
  On the queue host, or `qhost:HOST list-host`.
- `size`: DistSSHKit `size` on the queue host. Omit tokens to size config
  `hosts`. Does not enqueue; prints a `submit drive` template.

### Docs

- English README is the landing page. Japanese: `README.ja.md`. Documenter
  First Steps / User Guide cover Queue verbs; Kit `go` / `drive` stay in
  the kit docs. Requirements show client / queue-host / worker trees.
  The always-on queue host is macOS or Linux (WSL2 is a client or worker).
