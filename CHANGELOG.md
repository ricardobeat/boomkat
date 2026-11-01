# Changelog

Notable changes to Boomkat. Each heading shows the release date and the number
of commits since the previous release. Newest first.

## [Unreleased]

## [0.3.0] - 2026-10-30 · 259 commits

- Strings stored as Latin-1 or UTF-16; faster JSON on non-ASCII text.
- C API: breaking cleanup of runtime/context options, handles and callbacks.
- C API: host classes, proxies, weak handles, promises, modules, buffers, GC control.
- C++ `bk::` header-only API with a CMake package.
- Bindings gain compiled scripts and module loaders.
- Multi-agent `Atomics` and `SharedArrayBuffer`; `built-ins/Atomics` 389/389.
- Wider threaded dispatch and megamorphic property read caches.
- GC: heap grows to 3x live set, generation-ordered sweeps, capped slices.
- Compiler: whole-function liveness for move elimination and fusion.
- Smaller TINY runner; macOS executables are dead-stripped.
- `THIRD_PARTY` notices ship with releases.

## [0.2.0] - 2026-10-21 · 111 commits

- Intl and Temporal are explicit build profiles: default, slim and tiny builds
  omit them, `boomkat-full-icu` bundles the data.
- Calendar engine for every CLDR calendar Temporal requires; Temporal and
  `Intl.DateTimeFormat` resolve fields through the calendar.
- Intl: `Collator` with all ICU tailorings, `Locale`, `Segmenter`, `ListFormat`,
  `RelativeTimeFormat`, `DisplayNames`, `DurationFormat`, non-English
  `NumberFormat`/`PluralRules`/`DateTimeFormat` locale rows, compact time zone
  data.
- Shared-runtime realms (`bk_new_context(runtime)`) and redesigned embedding APIs.
- Explicit resource management: `using`, `await using`, disposal stacks,
  `SuppressedError`. Added `Promise.allKeyed` and `Promise.allSettledKeyed`.
- Bytecode: branch, `TRY` and constant-index operands are no longer limited to
  16 bits.
- Collector sources moved to `src/gc`; test262 runs every test in both sloppy
  and strict mode.

## [0.1.0] - 2026-10-20 · 150 commits

- Parser and code generator moved to a flat AST, with early errors resolved over it.
- Compile-time engine providers and portable module bytecode.
- Tiny and slim build profiles with feature flags for trimming builtins.
- Host hooks for promise rejection tracking and watchdog interrupts; C3 binding
  with a pluggable module reader.
- TypeScript type stripping and JSX lowering.
- Release binaries for macOS x64 and Windows.

## [0.0.1] - 2026-10-06 · 3232 commits

First release. Began on 2026-05-22 as a C3 port of Duktape.

- Register-based bytecode VM with threaded dispatch, compiler, and RegExp engine.
- Mark-and-sweep garbage collector, later incremental and generational with
  write barriers and allocation-paced slices.
- Delta shapes for objects with inline caches.
- ES2015+ core: classes, generators, async functions, Proxy, typed arrays,
  BigInt, Symbol, Temporal.
- ES modules, dynamic `import()` and import attributes; the CLI evaluates
  modules by default and runs classic scripts with `--script`.
- Sloppy and strict execution modes; C embedding API.
