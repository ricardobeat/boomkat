# Plan 024: Fused opcodes for hot loops (compare-and-branch, const-key GETPROP)

## Motivation

`bench_ic_monomorphic` runs at ~330ms warm vs QuickJS at ~87ms. Profiling shows the
IC itself is cheap (~5ns/iter, measured by diffing against an identical loop with a
plain variable: 280ms vs 330ms). The cost is interpreter dispatch overhead: the inner
loop `for (...; i < N; i++) { sum += p.x; }` compiles to **12 dispatches per iteration**.

Actual bytecode (dump via `./out/test_vm benchmarks/bench_ic_monomorphic.js`):

```
12: LDCONST  r3, 4          ; limit 10000000 — RELOADED EVERY ITERATION (back-edge target)
13: LDREG    r4 = r2        ; copy i
14: LT       r4 = r4, r3
15: IF_FALSE r4, +8         ; exit -> 24
16: JUMP     +3             ; -> body at 20
17: LDREG    r4 = r2        ; DEAD post-increment value (unused)
18: INC      r2
19: JUMP     -8             ; -> 12 (condition)
20: LDCONST  r4, 5          ; key "x"
21: GETPROP  r5 = r1, r4
22: ADD      r0 = r0, r5
23: JUMP     -7             ; -> 17 (increment)
24: RET      r0
```

Goal: cut this to ~7 dispatches/iteration via two fused opcodes plus small codegen
fixes. Every fusion is done as a **peephole that replaces instructions in place**
(rewrite one slot, NOP the other), matching the existing GETVAR+INC+PUTVAR →
INC_VAR fusion in `src/compiler/context.c3:299`. In-place replacement is mandatory:
jump offsets and the pc-indexed IC tables (`ic_base + pc_off`, see `src/vm.c3:2779`)
both assume instruction positions never shift.

## Instruction encoding constraints

`Instruction` is 32 bits: op(8) + a(8) + b(8) + c(8) (`src/bytecode.c3:486`).
Formats: ABC, A_BC (16-bit bc), A_SBX (16-bit signed offset). A fused
compare-and-branch needs two registers **and** an offset, so the offset must fit in
the 8-bit A field as signed (−128..127, encoded as `char`). Fall back to the unfused
pair when out of range. Loop back-edges and exit jumps are almost always short, so
this covers the common case.

## Phase 1: `GETPROPC` — const-key property load

Fuses `LDCONST rK, idx` + `GETPROP ra = rb, rK` into one dispatch. This pattern is
emitted for every `obj.name` access (`src/compiler/expressions.c3` member access),
so it helps all property-heavy code, not just this benchmark.

1. **Opcode** (`src/bytecode.c3`): add `GETPROPC` near GETPROP. Format ABC:
   A = dst reg, B = obj reg, C = constant-pool index of the key string.
   Add to the name table (`opcode_names`) and `OpFormat` switch.
2. **Peephole** (`src/compiler/context.c3`, alongside the INC_VAR fusion in
   `emit`/post-emit hook at line ~299): when the last two instructions are
   `LDCONST rK, idx` + `GETPROP ra = rb, rK`, and `idx <= 255`, and rK is a temp
   that is not otherwise referenced (it's the freshly allocated key register, same
   guarantee the INC_VAR peephole relies on), rewrite:
   - slot n−1 → `NOP`
   - slot n   → `GETPROPC ra = rb, idx`
   The GETPROP slot keeps its pc, so its `ICEntry` slot is unchanged.
   Respect the same jump-target guard the existing peephole uses (do not fuse
   across a label/patch target — check how `context.c3` tracks `last_target` /
   patch positions; if there is no guard today, add one: record the highest pc
   that is a jump target so far and refuse to fuse when slot n−1 ≤ that pc).
3. **VM handler** (`src/vm.c3`, next to `case Opcode.GETPROP` at line 2773):
   - `HString* key = (HString*)consts[insn.c]` — key is always a string constant,
     so the `rc.is_string()` / `lookup_key != null` checks in the IC fast path
     (vm.c3:2781-2783) disappear; guard becomes just
     `ic.key == key && ic.shape_id == hobj.shape_id && ic.cached_prop_alloc == ...`.
   - On IC miss, materialize a TVal for the key and fall into the same slow path
     GETPROP uses (factor the shared tail into a helper or `goto`-style
     fallthrough — simplest: build a local `TVal keyval` and reuse the existing
     code by jumping to a shared function; mirror however GETPROP's slow path is
     structured).
   - Keep the dense-array and exotic fast paths out of GETPROPC: a constant string
     key is never an array index in the hot case, but `.length` on arrays IS a
     constant key — so keep the ARRAY/.length and ARGUMENTS/.length checks.
4. **Bench expectation**: −1 dispatch/iter here (~25-30ms on this benchmark);
   bigger wins on bench_property_lookup / vdom_test.

## Phase 2: fused compare-and-branch (`JLT_F`, `JLE_F`, `JGT_F`, `JGE_F`)

Fuses `LT ra = rb, rc` + `IF_FALSE ra, sbx` into one "branch if NOT (b < c)" op.
(Also the IF_TRUE variants if the peephole finds them; start with IF_FALSE — that's
what loop conditions emit.)

1. **Opcodes** (`src/bytecode.c3`): `JLT_F, JLE_F, JGT_F, JGE_F` (and optionally
   `JEQ_F, JNEQ_F` later). Format ABC where A = signed 8-bit jump offset
   (cast through `char`), B/C = comparison operands. Offset semantics identical to
   IF_FALSE's sbx: relative to the instruction after the branch.
