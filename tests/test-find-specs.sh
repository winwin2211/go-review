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

# openspec + docs conventions, unmatched candidate still listed in specs-all.
# The "unrelated" ADR is committed on main and merged into the feature branch
# before any WORKTREE changes are made, so it is genuinely untouched by this
# change (clean in git status, absent from the main..HEAD log) -- unlike the
# openspec files below, which are added straight to the worktree, uncommitted.
git -C "$fx/dirty" checkout -q main
mkdir -p "$fx/dirty/docs/adr"
echo "# Unrelated ADR" > "$fx/dirty/docs/adr/001-logging.md"
git -C "$fx/dirty" add docs/adr/001-logging.md
git -C "$fx/dirty" commit -q -m "add unrelated adr"
git -C "$fx/dirty" checkout -q feature/XBI-100-orders
git -C "$fx/dirty" merge -q main -m "merge main into feature"
mkdir -p "$fx/dirty/openspec/changes/add-orders/specs/orders"
echo "# Proposal: XBI-100 orders" > "$fx/dirty/openspec/changes/add-orders/proposal.md"
echo "# Tasks" > "$fx/dirty/openspec/changes/add-orders/tasks.md"
echo "# orders spec" > "$fx/dirty/openspec/changes/add-orders/specs/orders/spec.md"
echo "# readme" > "$fx/dirty/docs/README.md"
mkdir -p "$out/o"
bash "$S/find-specs.sh" --repo "$fx/dirty" --out "$out/o" --base main --head WORKTREE --branch feature/XBI-100-orders --title "XBI-100 order listing"
t=$(cat "$out/o/specs.tsv")
assert_contains "$t" $'openspec/changes/add-orders/proposal.md\topenspec\t' "openspec proposal matched"
assert_contains "$t" "title:order" "title signal"
assert_contains "$t" $'openspec/changes/add-orders/proposal.md\topenspec\tticket:XBI-100,branch:orders,title:order,git-log' "untracked worktree file gets git-log signal"
assert_not_contains "$t" "docs/adr/001-logging.md" "unrelated adr not matched"
assert_contains "$(cat "$out/o/specs-all.txt")" "docs/adr/001-logging.md" "unrelated adr listed in all"
assert_not_contains "$(cat "$out/o/specs-all.txt")" "docs/README.md" "README excluded"
rm -rf "$fx/dirty/openspec" "$fx/dirty/docs"

# package basenames are lowercased before matching against the (lowercased) doc body
mkdir -p "$out/p"; echo "example.com/clean/internal/Service" > "$out/p/changed-packages.txt"
bash "$S/find-specs.sh" --repo "$fx/clean" --out "$out/p"
assert_contains "$(cat "$out/p/specs.tsv")" "package:service" "package signal lowercased"

# forced
mkdir -p "$out/f"
bash "$S/find-specs.sh" --repo "$fx/clean" --out "$out/f" --spec docs/superpowers/specs/2026-09-01-XBI-100-orders-design.md
assert_eq $'docs/superpowers/specs/2026-09-01-XBI-100-orders-design.md\tforced\tforced' "$(cat "$out/f/specs.tsv")" "forced row"
finish
