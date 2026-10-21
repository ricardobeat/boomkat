<div align="center">
<img width="161" height="67" alt="boomkat" src="https://github.com/user-attachments/assets/16c109a6-13cb-4f98-97e5-43e89cfcba3b" />

**Boomkat** is a modern, small Javascript engine developed using the [C3](https://c3-lang.org/) language.

It supports 100% of the [ES2025 spec](https://tc39.es/ecma262/2025/), has native TypeScript and JSX support, in a ~2MB package.

<img src="https://img.shields.io/badge/JavaScript-F7DF1E?logo=javascript&logoColor=000">&nbsp;<img src="https://img.shields.io/badge/TypeScript-3178C6?logo=typescript&logoColor=fff">

</div>

## Getting started

The easiest way to try it out is by downloading the latest `boomkat-cli` release from the [Releases](/releases) page. Or check the [building from source](#building-from-source) section below.

## Features

#### ⚡ Modern JS, built in

Boomkat targets the latest ECMAScript spec. It has ES modules, top-level await, private fields, proxies, async generators, and BigInt. It also has Iterator helpers, resizable ArrayBuffers, and explicit resource management (`using`). Temporal and Intl are available in the full ICU build.

#### ✂️ TypeScript and JSX without a build step

Run `.ts` and `.tsx` files natively. Type annotations are stripped by the parser. Respects `tsconfig.json` settings too. This lets you write software without any extra build tooling in your pipeline.

#### 🧱 Small and tunable

The default build is ~2MB, the *slim* profile ~1.5MB, and the *tiny* one about 700KB. You can pick and match build flags to trade features for size exactly the way you want it. No complex build tooling required besides the `c3c` compiler.

#### 🧪 Full ECMAScript compliance

Boomkat currently passes 99%+ of the test262 suite, above QuickJS, V8, Spidermonkey and JavascriptCore. Pass rate is 100% for most ECMAScript editions (ES5, ES2015, ES2025 etc). The engine has an extensive validation pipeline that checks it against qjs/node, test262, extensive regression and performance tests, and a set of popular javascript and typescript projects on every build.

#### 🪝 Embedding API

Friendly C embedding API - or use it as a library directly in a C3 project.

A full ECMAScript feature-by-feature breakdown against QuickJS, quickjs-ng, and Duktape can be found in [docs/features.md](docs/features.md).

## Performance

The engine is currently ~**10x** faster than Duktape, while using similar amounts of memory, and matches or beats QuickJS performance in primitive workloads. Currently slightly lagging behind QuickJS in Octane Bench. The numbers below exclude startup/teardown costs.

<img src="./docs/benchmarks.png" alt="Benchmark comparison of boomkat, QuickJS and Duktape across 17 benchmarks (time in ms, lower is better)" width="680" />

## A little backstory

Boomkat started around April 2026 as an attempt to port [Duktape](https://duktape.org) to C3 (thank you @svaarala!).

It quickly evolved into a personal AI-orchestration challenge - the Bun port to Rust cost $1+ million dollars, how much could I get done with open models and my close-to-zero budget? 

The engine is written using *AI-assisted engineering*: code is written by machines, but _heavily guided and edited by humans_. 400+ hours so far have been put into design, research, testing and agent orchestration.

> *boomkat* is the dutch name for the [Margay](https://en.wikipedia.org/wiki/Margay), a small wild cat native to South America; translates to 'tree cat'. It fits with the tradition of animal-themed names for JS engines (like SpiderMonkey) and has a nice ring to it :)

### Building from source

#### Requirements

- C3 compiler (v0.8.4+): `brew install c3c` | `pacman -S c3c`
- Just 1.46 or newer: `brew install just` | `pacman -S just`
- `python3` available in your PATH

Then `git clone https://github.com/ricardobeat/boomkat` and run `c3c build`. See `just --list` for a full list of available build outputs and tasks.

#### Build flags

- `-D TRACE_VM`: Enable bytecode disassembly and VM tracing
- `-D OP_PROFILE`: Enable opcode profiling
- `-D GC_PROFILE`: Enable GC profiling
- `-D NONANBOX`: disable NaN-boxing, 16-byte tagged union `TVal`
- `-D NOSHAPECACHE`: drop the per-object shape pointer cache
- `-D HEAP_VERIFY`: validate GC roots at yield/resume

See [docs/build-flags.md](docs/build-flags.md) for the full list.

### Build profiles

To show the modular engine features, we ship a few different build profiles:

The default **boomkat** CLI builds with all ES features, but only English-language localization. The engine ships it's own intl code taking the final build to over 4MB. Build with `just build-full-icu`.

**boomkat-full-icu** includes complete `Intl` and `Temporal` APIs for every language. The engine ships it's own intl code taking the final build to over 4MB. Build with `just build-full-icu`.

**boomkat-slim** is a smaller build that is strict-only, excludes the builtin `console`, `Temporal`, `Intl`, `BigInt`, `Proxy`, typescript and jsx support to achive a roughly ~1.5MB binary size. Build with `just build-slim`.

**boomkat-tiny** also excludes `RegExp`, `Map/Set`, `Iterators`, `SharedArrayBuffer` and a bunch of other modern features to achieve extreme size reduction. It is basically an ES2015 strict mode engine. It also *excludes the parser* and can only run precompiled bytecode:

```sh
just build-tiny
./out/boomkat_tiny_compile --compile program.bkbc program.js
./out/boomkat_tiny program.bkbc
```

### Intl options

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

### Strict-mode is the default

The CLI runs files as ES modules with `boomkat main.js`, so `import`, `export` and top-level `await` work. Use the
`--script` flag to run files in sloppy mode instead.

## Not implemented / unplanned

- decorators
- stage 2 features

## Language bindings

The engine ships a `bk_` C ABI (`include/boomkat.h`, static `boomkat.a` and a
shared library). See `docs/embedding.md`.

A quick example in C exposing a host function:

```c
#include <boomkat.h>
#include <stdio.h>

static bk_value print(bk_ctx ctx, bk_value receiver, unsigned argc,
                      const bk_value *argv, void *output) {
    (void)receiver;
    if (argc) {
        const char *text = bk_to_cstring(ctx, argv[0], NULL);
        if (!text) return BK_EXCEPTION;
        fprintf(output, "%s\n", text);
        bk_free_cstring(ctx, text);
    }
    return bk_new_undefined(ctx);
}

int main(void) {
    bk_runtime runtime = bk_new_runtime();
    bk_ctx ctx = bk_new_context(runtime);
    if (!ctx) { bk_free_runtime(runtime); return 1; }
    const bk_fn_def functions[] = {{"print", print, 1, 0, stdout}, BK_FN_END};
    bk_set_function_list(ctx, 0, functions);
    const char *source = "print('Hello, world from Boomkat!')";
    bk_value result = bk_eval(ctx, source, strlen(source), "hello.js", BK_EVAL_GLOBAL);
    int failed = bk_is_exception(result);
    if (failed) fprintf(stderr, "%s\n", bk_get_error_message(ctx));
    bk_free_value(ctx, result);
    bk_free_context(ctx);
    bk_free_runtime(runtime);
    return failed;
}
```

This example is available at [bindings/c/hello.c](bindings/c/hello.c). Build the static library with `just build-lib`, then run `just example-c-hello`.

> Bindings for Go, Rust, Python, Ruby, and Zig are currently a work in progress.

## License

Use of this software is governed by the Business Source License included in the [LICENSE](./LICENSE) file.

tl;dr Boomkat can be used without restrictions for open-source, personal and commercial projects up to $2M/year revenue, and each release becomes MIT-licensed after four years.

## Support this project

[![Sponsor](https://img.shields.io/badge/sponsor-%E2%9D%A4-red)](https://github.com/sponsors/ricardobeat)
