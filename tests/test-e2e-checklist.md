# End-to-end acceptance (manual)

Date: 2026-09-06   Commit: 1aaadb3

## dirty (expect REQUEST CHANGES)
- [ ] Tools line shows test FAIL / race FAIL
- [ ] BLOCKER: data race in internal/counter/counter.go (tools or correctness)
- [ ] BLOCKER or MAJOR: swallowed error internal/service/order.go (return nil, nil)
- [ ] BLOCKER: SQL concatenation internal/repo/order_repo.go (security)
- [ ] MAJOR: handler calls repository directly internal/handler/order_handler.go (architecture)
- [ ] BLOCKER: substantive change, no spec (sdd-tdd) with nearest candidates = none
- [ ] MAJOR: TestPlaceOrder has no assertion (sdd-tdd)
- [ ] Verdict: REQUEST CHANGES
- [ ] Last line: No artifacts left: verified
- [ ] `git -C dirty status --porcelain` is empty after the run

## clean (expect APPROVE or APPROVE WITH COMMENTS)
- [ ] No BLOCKER, no MAJOR
- [ ] SDD block: spec + plan found, rubric 10/10, matrix AC1-AC3 all mapped to TestPlaceOrder subtests
- [ ] Last line: No artifacts left: verified
- [ ] `git -C clean status --porcelain` is empty after the run

## Notes / false positives seen
<fill>
