# 107: Covering the deltablue, richards and splay hot paths with the JIT

Status: research complete, one enabling change landed, implementation of the
tier work not started.

Research baseline: `06202904` on the `rat` branch, measured on 2026-10-25 on
Apple silicon (macOS, arm64) with the default `boomkat` target (O2, threaded
dispatch, NaN-boxing). The element-access change described in section 5 is
`412877c8`, on top of that baseline. Recheck the numbers before
implementing anything.

Plan 106 measured the gap to Ignition and named "call-heavy loops" as a
cause. This plan narrows that down: it measures where the three object-heavy
minis actually spend their time, finds the exact instruction at which the
native tier gives up in each of them, and separates the structural blockers
from the ones that are real.

## 1. The measurements

Sampling with `/usr/bin/sample` over a 600-iteration variant of each mini,
`--jit` enabled, deltablue (1600 samples total):

| handler | samples | share |
|---|---|---|
| `vm_dispatch` | 523 | 33% |
| `th_call` | 293 | 18% |
| `th_resume_caller` | 288 | 18% |
| `th_return_general` | 248 | 16% |
| `th_call_native` | 126 | 8% |
| `th_jmp_lt` | 61 | 4% |
| `sljit_function_entry` | 26 | 2% |

Call and return together are 60% of the time. The native tier's own cost is
2%, so the tier is not slow: it is not running.

Where the native tier gives up is visible in the exit histogram. A `SLJIT
exit` line names the bytecode position the native code returned to, so the
position with the most exits is the instruction that ends every native run.
With `SLJIT_STATS` enabled:

| mini | hottest exit | opcode | meaning |
|---|---|---|---|
| deltablue | `removePropagateFrom` pc=32 | CALL | `c.isSatisfied()` |
| deltablue | pc=37 | PUTPROP | `unsatisfied.add(c)` |
| richards | `Scheduler.schedule` pc=6 | CALL | `isHeldOrSuspended()` |
| richards | pc=10 | PUTTHISC | `this.currentTcb = ...` |
| splay | pc=18 | CALL | a method read off the tree node |

Every one of them is a call the native tier cannot expand.

## 2. What was assumed, and what is true

The prior session's note was that two things keep the hot loops of these
minis out of the native tier:

1. the tier is single-block, so a loop body with an `if` cannot compile;
2. a callee that mutates state cannot be expanded.

Both are true of the loop tier's SSA form. Neither is what stops these
minis today, and both were confirmed with the exit data above:

- The loop tier never runs for any of the three minis. Its planner rejects
  any loop whose body holds a call, and every one of these hot loops calls
  a method. `ssa_loop_eligible` can expand a leaf callee, but
  `loop_analyze` refuses the loop before that check is ever reached, so the
  expansion added in `06202904` is unreachable. The prior session's
  "even with `at()`/`isSatisfied()` expanded" assumed the planner accepted
  the call.
- The function tier is the tier that runs, and it does compile these
  functions. It gives up at the same calls, for a different reason: the
  callee is not a leaf.

So the binding constraint is not the shape of the control flow. It is that
the callees at the hot call sites cannot be expanded.

## 3. Why the callees cannot be expanded

`function_inline_general_body` accepts a callee that reads fields of `this`,
reads and writes properties, does arithmetic and compares, and branches
forward. It rejects a callee that calls anything, and it cannot handle a
call site whose callee differs between receivers.

| site | why it is rejected |
|---|---|
| `c.isSatisfied()` (deltablue) | the receiver is sometimes a `UnaryConstraint` and sometimes a `BinaryConstraint`, so the site cache names one prototype and the other receiver fails the callee identity guard |
| `this.task.isHeldOrSuspended()` (richards) | the callee itself calls two more methods, so the body is not a leaf |
| `this.rotateRight()` (splay) | the callee calls other methods, so the body is not a leaf |

Two features would follow from that table, and neither is the CFG work:

