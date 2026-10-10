# [API](@id API)

```@meta
CurrentModule = DistSSHQueue
```

Julia entry points when you embed DistSSHQueue. Day-to-day work stays
on the CLI (`julia --project=. -m DistSSHQueue …`); see
[Home](@ref DistSSHQueue.jl).
The longer guide is the
[DistSSHKit manual](https://yamanori99.github.io/DistSSHKit.jl/stable/).
REPL help also works (`?DistSSHQueue.submit!`).

Submitters `using DistSSHQueue`. Queue-host code `using DistSSHKit`.
Job files for `go` / `ride` still do not call DistSSHKit.

Prefer the CLI. From a client: `qhost:HOST` on the command line (not
`--hosts`). `DISTSSHQUEUE_HOST` alone does not hop. CLI `submit` uses `follow_config`; library
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

`Job` persists the artifact-related fields used by cancel and fetch.
Their ownership and fallback order are described in
[Artifacts and paths](https://yamanori99.github.io/DistSSHKit.jl/stable/queue/artifacts/).

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
serve
```

## Paths

```@docs
job_project
default_store_path
```
