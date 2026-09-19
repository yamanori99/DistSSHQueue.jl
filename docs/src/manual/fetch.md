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
The dest is `{project}/.distsshqueue/{go|ride|drive}/{stem}_{id8}/`
(not the Kit `{project}/.distsshkit/{kind}/…` source),
or `--into PATH` itself (that directory **is** the leaf; no extra
`{stem}_{id8}` folder). `--into` may be outside the job project.
One dest holds one job. stdout is that path, one line. Fetch copies
the Kit leaf; files that exist only on dest stay. Same-name files
take the Kit leaf's content. Re-run of the same id into the same dest skips rsync
(`already fetched` on stderr) unless `--force`. A dest that already
has files and no matching `.distsshqueue-fetch-id` is refused without
`--force`. `--force` only skips that refusal; it does not delete
dest-only files. The marker stores the canonical job UUID (an 8-character
prefix fetch still matches). `qhost:` fetch prints `rsync ← HOST:…`
on stderr when the copy starts (`DISTSSHKIT_QUIET` hides it).

On the queue host (omit `qhost:`), fetch prints the Kit source path
and does not copy. That path is under the job project (or still under
`dirname(store)` for an explicit `--output-dir` there). Failed and cancelled jobs with a leaf are
fetchable. If Kit `setup!` failed before `execute!`, that leaf may
contain `setup_failure.log` (copied from `{project}/.distsshkit/setup/`)
instead of job output. The argument is the ticket path, the full UUID, or the
8-character prefix from `status`.

`fetch` stays on the client. It does not hop `main` (`status` /
`cancel` do). Path lookup is a captured `julia -e` on the queue host
(same hop as stage homedir).

## Flags

| Flag | Meaning |
| --- | --- |
| `<id>` | Unique 8-character prefix (`status`) or the full UUID (`submit` stdout) |
| ticket | `.distsshqueue/tickets/<uuid>` (same job; no need to copy stdout) |
| `--into PATH` | Dest directory (the leaf). Relative to the job project; absolute paths may be outside it. One job per dest |
| `--force` | Copy even if dest already has this or another job. Does not delete dest-only files |
| `--progress` | `qhost:` rsync `--info=progress2` (`DISTSSHKIT_PROGRESS`) |
| `-h` / `--help` | Queue usage |

No `--output-dir`. Kit worker collect is not repeated.

## Refused

`:queued`, `:running`, missing `result_path`, and a path outside the
job project and the queue store directory. Kit `runs/` (sidecars) is
not a fetch source. `submit --output-dir` under the project is
fetchable; dest is still `{kind}/{stem}_{id8}` unless `--into`.
