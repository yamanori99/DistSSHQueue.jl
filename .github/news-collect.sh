#!/usr/bin/env bash
# Build the NEWS section for a version cut from changelog.d/*.md.
#
# A fragment is one file. The first line is
#   category: breaking|planned|added|fixed|changed|skip
# then a blank line, then the bullet text. skip's text is one line, the
# reason, and is not copied into NEWS. There is no package field and no YAML.
# A line that starts with "## " is rejected. The file name is
# [a-z0-9][a-z0-9.-]{0,60}.md.
#
#   ./.github/news-collect.sh
#   ./.github/news-collect.sh --check OLD_REF NEW_REF
#   ./.github/news-collect.sh --self-test
#
# With no arguments, rewrite NEWS.md in the current directory and delete
# breaking, changed, added, fixed, and skip fragments. planned fragments stay.
# The release section is ## <Project.toml version>, with ### Breaking only
# when a breaking fragment exists, then changed, added, and fixed. Each group
# is sorted by file name. An empty release section is an error.
#
# --check rebuilds that result from the fragments between the merge-base of
# OLD_REF and NEW_REF, and compares it to NEW_REF. It does not modify the
# worktree. A fragment edited and deleted in one commit is read from the
# last commit that still has the file. Commit the fragment, then run this
# script.
set -euo pipefail

# shellcheck disable=SC2016
nc_note_one='Notes since the last release are files in `changelog.d/`.'
# shellcheck disable=SC2016
nc_note_two='The version-cut PR copies them into this file.'
nc_planned_heading='### Planned breaking (next minor)'

nc_read_version() {
  local file="$1"
  local version
  version="$(sed -n 's/^version[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$file" | head -1)"
  if [[ -z "$version" ]]; then
    echo "news-collect: no version in ${file}" >&2
    return 1
  fi
  printf '%s\n' "$version"
}

nc_validate_fragment() {
  local file="$1"
  local base line second third last nlines
  base="$(basename "$file")"
  if [[ ! "$base" =~ ^[a-z0-9][a-z0-9.-]{0,60}\.md$ ]]; then
    echo "news-collect: invalid fragment name: ${base}" >&2
    return 1
  fi
  if LC_ALL=C grep -q $'\r' "$file"; then
    echo "news-collect: ${base} must use LF" >&2
    return 1
  fi
  if ! tail -c 1 "$file" | cmp -s - <(printf '\n'); then
    echo "news-collect: ${base} must end with a newline" >&2
    return 1
  fi
  IFS= read -r line <"$file" || true
  case "$line" in
    "category: breaking" | "category: planned" | "category: added" | "category: fixed" | "category: changed" | "category: skip")
      ;;
    *)
      echo "news-collect: invalid category line in ${base}" >&2
      return 1
      ;;
  esac
  second="$(awk 'NR==2 { print; exit }' "$file")"
  if [[ -n "$second" ]]; then
    echo "news-collect: ${base} needs a blank line after the category" >&2
    return 1
  fi
  nlines="$(awk 'END { print NR+0 }' "$file")"
  if [[ "$nlines" -lt 3 ]]; then
    echo "news-collect: ${base} is missing text after the category" >&2
    return 1
  fi
  if awk 'NR>=3 && /^## / { found=1 } END { exit !found }' "$file"; then
    echo "news-collect: ${base} contains a ## heading" >&2
    return 1
  fi
  third="$(awk 'NR==3 { print; exit }' "$file")"
  if [[ -z "$third" ]]; then
    echo "news-collect: ${base} body is empty" >&2
    return 1
  fi
  last="$(awk 'END { print }' "$file")"
  if [[ -z "$last" ]]; then
    echo "news-collect: ${base} has a trailing blank line" >&2
    return 1
  fi
  if [[ "$line" == "category: skip" ]]; then
    if [[ "$nlines" -ne 3 ]]; then
      echo "news-collect: ${base} skip reason must be one line" >&2
      return 1
    fi
  elif ! awk 'NR>=3 && /^- / { found=1 } END { exit !found }' "$file"; then
    echo "news-collect: ${base} needs a bullet" >&2
    return 1
  fi
  printf '%s\n' "${line#category: }"
}

