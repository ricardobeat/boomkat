# Duktape C3 Port

> **High-level project phases and progress are tracked in `progress.md`.** Check it before starting work to understand where we are and what's next.

## Project Spec

A C3-native, strict-only JavaScript engine. **Goal**: pass 100% of the targeted test262 subset (the ~29,500 executable tests left after the skip list; roadmap in `plans/040-test262-100-percent.md`), beat Duktape on performance, keep memory low, and run on low-powered devices across platforms.

- Uses Duktape v2.7.0 and QuickJS as architectural references; leverage C3's native features for memory safety and its stdlib. When a path is unclear, compare Duktape source against QuickJS. Check the stdlib reference for what is available when planning a new feature.
- Focus on ES5/ES6 core; ignore *staging* features in the spec.
- RegExp uses libregexp (from QuickJS).
- **test262 skip list**: ~60% of test262 is irrelevant for a clean-slate engine targeting Node/Bun/browser compatibility (Annex B, ECMA-402, Stage 3 proposals, engine quirks). Rationale is in `test262_relevance_report.md`. The runner (`scripts/run_test262.py`) sources the shared skip list from `scripts/test262_skip.cfg` — update the .cfg when implementing new features.

## Strict-Only Mode

The engine is strict-only — a single execution mode. Non-strict / Annex B features (`with`, legacy octal literals/escapes, duplicate params, implicit globals, unqualified `delete`, `arguments.callee`/`caller`, two-way `arguments`↔param binding) are unsupported and rejected at parse time.

**Guardrails:**
- The engine is single-mode; there is no `is_strict` / `ACT_FLAG_STRICT` flag to branch on.
- `"use strict"` is parsed and ignored (a no-op, accepted for source compatibility).
- Direct vs. indirect `eval` is not a strict-mode distinction; both are fully supported. `ACT_FLAG_DIRECT_EVAL` / `has_direct_eval` / `callee_is_eval` are orthogonal to strict mode.
- `noStrict`-flagged test262 tests fail to compile by design.

## Running & Testing

All common tasks are `just` recipes (`just list` to see them all). The fast debug loop:

| Task | Command |
|------|---------|
| Run one JS file | `just run <file>` (rebuilds `duktape_c3`, runs `./out/duktape_c3 <file>`) |
| Inspect bytecode | `./out/duktape_c3_debug -c <file>` (disassemble, skip run) — build with `just build-trace` |
| Build a target | `just build <target>` (e.g. `duktape_c3`, `duktape_c3_debug`, `test262_runner`) |
| Build everything | `just all` |
| Debug build (`-O0`) | `just build-debug <target>` |
| Rosetta suite | `just rosetta` (22+ language features; the go-to regression check) |
| One test262 phase | `just test262-phase <n>` |
| Full test262 | `just test262` |

**Validate changes with `just rosetta`, `just run` on a local repro, or a single `just test262-phase <n>` — not a full `just test262` run, which is slow and noisy.** Test fixtures live in `test/`; test262 lives under `test262/`.

For test262 work: `python3 scripts/run_test262.py --phase <n> --log <file>` writes per-test `RESULT<TAB>path` lines for failure clustering, and `bash scripts/run_single_test.sh <path-under-test262/test>` reproduces one test with harness includes and real error output (`--keep` emits the combined file for `just lldb`). The runner kills workers exceeding 2 GB RSS (`MEMKILL`) — see `plans/040-test262-100-percent.md` §A5.

Typical debug loop: minimize a failure to a single-line `.js` repro → `just run` it → if it fails to compile the bug is in the compiler; if it runs but gives a wrong value / `VM_ERROR` it's in the VM → trace with the flags below.

**test262 result categories** (per-phase table from `python3 scripts/run_test262.py --phase <n>`):
- **Pass** — runtime PASS
- **Fail** — runtime FAIL (harness assertion, timeout, VM_ERROR)
- **Skip** — runner skip (noStrict, $DONOTEVALUATE, unsupported patterns, ES5-only)
- **CE** — Compile Error (strict-only engine rejected the source). For `noStrict` tests this is the expected/correct outcome.

## Build Flags

