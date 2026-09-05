#!/usr/bin/env bash
# Shared helpers for go-review scripts. Source this file.

die() { printf 'go-review: %s\n' "$*" >&2; exit 1; }
log() { printf 'go-review: %s\n' "$*" >&2; }

# run_with_timeout SECONDS OUTFILE CMD... -> prints OK | FAIL | TIMEOUT
run_with_timeout() {
  local secs=$1 out=$2; shift 2
  local rc=0
  perl -e 'alarm shift; exec @ARGV' "$secs" "$@" >"$out" 2>&1 || rc=$?
  if [[ $rc -eq 142 ]]; then echo TIMEOUT
  elif [[ $rc -eq 0 ]]; then echo OK
  else echo FAIL; fi
}

# assert_outside PATH ROOT -> dies when PATH resolves under ROOT
assert_outside() {
  local p r
  p=$(cd "$(dirname "$1")" 2>/dev/null && pwd -P)/$(basename "$1")
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
