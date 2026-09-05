#!/usr/bin/env bash
# List spec/plan candidates for a change under the three supported conventions.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

REPO="" OUT="" BASE="" HEAD="" BRANCH="" TITLE="" SPEC=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) REPO=$2; shift 2 ;; --out) OUT=$2; shift 2 ;; --base) BASE=$2; shift 2 ;;
    --head) HEAD=$2; shift 2 ;; --branch) BRANCH=$2; shift 2 ;; --title) TITLE=$2; shift 2 ;;
    --spec) SPEC=$2; shift 2 ;; *) die "unknown arg: $1" ;;
  esac
done
[[ -n "$REPO" && -n "$OUT" ]] || die "usage: find-specs.sh --repo R --out O [--base B] [--head H] [--branch N] [--title T] [--spec P]"
REPO=$(cd "$REPO" && pwd -P); assert_outside "$OUT" "$REPO"; mkdir -p "$OUT"

if [[ -n "$SPEC" ]]; then
  printf '%s\tforced\tforced\n' "$SPEC" > "$OUT/specs.tsv"; printf '%s\n' "$SPEC" > "$OUT/specs-all.txt"; exit 0
fi

# --- candidates: path<TAB>convention ---
cands=$(
  cd "$REPO"
  [[ -d docs/superpowers ]] && find docs/superpowers/specs docs/superpowers/plans -name '*.md' 2>/dev/null | sed 's/$/\tsuperpowers/'
  [[ -d openspec ]] && find openspec -name '*.md' 2>/dev/null | sed 's/$/\topenspec/'
  [[ -d docs ]] && find docs -name '*.md' -not -path 'docs/superpowers/*' 2>/dev/null | grep -viE '(^|/)readme\.md$' | sed 's/$/\tdocs/'
  true
) || true
printf '%s\n' "$cands" | awk -F'\t' 'NF { print $1 }' | sort -u > "$OUT/specs-all.txt"

# --- signals ---
tickets=$(printf '%s\n%s\n' "$BRANCH" "$TITLE" | grep -oE '[A-Z][A-Z0-9]+-[0-9]+' | sort -u || true)
btoks=$(printf '%s\n' "$BRANCH" | tr '/_-' '\n\n\n' | grep -vE '^(feature|fix|hotfix|bugfix|release|chore)$' | awk 'length($0) >= 4' | tr 'A-Z' 'a-z' | sort -u || true)
ttoks=$(printf '%s\n' "$TITLE" | tr -c 'A-Za-z0-9\n' '\n' | awk 'length($0) >= 4' | tr 'A-Z' 'a-z' | grep -vE '^(with|from|that|this|into|when|then|the|and|for)$' | sort -u || true)
pkgs=""
[[ -f "$OUT/changed-packages.txt" ]] && pkgs=$(sed 's#.*/##' "$OUT/changed-packages.txt" | tr 'A-Z' 'a-z' | sort -u)
logged=""
if [[ -n "$BASE" ]]; then
  h=HEAD; [[ -n "$HEAD" && "$HEAD" != "WORKTREE" ]] && h=$HEAD
  logged=$( { git -C "$REPO" log --name-only --format= "$BASE..$h" -- docs openspec 2>/dev/null; [[ "$HEAD" == "WORKTREE" ]] && git -C "$REPO" status --porcelain --untracked-files=all -- docs openspec | awk '{ print $2 }'; } | sort -u || true)
fi

: > "$OUT/specs.tsv.unsorted"
printf '%s\n' "$cands" | awk -F'\t' 'NF' | while IFS=$'\t' read -r path conv; do
  sig=""
  body=$(tr 'A-Z' 'a-z' < "$REPO/$path" 2>/dev/null || true)
  lpath=$(printf '%s' "$path" | tr 'A-Z' 'a-z')
  for k in $tickets; do lk=$(printf '%s' "$k" | tr 'A-Z' 'a-z'); [[ "$lpath" == *"$lk"* || "$body" == *"$lk"* ]] && sig="$sig,ticket:$k"; done
  for k in $btoks; do [[ "$lpath" == *"$k"* ]] && sig="$sig,branch:$k"; done
  for k in $ttoks; do [[ "$lpath" == *"$k"* ]] && sig="$sig,title:$k"; done
  for k in $pkgs; do [[ "$body" == *"$k"* ]] && sig="$sig,package:$k"; done
  printf '%s\n' "$logged" | grep -qxF "$path" && sig="$sig,git-log"
  if [[ -n "$sig" ]]; then printf '%s\t%s\t%s\n' "$path" "$conv" "${sig#,}" >> "$OUT/specs.tsv.unsorted"; fi
done
awk -F'\t' '{ n = split($3, a, ","); print n "\t" $0 }' "$OUT/specs.tsv.unsorted" | sort -t$'\t' -k1,1nr -k2,2 | cut -f2- > "$OUT/specs.tsv"
rm -f "$OUT/specs.tsv.unsorted"
