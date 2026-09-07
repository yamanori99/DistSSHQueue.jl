# [Walkthrough](@id Tutorial-Walkthrough)

Commands in the order you type them. Flags and trees stay on
[Prepare](@ref Tutorial-Prepare), [First job](@ref Tutorial-Client),
and the [User Guide](@ref Manual). Not a dump of root `--help`.

Names here: queue host SSH `mini`, worker SSH `host1`. Swap them.

## Queue host (once)

Always-on **macOS or Linux**. Default Julia env is enough
(`pkg> add DistSSHQueue` there). `setup` writes `config.toml` only.
`parent` is this box. Dedicated `~/.distsshqueue/env` is optional
until a laptop uses `qhost:` (that hop defaults to
`--project=~/.distsshqueue/env`).

```bash
julia -m DistSSHQueue setup
julia -m DistSSHQueue add-host parent child:host1
julia -m DistSSHQueue serve
```

`add-host` does not deploy. Kit `setup --rsync` / `--instantiate` is
later, from the **stage tree**, before `child:host1` runs a job.

Clients hop: create the env, then `pkg> add DistSSHQueue` in it
(Prepare). `enable` is optional (survive reboot).

## Client: go on parent

Job directory. Queue loadable (`julia --project=.`). DistSSHKit **0.6.x**
comes with Queue. `demo install` copies into `distsshkit_demos/`.

```bash
julia --project=. -m DistSSHKit demo install without_kit
julia --project=. -m DistSSHQueue qhost:mini go parent distsshkit_demos/without_kit/pi_echo.jl
```

`qhost:` rsyncs this tree to `~/.distsshqueue/stage/<key>` on `mini`
(excludes `.distsshkit/`). Stdout is the job UUID. This laptop has
`.distsshkit/queue/<id>` only; the Kit leaf is not here yet.

```bash
julia --project=. -m DistSSHQueue qhost:mini status
julia --project=. -m DistSSHQueue qhost:mini fetch <id>
```

`fetch` copies `.distsshkit/go/<stem>_<UTC>_<id>/` onto this tree.
Run it from the same directory as `go`.

## Worker (`child:NAME`)

On **mini**, after the first `qhost:` submit, the clone is the stage
dir (`ls ~/.distsshqueue/stage`). From **that** tree, DistSSHKit
setup — same two-segment remote Kit would use for drive
(`~/parent/<project>`), not Queue `add-host`:

```bash
cd ~/.distsshqueue/stage/<key>
julia --project=. -m DistSSHKit setup --rsync child:host1
julia --project=. -m DistSSHKit setup --instantiate child:host1
```

[kit Prepare](https://yamanori99.github.io/DistSSHKit.jl/stable/tutorial/prepare/).

Then from the **client**:

```bash
julia --project=. -m DistSSHQueue qhost:mini go child:host1:2 distsshkit_demos/without_kit/pi_echo.jl
julia --project=. -m DistSSHQueue qhost:mini fetch <id>
```

## Drive

```bash
julia --project=. -m DistSSHKit demo install with_kit
julia --project=. -m DistSSHQueue qhost:mini drive parent distsshkit_demos/with_kit/square_file.jl
julia --project=. -m DistSSHQueue qhost:mini fetch <id>
```

CSV is in `.distsshkit/drive/<stem>_<UTC>_<id>/`, not demo `output/`.

## Teardown

On the queue host. No `-y` is a dry-run (exit 0). Then `-y`. After
wipe, `status` is Store `path none` and Jobs `(none)`.

```bash
julia -m DistSSHQueue teardown
julia -m DistSSHQueue teardown -y
julia -m DistSSHQueue status
```

From a client: `qhost:mini teardown` then `qhost:mini teardown -y`.
