# test262 Irrelevance Report — Clean-Slate JS Engine

**Context**: Duktape C3 port, a strict-only ES5/ES6 engine. Scope is ECMA-262 core; a host embeds the engine and supplies its own runtime surface.
Full ECMAScript spec compliance is NOT the goal. The goal is: run real-world JS code.

**Total test262 tests**: 53,568

---

## Executive Summary

**~60% of test262 is irrelevant** for a clean-slate engine. You can safely skip ~32,000 tests
and focus on the ~21,000 that test behavior real code actually depends on.

The irrelevant tests fall into three buckets:
1. **Non-standard/legacy** (Annex B, Intl, engine quirks) — 4,470 tests
2. **Unstandardized proposals** (Temporal, decorators, etc.) — ~5,000 tests
3. **Platform-dependent or out-of-scope features** (SharedArrayBuffer, Atomics, cross-realm) — ~2,400 tests

---

## Tier 1: Skip Permanently

These test behavior that is **not part of standard JavaScript** or is **engine-specific quirks.
No real code depends on them. Skip with confidence.

### 1A. Non-Standard / Legacy

| Category | Tests | Reason |
|---|---|---|
| `test/annexB/` | 1,086 | Legacy browser quirks (`__proto__`, `escape()`, HTML comments in scripts, `String.prototype.substr`, `Function.prototype.caller`). NOT required by spec. V8/SpiderMonkey implement for web compat only. |
| `test/intl402/` | 3,337 | ECMA-402 Internationalization API. Separate spec. Not part of JS core. Duktape doesn't implement it. Add as optional module later. |
| `IsHTMLDDA` feature | 35 | Tests `document.all`-like behavior. HTML DOM quirk, not a JS language feature. |
| `caller` feature | 23 | `Function.prototype.caller` / `arguments.caller`. Forbidden in strict mode, deprecated everywhere. |
| `legacy-regexp` feature | 26 | `RegExp.$1`, `RegExp.lastMatch`, etc. Deprecated static properties. No modern code uses these. |
| `__proto__` feature | 20 | `__proto__` as a property (not just in literals). Annex B legacy. |
| `__getter__` / `__setter__` feature | 54 | `__defineGetter__` / `__defineSetter__`. Annex B legacy. |
| `cross-realm` feature | 203 | Tests behavior across different JS realms/contexts. Engine-specific internal semantics. |

**Subtotal: ~4,784 tests**

### 1B. Unstandardized Proposals (Stage 3 / Not Yet Published)

These are TC39 proposals that haven't shipped in the spec. Many will change before finalization.
Implementing them now means chasing a moving target.

| Category | Tests | Where |
|---|---|---|
| **Temporal** | 4,605 | `test/built-ins/Temporal/` + `test/staging/Temporal/` |
| **ShadowRealm** | 67 | `test/built-ins/ShadowRealm/` |
| **DisposableStack / AsyncDisposableStack / SuppressedError** | 219 | `test/built-ins/Disposable*` + `test/built-ins/SuppressedError/` |
| **AbstractModuleSource** | 8 | `test/built-ins/AbstractModuleSource/` |
| **Decorators** | ~24 | `test/staging/decorators/` + feature flag in `language/expressions/class/` |
| **Explicit Resource Management** | ~476 | `test/staging/explicit-resource-management/` + `await-using`/`using` stmts + feature flag |
| **Import Defer / Export Defer** | ~229 | Feature flag `import-defer` |
| **Source Phase Imports** | ~233 | `test/staging/source-phase-imports/` + feature flag |
| **Import Attributes** | ~100 | Feature flag `import-attributes` |
| **Import Text / Import Bytes** | ~11 | Feature flags |
| **Atomics.pause** | 6 | Feature flag |
| **Canonical TZ** | 19 | Feature flag |
| **Immutable ArrayBuffer** | 66 | Feature flag |
| **Non-extensible Applies to Private** | 1 | Feature flag |
| **Await Dictionary** | 37 | Feature flag |
| **Error Stack Accessor** | 35 | Feature flag |
| **Promise.try** | 12 | Feature flag |
| **Iterator Sequencing** | 32 | Feature flag |
| **Error.isError** | 12 | Feature flag |
| **Upsert** (`Map.emplace`) | 72 | Feature flag |
| **Array Grouping** | 28 | Feature flag |
| **RegExp.escape** | ~20 | Feature flag |
| **JSON Parse with Source** | 22 | Feature flag |
| **Math.sumPrecise** | 10 | Feature flag |
| **Regexp Modifiers** | 230 | Feature flag |
| **Regexp Duplicate Named Groups** | 15 | Feature flag |
| **Uint8Array Base64** | 70 | Feature flag |
| **Float16Array** | 49 | Feature flag |
| **Iterator Helpers** | 393 | Feature flag `iterator-helpers` |

