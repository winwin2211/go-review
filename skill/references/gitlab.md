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

Then run `collect.sh --repo "$WORK/wt" --head "$HEAD_SHA" --base "origin/$TARGET_BRANCH"`.
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
then one inline discussion per finding whose file is in the MR diff. Findings
outside the diff are folded into the summary. A rerun on the same head sha
prints `already posted` and posts nothing. Use `--dry-run` to preview the
API calls.

`findings.json` is the verified findings array (schema in
`severity-verdict.md`). `summary.md` is the Markdown version of the terminal
report without the per-finding bodies that become inline discussions.
