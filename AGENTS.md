# Boomkat

> **Worktree notice — `sloppy-mode`.** This branch is intentionally modifying the strict-only architecture to add sloppy-mode support. The contract below ("single strict mode", "rejected at parse time", etc.) describes the **current state of the source on disk** and what new code on this worktree is *transitioning away from*. Follow `plans/083-sloppy-mode.md` for the phased plan. Do **not** add new strict-only checks, do **not** assume "this engine always rejects X" is permanent — that contract is being deliberately loosened. The skip list in `scripts/run_test262.py` still gates test262 currently; expect the noStrict filter and several `SKIP_FILES` entries to be removed as phases land.

## Project Spec

A C3-native JavaScript engine. **Goal**: pass 100% of the targeted test262 subset (the ~29,500 executable tests left after the skip list; roadmap in `plans/040-test262-100-percent.md`), beat Duktape on performance, keep memory low, and run on low-powered devices across platforms.

- Uses Duktape v2.7.0 and QuickJS as architectural references; leverage C3's native features for memory safety and its stdlib. When a path is unclear, compare Duktape source against QuickJS. Check the stdlib reference for what is available when planning a new feature.
- Focus on ES5/ES6 core; ignore *staging* features in the spec.
- RegExp uses libregexp (from QuickJS).
- **BigInt** is implemented as fixed-width int128 (plan 056, range ~±1.7e38). Tests containing literals >2^127 stay skipped for precision reasons, not because BigInt is absent — see `built-ins/BigInt/asIntN/arithmetic.js` and similar `SKIP_FILES` entries.
- **Strict vs sloppy**: scripts default to sloppy (matching ES2024); modules default to strict; per-function `is_strict` is recorded in `FuncFlags`. The legacy `subst_global_this` flag is being repurposed/removed under plans/083 — do not add new readers or writers.
- **test262 skip list**: ~60% of test262 falls outside this engine's scope, which is ES5/ES6 core in a single execution mode (Annex B legacy, ECMA-402, Stage 3 proposals, host-specific and cross-realm behavior). Scope is documented in `docs/engine-scope.md`. The skip list (`SKIP_DIRS`/`SKIP_GLOBS`/`SKIP_FILES`/`UNSUPPORTED_PATTERN`) is embedded directly in `scripts/run_test262.py`: update it there when implementing new features. The skip list is the *only* place scope is expressed — test selection itself is exhaustive over test262's directory tree, so a feature is out of scope because a rule names it, never because nobody listed its directory. `intl402` (ECMA-402) is skipped per test262's own guidance; `staging` runs, as upstream `INTERPRETING.md` asks.

## Sloppy Mode (in progress)

This branch (`sloppy-mode`) is adding sloppy-mode execution as a peer to strict mode. Follow `plans/083-sloppy-mode.md` for the phased plan.

**Current state of the source on disk** (phases 0, 1, and 2 have landed):
- `FuncFlags.is_strict` bit 7, plumbed through `CompilerContext.is_strict`. The legacy `Lexer.strict_mode` and `Lexer.reserved_words_strict` flags still exist (one for octal rules, one for keyword reservation). `subst_global_this` is gone — the predicate is `!is_strict() && !is_arrow()` at every call / construct / generator-create site.
- Top-level scripts default to sloppy (ES2024 §16.2.1.1); modules stay strict; ordinary functions and dynamic `Function` / `GeneratorFunction` / `AsyncFunction` bodies default to sloppy; class bodies stay strict (ES2024 §15.4.1).
- `"use strict"` is parsed and raises `is_strict = true`.
- Phase 1 parser gates: `with`, legacy octal literals and octal escapes, `delete <id>`, `for (var x = 1 in y)`, plain duplicate params (Annex B.3.1), duplicate `__proto__:` keys (Annex B.3.1) all accepted in sloppy. The VM stubs `with` to throw SyntaxError at runtime (phase 4 implements semantics); everything else works end-to-end.
- Phase 1 still strict (unconditional): class method / object method / arrow / named-export param duplicates (UniqueFormalParameters, no Annex B exemption), catch / lexical ForDeclaration duplicate BoundNames, `eval` / `arguments` as binding identifiers.
- Phase 2 runtime semantics:
  - **Implicit globals**: `PUTVAR_ASSIGN`, `PUTGLOBAL`, and the `RESOLVEVAR`/`THROW_UNRESOLVED` pair create a configurable own property on the global object in sloppy, throw ReferenceError in strict.
  - **`this` substitution**: a non-arrow call's null / undefined `thisArg` coerces to globalThis iff the callee is sloppy. Predicate: `!target.is_strict()` with `!is_arrow()` already guaranteed by the surrounding branches.
  - **DELPROP silent failure**: a failed `delete x[y]` (non-configurable own, proxy trap returned falsish, TypedArray integer index, module-namespace export) throws TypeError in strict, returns `false` in sloppy. Writes (`f.caller = …`) are still unconditional SyntaxErrors per Annex B.3.5.
  - **DELVAR**: `delete x` walks the lex chain; BC == 0 (local register like a parameter) → false in sloppy, ReferenceError in strict; BC != 0 (name constant) → unresolvable is true in sloppy / ReferenceError in strict, present binding is false (Annex B.3.2).
  - **Poison pill**: `arguments.callee` throws TypeError in strict and returns `ds.act.tv_func` in sloppy (a new field on `Activation` that every CALL/CLOSURE path populates). `f.caller` / `f.arguments` are read-throws for strict, bound, class, arrow, and generator targets (the strict-or-special-function rule per ES2017 §15.3.5.4) and return null for ordinary sloppy.
  - **`make_default_constructor`**: the implicit class ctor now stamps `is_strict = true`, matching ES2015 §14.5.14 step 22.

