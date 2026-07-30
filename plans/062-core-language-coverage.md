# Plan 062 — Core-language coverage

## Goal

Bring the 13,030 orphaned test262 tests into `PHASES` and fix every real failure
they surface, so the two-run zero-fail gate covers core language semantics
rather than only the 64% currently in a phase.

## Enabling

`scripts/run_test262.py` `PHASES` now includes the previously orphaned
directories, assigned topically:

- Phase 2 — `does-not-equals`, `strict-does-not-equals`, `coalesce`,
  `logical-assignment`, `assignmenttargettype`, `grouping`, `concatenation`,
  `relational`, `this`
- Phase 7 — `statements/for-in`, `statements/function`, `statements/let`,
  `statements/const`, `statements/debugger`, `expressions/new.target`
- Phase 24 — `statements/async-function`, `expressions/async-function`,
  `expressions/async-arrow-function`, `expressions/await`

Deliberately excluded as declared non-goals: `statements/with` (sloppy mode),
`statements/labeled` (tail-call-optimization feature token),
`statements/using` + `statements/await-using` (Stage 3 explicit resource
management).

## Measured result of enabling

| Phase | Total | Pass | Fail | Skip | CE unexpected |
|---|---|---|---|---|---|
| 2 | 2484 | 1759 | 0 | 721 | 4 |
| 7 | 1898 | 1180 | 25 | 690 | 3 |
| 24 | 1483 | 1216 | 13 | 252 | 2 |

47 failures + 9 of the 13 phase-24 failures being MEMKILL. Grouped below by
root cause; each group is one agent-sized unit.

## Root-cause groups

### A. `return` inside `finally` in an async function — VM error + runaway

```js
async function f(){ try{ return 1 } finally{ return 2 } }
f().then(v => print(v));
// VM error: vm::VM_ERROR (at execute) / Uncaught: undefined is not a function
```

The synchronous form is correct (`function f(){try{return 1}finally{return 2}}`
→ 2). Only the async path breaks, and under the harness it does not just fail —
it allocates without bound and gets memory-killed. Affects all three async
function forms (declaration, expression, arrow) × three bodies
(`try-return-`, `try-throw-`, `try-reject-finally-return`) = 9 MEMKILL tests.

Suspect: the AWAIT/`finally` interaction in the generator-driver teardown —
the completion-override from `finally` is not being routed through the async
resumption path, so the driver re-enters with a non-callable continuation.

Tests: `language/{statements,expressions}/async-function/try-*-finally-return.js`,
`language/expressions/async-arrow-function/try-*-finally-return.js`

### B. `await` wrongly treated as a reserved assignment target

```js
var await = 0;
await = 1;   // SyntaxError: Assignment to eval or arguments is not allowed
```

`await` outside an async context is a plain identifier and is assignable. The
parser is grouping it with `eval`/`arguments` in the strict-mode
simple-assignment-target check. Also breaks `await` as an identifier inside a
non-async function nested in an async function.

Tests: `language/expressions/assignmenttargettype/simple-basic-identifierreference-await.js`,
`language/expressions/await/await-in-nested-function.js`,
`language/expressions/await/await-in-nested-generator.js`

### C. `for-in` / `for-of` head does not accept a bare comma expression

```js
for (let x in null, { key: 0 }) {}   // SyntaxError: expected ')', got ','
```

The head's `Expression` production is being parsed as `AssignmentExpression`
instead of `Expression`, so the comma operator is rejected. Parenthesised form
works.

Tests: `language/statements/for-in/head-decl-expr.js`, `head-expr-expr.js`,
`head-var-expr.js`

### D. `for-in` head lexical declarations are not in a TDZ

```js
let x = 1;
for (let x in { x }) {}   // must throw ReferenceError; we don't
```

Per ForIn/OfHeadEvaluation step 2, the bound names of the `ForDeclaration` must
be created as an uninitialised binding in a fresh declarative environment
before the head expression is evaluated. We evaluate the head in the enclosing
scope, so the head sees the outer `x` (or the not-yet-created inner one) with no
TDZ.

Tests: `language/statements/for-in/head-let-bound-names-fordecl-tdz.js`,
`head-const-bound-names-fordecl-tdz.js`, `scope-head-lex-open.js`,
`scope-head-lex-close.js`, `scope-body-lex-open.js`

### E. `for-in` statement completion value

```js
eval('1; for (var a in { x: 0 }) { }')   // must be undefined; we give 1
eval('1; for (var a in {}) { 2; }')      // must be undefined; we give 1
eval('1; for (var a in {x:0}) { break; }') // must be undefined; we give 1
```

Per ForIn/OfBodyEvaluation step 2, `V` starts as `undefined`, not as the
completion value of the preceding statement. `for-of` and `for` presumably have
the same shape — check them while here.

Tests: `language/statements/for-in/cptn-decl-{itr,skip-itr,zero-itr,abrupt-empty}.js`,
`cptn-expr-{itr,skip-itr,zero-itr,abrupt-empty}.js`

### F. `for-in` must skip prototype properties shadowed by a non-enumerable own property

