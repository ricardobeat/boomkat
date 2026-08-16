# Plan 055 — Pre-existing bugs surfaced by session-287/288 agents

Bugs found incidentally by cluster agents, outside their assigned scope.
Reproduced on main as of `4538dc7`. To be fixed by focused single-cause agents
once the current round (L, P2, C7a-cap) drains. **Do not dispatch until then.**

## Confirmed reproduced

### PB1 — arguments object lacks `@@iterator` — RESOLVED (already implemented)
RESEARCHED (not guessed): the strict `arguments` object IS a supported, first-
class feature. Evidence: dedicated `ObjClass.ARGUMENTS` exotic object built in 6+
VM call paths (vm_calls.c3:372 etc.) with indexed elements, `.length`, strict
`.callee` poison-pill ("may not be accessed in strict mode"), prototype =
Object.prototype; compiler `uses_arguments`/`forbid_arguments` (class-field-init
SyntaxError, spec-correct); `typeof arguments === "object"` inside a function.
My earlier "typeof undefined" probe was WRONG — it ran at global scope where
arguments correctly doesn't exist (`!self.is_global` gate).

What's OUT of scope: only the SLOPPY **mapped** arguments (arguments[i]↔named-param
aliasing) — the `language/arguments-object/` test dir is already skip-listed
(run_test262.py:312), which is the correct narrow exclusion.

RESOLVED — `@@iterator` is installed by `finish_arguments_object`
(src/vm/vm_calls.c3:22): it sets `.length`, `.callee`, and `@@iterator` to the
*same* function object as `%Array.prototype.values%` with descriptor
{writable: true, enumerable: false, configurable: true}. Verified against node:
value identity (`arguments[Symbol.iterator] === [][Symbol.iterator]` is true) and
descriptor match byte-for-byte; `[...arguments]`, `for-of arguments`,
`Array.from(arguments)` and destructuring all work. The edition is ES2015 core,
not >ES2015: test262 tags both tests `es6id` 9.4.4.6 S7 / 9.4.4.7 S22 (ES2015
§9.4.4 arguments-exotic-object steps). The two tests stay skipped only because
both carry `flags: [noStrict]` (wholesale runner filter): the mapped variant
genuinely needs sloppy mapped arguments, while the unmapped variant (assertions
inside a `'use strict'` IIFE) would pass if un-skipped per-file. The old
BACKLOG.md:59 pointer is stale — no such entry remains.

### PB2 — iterators have `next` as an OWN property, not on a shared prototype
`Object.getPrototypeOf([1,2][Symbol.iterator]()).hasOwnProperty("next")` is
`false`; the instance has its own `next`. So patching
`%ArrayIteratorPrototype%.next` is silently ineffective (spec-visible).
Affects Array/Map/Set/String iterators. Architectural — touches every iterator
type + GC. Reporter: TA. **Subsystem change — dedicated agent, careful.**

### PB6 — FIXED (`6599430`) — well-known symbol description + GETPROPC2 accessor bypass
Two bugs: (1) well-known symbols registered with bare description ("iterator" not
"Symbol.iterator"); (2) — the real symptom — the fused two-hop opcode GETPROPC2's
symbol-intermediate path returned the raw accessor-pair object instead of
auto-boxing + invoking the getter (why `Symbol.iterator.description` gave
`[object Object]` but `var s=Symbol.iterator; s.description` (single-hop GETPROPC)
worked). Fixed all 4 GETPROPC2 occurrences via a shared `getprop2_symbol_hop`
helper (vm_property.c3) + description literals (symbol.c3). NO test262 delta (no
test asserts the string) but a real correctness fix; validated via chained-access
+ alloc-in-getter stress + corpus, zero regressions. Latent same-pattern bug on
String/Number/Boolean.prototype GETPROPC2 intermediates is dormant (no accessors
there yet) — flagged for if those gain getters.
Adjacent unfixed: `Symbol.for(objectKey)` skips custom toString/toPrimitive
coercion (fails `Symbol/for/description.js`) — separate ToString bug.

