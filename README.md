<br />
<div align="center">
  <img src="./docs/boomkat.png" alt="" width="80" />
  <h1 align="center">boomkat</h1>
  <p align="center">
    A modern, lightweight Javascript engine
  </p>
  <p>
    <img src="https://img.shields.io/badge/JavaScript-F7DF1E?logo=javascript&logoColor=000">&nbsp;<img src="https://img.shields.io/badge/TypeScript-3178C6?logo=typescript&logoColor=fff">
  </p>
</div>

<br>

**Boomkat** is a strict-only Javascript engine developed from scratch using the [C3](https://c3-lang.org/) language.

It was heavily inspired by [Duktape](https://duktape.org) and [QuickJS](https://bellard.org/quickjs/), built for embedding and to potentially target embedded devices. In contrast to latest Duktape, *boomkat* supports 100% of the ES2025 specification; it also runs TypeScript files natively, while being significantly faster and only marginally larger in size.

> *boomkat* is the dutch name for the [Margay](https://en.wikipedia.org/wiki/Margay), a small wild cat native to South America; translates to 'tree cat'. It fits with the tradition of animal-themed names for JS engines (like SpiderMonkey) and has a nice ring to it :)

## Features and compatibility

- **Strict mode** only
- 100% pass rate on **50k** tests from the [test262 conformance suite](https://github.com/tc39/test262)
- Built-in support for **ES modules**
- **Natively runs TypeScript** code (including module support), including the TypeScript compiler itself
- Supports all modern JS features: `Map/Set`, `ArrayBuffer` and `TypedArray`, `Proxy`, async/await, private fields, template literals, optional chaining

A full ECMAScript feature-by-feature breakdown against QuickJS, quickjs-ng, and
Duktape can be found in [FEATURES.md](FEATURES.md).

> 👉 **not production-ready**. In particular, the source code has not been scanned for security vulnerabilities. Use at your own risk.

## Real-world validation

Tested against production libraries.

**Javascript**: we run unmodified npm sources against the engine, run a few functional tests, and compare the results with QuickJS.

Run with `python3 scripts/verify_libraries.py --api-checks`

Validated JavaScript libraries:

- ✅ lodash
- ✅ underscore
- ✅ moment
- ✅ marked
- ✅ handlebars
- ✅ immutable.js
- ✅ typescript
- ✅ @babel/standalone
- ✅ jszip
- ✅ papaparse
- others: acorn, bluebird, decimal.js, bignumber.js, mathjs, crypto-js, protobufjs, chance, he, nearley, d3-array, uuid

**TypeScript**: we download sources and run them unmodified against the engine; the output must match the result of running the same source stripped by `tsc`.

Run with `python3 scripts/verify_ts_libraries.py`

Validated TypeScript libraries:

- ✅ microdiff
- ✅ zustand
- ✅ valtio
- ✅ @preact/signals-core
- ✅ jotai
- ✅ fp-ts
- ✅ zod

## Benchmarks

From `just bench`:

- 5x-10x faster than Duktape across the board
- matches or beats QuickJS in most benchmarks

<img src="./docs/benchmarks.png" alt="Benchmark comparison of boomkat, QuickJS and Duktape across 17 benchmarks (time in ms, lower is better)" width="900" />

## Build and run

### Requirements

- C3 compiler: `brew install c3c`
- Just: `brew install just`
- `python3` in PATH

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
