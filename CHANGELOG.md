# Changelog

Notable changes to Boomkat. Each heading shows the release date and the number
of commits since the previous release. Newest first.

## [Unreleased]

- Multiple agents: `Atomics.wait` blocks and `Atomics.notify` wakes waiters in
  other agents, `Atomics.waitAsync` settles and times out through the host event
  loop, and `Atomics` operations on a `SharedArrayBuffer` are atomic. The
  SharedArrayBuffer's bytes are a refcounted block that outlives the heap that
  created it. The test262 `$262.agent` host is implemented, so the 112 agent
  files and the 2 `CanBlockIsFalse` files run: `built-ins/Atomics` is 389/389.
  Stage 3 proposals are in scope in the docs again.
- Threaded dispatch now covers `WIDE`-prefixed operands, typed array element
  access, native builtin calls, constructors and `f.apply(this, arguments)`.
- Property read caches handle megamorphic sites and several shapes per site.
- Garbage collector grows the heap to three times its live set between cycles,
  sweeps the nursery in generation order, and caps incremental slices.
- String concatenation cache for short, immutable operand pairs.
- Compiler: move elimination and fusion run on whole-function liveness.
- `THIRD_PARTY` notices ship with releases; macOS executables are dead-stripped.

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
