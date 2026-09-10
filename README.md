# DistSSHQueue.jl

[English](README.md) | [日本語](README.ja.md)

<!-- markdownlint-disable MD013 -->
[![Test](https://img.shields.io/github/actions/workflow/status/yamanori99/DistSSHQueue.jl/CI.yml?branch=main&style=flat-square&logo=githubactions&logoColor=white&label=Test)](https://github.com/yamanori99/DistSSHQueue.jl/actions/workflows/CI.yml)
[![PkgEval](https://raw.githubusercontent.com/yamanori99/DistSSHQueue.jl/main/docs/src/assets/pkgeval.svg)](https://juliaci.github.io/NanosoldierReports/pkgeval_badges/D/DistSSHQueue.html)
[![Codecov](https://img.shields.io/codecov/c/github/yamanori99/DistSSHQueue.jl?style=flat-square&logo=codecov&logoColor=white)](https://codecov.io/gh/yamanori99/DistSSHQueue.jl)
[![docs-stable](https://img.shields.io/badge/docs-stable-blue?style=flat-square&logo=gitbook&logoColor=white)](https://yamanori99.github.io/DistSSHQueue.jl/stable/)
[![docs-dev](https://img.shields.io/badge/docs-dev-blue?style=flat-square&logo=gitbook&logoColor=white)](https://yamanori99.github.io/DistSSHQueue.jl/dev/)
[![Julia 1.12+](https://img.shields.io/badge/Julia-1.12+-9558B2?style=flat-square&logo=julia&logoColor=white)](https://yamanori99.github.io/DistSSHQueue.jl/stable/requirements/)
[![License](https://img.shields.io/badge/License-MIT-yellow?style=flat-square)](LICENSE)
<!-- markdownlint-enable MD013 -->

DistSSHQueue runs jobs one after another on machines that several
people share. You can submit a job, check its status, fetch a finished
leaf, and cancel.
[DistSSHKit](https://github.com/yamanori99/DistSSHKit.jl) does the run.
Supported on **macOS, Linux, and WSL2 Ubuntu** (not native Windows).

Even small labs and individuals can keep one always-on machine, add
SSH hosts, and use them together as a small set of compute nodes.
Julia **1.12+**, DistSSHKit **0.7.x**.

## Install

From the Julia REPL, type `]` to enter the Pkg REPL mode and run:

```julia
pkg> add DistSSHQueue
```

Or, equivalently, via the `Pkg` API:

```julia
julia> import Pkg; Pkg.add("DistSSHQueue")
```

DistSSHKit **0.7.x** comes from General with it. Do not `Pkg.develop`
Kit for ordinary Queue work.

The queue host also needs **`ssh`**, **`rsync`**, and (only for git
deploys) **`git`** — `pkg> add` does not install them. Full requirements:
[Requirements](https://yamanori99.github.io/DistSSHQueue.jl/stable/requirements/).

For everything else, see the
**[Documentation](https://yamanori99.github.io/DistSSHQueue.jl/stable/)**.

## Usage

### Basic terms

- **Queue host** — the always-on **macOS or Linux** box that holds
  `~/.distsshqueue` and runs `serve` (a VM is fine). A machine that
  sleeps is not this box. WSL2 is a client or worker, not this role.
- **Client** — a dev machine that submits, lists, watches, fetches, or
  cancels. No cap. It must not become the Kit master.
- **serve** — FIFO process on the queue host. It starts DistSSHKit
  (`execute!(…; detached=true)`). Stopping it does not cancel a
  Kit job that is already running.
- **Workers** — where the script runs. DistSSHKit tokens: `parent[:N]` on
  the queue host, `child:NAME[:N]` on SSH machines.

```text
  clients = dev machines (no cap)         one queue host (always on)
  -------------------------------         --------------------------
  yours / a colleague's / ...             FIFO     one Kit job at a time
       |                                  table    ~/.distsshqueue
       |  julia -m DistSSHQueue           add-host / remove-host
       |    qhost:NAME                    serve    now, this terminal
       |    submit | status | list-host   enable   again after reboot
       |    watch | cancel | fetch | ...
       +--------------------------------> then DistSSHKit go/ride/drive
                                          -> workers (Kit tokens)
```

`qhost:NAME` is the SSH name of the queue host (same idea as Kit
`child:NAME`, but it names the queue host, not a worker). Not already
on that box: put `qhost:HOST` on the command line. `DISTSSHQUEUE_HOST` alone does not
hop. Already logged in on the queue host? Omit `qhost:` (this box's cwd
is the Kit tree; placement is still `parent` / `child:`). Local trial:
`DISTSSHQUEUE_LOCAL=1`. `--hosts` / `--julia` stay on Kit `go` / `ride` / `drive`.

Placement tokens, `go` / `ride` / `drive` flags, and remote setup are DistSSHKit's —
see the [kit docs](https://yamanori99.github.io/DistSSHKit.jl/stable/).

### submit

One argv, four nested pieces. `submit` is Queue. After it, the line is
DistSSHKit argv (`go` / `ride` / `drive` and the rest) and runs as-is
with `-m DistSSHKit` (no Queue). That Kit command starts compute on
**this** machine now; `submit` only enqueues the same argv.

```bash
julia --project=. -m DistSSHQueue  [qhost:HOST]  submit  drive  parent:4  SCRIPT.jl
#──────────── Julia ────────────┘  └─ qhost ──┘  Queue   └─── DistSSHKit argv ────┘
```

```bash
julia --project=. -m DistSSHQueue [qhost:HOST] submit drive parent:4 SCRIPT.jl
```

Break a long terminal line after `submit` with `\`:

```bash
julia --project=. -m DistSSHQueue [qhost:HOST] submit \
    drive parent:4 child:NAME:N SCRIPT.jl
```

Same DistSSHKit argv, no queue:

```bash
julia --project=. -m DistSSHKit drive parent:4 SCRIPT.jl
```

`pool:N` is Queue (next to `submit`), not a Kit token. Full notes:
[submit](https://yamanori99.github.io/DistSSHQueue.jl/stable/manual/submit/).

### Where files live

`qhost:` is the SSH name of the queue host, not a storage prefix. The
table and Kit result dirs stay **on that box**. The client has no
`~/.distsshqueue`. `qhost:` submit rsyncs the client job tree to
`~/.distsshqueue/stage/<uuid>` (same excludes as Kit rsync: `.gitignore`,
`.git/`, `.distsshkit/`, `.distsshqueue/`); the client keeps
`.distsshqueue/tickets/<uuid>` (every submit). Kit still copies queue
host → workers. `fetch` copies one finished Kit leaf back.

#### Client

```text
~/my-job/
  Project.toml          DistSSHQueue (CLI)
  Manifest.toml
  SCRIPT.jl             rsync'd on qhost: submit
  .distsshqueue/tickets/<uuid>  after each qhost: submit (kept)
  .distsshqueue/go/     after fetch
  .distsshqueue/ride/   after fetch
  .distsshqueue/drive/  after fetch
```

#### Queue host

`~/.distsshqueue` plus **one Kit tree per job**. Client `qhost:` submit:
`stage/<uuid>/`. Logged in on the queue host (no `qhost:`): this box's
cwd / `DISTRIBUTED_PROJECT_ROOT` (example `~/org/Repo.jl`, not a reserved
path). Not `--queue-env`. Do not set `DISTRIBUTED_REMOTE_PROJECT_ROOT` in
shared `config.toml`. `submit` errors if a second project would land on
the same worker path.

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
  SCRIPT.jl
  .distsshkit/go/
    SCRIPT_<UTC>_<id>/  result_path
      kit.pid
      kit.result
  .distsshkit/ride/
    SCRIPT_<UTC>_<id>/  same allocate
  .distsshkit/drive/
    SCRIPT_<UTC>_<id>/  same allocate; not demo output/
```

`enable` (optional; skip if you only `serve` in a terminal):

- **macOS** — `~/Library/LaunchAgents/org.distsshqueue.serve.plist`
- **Linux / WSL2** — `~/.config/systemd/user/distsshqueue.serve.service`

User units (no root). Same command:
`julia --project=<queue-env> -m DistSSHQueue serve`.

#### Workers

No Queue table. Kit default `~/parent/Repo.jl` (not a shared `[env]`
remote).
Collect lands in the queue-host `.distsshkit/` dir above.

```text
<remote project root>/
  Project.toml
  SCRIPT.jl
```

### Examples

From a **client** (job directory; Queue must be loadable from that env):

```bash
julia --project=. -m DistSSHQueue qhost:HOST list-host
julia --project=. -m DistSSHQueue qhost:HOST size
julia --project=. -m DistSSHQueue qhost:HOST plan SCRIPT.jl
julia --project=. -m DistSSHQueue qhost:HOST pool
julia --project=. -m DistSSHQueue qhost:HOST submit go child:host1:4 SCRIPT.jl
julia --project=. -m DistSSHQueue qhost:HOST status
julia --project=. -m DistSSHQueue qhost:HOST watch
julia --project=. -m DistSSHQueue qhost:HOST cancel <id>
julia --project=. -m DistSSHQueue qhost:HOST fetch <id>  # 8-char prefix or full UUID
julia --project=. -m DistSSHQueue qhost:HOST fetch .distsshqueue/tickets/<uuid>
```

`submit` starts `serve` on the queue host if none is running. `serve`
instantiates the job project on the queue host and runs Kit `setup!`
on `child:` hosts before each job (you do not hand-run DistSSHKit
`setup` on the stage tree). Kit `:check` runs only when the job tree
has `.git/`; a `qhost:` stage omits it. Job ids are a
bare stdout line; stderr shows `Queued  N` unless `DISTSSHKIT_QUIET` is set.
`fetch` copies the finished Kit leaf onto this job tree.

Typed path (queue host → submit / fetch → teardown):
[Walkthrough](https://yamanori99.github.io/DistSSHQueue.jl/stable/tutorial/walkthrough/).

On the **queue host** (once). `setup` writes `config.toml`, not `env/`.
Queue in the default Julia env (`julia -m DistSSHQueue`); from a
checkout add `--project=.`.

```bash
julia -m DistSSHQueue setup
julia -m DistSSHQueue add-host parent child:host1
julia -m DistSSHQueue serve
```

`qhost:` defaults to `--project=~/.distsshqueue/env` (`--queue-env @`
for the remote default env). `enable` uses that dir if present.
`setup` / `serve` / `enable` / `disable` / `add-host` / `remove-host`
refuse `qhost:`. Command reference:
[User Guide](https://yamanori99.github.io/DistSSHQueue.jl/stable/manual/).

## Documentation

- Introduction:
  [Introduction](https://yamanori99.github.io/DistSSHQueue.jl/stable/)
- First Steps:
  [First Steps](https://yamanori99.github.io/DistSSHQueue.jl/stable/requirements/)
- User Guide:
  [User Guide](https://yamanori99.github.io/DistSSHQueue.jl/stable/manual/)
- API: [API](https://yamanori99.github.io/DistSSHQueue.jl/stable/api/)
- News: [NEWS.md](NEWS.md)

## Contributing

Bugs and feature requests: [Issues](https://github.com/yamanori99/DistSSHQueue.jl/issues).
See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

Source code is [MIT](LICENSE).

<!-- markdownlint-disable MD033 -->
<p align="center">
  <picture>
    <source
      media="(prefers-color-scheme: dark)"
      srcset="https://raw.githubusercontent.com/yamanori99/DistSSHQueue.jl/main/docs/src/assets/logo/logo-dark-static.svg">
    <source
      media="(prefers-color-scheme: light)"
      srcset="https://raw.githubusercontent.com/yamanori99/DistSSHQueue.jl/main/docs/src/assets/logo/logo-static.svg">
    <img
      src="https://raw.githubusercontent.com/yamanori99/DistSSHQueue.jl/main/docs/src/assets/logo/logo-static.png"
      width="210"
      alt="DistSSHQueue.jl logo"/>
  </picture>
</p>
<!-- markdownlint-enable MD033 -->
