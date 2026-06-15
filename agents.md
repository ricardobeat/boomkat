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

A small function-local optimizer wired into all three `compiler::compile*` entry points via `optimizer::optimize(func)`. Currently a single pass is enabled: `pass_coalesce_arith_dest` detects `LDINT rX, imm; OP rY = rA, rX; LDREG rZ = rY; CALL rB = rB, nargs` and folds it into `LDINT rX, imm; OP rZ = rA, rX; CALL rB = rB, nargs`, saving one LDREG per recursive call. The pattern shows up for `n * rec(n-1)` style expressions; `bench_recursion` (Fib(32)) drops from ~250ms to ~210ms on macOS arm64 O3, ~16% compile+execute speedup. The pass requires `mov_dest == callee + 2` because the sliding-window register layout puts the first arg there (callee+1 is `this`, cleared to undefined by the VM).

### Env controls

- `DUK_OPT_DISABLE=1` — master switch, runs the compiler as if there were no optimizer.
- `DUK_OPT_DUMP=1` — print BEFORE/AFTER bytecode for every function.

### compact_nops gotchas

The optimizer creates NOPs (replacing the redundant LDREG with `make_abc(Opcode.NOP, 0, 0, 0)`) and `compact_nops` removes them. The first iteration had two non-determinism-producing bugs:

1. **Use-after-free of the `protected` bit array** — the array was freed right after the `old_to_new` table was built, but the build loop reads `!protected[i]` to decide whether to skip a NOP. By then, malloc's allocator had reused the freed memory for `old_to_new` or `new_code`, leaving `protected[i]` filled with garbage. When the bit happened to be set, the NOP wasn't skipped, the function came out one instruction *shorter than it should be* (real insn removed, NOP kept), and the VM hit a `VM_ERROR` ~10-30% of the time depending on which bits got clobbered. **Fix**: free `protected` only after the build loop completes. The rosetta `mutual_recursion` and `factorial` tests were the canaries.

2. **JMP_NLE/NLT/LT/LE/GT/GE/GT/GE remap missing** — `compact_nops` only remapped `JUMP`, `IF_TRUE`, `IF_FALSE`, and `TRY`. When the coalesce pass inserts a NOP before a fused compare-branch, the branch's signed-8-bit offset becomes wrong. Adding the missing remap was straightforward (`get_dest_reg` style cast via `(ichar)insn.a`).

3. **find_old_pc picking the wrong old pc** — when an old position is a NOP and the *surrounding* new positions both have the same `old_to_new[k]` value, a naive linear scan returns the NOP's k. The remap then computes the wrong absolute target. **Fix**: skip `Opcode.NOP` candidates in `find_old_pc`.

### `old_to_new` was originally a stack array of 1024

This overflows for any function > 1024 insns. Heap-allocate it from `func.code_count`.
