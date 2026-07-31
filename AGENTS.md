# Duktape C3 Port

> **High-level project phases and progress are tracked in `progress.md`.** Check it before starting work to understand where we are and what's next.

## Project Spec

A C3-native, strict-only JavaScript engine. **Goal**: pass 100% of the targeted test262 subset (the ~29,500 executable tests left after the skip list; roadmap in `plans/040-test262-100-percent.md`), beat Duktape on performance, keep memory low, and run on low-powered devices across platforms.

- Uses Duktape v2.7.0 and QuickJS as architectural references; leverage C3's native features for memory safety and its stdlib. When a path is unclear, compare Duktape source against QuickJS. Check the stdlib reference for what is available when planning a new feature.
- Focus on ES5/ES6 core; ignore *staging* features in the spec.
- RegExp uses libregexp (from QuickJS).
- **test262 skip list**: ~60% of test262 is irrelevant for a clean-slate engine targeting Node/Bun/browser compatibility (Annex B, ECMA-402, Stage 3 proposals, engine quirks). Rationale is in `test262_relevance_report.md`. The skip list (`SKIP_DIRS`/`SKIP_GLOBS`/`SKIP_FILES`/`UNSUPPORTED_PATTERN`) is embedded directly in `scripts/run_test262.py`: update it there when implementing new features.

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
| Run one JS file | `just run <file>` (rebuilds `duktape_c3`, runs `./out/duktape_c3 <file>`) |
| Inspect bytecode | `./out/duktape_c3_debug -c <file>` (disassemble, skip run); build with `just build-trace` |
| Build a target | `just build <target>` (e.g. `duktape_c3`, `duktape_c3_debug`, `test262_runner`) |
| Build everything | `just all` |
| Debug build (`-O0`) | `just build-debug <target>` |
| ASAN test262 runner | `just build-asan` (`out/test262_runner_asan`) |
| Rosetta suite | `just rosetta` (22+ language features; the go-to regression check) |
| Local suite | `just test-local` (every `test/*.js` + the ESM fixtures) |
| Run one JS file as ESM | `just run-module <file>` (`./out/duktape_c3 --module <file>`) |
| ESM module tests only | `just modules` (`test/modules/`, 12 entry points) |
| One test262 phase | `just test262-phase <n>` |
| Full test262 | `just test262` |

**Validate changes with `just rosetta`, `just run` on a local repro, or a single `just test262-phase <n>`: not a full `just test262` run, which is slow and noisy.** Test fixtures live in `test/`; test262 lives under `test262/`.

**ESM tests need `--module`.** `import`/`export` are rejected at parse time by the plain runner, so an ESM fixture run as a plain script always reports a SyntaxError. Every ESM test therefore lives under `test/modules/<tNN_name>/main.js` (with its dependency files alongside) and is invoked through `test/modules/run.sh`, which passes `--module` and treats a non-zero exit as failure. `just test-local` runs both surfaces: the flat `test/*.js` sweep under the plain runner, then `run.sh` for the module fixtures. Do NOT add `import`/`export` files directly to `test/`: they would read as spurious failures in the flat sweep. `test/test_async_500k.js` is skipped by the local suite: it passes but takes ~20s, so it is a perf stress test, not a regression check.

For test262 work: `python3 scripts/run_test262.py --phase <n> --log <file>` writes per-test `RESULT<TAB>path` lines for failure clustering, and `python3 scripts/run_test262.py --single <path-under-test262/test>` reproduces one test through the canonical worker path. **`--single` warns `⚠ SUITE SKIPS THIS TEST` (naming the reason) when the test carries an unsupported-feature or `noStrict` flag. A raw COMPILE_ERROR or FAIL on such a test is not a real failure**, the suite skips it. Add `--debug` (concat assert/sta/includes + run under `duktape_c3`) or `--keep` (emit the combined file for `just lldb` / `--trace-vm`). The runner kills workers exceeding 2 GB RSS (`MEMKILL`); see `plans/040-test262-100-percent.md` §A5.

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

## Writing Comments

Load the **humanizer** skill before writing or editing comments, doc comments, or
markdown in this repo. It removes the patterns that make text read as
machine-generated. The house style, which the whole codebase was passed through
in one sweep:

**Say what the code does now.** No "previously", "used to", "was changed to", no
retelling a bug that is already fixed, and no describing what something is *not*
unless the contrast is needed to understand it. A comment that only restates the
line below it should be deleted.

**Keep the why, cut the what.** Ordering constraints, GC safety invariants, spec
section references, and the reason a non-obvious branch exists all earn their
space. Paraphrasing the code does not.

