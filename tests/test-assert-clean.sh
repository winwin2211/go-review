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

# MINOR: a --worktree path that was never created (an MR run that bailed
# before creating it) is a benign no-op, not a hard error. Uses a fresh
# collect: the repo was committed to above, so an older baseline would
# (correctly) report .gitignore as written after its start marker.
out_nc=$(tmpdir)
bash "$S/collect.sh" --repo "$fx/clean" --base main --head WORKTREE --out "$out_nc" --no-tools
r=$(bash "$S/assert-clean.sh" --repo "$fx/clean" --out "$out_nc" --worktree "$out_nc/never-created")
assert_eq "No artifacts left: verified" "$r" "MINOR: --worktree for a path never created is a no-op, not an error"

# --- writes that leave `git status` unchanged must still be caught ---
# (a) a tracked file the user had already modified is rewritten during the run
echo '// user wip' >> "$fx/clean/cmd/api/main.go"
out_a=$(tmpdir)
bash "$S/collect.sh" --repo "$fx/clean" --base main --head WORKTREE --out "$out_a" --no-tools
echo '// tool rewrote this' >> "$fx/clean/cmd/api/main.go"
r=$(bash "$S/assert-clean.sh" --repo "$fx/clean" --out "$out_a" 2>&1 || true)
assert_contains "$r" "cmd/api/main.go" "a pre-dirty tracked file rewritten during the run is caught"
assert_not_contains "$r" "verified" "a pre-dirty tracked file rewritten during the run is not verified"
git -C "$fx/clean" checkout -q -- cmd/api/main.go

# (b) a new file appears inside a directory that was already untracked
mkdir -p "$fx/clean/scratch"; echo x > "$fx/clean/scratch/x.txt"
out_b=$(tmpdir)
bash "$S/collect.sh" --repo "$fx/clean" --base main --head WORKTREE --out "$out_b" --no-tools
echo y > "$fx/clean/scratch/y.txt"
r=$(bash "$S/assert-clean.sh" --repo "$fx/clean" --out "$out_b" 2>&1 || true)
assert_contains "$r" "scratch/y.txt" "a new file inside a pre-existing untracked directory is caught"
rm -rf "$fx/clean/scratch"

# (c) a file is written inside a directory that was already ignored
echo '/tmpbuild/' >> "$fx/clean/.gitignore"
git -C "$fx/clean" add .gitignore && git -C "$fx/clean" commit -q -m "ignore tmpbuild"
mkdir -p "$fx/clean/tmpbuild"; echo a > "$fx/clean/tmpbuild/a.bin"
out_c=$(tmpdir)
bash "$S/collect.sh" --repo "$fx/clean" --base main --head WORKTREE --out "$out_c" --no-tools
echo b > "$fx/clean/tmpbuild/b.bin"
r=$(bash "$S/assert-clean.sh" --repo "$fx/clean" --out "$out_c" 2>&1 || true)
assert_contains "$r" "tmpbuild/b.bin" "a file written inside a pre-existing ignored directory is caught"
rm -rf "$fx/clean/tmpbuild"

# (d) writes under node_modules (tool caches) are pruned from the mtime scan
# only when ASSERT_CLEAN_PRUNE names the directory
mkdir -p "$fx/clean/node_modules"; echo x > "$fx/clean/node_modules/x.js"
out_d=$(tmpdir)
bash "$S/collect.sh" --repo "$fx/clean" --base main --head WORKTREE --out "$out_d" --no-tools
mkdir -p "$fx/clean/node_modules/.vite"; echo '{}' > "$fx/clean/node_modules/.vite/results.json"
r=$(ASSERT_CLEAN_PRUNE=node_modules bash "$S/assert-clean.sh" --repo "$fx/clean" --out "$out_d")
assert_eq "No artifacts left: verified" "$r" "ASSERT_CLEAN_PRUNE=node_modules hides writes under node_modules"
r=$(bash "$S/assert-clean.sh" --repo "$fx/clean" --out "$out_d" 2>&1 || true)
assert_contains "$r" "node_modules/.vite/results.json" "without ASSERT_CLEAN_PRUNE a write under node_modules is caught"
rm -rf "$fx/clean/node_modules"

# (e) a service running from the repo appends to its gitignored log and the
# IDE rewrites its settings while the review runs. git status is unchanged, so
# the check cannot tell these writes from a test's: it lists them, says who
# might have written them, and exits 3 (2 means git status proves a change)
echo '/logs/' >> "$fx/clean/.gitignore"; echo '/.idea/' >> "$fx/clean/.gitignore"
git -C "$fx/clean" add .gitignore && git -C "$fx/clean" commit -q -m "ignore logs and ide"
mkdir -p "$fx/clean/logs" "$fx/clean/.idea"; echo start > "$fx/clean/logs/app.log"; echo '<x/>' > "$fx/clean/.idea/workspace.xml"
out_e=$(tmpdir)
bash "$S/collect.sh" --repo "$fx/clean" --base main --head WORKTREE --out "$out_e" --no-tools
echo 'GET /health 200' >> "$fx/clean/logs/app.log"; echo '<x a="1"/>' > "$fx/clean/.idea/workspace.xml"
assert_exit 3 bash "$S/assert-clean.sh" --repo "$fx/clean" --out "$out_e"
r=$(bash "$S/assert-clean.sh" --repo "$fx/clean" --out "$out_e" 2>&1 || true)
assert_contains "$r" "logs/app.log" "(e) a write git status cannot see is listed"
assert_contains "$r" ".idea/workspace.xml" "(e) every such write is listed"
assert_contains "$r" "cannot tell who wrote" "(e) the banner says the writer is unknown"
assert_contains "$r" "your editor" "(e) the banner names the user's own edits as a possible writer"
assert_not_contains "$r" "most likely cause" "(e) the banner does not blame the repo's test suite"
assert_not_contains "$r" "verified" "(e) unattributed writes are not verified"

# (f) a change git status does prove still exits 2 and keeps its banner; the
# unattributed writes beside it keep their own label
out_f=$(tmpdir)
bash "$S/collect.sh" --repo "$fx/clean" --base main --head WORKTREE --out "$out_f" --no-tools
touch "$fx/clean/stray-f.txt"; echo 'GET /ready 200' >> "$fx/clean/logs/app.log"
assert_exit 2 bash "$S/assert-clean.sh" --repo "$fx/clean" --out "$out_f"
r=$(bash "$S/assert-clean.sh" --repo "$fx/clean" --out "$out_f" 2>&1 || true)
assert_contains "$r" "stray-f.txt" "(f) the change git status proves is listed"
assert_contains "$r" "most likely cause" "(f) a proven change keeps the test-suite banner"
assert_contains "$r" "cannot tell who wrote" "(f) the log write is labelled as unattributed"
rm -f "$fx/clean/stray-f.txt"; rm -rf "$fx/clean/logs" "$fx/clean/.idea"

# and a run that writes nothing is still verified after all of the above
out_ok=$(tmpdir)
bash "$S/collect.sh" --repo "$fx/clean" --base main --head WORKTREE --out "$out_ok" --no-tools
r=$(bash "$S/assert-clean.sh" --repo "$fx/clean" --out "$out_ok")
assert_eq "No artifacts left: verified" "$r" "a run that writes nothing is still verified"

finish
