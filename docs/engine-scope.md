# Engine scope

What this engine implements, what it does not, and why. For the test262 numbers
themselves see `test262_results/latest.json`; for how those compare against
other engines see `test262-comparison.md`; for what the suite actually skips
see `SKIP_DIRS` / `SKIP_FILES` / `UNSUPPORTED_PATTERN` in
`scripts/run_test262.py`, which carry their reasoning inline and are the
authority.

## What it is

An ES5/ES6 engine meant to be embedded. A host links it and supplies
its own runtime surface: module loading, timers, I/O, and whatever globals that
host wants. The engine's own target is ECMA-262, not any particular runtime's
API.

Both execution modes. Strictness is per function: scripts, ordinary function
bodies and dynamic `Function()` bodies default to sloppy, modules and class
code are strict, and a `"use strict"` prologue raises a unit to strict
(`plans/083-sloppy-mode.md`).

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
- TypedArrays, `ArrayBuffer` (including resizable and immutable), `DataView`
- `Atomics` and `SharedArrayBuffer`, on a single agent
- ESM: `import`, `export`, namespace objects, dynamic `import()`, import
  attributes (`with { type: "json" | "text" | "bytes" }`)
- Iterator helpers (`Iterator.prototype.map`/`filter`/`take`/`drop`/...)
- Proper tail calls (ES2015 §14.8): a call in syntactic tail position reuses
  the caller's frame, so tail recursion runs in constant stack
- `BigInt`, arbitrary precision (a 32-bit limb vector; the only ceiling is
  `BIGINT_MAX_LIMBS`, ~2 billion bits, which turns a runaway expression into a
  RangeError instead of exhausting memory)

## Deliberately out of scope

- **The rest of Annex B**, beyond the parts sloppy mode needs. Annex B.3.1
  (duplicate parameters, mapped `arguments`, `delete x`), B.3.2 labelled
  function declarations, B.3.3 for function declarations in a block, B.3.4
  function declarations as `if` bodies, B.3.5 initializers in for-in heads,
  B.3.9 runtime errors for function call assignment targets, legacy octals and
  octal escapes are in. So are `Date.prototype.getYear`/`setYear` and
  `toGMTString` (B.2.4/B.2.6). Absent: the
  `String.prototype` HTML methods, the `RegExp` legacy statics, and the legacy
  eval-code and global-code var-hoisting rules.
- **ECMA-402 beyond English numeric/date services.** `Intl.NumberFormat`,
  `Intl.PluralRules` and `Intl.DateTimeFormat` support English (`en`/`en-US`)
  with Latin digits. NumberFormat handles decimal, percent, currency and units,
  parts and ranges, notation, sign display and decimal rounding. DateTimeFormat
  handles Gregorian/ISO dates, styles, hour cycles, day periods, fractional
  seconds, parts and ranges. It shares Temporal's IANA timezone data and adds
  English timezone names. Temporal plain values retain their civil fields;
  instants use the formatter's timezone. ZonedDateTime inputs throw TypeError.
  Number/BigInt and Date locale methods use these internal services.
  Other English tags fall back to `en`; regional conventions need more data.
  Other locales, numbering systems, non-Gregorian calendars, optional legacy
  constructor chaining, and other Intl constructors are excluded. The runner
  names these exclusions and checks test262's `locale` metadata, retaining
  numeric cases whose expected symbols match English.
  `-D NO_INTL` omits all three services; `-D NO_INTL_DATE` omits DateTimeFormat
  while retaining numeric Intl. Date methods use their fixed English fallback
  in either build; Number/BigInt methods return ordinary strings with NO_INTL.
- **Stage 3 proposals.** Decorators, ShadowRealm, explicit resource management.
  These still move.
- **Temporal.** `Temporal.Calendar` and `Temporal.PlainDate` with ISO 8601 and
  proleptic Gregorian support and native IANA timezone arithmetic. Non-ISO
  calendars remain outside the targeted subset.
- **Cross-realm behavior.** No second realm to be cross to.
- **Multi-agent coordination.** `Atomics` is well defined on one agent and ships;
  what needs threads is the coordination surface, so test262 files driving a
  second agent through the `$262.agent` hooks are skipped per file rather than
  the whole directory being excluded. `CanBlockIsFalse` tests are skipped for the
  opposite reason: this engine's single agent can suspend.

## Two notes for anyone editing the skip list

A skip is a claim that behavior is out of scope. It is not a place to park a
bug: an in-scope test that fails is a real bug, not a `SKIP_FILES` entry.

When you implement something, remove its skip in the same change.
