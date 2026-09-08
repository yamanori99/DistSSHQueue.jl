# [fetch](@id Manual-fetch)

Copy one finished Kit result leaf onto this job tree. Inverse of
`qhost:` stage (which excludes `.distsshkit/`). `qhost:` submit leaves
`.distsshkit/queue/<id>` on this tree so the laptop is not empty; that
file is not the leaf.

```bash
julia --project=. -m DistSSHQueue [qhost:HOST] fetch <id>
```

Also: [First job](@ref Tutorial-Client), [Walkthrough](@ref Tutorial-Walkthrough),
[submit](@ref Manual-submit),
[status](@ref Manual-status).

Run it from the same `cwd` / `DISTRIBUTED_PROJECT_ROOT` as `submit`.
The dest is that project's copy of the Kit leaf
(`…/.distsshkit/{go|ride|drive}/<stem>_<UTC>_<id>/`). stdout is that path,
one line. Re-run rsyncs into the same leaf. A Kit demo that writes
`output/` on a local `julia -m DistSSHKit drive` still uses that unique
`.distsshkit/drive/` leaf under Queue (`allocate_output_dir` sets
`DISTRIBUTED_OUTPUT_DIR` before `init_output_dir!`).

`fetch` stays on the client. It does not hop `main` (`status` /
`cancel` do). Path lookup is a captured `julia -e` on the queue host
(same hop as stage homedir). Omit `qhost:` on the queue host: the
leaf is already local; fetch prints the path.

## Flags

| Flag | Meaning |
| --- | --- |
| `<id>` | Exact job UUID (`submit` stdout / `status`) |
| `-h` / `--help` | Queue usage |

No `--output-dir`. Kit worker collect is not repeated.

## Refused

`:queued`, `:running`, missing `result_path`, a path outside this
tree's stage, a path that is not under `.distsshkit`, and a leaf
basename that does not contain the id (`submit --output-dir` unless
that dir already follows Kit's leaf name).
