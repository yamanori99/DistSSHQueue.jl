#!/usr/bin/env bash
# On a pull request that does not raise Project.toml version, require a
# changelog.d fragment when src/**, lib/**/src/**, or ext/** changes.
# Dependabot is exempt. A breaking label and a category: breaking fragment
# require each other. planned does not. A version cut does not run this.
#
#   ./.github/news-fragment.sh OLD_REF NEW_REF
#   ./.github/news-fragment.sh --self-test
#
# Labels come from the pull request API (GH_TOKEN, GITHUB_REPOSITORY, PR).
# NEWS_FRAGMENT_LABELS, when set, is the comma-separated label list instead.
# PR_AUTHOR, when set, is the pull request author login.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${script_dir}/news-collect.sh"

nf_author() {
  if [[ -n "${PR_AUTHOR+x}" ]]; then
    printf '%s\n' "$PR_AUTHOR"
    return 0
  fi
  local token="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
  if [[ -n "${GITHUB_REPOSITORY:-}" && -n "${PR:-}" && -n "$token" ]]; then
    gh api --jq .user.login "repos/${GITHUB_REPOSITORY}/pulls/${PR}"
    return 0
  fi
  printf '\n'
}

nf_labels() {
  if [[ -n "${NEWS_FRAGMENT_LABELS+x}" ]]; then
    printf '%s\n' "$NEWS_FRAGMENT_LABELS"
    return 0
  fi
  local token="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
  if [[ -z "$token" || -z "${GITHUB_REPOSITORY:-}" || -z "${PR:-}" ]]; then
    echo "news-fragment: need GH_TOKEN, GITHUB_REPOSITORY, and PR to read labels" >&2
    return 1
  fi
  gh api --jq '[.labels[].name] | join(",")' "repos/${GITHUB_REPOSITORY}/issues/${PR}"
}

