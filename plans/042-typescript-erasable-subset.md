# Plan 042: TypeScript Erasable-Subset Support

**Status:** Proposed
**Priority:** Medium — quality-of-life; lets `.ts` files run natively without a build step
**Reference:** [TypeScript 5.8 `--erasableSyntaxOnly`](https://www.typescriptlang.org/docs/handbook/release-notes/typescript-5-8.html#the---erasablesyntaxonly-option), [Node 22.6 `--experimental-strip-types`](https://nodejs.org/api/typescript.html), [Deno type stripping](https://deno.com/blog/v1.31)

## Goal

Run `.ts` files natively. The runtime **erases** type syntax at parse time — it does not type-check. Users run `tsc --noEmit --erasableSyntaxOnly` (or their editor's TS server) for checking; we run the code.

Non-goal: type checking, `enum` codegen, decorator metadata, JSX. If a user needs those, they compile to `.js` first.

## Design

### Supported subset (matches TS 5.8 `--erasableSyntaxOnly`)

Purely erasable — no runtime shape:

- Variable/param/return type annotations: `let x: number`, `fn(a: T): U`
- `interface` and `type` declarations (skipped whole)
- `as`, `as const`, `satisfies`, non-null `!` postfix
- Generic type parameters and arguments: `<T extends U>`, `identity<string>(...)`
- `declare` statements (skipped whole)
- `import type` / `export type`, type-only specifiers (`import { type Foo, bar }`)
- `readonly`, `public`, `private`, `protected`, `override` on class members (stripped, no semantics)
- Abstract classes / methods (`abstract` stripped)
- Definite assignment `!` on fields, optional `?` on params/fields
- Index signatures `[k: string]: T` (skipped)
- Call/construct signatures inside interfaces (skipped with the interface)

### Rejected (parse error, matches `--erasableSyntaxOnly`)

- `enum` — emits a runtime object
- `namespace`/`module` with values — emits an IIFE
- Constructor parameter properties: `constructor(public x: number)` — emits assignments
- `import =` / `export =` — CommonJS interop
- Legacy decorator metadata emission (decorators themselves out of scope entirely)
- JSX (out of scope; needs codegen)

Rejecting these keeps our implementation a pure token skipper and matches the checkable subset. `tsc --erasableSyntaxOnly` flags the same set, so users see errors in their editor before running.

### Source position preservation

Requirement: stack traces, `SyntaxError` locations, and (future) source maps must point at the original `.ts` line/column, not a rewritten offset.

Approach: **no rewrite pass**. The lexer/parser consumes and discards type tokens *in place*. The AST for `let x: number = 1` is identical to `let x = 1`, but the `x` and `1` tokens keep their original `(line, col, offset)` from the `.ts` source. Nothing shifts.

Consequences:
- Existing error reporting and (planned) debug info Just Work — they already carry source positions per node.
- No source-map file needed for our own runtime. If we later want to hand traces to external tools expecting `.js`, we can emit an identity source map, but that's out of scope here.

### Trigger

Two options; recommend **(a)** for simplicity:

- (a) File extension: `.ts` → TS mode; `.js` → plain JS. Extension is checked when the source is loaded (`module.c3`, REPL loader, `test262_runner`).
- (b) Pragma `// @ts-runtime` at file top — rejected: fragile, and TS files often don't start with a comment.

TS mode is a single boolean on the `Lexer` / `Parser` context. When off, all TS-only tokens and productions are inaccessible (they lex as identifiers or produce syntax errors as today).

## Implementation

Scope estimate: ~1500 LoC across lexer + parser. No VM, bytecode, or GC changes.

### Phase 1 — Lexer (`src/lexer.c3`)

1. Add a `ts_mode: bool` field on `Lexer`; set from the extension when the lexer is constructed.
2. Contextual keywords (only recognized in `ts_mode`, and only in identifier-position lookups — TypeScript treats these as identifiers everywhere else):
   `type`, `interface` (already reserved), `as`, `satisfies`, `declare`, `readonly`, `abstract`, `override`, `namespace`, `keyof`, `infer`, `is`, `unique`, `asserts`, `out`, `in` (variance — already a keyword)
3. No new punctuators. `?`, `!`, `<`, `>`, `|`, `&`, `:` are all reused; disambiguation is the parser's job.

### Phase 2 — Type-expression skipper (`src/compiler/ts_skip.c3`, new)

A single routine `skip_type()` that consumes a full TypeScript type expression by bracket balancing. It never builds an AST — it just advances the token cursor.

Rules:
- Balances `(`, `[`, `{`, `<`; stops at the first unbalanced `,`, `)`, `]`, `}`, `>`, `;`, `=`, or newline-with-ASI-eligible-follower at depth 0.
- Handles union `|`, intersection `&`, `keyof`, `typeof`, `infer`, conditional `T extends U ? A : B`, template literal types, tuple types with rest.
- Nested `{ ... }` in mapped/object types is skipped as a balanced brace group — we don't parse its contents.
- Function-type arrows `(a: T) => U` are skipped by continuing past `=>` at depth 0 when inside a type context.

This is the whole "type grammar" implementation: one bracket balancer with a small stop-set. Because we never interpret types, we don't need to track every production TS adds.

### Phase 3 — Parser hooks (`src/compiler/*.c3`)

Points where `skip_type()` or a related helper is called (all guarded by `ts_mode`):

- **Variable decls** (`statements.c3`): after binding name, if `:` seen → `skip_type()`. Same for destructuring patterns.
- **Function params** (`functions.c3`): after each param name, optional `?`, optional `: type`. Return type after `)` → optional `: type`.
- **Function/class generics**: at `<` after function/class name → `skip_generic_params()` (balanced `<...>`).
- **Call/new generics**: `foo<T>(x)` — the ambiguity with `<` comparison is resolved by TS's speculative parser. We use the same trick: try to parse `<...>(`; if it fails, rewind and treat `<` as less-than. Requires a token-stream checkpoint (already have this for regex/division disambiguation).
- **Expressions** (`expressions.c3`): postfix `as T`, `satisfies T`, `!` (non-null) → skip.
- **Class members** (`class.c3`): strip leading `public|private|protected|readonly|override|abstract` modifiers; optional `?`/`!` after field name; `: type` on fields; generics/return types on methods. **Reject** constructor parameter properties (any modifier on a constructor param).
- **Interface/type/declare statements** (`statements.c3`): skip the whole statement to the matching `}` or `;`. Produce a no-op AST node so line numbering is preserved.
- **Import/export** (once ESM lands, plan 037): recognize `import type`, `export type`, and per-specifier `type` — drop these entirely.
- **Enum / namespace / import=**: emit a parse error naming the erasable-syntax rule that was violated. Point at the offending keyword.

### Phase 4 — Loader

`module.c3` and `test262_runner` (and REPL): when opening a file, sniff the extension. `.ts` → set `ts_mode`. `.mts`/`.cts` accepted the same way. No change to the module resolution beyond that.

### Phase 5 — Tests

- `test/typescript/` — small `.ts` corpus:
  - Basic annotations, generics, `as`/`satisfies`, non-null.
  - `interface` and `type` are erased (referencing them at runtime is a ReferenceError, as expected).
  - Class with `private`/`readonly`/`?`/`!` runs.
  - Rejection tests: `enum`, `namespace X { export const y = 1 }`, `constructor(public x: number)`, `import Foo = require('foo')` — each must produce a specific SyntaxError.
  - Source-position test: throw inside an annotated function, assert the reported line/column matches the `.ts` source exactly.
- Run `tsc --noEmit --erasableSyntaxOnly` on the corpus in CI as an oracle: anything `tsc` accepts, we must accept; anything `tsc` rejects for this rule, we should reject too. This gives us a free conformance suite without writing our own type checker.

## Open questions

1. **`.tsx`** — support later or never? Recommend never; JSX needs codegen.
2. **`tsconfig.json`** — do we read it? Recommend no. Behavior is fixed to the erasable subset regardless of user config; `tsc` handles project config on its side.
3. **Triple-slash directives** (`/// <reference ... />`) — skip as comments. Already handled by the existing comment lexer; verify.
4. **`const` type parameters** (`<const T>`) — TS 5.0. Trivial to skip; include in Phase 2.

## Rollout

Single branch, single PR. Behind the extension check, so it's off for all existing `.js` inputs — no risk of regressing the JS pipeline. Ship once the rejection tests and the source-position test pass, and the `tsc --erasableSyntaxOnly` oracle over the corpus is green.
