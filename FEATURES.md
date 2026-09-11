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
| Sloppy mode, `with`, Annex B | ⚠️ sloppy + `with`; partial Annex B | ✅ | ✅ | ✅ |

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
| `BigInt` | ✅ int128 | ✅ arbitrary | ✅ arbitrary | ❌ |
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

Scripts, ordinary function bodies and dynamic `Function()` bodies run sloppy;
modules and class code are strict, and a `"use strict"` prologue raises a unit
to strict (`plans/083-sloppy-mode.md`).

| | Status |
|---|---|
| `with`, incl. `@@unscopables` and closures over the object | ✅ (181/181 tests) |
| Implicit globals (`x = 1` undeclared) | ✅ |
| Legacy octal literals `010`, escapes `'\101'` | ✅ octal values in sloppy, SyntaxError in strict |
| Duplicate parameter names | ✅ simple parameter lists only (Annex B.3.1) |
| Unqualified `delete x` | ✅ Annex B.3.1 result rules |
| `arguments.callee` / `.caller` | ✅ |
| Two-way `arguments` ↔ parameter binding | ✅ (Annex B.3.1 mapped arguments) |
| Sloppy `this` boxing (primitive → wrapper, null/undefined → global) | ✅ |
| `flags: [noStrict]` tests | ✅ run |

Still missing from sloppy semantics: Annex B.3.2 labelled function
declarations, B.3.4 function declarations as `if` bodies, and B.3.9's
runtime error for a call used as an assignment target (the engine raises
the early SyntaxError instead, which B.3.9 leaves to the host).

### Annex B

The `annexB` suite is excluded wholesale (1086 tests), but the web-reality
parts that the engine does implement are covered from the other suites:

- Mode-independent: `__proto__`, `__defineGetter__` / `__defineSetter__` /
  `__lookupGetter__` / `__lookupSetter__`, `String.prototype.substr`,
  `RegExp.prototype.compile`, `escape` / `unescape`, HTML-like comments
  (`<!--`, `-->`).
- Sloppy-mode: Annex B.3.1 (duplicate parameter names, mapped `arguments`,
  `delete x`), B.3.3 for function declarations in a `BlockStatement`, legacy
  octals and octal escapes.

Not implemented: `Date.prototype.getYear` / `setYear`, the
`String.prototype` HTML methods (`anchor`, `big`, `blink`, …),
`RegExp.$1`–`RegExp.$9` legacy statics, and B.3.2 / B.3.4 / B.3.9 above.

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
| Arbitrary-precision `BigInt` | ~20 | int128 is the ceiling |

Also excluded as still-moving proposals: `import-defer` (229),
`source-phase-imports` (222), `joint-iteration` (82), `immutable-arraybuffer`
(66), `await-dictionary` (63), `import-text` (6).

## Engine internals

| | boomkat | QuickJS | quickjs-ng | Duktape v2.7.0 |
|---|---|---|---|---|
| Language | C3 | C | C | C |
| Baseline | ES2025 + most ES2026 | ES2025 + most ES2026 | ES2025 + most ES2026 | ES5.1, partial ES6/7 |
| `BigInt` representation | int128 | arbitrary | arbitrary | |
| `Proxy` | full | full | full | subset |
| `SharedArrayBuffer` | single agent | shared | shared | |
| Sloppy mode | supported | supported | supported | supported |
| Annex B | sloppy-mode parts | supported | supported | supported |
| RegExp engine | libregexp | libregexp | libregexp | built-in |
| TypeScript stripping | erasable only | | | |
| GC | refcount + MS | refcount + cycles | refcount + cycles | refcount + MS |
| Inspection | disasm, VM trace | bytecode dump | bytecode dump | remote debugger |
| Embedding | C ABI | C API | C API | C API |
