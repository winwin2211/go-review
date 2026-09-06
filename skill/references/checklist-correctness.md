# Correctness and concurrency checklist

## How to work

1. Read `diff.patch` fully. For every changed function, open the file and read
   the whole function plus its direct callers (`grep -rn "FuncName("`).
2. Read `tools/summary.txt`, `tools/vet.txt`, `tools/test.txt`, `tools/lint.txt`.
   A `DATA RACE` block or a failing test is a BLOCKER with the tool line as evidence.
3. Walk the list below against each changed function. Report only what you can
   point to at a `file:line` on a changed line. Pre-existing defects on
   unchanged lines go in a separate list with `"line"` set and the title
   prefixed `PRE-EXISTING:`.
4. Do not report what `tools/lint.txt` already reports unless lint is UNAVAILABLE.

## Errors

- Error discarded: `_ = f()`, `if err != nil { return nil, nil }`, `err` shadowed by `:=` inside a block and never checked (`if err := ...; err != nil` fine; `x, err := ...` inside `if` that shadows an outer `err` later returned is not).
- Error returned without context: `return err` from a function that made an outbound call or has more than one error source. Require `fmt.Errorf("op %s: %w", id, err)`.
- `%v` instead of `%w` when the caller uses `errors.Is/As` on the result.
- Sentinel or typed errors compared with `==` after wrapping; must use `errors.Is/As`.
- Errors logged and returned (double reporting), or logged and dropped on a path the caller must know about.
- `panic` or `log.Fatal` outside `main`/init paths; recover that swallows everything including runtime errors that indicate corruption.
- Partial success not surfaced: batch loops that `continue` on error without collecting or counting failures.
- HTTP/gRPC handlers mapping all errors to 500 when the service returns typed validation/not-found errors (and vice versa: leaking internal error text to clients).

## Context and cancellation

- `context.Background()`/`TODO()` created in request paths instead of using the caller's `ctx`.
- `ctx` accepted but not passed to DB, HTTP, Redis, NATS, gRPC calls.
- Goroutine started from a request handler that outlives the request without its own detached context and lifecycle (leak on cancellation).
- `select` without `case <-ctx.Done()` in a loop that waits on a channel or ticker.
- Timeouts: `context.WithTimeout` result's `cancel` not deferred; deadline derived from a config value that can be zero (meaning "no timeout").

## Concurrency

- Shared map, slice, counter, or struct field written from more than one goroutine without a mutex, atomic, or channel ownership. Check `go` statements and callbacks (HTTP handlers, NATS subscribers, timers) that touch package-level or struct state.
- Mutex held across a blocking call (I/O, channel send, `wg.Wait`), or lock/unlock pairs that can skip the unlock on an early return (require `defer mu.Unlock()` or a clear reason).
- Copying a struct that contains a `sync.Mutex` or `sync.WaitGroup` (vet reports `copylocks`; if vet is UNAVAILABLE, check manually).
- `sync.WaitGroup`: `Add` inside the goroutine, or `Wait` that can be reached with zero `Add`.
- Unbounded goroutine spawn in a loop over user-controlled input; no semaphore or worker pool.
- Channel misuse: send on a channel with no guaranteed receiver (leak or block), close by the receiver, close twice, `range` over a channel that is never closed, unbuffered channel used as a queue between a producer and a slow consumer inside a request.
- Loop variable captured by a goroutine or closure on Go < 1.22 (check `go.mod` `go` directive); on >= 1.22 per-iteration semantics apply, do not report.
- `time.After` inside a hot loop (timer leak until fired); prefer `time.NewTimer` with `Stop`.
- `sync.Once` / lazy init that can return a partially initialized value on error.
- `errgroup` used without `WithContext` when workers do cancellable I/O, or the group's ctx not passed into the workers. A plain `errgroup.Group` for CPU-only fan-out with no cancellation need is fine.
- Ticker/cron/background loops: no exit path on shutdown, no recover, no backoff on repeated failure.

## Resources and transactions

- `rows`, `resp.Body`, files, gRPC streams, `*sql.Tx` not closed on every path; `defer` placed after an error check that can return early before it (`resp, err := ...; if err != nil { return }; defer resp.Body.Close()` is correct; `defer` before the check is wrong).
- `rows.Err()` not checked after a `rows.Next()` loop.
- Transaction: `Begin` without `Rollback` on every error path; commit error ignored; two writes that must be atomic done outside a transaction; transaction held while calling an external service.
- Read-modify-write on a row without `SELECT ... FOR UPDATE`, optimistic version check, or an atomic `UPDATE ... SET x = x + ?` when concurrent updates are possible (balances, counters, inventory).
- Idempotency: a retried operation (queue consumer, HTTP client with retry) that inserts, increments, or sends without an idempotency key or dedup check.
- Cache: write-through order (DB then cache), stale read after write, cache key missing a tenant/user dimension, no TTL on unbounded keys.

## Logic and types

- Nil: method on a nil pointer receiver that dereferences fields; nil map write; nil slice vs empty slice where JSON output differs (`null` vs `[]`) and the API contract cares; interface holding a typed nil.
- Zero values used as "not set": `0` for an ID, `""` for an optional field, `time.Time{}` compared with `IsZero` inconsistently.
- Integer: overflow in money or quantity math, `int` for 64-bit amounts on 32-bit targets, float used for money, division by zero from user input, unsigned subtraction underflow.
- Off-by-one in pagination (`limit`, `offset`, cursor comparison `>` vs `>=`), range boundaries, time windows (inclusive/exclusive end), `len-1` on empty slices.
- Slices: `append` to a sub-slice aliasing the parent; returning internal slices/maps that callers can mutate.
- Maps: iteration order relied on for output or for "first match" semantics.
- Time: `time.Now()` without a clock abstraction in code that must be tested; local time vs UTC mixed; `time.Duration` multiplied by an untyped constant with the wrong unit (`timeout * time.Second` where `timeout` is already a Duration).
- String/bytes: byte indexing on UTF-8 strings; `strings.Split` on empty input yields `[""]`.
- JSON: field tags missing or mistyped (`json:"userId"` vs `user_id`), `omitempty` on a bool/int that must be sent as zero, `int64` IDs sent to JS clients without string encoding when the contract requires it.
- Comparisons of errors, structs with slices, or `time.Time` with `==`.
- Switch without `default` on an enum that has since grown; `iota` enums persisted by value with a reordering in the diff.
- Retry loops with no max attempts or no backoff/jitter; retrying non-idempotent calls; retrying on non-retryable errors (4xx, validation).
- Generics: type parameter constrained by `any` where the body compares or orders values (needs `comparable`/`cmp.Ordered`); zero value `*new(T)` returned on error paths and indistinguishable from a real value; generic helper that hides an allocation or a copy of a large struct per call.

## Evidence to cite

Quote the exact changed line(s). For concurrency, name both writers (or writer
and reader) with `file:line` each. For tool findings quote the `tools/*.txt`
line. For a missing close/rollback, cite the early-return line that skips it.
