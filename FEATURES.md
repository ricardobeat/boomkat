# Feature comparison

A breakdown of ECMAScript language and runtime features, comparing boomkat
against QuickJS, quickjs-ng, and Duktape v2.7.0. boomkat's column is grounded
in the source (`src/builtins/`, `src/compiler/`), not aspiration; see
`docs/engine-scope.md` for the prose version and the reasoning behind what's
excluded.

## Syntax

| | boomkat | QuickJS | quickjs-ng | Duktape v2.7.0 |
|---|---|---|---|---|
| `let`/`const`, block scoping, TDZ | ✅ | ✅ | ✅ | ❌ |
| Arrow functions | ✅ | ✅ | ✅ | ❌ |
| Classes, `extends`, `super` | ✅ | ✅ | ✅ | ❌ |
| Public/private fields and methods | ✅ | ✅ | ✅ | ❌ |
| Static fields, methods, static blocks | ✅ | ✅ | ✅ | ❌ |
| `#x in obj` private brand check | ✅ | ✅ | ✅ | ❌ |
| Template literals, tagged templates | ✅ | ✅ | ✅ | ❌ |
| Destructuring (array/object, nested, defaults) | ✅ | ✅ | ✅ | ❌ |
| Spread/rest in calls, arrays, objects | ✅ | ✅ | ✅ | ❌ |
| Default parameters | ✅ | ✅ | ✅ | ❌ |
| `for...of`, `for...in` | ✅ | ✅ | ✅ | ⚠️ `for...in` only |
| `for await...of` | ✅ | ✅ | ✅ | ❌ |
| Generators, `yield`/`yield*` | ✅ | ✅ | ✅ | ❌ |
| async/await, async generators | ✅ | ✅ | ✅ | ❌ |
| Optional chaining (`?.`) | ✅ | ✅ | ✅ | ❌ |
| Nullish coalescing (`??`) | ✅ | ✅ | ✅ | ❌ |
| Exponentiation (`**`) | ✅ | ✅ | ✅ | ✅ |
| Logical assignment (`&&=`, `\|\|=`, `??=`) | ✅ | ✅ | ✅ | ❌ |
| Numeric separators (`1_000`) | ✅ | ✅ | ✅ | ❌ |
| Labeled statements, labeled `break`/`continue` | ✅ | ✅ | ✅ | ✅ |
| `try`/`catch`/`finally`, optional catch binding | ✅ | ✅ | ✅ | ✅ |
| ES modules (`import`/`export`, namespace objects) | ✅ | ✅ | ✅ | ❌ |
| Dynamic `import()`, `import.meta` | ✅ | ✅ | ✅ | ❌ |
| Top-level `await` | ✅ | ✅ | ✅ | ❌ |
| Import attributes (`with { type: "json" }`) | ✅ | ✅ | ⚠️ parsed only | ❌ |
| `import defer` (ES2026) | ❌ | ❌ | ❌ | ❌ |
| Decorators | ❌ | ❌ | ❌ | ❌ |
| `using`/`await using`, explicit resource management | ❌ | ❌ | ❌ | ❌ |
| Sloppy mode, `with`, Annex B | ❌ rejected | ✅ | ✅ | ✅ |

## Objects, functions, reflection

| | boomkat | QuickJS | quickjs-ng | Duktape v2.7.0 |
|---|---|---|---|---|
| Property descriptors, accessors | ✅ | ✅ | ✅ | ✅ |
| `Object` static methods (`assign`, `entries`, `fromEntries`, `groupBy`, `hasOwn`, freeze/seal family, ...) | ✅ | ✅ | ✅ | ⚠️ partial |
| `Proxy`, all traps | ✅ | ✅ | ✅ | ⚠️ subset |
| `Reflect`, full method set | ✅ | ✅ | ✅ | ❌ |
| `Function.prototype.bind`/`call`/`apply` | ✅ | ✅ | ✅ | ✅ |
| `Symbol`, well-known symbols, `Symbol.description` | ✅ | ✅ | ✅ | ⚠️ no description |
| `globalThis` | ✅ | ✅ | ✅ | ✅ |
| Proper tail calls | ❌ | ❌ | ❌ | ✅ |

## Collections and memory

