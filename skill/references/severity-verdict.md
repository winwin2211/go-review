# Severity, verification, and verdict

## Finding schema

Every agent returns a JSON array. Every object has exactly these keys:

    id           "" (assigned by the orchestrator after verification)
    dimension    correctness | security | architecture | performance | sdd-tdd | tools
    severity     BLOCKER | MAJOR | MINOR
    rule_based   true when the finding comes from a rule table (SDD/TDD, tool failure, CVE); false for judgment findings
    file         path relative to the repo root
    line         integer line in the new file (0 when not applicable)
    title        one line, <= 80 chars, states the defect, not the advice
    evidence     quoted code or tool output line, verbatim, <= 3 lines
    why          what breaks, when, and for whom; 1-2 sentences
    fix          the change to make; 1-2 sentences, a <= 6 line Go snippet allowed
    spec_ref     "path#heading" or ""
    score        0-100 (agent's own confidence; the verifier overwrites it)

## Severity

BLOCKER
- Bug on a reachable path: wrong result, panic, nil dereference, off-by-one on money/qty, lost update.
- Data loss or corruption: partial writes without a transaction, migration that drops or mis-types data.
- Security vulnerability: injection, missing authn/authz check, secret in code or logs, broken crypto, SSRF, path traversal.
- Concurrency: data race, deadlock, goroutine leak, unbounded goroutine spawn, channel that can block forever.
- Tooling: build/vet failure, failing test, `-race` report, reachable CVE.
- SDD/TDD blockers from `checklist-sdd-tdd.md`.

MAJOR
- Bug that needs a specific condition: retry without idempotency, timeout missing on an outbound call, context not propagated or cancellation ignored, error wrapped without context or swallowed on a non-critical path.
- Architecture: layer breach, wrong dependency direction, interface defined on the wrong side, transaction boundary in the wrong layer.
- Performance under production load: N+1, unbounded query, allocation in a hot loop, lock held across I/O.
- SDD/TDD majors from `checklist-sdd-tdd.md`.

MINOR
- Idiom and naming, missing doc comment on exported identifiers, small inefficiencies, log message quality.
- SDD/TDD minors from `checklist-sdd-tdd.md`.

## Verifier rubric

Score each non-rule finding 0-100 after re-reading the code at `file:line` and its callers:

- 0    Not a defect, or the code handles it elsewhere.
- 25   Might be real; could not confirm the path is reachable or the input is possible.
- 50   Confirmed real but rarely hit in practice, or a nitpick relative to the rest of the change.
- 75   Confirmed real, reachable, and matters; the change as written is insufficient.
- 100  Confirmed by direct evidence (tool output, a test, or an unambiguous code path) and will happen in normal operation.

Thresholds: >= 80 report; 60-79 "Needs human judgment"; < 60 drop.

A defect on unchanged lines is still scored on this rubric, never 0 for its
age: an agent reports one only when the change makes it reachable or worse,
with the title prefixed `PRE-EXISTING:`. Confirm the defect exists at
`file:line` and drop the finding if it does not. The orchestrator lists a
kept one under "Pre-existing" whatever its score, and it never counts toward
the verdict.

Rule-based findings are not scored. The verifier only checks the fact
(spec really absent, section really missing, test really absent, tool really
failed). If the fact is wrong, drop the finding; otherwise keep the severity
from the rule table and set score to 100.

Dedup: merge two findings only when they name the same defect with one
root cause, so one fix removes both: two agents reporting the same ignored
error, or a test `FAIL` row and an agent finding that explains why that test
fails (the data race the race detector reports). Keep the higher severity
and the better evidence. Never merge two rule-based findings that cite
different rows or rules: each failing package, each vulnerability (OSV id)
and each SDD rule is its own finding, even on the same line. Different
defects stay separate even on neighboring lines or in one function: a
`//nolint` comment and the issue it hides, an ignored error and the missing
test for it, an injectable query and the missing authorization check in the
same handler.

## Verdict

- Any BLOCKER, or 3 or more MAJOR: REQUEST CHANGES
- Otherwise, any MAJOR or MINOR remaining: APPROVE WITH COMMENTS
- Otherwise: APPROVE

Findings in "Needs human judgment", "Pre-existing", and NOT_RUNNABLE test
packages never affect the verdict.

## Noise rules

Do not report:
- Anything the compiler, vet, or the linter already reported (check `tools/lint.txt`) unless lint was UNAVAILABLE.
- Pre-existing issues on unchanged lines. Put at most 5 of them under "Pre-existing".
- Style the project's own linter config silences.
- Intentional behavior the spec or MR description explains.
- Nitpicks a senior engineer would not raise in a review.
- Missing features outside the stated scope.
