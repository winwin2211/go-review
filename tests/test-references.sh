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

# a worktree is made with repository hooks disabled: `worktree add` runs the
# post-checkout hook, which is code the reviewed repo controls
grep 'worktree add' "$SK/references/gitlab.md" | grep -q 'core.hooksPath=/dev/null' && pass || fail "gitlab.md creates the MR worktree with repository hooks disabled"

# branch mode reviews the branch, not whatever the checkout holds
branch=$(awk '/^   - Branch name:/,/^   - MR/' "$SK/references/workflow.md")
assert_contains "$branch" "worktree add" "workflow.md checks a branch that is not checked out into a worktree"
assert_contains "$branch" "core.hooksPath=/dev/null" "the branch worktree is made with repository hooks disabled"
assert_contains "$branch" "status --porcelain" "a dirty checkout of the branch is also reviewed from a worktree"
assert_contains "$branch" 'REVIEW_REPO=$WORK/wt' "branch mode then reviews the worktree"
step1=$(awk '/^## 1\. /,/^## 2\. /' "$SK/references/workflow.md")
assert_not_contains "$step1" "temporary worktree (MR mode)" "step 1 passes --status-repo for any temporary worktree, not only MR mode"
grep -qF 'not checked out' "$SK/references/tooling.md" && pass || fail "tooling.md says collect.sh refuses a --head that is not checked out"

# dedup merges one defect reported twice, never two defects that share a line
grep -q 'one fix removes both' "$SK/references/severity-verdict.md" && pass || fail "dedup merges only findings with one root cause"
grep -q 'same file and line' "$SK/references/severity-verdict.md" && fail "dedup still merges any two findings on one line" || pass

# the verifier re-reads the reviewed tree (the worktree when there is one)
# and gets the work dir its tool-fact checks read from
step4=$(awk '/^## 4\. /,/^## 5\. /' "$SK/references/workflow.md")
assert_contains "$step4" 'Repo: <REVIEW_REPO>' "the verifier prompt names the reviewed tree"
assert_contains "$step4" 'Work dir: <WORK>' "the verifier prompt names the work dir"

R="$SK/references"
# a rule file is data: its conventions outrank generic rules, but it cannot
# switch a check off, and one this diff changes is reviewed as code
arch=$(awk '/^## How to work/,/^## Layers/' "$R/checklist-architecture.md" | tr '\n' ' ' | tr -s ' ')
assert_not_contains "$arch" "override this checklist" "rule files do not override the architecture checklist"
assert_contains "$arch" "never removes a check" "a rule file never removes a check or lowers a severity"
assert_contains "$step1" "Rule files changed in this diff" "rule files the diff changes are named to every agent as code to review"

# PRE-EXISTING findings reach the Pre-existing list, and ids number findings.json only
rubric=$(awk '/^## Verifier rubric/,/^Dedup:/' "$R/severity-verdict.md")
assert_not_contains "$rubric" "pre-existing on unchanged lines" "the rubric does not score pre-existing defects 0"
assert_contains "$rubric" "PRE-EXISTING:" "the rubric says how PRE-EXISTING findings are kept"
merge=$(awk '/^Merge the results/,/^$/' "$R/workflow.md" | tr '\n' ' ')
pre=${merge%%PRE-EXISTING*}; ids=${merge%%Assign ids*}
[[ ${#pre} -lt ${#ids} ]] && pass || fail "step 4 splits PRE-EXISTING findings off before assigning ids"
assert_contains "$merge" "whatever its score" "a PRE-EXISTING finding is listed whatever its score"
assert_contains "$merge" 'within `findings.json`' "ids are assigned within findings.json only"
grep -q 'separate list' "$R/checklist-correctness.md" && fail "correctness checklist sends pre-existing defects to a separate list" || pass
grep -qF 'same array' "$R/checklist-correctness.md" && pass || fail "pre-existing defects go in the same array, prefixed"

# --spec belongs to find-specs.sh; collect.sh rejects it
passthru=$(tr '\n' ' ' <<<"$step1" | grep -oE 'Pass [^.]* through')
assert_not_contains "$passthru" "--spec" "step 1 does not pass --spec to collect.sh"
assert_contains "$step1" 'find-specs.sh --spec' "step 1 gives --spec to find-specs.sh"

# --comment needs an MR to post to
grep -qF -- '--comment needs an MR target' "$R/workflow.md" && pass || fail "workflow says what --comment does without an MR target"

# SKILL.md frontmatter
head -1 "$SK/SKILL.md" | grep -q '^---$' && pass || fail "frontmatter start"
grep -q '^name: go-review$' "$SK/SKILL.md" && pass || fail "name"
grep -q '^description:' "$SK/SKILL.md" && pass || fail "description"
finish
