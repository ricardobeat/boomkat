# Boomkat

## Project Spec

A C3-native, strict-only JavaScript engine. **Goal**: pass 100% of the targeted test262 subset (the ~29,500 executable tests left after the skip list; roadmap in `plans/040-test262-100-percent.md`), beat Duktape on performance, keep memory low, and run on low-powered devices across platforms.

- Uses Duktape v2.7.0 and QuickJS as architectural references; leverage C3's native features for memory safety and its stdlib. When a path is unclear, compare Duktape source against QuickJS. Check the stdlib reference for what is available when planning a new feature.
- Focus on ES5/ES6 core; ignore *staging* features in the spec.
- RegExp uses libregexp (from QuickJS).
- **test262 skip list**: ~60% of test262 falls outside this engine's scope, which is ES5/ES6 core in a single strict mode (Annex B legacy, ECMA-402, Stage 3 proposals, host-specific and cross-realm behavior). Scope is documented in `docs/engine-scope.md`. The skip list (`SKIP_DIRS`/`SKIP_GLOBS`/`SKIP_FILES`/`UNSUPPORTED_PATTERN`) is embedded directly in `scripts/run_test262.py`: update it there when implementing new features.

## Strict-Only Mode

The engine is strict-only, a single execution mode. Non-strict / Annex B features (`with`, legacy octal literals/escapes, duplicate params, implicit globals, unqualified `delete`, `arguments.callee`/`caller`, two-way `arguments`↔param binding) are unsupported and rejected at parse time.

**Guardrails:**
- The engine is single-mode; there is no `is_strict` / `ACT_FLAG_STRICT` flag to branch on.
- `"use strict"` is parsed and ignored (a no-op, accepted for source compatibility). The one exception: in a dynamic `Function`/`GeneratorFunction`/`AsyncFunction` body it clears `FuncFlags.subst_global_this` (below).
- `this`-substitution is **not** a strictness distinction here. `FuncFlags.subst_global_this` is set only on bodies built by the dynamic function constructors, so `Function('return this')()` keeps returning the global object (a ubiquitous UMD idiom). Ordinary functions never substitute, and functions nested inside a dynamic body do not inherit the flag.
- Direct vs. indirect `eval` is not a strict-mode distinction; both are fully supported. `ACT_FLAG_DIRECT_EVAL` / `has_direct_eval` / `callee_is_eval` are orthogonal to strict mode.
- `noStrict`-flagged test262 tests fail to compile by design.

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
| One test262 phase | `just test262-phase <n>` |
| Full test262 | `just test262` |

**Validate changes with `just rosetta`, `just run` on a local repro, or a single `just test262-phase <n>`: not a full `just test262` run, which is slow and noisy.** Test fixtures live in `test/`; test262 lives under `test262/`.

**ESM tests need `--module`.** `import`/`export` are rejected at parse time by the plain runner, so an ESM fixture run as a plain script always reports a SyntaxError. Every ESM test therefore lives under `test/modules/<tNN_name>/main.js` (with its dependency files alongside) and is invoked through `test/modules/run.sh`, which passes `--module` and treats a non-zero exit as failure. `just test-local` runs both surfaces: the flat `test/*.js` sweep under the plain runner, then `run.sh` for the module fixtures. Do NOT add `import`/`export` files directly to `test/`: they would read as spurious failures in the flat sweep. `test/test_async_500k.js` is skipped by the local suite: it passes but takes ~20s, so it is a perf stress test, not a regression check.

For test262 work: `python3 scripts/run_test262.py --phase <n> --log <file>` writes per-test `RESULT<TAB>path` lines for failure clustering. The `--phase` flag accepts a phase label number (0, 1, 2, … 8, 11-15, 17-25) and can be repeated to run multiple phases: `--phase 0 --phase 2 --phase 3`. Without `--phase`, all phases run. Invalid phase numbers are rejected with an error listing valid choices. `python3 scripts/run_test262.py --single <path-under-test262/test>` reproduces one test through the canonical worker path. **`--single` warns `⚠ SUITE SKIPS THIS TEST` (naming the reason) when the test carries an unsupported-feature or `noStrict` flag. A raw COMPILE_ERROR or FAIL on such a test is not a real failure**, the suite skips it. Add `--debug` (concat assert/sta/includes + run under `boomkat`) or `--keep` (emit the combined file for `just lldb` / `--trace-vm`). The runner kills workers exceeding 2 GB RSS (`MEMKILL`); see `plans/040-test262-100-percent.md` §A5.

**TypeScript conformance** (`just ts-conformance`, or `just ts-conformance <phase-dir>` for a subset like `types`/`classes`): `scripts/run_ts_conformance.py` runs the official Microsoft conformance corpus (`test/typescript/conformance-src`, a sparse clone fetched by `scripts/fetch_ts_conformance.py`; gitignored) against the engine's TS type-stripping mode, using `tsc --erasableSyntaxOnly` as the acceptance oracle. Each file is classified ACCEPT (must compile), REJECT (must SyntaxError, TS1294-only), or SKIP, with verdicts cached in `test/typescript/ts_conformance_cache` (also gitignored). The full corpus run takes about a minute: tsc verdicts are cached, engine runs are parallel (`--jobs`, default 16), files that compile but run past the per-file timeout count as passes (compile conformance, not runtime), and a hard deadline (default 600s) aborts with partial results. Use `--log <file>` for `RESULT<TAB>path` failure clustering. Documented non-goals are skipped by outcome, not fixed: decorators, auto-accessors (`accessor`), and `using` declarations. `JS_EARLY_ERROR_FILES` in the runner names spec-correct JS early errors tsc's lenient parser accepts (catch-var shadowing, `with`).

Typical debug loop: minimize a failure to a single-line `.js` repro → `just run` it → if it fails to compile the bug is in the compiler; if it runs but gives a wrong value / `VM_ERROR` it's in the VM → trace with the flags below.

**test262 result categories** (per-phase table from `python3 scripts/run_test262.py --phase <n>`):
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