**Subtotal: ~7,066 tests** (with overlap between feature flags)

### 1C. SpiderMonkey Staging Tests

| Category | Tests | Reason |
|---|---|---|
| `test/staging/sm/` | 1,412 | SpiderMonkey-specific test porting. Tests engine-specific behavior, not spec compliance. |

**Subtotal: 1,412 tests**

### Tier 1 Total: ~13,262 tests

---

## Tier 2: Skip For Now (Advanced Features)

These test **real, standardized ES features** that are either platform or
security dependent (SharedArrayBuffer, Atomics) or not required by the targeted
subset (tail-call optimization).

### Tier 2A: Complex / Platform-Dependent

| Category | Tests | Why Skip |
|---|---|---|
| **SharedArrayBuffer** | 104 (dir) + 463 (flag) | Requires multi-threading, Spectre mitigations, platform headers. Out of scope for a single-threaded engine. |
| **Atomics** | 390 | Same as SAB. Low-level concurrency primitives. |
| **resizable-arraybuffer** | 462 | ES2024, complex ArrayBuffer internals. |

Four entries that sat in this tier have since been implemented and now pass their
phases in full, so they are no longer skipped: **Proxy** (311, phase 23),
**BigInt** (77, fixed-width int128 rather than arbitrary precision),
**WeakRef** (29) and **FinalizationRegistry** (47, both phase 17-20).

**Subtotal: ~1,419 tests** (with overlap), down from ~1,983 as the four above moved into the implemented set.

### Tier 2B: Obscure / Edge-Case

| Category | Tests | Why Skip |
|---|---|---|
| `tail-call-optimization` | 35 | Only Safari implements PTC. V8 and SpiderMonkey don't. No real code depends on it. |
| `host-gc-required` | 15 | Tests requiring explicit GC invocation. Platform-specific. |
| `change-array-by-copy` | 132 | ES2023, but `toSorted`/`toReversed` etc. are low-priority. |
| `symbols-as-weakmap-keys` | 28 | ES2023 edge case. |

**Subtotal: ~210 tests**

### Tier 2 Total: ~2,193 tests

---

## Tier 3: Implement (Core Test Suite)

After removing Tiers 1 and 2, plus the `test/harness/` directory (116 tests testing the test harness itself), the remaining **~38,000 tests** are the ones that matter.

These test behavior that real-world JavaScript code depends on:

### Core Features (Must Implement)

