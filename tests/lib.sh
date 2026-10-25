#!/usr/bin/env bash
# Minimal assertion helpers for go-review tests. Source this file.
set -uo pipefail

_PASS=0
_FAIL=0
_TMPDIRS=()

pass() { _PASS=$((_PASS + 1)); }
fail() { _FAIL=$((_FAIL + 1)); printf 'FAIL: %s\n' "$1" >&2; }

assert_eq() { # expected actual msg
  if [[ "$1" == "$2" ]]; then pass; else fail "$3 (expected: '$1', actual: '$2')"; fi
}

assert_contains() { # haystack needle msg
  if [[ "$1" == *"$2"* ]]; then pass; else fail "$3 (missing: '$2')"; fi
}

assert_not_contains() { # haystack needle msg
  if [[ "$1" != *"$2"* ]]; then pass; else fail "$3 (unexpected: '$2')"; fi
}

assert_file() { # path msg
  if [[ -f "$1" ]]; then pass; else fail "$2 (no file: $1)"; fi
}

assert_link() { # path msg
  if [[ -L "$1" ]]; then pass; else fail "$2 (not a symlink: $1)"; fi
}

assert_exit() { # code cmd...
  local want=$1; shift
  local got=0
  "$@" >/dev/null 2>&1 || got=$?
  if [[ "$want" == "$got" ]]; then pass; else fail "exit code for '$*' (expected $want, got $got)"; fi
}

tmpdir() {
  local d
  d=$(mktemp -d "${TMPDIR:-/tmp}/${REVIEW_TOOL:-go-review}-test.XXXXXX")
  _TMPDIRS+=("$d")
  printf '%s\n' "$d"
}

_cleanup() {
  local d
  for d in "${_TMPDIRS[@]:-}"; do [[ -n "$d" && -d "$d" ]] && rm -rf "$d"; done
}
trap _cleanup EXIT

finish() {
  printf '%s: %d passed, %d failed\n' "$(basename "$0")" "$_PASS" "$_FAIL"
  [[ "$_FAIL" -eq 0 ]]
}

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export REPO_ROOT
