# go-review: High-Standard Go Backend Code Review Skill

Date: 2026-09-05
Status: approved design

## Goal

A Claude Code skill, `/go-review`, that reviews Go backend changes to a very high
standard and produces a verdict a senior reviewer would stand behind. It runs
locally in Claude Code, reviews a local diff/branch or a GitLab merge request,
runs real tooling as evidence, dispatches specialist read-only subagents across
five review dimensions, verifies findings to suppress false positives, prints an
English report, and can optionally post the findings to the MR.

Hard constraint: after a run, the reviewed project must be byte-for-byte
unchanged. No files, binaries, caches, or config are written under the project.

## Non-goals (this iteration)

- CI bot / pipeline integration (may be built later on top of this skill).
- Auto-fixing findings.
- Languages other than Go.
- Team-wide plugin packaging (the repo layout keeps this possible).
- Whole-service audit mode (only diff-based review).

## Repository layout

The skill lives in its own git repo and is installed into `~/.claude` by
symlink so it is versioned and can be promoted to a plugin later.

```
go-review/                          (this repo)
  install.sh                        symlinks skill + agents into ~/.claude
  skill/
    SKILL.md                        entry point: /go-review
    references/
      workflow.md                   orchestrator pipeline, step by step
      checklist-correctness.md      correctness + concurrency
      checklist-security.md
      checklist-architecture.md
      checklist-performance.md      performance + reliability + observability
      checklist-sdd-tdd.md          spec/plan discovery, spec rubric, test matrix
      severity-verdict.md           0-100 rubric, severity mapping, verdict rules
      report-format.md              terminal report + MR comment templates
      gitlab.md                     glab usage, inline discussions, idempotency
      tooling.md                    tool commands, scoping, timeouts, no-artifact rules
    scripts/
      collect.sh                    diff, changed packages, run tools -> temp dir
      find-specs.sh                 list spec/plan candidates under the 3 conventions
      gitlab-post.sh                post summary note + inline discussions to an MR
      golangci-strict.yml           fallback lint config when the repo has none
  agents/
    go-review-correctness.md
    go-review-security.md
    go-review-architecture.md
    go-review-performance.md
    go-review-sdd-tdd.md
    go-review-verifier.md
  docs/superpowers/specs/           this document
  docs/superpowers/plans/           implementation plan
  fixtures/                         throwaway test repos are generated here by a
                                    script, never committed
```

Install targets:

- `~/.claude/skills/go-review` -> `skill/`
- `~/.claude/agents/go-review-*.md` -> `agents/*.md`

## Command interface

```
/go-review [target] [--base <ref>] [--comment] [--no-tools] [--full-tests]
           [--spec <path>] [--skip-sdd "<reason>"]
```

| Argument | Meaning |
|---|---|
| (none) | Review working tree + current branch against base. |
| `<branch>` | Review that branch against base. |
| `!123`, `123`, MR URL | Review the GitLab MR at its head sha. |
| `--base <ref>` | Override base. Default: MR target branch, else `origin/HEAD`, else `develop`, else `main`. |
| `--comment` | After the report, post to the MR (asks for confirmation first). |
| `--no-tools` | Skip tool execution. Report marks tool evidence as unavailable. |
| `--full-tests` | Run `go test` on all packages instead of changed + direct importers. |
| `--spec <path>` | Force a spec/plan file or directory as the SDD source. |
| `--skip-sdd "<reason>"` | Downgrade missing-spec/plan blockers to MAJOR and record the reason in the report. Never silent. |

## Pipeline

The orchestrator (the main Claude session following `workflow.md`) executes:

### 0. Preflight

- Resolve target and base. For an MR: `glab` fetches metadata (iid, source/target
  branch, head sha, `diff_refs`, title, description). If `glab` is missing, stop
  with install instructions.
- Create `WORK=$(mktemp -d)` outside the project. Every intermediate file goes
  there.
- Snapshot `git status --porcelain` and `git stash list` for the final
  no-artifact assertion.
- If the MR head sha is not the current checkout, `git fetch` and create a
  temporary worktree under `$WORK/wt`. If the local branch has the same name but
  a different sha, warn and use the MR sha.