2. **Peephole** (`src/compiler/context.c3`): this fusion CANNOT happen at emit time
   because IF_FALSE's offset is patched later (`src/compiler/patches.c3`). Two
   options; pick (a):
   - (a) **Patch-time fusion**: in the patch resolution path, after an IF_FALSE
     offset is finalized, check whether the preceding instruction is
     LT/LE/GT/GE writing the same register IF_FALSE tests, that register is a
     temp, the final offset fits in signed 8 bits, and the IF_FALSE slot is not
     itself a jump target. If so rewrite: slot n−1 → `JLT_F off, rb, rc`,
     slot n → `NOP`. Note the fused op goes in the *compare's* slot, so the
     offset must be adjusted by +1 (one extra instruction is skipped relative
     to IF_FALSE's encoding). Landing on the NOP from other jumps is harmless.
   - (b) emit-time pseudo-op with its own patch kind — more invasive, skip.
3. **VM handlers** (`src/vm.c3`, near LT at line 2503): replicate LT's exact
   semantics (fastint fast path, string compare, ToNumber fallback including
   `vm_check_to_number_throw` / `needs_restart` handling — get this right, the
   restart path must re-execute the fused op, which is fine since it's
   side-effect-free before the branch). Then:
   `if (!result) curr_pc += (int)(char)insn.a;`
   The four handlers are near-identical; use a shared `@inline` helper for the
   compare to avoid drift.
4. **Bench expectation**: −1 dispatch/iter, and removes the boolean round-trip
   through r4.

## Phase 3: loop codegen cleanups (no new opcodes, adjacent wins)

These come straight from the bytecode dump and are arguably bigger than the fusions:

1. **Hoist the limit reload**: the back-edge jumps to pc 12 (`LDCONST r3, limit`)
   instead of pc 13. In `for_statement` (`src/compiler/statements.c3:429`),
   record the loop-condition start *after* emitting constant operand loads when
   the RHS of the condition is a constant… this is fragile in general. Simpler,
   robust fix: the condition is re-evaluated each iteration by design; instead
   teach the constant loader to skip re-emitting `LDCONST` when the register
   already holds that constant — too global. Most contained fix: in
   `for_statement`, evaluate nothing before the condition label; the LDCONST is
   part of condition evaluation, so instead apply a **loop-invariant constant
   hoist**: if the condition is `<simple var> <relop> <numeric/const literal>`,
   pre-load the constant into a pinned register before the condition label and
   emit the comparison against that register. Detect this syntactically at parse
   time in `for_statement` (peek: IDENT relop NUMBER). Keep scope narrow.
2. **Drop the dead post-increment copy**: `i++` as an expression statement emits
   `LDREG r4 = r2` (old value) + `INC r2` (`src/compiler/expressions.c3:566-570`
   area). When the postfix expression is in statement position (result discarded),
   skip emitting the LDREG. The for-statement increment clause is exactly this
   case — `for_statement` can call the expression with a "result unused" flag, or
   a peephole can NOP a `LDREG rT = rX` immediately followed by `INC rX` when rT
   is a dead temp (the INC_VAR fusion already demonstrates the temp-deadness
   check). Prefer the flag: it's explicit.

Phase 3 result for this loop: condition becomes `LDREG r4=r2; JLT_F` … actually with
phase 1+2+3 the per-iteration sequence is:

```
LDREG r4 = r2 ; copy i           (could also fuse later: JLT_F can read r2 directly
JGE_F +8, r4, r3                  if regalloc lets the compare read the var register —
JUMP +3                           check whether the LDREG copy is needed at all; if the
INC r2                            condition compiles var-reg-direct, that's −1 more)
JUMP -…
GETPROPC r5 = r1, "x"
ADD r0 = r0, r5
JUMP -…
```

~8 dispatches, down from 12 (~30% fewer). Loop rotation (emit increment+condition at
the bottom, removing the two JUMPs) is a further follow-up but is a control-flow
restructure, not a fused op — out of scope here.

## Correctness checklist

- [ ] Peepholes never fuse across a jump target (verify how INC_VAR fusion guards
      this today; add a `last_jump_target_pc` watermark if it doesn't).
- [ ] NaN comparison semantics: `JGE_F` is "branch if NOT (b < c)" — for doubles,
      `!(NaN < x)` is true, and IF_FALSE on `LT`'s false result also branches, so
      the fused form must use the negation of the original compare, NOT the
      inverted operator. Name the ops after the source compare + branch sense
      (e.g. `JMP_IF_NOT_LT`) to avoid this classic bug.
- [ ] ToNumber side effects (valueOf) in the slow compare path still throw/restart
      correctly through `vm_check_to_number_throw`.
- [ ] GETPROPC falls back to full GETPROP semantics on IC miss: getters, proto
      chain, string/arguments exotics, Proxy if supported.
- [ ] Offsets out of signed-8-bit range → leave unfused (test with a loop whose
      exit jump spans >127 instructions).
- [ ] `disassemble` (`src/bytecode.c3:629`) handles the new ops; OpFormat table
      updated (GETPROPC = ABC, J*_F = ABC with signed A).

## Validation

1. `c3c build test_vm && ./out/test_vm benchmarks/bench_ic_monomorphic.js` — inspect
   the fused bytecode and confirm PASS.
2. `c3c build boomkat && just bench-fast 3` — expect bench_ic_monomorphic,
   bench_loop, bench_arithmetic, bench_property_lookup all to improve; nothing
   should regress.
3. Local test suite (batch_test_vm over test/) — comparisons and property access
   are everywhere, so any semantic slip shows up immediately.
4. One targeted test262 phase for comparison operators if paranoid (not the full
   suite).

## Measured baseline (2026-06-10, M-series laptop, warm runs)

- bench_ic_monomorphic: ~330ms (HEAD, and identical at 5ec44cf — the "regression"
  vs the recorded 284ms is machine noise, not code)
- same loop without property access: ~280ms
- QuickJS reference: 87ms
