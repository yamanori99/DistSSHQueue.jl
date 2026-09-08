# [API](@id API)

```@meta
CurrentModule = DistSSHQueue
```

Julia entry points when you embed DistSSHQueue. Day-to-day work stays
on the CLI (`julia --project=. -m DistSSHQueue …`); see
[Introduction](@ref DistSSHQueue.jl),
[First Steps](@ref Tutorial-Walkthrough), and the [User Guide](@ref Manual).
REPL help also works (`?DistSSHQueue.submit!`).

Submitters `using DistSSHQueue`. Queue-host code `using DistSSHKit`.
Job files for Kit `go` / `ride` still do not import DistSSHKit.

Prefer the CLI. From a client: `qhost:HOST` (not `--hosts`). Default
queue host: `DISTSSHQUEUE_HOST`. CLI `submit` uses `follow_config`; library
[`submit!`](@ref) uses `Queue(; allowed=…)` unless `follow_config=true`.
Config: `~/.distsshqueue/config.toml`.

```julia
using DistSSHQueue

q = Queue(; store=default_store_path(), follow_config=true)
id = submit!(q, "SCRIPT.jl", "child:host1:4"; kind=:go)
cancel!(q, id)
serve!(q)
```

## Types

```@docs
DistSSHQueue
Queue
Job
```

## Enqueue and cancel

```@docs
submit!
cancel!
```

## Table

```@docs
jobs
job
load!
step!
```

## serve

```@docs
serve!
```

## Paths

```@docs
job_project
```

`default_store_path()` is `~/.distsshqueue/jobs.toml`.
`serve` calls DistSSHKit `execute!(…; detached=true, job_id=…)`.
