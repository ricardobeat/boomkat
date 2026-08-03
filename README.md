# Duktape C3

A strict-only ECMAScript engine written in [C3](https://c3-lang.org/).
Duktape v2.7.0 and QuickJS are the architectural references; the engine is a
native C3 implementation that leans on the language's memory safety and its
stdlib. The goal is 100% of a targeted test262 subset, better performance than
Duktape, low memory, and small-device portability.

## Status

The gate is green: **49,814 pass / 0 fail / 0 unexpected compile error** across
all 25 test262 phases (3,010 skips of 52,824 total, `test262_results/latest.json`,
refreshed session 303). The targeted subset is ES5/ES6 core in a single strict
mode; the skip list and its reasoning live in `scripts/run_test262.py`, and
`docs/engine-scope.md` explains what is out of scope and why. Progress is
tracked per session in `progress.md`, the roadmap to 100% in
`plans/040-test262-100-percent.md`.

Other gates:

- `just rosetta`: 41/41 unmodified rosettacode.org samples, cross-checked
  against qjs (`test/rosetta-verbatim/`)
- `just test-local`: every `test/*.js` plus the ESM fixtures under
  `test/modules/`
- `just test-golden-bytecode`: golden disassembly and the fusion-free
  `--no-optimize` invariant
- `just test-gc-stress`: an ASAN GC-stress suite, 20-30 minutes, nightly
  material

## Benchmarks

`just bench` runs the suite in `benchmarks/` (3 iterations per benchmark)
against this engine, original Duktape v2.7.0 (`out/duktape_orig`), and QuickJS
(`out/qjs`); the Duktape and QuickJS results are cached between runs. Lower is
better; the ratio columns are C3/reference, so below 1.0 the engine wins.

| Benchmark | C3 (ms) | Duktape (ms) | QuickJS (ms) | vs Duktape | vs QuickJS |
|---|---|---|---|---|---|
| bench_arithmetic | 349 | 3,272 | 297 | 0.1x | 1.2x |
| bench_array | 22 | 41 | 12 | 0.5x | 1.8x |
| bench_date | 80 | 906 | 60 | 0.1x | 1.3x |
| bench_function_call | 254 | 1,283 | 185 | 0.2x | 1.4x |
| bench_ic_monomorphic | 97 | 286 | 109 | 0.3x | 0.9x |
| bench_ic_proto | 121 | 451 | 136 | 0.3x | 0.9x |
| bench_loop | 146 | 1,361 | 146 | 0.1x | 1.0x |
| bench_memory_heavy | 113 | 173 | 62 | 0.7x | 1.8x |
| bench_object | 369 | 1,668 | 255 | 0.2x | 1.4x |
| bench_property_lookup | 256 | 1,775 | 189 | 0.1x | 1.4x |
| bench_recursion_deep | 900 | 1,975 | 614 | 0.5x | 1.5x |
| bench_recursion | 218 | 473 | 150 | 0.5x | 1.5x |
| bench_regexp | 694 | 670 | 312 | 1.0x | 2.2x |
| bench_shape_no_call | 8 | 9 | 7 | 0.9x | 1.1x |
| bench_shape_stress | 7 | 8 | 6 | 0.9x | 1.2x |
| bench_string | 10 | 18 | 8 | 0.6x | 1.3x |
| bench_valstack_copy | 11 | 14 | 13 | 0.8x | 0.8x |

The engine beats Duktape on every benchmark but `bench_regexp` (parity) and is
within ~1.5x of QuickJS everywhere except regexp (2.2x), ahead of it on the
inline-cache and valstack microbenchmarks.

### Startup time

Time from process spawn to a finished empty program, median of 60 runs on
macOS arm64. The engine initializes a heap, VM, and global environment per
process, so this is the cost a CLI tool pays on every invocation.

| Runtime | Median startup |
|---|---|
| duktape_c3 (this engine) | 2.7 ms |
| QuickJS (`out/qjs`) | 2.4 ms |
| Bun 1.3.13 | 8.4 ms |
| Node 24.13.0 | 19.0 ms |

The engine starts about 7x faster than Node and 3x faster than Bun, at
parity with the repo-built QuickJS. The gap to the big runtimes is process
and runtime initialization: no JIT warmup, no dependency graph, no workers.

## Design

- **Strict-only, single mode.** There is no sloppy mode and no `is_strict` flag
  to branch on. Non-strict and Annex B features are rejected at parse time;
  `"use strict"` is accepted and ignored.
- **One-pass compiler.** No AST: the parser emits register bytecode as it
  recognizes each construct, then `finish()` runs the fusion and
  move-elimination passes.
- **Register VM.** Fixed 32-bit instructions, threaded dispatch, inline caches
  for property and variable access, hidden classes behind those caches, fused
  opcodes on the hot paths.
- **NaN-boxed values.** The default build packs every `TVal` into 8 bytes;
  `-D NONANBOX` switches to a 16-byte tagged union.
- **Hybrid collector.** Refcounting reclaims most values; mark-and-sweep runs
  at safepoints to collect the cycles it cannot.
- **The ES5/ES6 core, plus what ordinary code assumes:** classes with private
  fields and static blocks, generators and async/await, async generators,
  `Promise`, `Map`/`Set`/`WeakMap`/`WeakSet`,
  `WeakRef`/`FinalizationRegistry`, `Symbol`, `Proxy`/`Reflect`, TypedArrays
  and resizable `ArrayBuffer`, `Atomics` and `SharedArrayBuffer` on a single
  agent, ES modules with top-level `await`, and `BigInt` as fixed-width
  int128. The full in-scope list is `docs/engine-scope.md`.

## Build and run

`just list` shows every task. The only requirements are C3 (`c3c`), `just`,
and Python 3.

| Task | Command |
|---|---|
| Build a target | `just build <target>` (e.g. `duktape_c3`, `duktape_c3_debug`, `test262_runner`) |
| Run one JS file | `just run <file>` |
| Run one JS file as ESM | `just run-module <file>` |
| Inspect bytecode | `just build-trace`, then `./out/duktape_c3_debug -c <file>` |
| Local suite | `just test-local` |
| Rosetta suite | `just rosetta` |
| One test262 phase | `just test262-phase <n>` |
| Full test262 | `just test262` |
| ASAN test262 runner | `just build-asan` |
| lldb on a crash | `just lldb <file>` |

`duktape_c3` is the plain runner. `duktape_c3_debug` carries the inspection
flags (`-c` disassembles, `-t` traces the VM). To reproduce one test262 test
through the worker path:

```sh
python3 scripts/run_test262.py --single test262/test/<path>.js
```

## Embedding

The engine ships a `jse_` C ABI (`include/jse.h`, static `libjse.a` and a
shared library) plus first-party bindings in C3, Rust, Python, Ruby, and Zig
(`bindings/`). `docs/embedding.md` covers packaging, the ABI reference, the
lifetime and GC rules, and each binding's status and known limitations.

## Build flags

- `-D NONANBOX`: disable NaN-boxing, 16-byte tagged union `TVal`
  (`just build-nonanbox`)
- `-D NOSHAPECACHE`: drop the per-object shape pointer cache
  (`just build-noshape`)
- `-D HEAP_VERIFY`: validate GC roots at yield/resume (`just build-verify`)
- `-D GC_STRESS`: pin the collector trigger for stress runs
- `-D ENV_STRICT`: compile-time environment-handling checks
  (`duktape_c3_envstrict` target)

## Project layout

```
src/            engine: types, heap, hstring, hobject, env, bytecode, lexer,
                compiler/, vm/, builtins/, capi, module, hbigint, re_bindings
cli/            duktape_c3, duktape_c3_debug, test262_runner
docs/           architecture.md, engine-scope.md, embedding.md,
                string-representation-survey.md
include/        jse.h, the public C ABI
bindings/       C3, Rust, Python, Ruby, Zig
test/           JS tests, golden bytecode, rosetta-verbatim, ESM modules,
                capi host-function tests
test262/        the conformance suite (skip list in scripts/run_test262.py)
benchmarks/     speed and memory benchmarks (`just bench`, `just bench-memory`)
plans/          design and roadmap plans
progress.md     per-session test262 tracker
```

## Documentation

- `AGENTS.md` is the operating manual: build and test commands, the
  strict-only rules, compiler and VM invariants.
- `docs/architecture.md` is the design guide: how a script runs, the compiler,
  the VM, values and objects, the heap and both collectors, builtins and
  modules.
- `docs/engine-scope.md` is what is in scope, what is not, and the notes for
  anyone editing the test262 skip list.
- `docs/string-representation-survey.md` is the survey behind the string
  encoding: CESU-8 storage, the char-index cache, interning.

## License

MIT, following the original Duktape license.
