# Security checklist

## How to work

1. Read `diff.patch`. List every place user- or network-controlled data enters
   the changed code: HTTP params/body/headers, gRPC request fields, GraphQL
   args, queue messages, config, files, environment.
2. For each entry point trace the data to every sink: SQL, shell, file path,
   URL, template, log, redirect, header, another service.
3. Read `tools/lint.txt` (gosec lines) and `tools/vuln.txt`. Each reachable
   vulnerability in `vuln.txt` is a BLOCKER, rule-based, evidence = OSV id +
   the trace line.
4. Report only on changed lines unless a changed line newly exposes a
   pre-existing sink (then cite both).

## Input and injection

- SQL built by concatenation or `fmt.Sprintf` with any non-constant part; GORM `Where(fmt.Sprintf(...))`, `Raw`, `Order(userInput)`, `Table(userInput)`; `?` placeholders required. Column/sort names from input must be allow-listed.
- NoSQL/Redis: keys or Lua scripts built from unvalidated input; `KEYS pattern` with user input.
- Command execution: `exec.Command("sh", "-c", ...)` with any variable; arguments not separated.
- Path traversal: `filepath.Join(base, userInput)` without `filepath.Clean` + prefix check; `..` accepted; `os.Open` on a user-supplied name.
- SSRF: outbound HTTP to a URL or host from input without an allow-list; redirects followed to internal ranges; DNS rebinding not considered for long-lived allow-lists.
- Template/HTML: `template.HTML(userInput)`, `text/template` used for HTML output.
- Deserialization: `json.Unmarshal` into `interface{}` then type-switched into privileged paths; `gob`/`yaml` from untrusted sources; unbounded body size (`http.MaxBytesReader` missing), unbounded array lengths, no `DisallowUnknownFields` where the contract requires strictness.
- Validation: numeric bounds (qty, amount, page size), string length, enum membership, UUID format; validation done in the handler but bypassed by another entry point (queue consumer, internal gRPC) into the same service method.
- Mass assignment: binding request bodies directly into DB models (GORM `Save(&model)` from a bound struct) exposing fields like `role`, `balance`, `is_admin`.
- Integer parsing: `strconv.Atoi` result used as an index or size without bounds.
- GraphQL: no query depth limit, complexity limit, or batching cap on the public schema; introspection enabled in production builds; resolvers that accept unbounded list arguments.

## Authentication and authorization

- New endpoint/resolver/RPC without the auth middleware or interceptor the rest of the group uses; check the router/registration diff, not just the handler.
- Object-level authorization: fetch by id from input without checking the caller owns/can access it (IDOR); list endpoints that filter by a user id taken from the request instead of the session.
- Role checks done client-side, in GraphQL directives that the internal schema skips, or only in one of two schemas (public vs internal gqlgen).
- Admin/internal endpoints reachable on the public listener; internal gRPC without mTLS or network policy assumption documented.
- JWT: `alg` not pinned, expiry not checked, claims trusted without signature verification, tokens accepted from query strings, refresh token reuse not detected.
- Session/user id derived from a header that clients can set (`X-User-Id`) on a public path.
- Rate limiting or lockout missing on login, OTP, password reset, expensive endpoints.
- CSRF: state-changing endpoint authenticated by cookie/session without a CSRF token or SameSite=Strict/Lax plus origin check; webhook and health endpoints that verify a signature instead of the standard middleware are acceptable and must not be flagged.

## Secrets and logging

- Secrets, tokens, private keys, or connection strings in code, test fixtures, config committed in the diff, or default values.
- Logging request bodies, headers (`Authorization`, cookies), tokens, passwords, PII (email, phone, wallet private material) at any level; error messages that embed them.
- Error responses leaking stack traces, SQL, file paths, or internal hostnames to clients.
- Debug endpoints (`pprof`, `expvar`, GraphQL playground/introspection) exposed without auth in non-dev builds.

## Crypto and tokens

- `math/rand` for tokens, OTPs, nonces, session ids; must be `crypto/rand`.
- MD5/SHA1 for passwords or signatures; passwords not hashed with bcrypt/scrypt/argon2; comparison of MACs/tokens with `==` instead of `hmac.Equal`/`subtle.ConstantTimeCompare`.
- AES in ECB, static IV/nonce, key derived from a short string without KDF, unauthenticated encryption where integrity matters.
- TLS: `InsecureSkipVerify: true`, custom `VerifyPeerCertificate` that accepts everything, min version below 1.2.
- Signature verification of webhooks/callbacks missing or done after side effects; replay not prevented (no timestamp/nonce check).
- Wallet/chain specifics: private key material in memory longer than needed, logged, or sent to another service; signing user-controlled payloads without domain separation.

## Network and files

- HTTP client without timeout (`http.DefaultClient`, `&http.Client{}`), or server without `ReadHeaderTimeout`/`ReadTimeout`.
- CORS `AllowOrigins: *` with credentials; reflecting the `Origin` header.
- Open redirect: `Location` from input without allow-list.
- Files written with permissive modes (`0666`, `0777`), temp files predictable, uploads without type/size limits, served from a user-controllable path.
- WebSocket: origin check disabled; no message size limit; no auth on upgrade.

## Dependencies

- New dependency added in `go.mod`: check it is maintained, pinned to a tagged release (no pseudo-version of a fork), and not replacing a stdlib capability.
- `replace` directives pointing at local paths or unreviewed forks.
- `govulncheck` unavailable: say so; do not claim dependencies are clean.

## Evidence to cite

Quote the source line where untrusted data enters and the sink line; for
missing auth cite the route registration line and a sibling route that has
the middleware. For crypto cite the call. For vuln cite the OSV id and the
function in the trace.