**No em dashes.** Use a comma, a colon, or a new sentence. This is the single
most reliable tell, and the codebase currently contains zero. Same for
box-drawing characters in banners: use `// ===` for sections and `// --- Title ---`
for sub-sections.

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

## Compiler / VM Invariants

- **PUTVAR zeroes its source register** (vm.c3): after syncing a register to the environment it decrefs and sets the register to `undefined`. Variable-binding work must not read a value back from a register after PUTVAR; read via GETVAR instead.
- **Register init must skip argument slots** (vm.c3): the per-call init memset starts at `max(undef_limit, nargs)`, not `undef_limit`, or it clobbers the sliding-window argument slots at `new_regs[0..nargs-1]`.
- **async/await uses resumable execution** (same as QuickJS/V8): async functions compile with `is_generator=true` to reuse the generator save/restore path. `AWAIT` extracts the result of a settled Promise or suspends (saves registers/PC/env to `GeneratorState`, adds a reaction, pops the activation); the resume callback restores it. Async generators (`async function*`) are **not** implemented.
- **`is_async` must not leak into nested functions**: `function_declaration`/`function_expr` restore `is_async` only around the `compile_inner_function` call, then reset it.
- **break/continue across finally** (vm.c3): `BREAK`/`CONTINUE` are jump-offset opcodes that walk the catcher chain and redirect through active `finally` blocks via `pending_pc`. Flags: `CATCHER_FLAG_PENDING_BREAK/CONTINUE/IN_FINALLY`. `IN_FINALLY` guards against throw/return-in-finally infinite loops.

Two CLI binaries share the engine (`src`): **`duktape_c3`** (`cli/duktape_c3.c3`) is
the plain runner: run a file, or `--module <file>` for ESM, nothing else. **`duktape_c3_debug`**
(`cli/duktape_c3_debug.c3`, built via `just build-trace`) is the inspection binary and is the
one that carries the debug flags below. The plain `duktape_c3` does not understand `-c` or `-t`;
it treats them as a file path. Debug flags (no perf impact on release builds):
- `-c` / `--compile-only`: disassemble bytecode, skip execution (`--format json` for structured output)
- `-t` / `--trace-vm`: print each instruction + register values before dispatch (stderr)
- `--dump-constants`: dump the constant pool
- `-d` / `--debug`: stage-level timing (load, compile, execute)
- `--no-optimize`: disable all compiler peephole passes (debug aid). When a miscompiled pattern reproduces only on optimized builds, this flag narrows the bug to either code generation or one of the peephole passes. The flag toggles `compiler::g_disable_optimize` (also accessible from C3 code via `compiler::set_disable_optimize(bool)` / `compiler::get_disable_optimize()`); per-context `CompilerContext.disable_optimize` is initialised from the global in `CompilerContext.init()`. When disabled, the bytecode is copied verbatim into the `CompiledFunction` (NOPs included) so every peephole-produced instruction is visible in the dump.

  **Caveat: `--no-optimize` output is not always correct.** The local-var-to-register elision guarded by `elide_ok` (`src/compiler/context.c3`) is not purely an optimization: with it disabled, a function-local `var` is emitted as `DECLVAR_HOIST`/`DECLVAR`/`PUTVAR`, which currently resolve against the *global* environment, so an inner `var x` leaks to the outer scope. Minimal repro:

  ```js
  var x = "outer";
  function f(){ var x = "inner"; }
  f();
  print(x);   // optimized: "outer" (correct)   --no-optimize: "inner" (wrong)
  ```

  Three files in `test/` (`function_scope.js`, `test_capture_analysis.js`, `test_spread.js`) fail under `--no-optimize` for this reason. So use the flag to compare *bytecode shape* (its intended purpose), and treat a wrong **value** under `--no-optimize` as suspect until reproduced on an optimized build. This is a pre-existing codegen bug, not a peephole bug.

`just lldb <file>` builds with `-O0` and launches lldb with a backtrace on crash; use it when a JS file triggers a VM fault. On `VM_ERROR` the CLI also dumps the failing instruction and first 32 registers to stderr.

### Printing TVal values (C3 gotcha)

`io::printf("%s", char*)` prints the **pointer as hex** (`0x...`), not the string content. For string TVal output, iterate bytes with `io::printf("%c", d[i])`:
```
case STRING:
    char[] d = s.get_data();
    io::printf("\"");
    for (usz i = 0; i < d.len; i++) { io::printf("%c", d[i]); }
    io::printf("\"");
```
Same pattern for stderr (`io::eprintf("%c", ...)`).