### PB6-orig — well-known symbol `.description` wrong / not a string
`Symbol.iterator.description` returns `[object Object]` (should be
`"Symbol.iterator"`). Well-known symbols' description handling is broken.
Reporter: B. Small, localized to symbol.c3 — good focused task.

### PB7 — async generators silently accepted but non-conforming
`async function* ag(){}` parses; `typeof ag === "function"`, `ag.prototype`
is `undefined`, calling returns a plain object not an async generator.
Should either be supported or rejected at parse. Reporter: O. Marked deferred
in project scope (B35) — leave unless we decide to implement.

## RESOLVED

### PB10 — FIXED (`9566c0c`) — bound lightfunc builtin lost its receiver
Actual root cause (agent's re-diagnosis, NOT reentrancy): `builtin_bound_call`'s
lightfunc-downstream branch set `inner_ctx.this_val = bound_this` but never wrote
`bound_this` into `ctx.regs[base_reg-1]` (nor callee into `base_reg-2`). Lightfunc
builtins read their receiver from the register, so `Promise.resolve.bind(Promise)`
saw a stale slot → "Promise capability not initialized". Fix mirrors the object
branch's register writes. Unblocked P2. Then P2 (`34a5269`) merged: Promise dir
612/81 → 618/75 (chunked, apples-to-apples) = **net +6/-6**, P2 targets 10/10,
corpus clean. Prerequisite-first approach avoided shipping the -9 regression.

### PB10-history — (was) BLOCKING before P2
P2 (agent adc1fa66) fixed two real Promise bugs (stale `vm.has_error` channel +
no-handler microtask ordering, commit `261cfd5`, NOT merged) — but the call-timing
change EXPOSES a dormant VM bug: a bound function's `this` is corrupted when the
bound call happens through a nested/reentrant `heap.call_fn` boundary (e.g. a
map/forEach/sort callback, or a combinator's own resolve re-entry). Result: 10
Promise tests fixed but 19 newly fail → net -9 on built-ins/Promise. Agent proved
the underlying bug exists on unmodified HEAD via a synthetic non-Promise repro.
Lives in `vm_calls.c3`/`vm_execute.c3` bound-call dispatch or reentrant activation
save/restore. **This is the prerequisite:** fix PB10 first (oracle = the 19
newly-failing Promise tests + the agent's synthetic repro), THEN cherry-pick
`261cfd5` and confirm net-positive. Do NOT merge P2 before PB10 is fixed.
(Awaiting agent's exact repro + failing-test list.)

### PB11 — assignment LHS reference checked eagerly, not deferred to PutValue
`try { s = throws(); } catch(e){}` where `s` is undeclared throws ReferenceError
(from the LHS) instead of letting the RHS's RangeError propagate. Per ES2022
assignment semantics the LHS Reference is obtained but NOT dereferenced/checked
until PutValue (after RHS eval). Root cause in `src/compiler/expressions.c3`
`assignment_expr` — the LHS identifier existence is checked before/independent of
RHS evaluation. Blocks 3 Number/toFixed tests (S15.7.4.5_A1.3/A1.4) and likely
others that assign a throwing-RHS to an undeclared var in a try. Reporter: N1.
Overlaps PB8's expressions.c3 ownership — coordinate (do after PB8 lands).

## Session regressions (found by reliable s288 baseline) — RESOLVED (55 → 6)
Fixed:
- 15 async-thenable adoption (`4e23453`) — async RET must adopt returned promise.
- 10 eval/Array (`89698d3`) — var-init-drop (PB8 env_declare_var skip) +
  strict-eval-leak + block-fn-leak.
- 9 class/fn-name/private (`f2176f5`) — THREE separate bugs, NOT a7f171e:
  symbol-desc marker byte in method .name (4538dc7), class-name TDZ span OOB on
  escaped idents (ed0db46), var-hoisting walking into class bodies (4ff3485).
- arrow lexical `arguments` + `new.target` capture (`867e48c`) — 48/48 async
  class tests, +18 class improvements. NOTE: P2 (34a5269) didn't CAUSE these —
  arrow capture was always broken; P2's correct microtask fix stopped the old
  draining order from spuriously passing them.

Remaining 6 (documented, not hidden):
- 5 `super-prop`-in-direct-eval — DEFER: compile_eval lacks home-object context
  (feature gap PB8 flagged). See PB5.
- 1 `Promise/prototype/finally/rejected-observable-then-calls-argument.js` —
  async harness-mode discrepancy: PASS via `--debug` (concat harness), FAIL via
  `--worker`. Ambiguous; likely a runner-mode async-completion quirk not a real
  fail. Investigate if it persists in s289.

**Bisect lesson:** my own bisects were repeatedly corrupted by (a) uncommitted
plans/055 blocking `git checkout`, and (b) stale binaries after checkout. Both
agents re-bisected with `rm -rf build out` fresh builds and CORRECTED my culprit
attributions (a7f171e was innocent; the real culprits were 3 other commits).
Always commit WIP + `rm -rf build/obj` before comparative bisect runs.

### PB12 — P2 broke async-method return handling (PARTIAL FIX `4e23453`)
P2 (`34a5269`, Promise microtask/vm.has_error change) regressed 29 `[async]`
class async-method tests (bisected cleanly: PASS at 9566c0c, FAIL at 34a5269;
verified 3x-stable start-PASS vs main-FAIL). Fix `4e23453`: async RET now adopts
a returned thenable/promise (routes through promise_resolve_with_value) instead
of fulfilling with the Promise object → recovered 15/29. Promise dir stays 628/75
(P2 gains preserved), corpus clean.
Remaining 14 = arrow **lexical `arguments`/`new.target` capture** bug: an arrow
returned from a method gets its OWN empty arguments / sees the class ctor as
new.target instead of capturing the enclosing function's. Deeper compiler/VM
lexical-capture fix needed. (NOTE: the agent wrongly concluded "never passed /
not a regression" — its worktree had broken test262/quickjs setup giving bogus
0/29 bisect results; I verified it IS a real regression. Its FIX was still
correct and kept. Lesson: separate a wrong conclusion from a correct fix; always
verify agent bisects against a KNOWN-GOOD checkout.)

### PB13 — `Function('return this;')()` returns undefined, not the global object
A non-strict Function-constructor body's `this` should be the global object; it
returns undefined. Blocks `Object/entries|values/tamper-with-global-object.js`.
Pre-existing (unmodified HEAD). Outside object.c3. Reporter: O4. (Related to the
strict-only `this` handling — but Function() bodies are a distinct path.)

### PB14 — `Object/fromEntries/evaluation-order.js` SIGABRTs the worker
Reproduces on unmodified HEAD. A crash, not a wrong value. Needs investigation.
Reporter: O4.

### PB15 — AggregateError has the same abrupt-completion bug as Error (follow-up)
`builtin_aggregate_error` (error.c3) uses raw `has_prop`/`get_prop`/`builtin_to_string`
for its `cause`/`message` args — same root cause E1 fixed for Error. Pre-existing
fails: `AggregateError/message-tostring-abrupt.js`, `*-abrupt-symbol.js` etc.
Natural follow-up: apply the same js_has_property/builtins_generic_get/
builtin_to_string_vm treatment. Reporter: E1.

## Needs more investigation

### PB3 — batch-runner SIGSEGV under sustained load — CLOSED (no longer reproduces)
`test262_runner --worker` crashed between tests under load (heap.reset/GC
fragility). Does not repro via isolated run_single_test.sh. Tracked in memory
`batch-runner-segv-under-load`. **Highest severity (a crash)** but hardest to
pin — needs a focused GC/heap-reset investigation, likely with a stress repro.

CLOSED 2026-08-16: no worker crash in any full-suite run since the session-302/303
GC fixes — sessions 303, 309, 312 and the review run all completed 49,814/0 with
`--workers 4` under sustained load. The heap-reset/GC fragility class PB3 pointed
at was addressed in that window: the deterministic worker segfaults fixed by the
decref revert (`37252db2`), the generator/async-resume GC lifetime crash
(`6722c1a6`, plus the `GC_STRESS` + ASAN gate it added), and the mid-sweep
refcount double-free (`afc10dd2`). The runner's RSS-sampling MEMKILL cap
(scripts/run_test262.py) also converts over-memory workers into clean kills
instead of native crashes. Reopen if a worker dies under sustained load again.

### PB5 — eval'd `super.x` in an OBJECT-LITERAL method resolves wrong super-base
`__super__` holds either the constructor (needs `.prototype`) or the home
object directly (needs GETPROTO) depending on compile-time context that eval
can't see. Fix needs unifying `__super__` to always hold the home object.
Touches shared class-compilation code. Reporter: B (2 super/*-from-eval tests).

### PB8 — eval/global-code declaration fixes (L validated then REVERTED)
L (agent a27cfd50) built + isolation-verified these fixes but reverted them to
converge cleanly (they touch the shared, high-risk `env.c3`/`builtins/global.c3`
eval surface). A fresh focused agent should redo — the design is proven:
- `builtin_eval` wraps global var/function decls in a throwaway child env; global
  eval `var`/`function` must become persistent global-object properties
  (CreateGlobalVar/FunctionBinding). Fix: split `var_env` from `lex_env`, only
  wrap when caller var-scope is a real function activation; companion fix in
  `env_declare_var` (env.c3) so re-declaring a global doesn't clobber it.
  (`global-code`, 16 tests; `script-decl-var.js` reached passing before revert.)
- direct-eval `this` used eval's own call this-slot not caller's `this`
  (`eval-code`: `this-value-global.js`, `this-value-func.js`).
- `(0, eval)(...)` still flagged as DIRECT eval — `callee_is_eval` never cleared
  when the grouping expr isn't a bare identifier. Fix: clear in expressions.c3's
  4 grouping-return paths.
- `typeof (x)` for undeclared parenthesized `x` threw instead of `"undefined"`.
- global/eval top-level `return` didn't throw SyntaxError (statements.c3).
- class-decl TDZ prescan only collected let/const, not `class` (general bug).
- `new.target`/`super` inside eval (4 tests): genuine feature gap (compile_eval
  lacks call-site enclosing-function/home-object context) — skip-list, don't fix.
The committed `functions.c3`/`expressions.c3` var-hoisting fixes (in 4ff3485) are
prerequisites these build on.

### PB9 — FIXED (`4900b11`) — prescan misdetected `this.#x` access as declaration
Real root cause (agent re-diagnosed): `prescan_private_names` only tracked {}
depth, not (), so a `this.#x` in a field-init/default-param (not brace-wrapped)
sat at the same depth as a real declaration → false "duplicate private name".
Fixed by excluding HASH_IDENT preceded by DOT/OPT_CHAIN from declaration
classification (private_names.c3) + field_init_ctx/static_init_ctx now
adopt_private_names (class.c3). NOTE: my repro used a PUBLIC field `f=...` which
is entirely UNIMPLEMENTED in this engine (pre-existing, separate) — agent used
the private-field equivalent that test262 actually exercises. +3 class tests.

### PB9-orig — arrow in class-field initializer accessing a private name
`class B { #s=5; f=(()=>this.#s); }` fails at compile with "duplicate private name
declaration". Confirmed pre-existing (fails identically on 4ff3485, before the
private-names-cap change — NOT a C7a-cap regression). Root cause: likely
`compile_default_expr`/field-initializer private-name scope propagation — the
arrow's nested context re-declares `#s` instead of borrowing. C7a-cap agent
flagged the same shape (`add(x = this.#base)`). Localized to compiler
field-init/private-name handling. Reporter: C7a-cap.

### PB4 — lightfunc as prototype / super-target
`super()` to a lightfunc builtin segfaulted in B's repro (reverted). Lightfuncs
have no HObject* identity. `Object.setPrototypeOf(fn, lightfunc)` does NOT crash
in isolation — B's crash was the more specific super-call path. Needs the exact
repro re-derived before fixing.
