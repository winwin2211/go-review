#!/usr/bin/env bash
# Collect diff, changed packages and tool evidence for go-review into an out dir.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
source "$HERE/lib.sh"

NOT_RUNNABLE_RE='connection refused|no such host|dial tcp|i/o timeout|connect: cannot|no route to host|environment variable .* not set|config file not found|open .*\.env: no such file'

# Per-tool budgets in seconds; override with GO_REVIEW_TIMEOUT_<TOOL>. go test
# gets its own -timeout so a hung test dies inside go with a goroutine dump (a
# FAIL with evidence) before the wrapper gives up and reports
# UNAVAILABLE(timeout). go's clock starts with each test binary, the wrapper's
# with go test, so the gap (a quarter of the budget, at least 10s) is what a
# hung binary may spend compiling, linking and waiting for a free slot.
T_BUILD=${GO_REVIEW_TIMEOUT_BUILD:-180}
T_VET=${GO_REVIEW_TIMEOUT_VET:-180}
T_LINT=${GO_REVIEW_TIMEOUT_LINT:-300}
T_TEST=${GO_REVIEW_TIMEOUT_TEST:-600}
T_VULN=${GO_REVIEW_TIMEOUT_VULN:-180}
GO_TEST_MARGIN=$((T_TEST / 4)); [[ $GO_TEST_MARGIN -lt 10 ]] && GO_TEST_MARGIN=10
GO_TEST_TIMEOUT=$((T_TEST - GO_TEST_MARGIN)); [[ $GO_TEST_TIMEOUT -lt 1 ]] && GO_TEST_TIMEOUT=1

# classify_tests TESTFILE -> lines "pkg<TAB>OK|FAIL|NOT_RUNNABLE|NO_TESTS"
#
# A failing package is NOT_RUNNABLE only when every failing test in it ended
# on an environment error. Each `--- FAIL:` block (any nesting) is judged by
# its last message (`file.go:N: ...` plus continuation lines): environment
# text there excuses that test; an assertion there makes the package FAIL
# even if an earlier line logged a connection error. A panic counts as the last
# message of its test (or of TestMain, outside any test): a connect helper's
# panic(err) with no database is an environment ending, any other panic (a nil
# dereference, go's own test timeout) is FAIL. A package with no `--- FAIL:`
# block at all (TestMain exited) is judged by any environment line in its
# output.
classify_tests() {
  awk -v re="$NOT_RUNNABLE_RE" '
    function finish_block() {
      if (in_block && has_msg) { if (last_env) pkg_env = 1; else pkg_fail = 1 }
      in_block = 0; has_msg = 0; last_env = 0
    }
    function reset_pkg() { finish_block(); pkg_fail = 0; pkg_env = 0; any_env = 0 }
    /^ok[ \t]/ { reset_pkg(); print $2 "\tOK"; next }
    /^\?[ \t]/ { reset_pkg(); print $2 "\tNO_TESTS"; next }
    /^FAIL[ \t]+[^ \t]+[ \t]/ {
      finish_block()
      st = pkg_fail ? "FAIL" : ((pkg_env || any_env) ? "NOT_RUNNABLE" : "FAIL")
      print $2 "\t" st; reset_pkg(); next
    }
    /^[ \t]*--- FAIL: / { finish_block(); in_block = 1; next }
    /^[ \t]*--- (PASS|SKIP): / || /^=== / || /^(FAIL|PASS)$/ { finish_block(); next }
    /^panic: / {
      env = ($0 ~ re)
      if (in_block) { has_msg = 1; last_env = env; finish_block() }
      else if (env) pkg_env = 1
      else pkg_fail = 1
      next
    }
    in_block && /^[ \t]+[^ \t]+\.go:[0-9]+: / { has_msg = 1; last_env = ($0 ~ re); next }
    in_block { if ($0 ~ re) last_env = 1; next }
    { if ($0 ~ re) any_env = 1 }
  ' "$1"
}

if [[ "${1:-}" == "--classify-only" ]]; then classify_tests "$2"; exit 0; fi

