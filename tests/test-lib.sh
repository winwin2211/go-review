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

# count_procs PATTERN -> number of processes whose full command line matches
count_procs() { pgrep -f "$1" | wc -l | tr -d ' '; }
# wait_procs PATTERN -> waits up to 5s for a matching process, prints the count
wait_procs() {
  local i
  for i in $(seq 1 50); do [[ $(count_procs "$1") -gt 0 ]] && break; perl -e 'select(undef, undef, undef, 0.1)'; done
  count_procs "$1"
}

# --- run_with_timeout: a timeout kills everything the command spawned, not only the direct child ---
# The grandchild is matched by its own command line only; it must be seen
# running first, or "none survive" would also pass when it never started.
marker="gr-timeout-marker-$$"
grandchild="^perl -e sleep 30 $marker\$"
run_with_timeout 2 "$out/timeout.txt" bash -c "perl -e 'sleep 30' $marker & wait" > "$out/timeout.status" &
seen=$(wait_procs "$grandchild")
wait $!
assert_eq "TIMEOUT" "$(cat "$out/timeout.status")" "a command that outlives its budget reports TIMEOUT"
[[ "$seen" -gt 0 ]] && pass || fail "the timed-out command's grandchild was seen running before the timeout"
sleep 1
n=$(count_procs "$grandchild")
pkill -f "$marker" 2>/dev/null || true
assert_eq "0" "$n" "no process spawned by the timed-out command survives the timeout"

# --- run_with_timeout: a caller killed with SIGKILL (no handler runs) does not leave the command running ---
# The caller runs in its own process group, as under a harness that kills a
# timed-out shell's whole group; the command's group is separate, so only a
# watchdog inside it can notice the supervisor is gone.
orphan="gr-orphan-marker-$$"
tool="^perl -e sleep 30 $orphan\$"
perl -e 'setpgrp(0, 0); exec @ARGV' bash -c "source '$REPO_ROOT/skill/scripts/lib.sh'; run_with_timeout 60 '$out/orphan.txt' perl -e 'sleep 30' $orphan" &
caller=$!
seen=$(wait_procs "$tool")
kill -KILL -- "-$caller"; wait "$caller" 2>/dev/null
for i in $(seq 1 40); do [[ $(count_procs "$tool") -eq 0 ]] && break; perl -e 'select(undef, undef, undef, 0.1)'; done
n=$(count_procs "$tool")
pkill -f "$orphan" 2>/dev/null || true
[[ "$seen" -gt 0 ]] && pass || fail "the command was seen running before its caller was killed"
assert_eq "0" "$n" "the command does not outlive a caller killed with SIGKILL"

# --- die/log prefix comes from REVIEW_TOOL, default go-review ---
r=$( (REVIEW_TOOL=other-review; die "boom") 2>&1 ); assert_eq "other-review: boom" "$r" "die uses REVIEW_TOOL as prefix"
r=$( (die "boom") 2>&1 ); assert_eq "go-review: boom" "$r" "die prefix defaults to go-review"

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
