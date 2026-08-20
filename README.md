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

👉 This is **not production-ready** code. Surprisingly, 100% test262 conformance is not nearly enough to validate the engine. There are still bugs lurking. In particular, the source code has not been scanned for security vulnerabilities. Use at your own peril.

## Features and compatibility

- Runs everything in **strict mode** only
- Passes **50k** tests from the [test262](https://github.com/tc39/test262) suite. 100% pass rate on the targeted subset (skips sloppy mode, legacy and proposal-stage features)
- Supports all modern JS features like `Map/Set`, `ArrayBuffer` and `TypedArray`, `Proxy`, async/await, private fields, template literals, optional chaining
- Built-in support for ES modules
- **Natively runs TypeScript** code (including module support), including the TypeScript compiler itself

<p align="center">
  <img align="center" src="./docs/example_javascript.png" width="400" />
  <img align="center" src="./docs/example_typescript.png" width="400" />
</p>

A full ECMAScript feature-by-feature breakdown against QuickJS, quickjs-ng, and
Duktape can be found in [FEATURES.md](FEATURES.md).

> Note: boomkat is *not a runtime*; it does not offer file or network APIs and is not a replacement for Node/Bun - and is very far from matching V8/SpiderMonkey performance. It is meant to be embedded into a host application as a scripting language, like QuickJS.

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

Run `just bench` to benchmark against Duktape and QuickJS.

- 5x-10x faster than Duktape across the board
- match or beat QuickJS in most benchmarks

<img src="./docs/benchmarks.png" alt="Benchmark comparison of boomkat, QuickJS and Duktape across 17 benchmarks (time in ms, lower is better)" width="900" />

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

## Support this project

If you'd like to support the project, you can [sponsor me](https://github.com/sponsors/ricardobeat) on Github.

[![Sponsor](https://img.shields.io/badge/sponsor-%E2%9D%A4-red)](https://github.com/sponsors/ricardobeat)

## License

Use of this software is governed by the Business Source License included in the [LICENSE](./LICENSE) file and at www.mariadb.com/bsl11.

Can be used without restrictions for open-source work, and commercial projects up to $2M/year revenue. Source becomes MIT-licensed after four years.