| | boomkat | QuickJS | quickjs-ng | Duktape v2.7.0 |
|---|---|---|---|---|
| `Map`/`Set`, full method set incl. `getOrInsert` | ✅ | ✅ | ✅ | ❌ |
| `Set` methods (`union`, `intersection`, `difference`, ...) | ✅ | ✅ | ✅ | ❌ |
| `WeakMap`/`WeakSet` | ✅ | ✅ | ✅ | ❌ |
| `WeakRef`, `FinalizationRegistry` | ✅ | ✅ | ✅ | ❌ |
| `ArrayBuffer`, resizable `ArrayBuffer` | ✅ | ⚠️ fixed-only | ✅ | ❌ |
| `TypedArray` family, `DataView` | ✅ | ✅ | ✅ | ✅ |
| Base64/hex `TypedArray` helpers (`fromBase64`, `toHex`, ...) | ✅ | ✅ | ✅ | ❌ |
| `SharedArrayBuffer`, `Atomics` | ⚠️ single agent | ✅ | ✅ | ❌ |
| `structuredClone` | ❌ | ❌ | ❌ | ❌ |

## Numbers, strings, dates

| | boomkat | QuickJS | quickjs-ng | Duktape v2.7.0 |
|---|---|---|---|---|
| `BigInt` | ✅ arbitrary | ✅ arbitrary | ✅ arbitrary | ❌ |
| `Number` static methods, `toFixed`/`toPrecision`/`toExponential` | ✅ | ✅ | ✅ | ⚠️ partial |
| `Math.sumPrecise` (ES2026) | ✅ | ✅ | ✅ | ❌ |
| `String.raw`, `padStart`/`padEnd`, `includes`, `at` | ✅ | ✅ | ✅ | ⚠️ `includes` only |
| `String` well-formed UTF-16 (`isWellFormed`, `toWellFormed`) | ✅ | ✅ | ✅ | ❌ |
| `Array`/`TypedArray` well-known additions (`from`/`of`/`flat`/`at`/`with`/`toSorted`/`toReversed`/`toSpliced`) | ✅ | ✅ | ✅ | ❌ |
| `Array.fromAsync` | ✅ | ❌ | ❌ | ❌ |
| `Date`, full get/set/UTC surface | ✅ | ✅ | ✅ | ✅ |
| `JSON.rawJSON`/`isRawJSON`, `parse` source access (ES2026) | ✅ | ✅ | ✅ | ❌ |
| `Intl` (ECMA-402) | ❌ | ❌ | ⚠️ partial (ng) | ❌ |

## RegExp

| | boomkat | QuickJS | quickjs-ng | Duktape v2.7.0 |
|---|---|---|---|---|
| Named capture groups, lookbehind | ✅ | ✅ | ✅ | ❌ |
| `s` (dotAll), `u` (unicode), `d` (indices) flags | ✅ | ✅ | ✅ | ❌ |
| `v` flag (`unicodeSets`), set notation, modifiers | ✅ | ✅ | ✅ | ❌ |
| `RegExp.escape` | ✅ | ✅ | ✅ | ❌ |

## Iterators and control-flow additions

| | boomkat | QuickJS | quickjs-ng | Duktape v2.7.0 |
|---|---|---|---|---|
| Iterator protocol, `Symbol.iterator`/`asyncIterator` | ✅ | ✅ | ✅ | ❌ |
| Iterator helpers (`map`, `filter`, `take`, `drop`, `flatMap`, ...) | ✅ | ✅ | ✅ | ❌ |
| `Iterator.concat` (ES2026) | ✅ | ✅ | ✅ | ❌ |
| `Promise`, microtask queue | ✅ | ✅ | ✅ | ❌ |
| `Promise.allSettled`/`any`/`withResolvers`, `AggregateError` | ✅ | ✅ | ✅ | ❌ |
| `Error.isError` (ES2026) | ✅ | ✅ | ✅ | ❌ |

## Other

| | boomkat | QuickJS | quickjs-ng | Duktape v2.7.0 |
|---|---|---|---|---|
| TypeScript type stripping | ✅ erasable-only | ❌ | ❌ | ❌ |
| Temporal | ❌ | ❌ | ⚠️ partial (ng) | ❌ |
| Built-in debugger protocol | ❌ | ❌ | ❌ | ✅ |

