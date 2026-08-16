# Plan 073: Runtime TypeScript validation

Plan 069 proved compile conformance: the Microsoft corpus passes under the
tsc accept/reject oracle, and typescript.js 5.4.5 itself runs end to end. But
compile-only says nothing about executing real `.ts` sources: value-level
behavior of type-erased files, module graphs in ts_mode, the syntax shapes
real libraries use that hand-written fixtures never hit.

Status: done (sessions 310-311).

## Contents

- [The corpus](#the-corpus)
- [The oracle](#the-oracle)
- [Engine support](#engine-support)
- [Parser gaps closed](#parser-gaps-closed)
- [Regression verification](#regression-verification)

---

## The corpus

Two layers, both checked in:

1. **Handbook syntax corpus** (`test/typescript/handbook/`): 43 small files
   organized along the TS Handbook's structure (everyday types, narrowing,
   functions, object types, generics, keyof/typeof/indexed access,
   conditional + infer, mapped types, template literal types, classes,
   declare, import/export type, overloads, accessors). Each accept file
   prints deterministic output; four reject files name non-erasable syntax
   (enums, namespaces, parameter properties, angle-bracket assertions) that
   the engine must refuse to compile. Runs as `just ts-handbook` and is part
   of `just test-local`.

2. **Runtime library sweep** (`scripts/verify_ts_libraries.py`,
   `just ts-runtime`): unmodified source files from npm packages fetched
   into `test/tscorpus/` (gitignored), driven by
   `scripts/ts_runtime_checks/*.ts`:
   - microdiff 1.4.0 (single file, 104 lines)
   - zustand 5.0.3 vanilla.ts (single file, 100 lines)
   - valtio 2.1.3 vanilla.ts, with proxy-compare 3.0.1 vendored as a bare
     specifier under `test/tscorpus/node_modules/` (resolved by the engine's
     node_modules walk, never leaving the repo)
   - @preact/signals-core 1.14.4 index.ts
   - jotai 2.20.2 vanilla package tree (`src/vanilla/`: atom, store,
     typeUtils, internals)

   No source file is rewritten. The sources stay byte-identical to upstream;
   all wiring lives in the drivers and the vendored node_modules layout.

## The oracle

The engine itself, twice: tsc strips each `.ts` to a `.js` mirror in
`test/tscorpus/_transpiled/` (same relative layout), the driver runs once
against the `.ts` sources and once against the mirrors, and stdout must
match. tsc runs with `--target es2022 --module esnext --skipLibCheck
--outDir`; TS2339-style errors do not block emit. The post-processing step
(SPEC_RE) rewrites `.ts` import specifiers to `.js` in the emitted files
only, and `drop_undeclared_export_names` removes same-file interface names
from trailing export lists (tsc keeps them, making the mirror an invalid
module; its `//` comments inside the list are stripped before the name
check). No node, no source rewrites.

The node oracle of session 310 is gone. The mirror run is the acceptance
bar: any behavior the engine executes must reproduce exactly on the
stripped output, which is the same code with the types erased. A library
passes only if both sides run and print identically.

An engine-side transpiler oracle (typescript.js `ts.transpileModule` on our
own engine) was tried first and is blocked by a pre-existing codegen bug:
`substituteNode` resolves undefined in `getPipelinePhase` (`TypeError:
undefined is not a function`), reproduced minimally with
`const q = 1; q.foo;`. It fails on `--no-optimize` and on the pre-session
binary, so it is not this session's changes. The repro lives in
`test/libcorpus/typescript.js`; fixing it is its own session.

## Engine support

The sweep needed two engine features to run unmodified multi-file sources:

1. **node_modules resolution** (src/module.c3): bare specifiers now walk the
   ancestor directories for `node_modules/<pkg>/`, probing subpath files,
   `package.json` main, and index files in order, hooked into
   `call_resolve_name` before the extension-probe fallback. This is what
   lets valtio's `import { createProxy } from 'proxy-compare'` resolve
   without touching the source. Relative specifiers are unaffected.
2. **ts_mode type erasure**: see the parser gaps below.

## Parser gaps closed

Session 310 closed four (see below). Session 311 found three more:

5. **Top-level `type` aliases with no trailing `;` desynced the hoist
   pre-scan** (functions.c3): `hoist_global_fn_decls` classified the
   `function` after a semicolonless alias as an expression (the alias's
   last token, an identifier, is not a statement terminator), so the name
   was never recorded and a following `export { f }` named no runtime
   binding. The pre-scan now skips whole `type` aliases like the statement
   pass does, and its statement-start decision is ASI-aware: a line break
   after a token that completes a statement starts a new one. That second
   half is a plain-JS fix too (`const x = 1\nfunction f() {}` in a module
   previously exported nothing). The first attempt at the alias skip left
   `type` on the compiler's pushback stack (the pre-scan's restore rewinds
   only the lexer), which broke every `import type` until the fall-through
   re-consume switched to `advance()`.
6. **`typeof` fast paths split optional chains** (expressions.c3): the
   bare- and parenthesized-identifier paths under TYPEOF emit TYPEOFIDENT
   directly and only checked `.` `[` `(` as a member continuation, so
   `typeof a?.b` and `typeof (a).b` left the continuation dangling (a
   SyntaxError from the enclosing parse). The continuation set now matches
   the member chain: `.` `[` `(` `?.` and a template literal.
7. **Object-type member names that are statement keywords** (ts_skip.c3):
   `delete(key: K): boolean` inside an object type stopped the type at the
   keyword. `ts_token_stops_type` is now gated on depth 0.

Session 310's four, still current:

1. **`ts_swallow_to_semi` ate the next statement** (ts_skip.c3): the ASI
   check ran after consuming the token that crossed the line break, so
   `export type A = Str` followed by `const q = 5` lost its `const`, and a
   following `console.log(...)` vanished whole because `.` kept the loop
   going. The stop now runs before consuming, with a continuation set
   (`|`, `&`, `?`, `:`, `.`, `,`, `=>`) for multi-line types.
2. **`keyof { ... }` broke** (ts_skip.c3): `{` after an IDENTIFIER always
   tripped the "enclosing body" heuristic. The skipper now tracks the
   previous token's text; `{` and a line break after a contextual type
   operator (`keyof`, `typeof`, `infer`, `as`, `satisfies`, `readonly`,
   `is`, `asserts`, `abstract`) continue the type instead of ending it.
   Return annotations (`(): Foo {`) still stop, as they must.
3. **`export type` with multi-line generic parameters broke** (ts_skip.c3):
   the alias form now routes through `skip_generic_params` + `skip_type`
   instead of the flat swallower (which does not track angle depth). The
   brace-list re-export form stays with the swallower.
4. **Inline type specifiers and exported overloads broke** (statements.c3):
   `import { type X, value }` parsed `type` as a binding name; the
   `export function` path had no overload-signature check, so valtio's five
   consecutive `export function unstable_replaceInternalFunction(...)`
   signatures died on the first one. Both now erase in ts_mode.

## Regression verification

- Handbook corpus 43/43 (wired into `just test-local`).
- Library sweep 5/5: both the `.ts` sources and the tsc-stripped mirrors
  run under the engine and print identically (microdiff, zustand, valtio,
  signals-core, jotai).
- `just ts-conformance` (Microsoft corpus): 0 failures.
- `just rosetta` 42/42; `just modules` 15/15 (includes the new
  t15_hoist_asi fixture); `just test-local` green.
- test262: phases 0-3 spot-checked 0 fail / 0 unexpected CE (the ASI and
  typeof fixes touch non-TS paths, so the targeted-subset run still stands
  at 100% from session 309).
