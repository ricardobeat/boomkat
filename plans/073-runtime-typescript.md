# Plan 073: Runtime TypeScript validation

Plan 069 proved compile conformance: the Microsoft corpus passes under the
tsc accept/reject oracle, and typescript.js 5.4.5 itself runs end to end. But
compile-only says nothing about executing real `.ts` sources: value-level
behavior of type-erased files, module graphs in ts_mode, the syntax shapes
real libraries use that hand-written fixtures never hit.

Status: done (session 310).

## Contents

- [The corpus](#the-corpus)
- [The oracle](#the-oracle)
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
   - valtio 2.1.3 vanilla.ts + proxy-compare 3.0.1 vendored beside it (the
     one bare-specifier import, rewritten to the local file; the rewrite is
     recorded in the script)

## The oracle

Node's native type stripping. A driver must produce byte-identical stdout
under `node` and the engine. For the handbook the reference output is
captured into `.expected` files (`run.sh --regen`), so `test-local` has no
node dependency; the library sweep runs node live, like the tsc oracle in
`just ts-conformance`.

Corpus selection was oracle-first: candidates were admitted only if node
itself runs them (nanostores was dropped, it ships compiled JS; fast-equals
was dropped, extensionless intra-package imports that node's ESM resolver
refuses).

## Parser gaps closed

Four, all found by the corpora on their first runs:

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
- Library sweep 3/3 byte-identical to node.
- `just ts-conformance` (Microsoft corpus): 0 failures.
- `just rosetta` 42/42; libcorpus 22/22; `just test-local` green.
- All four fixes are gated on `ts_mode`; no non-TS path changed, so test262
  (100% at session 309) is unaffected.