- Locate project rules: root `CLAUDE.md`, `CLAUDE.md` in touched directories,
  `docs/code-standards/**` if present. Paths are passed to every agent.

### 1. Collect (`collect.sh`)

Writes into `$WORK`:

- `diff.patch` (base...head, or working tree + branch), `changed-files.txt`,
  `changed-packages.txt`, `test-packages.txt` (changed packages + direct
  importers, or all with `--full-tests`), `changed-symbols.txt` (exported
  symbols added/changed).
- Tool outputs, each with its own timeout and exit code recorded:
  - `go build -o "$WORK/bin/" ./...`
  - `go vet ./...`
  - `golangci-lint run --new-from-rev <base> ./...` using the repo's config, or
    `-c <skill>/scripts/golangci-strict.yml` when the repo has none.
  - `go test -short -race -count=1 -coverprofile="$WORK/cover.out" <test-packages>`
    followed by `go tool cover -func` into `$WORK/cover.txt`.
  - `govulncheck ./...` if installed, otherwise a note with the install command.
- Test failures are classified: `connection refused`, `no such host`, missing
  env/config, or explicit `testing.Short()` skips are marked "not runnable
  locally" and excluded from the verdict. Other failures are BLOCKER evidence.
- Forbidden commands (enforced by the script): `go mod tidy`, `go generate`,
  `gofmt -w`, `goimports -w`, `golangci-lint --fix`, anything writing under the
  project root. Vendor-aware: `-mod` flags are never set.

### 2. Spec discovery (`find-specs.sh` + SDD agent)

Candidate sources, in order:

1. `docs/superpowers/specs/*.md` and `docs/superpowers/plans/*.md`
2. `openspec/changes/<id>/{proposal.md,design.md,tasks.md,specs/**/*.md}`, plus
   `openspec/specs/**/spec.md` as the baseline
3. Any `*.md` under `docs/` of the project root. `README.md` does not count.

Matching signals, any of which links a candidate to the change: ticket key in
branch name or MR title (e.g. `XBI-1234`), branch-name tokens, MR title words,
changed package names appearing in the doc, and docs modified in
`git log base..head -- docs/ openspec/`. When nothing matches, the SDD finding
lists the nearest candidates so the user can rerun with `--spec`.

### 3. Parallel review

Five agents run concurrently via the Agent tool. Each receives: paths to the
diff, tool outputs, spec candidates, project rule files, its own checklist path,
and the finding schema. Agents are read-only (tools: Read, Grep, Glob, Bash with
an explicit no-write instruction). They may read any file in the repo for
context but report only on the change unless the checklist says otherwise.

| Agent | Checklist | Focus |
|---|---|---|
| go-review-correctness | checklist-correctness.md | logic errors, nil/zero-value, error handling, context propagation and cancellation, goroutine leaks, data races, channel misuse, resource leaks, transactions, retries/idempotency correctness |
| go-review-security | checklist-security.md | injection (SQL/NoSQL/command/log), authn/authz, secrets, crypto misuse, input validation and limits, SSRF, path traversal, unsafe deserialization, gosec/govulncheck evidence |
| go-review-architecture | checklist-architecture.md | project rules first (CLAUDE.md, code-standards); then generic: layer boundaries, dependency direction, import cycles, interface placement, package cohesion, API/contract design, transaction boundary placement |
| go-review-performance | checklist-performance.md | allocations in hot paths, N+1 queries, unbounded queries/loads, lock contention, timeouts, retry/backoff, graceful shutdown, logging/metrics/tracing quality |
| go-review-sdd-tdd | checklist-sdd-tdd.md | spec/plan existence and quality, code vs spec drift, requirement-to-test matrix, test quality |

If the diff exceeds about 1500 lines, the orchestrator splits the correctness
and security agents by package group and merges their outputs.

Finding schema (each agent returns a list):

```
id, dimension, severity (BLOCKER|MAJOR|MINOR), rule-based (bool),
file, line, title, evidence (quoted code / tool output), why, fix,
spec_ref (optional), confidence (0-100, agent's own)
```

