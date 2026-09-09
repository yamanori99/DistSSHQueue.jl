# [submit](@id Manual-submit)

Enqueue a DistSSHKit `go`, `ride`, or `drive`. Starts `serve` if none is
running. That `serve` instantiates the job project on the queue host
and runs Kit `setup!` on `child:` hosts before `execute!` (not a
hand-run DistSSHKit `setup` on the stage tree).

One argv, four nested pieces. `qhost:HOST` is the SSH name of the
always-on queue machine (omit it when you are already logged in there).
`submit` is Queue. The next word is the DistSSHKit kind (`go` / `ride` /
`drive`); after that, argv matches DistSSHKit.

```text
julia -m DistSSHQueue  [qhost:HOST]  submit  drive  parent:4  SCRIPT.jl
└── Julia ──┘  └── queue host ──┘  └Queue┘  └──────── DistSSHKit argv ────────┘
```

```bash
julia --project=. -m DistSSHQueue [qhost:HOST] submit drive parent:4 SCRIPT.jl
```

`pool:N` is Queue, not Kit: it expands config `hosts` to the same `:N`
(clamped by add-host max). Place it next to `submit` (before or after
the kind), not among `parent` / `child` tokens. Library [`submit!`](@ref)
does not expand `pool:N`.

```bash
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
`DISTRIBUTED_PROJECT_ROOT`) to `~/.distsshqueue/stage/<uuid>` on the
queue host (Kit rsync excludes: `.gitignore`, `.git/`, `.distsshkit/`,
`.distsshqueue/`), then enqueue resolves
`SCRIPT.jl` there. The client keeps `.distsshqueue/tickets/<uuid>`
(every `qhost:` submit from this tree; not the Kit leaf). [`fetch`](@ref Manual-fetch) copies one finished
Kit leaf back onto that same tree. Omit `qhost:`:
the script is checked on this machine. Job id prints as a bare stdout line. CLI `submit` also prints
`queue: local (HOSTNAME)` (or `queue: qhost:HOST` when you passed `qhost:`) then `Queued  N` on stderr (`(R running)` when a job is already running);
`DISTSSHKIT_QUIET` hides that. Missing config `hosts` is allow-all; submit then prints `no add-host list; any child: is accepted`.

Two different projects
that Kit would deploy to the same worker path are refused (no
rename, no `setup --delete`). The same project may be submitted again.

## Flags

Kit `go` / `ride` / `drive` argv is forwarded as-is. Queue's extra on
this line is `pool:N` (above). A drive row is `:done` when Kit `ok` is true (listed hosts
must join unless `--best-effort`).

| Flag | Meaning |
| --- | --- |
| `go` / `ride` / `drive` | DistSSHKit kind (`execute!`) |
| Kit tokens | `parent[:N]` / `child:NAME[:N]` (not a Queue ceiling) |
| `pool:N` | Queue: same `:N` on every config host |
| `--hosts` / `--julia` | Kit's. Queue-host Julia is `--remote-julia` / `JULIA_DISTRIBUTED_EXE` |
| `-v` / `--version` | On `submit go` / `ride` / `drive`: Kit only |
| `-h` / `--help` | Kit help for that kind |

Opt out of auto `serve`: `DISTSSHQUEUE_NO_AUTOSERVE=1`. A prior
[`stop`](@ref Manual-serve) also holds `serve` off until an
explicit `serve`.

A `:running` Kit job is not stopped when `hosts` changes. `:queued`
rows still start if a name is later removed.
