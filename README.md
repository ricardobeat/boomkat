<h1 align="left"><img width="360" alt="boomkat" src="https://github.com/user-attachments/assets/bbe5a2f2-9d08-42cf-9bf9-cb42c7d0f388" /></h1>

*Small enough to hide. Fast enough to hunt.*

**boomkat** is a tiny, fast Javascript engine with modern features.

![ECMAScript](https://img.shields.io/badge/ECMAScript-2026-f7df1e?style=flat)
![TypeScript](https://img.shields.io/badge/TypeScript-native-3178c6?style=flat)
![Size](https://img.shields.io/badge/size-2MB-555585?style=flat)
![Test262](https://img.shields.io/badge/test262-99.3%25-green?logo=javascript&logoColor=yellow)

> *boomkat* is the dutch name for the [Margay](https://en.wikipedia.org/wiki/Margay), a small wild cat native to South America that can swivel it's hindlegs 180 degrees for better climbing; it translates to *tree cat*.

## Features

- 🟨 **ECMAScript 2026** — [ES2026](https://tc39.es/ecma262/2026/) support, native ESM, top-level await, proxies and modern built-ins.
- ⚛️ **TypeScript & JSX** — run `.ts`, `.tsx`, and `.jsx` files without a build step.
- 🌎 **Temporal & Intl** — full internationalization support with the *full-ICU* build.
- 🧱 **Small footprint** — tunable build profiles down to ~700 KB.
- ⚡ **Fast execution** — outperforms QuickJS on OctaneBench.

Developed using the [C3](https://c3-lang.org/) language.

## Quick start

Download the latest `boomkat-cli` from [Releases](https://github.com/ricardobeat/boomkat/releases/latest), then run:

```sh
boomkat hello.js
```

Boomkat runs files as ES modules in strict mode by default. Use `--script` for classic script semantics.

To build from source see the [building from source](#building-from-source) section below. Minimal tooling is required.

## ECMAScript conformance

*boomkat* passes **53,240 / 53,578** Test262 tests (99.3%).

<img width="380" alt="test262-compare" src="https://github.com/user-attachments/assets/498c9584-7895-4946-a1fa-4301d55ff42e" />

<details>
<summary>Test results per ECMA edition</summary>

| Version | Passed | Rate |
|:--------|-------:|-----:|
| ES5 | 23 / 23 | 100% |
| ES2015 | 29,231 / 29,497 | 99.0% |
| ES2016 | 197 / 198 | 99.4% |
| ES2017 | 1,359 / 1,632 | 83.2% |
| ES2018 | 6,890 / 6,890 | 100% |
| ES2019 | 185 / 185 | 100% |
| ES2020 | 3,076 / 3,121 | 98.5% |
| ES2021 | 1,038 / 1,038 | 100% |
| ES2022 | 7,611 / 7,611 | 100% |
| ES2023 | 299 / 299 | 100% |
| ES2024 | 813 / 866 | 93.8% |
| ES2025 | 1,322 / 1,322 | 100% |
| ES2026 | 375 / 375 | 100% |

</details>

## Architecture

- **Compiler** — parsing, type stripping, flat AST, and register-based bytecode.
- **Optimization** — constant folding, peephole optimization, fused operations, and inlining.
- **Interpreter** — direct-threaded VM dispatch.
- **Modern GC** — incremental, generational tracing GC with string reference counting, designed for low pause times
- **JIT** — optional [sljit](https://github.com/zherczeg/sljit) backend (in development).

<details>

<summary>Engine comparison</summary>

| Engine | Lang | Front end | Bytecode | JIT | GC | Size |
|---|---|---|---|---|---|---|
| boomkat | C3 | Flat AST | Register | 🚧 * | Generational GC + string refcount | 2.2 MB |
| QuickJS | C | Single-pass | Stack | ❌ | Refcount + cycle collector | 2.2 MB |
| Duktape | C | Single-pass | Register | ❌ | Refcount + mark-sweep | 0.5 MB |
| V8 | C++ | AST | Register | ✅ | Generational, concurrent GC | 51 MB |
| Boa | Rust | AST | Register | ❌ | Tracing GC (prototype) | 30 MB |
| Kiesel | Zig | AST, IR | Register | ❌ | Boehm (bdwgc) | 17 MB |

_* not yet available in release builds_

</details>

## Performance

Currently ~10x faster than Duktape, 20-40% faster than QuickJS, with similar memory usage. Process startup time <2ms.

<img width="800"  alt="Octane bench results" src="https://github.com/user-attachments/assets/4bf3910e-16d4-44bc-af61-e009e9fc6265" />

> Results from: Apple MacBook Air, M3, 16GB

## AI disclosure

This project is built through *AI-assisted engineering*. All code is written by AI agents, but under continuous human guidance - hands-on direction, feedback and review throughout the development process. Autonomous workflows are reserved for well-scoped, bounded tasks.

Over **500 hours of human effort** have gone into the project.

### Model and agent usage stats</summary>

**40B-50B** tokens used so far (estimated). The core of the engine was largely written using open models (MiMo, Minimax, DeepSeek), especially at earlier stages.

<img width="1055" height="490" alt="boomkat-commits" src="https://github.com/user-attachments/assets/6bb6502d-69a8-445c-9192-902b448ff964" />

<details>
    <summary>Commits by model</summary>
    <img width="1057" height="701" alt="boomkat-models" src="https://github.com/user-attachments/assets/253821da-8ab3-4d80-aa13-6555e8207a06" />
</details>

<details>
    <summary>Human input</summary>
    <strong>5000+</strong> unique prompts. 2000+ longer than ten words, 887 were Ralph-style loop prompts.
    <img width="1054" height="280" alt="boomkat-prompts" src="https://github.com/user-attachments/assets/b691b426-5ce9-4ccd-a58b-d273c65d3cd1" />
</details>

### Building from source

#### Requirements

- C3 compiler (v0.8.4+): `brew install c3c` | `pacman -S c3c`
- Just task runner: `brew install just` | `pacman -S just`
- `python3` available in your PATH

Then `git clone https://github.com/ricardobeat/boomkat` and run `c3c build`. See `just --list` for a full list of available build outputs and tasks.

<details>
<summary>Build flags</summary>

- `-D TRACE_VM`: Enable bytecode disassembly and VM tracing
- `-D OP_PROFILE`: Enable opcode profiling
- `-D GC_PROFILE`: Enable GC profiling
- `-D NONANBOX`: disable NaN-boxing, 16-byte tagged union `TVal`
- `-D NOSHAPECACHE`: drop the per-object shape pointer cache
- `-D HEAP_VERIFY`: validate GC roots at yield/resume

See [docs/build-flags.md](docs/build-flags.md) for the full list.
</details>

### Build profiles

The default release files come in several build profiles, allowing you to trade language features and internationalization support for binary size:

- **`boomkat`** — default CLI with modern ECMAScript features and English-language internationalization.
- **`boomkat-full-icu`** — complete Intl and Temporal APIs with bundled locale data and collation support. Over 4 MB.
- **`boomkat-slim`** — approximately 1.5 MB, excluding TypeScript, JSX, Temporal, Intl, BigInt, Proxy, and other optional features.
- **`boomkat-tiny`** — approximately 700 KB, with a reduced ECMAScript feature set and no parser. Executes precompiled bytecode only.

```sh
just build-tiny
./out/boomkat_tiny_compile --compile program.bkbc program.js
./out/boomkat_tiny program.bkbc
```

<details>
    <summary>Intl options</summary>

```sh
just build boomkat --intl=none --temporal=false
just build boomkat --intl=small
just build boomkat --intl=small --collator=true
just build boomkat --intl=full --temporal=true
just build boomkat-full-icu
just build boomkat-full-icu --collator=false
```

`--intl=small` enables English Intl formatting and Unicode text segmentation.
`--collator=true` adds root collation to small builds. Full builds enable
Collator with locale tailorings by default; `--collator=false` omits it.
`boomkat-full-icu` enables full bundled Intl data, Collator, and Temporal.
It uses the native C3 implementation and links no ICU runtime. Full data includes
the bundled formatting locales and ICU-derived collation tailorings. `intl=system` is
reserved for an ICU backend and reports an error until that backend exists.
`just test-local` and test262 use full builds; the test runner detects its worker's
available features automatically.

</details>

## Language bindings

The engine ships a `bk_` C ABI (`include/boomkat.h`, static `boomkat.a` and a
shared library). See `docs/embedding.md`.

A quick example in C exposing a host function:

<details>
    <summary>C binding example</summary>
    
```c
#include <boomkat.h>
#include <stdio.h>

static void print(bk_ctx js, void *out) {
    fprintf(out, "%s\n", bk_cstr(js, bk_arg(js, 0), NULL));
}

int main(void) {
    bk_ctx js = bk_create();
    bk_register_fn(js, 0, "print", print, 1, 0, stdout);
    int failed = bk_exec(js, "print('Hello, world from Boomkat!')");
    if (failed) fprintf(stderr, "%s\n", bk_error(js));
    bk_destroy(js);
    return failed;
}
```

This example is available at [bindings/c/hello.c](bindings/c/hello.c). Build the static library with `just build-lib`, then run `just example-c-hello`.

</details>

> Bindings for Go, Rust, Python, Ruby, and Zig are currently a work in progress.


## Credits

Thanks to the [Duktape](https://duktape.org) and [QuickJS](https://github.com/bellard/quickjs) authors. This engine initially started as an attempt to port Duktape to the C3 language, eventually trying to match QuickJS, and ultimately becoming something entirely new. It wouldn't exist without these prior works.

## License

Use of this software is governed by the Business Source License included in the [LICENSE](./LICENSE) file.

tl;dr *boomkat* can be used without restrictions for open-source, personal and commercial projects up to $2M/year revenue, and each release becomes MIT-licensed after four years.

See THIRD_PARTY for third-party licenses (QJS, Duktape, vendored modules).

## Support this project

[![Sponsor](https://img.shields.io/badge/sponsor-%E2%9D%A4-red)](https://github.com/sponsors/ricardobeat)

