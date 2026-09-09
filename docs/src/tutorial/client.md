# [First job](@id Tutorial-Client)

Submit from a **client** after the queue host is up
([Prepare](@ref Tutorial-Prepare)). Commands in order:
[Walkthrough](@ref Tutorial-Walkthrough). Also see
[User Guide · submit](@ref Manual-submit), [status](@ref Manual-status),
[fetch](@ref Manual-fetch), [Where files live](@ref Layout).

## Point at the queue host

Run from a directory where Queue is loadable (`julia --project=.`).
That `--project=.` stays on the **client**. `qhost:` defaults to
`--project=~/.distsshqueue/env` on the queue host (`--queue-env DIR` /
`--queue-env @`). Create that dir if clients hop (see Prepare).
`qhost:` **rsync**s the client job tree (`cwd` /
`DISTRIBUTED_PROJECT_ROOT`) to `~/.distsshqueue/stage/<uuid>` on the
queue host (Kit rsync excludes: `.gitignore`, `.git/`, `.distsshkit/`,
`.distsshqueue/`). After submit, this job tree has
`.distsshqueue/tickets/<uuid>` (not the Kit leaf; every submit stays).
`SCRIPT.jl` must exist on
the **client** in that tree.
Omit `qhost:`: no rsync; the script is on this machine. Kit still
copies queue host → workers.

```bash
julia --project=. -m DistSSHQueue qhost:HOST list-host
julia --project=. -m DistSSHQueue qhost:HOST size
julia --project=. -m DistSSHQueue qhost:HOST plan SCRIPT.jl
julia --project=. -m DistSSHQueue qhost:HOST pool
```

One queue host: still pass `qhost:HOST` (or `status qhost:HOST`).
`DISTSSHQUEUE_HOST` is not enough. Local trial without a hop:
`DISTSSHQUEUE_LOCAL=1`. Several clusters: pass `qhost:` each time.

`list-host` is not Kit `--hosts`. `ssh -G` runs on the queue host.
`size` / `plan` / `pool` are DistSSHKit inspect verbs there (do not enqueue).

## Submit

One line, nested the same way as [User Guide · submit](@ref Manual-submit):

```text
julia -m DistSSHQueue  [qhost:HOST]  submit  drive  parent:4  SCRIPT.jl
└── Julia ──┘  └── queue host ──┘  └Queue┘  └──────── DistSSHKit argv ────────┘
```

Kit argv is DistSSHKit's (`go child:NAME:N SCRIPT.jl`, or `parent:N`
when workers are on the queue host). Flags:
[kit go](https://yamanori99.github.io/DistSSHKit.jl/stable/manual/go/),
[kit ride](https://yamanori99.github.io/DistSSHKit.jl/stable/manual/ride/),
[kit drive](https://yamanori99.github.io/DistSSHKit.jl/stable/manual/drive/).

```bash
julia --project=. -m DistSSHQueue qhost:HOST submit go child:host1:4 SCRIPT.jl
julia --project=. -m DistSSHQueue qhost:HOST status
julia --project=. -m DistSSHQueue qhost:HOST watch
julia --project=. -m DistSSHQueue qhost:HOST cancel <id>
julia --project=. -m DistSSHQueue qhost:HOST fetch <id>  # 8-char prefix or full UUID
julia --project=. -m DistSSHQueue qhost:HOST fetch .distsshqueue/tickets/<uuid>
```

`submit` starts `serve` if none is running. `serve` instantiates the
job project on the queue host and runs Kit `setup!` on `child:` hosts
before `execute!`. `status` / `watch` print
`qhost` (or `local (hostname)` when you omitted it). `watch` is
`status --interval` until Ctrl-C; it does not stop `serve`. Job ids print as a bare
stdout line. `submit` also prints `Queued  N` on stderr unless
`DISTSSHKIT_QUIET` is set. After `qhost:` submit,
`.distsshqueue/tickets/<uuid>` marks the job on this laptop. `fetch`
copies the finished Kit leaf onto this job tree (inverse of the
`qhost:` rsync). Run it from the same directory as `submit`. Drive CSV
(Kit `square_file.jl`) is in that
`.distsshqueue/drive/<stem>_<id8>/` leaf, not `output/`.

A `.jl` with no Queue verb is not implicit `go` (same as Kit). Top-level
`go` / `ride` / `drive` are DistSSHKit; enqueue with `submit`. `ride` is
experimental.

There is no `--via`. Do not pass `qhost:` to `setup` / `serve` /
`enable` / `disable` / `add-host` / `remove-host`.

Next: [Walkthrough](@ref Tutorial-Walkthrough), or [User Guide](@ref Manual).
