# Report format (English)

## Terminal report

Print exactly this structure. Omit a severity section when it has no
findings. Keep each finding under 12 lines.

```
go-review — <repo-name> <target> vs <base> @ <short-sha>
Tools: build OK | vet OK | lint 0 new | test 42 pass, 3 not runnable locally | race OK | vuln none
Verdict: REQUEST CHANGES (2 blockers, 1 major)

BLOCKER
[B1] <title> — <file>:<line>
  Evidence: <verbatim>
  Why: <why>
  Fix: <fix>
  Spec: <spec_ref>                      (only when non-empty)

MAJOR
[M1] ...

MINOR
[N1] ...

SDD/TDD
  Change: substantive (<nontest-lines> non-test lines; new handler List)   | trivial (reason)
  Spec: <path> (matched by ticket:XBI-100, git-log)                        | none found (nearest: <path>, <path>)
  Plan: <path>                                                             | none
  Spec rubric: 8/10 (missing: risks/rollback, acceptance criteria)
  Requirement -> test
    AC1 valid order returned          -> TestPlaceOrder/success (internal/service/order_test.go:18)
    AC2 qty 0 -> ErrInvalidQty        -> TestPlaceOrder/invalid_qty (internal/service/order_test.go:19)
    AC3 repo error wrapped            -> MISSING (critical: error path of external call)
  Coverage (changed packages): internal/service 91.7%, internal/handler 0.0%

Needs human judgment
  - <title> — <file>:<line> (score 65): <why>

Pre-existing (not blocking)
  - <title> — <file>:<line>

No artifacts left: verified
```

Tools line rules: `test` shows `N pass` when OK, `N failing` when FAIL,
`N no tests` when `tools/test-classified.txt` has `NO_TESTS` packages;
`race` shows `FAIL` when `tools/test.txt` contains `DATA RACE`; `vuln`
shows `none`, `N reachable`, or `unavailable`. Any `UNAVAILABLE(reason)`
shows as `<tool> unavailable (<reason>)`.

Ids: BLOCKER B1..Bn, MAJOR M1..Mn, MINOR N1..Nn, in order of file path then
line.

## MR summary

`summary.md` is Markdown with the same content, except each finding is one
bullet in the following form (the body goes into the inline discussion):

```
- **B1** <title> — <file>:<line>
```

Start with the Verdict line, then Tools, then the bullets by severity, then
the SDD/TDD block as a fenced block, then Needs human judgment. Do not
include "No artifacts left".
