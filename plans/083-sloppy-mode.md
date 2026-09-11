# Sloppy Mode Support

**Date:** 2026-09-03
**Target:** Restore sloppy-mode execution as a peer to strict mode, alongside ESM's always-strict default. Inverse of plan 035 (strict-only migration).
**Strategy:** Parser first, then minimum-runtime semantics in order of test262 pass-rate yield.

> Plan 035 collapsed the engine to a single execution mode and explicitly removed every sloppy path it could find. This plan reverses that, but only the parts needed for test262 conformance — performance and code-size regressions are *not* a goal here, correctness against the ES spec is.

---

## 1. Rationale

The engine is currently strict-only by design (AGENTS.md guardrails, plan 035). This excludes ~2,687 `noStrict`-flagged tests + 19 file-path skips + 181 `language/statements/with/` tests. Restoring sloppy mode unlocks them, but the strict-only defaults are deeply baked into the lexer, compiler, and VM. A naive dual-mode restoration would re-introduce every conditional plan 035 removed — `ACT_FLAG_STRICT`, `WITH_START`/`WITH_END` opcodes, `is_with` env chains, two-way `arguments` mapping, implicit-global creation, octal literals.

**Goal:** minimum change that flips the parser to accept sloppy syntax, then the smallest VM edits that make sloppy tests actually pass. Measure the pass rate after each phase; let that drive the next.

The user wants this incremental:

> Do the parser first, see how many tests already pass. Then implement the smallest possible change to make sloppy behaviour work.

So the phases below are ordered by parser-first / yield-per-edit, not by architectural cleanliness.

---

## 2. Current State (Surveyed 2026-09-03)

### Two strictness flags, only one of which is live

| Flag | File | Current | Controls |
|---|---|---|---|
| `Lexer.strict_mode` | `src/lexer.c3:462` | **pinned `true`**, never toggled | octal literal/escape rejection (lines 1419, 1497) |
| `Lexer.reserved_words_strict` | `src/lexer.c3:475` | toggled by `set_strict()` for dynamic Function bodies and indirect eval | FutureReservedWord recognition; passes through `is_restricted_name(strict: …)` |
| `CompilerContext.is_strict` | `src/compiler/context.c3:223` (removed in plan 035) | **field does not exist** | n/a |
| `CompilerContext.subst_global_this` | `src/compiler/context.c3:791` | set only when compiling a dynamic `Function()` body | gates `FuncFlags.subst_global_this` |
| `FuncFlags.is_strict` | `src/bytecode.c3:1284` | **bit does not exist** (plan 035 removed it) | n/a |

There is **no per-function strictness flag** anywhere in the engine. `subst_global_this` (`FuncFlags:22`) is the closest thing, but it's only set on dynamic Function bodies, never for ordinary sloppy code.

### Strictness hardwiring, grouped by where to add the toggle

| Group | Currently unconditional | Sites (file:line) | Sloppy needs |
|---|---|---|---|
| **Parser rejects** | `with`, duplicate params, `eval`/`arguments` as binding names, octal literals `0777`, octal escapes in non-directive strings, `delete <id>`, duplicate `__proto__`, `for (var x = 1 in o)` | `statements.c3:374` (with); `functions.c3:183` (dup params); `tokens.c3:160` (eval/args binding); `expressions.c3:3844` (octal literal); `expressions.c3:3874` (octal escape); `expressions.c3:1816` (delete id); `expressions.c3:5593` (dup proto); `statements.c3:3322` (for-init in) | conditional on `is_strict` |
| **Currently gated** on `reserved_words_strict` | `eval`/`arguments` as params, restricted binding names | 26 call sites in `functions.c3`/`tokens.c3`/`destructuring.c3`/`statements.c3`/`expressions.c3` | already conditional — feed real `is_strict` instead of `reserved_words_strict` |
| **Compiler emission** | `PUTVAR_ASSIGN` (throws on undeclared) instead of `PUTVAR` (creates implicit global); DELPROP throws on `false` instead of returning `false` | `statements.c3:3876,4244`; `vm_property.c3:2614,2666,2694,2736` | conditional; sloppy needs silent failure path |
| **VM call paths** | `subst_global_this` checked at 7+ sites; always false for ordinary functions | `vm_calls.c3:1058,1073,1963,2153`; `vm_execute.c3:754,779` | sloppy: always substitute undefined/null `this` to global object |
| **VM this coercion** | none — primitives reach `this_binding` unwrapped | `vm_property.c3:205,273` (comments confirm) | sloppy: ToObject-wrap primitive receivers |
| **VM `arguments` exotic** | always unmapped/strict (`finish_arguments_object` line 41-42) | `vm_calls.c3:41-77,1098-1116,2018-2034` | sloppy: two-way mapped `arguments` (needs `[[ParameterMap]]`) |
| **VM poison pill** | `arguments.callee`/`caller`/`arguments` always throws TypeError | `vm_property.c3:169-177,501-526,753-772,1128-1138,136-141,1650-1662` | sloppy: return `null`; only throw on strict functions |
| **Annex B Object.prototype methods** | `__defineGetter__`/`__defineSetter__`/`__lookupGetter__`/`__lookupSetter__` **already installed** | `builtins/object.c3:5571-5591,5106-5209` | nothing — AGENTS.md was wrong here |
| **Catch parameter binding** | `expect_binding_identifier` always rejects restricted names | `statements.c3:4782` | conditional on `is_strict` |
| **`for (var x = 1 in y)`** | forbidden by `forbid_in` regardless of mode | `statements.c3:3322-3330` | sloppy: allow initializer |

