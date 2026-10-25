#!/usr/bin/env bash
# Unit tests for skill/scripts/lib.sh helpers.
source "$(dirname "$0")/lib.sh"
source "$REPO_ROOT/skill/scripts/lib.sh"
out=$(tmpdir)

# --- run_with_timeout: OK | FAIL | MISSING ---
r=$(run_with_timeout 5 "$out/missing.txt" nosuchcmd_xyz_should_never_exist)
assert_eq "MISSING" "$r" "a nonexistent binary reports MISSING, not a false OK"

r=$(run_with_timeout 5 "$out/fail.txt" false)
assert_eq "FAIL" "$r" "a binary that exits nonzero reports FAIL"

r=$(run_with_timeout 5 "$out/ok.txt" true)
assert_eq "OK" "$r" "a binary that exits zero reports OK"

# --- run_with_timeout: a timeout kills everything the command spawned, not only the direct child ---
marker="gr-timeout-marker-$$"
r=$(run_with_timeout 1 "$out/timeout.txt" bash -c "perl -e 'sleep 30' $marker & wait")
assert_eq "TIMEOUT" "$r" "a command that outlives its budget reports TIMEOUT"
sleep 1
n=$(pgrep -f "$marker" | wc -l | tr -d ' ')
pkill -f "$marker" 2>/dev/null || true
assert_eq "0" "$n" "no process spawned by the timed-out command survives the timeout"

# --- assert_outside: nonexistent multi-level paths must still resolve correctly ---
root=$(tmpdir)
outside=$(tmpdir)

# a path with two nonexistent parent levels, under root -> must be caught
(assert_outside "$root/a/b/c" "$root") 2>/dev/null
assert_eq "1" "$?" "assert_outside dies for a nonexistent nested path under root"

# same nonexistent shape, but outside root -> must pass silently
(assert_outside "$outside/a/b/c" "$root")
assert_eq "0" "$?" "assert_outside passes for a nonexistent nested path outside root"

# existing path under root is still caught
mkdir -p "$root/existing"
(assert_outside "$root/existing" "$root") 2>/dev/null
assert_eq "1" "$?" "assert_outside dies for an existing path under root"

finish
