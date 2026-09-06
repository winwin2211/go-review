# Workflow for the orchestrator

You are the main session. Agents do the reading; you do the plumbing, the
verification hand-off, the report, and the cleanup. `$SKILL` is this skill's
directory (the parent of `references/`).

## 0. Parse arguments and set up

1. Parse `$ARGUMENTS` into `TARGET`, `--base`, `--comment`, `--no-tools`,
   `--full-tests`, `--spec`, `--skip-sdd`.
2. `REPO=$(git rev-parse --show-toplevel)`; if that fails, stop: "not a git repo".
   Confirm `go.mod` exists somewhere under `$REPO`; if not, stop: "not a Go repo".
3. `WORK=$(mktemp -d "${TMPDIR:-/tmp}/go-review.XXXXXX")`. Create a todo list
   with steps 1-6 below so progress is visible.
4. Decide the mode:
   - No target: `HEAD=WORKTREE`, `BRANCH=$(git rev-parse --abbrev-ref HEAD)`, `TITLE=""`.
   - Branch name: `HEAD=<branch>`, `BRANCH=<branch>`, `TITLE=""`.
   - MR (`!N`, `N`, or URL): follow `references/gitlab.md` (section "Resolve an MR target").
     Sets `HEAD=<head sha>`, `BRANCH=<source>`, `TITLE=<mr title>`, `BASE=origin/<target>`,
     `REVIEW_REPO=$WORK/wt`. If the MR is merged/closed, print that and go to step 6.
   For non-MR modes `REVIEW_REPO=$REPO`.
5. From here on, every failure still ends at step 6.

## 1. Collect evidence

Run `scripts/collect.sh` and then `scripts/find-specs.sh` exactly as shown in
`references/tooling.md` (section "Commands"). Pass `--no-tools` / `--full-tests`
/ `--spec` through. Read `$WORK/tools/summary.txt` and `$WORK/meta.env` and
print a one-line progress message with the tool statuses.

Collect project rule files: root `CLAUDE.md`, `CLAUDE.md` in each directory
listed in `changed-files.txt` (walk up to root), `docs/code-standards/*.md`
if present. Store the list in `$WORK/rules.txt`.

## 2. Dispatch the five reviewers

Use the Agent tool, all five in one message so they run concurrently:
`go-review-correctness`, `go-review-security`, `go-review-architecture`,
`go-review-performance`, `go-review-sdd-tdd`.

Each prompt contains, verbatim:

```
Repo: <REVIEW_REPO>
Work dir: <WORK>   (read-only for you except nothing: do not write anywhere)
Skill dir: <SKILL>
Read first: <SKILL>/references/checklist-<dimension>.md, then <SKILL>/references/severity-verdict.md (section "Finding schema").
Inputs: <WORK>/diff.patch, <WORK>/meta.env, <WORK>/changed-files.txt, <WORK>/changed-packages.txt,
        <WORK>/changed-symbols.txt, <WORK>/nontest-lines.txt, <WORK>/tools/summary.txt, <WORK>/tools/*.txt,
        <WORK>/specs.tsv, <WORK>/specs-all.txt, project rules: <contents of rules.txt>
Flags: skip-sdd=<reason or none>
Return ONLY a JSON array of findings (schema above). Empty array if none.
```

The SDD agent's prompt adds: "Also return the SDD block object described in
the checklist's Output section, after the array."

Large diffs: if `diff.patch` has more than 1500 lines, split
`changed-packages.txt` into groups of at most 6 packages and dispatch one
correctness and one security agent per group, telling each which packages
are in scope. Merge their arrays.

Collect all arrays into `$WORK/findings-raw.json`. Save the SDD block to
`$WORK/sdd.json`.

## 3. Add tool findings

From `tools/summary.txt` and `tools/test-classified.txt` create rule-based
findings (dimension `tools`) per `references/tooling.md` (section "Reading the outputs"):
build/vet FAIL, any package `FAIL` in test-classified, `DATA RACE` in
`tools/test.txt`, reachable vulnerabilities in `tools/vuln.txt`. Append to
`findings-raw.json`.

## 4. Verify

Group `findings-raw.json` by `file`. Dispatch `go-review-verifier` agents,
one per group of up to 8 files, in one message. Each prompt contains: repo
path, skill dir, the findings for its files (JSON), and:

```
Read <SKILL>/references/severity-verdict.md (sections "Verifier rubric", "Noise rules").
For each finding re-read the code at file:line and its callers. Set "score".
Rule-based findings: confirm the fact only; keep severity; score 100 or drop.
Merge duplicates. Return ONLY the JSON array with scores.
```

Merge the results. Assign ids (B1.., M1.., N1.. by path then line). Split into:
`findings.json` (score >= 80), `judgment.json` (60-79), `preexisting.json`
(title prefixed `PRE-EXISTING:`, max 5). Write all three into `$WORK`.

## 5. Report

Compute the verdict per `references/severity-verdict.md` (section "Verdict").
Print the terminal report per `references/report-format.md` (section "Terminal report"),
filling the SDD/TDD block from `sdd.json`. Keep the final line for step 6.

If `--comment`:
1. Write `$WORK/summary.md` per `references/report-format.md` (section "MR summary").
2. Show the summary to the user and ask: "Post this to MR !<iid>? (yes/no)".
3. On yes, run `scripts/gitlab-post.sh` per `references/gitlab.md` (section "Posting").
   Print its last line.

## 6. Cleanup (always)

```
bash "$SKILL/scripts/assert-clean.sh" --repo "$REPO" --out "$WORK" [--worktree "$WORK/wt"]
rm -rf "$WORK"
```

Print the `No artifacts left: verified` line as the last line of the report.
If `assert-clean.sh` exits 2, print its output verbatim under a heading
`ARTIFACTS LEFT` and tell the user which files to remove; do not remove them
yourself.
