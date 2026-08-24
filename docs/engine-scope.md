# Engine scope

What this engine implements, what it does not, and why. For the test262 numbers
themselves see `test262_results/latest.json`; for how those compare against
other engines see `test262-comparison.md`; for what the suite actually skips
see `SKIP_DIRS` / `SKIP_FILES` / `UNSUPPORTED_PATTERN` in
`scripts/run_test262.py`, which carry their reasoning inline and are the
authority.

## What it is

A strict-only ES5/ES6 engine meant to be embedded. A host links it and supplies
its own runtime surface: module loading, timers, I/O, and whatever globals that
host wants. The engine's own target is ECMA-262, not any particular runtime's
API.

Single execution mode. There is no sloppy mode and no `is_strict` flag to branch
on, which removes a whole class of dual-semantics bugs and is why `noStrict`
tests fail to compile by design.

## In scope, and implemented

The ES5/ES6 core, plus the later additions that ordinary code now assumes:

- Objects, prototypes, property descriptors, accessors, `Reflect`, `Proxy`
- Classes, private fields and methods, static blocks
- Destructuring, spread, default and rest parameters, template literals
- `let`/`const`, block scoping, TDZ
- Iterators, generators, `for-of`, async functions, async generators, `for await`
- `Promise`, the microtask queue, `Map`/`Set`/`WeakMap`/`WeakSet`
- `WeakRef` and `FinalizationRegistry`
- `Symbol`, including the well-known symbols
- TypedArrays, `ArrayBuffer` (including resizable), `DataView`
- `Atomics` and `SharedArrayBuffer`, on a single agent
- ESM: `import`, `export`, namespace objects, dynamic `import()`, import
  attributes (`with { type: "json" }`)
- Iterator helpers (`Iterator.prototype.map`/`filter`/`take`/`drop`/...)
- `BigInt`, as fixed-width int128 rather than arbitrary precision

## Deliberately out of scope

- **Sloppy mode.** `with`, legacy octal, implicit globals, duplicate parameters,
  unqualified `delete`, `arguments.callee`. Single-mode engine. Two spec-required
  exceptions: an indirect `eval` / `Function()` body may bind the strict-mode
  reserved words (only identifier reservation relaxes), and a dynamic body's
  `this` substitutes to the global object for the UMD idiom.
- **Most of Annex B**, because most of it is sloppy-mode behavior. The
  mode-independent web-reality parts ship: `__proto__`, the
  `__defineGetter__`/`__lookupGetter__` family, `String.prototype.substr`,
  `RegExp.prototype.compile`, `escape`/`unescape`, HTML-like comments. Absent:
  `Date.prototype.getYear`/`setYear`, the `String.prototype` HTML methods, the
  `RegExp` legacy statics, block-scoped function semantics.
- **ECMA-402.** A separate specification. `Date.prototype.toLocaleString` is
  ES5-conformant: with a locales or options argument it resolves the bag per
  ECMA-402 §11.1.2 against the engine's single locale, with no full locale
  data.
- **Stage 3 proposals.** Decorators, ShadowRealm, explicit resource management.
  These still move.
- **Temporal.** `Temporal.Calendar` and `Temporal.PlainDate` with ISO 8601 and
  proleptic Gregorian support. Non-ISO calendars, `Intl.DateTimeFormat`
  formatters, and IANA timezone arithmetic are out of scope.
- **Cross-realm behavior.** No second realm to be cross to.
- **Multi-agent coordination.** `Atomics` is well defined on one agent and ships;
  what needs threads is the coordination surface, so test262 files driving a
  second agent through the `$262.agent` hooks are skipped per file rather than
  the whole directory being excluded. `CanBlockIsFalse` tests are skipped for the
  opposite reason: this engine's single agent can suspend.
- **Proper tail calls.** Not implemented.
- **Arbitrary-precision BigInt.** Limb-vector BigInt with `BIGINT_MAX_LIMBS =
  1 << 26` at `src/hbigint.c3:33`. The few `bigint-and-number-extremes` tests
  that need a larger literal stay skip-listed.

## Two notes for anyone editing the skip list

A skip is a claim that behavior is out of scope. It is not a place to park a
bug: an in-scope test that fails is a real bug, not a `SKIP_FILES` entry.

When you implement something, remove its skip in the same change. A skip entry
that outlives its feature makes the engine look smaller than it is.
