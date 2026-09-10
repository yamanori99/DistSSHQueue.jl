# [fetch](@id Manual-fetch)

Copy one finished Kit result leaf onto this job tree. Inverse of
`qhost:` stage (Kit rsync excludes: `.gitignore`, `.git/`, `.distsshkit/`,
`.distsshqueue/`). `qhost:` submit leaves
`.distsshqueue/tickets/<uuid>` on this tree (one file per job, kept).
That file is not the Kit leaf.

```bash
julia --project=. -m DistSSHQueue [qhost:HOST] fetch <id>  # 8-char prefix or full UUID
julia --project=. -m DistSSHQueue [qhost:HOST] fetch .distsshqueue/tickets/<uuid>
```

Also: [First job](@ref Tutorial-Client), [Walkthrough](@ref Tutorial-Walkthrough),
[submit](@ref Manual-submit),
[status](@ref Manual-status).

Run it from the same `cwd` / `DISTRIBUTED_PROJECT_ROOT` as `submit`.
The dest is `{project}/.distsshqueue/{go|ride|drive}/{stem}_{id8}/`.
stdout is that path, one line. Re-run rsyncs into the same leaf.
`qhost:` fetch prints `rsync ← HOST:…` on stderr when the copy starts
(`DISTSSHKIT_QUIET` hides it).

On the queue host (omit `qhost:`), fetch prints the leaf path
and does not copy. The leaf is under the job project (or still under
`dirname(store)` for an explicit `--output-dir` there). Failed and cancelled jobs with a leaf are
fetchable. The argument is the ticket path, the full UUID, or the
8-character prefix from `status`.

`fetch` stays on the client. It does not hop `main` (`status` /
`cancel` do). Path lookup is a captured `julia -e` on the queue host
(same hop as stage homedir).

## Flags

| Flag | Meaning |
| --- | --- |
| `<id>` | Unique 8-character prefix (`status`) or the full UUID (`submit` stdout) |
| ticket | `.distsshqueue/tickets/<uuid>` (same job; no need to copy stdout) |
| `--progress` | `qhost:` rsync `--info=progress2` (`DISTSSHKIT_PROGRESS`) |
| `-h` / `--help` | Queue usage |

No `--output-dir`. Kit worker collect is not repeated.

## Refused

`:queued`, `:running`, missing `result_path`, a path outside the
queue store directory, a path that is not under `go` / `ride` /
`drive`, and a leaf basename that does not contain the 8-character
id (`submit --output-dir` unless that dir already follows this leaf
name).
