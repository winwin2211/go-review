#!/usr/bin/env bash
# Verify the reviewed repo is unchanged after a go-review run.
#
# Exit 0: unchanged (prints the verified line). 1: the check could not run,
# or could not read every directory and found nothing else. 2: git status,
# the ignored status or the stash list changed. 3: only the mtime scan found
# writes, which git cannot attribute to anyone.
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

# Checked after the worktree is gone: a collect that died before taking the
# baselines must not also leave the worktree registered in the repo.
[[ -f "$OUT/status-before.txt" && -f "$OUT/stash-before.txt" && -f "$OUT/status-ignored-before.txt" && -f "$OUT/mtime-marker" ]] ||
  die "missing baseline files in $OUT (expected status-before.txt, stash-before.txt, status-ignored-before.txt and mtime-marker)"

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
# node_modules there. Who wrote these files is unknown: the repo's tests, the
# user's editor, or a process running from the repo (a service's log, an IDE's
# settings) all look the same. Alone they exit 3, never 2, so they reach the
# user as writes to check, not as artifacts to remove. Only writes up to now
# count, so a file whose mtime lies in the future (a skewed copy, an archive's
# timestamps) is not reported on every run. A directory find cannot read
# makes the scan incomplete; a file that vanished during it does not.
repo_real=$(cd "$REPO" && pwd -P)
prune=(-name .git)
IFS=: read -r -a extra <<<"${ASSERT_CLEAN_PRUNE:-}"
for d in "${extra[@]:-}"; do [[ -n "$d" ]] && prune+=(-o -name "$d"); done
touch "$OUT/mtime-now"
{ find "$repo_real" \( "${prune[@]}" \) -prune -o \( -type f -o -type l \) \
    -newer "$OUT/mtime-marker" ! -newer "$OUT/mtime-now" -print 2>"$OUT/mtime-find-errors.txt" || true; } |
  awk -v p="$repo_real/" 'index($0, p) == 1 { print substr($0, length(p) + 1) }' | sort > "$OUT/mtime-diff.txt"
grep -v 'No such file or directory' "$OUT/mtime-find-errors.txt" > "$OUT/mtime-unscanned.txt" || true
unscanned() {
  [[ -s "$OUT/mtime-unscanned.txt" ]] || return 0
  echo "Not scanned for writes (find could not read these):"
  cat "$OUT/mtime-unscanned.txt"
}
if [[ $rc -eq 0 && ! -s "$OUT/mtime-diff.txt" ]]; then
  [[ -s "$OUT/mtime-unscanned.txt" ]] &&
    die "could not scan every directory for files written during the run, so the check is incomplete: $(head -3 "$OUT/mtime-unscanned.txt" | tr '\n' ' ')"
  echo "No artifacts left: verified"; exit 0
fi
writers="the repo's own tests, your editor, or a process running from the repo (logs, IDE settings, local data)"
{
  if [[ $rc -eq 2 ]]; then
    echo "THE REVIEWED REPO CHANGED DURING THE RUN."
    echo "The repo's own test suite is the most likely cause. These paths need checking by hand:"
    cat "$OUT/status-diff.txt" "$OUT/stash-diff.txt" "$OUT/status-ignored-diff.txt"
    if [[ -s "$OUT/mtime-diff.txt" ]]; then
      echo "Also written after the run started (mtime newer than the start marker); git status cannot tell who wrote these: $writers:"
      cat "$OUT/mtime-diff.txt"
    fi
  else
    echo "FILES IN THE REVIEWED REPO WERE WRITTEN DURING THE RUN."
    echo "git status is unchanged, so this check cannot tell who wrote them: $writers. Check them before removing anything:"
    cat "$OUT/mtime-diff.txt"
  fi
  unscanned
} >&2
[[ $rc -eq 2 ]] && exit 2
exit 3