nc_heading_exists() {
  local file="$1"
  local version="$2"
  awk -v ver="$version" '
    BEGIN { found = 0 }
    {
      hdr = "## " ver
      if ($0 == hdr) { found = 1; exit }
      if (index($0, hdr) != 1) next
      rest = substr($0, length(hdr) + 1)
      if (rest ~ /^[ \t]*$/) { found = 1; exit }
    }
    END { exit !found }
  ' "$file"
}

nc_unreleased_line() {
  local file="$1"
  awk '
    /^## Unreleased[ \t]*$/ { print NR; found = 1; exit }
    END { if (!found) exit 1 }
  ' "$file"
}

nc_append_bodies() {
  local dest="$1"
  shift
  local file
  for file in "$@"; do
    awk 'NR>2 { print }' "$file" >>"$dest"
  done
}

nc_apply_root_impl() {
  local root="$1"
  local tmp="$2"
  local version news line next generated file category
  local -a files=() sorted=() breaking=() changed=() added=() fixed=() planned=() skip=() consumed=()
  shopt -s nullglob
  version="$(nc_read_version "${root}/Project.toml")"
  if [[ ! "$version" =~ ^[0-9]+[.][0-9]+[.][0-9]+$ ]]; then
    echo "news-collect: version ${version} is not a release X.Y.Z" >&2
    return 1
  fi
  news="${root}/NEWS.md"
  if [[ ! -f "$news" ]]; then
    echo "news-collect: NEWS.md is missing" >&2
    return 1
  fi
  if [[ ! -d "${root}/changelog.d" ]]; then
    echo "news-collect: changelog.d is missing" >&2
    return 1
  fi
  files=("${root}/changelog.d/"*)
  for file in "${files[@]}"; do
    case "$(basename "$file")" in
      *.md) ;;
      *)
        echo "news-collect: unexpected file in changelog.d: $(basename "$file")" >&2
        return 1
        ;;
    esac
  done
  if ((${#files[@]})); then
    mapfile -t sorted < <(printf '%s\n' "${files[@]}" | LC_ALL=C sort)
  fi
  for file in "${sorted[@]}"; do
    category="$(nc_validate_fragment "$file")"
    case "$category" in
      breaking) breaking+=("$file") ;;
      changed) changed+=("$file") ;;
      added) added+=("$file") ;;
      fixed) fixed+=("$file") ;;
      planned) planned+=("$file") ;;
      skip) skip+=("$file") ;;
      *)
        echo "news-collect: unknown category ${category}" >&2
        return 1
        ;;
    esac
  done
  if ((${#breaking[@]} + ${#changed[@]} + ${#added[@]} + ${#fixed[@]} == 0)); then
    echo "news-collect: release section would be empty" >&2
    return 1
  fi
  if nc_heading_exists "$news" "$version"; then
    echo "news-collect: NEWS.md already has ## ${version}" >&2
    return 1
  fi
  line="$(nc_unreleased_line "$news")"
  next="$(awk -v start="$line" 'NR>start && /^## / { print NR; exit }' "$news")"
  generated="${tmp}/generated"
  {
    printf '%s\n' "## Unreleased"
    printf '\n'
    printf '%s\n' "$nc_note_one"
    printf '%s\n' "$nc_note_two"
    printf '\n'
    printf '%s\n' "$nc_planned_heading"
    printf '\n'
  } >"$generated"
  if ((${#planned[@]})); then
    nc_append_bodies "$generated" "${planned[@]}"
    printf '\n' >>"$generated"
  fi
  {
    printf '## %s\n' "$version"
    printf '\n'
  } >>"$generated"
  if ((${#breaking[@]})); then
    printf '%s\n\n' "### Breaking" >>"$generated"
    nc_append_bodies "$generated" "${breaking[@]}"
  fi
  if ((${#changed[@]})); then
    nc_append_bodies "$generated" "${changed[@]}"
  fi
  if ((${#added[@]})); then
    nc_append_bodies "$generated" "${added[@]}"
  fi
  if ((${#fixed[@]})); then
    nc_append_bodies "$generated" "${fixed[@]}"
  fi
  printf '\n' >>"$generated"
  {
    head -n "$((line - 1))" "$news"
    cat "$generated"
    if [[ -n "$next" ]]; then
      tail -n +"$next" "$news"
    fi
  } >"${tmp}/NEWS.md"
  mv "${tmp}/NEWS.md" "$news"
  consumed=("${breaking[@]}" "${changed[@]}" "${added[@]}" "${fixed[@]}" "${skip[@]}")
  if ((${#consumed[@]})); then
    rm -f "${consumed[@]}"
  fi
  echo "news-collect: wrote ## ${version}"
}

nc_apply_root() {
  local root="$1"
  local tmp status
  tmp="$(mktemp -d)"
  status=0
  (
    set -euo pipefail
    nc_apply_root_impl "$root" "$tmp"
  ) || status=$?
  rm -rf "$tmp"
  return "$status"
}

nc_blob() {
  local rev="$1"
  local path="$2"
  local dest="$3"
  git cat-file -p "${rev}:${path}" >"$dest"
}

nc_ensure_range() {
  local old="$1"
  local new="$2"
  export GIT_TERMINAL_PROMPT=0
  git cat-file -e "${old}^{commit}" 2>/dev/null || git fetch --depth=1 origin "$old"
  git cat-file -e "${new}^{commit}" 2>/dev/null || git fetch --depth=1 origin "$new"
  git cat-file -e "${old}^{commit}" >/dev/null
  git cat-file -e "${new}^{commit}" >/dev/null
  if git merge-base "$old" "$new" >/dev/null 2>&1; then
    return 0
  fi
  if [[ -f "$(git rev-parse --git-path shallow)" ]]; then
    git fetch --unshallow origin >/dev/null 2>&1 || true
  fi
}

nc_recover_deleted() {
  local old="$1"
  local new="$2"
  local path="$3"
  local dest="$4"
  local commit
  if git merge-base --is-ancestor "$old" "$new" 2>/dev/null; then
    while IFS= read -r commit; do
      [[ -z "$commit" ]] && continue
      if git cat-file -e "${commit}:${path}" 2>/dev/null; then
        nc_blob "$commit" "$path" "$dest"
        return 0
      fi
    done < <(git rev-list "${old}..${new}")
  fi
  if git cat-file -e "${old}:${path}" 2>/dev/null; then
    nc_blob "$old" "$path" "$dest"
    return 0
  fi
  echo "news-collect: ${path} changed in this range but the fragment text is not in a commit. Commit the fragment, then run news-collect.sh." >&2
  return 1
}

nc_check_refs_impl() {
  local old="$1"
  local new="$2"
  local tmp="$3"
  local work frag actual path base version src
  local -a paths=()
  src="$old"
  if base_mb="$(git merge-base "$old" "$new" 2>/dev/null)"; then
    src="$base_mb"
  fi
  work="${tmp}/work"
  frag="${work}/changelog.d"
  actual="${tmp}/actual/changelog.d"
  mkdir -p "$frag" "$actual"
  nc_blob "$src" "NEWS.md" "${work}/NEWS.md"
  nc_blob "$new" "Project.toml" "${work}/Project.toml"
  {
    git ls-tree -r --name-only "$src" -- changelog.d
    git ls-tree -r --name-only "$new" -- changelog.d
    if git merge-base --is-ancestor "$src" "$new" 2>/dev/null; then
      git log --name-only --pretty=format: "${src}..${new}" -- changelog.d
    fi
  } | LC_ALL=C sort -u >"${tmp}/paths"
  mapfile -t paths <"${tmp}/paths"
  for path in "${paths[@]}"; do
    [[ -z "$path" ]] && continue
    case "$path" in
      changelog.d/*/*)
        echo "news-collect: nested fragment path ${path}" >&2
        return 1
        ;;
      changelog.d/*) ;;
      *)
        echo "news-collect: unexpected changelog path ${path}" >&2
        return 1
        ;;
    esac
    base="$(basename "$path")"
    if git cat-file -e "${new}:${path}" 2>/dev/null; then
      nc_blob "$new" "$path" "${frag}/${base}"
    else
      nc_recover_deleted "$src" "$new" "$path" "${frag}/${base}"
    fi
  done
  while IFS= read -r path; do
    [[ -z "$path" ]] && continue
    nc_blob "$new" "$path" "${actual}/$(basename "$path")"
  done < <(git ls-tree -r --name-only "$new" -- changelog.d)
  nc_apply_root "$work"
  if ! cmp -s "${work}/NEWS.md" <(git cat-file -p "${new}:NEWS.md"); then
    echo "news-collect: NEWS.md does not match the fragments" >&2
    diff -u <(git cat-file -p "${new}:NEWS.md") "${work}/NEWS.md" >&2 || true
    return 1
  fi
  if ! diff -ru "$frag" "$actual" >&2; then
    echo "news-collect: consumed fragments are still in changelog.d, or a planned fragment differs" >&2
    return 1
  fi
  version="$(nc_read_version "${work}/Project.toml")"
  echo "news-collect: NEWS.md ## ${version} matches the fragments"
}

nc_check_refs() {
  local old="$1"
  local new="$2"
  local tmp status
  nc_ensure_range "$old" "$new"
  tmp="$(mktemp -d)"
  status=0
  (
    set -euo pipefail
    nc_check_refs_impl "$old" "$new" "$tmp"
  ) || status=$?
  rm -rf "$tmp"
  return "$status"
}

nc_self_test() {
  local tmp failed script repo
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
  write_frag() {
    local path="$1"
    local category="$2"
    local body="$3"
    mkdir -p "$(dirname "$path")"
    printf 'category: %s\n\n%s\n' "$category" "$body" >"$path"
  }
  section_between() {
    local start="$1"
    local end="$2"
    awk -v start="$start" -v end="$end" '
      $0 == start { on = 1 }
      $0 == end { on = 0 }
      on { print }
    ' NEWS.md
  }

  mkdir -p "$repo"
  pushd "$repo" >/dev/null
  git init -q -b main
  git config user.email "news-collect@example.com"
  git config user.name "news-collect"
  printf 'name = "Example"\nversion = "0.1.0"\n' >Project.toml
  cat >NEWS.md <<'EOF'
# News

Intro stays.

## Unreleased

### Planned breaking (next minor)

- old planned text

## 0.1.0

- released line stays
EOF
  mkdir -p changelog.d
  write_frag changelog.d/brk.md breaking "- flags change"
  write_frag changelog.d/chg.md changed "- a default moved"
  write_frag changelog.d/add.md added "- new verb"
  write_frag changelog.d/fix.md fixed "- a bug"
  write_frag changelog.d/plan.md planned "- later break"
  write_frag changelog.d/quiet.md skip "rename of a private helper"
  git add -A
  git commit -q -m base
  base="$(git rev-parse HEAD)"
  printf 'name = "Example"\nversion = "0.1.1"\n' >Project.toml
  expect_rc 0 bash "$script"
  if [[ -e changelog.d/brk.md || -e changelog.d/chg.md || -e changelog.d/add.md || -e changelog.d/fix.md || -e changelog.d/quiet.md ]]; then
    fail "consumed fragments were not deleted"
  fi
  if [[ ! -f changelog.d/plan.md ]]; then
    fail "planned fragment was deleted"
  fi
  if ! grep -q '^- released line stays$' NEWS.md; then
    fail "released section changed"
  fi
  if grep -q 'old planned text' NEWS.md; then
    fail "old unreleased text remained"
  fi
  cat >"${tmp}/want-release" <<'EOF'
## 0.1.1

### Breaking

- flags change
- a default moved
- new verb
- a bug

EOF
  section_between "## 0.1.1" "## 0.1.0" >"${tmp}/got-release"
  if ! cmp -s "${tmp}/want-release" "${tmp}/got-release"; then
    fail "release section text"
    diff -u "${tmp}/want-release" "${tmp}/got-release" >&2 || true
  fi
  cat >"${tmp}/want-unreleased" <<'EOF'
## Unreleased

Notes since the last release are files in `changelog.d/`.
The version-cut PR copies them into this file.

### Planned breaking (next minor)

- later break

EOF
  section_between "## Unreleased" "## 0.1.1" >"${tmp}/got-unreleased"
  if ! cmp -s "${tmp}/want-unreleased" "${tmp}/got-unreleased"; then
    fail "unreleased section text"
    diff -u "${tmp}/want-unreleased" "${tmp}/got-unreleased" >&2 || true
  fi
  git show "${base}:NEWS.md" | awk 'BEGIN{p=0} /^## 0\.1\.0/{p=1} p{print}' >"${tmp}/old-rel"
  awk 'BEGIN{p=0} /^## 0\.1\.0/{p=1} p{print}' NEWS.md >"${tmp}/new-rel"
  if ! cmp -s "${tmp}/old-rel" "${tmp}/new-rel"; then
    fail "released bytes differ"
  fi
  git add -A
  git commit -q -m cut
  head_sha="$(git rev-parse HEAD)"
  expect_rc 0 bash "$script" --check "$base" "$head_sha"
  printf '\n- hand edit\n' >>NEWS.md
  git add -A
  git commit -q -m 'bad news'
  bad_news="$(git rev-parse HEAD)"
  expect_rc 1 bash "$script" --check "$base" "$bad_news"
  git reset -q --hard "$head_sha"
  write_frag changelog.d/extra.md fixed "- leftover"
  git add -A
  git commit -q -m leftover
  leftover="$(git rev-parse HEAD)"
  expect_rc 1 bash "$script" --check "$base" "$leftover"
  git reset -q --hard "$head_sha"

  git checkout -q "$base"
  git clean -q -fd
  printf 'name = "Example"\nversion = "0.1.1"\n' >Project.toml
  write_frag changelog.d/plan.md breaking "- later break"
  git add -A
  git commit -q -m promote
  expect_rc 0 bash "$script"
  git add -A
  git commit -q -m collect
  promoted="$(git rev-parse HEAD)"
  expect_rc 0 bash "$script" --check "$base" "$promoted"
  if ! awk '
    $0 == "## 0.1.1" { inrel = 1; next }
    inrel && $0 ~ /^## / { exit }
    inrel && $0 == "### Breaking" { hit = 1 }
    inrel && $0 == "- later break" { moved = 1 }
    END { exit !(hit && moved) }
  ' NEWS.md; then
    fail "promoted planned item was not under ### Breaking"
  fi

  git checkout -q "$base"
  git clean -q -fd
  rm -f changelog.d/*.md
  printf 'name = "Example"\nversion = "0.1.1"\n' >Project.toml
  write_frag changelog.d/only-skip.md skip "no user-visible change"
  before="$(cksum NEWS.md)"
  expect_rc 1 bash "$script"
  after="$(cksum NEWS.md)"
  if [[ "$before" != "$after" ]]; then
    fail "empty release rewrote NEWS.md"
  fi
  if [[ ! -f changelog.d/only-skip.md ]]; then
    fail "empty release deleted a fragment"
  fi
  popd >/dev/null

  mkdir -p "${tmp}/v"
  write_frag "${tmp}/v/ok.md" fixed "- one line"
  if ! nc_validate_fragment "${tmp}/v/ok.md" >/dev/null; then
    fail "valid fragment rejected"
  fi
  printf 'category: fixed\n\n- heading\n## 1.0\n' >"${tmp}/v/hed.md"
  if nc_validate_fragment "${tmp}/v/hed.md" >/dev/null 2>&1; then
    fail "heading fragment accepted"
  fi
  printf 'category: skip\n\nreason one\nreason two\n' >"${tmp}/v/long.md"
  if nc_validate_fragment "${tmp}/v/long.md" >/dev/null 2>&1; then
    fail "two-line skip accepted"
  fi
  printf 'category: skip\n\none reason\n' >"${tmp}/v/sk.md"
  if ! nc_validate_fragment "${tmp}/v/sk.md" >/dev/null; then
    fail "skip fragment rejected"
  fi
  printf 'category: fixed\npackage: Example\n\n- x\n' >"${tmp}/v/pkg.md"
  if nc_validate_fragment "${tmp}/v/pkg.md" >/dev/null 2>&1; then
    fail "package field accepted"
  fi
  printf 'category: fixed\n\n- Nope\n' >"${tmp}/v/Bad.md"
  if nc_validate_fragment "${tmp}/v/Bad.md" >/dev/null 2>&1; then
    fail "uppercase fragment name accepted"
  fi

  rm -rf "$tmp"
  if [[ "$failed" -ne 0 ]]; then
    exit 1
  fi
  echo "news-collect self-test ok"
}

nc_main() {
  case "${1:-}" in
    --self-test)
      nc_self_test
      ;;
    --check)
      if [[ $# -ne 3 ]]; then
        echo "usage: $0 --check OLD_REF NEW_REF" >&2
        exit 2
      fi
      nc_check_refs "$2" "$3"
      ;;
    "")
      nc_apply_root "."
      ;;
    *)
      echo "usage: $0 [--check OLD_REF NEW_REF | --self-test]" >&2
      exit 2
      ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  nc_main "$@"
fi
