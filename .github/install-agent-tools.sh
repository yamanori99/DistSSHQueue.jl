#!/usr/bin/env bash
# Install Runic and JETLS Pkg apps for Cloud Agent VMs (idempotent).
# Called from .cursor/install.sh. Individual tool failures warn only.
set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STABLE_CHANNEL="1.13"
JULIA_APPS_JULIA="${HOME}/.juliaup/bin/julia"
JULIA_BIN_DIR="${HOME}/.julia/bin"

warn() {
  echo "install-agent-tools: $*" >&2
}

link_into_path() {
  local name="$1"
  local source="${JULIA_BIN_DIR}/${name}"
  local dest="/usr/local/bin/${name}"
  if [[ ! -e "${source}" ]]; then
    warn "missing ${source}; skip symlink for ${name}"
    return 0
  fi
  if [[ -L "${dest}" ]] && [[ "$(readlink -f "${dest}")" == "$(readlink -f "${source}")" ]]; then
    return 0
  fi
  if [[ -e "${dest}" && ! -L "${dest}" ]]; then
    warn "refusing to replace non-symlink ${dest}"
    return 0
  fi
  if [[ -w "$(dirname "${dest}")" ]]; then
    ln -sfn "${source}" "${dest}" || warn "ln failed for ${name}"
    return 0
  fi
  if ! sudo -n ln -sfn "${source}" "${dest}" 2>/dev/null; then
    warn "could not link ${name} into /usr/local/bin (add ${JULIA_BIN_DIR} to PATH)"
  fi
}

read_jetls_pin() {
  local action="${repo_root}/.github/actions/jetls-check/action.yml"
  local rev
  rev="$(grep -E -m 1 -o 'rev="[0-9]{4}-[0-9]{2}-[0-9]{2}"' "${action}" || true)"
  rev="${rev#rev=\"}"
  rev="${rev%\"}"
  if [[ ! "${rev}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
    warn "JETLS date pin missing in ${action}"
    return 1
  fi
  printf '%s' "${rev}"
}

app_repo_rev() {
  local name="$1"
  local manifest="${HOME}/.julia/environments/apps/AppManifest.toml"
  if [[ ! -f "${manifest}" ]]; then
    return 0
  fi
  awk -v section_header="[[deps.${name}]]" '
    $0 == section_header { section = 1; next }
    /^\[\[/ { section = 0; next }
    section && $1 == "repo-rev" {
      gsub(/"/, "", $3)
      print $3
      exit
    }
  ' "${manifest}"
}

jetls_ok() {
  local pin="$1"
  local rev
  rev="$(app_repo_rev JETLS)"
  if [[ "${rev}" != "${pin}" ]]; then
    return 1
  fi
  env JULIA_APPS_JULIA_CMD="${JULIA_APPS_JULIA}" PATH="${JULIA_BIN_DIR}:${PATH}" \
    jetls version >/dev/null 2>&1
}

install_jetls() {
  local pin="$1"
  if jetls_ok "${pin}"; then
    echo "install-agent-tools: JETLS ${pin} already installed"
    link_into_path jetls
    return 0
  fi
  echo "install-agent-tools: installing JETLS ${pin}"
  if ! env JULIA_APPS_JULIA_CMD="${JULIA_APPS_JULIA}" \
    julia +"${STABLE_CHANNEL}" --startup-file=no -e '
      using Pkg
      Pkg.Apps.add(; url="https://github.com/aviatesk/JETLS.jl", rev=ARGS[1])
    ' -- "${pin}"; then
    warn "JETLS install failed"
    return 0
  fi
  link_into_path jetls
}

runic_ok() {
  env JULIA_APPS_JULIA_CMD="${JULIA_APPS_JULIA}" PATH="${JULIA_BIN_DIR}:${PATH}" \
    runic --version >/dev/null 2>&1
}

install_runic() {
  if runic_ok; then
    echo "install-agent-tools: Runic already installed"
    link_into_path runic
    return 0
  fi
  echo "install-agent-tools: installing Runic"
  if ! env JULIA_APPS_JULIA_CMD="${JULIA_APPS_JULIA}" \
    julia +"${STABLE_CHANNEL}" --startup-file=no -e '
      using Pkg
      Pkg.Apps.add("Runic")
    '; then
    warn "Runic install failed"
    return 0
  fi
  link_into_path runic
}

if [[ ! -x "${JULIA_APPS_JULIA}" ]]; then
  warn "juliaup launcher missing at ${JULIA_APPS_JULIA}; skip agent tools"
  exit 0
fi

mkdir -p "${JULIA_BIN_DIR}" 2>/dev/null || true

pin=""
if pin="$(read_jetls_pin)"; then
  install_jetls "${pin}"
else
  warn "skip JETLS install"
fi
install_runic

exit 0