- **Multi-level expansion.** A callee that calls other methods could be
  expanded with its own calls expanded in turn. The receiver stays the
  same, so the inner sites are monomorphic and expand cleanly. The cost is
  a second register window, since the nested callee needs its own frame,
  and a save stack for `this`, because the nested expansion installs its own
  receiver in the same register the outer expansion is using.
- **Multi-target expansion.** A site whose callee differs between receivers
  could expand one target per receiver shape, each with its own identity
  guard. The site cache holds one prototype chain, so the extra targets
  have to come from a runtime history the cache does not keep yet.

## 4. The control-flow blocker is real, but separate

The loop tier's SSA form is single-block: `ssa_loop_eligible` requires the
backedge to be the only branch. The straight-line tier below it already
accepts forward branches, so the shape is not missing from the engine, only
from the tier that keeps values in registers.

The work, when it is done:

- **Blocks.** Split the body at every forward branch target. Each block
  keeps its own register state; the block's entry state is the merge of its
  predecessors' exit states.
- **Join phis.** Where the predecessors disagree about a register, the
  join needs a phi. The join phi's home is written by each predecessor
  before it jumps, which is the same parallel-copy problem the latch
  already solves, and the same solution applies: a home that no incoming
  value can hold, so the copies cannot form a cycle.
- **Conditions.** The compiler fuses a comparison with its branch, so an
  arm's condition is usually a `JMP_*` comparison, which the tier's
  condition machinery already builds. An arm that tests a value's
  truthiness needs a new operation: the tier has no truthiness test, and
  one on a boxed boolean is only a payload test, but one on an arbitrary
  value is a tag dispatch.
- **Comparisons.** The tier has no comparison operation, so `if (a[i] > 0)`
  needs one that produces a boolean.

That is roughly 500 lines in the SSA tier, and it is worth doing on its own
terms: it lets the tier compile the numeric loops with a branch inside
them, which are common and which it currently rejects.

## 5. What was landed

The one blocker that turned out to be both real and cheap was the array
element access. A helper that returns the element at an index, or stores
one, could not stay native, because the compiler only knew how to look up
a property by name: a numeric key always fell back to the interpreter, and
so did the loop around it.

`412877c8` adds the dense-part path to the function tier's property
emitter. A numeric key on an array reads or writes the dense element
directly, after checking that the receiver is an array whose indices live
in the dense part, that the index is inside it, and that no string sits in
the slot. Everything else, a hole, a named index property, a string, an
index past the end, still leaves to the interpreter, which owns those
paths. A helper that stores into an element is now expandable as well.

A loop that stores through a helper runs about twice as fast as the
interpreter, and a helper that only reads an element is expanded.

The change also fixed a latent fault: the loop tier read the operand of a
truthiness backedge as a register, reaching outside the register file,
because such a branch packs its operand into the offset field. Such a
backedge is now rejected up front.

## 6. What the three minis need, in order

1. **Multi-level expansion** in the function tier, so a callee that calls
   other methods expands with them. This is what richards and splay need.
   The second register window and the `this` save stack are the two pieces
   of machinery it needs.
2. **Multi-target expansion** at a site whose callee differs between
   receivers, so the callee identity guard stops ending the native run.
   This is what deltablue's `isSatisfied()` needs.
3. **The CFG loop tier**, which lets the register-allocating tier compile a
   loop whose body has an arm, and which needs the comparison and
   truthiness operations the tier lacks.

Each step is worth measuring on its own. The order matters: steps 1 and 2
move the three minis, step 3 moves the numeric loops with a branch inside.

## 7. Validation gates for any of the three

- `just test-local`, `just modules`, `just rosetta`.
- The interpreter and `--jit` must print the same bytes for every mini.
  Note that `pdfjs` already differs between the two on the baseline
  commit: the native tier miscompiles the string it reports as malformed.
  That is a separate fault and it predates this plan.
- A microbenchmark per step, in the shape of the site it targets: a helper
  that calls a helper, a site with two receiver shapes, a numeric loop with
  an `if` inside.
- The non-NaN-boxing build, which has no JIT and must stay unaffected.
