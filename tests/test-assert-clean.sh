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
finish