nf_needs_path() {
  local path="$1"
  [[ "$path" == src/* || "$path" == ext/* ]] && return 0
  [[ "$path" =~ ^lib/(.+/)?src/.+ ]] && return 0
  return 1
}

nf_check() {
  local old="$1"
  local new="$2"
  local author need status p1 p2 kind path labels has_label
  local -a frags=()
  local tmp category breaking valid frag base
  author="$(nf_author)"
  if [[ "$author" == "dependabot[bot]" ]]; then
    echo "news-fragment: Dependabot is exempt"
    return 0
  fi
  need=false
  while IFS=$'\t' read -r status p1 p2; do
    [[ -z "${status:-}" ]] && continue
    kind="${status:0:1}"
    case "$kind" in
      R | C)
        path="$p2"
        ;;
      *)
        path="$p1"
        ;;
    esac
    if nf_needs_path "$path"; then
      need=true
    fi
    if [[ "$kind" == R || "$kind" == C ]] && nf_needs_path "$p1"; then
      need=true
    fi
    case "$kind" in
      A | M | R | C | T)
        if [[ "$path" == changelog.d/* ]]; then
          frags+=("$path")
        fi
        ;;
    esac
  done < <(git diff --name-status -M "$old" "$new")

  tmp="$(mktemp -d)"
  breaking=false
  valid=false
  if ((${#frags[@]})); then
    for frag in "${frags[@]}"; do
      base="$(basename "$frag")"
      if [[ ! "$frag" =~ ^changelog[.]d/[a-z0-9][a-z0-9.-]{0,60}[.]md$ ]]; then
        echo "news-fragment: invalid fragment path ${frag}" >&2
        rm -rf "$tmp"
        return 1
      fi
      git cat-file -p "${new}:${frag}" >"${tmp}/${base}"
      if ! category="$(nc_validate_fragment "${tmp}/${base}")"; then
        rm -rf "$tmp"
        return 1
      fi
      valid=true
      if [[ "$category" == breaking ]]; then
        breaking=true
      fi
    done
  fi
  rm -rf "$tmp"
  if [[ "$need" == true && "$valid" != true ]]; then
    echo "news-fragment: changes under src/, lib/**/src/, or ext/ need a changelog.d fragment" >&2
    return 1
  fi
  labels="$(nf_labels)"
  has_label=false
  case ",${labels}," in
    *,breaking,*) has_label=true ;;
  esac
  if [[ "$has_label" == true && "$breaking" != true ]]; then
    echo "news-fragment: breaking label requires a category: breaking fragment" >&2
    return 1
  fi
  if [[ "$breaking" == true && "$has_label" != true ]]; then
    echo "news-fragment: category: breaking requires the breaking label" >&2
    return 1
  fi
  echo "news fragment ok"
}

nf_self_test() {
  local tmp failed script repo base
  tmp="$(mktemp -d)"
  failed=0
  script="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
  repo="${tmp}/repo"
  # shellcheck disable=SC2317
  fail() {
    echo "FAIL $*" >&2
    failed=1
  }
  expect_rc() {
    local want="$1"
    shift
    local status=0
    if "$@" >"${tmp}/out" 2>"${tmp}/err"; then
      status=0
    else
      status=$?
    fi
    if [[ "$status" -ne "$want" ]]; then
      echo "FAIL $* want exit ${want} got ${status}" >&2
      cat "${tmp}/err" >&2 || true
      failed=1
    fi
  }
  reset_tree() {
    git checkout -q "$base"
    git clean -q -fd
  }
  commit_tree() {
    git add -A
    git commit -q -m "$1"
    git rev-parse HEAD
  }

  mkdir -p "$repo"
  pushd "$repo" >/dev/null
  git init -q -b main
  git config user.email "news-fragment@example.com"
  git config user.name "news-fragment"
  mkdir -p src
  printf 'x = 1\n' >src/keep.jl
  printf 'readme\n' >README.md
  git add -A
  git commit -q -m base
  base="$(git rev-parse HEAD)"

  printf 'x = 2\n' >src/keep.jl
  src_sha="$(commit_tree src)"
  expect_rc 1 env NEWS_FRAGMENT_LABELS= PR_AUTHOR= bash "$script" "$base" "$src_sha"

  reset_tree
  printf 'x = 2\n' >src/keep.jl
  mkdir -p changelog.d
  printf 'category: fixed\n\n- A quoted path stays one word.\n' >changelog.d/quote-path.md
  fixed_sha="$(commit_tree fixed)"
  expect_rc 0 env NEWS_FRAGMENT_LABELS= PR_AUTHOR= bash "$script" "$base" "$fixed_sha"

  reset_tree
  printf 'x = 3\n' >src/keep.jl
  mkdir -p changelog.d
  printf 'category: breaking\n\n- Flags no longer delete without a path.\n' >changelog.d/confirm-path.md
  brk_sha="$(commit_tree breaking)"
  expect_rc 1 env NEWS_FRAGMENT_LABELS= PR_AUTHOR= bash "$script" "$base" "$brk_sha"
  expect_rc 0 env NEWS_FRAGMENT_LABELS=breaking PR_AUTHOR= bash "$script" "$base" "$brk_sha"

  reset_tree
  printf 'x = 4\n' >src/keep.jl
  mkdir -p changelog.d
  printf 'category: planned\n\n- A later minor will reject this.\n' >changelog.d/later.md
  plan_sha="$(commit_tree planned)"
  expect_rc 1 env NEWS_FRAGMENT_LABELS=breaking PR_AUTHOR= bash "$script" "$base" "$plan_sha"
  expect_rc 0 env NEWS_FRAGMENT_LABELS= PR_AUTHOR= bash "$script" "$base" "$plan_sha"

  reset_tree
  printf 'docs\n' >README.md
  docs_sha="$(commit_tree docs)"
  expect_rc 0 env NEWS_FRAGMENT_LABELS= PR_AUTHOR= bash "$script" "$base" "$docs_sha"

  reset_tree
  mkdir -p ext lib/Pkg/src
  printf 'module E\nend\n' >ext/E.jl
  ext_sha="$(commit_tree ext)"
  expect_rc 1 env NEWS_FRAGMENT_LABELS= PR_AUTHOR= bash "$script" "$base" "$ext_sha"

  reset_tree
  mkdir -p lib/Pkg/src
  printf 'x = 1\n' >lib/Pkg/src/x.jl
  lib_sha="$(commit_tree lib)"
  expect_rc 1 env NEWS_FRAGMENT_LABELS= PR_AUTHOR= bash "$script" "$base" "$lib_sha"

  reset_tree
  mkdir -p lib/Pkg/src changelog.d
  printf 'x = 1\n' >lib/Pkg/src/x.jl
  printf 'category: skip\n\nPrivate helper renamed.\n' >changelog.d/rename-helper.md
  skip_sha="$(commit_tree skip)"
  expect_rc 0 env NEWS_FRAGMENT_LABELS= PR_AUTHOR= bash "$script" "$base" "$skip_sha"

  reset_tree
  printf 'x = 9\n' >src/keep.jl
  bot_sha="$(commit_tree bot)"
  expect_rc 0 env PR_AUTHOR='dependabot[bot]' bash "$script" "$base" "$bot_sha"

  reset_tree
  mkdir -p changelog.d
  printf 'category: fixed\n\n- Nope.\n' >changelog.d/Bad.md
  bad_sha="$(commit_tree badname)"
  expect_rc 1 env NEWS_FRAGMENT_LABELS= PR_AUTHOR= bash "$script" "$base" "$bad_sha"

  reset_tree
  mkdir -p changelog.d
  printf 'category: fixed\n\n- item\n## 1.0\n' >changelog.d/heading.md
  hed_sha="$(commit_tree heading)"
  expect_rc 1 env NEWS_FRAGMENT_LABELS= PR_AUTHOR= bash "$script" "$base" "$hed_sha"

  reset_tree
  git rm -q src/keep.jl
  rm_sha="$(commit_tree remove)"
  expect_rc 1 env NEWS_FRAGMENT_LABELS= PR_AUTHOR= bash "$script" "$base" "$rm_sha"

  popd >/dev/null
  rm -rf "$tmp"
  if [[ "$failed" -ne 0 ]]; then
    exit 1
  fi
  echo "news-fragment self-test ok"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  case "${1:-}" in
    --self-test)
      nf_self_test
      ;;
    "")
      echo "usage: $0 OLD_REF NEW_REF" >&2
      exit 2
      ;;
    *)
      if [[ $# -ne 2 ]]; then
        echo "usage: $0 OLD_REF NEW_REF" >&2
        exit 2
      fi
      nf_check "$1" "$2"
      ;;
  esac
fi