### 4. Verify

`go-review-verifier` receives the findings batched by file, re-reads the code,
and scores each 0-100 with the rubric in `severity-verdict.md`. It also
deduplicates across agents, drops findings already reported by the linters, and
drops pre-existing issues on unchanged lines (moved to a "Pre-existing" list).

Rule-based findings (SDD/TDD and tool failures) are not scored subjectively: the
verifier only confirms the fact (spec really absent, test really absent, tool
really failed) and keeps the severity assigned by the rule.

Thresholds: >= 80 reported as findings; 60-79 listed under "Needs human
judgment"; < 60 dropped.

### 5. Report, post, cleanup

- Print the English report (format below) and the verdict.
- With `--comment`: show what will be posted, ask for confirmation, then
  `gitlab-post.sh` posts one summary note plus one inline discussion per finding
  whose line is in the MR diff (positioned with `diff_refs`). Findings outside
  the diff go into the summary note. Every note carries a hidden marker
  `<!-- go-review:<head_sha> -->`; if a note with the same marker exists, the run
  skips posting and says so.
- Cleanup: remove the temp worktree (`git worktree remove --force` +
  `git worktree prune`), `rm -rf "$WORK"`, then compare `git status --porcelain`
  and `git stash list` with the preflight snapshot. Any difference is reported
  prominently as a bug in the skill.

## SDD/TDD gate

### Change classification

Substantive if any of: new or changed endpoint, handler, resolver, consumer,
publisher, schema, migration, or package; behavior change in service, usecase,
or repository layers; more than 50 non-test lines changed. Otherwise trivial
(typo, log message, dependency bump, pure rename). Trivial changes are exempt
from the spec/plan requirement and the report says so explicitly.

### Rules

| Condition | Severity |
|---|---|
| Substantive change, no matching spec | BLOCKER |
| Substantive change, no plan/tasks | MAJOR |
| Plan tasks unchecked but implemented, or checked but not implemented | MAJOR |
| Spec missing 1 required section | MAJOR |
| Spec missing 2+ required sections ("sloppy spec") | BLOCKER |
| Code contradicts spec, or behavior not described by spec | BLOCKER if it affects a contract or data; else MAJOR |
| Missing test for a critical case | BLOCKER |
| Missing test for a non-critical spec case | MAJOR |
| Non-trivial function changed with no corresponding test change | MAJOR |
| Test without a real assertion, or only happy path for a function with error paths | MAJOR |
| Concurrent code with no test exercising concurrency under `-race` | MAJOR |
| `--skip-sdd` given | missing-spec/plan blockers become MAJOR, reason printed |

Critical cases: money, balance, order, or position logic; authn/authz; concurrent
paths; error paths of external calls (DB, cache, queue, HTTP, RPC); data
migrations.

### Required spec sections

1. Goal / problem statement
2. Scope and out-of-scope
3. Current state / context
4. Design decisions with rationale
5. Concrete contracts: API, events, schema, config
6. Error handling and edge cases
7. Data / migration impact
8. Risks and rollback
9. Testing strategy naming the cases that must be tested
10. Acceptance criteria

OpenSpec mapping: `proposal.md` covers 1-3 and 7-8; `design.md` covers 4; the
delta `specs/**/spec.md` cover 5-6 and 10 via requirements with `WHEN/THEN`
scenarios (a requirement without a scenario counts as missing); `tasks.md` is
the plan and covers 9 when it lists test tasks.

Superpowers mapping: the spec file covers 1-10; the plan file covers the plan
requirement and test tasks.

Plain `docs/` mapping: the same 10 sections are looked for by heading or
content; the plan may be a section inside the spec.

### Requirement-to-test matrix

The SDD agent builds a table: requirement / acceptance criterion / scenario ->
test function(s) that exercise it, with file:line. When no spec exists, the
agent derives the important cases from the code itself (branches, error paths,
boundaries, concurrent paths) and builds the same table, so missing tests are
still flagged. Coverage numbers from `cover.txt` are attached as evidence only;
there is no hard coverage threshold. Commit ordering (tests before code) is
informational only.

