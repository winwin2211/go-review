# Spec-driven and test-driven development checklist

Everything in this checklist is rule-based. Findings carry `rule_based: true`
and the severity from the Rules table; the verifier only confirms facts.

## How to work

1. Read `meta.env`, `nontest-lines.txt`, `changed-files.txt`,
   `changed-symbols.txt`, `diff.patch`.
2. Classify the change (below).
3. Read `specs.tsv` and `specs-all.txt`. Open every matched candidate.
4. Score the spec against the rubric, build the requirement-to-test matrix,
   check test quality, then emit findings from the Rules table.

## Classify the change

Substantive when any of:
- `nontest-lines.txt` > 50
- a new or changed HTTP handler, gRPC method, GraphQL resolver, consumer,
  publisher, scheduler job (look at `changed-symbols.txt` and route/schema
  registration lines in the diff)
- a new or changed DB schema, migration, proto, GraphQL schema, event payload
- a new package
- behavior change in a service/usecase/repository function (a changed `if`,
  return value, query, or call sequence; not a rename or comment)

Trivial otherwise: typo, comment, log text, dependency bump with no code
change, pure rename verified by the diff, formatting.

State the classification and the reason in the SDD block. Trivial changes
skip the spec/plan rules but still get the test-quality rules.

## Locate spec and plan

Conventions, in order; the first convention with a match wins:

1. Superpowers: `docs/superpowers/specs/*.md` is the spec,
   `docs/superpowers/plans/*.md` is the plan.
2. OpenSpec: `openspec/changes/<id>/proposal.md` (+ `design.md`) is the spec,
   `openspec/changes/<id>/specs/**/spec.md` are the requirement deltas,
   `openspec/changes/<id>/tasks.md` is the plan. `openspec/specs/**` is the
   baseline to diff against for drift.
3. Plain docs: any `docs/**/*.md` except README; the plan may be a section
   (`## Plan`, `## Tasks`, `## Implementation`) in the same file.

A candidate counts as the spec for this change only if it is in `specs.tsv`
(has at least one signal) and its content describes the changed behavior.
A doc that merely mentions the package but describes a different feature is
not a match; say so.

`--spec <path>` (row `forced`) is always the spec, even if it looks unrelated;
still score it.

If no spec matches, list up to 3 nearest paths from `specs-all.txt` in the
finding's `fix` so the user can rerun with `--spec`.

## Spec rubric

Ten required sections. A section counts as present when the content is there
under any heading name, with at least one concrete sentence (a heading with
"TBD", "N/A" without a reason, or one generic line does not count).

| # | Section | Present when |
|---|---|---|
| 1 | Goal / problem | says what is wrong or missing today and for whom |
| 2 | Scope / out of scope | lists what is in and explicitly what is out |
| 3 | Current state | describes the code/behavior before the change |
| 4 | Design decisions with rationale | at least one decision and a because |
| 5 | Contracts | API/event/schema/config signatures or shapes, concrete |
| 6 | Error handling and edge cases | names specific failure modes and what happens |
| 7 | Data / migration impact | says none with a reason, or describes the change |
| 8 | Risks and rollback | at least one risk and how to revert |
| 9 | Testing strategy | names the cases that must be tested |
| 10 | Acceptance criteria | checkable statements (given/when/then or a list) |

OpenSpec mapping: proposal covers 1, 2, 3, 7, 8 (its Why/What/Impact
sections); design covers 4; delta specs cover 5, 6, 10 through requirements
with `#### Scenario:` blocks (a requirement without a scenario is a missing
10); tasks.md covers 9 when it lists test tasks.

Report `Spec rubric: N/10 (missing: ...)`.

## Code vs spec

For each contract, decision, and acceptance criterion in the spec, find the
implementing lines in the diff. Flag:
- Behavior in the diff that the spec does not describe (new endpoint, new
  field, new side effect, new config key).
- Spec statements the diff contradicts (different name, type, status code,
  error, ordering, default).
- Plan/tasks: items checked but not implemented, or implemented but not
  checked; tasks that mention files the diff does not touch and vice versa.

## Requirement-to-test matrix

Rows: every acceptance criterion, scenario, and "must test" case from the
spec. When there is no spec, derive rows from the code: each `if`/`switch`
branch on input, each error return, each boundary (empty, zero, max, off by
one), each concurrent path, each external call's failure.

For each row find a test that exercises it: read `*_test.go` in the changed
packages and importers, match by function under test and by the input or
error asserted. Record `TestName/subtest (file:line)` or `MISSING`.

Mark a row critical when it involves: money, balance, quantity, order,
position, or fee math; authn/authz; concurrency; the error path of an
external call (DB, cache, queue, HTTP, RPC); a migration or data backfill.

Attach per-package coverage from `tools/cover.txt` as evidence only.

## Test quality

Flag when true for a changed package:
- A changed non-trivial function (more than a getter/setter/constructor) with
  no test added or modified that calls it.
- A test with no assertion: no `t.Error*`, `t.Fatal*`, `require.*`,
  `assert.*`, `cmp.Diff` check, or `if got != want`. A test that only checks
  `err == nil` for a function that has error paths counts as happy-path only.
- Tests that call the function but ignore the return (`_, _ = f()`).
- Only happy-path tests for a function with error returns.
- Concurrency-touching code (goroutines, mutexes, channels) with no test that
  runs the code from multiple goroutines; `go test -race` cannot catch what no
  test exercises.
- Tests that depend on wall-clock sleeps or real network for unit behavior.
- Table-driven cases with duplicated inputs, or a subtest name that does not
  say what is being asserted.
- Test-only code paths in production code (`if testing.Testing()`, `if
  isTest`).

## Rules

| Condition | Severity |
|---|---|
| Substantive, no matching spec | BLOCKER |
| Substantive, no plan/tasks | MAJOR |
| Plan tasks checked but not implemented, or implemented but not checked | MAJOR |
| Spec missing exactly 1 rubric section | MAJOR |
| Spec missing 2 or more rubric sections | BLOCKER |
| Diff contradicts spec on a contract, or adds undocumented behavior touching a contract or data | BLOCKER |
| Diff contradicts spec elsewhere, or adds undocumented behavior elsewhere | MAJOR |
| Matrix row MISSING and critical | BLOCKER |
| Matrix row MISSING, not critical | MAJOR |
| Changed non-trivial function without a test change | MAJOR |
| Assertion-less or happy-path-only test on a function with error paths | MAJOR |
| Concurrent code without a concurrent test | MAJOR |
| Sleep/network-dependent unit test, test-only branches in prod code | MINOR |
| `--skip-sdd "<reason>"` given | the first two rows become MAJOR; put the reason in `why` |

## Output

Return the findings array and, as a second JSON object, the SDD block:

```
{
  "classification": "substantive|trivial",
  "classification_reason": "...",
  "spec": {"path": "...", "convention": "...", "signals": "..."} | null,
  "plan": {"path": "..."} | null,
  "nearest_candidates": ["..."],
  "rubric": {"score": 8, "missing": ["risks/rollback", "acceptance criteria"]},
  "matrix": [{"requirement": "AC1 ...", "critical": false, "test": "TestX/success (file:line)" | "MISSING"}],
  "coverage": [{"package": "...", "percent": 91.7}]
}
```