- `-D NONANBOX` — disable NaN-boxing, using the 16-byte tagged union `TVal` instead. Default is nanbox-on. Use `just build-nonanbox` or `just test-nonanbox` to exercise the non-nanbox path (e.g., for 16-bit ESP32 targets).

## NaN-Boxing (src/types.c3)

Tagged values live in the mantissa of IEEE 754 NaNs (Duktape's scheme): **16-bit tags in bits 63-48**, 48-bit payload in bits 47-0. Full 16-bit tags (`TAG_FASTINT=0xFFF1`, `TAG_UNDEFINED=0xFFF3`, …); a value is a double iff `bits >> 48 <= 0xFFF0`.

- **NaN normalization**: negative NaNs (bits 63-48 in 0xFFF8-0xFFFF) collide with tags, so `set_number()` normalizes any double with bits 63-48 >= 0xFFF8 to canonical `0x7FF8000000000000`.
- **Fastint sign extension**: branchless `(long)(bits << 16) >> 16`; range ±2^47.

**C3 gotcha**: always parenthesize bitwise operations mixed with comparisons — `&` / `|` / `^` bind looser than in C, so `(v >> 52) & 0x7FF != 0x7FF0` parses as `(v >> 52) & (0x7FF != 0x7FF0)`.

## Compiler / VM Invariants

- **PUTVAR zeroes its source register** (vm.c3): after syncing a register to the environment it decrefs and sets the register to `undefined`. Variable-binding work must not read a value back from a register after PUTVAR — read via GETVAR instead.
- **Register init must skip argument slots** (vm.c3): the per-call init memset starts at `max(undef_limit, nargs)`, not `undef_limit`, or it clobbers the sliding-window argument slots at `new_regs[0..nargs-1]`.
- **async/await uses resumable execution** (same as QuickJS/V8): async functions compile with `is_generator=true` to reuse the generator save/restore path. `AWAIT` extracts the result of a settled Promise or suspends (saves registers/PC/env to `GeneratorState`, adds a reaction, pops the activation); the resume callback restores it. Async generators (`async function*`) are **not** implemented.
- **`is_async` must not leak into nested functions**: `function_declaration`/`function_expr` restore `is_async` only around the `compile_inner_function` call, then reset it.
- **break/continue across finally** (vm.c3): `BREAK`/`CONTINUE` are jump-offset opcodes that walk the catcher chain and redirect through active `finally` blocks via `pending_pc`. Flags: `CATCHER_FLAG_PENDING_BREAK/CONTINUE/IN_FINALLY`. `IN_FINALLY` guards against throw/return-in-finally infinite loops.

Two CLI binaries share the engine (`src`): **`duktape_c3`** (`cli/duktape_c3.c3`) is
the plain runner — run a file, or `--module <file>` for ESM, nothing else. **`duktape_c3_debug`**
(`cli/duktape_c3_debug.c3`, built via `just build-trace`) is the inspection binary and is the
one that carries the debug flags below. The plain `duktape_c3` does NOT understand `-c`/`-t` —
it treats them as a file path. Debug flags (no perf impact on release builds):
- `-c` / `--compile-only` — disassemble bytecode, skip execution (`--format json` for structured output)
- `-t` / `--trace-vm` — print each instruction + register values before dispatch (stderr)
- `--dump-constants` — dump the constant pool
- `-d` / `--debug` — stage-level timing (load, compile, execute)
- `--no-optimize` — disable all compiler peephole passes (debug aid). When a miscompiled pattern reproduces only on optimized builds, this flag narrows the bug to either code generation or one of the peephole passes. The flag toggles `compiler::g_disable_optimize` (also accessible from C3 code via `compiler::set_disable_optimize(bool)` / `compiler::get_disable_optimize()`); per-context `CompilerContext.disable_optimize` is initialised from the global in `CompilerContext.init()`. When disabled, the bytecode is copied verbatim into the `CompiledFunction` (NOPs included) so every peephole-produced instruction is visible in the dump.

`just lldb <file>` builds with `-O0` and launches lldb with a backtrace on crash — use when a JS file triggers a VM fault. On `VM_ERROR` the CLI also dumps the failing instruction and first 32 registers to stderr.

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
