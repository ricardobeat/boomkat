# Plan 067 — `console` in the default binary, opt-out for embedders

Goal: the CLI binary ships `console` as it does today; the `lib` static-lib
target omits it, and an embedder can opt back in with one call.

**Status: unblocked.** The `util.inspect` work has landed (`e234d4df`), and it
made this plan simpler than when first written. The formatter is no longer
tangled into `global.c3` — it is a standalone `src/builtins/inspect.c3` (1106
lines) behind a two-function interface, `inspect_root` and `inspect_nested`,
called from `global.c3:186` and `:332`. So step 3 gates one self-contained file
at its two call sites rather than carving machinery out of a shared one.

## Decisions (settled with the user)

1. **Without console, `console` is simply absent** — guest `console.log(...)`
   raises `ReferenceError: console is not defined`. No silent no-op object, no
   always-on host sink. The host decides what console means; guest code that
   needs it feature-detects (`typeof console !== "undefined"`), which is normal
   for embedded JS. This also keeps the engine free of a mandatory stdio
   dependency, which matters on the low-powered targets in the project spec.
2. **`util.inspect`'s formatter is gated by the same flag.** It is reachable
   only through console (verified: no other caller in `src/`; the CLI's uncaught
   reporting lives in `cli/duktape_c3.c3` and does not use it). Gating both
   gives embedders the real size win — the formatter is the bulk of the code.

## Why a `NO…` flag, not a `CONSOLE` flag

C3 `-D` features are **additive only**; there is no way to switch one off. The
repo already solved this twice by inverting the sense:

```c3
const bool USE_SHAPE_CACHE = !$feature(NOSHAPECACHE);  // src/hobject.c3:83
const bool USE_NANBOX      = !$feature(NONANBOX);      // src/types.c3:102
```

Follow that pattern exactly — default-on, opt-out — so there is one convention
for build toggles rather than two.

```c3
/// Default is true: the CLI binary ships `console`. Pass `-D NOCONSOLE` to omit
/// the console object and the value formatter behind it, which embedders do so
/// the host decides what console means.
const bool HAS_CONSOLE = !$feature(NOCONSOLE);
```

`lib` is the only target that sets it:

```json
"lib": {
  "type": "static-lib",
  "sources": ["src"],
  "features": ["NOCONSOLE"]
}
```

Every executable target is unchanged and keeps console.

## Implementation

### 1. Extract the registration (prerequisite refactor)

Today console is built **inline** at `src/builtins/core.c3:3040-3053` —
`alloc_object`, `register_console_methods`, `env_declare_nonenum`, interleaved
with the `parseInt`/`parseFloat` registrations that follow. There is no function
to guard yet.

Extract it verbatim into a public function:

```c3
/// Install `console` on the global object. Called by the global-object builder
/// unless NOCONSOLE; embedders linking the static lib call it themselves to opt
/// back in.
fn bool register_console_object(EnvRecord* global_env, Heap* heap) { … }
```

Pure motion — no behaviour change. Verify with a green gate before step 2.

### 2. Guard the one call site

```c3
$if HAS_CONSOLE:
    if (!register_console_object(global_env, heap)) return false;
$endif
```

**Guard the registration, not the eight `builtin_console_*` bodies.** The
`Builtin` enum at `core.c3:187-194` is a table indexed by ordinal;
`$if`-ing entries out of it renumbers every later builtin and desyncs anything
that stores an ordinal. Leave the table intact. Unreferenced bodies are dropped
by the linker under `--gc-sections`, so the size win does not require touching
it.

### 3. Gate the formatter

`src/builtins/inspect.c3` is self-contained and reached only through
`inspect_root` / `inspect_nested` (called at `global.c3:186` and `:332`). Gate
the module and those two call sites under the same `$if HAS_CONSOLE:`.

Since the only callers are the console paths already gated in step 2, confirm
whether an explicit `$if` around `inspect.c3` is even needed — with no
references, `--gc-sections` should drop all 1106 lines on its own. **Measure
before adding the guard**: if the linker already removes it, the `$if` is dead
weight and should be left out. Report the measured size either way.

Keep `HAS_CONSOLE` defined in ONE place and import it; do not re-derive
`!$feature(NOCONSOLE)` per file — that is the N-copies pattern that has been the
root cause five times in this repo (BACKLOG session 302; plans 063-066).

### 4. Keep the opt-in path public

`register_console_object` must stay exported so an embedder can write:

```c3
duktape::builtins::register_console_object(global_env, heap);
```

Same function the CLI calls — one code path, no drift between the two.

## Validation

1. **Default build unchanged**: `just all`, then `just test-local` green — the
   console-format corpus is now **5796 lines** of captured expectation and is
   the real console test; it must pass unchanged. Plus `just rosetta` 41/41
   (two `.expected` files there encode inspect output, so a console regression
   shows up here too) and `just test-golden-bytecode` 28/28.
2. **`-D NOCONSOLE` builds and runs**: build an executable with the flag and
   confirm `console.log("x")` raises `ReferenceError: console is not defined`,
   while ordinary JS still evaluates. Add this as a scripted check — a build
   flag with no test rots silently.
3. **`c3c build lib` succeeds** with `NOCONSOLE` in its features.
4. **Opt-in works**: a small harness that links the lib, calls
   `register_console_object`, and gets working `console.log`. This is the half
   most likely to bit-rot, so it needs a test rather than a claim.
5. **Size delta measured, not assumed**: report stripped `lib.a` /binary size
   with and without the flag. If the saving is negligible the design is still
   right (embedders should not inherit a stdio dependency), but the number
   should be recorded rather than guessed at.
6. Full test262 unaffected — the default build is what the suite exercises.

## Out of scope

- A host-settable console sink. That is a different feature (always-on console,
  redirected output); this plan is about omission. If it is wanted later it
  composes fine: register the object, point it at a host callback.
- Splitting `NOINSPECT` from `NOCONSOLE`. Rejected as more build combinations
  to keep green than the control is worth, given inspect has no other caller.
