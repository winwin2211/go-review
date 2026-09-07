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

# --- C1: assert_outside must not fail open when --out's parents don't exist ---
assert_exit 1 bash "$S/collect.sh" --repo "$fx/dirty" --base main --head WORKTREE --out "$fx/dirty/a/b/c"
[[ -e "$fx/dirty/a" ]] && fail "C1: refused --out must not create any parent dir inside the repo" || pass

# --- C3: lint step must not abort on bash 3.2 when the repo has its own golangci config ---
cat > "$fx/dirty/.golangci.yml" <<'EOF'
version: "2"
linters:
  default: none
  enable:
    - govet
EOF
bash "$S/collect.sh" --repo "$fx/dirty" --base main --head feature/XBI-100-orders --out "$out/d-cfg"
assert_contains "$(cat "$out/d-cfg/tools/summary.txt")" $'test\t' "C3: run reaches the test step with a repo-owned golangci config"
assert_contains "$(cat "$out/d-cfg/tools/summary.txt")" $'vuln\t' "C3: run reaches the vuln step with a repo-owned golangci config"
rm "$fx/dirty/.golangci.yml"
assert_eq "" "$(git -C "$fx/dirty" status --porcelain)" "C3: dirty fixture clean again after removing the config"

# --- C4: go test's own exit status must not be discarded when no per-package FAIL line is emitted ---
c4=$(tmpdir)
git -C "$c4" init -q -b main
git -C "$c4" config user.email fixture@example.com
git -C "$c4" config user.name fixture
mkdir -p "$c4/pkg"
cat > "$c4/go.mod" <<'EOF'
module example.com/c4

go 1.22
EOF
cat > "$c4/pkg/a.go" <<'EOF'
package pkg

func A() int { return 1 }
EOF
git -C "$c4" add -A && git -C "$c4" commit -q -m base
git -C "$c4" checkout -q -b feature/x
cat > "$c4/pkg/a_test.go" <<'EOF'
package pkg

import "testing"

func TestA(t *testing.T) {
	if A() != 1 {
		t.Fatal("bad")
	}
}
EOF
git -C "$c4" add -A && git -C "$c4" commit -q -m "add test"
c4out=$(tmpdir)
# Pre-create the coverprofile path as a directory: `go test -coverprofile`
# then fails at the toolchain level ("... is a directory") before running any
# package, so it emits neither an "ok" nor a "FAIL <pkg>" line — exactly the
# class of run-error a FAIL-line count alone cannot see.
mkdir -p "$c4out/tools/cover.out"
bash "$S/collect.sh" --repo "$c4" --base main --head feature/x --out "$c4out"
assert_contains "$(cat "$c4out/tools/summary.txt")" $'test\tUNAVAILABLE(run-error)' "C4: go test's own failure is surfaced, not swallowed as OK"
assert_not_contains "$(cat "$c4out/tools/summary.txt")" $'test\tOK' "C4: must not report test OK when go test itself failed"

# --- Important 1: a NOT_RUNNABLE package (go test exits non-zero, but the
# failure is an environment-reason test, not a genuine FAIL) must report
# test OK with the not-runnable count, never run-error ---
nr=$(tmpdir)
git -C "$nr" init -q -b main
git -C "$nr" config user.email fixture@example.com
git -C "$nr" config user.name fixture
mkdir -p "$nr/pkg"
cat > "$nr/go.mod" <<'EOF'
module example.com/nr

go 1.22
EOF
cat > "$nr/pkg/a.go" <<'EOF'
package pkg

func A() int { return 1 }
EOF
git -C "$nr" add -A && git -C "$nr" commit -q -m base
git -C "$nr" checkout -q -b feature/x
cat > "$nr/pkg/a_test.go" <<'EOF'
package pkg

import (
	"net"
	"testing"
)

func TestPing(t *testing.T) {
	_, err := net.Dial("tcp", "127.0.0.1:1")
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
}
EOF
git -C "$nr" add -A && git -C "$nr" commit -q -m "add integration test"
nrout=$(tmpdir)
bash "$S/collect.sh" --repo "$nr" --base main --head feature/x --out "$nrout"
nrtest=$(grep $'^test\t' "$nrout/tools/summary.txt")
assert_contains "$nrtest" $'test\tOK' "Important 1: a NOT_RUNNABLE-only test package reports OK"
assert_contains "$nrtest" "1 not runnable locally" "Important 1: the not-runnable count is in the test detail"
assert_not_contains "$nrtest" "run-error" "Important 1: a NOT_RUNNABLE package must not be reported as run-error"

# --- Important 2: --status-repo takes the no-artifact baseline against a
# different working tree than --repo, for MR mode where --repo is a
# temporary worktree but assert-clean.sh later checks the real repo ---
i2main=$(tmpdir)
git -C "$i2main" init -q -b main
git -C "$i2main" config user.email fixture@example.com
git -C "$i2main" config user.name fixture
echo 'bin/' > "$i2main/.gitignore"
mkdir -p "$i2main/pkg"
cat > "$i2main/go.mod" <<'EOF'
module example.com/i2

go 1.22
EOF
cat > "$i2main/pkg/a.go" <<'EOF'
package pkg

func A() int { return 1 }
EOF
git -C "$i2main" add -A && git -C "$i2main" commit -q -m base
mkdir -p "$i2main/bin"
touch "$i2main/bin/x"
i2wt="$out/i2wt"
git -C "$i2main" worktree add -q --detach "$i2wt" main

