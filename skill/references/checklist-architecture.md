# Architecture and design checklist

## How to work

1. Read the project rule files passed to you (root `CLAUDE.md`, `CLAUDE.md`
   in touched dirs, `docs/code-standards/**`). Rules there override this
   checklist; cite the rule file and line in `spec_ref` when a finding comes
   from them.
2. Map the repo layout: `ls internal/ pkg/ cmd/` and read one existing file per
   layer to learn the established pattern (how handlers call services, how
   repositories are injected, how errors flow up).
3. Read `diff.patch` and `changed-symbols.txt`. For each new or changed
   exported symbol ask: which layer owns it, who imports it, does that match
   the pattern found in step 2.
4. Report deviations from the repo's own pattern before generic rules. A
   generic rule only applies when the repo has no established pattern for it.

## Project rules first

Look for and apply, in this order: `CLAUDE.md` sections about architecture,
layers, naming, error handling, DI; `docs/code-standards/*`; `README.md`
architecture sections; `.golangci.yml` `depguard`/`gomodguard` settings.
Quote the rule text in `why`.

## Layers and dependencies

Generic rules when the repo does not say otherwise (typical layout: transport
-> usecase/service -> repository -> infra):

- Transport (handler, resolver, gRPC server, consumer) calling a repository or
  DB client directly, bypassing the service/usecase layer. MAJOR.
- Business logic (validation, calculations, state transitions) living in a
  handler or in a repository. MAJOR.
- Lower layer importing a higher layer (repository importing service, domain
  importing transport). Import cycle avoided only via a hack (init, globals). MAJOR.
- Domain/service packages importing framework packages they do not need
  (gin, grpc, gqlgen generated types) instead of plain structs. MAJOR when it
  makes the service untestable without the framework; MINOR otherwise. ORM
  model structs importing `gorm` are accepted.
- Transaction boundary: `Begin/Commit` inside a repository method that is
  called as part of a larger unit of work, or in a handler. The service/usecase
  owns the boundary; repositories accept a tx or a `Querier`. MAJOR.
- Global mutable state (package-level clients, config, caches) added instead of
  injected via the constructor/fx/wire pattern the repo uses. MAJOR.
- New package with one file and one type that belongs in an existing package;
  or a `utils`/`common`/`helpers` package gaining domain logic. MINOR.

## Interfaces and packages

- Interface declared next to the implementation and exported for the sake of
  mocking, instead of declared by the consumer with only the methods it uses.
  MINOR, MAJOR if the interface has > 5 methods and only 1-2 are used.
- Interface with a single implementation and no test double: unnecessary
  abstraction. MINOR.
- Constructor returning a concrete type while the rest of the repo returns
  interfaces (or the reverse). MINOR.
- Exported identifier that is only used within its package. MINOR.
- Package naming: `package models` holding behavior, stuttering names
  (`order.OrderService`), generic names (`types`, `base`). MINOR.
- Struct with > 7 injected dependencies: the type does too much. MAJOR if the
  diff added the 8th.
- Duplicated logic with an existing helper in the repo (`grep` for the
  operation before flagging). MAJOR when the duplicate diverges in behavior.

## Contracts

- Public API shape: new endpoint/resolver/RPC inconsistent with siblings
  (naming, pagination style, error envelope, id types, timestamp format).
  MAJOR.
- Breaking change to an existing contract: removed/renamed field, changed type,
  changed enum value or proto field number, changed event payload, without a
  version or compatibility note. BLOCKER when consumers exist in the repo or
  the spec lists external consumers; MAJOR otherwise.
- Proto/GraphQL/OpenAPI schema changed but generated code not regenerated, or
  regenerated code changed by hand. BLOCKER.
- Events/messages: payload without schema version, subject/topic naming
  inconsistent with existing ones, consumer not idempotent for at-least-once
  delivery. MAJOR.
- Configuration: new required config key without a default, validation at
  startup, and documentation in the env example. MAJOR.
- Database schema: migration not reversible, missing index for a new query
  pattern, nullable column without a stated reason, enum stored as string vs
  int inconsistently with the rest of the schema. MAJOR.

## Evidence to cite

Cite the import line or call line that crosses the boundary, plus one
existing file that shows the established pattern (`file:line`). For contract
breaks cite the removed/changed line and one consumer.
