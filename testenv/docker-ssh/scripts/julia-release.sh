#!/usr/bin/env bash
# Resolve the newest Julia release on one major.minor channel.
# Source from docker-ssh / apple-container up.sh, then call
# distsshqueue_export_julia_release.
#
# The channel name stays 1.13 when 1.13.0-rc4 becomes 1.13.1. The release
# string is a Docker build-arg so that juliaup layer rebuilds.

_distsshqueue_julia_ver_sort_key() {
  local ver="$1" patch kind n rank
  if [[ "${ver}" =~ ^[0-9]+\.[0-9]+\.([0-9]+)$ ]]; then
    printf '%05d\n' "${BASH_REMATCH[1]}"
    return 0
  fi
  if [[ "${ver}" =~ ^[0-9]+\.[0-9]+\.([0-9]+)-(alpha|beta|rc)([0-9]+)$ ]]; then
    patch="${BASH_REMATCH[1]}"
    kind="${BASH_REMATCH[2]}"
    n="${BASH_REMATCH[3]}"
    case "${kind}" in
      alpha) rank=0 ;;
      beta) rank=1 ;;
      rc) rank=2 ;;
    esac
    printf '%05d%d%05d\n' "${patch}" "${rank}" "${n}"
    return 0
  fi
  echo "unrecognized Julia version: ${ver}" >&2
  return 1
}

_distsshqueue_julia_newest() {
  local best="" best_key="" ver key
  (($#)) || return 1
  for ver in "$@"; do
    key="$(_distsshqueue_julia_ver_sort_key "${ver}")" || return 1
    # 10# forces base 10. A leading zero would make -gt read the key as octal.
    if [[ -z "${best}" || "10#${key}" -gt "10#${best_key}" ]]; then
      best="${ver}"
      best_key="${key}"
    fi
  done
  printf '%s\n' "${best}"
}

# Newest release on one major.minor. Stable wins over a later prerelease.
_distsshqueue_julia_release_for_channel() {
  local channel="$1" json="$2" esc line re_stable re_pre
  local -a stable=() pre=()
  esc="${channel//./\\.}"
  re_stable="^[[:space:]]*\"(${esc}\\.[0-9]+)\"[[:space:]]*:"
  re_pre="^[[:space:]]*\"(${esc}\\.[0-9]+-(alpha|beta|rc)[0-9]+)\"[[:space:]]*:"
  while IFS= read -r line; do
    if [[ "${line}" =~ ${re_stable} ]]; then
      stable+=("${BASH_REMATCH[1]}")
    elif [[ "${line}" =~ ${re_pre} ]]; then
      pre+=("${BASH_REMATCH[1]}")
    fi
  done < "${json}"
  if ((${#stable[@]})); then
    _distsshqueue_julia_newest "${stable[@]}"
  elif ((${#pre[@]})); then
    _distsshqueue_julia_newest "${pre[@]}"
  else
    echo "no Julia release for channel ${channel}" >&2
    return 1
  fi
}

# Sets JULIA_CHANNEL (default 1.13) and JULIA_RELEASE from versions.json.
distsshqueue_export_julia_release() {
  local json
  export JULIA_CHANNEL="${JULIA_CHANNEL:-1.13}"
  json="$(mktemp)"
  curl --retry 5 --retry-delay 5 --retry-connrefused --connect-timeout 10 \
    -fsSL -o "${json}" https://julialang-s3.julialang.org/bin/versions.json \
    || { rm -f "${json}"; echo "failed to download versions.json" >&2; return 1; }
  if ! JULIA_RELEASE="$(_distsshqueue_julia_release_for_channel "${JULIA_CHANNEL}" "${json}")"; then
    rm -f "${json}"
    echo "failed to resolve Julia ${JULIA_CHANNEL}" >&2
    return 1
  fi
  rm -f "${json}"
  export JULIA_RELEASE
  echo "juliaup release: ${JULIA_CHANNEL} (${JULIA_RELEASE})"
}
