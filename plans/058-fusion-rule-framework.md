# Bytecode fusion framework

Two deliverables: a golden-bytecode test suite that makes fusion regressions
fail loudly, and a declarative rule framework, now covering 3 of the 5
fusion-shaped peephole passes in `CompilerContext.finish()` (ADDI/SUBI,
GETPROPC, INC_VAR/DEC_VAR — see "Final tally" below for the other two).

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
| `inc_var.js` | `GETVAR+INC+PUTVAR → INC_VAR` fires (declarative since the INC_VAR/DEC_VAR port) |
| `dec_var.js` | `GETVAR+DEC+PUTVAR → DEC_VAR` fires (same pass, DEC side) |
| `getpropc.js` | `LDCONST+GETPROP → GETPROPC` fires (declarative since the GETPROPC port) |

`inc_var.js`/`dec_var.js` need the loop variable captured by a closure —
otherwise the register-resident-locals pass elides `GETVAR`/`PUTVAR` for `i`
entirely (it never touches the runtime scope object) and the INC_VAR/DEC_VAR
pattern never gets a chance to match. This was the first thing the golden
suite caught during authoring: a naive `while (i<5) i++;` produces zero
`GETVAR`/`PUTVAR` in this compiler.

**Running it:**

```
just test-golden-bytecode          # build duktape_c3_debug, run + diff all 6, plus --check-noop
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

### Ported: GETPROPC

`FUSION_GETPROPC` fits the 2-slot framework exactly as predicted above:
trigger = LDCONST (guard: `idx <= 255` and constant is a string), consumer =
GETPROP (guard: `c == rK`), same `fusion_reg_live_from` dead-after scan
(which already implements the "rK kept alive for a following PUTPROP/DELPROP
in LHS mode" case for free — that's just ordinary dead-after liveness, not a
special case).

This is the first rule whose trigger guard needs more than the raw
instruction bits (it has to look up the constant pool to check
`is_string()`), so the framework grew one small, deliberately generic
extension for it: `FusionTriggerFn`/`FusionConsumerFn` both take an opaque
`void* ctx` parameter, threaded unchanged through `run_fusion_rule(code,
code_count, rule, ctx = null)`. ADDI/SUBI's callbacks take and ignore it;
GETPROPC's trigger casts it to `TVal*` (the constant pool). This keeps the
driver itself opcode-agnostic while letting individual rules opt into
whatever context they need.

**Equivalence proof:** added a `getpropc` golden (`obj.x` property read)
that fires GETPROPC; disasm is unchanged pre/post-port for all existing
goldens, and `--check-noop` confirms GETPROPC doesn't fire under
`--no-optimize`.

### Ported: INC_VAR/DEC_VAR

`GETVAR r,name + INC/DEC r + PUTVAR r,name → INC_VAR/DEC_VAR name` does NOT
fit the 2-slot trigger/consumer shape, confirming the original prediction:
it's a fixed 3-instruction window over ONE register that *survives* the
fusion (a live variable, not a dying scratch temp), so there is nothing to
NOP-skip to and no liveness scan to run at all — correctness is pure
structural/name-index equality across all three slots, and the rewrite
lands on the *middle* slot (not the trailing one, unlike every 2-slot rule).

Rather than force this into `FusionMatch` (which would mean inventing
dummy `src_reg`/liveness semantics that don't apply here), it got its own
small parallel schema: `Fusion3Match` / `Fusion3Rule` / `run_fusion3_rule`,
using the same `void* ctx` threading convention as the 2-slot driver (here
carrying a pointer to `const_count`, mirroring the original pass's `name0 <
self.const_count` bound). This is a second driver, not a second framework —
both share the same rule-shape philosophy (declarative match callback +
one shared driver owning the mechanical NOP/rewrite emission), they just
can't share the *same* driver because the rewrite geometry differs (2 slots
→ 1 vs. 3 slots → 1-in-the-middle).

**Equivalence proof:** the existing `inc_var` golden stayed byte-identical
post-port; added a `dec_var` golden (DEC_VAR had no prior coverage) which
fires correctly. `--check-noop` unaffected (INC_VAR/DEC_VAR were already on
the check-noop opcode list).

### Deliberately left hand-written: comparison fusion

**`LT/LE/GT/GE + IF_FALSE/IF_TRUE → JMP_N*/JMP_*`** (context.c3:814, now the
only remaining hand-written peephole pass besides the two copy-prop passes
below) is a genuine mismatch with both driver shapes above, not a "would be
nice to generalize eventually" gap:

- It rewrites the *branch itself* — the fused op replaces both the compare
  AND the following conditional jump's semantics — rather than collapsing a
  trigger+consumer pair that share a dying scratch register. There's no
  register being retired into an immediate; the entire *control-flow shape*
  of the two-instruction pair changes.
- It requires a **whole-function jump-target bitset**, built *before* any
  rewriting (scanning JUMP/BREAK/CONTINUE/IF_TRUE/IF_FALSE/TRY for static
  targets), to reject fusing when the branch slot is itself a jump target.
  Neither existing driver builds or threads one; retrofitting it as an
  optional driver-level guard would mean the "generic" driver has to know
  what a jump target even is for every opcode shape in the ISA (JUMP vs TRY
  vs IF_*), which is exactly the opcode-specific knowledge the drivers are
  built to keep out.
- It runs **two separate liveness scans** (fall-through path from `i+2`,
  AND the branch-target path from `i+2+sbx`), each of which special-cases
  jump-targets differently *mid-scan* (probe-and-continue on the
  fall-through side, immediate live on the branch side) — a shape neither
  `fusion_reg_live_from` nor any single-scan liveness helper supports.
- It carries three empirically-discovered correctness patches with no
  general form: the B23/B26 "bridge" fix (extend the fused offset past a
  chained short-circuit IF_FALSE/IF_TRUE), the B28 fix (only treat a
  *forward* bridge as a bridge — a negative offset is a loop back-edge, and
  extending through it inverts the jump direction), and the B27
  short-circuit-skip veto (don't fuse when the branch target is immediately
  followed by an LDREG writing the compare's result register — the `&&`/`||`
  short-circuit path needs that boolean materialized, which the fused
  branch never does). These aren't guard predicates in the trigger/consumer
  sense; they're targeted corrections against specific loop and
  short-circuit-operator code shapes found by testing, and forcing them
  into a declarative schema would mean exposing the same amount of detail
  through callback parameters instead of removing it.

Given the task's explicit permission to make this call: this is left as a
hand-written pass. "Fuse two straight-line ops that share a scratch
register" and "fuse a compare into a branch, with jump-target and dual-path
liveness analysis" are different enough operations that a forced common
schema would just relocate the branch-specific complexity into extra
`FusionMatch`/`FusionRule` fields with no reuse benefit — no other fusion
in this compiler needs a jump-target bitset or a second liveness scan, so
there is no second caller to amortize the abstraction over.

### Deliberately left hand-written: copy-propagation and dead-LDREG DCE

**Copy-propagation** (context.c3:1101, `LDREG rT=rS` substituted into a
consumer's b/c operands) and **dead-LDREG-before-INC/DEC elision**
(context.c3:1180) were judged, per the task's instruction to assess fit,
NOT to be fusions at all:

- Neither produces a new superinstruction opcode. Copy-prop's consumer
  keeps its *original* opcode (`ADD`, `LT`, `JMP_NLT`, ...) with only its
  register operands rewritten; dead-LDREG elision doesn't rewrite anything
  downstream, it just NOPs an instruction whose result is proven unread.
  `FusionMatch.rewrite_op`/`imm` (the "bake a scratch value into an
  immediate" contract every other rule in this file follows) has no
  meaning for either pass.
  Copy-prop's cop_reads_b_c matches JMP_N*+LT/LE/GT/GE/ADD/SUB/MUL,
  which is an ad-hoc opcode whitelist, not a trigger/consumer *pattern* —
  there's no single "consumer shape" being recognized.
- These are classic dead-code-elimination / value-numbering passes that
  happen to be implemented as narrow, single-instruction-lookback peephole
  scans in this compiler, not a fusion in the "two adjacent ops collapse
  into a superinstruction" sense the rest of this file is about.

Both are left in `context.c3` as-is; `fusion.c3` is scoped to true
superinstruction fusion (a new fused opcode replaces N old ones), and
widening that scope to cover general peephole DCE would blur what the file
is for without offering these two passes anywhere cleaner to live.

### Files changed

- `src/compiler/fusion.c3` — `FusionMatch`/`FusionRule`/`run_fusion_rule`/
  `fusion_reg_live_from`/`FUSION_ADDI_SUBI`/`fuse_addi_subi` (existing);
  added `ctx: void*` threading to the 2-slot driver, `FUSION_GETPROPC`/
  `fuse_getpropc`, and the new 3-slot driver
  (`Fusion3Match`/`Fusion3Rule`/`run_fusion3_rule`) with
  `FUSION_INC_DEC_VAR`/`fuse_inc_dec_var`.
- `src/compiler/context.c3` — the GETPROPC and INC_VAR/DEC_VAR hand-written
  passes replaced with single calls to `fuse_getpropc`/`fuse_inc_dec_var`;
  the comparison-fusion and both copy-prop/DCE passes are unchanged.
- `test/golden_bytecode/*.js`, `*.expected` — added `getpropc` and
  `dec_var` goldens (6 total now, up from 4); `inc_var` already existed
  and stays byte-identical post-port, proving INC_VAR's driver swap.
- `scripts/run_golden_bytecode.py`, `justfile` — unchanged (already wired
  from the ADDI/SUBI port).

### Final tally

| pass | status | mechanism |
|---|---|---|
| ADDI/SUBI | declarative | `FUSION_ADDI_SUBI` / `run_fusion_rule` (pre-existing) |
| GETPROPC | declarative | `FUSION_GETPROPC` / `run_fusion_rule` + `ctx` |
| INC_VAR/DEC_VAR | declarative | `FUSION_INC_DEC_VAR` / `run_fusion3_rule` (new 3-slot driver) |
| comparison → JMP_N*/JMP_* | hand-written (deliberate) | jump-target bitset + dual-path liveness + bridge/short-circuit patches don't amortize over a second caller |
| copy-propagation (LDREG elision) | hand-written (deliberate) | DCE/copy-prop, not fusion — no new opcode, no trigger/consumer pattern |
| dead-LDREG-before-INC elision | hand-written (deliberate) | same — pure DCE |

