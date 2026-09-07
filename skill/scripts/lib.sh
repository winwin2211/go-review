#!/usr/bin/env bash
# Shared helpers for go-review scripts. Source this file.

die() { printf 'go-review: %s\n' "$*" >&2; exit 1; }
log() { printf 'go-review: %s\n' "$*" >&2; }

# run_with_timeout SECONDS OUTFILE CMD... -> prints OK | FAIL | TIMEOUT | MISSING
run_with_timeout() {
  local secs=$1 out=$2; shift 2
  local rc=0
  perl -e 'alarm shift; exec @ARGV or exit 127' "$secs" "$@" >"$out" 2>&1 || rc=$?
  if [[ $rc -eq 142 ]]; then echo TIMEOUT
  elif [[ $rc -eq 127 ]]; then echo MISSING
  elif [[ $rc -eq 0 ]]; then echo OK
  else echo FAIL; fi
}

# resolve_path PATH -> prints an absolute, lexically resolved path for PATH.
# Walks up to the nearest existing ancestor of PATH and appends the
# remaining (possibly multi-level, possibly nonexistent) components, so a
# path with missing parent directories still resolves to somewhere sane (a
# bare `cd .../missing 2>/dev/null` failure used to leave a bogus relative
# path instead).
resolve_path() {
  local cur rest comp
  cur=$1
  rest=""
  while [[ ! -d "$cur" ]]; do
    comp=$(basename "$cur")
    if [[ -z "$rest" ]]; then rest="$comp"; else rest="$comp/$rest"; fi
    cur=$(dirname "$cur")
  done
  if [[ -n "$rest" ]]; then
    printf '%s/%s\n' "$(cd "$cur" && pwd -P)" "$rest"
  else
    (cd "$cur" && pwd -P)
  fi
}

# assert_outside PATH ROOT -> dies when PATH resolves under ROOT
assert_outside() {
  local p r
  p=$(resolve_path "$1")
  r=$(cd "$2" && pwd -P)
  case "$p" in "$r"/*|"$r") die "refusing to write inside the reviewed repo: $1" ;; esac
}

merge_base() { git -C "$1" merge-base "$2" "$3"; }

# resolve_base REPO -> prints the default base ref
resolve_base() {
  local repo=$1 b c
  b=$(git -C "$repo" symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null || true)
  [[ -n "$b" ]] && { echo "$b"; return; }
  for c in origin/develop origin/main develop main master; do
    git -C "$repo" rev-parse -q --verify "$c" >/dev/null 2>&1 && { echo "$c"; return; }
  done
  die "cannot resolve a base branch; pass --base"
}