### Skip-list surface (audit 2026-09-03)

| Source | Count | Notes |
|---|---|---|
| `FLAG_NOSTRICT_RE` (noStrict-flagged tests) | **2,687** files (1,136 inline form + 1,551 YAML-block form in `staging/sm/`) | minus 2 exempted by `NOSTRICT_RUN_GLOBS` → ~2,685 effective skips |
| `SKIP_DIRS` strict-only entries | 1 | `language/statements/with` (181 tests) |
| `SKIP_FILES` strict-only entries | 19 | 8 category-A (parser-level), 11 category-B (runtime) |
| Non-strict-only exclusions (out of scope) | ~4,970 | BigInt precision (>2^127), `intl402`, `annexB`, ShadowRealm/DisposableStack, cross-realm, multi-agent, $DONOTEVALUATE — **do not unskip these** |
| `staging/sm/strict/` | 51 | SpiderMonkey-donated; `testLenientAndStrict` expects modes to differ |
| `language/statements/with/` | 181 | un-skippable only once `with` works |

Breakdown of the 19 SKIP_FILES entries:
- **Category A (parser-level)**: 8 entries. `built-ins/Function/15.3.2.1-11-{1,2,5,6,8,9}-s.js` and the 4 `built-ins/Function/length/S15.3.5.1_A{1,2,3,4}_T3.js` — all duplicate-param tests on Function-constructor bodies, plus `language/eval-code/indirect/always-non-strict.js` and `language/comments/hashbang/use-strict.js` (both `with`).
- **Category B (runtime)**: 11 entries. `built-ins/Function/prototype/{apply,call}/S15.3.4.{3,4}_A5_T{1,2}.js` (sloppy `this` substitution), `language/statements/variable/12.2.1-{9,21}-s.js` (indirect-eval var `eval`/`arguments`), 8 `staging/sm/strict/*.js` SpiderMonkey tests.

---

## 3. Migration Phases

**Status (2026-09-12).** Phases 0-4 have landed. Phase 5 is done except for the
`annexB` suite, which stays skipped: measured at 332/1086 passing, blocked on
the B.3.3/B.3.4 hoisting matrices and the legacy direct/indirect eval-code
rules. The per-phase checklists below are kept as the record of what each phase
was for, not as instructions.

### Phase 0 — Per-function `is_strict` flag (infrastructure only, no behavior change)

1. **`src/bytecode.c3`** — add `is_strict` to `FuncFlags` bitstruct. Pick the next free bit (currently bits 0-31 used; pick bit 32, may need widening). Add the `CompiledFunction.is_strict()` accessor macro alongside `subst_global_this()`.
2. **`src/compiler/context.c3`** — add `bool is_strict = true` to `CompilerContext` (init to true → preserves current behavior). Add `bool current_strict` derived from `current_func.flags.is_strict` so inner functions inherit. Add `CompilerContext.is_strict` field.
3. **`src/compiler/entry.c3`** — `compile()` (line 29) sets `ctx.is_strict = false` for scripts (sloppy is now default). `compile_module()` (line 438) keeps `ctx.is_strict = true`. `compile_function()` (line 371) honors a `dynamic` parameter (already does); for non-dynamic ordinary functions, `is_strict` defaults to **false** (sloppy). For dynamic Function bodies, `is_strict` starts **false** but `parse_directives()` flips it true when `"use strict"` is seen (currently the directive clears `subst_global_this` at `statements.c3:815-817`; add `is_strict = true` next to that).
4. **`src/compiler/context.c3:2256`** — stamp `func.flags.is_strict = self.is_strict` in `finish()`.
5. **`src/vm/*.c3`** — keep runtime behavior identical. **Do not** read `is_strict` anywhere yet.
6. **Verification**: `just rosetta` must still pass 100%. `just test262` should produce the same numbers as before. The flag is dead — it's just plumbed through.

This is the highest-risk phase because the flag has to land in `FuncFlags` without breaking dump_function, the GC, the bytecode serializer, or any test that disassembles. Land it on a build flag if necessary (`NONANBOX` precedent).

### Phase 1 — Parser accepts sloppy syntax (no VM changes yet)

Goal: `with`, octal literals, octal escapes in non-directive strings, `eval`/`arguments` as binding names, duplicate params, `let`/`static` as identifiers, duplicate `__proto__`, `delete x`, `for (var x = 1 in y)` all **parse** without error. Runtime semantics remain strict. Many of these tests will still fail at runtime, but a meaningful fraction will pass because their assertions check parse-time behavior.

