# DistSSHQueue.jl

[English](README.md) | [日本語](README.ja.md)

<!-- markdownlint-disable MD013 -->
[![Test](https://img.shields.io/github/actions/workflow/status/yamanori99/DistSSHQueue.jl/CI.yml?branch=main&style=flat-square&logo=githubactions&logoColor=white&label=Test)](https://github.com/yamanori99/DistSSHQueue.jl/actions/workflows/CI.yml)
[![PkgEval](https://raw.githubusercontent.com/yamanori99/DistSSHQueue.jl/main/docs/src/assets/pkgeval.svg)](https://juliaci.github.io/NanosoldierReports/pkgeval_badges/D/DistSSHQueue.html)
[![Codecov](https://img.shields.io/codecov/c/github/yamanori99/DistSSHQueue.jl?style=flat-square&logo=codecov&logoColor=white)](https://codecov.io/gh/yamanori99/DistSSHQueue.jl)
[![docs-stable](https://img.shields.io/badge/docs-stable-blue?style=flat-square&logo=gitbook&logoColor=white)](https://yamanori99.github.io/DistSSHQueue.jl/stable/)
[![docs-dev](https://img.shields.io/badge/docs-dev-blue?style=flat-square&logo=gitbook&logoColor=white)](https://yamanori99.github.io/DistSSHQueue.jl/dev/)
[![Julia 1.12+](https://img.shields.io/badge/Julia-1.12+-9558B2?style=flat-square&logo=julia&logoColor=white)](https://yamanori99.github.io/DistSSHQueue.jl/stable/requirements/)
[![code style: runic](https://img.shields.io/badge/code_style-%E1%9A%B1%E1%9A%A2%E1%9A%BE%E1%9B%81%E1%9A%B2-black)](https://github.com/fredrikekre/Runic.jl)
[![License](https://img.shields.io/badge/License-MIT-yellow?style=flat-square)](LICENSE)
<!-- markdownlint-enable MD013 -->

DistSSHQueue runs jobs one after another on machines that several
people share. You can submit a job, check its status, fetch a finished
leaf, and cancel.
[DistSSHKit](https://github.com/yamanori99/DistSSHKit.jl) does the run.
Supported on **macOS, Linux, and WSL2 Ubuntu** (not native Windows).

Even small labs and individuals can keep one always-on machine, add
SSH hosts, and use them together as a small set of compute nodes.
Julia **1.12+**, DistSSHKit **0.8.x**.

## Install

From the Julia REPL, type `]` to enter the Pkg REPL mode and run:

```julia
pkg> add DistSSHQueue
```

Or, equivalently, via the `Pkg` API:

```julia
julia> import Pkg; Pkg.add("DistSSHQueue")
```

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
on that box: put `qhost:HOST` on the command line.
`DISTSSHQUEUE_HOST` alone does not hop. Already logged in on the queue
host? Omit `qhost:` (this box's cwd is the Kit tree; placement is still
`parent` / `child:`). Local trial:
`DISTSSHQUEUE_LOCAL=1`. `--hosts` / `--julia` stay on Kit `go` /
`ride` / `drive`.

Placement tokens, `go` / `ride` / `drive` flags, and remote setup are
DistSSHKit's — see the
[kit docs](https://yamanori99.github.io/DistSSHKit.jl/stable/).

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

`qhost:` is an SSH name, not a storage prefix.

- The queue table and Kit results stay on the queue host.
- `qhost:` submit stages the client tree at
  `~/.distsshqueue/stage/<uuid>`.
- The client keeps `.distsshqueue/tickets/<uuid>`.
- The script owns result files.
- Kit owns the queue-host `.distsshkit/` run bundle.
- Queue owns scheduling and the fetched `.distsshqueue/` copy.

The stage excludes `.gitignore`, `.git/`, `.distsshkit/`, and
`.distsshqueue/`. Details:
[Artifacts and paths](https://yamanori99.github.io/DistSSHQueue.jl/stable/manual/artifacts/).

#### Client

```text
~/my-job/
  Project.toml          DistSSHQueue (CLI)
  Manifest.toml
  SCRIPT.jl             rsync'd on qhost: submit
  .distsshqueue/tickets/<uuid>  after each qhost: submit (kept)
  .distsshqueue/<kind>/<stem>_<id8>/  after fetch
    .distsshqueue-fetch-id
    ...                              primary artifact copy
    .distsshkit/logs/...
    .distsshkit/collect/...
```

#### Queue host

`~/.distsshqueue` holds Queue state. Each job also uses one Kit project:

- Client `qhost:` submit: `stage/<uuid>/`
- Logged in on the queue host: cwd / `DISTRIBUTED_PROJECT_ROOT`

The job project below (`~/my-job/`) is just an example directory, not a
reserved path, and is separate from `--queue-env`. Leave
`DISTRIBUTED_REMOTE_PROJECT_ROOT` unset in shared config; `submit`
rejects projects that would collide on a worker.

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

~/my-job/               the job project on this box (logged-in submit; cwd / DISTRIBUTED_PROJECT_ROOT)
  Project.toml          compute deps
  SCRIPT.jl
  .distsshkit/runs/<kind>/<run>/  run.toml, kit.pid, kit.result
  .distsshkit/<kind>/SCRIPT_<UTC>_<id>/  result_path (Kit/script picks it)
  .distsshkit/setup/*.log         Kit setup logs
```

`enable` (optional; skip if you only `serve` in a terminal):

- **macOS** — `~/Library/LaunchAgents/org.distsshqueue.serve.plist`
- **Linux / WSL2** — `~/.config/systemd/user/distsshqueue.serve.service`

User units (no root). Same command:
`julia --project=<queue-env> -m DistSSHQueue serve`.

#### Workers

A worker holds no Queue state. Kit (not Queue) rsyncs the job project
from the queue host and instantiates it there before the run:

- No `~/.distsshqueue`, no `jobs.toml`.
- Default path is `~/basename(parent)/basename(project)` — with parent
  `host1` and project `Repo.jl`, that is `~/host1/Repo.jl`. Do not pin a
  shared `DISTRIBUTED_REMOTE_PROJECT_ROOT` in `config.toml`.
- Artifacts do not stay here: Kit collects results back to the queue
  host. The default leaf is `.distsshkit/<kind>/` shown above; a custom
  Kit `output_dir` lands wherever it points, and Queue persists that as
  `result_path` (fetch follows it, even outside the project).

```text
~/<parent>/<project>/   e.g. ~/host1/Repo.jl (Kit rsyncs it here)
  Project.toml          same deps as the queue-host tree
  Manifest.toml
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
julia --project=. -m DistSSHQueue qhost:HOST fetch <id>
julia --project=. -m DistSSHQueue qhost:HOST fetch .distsshqueue/tickets/<uuid>
```

`submit` starts `serve` on the queue host if none is running. `serve`
instantiates the job project on the queue host and runs Kit `setup!`
on `child:` hosts before each job (you do not hand-run DistSSHKit
`setup` on the stage tree). Kit `:check` always runs there
(DistSSHKit **0.7.3+** warns if a `qhost:` stage has no `.git/`). Job ids are a
bare stdout line; stderr shows `Queued  N` unless `DISTSSHKIT_QUIET` is set.
`fetch` copies the finished result to
`.distsshqueue/<kind>/<stem>_<id8>/` in this job tree.

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
