# DistSSHQueue.jl

[English](README.md) | [日本語](README.ja.md)

<!-- markdownlint-disable MD013 -->
[![Test](https://img.shields.io/github/actions/workflow/status/yamanori99/DistSSHQueue.jl/CI.yml?branch=main&style=flat-square&logo=githubactions&logoColor=white&label=Test)](https://github.com/yamanori99/DistSSHQueue.jl/actions/workflows/CI.yml)
[![Codecov](https://img.shields.io/codecov/c/github/yamanori99/DistSSHQueue.jl?style=flat-square&logo=codecov&logoColor=white)](https://codecov.io/gh/yamanori99/DistSSHQueue.jl)
[![docs-stable](https://img.shields.io/badge/docs-stable-blue?style=flat-square&logo=gitbook&logoColor=white)](https://yamanori99.github.io/DistSSHQueue.jl/stable/)
[![docs-dev](https://img.shields.io/badge/docs-dev-blue?style=flat-square&logo=gitbook&logoColor=white)](https://yamanori99.github.io/DistSSHQueue.jl/dev/)
[![Julia 1.13+](https://img.shields.io/badge/Julia-1.13+-9558B2?style=flat-square&logo=julia&logoColor=white)](https://yamanori99.github.io/DistSSHKit.jl/dev/requirements/)
[![code style: runic](https://img.shields.io/badge/code_style-%E1%9A%B1%E1%9A%A2%E1%9A%BE%E1%9B%81%E1%9A%B2-black)](https://github.com/fredrikekre/Runic.jl)
[![License](https://img.shields.io/badge/License-MIT-yellow?style=flat-square)](LICENSE)
<!-- markdownlint-enable MD013 -->

DistSSHQueue leaves jobs on a queue host. They run one at a
time. You can submit a job, check its status, fetch a finished leaf,
and cancel. Most people install DistSSHKit, which bundles this
package. `pkg> add DistSSHQueue` is for using the queue on its own.
The longer guide is the
[DistSSHKit manual](https://yamanori99.github.io/DistSSHKit.jl/dev/).
Supported on **macOS, Linux, and WSL2 Ubuntu** (not native Windows).

Even small labs and individuals can keep one always-on machine, add
SSH hosts, and use them together as a small set of compute nodes.
Julia **1.13+**.

## Install

From the Julia REPL, type `]` to enter the Pkg REPL mode and run:

```julia
pkg> add DistSSHQueue
```

Or, equivalently, via the `Pkg` API:

```julia
julia> import Pkg; Pkg.add("DistSSHQueue")
```

The queue host needs **`ssh`**, **`rsync`**, and (only for git
deploys) **`git`**. A client also needs **`ssh`** and **`rsync`**
for `qhost:` submit and `fetch`. `pkg> add` does not install them.
Full requirements:
[Requirements](https://yamanori99.github.io/DistSSHKit.jl/dev/requirements/).

For everything else, see the
**[Documentation](https://yamanori99.github.io/DistSSHQueue.jl/stable/)**.

## Usage

### Basic terms

- **Queue host** — the always-on **macOS or Linux** box that holds
  `~/.distsshqueue` and runs `serve` (a VM is fine). A machine that
  sleeps is not this box. WSL2 is a client or worker, not this role.
- **Client** — a dev machine that submits, lists, watches, fetches, or
  cancels. No cap. The run does not start on a client; it starts
  on the queue host.
- **serve** — FIFO process on the queue host. It starts the
  job (`execute!(…; detached=true)`). Stopping it does not cancel a
  job that is already running.
- **Workers** — where the script runs. Host tokens: `parent[:N]` on
  the queue host, `child:NAME[:N]` on SSH machines.

```text
  clients = dev machines (no cap)         one queue host (always on)
  -------------------------------         --------------------------
  yours / a colleague's / ...             FIFO     one job at a time
       |                                  table    ~/.distsshqueue
       |  julia -m DistSSHQueue           add-host / remove-host
       |    qhost:NAME                    serve    now, this terminal
       |    submit | status | list-host   enable   again after reboot
       |    watch | cancel | fetch | ...
       +--------------------------------> then go / ride / drive
                                          -> workers (host tokens)
```

`qhost:NAME` is the SSH name of the queue host (same idea as
`child:NAME`, but it names that machine, not a worker). Not already
on that box: put `qhost:HOST` on the command line.
`DISTSSHQUEUE_HOST` alone does not hop. Already logged in there?
Omit `qhost:` (this box's cwd is the job tree; placement is still
`parent` / `child:`). Local trial:
`DISTSSHQUEUE_LOCAL=1`. `--hosts` / `--julia` stay on `go` /
`ride` / `drive`.

Host tokens, `go` / `ride` / `drive` flags, and remote setup are in the
[DistSSHKit manual](https://yamanori99.github.io/DistSSHKit.jl/dev/).

### submit

One argv, four nested pieces. `submit` leaves the job on the queue
host. After it, the line is `go` / `ride` / `drive` and the
rest. The same argv, started on this machine now, is in the
[DistSSHKit manual](https://yamanori99.github.io/DistSSHKit.jl/dev/manual/).

```bash
julia --project=. -m DistSSHQueue  [qhost:HOST]  submit  drive  parent:4  SCRIPT.jl
#──────────── Julia ────────────┘  └─ qhost ──┘  submit  └── go / ride / drive ──┘
```

```bash
julia --project=. -m DistSSHQueue [qhost:HOST] submit drive parent:4 SCRIPT.jl
```

Break a long terminal line after `submit` with `\`:

```bash
julia --project=. -m DistSSHQueue [qhost:HOST] submit \
    drive parent:4 child:NAME:N SCRIPT.jl
```

Same argv, started on this machine now. This env needs DistSSHRun.
If DistSSHKit is installed, `julia -m DistSSHKit` is the same command:

```bash
julia -m DistSSHRun drive parent:4 SCRIPT.jl
```

`pool:N` sits next to `submit`. It is not a host token. Full notes:
[submit](https://yamanori99.github.io/DistSSHKit.jl/dev/queue/submit/).

### Where files live

`qhost:` is an SSH name, not a storage prefix.

- The queue and job results stay on the queue host.
- `qhost:` submit stages the client tree at
  `~/.distsshqueue/stage/<uuid>`.
- The client keeps `.distsshqueue/tickets/<uuid>`.
- The script owns result files.
- The run owns the `.distsshkit/` bundle on that machine.
- The queue owns scheduling and the fetched `.distsshqueue/` copy.

The stage excludes `.gitignore`, `.git/`, `.distsshkit/`, and
`.distsshqueue/`. Details:
[Artifacts and paths](https://yamanori99.github.io/DistSSHKit.jl/dev/queue/artifacts/).

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

`~/.distsshqueue` holds the queue. Each `qhost:` job is a project
under `stage/<uuid>/`. `parent` runs from that stage on this box. Leave
`DISTRIBUTED_REMOTE_PROJECT_ROOT` unset in shared config so each
`child:` copy stays `~/stage/<uuid>`.

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
    Project.toml        compute deps
    SCRIPT.jl
    .distsshkit/runs/<kind>/<run>/  run.toml, kit.pid, kit.result
    .distsshkit/<kind>/SCRIPT_<UTC>_<id>/  result_path (the run or the script picks it)
    .distsshkit/setup/*.log         setup logs
```

`enable` (optional; skip if you only `serve` in a terminal):

- **macOS** — `~/Library/LaunchAgents/org.distsshqueue.serve.plist`
- **Linux / WSL2** — `~/.config/systemd/user/distsshqueue.serve.service`

User units (no root). Same command:
`julia --project=<queue-env> -m DistSSHQueue serve`.

#### Workers

`parent` is the queue host. It runs the staged tree in place
(`~/.distsshqueue/stage/<uuid>/`). The queue's table stays next to it.

A `child:` host has no queue table. The job tree is rsynced there
and instantiated before the run:

- No `~/.distsshqueue`, no `jobs.toml`.
- After `qhost:` the copy is `~/stage/<uuid>` (unique per job). Do not
  pin a shared `DISTRIBUTED_REMOTE_PROJECT_ROOT` in `config.toml`.
- Artifacts do not stay here: results are collected back to the queue
  host. The default leaf is `.distsshkit/<kind>/` shown above; a custom
  `output_dir` lands wherever it points, and that path is stored as
  `result_path` (fetch follows it, even outside the project).

```text
~/stage/<uuid>/         child: copy after qhost: submit (this uuid only)
  Project.toml
  Manifest.toml
  SCRIPT.jl
```

### Examples

From a **client** (job directory; this package must be loadable from that env):

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
instantiates the job project there and runs `setup!`
on `child:` hosts before each job (you do not hand-run
`setup` on the stage tree). `:check` always runs there
(a `qhost:` stage with no `.git/` warns). Job ids are a
bare stdout line; stderr shows `Queued  N` unless `DISTSSHKIT_QUIET` is set.
`fetch` copies the finished result to
`.distsshqueue/<kind>/<stem>_<id8>/` in this job tree.

Typed path (prepare the machine → submit / fetch → teardown):
[Walkthrough](https://yamanori99.github.io/DistSSHKit.jl/dev/tutorial/queue-walkthrough/).

On the **queue host** (once). `setup` writes `config.toml`, not `env/`.
From the default Julia env (`julia -m DistSSHQueue`); from a
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
[How it runs](https://yamanori99.github.io/DistSSHKit.jl/dev/queue/).

## Documentation

- Home:
  [Home](https://yamanori99.github.io/DistSSHQueue.jl/stable/)
- Manual:
  [DistSSHKit](https://yamanori99.github.io/DistSSHKit.jl/dev/manual/)
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
