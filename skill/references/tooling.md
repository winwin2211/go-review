# Tooling: collecting evidence without touching the repo

All scripts live in `scripts/` next to this file. `$SKILL` below means the
directory containing `SKILL.md`. `$WORK` is a directory created with
`mktemp -d`; it must be outside the reviewed repo. `collect.sh` requires `go`
and, whenever tools actually run (i.e. not `--no-tools`), `perl` on PATH —
`perl` backs the timeout wrapper in `lib.sh`.

`$REPO` is the user's checkout. `$REVIEW_REPO` is the tree that holds the
code under review: the same as `$REPO` in local modes, the temporary
worktree `$WORK/wt` in MR mode (`gitlab.md`). Everything that reads the
reviewed code — `collect.sh`, `find-specs.sh`, the project rule files —
takes `$REVIEW_REPO`; only the no-artifact baseline and check
(`--status-repo`, `assert-clean.sh --repo`) take `$REPO`.

## Commands

Local diff (working tree + branch vs base):

    bash "$SKILL/scripts/collect.sh" --repo "$REVIEW_REPO" --head WORKTREE --out "$WORK" [--base <ref>] [--status-repo <path>] [--no-tools] [--full-tests]

Branch or MR head already checked out in `$REVIEW_REPO` (or in a temp worktree):

    bash "$SKILL/scripts/collect.sh" --repo "$REVIEW_REPO" --head <ref-or-sha> --out "$WORK" [--base <ref>] [--status-repo <path>] [--no-tools] [--full-tests]

`--status-repo <path>` names the working tree the no-artifact baselines
(`status-before.txt`, `stash-before.txt`, `status-ignored-before.txt`) are
taken from; it defaults to `--repo`. Pass it whenever `--repo` is a temporary
worktree (MR mode) rather than the repo `assert-clean.sh` will later check,
so the baseline describes the same working tree the final check inspects.

Spec candidates (run after collect so `changed-packages.txt` exists):

    bash "$SKILL/scripts/find-specs.sh" --repo "$REVIEW_REPO" --out "$WORK" --base <ref> --head <ref|WORKTREE> --branch "<branch>" --title "<mr title or empty>" [--spec <path>]

In MR mode this must be the worktree: a spec that exists only on the MR
branch is invisible in a `$REPO` checked out elsewhere and would turn into
a false "no matching spec" BLOCKER.

Final no-artifact check (always run, even after errors):

    bash "$SKILL/scripts/assert-clean.sh" --repo "$REPO" --out "$WORK" [--worktree "$WORK/wt"]
    rm -rf "$WORK"

## Reading the outputs

| File | Meaning |
|---|---|
| `meta.env` | `REPO, BASE, HEAD, HEAD_SHA, MERGE_BASE, MODE, MODULE, MODULE_DIR` |
| `diff.patch` | unified diff; the review scope |
| `changed-files.txt`, `changed-go-files.txt` | paths relative to repo |
| `changed-packages.txt` | import paths of changed packages |
| `test-packages.txt` | packages tested (changed + direct importers, or `./...`) |
| `changed-symbols.txt` | added/changed `func`, `type`, `var`, `const` lines |
| `nontest-lines.txt` | added+removed non-test lines; > 50 means substantive |
| `tools/summary.txt` | `name<TAB>OK|FAIL|UNAVAILABLE(reason)<TAB>detail` |
| `tools/build.txt`, `tools/vet.txt` | compiler / vet output |
| `tools/lint.txt` | golangci-lint, only issues new since merge-base |
| `tools/test.txt` | `go test -short -race` output |
| `tools/test-classified.txt` | `pkg<TAB>OK|FAIL|NOT_RUNNABLE|NO_TESTS` |
| `tools/cover.txt` | `go tool cover -func` per function |
| `tools/vuln.txt` | govulncheck output |
| `specs.tsv` | matched spec/plan candidates, columns: `path<TAB>convention<TAB>signals`, where convention is `superpowers\|openspec\|docs\|forced` (`forced` when `--spec` was passed) and signals is a comma-separated list from `ticket:<KEY>`, `branch:<token>`, `title:<word>`, `package:<name>`, `git-log`, `forced`; sorted by signal count, best first |
| `specs-all.txt` | every candidate, one path per line, README excluded, for the "nearest candidates" hint |

