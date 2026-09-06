#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
SK="$REPO_ROOT/skill"
assert_file "$SK/SKILL.md" "SKILL.md exists"
assert_file "$SK/references/workflow.md" "workflow.md exists"

# every `references/...` or `scripts/...` path in backticks must exist
for f in "$SK/SKILL.md" "$SK/references/workflow.md"; do
  while read -r p; do
    [[ -e "$SK/$p" ]] && pass || fail "$(basename "$f") references missing path $p"
  done < <(grep -oE '`(references|scripts)/[A-Za-z0-9_./-]+`' "$f" | tr -d '`' | sort -u)
done

# every `references/x.md` (section "Heading") link in workflow.md must resolve
while read -r l; do
  p=$(sed -E 's/`(references[^`]+)`.*/\1/' <<<"$l"); h=$(sed -E 's/.*section "([^"]+)".*/\1/' <<<"$l")
  grep -q "^## .*$h\$" "$SK/$p" && pass || fail "heading '$h' missing in $p"
done < <(grep -oE '`references/[a-z-]+\.md` *\(section "[^"]+"\)' "$SK/references/workflow.md")

# all six agents are named in the workflow
for a in correctness security architecture performance sdd-tdd verifier; do
  grep -q "go-review-$a" "$SK/references/workflow.md" && pass || fail "workflow names agent $a"
done

# SKILL.md frontmatter
head -1 "$SK/SKILL.md" | grep -q '^---$' && pass || fail "frontmatter start"
grep -q '^name: go-review$' "$SK/SKILL.md" && pass || fail "name"
grep -q '^description:' "$SK/SKILL.md" && pass || fail "description"
finish
