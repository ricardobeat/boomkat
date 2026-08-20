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

## Engine internals

| | boomkat | QuickJS | quickjs-ng | Duktape v2.7.0 |
|---|---|---|---|---|
| Language | C3 | C | C | C |
| Baseline | ES2025 + most ES2026, strict-only | ES2025 + most ES2026 | ES2025 + most ES2026 | ES5.1, partial ES6/7 |
| `BigInt` representation | int128 | arbitrary | arbitrary | |
| `Proxy` | full | full | full | subset |
| `SharedArrayBuffer` | single agent | shared | shared | |
| Sloppy mode, Annex B | rejected | supported | supported | supported |
| RegExp engine | libregexp | libregexp | libregexp | built-in |
| TypeScript stripping | erasable only | | | |
| GC | refcount + MS | refcount + cycles | refcount + cycles | refcount + MS |
| Inspection | disasm, VM trace | bytecode dump | bytecode dump | remote debugger |
| Embedding | C ABI | C API | C API | C API |
