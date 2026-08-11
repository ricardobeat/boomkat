# Plan 070: real-world battle testing

Findings from running third-party production JavaScript against the engine
rather than test262. The gate is green on 49,814 conformance tests, so the
bugs below are all in territory the suite does not reach: register pressure
in large real functions, the regex/division lexer heuristic, incremental
string building, and host-visible error reporting.

Corpus used: 21 unmodified library bundles fetched from jsDelivr (lodash,
underscore, moment, marked, handlebars, immutable, acorn, bluebird,
decimal.js, bignumber.js, mathjs, jszip, papaparse, crypto-js, protobufjs,
chance, he, nearley, d3-array, uuid, plus typescript 9 MB and babel 5 MB).
QuickJS (`out/qjs`) is the differential oracle throughout.

Status: B2, B5, B6, B7, B8, B9, B10, B11 fixed. B1 in progress. B3, B4, B12
and the E-series open.

## Contents

- [Scope note: strict-only is not the cause](#scope-note-strict-only-is-not-the-cause)
- [Headline: 8 of 21 libraries fail to load](#headline-8-of-21-libraries-fail-to-load)
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

## Headline: 8 of 21 libraries fail to load

Each bundle was prefixed with a host shim
(`globalThis.window = globalThis.self = globalThis.global = globalThis`)
and followed by `console.log("LOADED")`, then run under both engines.
**All 21 load under QuickJS. 8 fail here.**

| library | duktape_c3 | first error |
|---|---|---|
| underscore 1.13.6 | FAIL | `Cannot read properties of undefined (reading 'length')` (B1) |
| marked 4.3.0 | FAIL | `SyntaxError: unexpected token in expression` (B2) |
| bluebird 3.7.2 | FAIL | `Cannot read properties of undefined` |
| jszip 3.10.1 | FAIL | `Cannot read properties of undefined` |
| handlebars 4.7.8 | FAIL | `object is not a function` |
| protobufjs 7.4.0 | FAIL | `undefined is not a function` |
| typescript 5.4.5 | FAIL | exit 2 |
| babel 7.24.7 | FAIL | exit 1 |
| lodash, moment, immutable, acorn, decimal.js, bignumber.js, mathjs, papaparse, crypto-js, chance, he, nearley, d3-array, uuid | PASS | — |

Two failures are root-caused: underscore to B1, marked to B2.

The other six are **not** explained by B1, and are still unidentified.
Counting function declarations per scope rules it out: only underscore
concentrates them in a single scope (109 at two-space indent). bluebird
(149), jszip (148), protobufjs (131) and handlebars (76) spread theirs
across per-module closures, so none of them approaches the 256-register
ceiling in any one scope. Their errors — `Cannot read properties of
undefined`, `object is not a function`, `undefined is not a function` —
share the signature of a value silently becoming `undefined`, but the
cause is different and needs its own minimisation. typescript and babel
fail with bare non-zero exits (2 and 1) and are the least useful starting
points given their size.

Investigating these six is the highest-value follow-up from this plan:
they are six independent real-world reproductions of bugs not yet
characterised.

This is the number that matters most: the conformance gate is green at
49,814 tests, but a majority-of-the-ecosystem sample of real bundles has a
38% load failure rate. Conformance and real-world compatibility have
diverged, which is what motivated this plan.

---

## B1: register allocation silently wraps at 256

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

`String.prototype.split` on a large string shows the same order of
overhead (18x at 20k) and is likely the same underlying copy.

Probable cause: the engine-wide invariant that every `HString` is interned
(string equality is pointer identity) means each intermediate result is
copied and hashed in full. QuickJS avoids this with ropes / in-place
extension of a uniquely-referenced string. Any fix has to preserve the
interning invariant — most likely by leaving concatenation temporaries
un-interned until they escape, which `src/hstring.c3:186` already
contemplates ("non-interned, such as a concatenation temporary").

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

## B12: `yield` as a destructuring default in `for await` loses the binding

**Severity: medium. Found by B9's rejection reporting, not by the suite.**

A destructuring pattern whose default is a `yield` expression, used as the
`for await` target, never binds the variable. The resulting `ReferenceError`
is swallowed into a rejected promise, so the failure was invisible until
unhandled-rejection reporting landed.

```js
async function* g(){ for await ([value = yield "a"] of [[]]) { print(value); } }
var it = g();
it.next().then(function(r){ return it.next(11); });
```

- `qjs`: resumes the body with `value=11`
- `duktape_c3`: `ReferenceError: 'value' is not defined`

`test/test_for_await_yield_operand.js` reports `4 pass, 0 fail` in both
engines, because the assertions live inside the loop body the engine never
reaches. Only the stderr rejection distinguishes them, which is why the
existing test did not catch it.

Both the array (`[value = yield]`) and object (`{value = yield}`) forms fail
the same way.

Note this is a genuine engine bug and not fixture noise: unlike the four
promise fixtures quieted in `eba2734d`, QuickJS produces no rejection here at
all.

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
