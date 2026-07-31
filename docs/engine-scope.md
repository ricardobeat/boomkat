# Engine scope

What this engine implements, what it does not, and why. For the test262 numbers
themselves see `test262_results/latest.json`; for what the suite actually skips
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
- ESM: `import`, `export`, namespace objects, dynamic `import()`
- `BigInt`, as fixed-width int128 rather than arbitrary precision

## Deliberately out of scope

- **Sloppy mode and Annex B.** `with`, legacy octal, implicit globals,
  `arguments.callee`, `__defineGetter__`, HTML-like comments. Single-mode engine.
- **ECMA-402.** A separate specification. `Date.prototype.toLocaleString`
  ignores its options bag, which ES5 §15.9.5.5 permits.
- **Stage 3 proposals.** Temporal, decorators, ShadowRealm, explicit resource
  management, import attributes, iterator helpers. These still move.
- **Cross-realm behavior.** No second realm to be cross to.
- **Multi-agent coordination.** `Atomics` is well defined on one agent and ships;
  what needs threads is the coordination surface, so test262 files driving a
  second agent through the `$262.agent` hooks are skipped per file rather than
  the whole directory being excluded. `CanBlockIsFalse` tests are skipped for the
  opposite reason: this engine's single agent can suspend.
- **Proper tail calls.** Not implemented.
- **Arbitrary-precision BigInt.** int128 is the ceiling, so the two
  `bigint-and-number-extremes` tests are skip-listed.

## Two notes for anyone editing the skip list

A skip is a claim that behavior is out of scope. It is not a place to park a
bug: an in-scope test that fails belongs in `BACKLOG.md`, not in `SKIP_FILES`.

When you implement something, remove its skip in the same change. This file
replaced a tiered planning document whose "implement later" tiers had quietly
emptied out as features landed, leaving it describing a smaller engine than the
one that existed. Several of its rationales were stale by years, and it misled
more than one reader before it was retired.