## Unsupported

What the engine does not implement, and why. Counts are test262 files excluded
by `scripts/run_test262.py` (25.8% of the suite); see `docs/engine-scope.md`
for the reasoning.

### Sloppy mode

The engine is strict-only: one execution mode, no runtime strictness flag.

| | Status |
|---|---|
| `with` | ❌ rejected at parse time (181 tests) |
| Implicit globals (`x = 1` undeclared) | ❌ ReferenceError |
| Legacy octal literals `010`, escapes `'\101'` | ❌ SyntaxError |
| Duplicate parameter names | ❌ SyntaxError |
| Unqualified `delete x` | ❌ SyntaxError |
| `arguments.callee` / `.caller` | ❌ (23 tests) |
| Two-way `arguments` ↔ parameter binding | ❌ |
| Sloppy `this` boxing (primitive → wrapper) | ❌ |
| `flags: [noStrict]` tests | ❌ skipped (1313 tests) |

Two deliberate exceptions, both spec-required rather than sloppy mode:

- **Dynamic code reserved words.** An indirect `eval` or a `Function()` body is
  non-strict per ES2024 §19.2.1.1 / §20.2.1.1 unless it has its own `"use
  strict"`, so `eval`, `arguments` and the FutureReservedWords are legal
  binding names there. Only identifier reservation relaxes — octals and the
  rest above stay rejected. Direct `eval` inherits the caller's strictness and
  so stays strict.
- **`this`-substitution.** `Function('return this')()` yields the global
  object (the UMD idiom). This is not a strictness distinction here: it is set
  only on dynamic bodies, cleared by a `"use strict"` prologue, and never
  inherited by nested functions.

### Annex B

Mostly unsupported (1086 tests excluded), because most of it is sloppy-mode
behavior. The web-reality parts that are mode-independent **are** implemented:
`__proto__`, `__defineGetter__` / `__defineSetter__` / `__lookupGetter__` /
`__lookupSetter__`, `String.prototype.substr`, `RegExp.prototype.compile`,
`escape` / `unescape`, and HTML-like comments (`<!--`, `-->`).

Not implemented: `Date.prototype.getYear` / `setYear`, the
`String.prototype` HTML methods (`anchor`, `big`, `blink`, …),
`RegExp.$1`–`RegExp.$9` legacy statics, and block-scoped function
semantics.

### Out of scope

| | Tests | Why |
|---|---:|---|
| Temporal | 4611 | Stage 3, still moving |
| ECMA-402 (`intl402`) | 3341 | Separate specification |
| test262 `staging/` | 1485 | Not normative |
| Explicit resource management | 398 | Stage 3 (`using`, `DisposableStack`) |
| Cross-realm | 179 | No second realm |
| Multi-agent (`$262.agent`) | 114 | Needs threads; `Atomics` on one agent ships |
| ShadowRealm | 64 | Stage 3 |
| Decorators | 24 | Stage 3 |
| Proper tail calls | 35 | Not implemented |

Also excluded as still-moving proposals: `import-defer` (229),
`source-phase-imports` (222), `joint-iteration` (82), `immutable-arraybuffer`
(66), `await-dictionary` (63), `import-text` (6).

## Engine internals

| | boomkat | QuickJS | quickjs-ng | Duktape v2.7.0 |
|---|---|---|---|---|
| Language | C3 | C | C | C |
| Baseline | ES2025 + most ES2026, strict-only | ES2025 + most ES2026 | ES2025 + most ES2026 | ES5.1, partial ES6/7 |
| `BigInt` representation | arbitrary (32-bit limb vector) | arbitrary | arbitrary | |
| `Proxy` | full | full | full | subset |
| `SharedArrayBuffer` | single agent | shared | shared | |
| Sloppy mode | rejected | supported | supported | supported |
| Annex B | mode-independent parts only | supported | supported | supported |
| RegExp engine | libregexp | libregexp | libregexp | built-in |
| TypeScript stripping | erasable only | | | |
| GC | refcount + MS | refcount + cycles | refcount + cycles | refcount + MS |
| Inspection | disasm, VM trace | bytecode dump | bytecode dump | remote debugger |
| Embedding | C ABI | C API | C API | C API |
