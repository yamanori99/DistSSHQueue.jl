# [DistSSHQueue.jl](@id DistSSHQueue.jl)

Leave jobs on a machine that stays on. They run one at a time. You can
submit a job, check its status, fetch a finished leaf, and cancel.
Supported on **macOS, Linux, and WSL2 Ubuntu** (not native Windows).

The longer guide is the
[DistSSHKit manual](https://yamanori99.github.io/DistSSHKit.jl/dev/).

## Install

```julia
pkg> add DistSSHQueue
```

Julia **1.13+**. The machine that stays on needs **`ssh`** and
**`rsync`**. Git deploys also need **`git`**.

## Commands

The command is `julia -m DistSSHQueue`.

```bash
julia -m DistSSHQueue qhost:HOST submit go SCRIPT.jl
julia -m DistSSHQueue status
julia -m DistSSHQueue fetch ID
```

```julia
using DistSSHQueue
q = Queue(; store=default_store_path(), follow_config=true)
id = submit!(q, "SCRIPT.jl", "child:host1:4"; kind=:go)
```
