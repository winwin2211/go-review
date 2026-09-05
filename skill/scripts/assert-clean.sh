#!/usr/bin/env bash
# Verify the reviewed repo is unchanged after a go-review run.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
REPO="" OUT="" WT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) REPO=$2; shift 2 ;; --out) OUT=$2; shift 2 ;; --worktree) WT=$2; shift 2 ;;
    *) die "unknown arg: $1" ;;
  esac
done
[[ -n "$REPO" && -n "$OUT" ]] || die "usage: assert-clean.sh --repo R --out O [--worktree W]"
if [[ -n "$WT" && -d "$WT" ]]; then
  git -C "$REPO" worktree remove --force "$WT" || rm -rf "$WT"
fi
if [[ -n "$WT" ]]; then
  git -C "$REPO" worktree prune
fi
rc=0
diff "$OUT/status-before.txt" <(git -C "$REPO" status --porcelain) > "$OUT/status-diff.txt" || rc=2
diff "$OUT/stash-before.txt" <(git -C "$REPO" stash list) > "$OUT/stash-diff.txt" || rc=2
if [[ $rc -eq 0 ]]; then echo "No artifacts left: verified"; exit 0; fi
echo "ARTIFACTS LEFT IN REPO (bug in go-review, please report):" >&2
cat "$OUT/status-diff.txt" "$OUT/stash-diff.txt" >&2
exit 2
