# Performance, reliability, and observability checklist

## How to work

1. Read `diff.patch`. Mark each changed function as hot (request path,
   consumer loop, scheduler tick, per-row callback) or cold (startup, admin,
   one-off). Apply allocation rules only to hot paths.
2. For every DB/cache/HTTP/RPC call in the diff, find the loop it is in
   (`grep -n "for " <file>`) and whether the call has a timeout and a bound.
3. Read `tools/cover.txt` only to see whether hot paths have tests; do not
   report coverage numbers as findings.

## Database and cache

- N+1: a query inside a loop over a result set; GORM associations loaded per
  row instead of `Preload`/join; per-item Redis `GET` instead of `MGET`/pipeline. MAJOR.
- Unbounded query: `Find(&all)` without a limit on a table that grows; list
  endpoints without max page size; `SELECT *` with large columns where only ids
  are needed. MAJOR.
- Missing index for a new filter/sort column, or a query that cannot use the
  existing index (function on the column, leading wildcard). MAJOR.
- Transactions held across outbound calls or user waits. MAJOR.
- Cache: no TTL, key cardinality unbounded (per-request keys), stampede on
  expiry for hot keys without singleflight/lock, cache storing errors. MAJOR.
- Redis blocking commands or `KEYS`/`SMEMBERS` on large sets in request paths. MAJOR.
- Bulk work done row by row where a batch insert/update exists. MINOR, MAJOR in a consumer.

## Allocation and CPU

- Slice/map grown in a loop without capacity hint when the size is known. MINOR.
- String concatenation in a loop; `fmt.Sprintf` for simple joins in hot paths;
  `[]byte(s)`/`string(b)` conversions repeated. MINOR.
- Regex compiled per call (`regexp.MustCompile` inside a function). MAJOR in hot paths.
- JSON marshal/unmarshal of large payloads repeatedly for the same data. MINOR.
- Reflection or `interface{}` boxing in tight loops. MINOR.
- Lock contention: a single mutex guarding a hot map with many readers
  (consider `RWMutex` or sharding); lock held while doing work that does not
  need it. MAJOR when on a request path.
- Goroutine per item without a bound; channel buffer sized from input. MAJOR.
- Large struct passed by value in hot loops; closures capturing large state
  per iteration. MINOR.
- Timers/tickers created per request and not stopped. MAJOR.

## Reliability

- Outbound call without timeout (HTTP client, gRPC dial/call, Redis, DB
  context), or with a timeout longer than the caller's budget. MAJOR.
- No retry on transient failure for an idempotent call, or retry without
  backoff+jitter+max attempts, or retry on a non-idempotent call. MAJOR.
- Circuit breaking / bulkhead absent on a dependency that already has an
  established pattern in the repo. MINOR.
- Graceful shutdown: new server, consumer, worker, or ticker not hooked into
  the shutdown sequence (fx lifecycle hooks, signal handler); in-flight work
  dropped on SIGTERM. MAJOR.
- Startup: dependency checks that crash-loop instead of degrading; missing
  readiness/liveness distinction for a new dependency. MINOR.
- Queue consumers: no ack/nack strategy, poison messages retried forever, no
  dead-letter path, ordering assumptions not guaranteed by the transport. MAJOR.
- Schedulers: overlapping runs not prevented, no jitter across replicas,
  clock/timezone assumptions. MAJOR.
- Resource limits: unbounded in-memory buffering of a stream, unbounded map
  growth (per-user state never evicted). MAJOR.

## Observability

- New error path without a log line carrying the ids needed to debug it
  (request id, user/order id) or logging at the wrong level (errors at Info,
  expected conditions at Error). MINOR.
- Logs with unstructured `fmt.Sprintf` where the repo uses structured fields. MINOR.
- New external call or consumer without metrics/tracing where siblings have
  them. MINOR.
- Log spam: logging inside a hot loop per item, or logging the full payload. MAJOR.
- Panics in goroutines not recovered and reported (crash the whole process). MAJOR.

## Evidence to cite

Cite the call line and the enclosing loop or handler line. For timeouts cite
the client construction line. For shutdown cite where siblings register
their hooks.