Phase 2 scope deferred to later phases:
  - `with` semantics (Phase 4 — opcodes `WITH_START`/`WITH_END` exist as stubs).
  - ToObject-wrap of primitive `thisArg` for sloppy `Function.prototype.call` / `.apply` (Phase 3 — `S15.3.4.3_A5_T1.js`-style F1 SKIP_FILES stay skipped).
  - Two-way `arguments` ↔ parameter mapping for sloppy (Phase 3).

**What not to write:**
- Do not add new strict-only parse rejections.
- Do not assume any parser rejection is unconditional — every rejection in `src/compiler/{statements,expressions,functions,tokens,destructuring,class}.c3` that exists for sloppy-mode-only syntax is now gated on `self.is_strict`. If you find an ungated one, gate it.
- Do not assume `subst_global_this` will remain a separate flag. Phase 2 folds its semantics into `!is_strict && !is_arrow`; treat it as legacy.
- Do not touch the test262 skip list without reading plans/083 §5 (test262 strategy). Un-skipping the wrong tests pollutes the suite's signal.

## Running & Testing

All common tasks are `just` recipes (`just list` to see them all). The fast debug loop:

| Task | Command |
|------|---------|
| Run one JS file | `just run <file>` (rebuilds `boomkat`, runs `./out/boomkat <file>`) |
| Inspect bytecode | `./out/boomkat_debug -c <file>` (disassemble, skip run); build with `just build-trace` |
| Build a target | `just build <target>` (e.g. `boomkat`, `boomkat_debug`, `test262_runner`) |
| Build everything | `just all` |
| Debug build (`-O0`) | `just build-debug <target>` |
| ASAN test262 runner | `just build-asan` (`out/test262_runner_asan`) |
| Rosetta suite | `just rosetta` (22+ language features; the go-to regression check) |
| Local suite | `just test-local` (every `test/*.js` + the ESM fixtures) |
| Run one JS file as ESM | `just run-module <file>` (`./out/boomkat --module <file>`) |
| ESM module tests only | `just modules` (`test/modules/`, 12 entry points) |
| One test262 suite | `just test262-suite <name>` |
| One test262 directory | `just test262-dir <path>` |
| Full test262 | `just test262` |

**Validate changes with `just rosetta`, `just run` on a local repro, or a narrow `just test262-dir <path>`: not a full `just test262` run, which is slow and noisy.** Test fixtures live in `test/`; test262 lives under `test262/`.

**ESM tests need `--module`.** `import`/`export` are rejected at parse time by the plain runner, so an ESM fixture run as a plain script always reports a SyntaxError. Every ESM test therefore lives under `test/modules/<tNN_name>/main.js` (with its dependency files alongside) and is invoked through `test/modules/run.sh`, which passes `--module` and treats a non-zero exit as failure. `just test-local` runs both surfaces: the flat `test/*.js` sweep under the plain runner, then `run.sh` for the module fixtures. Do NOT add `import`/`export` files directly to `test/`: they would read as spurious failures in the flat sweep. `test/test_async_500k.js` is skipped by the local suite: it passes but takes ~20s, so it is a perf stress test, not a regression check.

For test262 work: `python3 scripts/run_test262.py --dir <path> --log <file>` writes per-test `RESULT<TAB>path` lines for failure clustering. Selection follows test262's own top-level directories: `--suite` takes one of `language`, `built-ins`, `staging`, `annexB`, `intl402`, `harness` and is repeatable; `--dir <path-under-test262/test>` narrows to a single directory for the tight debug loop. Without either, every suite runs. Because the suites are the corpus's own layout, selection is exhaustive: a directory added upstream is picked up automatically, and anything the engine does not target is excluded by `SKIP_DIRS`/`UNSUPPORTED_PATTERN` rather than by going unlisted. `python3 scripts/run_test262.py --single <path-under-test262/test>` reproduces one test through the canonical worker path. **`--single` warns `⚠ SUITE SKIPS THIS TEST` (naming the reason) when the test carries an unsupported-feature or `noStrict` flag. A raw COMPILE_ERROR or FAIL on such a test is not a real failure**, the suite skips it. Add `--debug` (concat assert/sta/includes + run under `boomkat`) or `--keep` (emit the combined file for `just lldb` / `--trace-vm`). The runner kills workers exceeding 2 GB RSS (`MEMKILL`); see `plans/040-test262-100-percent.md` §A5.

