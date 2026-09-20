# Requirements

Prerequisites for [Introduction](@ref DistSSHQueue.jl) and
[Prepare](@ref Tutorial-Prepare). Typed commands:
[Walkthrough](@ref Tutorial-Walkthrough). DistSSHKit's own checks
([kit Requirements](https://yamanori99.github.io/DistSSHKit.jl/stable/requirements/))
still apply to workers. This page is Queue: queue host vs client.

`pkg> add DistSSHQueue` does not install **`ssh`**, **`rsync`**, or
**`git`**.

Runs need **SSH** (client → queue host, queue host → workers). LAN or
VPN is enough. Constant internet is not required; you mainly need it
for `Pkg.add` / `instantiate`, outbound `git clone` / `git pull`, or installing
Julia.

## All machines

Applies to the **queue host**, each **client**, and each SSH host that
runs jobs.

- **macOS, Linux, and WSL2 Ubuntu** (not native Windows)
- **Julia 1.12+**
  - Library (`Pkg.add` / `using` / `submit!`), CLI
    (`julia -m DistSSHQueue`)
  - Same **major.minor** on the queue host and SSH workers (DistSSHKit
    `setup --check` fails on a mismatch unless `--ignore-julia-version`;
    patch-only differences warn). `serve` always runs that `:check` on
    `child:` hosts, including a `qhost:` stage with no `.git/`
    (DistSSHKit **0.7.3+** warns on a missing local git commit).
  - Prefer **[juliaup](https://github.com/JuliaLang/juliaup)** at
    `$HOME/.juliaup/bin/julia`. If it is not there, put a 1.12+ binary at a
    usual OS path ([Checks](@ref)) or set `--remote-julia` /
    `JULIA_DISTRIBUTED_EXE`. Missing path or a related bug:
    [open an Issue](https://github.com/yamanori99/DistSSHQueue.jl/issues).
- **DistSSHKit 0.8.x** from General. Do not `Pkg.develop` Kit (or
  Queue) in a job project whose Manifest is copied to workers — that path
  is absolute and the workers do not have it. Separate env for package
  work.

WSL2 is Linux, with DistSSHKit's extra rules:

- Run Queue **inside** the distro, not PowerShell
- Keep the project on the Linux filesystem (`~/…`), not `/mnt/c/…`
- Install `ssh` / `rsync` / Julia inside WSL
- SSH E2E uses `./testenv/docker-ssh/scripts/up.sh --e2e` (Docker Compose
  must be visible from WSL)

## Queue host

The always-on **queue host** is **macOS or Linux** (Mac mini, Linux VM;
`enable` is LaunchAgent / systemd). A machine that sleeps is not this
machine. WSL2 is Linux for a **client** or a worker; do not use it as
the always-on queue host.

Install Queue so `julia -m DistSSHQueue` works on this host (default
env or `--project=`). Dedicated **`~/.distsshqueue/env`** is optional:
create it for `qhost:` hops (that path is the default `--queue-env`)
and for `enable`. `setup` does not create it. The table lives at
`~/.distsshqueue/jobs.toml`.

Also install, as in DistSSHKit (the kit parent for each job is this
machine):

- **`ssh`** — passwordless login to each worker
- **`rsync`** — collect / rsync deploy
- **`git`** — git deploy path only

Anyone who can run Queue `submit` as the queue-host user (on that box or
via `qhost:`) can run arbitrary Julia as that user; DistSSHKit then uses
passwordless SSH to every listed worker. The queue host and its workers
are **one trust domain** — the intended lab premise (shared shell
access), not a place for untrusted submitters. `add-host child:` reminds
the person who just added inventory. `add-host child:` also warns that
Kit instantiate on that host needs outbound internet unless the depot
already has the registry and packages (a nonempty `~/.julia` is not
enough by itself).
Same idea as
[kit Requirements](https://yamanori99.github.io/DistSSHKit.jl/stable/requirements/);
how to report a vulnerability stays in [SECURITY.md](https://github.com/yamanori99/DistSSHQueue.jl/blob/main/SECURITY.md).

Do not set `DISTSSHQUEUE_HOST` here (or in `config.toml` `[env]`).
Client verbs still need `qhost:HOST` on the command line; the env
alone does not hop.

## Client

A dev machine. No `~/.distsshqueue` on the client. After `fetch`, the
copied job lands under the job tree's `.distsshqueue/`; fetched logs
and collected directories use `.distsshkit/` inside that destination.
Queue must be loadable from the job env (`julia --project=.`).

- Passwordless SSH from the client to the **queue host** (`qhost:NAME`)
- `rsync` on the client (`qhost:` submit and `fetch`)
- Queue-host Julia: auto, or `--remote-julia` /
  `JULIA_DISTRIBUTED_EXE` (same detection as DistSSHKit)

`qhost:` submit copies the client job tree onto the queue host (and
excludes `.gitignore`, `.git/`, `.distsshkit/`, `.distsshqueue/`), then runs Queue as the **queue-host user**.
`fetch` copies one finished Kit leaf back.
Placement tokens are interpreted **on the queue host**. Omit `qhost:`:
no copy.

## Workers

DistSSHKit hosts. Passwordless SSH **from the queue host**, Julia
1.12+ with the same major.minor. Details:
[kit Requirements](https://yamanori99.github.io/DistSSHKit.jl/stable/requirements/).

## Checks

The `ssh …` snippets below are **examples** you can type yourself — DistSSHQueue
does not run them. Timeouts need not match DistSSHKit (`ConnectTimeout` here is
`5`; the kit uses `10` plus keepalives). Worker probes are DistSSHKit's
(`setup --check` from the queue host). `serve` also runs Kit
`:check` on a `qhost:` stage (DistSSHKit **0.7.3+** warns, not fails,
when that snapshot has no `.git/`).

### Probe the queue host

- `julia --version`
- `uname -s` — Darwin or Linux
- `which rsync`
- `which git` — git deploy path only
- `julia --project=$HOME/.distsshqueue/env -m DistSSHQueue --version`

### Client to queue host

`HOST` is the SSH name in `qhost:HOST`.

```bash
ssh -o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=accept-new HOST echo ok
```

Queue-host Julia (non-interactive `ssh` often has no login `PATH`):

- `$HOME/.juliaup/bin/julia`
- macOS: `/opt/homebrew/bin/julia`, `/usr/local/bin/julia`, `/usr/bin/julia`
- Linux / WSL2: `/usr/bin/julia`, `/usr/local/bin/julia`

```bash
ssh -o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=accept-new HOST '$HOME/.juliaup/bin/julia --version'
```

`--remote-julia` / `JULIA_DISTRIBUTED_EXE` if the binary is elsewhere.

### Probe workers

From the **queue host**, DistSSHKit [Checks](https://yamanori99.github.io/DistSSHKit.jl/stable/requirements/#Checks)
(passwordless SSH, Julia path / version). Example (any env that has
DistSSHKit; dedicated `~/.distsshqueue/env` is optional):

```bash
julia -m DistSSHKit setup --check child:USER@HOST
# or: julia --project=$HOME/.distsshqueue/env -m DistSSHKit setup --check child:USER@HOST
```

### Align Julia with juliaup

`julia -m DistSSHQueue setup --juliaup` wraps DistSSHKit
`juliaup_align_remotes` (same `parent` / `child:NAME` tokens as go /
ride / drive). Do not combine with `--force`. That changes each
target's **juliaup default** only — it does not change a Julia
process that is already running.

Prefer the **queue host**. Channel = this command's major.minor.
Typical labs have passwordless SSH from the queue host to workers,
not from the client:

```bash
# On the queue host: parent = this box; remotes = child:NAME
julia -m DistSSHQueue setup --juliaup parent child:host1
# or omit tokens after add-host:
# julia -m DistSSHQueue setup --juliaup

# From a client: only hosts you can SSH to from this machine.
# parent here is this client, not the queue host.
julia --project=. -m DistSSHKit setup --juliaup child:QHOST
```

After changing the default on the queue host: stop `serve` and start it
again. If you use `enable`, run `enable` again so the OS unit picks up
the new Julia path, then restart serve. Running jobs keep their old
binary; workers usually pick the new default on the next Kit job.
Details: [kit Requirements](https://yamanori99.github.io/DistSSHKit.jl/stable/requirements/).

## [Where files live](@id where-files-live)

Typical paths. `qhost:` is the SSH name of the queue host, not a
storage prefix. The table and Kit result dirs accumulate **on that
box**. `qhost:` submit rsyncs the client job tree to
`~/.distsshqueue/stage/<uuid>`. Kit still copies that tree to workers.
`teardown` removes `~/.distsshqueue` (including `stage/`), not a git
clone or `.distsshkit/`. Ownership and the fetch source/destination
contract are in [Artifacts and paths](@ref Manual-artifacts).

Each job uses one Kit project tree on the queue host:

- Client `qhost:` submit: `stage/<uuid>/`
- Submit while logged in to the queue host: the current
  `DISTRIBUTED_PROJECT_ROOT`

`~/org/Repo.jl` below is only an example. Queue does not add another
job-name directory.

Worker paths need extra care:

- Leave `DISTRIBUTED_REMOTE_PROJECT_ROOT` unset in shared
  `config.toml`.
- Kit defaults to `~/basename(parent)/basename(project)`.
- Projects with the same parent and repository names would collide,
  even when their queue-host paths differ. Queue refuses the second
  project instead of renaming or running `setup --delete`.
- Submitting the same clone again is allowed. Its
  `SCRIPT_<UTC>_<id>/` run leaves are unique.

### Client tree

No `~/.distsshqueue`. The job env only needs Queue loadable for the
CLI.

```text
~/my-job/
  Project.toml          DistSSHQueue (CLI)
  Manifest.toml
  SCRIPT.jl             rsync'd on qhost submit
  .distsshqueue/tickets/<uuid>  after each qhost: submit (kept)
  .distsshqueue/<kind>/<stem>_<id8>/  after fetch
    .distsshqueue-fetch-id
    ...                              primary artifact copy
    .distsshkit/logs/...
    .distsshkit/collect/...
```

### Queue-host tree

Queue state plus **one Kit clone per job** (not `--queue-env`). `enable` writes an OS
unit; skip that file if you only `serve` in a terminal.

```text
~/.distsshqueue/
  config.toml
  jobs.toml             every row (no prune)
  jobs.toml.log
  jobs.toml.pid         while serve is up
  jobs.toml.stopped     after stop, until serve
  env/                  qhost: default --project=; enable if present
    Project.toml
    Manifest.toml
  stage/<uuid>/         client tree after each qhost: submit

~/org/Repo.jl/          example: logged in, no qhost: (cwd / DISTRIBUTED_PROJECT_ROOT)
  Project.toml          compute deps
  Manifest.toml
  SCRIPT.jl
  .distsshkit/runs/<kind>/<run>/  run.toml, kit.pid, kit.result
  .distsshkit/<kind>/<kit leaf>/  Kit artifact
  .distsshkit/setup/*.log         Kit setup logs
```

`enable` unit (same `julia --project=<queue-env> -m DistSSHQueue serve`):

- **macOS** — `~/Library/LaunchAgents/org.distsshqueue.serve.plist`
- **Linux / WSL2** — `~/.config/systemd/user/distsshqueue.serve.service`

Both are user units (no root). `disable` removes that file. The table
and Kit dirs do not change.

### Worker tree

No Queue table. Kit default `~/parent/Repo.jl` from that clone (do not
pin `DISTRIBUTED_REMOTE_PROJECT_ROOT` in shared queue config). Collect
lands on the queue host `{project}/.distsshkit/{kind}/` dir above.

```text
<remote project root>/
  Project.toml
  SCRIPT.jl
```

Next: [Prepare](@ref Tutorial-Prepare).
