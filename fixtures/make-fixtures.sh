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
	"strings"
	"testing"
)

type fakeSaver struct {
	err   error
	calls int
}

func (f *fakeSaver) Save(context.Context, Order) error { f.calls++; return f.err }

func TestPlaceOrder(t *testing.T) {
	boom := errors.New("boom")
	cases := []struct {
		name      string
		order     Order
		saveErr   error
		wantErr   error
		wantCalls int
	}{
		{"success", Order{ID: "1", User: "u", Qty: 2}, nil, nil, 1},
		{"invalid qty", Order{ID: "1", User: "u", Qty: 0}, nil, ErrInvalidQty, 0},
		{"repo error", Order{ID: "42", User: "u", Qty: 1}, boom, boom, 1},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			fs := &fakeSaver{err: tc.saveErr}
			s := New(fs)
			got, err := s.PlaceOrder(context.Background(), tc.order)
			if !errors.Is(err, tc.wantErr) {
				t.Fatalf("err = %v, want %v", err, tc.wantErr)
			}
			if fs.calls != tc.wantCalls {
				t.Fatalf("Save calls = %d, want %d", fs.calls, tc.wantCalls)
			}
			if tc.wantErr == nil && (got == nil || *got != tc.order) {
				t.Fatalf("got = %+v, want %+v", got, tc.order)
			}
			if tc.saveErr != nil && !strings.Contains(err.Error(), tc.order.ID) {
				t.Fatalf("error %q does not mention order id %s", err, tc.order.ID)
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

- [x] Task 1: Write failing table test `TestPlaceOrder` (success, invalid qty, repo error; asserts Save call count and wrapped error mentions the order id)
- [x] Task 2: Implement `OrderService.PlaceOrder` and `ErrInvalidQty`
- [x] Task 3: Run `go test -race ./...`
EOF
commit_all "$C" "XBI-100 add order placement service"
echo "fixtures written to $OUT"
