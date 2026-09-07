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
command -v go >/dev/null || die "go not found on PATH"
command -v perl >/dev/null || die "perl not found on PATH"
REPO=$(cd "$REPO" && pwd -P)
[[ -n "$BASE" ]] || BASE=$(resolve_base "$REPO")
assert_outside "$OUT" "$REPO"
mkdir -p "$OUT/tools"
OUT=$(cd "$OUT" && pwd -P)

# Baseline snapshots for assert-clean.sh's no-artifact guarantee: taken as
# early as possible (before merge-base / diff / tool runs, any of which can
# fail on a bad --base) so a later failure never leaves the reviewed repo
# without a baseline to compare against.
git -C "$REPO" status --porcelain > "$OUT/status-before.txt"
git -C "$REPO" status --porcelain --ignored > "$OUT/status-ignored-before.txt"
git -C "$REPO" stash list > "$OUT/stash-before.txt"

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
  (cd "$MODULE_DIR" && go list -f '{{.ImportPath}}{{range .Imports}} {{.}}{{end}}' ./... 2>/dev/null) > "$OUT/tools/import-graph.txt" || true
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

cd "$MODULE_DIR"
st=$(run_with_timeout 180 "$OUT/tools/build.txt" go build -o "$OUT/bin/" ./...)
case $st in
  TIMEOUT) summary build "UNAVAILABLE(timeout)" "180s" ;;
  MISSING) summary build "UNAVAILABLE(missing)" "go not found" ;;
  *) summary build "$st" "$(grep -c . "$OUT/tools/build.txt" || true) lines" ;;
esac

st=$(run_with_timeout 180 "$OUT/tools/vet.txt" go vet ./...)
case $st in
  TIMEOUT) summary vet "UNAVAILABLE(timeout)" "180s" ;;
  MISSING) summary vet "UNAVAILABLE(missing)" "go not found" ;;
  *) summary vet "$st" "$(grep -c . "$OUT/tools/vet.txt" || true) lines" ;;
esac

if command -v golangci-lint >/dev/null; then
  if [[ -f .golangci.yml || -f .golangci.yaml || -f .golangci.toml || -f .golangci.json ]]; then
    st=$(run_with_timeout 300 "$OUT/tools/lint.txt" golangci-lint run --new-from-rev "$MB" ./...)
  else
    st=$(run_with_timeout 300 "$OUT/tools/lint.txt" golangci-lint run -c "$HERE/golangci-strict.yml" --new-from-rev "$MB" ./...)
  fi
  n=$(grep -cE '^[^ ]+\.go:[0-9]+:[0-9]+:' "$OUT/tools/lint.txt" || true)
  case $st in
    TIMEOUT) summary lint "UNAVAILABLE(timeout)" "300s" ;;
    MISSING) summary lint "UNAVAILABLE(missing)" "golangci-lint not found" ;;
    OK) summary lint OK "0 new" ;;
    *) summary lint FAIL "$n new" ;;
  esac
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
  elif [[ $st == MISSING ]]; then summary test "UNAVAILABLE(missing)" "go not found"
  elif [[ $nf -gt 0 ]]; then summary test FAIL "$nf failing, $nn not runnable locally"
  elif [[ $st == FAIL ]]; then
    firstline=$(head -1 "$OUT/tools/test.txt" 2>/dev/null || true)
    summary test "UNAVAILABLE(run-error)" "$firstline"
  else summary test OK "$nn not runnable locally"; fi
else
  summary test "UNAVAILABLE(no-changed-packages)" ""
fi

if command -v govulncheck >/dev/null; then
  st=$(run_with_timeout 180 "$OUT/tools/vuln.txt" govulncheck ./...)
  case $st in
    TIMEOUT) summary vuln "UNAVAILABLE(timeout)" "180s" ;;
    MISSING) summary vuln "UNAVAILABLE(missing)" "govulncheck not found" ;;
    *) summary vuln "$st" "$(grep -c 'Vulnerability #' "$OUT/tools/vuln.txt" || true) found" ;;
  esac
else
  summary vuln "UNAVAILABLE(missing)" "go install golang.org/x/vuln/cmd/govulncheck@latest"
fi
