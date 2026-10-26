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

# every references/x.md (section(s) "Heading"[, "Heading2", ...]) citation in
# workflow.md must resolve, with or without backticks around the path, and
# whether it names one section or several
while read -r l; do
  p=$(grep -oE 'references/[a-z-]+\.md' <<<"$l" | head -1)
  while read -r h; do
    [[ -z "$h" ]] && continue
    grep -q "^## .*$h\$" "$SK/$p" && pass || fail "heading '$h' missing in $p"
  done < <(grep -oE '"[^"]+"' <<<"$l" | tr -d '"')
done < <(grep -oE '`?references/[a-z-]+\.md`? *\(sections? "[^"]+"(, *"[^"]+")*\)' "$SK/references/workflow.md")

# all six agents are named in the workflow
for a in correctness security architecture performance sdd-tdd verifier; do
  grep -q "go-review-$a" "$SK/references/workflow.md" && pass || fail "workflow names agent $a"
done

# assert-clean exit 3 (writes git status cannot attribute: the user's editor,
# a service's log) is reported as such, never as files to remove
exit3=$(awk '/assert-clean.sh` exits 3/,/^$/' "$SK/references/workflow.md")
assert_contains "$exit3" "WRITTEN DURING THE RUN" "workflow.md gives assert-clean exit 3 its own heading"
assert_contains "$exit3" "never tell the user to remove them" "workflow.md never has the user remove unattributed writes"
grep -qF 'exits 3 instead of 2' "$SK/references/tooling.md" && pass || fail "tooling.md explains when assert-clean exits 3"
exit1=$(awk '/assert-clean.sh` exits 1/,/^$/' "$SK/references/workflow.md")
assert_contains "$exit1" "could not read" "workflow.md names an unreadable directory as an assert-clean exit 1"
grep -qF 'Not scanned' "$SK/references/workflow.md" && pass || fail "workflow.md says the Not scanned lines are not files to remove"
grep -qF 'cannot read' "$SK/references/tooling.md" && pass || fail "tooling.md explains what an unreadable directory does to the scan"
grep -qF 'later than the check' "$SK/references/tooling.md" && pass || fail "tooling.md says future mtimes are not counted"

# SKILL.md frontmatter
head -1 "$SK/SKILL.md" | grep -q '^---$' && pass || fail "frontmatter start"
grep -q '^name: go-review$' "$SK/SKILL.md" && pass || fail "name"
grep -q '^description:' "$SK/SKILL.md" && pass || fail "description"
finish
