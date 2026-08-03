# Plan 069: TypeScript conformance against the tsc erasable-syntax corpus

Retroactive plan for the work that took the TypeScript erasable-subset
support (plan 042) from "the local fixtures pass" to "the full Microsoft
conformance corpus passes". Landed as `e1cfafe4` on `worktree-typescript`
and fast-forwarded into `main`.

Status: done.

## Contents

- [The problem](#the-problem)
- [The oracle](#the-oracle)
- [The harness](#the-harness)
- [Parser gaps closed](#parser-gaps-closed)
- [Documented non-goals](#documented-non-goals)
- [Two JS bugs the corpus surfaced](#two-js-bugs-the-corpus-surfaced)
- [Making the full run fast](#making-the-full-run-fast)
- [Result](#result)
- [Regression verification](#regression-verification)

---

## The problem

Plan 042 gave the engine a `ts_mode` that erases type syntax at parse
time. The conformance signal was a handful of hand-written fixtures in
`test/typescript/`, which said nothing about how the parser behaved on
real TypeScript. The natural corpus is the TypeScript project's own
`tests/cases/conformance/` directory, thousands of files covering every
syntactic corner.

## The oracle

There is no test262 for TypeScript, so the harness turns the conformance
corpus into one by running `tsc --erasableSyntaxOnly` per file:

- ACCEPT: tsc reports no errors. The file is purely erasable, so the
  engine must compile it. A SyntaxError here is a real failure.
- REJECT: tsc reports only TS1294 (`erasableSyntaxOnly` violations such
  as `enum`, runtime `namespace`, parameter properties). The engine must
  reject the source too.
- SKIP: tsc reports other diagnostics (type errors, deliberate-error
  tests, missing libs), or the file is a `.d.ts` tsc cannot run as a
  single program.

The verdicts are cached under `test/typescript/ts_conformance_cache`
(one `.txt` per file, gitignored), so re-runs skip tsc entirely.

## The harness

`scripts/run_ts_conformance.py`, wired into the justfile as
`just ts-conformance` (with `just ts-conformance <phase-dir>` for a
subset). The corpus lives at `test/typescript/conformance-src`, fetched
by `scripts/fetch_ts_conformance.py` as a sparse, blobless clone of
microsoft/TypeScript.

- `--log <file>` writes `RESULT<TAB>path` lines for failure clustering,
  same format as the test262 runner.
- `--phase-dir <subdir>` runs one phase directory (`types`, `classes`,
  `functions`, `expressions`), which is the fast iteration loop.
- `--only <substring>` and `--limit N` narrow a run further.
- `--jobs` (default 16) parallelizes the engine runs.
- A 600s hard deadline aborts the run with partial results and exit 2,
  so a pathological batch cannot run for hours.

## Parser gaps closed

The first full run reported 189 failures. Cluster by cluster:

- **Overload signatures** at statement, class, and `export default`
  level, including constructors and ASI'd forms without a terminating
  `;`. The hoist pre-scans (`hoist_global_fn_decls`, `hoist_decls`) skip
  signatures without recording the name, so the implementation is the
  occurrence that gets hoisted.
- **Class members**: optional methods (`f?() {}`), the `declare` field
  modifier, and auto-accessors rejected with a dedicated message.
- **Generic methods in object literals** (`{ foo<T>(x: T) { ... } }`)
  and call-site type arguments before a tagged template
  (`f<Stuff>\`...\``).
- **`this` parameters** (`function f(this: T, x) {}`) in both parameter
  parsers.
- **Type-only namespaces**: `module.exports = ...` and `namespace.foo`
  are ordinary identifier expressions, `declare namespace` bodies are
  erasable, the name must sit on the same line as the keyword, and a
  body containing `declare var`/`function`/`class`/`enum` is TS1294
  (only interface/type-alias/nested-namespace members are erasable).
- **Export forms**: `export { type foo }`, `export default interface`,
  `export type X = ...`, and export-clause specifiers that name
  type-only bindings (`interface G {}` then `export { G };`) erase to
  nothing instead of registering a phantom export.
- **Import types** `import("mod")` and `import("mod").T` inside type
  annotations.
- **Template literal types** in generic parameter lists and inside
  erased statements. The token-level skippers (`skip_generic_params`,
  the `declare` swallow, `ts_swallow_to_semi`, `skip_braced_body`,
  `skip_expr_lex`) are all template-aware now: a substitution's `}` must
  be consumed through `scan_template_after_expr` or the lexer re-lexes
  the template tail as JS.
- **Non-null assertions** in member chains (`o!.x`, `f()!`) are consumed
  inside the call chain loop so the following suffix still parses.
- **Async arrows with generic parameters** (`async <T>(x: T) => ...`)
  via the async-arrow lookahead.
- **Computed-key destructuring defaults** (`{ [k]: { x } = d }`) in the
  parameter-pattern collector.
- **For-of member LHS with calls** (`for (foo().x of [])`) by probing
  with `call_expr` instead of `member_expr`.
- **`using` declarations** rejected in for-heads with the same message
  as statement level.
- **Labels**: the loop-detection lookahead in `labeled_statement` skips
  nested labels, so `continue` can target the outer of
  `target1: target2: while (...)`; the non-loop-label continue error
  gained a message.

## Documented non-goals

Skipped by the runner, not fixed, because they are real runtime syntax
the engine deliberately does not implement:

- decorators (both the `@` token and sources that die in the parser
  before the `@` is lexed)
- auto-accessors (`accessor x: T`)
- `using` declarations (explicit resource management)

`JS_EARLY_ERROR_FILES` in the runner names accept-files whose rejection
is a spec-correct JS early error tsc's lenient parser does not enforce:
catch-var shadowing and a `with` statement.

## Two JS bugs the corpus surfaced

The corpus runs plain JS too, and it found two real bugs in code
unrelated to TS:

- `is_restricted_name` checked the 9-character word `interface` under
  `case 10`, so any 10-character name starting with `interface`
  (`interfaced`, `interface_`) was rejected as reserved.
- The speculative paren arrow-scan in `primary_expr` restored the lexer
  but left rejected tokens on the compiler's own pushback stack, so a
  parenthesized ternary (`(a ? 1 : 2)`) re-parsed from the wrong token.

## Making the full run fast

The first full run took 62 minutes, almost all of it engine subprocess
time: 40 corpus files compile and then run forever (infinite iterators
in the for-of/destructuring/spread tests), and everything ran
sequentially. The runner now:

- runs engine subprocesses in parallel (`--jobs 16`)
- treats a file that compiles but runs past the per-file timeout as a
  pass, since this is compile conformance, not runtime conformance
- classifies the infinite-run files as pass-with-timeout instead of
  burning 120s each

Result: the full corpus runs in about 43 seconds, comfortably inside the
10-minute cap.

## Result

| Verdict | Count |
|---|---|
| accept, compiled | 1969 (34 ran past the timeout) |
| reject, rejected | 250 |
| skipped (not erasable tests) | 3296 |
| skipped (decorators, non-goal) | 129 |
| skipped (auto-accessors, non-goal) | 12 |
| skipped (using declarations, non-goal) | 1 |
| skipped (JS early error) | 2 |
| failures | 0 |

## Regression verification

The parser changes touch shared compiler files, so the JS surface was
re-verified after the work and again after the merge into `main`:
rosetta 42/42, `just test-local` clean, test262 phase 0 (2468 pass,
0 fail, 0 unexpected compile errors).
