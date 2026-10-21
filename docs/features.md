# Feature comparison

A breakdown of ECMAScript language and runtime features, comparing boomkat
against QuickJS, quickjs-ng, and Duktape v2.7.0. boomkat's column is grounded
in the source (`src/builtins/`, `src/compiler/`); see
[engine-scope.md](engine-scope.md) for scope and exclusions.

Checked against Boomkat's source and skip rules on 2026-10-13. The
comparison columns cover QuickJS upstream, quickjs-ng 0.15.1, and Duktape
2.7.0. A checkmark means the feature exists; conformance rates belong in
[test262-comparison.md](test262-comparison.md), whose results are a historical
snapshot.

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
| `try`/`catch`/`finally` | ✅ | ✅ | ✅ | ✅ |
| Optional catch binding | ✅ | ✅ | ✅ | ❌ |
| ES modules (`import`/`export`, namespace objects) | ✅ | ✅ | ✅ | ❌ |
| Dynamic `import()`, `import.meta` | ✅ | ✅ | ✅ | ❌ |
| Top-level `await` | ✅ | ✅ | ✅ | ❌ |
| Import attributes (`with { type: "json" }`) | ✅ | ✅ | ✅ | ❌ |
| `import defer` | ✅ | ❌ | ❌ | ❌ |
| Decorators | ❌ | ❌ | ❌ | ❌ |
| `using`/`await using`, explicit resource management | ✅ | ❌ | ✅ | ❌ |
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
| Proper tail calls | ✅ | ❌ | ❌ | ✅ |

## Collections and memory

| | boomkat | QuickJS | quickjs-ng | Duktape v2.7.0 |
|---|---|---|---|---|
| `Map`/`Set` | ✅ | ✅ | ✅ | ❌ |
| `Map`/`WeakMap.getOrInsert` / `getOrInsertComputed` | ✅ | ✅ | ✅ | ❌ |
| `Set` methods (`union`, `intersection`, `difference`, ...) | ✅ | ✅ | ✅ | ❌ |
| `WeakMap`/`WeakSet` | ✅ | ✅ | ✅ | ❌ |
| `WeakRef`, `FinalizationRegistry` | ✅ | ✅ | ✅ | ❌ |
| `ArrayBuffer` | ✅ | ✅ | ✅ | ⚠️ partial |
| Resizable `ArrayBuffer` | ✅ | ✅ | ✅ | ❌ |
| `TypedArray` family, `DataView` | ✅ | ✅ | ✅ | ⚠️ partial |
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
| `Array.fromAsync` | ✅ | ❌ | ✅ | ❌ |
| `Date`, full get/set/UTC surface | ✅ | ✅ | ✅ | ✅ |
| `JSON.rawJSON`/`isRawJSON`, `parse` source access (ES2026) | ✅ | ✅ | ✅ | ❌ |
| `Intl` (ECMA-402) | ⚠️ Optional bundled Intl services | ❌ | ❌ | ❌ |

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
| JSX (classic and automatic runtimes, pragmas, tsconfig/jsconfig) | ✅ | ❌ | ❌ | ❌ |
| Temporal | ✅ Optional; 16 calendars, IANA timezones | ❌ | ❌ | ❌ |
| Built-in debugger protocol | ❌ | ❌ | ❌ | ✅ |

## Execution modes and scope

The skip rules in [scripts/run_test262.py](../scripts/run_test262.py) define
which tests run. Feature support and test selection are separate: a host API
or unsupported calendar can exclude a test of an implemented feature.

### Sloppy mode

Scripts, ordinary function bodies and dynamic `Function()` bodies run sloppy;
modules and class code are strict, and a `"use strict"` prologue raises a unit
to strict ([plan 083](../plans/083-sloppy-mode.md)).

| | Status |
|---|---|
| `with`, including `@@unscopables` and closures over the object | ✅ |
| Implicit globals (`x = 1` undeclared) | ✅ |
| Legacy octal literals `010`, escapes `'\101'` | ✅ sloppy only |
| Duplicate parameter names | ✅ simple parameter lists in sloppy functions |
| Unqualified `delete x` | ✅ sloppy only |
| Mapped `arguments`, `arguments.callee` | ✅ sloppy functions |
| Sloppy `this` boxing (primitive → wrapper, null/undefined → global) | ✅ |
| Labelled function declarations, functions as `if` bodies | ✅ sloppy only |
| Function calls as assignment targets | ✅ runtime ReferenceError in sloppy code |
| `flags: [noStrict]` tests | ✅ run |