| Feature | ES Version | Why It Matters |
|---|---|---|
| Strict mode | ES5 | All modern code uses strict mode |
| Object/Array/Function/String/Number/Date/RegExp/JSON/Math/Error | ES5 | Foundation of all JS |
| `let`/`const`, block scoping, TDZ | ES6 | Every modern file uses these |
| Arrow functions, template literals | ES6 | Ubiquitous in modern code |
| Classes (public methods, static, extends, super) | ES6 | Used everywhere |
| Destructuring, default/rest params, spread | ES6 | Used everywhere |
| `for-of`, iterators, Symbol.iterator | ES6 | Used everywhere |
| Generators | ES6 | Used in async/await transpilation, Redux-Saga |
| Map/Set/WeakMap/WeakSet | ES6 | Standard data structures |
| Symbol (toStringTag, toPrimitive, species, etc.) | ES6 | Used by libraries |
| Promise | ES6 | Foundation of async JS |
| async/await | ES2017 | Foundation of modern async code |
| Async generators/iteration | ES2018 | Used in streaming patterns |
| Optional chaining (`?.`) | ES2020 | Used everywhere |
| Nullish coalescing (`??`) | ES2020 | Used everywhere |
| Logical assignment (`??=`, `||=`, `&&=`) | ES2021 | Common pattern |
| `Array.prototype.includes` | ES2016 | Used everywhere |
| `Object.hasOwn`, `Object.fromEntries` | ES2019/2022 | Common utilities |
| `String.prototype.replaceAll` | ES2021 | Common pattern |
| `Promise.allSettled`, `Promise.any` | ES2020/2021 | Async patterns |
| `globalThis` | ES2020 | Cross-environment globals |
| Dynamic `import()` | ES2020 | Code splitting |
| `Array.prototype.flat`/`flatMap` | ES2019 | Common utility |
| RegExp named groups, lookbehind, dotall, unicode | ES2018 | Used in modern regex |
| `String.prototype.matchAll` | ES2020 | Common pattern |
| Numeric separators (`1_000_000`) | ES2021 | Readability feature |
| `AggregateError` | ES2021 | Promise.any error type |
| `Array.prototype.at` | ES2022 | Negative indexing |
| `Error.cause` | ES2022 | Error chaining |
| Class fields (public + private) | ES2022 | Used in modern classes |
| Class static blocks | ES2022 | Initialization patterns |
| `for-in` order | ES2020 | Specified iteration order |
| Top-level await | ES2022 | ESM feature |
| `set-methods` (union, intersection, etc.) | ES2025 | Set operations |
| `Array.fromAsync` | ES2024 | Async array construction |
| `Promise.withResolvers` | ES2024 | Common pattern |

### Tests by Directory (Core Only)

| Directory | Tests | Notes |
|---|---|---|
| `test/language/expressions/` | ~11,095 | Core expressions (operators, functions, classes) |
| `test/language/statements/` | ~9,337 | Core statements (for, while, try, class, etc.) |
| `test/built-ins/Array/` | ~3,081 | Array constructor + prototype methods |
| `test/built-ins/Object/` | ~3,411 | Object constructor + static methods |
| `test/built-ins/String/` | ~1,223 | String constructor + prototype methods |
| `test/built-ins/RegExp/` | ~1,879 | RegExp engine + prototype methods |
| `test/built-ins/TypedArray/` | ~1,446 | TypedArray base + subclasses |
| `test/built-ins/Function/` | ~509 | Function constructor + methods |
| `test/built-ins/Promise/` | ~677 | Promise API |
| `test/built-ins/Date/` | ~594 | Date constructor + methods |
| `test/built-ins/DataView/` | ~561 | DataView API |
| `test/built-ins/Iterator/` | ~514 | Iterator helpers (if implementing) |
| `test/built-ins/Map/` | ~204 | Map data structure |
| `test/built-ins/Set/` | ~383 | Set data structure |
| `test/built-ins/Math/` | ~327 | Math methods |
| `test/built-ins/Number/` | ~340 | Number constructor + methods |
| `test/built-ins/JSON/` | ~165 | JSON parse/stringify |
| `test/built-ins/Error/` | ~93 | Error constructors |
| `test/language/literals/` | ~534 | String/number/regex literals |
| `test/language/eval-code/` | ~347 | eval() semantics |
| `test/built-ins/Reflect/` | ~153 | Reflect API |
| `test/built-ins/Symbol/` | ~98 | Symbol primitive |
| `test/built-ins/Boolean/` | ~51 | Boolean constructor |
| `test/built-ins/generators/` | ~61 | GeneratorPrototype |
| Others | ~various | Smaller categories |

