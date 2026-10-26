# 107: Covering the deltablue, richards and splay hot paths with the JIT

Status: the loop tier's arms, the array element read, RETUNDEF, loose
equality and multi-level expansion landed. Object-valued property stores
are the next blocker; see section 10.

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

## 4. The control-flow blocker, and the tier that now handles it

The loop tier's SSA form was single-block: `ssa_loop_eligible` required the
backedge to be the only branch. The straight-line tier below it already
accepted forward branches, so the shape was not missing from the engine,
only from the tier that keeps values in registers.

That tier now compiles a body with arms (`9da13ba4`):

- **Blocks.** The body is split at the branches. A block starts at the
  body's head, after a conditional branch (the arm that falls through) and
  at the target of a forward branch; it ends at the branch that leaves it.
- **State per block.** Each block keeps its own register state, and the
  state a block starts with is the merge of its predecessors' states.
- **Join phis.** Where the predecessors disagree about a register, the join
  holds a merged value, and each predecessor writes it on the way in, so
  the path that arrives carries its own value. The merged value takes the
  first incoming's representation, and a copy from a predecessor with
  another one converts.
- **Conditions.** The compiler fuses a comparison with its branch, so an
  arm's condition is usually a `JMP_*` comparison, which the tier's
  condition machinery already builds. A truthiness test of a number or of a
  boolean is supported; a truthiness test of an arbitrary value is not,
  because it needs a tag dispatch.

A loop with an arm runs about 2.4 times faster than the interpreter, and
2.4 times faster than the straight-line tier that used to run it.

## 5. What was landed

Two capabilities came out of this, and one fault they uncovered.

**Array element reads** (`412877c8`). A helper that returns the element at
an index could not stay native, because the compiler only knew how to look
up a property by name: a numeric key always fell back to the interpreter,
and so did the loop around it. The function tier's property emitter now
answers a numeric key on an array from the dense part, after checking that
the receiver is an array whose indices live in the dense part, that the
index is inside it, and that the slot is not a hole. Everything else, a
named index property, an index past the end, a receiver that is not an
array, still leaves to the interpreter, which owns those paths. A helper
that only reads an element is expanded, and a loop that reads through one
runs about twice as fast as the interpreter.

**Array element writes** were tried and taken back (`a18af0ad`). Storing
into the dense part has to consult the prototype chain, because an
inherited index setter has to see the write, and it has to keep the array's
hole count in step, because that count decides whether a frozen array still
holds live elements and whether a prototype can intercept an indexed store.
Skipping both let the TypeScript compiler's own scanner mis-parse its input
under the JIT, which is how the fault surfaced. Writes stay with the
interpreter.

**The loop tier's arms** (`9da13ba4`), described in section 4.

The work also fixed a latent fault: the loop tier read the operand of a
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

Step 3 is done. Each step is worth measuring on its own, and the order
matters: steps 1 and 2 move the three minis, step 3 moves the numeric
loops with a branch inside.

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

## 8. The callees are rejected for four different reasons

A later session dumped the actual rejected callees with `SLJIT_STATS` and
the bytecode disassembler instead of reading the predicates. The blockers
are mostly not call depth:

1. **`RETUNDEF` was not in the general-inline opcode set.** An implicit
   `return;` is the normal shape of a setter, so this alone rejected
   `TaskControlBlock.markAsHeld`, `markAsSuspended`, `OrderedCollection.add`
   and the rest of that family.
2. **A call inside the callee.** This is the real depth work
   (`suspendCurrent -> markAsSuspended`, `add -> elms.push`).
3. **No resolved target at all.** Many sites never name a callee: the
   property IC chain is not the immediate prototype (`chain_len != 1`), or
   the site has not warmed. Some of these are multi-target sites; others are
   simply cold.