Legacy function `.caller` stack inspection remains excluded. Strict functions
retain the restricted `caller`/`arguments` accessors.

### Annex B

The `annexB` suite runs with explicit exclusions for String HTML wrappers
and `legacy-regexp` tests. The `[[IsHTMLDDA]]` slot (§B.3.6) is implemented
and exercised through the host's `$262.IsHTMLDDA`: the object is callable
(returning `null`), falsy, reports `typeof` `"undefined"`, and loosely
equals `null` and `undefined`.

Implemented behavior includes:

- `__proto__`, `__defineGetter__` / `__defineSetter__` /
  `__lookupGetter__` / `__lookupSetter__`, `String.prototype.substr`,
  `RegExp.prototype.compile`, `escape` / `unescape`, and HTML-like comments.
- Sloppy function declarations in blocks, labelled statements and `if` bodies;
  legacy eval/global var hoisting; initializers in `for (var x = ... in y)`;
  legacy octals, mapped arguments and runtime assignment-target errors.
- `Date.prototype.getYear`, `setYear` and `toGMTString`.

String HTML methods and RegExp legacy statics remain excluded. The engine
registers `.compile()`, but the runner excludes tests tagged `legacy-regexp`.

### Optional features, exclusions and partial implementations

| Surface | Scope |
|---|---|
| Temporal | Optional full build; 16 calendars and IANA timezone arithmetic |
| ECMA-402 | Optional small/full builds; bundled formatting locales, collation, segmentation and locale queries; dictionary segmentation excluded |
| Explicit resource management | Full: `using`/`await using` declarations, DisposableStack, AsyncDisposableStack, SuppressedError and the @@dispose/@@asyncDispose symbols |
| Cross-realm | Shared-heap realms with independent globals and intrinsics; `$262.createRealm` supported |
| Multi-agent | Single-agent Atomics; `$262.agent` tests excluded |
| ShadowRealm, decorators | Excluded |
| `export defer`, await dictionaries | Excluded by feature token |
| `structuredClone` | Host API excluded |

`staging/` runs through the same skip rules. Deferred and source-phase imports,
immutable ArrayBuffers, and text imports are implemented. No aggregate skip
percentage or per-feature count is asserted here; those depend on the corpus
revision and overlapping skip rules.

## Engine internals

| | boomkat | QuickJS | quickjs-ng | Duktape v2.7.0 |
|---|---|---|---|---|
| Language | C3 | C | C | C |
| Baseline | ES2025 + most ES2026 | ES2025 + most ES2026 | ES2025 + most ES2026 | ES5.1, partial ES6/7 |
| `BigInt` representation | arbitrary (32-bit limb vector) | arbitrary | arbitrary | |
| `Proxy` | full | full | full | subset |
| `SharedArrayBuffer` | single agent | shared | shared | |
| Sloppy mode | supported | supported | supported | supported |
| Annex B | sloppy-mode parts | supported | supported | supported |
| RegExp engine | libregexp | libregexp | libregexp | built-in |
| TypeScript stripping | erasable only | | | |
| GC | refcounted strings + cooperative generational tracing | refcount + cycles | refcount + cycles | refcount + MS |
| Inspection | disasm, VM trace | bytecode dump | bytecode dump | remote debugger |
| Embedding | C ABI | C API | C API | C API |

## Comparison sources

- [QuickJS upstream source](https://github.com/bellard/quickjs/blob/master/quickjs.c)
  and [changelog](https://bellard.org/quickjs/Changelog).
- [quickjs-ng 0.15.1 source](https://github.com/quickjs-ng/quickjs/blob/v0.15.1/quickjs.c)
  and [feature policy](https://quickjs-ng.github.io/quickjs/es_features/).
- [Duktape post-ES5 features](https://wiki.duktape.org/postes5features).