```js
var proto = { p2: 'p2' };
var o = Object.create(proto, {
  p1: { value: 'p1', enumerable: true },
  p2: { value: 'x',  enumerable: false },
});
var k = []; for (var p in o) k.push(p);
// ours: ["p1","p2"]   spec/qjs: ["p1"]
```

EnumerateObjectProperties must record every own key it visits — including
non-enumerable ones — as "already seen", so a same-named enumerable prototype
property is not emitted. We only record the keys we actually yield.

Tests: `language/statements/for-in/order-enumerable-shadowed.js`,
`12.6.4-2.js`

### G. TDZ for a `let`/`const` self-reference is missed inside a function body

```js
function g(){ { const x = x + 1; } }
g();   // must throw ReferenceError; at top level we do, in a function we don't
```

Top-level block scope gets the TDZ right; a block nested in a function body
does not. Likely the function-body scope path initialises the lexical slot
before evaluating the initialiser.

Tests: `language/statements/{let,const}/block-local-use-before-initialization-in-declaration-statement.js`,
`function-local-use-before-initialization-in-declaration-statement.js`

### H. Assignment to a `const` in a loop head/body must throw TypeError

```js
for (const i = 0; i < 1; i++) {}   // must throw TypeError
```

Standalone this does throw TypeError; the harness-wrapped form fails. Determine
whether the failure is the `for-in`/`for-of` body variants
(`const-invalid-assignment-statement-body-for-in`/`-for-of`) rather than the
plain `for` head, and fix the ones that are genuinely wrong.

Tests: `language/statements/const/syntax/const-invalid-assignment-next-expression-for.js`,
`const-invalid-assignment-statement-body-for-in.js`,
`const-invalid-assignment-statement-body-for-of.js`

### I. `delete (obj.prop)` rejected as an unqualified identifier

```js
var o = {};
delete (o.prop);   // SyntaxError: delete of an unqualified identifier
```

The strict-mode `delete` check does not look through a parenthesised
expression, so a perfectly qualified member reference is misclassified.

Tests: `language/expressions/grouping/S11.1.6_A2_T1.js`

### J. `[[Construct]]` with a non-object `.prototype` must fall back to `%Object.prototype%`

```js
function F(){}; F.prototype = 1;
Object.prototype.isPrototypeOf(new F());   // must be true; we give false
```

OrdinaryCreateFromConstructor: when `constructor.prototype` is not an object,
use the intrinsic default prototype. We appear to install the primitive (or
null) instead.

Tests: `language/statements/function/S13.2.2_A3_T1.js`, `S13.2.2_A3_T2.js`

### K. Escaped `async` followed by a line terminator

```js
async
x => {}      // must not parse as an AsyncArrowFunction
async
function f(){}   // `async` is an expression statement, not an async function
```

The `[no LineTerminator here]` restriction after `async` is not enforced, and
the escaped-`async` spelling is being treated as the contextual keyword.

Tests: `language/expressions/async-arrow-function/escaped-async-line-terminator.js`,
`async-lineterminator-identifier-throws.js`,
`language/statements/async-function/syntax-declaration-no-line-terminator.js`

### L. `await` on a non-promise thenable

`language/expressions/await/await-non-promise-thenable.js` fails in-harness
while the reduced form resolves correctly. Reproduce under the harness before
assuming a fix is needed — may be an ordering/job-count assertion rather than a
value bug.

### N. `for-in` yields keys deleted during enumeration (found in batch 1)

`language/statements/for-in/S12.6.4_A7_T2.js` was listed under group F but is a
different bug: we pre-collect the key list, so a property deleted mid-loop is
still yielded (ours: `aa1baundefinedca3`, expected: `aa1ca3`). Spec requires
liveness — a key whose property was deleted before its turn is skipped.

### M. BigInt precision limit (out of scope, needs a skip entry)

`does-not-equals/bigint-and-number-extremes.js` and
`strict-does-not-equals/bigint-and-number-extremes.js` use ~256-bit BigInt
literals. Arbitrary-precision BigInt is out of scope (plan 056 chose fixed-width
int128); these belong in `SKIP_FILES` alongside the existing
`built-ins/Map/valid-keys.js` entry, with the same rationale.

## Execution

Batches 1-3 (merged, validated): A (async finally/return), F (for-in shadowing),
J (construct prototype fallback), B (`await` identifier), I (`delete` grouping),
D+E (for-in head TDZ + completion value — incl. closure capture of the head
env), C (for-in/of comma RHS), G (nested block TDZ), K (async no-LineTerminator).
Post-merge main: phase 2 → 1761 pass / 0 fail / 2 unexpected CE (the two BigInt
extremes, group M), phase 7 → 1204 pass / 4 fail (H×3 + N), phase 24 → 1230
pass / 1 fail (L); rosetta 100/100, golden bytecode 10/10.

Final batch — agents in `.worktrees/agent-1|2|3`, each reset to current `main`:

4. H (const assignment), L (await thenable), M (BigInt skip entries) + N (for-in deletion liveness)

## Verification

Per agent: `rm -rf build`, rebuild both binaries, run the owning phase to zero
new failures, `just test-golden-bytecode` (10/10), `just rosetta` (100/100).
Final: `just test262-gate` two-run zero-fail across all phases.
