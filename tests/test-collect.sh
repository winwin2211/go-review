#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
S="$REPO_ROOT/skill/scripts"

fx=$(tmpdir); bash "$REPO_ROOT/fixtures/make-fixtures.sh" "$fx" >/dev/null
out=$(tmpdir)

# --- dirty, ref mode ---
bash "$S/collect.sh" --repo "$fx/dirty" --base main --head feature/XBI-100-orders --out "$out/d"
assert_file "$out/d/meta.env" "meta written"
assert_contains "$(cat "$out/d/meta.env")" "MODULE=example.com/dirty" "module detected"
assert_contains "$(cat "$out/d/changed-go-files.txt")" "internal/service/order.go" "changed go file listed"
assert_contains "$(cat "$out/d/changed-packages.txt")" "example.com/dirty/internal/handler" "changed package listed"
assert_contains "$(cat "$out/d/changed-symbols.txt")" "func (h *OrderHandler) List" "changed symbol listed"
assert_contains "$(cat "$out/d/tools/summary.txt")" $'build\tOK' "build ok"
assert_contains "$(cat "$out/d/tools/summary.txt")" $'test\tFAIL' "race makes tests fail"
assert_contains "$(cat "$out/d/tools/test.txt")" "DATA RACE" "race reported"
assert_contains "$(cat "$out/d/tools/test-classified.txt")" $'example.com/dirty/internal/counter\tFAIL' "counter classified FAIL"
[[ -e "$fx/dirty/bin" ]] && fail "no bin dir in repo" || pass
assert_eq "" "$(git -C "$fx/dirty" status --porcelain)" "dirty repo untouched"
[[ "$(cat "$out/d/nontest-lines.txt")" -gt 10 ]] && pass || fail "nontest line count"

# --- clean, worktree mode with an uncommitted change ---
echo '// touched' >> "$fx/clean/cmd/api/main.go"
echo 'package clean' > "$fx/clean/root.go"
bash "$S/collect.sh" --repo "$fx/clean" --base main --head WORKTREE --out "$out/c" --no-tools
assert_contains "$(cat "$out/c/meta.env")" "MODE=worktree" "worktree mode"
assert_contains "$(cat "$out/c/changed-go-files.txt")" "cmd/api/main.go" "uncommitted change included"
assert_contains "$(cat "$out/c/tools/summary.txt")" "UNAVAILABLE(skipped)" "tools skipped"
assert_eq "example.com/clean" "$(grep -x 'example.com/clean' "$out/c/changed-packages.txt")" "root-level go file yields root package"
rm "$fx/clean/root.go"
git -C "$fx/clean" checkout -q -- cmd/api/main.go

# --- not-runnable classification ---
mkdir -p "$out/x"
printf -- '--- FAIL: TestDB (0.00s)\n    db_test.go:10: dial tcp 127.0.0.1:5432: connect: connection refused\nFAIL\nFAIL\texample.com/x/internal/db\t0.1s\nok\texample.com/x/internal/ok\t0.1s\n' > "$out/x/test.txt"
bash "$S/collect.sh" --classify-only "$out/x/test.txt" > "$out/x/classified.txt"
assert_contains "$(cat "$out/x/classified.txt")" $'example.com/x/internal/db\tNOT_RUNNABLE' "connection refused -> not runnable"
assert_contains "$(cat "$out/x/classified.txt")" $'example.com/x/internal/ok\tOK' "ok package"

# --- refuses to write inside repo ---
assert_exit 1 bash "$S/collect.sh" --repo "$fx/dirty" --base main --head WORKTREE --out "$fx/dirty/.review"

# --- repo without go.mod: no-module handling must not abort under pipefail ---
nomod=$(tmpdir)
git -C "$nomod" init -q -b main
git -C "$nomod" config user.email fixture@example.com
git -C "$nomod" config user.name fixture
echo "hello" > "$nomod/file.txt"
git -C "$nomod" add -A && git -C "$nomod" commit -q -m "base"
git -C "$nomod" checkout -q -b feature/x
echo "hello again" >> "$nomod/file.txt"
git -C "$nomod" add -A && git -C "$nomod" commit -q -m "change"
assert_exit 0 bash "$S/collect.sh" --repo "$nomod" --base main --head feature/x --out "$out/nm"
assert_eq "MODULE=" "$(grep -x 'MODULE=' "$out/nm/meta.env")" "empty module recorded"
assert_contains "$(cat "$out/nm/tools/summary.txt")" $'build\tUNAVAILABLE(no-module)' "no-module build summary"

finish