3 of 5 fusion-shaped passes are now declarative (all 3 that are actually
superinstruction fusions in the "N ops → 1 new op" sense); the comparison
fusion is a real branch-rewrite with correctness machinery that has no
second caller to justify generalizing; the two copy-prop/DCE passes were
never fusions to begin with.

### Gaps / follow-ups

- The golden suite has 6 goldens (up from 4): `fib_subi`, `loop_addi`,
  `sub_out_of_range` (ADDI/SUBI), `inc_var`, `dec_var` (INC_VAR/DEC_VAR),
  `getpropc` (GETPROPC). No golden yet exercises the comparison fusion's
  offset-clamp guard (`sbx+1` overflow) or its bridge/short-circuit
  patches — worth adding if that pass is ever touched, declarative or not,
  since it's the most correctness-fragile of the six passes in `finish()`.
- `run_fusion_rule` and `run_fusion3_rule` both still assume a single
  register is the sole liveness-tracked/shared value per rule (`dest_reg`
  in `FusionMatch`, `reg` in `Fusion3Match`). Holds for all three ported
  rules; would need splitting if a future rule's trigger register and
  rewritten-destination register diverge.
- If the comparison fusion is ever ported, the natural shape is a third
  driver (not a retrofit of the two above) that owns: building the
  jump-target bitset once per `finish()` call, a `Fusion2PathMatch` result
  carrying both liveness-scan starting points, and a dedicated rewrite step
  that installs the fused branch op in slot `i` and NOPs slot `i+1` (mirror
  image of the current NOP-then-consumer geometry, since here the surviving
  slot is first, not second).
