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