Interpretation rules:

- `FAIL` in build, vet, or test (with at least one `FAIL` package in
  `test-classified.txt`) is a BLOCKER finding of dimension `tools`, rule-based.
  Quote the first failing line as evidence.
- `NOT_RUNNABLE` packages are reported in the header line only ("3 not runnable
  locally") and never affect the verdict. A failing package is `NOT_RUNNABLE`
  only when every failing test in it ended on an environment error
  (connection refused, no such host, missing env/config), a panic whose
  message is that error included (a `MustConnect`-style helper with no
  database); a test that logged such an error and then failed an assertion,
  or panicked on anything else (a nil dereference, go's own test timeout),
  makes the package `FAIL`. When in doubt the classifier says `FAIL`, so a `FAIL` whose evidence
  is only environment text is for the human to downgrade, never the reverse.
- `UNAVAILABLE(...)` is reported in the header line; agents must then not
  assume the linter caught anything, so linter-territory issues become fair
  game for the correctness agent.
- `lint FAIL` with N new issues: each issue is evidence, not a finding of its
  own; the correctness or security agent cites it when it supports a finding.
  Do not restate lint output as findings.
- `vuln FAIL`: each reachable vulnerability is a BLOCKER finding of dimension
  `security`, rule-based, quoting the OSV id and the call stack line.

## Never run

Inside the reviewed repo the orchestrator and every agent must never run:
`go mod tidy`, `go mod vendor`, `go generate`, `go get`, `gofmt -w`,
`goimports -w`, `golangci-lint run --fix`, `git stash`, `git checkout` of
files, `git add`, or any command with a redirect into the repo. If a tool
is missing, print the install hint from `tools/summary.txt` and continue.

The no-artifact guarantee in `assert-clean.sh` compares tracked status,
ignored-file status, and the stash list before and after the run, and lists
every file under the repo whose mtime is newer than the marker `collect.sh`
wrote at its start (so a rewritten already-modified file, or a new file
inside an untracked or ignored directory, is caught even though `git status`
looks the same). Directories named in `ASSERT_CLEAN_PRUNE` (colon-separated
basenames, default none) are pruned from that scan along with `.git`;
sibling skills use it for tool-cache directories such as `node_modules`, and
go-review leaves it empty. Outside the guarantee: `.git` internal writes
made by `git fetch` or worktree add/remove (updated remote-tracking refs,
packed-refs, reflog entries), a write that restores the file's previous
mtime, and a file whose mtime is later than the check itself (a copy with a
skewed clock, an archive's timestamps), which would otherwise be listed on
every run. A directory the scan cannot read (another user's, mode 000) is
named under `Not scanned`; with nothing else found it makes the script exit 1,
since the check is incomplete. Anything else that writes inside the repo while the review runs is
listed too: the user's editor, a service logging into the repo, an IDE. When
`git status` is otherwise unchanged the script cannot tell those writes from
a test's, so it exits 3 instead of 2 and its banner says who may have written
them; workflow.md (step 6) reports them as writes to check, never as files to
remove.

## Timeouts

build 180s, vet 180s, lint 300s, test 600s, vuln 180s; override any of them
with `GO_REVIEW_TIMEOUT_BUILD|VET|LINT|TEST|VULN=<seconds>` in the
environment of `collect.sh` (whole seconds, at least 1; anything else, such
as `20m` or `0`, makes `collect.sh` exit 1 naming the variable before it
touches the repo). A wrapper timeout produces `UNAVAILABLE(timeout)`,
never `FAIL`, and kills every process the tool started. `go test` additionally
runs with `-timeout` set a quarter of the test budget (at least 10s) below
it: 450s by default. go's clock starts with each test binary and the
wrapper's with `go test`, so a single hung test panics inside go (`panic: test
timed out`, with a goroutine dump) and is classified `FAIL` with that dump as
evidence as long as its binary starts within that quarter (compiling,
linking, waiting for a free slot). A hung binary that starts later, or a
suite whose packages together exceed the budget, reaches the wrapper timeout
instead. Suggest `--no-tools`,
`--full-tests`, or a larger `GO_REVIEW_TIMEOUT_TEST` in the report when a
timeout hides evidence.
