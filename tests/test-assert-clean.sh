#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
S="$REPO_ROOT/skill/scripts"
fx=$(tmpdir); bash "$REPO_ROOT/fixtures/make-fixtures.sh" "$fx" >/dev/null
out=$(tmpdir)
bash "$S/collect.sh" --repo "$fx/clean" --base main --head WORKTREE --out "$out" --no-tools

r=$(bash "$S/assert-clean.sh" --repo "$fx/clean" --out "$out"); assert_eq "No artifacts left: verified" "$r" "clean verdict"

touch "$fx/clean/stray.txt"
assert_exit 2 bash "$S/assert-clean.sh" --repo "$fx/clean" --out "$out"
r=$(bash "$S/assert-clean.sh" --repo "$fx/clean" --out "$out" 2>&1 || true); assert_contains "$r" "stray.txt" "names the stray file"
rm "$fx/clean/stray.txt"

wt="$out/wt"; git -C "$fx/clean" worktree add -q "$wt" main
bash "$S/assert-clean.sh" --repo "$fx/clean" --out "$out" --worktree "$wt" >/dev/null
[[ -d "$wt" ]] && fail "worktree removed" || pass
n=$(git -C "$fx/clean" worktree list | grep -c "$wt" || true); assert_eq "0" "$n" "worktree pruned"

wt2="$out/wt2"; git -C "$fx/clean" worktree add -q "$wt2" main
rm -rf "$wt2"
assert_exit 0 bash "$S/assert-clean.sh" --repo "$fx/clean" --out "$out" --worktree "$wt2"
n=$(git -C "$fx/clean" worktree list | grep -c "$wt2" || true); assert_eq "0" "$n" "stale worktree metadata pruned"

assert_exit 1 bash "$S/assert-clean.sh" --repo "$out/does-not-exist" --out "$out"
r=$(bash "$S/assert-clean.sh" --repo "$out/does-not-exist" --out "$out" 2>&1 || true)
assert_not_contains "$r" "verified" "non-git repo path never reports verified"

out_nobaseline=$(tmpdir)
assert_exit 1 bash "$S/assert-clean.sh" --repo "$fx/clean" --out "$out_nobaseline"

# I4: the ignored-file snapshot is also part of the required baseline
out_noignored=$(tmpdir)
cp "$out/status-before.txt" "$out/stash-before.txt" "$out_noignored/"
assert_exit 1 bash "$S/assert-clean.sh" --repo "$fx/clean" --out "$out_noignored"

# I4: a gitignored file the reviewed repo's own tests write is caught, not
# silently invisible, and the failure banner points at the repo's own test
# suite rather than "a bug in go-review"
echo '/ignored-artifact.txt' >> "$fx/clean/.gitignore"
git -C "$fx/clean" add .gitignore && git -C "$fx/clean" commit -q -m "ignore artifact"
out_ignored=$(tmpdir)
bash "$S/collect.sh" --repo "$fx/clean" --base main --head WORKTREE --out "$out_ignored" --no-tools
touch "$fx/clean/ignored-artifact.txt"
r=$(bash "$S/assert-clean.sh" --repo "$fx/clean" --out "$out_ignored" 2>&1 || true)
assert_contains "$r" "ignored-artifact.txt" "I4: a stray gitignored file is caught by the ignored-status snapshot"
assert_contains "$r" "repo's own test suite" "I4: failure banner names the reviewed repo's tests as the likely cause"
rm "$fx/clean/ignored-artifact.txt"

# C5: never touch a --worktree that is not both outside the repo and a
# worktree git actually knows about, even when it happens to be the repo
# itself (a compromised or buggy orchestrator could compose exactly this).
r=$(bash "$S/assert-clean.sh" --repo "$fx/clean" --out "$out" --worktree "$fx/clean" 2>&1 || true)
rc=0
bash "$S/assert-clean.sh" --repo "$fx/clean" --out "$out" --worktree "$fx/clean" >/dev/null 2>&1 || rc=$?
[[ "$rc" -ne 0 ]] && pass || fail "C5: --worktree pointing at the repo itself must not exit 0"
assert_not_contains "$r" "verified" "C5: --worktree pointing at the repo itself must not print verified"
[[ -d "$fx/clean/.git" ]] && pass || fail "C5: the repo itself must survive a --worktree=repo call"

not_registered="$out/not-a-registered-worktree"
mkdir -p "$not_registered"
rc=0
bash "$S/assert-clean.sh" --repo "$fx/clean" --out "$out" --worktree "$not_registered" >/dev/null 2>&1 || rc=$?
[[ "$rc" -ne 0 ]] && pass || fail "C5: --worktree pointing at an unregistered directory must not exit 0"
[[ -d "$not_registered" ]] && pass || fail "C5: an unregistered --worktree directory must not be removed"

finish