---

## Recommended Exclusion Filters

### Directory Exclusions (add to test runner)

```
test/annexB/              # 1,086 tests — legacy browser quirks
test/intl402/             # 3,337 tests — ECMA-402 (separate spec)
test/staging/             # 1,493 tests — unstandardized proposals + SM-specific
test/harness/             # 116 tests — test harness self-tests
test/built-ins/Temporal/  # 4,603 tests — Stage 3 proposal
test/built-ins/ShadowRealm/              # 67 tests
test/built-ins/DisposableStack/          # 93 tests
test/built-ins/AsyncDisposableStack/     # 104 tests
test/built-ins/SuppressedError/          # 22 tests
test/built-ins/AbstractModuleSource/     # 8 tests
test/built-ins/SharedArrayBuffer/        # 104 tests
test/built-ins/Atomics/                  # 390 tests
test/built-ins/Proxy/                    # 311 tests
test/built-ins/WeakRef/                  # 29 tests
test/built-ins/FinalizationRegistry/     # 47 tests
test/built-ins/BigInt/                   # 77 tests
```

### Feature Flag Exclusions (add to test runner metadata filter)

```
# Engine quirks / non-standard
IsHTMLDDA
host-gc-required
cross-realm
tail-call-optimization
legacy-regexp
caller
__proto__
__getter__
__setter__

# Stage 3 proposals (not yet in published spec)
Temporal
ShadowRealm
decorators
explicit-resource-management
source-phase-imports
import-defer
export-defer
import-attributes
import-text
import-bytes
Atomics.pause
canonical-tz
immutable-arraybuffer
nonextensible-applies-to-private
await-dictionary
error-stack-accessor
promise-try
iterator-sequencing
Error.isError
upsert
array-grouping
Math.sumPrecise
RegExp.escape
json-parse-with-source
regexp-modifiers
uint8array-base64
Float16Array
resizable-arraybuffer
joint-iteration
iterator-helpers

# ES2024+ features (implement later)
Array.fromAsync
set-methods
promise-with-resolvers
symbols-as-weakmap-keys
change-array-by-copy
Atomics.waitAsync
regexp-duplicate-named-groups
```

---

## Impact Summary

| Tier | Tests | % of Total | Action |
|---|---|---|---|
| **Tier 1: Skip permanently** | ~13,262 | 24.8% | Non-standard, proposals, engine quirks |
| **Tier 2: Skip for now** | ~2,193 | 4.1% | Advanced features, add later |
| **Harness self-tests** | 116 | 0.2% | Not engine tests |
| **Core tests (implement)** | ~38,000 | 70.9% | Real JS features |
| **Total** | 53,568 | 100% | |

### Current Progress vs. Relevant Tests

| Metric | Value |
|---|---|
| Total test262 | 53,568 |
| Relevant tests (Tier 3) | ~38,000 |
| Currently passing | 7,182 |
| Currently failing | 23,264 |
| Currently skipped (feature flags) | 11,541 |
| Pass rate of relevant tests | ~19% (7,182 / ~38,000) |
| Pass rate of attempted tests | 23.6% |

---

## What the targeted subset covers

The engine implements ES5/ES6 core in a single strict mode. That means:

1. **The syntax**: arrow functions, classes, destructuring, async/await, template literals, optional chaining.
2. **The built-in API surface**: Array, Object, String, Number, Map, Set, Promise, Date, RegExp, JSON, Math, Error, Symbol, generators, async iterators, TypedArrays, DataView, ArrayBuffer, Reflect, Proxy.
3. **The semantics behind them**: prototype chain, property access, function calls, closures, block scoping.
4. **Out of scope**: Annex B legacy, ECMA-402, cross-realm behavior, tail-call optimization, SharedArrayBuffer atomics, and the host-provided surface a runtime supplies (module loaders, timers, I/O). A host embeds this engine and provides those itself.

The ~38,000 in-scope tests cover the above. The rest are for behavior this engine does not claim.
