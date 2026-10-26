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
  "GET projects/"*"/merge_requests/7/notes"*)
    if [[ "${FAKE_GLAB_FAIL_NOTES:-0}" == "1" ]]; then exit 1; fi
    page=1
    case "$ep" in *page=*) page=$(printf '%s' "$ep" | sed -n 's/.*page=\([0-9]*\).*/\1/p') ;; esac
    if [[ -n "${FAKE_GLAB_NOTES_PAGE2:-}" ]]; then
      if [[ "$page" == "1" ]]; then jq -nc '[range(100) | {id: ., body: "dummy"}]'; else cat "$FAKE_GLAB_NOTES_PAGE2"; fi
    elif [[ "$page" == "1" ]]; then
      cat "${FAKE_GLAB_NOTES:-/dev/null}"; [[ -f "${FAKE_GLAB_NOTES:-}" ]] || echo '[]'
    else
      echo '[]'
    fi
    ;;
  "POST "*"/discussions")
    if [[ -n "${FAKE_GLAB_FAIL_DISCUSSION_PATH:-}" ]]; then
      stdin_body=$(cat)
      if printf '%s' "$stdin_body" | grep -q "$FAKE_GLAB_FAIL_DISCUSSION_PATH"; then exit 1; fi
    fi
    echo '{"id":1}'
    ;;
  "POST "*) echo '{"id":1}' ;;
  *) echo "unexpected: $method $ep" >&2; exit 1 ;;
esac
EOF
chmod +x "$w/bin/glab"
export PATH="$w/bin:$PATH" FAKE_GLAB_LOG="$w/calls.log"

cat > "$w/findings.json" <<'EOF'
[
 {"id":"B1","dimension":"correctness","severity":"BLOCKER","rule_based":false,"file":"internal/service/order.go","line":24,"title":"Error swallowed","evidence":"return nil, nil","why":"caller cannot distinguish failure","fix":"return the wrapped error","score":95},
 {"id":"M1","dimension":"sdd-tdd","severity":"MAJOR","rule_based":true,"file":"docs/missing.md","line":0,"title":"No plan","evidence":"","why":"substantive change without plan","fix":"add docs/superpowers/plans/...","spec_ref":"","score":100},
 {"id":"M2","dimension":"sdd-tdd","severity":"MAJOR","rule_based":true,"file":"go.mod","line":0,"title":"Dependency bump without plan","evidence":"","why":"substantive change without plan","fix":"add docs/superpowers/plans/...","spec_ref":"","score":100}
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
assert_contains "$out" "M2" "line-0 finding on an in-diff file (go.mod) is folded into the summary, not posted inline"
assert_not_contains "$out" '"new_line":0' "no discussion is ever attempted for a line-0 finding"
assert_not_contains "$out" "Spec: null" "a finding with no spec_ref does not render Spec: null"
assert_eq "1" "$(grep -c 'DRY: POST.*discussions' <<<"$out" || true)" "only the line>0, in-diff finding is posted inline"
assert_eq "0" "$(grep -c '^api --method POST' "$w/calls.log" || true)" "no real POST in dry run"

# the marker carries the skill's own name so a sibling skill's notes never
# collide with ours, even when the sibling's REVIEW_TOOL is in the environment
out=$(REVIEW_TOOL=nodejs-review bash "$S/gitlab-post.sh" --project group/repo --mr 7 --head-sha h1 --findings "$w/findings.json" --summary "$w/summary.md" --dry-run)
assert_contains "$out" "<!-- go-review:h1 -->" "marker uses the name in SKILL.md"
assert_not_contains "$out" "nodejs-review:h1" "an inherited REVIEW_TOOL does not change the marker"

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

# notes GET failure: refuse to post rather than treating it as "not yet posted"
: > "$w/calls.log"
export FAKE_GLAB_FAIL_NOTES=1
assert_exit 1 bash "$S/gitlab-post.sh" --project group/repo --mr 7 --head-sha h1 --findings "$w/findings.json" --summary "$w/summary.md"
unset FAKE_GLAB_FAIL_NOTES
assert_eq "0" "$(grep -c POST "$w/calls.log" || true)" "no POST when notes GET fails"

# notes pagination: marker only on page 2 must still be found
echo '[{"id":99,"body":"<!-- go-review:h1 -->\nfound on page 2"}]' > "$w/notes-page2.json"
: > "$w/calls.log"
out=$(FAKE_GLAB_NOTES_PAGE2="$w/notes-page2.json" bash "$S/gitlab-post.sh" --project group/repo --mr 7 --head-sha h1 --findings "$w/findings.json" --summary "$w/summary.md")
assert_contains "$out" "already posted for h1" "pagination: marker found on page 2"
assert_eq "0" "$(grep -c POST "$w/calls.log" || true)" "no POST when marker found via pagination"

# per-finding discussion failures: one bad discussion must not abort the rest
cat > "$w/findings2.json" <<'EOF'
[
 {"id":"B1","dimension":"correctness","severity":"BLOCKER","rule_based":false,"file":"internal/service/order.go","line":24,"title":"Error swallowed","evidence":"return nil, nil","why":"caller cannot distinguish failure","fix":"return the wrapped error","spec_ref":"","score":95},
 {"id":"B2","dimension":"correctness","severity":"MAJOR","rule_based":false,"file":"go.mod","line":3,"title":"Bad version pin","evidence":"go 1.20","why":"pinned too old","fix":"bump go directive","spec_ref":"","score":80}
]
EOF
: > "$w/calls.log"
export FAKE_GLAB_FAIL_DISCUSSION_PATH="go.mod"
out=$(bash "$S/gitlab-post.sh" --project group/repo --mr 7 --head-sha h1 --findings "$w/findings2.json" --summary "$w/summary.md")
rc=$?
unset FAKE_GLAB_FAIL_DISCUSSION_PATH
assert_eq "0" "$rc" "exits 0 even when a discussion POST fails"
assert_contains "$out" "1 failed" "final line reports the failed discussion count"
assert_eq "2" "$(grep -c 'merge_requests/7/discussions' <(grep POST "$w/calls.log") || true)" "both discussions were attempted"

finish
