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
