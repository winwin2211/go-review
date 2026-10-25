#!/usr/bin/env bash
# Verify the reviewed repo is unchanged after a go-review run.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
usage="usage: assert-clean.sh --repo R --out O [--worktree W]"
REPO="" OUT="" WT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) [[ $# -ge 2 ]] || die "$usage"; REPO=$2; shift 2 ;;
    --out) [[ $# -ge 2 ]] || die "$usage"; OUT=$2; shift 2 ;;
    --worktree) [[ $# -ge 2 ]] || die "$usage"; WT=$2; shift 2 ;;
    *) die "unknown arg: $1" ;;
  esac
done
[[ -n "$REPO" && -n "$OUT" ]] || die "$usage"
git -C "$REPO" rev-parse --show-toplevel >/dev/null 2>&1 || die "not a git working tree: $REPO"
[[ -f "$OUT/status-before.txt" && -f "$OUT/stash-before.txt" && -f "$OUT/status-ignored-before.txt" && -f "$OUT/mtime-marker" ]] ||
  die "missing baseline files in $OUT (expected status-before.txt, stash-before.txt, status-ignored-before.txt and mtime-marker)"

if [[ -n "$WT" ]]; then
  # $WT is composed by the orchestrator (in practice, an LLM) and must never
  # be trusted blindly: if it were ever equal to $REPO itself, `git worktree
  # remove` refuses ("is a main working tree") and a naive `rm -rf` fallback
  # would then delete the reviewed repository. Require both that $WT
  # resolves outside $REPO AND that it is actually a worktree git knows
  # about before touching it either way; otherwise die without removing
  # anything.
  assert_outside "$WT" "$REPO"
  wt_real=$(resolve_path "$WT")
  registered=$(git -C "$REPO" worktree list --porcelain |
    awk -v w="$wt_real" '$1 == "worktree" { p = $0; sub(/^worktree /, "", p); if (p == w) found = 1 } END { print (found ? 1 : 0) }')
  if [[ "$registered" != "1" ]]; then
    # A path that doesn't exist and was never registered is a benign no-op
    # (e.g. an MR run that bailed before creating the worktree): prune any
    # stale registration and fall through to the clean check instead of
    # dying. A path that exists but isn't a registered worktree is still a
    # hard error -- never touch or trust it.
    [[ -e "$WT" ]] && die "refusing to remove unregistered worktree path: $WT"
    git -C "$REPO" worktree prune
  else
    if [[ -d "$WT" ]]; then
      git -C "$REPO" worktree remove --force "$WT" || rm -rf "$WT"
    fi
    git -C "$REPO" worktree prune
  fi
fi

rc=0
diff "$OUT/status-before.txt" <(git -C "$REPO" status --porcelain) > "$OUT/status-diff.txt" || rc=2
diff "$OUT/stash-before.txt" <(git -C "$REPO" stash list) > "$OUT/stash-diff.txt" || rc=2
diff "$OUT/status-ignored-before.txt" <(git -C "$REPO" status --porcelain --ignored) > "$OUT/status-ignored-diff.txt" || rc=2
# Files written after collect.sh's start marker. This is what catches writes
# `git status` cannot distinguish from the baseline: an already-modified file
# rewritten, or a new file inside a directory that was already untracked or
# ignored. .git is pruned: index and ref updates by git itself are not
# artifacts. ASSERT_CLEAN_PRUNE (colon-separated directory basenames, default
# none) prunes more: sibling skills name tool-cache directories such as
# node_modules there.
repo_real=$(cd "$REPO" && pwd -P)
prune=(-name .git)
IFS=: read -r -a extra <<<"${ASSERT_CLEAN_PRUNE:-}"
for d in "${extra[@]:-}"; do [[ -n "$d" ]] && prune+=(-o -name "$d"); done
find "$repo_real" \( "${prune[@]}" \) -prune -o \( -type f -o -type l \) -newer "$OUT/mtime-marker" -print 2>/dev/null |
  awk -v p="$repo_real/" 'index($0, p) == 1 { print substr($0, length(p) + 1) }' | sort > "$OUT/mtime-diff.txt"
[[ -s "$OUT/mtime-diff.txt" ]] && rc=2
if [[ $rc -eq 0 ]]; then echo "No artifacts left: verified"; exit 0; fi
{
  echo "THE REVIEWED REPO CHANGED DURING THE RUN."
  echo "The repo's own test suite is the most likely cause. These paths need checking by hand:"
  cat "$OUT/status-diff.txt" "$OUT/stash-diff.txt" "$OUT/status-ignored-diff.txt"
  if [[ -s "$OUT/mtime-diff.txt" ]]; then
    echo "Written after the run started (mtime newer than the start marker):"
    cat "$OUT/mtime-diff.txt"
  fi
} >&2
exit 2
