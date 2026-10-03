#!/usr/bin/env bash
# Stop and remove docker-ssh workers.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "${ROOT}"

if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
  COMPOSE=(docker compose)
elif command -v docker-compose >/dev/null 2>&1; then
  COMPOSE=(docker-compose)
else
  echo "docker compose not found" >&2
  exit 1
fi

"${COMPOSE[@]}" -f compose.yml down --remove-orphans
# Previous container_name was distsshqueue-child-*. `down` above misses those.
for name in distsshqueue-child-1 distsshqueue-child-2 distsshqueue-worker-1 distsshqueue-worker-2 \
            distsshkitqueue-child-1 distsshkitqueue-child-2 distsshkitqueue-worker-1 distsshkitqueue-worker-2; do
  docker rm -f "${name}" >/dev/null 2>&1 || true
done
