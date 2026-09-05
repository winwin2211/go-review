# go-review Skill Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the `/go-review` Claude Code skill: scripts that collect diff + tool evidence and spec candidates, six read-only agent definitions, reference checklists, and an orchestrator workflow, all leaving the reviewed project untouched.

**Architecture:** Bash scripts (tested with plain bash test files against generated Go fixture repos) produce evidence files in a temp dir. Markdown reference files define the review standard per dimension. Agent definition files in `agents/` are symlinked into `~/.claude/agents`; the skill dir into `~/.claude/skills/go-review`. The orchestrator is the SKILL.md + `references/workflow.md` that the main session follows.

**Tech Stack:** bash 3.2+ (macOS default), git, go 1.22+, golangci-lint v2, jq, perl (for timeouts), glab (optional, MR only). No bats, no shellcheck, no GNU timeout assumed.

**Spec:** `docs/superpowers/specs/2026-09-05-go-review-skill-design.md`

## Global Constraints

- Scripts never write under the reviewed repo root. All output goes to a `--out` dir the caller created with `mktemp -d`.
- Scripts never run: `go mod tidy`, `go generate`, `gofmt -w`, `goimports -w`, `golangci-lint --fix`, and never set `-mod` flags.
- `go build` always uses `-o "$OUT/bin/"`.
- `go test` always uses `-short -race -count=1 -coverprofile="$OUT/tools/cover.out"`.
- Timeouts: build/vet 180s, lint 300s, tests 600s, vuln 180s. Timed-out tool status is `UNAVAILABLE(timeout)`, never `FAIL`.
- Report language: English. Severities: `BLOCKER`, `MAJOR`, `MINOR`. Verdicts: `REQUEST CHANGES`, `APPROVE WITH COMMENTS`, `APPROVE`.
- Verifier thresholds: >= 80 report, 60-79 "Needs human judgment", < 60 drop. Rule-based findings are not scored.
- Spec conventions searched in order: `docs/superpowers/{specs,plans}`, `openspec/`, `docs/**/*.md` (README excluded).
- Substantive threshold: > 50 non-test lines, or any endpoint/handler/resolver/consumer/publisher/schema/migration/package change, or behavior change in service/usecase/repository.
- Commit messages: plain, no AI attribution trailers (user's global rule).
- Bash scripts start with `#!/usr/bin/env bash` and `set -euo pipefail`.

## Shared interfaces

**Findings JSON** (`$OUT/findings.json`, written by the orchestrator after verification, read by `gitlab-post.sh`): a JSON array of objects:

```json
{
  "id": "B1",
  "dimension": "correctness|security|architecture|performance|sdd-tdd|tools",
  "severity": "BLOCKER|MAJOR|MINOR",
  "rule_based": true,
  "file": "internal/service/order.go",
  "line": 42,
  "title": "Balance updated outside the transaction",
  "evidence": "quoted code or tool output",
  "why": "one or two sentences",
  "fix": "one or two sentences, optional short Go snippet",
  "spec_ref": "docs/superpowers/specs/x.md#section or empty string",
  "score": 92
}
```

**Tool summary** (`$OUT/tools/summary.txt`): one line per tool, `name<TAB>status<TAB>detail`, status in `OK|FAIL|UNAVAILABLE(<reason>)`.

**Spec candidates** (`$OUT/specs.tsv`): `path<TAB>convention<TAB>signals`, convention in `superpowers|openspec|docs|forced`, signals comma-separated from `ticket:<KEY>`, `branch:<token>`, `title:<word>`, `package:<name>`, `git-log`, `forced`. Sorted by signal count descending. `$OUT/specs-all.txt` lists every candidate path regardless of match.

## File Structure

```
go-review/
  install.sh                      Task 1
  README.md                       Task 15
  tests/
    lib.sh                        Task 1  assert helpers + temp dir handling
    run.sh                        Task 1  runs every tests/test-*.sh
    test-install.sh               Task 1
    test-fixtures.sh              Task 2
    test-collect.sh               Task 3
    test-assert-clean.sh          Task 4
    test-find-specs.sh            Task 5
    test-gitlab-post.sh           Task 6
    test-references.sh            Task 13 every path/heading referenced by SKILL.md/workflow.md exists
    test-agents.sh                Task 14 frontmatter and contract of every agent file
    test-e2e-checklist.md         Task 15 manual acceptance record
  fixtures/
    make-fixtures.sh              Task 2  generates dirty/ and clean/ git repos into <outdir>
    out/                          gitignored
  skill/
    SKILL.md                      Task 13
    references/
      workflow.md                 Task 13
      tooling.md                  Task 7
      gitlab.md                   Task 7
      severity-verdict.md         Task 8
      report-format.md            Task 8
      checklist-correctness.md    Task 9
      checklist-security.md       Task 10
      checklist-architecture.md   Task 11
      checklist-performance.md    Task 11
      checklist-sdd-tdd.md        Task 12
    scripts/
      lib.sh                      Task 3  shared: die, log, run_with_timeout, assert_outside, merge_base, resolve_base
      collect.sh                  Task 3
      assert-clean.sh             Task 4
      find-specs.sh               Task 5
      gitlab-post.sh              Task 6
      golangci-strict.yml         Task 3
  agents/
    go-review-correctness.md      Task 1 (placeholder), Task 14 (real)
    go-review-security.md         Task 14
    go-review-architecture.md     Task 14
    go-review-performance.md      Task 14
    go-review-sdd-tdd.md          Task 14
    go-review-verifier.md         Task 14
```

---

### Task 1: Test harness and installer

**Files:**
- Create: `tests/lib.sh`, `tests/run.sh`, `tests/test-install.sh`, `install.sh`

**Interfaces:**
- Produces: `tests/lib.sh` exports `assert_eq <expected> <actual> <msg>`, `assert_contains <haystack> <needle> <msg>`, `assert_file <path> <msg>`, `assert_exit <code> <cmd...>`, `tmpdir` (creates and registers a temp dir removed on exit), `pass`/`fail` counters, `finish` (prints summary, exits 1 on any failure). Every test file sources it with `source "$(dirname "$0")/lib.sh"`.
- Produces: `install.sh [--uninstall]` creates symlinks `~/.claude/skills/go-review -> <repo>/skill` and `~/.claude/agents/go-review-*.md -> <repo>/agents/*.md`. Honors `CLAUDE_HOME` env override (default `$HOME/.claude`) so tests do not touch the real home.

- [ ] **Step 1: Write `tests/lib.sh`**

```bash
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
  d=$(mktemp -d "${TMPDIR:-/tmp}/go-review-test.XXXXXX")
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
```

- [ ] **Step 2: Write `tests/run.sh`**

```bash
#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")"
rc=0
for t in test-*.sh; do
  echo "== $t"
  bash "$t" || rc=1
done
exit $rc
```

- [ ] **Step 3: Write the failing installer test `tests/test-install.sh`**

```bash
#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"

home=$(tmpdir)
mkdir -p "$home/skills" "$home/agents"

CLAUDE_HOME="$home" bash "$REPO_ROOT/install.sh" >/dev/null
assert_link "$home/skills/go-review" "skill symlink created"
assert_eq "$REPO_ROOT/skill" "$(readlink "$home/skills/go-review")" "skill symlink target"
for a in correctness security architecture performance sdd-tdd verifier; do
  assert_link "$home/agents/go-review-$a.md" "agent symlink $a"
done

# idempotent
CLAUDE_HOME="$home" bash "$REPO_ROOT/install.sh" >/dev/null
assert_link "$home/skills/go-review" "skill symlink survives reinstall"

CLAUDE_HOME="$home" bash "$REPO_ROOT/install.sh" --uninstall >/dev/null
[[ -e "$home/skills/go-review" ]] && fail "skill symlink removed" || pass
[[ -e "$home/agents/go-review-verifier.md" ]] && fail "agent symlink removed" || pass

finish
```

- [ ] **Step 4: Run it to verify it fails**

Run: `bash tests/test-install.sh`
Expected: FAIL lines (install.sh does not exist yet), non-zero exit.

- [ ] **Step 5: Write `install.sh`**

```bash
#!/usr/bin/env bash
# Symlink the go-review skill and agents into a Claude Code home.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")" && pwd)
CLAUDE_HOME=${CLAUDE_HOME:-$HOME/.claude}
AGENTS="correctness security architecture performance sdd-tdd verifier"

link() { # target linkpath
  if [[ -L "$2" ]]; then rm "$2"; elif [[ -e "$2" ]]; then
    echo "refusing to replace non-symlink: $2" >&2; exit 1; fi
  ln -s "$1" "$2"
  echo "linked $2 -> $1"
}

unlink_if_ours() { # linkpath
  [[ -L "$1" ]] && rm "$1" && echo "removed $1" || true
}

if [[ "${1:-}" == "--uninstall" ]]; then
  unlink_if_ours "$CLAUDE_HOME/skills/go-review"
  for a in $AGENTS; do unlink_if_ours "$CLAUDE_HOME/agents/go-review-$a.md"; done
  exit 0
fi

mkdir -p "$CLAUDE_HOME/skills" "$CLAUDE_HOME/agents"
link "$ROOT/skill" "$CLAUDE_HOME/skills/go-review"
for a in $AGENTS; do
  [[ -f "$ROOT/agents/go-review-$a.md" ]] || { echo "missing agents/go-review-$a.md (not written yet)" >&2; continue; }
  link "$ROOT/agents/go-review-$a.md" "$CLAUDE_HOME/agents/go-review-$a.md"
done
```

Create placeholder agent files so the test passes now (they are rewritten in Task 15): `mkdir -p skill agents && for a in correctness security architecture performance sdd-tdd verifier; do printf -- '---\nname: go-review-%s\ndescription: placeholder\ntools: Read, Grep, Glob, Bash\nmodel: inherit\n---\nplaceholder\n' "$a" > agents/go-review-$a.md; done`

- [ ] **Step 6: Run the test to verify it passes**

Run: `bash tests/test-install.sh`
Expected: `test-install.sh: N passed, 0 failed`

- [ ] **Step 7: Commit**

```bash
git add tests/lib.sh tests/run.sh tests/test-install.sh install.sh agents/
git commit -m "Add test harness and installer"
```

---

### Task 2: Fixture generator (dirty and clean Go repos)

**Files:**
- Create: `fixtures/make-fixtures.sh`, `tests/test-fixtures.sh`

**Interfaces:**
- Produces: `fixtures/make-fixtures.sh <outdir>` creates `<outdir>/dirty` and `<outdir>/clean`, each a git repo with branch `main` (base) and `feature/XBI-100-orders` (head) checked out, module names `example.com/dirty` and `example.com/clean`. Both compile with `go build ./...` on `main`.
- Seeded defects in `dirty` feature branch (each is a test expectation in later tasks):
  - D1 data race: `internal/counter/counter.go` `Counter.Inc` increments without a mutex; `counter_test.go` runs 50 goroutines so `go test -race` fails.
  - D2 swallowed error: `internal/service/order.go` `PlaceOrder` does `if err := s.repo.Save(ctx, o); err != nil { return nil }`.
  - D3 SQL concat: `internal/repo/order_repo.go` `FindByUser` builds `"SELECT id FROM orders WHERE user = '" + user + "'"`.
  - D4 layer breach: `internal/handler/order_handler.go` imports `internal/repo` and calls `repo.FindByUser` directly.
  - D5 no spec: no `docs/`, no `openspec/`.
  - D6 assertion-less test: `internal/service/order_test.go` `TestPlaceOrder` calls the function and asserts nothing.
- `clean` feature branch: `internal/service/order.go` with proper error wrapping, `order_test.go` covering success, repo error, and validation error; `docs/superpowers/specs/2026-09-01-XBI-100-orders-design.md` with all 10 sections; `docs/superpowers/plans/2026-09-01-XBI-100-orders-plan.md` with checked tasks.

- [ ] **Step 1: Write the failing fixture test `tests/test-fixtures.sh`**

```bash
#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"

out=$(tmpdir)
bash "$REPO_ROOT/fixtures/make-fixtures.sh" "$out" >/dev/null

for r in dirty clean; do
  d="$out/$r"
  assert_file "$d/go.mod" "$r has go.mod"
  assert_eq "feature/XBI-100-orders" "$(git -C "$d" rev-parse --abbrev-ref HEAD)" "$r on feature branch"
  assert_exit 0 git -C "$d" rev-parse --verify main
  assert_eq "" "$(git -C "$d" status --porcelain)" "$r working tree clean"
  ( cd "$d" && go build -o "$out/bin-$r/" ./... >/dev/null 2>&1 ) && pass || fail "$r builds"
done

# dirty: race must be detectable, spec must be absent
( cd "$out/dirty" && go test -short -race -count=1 ./internal/counter/ >/dev/null 2>&1 ) && fail "dirty race detected" || pass
[[ -d "$out/dirty/docs" ]] && fail "dirty has no docs" || pass
assert_contains "$(cat "$out/dirty/internal/repo/order_repo.go")" "WHERE user = '\" + user" "dirty has SQL concat"
assert_contains "$(cat "$out/dirty/internal/handler/order_handler.go")" "example.com/dirty/internal/repo" "dirty handler imports repo"

# clean: tests pass, spec + plan exist
( cd "$out/clean" && go test -short -race -count=1 ./... >/dev/null 2>&1 ) && pass || fail "clean tests pass"
assert_file "$out/clean/docs/superpowers/specs/2026-09-01-XBI-100-orders-design.md" "clean spec"
assert_file "$out/clean/docs/superpowers/plans/2026-09-01-XBI-100-orders-plan.md" "clean plan"
finish
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash tests/test-fixtures.sh`
Expected: fails because `fixtures/make-fixtures.sh` does not exist.

- [ ] **Step 3: Write `fixtures/make-fixtures.sh`**

```bash
#!/usr/bin/env bash
# Generate throwaway Go git repos used to test go-review. Usage: make-fixtures.sh <outdir>
set -euo pipefail
OUT=${1:?outdir required}
mkdir -p "$OUT"

git_init() { # dir
  git -C "$1" init -q -b main
  git -C "$1" config user.email fixture@example.com
  git -C "$1" config user.name fixture
}
commit_all() { git -C "$1" add -A && git -C "$1" commit -q -m "$2"; }

# ---------- dirty ----------
D="$OUT/dirty"; rm -rf "$D"; mkdir -p "$D/internal/counter" "$D/internal/repo" "$D/internal/service" "$D/internal/handler" "$D/cmd/api"
git_init "$D"
cat > "$D/go.mod" <<'EOF'
module example.com/dirty

go 1.22
EOF
cat > "$D/internal/counter/counter.go" <<'EOF'
package counter

// Counter counts events.
type Counter struct{ n int }

// Inc increments the counter.
func (c *Counter) Inc() { c.n++ }

// Value returns the count.
func (c *Counter) Value() int { return c.n }
EOF
cat > "$D/internal/repo/order_repo.go" <<'EOF'
package repo

import (
	"context"
	"database/sql"
)

// Order is a persisted order.
type Order struct {
	ID   string
	User string
	Qty  int
}

// OrderRepo stores orders.
type OrderRepo struct{ DB *sql.DB }

// Save persists an order.
func (r *OrderRepo) Save(ctx context.Context, o Order) error {
	_, err := r.DB.ExecContext(ctx, "INSERT INTO orders(id, user, qty) VALUES (?, ?, ?)", o.ID, o.User, o.Qty)
	return err
}

// FindByUser lists order ids for a user.
func (r *OrderRepo) FindByUser(ctx context.Context, user string) ([]string, error) {
	rows, err := r.DB.QueryContext(ctx, "SELECT id FROM orders WHERE user = ?", user)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var ids []string
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			return nil, err
		}
		ids = append(ids, id)
	}
	return ids, rows.Err()
}
EOF
cat > "$D/internal/service/order.go" <<'EOF'
package service

import (
	"context"
	"errors"
	"fmt"

	"example.com/dirty/internal/repo"
)

// Saver persists orders.
type Saver interface {
	Save(ctx context.Context, o repo.Order) error
}

// OrderService places orders.
type OrderService struct{ repo Saver }

// New creates an OrderService.
func New(s Saver) *OrderService { return &OrderService{repo: s} }

// PlaceOrder validates and stores an order.
func (s *OrderService) PlaceOrder(ctx context.Context, o repo.Order) (*repo.Order, error) {
	if o.Qty <= 0 {
		return nil, errors.New("qty must be positive")
	}
	if err := s.repo.Save(ctx, o); err != nil {
		return nil, fmt.Errorf("save order %s: %w", o.ID, err)
	}
	return &o, nil
}
EOF
cat > "$D/internal/handler/order_handler.go" <<'EOF'
package handler

import (
	"context"
	"net/http"

	"example.com/dirty/internal/service"
)

// OrderHandler serves order endpoints.
type OrderHandler struct{ svc *service.OrderService }

// New creates an OrderHandler.
func New(svc *service.OrderService) *OrderHandler { return &OrderHandler{svc: svc} }

// Health responds 200.
func (h *OrderHandler) Health(w http.ResponseWriter, r *http.Request) { w.WriteHeader(http.StatusOK) }

var _ = context.Background
EOF
cat > "$D/cmd/api/main.go" <<'EOF'
package main

import "fmt"

func main() { fmt.Println("dirty api") }
EOF
commit_all "$D" "base"

git -C "$D" checkout -q -b feature/XBI-100-orders
# D1: race
cat > "$D/internal/counter/counter_test.go" <<'EOF'
package counter

import (
	"sync"
	"testing"
)

func TestIncConcurrent(t *testing.T) {
	var c Counter
	var wg sync.WaitGroup
	for i := 0; i < 50; i++ {
		wg.Add(1)
		go func() { defer wg.Done(); c.Inc() }()
	}
	wg.Wait()
	if c.Value() != 50 {
		t.Fatalf("got %d", c.Value())
	}
}
EOF
# D2: swallowed error
cat > "$D/internal/service/order.go" <<'EOF'
package service

import (
	"context"
	"errors"

	"example.com/dirty/internal/repo"
)

// Saver persists orders.
type Saver interface {
	Save(ctx context.Context, o repo.Order) error
}

// OrderService places orders.
type OrderService struct{ repo Saver }

// New creates an OrderService.
func New(s Saver) *OrderService { return &OrderService{repo: s} }

// PlaceOrder validates and stores an order.
func (s *OrderService) PlaceOrder(ctx context.Context, o repo.Order) (*repo.Order, error) {
	if o.Qty <= 0 {
		return nil, errors.New("qty must be positive")
	}
	if err := s.repo.Save(ctx, o); err != nil {
		return nil, nil
	}
	return &o, nil
}
EOF
# D3: SQL concat
python3 - "$D/internal/repo/order_repo.go" <<'EOF'
import sys
p = sys.argv[1]
s = open(p).read()
s = s.replace('"SELECT id FROM orders WHERE user = ?", user', '"SELECT id FROM orders WHERE user = \'" + user + "\'"')
open(p, "w").write(s)
EOF
# D4: handler -> repo directly
cat > "$D/internal/handler/order_handler.go" <<'EOF'
package handler

import (
	"encoding/json"
	"net/http"

	"example.com/dirty/internal/repo"
	"example.com/dirty/internal/service"
)

// OrderHandler serves order endpoints.
type OrderHandler struct {
	svc  *service.OrderService
	repo *repo.OrderRepo
}

// New creates an OrderHandler.
func New(svc *service.OrderService, r *repo.OrderRepo) *OrderHandler {
	return &OrderHandler{svc: svc, repo: r}
}

// List returns the caller's order ids.
func (h *OrderHandler) List(w http.ResponseWriter, r *http.Request) {
	ids, err := h.repo.FindByUser(r.Context(), r.URL.Query().Get("user"))
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	_ = json.NewEncoder(w).Encode(ids)
}

// Health responds 200.
func (h *OrderHandler) Health(w http.ResponseWriter, r *http.Request) { w.WriteHeader(http.StatusOK) }
EOF
# D6: assertion-less test
cat > "$D/internal/service/order_test.go" <<'EOF'
package service

import (
	"context"
	"testing"

	"example.com/dirty/internal/repo"
)

type fakeSaver struct{}

func (fakeSaver) Save(context.Context, repo.Order) error { return nil }

func TestPlaceOrder(t *testing.T) {
	s := New(fakeSaver{})
	_, _ = s.PlaceOrder(context.Background(), repo.Order{ID: "1", User: "u", Qty: 1})
}
EOF
commit_all "$D" "XBI-100 add order listing"

# ---------- clean ----------
C="$OUT/clean"; rm -rf "$C"; mkdir -p "$C/internal/service" "$C/cmd/api"
git_init "$C"
cat > "$C/go.mod" <<'EOF'
module example.com/clean

go 1.22
EOF
cat > "$C/cmd/api/main.go" <<'EOF'
package main

import "fmt"

func main() { fmt.Println("clean api") }
EOF
commit_all "$C" "base"
git -C "$C" checkout -q -b feature/XBI-100-orders
mkdir -p "$C/docs/superpowers/specs" "$C/docs/superpowers/plans"
cat > "$C/internal/service/order.go" <<'EOF'
package service

import (
	"context"
	"errors"
	"fmt"
)

// ErrInvalidQty is returned when quantity is not positive.
var ErrInvalidQty = errors.New("qty must be positive")

// Order is an order request.
type Order struct {
	ID   string
	User string
	Qty  int
}

// Saver persists orders.
type Saver interface {
	Save(ctx context.Context, o Order) error
}

// OrderService places orders.
type OrderService struct{ repo Saver }

// New creates an OrderService.
func New(s Saver) *OrderService { return &OrderService{repo: s} }

// PlaceOrder validates and stores an order.
func (s *OrderService) PlaceOrder(ctx context.Context, o Order) (*Order, error) {
	if o.Qty <= 0 {
		return nil, ErrInvalidQty
	}
	if err := s.repo.Save(ctx, o); err != nil {
		return nil, fmt.Errorf("save order %s: %w", o.ID, err)
	}
	return &o, nil
}
EOF
cat > "$C/internal/service/order_test.go" <<'EOF'
package service

import (
	"context"
	"errors"
	"testing"
)

type fakeSaver struct{ err error }

func (f fakeSaver) Save(context.Context, Order) error { return f.err }

func TestPlaceOrder(t *testing.T) {
	boom := errors.New("boom")
	cases := []struct {
		name    string
		order   Order
		saveErr error
		wantErr error
	}{
		{"success", Order{ID: "1", User: "u", Qty: 2}, nil, nil},
		{"invalid qty", Order{ID: "1", User: "u", Qty: 0}, nil, ErrInvalidQty},
		{"repo error", Order{ID: "1", User: "u", Qty: 1}, boom, boom},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			s := New(fakeSaver{err: tc.saveErr})
			got, err := s.PlaceOrder(context.Background(), tc.order)
			if !errors.Is(err, tc.wantErr) {
				t.Fatalf("err = %v, want %v", err, tc.wantErr)
			}
			if tc.wantErr == nil && (got == nil || got.ID != tc.order.ID) {
				t.Fatalf("got = %+v", got)
			}
		})
	}
}
EOF
cat > "$C/docs/superpowers/specs/2026-09-01-XBI-100-orders-design.md" <<'EOF'
# XBI-100 Order Placement Service

## Goal
Add an `OrderService.PlaceOrder` that validates quantity and persists the order.

## Scope
In: validation of quantity, persistence through a `Saver` interface, error wrapping.
Out of scope: HTTP handler, pricing, inventory.

## Current State
No order service exists; `cmd/api` only prints a banner.

## Design Decisions
- `Saver` is an interface owned by the service package so the repository can be faked in tests (rationale: keeps service tests hermetic).
- Validation returns the sentinel `ErrInvalidQty` so callers can map it to HTTP 400.

## Contracts
`func (s *OrderService) PlaceOrder(ctx context.Context, o Order) (*Order, error)`
`type Saver interface { Save(ctx context.Context, o Order) error }`

## Error Handling and Edge Cases
- `Qty <= 0` returns `ErrInvalidQty` without calling `Save`.
- `Save` errors are wrapped with the order id and returned; no retry.

## Data / Migration Impact
None; persistence schema is owned by the repository (future work).

## Risks and Rollback
Low risk, additive package. Rollback by deleting `internal/service`.

## Testing Strategy
Table-driven test for: success, invalid qty, repository error. Each must assert the returned error with `errors.Is`.

## Acceptance Criteria
- AC1: valid order is returned unchanged and `Save` is called once.
- AC2: qty 0 returns `ErrInvalidQty`.
- AC3: repository error is returned wrapped and `errors.Is` matches the cause.
EOF
cat > "$C/docs/superpowers/plans/2026-09-01-XBI-100-orders-plan.md" <<'EOF'
# XBI-100 Order Placement Implementation Plan

- [x] Task 1: Write failing table test `TestPlaceOrder` (success, invalid qty, repo error)
- [x] Task 2: Implement `OrderService.PlaceOrder` and `ErrInvalidQty`
- [x] Task 3: Run `go test -race ./...`
EOF
commit_all "$C" "XBI-100 add order placement service"
echo "fixtures written to $OUT"
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash tests/test-fixtures.sh`
Expected: all pass. If the `env -C` line errors on macOS, replace it with the subshell-only form.

- [ ] **Step 5: Commit**

```bash
git add fixtures/make-fixtures.sh tests/test-fixtures.sh
git commit -m "Add dirty and clean Go fixture generator"
```

---

### Task 3: `collect.sh` — diff, changed packages, tool evidence

**Files:**
- Create: `skill/scripts/lib.sh`, `skill/scripts/collect.sh`, `skill/scripts/golangci-strict.yml`, `tests/test-collect.sh`

**Interfaces:**
- Produces `skill/scripts/lib.sh` functions: `die <msg>` (stderr + exit 1), `log <msg>` (stderr), `run_with_timeout <seconds> <outfile> <cmd...>` (runs cmd, stdout+stderr to outfile, echoes `OK`, `FAIL`, or `TIMEOUT`), `assert_outside <path> <root>` (dies if path is under root), `merge_base <repo> <base> <head>`, `resolve_base <repo>`.
- Produces `skill/scripts/collect.sh`:
  ```
  collect.sh --repo <path> --base <ref> --head <ref|WORKTREE> --out <dir> [--no-tools] [--full-tests]
  collect.sh --classify-only <go-test-output-file>
  ```
  Writes into `$OUT`: `meta.env`, `status-before.txt`, `stash-before.txt`, `diff.patch`, `changed-files.txt`, `changed-go-files.txt`, `changed-packages.txt`, `test-packages.txt`, `changed-symbols.txt`, `nontest-lines.txt` (single integer), `tools/{build,vet,lint,test,cover,vuln}.txt`, `tools/test-classified.txt`, `tools/summary.txt`. Exit 0 even when tools fail; exit 1 only on usage or environment errors.
- `meta.env` lines: `REPO=`, `BASE=`, `HEAD=`, `HEAD_SHA=`, `MERGE_BASE=`, `MODE=worktree|ref`, `MODULE=`.
- `tools/test-classified.txt` lines: `pkg<TAB>OK|FAIL|NOT_RUNNABLE|NO_TESTS`.

- [ ] **Step 1: Write `skill/scripts/lib.sh`**

```bash
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
```

- [ ] **Step 2: Write `skill/scripts/golangci-strict.yml`** (used only when the repo has no config)

```yaml
version: "2"
linters:
  default: none
  enable:
    - govet
    - staticcheck
    - errcheck
    - ineffassign
    - unused
    - gosec
    - errorlint
    - nilerr
    - bodyclose
    - noctx
    - contextcheck
    - rowserrcheck
    - sqlclosecheck
    - prealloc
    - unconvert
    - unparam
    - gocritic
    - revive
    - misspell
  settings:
    errcheck:
      check-type-assertions: true
      check-blank: true
    govet:
      enable-all: true
      disable:
        - fieldalignment
issues:
  max-issues-per-linter: 0
  max-same-issues: 0
```

- [ ] **Step 3: Write the failing test `tests/test-collect.sh`**

```bash
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
bash "$S/collect.sh" --repo "$fx/clean" --base main --head WORKTREE --out "$out/c" --no-tools
assert_contains "$(cat "$out/c/meta.env")" "MODE=worktree" "worktree mode"
assert_contains "$(cat "$out/c/changed-go-files.txt")" "cmd/api/main.go" "uncommitted change included"
assert_contains "$(cat "$out/c/tools/summary.txt")" "UNAVAILABLE(skipped)" "tools skipped"
git -C "$fx/clean" checkout -q -- cmd/api/main.go

# --- not-runnable classification ---
mkdir -p "$out/x"
printf -- '--- FAIL: TestDB (0.00s)\n    db_test.go:10: dial tcp 127.0.0.1:5432: connect: connection refused\nFAIL\nFAIL\texample.com/x/internal/db\t0.1s\nok\texample.com/x/internal/ok\t0.1s\n' > "$out/x/test.txt"
bash "$S/collect.sh" --classify-only "$out/x/test.txt" > "$out/x/classified.txt"
assert_contains "$(cat "$out/x/classified.txt")" $'example.com/x/internal/db\tNOT_RUNNABLE' "connection refused -> not runnable"
assert_contains "$(cat "$out/x/classified.txt")" $'example.com/x/internal/ok\tOK' "ok package"

# --- refuses to write inside repo ---
assert_exit 1 bash "$S/collect.sh" --repo "$fx/dirty" --base main --head WORKTREE --out "$fx/dirty/.review"
finish
```

- [ ] **Step 4: Run it to verify it fails**

Run: `bash tests/test-collect.sh`
Expected: fails, `collect.sh` missing.

- [ ] **Step 5: Write `skill/scripts/collect.sh`**

```bash
#!/usr/bin/env bash
# Collect diff, changed packages and tool evidence for go-review into an out dir.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
source "$HERE/lib.sh"

NOT_RUNNABLE_RE='connection refused|no such host|dial tcp|i/o timeout|connect: cannot|no route to host|environment variable .* not set|config file not found|open .*\.env: no such file'

# classify_tests TESTFILE -> lines "pkg<TAB>OK|FAIL|NOT_RUNNABLE|NO_TESTS"
classify_tests() {
  awk -v re="$NOT_RUNNABLE_RE" '
    { if ($0 ~ re) nr = 1 }
    /^ok[ \t]/   { print $2 "\tOK"; nr = 0 }
    /^FAIL[ \t]+[^ \t]+[ \t]/ { print $2 "\t" (nr ? "NOT_RUNNABLE" : "FAIL"); nr = 0 }
    /^\?[ \t]/   { print $2 "\tNO_TESTS"; nr = 0 }
  ' "$1"
}

if [[ "${1:-}" == "--classify-only" ]]; then classify_tests "$2"; exit 0; fi

REPO="" BASE="" HEAD="" OUT="" NO_TOOLS=0 FULL_TESTS=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) REPO=$2; shift 2 ;;
    --base) BASE=$2; shift 2 ;;
    --head) HEAD=$2; shift 2 ;;
    --out) OUT=$2; shift 2 ;;
    --no-tools) NO_TOOLS=1; shift ;;
    --full-tests) FULL_TESTS=1; shift ;;
    *) die "unknown arg: $1" ;;
  esac
done
[[ -n "$REPO" && -n "$OUT" && -n "$HEAD" ]] || die "usage: collect.sh --repo R --base B --head H|WORKTREE --out O [--no-tools] [--full-tests]"
REPO=$(cd "$REPO" && pwd -P)
[[ -n "$BASE" ]] || BASE=$(resolve_base "$REPO")
assert_outside "$OUT" "$REPO"
mkdir -p "$OUT/tools"
OUT=$(cd "$OUT" && pwd -P)

if [[ "$HEAD" == "WORKTREE" ]]; then MODE=worktree; HEAD_SHA=$(git -C "$REPO" rev-parse HEAD)
else MODE=ref; HEAD_SHA=$(git -C "$REPO" rev-parse "$HEAD"); fi
MB=$(merge_base "$REPO" "$BASE" "$HEAD_SHA")
MODULE=$(cd "$REPO" && go list -m 2>/dev/null | head -1)
{
  echo "REPO=$REPO"; echo "BASE=$BASE"; echo "HEAD=$HEAD"; echo "HEAD_SHA=$HEAD_SHA"
  echo "MERGE_BASE=$MB"; echo "MODE=$MODE"; echo "MODULE=$MODULE"
} > "$OUT/meta.env"
git -C "$REPO" status --porcelain > "$OUT/status-before.txt"
git -C "$REPO" stash list > "$OUT/stash-before.txt"

# --- diff ---
if [[ "$MODE" == "worktree" ]]; then
  git -C "$REPO" diff "$MB" > "$OUT/diff.patch"
  git -C "$REPO" ls-files --others --exclude-standard | while read -r f; do
    git -C "$REPO" diff --no-index -- /dev/null "$f" >> "$OUT/diff.patch" || true
  done
  { git -C "$REPO" diff --name-only "$MB"; git -C "$REPO" ls-files --others --exclude-standard; } | sort -u > "$OUT/changed-files.txt"
else
  git -C "$REPO" diff "$MB" "$HEAD_SHA" > "$OUT/diff.patch"
  git -C "$REPO" diff --name-only "$MB" "$HEAD_SHA" | sort -u > "$OUT/changed-files.txt"
fi
grep -E '\.go$' "$OUT/changed-files.txt" > "$OUT/changed-go-files.txt" || true
grep -E '^\+(func |type |var |const )' "$OUT/diff.patch" | sed 's/^+//' > "$OUT/changed-symbols.txt" || true

# non-test added+removed lines
awk '/^diff --git/ { intest = ($3 ~ /_test\.go$/) } /^[+-]/ && !/^(\+\+\+|---)/ { if (!intest) n++ } END { print n+0 }' "$OUT/diff.patch" > "$OUT/nontest-lines.txt"

# --- packages ---
: > "$OUT/changed-packages.txt"
if [[ -n "$MODULE" && -s "$OUT/changed-go-files.txt" ]]; then
  sed 's#/[^/]*$##' "$OUT/changed-go-files.txt" | sort -u | while read -r d; do
    [[ -d "$REPO/$d" ]] || continue
    (cd "$REPO" && go list "./$d" 2>/dev/null) || true
  done | sort -u > "$OUT/changed-packages.txt"
fi
if [[ $FULL_TESTS -eq 1 ]]; then
  echo "./..." > "$OUT/test-packages.txt"
elif [[ -s "$OUT/changed-packages.txt" ]]; then
  (cd "$REPO" && go list -f '{{.ImportPath}}{{range .Imports}} {{.}}{{end}}' ./... 2>/dev/null) > "$OUT/tools/import-graph.txt" || true
  {
    cat "$OUT/changed-packages.txt"
    while read -r p; do awk -v p="$p" '{ for (i = 2; i <= NF; i++) if ($i == p) print $1 }' "$OUT/tools/import-graph.txt"; done < "$OUT/changed-packages.txt"
  } | sort -u > "$OUT/test-packages.txt"
else
  : > "$OUT/test-packages.txt"
fi

# --- tools ---
summary() { printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$OUT/tools/summary.txt"; }
: > "$OUT/tools/summary.txt"
if [[ $NO_TOOLS -eq 1 ]]; then
  for t in build vet lint test vuln; do summary "$t" "UNAVAILABLE(skipped)" "--no-tools"; done
  exit 0
fi
[[ -n "$MODULE" ]] || { for t in build vet lint test vuln; do summary "$t" "UNAVAILABLE(no-module)" "no go.mod"; done; exit 0; }

cd "$REPO"
st=$(run_with_timeout 180 "$OUT/tools/build.txt" go build -o "$OUT/bin/" ./...)
if [[ $st == TIMEOUT ]]; then summary build "UNAVAILABLE(timeout)" "180s"; else summary build "$st" "$(grep -c . "$OUT/tools/build.txt" || true) lines"; fi

st=$(run_with_timeout 180 "$OUT/tools/vet.txt" go vet ./...)
if [[ $st == TIMEOUT ]]; then summary vet "UNAVAILABLE(timeout)" "180s"; else summary vet "$st" "$(grep -c . "$OUT/tools/vet.txt" || true) lines"; fi

if command -v golangci-lint >/dev/null; then
  cfg=()
  [[ -f .golangci.yml || -f .golangci.yaml || -f .golangci.toml || -f .golangci.json ]] || cfg=(-c "$HERE/golangci-strict.yml")
  st=$(run_with_timeout 300 "$OUT/tools/lint.txt" golangci-lint run "${cfg[@]}" --new-from-rev "$MB" ./...)
  n=$(grep -cE '^[^ ]+\.go:[0-9]+:[0-9]+:' "$OUT/tools/lint.txt" || true)
  case $st in TIMEOUT) summary lint "UNAVAILABLE(timeout)" "300s" ;; OK) summary lint OK "0 new" ;; *) summary lint FAIL "$n new" ;; esac
else
  summary lint "UNAVAILABLE(missing)" "brew install golangci-lint"
fi

if [[ -s "$OUT/test-packages.txt" ]]; then
  # shellcheck disable=SC2046
  st=$(run_with_timeout 600 "$OUT/tools/test.txt" go test -short -race -count=1 -coverprofile="$OUT/tools/cover.out" $(cat "$OUT/test-packages.txt"))
  classify_tests "$OUT/tools/test.txt" > "$OUT/tools/test-classified.txt"
  if [[ -f "$OUT/tools/cover.out" ]]; then go tool cover -func="$OUT/tools/cover.out" > "$OUT/tools/cover.txt" 2>/dev/null || true; fi
  nf=$(grep -c $'\tFAIL$' "$OUT/tools/test-classified.txt" || true)
  nn=$(grep -c $'\tNOT_RUNNABLE$' "$OUT/tools/test-classified.txt" || true)
  if [[ $st == TIMEOUT ]]; then summary test "UNAVAILABLE(timeout)" "600s"
  elif [[ $nf -gt 0 ]]; then summary test FAIL "$nf failing, $nn not runnable locally"
  else summary test OK "$nn not runnable locally"; fi
else
  summary test "UNAVAILABLE(no-changed-packages)" ""
fi

if command -v govulncheck >/dev/null; then
  st=$(run_with_timeout 180 "$OUT/tools/vuln.txt" govulncheck ./...)
  if [[ $st == TIMEOUT ]]; then summary vuln "UNAVAILABLE(timeout)" "180s"; else summary vuln "$st" "$(grep -c 'Vulnerability #' "$OUT/tools/vuln.txt" || true) found"; fi
else
  summary vuln "UNAVAILABLE(missing)" "go install golang.org/x/vuln/cmd/govulncheck@latest"
fi
```

- [ ] **Step 6: Run the test to verify it passes**

Run: `bash tests/test-collect.sh`
Expected: all pass. The dirty run takes ~20s because of `-race`. If `test\tFAIL` is not found, inspect `$out/d/tools/test.txt`; the race must be reported by `go test -race` on the counter package.

- [ ] **Step 7: Commit**

```bash
git add skill/scripts/lib.sh skill/scripts/collect.sh skill/scripts/golangci-strict.yml tests/test-collect.sh
git commit -m "Add collect.sh for diff and tool evidence"
```

---

### Task 4: `assert-clean.sh` — no-artifact verification

**Files:**
- Create: `skill/scripts/assert-clean.sh`, `tests/test-assert-clean.sh`

**Interfaces:**
- Produces `assert-clean.sh --repo <path> --out <dir> [--worktree <path>]`: removes `--worktree` if given (`git worktree remove --force` + `prune`), compares current `git status --porcelain` and `git stash list` with `$OUT/status-before.txt` and `$OUT/stash-before.txt`, prints `No artifacts left: verified` and exits 0, or prints the differing lines and exits 2. It never deletes `$OUT` (the orchestrator does that last).

- [ ] **Step 1: Write the failing test `tests/test-assert-clean.sh`**

```bash
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
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash tests/test-assert-clean.sh` — expected FAIL (script missing).

- [ ] **Step 3: Write `skill/scripts/assert-clean.sh`**

```bash
#!/usr/bin/env bash
# Verify the reviewed repo is unchanged after a go-review run.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
REPO="" OUT="" WT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) REPO=$2; shift 2 ;; --out) OUT=$2; shift 2 ;; --worktree) WT=$2; shift 2 ;;
    *) die "unknown arg: $1" ;;
  esac
done
[[ -n "$REPO" && -n "$OUT" ]] || die "usage: assert-clean.sh --repo R --out O [--worktree W]"
if [[ -n "$WT" && -d "$WT" ]]; then
  git -C "$REPO" worktree remove --force "$WT" || rm -rf "$WT"
  git -C "$REPO" worktree prune
fi
rc=0
diff "$OUT/status-before.txt" <(git -C "$REPO" status --porcelain) > "$OUT/status-diff.txt" || rc=2
diff "$OUT/stash-before.txt" <(git -C "$REPO" stash list) > "$OUT/stash-diff.txt" || rc=2
if [[ $rc -eq 0 ]]; then echo "No artifacts left: verified"; exit 0; fi
echo "ARTIFACTS LEFT IN REPO (bug in go-review, please report):" >&2
cat "$OUT/status-diff.txt" "$OUT/stash-diff.txt" >&2
exit 2
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash tests/test-assert-clean.sh` — expected all pass.

- [ ] **Step 5: Commit**

```bash
git add skill/scripts/assert-clean.sh tests/test-assert-clean.sh
git commit -m "Add assert-clean.sh no-artifact check"
```

---

### Task 5: `find-specs.sh` — spec/plan candidate discovery

**Files:**
- Create: `skill/scripts/find-specs.sh`, `tests/test-find-specs.sh`

**Interfaces:**
- Produces:
  ```
  find-specs.sh --repo <path> --out <dir> [--base <ref>] [--head <ref|WORKTREE>] [--branch <name>] [--title <text>] [--spec <path>]
  ```
  Writes `$OUT/specs.tsv` (`path<TAB>convention<TAB>signals`, sorted by signal count desc, only candidates with at least one signal) and `$OUT/specs-all.txt` (every candidate path, one per line). Reads `$OUT/changed-packages.txt` if present for `package:` signals. `--spec` writes a single `forced` row. Exit 0 always except usage errors.
- Ticket key regex: `[A-Z][A-Z0-9]+-[0-9]+`. Branch tokens: split on `/`, `-`, `_`, drop tokens shorter than 4 chars, drop `feature|fix|hotfix|bugfix|release|chore`.

- [ ] **Step 1: Write the failing test `tests/test-find-specs.sh`**

```bash
#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
S="$REPO_ROOT/skill/scripts"
fx=$(tmpdir); bash "$REPO_ROOT/fixtures/make-fixtures.sh" "$fx" >/dev/null
out=$(tmpdir)

# clean: superpowers spec + plan matched by ticket and git-log
mkdir -p "$out/c"; echo "example.com/clean/internal/service" > "$out/c/changed-packages.txt"
bash "$S/find-specs.sh" --repo "$fx/clean" --out "$out/c" --base main --head feature/XBI-100-orders --branch feature/XBI-100-orders
t=$(cat "$out/c/specs.tsv")
assert_contains "$t" $'docs/superpowers/specs/2026-09-01-XBI-100-orders-design.md\tsuperpowers\t' "spec found"
assert_contains "$t" $'docs/superpowers/plans/2026-09-01-XBI-100-orders-plan.md\tsuperpowers\t' "plan found"
assert_contains "$t" "ticket:XBI-100" "ticket signal"
assert_contains "$t" "git-log" "git-log signal"
assert_contains "$t" "package:service" "package signal"

# dirty: nothing
mkdir -p "$out/d"
bash "$S/find-specs.sh" --repo "$fx/dirty" --out "$out/d" --base main --head feature/XBI-100-orders --branch feature/XBI-100-orders
assert_eq "" "$(cat "$out/d/specs.tsv")" "no candidates in dirty"
assert_eq "" "$(cat "$out/d/specs-all.txt")" "no all-candidates in dirty"

# openspec + docs conventions, unmatched candidate still listed in specs-all
mkdir -p "$fx/dirty/openspec/changes/add-orders/specs/orders" "$fx/dirty/docs/adr"
echo "# Proposal: XBI-100 orders" > "$fx/dirty/openspec/changes/add-orders/proposal.md"
echo "# Tasks" > "$fx/dirty/openspec/changes/add-orders/tasks.md"
echo "# orders spec" > "$fx/dirty/openspec/changes/add-orders/specs/orders/spec.md"
echo "# Unrelated ADR" > "$fx/dirty/docs/adr/001-logging.md"
echo "# readme" > "$fx/dirty/docs/README.md"
mkdir -p "$out/o"
bash "$S/find-specs.sh" --repo "$fx/dirty" --out "$out/o" --base main --head WORKTREE --branch feature/XBI-100-orders --title "XBI-100 order listing"
t=$(cat "$out/o/specs.tsv")
assert_contains "$t" $'openspec/changes/add-orders/proposal.md\topenspec\t' "openspec proposal matched"
assert_contains "$t" "title:order" "title signal"
assert_not_contains "$t" "docs/adr/001-logging.md" "unrelated adr not matched"
assert_contains "$(cat "$out/o/specs-all.txt")" "docs/adr/001-logging.md" "unrelated adr listed in all"
assert_not_contains "$(cat "$out/o/specs-all.txt")" "docs/README.md" "README excluded"
rm -rf "$fx/dirty/openspec" "$fx/dirty/docs"

# forced
mkdir -p "$out/f"
bash "$S/find-specs.sh" --repo "$fx/clean" --out "$out/f" --spec docs/superpowers/specs/2026-09-01-XBI-100-orders-design.md
assert_eq $'docs/superpowers/specs/2026-09-01-XBI-100-orders-design.md\tforced\tforced' "$(cat "$out/f/specs.tsv")" "forced row"
finish
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash tests/test-find-specs.sh` — expected FAIL (script missing).

- [ ] **Step 3: Write `skill/scripts/find-specs.sh`**

```bash
#!/usr/bin/env bash
# List spec/plan candidates for a change under the three supported conventions.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

REPO="" OUT="" BASE="" HEAD="" BRANCH="" TITLE="" SPEC=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) REPO=$2; shift 2 ;; --out) OUT=$2; shift 2 ;; --base) BASE=$2; shift 2 ;;
    --head) HEAD=$2; shift 2 ;; --branch) BRANCH=$2; shift 2 ;; --title) TITLE=$2; shift 2 ;;
    --spec) SPEC=$2; shift 2 ;; *) die "unknown arg: $1" ;;
  esac
done
[[ -n "$REPO" && -n "$OUT" ]] || die "usage: find-specs.sh --repo R --out O [--base B] [--head H] [--branch N] [--title T] [--spec P]"
REPO=$(cd "$REPO" && pwd -P); assert_outside "$OUT" "$REPO"; mkdir -p "$OUT"

if [[ -n "$SPEC" ]]; then
  printf '%s\tforced\tforced\n' "$SPEC" > "$OUT/specs.tsv"; printf '%s\n' "$SPEC" > "$OUT/specs-all.txt"; exit 0
fi

# --- candidates: path<TAB>convention ---
cands=$(
  cd "$REPO"
  [[ -d docs/superpowers ]] && find docs/superpowers/specs docs/superpowers/plans -name '*.md' 2>/dev/null | sed 's/$/\tsuperpowers/'
  [[ -d openspec ]] && find openspec -name '*.md' 2>/dev/null | sed 's/$/\topenspec/'
  [[ -d docs ]] && find docs -name '*.md' -not -path 'docs/superpowers/*' 2>/dev/null | grep -viE '(^|/)readme\.md$' | sed 's/$/\tdocs/'
  true
) || true
printf '%s\n' "$cands" | awk -F'\t' 'NF { print $1 }' | sort -u > "$OUT/specs-all.txt"

# --- signals ---
tickets=$(printf '%s\n%s\n' "$BRANCH" "$TITLE" | grep -oE '[A-Z][A-Z0-9]+-[0-9]+' | sort -u || true)
btoks=$(printf '%s\n' "$BRANCH" | tr '/_-' '\n\n\n' | grep -vE '^(feature|fix|hotfix|bugfix|release|chore)$' | awk 'length($0) >= 4' | tr 'A-Z' 'a-z' | sort -u || true)
ttoks=$(printf '%s\n' "$TITLE" | tr -c 'A-Za-z0-9\n' '\n' | awk 'length($0) >= 4' | tr 'A-Z' 'a-z' | grep -vE '^(with|from|that|this|into|when|then|the|and|for)$' | sort -u || true)
pkgs=""
[[ -f "$OUT/changed-packages.txt" ]] && pkgs=$(sed 's#.*/##' "$OUT/changed-packages.txt" | sort -u)
logged=""
if [[ -n "$BASE" ]]; then
  h=HEAD; [[ -n "$HEAD" && "$HEAD" != "WORKTREE" ]] && h=$HEAD
  logged=$( { git -C "$REPO" log --name-only --format= "$BASE..$h" -- docs openspec 2>/dev/null; [[ "$HEAD" == "WORKTREE" ]] && git -C "$REPO" status --porcelain -- docs openspec | awk '{ print $2 }'; } | sort -u || true)
fi

: > "$OUT/specs.tsv.unsorted"
printf '%s\n' "$cands" | awk -F'\t' 'NF' | while IFS=$'\t' read -r path conv; do
  sig=""
  body=$(tr 'A-Z' 'a-z' < "$REPO/$path" 2>/dev/null || true)
  lpath=$(printf '%s' "$path" | tr 'A-Z' 'a-z')
  for k in $tickets; do lk=$(printf '%s' "$k" | tr 'A-Z' 'a-z'); [[ "$lpath" == *"$lk"* || "$body" == *"$lk"* ]] && sig="$sig,ticket:$k"; done
  for k in $btoks; do [[ "$lpath" == *"$k"* ]] && sig="$sig,branch:$k"; done
  for k in $ttoks; do [[ "$lpath" == *"$k"* ]] && sig="$sig,title:$k"; done
  for k in $pkgs; do [[ "$body" == *"$k"* ]] && sig="$sig,package:$k"; done
  printf '%s\n' "$logged" | grep -qxF "$path" && sig="$sig,git-log"
  [[ -n "$sig" ]] && printf '%s\t%s\t%s\n' "$path" "$conv" "${sig#,}" >> "$OUT/specs.tsv.unsorted"
done
awk -F'\t' '{ n = split($3, a, ","); print n "\t" $0 }' "$OUT/specs.tsv.unsorted" | sort -t$'\t' -k1,1nr -k2,2 | cut -f2- > "$OUT/specs.tsv"
rm -f "$OUT/specs.tsv.unsorted"
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash tests/test-find-specs.sh` — expected all pass. If `package:service` is missing, confirm the clean spec body mentions "service" (it does, in the Goal line).

- [ ] **Step 5: Commit**

```bash
git add skill/scripts/find-specs.sh tests/test-find-specs.sh
git commit -m "Add find-specs.sh spec candidate discovery"
```

---

### Task 6: `gitlab-post.sh` — MR summary note + inline discussions

**Files:**
- Create: `skill/scripts/gitlab-post.sh`, `tests/test-gitlab-post.sh`

**Interfaces:**
- Produces:
  ```
  gitlab-post.sh --project <path|id> --mr <iid> --head-sha <sha> --findings <findings.json> --summary <summary.md> [--dry-run]
  ```
  Requires `glab` and `jq`. Fetches `diff_refs` and the changed paths of the MR via `glab api`, checks existing notes for the marker `<!-- go-review:<head-sha> -->` (if found: prints `already posted for <sha>` and exits 0 without posting), posts one summary note (marker + summary.md), then one inline discussion per finding whose `file` is in the MR changes (position: `text`, `new_path`, `new_line`, `base_sha`, `start_sha`, `head_sha`). Findings whose file is not in the MR are appended to the summary under `Outside the diff`. `--dry-run` prints each `glab api` invocation as `DRY: <method> <endpoint> <json body>` instead of calling. Project path must be URL-encoded (`/` -> `%2F`).
- Tests use a fake `glab` on `PATH` that records calls and serves canned responses.

- [ ] **Step 1: Write the failing test `tests/test-gitlab-post.sh`**

```bash
#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
S="$REPO_ROOT/skill/scripts"
w=$(tmpdir)

# fake glab: GET mr -> diff_refs; GET changes -> paths; GET notes -> canned; POST -> record
mkdir -p "$w/bin"
cat > "$w/bin/glab" <<'EOF'
#!/usr/bin/env bash
log=${FAKE_GLAB_LOG:?}
echo "$*" >> "$log"
if [[ "$1" != "api" ]]; then exit 1; fi
shift
method=GET; ep=""
while [[ $# -gt 0 ]]; do case "$1" in --method|-X) method=$2; shift 2;; -f|--field|--raw-field) shift 2;; --input) shift 2;; *) ep=$1; shift;; esac; done
case "$method $ep" in
  "GET projects/"*"/merge_requests/7") echo '{"iid":7,"sha":"h1","diff_refs":{"base_sha":"b1","start_sha":"s1","head_sha":"h1"}}' ;;
  "GET projects/"*"/merge_requests/7/changes") echo '{"changes":[{"new_path":"internal/service/order.go"},{"new_path":"go.mod"}]}' ;;
  "GET projects/"*"/merge_requests/7/notes"*) cat "${FAKE_GLAB_NOTES:-/dev/null}"; [[ -f "${FAKE_GLAB_NOTES:-}" ]] || echo '[]' ;;
  "POST "*) echo '{"id":1}' ;;
  *) echo "unexpected: $method $ep" >&2; exit 1 ;;
esac
EOF
chmod +x "$w/bin/glab"
export PATH="$w/bin:$PATH" FAKE_GLAB_LOG="$w/calls.log"

cat > "$w/findings.json" <<'EOF'
[
 {"id":"B1","dimension":"correctness","severity":"BLOCKER","rule_based":false,"file":"internal/service/order.go","line":24,"title":"Error swallowed","evidence":"return nil, nil","why":"caller cannot distinguish failure","fix":"return the wrapped error","spec_ref":"","score":95},
 {"id":"M1","dimension":"sdd-tdd","severity":"MAJOR","rule_based":true,"file":"docs/missing.md","line":0,"title":"No plan","evidence":"","why":"substantive change without plan","fix":"add docs/superpowers/plans/...","spec_ref":"","score":100}
]
EOF
printf 'Verdict: REQUEST CHANGES\n' > "$w/summary.md"

# dry run prints calls, posts nothing
out=$(bash "$S/gitlab-post.sh" --project group/repo --mr 7 --head-sha h1 --findings "$w/findings.json" --summary "$w/summary.md" --dry-run)
assert_contains "$out" "DRY: POST projects/group%2Frepo/merge_requests/7/notes" "summary note dry"
assert_contains "$out" "go-review:h1" "marker in summary"
assert_contains "$out" "DRY: POST projects/group%2Frepo/merge_requests/7/discussions" "discussion dry"
assert_contains "$out" '"new_line":24' "inline position line"
assert_contains "$out" '"base_sha":"b1"' "position base sha"
assert_contains "$out" "Outside the diff" "non-diff finding folded into summary"
assert_eq "0" "$(grep -c '^api --method POST' "$w/calls.log" || true)" "no real POST in dry run"

# real (fake) post: 1 note + 1 discussion
: > "$w/calls.log"
bash "$S/gitlab-post.sh" --project group/repo --mr 7 --head-sha h1 --findings "$w/findings.json" --summary "$w/summary.md" >/dev/null
assert_eq "1" "$(grep -c 'merge_requests/7/notes' <(grep POST "$w/calls.log") || true)" "one summary note"
assert_eq "1" "$(grep -c 'merge_requests/7/discussions' <(grep POST "$w/calls.log") || true)" "one discussion"

# idempotent
echo '[{"id":9,"body":"<!-- go-review:h1 -->\nold"}]' > "$w/notes.json"
: > "$w/calls.log"
out=$(FAKE_GLAB_NOTES="$w/notes.json" bash "$S/gitlab-post.sh" --project group/repo --mr 7 --head-sha h1 --findings "$w/findings.json" --summary "$w/summary.md")
assert_contains "$out" "already posted for h1" "skips when marker exists"
assert_eq "0" "$(grep -c POST "$w/calls.log" || true)" "no POST when already posted"
finish
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash tests/test-gitlab-post.sh` — expected FAIL (script missing).

- [ ] **Step 3: Write `skill/scripts/gitlab-post.sh`**

```bash
#!/usr/bin/env bash
# Post go-review findings to a GitLab MR as one summary note + inline discussions.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
command -v glab >/dev/null || die "glab not found: brew install glab && glab auth login --hostname <your-gitlab-host>"
command -v jq >/dev/null || die "jq not found"

PROJECT="" MR="" SHA="" FINDINGS="" SUMMARY="" DRY=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --project) PROJECT=$2; shift 2 ;; --mr) MR=$2; shift 2 ;; --head-sha) SHA=$2; shift 2 ;;
    --findings) FINDINGS=$2; shift 2 ;; --summary) SUMMARY=$2; shift 2 ;; --dry-run) DRY=1; shift ;;
    *) die "unknown arg: $1" ;;
  esac
done
[[ -n "$PROJECT" && -n "$MR" && -n "$SHA" && -f "$FINDINGS" && -f "$SUMMARY" ]] || die "usage: gitlab-post.sh --project P --mr IID --head-sha SHA --findings F.json --summary S.md [--dry-run]"
PROJ=$(printf '%s' "$PROJECT" | sed 's#/#%2F#g')
MARKER="<!-- go-review:$SHA -->"
BASE_EP="projects/$PROJ/merge_requests/$MR"

api_get() { glab api "$1"; }
api_post() { # endpoint json
  if [[ $DRY -eq 1 ]]; then printf 'DRY: POST %s %s\n' "$1" "$2"; else printf '%s' "$2" | glab api --method POST --input - "$1" >/dev/null; fi
}

# idempotency
if api_get "$BASE_EP/notes?per_page=100" | jq -e --arg m "$MARKER" 'map(select(.body | contains($m))) | length > 0' >/dev/null; then
  echo "already posted for $SHA"; exit 0
fi

refs=$(api_get "$BASE_EP")
base_sha=$(jq -r .diff_refs.base_sha <<<"$refs"); start_sha=$(jq -r .diff_refs.start_sha <<<"$refs"); head_sha=$(jq -r .diff_refs.head_sha <<<"$refs")
paths=$(api_get "$BASE_EP/changes" | jq -r '.changes[].new_path')

inside=$(jq -c --argjson p "$(printf '%s\n' "$paths" | jq -R . | jq -s .)" '[.[] | select(.file as $f | $p | index($f))]' "$FINDINGS")
outside=$(jq -c --argjson p "$(printf '%s\n' "$paths" | jq -R . | jq -s .)" '[.[] | select(.file as $f | ($p | index($f)) | not)]' "$FINDINGS")

body=$(printf '%s\n\n%s' "$MARKER" "$(cat "$SUMMARY")")
if [[ "$(jq length <<<"$outside")" -gt 0 ]]; then
  body="$body"$'\n\n### Outside the diff\n'"$(jq -r '.[] | "- **\(.severity) \(.id)** \(.title) — `\(.file)`: \(.why) Fix: \(.fix)"' <<<"$outside")"
fi
api_post "$BASE_EP/notes" "$(jq -n --arg b "$body" '{body: $b}')"

jq -c '.[]' <<<"$inside" | while read -r f; do
  note=$(jq -r '"**\(.severity) \(.id): \(.title)**\n\nEvidence: `\(.evidence)`\n\nWhy: \(.why)\n\nFix: \(.fix)" + (if .spec_ref != "" then "\n\nSpec: \(.spec_ref)" else "" end)' <<<"$f")
  payload=$(jq -n --arg b "$note" --arg p "$(jq -r .file <<<"$f")" --argjson l "$(jq -r .line <<<"$f")" \
    --arg bs "$base_sha" --arg ss "$start_sha" --arg hs "$head_sha" \
    '{body: $b, position: {position_type: "text", new_path: $p, new_line: $l, base_sha: $bs, start_sha: $ss, head_sha: $hs}}')
  api_post "$BASE_EP/discussions" "$payload"
done
echo "posted summary + $(jq length <<<"$inside") inline discussions for $SHA"
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash tests/test-gitlab-post.sh` — expected all pass. If the fake `glab` receives `--input -` and chokes, confirm its arg parser skips `--input <value>` (it does).

- [ ] **Step 5: Commit**

```bash
git add skill/scripts/gitlab-post.sh tests/test-gitlab-post.sh
git commit -m "Add gitlab-post.sh for MR comments"
```

---

### Task 7: References — `tooling.md` and `gitlab.md`

**Files:**
- Create: `skill/references/tooling.md`, `skill/references/gitlab.md`

**Interfaces:**
- Consumes: script CLIs from Tasks 3-6.
- Produces: the two documents the orchestrator reads when running scripts and talking to GitLab. Headings referenced by `workflow.md` (Task 13): `## Commands`, `## Reading the outputs`, `## Never run` in tooling.md; `## Resolve an MR target`, `## Posting` in gitlab.md.

- [ ] **Step 1: Write `skill/references/tooling.md`**

```markdown
# Tooling: collecting evidence without touching the repo

All scripts live in `scripts/` next to this file. `$SKILL` below means the
directory containing `SKILL.md`. `$WORK` is a directory created with
`mktemp -d`; it must be outside the reviewed repo.

## Commands

Local diff (working tree + branch vs base):

    bash "$SKILL/scripts/collect.sh" --repo "$REPO" --head WORKTREE --out "$WORK" [--base <ref>] [--no-tools] [--full-tests]

Branch or MR head already checked out in `$REPO` (or in a temp worktree):

    bash "$SKILL/scripts/collect.sh" --repo "$REPO" --head <ref-or-sha> --out "$WORK" [--base <ref>] [--no-tools] [--full-tests]

Spec candidates (run after collect so `changed-packages.txt` exists):

    bash "$SKILL/scripts/find-specs.sh" --repo "$REPO" --out "$WORK" --base <ref> --head <ref|WORKTREE> --branch "<branch>" --title "<mr title or empty>" [--spec <path>]

Final no-artifact check (always run, even after errors):

    bash "$SKILL/scripts/assert-clean.sh" --repo "$REPO" --out "$WORK" [--worktree "$WORK/wt"]
    rm -rf "$WORK"

## Reading the outputs

| File | Meaning |
|---|---|
| `meta.env` | `REPO, BASE, HEAD, HEAD_SHA, MERGE_BASE, MODE, MODULE` |
| `diff.patch` | unified diff; the review scope |
| `changed-files.txt`, `changed-go-files.txt` | paths relative to repo |
| `changed-packages.txt` | import paths of changed packages |
| `test-packages.txt` | packages tested (changed + direct importers, or `./...`) |
| `changed-symbols.txt` | added/changed `func`, `type`, `var`, `const` lines |
| `nontest-lines.txt` | added+removed non-test lines; > 50 means substantive |
| `tools/summary.txt` | `name<TAB>OK|FAIL|UNAVAILABLE(reason)<TAB>detail` |
| `tools/build.txt`, `tools/vet.txt` | compiler / vet output |
| `tools/lint.txt` | golangci-lint, only issues new since merge-base |
| `tools/test.txt` | `go test -short -race` output |
| `tools/test-classified.txt` | `pkg<TAB>OK|FAIL|NOT_RUNNABLE|NO_TESTS` |
| `tools/cover.txt` | `go tool cover -func` per function |
| `tools/vuln.txt` | govulncheck output |
| `specs.tsv` | matched spec/plan candidates, best first |
| `specs-all.txt` | every candidate, for the "nearest candidates" hint |

Interpretation rules:

- `FAIL` in build, vet, or test (with at least one `FAIL` package in
  `test-classified.txt`) is a BLOCKER finding of dimension `tools`, rule-based.
  Quote the first failing line as evidence.
- `NOT_RUNNABLE` packages are reported in the header line only ("3 not runnable
  locally") and never affect the verdict.
- `UNAVAILABLE(...)` is reported in the header line; agents must then not
  assume the linter caught anything, so linter-territory issues become fair
  game for the correctness agent.
- `lint FAIL` with N new issues: each issue is evidence, not a finding of its
  own; the correctness or security agent cites it when it supports a finding.
  Do not restate lint output as findings.
- `vuln FAIL`: each reachable vulnerability is a BLOCKER finding of dimension
  `security`, rule-based, quoting the OSV id and the call stack line.

## Never run

Inside the reviewed repo the orchestrator and every agent must never run:
`go mod tidy`, `go mod vendor`, `go generate`, `go get`, `gofmt -w`,
`goimports -w`, `golangci-lint run --fix`, `git stash`, `git checkout` of
files, `git add`, or any command with a redirect into the repo. If a tool
is missing, print the install hint from `tools/summary.txt` and continue.

## Timeouts

build 180s, vet 180s, lint 300s, test 600s, vuln 180s. A timeout produces
`UNAVAILABLE(timeout)`, never `FAIL`. Suggest `--no-tools` or `--full-tests`
adjustments in the report when a timeout hides evidence.
```

- [ ] **Step 2: Write `skill/references/gitlab.md`**

```markdown
# GitLab merge requests

Requires `glab` authenticated against the self-hosted instance:

    brew install glab
    glab auth login --hostname <gitlab-host>

Run all `glab` commands with `-R <group/repo>` or from inside the repo so the
remote is resolved automatically.

## Resolve an MR target

Accepted forms: `!123`, `123`, or a full MR URL. Extract the iid, then:

    glab mr view <iid> --output json > "$WORK/mr.json"

Fields to read with `jq`: `.iid`, `.title`, `.description`,
`.source_branch`, `.target_branch`, `.sha` (head), `.diff_refs`,
`.state` (skip review if `merged` or `closed`, say so), `.draft`.
Project path for the API: `glab repo view --output json | jq -r .path_with_namespace`.

Check out the head without touching the user's branch:

    git -C "$REPO" fetch origin "$SOURCE_BRANCH"
    git -C "$REPO" worktree add --detach "$WORK/wt" "$HEAD_SHA"

Then run `collect.sh --repo "$WORK/wt" --head "$HEAD_SHA" --base "origin/$TARGET_BRANCH"`.
If the local branch has the same name as the source branch but a different
sha, warn in the report header: "local <branch> is at <sha>, reviewed MR head
<sha>". The worktree is removed by `assert-clean.sh --worktree "$WORK/wt"`
run against the original `$REPO`.

## Posting

Only with `--comment`, and only after showing the user the summary that will
be posted and receiving an explicit yes.

    bash "$SKILL/scripts/gitlab-post.sh" --project <group/repo> --mr <iid> --head-sha <sha> \
      --findings "$WORK/findings.json" --summary "$WORK/summary.md" [--dry-run]

Behavior: one summary note carrying the marker `<!-- go-review:<sha> -->`,
then one inline discussion per finding whose file is in the MR diff. Findings
outside the diff are folded into the summary. A rerun on the same head sha
prints `already posted` and posts nothing. Use `--dry-run` to preview the
API calls.

`findings.json` is the verified findings array (schema in
`severity-verdict.md`). `summary.md` is the Markdown version of the terminal
report without the per-finding bodies that become inline discussions.
```

- [ ] **Step 3: Verify the headings the workflow will link to exist**

Run: `grep -c '^## Commands\|^## Reading the outputs\|^## Never run' skill/references/tooling.md; grep -c '^## Resolve an MR target\|^## Posting' skill/references/gitlab.md`
Expected: `3` and `2`.

- [ ] **Step 4: Commit**

```bash
git add skill/references/tooling.md skill/references/gitlab.md
git commit -m "Add tooling and gitlab references"
```

---

### Task 8: References — `severity-verdict.md` and `report-format.md`

**Files:**
- Create: `skill/references/severity-verdict.md`, `skill/references/report-format.md`

**Interfaces:**
- Produces: the finding schema, the 0-100 rubric, severity mapping, verdict rules, and the exact report and summary templates. `workflow.md` and every agent link here. Headings: `## Finding schema`, `## Severity`, `## Verifier rubric`, `## Verdict`, `## Noise rules` in severity-verdict.md; `## Terminal report`, `## MR summary` in report-format.md.

- [ ] **Step 1: Write `skill/references/severity-verdict.md`**

```markdown
# Severity, verification, and verdict

## Finding schema

Every agent returns a JSON array. Every object has exactly these keys:

    id           "" (assigned by the orchestrator after verification)
    dimension    correctness | security | architecture | performance | sdd-tdd | tools
    severity     BLOCKER | MAJOR | MINOR
    rule_based   true when the finding comes from a rule table (SDD/TDD, tool failure, CVE); false for judgment findings
    file         path relative to the repo root
    line         integer line in the new file (0 when not applicable)
    title        one line, <= 80 chars, states the defect, not the advice
    evidence     quoted code or tool output line, verbatim, <= 3 lines
    why          what breaks, when, and for whom; 1-2 sentences
    fix          the change to make; 1-2 sentences, a <= 6 line Go snippet allowed
    spec_ref     "path#heading" or ""
    score        0-100 (agent's own confidence; the verifier overwrites it)

## Severity

BLOCKER
- Bug on a reachable path: wrong result, panic, nil dereference, off-by-one on money/qty, lost update.
- Data loss or corruption: partial writes without a transaction, migration that drops or mis-types data.
- Security vulnerability: injection, missing authn/authz check, secret in code or logs, broken crypto, SSRF, path traversal.
- Concurrency: data race, deadlock, goroutine leak, unbounded goroutine spawn, channel that can block forever.
- Tooling: build/vet failure, failing test, `-race` report, reachable CVE.
- SDD/TDD blockers from `checklist-sdd-tdd.md`.

MAJOR
- Bug that needs a specific condition: retry without idempotency, timeout missing on an outbound call, context not propagated or cancellation ignored, error wrapped without context or swallowed on a non-critical path.
- Architecture: layer breach, wrong dependency direction, interface defined on the wrong side, transaction boundary in the wrong layer.
- Performance under production load: N+1, unbounded query, allocation in a hot loop, lock held across I/O.
- SDD/TDD majors from `checklist-sdd-tdd.md`.

MINOR
- Idiom and naming, missing doc comment on exported identifiers, small inefficiencies, log message quality.

## Verifier rubric

Score each non-rule finding 0-100 after re-reading the code at `file:line` and its callers:

- 0    Not a defect, pre-existing on unchanged lines, or the code handles it elsewhere.
- 25   Might be real; could not confirm the path is reachable or the input is possible.
- 50   Confirmed real but rarely hit in practice, or a nitpick relative to the rest of the change.
- 75   Confirmed real, reachable, and matters; the change as written is insufficient.
- 100  Confirmed by direct evidence (tool output, a test, or an unambiguous code path) and will happen in normal operation.

Thresholds: >= 80 report; 60-79 "Needs human judgment"; < 60 drop.

Rule-based findings are not scored. The verifier only checks the fact
(spec really absent, section really missing, test really absent, tool really
failed). If the fact is wrong, drop the finding; otherwise keep the severity
from the rule table and set score to 100.

Dedup: two findings on the same file and line (or the same defect described
twice) merge into one, keeping the higher severity and the better evidence.

## Verdict

- Any BLOCKER, or 3 or more MAJOR: REQUEST CHANGES
- Otherwise, any MAJOR or MINOR remaining: APPROVE WITH COMMENTS
- Otherwise: APPROVE

Findings in "Needs human judgment", "Pre-existing", and NOT_RUNNABLE test
packages never affect the verdict.

## Noise rules

Do not report:
- Anything the compiler, vet, or the linter already reported (check `tools/lint.txt`) unless lint was UNAVAILABLE.
- Pre-existing issues on unchanged lines. Put at most 5 of them under "Pre-existing".
- Style the project's own linter config silences.
- Intentional behavior the spec or MR description explains.
- Nitpicks a senior engineer would not raise in a review.
- Missing features outside the stated scope.
```

- [ ] **Step 2: Write `skill/references/report-format.md`**

````markdown
# Report format (English)

## Terminal report

Print exactly this structure. Omit a severity section when it has no
findings. Keep each finding under 12 lines.

```
go-review — <repo-name> <target> vs <base> @ <short-sha>
Tools: build OK | vet OK | lint 0 new | test 42 pass, 3 not runnable locally | race OK | vuln none
Verdict: REQUEST CHANGES (2 blockers, 1 major)

BLOCKER
[B1] <title> — <file>:<line>
  Evidence: <verbatim>
  Why: <why>
  Fix: <fix>
  Spec: <spec_ref>                      (only when non-empty)

MAJOR
[M1] ...

MINOR
[N1] ...

SDD/TDD
  Change: substantive (<nontest-lines> non-test lines; new handler List)   | trivial (reason)
  Spec: <path> (matched by ticket:XBI-100, git-log)                        | none found (nearest: <path>, <path>)
  Plan: <path>                                                             | none
  Spec rubric: 8/10 (missing: risks/rollback, acceptance criteria)
  Requirement -> test
    AC1 valid order returned          -> TestPlaceOrder/success (internal/service/order_test.go:18)
    AC2 qty 0 -> ErrInvalidQty        -> TestPlaceOrder/invalid_qty (internal/service/order_test.go:19)
    AC3 repo error wrapped            -> MISSING (critical: error path of external call)
  Coverage (changed packages): internal/service 91.7%, internal/handler 0.0%

Needs human judgment
  - <title> — <file>:<line> (score 65): <why>

Pre-existing (not blocking)
  - <title> — <file>:<line>

No artifacts left: verified
```

Tools line rules: `test` shows `N pass` when OK, `N failing` when FAIL;
`race` shows `FAIL` when `tools/test.txt` contains `DATA RACE`; `vuln`
shows `none`, `N reachable`, or `unavailable`. Any `UNAVAILABLE(reason)`
shows as `<tool> unavailable (<reason>)`.

Ids: BLOCKER B1..Bn, MAJOR M1..Mn, MINOR N1..Nn, in order of file path then
line.

## MR summary

`summary.md` is Markdown with the same content, except each finding is one
bullet `- **B1** <title> — `<file>:<line>`` (the body goes into the inline
discussion). Start with the Verdict line, then Tools, then the bullets by
severity, then the SDD/TDD block as a fenced block, then Needs human
judgment. Do not include "No artifacts left".
````

- [ ] **Step 3: Verify headings**

Run: `grep -c '^## Finding schema\|^## Severity\|^## Verifier rubric\|^## Verdict\|^## Noise rules' skill/references/severity-verdict.md; grep -c '^## Terminal report\|^## MR summary' skill/references/report-format.md`
Expected: `5` and `2`.

- [ ] **Step 4: Commit**

```bash
git add skill/references/severity-verdict.md skill/references/report-format.md
git commit -m "Add severity, verdict and report format references"
```

---

### Task 9: `checklist-correctness.md`

**Files:**
- Create: `skill/references/checklist-correctness.md`

**Interfaces:**
- Produces: the checklist the `go-review-correctness` agent reads first. Sections: `## How to work`, `## Errors`, `## Context and cancellation`, `## Concurrency`, `## Resources and transactions`, `## Logic and types`, `## Evidence to cite`.

- [ ] **Step 1: Write the file**

```markdown
# Correctness and concurrency checklist

## How to work

1. Read `diff.patch` fully. For every changed function, open the file and read
   the whole function plus its direct callers (`grep -rn "FuncName("`).
2. Read `tools/summary.txt`, `tools/vet.txt`, `tools/test.txt`, `tools/lint.txt`.
   A `DATA RACE` block or a failing test is a BLOCKER with the tool line as evidence.
3. Walk the list below against each changed function. Report only what you can
   point to at a `file:line` on a changed line. Pre-existing defects on
   unchanged lines go in a separate list with `"line"` set and the title
   prefixed `PRE-EXISTING:`.
4. Do not report what `tools/lint.txt` already reports unless lint is UNAVAILABLE.

## Errors

- Error discarded: `_ = f()`, `if err != nil { return nil, nil }`, `err` shadowed by `:=` inside a block and never checked (`if err := ...; err != nil` fine; `x, err := ...` inside `if` that shadows an outer `err` later returned is not).
- Error returned without context: `return err` from a function that made an outbound call or has more than one error source. Require `fmt.Errorf("op %s: %w", id, err)`.
- `%v` instead of `%w` when the caller uses `errors.Is/As` on the result.
- Sentinel or typed errors compared with `==` after wrapping; must use `errors.Is/As`.
- Errors logged and returned (double reporting), or logged and dropped on a path the caller must know about.
- `panic` or `log.Fatal` outside `main`/init paths; recover that swallows everything including runtime errors that indicate corruption.
- Partial success not surfaced: batch loops that `continue` on error without collecting or counting failures.
- HTTP/gRPC handlers mapping all errors to 500 when the service returns typed validation/not-found errors (and vice versa: leaking internal error text to clients).

## Context and cancellation

- `context.Background()`/`TODO()` created in request paths instead of using the caller's `ctx`.
- `ctx` accepted but not passed to DB, HTTP, Redis, NATS, gRPC calls.
- Goroutine started from a request handler that outlives the request without its own detached context and lifecycle (leak on cancellation).
- `select` without `case <-ctx.Done()` in a loop that waits on a channel or ticker.
- Timeouts: `context.WithTimeout` result's `cancel` not deferred; deadline derived from a config value that can be zero (meaning "no timeout").

## Concurrency

- Shared map, slice, counter, or struct field written from more than one goroutine without a mutex, atomic, or channel ownership. Check `go` statements and callbacks (HTTP handlers, NATS subscribers, timers) that touch package-level or struct state.
- Mutex held across a blocking call (I/O, channel send, `wg.Wait`), or lock/unlock pairs that can skip the unlock on an early return (require `defer mu.Unlock()` or a clear reason).
- Copying a struct that contains a `sync.Mutex` or `sync.WaitGroup` (vet reports `copylocks`; if vet is UNAVAILABLE, check manually).
- `sync.WaitGroup`: `Add` inside the goroutine, or `Wait` that can be reached with zero `Add`.
- Unbounded goroutine spawn in a loop over user-controlled input; no semaphore or worker pool.
- Channel misuse: send on a channel with no guaranteed receiver (leak or block), close by the receiver, close twice, `range` over a channel that is never closed, unbuffered channel used as a queue between a producer and a slow consumer inside a request.
- Loop variable captured by a goroutine or closure on Go < 1.22 (check `go.mod` `go` directive); on >= 1.22 per-iteration semantics apply, do not report.
- `time.After` inside a hot loop (timer leak until fired); prefer `time.NewTimer` with `Stop`.
- `sync.Once` / lazy init that can return a partially initialized value on error.
- `errgroup` used without `WithContext`, or the group's ctx not passed into the workers.
- Ticker/cron/background loops: no exit path on shutdown, no recover, no backoff on repeated failure.

## Resources and transactions

- `rows`, `resp.Body`, files, gRPC streams, `*sql.Tx` not closed on every path; `defer` placed after an error check that can return early before it (`resp, err := ...; if err != nil { return }; defer resp.Body.Close()` is correct; `defer` before the check is wrong).
- `rows.Err()` not checked after a `rows.Next()` loop.
- Transaction: `Begin` without `Rollback` on every error path; commit error ignored; two writes that must be atomic done outside a transaction; transaction held while calling an external service.
- Read-modify-write on a row without `SELECT ... FOR UPDATE`, optimistic version check, or an atomic `UPDATE ... SET x = x + ?` when concurrent updates are possible (balances, counters, inventory).
- Idempotency: a retried operation (queue consumer, HTTP client with retry) that inserts, increments, or sends without an idempotency key or dedup check.
- Cache: write-through order (DB then cache), stale read after write, cache key missing a tenant/user dimension, no TTL on unbounded keys.

## Logic and types

- Nil: method on a nil pointer receiver that dereferences fields; nil map write; nil slice vs empty slice where JSON output differs (`null` vs `[]`) and the API contract cares; interface holding a typed nil.
- Zero values used as "not set": `0` for an ID, `""` for an optional field, `time.Time{}` compared with `IsZero` inconsistently.
- Integer: overflow in money or quantity math, `int` for 64-bit amounts on 32-bit targets, float used for money, division by zero from user input, unsigned subtraction underflow.
- Off-by-one in pagination (`limit`, `offset`, cursor comparison `>` vs `>=`), range boundaries, time windows (inclusive/exclusive end), `len-1` on empty slices.
- Slices: `append` to a sub-slice aliasing the parent; returning internal slices/maps that callers can mutate.
- Maps: iteration order relied on for output or for "first match" semantics.
- Time: `time.Now()` without a clock abstraction in code that must be tested; local time vs UTC mixed; `time.Duration` multiplied by an untyped constant with the wrong unit (`timeout * time.Second` where `timeout` is already a Duration).
- String/bytes: byte indexing on UTF-8 strings; `strings.Split` on empty input yields `[""]`.
- JSON: field tags missing or mistyped (`json:"userId"` vs `user_id`), `omitempty` on a bool/int that must be sent as zero, `int64` IDs sent to JS clients without string encoding when the contract requires it.
- Comparisons of errors, structs with slices, or `time.Time` with `==`.
- Switch without `default` on an enum that has since grown; `iota` enums persisted by value with a reordering in the diff.
- Retry loops with no max attempts or no backoff/jitter; retrying non-idempotent calls; retrying on non-retryable errors (4xx, validation).

## Evidence to cite

Quote the exact changed line(s). For concurrency, name both writers (or writer
and reader) with `file:line` each. For tool findings quote the `tools/*.txt`
line. For a missing close/rollback, cite the early-return line that skips it.
```

- [ ] **Step 2: Verify sections**

Run: `grep -c '^## ' skill/references/checklist-correctness.md`
Expected: `7`.

- [ ] **Step 3: Commit**

```bash
git add skill/references/checklist-correctness.md
git commit -m "Add correctness and concurrency checklist"
```

---

### Task 10: `checklist-security.md`

**Files:**
- Create: `skill/references/checklist-security.md`

**Interfaces:**
- Produces: the checklist the `go-review-security` agent reads first. Sections: `## How to work`, `## Input and injection`, `## Authentication and authorization`, `## Secrets and logging`, `## Crypto and tokens`, `## Network and files`, `## Dependencies`, `## Evidence to cite`.

- [ ] **Step 1: Write the file**

```markdown
# Security checklist

## How to work

1. Read `diff.patch`. List every place user- or network-controlled data enters
   the changed code: HTTP params/body/headers, gRPC request fields, GraphQL
   args, queue messages, config, files, environment.
2. For each entry point trace the data to every sink: SQL, shell, file path,
   URL, template, log, redirect, header, another service.
3. Read `tools/lint.txt` (gosec lines) and `tools/vuln.txt`. Each reachable
   vulnerability in `vuln.txt` is a BLOCKER, rule-based, evidence = OSV id +
   the trace line.
4. Report only on changed lines unless a changed line newly exposes a
   pre-existing sink (then cite both).

## Input and injection

- SQL built by concatenation or `fmt.Sprintf` with any non-constant part; GORM `Where(fmt.Sprintf(...))`, `Raw`, `Order(userInput)`, `Table(userInput)`; `?` placeholders required. Column/sort names from input must be allow-listed.
- NoSQL/Redis: keys or Lua scripts built from unvalidated input; `KEYS pattern` with user input.
- Command execution: `exec.Command("sh", "-c", ...)` with any variable; arguments not separated.
- Path traversal: `filepath.Join(base, userInput)` without `filepath.Clean` + prefix check; `..` accepted; `os.Open` on a user-supplied name.
- SSRF: outbound HTTP to a URL or host from input without an allow-list; redirects followed to internal ranges; DNS rebinding not considered for long-lived allow-lists.
- Template/HTML: `template.HTML(userInput)`, `text/template` used for HTML output.
- Deserialization: `json.Unmarshal` into `interface{}` then type-switched into privileged paths; `gob`/`yaml` from untrusted sources; unbounded body size (`http.MaxBytesReader` missing), unbounded array lengths, no `DisallowUnknownFields` where the contract requires strictness.
- Validation: numeric bounds (qty, amount, page size), string length, enum membership, UUID format; validation done in the handler but bypassed by another entry point (queue consumer, internal gRPC) into the same service method.
- Mass assignment: binding request bodies directly into DB models (GORM `Save(&model)` from a bound struct) exposing fields like `role`, `balance`, `is_admin`.
- Integer parsing: `strconv.Atoi` result used as an index or size without bounds.

## Authentication and authorization

- New endpoint/resolver/RPC without the auth middleware or interceptor the rest of the group uses; check the router/registration diff, not just the handler.
- Object-level authorization: fetch by id from input without checking the caller owns/can access it (IDOR); list endpoints that filter by a user id taken from the request instead of the session.
- Role checks done client-side, in GraphQL directives that the internal schema skips, or only in one of two schemas (public vs internal gqlgen).
- Admin/internal endpoints reachable on the public listener; internal gRPC without mTLS or network policy assumption documented.
- JWT: `alg` not pinned, expiry not checked, claims trusted without signature verification, tokens accepted from query strings, refresh token reuse not detected.
- Session/user id derived from a header that clients can set (`X-User-Id`) on a public path.
- Rate limiting or lockout missing on login, OTP, password reset, expensive endpoints.

## Secrets and logging

- Secrets, tokens, private keys, or connection strings in code, test fixtures, config committed in the diff, or default values.
- Logging request bodies, headers (`Authorization`, cookies), tokens, passwords, PII (email, phone, wallet private material) at any level; error messages that embed them.
- Error responses leaking stack traces, SQL, file paths, or internal hostnames to clients.
- Debug endpoints (`pprof`, `expvar`, GraphQL playground/introspection) exposed without auth in non-dev builds.

## Crypto and tokens

- `math/rand` for tokens, OTPs, nonces, session ids; must be `crypto/rand`.
- MD5/SHA1 for passwords or signatures; passwords not hashed with bcrypt/scrypt/argon2; comparison of MACs/tokens with `==` instead of `hmac.Equal`/`subtle.ConstantTimeCompare`.
- AES in ECB, static IV/nonce, key derived from a short string without KDF, unauthenticated encryption where integrity matters.
- TLS: `InsecureSkipVerify: true`, custom `VerifyPeerCertificate` that accepts everything, min version below 1.2.
- Signature verification of webhooks/callbacks missing or done after side effects; replay not prevented (no timestamp/nonce check).
- Wallet/chain specifics: private key material in memory longer than needed, logged, or sent to another service; signing user-controlled payloads without domain separation.

## Network and files

- HTTP client without timeout (`http.DefaultClient`, `&http.Client{}`), or server without `ReadHeaderTimeout`/`ReadTimeout`.
- CORS `AllowOrigins: *` with credentials; reflecting the `Origin` header.
- Open redirect: `Location` from input without allow-list.
- Files written with permissive modes (`0666`, `0777`), temp files predictable, uploads without type/size limits, served from a user-controllable path.
- WebSocket: origin check disabled; no message size limit; no auth on upgrade.

## Dependencies

- New dependency added in `go.mod`: check it is maintained, pinned to a tagged release (no pseudo-version of a fork), and not replacing a stdlib capability.
- `replace` directives pointing at local paths or unreviewed forks.
- `govulncheck` unavailable: say so; do not claim dependencies are clean.

## Evidence to cite

Quote the source line where untrusted data enters and the sink line; for
missing auth cite the route registration line and a sibling route that has
the middleware. For crypto cite the call. For vuln cite the OSV id and the
function in the trace.
```

- [ ] **Step 2: Verify sections**

Run: `grep -c '^## ' skill/references/checklist-security.md`
Expected: `8`.

- [ ] **Step 3: Commit**

```bash
git add skill/references/checklist-security.md
git commit -m "Add security checklist"
```

---

### Task 11: `checklist-architecture.md` and `checklist-performance.md`

**Files:**
- Create: `skill/references/checklist-architecture.md`, `skill/references/checklist-performance.md`

**Interfaces:**
- Produces: checklists for the `go-review-architecture` and `go-review-performance` agents. Architecture sections: `## How to work`, `## Project rules first`, `## Layers and dependencies`, `## Interfaces and packages`, `## Contracts`, `## Evidence to cite`. Performance sections: `## How to work`, `## Database and cache`, `## Allocation and CPU`, `## Reliability`, `## Observability`, `## Evidence to cite`.

- [ ] **Step 1: Write `skill/references/checklist-architecture.md`**

```markdown
# Architecture and design checklist

## How to work

1. Read the project rule files passed to you (root `CLAUDE.md`, `CLAUDE.md`
   in touched dirs, `docs/code-standards/**`). Rules there override this
   checklist; cite the rule file and line in `spec_ref` when a finding comes
   from them.
2. Map the repo layout: `ls internal/ pkg/ cmd/` and read one existing file per
   layer to learn the established pattern (how handlers call services, how
   repositories are injected, how errors flow up).
3. Read `diff.patch` and `changed-symbols.txt`. For each new or changed
   exported symbol ask: which layer owns it, who imports it, does that match
   the pattern found in step 2.
4. Report deviations from the repo's own pattern before generic rules. A
   generic rule only applies when the repo has no established pattern for it.

## Project rules first

Look for and apply, in this order: `CLAUDE.md` sections about architecture,
layers, naming, error handling, DI; `docs/code-standards/*`; `README.md`
architecture sections; `.golangci.yml` `depguard`/`gomodguard` settings.
Quote the rule text in `why`.

## Layers and dependencies

Generic rules when the repo does not say otherwise (typical layout: transport
-> usecase/service -> repository -> infra):

- Transport (handler, resolver, gRPC server, consumer) calling a repository or
  DB client directly, bypassing the service/usecase layer. MAJOR.
- Business logic (validation, calculations, state transitions) living in a
  handler or in a repository. MAJOR.
- Lower layer importing a higher layer (repository importing service, domain
  importing transport). Import cycle avoided only via a hack (init, globals). MAJOR.
- Domain/service packages importing framework packages they do not need
  (gin, grpc, gqlgen generated types) instead of plain structs. MAJOR when it
  makes the service untestable without the framework; MINOR otherwise. ORM
  model structs importing `gorm` are accepted.
- Transaction boundary: `Begin/Commit` inside a repository method that is
  called as part of a larger unit of work, or in a handler. The service/usecase
  owns the boundary; repositories accept a tx or a `Querier`. MAJOR.
- Global mutable state (package-level clients, config, caches) added instead of
  injected via the constructor/fx/wire pattern the repo uses. MAJOR.
- New package with one file and one type that belongs in an existing package;
  or a `utils`/`common`/`helpers` package gaining domain logic. MINOR.

## Interfaces and packages

- Interface declared next to the implementation and exported for the sake of
  mocking, instead of declared by the consumer with only the methods it uses.
  MINOR, MAJOR if the interface has > 5 methods and only 1-2 are used.
- Interface with a single implementation and no test double: unnecessary
  abstraction. MINOR.
- Constructor returning a concrete type while the rest of the repo returns
  interfaces (or the reverse). MINOR.
- Exported identifier that is only used within its package. MINOR.
- Package naming: `package models` holding behavior, stuttering names
  (`order.OrderService`), generic names (`types`, `base`). MINOR.
- Struct with > 7 injected dependencies: the type does too much. MAJOR if the
  diff added the 8th.
- Duplicated logic with an existing helper in the repo (`grep` for the
  operation before flagging). MAJOR when the duplicate diverges in behavior.

## Contracts

- Public API shape: new endpoint/resolver/RPC inconsistent with siblings
  (naming, pagination style, error envelope, id types, timestamp format).
  MAJOR.
- Breaking change to an existing contract: removed/renamed field, changed type,
  changed enum value or proto field number, changed event payload, without a
  version or compatibility note. BLOCKER when consumers exist in the repo or
  the spec lists external consumers; MAJOR otherwise.
- Proto/GraphQL/OpenAPI schema changed but generated code not regenerated, or
  regenerated code changed by hand. BLOCKER.
- Events/messages: payload without schema version, subject/topic naming
  inconsistent with existing ones, consumer not idempotent for at-least-once
  delivery. MAJOR.
- Configuration: new required config key without a default, validation at
  startup, and documentation in the env example. MAJOR.
- Database schema: migration not reversible, missing index for a new query
  pattern, nullable column without a stated reason, enum stored as string vs
  int inconsistently with the rest of the schema. MAJOR.

## Evidence to cite

Cite the import line or call line that crosses the boundary, plus one
existing file that shows the established pattern (`file:line`). For contract
breaks cite the removed/changed line and one consumer.
```

- [ ] **Step 2: Write `skill/references/checklist-performance.md`**

```markdown
# Performance, reliability, and observability checklist

## How to work

1. Read `diff.patch`. Mark each changed function as hot (request path,
   consumer loop, scheduler tick, per-row callback) or cold (startup, admin,
   one-off). Apply allocation rules only to hot paths.
2. For every DB/cache/HTTP/RPC call in the diff, find the loop it is in
   (`grep -n "for " <file>`) and whether the call has a timeout and a bound.
3. Read `tools/cover.txt` only to see whether hot paths have tests; do not
   report coverage numbers as findings.

## Database and cache

- N+1: a query inside a loop over a result set; GORM associations loaded per
  row instead of `Preload`/join; per-item Redis `GET` instead of `MGET`/pipeline. MAJOR.
- Unbounded query: `Find(&all)` without a limit on a table that grows; list
  endpoints without max page size; `SELECT *` with large columns where only ids
  are needed. MAJOR.
- Missing index for a new filter/sort column, or a query that cannot use the
  existing index (function on the column, leading wildcard). MAJOR.
- Transactions held across outbound calls or user waits. MAJOR.
- Cache: no TTL, key cardinality unbounded (per-request keys), stampede on
  expiry for hot keys without singleflight/lock, cache storing errors. MAJOR.
- Redis blocking commands or `KEYS`/`SMEMBERS` on large sets in request paths. MAJOR.
- Bulk work done row by row where a batch insert/update exists. MINOR, MAJOR in a consumer.

## Allocation and CPU

- Slice/map grown in a loop without capacity hint when the size is known. MINOR.
- String concatenation in a loop; `fmt.Sprintf` for simple joins in hot paths;
  `[]byte(s)`/`string(b)` conversions repeated. MINOR.
- Regex compiled per call (`regexp.MustCompile` inside a function). MAJOR in hot paths.
- JSON marshal/unmarshal of large payloads repeatedly for the same data. MINOR.
- Reflection or `interface{}` boxing in tight loops. MINOR.
- Lock contention: a single mutex guarding a hot map with many readers
  (consider `RWMutex` or sharding); lock held while doing work that does not
  need it. MAJOR when on a request path.
- Goroutine per item without a bound; channel buffer sized from input. MAJOR.
- Large struct passed by value in hot loops; closures capturing large state
  per iteration. MINOR.
- Timers/tickers created per request and not stopped. MAJOR.

## Reliability

- Outbound call without timeout (HTTP client, gRPC dial/call, Redis, DB
  context), or with a timeout longer than the caller's budget. MAJOR.
- No retry on transient failure for an idempotent call, or retry without
  backoff+jitter+max attempts, or retry on a non-idempotent call. MAJOR.
- Circuit breaking / bulkhead absent on a dependency that already has an
  established pattern in the repo. MINOR.
- Graceful shutdown: new server, consumer, worker, or ticker not hooked into
  the shutdown sequence (fx lifecycle hooks, signal handler); in-flight work
  dropped on SIGTERM. MAJOR.
- Startup: dependency checks that crash-loop instead of degrading; missing
  readiness/liveness distinction for a new dependency. MINOR.
- Queue consumers: no ack/nack strategy, poison messages retried forever, no
  dead-letter path, ordering assumptions not guaranteed by the transport. MAJOR.
- Schedulers: overlapping runs not prevented, no jitter across replicas,
  clock/timezone assumptions. MAJOR.
- Resource limits: unbounded in-memory buffering of a stream, unbounded map
  growth (per-user state never evicted). MAJOR.

## Observability

- New error path without a log line carrying the ids needed to debug it
  (request id, user/order id) or logging at the wrong level (errors at Info,
  expected conditions at Error). MINOR.
- Logs with unstructured `fmt.Sprintf` where the repo uses structured fields. MINOR.
- New external call or consumer without metrics/tracing where siblings have
  them. MINOR.
- Log spam: logging inside a hot loop per item, or logging the full payload. MAJOR.
- Panics in goroutines not recovered and reported (crash the whole process). MAJOR.

## Evidence to cite

Cite the call line and the enclosing loop or handler line. For timeouts cite
the client construction line. For shutdown cite where siblings register
their hooks.
```

- [ ] **Step 3: Verify sections**

Run: `grep -c '^## ' skill/references/checklist-architecture.md; grep -c '^## ' skill/references/checklist-performance.md`
Expected: `6` and `6`.

- [ ] **Step 4: Commit**

```bash
git add skill/references/checklist-architecture.md skill/references/checklist-performance.md
git commit -m "Add architecture and performance checklists"
```

---

### Task 12: `checklist-sdd-tdd.md`

**Files:**
- Create: `skill/references/checklist-sdd-tdd.md`

**Interfaces:**
- Produces: the checklist for the `go-review-sdd-tdd` agent. Sections: `## How to work`, `## Classify the change`, `## Locate spec and plan`, `## Spec rubric`, `## Code vs spec`, `## Requirement-to-test matrix`, `## Test quality`, `## Rules`, `## Output`.

- [ ] **Step 1: Write the file**

````markdown
# Spec-driven and test-driven development checklist

Everything in this checklist is rule-based. Findings carry `rule_based: true`
and the severity from the Rules table; the verifier only confirms facts.

## How to work

1. Read `meta.env`, `nontest-lines.txt`, `changed-files.txt`,
   `changed-symbols.txt`, `diff.patch`.
2. Classify the change (below).
3. Read `specs.tsv` and `specs-all.txt`. Open every matched candidate.
4. Score the spec against the rubric, build the requirement-to-test matrix,
   check test quality, then emit findings from the Rules table.

## Classify the change

Substantive when any of:
- `nontest-lines.txt` > 50
- a new or changed HTTP handler, gRPC method, GraphQL resolver, consumer,
  publisher, scheduler job (look at `changed-symbols.txt` and route/schema
  registration lines in the diff)
- a new or changed DB schema, migration, proto, GraphQL schema, event payload
- a new package
- behavior change in a service/usecase/repository function (a changed `if`,
  return value, query, or call sequence; not a rename or comment)

Trivial otherwise: typo, comment, log text, dependency bump with no code
change, pure rename verified by the diff, formatting.

State the classification and the reason in the SDD block. Trivial changes
skip the spec/plan rules but still get the test-quality rules.

## Locate spec and plan

Conventions, in order; the first convention with a match wins:

1. Superpowers: `docs/superpowers/specs/*.md` is the spec,
   `docs/superpowers/plans/*.md` is the plan.
2. OpenSpec: `openspec/changes/<id>/proposal.md` (+ `design.md`) is the spec,
   `openspec/changes/<id>/specs/**/spec.md` are the requirement deltas,
   `openspec/changes/<id>/tasks.md` is the plan. `openspec/specs/**` is the
   baseline to diff against for drift.
3. Plain docs: any `docs/**/*.md` except README; the plan may be a section
   (`## Plan`, `## Tasks`, `## Implementation`) in the same file.

A candidate counts as the spec for this change only if it is in `specs.tsv`
(has at least one signal) and its content describes the changed behavior.
A doc that merely mentions the package but describes a different feature is
not a match; say so.

`--spec <path>` (row `forced`) is always the spec, even if it looks unrelated;
still score it.

If no spec matches, list up to 3 nearest paths from `specs-all.txt` in the
finding's `fix` so the user can rerun with `--spec`.

## Spec rubric

Ten required sections. A section counts as present when the content is there
under any heading name, with at least one concrete sentence (a heading with
"TBD", "N/A" without a reason, or one generic line does not count).

| # | Section | Present when |
|---|---|---|
| 1 | Goal / problem | says what is wrong or missing today and for whom |
| 2 | Scope / out of scope | lists what is in and explicitly what is out |
| 3 | Current state | describes the code/behavior before the change |
| 4 | Design decisions with rationale | at least one decision and a because |
| 5 | Contracts | API/event/schema/config signatures or shapes, concrete |
| 6 | Error handling and edge cases | names specific failure modes and what happens |
| 7 | Data / migration impact | says none with a reason, or describes the change |
| 8 | Risks and rollback | at least one risk and how to revert |
| 9 | Testing strategy | names the cases that must be tested |
| 10 | Acceptance criteria | checkable statements (given/when/then or a list) |

OpenSpec mapping: proposal covers 1, 2, 3, 7, 8 (its Why/What/Impact
sections); design covers 4; delta specs cover 5, 6, 10 through requirements
with `#### Scenario:` blocks (a requirement without a scenario is a missing
10); tasks.md covers 9 when it lists test tasks.

Report `Spec rubric: N/10 (missing: ...)`.

## Code vs spec

For each contract, decision, and acceptance criterion in the spec, find the
implementing lines in the diff. Flag:
- Behavior in the diff that the spec does not describe (new endpoint, new
  field, new side effect, new config key).
- Spec statements the diff contradicts (different name, type, status code,
  error, ordering, default).
- Plan/tasks: items checked but not implemented, or implemented but not
  checked; tasks that mention files the diff does not touch and vice versa.

## Requirement-to-test matrix

Rows: every acceptance criterion, scenario, and "must test" case from the
spec. When there is no spec, derive rows from the code: each `if`/`switch`
branch on input, each error return, each boundary (empty, zero, max, off by
one), each concurrent path, each external call's failure.

For each row find a test that exercises it: read `*_test.go` in the changed
packages and importers, match by function under test and by the input or
error asserted. Record `TestName/subtest (file:line)` or `MISSING`.

Mark a row critical when it involves: money, balance, quantity, order,
position, or fee math; authn/authz; concurrency; the error path of an
external call (DB, cache, queue, HTTP, RPC); a migration or data backfill.

Attach per-package coverage from `tools/cover.txt` as evidence only.

## Test quality

Flag when true for a changed package:
- A changed non-trivial function (more than a getter/setter/constructor) with
  no test added or modified that calls it.
- A test with no assertion: no `t.Error*`, `t.Fatal*`, `require.*`,
  `assert.*`, `cmp.Diff` check, or `if got != want`. A test that only checks
  `err == nil` for a function that has error paths counts as happy-path only.
- Tests that call the function but ignore the return (`_, _ = f()`).
- Only happy-path tests for a function with error returns.
- Concurrency-touching code (goroutines, mutexes, channels) with no test that
  runs the code from multiple goroutines; `go test -race` cannot catch what no
  test exercises.
- Tests that depend on wall-clock sleeps or real network for unit behavior.
- Table-driven cases with duplicated inputs, or a subtest name that does not
  say what is being asserted.
- Test-only code paths in production code (`if testing.Testing()`, `if
  isTest`).

## Rules

| Condition | Severity |
|---|---|
| Substantive, no matching spec | BLOCKER |
| Substantive, no plan/tasks | MAJOR |
| Plan tasks checked but not implemented, or implemented but not checked | MAJOR |
| Spec missing exactly 1 rubric section | MAJOR |
| Spec missing 2 or more rubric sections | BLOCKER |
| Diff contradicts spec on a contract, or adds undocumented behavior touching a contract or data | BLOCKER |
| Diff contradicts spec elsewhere, or adds undocumented behavior elsewhere | MAJOR |
| Matrix row MISSING and critical | BLOCKER |
| Matrix row MISSING, not critical | MAJOR |
| Changed non-trivial function without a test change | MAJOR |
| Assertion-less or happy-path-only test on a function with error paths | MAJOR |
| Concurrent code without a concurrent test | MAJOR |
| Sleep/network-dependent unit test, test-only branches in prod code | MINOR |
| `--skip-sdd "<reason>"` given | the first two rows become MAJOR; put the reason in `why` |

## Output

Return the findings array and, as a second JSON object, the SDD block:

    {
      "classification": "substantive|trivial",
      "classification_reason": "...",
      "spec": {"path": "...", "convention": "...", "signals": "..."} | null,
      "plan": {"path": "..."} | null,
      "nearest_candidates": ["..."],
      "rubric": {"score": 8, "missing": ["risks/rollback", "acceptance criteria"]},
      "matrix": [{"requirement": "AC1 ...", "critical": false, "test": "TestX/success (file:line)" | "MISSING"}],
      "coverage": [{"package": "...", "percent": 91.7}]
    }
````

- [ ] **Step 2: Verify sections**

Run: `grep -c '^## ' skill/references/checklist-sdd-tdd.md`
Expected: `9`.

- [ ] **Step 3: Commit**

```bash
git add skill/references/checklist-sdd-tdd.md
git commit -m "Add SDD/TDD checklist"
```

---

### Task 13: `SKILL.md`, `workflow.md`, and the reference-integrity test

**Files:**
- Create: `skill/SKILL.md`, `skill/references/workflow.md`, `tests/test-references.sh`

**Interfaces:**
- Consumes: every script CLI (Tasks 3-6), every reference heading (Tasks 7-12), agent names `go-review-{correctness,security,architecture,performance,sdd-tdd,verifier}` (Task 14).
- Produces: the orchestrator instructions. `tests/test-references.sh` checks that every relative path mentioned in backticks in `SKILL.md` and `workflow.md` exists under `skill/`, and that every `references/*.md` heading the workflow links to exists.

- [ ] **Step 1: Write the failing test `tests/test-references.sh`**

```bash
#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
SK="$REPO_ROOT/skill"
assert_file "$SK/SKILL.md" "SKILL.md exists"
assert_file "$SK/references/workflow.md" "workflow.md exists"

# every `references/...` or `scripts/...` path in backticks must exist
for f in "$SK/SKILL.md" "$SK/references/workflow.md"; do
  while read -r p; do
    [[ -e "$SK/$p" ]] && pass || fail "$(basename "$f") references missing path $p"
  done < <(grep -oE '`(references|scripts)/[A-Za-z0-9_./-]+`' "$f" | tr -d '`' | sort -u)
done

# every `references/x.md` (section "Heading") link in workflow.md must resolve
while read -r l; do
  p=$(sed -E 's/`(references[^`]+)`.*/\1/' <<<"$l"); h=$(sed -E 's/.*section "([^"]+)".*/\1/' <<<"$l")
  grep -q "^## .*$h\$" "$SK/$p" && pass || fail "heading '$h' missing in $p"
done < <(grep -oE '`references/[a-z-]+\.md` *\(section "[^"]+"\)' "$SK/references/workflow.md")

# all six agents are named in the workflow
for a in correctness security architecture performance sdd-tdd verifier; do
  grep -q "go-review-$a" "$SK/references/workflow.md" && pass || fail "workflow names agent $a"
done

# SKILL.md frontmatter
head -1 "$SK/SKILL.md" | grep -q '^---$' && pass || fail "frontmatter start"
grep -q '^name: go-review$' "$SK/SKILL.md" && pass || fail "name"
grep -q '^description:' "$SK/SKILL.md" && pass || fail "description"
finish
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash tests/test-references.sh` — expected FAIL (SKILL.md missing).

- [ ] **Step 3: Write `skill/SKILL.md`**

```markdown
---
name: go-review
description: >-
  High-standard code review for Go backend changes. Use when asked to review
  Go code, a Go diff, branch, or GitLab merge request, or when the user says
  "review", "go review", "review MR", "review this branch", "check my PR",
  "review code" in a Go repository. Runs build/vet/lint/test/race/vuln as
  evidence, dispatches specialist read-only agents for correctness and
  concurrency, security, architecture, performance and reliability, and
  spec-driven/test-driven compliance (spec, plan, tests for critical cases),
  verifies findings, prints an English report with a verdict, and can post to
  the MR. Leaves the reviewed repository untouched.
---

# go-review

Review Go backend changes to a standard a senior reviewer would sign.
Everything you need is in `references/workflow.md`; read it now and follow it
step by step. Do not skip the final cleanup step even when an earlier step
fails.

## Invocation

    /go-review [target] [--base <ref>] [--comment] [--no-tools] [--full-tests] [--spec <path>] [--skip-sdd "<reason>"]

| Argument | Meaning |
|---|---|
| none | working tree + current branch vs base |
| `<branch>` | that branch vs base |
| `!123`, `123`, MR URL | the GitLab MR at its head sha |
| `--base <ref>` | override base (default: MR target, else `origin/HEAD`, else develop/main) |
| `--comment` | after the report, post to the MR (asks first) |
| `--no-tools` | skip build/vet/lint/test/vuln |
| `--full-tests` | test all packages, not only changed + importers |
| `--spec <path>` | force this file/dir as the spec |
| `--skip-sdd "<reason>"` | downgrade missing spec/plan to MAJOR; reason is printed |

## Hard rules

- Never write inside the reviewed repo. All scratch goes to a `mktemp -d`
  directory; `scripts/assert-clean.sh` proves it at the end.
- Never run `go mod tidy`, `go generate`, formatters with `-w`, or
  `golangci-lint --fix` (full list in `references/tooling.md`).
- Never post to GitLab without `--comment` and an explicit yes after showing
  the summary.
- Report in English, in the exact shape of `references/report-format.md`.
- Findings need `file:line` and verbatim evidence. No evidence, no finding.

## Files

- `references/workflow.md` — the pipeline you execute
- `references/tooling.md`, `references/gitlab.md` — how to run the scripts
- `references/severity-verdict.md`, `references/report-format.md` — how to judge and print
- `references/checklist-*.md` — what each specialist agent checks
- `scripts/collect.sh`, `scripts/find-specs.sh`, `scripts/assert-clean.sh`, `scripts/gitlab-post.sh`
```

- [ ] **Step 4: Write `skill/references/workflow.md`**

````markdown
# Workflow for the orchestrator

You are the main session. Agents do the reading; you do the plumbing, the
verification hand-off, the report, and the cleanup. `$SKILL` is this skill's
directory (the parent of `references/`).

## 0. Parse arguments and set up

1. Parse `$ARGUMENTS` into `TARGET`, `--base`, `--comment`, `--no-tools`,
   `--full-tests`, `--spec`, `--skip-sdd`.
2. `REPO=$(git rev-parse --show-toplevel)`; if that fails, stop: "not a git repo".
   Confirm `go.mod` exists somewhere under `$REPO`; if not, stop: "not a Go repo".
3. `WORK=$(mktemp -d "${TMPDIR:-/tmp}/go-review.XXXXXX")`. Create a todo list
   with steps 1-6 below so progress is visible.
4. Decide the mode:
   - No target: `HEAD=WORKTREE`, `BRANCH=$(git rev-parse --abbrev-ref HEAD)`, `TITLE=""`.
   - Branch name: `HEAD=<branch>`, `BRANCH=<branch>`, `TITLE=""`.
   - MR (`!N`, `N`, or URL): follow `references/gitlab.md` (section "Resolve an MR target").
     Sets `HEAD=<head sha>`, `BRANCH=<source>`, `TITLE=<mr title>`, `BASE=origin/<target>`,
     `REVIEW_REPO=$WORK/wt`. If the MR is merged/closed, print that and go to step 6.
   For non-MR modes `REVIEW_REPO=$REPO`.
5. From here on, every failure still ends at step 6.

## 1. Collect evidence

Run `scripts/collect.sh` and then `scripts/find-specs.sh` exactly as shown in
`references/tooling.md` (section "Commands"). Pass `--no-tools` / `--full-tests`
/ `--spec` through. Read `$WORK/tools/summary.txt` and `$WORK/meta.env` and
print a one-line progress message with the tool statuses.

Collect project rule files: root `CLAUDE.md`, `CLAUDE.md` in each directory
listed in `changed-files.txt` (walk up to root), `docs/code-standards/*.md`
if present. Store the list in `$WORK/rules.txt`.

## 2. Dispatch the five reviewers

Use the Agent tool, all five in one message so they run concurrently:
`go-review-correctness`, `go-review-security`, `go-review-architecture`,
`go-review-performance`, `go-review-sdd-tdd`.

Each prompt contains, verbatim:

```
Repo: <REVIEW_REPO>
Work dir: <WORK>   (read-only for you except nothing: do not write anywhere)
Skill dir: <SKILL>
Read first: <SKILL>/references/checklist-<dimension>.md, then <SKILL>/references/severity-verdict.md (section "Finding schema").
Inputs: <WORK>/diff.patch, <WORK>/meta.env, <WORK>/changed-files.txt, <WORK>/changed-packages.txt,
        <WORK>/changed-symbols.txt, <WORK>/nontest-lines.txt, <WORK>/tools/summary.txt, <WORK>/tools/*.txt,
        <WORK>/specs.tsv, <WORK>/specs-all.txt, project rules: <contents of rules.txt>
Flags: skip-sdd=<reason or none>
Return ONLY a JSON array of findings (schema above). Empty array if none.
```

The SDD agent's prompt adds: "Also return the SDD block object described in
the checklist's Output section, after the array."

Large diffs: if `diff.patch` has more than 1500 lines, split
`changed-packages.txt` into groups of at most 6 packages and dispatch one
correctness and one security agent per group, telling each which packages
are in scope. Merge their arrays.

Collect all arrays into `$WORK/findings-raw.json`. Save the SDD block to
`$WORK/sdd.json`.

## 3. Add tool findings

From `tools/summary.txt` and `tools/test-classified.txt` create rule-based
findings (dimension `tools`) per `references/tooling.md` (section "Reading the outputs"):
build/vet FAIL, any package `FAIL` in test-classified, `DATA RACE` in
`tools/test.txt`, reachable vulnerabilities in `tools/vuln.txt`. Append to
`findings-raw.json`.

## 4. Verify

Group `findings-raw.json` by `file`. Dispatch `go-review-verifier` agents,
one per group of up to 8 files, in one message. Each prompt contains: repo
path, skill dir, the findings for its files (JSON), and:

```
Read <SKILL>/references/severity-verdict.md (sections "Verifier rubric", "Noise rules").
For each finding re-read the code at file:line and its callers. Set "score".
Rule-based findings: confirm the fact only; keep severity; score 100 or drop.
Merge duplicates. Return ONLY the JSON array with scores.
```

Merge the results. Assign ids (B1.., M1.., N1.. by path then line). Split into:
`findings.json` (score >= 80), `judgment.json` (60-79), `preexisting.json`
(title prefixed `PRE-EXISTING:`, max 5). Write all three into `$WORK`.

## 5. Report

Compute the verdict per `references/severity-verdict.md` (section "Verdict").
Print the terminal report per `references/report-format.md` (section "Terminal report"),
filling the SDD/TDD block from `sdd.json`. Keep the final line for step 6.

If `--comment`:
1. Write `$WORK/summary.md` per `references/report-format.md` (section "MR summary").
2. Show the summary to the user and ask: "Post this to MR !<iid>? (yes/no)".
3. On yes, run `scripts/gitlab-post.sh` per `references/gitlab.md` (section "Posting").
   Print its last line.

## 6. Cleanup (always)

```
bash "$SKILL/scripts/assert-clean.sh" --repo "$REPO" --out "$WORK" [--worktree "$WORK/wt"]
rm -rf "$WORK"
```

Print the `No artifacts left: verified` line as the last line of the report.
If `assert-clean.sh` exits 2, print its output verbatim under a heading
`ARTIFACTS LEFT` and tell the user which files to remove; do not remove them
yourself.
````

- [ ] **Step 5: Run the test to verify it passes**

Run: `bash tests/test-references.sh`
Expected: all pass. If a heading check fails, the heading text in the workflow must match the reference file exactly (case and punctuation).

- [ ] **Step 6: Commit**

```bash
git add skill/SKILL.md skill/references/workflow.md tests/test-references.sh
git commit -m "Add SKILL.md and orchestrator workflow"
```

---

### Task 14: Agent definitions

**Files:**
- Modify (replace placeholders): `agents/go-review-correctness.md`, `agents/go-review-security.md`, `agents/go-review-architecture.md`, `agents/go-review-performance.md`, `agents/go-review-sdd-tdd.md`, `agents/go-review-verifier.md`
- Create: `tests/test-agents.sh`

**Interfaces:**
- Consumes: checklist files (Tasks 9-12), `severity-verdict.md` (Task 8).
- Produces: six agent files with frontmatter `name`, `description`, `tools: Read, Grep, Glob, Bash`, `model: inherit`, and a body following the shared template below.

- [ ] **Step 1: Write the failing test `tests/test-agents.sh`**

```bash
#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
A="$REPO_ROOT/agents"
for a in correctness security architecture performance sdd-tdd verifier; do
  f="$A/go-review-$a.md"
  assert_file "$f" "agent file $a"
  grep -q "^name: go-review-$a\$" "$f" && pass || fail "$a name"
  grep -q '^tools: Read, Grep, Glob, Bash$' "$f" && pass || fail "$a tools are read-only set"
  grep -q '^model: inherit$' "$f" && pass || fail "$a model inherit"
  grep -q 'placeholder' "$f" && fail "$a still placeholder" || pass
  grep -qi 'do not write' "$f" && pass || fail "$a states read-only contract"
  grep -q 'go mod tidy' "$f" && pass || fail "$a forbids go mod tidy"
  grep -q 'JSON array' "$f" && pass || fail "$a returns JSON array"
  if [[ "$a" != "verifier" ]]; then
    grep -q "checklist-$a.md" "$f" && pass || fail "$a reads its checklist"
  else
    grep -q 'Verifier rubric' "$f" && pass || fail "verifier reads rubric"
  fi
done
finish
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash tests/test-agents.sh` — expected FAIL on `still placeholder`.

- [ ] **Step 3: Write the five reviewer agents**

Shared body template. Replace `<DIM>` with the dimension name, `<CHECKLIST>` with the checklist file name, `<FOCUS>` with the focus sentence from the table.

| Agent | `<DIM>` | `<CHECKLIST>` | `<FOCUS>` |
|---|---|---|---|
| go-review-correctness | correctness | checklist-correctness.md | logic errors, error handling, context and cancellation, data races, goroutine and resource leaks, transactions, idempotency |
| go-review-security | security | checklist-security.md | injection, authn/authz, secrets and logging, crypto, SSRF and file access, dependency vulnerabilities |
| go-review-architecture | architecture | checklist-architecture.md | project rules, layer boundaries, dependency direction, interface placement, package cohesion, contract compatibility |
| go-review-performance | performance | checklist-performance.md | N+1 and unbounded queries, allocations in hot paths, lock contention, timeouts and retries, graceful shutdown, observability |
| go-review-sdd-tdd | sdd-tdd | checklist-sdd-tdd.md | spec and plan existence and quality, code vs spec drift, requirement-to-test matrix, test quality |

File content for each (example shown for correctness; the description line differs per agent as given in the table's `<FOCUS>`):

```markdown
---
name: go-review-correctness
description: Read-only Go code reviewer for the correctness dimension of go-review — logic errors, error handling, context and cancellation, data races, goroutine and resource leaks, transactions, idempotency. Dispatched by the go-review skill; not for general use.
tools: Read, Grep, Glob, Bash
model: inherit
---

You are a senior Go backend reviewer. You review one dimension: correctness.
Focus: logic errors, error handling, context and cancellation, data races,
goroutine and resource leaks, transactions, idempotency.

## Contract

- Read-only. Do not write, create, move, or delete any file anywhere. Do not
  run `go mod tidy`, `go generate`, `go get`, `gofmt -w`, `goimports -w`,
  `golangci-lint --fix`, `git stash`, `git checkout`, `git add`, or any
  command that redirects output into the repo. Bash is for `grep`, `go list`,
  `go doc`, `git log`/`blame`/`show`, and reading files only.
- Start by reading, in this order: the checklist file named in your prompt
  (`checklist-correctness.md`), then the "Finding schema" and "Noise rules"
  sections of `severity-verdict.md`, then the project rule files listed in
  the prompt, then `diff.patch`.
- Review the change, not the codebase. Read surrounding code and callers as
  needed to be sure, but report only defects on changed lines, except a
  pre-existing defect that the change makes reachable or worse (prefix the
  title with `PRE-EXISTING:`).
- Evidence or nothing: every finding has `file`, `line`, and a verbatim
  `evidence` quote. If you cannot point to a line, do not report it.
- Do not report what the compiler, vet, or `tools/lint.txt` already reports,
  unless `tools/summary.txt` marks that tool UNAVAILABLE.
- Do not report style, nitpicks, or missing features outside the change's
  stated scope. A senior engineer would not raise it: do not raise it.
- Be severe on real defects and silent on non-defects. Fewer, better findings
  beat many weak ones.

## Output

Return ONLY a JSON array of findings using the schema in
`severity-verdict.md`. Set `dimension` to `correctness`, `rule_based` to
`false` (unless the checklist says a rule applies), and `score` to your own
confidence 0-100. Return `[]` when there is nothing to report. No prose
before or after the JSON.
```

For `go-review-sdd-tdd` change the last section to:

```markdown
## Output

Return ONLY: a JSON array of findings (schema in `severity-verdict.md`,
`dimension` = `sdd-tdd`, `rule_based` = `true`, `score` = 100), followed on
a new line by the SDD block JSON object described in the "Output" section of
`checklist-sdd-tdd.md`. No prose before, between, or after.
```

- [ ] **Step 4: Write `agents/go-review-verifier.md`**

```markdown
---
name: go-review-verifier
description: Read-only verifier for go-review findings — re-reads the code for each candidate finding, scores confidence 0-100 with a fixed rubric, confirms rule-based facts, merges duplicates. Dispatched by the go-review skill; not for general use.
tools: Read, Grep, Glob, Bash
model: inherit
---

You are the skeptic. Other agents proposed findings; your job is to keep only
the ones a senior Go engineer would defend in front of the author.

## Contract

- Read-only. Do not write, create, move, or delete any file anywhere. Do not
  run `go mod tidy`, `go generate`, `go get`, formatters with `-w`,
  `golangci-lint --fix`, or any git command that changes state. Bash is for
  `grep`, `go list`, `go doc`, `git log`/`blame`/`show`, and reading only.
- Start by reading the "Verifier rubric", "Noise rules", and "Finding schema"
  sections of `severity-verdict.md` in the skill dir given in your prompt.
- For each finding: open `file` at `line`, read the whole function, find its
  callers with `grep -rn`, and decide whether the defect is real, reachable,
  and on a changed line (check `diff.patch` in the work dir).
- Judgment findings (`rule_based: false`): overwrite `score` with the rubric
  value. Lower it when the path is unreachable, the input is impossible, the
  code handles it elsewhere, the line is unchanged, or a linter already
  reports it. Raise it when tool output or a test confirms it.
- Rule-based findings (`rule_based: true`): verify the fact only (the spec
  file really is absent or lacks the section, the test really is missing, the
  tool really failed). If the fact holds, keep `severity` and set `score` to
  100; otherwise drop the finding.
- Merge duplicates (same file and line, or the same defect worded twice):
  keep the higher severity and the better evidence, one entry.
- Never add new findings. Never change `file` or `line` except to correct an
  off-by-a-few line number after reading the file.

## Output

Return ONLY the JSON array of surviving findings with updated `score` (and
`severity` unchanged). No prose.
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `bash tests/test-agents.sh` — expected all pass.

- [ ] **Step 6: Commit**

```bash
git add agents/ tests/test-agents.sh
git commit -m "Add go-review agent definitions"
```

---

### Task 15: Install, end-to-end acceptance on fixtures, README

**Files:**
- Create: `README.md`, `tests/test-e2e-checklist.md` (manual acceptance record)
- Modify: none

**Interfaces:**
- Consumes: everything above.
- Produces: the skill installed in the real `~/.claude`, and a recorded acceptance run on both fixtures.

- [ ] **Step 1: Run the full automated suite**

Run: `bash tests/run.sh`
Expected: every file prints `N passed, 0 failed`, exit 0.

- [ ] **Step 2: Install for real**

Run: `bash install.sh && ls -la ~/.claude/skills/go-review ~/.claude/agents/go-review-*.md`
Expected: symlinks pointing into this repo. Restart Claude Code (or start a new session) so the skill and agents are picked up.

- [ ] **Step 3: Generate fixtures into the scratchpad**

Run: `bash fixtures/make-fixtures.sh "$TMPDIR/go-review-fx"` (any dir outside this repo).

- [ ] **Step 4: Acceptance run on `dirty`**

In a new Claude Code session with cwd `$TMPDIR/go-review-fx/dirty`, run `/go-review --base main`. Record in `tests/test-e2e-checklist.md`:

```markdown
# End-to-end acceptance (manual)

Date: <fill>   Commit: <fill>

## dirty (expect REQUEST CHANGES)
- [ ] Tools line shows test FAIL / race FAIL
- [ ] BLOCKER: data race in internal/counter/counter.go (tools or correctness)
- [ ] BLOCKER or MAJOR: swallowed error internal/service/order.go (return nil, nil)
- [ ] BLOCKER: SQL concatenation internal/repo/order_repo.go (security)
- [ ] MAJOR: handler calls repository directly internal/handler/order_handler.go (architecture)
- [ ] BLOCKER: substantive change, no spec (sdd-tdd) with nearest candidates = none
- [ ] MAJOR: TestPlaceOrder has no assertion (sdd-tdd)
- [ ] Verdict: REQUEST CHANGES
- [ ] Last line: No artifacts left: verified
- [ ] `git -C dirty status --porcelain` is empty after the run

## clean (expect APPROVE or APPROVE WITH COMMENTS)
- [ ] No BLOCKER, no MAJOR
- [ ] SDD block: spec + plan found, rubric 10/10, matrix AC1-AC3 all mapped to TestPlaceOrder subtests
- [ ] Last line: No artifacts left: verified
- [ ] `git -C clean status --porcelain` is empty after the run

## Notes / false positives seen
<fill>
```

Tick each box from the actual output. Any unticked box is a defect: fix the responsible checklist, agent, or script, add or adjust a test where a script is at fault, and rerun.

- [ ] **Step 5: Acceptance run on `clean`**

Same as step 4 with cwd `$TMPDIR/go-review-fx/clean`. Tick the clean section.

- [ ] **Step 6: Write `README.md`**

```markdown
# go-review

High-standard code review skill for Go backends, for Claude Code.

    /go-review [target] [--base <ref>] [--comment] [--no-tools] [--full-tests] [--spec <path>] [--skip-sdd "<reason>"]

Reviews a local diff, a branch, or a GitLab MR. Runs build, vet,
golangci-lint, `go test -race`, and govulncheck as evidence; dispatches
read-only specialist agents for correctness and concurrency, security,
architecture, performance and reliability, and spec/test-driven compliance;
verifies findings; prints an English report with a verdict; optionally posts
to the MR. Leaves the reviewed repo untouched and proves it.

## Install

    git clone <this repo> ~/Projects/personal/go-review
    cd ~/Projects/personal/go-review && bash install.sh

Optional tools: `brew install golangci-lint glab`,
`go install golang.org/x/vuln/cmd/govulncheck@latest`,
`glab auth login --hostname <your-gitlab-host>`.

## Layout

- `skill/` — SKILL.md, references (checklists, rubric, report format), scripts
- `agents/` — six read-only agent definitions
- `tests/` — `bash tests/run.sh`
- `fixtures/` — `make-fixtures.sh <outdir>` generates throwaway repos for testing
- `docs/superpowers/` — design spec and implementation plan

## Tuning the standard

Edit `skill/references/checklist-*.md` to change what is flagged, and
`skill/references/severity-verdict.md` to change severities and thresholds.
Changes take effect on the next run; no reinstall needed.
```

- [ ] **Step 7: Commit**

```bash
git add README.md tests/test-e2e-checklist.md
git commit -m "Add README and end-to-end acceptance record"
```
