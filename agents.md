# Duktape C3 Port


> **See spec at PRD.md.**
> **High-level project phases and progress are tracked in `progress.md`.**
> Check it before starting work to understand where we are and what's next.

**Key principle**: This is a faithful port of Duktape v2.7.0 to C3, but we should leverage C3's native features where they improve clarity or safety. Check the stdlib reference for what is available when planning a new feature.

## Build Flags

- `-D NONANBOX` — disable NaN-boxing, using the 16-byte tagged union `TVal` instead. Default is nanbox-on. Use `just build-nonanbox` or `just test-nonanbox` to exercise the non-nanbox path (e.g., for 16-bit ESP32 targets).

## NaN-Boxing Gotchas (src/types.c3)

The NaN-boxing encoding stores tagged values in the mantissa of IEEE 754 NaN values using Duktape's scheme: **16-bit tags in bits 63-48**, 48-bit payload in bits 47-0.

### Current encoding (Duktape-style)

Tags are full 16-bit values: `TAG_FASTINT=0xFFF1`, `TAG_UNDEFINED=0xFFF3`, etc. A value is a double if `bits >> 48 <= 0xFFF0`. Tagged values have `bits >> 48 >= 0xFFF1`.

**NaN normalization**: Negative NaNs have bits 63-48 in 0xFFF8-0xFFFF, which collides with tagged values. `set_number()` normalizes any double with bits 63-48 >= 0xFFF8 to the canonical positive NaN `0x7FF8000000000000`.

**Fastint sign extension**: 48-bit payload, branchless: `(long)(bits << 16) >> 16`. Range is ±2^47 (~140 trillion).

### Bugs encountered during implementation

1. **C3 operator precedence in `nanbox_is_double`**: The expression `(v >> 52) & 0x7FF != 0x7FF0` parses as `(v >> 52) & (0x7FF != 0x7FF0)` in C3, which evaluates to `(v >> 52) & 1` — making every tagged value look like a double. Must use parentheses: `((v >> 52) & 0x7FF) != 0x7FF`.

**Rule of thumb**: In C3, always parenthesize bitwise operations mixed with comparisons. `&` / `|` / `^` bind differently than in C.

2. **Small tag scheme collision**: An earlier scheme used 4-bit tags (0-8) shifted into bits 51-48 with `NANBOX_BASE = 0xFFF8000000000000`. This collided because NANBOX_BASE already has bits 51-48 = 0x8, making `nanbox_get_tag(UNDEFINED)` return 8 instead of 0. Fixed by switching to Duktape's 16-bit tag scheme.

3. **Negative NaN collision**: A scheme with `NANBOX_BASE = 0xFFF0000000000000` and 4-bit tags in bits 51-48 worked for positive values but negative NaN doubles (0xFFF8...) had bits 51-48 = 0x8, colliding with tags. Fixed by NaN normalization in `set_number()`.

## Compiler / VM Gotchas

### PUTVAR clears the source register (vm.c3)

After syncing a register value to the environment, `PUTVAR` (line ~6156) decrefs the register and sets it to `undefined`. This prevents reference leaks but means **any variable that's both register-cached and written via PUTVAR will lose its register value**. This broke `for (var k in obj)` in functions: NEXTFOR wrote the key to a register, PUTVAR synced it to the env, then zeroed the register. The body read the register directly (via `resolve_var`) and got `undefined`.

**Fix**: for-in uses a temp register for NEXTFOR output, not a `declare_var`-cached register. The body reads via GETVAR from the environment. **Any future variable-binding work must consider whether PUTVAR will clobber the register.**

### Sliding-window register init must skip argument slots (vm.c3)

When calling a function with zero formal parameters but actual arguments (e.g. `function f() { return arguments[0]; } f(42)`), the register initialization memset starts at `undef_limit = formals = 0`, which overwrites the sliding-window argument slots at `new_regs[0..nargs-1]`. Fix: start the memset at `max(undef_limit, nargs)`.

### Rosetta Code tests as a debugging tool

The 43 rosetta tests cover 22+ JS language features and proved highly effective at finding real engine bugs. The pattern: minimize the failing test to a single-line repro, check if the issue is in the compiler (compile failed) or VM (VM_ERROR / wrong value), then trace through the bytecode. For VM issues, adding `io::printfn` debug prints to the relevant opcode handler was the fastest way to pinpoint the problem.

## Post-compilation Optimizer (src/optimizer.c3)

A small function-local optimizer wired into all three `compiler::compile*` entry points via `optimizer::optimize(func)`. The optimizer runs 4 iterations per basic block, passes in order:

