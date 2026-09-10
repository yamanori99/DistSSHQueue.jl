# [Prepare](@id Tutorial-Prepare)

First-time **queue host** before a [First job](@ref Tutorial-Client).
Typed path (submit / fetch / teardown): [Walkthrough](@ref Tutorial-Walkthrough).
This box is always-on **macOS or Linux**. Clients can skip this page if
someone already set that box up.

Also see [Requirements](@ref), [Where files live](@ref Layout),
[User Guide · setup](@ref Manual-setup),
[Introduction](@ref DistSSHQueue.jl).

`setup` / `serve` / `enable` / `disable` / `add-host` / `remove-host`
refuse `qhost:` — log in to the queue host and run them there.

## Config and inventory

Queue must be loadable here. `setup` does not install the package and
does not create `~/.distsshqueue/env`. It writes
`~/.distsshqueue/config.toml` if missing. That tree (config / store) is
not the same as `julia --project=`.

Default Julia env (`pkg> add DistSSHQueue` there):

```bash
julia -m DistSSHQueue setup
julia -m DistSSHQueue add-host parent child:host1
julia -m DistSSHQueue list-host
julia -m DistSSHQueue serve
```

From a checkout of this package, the same verbs with `--project=.`.

Defaults work without `config.toml`. `--force` rewrites it. Use it for
`store=` or `[env]`.

`add-host` writes Kit tokens into config `hosts`
(`parent[:N]` / `child:NAME[:N]`). `parent` is this queue host;
`child:NAME` is SSH. `add-host child:` warns that submitters as this user
can reach that SSH name ([Requirements](@ref)). First add creates the
list. CLI submit with a placement token and no `hosts` is an error.
Optional `:N` is a max. No `serve` restart: the next
`submit` re-reads the file. `list-host` NAME for parent is the hostname;
TOKEN stays `parent`. JULIA is that host's `juliaup default`
(`-` if missing, SSH/`status` fails, or no `*` row).

Do not `cd` the stage tree and run DistSSHKit `setup` by hand. `serve`
`Pkg.instantiate`s that tree on the queue host, then Kit `setup!`
(`rsync` → `instantiate`, then `check` only if the tree has `.git/`)
on `child:` hosts, unless
`DISTSSHQUEUE_NO_KIT_SETUP=1`. A `qhost:` stage omits `.git/`, so
`:check` is skipped there (Kit still fatals on a missing local
commit; Queue does not run that exam on a snapshot). Leave
`DISTRIBUTED_REMOTE_PROJECT_ROOT` unset in queue `config.toml` so Kit
uses `~/parent/Repo.jl` per clone.
[kit Prepare](https://yamanori99.github.io/DistSSHKit.jl/stable/tutorial/prepare/).
To align Julia versions, Queue `setup --juliaup` on the queue host
(`parent` / `child:NAME`; see [Requirements](@ref)).

## Dedicated env (optional)

Create `~/.distsshqueue/env` when clients `qhost:` (`qhost:` defaults to
`--project=~/.distsshqueue/env`) or when `enable` should not pin a
checkout. Skip it if you only `setup` / `add-host` / `serve` from an env
that already has DistSSHQueue. `--queue-env @` is the remote default
Julia env (no `--project=`).

```bash
mkdir -p ~/.distsshqueue/env
cd ~/.distsshqueue/env
julia --project=.
```

```julia
pkg> add DistSSHQueue
```

That pulls DistSSHKit **0.7.x** from General. A different dir is
`--queue-env DIR` on `enable` and on client `qhost:`.

## Survive reboot (optional)

```bash
julia --project=. -m DistSSHQueue enable --queue-env ~/.distsshqueue/env
```

`--queue-env` is the env that loads Queue in the OS unit, not Julia
`--project=` / the Kit project. After that, clients only `submit`. You do
not leave a `serve` terminal open. If there is no dedicated dir,
`enable` uses the active project.

Next: [Walkthrough](@ref Tutorial-Walkthrough), or [First job](@ref Tutorial-Client).
