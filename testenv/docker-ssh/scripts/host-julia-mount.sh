#!/usr/bin/env bash
# Resolve the queue-host Julia install prefix and optional compose overlay for
# mounting it into docker-ssh workers (sysimage path parity with the controller).

distsshqueue_export_host_julia_prefix() {
  if [[ -n "${DISTSSHQUEUE_HOST_JULIA_PREFIX:-}" ]]; then
    return 0
  fi
  if ! command -v julia >/dev/null 2>&1; then
    return 0
  fi
  local prefix
  prefix="$(julia --startup-file=no -e 'print(dirname(Sys.BINDIR))' 2>/dev/null)" || return 0
  if [[ -n "${prefix}" && -x "${prefix}/bin/julia" ]]; then
    export DISTSSHQUEUE_HOST_JULIA_PREFIX="${prefix}"
    echo "controller Julia prefix: ${DISTSSHQUEUE_HOST_JULIA_PREFIX} (mounted into workers when up runs)"
  fi
  return 0
}

# Sets DISTSSHQUEUE_COMPOSE_FILES to a bash array name the caller must use with
# "${DISTSSHQUEUE_COMPOSE_FILES[@]}".
distsshqueue_compose_files() {
  # shellcheck disable=SC2034
  DISTSSHQUEUE_COMPOSE_FILES=(-f compose.yml)
  if [[ -n "${DISTSSHQUEUE_HOST_JULIA_PREFIX:-}" ]]; then
    DISTSSHQUEUE_COMPOSE_FILES+=(-f compose.julia-mount.yml)
  fi
}