1. **`src/lexer.c3`** — `strict_mode` (line 462) reads from a new flag that follows `current_func.flags.is_strict`. Easiest: make `scan_number` (line 1090-1309) and `scan_string` (line 1340-1517) consult a per-call strictness hint passed from the parser. Alternative: per-function `is_strict` lookup at compile time emits a directive that toggles the lexer flag. The simpler path: leave the lexer pinned, but lower `reserved_words_strict` and add a new "octal scan enable" flag that the parser toggles via `set_strict()`. Refactor `set_strict()` (line 2610-2611) to actually flip `strict_mode` too.
2. **`src/lexer.c3:1182-1195`** — `scan_number` legacy-octal scan path. Today it consumes `0777` as decimal. In sloppy mode it should either reject (ES2024 says yes) or convert to octal value. test262 expects the value to be `511` (true octal) when sloppy, not `777` decimal. **Add octal value parsing** to `scan_number`: when `is_legacy_octal_like` and not strict, parse as base-8 and produce the octal value, raising the `has_octal_escape` flag (no — that's strings only). This is a non-trivial lex change; verify against Duktape/QuickJS for the exact behavior.
3. **`src/compiler/statements.c3:374`** — `with` parser: guard the rejection on `self.is_strict`. In sloppy, accept the statement and emit a `WITH_START`/`WITH_END` opcode pair (the opcodes already exist as enums at `bytecode.c3:292,295` per plan 035). For Phase 1, the VM doesn't have these opcodes yet — emit a placeholder that throws at runtime (preserves current "rejected at parse" → "fails at runtime" transition). Mark the opcodes as "Phase 4: implement semantics" in a comment.
4. **`src/compiler/functions.c3:181-191`** — `SeenParams.declare()`. The duplicate-param check at line 183 (`if (self.contains(name)) return COMPILE_ERROR~`) becomes conditional on `self.strict`. Restrict the strict-default to true only when `self.strict` is set.
5. **All 26 `is_restricted_name(..., strict: self.lexer.reserved_words_strict)` call sites** — audit each and pass the correct strictness for the current function. The pattern `self.lexer.reserved_words_strict` is no longer accurate when the function is sloppy; replace with `self.is_strict` (or equivalent field on CompilerContext). Sites:
   - `functions.c3:182,398,2245,2840,4255,5039` (function names + params)
   - `tokens.c3:160` (universal binding identifier gate)
   - `expressions.c3:443,1854,1933,2117` (assignment to eval/arguments)
   - `destructuring.c3:487,978,1046,1115` (destructuring targets)
   - `statements.c3:1948,6111,6617,6704` (declarations + imports + exports + catch)
   - `functions.c3:3169,3817,4515` (`seen_params.strict` plumbing)
6. **`src/compiler/expressions.c3:3844-3845`** — octal literal reject: gate on `self.is_strict`.
7. **`src/compiler/expressions.c3:3874-3875`** — octal-escape-in-string reject: gate on `self.is_strict`.
8. **`src/compiler/expressions.c3:1816-1826`** — `delete <id>` reject: gate on `self.is_strict`. Sloppy: emit a `DELVAR` opcode (already exists at `bytecode.c3:327`) and let the VM handle it. Phase 1 may stub the DELVAR handler to throw; Phase 2 implements semantics.
9. **`src/compiler/expressions.c3:5593-5596`** — duplicate `__proto__`: gate on `self.is_strict`.
10. **`src/compiler/statements.c3:3322-3330`** — `for (var x = 1 in y)` reject (via `forbid_in`): gate on `self.is_strict`. Sloppy: parse as `var x = 1; for (x in y) { ... }`. Per plan 035, plan 054 follow-up notes this as a separate work item.
11. **`src/compiler/statements.c3:756-826`** — `parse_directives()`. Currently `"use strict"` clears `subst_global_this` (line 815-817). Add: also sets `self.is_strict = true` and `func.flags.is_strict = true`. Update the post-body raise at line 1807 (`if (self.saw_use_strict) self.lexer.set_strict(true);`) accordingly.
12. **`src/compiler/statements.c3:4776-4808`** — catch parameter restricted-name check: gate on `self.is_strict`.
13. **Verification**: `just build`, then `just test262 --suite language` to get the parser-only delta. Also un-skip the 8 category-A `SKIP_FILES` entries in `scripts/run_test262.py`:
    - `built-ins/Function/15.3.2.1-11-{1,5,9-s}.js`
    - `built-ins/Function/15.3.2.1-11-{2,6,8}-s.js` (also category-A but `onlyStrict`-flagged — they'll still CE, leave skipped)
    - `built-ins/Function/length/S15.3.5.1_A{1,2,3,4}_T3.js`
    - `language/eval-code/indirect/always-non-strict.js`
    - `language/comments/hashbang/use-strict.js`
    Then run the suite; record the pass count delta.

**Expected yield (Phase 1)**: the 8 category-A tests un-skip and start to pass; a slice of noStrict tests pass at parse time but fail at runtime; the rest stay in their pre-existing failure mode. Net positive but small.

### Phase 2 — Cheap runtime semantics

Goal: the runtime behaviors that are localized to one or two opcode handlers, with no data-structure changes.

1. **`this` substitution and primitive `this` coercion** — flip the default. `FuncFlags.subst_global_this` (line 1339-1349) currently means "substitute on dynamic Function bodies only." In dual mode, the right knob is `FuncFlags.is_strict`:
   - When `is_strict` is true: no substitution, no primitive coercion.
   - When `is_strict` is false and not an arrow: substitute undefined/null to globalThis, ToObject-wrap primitives.
   - At every `subst_global_this()` site (`vm_calls.c3:1058,1073,1963,2153`, `vm_execute.c3:754,779`), replace with `!target.is_strict() && !target.is_arrow()`. Keep `subst_global_this` for the dynamic-Function case where `"use strict"` was *not* in the body — there it's still needed (an empty body `Function('')` is non-strict even though constructed via `Function()`). Actually — once `is_strict` is per-function, just check `!is_strict`. Delete `subst_global_this` entirely.
   - ToObject-wrap primitives in `vm_calls.c3`/`vm_execute.c3` `this_binding` paths. Add a helper `to_object_for_this_call(TVal)` that wraps number/string/boolean/symbol primitives.
2. **Implicit globals** — `vm_execute.c3:5237-5247` (`PUTGLOBAL`) and `:5554-5564` (`PUTVAR_ASSIGN`). When the binding lookup misses and the function is sloppy, fall through to `env::env_put(global_env, key, value)` to create a configurable property on the global object instead of throwing. Today the throw is unconditional.
3. **DELPROP silent failure** — `vm_property.c3:2614-2736`. Four sites throw on `false`; make them conditional on the calling activation's strictness. Read `act.flags.is_strict` (already on the activation flags by Phase 0). Sloppy: return `false` from DELPROP; strict: throw as today.
4. **DELVAR (delete unqualified identifier)** — Phase 1 emits this; implement it. Walk the variable environment chain; if `eval`-style direct-eval was used, the chain is the caller's; otherwise it's the function's var_env + lex_env. Sloppy semantics: return `true` if unresolvable; return `false` if a `var`/`function` binding (Annex B.3.1); return `false` if non-configurable (per the property check). Strict semantics: throw ReferenceError on unresolvable (today's behavior — but Phase 1 stubs throw for sloppy too; need to gate on activation strictness).
5. **Poison pill, sloppy functions only** — `vm_property.c3:169-177` and call sites (`502-509, 511-524, 754-762, 1128-1138, 136-141, 1650-1662`). For `arguments.callee` / `caller`: when the activation is sloppy, return `null` (sloppy default) or the underlying function (if non-strict frame's own arguments). For `f.caller`/`f.arguments`: when the target function is sloppy, return `null`. The poison pill stays on strict frames.
6. **Octal escape in non-directive strings** — `lexer.c3:1419,1497`. With `set_strict()` now flipping `strict_mode`, this works automatically once the parser threads `is_strict` into the lexer via `set_strict(false)`. Verify the directive-prologue check at `statements.c3:769-771` still runs in sloppy bodies (sloppy allows octal escapes even in directive-position strings per Annex B; this is correct).

**Expected yield (Phase 2)**: most of the `staging/sm/strict/` suite starts passing (44+ tests); the F1/F2/F2b/F3 SKIP_FILES entries in `scripts/run_test262.py` can be un-skipped; a large fraction of noStrict tests with sloppy `this` or implicit-global assertions pass.

### Phase 3 — Medium-difficulty runtime semantics

1. **Two-way `arguments`↔parameter mapping** — `vm_calls.c3:41-77` (`finish_arguments_object`). Add a sloppy variant that creates a `[[ParameterMap]]` (parallel array indexed by parameter ordinal, holding the parameter's storage slot). Mutations to `arguments[i]` write back to the parameter; mutations to the parameter write back to `arguments[i]`. Need to identify the parameter's storage location at call time (locals register, env, or captured). Cheap implementation: store the parameters on a register-resident block and have `arguments[i]` be a getter/setter that round-trips through the block. Duktape and QuickJS both have prior art.
2. **Function declarations in blocks (Annex B.3.3 sloppy-hoist)** — `functions.c3:2164-2168` and `statements.c3:1331`. In sloppy mode, when a function declaration appears inside a block, also create a `var`-like binding in the enclosing function scope, initialized once at function-entry time (the "Annex B B.3.3 the second binding" rule).
3. **Octal literal value parsing** — `lexer.c3:1266-1281`. Currently `0777` parses as 777. In sloppy, parse as 511 (octal). Verify against test262 expectations before implementing; some tests check the parse-time error, others check the value.
4. **`Function.prototype.call/apply` sloppy `this` coercion** — `builtins/function.c3:283-474`. When the callee is sloppy and `thisArg` is a primitive, ToObject-wrap. When `thisArg` is undefined/null, substitute globalThis. The comment at line 303-305 explicitly calls this out as a future-work item.
5. **catch parameter restricted names** — already Phase 1; verify runtime.

**Expected yield (Phase 3)**: remaining `arguments`/`__proto__`/`for-in initializer` noStrict tests pass. F1 family fully un-skippable.

### Phase 4 — `with` statement

This is the biggest single feature. Plan 035 explicitly removed it. Restoring it requires:

1. **Parser** — `src/compiler/statements.c3:1998-2017` (per plan 035's record of the original `with_statement` parser; ~20 lines). Reads the expression, emits `WITH_START <expr_reg>`, parses the body, emits `WITH_END`.
2. **Bytecode** — `WITH_START` and `WITH_END` opcodes already exist as enums (`bytecode.c3:292,295`) per plan 035's removal. Format arms at `:500,535`, dump names at `:1112,1113`.
3. **EnvRecord** — `src/env.c3`. Add `is_with` field. `env_create_with_object(Object* o)` allocates an env whose lookups walk the object's prototype chain. Plumb `is_with` into `env_has`/`env_get`/`env_put`. Eight sites per plan 035 (`env.c3:138,186,206,236,256` + comments).
4. **VM** — `WITH_START`/`WITH_END` opcode handlers (`vm.c3:8406,8482` per plan 035, line numbers drifted). `WITH_START` evaluates the expression, pushes a new env on the env chain, points the var_env to it for the duration of the body. `WITH_END` pops. The body's RESOLVEVAR/PUTVAR/PUTGLOBAL walk the chain as normal; the with-env intercepts lookups.
5. **Sloppy-only** — `with` is always sloppy. The parser emits `WITH_START` only in non-strict context. The runtime can also guard, but it's redundant.

**Expected yield (Phase 4)**: 181 `language/statements/with/` tests un-skippable. `staging/sm/strict/B.1.1.js` and `12.10.1.js` start passing.

### Phase 5 — Test runner + docs

1. **`scripts/run_test262.py`**:
   - Remove the `FLAG_NOSTRICT_RE` skip (line 498) entirely. noStrict tests now run.
   - Remove the 19 strict-only entries from `SKIP_FILES` (already done incrementally per phase).
   - Remove `language/statements/with` from `SKIP_DIRS` (Phase 4 milestone).
   - Simplify the comment block at lines 152-460 that documents strict-only skip reasons — most of it becomes historical.
   - Update `NOSTRICT_RUN_GLOBS` exemptions — they're already covered by the now-empty filter, so the exemption can be removed.
2. **`cli/test262_runner.c3`** — currently prepends `"use strict"` for `onlyStrict` tests (lines 457-482). Verify this still works with the per-function `is_strict` flag. Likely needs no change.
3. **`AGENTS.md`** — replace the "Strict-Only Mode" section with a "Strict and Sloppy Modes" section. Update the guardrails list. `subst_global_this` no longer exists (replaced by `!is_strict` checks); document `is_strict` flag. `"use strict"` is no longer a no-op.
4. **`docs/architecture.md`** — describe the dual-mode compiler + VM. Update any claims about strict-only enforcement.
5. **`docs/engine-scope.md`** — update scope description.
6. **`FEATURES.md`** — mark sloppy mode features as supported.
7. **`README.md`** — note that sloppy mode is now supported.

---

## 4. File-by-File Change List

| File | Phase | Change volume | Risk |
|---|---|---|---|
| `src/bytecode.c3` | 0 | 1 bit added to `FuncFlags`, 1 accessor macro | Low — additive |
| `src/compiler/context.c3` | 0, 2 | 2 fields, 2 inits, 1 stamp in `finish()` | Low |
| `src/compiler/entry.c3` | 0, 1 | 3 sites flip `is_strict` based on script/module/dynamic | Low–Med (script default changes) |
| `src/compiler/statements.c3` | 1, 4 | guard 8 rejections + restore `with_statement` parser (~20 lines) | Medium |
| `src/compiler/functions.c3` | 1 | guard duplicate-param check; replace `reserved_words_strict` with `is_strict` at 6 sites | Low |
| `src/compiler/expressions.c3` | 1, 2 | guard 4 rejections; replace `reserved_words_strict` with `is_strict` at 4 sites; emit DELVAR | Low–Med |
| `src/compiler/destructuring.c3` | 1 | replace `reserved_words_strict` with `is_strict` at 4 sites | Low |
| `src/compiler/tokens.c3` | 1 | replace `reserved_words_strict` with `is_strict` at 1 site | Low |
| `src/lexer.c3` | 1, 3 | `set_strict()` flips `strict_mode` too; `scan_number` parses octal values in sloppy; `scan_string` follows `strict_mode` | Medium — numeric parsing has subtle test cases |
| `src/vm/vm_calls.c3` | 2, 3 | 6 sites drop `subst_global_this` for `!is_strict`; primitive `this` coercion; two-way `arguments` mapping | Medium — hot path |
| `src/vm/vm_execute.c3` | 2 | 6 sites (PUTGLOBAL/PUTVAR_ASSIGN) handle implicit globals | Medium — global path |
| `src/vm/vm_property.c3` | 2, 3 | 4 DELPROP sites make failure silent in sloppy; poison pill sloppy-aware at 6+ sites | Medium — hot path |
| `src/env.c3` | 4 | `is_with` field + 8 lookup sites + `env_create_with_object` | High — every env lookup |
| `src/builtins/function.c3` | 3 | `call`/`apply` sloppy `this` coercion — 2 functions, ~10 lines | Low |
| `src/builtins/object.c3` | 3 | (already has Annex B methods, no change) | None |
| `scripts/run_test262.py` | 1, 2, 4, 5 | remove `FLAG_NOSTRICT_RE`, prune `SKIP_FILES`, drop `language/statements/with` from `SKIP_DIRS` | None |
| `cli/test262_runner.c3` | 5 | verify onlyStrict prepend still works (likely no change) | None |
| `AGENTS.md` | 5 | rewrite "Strict-Only Mode" section | None (docs) |
| `docs/architecture.md` | 5 | update architecture description | None (docs) |
| `docs/engine-scope.md` | 5 | update scope | None (docs) |
| `FEATURES.md` | 5 | mark features supported | None (docs) |
| `README.md` | 5 | mention sloppy mode | None (docs) |

**Estimated total**: ~700 lines of new/conditional code, ~50 lines of documentation. The `FuncFlags` grows by 1 bit; activations get 1 more byte if we add a runtime-side mirror (or stay 0-byte if we use the existing `subst_global_this` bit repurposed).

---

## 5. Test262 Strategy

### Phase-by-phase expectations

| Phase | noStrict un-skipped | category-A SKIP_FILES un-skipped | category-B SKIP_FILES un-skipped | `language/statements/with/` un-skipped | Expected pass-rate delta |
|---|---|---|---|---|---|
| 0 | 0 | 0 | 0 | 0 | **0** (no behavior change) |
| 1 | 0 (still skip in runner) | **8** | 0 | 0 | small positive (~50–100 tests; some of those 8 + noStrict tests whose only assertion is "should parse") |
| 2 | 0 | 8 | **5** (F1, F2, F2b, indirect-eval) | 0 | large positive (~300–600 tests; `staging/sm/strict/` suite mostly passes; many noStrict tests with sloppy-`this` or implicit-global assertions pass even with runner skip in place once those tests are runnable) |
| 3 | un-skip all (FLAG_NOSTRICT_RE removed) | 8 | **+ Annex B / dup-`__proto__` / for-in** | 0 | very large positive (~1,500–2,000 tests) |
| 4 | — | 8 | all | **181** | large positive (~150 tests; `with` semantics) |
| 5 | — | 8 | all | 181 | numbers stabilize |

The runner-side `FLAG_NOSTRICT_RE` removal is gated on Phase 3, not Phase 1 — by Phase 3 the parser and most of the runtime semantics are in place, so un-skipped noStrict tests have a real chance of passing. Doing it in Phase 1 would generate a flood of confusing CEs.

### Targeted test runs per phase

Each phase lands with `just test262 --dir language/statements/with` (Phase 4), `--suite staging --suite language` (Phases 2-3), and the relevant category-A/B SKIP_FILES individually via `python3 scripts/run_test262.py --single <path>`. **Not a full `just test262`** — too noisy.

---

## 6. Risk Assessment

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Per-script strictness default change breaks the many strict-by-default test262 tests | High | High | Test262 default-run tests are spec-required to pass in **both** modes; sloppy support is by spec. Verify by re-running the suite after Phase 1 and comparing baseline pass count — should not regress. |
| `FuncFlags` bitfield addition breaks dump_function / GC | Low | High | Phase 0 lands the flag with no behavior change; run rosetta + a full sweep before Phase 1. |
| Legacy-octal value parsing disagrees with V8/SpiderMonkey | Medium | Medium | Check test262 `built-ins/Number/0o*` and `language/literals/numeric/octal*` fixtures for the exact semantics. Duktape source is in `duktape/` and QuickJS in `quickjs/` — peek at their `scan_number`. |
| Implicit-global creation path interacts badly with eval | Medium | High | Verify against `language/eval-code/indirect/*` and `language/global-code/*`. The existing global-declaration-instantiation work in plan 054 may need coordination. |
| Two-way arguments mapping costs performance | High | Low | Hot-path regression. Acceptable for first cut; optimization is a follow-up. The mapped args object only matters for sloppy functions, and sloppy functions are typically legacy code where perf is less critical. |
| `with` semantics require deep env-chain changes | Medium | High | Plan 035 explicitly removed `is_with`; the prior implementation is recoverable but may have rotted. Verify by re-reading the original `env.c3` git history before Phase 4. |
| Test262 harness itself fails to run in sloppy mode | Low | High | Run the harness self-tests once sloppy mode is on; the harness files are mostly strict-flagged and should be unaffected. |
| `delete x` semantics split makes the existing PUTPROP check diverge from the new DELVAR check | Medium | Medium | Phase 1 emits DELVAR as a stub that throws; Phase 2 implements. Land DELVAR behind the same activation-strictness flag as DELPROP for symmetry. |

---

## 7. Success Criteria

- [ ] `FuncFlags.is_strict` exists and is propagated; Phase 0 rosetta pass rate unchanged.
- [ ] Parser accepts all 8 categories of currently-rejected sloppy syntax in sloppy context.
- [ ] Parser still rejects all 8 categories in strict context (regression guard).
- [ ] `just rosetta` still passes 22+ language features.
- [ ] `just test262 --suite staging` passes the 44 `staging/sm/strict/*.js` tests with `testLenientAndStrict` assertions.
- [ ] `just test262 --dir language/statements/with` passes at least 150/181 tests (Annex B `with` quirks may leave some).
- [ ] `FLAG_NOSTRICT_RE` removed; all 2,685 noStrict tests runnable.
- [ ] Test262 pass rate higher than the strict-only baseline by >1,500 tests.
- [ ] No regression in any previously-passing test262 test.
- [ ] AGENTS.md, architecture.md, engine-scope.md, FEATURES.md, README.md updated.

---

## 8. Execution Order

1. Phase 0 (infrastructure) — land on a build flag if necessary for safety.
2. Phase 1 (parser) — first user-visible payoff, low risk per change. Un-skip 8 category-A SKIP_FILES. Run `language` suite, record delta.
3. Phase 2 (cheap runtime) — un-skip 5 category-B SKIP_FILES (F1, F2, F2b, indirect-eval). Run `staging/sm/strict/` suite, expect ~44 tests to flip from CE/skipped to PASS.
4. Phase 3 (medium runtime) — un-skip the rest of category-B SKIP_FILES. Remove `FLAG_NOSTRICT_RE`. Run full `just test262`. Big delta.
5. Phase 4 (`with`) — biggest single piece. Un-skip `language/statements/with/`. Verify `staging/sm/strict/12.10.1.js`.
6. Phase 5 (docs + final cleanup). Full `just test262` re-baseline.

---

## 9. Key File References (verified 2026-09-03)

| Concern | File:Line |
|---|---|
| `FuncFlags` bitstruct (no `is_strict` yet) | `src/bytecode.c3:1284-1405` |
| `subst_global_this` flag | `src/bytecode.c3:1339-1349` |
| `subst_global_this` accessor | `src/bytecode.c3:1655-1657` |
| `CompilerContext.is_strict` removed | (was `context.c3:223` per plan 035) |
| `CompilerContext.subst_global_this` | `src/compiler/context.c3:791-793` |
| `set_strict()` | `src/lexer.c3:2610-2611` |
| `Lexer.strict_mode` (pinned) | `src/lexer.c3:462` |
| `Lexer.reserved_words_strict` | `src/lexer.c3:475` |
| `parse_directives()` | `src/compiler/statements.c3:756-826` |
| `"use strict"` clears `subst_global_this` | `src/compiler/statements.c3:814-818` |
| `with` parser-rejected | `src/compiler/statements.c3:374-375` |
| `with_statement` original (~20 lines) | (was `statements.c3:1998-2017` per plan 035) |
| `WITH_START`/`WITH_END` opcode enums | `src/bytecode.c3:292,295` |
| `WITH_START`/`WITH_END` format/dump | `src/bytecode.c3:500,535,1112,1113` |
| `WITH_START`/`WITH_END` VM handlers removed | (were `vm.c3:8406,8482` per plan 035; line numbers have drifted) |
| `is_with` env field removed | (was `env.c3:79` per plan 035) |
| `env_create_with_object` removed | (was `env.c3:132` per plan 035) |
| `SeenParams.declare` duplicate check | `src/compiler/functions.c3:181-191` |
| `is_restricted_name` (param: `strict`) | `src/compiler/statements.c3:662-733` |
| 26 `is_restricted_name` call sites | `functions.c3:182,398,2245,2840,4255,5039,3169,3817,4515`; `tokens.c3:160`; `expressions.c3:443,1854,1933,2117`; `destructuring.c3:487,978,1046,1115`; `statements.c3:1948,6111,6617,6704` |
| Octal literal reject | `src/compiler/expressions.c3:3844-3845` |
| Octal escape reject in strings | `src/compiler/expressions.c3:3874-3875` |
| Octal lex sites | `src/lexer.c3:1180-1195,1416-1421,1493-1501` |
| Octal escape in directive prologue | `src/compiler/statements.c3:769-771` |
| Delete-unqualified reject | `src/compiler/expressions.c3:1816-1826` |
| Duplicate `__proto__` reject | `src/compiler/expressions.c3:5593-5596` |
| For-in initializer reject | `src/compiler/statements.c3:3322-3330` |
| `subst_global_this` runtime reads | `src/vm/vm_calls.c3:1058,1073,1963,2153`; `src/vm/vm_execute.c3:754,779` |
| `arguments.callee`/`caller` poison pill | `src/vm/vm_property.c3:169-177` (helper) and sites `502-509,511-524,754-772,1128-1138,136-141,1650-1662` |
| `finish_arguments_object` (always strict) | `src/vm/vm_calls.c3:41-77,1098-1116,2018-2034` |
| DELPROP strict-only throws | `src/vm/vm_property.c3:2614-2736` |
| Implicit-globals always-throw | `src/vm/vm_execute.c3:5237-5247,5554-5564` |
| `Function.prototype.call` strict comment | `src/builtins/function.c3:303-305` |
| `Function.prototype.call` body | `src/builtins/function.c3:283-409` |
| `Function.prototype.apply` body | `src/builtins/function.c3:411-474` |
| Annex B Object.prototype methods (already installed) | `src/builtins/object.c3:5571-5591,5106-5209`; `src/builtins/core.c3:318-321` |
| `FLAG_NOSTRICT_RE` skip | `scripts/run_test262.py:498-500` |
| `SKIP_DIRS` strict-only entry | `scripts/run_test262.py:172` (`language/statements/with`) |
| 8 category-A `SKIP_FILES` | `scripts/run_test262.py:273-279,293,299,367-369` |
| 11 category-B `SKIP_FILES` | `scripts/run_test262.py:325-328,338-339,439-459` |
| `cli/test262_runner.c3` onlyStrict handling | `cli/test262_runner.c3:457-482` |
| `seen_use_strict` post-raise | `src/compiler/statements.c3:1807` |
| Catch parameter restricted-name check | `src/compiler/statements.c3:4776-4808` |
| `non_strict_source` plumbing | `src/compiler/entry.c3:29-60` |
| `compile_function` (dynamic) | `src/compiler/entry.c3:371-403` |
| `compile_function_kind` (dynamic generator/async) | `src/compiler/entry.c3:407-431` |
| `compile_eval` (eval strictness) | `src/compiler/entry.c3:186-364` |
| `compile_module` (always strict) | `src/compiler/entry.c3:438-507` |
| Plan 035 (prior strict-only migration) | `plans/035-enforce-strict-mode.md` |
| Plan 056 (fixed-width BigInt, int128) | `plans/056-bigint.md` |
| Docs to update | `AGENTS.md`, `docs/architecture.md`, `docs/engine-scope.md`, `FEATURES.md`, `README.md` |

---

## 10. Open Questions

1. **Should scripts default to sloppy or strict?** ES2015+ defaults scripts to sloppy (modules are strict, scripts are sloppy unless `"use strict"` is present). The strict-only engine flipped this. Going back to sloppy-by-default is the spec-correct move but is a behavioral change for any existing user. Recommend: sloppy-by-default, matching ES2024.
2. **What about `"use strict"` in non-simple-parameter functions?** Strict-mode says SyntaxError; sloppy says "fine, ignore the directive per sloppy semantics." Phase 1 should reject `"use strict"` in non-simple-param sloppy functions (current behavior at `statements.c3:808-809` is correct), but the rejection message should be clearer about why.
3. **Should implicit globals be configurable:true or writable:true?** Spec says configurable:true, writable:true, enumerable:true. The engine's `env_put` on global_env should produce this property descriptor. Verify against test262's `language/global-code/` corpus.
4. **Two-way `arguments` mapping: per-function or per-binding?** Spec says per-binding. The simplest implementation is per-binding (store parameter values in a small array indexed by ordinal; `arguments[i]` becomes a getter that reads/writes that array). Per-function mapping (a single "are we in sloppy mode with simple params?" bit) is wrong because parameters with defaults/rest/destructuring in sloppy mode don't get mapped.
5. **Should `with` be Phase 4 or first?** Plan 035's biggest deletion; arguably the most spec-divergent feature; arguably the most user-noticed. But: low test262 yield (181 tests), high implementation cost, isolated from everything else. Recommend: leave for last so prior phases stabilize the flag plumbing.
6. **What about Annex B legacy features beyond `with`?** `Date.prototype.toJSON` Annex B quirks, `String.prototype.{substr,sup,sub,strike,small,big,bold,fixed,fontcolor,fontsize,blink,italics,anchor,link}` HTML wrappers, `Object.prototype.__proto__` accessors — these are spec-required even in strict code and may or may not be implemented. Audit separately; out of scope here.
7. **Does the test262 runner need to change for `--module`?** Some `staging/sm/strict/*.js` tests may need module-mode execution. Check after Phase 2 whether any fail due to script vs module expectations.

---

## 11. Notes for the Implementer

- Plan 035 is the inverse. Read it before starting; the deletion list there is the worklist for re-implementation.
- The Duktape source under `duktape/` and QuickJS source under `quickjs/` are reference implementations of sloppy mode. When in doubt about a behavior, peek at both. QuickJS especially — it's the engine whose `js_regexp_exec` semantics the regexp plan already matches.
- Land each phase as its own commit. The flag in Phase 0 must be observable as no-op before Phase 1 changes anything visible.
- Use `python3 scripts/run_test262.py --single <path>` for tight debug loops, not full sweeps. Cluster failures with `awk -F'\t' '$1=="FAIL"{print $2}' results.tsv | xargs -n1 dirname | sort | uniq -c | sort -rn`.
- **Do not unskip the BigInt entries** (`built-ins/BigInt/asIntN/arithmetic.js` etc., `built-ins/Map/valid-keys.js`, `built-ins/Set/valid-values.js`). BigInt is implemented as fixed-width int128 (plan 056); these tests contain literals >2^127 that legitimately don't fit. Same for `intl402`, `annexB`, `ShadowRealm`, multi-agent, cross-realm — none of these are strict-mode-related.

---

## 12. Success Criteria

- [ ] `FuncFlags.is_strict` plumbed end-to-end; default for ordinary scripts = false (sloppy); default for modules = true (strict); default for dynamic Function bodies = false; `"use strict"` raises it to true.
- [ ] All 8 parser-rejection categories in §2 conditional on `is_strict`.
- [ ] All 26 `reserved_words_strict` call sites use the per-function strictness.
- [ ] `with`, two-way `arguments`, implicit globals, sloppy `this` substitution, octal literals, octal escapes, `delete <id>`, duplicate params, duplicate `__proto__`, `for-in` initializer, catch restricted names all work in sloppy context.
- [ ] All previously-strict-only SKIP_FILES entries un-skipped.
- [ ] `language/statements/with/` un-skipped; ≥150/181 tests pass.
- [ ] `staging/sm/strict/` ≥44/51 tests pass.
- [ ] `FLAG_NOSTRICT_RE` removed; full test262 pass count ≥ strict-only baseline + 1,500.
- [ ] Rosetta suite 100%.
- [ ] AGENTS.md, architecture.md, engine-scope.md, FEATURES.md, README.md updated.
