# 108: JIT correctness gates and direction

Status: **COMPLETED — consolidated into [plan 113](113-fifty-thousand-octane.md), 2026-10-28.**

The review and corrective implementation cycle are closed. Later repair and validation are recorded in plans 110 and 116–118. Ongoing recovery, ownership and optimizing-tier requirements are tracked in plan 113. Completion closes this document as a separate workstream; it does not assert that the broader optimizing tier or performance target has been achieved.

The original implementation notes, measurements and status statements below are historical evidence. Plan 113 owns the current priorities and acceptance criteria.

---

Historical status: proposed. A review of the `rat` branch at `8ab73eba` plus the
uncommitted work in `.worktrees/rat` (equality and null branches in the
function tier). It follows plan 107 and reorders its next steps. Nothing
here was built or measured; the facts come from the branch, its diff
against main and plan 107's own measurements.

The branch is 40 commits ahead of main, with about 9.1k lines across the
`src/vm/vm_sljit_*.c3` files. On the three object-heavy minis the JIT is
still a loss: plan 107 §14 has deltablue and richards about four percent
slower than the interpreter and splay level, with roughly one sample in JIT
code over a 1500-iteration deltablue run.

## 1. Known wrong output comes first

Three correctness faults are open, all recorded in plan 107:

- The straight-line loop tier decrypts `crypto` wrongly (107 §12). Two
  minimized repros exist: the first `modPow` on the Montgomery path, and
  `reduce` failing at iterations 9 and 65 of 400.
- `pdfjs` prints different bytes under `--jit` (107 §7). It predates
  plan 107 and has no repro yet.
- The SSA tier miscompiles a loop that boxes a constant into a growing
  array (107 §12) and is disabled with `SSA_ENABLED`. It is still about
  3k lines that must keep compiling (`e462dc7b`).

Every new native opcode widens the surface these faults hide in. Fix the
`crypto` mismatch before any further emitter work, then reduce `pdfjs` to
a script. Decide the SSA tier: fix it against its repro, or delete it and
bring it back when it can be enabled.

## 2. Differential testing under the JIT

`just test-jit` runs three files. The faults found so far surfaced by
accident: the TypeScript scanner under array element writes (107 §5),
`crypto` and `pdfjs`. The JIT needs the same coverage the interpreter has.

- A stress setting that compiles on the first call instead of the 64th
  (`sljit_function_calls >= 64` in `vm_sljit_function.c3`) and disables the
  stuck-entry rule, so every function that can compile does.
- A recipe that runs `test-local`, `rosetta` and `modules` with and without
  `--jit` under that setting and diffs the output.
- A `--jit` switch on `test262_runner`, then the same comparison over
  `language/expressions`, `language/statements` and `built-ins/Array`.

This is a gate for every later item in this plan.

## 3. Tests must reach native code

`test/jit_append_property.js` in the uncommitted work checks the setter,
`preventExtensions` and `Derived` cases once each. A function compiles
after 64 calls, so those cases only exercise the interpreter.

A JIT regression should:

- warm the site with the fast shape inside a function called well past the
  threshold;
- then change the shape while the code is native: add a setter on the
  prototype, make the receiver non-extensible, swap the prototype;
- fail when no native code ran, using the `SLJIT_STATS` counters as
  `test/capi/jit.c3` does.

`test/jit_loose_equality.js` already has the first part right.

## 4. Opcode ranges

Main added `JMP_EQ`, `JMP_NEQ`, `JMP_NULL` and `JMP_NNULL` between
`JMP_SNEQ` and `JMP_NLTI` (`df36fbc5`). After the merge (`30022958`), at
`8ab73eba`:

- `function_inline_general_body` accepts `case JMP_NLT..JMP_SNEQI`, which
  now includes the four new opcodes.
- `loop_target` stops at `JMP_SNEQ`, so it does not report those four as
  branches, and the inline emitter does not emit them as branches.

An expanded callee containing `x == null` can therefore lose its branch.
The uncommitted diff fixes this. Land it as its own commit with a
regression that expands a callee holding a null and an equality branch.

