#!/usr/bin/env bash
# Build once, then start docker-ssh workers (ports 2222 / 2223).
# Optional: ./scripts/up.sh --e2e  → also run the Queue SSH E2E from queue root.
#
# These containers are DistSSHKit go/drive targets. The queue host and the
# serve run on this host during --e2e, not in a container.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
QUEUE_ROOT="$(cd "${ROOT}/../.." && pwd)"
RUN_E2E=0
LOCAL_IMAGE="local/distsshqueue-linux-ssh-worker:latest"

for arg in "$@"; do
  case "$arg" in
    --e2e) RUN_E2E=1 ;;
    -h|--help)
      echo "usage: $0 [--e2e]"
      echo "  DISTSSHQUEUE_WORKER_IMAGE  pull this tag (skip compose build)"
      echo "  DISTSSHQUEUE_WORKER_PULL_RETRIES  pull attempts (default 1; daily CI uses 8)"
      echo "  DISTSSHQUEUE_PUSH_IMAGE  after local build, tag and push this name"
      echo "  DISTSSHQUEUE_SKIP_UP=1     skip compose up (push-only)"
      echo "  DISTSSHQUEUE_CODE_COVERAGE=1  e2e with --code-coverage=user"
      exit 0
      ;;
    *)
      echo "unknown option: $arg" >&2
      exit 1
      ;;
  esac
done

cd "${ROOT}"

# shellcheck source=julia-release.sh
source "${ROOT}/scripts/julia-release.sh"

./scripts/gen-keys.sh

if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
  COMPOSE=(docker compose)
elif command -v docker-compose >/dev/null 2>&1; then
  COMPOSE=(docker-compose)
else
  echo "docker compose not found" >&2
  exit 1
fi

pull_worker_image() {
  local image="$1"
  local retries="${DISTSSHQUEUE_WORKER_PULL_RETRIES:-1}"
  local attempt=1
  while true; do
    if docker pull "$image"; then
      docker tag "$image" "$LOCAL_IMAGE"
      return 0
    fi
    if (( attempt >= retries )); then
      echo "docker pull failed after ${retries} attempts: ${image}" >&2
      return 1
    fi
    echo "waiting for worker image (${attempt}/${retries}): ${image}" >&2
    sleep 15
    attempt=$((attempt + 1))
  done
}

if [[ -n "${DISTSSHQUEUE_WORKER_IMAGE:-}" ]]; then
  pull_worker_image "$DISTSSHQUEUE_WORKER_IMAGE"
else
  # Build a single service so logs are not interleaved (both share the image).
  # Compose passes JULIA_CHANNEL and the resolved release into Dockerfile ARGs.
  distsshqueue_export_julia_release
  "${COMPOSE[@]}" -f compose.yml build child-1
  if [[ -n "${DISTSSHQUEUE_PUSH_IMAGE:-}" ]]; then
    DISTSSHQUEUE_LOCAL_IMAGE="$LOCAL_IMAGE" ./scripts/push-image.sh "$DISTSSHQUEUE_PUSH_IMAGE"
  fi
fi

if [[ "${DISTSSHQUEUE_SKIP_UP:-}" == "1" ]]; then
  echo "DISTSSHQUEUE_SKIP_UP=1: image ready, not starting workers"
  exit 0
fi

./scripts/down.sh
# Recreated sshd host keys must not fight BatchMode + a stale known_hosts.
rm -f "${ROOT}/.generated/known_hosts"
"${COMPOSE[@]}" -f compose.yml up -d --no-build
./scripts/wait-ready.sh
echo "Workers ready: child-1 (2222), child-2 (2223)"
echo "SSH config: ${ROOT}/.generated/ssh_config"

if [[ "$RUN_E2E" -eq 1 ]]; then
  export DISTSSHQUEUE_SSH_E2E=1
  cd "${QUEUE_ROOT}"
  # WSL weekly has no julia-buildpkg. Fresh juliaup has no registries
  # (`Registry.update` then fails). A restored `.julia` tarball can have a
  # stale General (older Kit while Queue wants 0.5). linux/macOS already
  # instantiated (no-op). Workspace Manifest is gitignored. A root-only
  # instantiate can omit test's path dep; Julia 1.13 `instantiate` then
  # errors instead of resolving.
  julia --project=test --color=yes -e '
    using Pkg
    isempty(Pkg.Registry.reachable_registries()) && Pkg.Registry.add("General")
    Pkg.Registry.update()
    Pkg.resolve()
    Pkg.instantiate()
  '
  julia_e2e=(julia --project=test --color=yes)
  if [[ "${DISTSSHQUEUE_CODE_COVERAGE:-}" == "1" ]]; then
    julia_e2e+=(--code-coverage=user)
  fi
  e2e_status=0
  "${julia_e2e[@]}" test/e2e.jl || e2e_status=$?
  if [[ "$e2e_status" -eq 0 ]]; then
    "${ROOT}/scripts/down.sh"
  else
    echo "e2e failed (exit ${e2e_status}) — leaving workers up for debugging; ${ROOT}/scripts/down.sh to tear down" >&2
  fi
  exit "$e2e_status"
fi
