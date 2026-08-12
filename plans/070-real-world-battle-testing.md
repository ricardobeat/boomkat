# Plan 070: real-world battle testing

Findings from running third-party production JavaScript against the engine
rather than test262. The gate is green on 49,814 conformance tests, so every
bug below is in territory the suite does not reach.

Two shapes account for all of them. **Scale**: register pressure, scope depth,
clause counts and source length in real functions, where fixed compiler arrays
silently dropped entries or overran. **Nesting**: two ordinary constructs
combined in a way the suite only ever exercises separately — a call inside a
parenthesised assignment, an arrow inside a call inside a binary operand. Plus
the original lexer, string-building and error-reporting findings.

Corpus used: 21 unmodified library bundles fetched from jsDelivr (lodash,
underscore, moment, marked, handlebars, immutable, acorn, bluebird,
decimal.js, bignumber.js, mathjs, jszip, papaparse, crypto-js, protobufjs,
chance, he, nearley, d3-array, uuid, plus typescript 9 MB and babel 5 MB).
QuickJS (`out/qjs`) is the differential oracle throughout.

Status: B1-B11, B13-B17 and B19-B21 fixed. B12 withdrawn — it was a
sloppy-mode fixture, not an engine bug. **B18 is open** (an async callback
invoked by a builtin does not return a promise), along with the E-series.

Library loading: **5 of the 8 original failures now pass** — four of them
fixed by B16 alone. protobufjs and typescript still fail; babel is untested.

The last five bugs (B16, B17, B19, B20, B21) were all found by loading real
library bundles, and **every one of them is a silent wrong answer or memory
corruption that the full test262 corpus passes straight through**.

As of 2026-08-12 **every known test failure is closed**: the full test262
corpus runs **49814 pass / 0 fail** (verified against a freshly built
`out/test262_runner`), the local suite is 326/0, `test/engine/` is 106/0,
golden-bytecode is 30/30, and the module, uncaught, rejection and robustness
surfaces are all clean. The run immediately before the last two fixes was
49812 pass / 2 fail, and those 2 were B15.

**A green corpus is not a working engine.** B16-B21 were all present while
those 49,814 tests passed: a wrong-register call, a rejection of
`a && b.every((x, i) => ...)`, async callbacks that never return promises, two
unbounded writes into fixed compiler buffers, a switch that silently answered
`default` past 256 clauses, and a `Function` body truncated mid-token. Each
needs either two ordinary constructs nested a particular way, or simply more
of something than any fixture contains — and the suite has neither.

B14 and B15 were found by re-running the suites against a freshly built batch
binary rather than by new probing (see the measurement note below); B16 and
B17 were found by loading real library bundles.

## Contents

