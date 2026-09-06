# go-review

High-standard code review skill for Go backends, for Claude Code.

    /go-review [target] [--base <ref>] [--comment] [--no-tools] [--full-tests] [--spec <path>] [--skip-sdd "<reason>"]

Reviews a local diff, a branch, or a GitLab MR. Runs build, vet,
golangci-lint, `go test -race`, and govulncheck as evidence; dispatches
read-only specialist agents for correctness and concurrency, security,
architecture, performance and reliability, and spec/test-driven compliance;
verifies findings; prints an English report with a verdict; optionally posts
to the MR. Leaves the reviewed repo untouched and proves it.

## Install

    git clone /Users/thangtrinh/Projects/personal/go-review ~/Projects/personal/go-review
    cd ~/Projects/personal/go-review && bash install.sh

Optional tools: `brew install golangci-lint glab`,
`go install golang.org/x/vuln/cmd/govulncheck@latest`,
`glab auth login --hostname <your-gitlab-host>`.

## Layout

- `skill/` — SKILL.md, references (checklists, rubric, report format), scripts
- `agents/` — six read-only agent definitions
- `tests/` — `bash tests/run.sh`
- `fixtures/` — `make-fixtures.sh <outdir>` generates throwaway repos for testing
- `docs/superpowers/` — design spec and implementation plan

## Tuning the standard

Edit `skill/references/checklist-*.md` to change what is flagged, and
`skill/references/severity-verdict.md` to change severities and thresholds.
Changes take effect on the next run; no reinstall needed.
