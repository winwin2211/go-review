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
MARKER="<!-- ${REVIEW_TOOL}:$SHA -->"
BASE_EP="projects/$PROJ/merge_requests/$MR"

api_get() { glab api "$1"; }
api_post() { # endpoint json
  if [[ $DRY -eq 1 ]]; then printf 'DRY: POST %s %s\n' "$1" "$2"; else printf '%s' "$2" | glab api --method POST --input - "$1" >/dev/null; fi
}

# idempotency: paginate through notes (hard cap 50 pages) and die if a page fetch fails,
# rather than silently treating a failed GET as "not yet posted".
notes_page=1
already_posted=0
while [[ $notes_page -le 50 ]]; do
  notes=$(api_get "$BASE_EP/notes?per_page=100&page=$notes_page") || die "cannot list MR notes; refusing to post"
  if jq -e --arg m "$MARKER" 'map(select(.body | contains($m))) | length > 0' <<<"$notes" >/dev/null; then
    already_posted=1
    break
  fi
  note_count=$(jq 'length' <<<"$notes")
  [[ "$note_count" -lt 100 ]] && break
  notes_page=$((notes_page + 1))
done
if [[ $already_posted -eq 1 ]]; then
  echo "already posted for $SHA"; exit 0
fi

refs=$(api_get "$BASE_EP")
base_sha=$(jq -r .diff_refs.base_sha <<<"$refs"); start_sha=$(jq -r .diff_refs.start_sha <<<"$refs"); head_sha=$(jq -r .diff_refs.head_sha <<<"$refs")
paths=$(api_get "$BASE_EP/changes" | jq -r '.changes[].new_path')

# Inline only findings whose file is in the MR's changed paths AND have a
# usable (numeric, > 0) line: GitLab's discussions API rejects a position
# with new_line 0 (line: 0 is how the schema represents a finding with no
# single anchor line), so posting one there would just fail, and since the
# summary note is posted first, that failure would lose the inline comment
# while leaving "already posted" for any retry.
# Everything else — including line-0 findings on in-diff files — is folded
# into the summary's "Outside the diff" section instead.
is_inline='(.file as $f | $p | index($f)) and (((.line // 0)) > 0)'
inside=$(jq -c --argjson p "$(printf '%s\n' "$paths" | jq -R . | jq -s .)" "[.[] | select($is_inline)]" "$FINDINGS")
outside=$(jq -c --argjson p "$(printf '%s\n' "$paths" | jq -R . | jq -s .)" "[.[] | select(($is_inline) | not)]" "$FINDINGS")

body=$(printf '%s\n\n%s' "$MARKER" "$(cat "$SUMMARY")")
if [[ "$(jq length <<<"$outside")" -gt 0 ]]; then
  body="$body"$'\n\n### Outside the diff\n'"$(jq -r '.[] | "- **\(.severity) \(.id)** \(.title) — `\(.file)`: \(.why) Fix: \(.fix)"' <<<"$outside")"
fi
api_post "$BASE_EP/notes" "$(jq -nc --arg b "$body" '{body: $b}')"

# post inline discussions one by one; a failed POST is logged and counted, not fatal,
# since the summary note is already posted (avoid leaving a half-posted run silent).
ok=0
failed=0
while read -r f; do
  fid=$(jq -r '.id' <<<"$f")
  ffile=$(jq -r '.file' <<<"$f")
  fline=$(jq -r '.line' <<<"$f")
  note=$(jq -r '"**\(.severity) \(.id): \(.title)**\n\nEvidence: `\(.evidence)`\n\nWhy: \(.why)\n\nFix: \(.fix)" + (if ((.spec_ref // "") != "") then "\n\nSpec: \(.spec_ref)" else "" end)' <<<"$f")
  payload=$(jq -nc --arg b "$note" --arg p "$ffile" --argjson l "$fline" \
    --arg bs "$base_sha" --arg ss "$start_sha" --arg hs "$head_sha" \
    '{body: $b, position: {position_type: "text", new_path: $p, new_line: $l, base_sha: $bs, start_sha: $ss, head_sha: $hs}}')
  if api_post "$BASE_EP/discussions" "$payload"; then
    ok=$((ok + 1))
  else
    failed=$((failed + 1))
    log "failed to post discussion for $fid ($ffile:$fline)"
  fi
done < <(jq -c '.[]' <<<"$inside")

if [[ $failed -eq 0 ]]; then
  echo "posted summary + $ok inline discussions for $SHA"
else
  echo "posted summary + $ok inline discussions for $SHA; $failed failed (see stderr)"
fi