- [Scope note: strict-only is not the cause](#scope-note-strict-only-is-not-the-cause)
- [Headline: 8 of 21 libraries failed to load; 5 now pass](#headline-8-of-21-libraries-failed-to-load-5-now-pass)
- [B1: register allocation silently wraps at 256](#b1-register-allocation-silently-wraps-at-256)
- [B2: regexp literal after a control-clause `)`](#b2-regexp-literal-after-a-control-clause-)
- [B3: string `+=` is quadratic](#b3-string--is-quadratic)
- [B4: `error.stack` has no frames](#b4-errorstack-has-no-frames)
- [B5: cyclic array survives `JSON.stringify`](#b5-cyclic-array-survives-jsonstringify)
- [B6: string length overflow segfaults the host](#b6-string-length-overflow-segfaults-the-host)
- [B7: `String.prototype.repeat` truncates to 32 bits](#b7-stringprototyperepeat-truncates-to-32-bits)
- [B8: `Number.prototype.toString(radix)` saturates at 2^63](#b8-numberprototypetostringradix-saturates-at-263)
- [B9: unhandled promise rejections are silent](#b9-unhandled-promise-rejections-are-silent)
- [B10: uncaught errors degrade to `VM_ERROR` when a microtask is pending](#b10-uncaught-errors-degrade-to-vm_error-when-a-microtask-is-pending)
- [B11: deeply nested source segfaults the parser](#b11-deeply-nested-source-segfaults-the-parser)
- [B12: NOT A BUG — a sloppy-mode fixture, withdrawn](#b12-not-a-bug--a-sloppy-mode-fixture-withdrawn)
- [B13: `ADDI` fusion swaps operands, so `1 + str` concatenates backwards](#b13-addi-fusion-swaps-operands-so-1--str-concatenates-backwards)
- [B14: `Array.prototype.pop` reads a hole as `undefined`](#b14-arrayprototypepop-reads-a-hole-as-undefined)
- [B15: a `yield` operand ignores the enclosing `[In]` parameter](#b15-a-yield-operand-ignores-the-enclosing-in-parameter)
- [B16: a call's callee is materialized into the wrong register](#b16-a-calls-callee-is-materialized-into-the-wrong-register)
- [B17: an arrow call argument rejected as a bare arrow operand](#b17-an-arrow-call-argument-rejected-as-a-bare-arrow-operand)
- [B18: an async callback invoked by a builtin does not return a promise](#b18-an-async-callback-invoked-by-a-builtin-does-not-return-a-promise)
- [B19: unbounded writes into fixed compiler buffers](#b19-unbounded-writes-into-fixed-compiler-buffers)
- [B20: a switch past 256 clauses silently fell through to `default`](#b20-a-switch-past-256-clauses-silently-fell-through-to-default)
- [B21: an oversized `Function` constructor body was truncated](#b21-an-oversized-function-constructor-body-was-truncated)
- [Note on measurement: the batch binary is a separate build](#note-on-measurement-the-batch-binary-is-a-separate-build)
- [E1: no way to interrupt a runaway script](#e1-no-way-to-interrupt-a-runaway-script)
- [E2: embedding API gaps](#e2-embedding-api-gaps)
- [What held up](#what-held-up)
- [Verification method](#verification-method)

---

## Scope note: strict-only is not the cause

Every finding below was re-checked with an explicit `"use strict";`
prologue under both engines. None of them depends on sloppy-mode or
Annex B behaviour, and none is a missing host global: underscore, for
example, runs clean under `qjs` with a `"use strict"` prologue and still
fails here. These are engine bugs, not scope decisions.

---

## Headline: 8 of 21 libraries failed to load; 5 now pass

Each bundle was prefixed with a host shim
(`globalThis.window = globalThis.self = globalThis.global = globalThis`)
and followed by `console.log("LOADED")`, then run under both engines.
All 21 load under QuickJS; 8 failed here originally.

**Original state (8 failing).** Re-verified 2026-08-12 after B1-B17:

| library | was | now | root cause |
|---|---|---|---|
| underscore 1.13.6 | FAIL | **PASS** | B1 (>255 registers) |
| marked 4.3.0 | FAIL | **PASS** | B2, then B16 |
| bluebird 3.7.2 | FAIL | **PASS** | B16 |
| jszip 3.10.1 | FAIL | **PASS** | B16 |
| handlebars 4.7.8 | FAIL | **PASS** | B16 |
| protobufjs 7.4.0 | FAIL | FAIL | `request must be specified` — see below |
| typescript 5.4.5 | FAIL | FAIL | **Diagnosed.** Was a SIGBUS from B19; now reports `compile error at line 15576:4: too many nested scopes or declarations in one function`. It genuinely exceeds `MAX_SCOPE_DEPTH` (1024) in one function — a real limit to raise, not a bug. ASan is clean. |
| babel 7.24.7 | FAIL | ? | not re-tested |

**Five of the eight are fixed, four of them by B16 alone.** Their symptoms had
looked unrelated — handlebars reported `Object.defineProperty called on
non-object`, jszip and marked reported `undefined is not a function` — which
is why they were carried as four separate unexplained failures for weeks. One
missing guard term accounted for all of them.

protobufjs's remaining error is thrown by protobufjs itself, not by the
engine, and it loads far enough to run its own argument validation; it may not
be an engine bug at all. Worth confirming before spending on it.

**Fixing the diagnostic diagnosed it.** The plan above was to repair
`compile error at line 0:0` before guessing at the cause; enforcing the
scope-stack cap (`bcef20e9`) did exactly that, and typescript immediately named
its own problem: it exceeds `MAX_SCOPE_DEPTH` in one function, at line 15576.

**`scope_stack` is now heap-grown** (`a5c26d6f`), so that cap is gone entirely
— 8000 declarations in one function compile where 1024 was the hard limit.
`MAX_SCOPE_DEPTH` is deleted.

typescript gets further and still fails, now against **a different silent
limit**: `compile error at line 0:0` again, with ASan clean on the full 9 MB
source (so it is a cap, not memory corruption). Finding it is the same exercise
as before — the positionless message means some path returns `COMPILE_ERROR`
without calling `record_error`, and `grep -n "return COMPILE_ERROR~;"
src/compiler/*.c3 | grep -v "fail("` lists the candidates.

`patches` (2048) and `hoisted_fn_names` (512) are still fixed, but both are
enforced now and both have real headroom; converting them to the same
heap-grown pattern is mechanical when it is wanted.
The original analysis here reasoned from function-declaration counts per scope
and concluded the remaining six needed "six independent minimisations". That
was wrong in an instructive way: bluebird, jszip, handlebars and marked shared
a **single** root cause (B16), and their three different-looking error messages
were all the same wrong-register read surfacing at different points. Distinct
symptoms are not evidence of distinct bugs.

What actually found it was not counting anything about the source. It was
picking ONE failure (jszip), injecting a per-module load trace into its
browserify loader to get the failing module number, extracting that module's
body, and cutting it down to five lines — then narrowing the trigger by
probing adjacent shapes against node under `"use strict"`. That took one
sitting and cleared four libraries.

**The lesson for the rest of this plan:** minimise one failure completely
rather than triaging several partially. And note that the conformance gate was
green at 49,814 tests through all of B16, B17 and B18 — test262 could not have
found any of them, because each needs two ordinary constructs *nested in a
specific way* that the suite exercises only separately.

---

## B1: register allocation silently wraps at 256

**Status: FIXED (a9b75316)** — a two-word WIDE prefix extends operands to
16 bits (65535 registers); see the commit for the full design.

**Severity: high. Silent wrong answers, no diagnostic.**

`src/bytecode.c3` encodes instruction operands in 8 bits:

```c3
const uint MAX_A  = 0xFF;
const uint MAX_B  = 0xFF;
const uint MAX_C  = 0xFF;
```

but `src/compiler/context.c3` sets the allocator's ceiling to

```c3
const uint MAX_REGISTERS  = 65535;
```

`alloc_reg`/`alloc_regs` in `src/compiler/regalloc.c3` only raise
`reg_overflow` when `next_reg > MAX_REGISTERS`, so for any register index
between 256 and 65535 the guard never fires. The index is then masked to
`& 0xFF` when the instruction is packed, and the emitted code reads or
writes the wrong register. `finish()` has the right machinery already —

```c3
if (self.reg_overflow) { return self.fail("register limit exceeded")~; }
```

— it simply never sees the flag. The fix is to make the allocator's limit
match the operand width (or to widen the operands); the reporting path is
already correct.

### Repro

```js
"use strict";
(function(){
  function f0(){ return 0; }
  /* ... 130 sibling function declarations ... */
  function f129(){ return 129; }
  function t(p){ console.log("param=" + typeof p); }
  t(123);
})();
```

`duktape_c3` prints `param=undefined`; `qjs` prints `param=number`. The
argument is simply lost.

### Bytecode evidence

Failing (130 declarations) — the allocator saturates and every later
instruction reuses `r255`, so the argument is written to `r1` instead of
the slot the call reads:

```
[524] LDREG            r255 = r130, r0
[525] LDINT            r1, +123
[526] CALL_UNDEF_THIS  r255 = r255, r1
```

Passing (124 declarations) — registers still advance, argument lands
contiguously with the callee:

```
[500] LDREG            r250 = r249, r0
[501] LDINT            r252, +123
[502] CALL_UNDEF_THIS  r250 = r250, r1
```

### Trigger shape

What consumes registers permanently is **hoisted function declarations**
(one slot each, never freed — they sit below `reserved_regs`). Measured
window where a parameter is corrupted: **125 to 253** sibling declarations
inside one function scope. Above ~254 the shape changes again; the whole
region above 256 registers is unsound, not just that window.

These forms are **not** affected, because their registers are freed:

- `var g = function(){}` — safe at 260+
- object literals of methods — safe at 260+
- plain locals (`var v0..v299`) — safe until roughly 300

Top-level code is unaffected; the bug needs a function scope.

A second, independent symptom of the same root cause:

```js
"use strict";
(function(){
  var v0 = 0; /* ... 400 locals ... */
  console.log(v0 + v1 + /* ... */ + v399);
})();
```

`qjs` prints `79800`; `duktape_c3` throws
`Cannot convert object to primitive value` — a register holding an
unrelated value is read as an operand.

### Real-world impact

`underscore@1.13.6` fails to load outright:
`Cannot read properties of undefined (reading 'length')`, thrown from
`restArguments` where `func.length` is read and `func` arrived as
`undefined`. The UMD factory contains 109 top-level function declarations,
which together with its vars and temporaries crosses 256. `immutable` has
176 and is a candidate for the same failure.

---

## B2: regexp literal after a control-clause `)`

**Severity: medium. Valid programs rejected at parse time.**

`Lexer.prev_was_operand` (`src/lexer.c3`) treats `RPAREN` as
operand-ending, which is correct for `(a+b)/2` but wrong when the `)`
closes the control clause of an `if`/`while`/`for`. There the `/` starts a
regexp, and the engine lexes it as division:

```js
"use strict"; if(1)/a/.test("a");     // SyntaxError: unexpected token in expression
"use strict"; while(0)/a/.test("a");  // SyntaxError
"use strict"; for(;0;)/a/.test("a");  // SyntaxError
```

All three run clean under `qjs`. These forms already work, which localises
the bug precisely:

```js
do /a/.test("a"); while(0);      // ok
if(1){} /a/.test("a");           // ok
switch(1){case 1:/a/.test("a");} // ok
label: /a/.test("a");            // ok
var f=function(){}; /a/.test("a");  // ok
```

The lexer already carries the analogous escape hatch for the `}` case —
`force_regex_after_brace`, set at `src/lexer.c3:2323` and consumed in
`next_token` — so the fix follows the existing pattern: have the `if` /
`while` / `for` statement parsers set the same hint after consuming the
clause-closing `)`.

### Real-world impact

`marked@4.3.0` fails to parse:
`SyntaxError: unexpected token in expression (line 6, col 8707)`, at
`for(...;s<i;s++)/^ *-+: *$/.test(t.align[s])?...`. This pattern is common
in minified bundles, where braces around single-statement bodies are
dropped.

---

## B3: string `+=` is quadratic

**Severity: high. Ubiquitous pattern, unbounded slowdown.**

Building a string by repeated `+=` copies the accumulator on every
iteration. Time quadruples for each doubling of the loop count, while
QuickJS stays flat:

| iterations | duktape_c3 | qjs | growth vs previous |
|---|---|---|---|
| 10,000 | 23 ms | 4 ms | — |
| 20,000 | 79 ms | 4 ms | 3.4x |
| 40,000 | 295 ms | 5 ms | 3.7x |
| 80,000 | 1,165 ms | 7 ms | 3.9x |

At 80k iterations that is ~166x QuickJS and still widening. The
convergence on 4x per doubling is the signature of O(n²).

```js
"use strict";
var s = "";
for (var i = 0; i < 80000; i++) { s += "abc"; }
console.log(s.length);
```

The array-join equivalent is at parity (6 ms vs 5 ms at 40k), so the cost
is specific to incremental concatenation, not to string handling
generally:

```js
var a = []; for (var i=0;i<40000;i++){ a.push("abc"); } var s = a.join("");
```

`String.prototype.split` was originally listed here as showing the same
order of overhead (18x at 20k). That was a misattribution: the benchmark
built its subject string with `+=`, so it measured the quadratic
accumulation, not the split. Measured in isolation, split is linear —
4x the input costs 3.1x the time (2.2 ms at 20k, 6.9 ms at 80k), about
3x QuickJS.

Probable cause: the engine-wide invariant that every `HString` is interned
(string equality is pointer identity) means each intermediate result is
copied and hashed in full. QuickJS avoids this with ropes / in-place
extension of a uniquely-referenced string. Any fix has to preserve the
interning invariant — most likely by leaving concatenation temporaries
un-interned until they escape, which `src/hstring.c3:186` already
contemplates ("non-interned, such as a concatenation temporary").

### Remaining after the fix

The in-place accumulator covers the ADD opcode's string+string path only. The
`STRING + FASTINT` fast path just above it is untouched and is still
quadratic — `s += 1` over 80,000 iterations takes 407 ms against QuickJS's
4 ms (~100x). The same in-place treatment should apply; it was measured but
not fixed.

`src/vm/vm_execute_threaded.c3` also has a concat path that was not checked
for the same issue.

Absolute throughput on the fixed path is ~6x QuickJS (17 ms vs 3 ms at 80k),
but the growth is now linear: 4x the work costs 1.31x the time, against 4x
before.

---

## B4: `error.stack` has no frames

**Severity: medium. Debuggability and embedding gap.**

```js
"use strict";
function inner(){ throw new Error("boom"); }
function middle(){ inner(); }
function outer(){ middle(); }
try { outer(); } catch(e){ console.log(JSON.stringify(e.stack)); }
```

- `duktape_c3`: `"Error: boom"`
- `qjs`: `"    at inner (f.js:2:34)\n    at middle (f.js:3:25)\n    at outer (f.js:4:25)\n    at <eval> (f.js:5:12)\n"`

`e.stack` exists and is a string, but carries no frames, no file, and no
line numbers. An uncaught error prints only `Uncaught: x` with no
location either.

This also bounds what an embedder can report: the only error channel in
`include/jse.h` is `jse_last_error`, documented as returning
`"Name: message"`. A host embedding the engine cannot tell its own users
where a script failed. Stack traces are not listed as a non-goal in
`docs/engine-scope.md`, so this is a gap rather than a scope decision.

---

## B5: cyclic array survives `JSON.stringify`

**Severity: medium. Silent data loss.**

A self-referential array built by *indexed assignment* serialises to
`"[]"` instead of throwing. Building the identical cycle with `push`
throws correctly, which is the whole subtlety:

```js
"use strict";
var a = []; a[0] = a;
JSON.stringify(a);        // c3: returns "[]"      qjs: throws TypeError

var d = []; d.push(d);
JSON.stringify(d);        // c3: throws TypeError  qjs: throws TypeError

var o = {}; o.self = o;
JSON.stringify(o);        // c3: throws TypeError  qjs: throws TypeError
```

So the cycle check is present but is not reached for elements installed
by direct index assignment — likely a fast path for dense/indexed
elements that bypasses the stack check the `push`-created shape goes
through.

test262 **does** cover cyclic arrays
(`built-ins/JSON/stringify/value-array-circular.js`) and that test
**passes**, because it constructs both its cases with `push`:

```js
var direct = [];
direct.push(direct);
assert.throws(TypeError, function() { JSON.stringify(direct); });
```

A one-line variant using `direct[0] = direct` would have caught this.

Per spec (`SerializeJSONArray`), a value already on the stack must raise a
`TypeError`. Returning `"[]"` means a host silently persists or transmits
data that has lost its contents, which is worse than an error.

---

## B6: string length overflow segfaults the host

**Severity: critical. Host process crash, no catchable error.**

Four lines of ordinary strict-mode JavaScript kill the process with
**SIGSEGV (exit 139, signal 11)**, reproducible on every run:

```js
"use strict";
var s = "x";
for (var i = 0; i < 40; i++) { s += s; }
console.log("survived", s.length);
```

The doubling is allowed to pass 2^31 — the loop prints lengths up to
`2147483648` — and then faults. QuickJS stops cleanly at 2^29 with
`InternalError: string too long`.

For an embeddable engine this is the worst failure mode available: a host
that runs untrusted or merely careless script has its process taken down
with no exception to catch and no way to recover. It needs a maximum
string length enforced at every allocation and concatenation site, raising
a JS error instead of overflowing.

---

## B11: deeply nested source segfaults the parser

**Severity: critical. Host process crash on input, not on execution.**

The parser has no recursion depth limit, so nested literals overflow the
native stack:

```js
var x = [[[[ ... 1000 levels ... ]]]];   // SIGSEGV (exit 139)
var y = (((( ... 2000 levels ... ))));   // SIGSEGV (exit 139)
```

QuickJS reports `SyntaxError: stack overflow` for both. Measured
threshold: 500 levels is fine, 1000 crashes.

This is worse than B6 in one respect — it happens at *compile* time, so an
embedder is exposed merely by parsing untrusted source, before any script
runs. A depth counter in the recursive-descent parser, raising a
SyntaxError past a bound, is the standard fix.

**Correction to an earlier claim in this plan:** an initial probe reported
5,000-level nesting compiling fine and was listed under "what held up".
That probe used a form whose value was discarded, and did not crash; the
crash appears once the parsed value is bound and used. The robustness
suite (`test/robustness/run.sh`) caught it, and the earlier claim has been
removed.

---

## B7: `String.prototype.repeat` truncates to 32 bits

**Severity: high. Silent wrong results.**

Counts at or above 2^32 wrap instead of raising `RangeError`:

| call | duktape_c3 | qjs |
|---|---|---|
| `"x".repeat(4294967296)` | length **0** | RangeError |
| `"x".repeat(4294967297)` | length **1** | RangeError |
| `"x".repeat(2147483648)` | length 2147483648 | RangeError |
| `"x".repeat(1e10)` | length **1410065408** | RangeError |

`1e10 mod 2^32 = 1410065408`, so the count is being narrowed to a 32-bit
value somewhere before the limit check. The spec requires `RangeError`
when the count is negative or infinite, and an implementation limit error
when the result cannot be allocated — never a shorter string. Returning an
empty string for a request of four billion characters is silent
corruption, and shares a root cause with B6: string lengths are handled as
32-bit quantities without overflow checks.

---

## B8: `Number.prototype.toString(radix)` saturates at 2^63

**Severity: high. Silent wrong results for any large number.**

Every value at or above 2^63 converts to the *same* string, because the
integer part is cast through a signed 64-bit integer in
`src/builtins/number.c3:195`:

```c3
ulong int_val = (ulong)(long)int_part;
```

The cast saturates at `INT64_MAX`, so the digits produced are always those
of `9223372036854775807`:

| value | c3 `toString(16)` | node |
|---|---|---|
| 1e19 | `7fffffffffffffff` | `8ac7230489e80000` |
| 1e20 | `7fffffffffffffff` | `56bc75e2d63100000` |
| 1e25 | `7fffffffffffffff` | `845951614014880000000` |
| 1e30 | `7fffffffffffffff` | `c9f2c9cd04675000000000000` |
| `Number.MAX_VALUE` | `7fffffffffffffff` | `fffffffffffff800…` (269 digits) |

Decoding makes the mechanism unambiguous: `(1e20).toString(36)` returns
`1y2p0ij32e8e7`, which is exactly `9223372036854775807` in base 36, while
node returns `l3r41ifs0p800` ≈ 1e20.

Doubles range to ~1.8e308, so no 64-bit integer can hold the integer part.
The conversion has to be done in floating point by repeated division (the
approach V8 and QuickJS take), not via an integer cast.

Two related defects in the same function:

- The output buffer is a fixed `char[128]`, but
  `Number.MAX_VALUE.toString(2)` needs 1024 integer digits. Currently
  masked by the saturation above (it returns 63 digits), so fixing the
  cast without growing the buffer would turn a wrong answer into an
  overflow.
- The fractional part is capped at 20 digits, so `(5e-324).toString(2)`
  returns 22 characters where node returns 1076.

`toString(10)` is unaffected: it delegates to the dtoa path.

---

## B9: unhandled promise rejections are silent

**Severity: high. Async failures disappear.**

```js
"use strict";
Promise.reject(new Error("boom"));
```

- `duktape_c3` (CLI): no output, exit 0
- `qjs`: `Possibly unhandled promise rejection: Error: boom` plus a stack,
  exit 1

The same holds through the C ABI: `jse_eval` returns `JSE_OK` with an
empty `jse_last_error`, and calling `jse_drain_microtasks` afterwards
still reports nothing. Any failure inside an async function or promise
chain that nobody `catch`es is lost, and the host cannot discover it.
There is no rejection-tracker callback in `include/jse.h` to register
either, so this is not merely a CLI default — the information is not
reachable.

---

## B10: uncaught errors degrade to `VM_ERROR` when a microtask is pending

**Severity: high. Every error message in an async program is destroyed.**

```js
"use strict";
Promise.resolve().then(function(){});
undefinedGlobal;
```

- `duktape_c3`: `VM error: vm::VM_ERROR (at execute)`, exit 1
- `qjs`: `ReferenceError: 'undefinedGlobal' is not defined` plus location

Without the pending microtask the same script reports
`Uncaught: undefinedGlobal is not defined` correctly, so the error is
formed and then lost on the unwind path once a microtask queue is live.

It is not specific to `ReferenceError` — with a pending microtask, every
uncaught error becomes the same opaque string:

| thrown | reported |
|---|---|
| `undefinedGlobal` | `VM error: vm::VM_ERROR (at execute)` |
| `null.x` | `VM error: vm::VM_ERROR (at execute)` |
| `undefined.foo()` | `VM error: vm::VM_ERROR (at execute)` |
| `(1)()` | `VM error: vm::VM_ERROR (at execute)` |
| `throw new Error("plain")` | `VM error: vm::VM_ERROR (at execute)` |

An internal error enum is being surfaced where the JS error belongs. Since
essentially every real async program has a live microtask queue, this is
the error message users will actually see. Caught errors are unaffected
(`catch(e)` still receives a proper `ReferenceError`), so the loss is in
the top-level uncaught path.

---

## B12: NOT A BUG — a sloppy-mode fixture, withdrawn

**Resolved 2026-08-12 in `a2be8d67`. The engine was correct; the test was
wrong, and so was this entry.**

Originally filed as "`yield` as a destructuring default in `for await` loses
the binding", on the strength of this comparison:

```js
async function* g(){ for await ([value = yield "a"] of [[]]) { print(value); } }
```

- `qjs`: resumes the body with `value=11`
- `duktape_c3`: `ReferenceError: 'value' is not defined`

The fixture never declares `value`. This engine is strict-only, so assigning
to an undeclared identifier is a ReferenceError — and **node agrees under an
explicit `"use strict"`**, producing the identical error. `qjs` and bare node
accepted it only because they ran the file as sloppy mode, where the
assignment implicitly creates a global. The rejection was correct behaviour.

With the binding declared, the feature works and matches both oracles exactly
(yielded operand `"array"`, resume value `11`, body runs). Verified against
qjs and node.

The entry above asserted "this is a genuine engine bug and not fixture noise"
precisely because qjs produced no rejection — but qjs's silence *was* the
sloppy-mode tell, not evidence of a bug. This is the exact false-positive
class the [scope note](#scope-note-strict-only-is-not-the-cause) warns about,
and it got past that guard because the fixture's self-reported `4 pass, 0
fail` looked like corroboration. It was not: all four of those assertions were
the `instanceof Promise` checks *outside* the loop, and the two that mattered
sat in a body that never ran.

The rewritten fixture declares its bindings, asserts the yielded operands and
completion from the promise chain, and counts body executions so a body that
never runs can no longer report a pass. 8 assertions, identical in all three
engines.

**Lesson for the remaining entries:** a fixture that prints a pass while
stderr shows an error is not two independent signals agreeing. Check where
the assertions actually live.

---

## B13: `ADDI` fusion swaps operands, so `1 + str` concatenates backwards

**Severity: high. Silent wrong answers on ordinary code.**

```js
function f(a){ return 1 + a; }
f("A");   // duktape_c3: "A1"      node/qjs: "1A"
```

`FUSION_ADDI_SUBI` (`src/compiler/fusion.c3`, the `is_add` branch) folds a
constant operand into `ADDI` from *either* side:

```c3
if (rX == rK && rY != rK)      { rS = rY; }
else if (rY == rK && rX != rK) { rS = rX; }
```

`ADDI`'s A/B/C fields are fully consumed by dest/src/immediate, so nothing
records which side the immediate was on, and the VM evaluates every fused form
as `rS + imm`. Addition is commutative for numbers, so this is invisible for
arithmetic — but string concatenation is not, and the operands come out
reversed.

Only the constant-on-the-left form is affected; `a + 1` is already correct.

Found while investigating string-concatenation performance, and confirmed at
`9e3bae69` with all perf work stashed, so it is independent of that change.

**Fixed 2026-08-12 in `5342971b`.** The fold is now restricted to
`rS <op> imm` — the constraint `SUB` already carried, since `imm - rS` was
never a subtract-immediate either. `imm + rS` stays as `LDINT`+`ADD`, which
reads its operands in source order.

Restricting beat spending a bit on operand order: the golden-bytecode suite is
unchanged at 30/30, so no fused case in that corpus even used the removed
form, and `bench-fast` shows no movement. The commutative case that matters
for performance — `acc + 1` in a loop — was always the right-hand form.

Regression coverage in `test/test_addi_fusion_operand_order.js`, which
mutation-tests to 4 failures with the fix reverted. It pins both orders for
strings and numbers, the ±128 immediate boundaries, the out-of-range (unfused)
path, `ToPrimitive` operands, and the `SUB` asymmetry — so a later change
cannot "restore symmetry" by folding the other side back in.

---

## B14: `Array.prototype.pop` reads a hole as `undefined`

**Severity: medium. The last standing test262 failure, and a real one.**

**Fixed 2026-08-12 in `0c6dc565`.**

```js
Array.prototype[1] = 1;
var x = [0]; x.length = 2;
x.pop();   // duktape_c3: undefined      node/qjs: 1
```

`pop` reads index `length-1` with `[[Get]]`, which continues up the prototype
chain when the own element is absent. The dense fast path in
`builtin_array_proto_pop` treated "no own dense slot" as "the value is
undefined" and answered directly. The generic-object path — `Array.prototype
.pop` applied to a plain object — was always correct; only the array fast path
short-cut the lookup, which is why the same test's later assertions passed.

The fast path now requires the element to be *present* in the dense part
before it may claim the operation, so a hole falls through to the existing
prototype-aware `arr_get_elem_vm`. An own `undefined` is still present and
continues to shadow the inherited value.

Probed the sibling methods for the same hole-vs-undefined confusion —
`shift`, `indexOf`, `includes`, `join`, `slice`, `concat`, `reverse`,
`lastIndexOf` all already match QuickJS on an inherited indexed property.
`pop` was alone.

This one had been carried for weeks as "pre-existing, unrelated" whenever a
phase-6 number was quoted. It was a one-condition fix. **A known failure that
nobody has read is not a known failure.**

Coverage: `test/test_array_pop_hole_prototype.js`, green in all three engines.

---

## B15: a `yield` operand ignores the enclosing `[In]` parameter

**Severity: low (accepts invalid syntax). Fixed 2026-08-12 in `77057548`.**

```js
function* g(){ for (yield '' in {}; ; ) ; }   // must be a SyntaxError
```

`yield [no LineTerminator here] AssignmentExpression[?In, +Yield]` — the `?In`
propagates, so in a `[~In]` position (a C-style for head) the operand may not
consume an `in` either. Both the plain and `yield*` forms parsed; qjs and node
both reject them.

`binary_expr` consumes `forbid_in` on entry so it cannot leak into a nested
`[+In]` construct like `f(a in b)`. That is correct for those, but a
YieldExpression is not one of them — it propagates `?In` rather than forcing
`+In`, and it is handled in `primary_expr`, far below where the flag was
cleared. The fix parks the consumed value in `yield_forbid_in` alongside
`yield_ok_here`, which already marks the only position a `yield` can appear.

**These were the last two failures in the entire test262 corpus** (phase 21,
`language/expressions/yield/{in,star-in}-iteration-stmt.js`). They are
negative *parse* tests, so no runtime suite could have caught them — and they
only surfaced because the full-corpus run below was done against a freshly
built batch binary.

---

## B16: a call's callee is materialized into the wrong register

**Severity: high. Silent wrong-register read. Fixed 2026-08-12 in `44acadc8`.**

```js
(function(e){
  function n(){ var e = 1; return e; }
  (n.x = e("k")).y = 1;
  print("ok n.x=" + JSON.stringify(n.x));
})(function(k){ return {v:k}; });
```

- node (with `"use strict"`): `ok n.x={"v":"k","y":1}`
- `duktape_c3`: `Uncaught: undefined is not a function`

The disassembly of the inner function shows the fault directly:

```
[  5] LDCONST         r3, 2
[  6] LDREG           r6 = r2, r0      <-- callee materialized into r6
[  7] LDCONST         r7, 3
[  8] CALL            r5 = r5, r1      <-- but CALL reads the callee from r5
[  9] PUTPROP         r2 = r3, r5
```

The callee lands in `r6` while `CALL` reads `r5`, so it calls a stale
register. (`[6]` also copies from `r2`, the closure `n`, which does not look
like `e` either — possibly a second fault, possibly register reuse.)

**Two ingredients are required**, each harmless alone. Measured by probing
adjacent shapes against node (`"use strict"`), which is the only usable oracle
here:

1. **Shadowing.** Some nested function rebinds the callee's name. Any form
   does it: `var e` in an inner declaration, `var e` in a function
   *expression*, or an inner *parameter* named `e`. Rename it and the bug goes
   away. The outer binding may be either a parameter or a `var`.
2. **A parenthesized property-assignment around the call.**
   `(o.b = e("q"))` fails; `(z = e("q"))` with a plain variable target does
   NOT, and neither does `o.b = e("q")` without the parentheses. A further
   `.y = 1` on the result is *not* required — `var w = (o.b = e("q"))` fails
   on its own, so the original "base of a further assignment" reading was too
   narrow.

Unaffected: method calls (`o.make("m")`) and `new C("n")` in the same
position both work, so this is specific to a **bare-identifier callee**.

This is what breaks **jszip 3.10.1**, whose browserify module 10 is exactly
this shape:

```js
(function(e,t,r){ function n(){ ...this.clone=function(){var e=new n;...} }
  (n.prototype=e("./object")).loadAsync=e("./load"), ... })(...)
```

Found by bisecting the minified bundle down to the 5 lines above, via a
per-module load trace injected into the browserify loader.

**Root cause.** The callee's `GETVAR` is STRIPPED from the code stream up
front, on the promise that `CALL_VAR` at the end of the call will load the
callee itself. But `CALL_VAR` is only emitted when `undef_this` holds, and
that is false whenever a receiver register is pending. A stale
`call_prop_obj_reg` left by the enclosing property assignment made the strip
fire and then emit a plain `CALL`, reading a register nothing had written.

The sibling `getglobal_callee` guard already carried the
`call_prop_obj_reg == REG_NONE` precondition, with a comment naming this exact
hazard — "the same non-method precondition that makes the CALL_GLOBAL emission
below reachable". `getvar_callee` was simply missing it. The fix adds the same
term. **A guard that exists on one of two parallel paths is a bug report about
the other one.**

Regression coverage in `test/test_call_callee_register.js`, pinning all 15
probed shapes — the failing ones and the passing ones, so a later change
cannot narrow the guard to the wrong condition.

The whole test262 corpus (49814 tests) passes with this bug present, so **the
suite cannot be the oracle here**; node under `"use strict"` is. Likewise
`./out/qjs` on a plain script is sloppy mode and will mislead on the
shadowing cases.

---

## B17: an arrow call argument rejected as a bare arrow operand

**Severity: high (rejects valid, extremely common code). Fixed 2026-08-12 in
`77f06187`.**

```js
true && a.every((x, i) => x > 0)   // SyntaxError: arrow function in
                                    // expression position not allowed
```

ArrowFunction is AssignmentExpression-level and may not appear directly as a
binary operand (`1 + () => 2`, ES §13.16/§13.15). `check_no_arrow_rhs`
enforces that with a `last_was_arrow_expr` flag — but an arrow inside a
**call's parentheses** is not that. The flag survived the argument parse, and
nothing cleared it before the enclosing `binary_expr`'s post-RHS check.

Any binary operator, any arrow arity: `&&`, `||`, `??`, `+`, `===` all
rejected. This is the line that broke **typescript 5.4.5**:

```js
a.length === b.length && a.every((x, i) => equalityComparer(x, b[i]))
```

Fixed by clearing the flag when a CallExpression finishes parsing. The
negative cases are now pinned in `compile_error_messages` so a later change
cannot "fix" an over-rejection by dropping the guard entirely.

---

## B18: an async callback invoked by a builtin does not return a promise

**Severity: medium. OPEN — partial fix attempted and reverted, see below.**

```js
[1, 2].map(async (x) => x)[0]        // ours: 1        node: Promise
[1, 2].filter(async () => false)     // ours: []       node: [1, 2]
```

A plain function *returning* a promise works. An **async function** called by
a builtin does not: it runs to completion and hands back the raw return value.
`filter` is the sharpest case — a promise is always truthy, so an async
predicate must keep every element, and ours drops them all.

Root cause: `vm_call_fn_impl` (`src/vm/vm_execute.c3`, "Case 3: compiled
function on HObject") is the path builtins use to invoke a JS callback. It
handles *resuming* an async function (`gs_r.async_promise`) but has no setup
for an **initial** async call — no `promise_create`, no `ACT_FLAG_ASYNC`. The
CALL opcode's path in `vm_calls.c3` does both.

**A one-block fix is NOT sufficient.** Adding the `promise_create` +
`ACT_FLAG_ASYNC` setup there does make `map`/`filter`/`some` return real
promises that resolve correctly — but a callback that actually *suspends*
(`async x => { await null; return x; }`) then resolves to `null`, because this
path re-enters the VM synchronously and has no generator state to suspend
into. That is strictly worse than the current behaviour, so the attempt was
reverted rather than shipped.

Doing this properly means giving the call_fn path the same
suspend/resume machinery the CALL opcode has. Affects every builtin that
invokes a callback: `map`, `filter`, `some`, `every`, `forEach`, `sort`
comparators, `Promise` executors, and accessors.

---

## B19: unbounded writes into fixed compiler buffers

**Severity: critical (memory corruption). Fixed 2026-08-12 in `f6abf005`.**

Two stack arrays in the compiler were written with no bound at all:

- `switch_statement`'s `body_addrs` / `ft_jump_addrs` (`uint[64]`). A switch
  with more than 64 clauses wrote past the end of the compiler's own frame,
  **silently** — a 100-case switch still produced correct output while writing
  36 entries past the end. Raised to 1024 with a check.
- `scan_template_content`'s `buf` / `raw_buf` (`char[65536]`), in both the
  cooked loop and the invalid-escape rescan. `scan_string` already carried
  exactly this check (`buf_len >= STRING_BUF_SIZE - 6`); the template scanner
  did not — the same guard-on-one-of-two-parallel-paths shape as B16.

Found by running typescript 5.4.5 (9 MB) under AddressSanitizer. In the release
build the template overflow landed as a **jump into string data**
(PC = `0x6e694c656c676e69`, which is ASCII text): memory corruption with
nothing pointing at the lexer. ASan named the file and line immediately.

**Reach for ASan early on a crash whose PC is nonsense.** The release-build
symptom was unusable and cost far more time than the ASan run, which took one
command.

---

## B20: a switch past 256 clauses silently fell through to `default`

**Severity: high. Silent wrong answers. Fixed 2026-08-12 in `453a97d1`.**

```js
function f(x){ switch(x){ /* 300 clauses */ } }
f(257)   // ours: the default arm's value      node: 514
```

`add_patch` returned **silently** when the break/continue patch pool was full:
the jump was never recorded, `patch_chain` never patched it, and it executed as
`JUMP 0`. Arms 0..255 answered correctly; everything past the 256th returned
`default`, with no diagnostic.

The pool is per-**function** and never reset mid-function, so the bound was the
total number of break/continue statements in one function body, not the depth
of any one loop — 400 loops each containing a `break` hit it too.

Fixed by raising `MAX_PATCHES` to 2048 (16 KB; `CompilerContext` is a stack
local, so 8192 exceeded c3c's 64 KB stack-object limit and failed to build) and
by turning overflow into a compile error via `patch_overflow`, alongside the
existing `reg_overflow` check.

Also fixed alongside it: `switch_statement` freed its case registers with two
`free_reg` calls, but `free_reg` is strictly LIFO, so freeing `case_reg` while
`cmp_reg` sat above it was a no-op and **every clause leaked a register** — the
comparison register climbed r3, r4, ... r260 over 258 clauses. Now reclaimed
with `free_regs_to`, which also tightens ordinary switches (the `switch_seq`
golden reuses r1 instead of climbing to r2, with both `JMP_SEQ` fusions still
firing).

---

## B21: an oversized `Function` constructor body was truncated

**Severity: high. Silent wrong answers. Fixed 2026-08-12 in `34626235`.**

The `Function` and `GeneratorFunction` constructors build their compilation
source in a fixed `char[16384]` stack buffer. The copy was bounds-checked, so
nothing overflowed — but a body that did not fit was silently cut **mid-token**
and then compiled:

- a truncated `return` failed at CALL time with `retu is not defined`;
- a body cut at a statement boundary compiled cleanly and returned `undefined`;
- a body cut inside a block gave `SyntaxError in Function constructor` with no
  hint that length was the issue.

Now rejected with an error that names the limit. Found while generating a
400-iteration loop body through `new Function` for the B20 test.

**Still open, found alongside it:** `Function.prototype.toString` on a
constructor-built function returns `"[native code]"` rather than the source
text ES2019 §19.2.1.1.1 requires. Verified pre-existing.

---

## Note on measurement: the batch binary is a separate build

`out/test262_runner` is **not** rebuilt by `just build`, and
`python3 scripts/run_test262.py` rebuilds nothing at all. Only `just
build-batch` (or the `just test262*` recipes) refreshes it.

This bit twice on 2026-08-12. The B14 pop fix was correct and a hand-run of
the test262 file passed, yet the suite kept reporting the same failure against
a nine-day-old binary. The tell is the contradiction itself: a hand-run of the
exact file passing while the suite disagrees means the two are running
different code. Separately, and more quietly, the "no conformance regression"
number quoted during the WIDE-prefix review had been measured the same way —
the right conclusion, but not actually evidence.

Any test262 number is only as fresh as `out/test262_runner`.

---

## E1: no way to interrupt a runaway script

**Severity: critical for embedders. Host hangs permanently.**

```c
const char* s = "while(true){}";
jse_eval(rt, s, strlen(s), &v);   /* never returns */
```

The host process hangs and must be killed from outside (verified: the
probe exited only on an external `timeout`, rc=124). `include/jse.h`
exposes no interrupt handler, deadline, instruction budget, or memory
limit — grepping the header for `interrupt`, `timeout`, `deadline`,
`memory_limit` returns nothing.

QuickJS solves this with `JS_SetInterruptHandler` (a host callback polled
by the interpreter, returning non-zero to abort with a JS exception), and
Duktape with an executor timeout. Without an equivalent, this engine
cannot safely run untrusted or even merely buggy script — which is the
main reason to embed a JS engine at all. This is the single most
important gap found in the API.

### Test coverage

**None, deliberately.** Every other finding in this plan has a regression
test (see the section below), but E1 is a *missing feature* rather than a
broken one: there is no API to call, so a test would not compile. Writing
one that merely asserts `while(true){}` hangs would encode the defect as
expected behaviour and would itself hang the suite.

What to add once the API exists — the shape the fix should be designed
against:

- A C host in `test/capi/` that installs an interrupt handler, evaluates
  `while(true){}`, and asserts `jse_eval` returns a throw status within a
  bounded number of callbacks. It must exit on its own, with no external
  `timeout` — an in-suite watchdog is the whole point.
- The runtime must remain usable afterwards: a subsequent `jse_eval` of
  `1+1` must return `JSE_OK`. An interrupt that poisons the runtime only
  converts a hang into a leak.
- The interrupt must surface as a catchable JS error, and a `try`/`catch`
  in script must not be able to swallow it and resume looping.
- Uninterrupted scripts must be unaffected, so the polling cannot be
  implemented by aborting anything long-running.

The same host program is the natural place to cover the other E2 gaps
(property access, source location) as they land.

---

## E2: embedding API gaps

**Severity: medium. Capability and diagnostics holes.**

Working from `include/jse.h` and host programs compiled against
`out/jse_static.a`:

- **No source location, anywhere.** `jse_eval` takes
  `(rt, src, len, out_val)` with no script-name parameter, and errors
  carry no line or column: a syntax error reports
  `unexpected token in expression` where the CLI prints
  `... (line 1, col 20)`. The host gets strictly *less* than the CLI, and
  cannot tell a user which file or line failed. Together with B4 (frameless
  `error.stack`) there is no diagnostic path at all.
- **No property access.** There is no `jse_get_prop` / `jse_set_prop` /
  key enumeration. A host can call functions and read primitives, but
  cannot inspect or build an object graph, which most real embeddings need
  (config objects, structured returns).
- **No object/array construction** from the host: the return helpers cover
  number, bool, null and string only.
- **No bytecode serialisation**, so every start pays full compile cost.

What works well and should be kept: errors never unwind through C;
`jse_last_error` is documented as never re-entering the VM (so a throwing
`toString` cannot recurse on the unwind path); the readers clear the error
on entry so stale messages do not leak between calls; and the runtime
stays usable after an ignored error (verified: `rc=0` on the next
`jse_eval`). The handle registry being a GC root is the right call, and I
could not construct a use-after-free through it.

---

## On hardcoded limits vs. growable structures

Several findings look like "a buffer was too small", but they are not all
the same problem, and only one is fixed by reaching for a growable
structure.

**Use `StrBuf` (already in `src/builtins/core.c3:73`).** It is heap-backed
with a `STRBUF_INLINE_CAP` inline buffer, so short results never allocate,
and it grows otherwise — `Array.prototype.toLocaleString` already uses it
precisely so "output length is bounded only by memory"
(`src/builtins/array.c3:1345`). The `char[128] buf` in
`number_to_radix_str`'s caller should become a `StrBuf` with
`defer out.free()`; then `Number.MAX_VALUE.toString(2)` and its 1,024
integer digits need no constant to be chosen. The same applies to the
fixed 20-digit fraction cap: the right bound is "until the value is
exhausted", not a magic number. Other fixed buffers worth the same
treatment: `char[512] stack_buf` in `error.c3:108,337` (relevant to B4,
where real stack traces will not fit in 512 bytes) and `char[256] buf` in
`core.c3:2810`.

**A growable structure does not fix these:**

- **B8's actual defect** is the `(ulong)(long)` cast saturating at
  `INT64_MAX`. No container helps; the integer part must be produced by
  repeated division in `double`, because doubles reach ~1.8e308 and no
  64-bit integer can hold that. `StrBuf` fixes where the digits are
  written, not how they are computed. Both changes are needed, and the
  buffer must be fixed *with* the cast — correcting the cast alone turns a
  wrong answer into a 1,024-digit overflow of a 128-byte buffer.
- **B1 is the inverse problem**: the limit is hardcoded too *high*
  (`MAX_REGISTERS = 65535` against an 8-bit operand field). The ceiling is
  the instruction encoding, so no data structure can raise it. Either make
  the allocator's limit honest at 255 so the existing `reg_overflow` →
  `COMPILE_ERROR` path fires, or widen the operands. (Nearby
  `char[][256] hoisted_fn_names` and `PatchEntry[256] patches` *are*
  genuine `List` candidates, and silently cap large functions today.)

  **That parenthetical was right, and it took a real bundle to prove it.**
  `PatchEntry[256] patches` became **B20**: `add_patch` returned silently at
  the cap, so a switch past 256 clauses answered `default` for every arm after
  the 256th. Two more of the same shape turned up in the same sitting — B19
  (`uint[64]` switch tables and `char[65536]` template buffers, written with
  no bound at all) and B21 (a `Function` body truncated mid-token).

  The through-line is not the specific numbers. It is that **every one of these
  failed silently**: no error, no diagnostic, just a wrong answer or a
  corrupted frame. Where a growable structure is not warranted, the limit still
  has to be *enforced* — a cap that is merely "not exceeded in practice" is a
  latent silent-wrong-answer bug.

  `MAX_SCOPE_DEPTH` was the last of these and is now fixed (`bcef20e9`): a
  dropped scope entry made a declaration invisible to shadowing, TDZ and
  duplicate-declaration checks. It is a compile error now — **and the error
  alone was not enough.** At the old bound of 256 it *rejected* bluebird and
  jszip, which had been loading, because real minified bundles pass 256
  declarations in one function routinely. Turning a silent miscompile into a
  hard rejection of working code is a regression, not a fix; the cap had to be
  raised (to 1024) at the same time. **Enforce the limit AND size it for real
  input — the two changes belong in the same commit.**

  `char[][256] hoisted_fn_names` is still in the unenforced state.
- **B6/B7 need a limit that is deliberately hardcoded.** An engine must
  refuse an over-long string with a JS error rather than attempt the
  allocation; QuickJS caps at 2^30 and throws `InternalError: string too
  long`. Unbounded growth is what produces the segfault, so the fix is an
  explicit maximum enforced at every allocation and concatenation site,
  with 64-bit length arithmetic so the check cannot itself wrap.

---

## What held up

Worth recording, since these were attacked and did not break:

- Deep recursion raises a clean `RangeError: Maximum call stack size
  exceeded` rather than overflowing the native stack.
- Recursive proxy `get` traps terminate with `RangeError`; revoked proxies
  raise `TypeError`.
- Mutating an array inside its own `sort` comparator, and deleting a
  property from a getter during `for-in`, both behave sanely.
- `var g = function(){}`, object-literal methods, and plain locals do not
  leak registers (see B1), so the 256-register wrap needs hoisted
  declarations specifically.

---

## test262 skip-list audit

Question asked: could the official suite have caught these already, and is
the skip list hiding in-scope tests? **Answer: no on both counts.** The
skip list is tight and the misses are genuine coverage gaps upstream.

**The skip list is not the problem.** `SKIP_DIRS` has two entries
(`annexB`, `intl402`), `SKIP_GLOBS` is empty, and `SKIP_FILES` has two
individual files. Everything else is `UNSUPPORTED_PATTERN`, which matches
on `features:` keywords only — Stage 3 proposals (Temporal, ShadowRealm,
decorators…), Annex B (`__proto__`, `__getter__`), and engine pragmatics
(`cross-realm`, `caller`, `tail-call-optimization`). No rule is
over-broad. In the three directories covering these bugs, the number of
tests skipped by any rule is:

| directory | tests | skipped |
|---|---|---|
| `built-ins/String/prototype/repeat/` | 16 | **0** |
| `built-ins/Number/prototype/toString/` | 90 | **0** |
| `built-ins/JSON/stringify/` | 66 | 2 (unrelated feature flags) |

Per-bug classification:

- **B7 (`repeat` 32-bit truncation) — NOT-COVERED.** All 16 tests exist
  and run. They cover `Infinity`, negative counts, zero, and coercion —
  but no test anywhere in `built-ins/String/` uses a count near 2^32, and
  none asserts an implementation-limit error. A new test would need
  `assert.throws(RangeError, () => "x".repeat(4294967296))`.
- **B8 (`toString(radix)` saturation) — NOT-COVERED.** All 90 tests run
  and pass. `numeric-literal-tostring-radix-16.js` contains exactly four
  assertions — `0`, `1`, `NaN`, `Infinity` — so **the largest number it
  tests is `1`**. No test in the directory uses `1e20` or `MAX_VALUE`.
  Nothing there could detect a cliff at 2^63.
- **B5 (cyclic array) — COVERED-AND-PASSING, and the passing is
  legitimate.** `value-array-circular.js` tests precisely this, and the
  engine passes it, because the test builds its cycles with
  `direct.push(direct)` — the path that works. The broken path is
  `a[0] = a`. A one-line variant would have caught it. This is the
  closest call of the audit: test262 had the concept but not the shape.
- **B2 (regexp after a control-clause `)`) — NOT-COVERED.** No test under
  `language/statements/{if,while,for}/` puts a regexp literal in an
  unbraced body; searching for the pattern returns nothing.
- **B1, B3, B6, B9, B10, E1, E2 — outside test262's remit by
  construction.** Register pressure at scale, quadratic performance,
  process crashes, host-embedding APIs and CLI error reporting are not
  things a conformance suite asserts.

**Conclusion.** The green gate is not overstating conformance — it is
accurately reporting that the engine passes what test262 asserts. The
gap is that test262 asserts *behaviour on small inputs*, and every bug
here needed either scale (B1, B3, B6, B7, B8), an unusual construction
shape (B5, B2), or a non-language surface (B9, B10, E1, E2). The
actionable follow-up is not to change the skip list but to add the
targeted regression tests named above, and to keep the real-library
sweep as a separate gate.

---

## Open questions / next steps

Not yet answered — the session ran out of budget before these finished.

1. **Root-cause the other six library failures.** bluebird, jszip,
   handlebars and protobufjs fail with `undefined`-shaped errors that B1
   does not explain (see the headline table); typescript and babel exit
   non-zero with no message. Each is a free real-world reproduction of a
   bug not yet characterised. For handlebars specifically the trail is
   already warm: it is a webpack bundle, and the throw happens inside
   `$export` (bundle module 20) after it is entered with `name='Object'`,
   called from module 64 via module 81's `Object.seal` core-js polyfill.
   Module 64 returning a function, `exec(fn)`, `Object.seal/freeze/keys`
   on the primitive `1`, and reserved-word property access
   (`o["default"]`) have all been ruled out. The next step is to
   instrument inside `$export`'s `for(key in source)` loop — candidates
   are `key in target`, `target[key] == out`, the `ctx(out, global)` call,
   and the `IS_PROTO` branch.

2. **Implement an interrupt/limit API (E1).** This is the one finding with
   no regression test, because there is no API to test — it needs building
   before it can be covered. Design notes and the test to write alongside
   it are in the E1 section above. Minimum viable shape, following
   QuickJS's `JS_SetInterruptHandler`:

   ```c
   typedef int (*jse_interrupt_fn)(jse_runtime rt, void *udata);
   JSE_API void jse_set_interrupt_handler(jse_runtime rt,
                                          jse_interrupt_fn fn, void *udata);
   ```

   A non-zero return aborts the running script with a catchable JS error
   and leaves the runtime usable. The handler needs polling at backward
   jumps and call entry — the same safepoints the collector already uses,
   so the hook has a natural home. Worth considering in the same pass: a
   memory ceiling and a bytecode-instruction budget, since a host that
   cannot bound time usually cannot bound allocation either.

3. **Re-run the loading sweep after B1 and B2 land**, to see how many of
   the eight failures they actually account for.

Done since: the test262 skip-list audit (its own section above) and
regression coverage for every finding except E1 (see below).

---

## Regression coverage

Every finding except E1 has a test that **fails on the current engine and
passes under QuickJS or node**. A test that passes on broken code is worth
nothing, so each was validated in both directions before being committed.

| finding | test | surface |
|---|---|---|
| B1 registers | `test/test_many_decls_param_registers.js` | flat sweep |
| B2 regexp after `)` | `test/test_regexp_after_control_clause.js` | flat sweep |
| B3 quadratic `+=` | `scripts/check_string_concat_scaling.sh` | `just test-string-concat-scaling` |
| B5 JSON cycles | `test/test_json_stringify_cycles.js` | flat sweep |
| B6 string overflow | `test/robustness/run.sh` | `test-local` |
| B7 `repeat` limits | `test/test_string_repeat_limits.js` | flat sweep |
| B8 `toString(radix)` | `test/test_number_tostring_radix.js` | flat sweep |
| B9 rejections | `test/rejections/run.sh` | `test-local` |
| B10 `VM_ERROR` | `test/uncaught/run.sh` | `test-local` |
| B11 nesting crash | `test/robustness/run.sh` | `test-local` |
| B4 `error.stack` | — | needs frames first; assert in `test/uncaught/` once they exist |
| E1 interrupt | — | no API to test; see E1 above |

Three new surfaces were added to `test/run_local.sh`, because the flat
`test/*.js` sweep cannot express them:

- `test/rejections/` — asserts exit status and stderr. A script cannot
  assert its own silent death, and these must also confirm the complement:
  a *handled* rejection stays quiet and exits 0, so the fix cannot be to
  shout about every rejection.
- `test/robustness/` — the failures are crashes and hangs, so there is no
  output to assert and, for a hang, no return to wait for. Classifies by
  exit signal.
- B10's cases went into the existing `test/uncaught/`, which already owns
  the invariant they violate: `"VM error:"` is reserved for a genuine
  internal fault and must never appear for a JS-level throw.

B3 is a *scaling* assertion, not a speed one: it times the engine against
itself at 20k and 80k iterations and fails if 4x the work costs more than
8x the time. Linear is ~4x, quadratic ~16x, so the threshold tolerates a
loaded machine without tolerating the bug. Measured: 12.4x before the fix,
1.11x for QuickJS.

Two tests are worth keeping even though they pass today, as guards on
invariants a fix could easily break: `test_error_identity_with_microtasks.js`
(caught errors keep identity while a queue is live — the catchable half of
B10) and the deep-recursion cases in `test/robustness/run.sh` (already
correct, but a frame-layout change could turn them into segfaults).

---

## Verification method

Each finding was minimised to a self-contained strict-mode repro, run
under both `out/duktape_c3` and `out/qjs`, and confirmed to be
strict-legal. B1 and B2 were traced to the responsible source lines and
confirmed against disassembly (`out/duktape_c3_debug -c`). B3 was measured
as a median of three runs per point, across four input sizes, to establish
the growth rate rather than a single ratio.

Reproductions for B1 and B3 are generated by script; the generators are
inlined in the sections above.
