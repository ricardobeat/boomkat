# Duktape C3 — Backlog

`[ ]` TODO · `[>]` IN PROGRESS · `[x]` DONE.

Details for the open items: `plans/062-core-language-coverage.md`.

## test262 coverage

- [x] Add the orphaned core-language dirs to `PHASES` (phases 2, 7, 24)

## Core language bugs

- [x] **Property writes silently fail once the shape table is exhausted.** After ~65k unique property-key transitions *process-wide*, `o[k] = v` reports success and `o[k]` immediately reads back the wrong value, with no error. Plain JS reproducer on `./out/duktape_c3`: `var o={}; for (var i=0;i<70000;i++){ var k="k"+i; o[k]=i; if (o[k]!==i) break; }` → misses at **65535**. Root cause: `Shape.shape_id` is a `ushort`, so `Heap.alloc_shape_slot` (heap.c3:1112) returns `SHAPE_NONE` past 65534; both call sites (hobject.c3:1143 and :1577) then `shape_free` the new shape and keep the old one, so `put_prop` writes the value and returns `true` while the shape never records the key — `find_prop_idx` returns -1 right after a "successful" store, and `delete_prop` can never find it. The budget is **global, not per object**: two objects with distinct 40k key sets fail at iteration 0 of the second, while two objects sharing a transition chain are fine. `Map` is unaffected and is the workaround for large dynamic key sets. Should fail loudly (throw) rather than corrupt silently, even if the 16-bit id stays. Found while stress-testing the Rust binding; pre-existing, not caused by host functions. Verified fixed on current main: the 70k-key loop runs to completion.

- [x] **Arrow parameters clobbered by a void-context call in the body, eval path only.** `((x)=>{Math.max(1,2); return x+100})(7)` yields **102 instead of 107**, and `((x,y)=>{Math.max(1,2); return x+y})(3,4)` yields 6 instead of 7. Silent wrong answer, no error. Reproduces through `eval()` and `jse_eval` (both `compile_eval`) but NOT through a top-level script (`compile`), so every C-ABI embedder hits it while the CLI does not. Controls that work: no call in the body; the same body in a `function` expression; binding the call's result (`let q = Math.max(1,2)`). That last one localises it to register allocation for a **discarded** call result overlapping the arrow's parameter registers in eval context. Pre-existing — reproduced at `51c4ccaf`, before host-function work. Found independently by the Python and Ruby binding agents. Verified fixed on current main: the two eval reproducers return 107 and 7.

