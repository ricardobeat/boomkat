# Bytecode fusion framework

Two deliverables: a golden-bytecode test suite that makes fusion regressions
fail loudly, and a declarative rule framework proven on the ADDI/SUBI pass.

## 1. Golden-bytecode test suite

**Location:** `test/golden_bytecode/*.js` + `*.expected`, runner at
`scripts/run_golden_bytecode.py`, wired via `just test-golden-bytecode` /
`just update-golden-bytecode`.

**Mechanism:** each `<name>.js` is compiled with
`out/duktape_c3_debug -c <name>.js` (requires the `duktape_c3_debug` target,
which carries `-D TRACE_VM` — `just build-trace` or plain
`c3c build duktape_c3_debug`). The stdout disasm is diffed verbatim against
the checked-in `<name>.expected`. Any diff — a fusion that stopped firing,
an extra fusion firing somewhere it shouldn't, a register-allocation shift —
fails the specific golden with a unified diff, not a silent perf drop.

**Seeded goldens:**

| golden | proves |
|---|---|
| `fib_subi.js` | `SUBI` fires twice (`n-1`, `n-2`) — the original bug-motivating case |
| `loop_addi.js` | `ADDI` fires on `i = i + 1` inside a `for` loop |
| `sub_out_of_range.js` | `x - 256` (imm > 127) stays plain `SUB` — proves the signed-8-bit guard |
| `inc_var.js` | `GETVAR+INC+PUTVAR → INC_VAR` still fires (existing hand-written pass, unrelated to ADDI/SUBI, included so the suite isn't ADDI/SUBI-only) |

`inc_var.js` needs the loop variable captured by a closure — otherwise the
register-resident-locals pass elides `GETVAR`/`PUTVAR` for `i` entirely
(it never touches the runtime scope object) and the INC_VAR pattern never
gets a chance to match. This was the first thing the golden suite caught
during authoring: a naive `while (i<5) i++;` produces zero `GETVAR`/`PUTVAR`
in this compiler.

**Running it:**

```
just test-golden-bytecode          # build duktape_c3_debug, run + diff all 4, plus --check-noop
python3 scripts/run_golden_bytecode.py fib_subi     # single golden
python3 scripts/run_golden_bytecode.py --update     # regenerate .expected after an intentional change
```

**disable_optimize equivalence:** `--no-optimize` is already wired
(`cli/duktape_c3_debug.c3` → `compiler::set_disable_optimize(true)`, gates
every peephole pass in `CompilerContext.finish()`, see `context.c3:164`).
`--check-noop` (default-on via the justfile recipe) re-runs each golden with
`--no-optimize` and asserts the output contains none of `ADDI, SUBI,
INC_VAR, DEC_VAR, GETPROPC, JMP_N*` — i.e. fusion is continuously checked to
be a pure no-op when disabled, not just assumed. All 4 goldens currently
pass this check.

## 2. Declarative fusion rules

**Location:** `src/compiler/fusion.c3` (new file, same module
`duktape::compiler`).

### Why declarative

Every existing peephole pass in `CompilerContext.finish()` re-derives the
same three pieces of machinery by hand, with small but real divergences
between copies:

1. **NOP-skipping** to find the real consumer (copy-propagation leaves NOPs
   between a trigger and what was, pre-optimization, its adjacent user).
2. **Dead-after-liveness scan**: is the scratch register read again before
   it's overwritten? (IF_TRUE/IF_FALSE read field `a`, everything else in
   `ABC` format reads `b`/`c`; `A_BC`/`A_SBX`/wide formats never have
   register operands outside `a`.)
3. **Rewrite emission**: NOP the trigger, replace the consumer slot.

The ADDI/SUBI bug that motivated this task was exactly a phase-ordering
mistake in machinery #1 — the pass didn't skip NOPs at all in its first
version, so it only matched a `LDINT` immediately followed by `ADD`/`SUB`,
which copy-propagation's own NOPs (of the intervening `LDREG` moves)
routinely broke. Nothing failed a test; it just silently stopped firing.

### Schema

```c3
struct FusionMatch {
    bool   matched;
    Opcode rewrite_op;   // opcode to install at the consumer's slot
    uint   dest_reg;     // destination register of the rewritten instruction
    uint   src_reg;      // surviving source register
    uint   imm;          // immediate baked into the rewritten instruction
}

alias FusionTriggerFn  = fn FusionMatch(Instruction trigger);
alias FusionConsumerFn = fn FusionMatch(Instruction trigger, Instruction consumer, uint scratch_reg);

struct FusionRule {
    FusionTriggerFn  trigger;
    FusionConsumerFn consumer;
}
```

A rule is `{trigger, consumer}`: `trigger` recognizes the instruction that
introduces a scratch value and reports its register + would-be immediate;
`consumer` recognizes whether the next real instruction consumes that
register in a fusable way and reports the rewrite. The **shared driver**,
`run_fusion_rule(code, code_count, rule)`, owns:

- iterating the trigger over the whole stream,
- NOP-skipping to the consumer,
- the dead-after-liveness scan (`fusion_reg_live_from`) on the scratch
  register after the consumer,
- emitting `NOP` + the rewritten instruction.

Guard predicates (i8-immediate-fits, which-operand-is-the-scratch-register,
commutativity) live entirely inside a rule's `trigger`/`consumer`
callbacks — the driver has zero opcode-specific knowledge.

