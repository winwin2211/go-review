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