| Pass | Enables | What it does |
|---|---|---|
| `pass_coalesce_arith_dest` | yes | `LDINT rX, imm; OP rY = rA, rX; LDREG rZ = rY; CALL rB = rB, nargs` → `LDINT rX, imm; OP rZ = rA, rX; CALL rB = rB, nargs`. Saves one LDREG per call, main win for `bench_recursion` (~16%) |
| `pass_constant_fold` | yes | Folds arithmetic/bitwise ops where both operands are LDINT/LDCONST fastints into a single LDINT. Handles USHR via `(ulong)` cast. Range-checked to FASTINT_MIN/MAX. |
| `pass_constant_fold_unary` | yes | Folds UNM (skips -0), BNOT (always fastint), LNOT (produces BOOLEAN via LDFALSE/LDTRUE) |
| `pass_ldint_through_ldreg` | yes | `LDINT rX, imm; LDREG rY = rX` → `LDINT rY, imm`; also LDCONST-of-fastint → LDINT. Catches the `i = 0` loop-init pattern. |
| `pass_elide_unused_ldreg` | yes | Removes LDREG rD=rS where rD is overwritten before being read in the same block (conservative: keeps if `!overwritten` because the use might be in a successor block). Self-copies (rD=rD) always removed. |
| `pass_dead_store` | yes | Removes pure-compute instructions whose result is overwritten before any read in the same block. Pure-compute set: arithmetic, bitwise, comparison, LDINT, LDCONST, LDUNDEF, LDNULL, LDTRUE, LDFALSE, LDTHIS, LDREG, UNM, UNP, BNOT, LNOT, TYPEOF, TYPEOFIDENT. |
| `pass_copy_propagate` | **no** | Propagates single-use LDREG rA=rB to the consuming op, NOPing the LDREG. Disabled: causes 8/43 rosetta failures (needs more analysis). |

### Block-local design

All passes work within basic blocks to avoid inter-block data-flow analysis. Block boundaries are computed once by `mark_jump_targets`. The conservative rule: if a register definition's destination is `!used && overwritten` (found by scanning within the current block only), it's dead and can be NOPed. If `!used && !overwritten`, the definition might flow to a successor block and is kept.

### reads_register and get_dest_reg helpers

These two functions are the backbone of all passes and had **numerous bugs** that caused nearly all rosetta failures:

**reads_register** — Returns true if `insn` reads `reg` as an operand:
- ✅ CALL/CALL_S/NEW_OBJ/SUPER_CALL/TAILCALL: the argument window `[B+1, B+1+C]` (this + C explicit args) is implicitly read. Before this fix, dead_store removed argument slot setups, causing VM_ERROR/hangs on almost all tests. CALL_S uses conservative `reg > B` since C is a runtime register.
- ✅ A_BC format ops: PUTVAR, DECLVAR, SETALEN, WITH_START, PUTLEX, PUTLEX_C all read register A. The original `reads_register` returned false for all A_BC ops, so PUTVAR's source register was never seen as "used".
- ✅ JMP_N*: A is a signed offset, not a register. B and C are source regs.
- ✅ THROW/RET/RET_GEN: reads A (value to throw/return) + B + C.
- ✅ IN: reads A (key/object, both B and C) — A is both source and dest in Duktape.
- ✅ INC/DEC (NONE format): reads AND writes register A.

**get_dest_reg** — Returns the register defined by `insn`, or NO_REG:
- ✅ JMP_N*: A is offset, not dest → NO_REG.
- ✅ A_BC format: only LDCONST, LDINTX, GETVAR, TYPEOFIDENT, DELVAR, CLOSURE, GETBOUND, INC_VAR, DEC_VAR, LDINT write to A. PUTVAR, DECLVAR, TRY, BREAK, CONTINUE, INITTZ, etc. → NO_REG.

### Env controls

- `DUK_OPT_DISABLE=1` — master switch, runs the compiler as if there were no optimizer.
- `DUK_OPT_DUMP=1` — print BEFORE/AFTER bytecode for every function.

### compact_nops gotchas

The optimizer creates NOPs and `compact_nops` removes them. The following bugs were found and fixed:

1. **Use-after-free of the `protected` bit array** — freed right after the `old_to_new` table was built, but the build loop reads `!protected[i]`. **Fix**: free `protected` only after the build loop completes.

2. **JMP_NLE/NLT/LT/LE/GT/GE remap missing** — only `JUMP`, `IF_TRUE`, `IF_FALSE`, and `TRY` were remapped. **Fix**: add fused compare-branch remap.

3. **find_old_pc picking the wrong old pc** — naive linear scan returns a NOP's position. **Fix**: skip `Opcode.NOP` candidates.

4. **TRY catch_offset used `insn.a` (flags, 0-3) instead of `insn.get_bc()`** — both in `mark_jump_targets` and `compact_nops`. When a TRY had non-zero flags (e.g. just-catch), `old_catch` pointed 2-3 instructions past TRY instead of the actual catch target. The CATCH landing pad wasn't recognized as a block start. **Fix**: use `insn.get_bc()` in both places.

5. **TRY make_a_bc swapped A/BC** — `make_a_bc(TRY, new_catch_off, old_flags)` set A=catch_offset, BC=flags, but TRY format is A=flags, BC=catch_offset. The VM read flags from the large catch offset value. **Fix**: `make_a_bc(TRY, old_flags, new_catch_off)`.

6. **Protected NOP after TRY overwritten by find_old_pc fallback** — the NOP at TRY+1 is protected (carries finally offset in BC). `find_old_pc` skips NOPs, so it returned fallback 0 (meaning `func.code[0]`, the first instruction of the function) instead of the actual NOP position. This replaced the NOP with `LDUNDEF r0 = r0, r0`, corrupting the finally offset. **Fix**: use `old_pc + 1` directly instead of `find_old_pc`.

### old_to_new was originally a stack array of 1024

Overflows for any function > 1024 insns. Heap-allocate it from `func.code_count`.
