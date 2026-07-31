# Plan 065 — `typeof arguments` returns `"undefined"`

Pre-existing, found by the plan-062 class-body agent while working on an
unrelated cluster, then independently confirmed. **Not caused by any of this
session's fixes** — reproduced on a binary built before them.

## Symptom

```js
"use strict";
function f(){ return typeof arguments; }
f();                          // ours: "undefined"   node: "object"
```

A silent wrong-value bug in ordinary, idiomatic code — no error, no test262
failure in the phases run so far. That makes it more serious than the
parse-rejection gaps fixed this session, which only affect invalid input.

## The binding exists; only `typeof` misreads it

```js
function g(){ return arguments.length; }  g(1,2);   // 2        ✓ correct
function h(){ return !!arguments; }       h();      // true     ✓ correct
function i(){ return typeof arguments; }  i();      // undefined ✗
```

So `arguments` is present and usable. Only the `typeof` path fails.

Scope (all verified against node, strict mode):

| shape | ours | node |
|---|---|---|
| `function f(){ return typeof arguments }` | `undefined` | `object` |
| `var o={m(){ return typeof arguments }}` (method) | `undefined` | `object` |
| `function f(){ return (()=>typeof arguments)() }` (arrow closes over) | `undefined` | `object` |

Controls that are already correct — do not regress:

| shape | ours | node |
|---|---|---|
| `typeof nope123` (undeclared) | `undefined` | `undefined` |
| `arguments.length`, `!!arguments` | correct | correct |

**Correction (post-fix).** An earlier draft listed
`function f(){ return typeof this }` → `"object"` as a control. That is the
*sloppy-mode* answer and was wrong for this engine. In genuine strict mode an
unbound call's `this` is undefined, so `"undefined"` is correct — verified
against node run as an ES module (a plain `.js` is sloppy CommonJS there, which
is what produced the mistaken expectation). The engine was already right; the
control was dropped rather than encode a sloppy-mode expectation.

## Likely mechanism

`src/compiler/expressions.c3:1464-1590` compiles `typeof <ident>`. A bare
identifier operand emits either:

- `TYPEOF` (register-based) when the name resolves to a known local, or
- `TYPEOFIDENT` (env-walking, by name) otherwise — deliberately, so an
  *undeclared* identifier yields `"undefined"` rather than throwing.

`arguments` is materialized lazily rather than existing as an ordinary env
binding, so the `TYPEOFIDENT` name-walk does not find it and falls into the
not-found branch that returns `"undefined"`. Every other use of `arguments`
goes through a path that triggers materialization, which is why only `typeof`
is wrong.

Verify this before fixing: disassemble with `./out/duktape_c3_debug -c` on a
`typeof arguments` repro and confirm `TYPEOFIDENT` is emitted and that the
name-walk misses. Do not assume — the fix differs depending on whether the
right place is the compiler (recognize `arguments` and force materialization /
emit register-based `TYPEOF`) or the VM (`TYPEOFIDENT` consults the lazy
`arguments` slot before concluding not-found).

Prefer whichever keeps the undeclared-identifier semantics intact with the
least duplication. If the compiler already has a helper that recognizes
`arguments` for other purposes, reuse it rather than adding another check —
this repo has repeatedly been bitten by the same predicate hand-rolled at N
sites (BACKLOG session 302; plans 063 and 064, where the fix was to *remove*
copies).

## Not in scope

`eval("function A(){} var A;")` was reported alongside this as an
EvalDeclarationInstantiation bug. Re-checked: `typeof A` after that eval
returns `undefined` in **both** ours and node, so the reported shape is not a
divergence. If there is a real bug there it needs a different repro; do not
chase it under this plan.

## Validation

1. All three failing shapes return `"object"`, matching node.
2. All controls above unchanged — especially `typeof nope123` → `"undefined"`,
   which is the semantics `TYPEOFIDENT` exists to provide.
3. Golden bytecode: if the emitted opcode for `typeof <ident>` changes,
   `just test-golden-bytecode` will move. Regenerate ONLY after confirming the
   disasm diff is the intended change, and pair any regenerated golden with a
   behavioural assertion (BACKLOG notes that regenerating goldens silently
   destroys coverage otherwise).
4. `just rosetta` 41/41 · `just test-local` green.
5. Phases 0-1, 3, 7 (function/scope-heavy) — no new failures.
6. Regression test under `test/` covering the three shapes plus the controls.