**Jump-target safety is deliberately NOT part of the driver.** Every
trigger→consumer fusion in this shape rewrites the trigger slot to `NOP`
(always a safe jump target — control falls through into the still-valid
consumer) and leaves the consumer's own position unchanged (only its opcode
and operands are replaced in place, so anything jumping to the consumer
slot still lands on a valid instruction start). This is why ADDI/SUBI and
GETPROPC don't need a jump-target bitset at all, unlike the comparison
fusion below, which rewrites a *branch* — see "what doesn't fit" below.

### Ported: ADDI/SUBI

`FUSION_ADDI_SUBI` in `fusion.c3` is the trigger/consumer pair for
`LDINT rK, imm (i8) + ADD/SUB rD = …,rK → ADDI/SUBI rD = rS, imm`, ported
1:1 from the hand-written pass previously in `context.c3` (same guard
logic: ADD commutes on either operand, SUB only folds `rS - imm`).
`context.c3:finish()` now calls `fuse_addi_subi(self.code, self.code_count)`
inside the same `if (!self.disable_optimize && ...)` guard as before, at
the same point in the pass ordering (immediately after copy-propagation).

**Equivalence proof:** ran `just test-golden-bytecode` before and after the
port — all 4 goldens produce byte-identical disasm, including
`sub_out_of_range` (proves the guard survived the port) and `--check-noop`
(proves `disable_optimize` still short-circuits it). Also ran
`test262 --phase 0` (2185 tests, 11 pre-existing fails, unchanged count)
and the full `test/*.js` smoke suite (7 pre-existing unrelated fails —
`with`, module-mode files needing `-m`, strict-mode-by-design — unchanged
from before the port) as broader regression checks.

### What wasn't ported, and how it would map

Only ADDI/SUBI was ported, per the task's risk budget. The other three:

**GETPROPC (`LDCONST rK, idx + GETPROP → GETPROPC`)** — fits the framework
shape exactly as-is: trigger = LDCONST (guard: `idx <= 255` and constant is
a string), consumer = GETPROP (guard: `c == rK`), same dead-after scan. This
is the next easiest port; the only wrinkle is that `context.c3` currently
starts its liveness scan from `i+2` (immediately after the pair) rather
than `k+1` (after NOP-skipping) — since this pass requires *physical*
adjacency (no NOP-skip window), `i+2 == k+1` always holds here, so
`run_fusion_rule`'s NOP-skip degrades to a no-op check and the port would
be behavior-preserving.

**INC_VAR/DEC_VAR (`GETVAR r,name + INC/DEC r + PUTVAR r,name`)** — does
NOT fit the 2-slot trigger/consumer shape: it's a 3-instruction window with
no scratch register at all (all three instructions reference the *same*
register `r`, which survives the fusion rather than dying). It would need
either a 3-slot variant (`FusionRule3` with a `middle` matcher) or
reframing as "trigger = GETVAR, consumer = INC/DEC, then a *second*
mandatory follow-up matcher for PUTVAR" — a `FusionRule` with an optional
`tail` callback. Not attempted; the win is smaller than the ADDI/SUBI
guard-logic complexity would suggest, so it wasn't worth the schema
extension in this budget.

**Comparison fusion (`LT/LE/GT/GE + IF_FALSE/IF_TRUE → JMP_N*/JMP_*`)** —
the one genuine mismatch with the current framework's safety assumption.
This fusion rewrites the *consumer* into a branch and deletes the original
branch's semantics from that slot, so (a) it needs the jump-target bitset
the current driver doesn't build (a jump landing on the fused branch slot
must not have been targeting the old IF_FALSE/IF_TRUE for different
reasons), and (b) it has an extra offset-arithmetic guard (`sbx+1` must
still fit signed 8-bit) that has no analog in `FusionMatch`. Mapping this
in would mean either extending `FusionRule` with an optional
`jump_target_bitset` guard the driver checks before rewriting, or leaving
branch-rewriting fusions as a deliberately separate category outside this
framework (arguably the more honest design — "fuse two straight-line ops"
and "fuse a compare into a branch" are different enough operations that
forcing them through one schema may just relocate the complexity rather
than remove it).

### Files changed

- `src/compiler/fusion.c3` — new: `FusionMatch`, `FusionRule`,
  `run_fusion_rule`, `fusion_reg_live_from`, `FUSION_ADDI_SUBI`,
  `fuse_addi_subi`.
- `src/compiler/context.c3` — `finish()`'s hand-written ADDI/SUBI pass
  (~68 lines) replaced with a single call to `fuse_addi_subi`.
- `test/golden_bytecode/*.js`, `*.expected` — new golden fixtures.
- `scripts/run_golden_bytecode.py` — new runner.
- `justfile` — `test-golden-bytecode`, `update-golden-bytecode` recipes.

### Gaps / follow-ups

- Only 1 of 5 fusion-shaped passes ported; see above for how the other 3
  would map (2 fit cleanly, 1 needs a 3-slot schema, 1 needs a
  jump-target-bitset extension).
- The golden suite has 4 goldens; it proves the framework and the specific
  bug class that motivated this task, but is not exhaustive coverage of
  every opcode. Natural next additions: a GETPROPC golden once that pass is
  ported, and a golden that exercises the comparison fusion's offset-clamp
  guard (`sbx+1` overflow).
- `run_fusion_rule` assumes a single register is both the trigger's output
  and the sole liveness-tracked value (`dest_reg` in `FusionMatch` doubles
  as "the scratch register to check for death" on the trigger side and
  "the destination register of the rewritten op" on the consumer side).
  This coincidence holds for ADDI/SUBI and would hold for GETPROPC, but is
  worth flagging explicitly if a future rule's trigger register and
  rewritten-destination register diverge — the field would need splitting.