4. **Non-call gaps.** Object-vs-object `==`/`!=` exited through the numeric
   path (deltablue's `c != determining`), `x == null` exited the same way,
   an array `.length` read inside a helper tripped a guard, and stores of
   object-valued properties are refused outright by the property emitter
   (`guard(GREATER, tag, TAG_BOOLEAN)` on both the old and the new value).

The function tier was also the tier doing the work: `loop_analyze` rejects
any loop whose body contains a CALL, so `ssa_loop_eligible`'s leaf-call
expansion is unreachable for these loops.

## 9. What landed on top of section 5

- **A real replay guard** for expanded callees. A guard that fires after a
  partial inline run makes the interpreter rerun the callee, so a store the
  native run already made would happen twice. The old check was a stub (the
  key arrays were never filled). Now a store whose value depends on a
  property read may not be followed by an instruction that can exit.
- **`RETUNDEF`** in the predicate and the emitter. `holdCurrent` now runs
  fully native in richards (`returns=1000`, one inline per call).
- **Loose equality**: object-vs-object compares by reference, and
  null/undefined compare equal to each other and to nothing else. This
  removed deltablue's `NEQ` exit and richards' `t == null` exit in
  `Scheduler.queue`.
- **Multi-level expansion**, with one register window per nesting level in
  `FunctionRun.inline_values` and the receiver kept in a spare slot of that
  window rather than in a saved register. That last detail matters: a
  memory save of `reg_s(3)` across the body corrupted deltablue, and the
  window slot is both simpler and correct at any depth. The nesting bound
  is `INLINE_DEPTH = 4` (three nested callees).
- **Stuck-entry detection**: an entry that returns at the same
  unexpandable CALL without completing a backedge is disabled after eight
  attempts, so the tier stops paying an entry and exit per loop iteration
  for a call it can never take.
- `SsaEmitter.resolve_blocks` gained the `@feat(SLJIT)` it was missing,
  which is what broke the no-SLJIT `boomkat_debug` target.

Measurements, same machine, default target, single run each: crypto
301 -> 150 ms and navier-stokes 561 -> 246 ms with `--jit`. The three
object-heavy minis are still slightly slower with the JIT (deltablue
305 -> 314, richards 230 -> 240, splay 122 -> 134). Their hot regions still
bail: deltablue at `todo.size()` and at object-valued stores, richards at
`this.currentTcb = this.currentTcb.link` (an object store) and at
`t.checkPriorityAdd(...)`, splay at node property guards after the node
shape changes.

## 10. Next, in order

1. **Object-valued property stores.** This is the largest remaining single
   blocker: richards' `schedule` and `queue`, and most of deltablue's
   planner, stop at a store of a reference. It needs the same
   incref-new/store/decref-old sequence that `function_store` already does
   for registers, with no exit between the incref and the decref.
2. **The property guard bails.** Deltablue's inlined `size()` still exits
   on the `this.elms.length` guard, and splay's loop exits on node shapes
   that gain `left`/`right` own properties. Both need to be reproduced in a
   micro before changing the emitter.
3. **Multi-target expansion** at a site with two receiver shapes
   (deltablue's `isSatisfied`), which needs the site cache to hold more
   than one callee.
4. Native builtin calls (`Array.prototype.push`) are still interpreter
   work at every `add`; a direct call form would remove the interpreter
   round trip from the `todo.add(...)` sites.

## 11. Object-valued stores, and what they did not fix

The property emitter now stores a traced object when no write barrier is
required: the collector is not marking, and either the owner is young or the
value being stored is already old. Strings stay with the interpreter because
only they are reference counted. This removed richards' `schedule` exit at
`this.currentTcb = this.currentTcb.link`, so that region now runs from the
loop head to the `run()` call.

It did not move the timings, and profiling explains why. The three minis
spend their time in native builtin calls, not in reference stores:
deltablue's `addPropagate` exits at `todo.removeFirst()`, whose body is
`this.elms.pop()`; the expanded `size()` in the loop condition is fine. A
`pop`/`push` call is a full interpreter call inside an expanded body, and
neither has a native form.

Two other facts matter for what comes next:

- The function tier compiles and enters a region, exits at the first
  non-expandable call, and re-enters at the next block; the call itself is
  the cost, so removing calls is the only thing that moves these minis.
- A callee's own property cache is often cold, because the interpreter
  never runs the callee once the call is expanded. An inlined body then
  emits an exit at the call site for its first property access. Borrowing
  the call site's receiver shape was tried and did not help: the hot
  accesses either live on a prototype or the call-site cache was cold too.
  Plan recompilation on a warm cache, or the absent-append store form, is
  the real answer.
