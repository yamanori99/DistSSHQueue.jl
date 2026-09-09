# [submit](@id Manual-submit)

Enqueue a DistSSHKit `go`, `ride`, or `drive`. Starts `serve` if none is
running. That `serve` instantiates the job project on the queue host
and runs Kit `setup!` on `child:` hosts before `execute!` (not a
hand-run DistSSHKit `setup` on the stage tree).

```bash
julia --project=. -m DistSSHQueue [qhost:HOST] submit go [Kit go argv]
julia --project=. -m DistSSHQueue [qhost:HOST] submit pool:8 drive SCRIPT.jl
```

A `.jl` with no Queue verb is not implicit `go` (same as Kit). Top-level
`go` / `ride` / `drive` are DistSSHKit; enqueue with `submit`. `ride` is
experimental.

Also: [First job](@ref Tutorial-Client), [Walkthrough](@ref Tutorial-Walkthrough),
[hosts](@ref Manual-hosts),
`julia -m DistSSHQueue --help`. Kit flags:
[go](https://yamanori99.github.io/DistSSHKit.jl/stable/manual/go/),
[ride](https://yamanori99.github.io/DistSSHKit.jl/stable/manual/ride/),
[drive](https://yamanori99.github.io/DistSSHKit.jl/stable/manual/drive/).

CLI `submit` uses `Queue(; follow_config=true)` so each enqueue
re-reads config `hosts`. Library [`submit!`](@ref) uses
`Queue(; allowed=…)` unless `follow_config=true`.

With `qhost:`, the client **rsync**s the job project (`cwd` /
`DISTRIBUTED_PROJECT_ROOT`) to `~/.distsshqueue/stage/<id>` on the
queue host (Kit rsync excludes: `.gitignore`, `.git/`, `.distsshkit/`,
`.distsshqueue/`), then enqueue resolves
`SCRIPT.jl` there. The client gets `.distsshkit/queue/<id>` (a ticket,
not the Kit leaf). [`fetch`](@ref Manual-fetch) copies one finished
Kit leaf back onto that same tree. Omit `qhost:`:
the script is checked on this machine. Job id prints as a bare stdout line. CLI `submit` also prints
`queue: local (HOSTNAME)` then `Queued  N` on stderr (`(R running)` when a job is already running);
`DISTSSHKIT_QUIET` hides that. `pool:N` (before or after the kind) sets
the same `:N` on every config host (clamped by add-host max). Do not
mix with `parent` / `child` tokens. Library [`submit!`](@ref) does not.
Two different projects
that Kit would deploy to the same worker path are refused (no
rename, no `setup --delete`). The same project may be submitted again.

## Flags

Kit `go` / `ride` / `drive` argv is forwarded as-is. Queue does not add a second
flag set. A drive row is `:done` when Kit `ok` is true (listed hosts
must join unless `--best-effort`).

| Flag | Meaning |
| --- | --- |
| `go` / `ride` / `drive` | DistSSHKit kind (`execute!`) |
| Kit tokens | `parent[:N]` / `child:NAME[:N]` (not a Queue ceiling) |
| `--hosts` / `--julia` | Kit's. Queue-host Julia is `--remote-julia` / `JULIA_DISTRIBUTED_EXE` |
| `-v` / `--version` | On `submit go` / `ride` / `drive`: Kit only |
| `-h` / `--help` | Kit help for that kind |

Opt out of auto `serve`: `DISTSSHQUEUE_NO_AUTOSERVE=1`. A prior
[`stop`](@ref Manual-serve) also holds `serve` off until an
explicit `serve`.

A `:running` Kit job is not stopped when `hosts` changes. `:queued`
rows still start if a name is later removed.
