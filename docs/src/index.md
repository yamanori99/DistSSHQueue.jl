# [DistSSHQueue.jl](@id DistSSHQueue.jl)

DistSSHQueue runs jobs one after another on machines that several
people share. You can submit a job, check its status, fetch a finished
leaf, and cancel.
[DistSSHKit](https://yamanori99.github.io/DistSSHKit.jl/stable/) does the run.
Supported on **macOS, Linux, and WSL2 Ubuntu** (not native Windows).

Even small labs and individuals can keep one always-on machine, add
SSH hosts, and use them together as a small set of compute nodes.
Julia **1.12+**, DistSSHKit **0.7.x**. Placement tokens
(`parent[:N]` / `child:NAME[:N]`) stay DistSSHKit's — see the
[kit docs](https://yamanori99.github.io/DistSSHKit.jl/stable/).

## What is DistSSHQueue?

Day to day you **submit** from a client (`qhost:HOST`). If no `serve` is up,
`submit` starts one on the queue host. You do not need `setup`, `serve`, or
`enable` for a job to run.

How you call it:

- **CLI** — `julia --project=. -m DistSSHQueue qhost:HOST submit go …`
- **Julia API** — `submit!` / `cancel!` / `serve!` on a [`Queue`](@ref)
  ([API](@ref API))

`qhost:NAME` names the queue host (like Kit `child:NAME`, but not a worker).
`--hosts` / `--julia` stay on Kit `go` / `ride` / `drive`. Queue-host Julia is
`--remote-julia` / `JULIA_DISTRIBUTED_EXE`.

## Installation

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

Also needs **`ssh`**, **`rsync`**, and **`git`** (git deploy only);
`pkg> add` does not install them. [Requirements](@ref).

## Basic terms

- **Queue host** — the always-on **macOS or Linux** box that holds
  `~/.distsshqueue` and runs `serve`. A sleeping laptop is not this
  box (WSL2 is a client or worker, not this role).
- **Client** — a dev machine that submits, lists, watches, fetches, or cancels. No
  cap. It must not become the Kit master.
- **serve** — FIFO process on the queue host. It starts DistSSHKit
  (`execute!(…; detached=true)`). Stopping it does not cancel a
  Kit job that is already running.
- **Workers** — where the script runs. DistSSHKit tokens: `parent[:N]` on
  the queue host, `child:NAME[:N]` on SSH machines.

Trees (client / queue host / workers): [Where files live](@ref Layout).

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

Queue is not a bigger Kit and does not keep a lab-wide slot ceiling.
`serve` is “run the process”. `enable` is “register that process with the
OS”. They are not two ways to start the same thing.

On a shared queue host that means: one long job holds the whole FIFO
(no preemption, no priority, no per-user fairness). Work started with
DistSSHKit **bypassing** the queue competes for the same workers and is
invisible to Queue. Split long jobs, or agree in the group that shared
hosts are driven only through the queue.

## Next

Start at **[Requirements](@ref)**, then **[Prepare](@ref Tutorial-Prepare)**
(queue host, once). Type the path in **[Walkthrough](@ref Tutorial-Walkthrough)**.
Command catalog: **[First job](@ref Tutorial-Client)**.

Later: [`submit`](@ref Manual-submit), [`status`](@ref Manual-status), and
the rest of the [User Guide](@ref Manual); or the **[API](@ref API)** to
embed from Julia.

## Contributing

Bugs and feature requests:
[Issues](https://github.com/yamanori99/DistSSHQueue.jl/issues).
See
[CONTRIBUTING.md](https://github.com/yamanori99/DistSSHQueue.jl/blob/main/CONTRIBUTING.md).

## License

Source code is
[MIT](https://github.com/yamanori99/DistSSHQueue.jl/blob/main/LICENSE).