- [x] `for (let y in/of ...)` falsely rejected as duplicate when an enclosing function has `var y` (the head's lexical scope must not conflict with function-level var names; no test262 coverage — gate is green)
- [x] `return` inside `finally` in an async function raises a VM error and allocates without bound
- [x] `await` as a plain identifier rejected as an invalid assignment target
- [x] `for-in`/`for-of` head does not accept a bare comma expression
- [x] `for-in` head lexical bindings are not in a TDZ while the head expression evaluates
- [x] `for-in` completion value starts from the preceding statement instead of `undefined`
- [x] `for-in` emits a prototype property shadowed by a non-enumerable own property
- [x] `let`/`const` self-reference TDZ missed for a block nested in a function body
- [x] Assignment to a `const` bound in a `for-in`/`for-of` body must throw TypeError
- [x] `delete (obj.prop)` rejected as an unqualified identifier
- [x] `[[Construct]]` with a non-object `.prototype` must fall back to `%Object.prototype%`
- [x] `for-in` yields keys deleted during enumeration (`S12.6.4_A7_T2` — keys are pre-collected)
- [x] `[no LineTerminator here]` after `async` not enforced; escaped `async` treated as the keyword
- [x] `await` on a non-promise thenable fails under the harness — reproduce before fixing
- [x] Skip-list the two `bigint-and-number-extremes` tests (256-bit literals, fixed-width int128 by design)

## Compiler / codegen correctness (session 302)

Four silent wrong-value or spec bugs, all of the same shape: an invariant hand-maintained in N places, wrong in the copies that omit it.

- [x] Ternary as the right operand of a binary op took the false branch (`5 + (true?10:20)` → 25). Two jump-blind peepholes; three fusion passes already carried a jump-target bitset and were correct, the two without one were the two that were buggy — `073aa16b`
- [x] Bare truthiness test on a loop counter read a stale value (`for(…){if(j)…}` → "333"). The `&&`/`||` bridge correction matched on opcode and offset sign alone, never register identity. Predates `69e65f84` — `4f486724`
- [x] `(u=45)>0` emitted the comparison into `u`'s own home register; `hoist_decls` swallowed a function's closing brace and hoisted a sibling's locals — `b0fdc49c`
- [x] Arrow functions skip duplicate-param and restricted-name checks — `(a, a) => a` now correctly throws SyntaxError (verified session 303; the entry was stale)
- [x] Audit the remaining fusions (`run_move_gg_fusion`, `run_jmp_lt_g_fusion`) for positional-only reasoning. Both were already clean: each builds the shared jump-target bitset, guards the trailing word, matches the scratch register by identity, and `run_jmp_lt_g_fusion` checks liveness on the taken-branch path as well as the fall-through. A 167-case differential against qjs plus `--no-optimize` (108 files fusing `JMP_LT_G`, 9 fusing `MOVE_GG`) found no wrong answer, and 113 fused branch targets were checked against the target the unfused pair would have used. The audit did surface three things worth fixing, below
- [x] `JMP_LT_G` had no golden and no behavioural test, so its entry in the golden runner's `FUSED_OPCODES` was vacuous: `--check-noop` was asserting the absence of an opcode no golden produced. Added `test/golden_bytecode/jmp_lt_g` and `test/codegen_jmp_lt_g.js`, both mutation-checked against a +1 offset change
- [x] `build_jump_targets` did not decode `JMP_LT_G`, so its branch target was invisible to the bitset. Unreachable inside `finish()` (every consumer runs before `JMP_LT_G` is installed) but `peephole_scan` runs on final code, where a missed target could let the `GETPROPC2` fusion turn a branch destination into a data word. Instrumenting the compiler over all 51,834 non-staging test262 files found 0 such overlaps against 1,135,151 fusions, so this was latent rather than live; the arm is now present
- [x] `moveelim_mark_jump_targets_and_try_regions` carried a 41-line byte-identical copy of `build_jump_targets`'s branch switch. Now delegates to it and only adds the try-region marking. Verified a no-op: disassembly is byte-identical across 866 files

## Host / console

- [x] **Structured object rendering for console** — `console.log`, `console.dir` and the `%o`/`%O` specifiers now route through `src/builtins/inspect.c3`, matched byte-for-byte against captured reference output: plain objects and arrays, holes, Map/Set, functions and classes, errors, boxed primitives, null-prototype objects, TypedArrays, symbols, BigInt, `-0`, `[Circular *1]` under a `<ref *1>` marker, the depth-2 limit, and the line-breaking and column-grouping rules. Getters render as `[Getter]` and are never invoked. `test/console_format/` grew from 59 to 5796 lines of captured expectation, the bulk of it a generated shape x kind x size matrix. Remaining deviation: `%o` does not imply `showHidden`/depth-4, so it renders as `%O` rather than listing `[length]`/`[prototype]`
- [x] `Date.prototype.toLocaleString` ignores its options bag and `timeZone`, returning `toString()` (`src/builtins/date.c3:903`). ES5 §15.9.5.5 permits an implementation-defined result, so this is conformant today and only a gap against ECMA-402 — listed here rather than under Out of scope because the `intl402` exclusion covers the test suite, not the method's behavior. Cost the verbatim Rosetta suite its `Date_format` sample. Fixed: with a locales or options argument it now resolves the bag per ECMA-402 §11.1.2 (`src/builtins/date.c3:999`), and `timeZone` is honored; the no-argument path is still `toString()`.

## Test coverage gaps

- [x] **`$DONOTEVALUATE` parse-negative tests are no longer skipped wholesale** — `scripts/run_test262.py:851` compiles `negative: phase: parse` tests and scores rejection as a pass. Un-skipping them surfaced 35 real failures (all cleared in session 303). Only `phase: resolution` module-linking negatives remain skipped, correctly: they need the loader, not the parser
- [x] Golden bytecode covers control-flow-carrying expressions — `test/golden_bytecode/` holds ternary (6 cases: nested, both operands, left/right operand, binary arms, compound assign), `&&`/`||`/`??` (4) and optional chaining, each carrying the behavioural pair in its header comment (e.g. `ternary_nested.js` names `test/codegen_control_flow_expr.js`)
- [x] The two general codegen bugs from `b0fdc49c` have dedicated tests — `test/codegen_assign_clobber.js` (36 assertions) and `test/codegen_hoist_brace_swallow.js` (10), no longer resting on the `t11_colord` bundle
- [x] Engine tests only exercised code we wrote — `test/rosetta-verbatim/` now runs 41 unmodified rosettacode.org samples, cross-checked against qjs and mutation-tested (`just rosetta`). Roughly half the candidate tasks are unusable as verbatim samples; `test/rosetta-verbatim/README.md` records each exclusion reason

## Parser over-rejection (valid code refused)

Found while clearing the parse-negative clusters in session 303. None are
test262-visible — every phase reports 0 fail / 0 unexpected-CE — so these need
their own regression tests or they will silently persist.

- [x] **`await` as an arrow parameter outside async** — `await => 1`, `(await) => 1`, `(a, await) => a` and `(...await) => …` all bind a parameter named `await` in script code and were rejected. ArrowParameters inherit the enclosing `[Await]`, so the reservation is read off the enclosing context, not the arrow's own flag. The head scan tested for `IDENTIFIER` directly, which no `await` token ever is, so the head never registered as an arrow. Every async-context reservation still rejects

  ~~**ClassHeritage rejects valid non-arrow forms**~~ — **withdrawn, this was never a bug.** `class C extends (() => {}) {}`, `extends []`, `extends ({})`, `extends 1` and `` extends `t` `` all throw `TypeError: class extends value is not a constructor or null` — a *runtime* error, and exactly what node does. The valid cases (`extends null`, `extends (B)`) evaluate fine in both. The original entry came from probing with `node --check`, which only parses and never evaluates the class, so a correct runtime TypeError read as a parse over-rejection. **Methodology note: `node --check` is the wrong oracle for anything whose error is thrown at evaluation time — run node for real.**

## Latent runtime bugs

- [x] **A warmed variable IC serves a stale value after `eval` redeclares the global** — `var g1=1; function r(){return g1}; r();r();r(); eval("var g1 = 2;"); r()` returns `1`; node returns `2`. Not a bug: the engine is strict-only, so a direct eval is always strict and its `var` declarations are confined to the eval's fresh declarative environment (ES2015 §18.2.1.1 step 18.f; `src/builtins/global.c3:1006`). A strict-mode node reproducer returns `1` as well; the entry compared against sloppy node, whose eval `var` leaks by design. Assignment through eval (`eval("g1 = 2")`) does write through to the outer binding, and that path works. No IC staleness involved, the eval body never touches the warmed slot. Verified on `main`: direct read, warmed read, and a fresh function all see the unchanged `1`, matching strict node on global and function scope

- [x] **`test262_runner --worker` segfaults on `staging/sm/class/superPropProxies.js`** — exit 139, reproducible on clean `main` with that one path as the whole input, so it needs no preceding test and is not batch-state dependent. The same source runs clean under `./out/duktape_c3` with the harness concatenated, which puts the fault on the runner path rather than the language. Invisible to the gate because `staging` is skip-listed, so this is out of the targeted subset; it is recorded because a segfault in a shipped entry point is worth understanding regardless of which corpus surfaced it. The test combines `class mid extends new Proxy(base, handler)` with `super` property get/set through a proxy on the prototype chain; neither construct crashes on its own. Verified fixed on current main: the test now fails cleanly with `createRealm not supported`, the out-of-scope cross-realm path, and the worker exits 0.

- [x] **`test/test_async_loops.js` segfaulted under aggressive GC** — a generator/async resume restores `gs.saved_regs` with `tval_copy_ref`, taking a reference per heap value, but bypassed `track_heap_store` while `activation_begin` had just reset `max_heap_reg = 0`. `decref_callee_regs` sweeps only `[0..max_heap_reg]`, so restored registers above the highest index the resumed body happened to rewrite were never decref'd or cleared: the reference leaked and the slot kept stale pointer bits, which `vm_mark_activations` later read through a different frame reusing that valstack address. `track_restored_regs` raises the watermark over the restored window at both resume sites. Reachable in principle at any GC cadence; it needed collection pressure to surface. `just test-gc-stress` now covers it
- [x] **The `max_heap_reg` sentinel collision is gone** — the field stored the highest register index holding a heap reference, so the empty case and register 0 were both 0 and `decref_callee_regs`' early-out could not distinguish them. No shape reached it (arguments in register 0 are borrowed; a value returned out of register 0 is tracked on the caller), but both are ownership rules rather than guarantees. Replaced by `heap_reg_count`, one past the highest such index, so register 0 is expressible. Two writers, one reader and four resets moved together
## Design debt

- [x] **`StrBuf` by-value copy hazard documented** — `data` points into the struct's own `inline_buf` until the first growth, so copying by value dangles the copy's pointer. Silent and size-dependent: corrupts buffers <= 256 bytes, looks correct for grown ones. Audited the tree: `src/builtins/inspect.c3:862` is the ONLY by-value copy and it already re-points `data`; no other site copies one. A do-not-copy warning now sits on the struct definition (`src/builtins/core.c3`) so a future copy does not reintroduce it silently

- [x] **The last hand-rolled copy of the `await` identifier predicate is gone** — `shorthand_key_is_identifier_ref` in `src/compiler/destructuring.c3` now calls the shared `await_is_identifier`. Folded into the arrow-parameter fix, since that work routed the scan and binding sites through the same helper. This pattern, one invariant hand-maintained at N sites and wrong in the copies that omit it, was the root cause six times (the four session-302 codegen bugs, plans 063/064/065/066); four of those fixes worked by *removing* copies

## Out of scope

- test262: Temporal, `intl402`, `staging`, annexB, `harness`, other Stage 3 proposals
- test262 dirs: `statements/with`, `statements/labeled`, `statements/using`, `statements/await-using`
- Feature tokens: `cross-realm`, `tail-call-optimization`, `caller`, `__proto__`/`__getter__`/`__setter__`
- In-phase `noStrict` skips (strict-only engine by design — see AGENTS.md §Strict-Only Mode)
- Sloppy mode

  Note: `$DONOTEVALUATE` was previously listed here alongside `noStrict`. That conflated two different things — `noStrict` tests are out of scope because the engine is deliberately single-mode, but parse-negative tests are squarely in scope for a strict-only engine and are now tracked above.
- qjs CLI/std/os modules
- `(o?.m)()` undefined-this "fix"
- Arbitrary-precision BigInt
