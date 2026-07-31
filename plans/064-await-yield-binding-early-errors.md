# Plan 064 — `await` / `yield` reserved-word early errors in async contexts

Queued follow-up. Same family as the phase-15 class-body under-rejection
(engine ACCEPTS source it must REJECT), but a different root cause: reserved-word
handling in async/generator contexts rather than class-body grammar.

## Failing tests (6)

Phase 21:
- `language/expressions/await/await-BindingIdentifier-nested.js`
- `language/expressions/async-generator/early-errors-expression-await-as-function-binding-identifier.js`

Phase 24 (all `flags: [onlyStrict]`):
- `language/statements/for-await-of/async-func-decl-dstr-array-elem-init-yield-ident-invalid.js`
- `language/statements/for-await-of/async-func-decl-dstr-array-elem-nested-array-yield-ident-invalid.js`
- `language/statements/for-await-of/async-func-decl-dstr-array-elem-nested-obj-yield-ident-invalid.js`
- `language/statements/for-await-of/async-func-decl-dstr-array-elem-target-yield-invalid.js`

## Measured behavior

**Oracle note:** these are `onlyStrict` tests and this engine is strict-only, so
the correct oracle is `node --check` on a `"use strict"` source. A bare sloppy
`node --check` ACCEPTS most of these and is the wrong comparison — I initially
mis-read the cluster that way.

Verified with the correct oracle:

| shape | ours | node (strict) |
|---|---|---|
| `async function fn(){ for await ([ x = yield ] of [[]]) {} }` | ACCEPT | reject |
| `async function fn(){ for await ([ [ x = yield ] ] of [[[]]]) {} }` | ACCEPT | reject |
| `async function fn(){ for await ([ { x = yield } ] of [[{}]]) {} }` | ACCEPT | reject |
| `async function fn(){ for await ([ yield ] of [[]]) {} }` | **reject (correct)** | reject |
| `async function foo(){ function await(){} }` | ACCEPT | reject |
| `(async function* await(){});` | ACCEPT | reject |

Controls that must KEEP working (no over-rejection):
- `async function fn(){ var q = 1; return q; }` → accept
- `async function fn(){ for await (const v of []) {} }` → accept
- `function await(){}` at sloppy top level → node accepts; we accept. Unchanged.

## Two sub-clusters

**A. `await` as a BindingIdentifier inside an async context** (2 tests).
`await` is reserved in an async function body and in an async generator's own
name position. We accept both. Note the nesting: the inner `function await(){}`
is an *ordinary* function, but it is lexically inside an async function, and the
restriction still applies there.

Also found, with no test262 coverage in these phases — fix alongside:
- `(async function await(){});` → we ACCEPT, node (strict) rejects.

**B. `yield` as an IdentifierReference in for-await destructuring** (4 tests).
In strict mode `yield` is reserved, so it cannot appear as an
IdentifierReference in a destructuring Initializer or DestructuringAssignmentTarget.

Important: the 4th shape (`[ yield ]` as target) **already rejects correctly**,
so that test failing has a different cause from the other three. Diagnose it
separately before assuming one fix covers all four — do not let a single fix for
the Initializer path be assumed to cover the target path.

## Approach

Find where BindingIdentifier / IdentifierReference validity is decided and make
the async/generator context propagate into it — including into nested ordinary
functions for the `await` case, and into destructuring sub-patterns for `yield`.
The likely shape, given the class-body cluster's diagnosis, is a restriction
checked at some parse sites and not others.

If the restriction is currently hand-checked at N sites, prefer one shared
predicate over adding more copies — this repo has been bitten repeatedly by
invariants maintained in N places (BACKLOG session 302; plan 063).

## Guard against over-rejection

This is the main risk, as with the class-body cluster: rejecting VALID code is
worse than the current under-rejection. For every restriction added, add a
positive test proving the legal form still compiles. Phase 21/24 pass counts must
RISE, and unexpected-CE must not rise.

## Validation

1. All 6 named tests pass via `--single`.
2. All shapes in the table above match node (strict) — including the two
   uncovered extras.
3. `--phase 21 --phase 24`. Baseline before any of this session's work:
   phase 21 = 2128 pass / 3 fail, phase 24 = 1409 pass / 5 fail.
   **Coordinate with plan 063**, which is separately fixing the 5 phase-24
   async-gen throw failures; re-measure the baseline at start rather than
   assuming these numbers.
4. `just rosetta` 41/41 · `just test-golden-bytecode` 28/28 · `just test-local` green.
5. Regression tests under `test/` — negative AND positive cases.