REPO="" BASE="" HEAD="" OUT="" STATUS_REPO="" NO_TOOLS=0 FULL_TESTS=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) REPO=$2; shift 2 ;;
    --base) BASE=$2; shift 2 ;;
    --head) HEAD=$2; shift 2 ;;
    --out) OUT=$2; shift 2 ;;
    --status-repo) STATUS_REPO=$2; shift 2 ;;
    --no-tools) NO_TOOLS=1; shift ;;
    --full-tests) FULL_TESTS=1; shift ;;
    *) die "unknown arg: $1" ;;
  esac
done
[[ -n "$REPO" && -n "$OUT" && -n "$HEAD" ]] || die "usage: collect.sh --repo R --base B --head H|WORKTREE --out O [--status-repo P] [--no-tools] [--full-tests]"
command -v go >/dev/null || die "go not found on PATH"
REPO=$(cd "$REPO" && pwd -P)
[[ -n "$STATUS_REPO" ]] || STATUS_REPO="$REPO"
STATUS_REPO=$(cd "$STATUS_REPO" && pwd -P)
[[ -n "$BASE" ]] || BASE=$(resolve_base "$REPO")
assert_outside "$OUT" "$REPO"
mkdir -p "$OUT/tools"
OUT=$(cd "$OUT" && pwd -P)

# Baseline snapshots for assert-clean.sh's no-artifact guarantee: taken as
# early as possible (before merge-base / diff / tool runs, any of which can
# fail on a bad --base) so a later failure never leaves the reviewed repo
# without a baseline to compare against. Taken against --status-repo (the
# working tree assert-clean.sh will later be run against), which defaults to
# --repo but differs from it in MR mode, where --repo is a throwaway worktree.
#
# mtime-marker goes first: at the end of the run assert-clean.sh lists every
# file under the repo with an mtime newer than it, which catches writes that
# leave `git status` unchanged (an already-modified file rewritten, a new file
# inside an untracked or ignored directory).
touch "$OUT/mtime-marker"
git -C "$STATUS_REPO" status --porcelain > "$OUT/status-before.txt"
git -C "$STATUS_REPO" status --porcelain --ignored > "$OUT/status-ignored-before.txt"
git -C "$STATUS_REPO" stash list > "$OUT/stash-before.txt"

if [[ "$HEAD" == "WORKTREE" ]]; then MODE=worktree; HEAD_SHA=$(git -C "$REPO" rev-parse HEAD)
else
  MODE=ref; HEAD_SHA=$(git -C "$REPO" rev-parse "$HEAD")
  actual_head=$(git -C "$REPO" rev-parse HEAD)
  [[ "$actual_head" == "$HEAD_SHA" ]] || log "checked-out HEAD $actual_head differs from --head $HEAD_SHA; tools run against the checkout"
fi
MB=$(merge_base "$REPO" "$BASE" "$HEAD_SHA")

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

