# shellcheck shell=bash
# Retry a step that downloads Julia or juliaup. Sourced, not executed.
#
# juliaup fetches its version db from julialang-s3 after the installer
# download, and `curl --retry` does not cover that request.
#
#   DISTSSHQUEUE_BUILD_RETRIES     attempts, default 3 (1 disables retry)
#   DISTSSHQUEUE_BUILD_RETRY_WAIT  first wait in seconds, default 30; doubles

distsshqueue_retry() {
  local what="$1"
  shift
  local tries="${DISTSSHQUEUE_BUILD_RETRIES:-3}"
  local wait_s="${DISTSSHQUEUE_BUILD_RETRY_WAIT:-30}"
  local i
  for ((i = 1; ; i++)); do
    if "$@"; then
      return 0
    fi
    if ((i >= tries)); then
      echo "${what} failed after ${tries} attempts" >&2
      return 1
    fi
    echo "${what} failed (${i}/${tries}); retrying in ${wait_s}s" >&2
    sleep "${wait_s}"
    wait_s=$((wait_s * 2))
  done
}

# Fresh juliaup install with the default channel. A failed attempt leaves
# ~/.julia/juliaup/juliaup.json; the installer then refuses in non-interactive
# mode and exits 0 without installing.
distsshqueue_install_juliaup() {
  local channel="$1"
  rm -rf "$HOME/.juliaup" "${JULIAUP_DEPOT_PATH:-$HOME/.julia}/juliaup"
  (
    set -o pipefail
    curl --retry 5 --retry-delay 5 --retry-connrefused --connect-timeout 10 \
      -fsSL https://install.julialang.org | sh -s -- --yes --default-channel "${channel}"
  ) || return 1
  [[ -x "$HOME/.juliaup/bin/juliaup" ]] || { echo "juliaup not installed" >&2; return 1; }
  distsshqueue_relink_julia
}

# juliaup symlinks `julia` to an absolute `julialauncher` path. The WSL cache
# is one tarball shared by root (SSH E2E) and user ci (Pkg.test). Restoring it
# into the other home leaves a dangling symlink, and bash reports
# `julia: command not found`. Point `julia` at the launcher in this home.
# Compiled files are not in that tarball: they record absolute source paths,
# and ci cannot stat /root.
distsshqueue_relink_julia() {
  local bin="$HOME/.juliaup/bin"
  local launcher=""
  if [[ -x "${bin}/julialauncher" ]]; then
    launcher="julialauncher"
  elif [[ -x "${bin}/juliaup" ]]; then
    launcher="juliaup"
  else
    echo "julia launcher missing in ${bin}" >&2
    return 1
  fi
  ln -sfn "${launcher}" "${bin}/julia"
  [[ -x "${bin}/julia" ]] || { echo "julia is not executable at ${bin}/julia" >&2; return 1; }
}
