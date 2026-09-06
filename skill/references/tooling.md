# Tooling: collecting evidence without touching the repo

All scripts live in `scripts/` next to this file. `$SKILL` below means the
directory containing `SKILL.md`. `$WORK` is a directory created with
`mktemp -d`; it must be outside the reviewed repo.

## Commands

Local diff (working tree + branch vs base):

    bash "$SKILL/scripts/collect.sh" --repo "$REPO" --head WORKTREE --out "$WORK" [--base <ref>] [--no-tools] [--full-tests]

Branch or MR head already checked out in `$REPO` (or in a temp worktree):

    bash "$SKILL/scripts/collect.sh" --repo "$REPO" --head <ref-or-sha> --out "$WORK" [--base <ref>] [--no-tools] [--full-tests]

Spec candidates (run after collect so `changed-packages.txt` exists):

    bash "$SKILL/scripts/find-specs.sh" --repo "$REPO" --out "$WORK" --base <ref> --head <ref|WORKTREE> --branch "<branch>" --title "<mr title or empty>" [--spec <path>]

Final no-artifact check (always run, even after errors):

    bash "$SKILL/scripts/assert-clean.sh" --repo "$REPO" --out "$WORK" [--worktree "$WORK/wt"]
    rm -rf "$WORK"

## Reading the outputs

| File | Meaning |
|---|---|
| `meta.env` | `REPO, BASE, HEAD, HEAD_SHA, MERGE_BASE, MODE, MODULE` |
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
  locally") and never affect the verdict.
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

## Timeouts

build 180s, vet 180s, lint 300s, test 600s, vuln 180s. A timeout produces
`UNAVAILABLE(timeout)`, never `FAIL`. Suggest `--no-tools` or `--full-tests`
adjustments in the report when a timeout hides evidence.
