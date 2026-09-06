---
name: go-review
description: >-
  High-standard code review for Go backend changes. Use when asked to review
  Go code, a Go diff, branch, or GitLab merge request, or when the user says
  "review", "go review", "review MR", "review this branch", "check my PR",
  "review code" in a Go repository. Runs build/vet/lint/test/race/vuln as
  evidence, dispatches specialist read-only agents for correctness and
  concurrency, security, architecture, performance and reliability, and
  spec-driven/test-driven compliance (spec, plan, tests for critical cases),
  verifies findings, prints an English report with a verdict, and can post to
  the MR. Leaves the reviewed repository untouched.
---

# go-review

Review Go backend changes to a standard a senior reviewer would sign.
Everything you need is in `references/workflow.md`; read it now and follow it
step by step. Do not skip the final cleanup step even when an earlier step
fails.

## Invocation

    /go-review [target] [--base <ref>] [--comment] [--no-tools] [--full-tests] [--spec <path>] [--skip-sdd "<reason>"]

| Argument | Meaning |
|---|---|
| none | working tree + current branch vs base |
| `<branch>` | that branch vs base |
| `!123`, `123`, MR URL | the GitLab MR at its head sha |
| `--base <ref>` | override base (default: MR target, else `origin/HEAD`, else develop/main) |
| `--comment` | after the report, post to the MR (asks first) |
| `--no-tools` | skip build/vet/lint/test/vuln |
| `--full-tests` | test all packages, not only changed + importers |
| `--spec <path>` | force this file/dir as the spec |
| `--skip-sdd "<reason>"` | downgrade missing spec/plan to MAJOR; reason is printed |

## Hard rules

- Never write inside the reviewed repo. All scratch goes to a `mktemp -d`
  directory; `scripts/assert-clean.sh` proves it at the end.
- Never run `go mod tidy`, `go generate`, formatters with `-w`, or
  `golangci-lint --fix` (full list in `references/tooling.md`).
- Never post to GitLab without `--comment` and an explicit yes after showing
  the summary.
- Report in English, in the exact shape of `references/report-format.md`.
- Findings need `file:line` and verbatim evidence. No evidence, no finding.

## Files

- `references/workflow.md` — the pipeline you execute
- `references/tooling.md`, `references/gitlab.md` — how to run the scripts
- `references/severity-verdict.md`, `references/report-format.md` — how to judge and print
- `references/checklist-*.md` — what each specialist agent checks
- `scripts/collect.sh`, `scripts/find-specs.sh`, `scripts/assert-clean.sh`, `scripts/gitlab-post.sh`