# non-test added+removed lines: only .go files that are not _test.go. An
# untracked file is diffed as `a//dev/null` vs `b/<path>` (--no-index), so
# the real path is $4, not $3, in that case.
awk '
  /^diff --git/ {
    a = $3; b = $4;
    path = (a == "a//dev/null") ? b : a;
    sub(/^[ab]\//, "", path);
    is_go = (path ~ /\.go$/);
    is_test = (path ~ /_test\.go$/);
    count_this = (is_go && !is_test);
  }
  /^[+-]/ && !/^(\+\+\+|---)/ { if (count_this) n++ }
  END { print n+0 }
' "$OUT/diff.patch" > "$OUT/nontest-lines.txt"

# --- module detection ---
# module_dir_for FILE -> prints the absolute dir of the nearest ancestor
# go.mod for FILE (a path relative to REPO), or nothing if none is found.
module_dir_for() {
  local f=$1 d
  d=$(dirname "$f")
  while :; do
    if [[ -f "$REPO/$d/go.mod" ]]; then echo "$REPO/$d"; return; fi
    [[ "$d" == "." ]] && return
    d=$(dirname "$d")
  done
}

MODULE_DIR=""
MODULE=""
NO_MODULE_DETAIL="no go.mod"
if [[ -f "$REPO/go.mod" ]]; then
  MODULE_DIR="$REPO"
  MODULE=$( (cd "$MODULE_DIR" && go list -m 2>/dev/null | head -1) || true )
else
  mod_dirs=""
  if [[ -s "$OUT/changed-go-files.txt" ]]; then
    mod_dirs=$(while read -r f; do module_dir_for "$f"; done < "$OUT/changed-go-files.txt" | sort -u)
  fi
  n_mods=$(printf '%s' "$mod_dirs" | grep -c . || true)
  if [[ "$n_mods" -eq 1 ]]; then
    MODULE_DIR=$(printf '%s' "$mod_dirs")
    MODULE=$( (cd "$MODULE_DIR" && go list -m 2>/dev/null | head -1) || true )
  fi
  NO_MODULE_DETAIL="no go.mod at repo root; changed files span $n_mods modules"
fi
if [[ -n "$MODULE_DIR" && "$MODULE_DIR" != "$REPO" ]]; then
  MODULE_REL=${MODULE_DIR#"$REPO"/}
else
  MODULE_REL=""
fi

{
  echo "REPO=$REPO"; echo "BASE=$BASE"; echo "HEAD=$HEAD"; echo "HEAD_SHA=$HEAD_SHA"
  echo "MERGE_BASE=$MB"; echo "MODE=$MODE"; echo "MODULE=$MODULE"; echo "MODULE_DIR=$MODULE_DIR"
} > "$OUT/meta.env"

# --- packages ---
: > "$OUT/changed-packages.txt"
if [[ -n "$MODULE" && -s "$OUT/changed-go-files.txt" ]]; then
  while read -r f; do dirname "$f"; done < "$OUT/changed-go-files.txt" | sort -u | while read -r d; do
    if [[ -n "$MODULE_REL" ]]; then
      case "$d" in
        "$MODULE_REL") d="." ;;
        "$MODULE_REL"/*) d=${d#"$MODULE_REL"/} ;;
        *) continue ;;
      esac
    fi
    [[ -d "$MODULE_DIR/$d" ]] || continue
    if [[ "$d" == "." ]]; then p="."; else p="./$d"; fi
    (cd "$MODULE_DIR" && go list "$p" 2>/dev/null) || true
  done | sort -u > "$OUT/changed-packages.txt"
fi
if [[ $FULL_TESTS -eq 1 ]]; then
  echo "./..." > "$OUT/test-packages.txt"
elif [[ -s "$OUT/changed-packages.txt" ]]; then
  # Test-only importers (integration-test packages, external _test packages)
  # exercise the changed code too, so include .TestImports and .XTestImports.
  (cd "$MODULE_DIR" && go list -f '{{.ImportPath}}{{range .Imports}} {{.}}{{end}}{{range .TestImports}} {{.}}{{end}}{{range .XTestImports}} {{.}}{{end}}' ./... 2>/dev/null) > "$OUT/tools/import-graph.txt" || true
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
[[ -n "$MODULE" ]] || { for t in build vet lint test vuln; do summary "$t" "UNAVAILABLE(no-module)" "$NO_MODULE_DETAIL"; done; exit 0; }

# perl backs run_with_timeout (lib.sh), used only by the tool runs below; not
# needed for --no-tools or --classify-only, and not needed for the go list -m
# module detection above, so it's checked here rather than up front.
command -v perl >/dev/null || die "perl not found on PATH"

cd "$MODULE_DIR"
st=$(run_with_timeout "$T_BUILD" "$OUT/tools/build.txt" go build -o "$OUT/bin/" ./...)
case $st in
  TIMEOUT) summary build "UNAVAILABLE(timeout)" "${T_BUILD}s" ;;
  MISSING) summary build "UNAVAILABLE(missing)" "go not found" ;;
  *) summary build "$st" "$(grep -c . "$OUT/tools/build.txt" || true) lines" ;;
esac

st=$(run_with_timeout "$T_VET" "$OUT/tools/vet.txt" go vet ./...)
case $st in
  TIMEOUT) summary vet "UNAVAILABLE(timeout)" "${T_VET}s" ;;
  MISSING) summary vet "UNAVAILABLE(missing)" "go not found" ;;
  *) summary vet "$st" "$(grep -c . "$OUT/tools/vet.txt" || true) lines" ;;
esac

if command -v golangci-lint >/dev/null; then
  if [[ -f .golangci.yml || -f .golangci.yaml || -f .golangci.toml || -f .golangci.json ]]; then
    st=$(run_with_timeout "$T_LINT" "$OUT/tools/lint.txt" golangci-lint run --new-from-rev "$MB" ./...)
  else
    st=$(run_with_timeout "$T_LINT" "$OUT/tools/lint.txt" golangci-lint run -c "$HERE/golangci-strict.yml" --new-from-rev "$MB" ./...)
  fi
  n=$(grep -cE '^[^ ]+\.go:[0-9]+:[0-9]+:' "$OUT/tools/lint.txt" || true)
  case $st in
    TIMEOUT) summary lint "UNAVAILABLE(timeout)" "${T_LINT}s" ;;
    MISSING) summary lint "UNAVAILABLE(missing)" "golangci-lint not found" ;;
    OK) summary lint OK "0 new" ;;
    *) summary lint FAIL "$n new" ;;
  esac
else
  summary lint "UNAVAILABLE(missing)" "brew install golangci-lint"
fi

if [[ -s "$OUT/test-packages.txt" ]]; then
  # shellcheck disable=SC2046
  st=$(run_with_timeout "$T_TEST" "$OUT/tools/test.txt" go test -short -race -count=1 -timeout "${GO_TEST_TIMEOUT}s" -coverprofile="$OUT/tools/cover.out" $(cat "$OUT/test-packages.txt"))
  classify_tests "$OUT/tools/test.txt" > "$OUT/tools/test-classified.txt"
  if [[ -f "$OUT/tools/cover.out" ]]; then go tool cover -func="$OUT/tools/cover.out" > "$OUT/tools/cover.txt" 2>/dev/null || true; fi
  nf=$(grep -c $'\tFAIL$' "$OUT/tools/test-classified.txt" || true)
  nn=$(grep -c $'\tNOT_RUNNABLE$' "$OUT/tools/test-classified.txt" || true)
  if [[ $st == TIMEOUT ]]; then summary test "UNAVAILABLE(timeout)" "${T_TEST}s"
  elif [[ $st == MISSING ]]; then summary test "UNAVAILABLE(missing)" "go not found"
  elif [[ $nf -gt 0 ]]; then summary test FAIL "$nf failing, $nn not runnable locally"
  elif [[ $st == FAIL && $nn -eq 0 ]]; then
    # go test itself failed (non-zero exit) but no package was classified
    # FAIL or NOT_RUNNABLE at all -- a toolchain-level run error (e.g. a bad
    # -coverprofile path), not a test failure. A package that fails for an
    # environment reason is NOT_RUNNABLE, not this branch: see the nn check.
    firstline=$(head -1 "$OUT/tools/test.txt" 2>/dev/null | tr '\t' ' ' | cut -c1-200 || true)
    summary test "UNAVAILABLE(run-error)" "$firstline"
  else summary test OK "$nn not runnable locally"; fi
else
  summary test "UNAVAILABLE(no-changed-packages)" ""
fi

if command -v govulncheck >/dev/null; then
  st=$(run_with_timeout "$T_VULN" "$OUT/tools/vuln.txt" govulncheck ./...)
  case $st in
    TIMEOUT) summary vuln "UNAVAILABLE(timeout)" "${T_VULN}s" ;;
    MISSING) summary vuln "UNAVAILABLE(missing)" "govulncheck not found" ;;
    *) summary vuln "$st" "$(grep -c 'Vulnerability #' "$OUT/tools/vuln.txt" || true) found" ;;
  esac
else
  summary vuln "UNAVAILABLE(missing)" "go install golang.org/x/vuln/cmd/govulncheck@latest"
fi
