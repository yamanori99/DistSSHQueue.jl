# Apple container SSH workers (macOS, optional)

Linux SSH workers on a Mac via Apple
[`container`](https://github.com/apple/container). Same image, keys, and
`child-1` / `child-2` aliases as [`../docker-ssh`](../docker-ssh),
so [`test/e2e.jl`](../../test/e2e.jl) is unchanged. Those aliases are Kit
**child** Hosts, not a queue host. Roles: [test/README.md](../../test/README.md#ssh-e2e-roles).

**Not CI and not `Pkg.test()`.** Compose path stays the default for GitHub
and for Linux / Docker Desktop / WSL.

Do not run `docker-ssh` compose workers at the same time: both write
`docker-ssh/.generated/ssh_config`. Container names are `child-1` /
`child-2`, same as the SSH Host and the hostname. Do not run beside DistSSHKit's Apple containers.

## Requirements

- macOS 26+, Apple silicon
- [`container`](https://github.com/apple/container) CLI
- `python3` (reads `container inspect` JSON)

## Local use

From this directory (queue root also works if you keep the path):

```bash
./scripts/up.sh --e2e    # workers + suite
./scripts/up.sh          # workers only
./scripts/down.sh
```

First `up.sh` runs `container system start` and, if needed, builds
`local/distsshqueue-linux-ssh-worker:latest` from [`../docker-ssh/Dockerfile`](../docker-ssh/Dockerfile).
Every run removes and recreates `child-1` / `child-2` (fresh state each time).
Keys come from `docker-ssh/scripts/gen-keys.sh` (mounted from
`docker-ssh/mounted-keys`). `up.sh` drops a stale `docker-ssh/.generated/known_hosts`
(container sshd host keys / IPs change on recreate; `BatchMode` cannot replace them).

Each worker gets 1 CPU / 3.5GB (`DISTSSHQUEUE_APPLE_WORKER_CPUS` /
`DISTSSHQUEUE_APPLE_WORKER_MEMORY` override), so the pair together matches one
`ubuntu-latest` CI runner (2 CPU / 7GB).

SSH aliases after `up.sh`:

- `child-1` → worker IP, port 22, user `dev`
- `child-2` → the other worker

```bash
ssh -F ../docker-ssh/.generated/ssh_config child-1 'echo ok; julia --version'
```

Apple’s default network does not resolve `child-1` / `child-2` between
containers. `up.sh` appends those names to each child `/etc/hosts` so peer
SSH matches Compose DNS.

## Manual smoke (no E2E)

`./scripts/up.sh` is enough. `container exec` has no `--` (that flag is Docker):

```bash
container exec -it -u dev child-1 bash -l
```

## Teardown

```bash
./scripts/down.sh
```

Leaves `buildkit` and the image. Optional:

```bash
container image rm local/distsshqueue-linux-ssh-worker:latest
```

Switch back to Docker: `docker-ssh/scripts/up.sh` rewrites `ssh_config` to
`127.0.0.1:2222` / `2223`.

## Troubleshooting

| Symptom | What to do |
| --- | --- |
| `container CLI not found` | Install Apple `container`, then retry |
| `apiserver is not running` | `container system start` (also done by `up.sh`) |
| `dockerfile not found` | `up.sh` builds from `testenv/docker-ssh`; run it from this `scripts/` tree |
| `401` pulling `distsshqueue-linux-ssh-worker` | Let `up.sh` build, or `cd ../docker-ssh && container build -t local/distsshqueue-linux-ssh-worker:latest .` |
| SSH timeout | `container ls` — empty IP means `container start <name>` or `./scripts/up.sh` |
| `Host key verification failed` / changed host key | `up.sh` wipes docker-ssh `known_hosts` and uses `StrictHostKeyChecking accept-new` |
| peer SSH cannot reach `dev@child-1` | Re-run `up.sh` (injects `/etc/hosts`); do not skip that step |