## Severity and verdict

- BLOCKER: bug on a reachable path, data loss or corruption, security
  vulnerability, race or leak, build/vet/test/race failure, reachable CVE, and
  the SDD/TDD blockers above.
- MAJOR: bug under specific conditions, layer or dependency-direction violation,
  missing timeout or context propagation, error wrapping that loses context,
  performance issue under production load, SDD/TDD majors.
- MINOR: Go idiom, naming, exported doc comments, small inefficiencies.

Verdict: any BLOCKER, or 3 or more MAJOR -> REQUEST CHANGES. Otherwise APPROVE
WITH COMMENTS when any finding remains, else APPROVE.

Noise rules: never repeat linter output; pre-existing issues outside the diff
are listed separately (max 5) and do not affect the verdict; issues a compiler
or linter would catch are not findings unless tools were skipped.

## Report format (English)

```
go-review — <repo> <target> vs <base> @ <sha>
Tools: build OK | vet OK | lint 0 new | test 42 pass, 3 not runnable locally | race OK | vuln none
Verdict: REQUEST CHANGES (2 blockers, 1 major)

BLOCKER
[B1] <title> — path/file.go:123
  Evidence: <quoted code or tool line>
  Why: ...
  Fix: ... (short Go snippet when it helps)
  Spec: docs/superpowers/specs/....md#section (if any)

MAJOR ...
MINOR ...

SDD/TDD
  Spec: <path> (matched by XBI-1234) | none found (candidates: ...)
  Plan: <path> | none
  Spec rubric: 8/10 (missing: risks/rollback, acceptance criteria)
  Requirement -> test:
    R1 ... -> TestFoo_Bar (svc_test.go:40)
    R2 ... -> MISSING (critical)

Needs human judgment: ...
Pre-existing (not blocking): ...
No artifacts left: verified (git status unchanged)
```

The MR summary note uses the same content in Markdown; inline discussions carry
one finding each.

## Agent definitions

Each `agents/go-review-*.md` has frontmatter `name`, `description`, `tools:
Read, Grep, Glob, Bash`, `model: inherit`, and a body that: states the
read-only contract (no writes, no `go mod`, no formatters, no installs),
instructs the agent to read its checklist file first, defines the finding
schema, and lists false-positive classes to avoid (pre-existing code, linter
territory, intentional behavior, nitpicks a senior engineer would not raise).

## Tooling and dependencies

- Required: `go`, `git`. `golangci-lint` recommended (fallback strict config
  shipped). `govulncheck` optional. `glab` required only for MR targets and
  `--comment`; `glab auth login --hostname <self-hosted host>` is documented in
  `gitlab.md`.
- The skill suggests installs; it never installs anything itself.
- Tool budget: each tool has a timeout (build/vet 3 min, lint 5 min, tests 10
  min, vuln 3 min). A timed-out tool is reported as "unavailable", not as a
  failure.

## Testing the skill

`fixtures/make-fixtures.sh` generates two throwaway git repos under the session
scratchpad (never inside this repo's tracked tree):

- `dirty`: base branch plus a feature branch seeding a data race, a swallowed
  error, string-concatenated SQL, a handler calling a repository directly, a
  substantive change with no spec, and a test without assertions.
- `clean`: a feature branch with a complete superpowers spec + plan, tests
  covering every acceptance criterion, and no defects.

Acceptance: on `dirty` every seeded defect appears as a finding at the expected
severity and the verdict is REQUEST CHANGES; on `clean` there are no BLOCKER or
MAJOR findings and the verdict is APPROVE or APPROVE WITH COMMENTS; after both
runs `git status` in the fixture is unchanged. GitLab posting is tried only on
an MR the user designates, with confirmation.

## Risks

- Cost: six agents per run. Mitigated by scoping tools to changed packages and
  batching verification by file; the model line in each agent file is the knob.
- Spec matching misses: mitigated by the fallback signals and `--spec`.
- Architecture false positives across differing layouts: mitigated by reading
  project rules first and keeping generic rules minimal.
- Long test suites: mitigated by scoping, `-short`, timeouts, `--no-tools`.
