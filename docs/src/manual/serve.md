# [serve](@id Manual-serve)

Run or register `serve` on the queue host.

```bash
julia -m DistSSHQueue serve [--interval S]
julia -m DistSSHQueue stop
julia -m DistSSHQueue enable [--queue-env DIR]
julia -m DistSSHQueue disable
```

Also: [Prepare](@ref Tutorial-Prepare), [submit](@ref Manual-submit),
[setup](@ref Manual-setup). `qhost:` is refused (log in on the queue host).

`serve` is this terminal, now. Ctrl-C stops this process, not a Kit job
that is already running. Before each `execute!` it runs Kit `setup!`
(`rsync` → `instantiate` → `check`) unless `DISTSSHQUEUE_NO_KIT_SETUP=1`.
`enable` tells the OS to start `serve` after reboot / login
(LaunchAgent / systemd). `submit` starts `serve` if none is up.

## Flags

| Flag | Meaning |
| --- | --- |
| `--interval S` | `serve` poll interval (default `0.2`) |
| `--queue-env DIR` | `enable`: `julia --project=` in the OS unit |
| `--julia PATH` | `enable`: Julia binary in that unit |
| `--write-only` | `enable` / `disable`: write or remove the unit file without `launchctl` / `systemctl` |
| `-h` / `--help` | Queue usage |

`enable --project` is refused. Project stays cwd /
`DISTRIBUTED_PROJECT_ROOT`.

A dedicated env at `~/.distsshqueue/env`, if present, is the default
`--queue-env`. Prefer that so a checkout can be deleted.

## stop

Halts `serve`, keeps config / store / OS unit. Writes
(`jobs.toml.stopped`) so `submit` will not auto-start; only an explicit
`serve` resumes. Clients can `qhost:HOST stop`.

`disable` removes the OS unit. It does not delete the job table.
`Removed` when a unit file was deleted; `Present` (unchanged) when there
was nothing to drop. LaunchAgent / systemd still unload unless
`--write-only`.
