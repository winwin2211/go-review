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
api_post "$BASE_EP/notes" "$(jq -nc --arg b "$body" '{body: $b}')"

jq -c '.[]' <<<"$inside" | while read -r f; do
  note=$(jq -r '"**\(.severity) \(.id): \(.title)**\n\nEvidence: `\(.evidence)`\n\nWhy: \(.why)\n\nFix: \(.fix)" + (if .spec_ref != "" then "\n\nSpec: \(.spec_ref)" else "" end)' <<<"$f")
  payload=$(jq -nc --arg b "$note" --arg p "$(jq -r .file <<<"$f")" --argjson l "$(jq -r .line <<<"$f")" \
    --arg bs "$base_sha" --arg ss "$start_sha" --arg hs "$head_sha" \
    '{body: $b, position: {position_type: "text", new_path: $p, new_line: $l, base_sha: $bs, start_sha: $ss, head_sha: $hs}}')
  api_post "$BASE_EP/discussions" "$payload"
done
echo "posted summary + $(jq length <<<"$inside") inline discussions for $SHA"