**TypeScript conformance** (`just ts-conformance`, or `just ts-conformance <phase-dir>` for a subset like `types`/`classes`): `scripts/run_ts_conformance.py` runs the official Microsoft conformance corpus (`test/typescript/conformance-src`, a sparse clone fetched by `scripts/fetch_ts_conformance.py`; gitignored) against the engine's TS type-stripping mode, using `tsc --erasableSyntaxOnly` as the acceptance oracle. Each file is classified ACCEPT (must compile), REJECT (must SyntaxError, TS1294-only), or SKIP, with verdicts cached in `test/typescript/ts_conformance_cache` (also gitignored). The full corpus run takes about a minute: tsc verdicts are cached, engine runs are parallel (`--jobs`, default 16), files that compile but run past the per-file timeout count as passes (compile conformance, not runtime), and a hard deadline (default 600s) aborts with partial results. Use `--log <file>` for `RESULT<TAB>path` failure clustering. Documented non-goals are skipped by outcome, not fixed: decorators, auto-accessors (`accessor`), and `using` declarations. `JS_EARLY_ERROR_FILES` in the runner names spec-correct JS early errors tsc's lenient parser accepts (catch-var shadowing, `with`).

Typical debug loop: minimize a failure to a single-line `.js` repro → `just run` it → if it fails to compile the bug is in the compiler; if it runs but gives a wrong value / `VM_ERROR` it's in the VM → trace with the flags below.

**test262 result categories** (per-suite table from `python3 scripts/run_test262.py --suite <name>`):
- **Pass**: runtime PASS
- **Fail**: runtime FAIL (harness assertion, timeout, VM_ERROR)
- **Skip**: runner skip (noStrict, $DONOTEVALUATE, unsupported patterns, ES5-only)
- **CE**: Compile Error (strict-only engine rejected the source). For `noStrict` tests this is the expected/correct outcome.

## Build Flags

- `-D NONANBOX`: disable NaN-boxing, using the 16-byte tagged union `TVal` instead. Default is nanbox-on. Use `just build-nonanbox` or `just test-nonanbox` to exercise the non-nanbox path (e.g., for 16-bit ESP32 targets).

## AddressSanitizer

`just build-asan` builds `out/test262_runner_asan` (the `test262_runner_asan` target: same sources as the normal runner, `-O0` plus `"sanitize": "address"`). Use it to turn a use-after-free or heap-overflow that only shows up as a sporadic crash into a precise allocation/free trace. Drive it exactly like the normal worker:

```
just build-asan
echo test262/test/<path>.js | ./out/test262_runner_asan --worker
```

**It is deliberately excluded from `just all` and `make all`**: ASAN at `-O0` would slow every default build. That means it does not rebuild unless you ask for it, so **always rebuild before trusting a clean result**: a stale ASAN binary reports no errors for code it does not contain, which reads as proof a lifetime bug is fixed when the binary simply predates the fix.

## NaN-Boxing (src/types.c3)

Tagged values live in the mantissa of IEEE 754 NaNs (Duktape's scheme): **16-bit tags in bits 63-48**, 48-bit payload in bits 47-0. Full 16-bit tags (`TAG_FASTINT=0xFFF1`, `TAG_UNDEFINED=0xFFF3`, …); a value is a double iff `bits >> 48 <= 0xFFF0`.

- **NaN normalization**: negative NaNs (bits 63-48 in 0xFFF8-0xFFFF) collide with tags, so `set_number()` normalizes any double with bits 63-48 >= 0xFFF8 to canonical `0x7FF8000000000000`.
- **Fastint sign extension**: branchless `(long)(bits << 16) >> 16`; range ±2^47.

**C3 gotcha**: always parenthesize bitwise operations mixed with comparisons: `&`, `|`, and `^` bind looser than in C, so `(v >> 52) & 0x7FF != 0x7FF0` parses as `(v >> 52) & (0x7FF != 0x7FF0)`.

## Writing style

**Say what the code does now.** No "previously", "used to", "was changed to", no
retelling a bug that is already fixed, and no describing what something is *not*
unless the contrast is needed to understand it. A comment that only restates the
line below it should be deleted.

**Keep the why, cut the what.** Ordering constraints, GC safety invariants, spec
section references, and the reason a non-obvious branch exists all earn their
space. Paraphrasing the code does not.

**Be direct.** "is not on the list" beats "is off the list"; "the table is full
but we found a tombstone" beats "no empty slot remained". Do not trade a precise
phrase for a vaguer one to vary the wording, and do not soften an active
statement into a passive one. First person for the running code is fine.

**Formatting.** Do not leave a last line holding one or two orphaned words;
shorten the text instead of reshuffling the tail. State a shared rationale once
over a group of fields rather than repeating it per field.

**Verify before you write.** Byte offsets, struct sizes, table counts, and "N
entries" figures go stale. Either check them against the code or leave them out.
The sweep found several comments that contradicted their own functions, so if a
comment and its code disagree, read the code and fix the comment.

`docs/architecture.md` is the engine's design guide, and it follows the same
rules. Update it when a change makes one of its claims wrong.
