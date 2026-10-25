# GitLab merge requests

Requires `glab` authenticated against the self-hosted instance:

    brew install glab
    glab auth login --hostname <gitlab-host>

Run all `glab` commands with `-R <group/repo>` or from inside the repo so the
remote is resolved automatically.

## Resolve an MR target

Accepted forms: `!123`, `123`, or a full MR URL. Extract the iid, then:

    glab mr view <iid> --output json > "$WORK/mr.json"

Fields to read with `jq`: `.iid`, `.title`, `.description`,
`.source_branch`, `.target_branch`, `.sha` (head), `.diff_refs`,
`.state` (skip review if `merged` or `closed`, say so), `.draft`.
Project path for the API: `glab repo view --output json | jq -r .path_with_namespace`.

Check out the head without touching the user's branch:

    git -C "$REPO" fetch origin "$SOURCE_BRANCH"
    git -C "$REPO" worktree add --detach "$WORK/wt" "$HEAD_SHA"

Then run `collect.sh --repo "$WORK/wt" --head "$HEAD_SHA" --base "${BASE:-origin/$TARGET_BRANCH}" --status-repo "$REPO"`.
`--status-repo "$REPO"` is required here: the no-artifact baselines must
describe the same working tree that `assert-clean.sh --repo "$REPO"` checks
in step 6, not the temporary `$WORK/wt` that collect.sh reads the diff from.
A user-supplied `--base` overrides the MR target branch; otherwise the MR's
own target branch is used. `find-specs.sh --repo "$WORK/wt"` likewise, and
read the project rule files (`CLAUDE.md`, `docs/code-standards/**`) from
`$WORK/wt`: `$REPO` may be checked out on an unrelated branch, so a spec or
rule that exists only on the MR branch is invisible there.
If the local branch has the same name as the source branch but a different
sha, warn in the report header: "local <branch> is at <sha>, reviewed MR head
<sha>". The worktree is removed by `assert-clean.sh --worktree "$WORK/wt"`
run against the original `$REPO`.

## Posting

Only with `--comment`, and only after showing the user the summary that will
be posted and receiving an explicit yes.

    bash "$SKILL/scripts/gitlab-post.sh" --project <group/repo> --mr <iid> --head-sha <sha> \
      --findings "$WORK/findings.json" --summary "$WORK/summary.md" [--dry-run]

Behavior: one summary note carrying the marker `<!-- go-review:<sha> -->`,
then one inline discussion per finding whose file is in the MR diff and whose
`line` is a usable (> 0) anchor. Findings outside the diff, and in-diff
findings with no such line, are folded into the summary. A rerun on the same
head sha prints `already posted` and posts nothing. Use `--dry-run` to
preview the API calls.

`findings.json` is the verified findings array (schema in
`severity-verdict.md`). `summary.md` is the Markdown version of the terminal
report without the per-finding bodies that become inline discussions.
