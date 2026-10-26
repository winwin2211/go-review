#!/usr/bin/env bash
# Shared helpers for go-review scripts. Source this file.
#
# This file is shared byte-for-byte with sibling review skills; anything that
# differs between them goes through REVIEW_TOOL (log prefix, MR marker, test
# tmpdir prefix), never through an edit. REVIEW_TOOL is the name in the
# frontmatter of the SKILL.md beside scripts/, never the environment's: a
# value exported for one skill would otherwise put its name on the other's MR
# note, and its own already-posted check would then match that note and skip.
REVIEW_TOOL=$(awk 'NR > 1 && /^---$/ { exit } sub(/^name:[ \t]*/, "") { print; exit }' \
  "$(dirname "${BASH_SOURCE[0]}")/../SKILL.md" 2>/dev/null || true)
REVIEW_TOOL=${REVIEW_TOOL:-review}

die() { printf '%s: %s\n' "$REVIEW_TOOL" "$*" >&2; exit 1; }
log() { printf '%s: %s\n' "$REVIEW_TOOL" "$*" >&2; }

# run_with_timeout SECONDS OUTFILE CMD... -> prints OK | FAIL | TIMEOUT | MISSING
#
# The command runs in its own process group under a perl supervisor. On
# timeout the whole group gets TERM, then KILL five seconds later, so
# processes the command spawned (go test's test binaries, for instance) die
# with it instead of running on after the review has finished. A plain
# `alarm; exec` would only kill the direct child. A supervisor killed with
# SIGKILL runs no handler, so a watchdog inside the command's group polls for
# it once a second and kills the group when it is gone; the group is the
# watchdog's own, so it can never signal anyone else's.
run_with_timeout() {
  local secs=$1 out=$2; shift 2
  local rc=0
  perl -e '
    my $secs = shift @ARGV;
    my $super = $$;
    my $pid = fork;
    exit 127 unless defined $pid;
    if ($pid == 0) {
      setpgrp(0, 0);
      my $wd = fork;
      if (defined $wd && $wd == 0) {
        open(STDIN, "<", "/dev/null"); open(STDOUT, ">", "/dev/null"); open(STDERR, ">", "/dev/null");
        select(undef, undef, undef, 1) while kill 0, $super;
        kill "KILL", -getpgrp();
        exit 0;
      }
      exec @ARGV or exit 127;
    }
    my $timed_out = 0;
    $SIG{ALRM} = sub { $timed_out++; kill($timed_out == 1 ? "TERM" : "KILL", -$pid); alarm 5 };
    $SIG{TERM} = $SIG{INT} = $SIG{HUP} = sub { kill "TERM", -$pid; exit 143 };
    alarm $secs;
    my $w;
    do { $w = waitpid($pid, 0) } while ($w == -1 && $!{EINTR});
    my $st = $?;
    kill "KILL", -$pid;
    exit 142 if $timed_out;
    exit(($st & 127) ? 128 + ($st & 127) : $st >> 8);
  ' "$secs" "$@" >"$out" 2>&1 || rc=$?
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
