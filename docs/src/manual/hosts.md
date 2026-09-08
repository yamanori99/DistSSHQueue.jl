# [hosts](@id Manual-hosts)

Lab inventory and DistSSHKit `size` / `plan` / `pool` on the queue host. These verbs do
not enqueue. Not Kit `--hosts` (that still names workers on `go` /
`ride` / `drive`).

```bash
julia -m DistSSHQueue add-host parent child:host1
julia -m DistSSHQueue list-host
julia -m DistSSHQueue size
julia -m DistSSHQueue remove-host child:host1
```

From a **client**, `list-host`, `size`, `plan`, and `pool` are forwarded like `status`.
`add-host` / `remove-host` run on the queue host only (like `setup`).
A major.minor Julia mismatch vs this process is a warning only
(`DISTSSHKIT_QUIET` silences it). Fix: `setup --juliaup`.

Also: [Prepare](@ref Tutorial-Prepare), [submit](@ref Manual-submit),
[kit size](https://yamanori99.github.io/DistSSHKit.jl/stable/manual/size/),
[kit plan](https://yamanori99.github.io/DistSSHKit.jl/stable/manual/plan/),
[kit pool](https://yamanori99.github.io/DistSSHKit.jl/stable/manual/pool/).

## add-host / remove-host

Write Kit tokens into config `hosts`
(`parent[:N]` / `child:NAME[:N]`). `parent` is slots on this queue
host, not an SSH Host named parent. `child:NAME` is SSH `Host NAME`.
Optional `:N` is a per-name max. Bare `host1` is not a token.

| | |
| --- | --- |
| Missing `hosts` | Allow all names |
| First `add-host` | Creates the list (submit is no longer allow-all) |
| `hosts = []` | Last `remove-host`; submit accepts none |
| Leftover `allowed` | Still read until rewritten to `hosts` |

No `serve` restart. Next [`submit`](@ref Manual-submit) re-reads the
file. A `:running` Kit job is not stopped.

## list-host

Read-only. NAME for `parent` is this queue host's hostname; HOST TOKEN
stays `parent` (copy-paste for `submit`, including `parent:N`). Children:
NAME is the SSH Host, HOST TOKEN is `child:NAME`. `ssh -G` (Host /
HostName / User / Port) runs on the queue host. No private keys or
IdentityFile. Locally, parent SSH is `this machine (hostname)`. Via
`qhost:`, it is `queue host (hostname)` — not the client's hostname.

```bash
julia -m DistSSHQueue qhost:mini list-host
```

## size

DistSSHKit `size` on the queue host (cwd / project). Omit tokens to size
config `hosts`. Does not enqueue. Prints a `submit drive` template.

```bash
julia -m DistSSHQueue qhost:mini size
julia -m DistSSHQueue qhost:mini size --gb-per-worker 1.5 parent child:host1
```

Kit flags (`--probe`, `--gb-per-worker`, …):
[kit size](https://yamanori99.github.io/DistSSHKit.jl/stable/manual/size/).
`size --help` adds a Queue note under the Kit help.

## plan

DistSSHKit `plan` on the queue host (cwd / project). Inspects a script
and suggests `go` / `ride` / `drive`. Does not enqueue. Prints a
`submit` template for that kind.

```bash
julia -m DistSSHQueue qhost:mini plan SCRIPT.jl
```

Kit flags:
[kit plan](https://yamanori99.github.io/DistSSHKit.jl/stable/manual/plan/).
`plan --help` adds a Queue note under the Kit help.

## pool

DistSSHKit `pool` on the queue host (cwd / project). Cores / RAM / slot
hint (no RSS). Omit tokens to pool config `hosts`. Does not enqueue.
Prints sizing notes and a `Suggested submit (template):` footer (always
`submit drive`; use `size` to measure RSS).

```bash
julia -m DistSSHQueue qhost:mini pool
julia -m DistSSHQueue qhost:mini pool parent child:host1
```

Kit flags:
[kit pool](https://yamanori99.github.io/DistSSHKit.jl/stable/manual/pool/).
`pool --help` adds a Queue note under the Kit help.
