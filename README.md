<br />
<div align="center">
  <img src="./docs/boomkat.png" alt="" width="80" />
  <h1 align="center">boomkat</h1>
  <p align="center">
    A modern, fully ES compatible, strict-only javascript engine
  </p>
</div>

> *boomkat* is the dutch name for the [Margay](https://en.wikipedia.org/wiki/Margay), a small wild cat native to South America; translates to 'tree cat'. It fits with the tradition of animal-themed names for JS engines and sounds cool :)

## About

**Boomkat** is a strict-only Javascript engine developed from scratch. It is written in [C3](https://c3-lang.org/), using Duktape and QuickJS as architectural references. The goal was to match Duktape's performance, but ended up matching (even slightly surpassing) QuickJS in runtime performance and memory usage.

👉 This is **not production-ready** code. In particular, the engine has not been scanned for security vulnerabilities. Use at your own peril.

## Compatibility

The engine passes 100% of a targeted subset of ES5/ES6. Because it only runs in strict mode, sloppy mode tests are skipped. A full **50,002** tests pass using the official [test262](https://github.com/tc39/test262) suite, with zero failures or compile errors.

## Features

All modern ES features are supported: `Map/Set`, `ArrayBuffer` and `TypedArray`, `Proxy` objects, Promises and async/await, private fields, template literals, optional chaining, etc. The engine also has built-in support for ES modules.

It can also *natively execute TypeScript* by stripping types at runtime. The module system is TS-aware so you can run typescript projects directly from source. The engine can sucessfully run libraries like **Zod**, **fp-ts**, and the TypeScript compiler itself.

A full ECMAScript feature-by-feature breakdown against QuickJS, quickjs-ng, and
Duktape can be found in [FEATURES.md](FEATURES.md).

> Note that boomkat is *not a runtime*: it does not offer file or network APIs and is not a replacement for Node/Bun - and is very far from matching V8/SpiderMonkey performance. It is meant to be embedded into a host application as a scripting language, like QuickJS.

## Why?

This started as a simple attempt at converting Duktape from C to C3. I was bored, excited about doing something in the C3 lang, and really wanted to see what could be done using the latest generation of open-weight LLMs. As development went on I dropped the idea of a 1:1 port and started looking at other engines for new ideas.

This project took about 12 weeks of nearly non-stop AI agents, working day and night. An estimated ~$300 was spent across Minimax, DeepSeek, Xiaomi Mimo, Claude Code and a dozen other LLMs. A full write-up on the development process, timeline and cost breakdown is in the works.

## Design

- **Strict-only.** There is no sloppy mode. Non-strict and Annex B features are rejected at parse time;
  `"use strict"` is accepted and ignored.
- **One-pass compiler.** No AST, parser emits bytecode.
- **Register VM.** 32-bit instructions, inline caches for property and variable access, hidden classes / object shapes, peephole optimizations and fused opcodes on the hot paths.
- **Threaded dispatch**. Direct-threaded dispatch achieved through tail-call optimization in LLVM as C3 does not have computed-goto.
- **NaN-boxed values.** Uses 8-byte packed `TVal` structs; A plain tagged union mode is available with `-D NONANBOX` for debugging and portability
- **Hybrid collector.** Refcounting reclaims most values; a mark-and-sweep GC collects the rest

## Real-world validation

Apparently fifty thousand tests are not nearly enough to verify that the engine actually works. A trillion bugs were uncovered by actually trying to run code.

**Javascript**: we run unmodified npm sources against the engine. The `python3 scripts/verify_libraries.py --api-checks` script downloads and tries to execute each library, then runs a few tests against each, and compare the results with QuickJS:

| Library | Version | Loading | API checks |
|---|---|:---:|---:|
| lodash | 4.17.21 | ✅ | 17 |
| underscore | 1.13.6 | ✅ | 8 |
| moment | * | ✅ | 6 |
| marked | 4.3.0 | ✅ | 5 |
| handlebars | 4.7.8 | ✅ | 5 |
| immutable | * | ✅ | 6 |
| acorn | * | ✅ | 4 |
| bluebird | 3.7.2 | ✅ | 5 |
| decimal.js | * | ✅ | 5 |
| bignumber.js | * | ✅ | 7 |
| mathjs | * | ✅ | 5 |
| jszip | 3.10.1 | ✅ | 4 |
| papaparse | * | ✅ | 4 |
| crypto-js | * | ✅ | 4 |
| protobufjs | 7.4.0 | ✅ | 2 |
| chance | * | ✅ | 5 |
| he | * | ✅ | 4 |
| nearley | * | ✅ | 2 |
| d3-array | * | ✅ | 7 |
| uuid | 8.3.2 | ✅ | 2 |
| typescript | 5.4.5 | ✅ | 4 |
| @babel/standalone | 7.24.7 | ✅ | 3 |

**TypeScript**: `python3 scripts/verify_ts_libraries.py` downloads sources and runs them
unmodified against the engine. The output must match the result of running the same source stripped by `tsc`.

| Source | Version | What is checked | Pass |
|---|---|---|:---:|
| microdiff | 1.4.0 | single-file diff library | ✅ |
| zustand | 5.0.3 | vanilla store (`src/vanilla.ts`) | ✅ |
| valtio | 2.1.3 | vanilla store + vendored proxy-compare 3.0.1 | ✅ |
| @preact/signals-core | 1.14.4 | signal primitives (`src/index.ts`) | ✅ |
| jotai | 2.20.2 | vanilla package tree (`src/vanilla/`) | ✅ |
| fp-ts | 2.16.9 | full source tree (123 modules), bare self-imports, `import X = Y`, overload signatures | ✅ |
| zod | 4.4.3 | lib tree (107 modules), NodeNext `.js` specifiers, type modifiers in re-export lists | ✅ |

## Benchmarks

Run `just bench` to benchmark against Duktape and QuickJS:

| Benchmark | C3 (ms) | Duktape (ms) | QuickJS (ms) | vs Duktape | vs QuickJS |
|---|---|---|---|---|---|
| bench_arithmetic | 332 | 3,305 | 246 | 0.1x | 1.3x |
| bench_array | 12 | 40 | 9 | 0.3x | 1.3x |
| bench_date | 77 | 885 | 49 | 0.1x | 1.6x |
| bench_function_call | 222 | 1,266 | 148 | 0.2x | 1.5x |
| bench_ic_monomorphic | 81 | 283 | 88 | 0.3x | 0.9x |
| bench_ic_proto | 114 | 447 | 110 | 0.2x | 1.0x |
| bench_loop | 113 | 1,342 | 119 | 0.1x | 0.9x |
| bench_memory_heavy | 76 | 170 | 49 | 0.4x | 1.6x |
| bench_object | 356 | 1,647 | 208 | 0.2x | 1.7x |
| bench_property_lookup | 243 | 1,756 | 156 | 0.1x | 1.6x |
| bench_recursion_deep | 863 | 1,954 | 490 | 0.4x | 1.8x |
| bench_recursion | 207 | 468 | 120 | 0.4x | 1.7x |
| bench_regexp | 542 | 652 | 258 | 0.8x | 2.1x |
| bench_shape_no_call | 8 | 8 | 5 | 1.0x | 1.6x |
| bench_shape_stress | 8 | 8 | 5 | 1.0x | 1.6x |
| bench_string | 9 | 17 | 6 | 0.5x | 1.5x |
| bench_valstack_copy | 11 | 13 | 10 | 0.8x | 1.1x |

### Startup time

| Runtime | Median startup |
|---|---|
| boomkat | 2.7 ms |
| QuickJS | 2.4 ms |
| Bun 1.3.13 | 8.4 ms |
| Node 24.13.0 | 19.0 ms |

(not an entirely fair comparison as bun/node do a *lot more*, but useful for a baseline)

## Build and run

### Requirements

- C3 compiler: `brew install c3c`
- Just: `brew install just`
- Python 3

| Task | Command |
|---|---|
| Build a target | `just build <target>` (e.g. `boomkat`, `boomkat_debug`, `test262_runner`) |
| Run one JS file | `just run <file>` |
| Run one JS file as ESM | `just run-module <file>` |
| Inspect bytecode | `just build-trace`, then `./out/boomkat_debug -c <file>` |
| Local suite | `just test-local` |
| Rosetta suite | `just rosetta` |
| One test262 phase | `just test262-phase <n>` |
| Full test262 | `just test262` |
| ASAN test262 runner | `just build-asan` |
| lldb on a crash | `just lldb <file>` |

## Embedding / bindings

The engine ships a `jse_` C ABI (`include/jse.h`, static `libjse.a` and a
shared library). See `docs/embedding.md`.

Bindings in C3, Rust, Python, Ruby, and Zig
(`bindings/` and `examples/`) are **work in progress*.

## Build flags

- `-D NONANBOX`: disable NaN-boxing, 16-byte tagged union `TVal`
  (`just build-nonanbox`)
- `-D NOSHAPECACHE`: drop the per-object shape pointer cache
  (`just build-noshape`)
- `-D HEAP_VERIFY`: validate GC roots at yield/resume (`just build-verify`)
- `-D GC_STRESS`: pin the collector trigger for stress runs
- `-D ENV_STRICT`: compile-time environment-handling checks
  (`boomkat_envstrict` target)

## License

Use of this software is govered by the Business Source License included in the [LICENSE](./LICENSE) file and at www.mariadb.com/bsl11.

Can be used without restrictions for open-source work, and commercial projects up to $2M/year revenue. Source becomes MIT-licensed after four years.