i2out=$(tmpdir)
bash "$S/collect.sh" --repo "$i2wt" --base main --head WORKTREE --out "$i2out" --status-repo "$i2main" --no-tools
r=$(bash "$S/assert-clean.sh" --repo "$i2main" --out "$i2out")
assert_eq "No artifacts left: verified" "$r" "Important 2: --status-repo takes the baseline from the real repo, matching assert-clean.sh's target"

i2out2=$(tmpdir)
bash "$S/collect.sh" --repo "$i2wt" --base main --head WORKTREE --out "$i2out2" --no-tools
assert_exit 2 bash "$S/assert-clean.sh" --repo "$i2main" --out "$i2out2"

# --- I1: nontest-lines counts only non-test .go files; untracked _test.go files don't inflate it ---
nt=$(tmpdir)
git -C "$nt" init -q -b main
git -C "$nt" config user.email fixture@example.com
git -C "$nt" config user.name fixture
mkdir -p "$nt/pkg"
cat > "$nt/go.mod" <<'EOF'
module example.com/nt

go 1.22
EOF
cat > "$nt/pkg/a.go" <<'EOF'
package pkg

func A() int { return 1 }
EOF
git -C "$nt" add -A && git -C "$nt" commit -q -m base
# one genuine non-test line change, tracked
echo 'func B() int { return 2 }' >> "$nt/pkg/a.go"
# an untracked _test.go file with many lines must not count as non-test lines
{
  echo "package pkg"
  echo
  echo 'import "testing"'
  echo
  echo "func TestA(t *testing.T) {"
  for i in $(seq 1 20); do echo "  _ = $i"; done
  echo "}"
} > "$nt/pkg/a_test.go"
bash "$S/collect.sh" --repo "$nt" --base main --head WORKTREE --out "$out/nt" --no-tools
assert_eq "1" "$(cat "$out/nt/nontest-lines.txt")" "I1: nontest-lines counts only the one non-test .go line, ignoring the untracked test file"

# --- I5: a go.mod anywhere (not just the repo root) is recognized as a module ---
mono=$(tmpdir)
git -C "$mono" init -q -b main
git -C "$mono" config user.email fixture@example.com
git -C "$mono" config user.name fixture
mkdir -p "$mono/services/foo"
cat > "$mono/services/foo/go.mod" <<'EOF'
module example.com/foo

go 1.22
EOF
cat > "$mono/services/foo/main.go" <<'EOF'
package main

func main() {}
EOF
git -C "$mono" add -A && git -C "$mono" commit -q -m base
git -C "$mono" checkout -q -b feature/x
cat >> "$mono/services/foo/main.go" <<'EOF'

func helper() int { return 1 }
EOF
git -C "$mono" add -A && git -C "$mono" commit -q -m change
monoreal=$(cd "$mono" && pwd -P)
bash "$S/collect.sh" --repo "$mono" --base main --head feature/x --out "$out/mono"
assert_contains "$(cat "$out/mono/meta.env")" "MODULE_DIR=$monoreal/services/foo" "I5: monorepo module dir recorded"
assert_contains "$(cat "$out/mono/meta.env")" "MODULE=example.com/foo" "I5: monorepo module name resolved"
assert_contains "$(cat "$out/mono/tools/summary.txt")" $'build\tOK' "I5: build runs against the nested module, not the repo root"

# --- I5: changed files spanning more than one module keep UNAVAILABLE, with an accurate detail ---
mono2=$(tmpdir)
git -C "$mono2" init -q -b main
git -C "$mono2" config user.email fixture@example.com
git -C "$mono2" config user.name fixture
mkdir -p "$mono2/a" "$mono2/b"
printf 'module example.com/a\n\ngo 1.22\n' > "$mono2/a/go.mod"
printf 'module example.com/b\n\ngo 1.22\n' > "$mono2/b/go.mod"
printf 'package main\nfunc main() {}\n' > "$mono2/a/main.go"
printf 'package main\nfunc main() {}\n' > "$mono2/b/main.go"
git -C "$mono2" add -A && git -C "$mono2" commit -q -m base
git -C "$mono2" checkout -q -b feature/x
echo '// touch' >> "$mono2/a/main.go"
echo '// touch' >> "$mono2/b/main.go"
git -C "$mono2" add -A && git -C "$mono2" commit -q -m "touch both modules"
bash "$S/collect.sh" --repo "$mono2" --base main --head feature/x --out "$out/mono2"
assert_contains "$(cat "$out/mono2/tools/summary.txt")" "no go.mod at repo root; changed files span 2 modules" "I5: accurate detail when changed files span multiple modules"

# --- I7: baseline snapshots for assert-clean must exist even when --base cannot be resolved ---
i7out=$(tmpdir)
i7rc=0
bash "$S/collect.sh" --repo "$mono" --base no-such-branch-xyz --head WORKTREE --out "$i7out" >/dev/null 2>&1 || i7rc=$?
[[ "$i7rc" -ne 0 ]] && pass || fail "I7: a bad --base must fail the run (got exit 0)"
assert_file "$i7out/status-before.txt" "I7: status-before.txt written before the merge-base computation could fail"
assert_file "$i7out/stash-before.txt" "I7: stash-before.txt written before the merge-base computation could fail"
assert_file "$i7out/status-ignored-before.txt" "I7: status-ignored-before.txt written before the merge-base computation could fail"

finish