The cause is the ordinal ranges and the lookup tables indexed by
`op.ordinal - Opcode.JMP_NLT.ordinal` (`function_inline_condition`,
`loop_condition`, two in `vm_sljit_ssa.c3`). Replace them with explicit
case lists, or add `$assert`s on the range sizes so an opcode inserted by a
merge fails the build.

The uncommitted `loop_condition` pads its table with `{ 0, 1, 0, 1 }` for
the four new opcodes so it cannot be overrun. Those entries turn loose
equality into a raw bit compare, so any path that reaches them miscompiles
without a trace. Unsupported opcodes should fail there instead.

## 5. Find where native code is missing

Plan 107 §15 lists this second, after append stores. It should come
first. With about one sample in JIT code on deltablue, another emitter
feature cannot be targeted until it is known which functions matter and
why they stay interpreted.

Under `SLJIT_STATS`, print at exit the top N functions by interpreted
instruction count, each with one of:

- rejected by `function_analyze` or `loop_analyze`, and the opcode that
  rejected it;
- compiled, with the bytecode positions it exits at;
- disabled by the stuck-entry rule.

The stuck-entry rule (eight entries that stop at the same call without a
backedge) may be what turns off the functions that dominate the run.

## 6. Calls end the native run

A call that cannot be expanded exits the region, goes through the
interpreter's call, return and `th_resume_caller`, then re-enters native
code at the next block. Plan 107 §1 measured call and return at 60% of a
deltablue run. Most of the recent work goes around this: multi-level
expansion, multi-target expansion, the replay guard, stuck-entry detection
and the recompile heuristics tried in §14.

Two structural changes would remove the reason for most of them.

- **Native `CALL`.** Emit a call as a call to a helper that runs the
  callee and returns into the same compiled code, as baseline JITs do.
  Builtins already call into JS, so the VM supports nested calls. What
  needs design: exceptions unwinding through native frames, generators and
  async functions (exit as now), the interrupt and budget checks, and C
  stack depth.
- **Frame reconstruction on guard failure.** When a guard fails inside an
  expanded callee, the interpreter reruns the whole callee, so a store the
  native run already made happens twice. The replay guard (107 §9) avoids
  that by refusing a store that is followed by anything that can exit,
  which also limits what can be expanded. Recording enough to rebuild the
  callee's frame and resume at the failing instruction removes the
  restriction.

Measure the first against deltablue and richards before starting the
second.

## 7. One capability table for the tiers

There are five tiers: template, function, loop, SSA (disabled) and typed.
Each has its own opcode predicates and condition emitter. The uncommitted
equality and null work touches `function_op`,
`function_inline_general_body`, `loop_analyze` and `loop_condition`, three
of them only to keep the opcodes out.

Move opcode support into one table and the branch condition into one
emitter that the tiers share. The template tier recognizes the specific
shape of a template rendering loop; keep it only if the diff tests of §2
show it pays for its 482 lines.

## 8. Smaller items in the uncommitted diff

- `plan.hits % 10000 == 0` in `sljit_function_entry` is a debugging change
  to the stats output. Revert it.
- `null_check` takes the `htmldda_obj` offset from a stack `Heap heap_view`.
  `Heap.htmldda_obj.offsetof` says the same thing directly; the other
  `_view` uses (5 in `vm_sljit_function.c3`, 2 each in `vm_sljit_array.c3`
  and `vm_sljit_inline.c3`) can follow.
- `test/jit_append_property.js` belongs to append stores, which the diff
  does not implement. Keep it out of the equality and null commit.
- `8ab73eba` has no `Assisted-by:` trailer, which `AGENTS.md` requires.

## 9. Order

1. Commit the opcode-range fix (§4) with its regression.
2. The stress setting and differential recipes (§2).
3. The `crypto` mismatch, then `pdfjs` (§1). Decide the SSA tier.
4. The coverage report (§5).
5. Native `CALL` (§6), measured on deltablue and richards.
6. Append stores (107 §15) and the rest of 107, guided by the report.

The capability table (§7) can happen whenever a tier is next touched.
