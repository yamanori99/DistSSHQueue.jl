# [User Guide](@id Manual)

Command reference. For a hands-on path, use First Steps
([Requirements](@ref) → [Prepare](@ref Tutorial-Prepare) →
[Walkthrough](@ref Tutorial-Walkthrough)).

Root `--help` defines Client vs Queue host (`qhost:HOST`), then Usage,
then `--help client` / `--help qhost`. Version is
`DistSSHQueue X (DistSSHKit Y)`. `--help client` is Jobs then Hosts;
`--help qhost` is Setup, Serve, then Danger (`teardown`; needs `-y`;
job trees stay). `<command> -h` is that verb's Usage and Flags,
not how to invoke DistSSHQueue. Kit argv is on
`--help client`. Flags and FAQ:
`julia --project=. -m DistSSHQueue <command> -h` and the pages below.
Each command page starts with **Usage**, then **Flags**.
Kit `go` / `ride` / `drive` / `size` / `plan` / `pool` flags stay in the
[kit User Guide](https://yamanori99.github.io/DistSSHKit.jl/stable/manual/).

| | |
| --- | --- |
| [submit](@ref Manual-submit) | Enqueue DistSSHKit `go` / `ride` / `drive` |
| [status](@ref Manual-status) | `status` / `watch` / `cancel` |
| [fetch](@ref Manual-fetch) | Copy a finished Kit leaf onto this job tree |
| [hosts](@ref Manual-hosts) | `add-host` / `remove-host` / `list-host` / `size` / `plan` / `pool` |
| [serve](@ref Manual-serve) | `serve` / `stop` / `enable` / `disable` |
| [setup](@ref Manual-setup) | `setup` / `teardown` / `config.toml` |

## Client vs queue host

`qhost:HOST` is a **client** token (like Kit `child:NAME`). Not already
on the queue host: put it on the command line (leading or right after
the verb).
`DISTSSHQUEUE_HOST` alone does not hop. On the queue host, omit
`qhost:`. After `teardown`, `status` without `qhost:` asks for `setup`
first (the config is gone), or `qhost:HOST` if this was a client hop.
Local trial: `DISTSSHQUEUE_LOCAL=1`.

Refuse `qhost:`: `setup`, `serve`, `enable`, `disable`, `add-host`,
`remove-host`. Forward: `submit`, `status`, `list-host`, `size`, `plan`,
`pool`, `watch`, `cancel`, `stop`, `teardown`. Client (not forwarded as a
whole): `fetch` (inverse of stage).

`--hosts` / `--julia` belong to Kit `go` / `ride` / `drive`. Queue-host Julia is
`--remote-julia` / `JULIA_DISTRIBUTED_EXE`. `--queue-env DIR` is
`julia --project=` on the queue host (default `~/.distsshqueue/env` if
you created that dir), not the client's `--project=.`. `--queue-env @`
is the remote default Julia env. Hop is argv `qhost:HOST` (not
`DISTSSHKIT_HOSTS`). `DISTSSHQUEUE_HOST` alone does not hop. Not forwarded.
Not `DISTSSHQUEUE_QHOST` (that is `status` / `watch` display).

`serve` is “run the process”. `enable` is “register that process with
the OS” (LaunchAgent / systemd). The queue host is **macOS or Linux**.
`enable` does not make a client or WSL2 the always-on box. `disable`
is the opposite of `enable`, not of `serve`.

## [Job record](@id Manual-job-record)

Each row: `id` (UUID), `kind` (`:go` / `:ride` / `:drive`), `script`, `hosts`,
`state` (`:queued` / `:running` / `:done` / `:failed` / `:cancelled`),
`queued_at` / `started_at` / `finished_at`, `error`, and `result_path`
— Kit's output directory. If submit omitted `--output-dir`, `serve`
sets one under `{project}/.distsshqueue/{kind}/{stem}_{id8}/` when the row becomes
`:running` (so `cancel` and a later `serve` can find `kit.pid`). Drive
is that unique leaf, not shared `.distsshkit/drive` and not demo
`output/`. Queue
does not keep a second copy of Kit's result tree. Kit kwargs (`args`,
`project`, `output_dir`, …) travel as an opaque bag through DistSSHKit's
`execute!` allow-list. `serve` also passes `job_id` (the row UUID)
so Kit progress lines can carry `job=`. `serve` instantiates the job
project on the queue host, then Kit `setup!` on `child:` hosts, unless
`DISTSSHQUEUE_NO_KIT_SETUP=1`.

The table is TOML on the queue host (`~/.distsshqueue/jobs.toml`),
rewritten under a directory lock (`jobs.toml.lock`). Writers
(`submit`, `cancel`, `serve`, `fetch` load, …) take that lock before a
rewrite. The rewrite is not atomic (truncate-in-place); a crash
mid-write can leave a bad table. `status` / `watch` read without the
lock (best-effort; they may fail if they hit a mid-write).
`jobs.toml.pid` names a live `serve` (a dead pid is ignored);
`jobs.toml.stopped` after `stop` blocks autoserve until an explicit
`serve`. If writers hang and no Queue process holds the lock, remove a
stale `jobs.toml.lock`. File names: [Where files live](@ref Layout).
If `serve` dies: `:queued` rows reload on the next `serve`. A `:running`
row whose DistSSHKit `kit.pid` is still alive stays `:running` (`serve`
will not start the next FIFO job). A `:running` row with no live
`kit.pid` is `:done` or `:failed` from DistSSHKit `ok` in `kit.result`
when that file exists, otherwise `:failed`. Drive listed `parent` /
`child` hosts must join, stay, and collect unless the job passed
`--best-effort` (Kit 0.7;
[kit drive](https://yamanori99.github.io/DistSSHKit.jl/stable/manual/drive/)).
Kit results stay under `{project}/.distsshqueue/{kind}/`.

## Shared peel

| Topic | Rule |
| --- | --- |
| `-q` / `--quiet` | `status` / `watch`: table only. Kit `DISTSSHKIT_QUIET`. |
| `--progress` / `--verbose` | Accepted (exclusive with `-q`); Queue has no live Kit run, so they keep chrome. |
| `-v` / `--version` | Top-level: Queue then DistSSHKit. `submit go -v` is Kit only. |
| `-y` / `--yes` | `teardown` (or `DISTSSHKIT_YES`). Same values as DistSSHKit. |
| Ctrl-C | `serve` / `watch`: that process only, never a running Kit job. |

## Out of scope

A scheduler inside DistSSHKit, weakdeps from Queue to DistSSHKit, a glue
package, lab-wide slot ceilings or occupancy packing, preemption /
fair-share / priorities / reservations / backfill, HTTP or a listen
socket, a client that sleeps as `serve`, auto-retry of crashed
`:running` jobs, a Queue-owned copy of Kit's result trees, and native
Windows. Day-to-day consequences of the single FIFO:
[Introduction](@ref DistSSHQueue.jl).
