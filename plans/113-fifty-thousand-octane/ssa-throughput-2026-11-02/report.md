# SSA throughput pass: scratch pooling, dictionary reads, self-healing tiers

Work is confined to rat (commits 29da643a and ea96005b on top of 252ff89e); this
evidence lives on plans/archive. Main was not modified. The 50,000 full-Octane
target remains open.

## What changed

- Pooled SSA invocation scratch. One allocation per concurrent activation now
  carries every array an invocation needs (loop state, spills, edges, inputs,
  outputs, saved bits, roots, root maps and ordering), taken from a plan-owned
  free list, instead of nine heap allocations and frees per native entry. Each
  carved array is independently rounded to eight bytes so the pointers the
  generated code publishes stay aligned for any capacity, including the odd
  one-element maps the sparse-import fixtures exercise. This accounting error
  was a real heap overflow: the first ASan build caught the root maps writing
  one byte past the block for a 900-register fixture.
- Dictionary-mode receivers cache inherited reads. The IC records
  `receiver.prop_count + 1`; appending a key bumps the count, so the identity
  and shape guards stay valid and a shadowing own store invalidates the entry.
  The template tier revalidates the same count inline before every chain walk,
  and method inlining refuses such sites. This was the root cause of the
  Gameboy regression: `GameBoyCore` is a >64-property dictionary object, and
  every `GETTHISC`/`GETPROPC_CACHED`/`PUTTHISC` became a per-execution helper.
- Feedback-driven plan rebuilds. A helper site whose IC later became
  specializable asks for one rebuild; the next gateway outside every generated
  frame (`jit_native_active == 0`) frees and recompiles the plan so the site
  joins the native body. Two rebuilds bound the retry. A plan pointer held
  across evaluation can therefore be replaced, which is the same contract the
  dependency-invalidation path already had; three fixtures that inspect a
  specific specialization now opt out with `Heap.jit_hold_tier`.
- Helper-dominated demotion. When a whole-body specialization spends more
  helper calls than its own entries past a 256-call sample, the function
  recompiles on the baseline template tier. Measured on the minis this is
  worth ~12% on Gameboy and ~6% on Box2D; a plain SSA rebuild instead of a
  demotion loses 1.58x on Gameboy, so the baseline tier really is the right
  destination for those bodies.
- Whole-body SSA attempt bound. Bodies above 320 opcodes keep the baseline
  tier (Mandreel 576 -> 556 ms, Gameboy 246 -> 229 ms measured A/B). Failures
  are memoized per function (`sljit_ssa_failed`) instead of retried. The bound
  is `Heap.jit_ssa_body_ops` for hosts with larger hand-built bodies, and
  `jit_stress` mode lifts it so the differential setting compiles everything.
- SSA opcode coverage: UNM lowers through the typed scalar path, UNP/LNOT/
  INSTANCEOF and the nullish branches (JMP_NULL/JMP_NNULL, tag-delta compare)
  enter the graph; the vm-step admission list matches.
- Threaded re-entry guard: returning into a native frame no longer dispatches
  a second gateway over the same activation.
- Stats: per-site helper call counts, per-plan helper totals (now
  unconditional, demotion reads them) and per-PC native read counters.

## Performance evidence

Matched screen, three alternating pairs, historical b85ef0ba binary versus
final head (median of interleaved runs; raw data in `summary.json`/`raw.json`):

| Mini | b85ef0ba ms | rat ms | ratio |
|---|---:|---:|---:|
| Gameboy | 272 | 229 | 1.19x faster |
| Box2D | 202 | 268 | 0.75x (open regression) |
| DeltaBlue | 88 | 91 | ~equal |
| Crypto | 175 | 186 | 0.94x (pre-existing gap) |
| Mandreel | 552 | 553 | ~equal |
| NavierStokes | 293 | 137 | 2.14x faster |

Session trajectory for the two repaired regressions: Gameboy 403 -> 234 -> 229
(historical 272-277), Mandreel 583 -> 561 -> 553 (historical 552-565). The
early screen (before the scratch and policy work settled) is archived as
`screen-early-summary.json`.

The machine load swung between 0.5 and 26 during the day; one screen that ran
under load 26 produced 2-3x inflated absolute numbers on both binaries and was
discarded in favor of the calm-load rerun. All comparisons are interleaved
min-of-N for this reason.

## Crash found and fixed

The embedding JIT suite crashed with EXC_BAD_ACCESS after four PASS lines.
Two independent causes, both found with an ASan embedding target
(`embedding_jit_asan`, sanitize+debug-info variant of the same target):

1. Scratch accounting: `ssa_align8(cap * uint::size * 2)` under-counts two
   separately aligned maps when `cap` is odd (an 8-byte overrun on a
   24128-byte block for a 900-register, capacity-1 fixture).
2. Plan replacement: the rebuild gate frees a plan that a holder may still
   read (use-after-free of `plan.ssa_region` in the boolean fixture). The
   gate now honors `jit_hold_tier`, and fixtures that assert a specific
   specialization set it.

## Validation

- `./out/embedding_jit`: 29/29 PASS, rc 0; ASan build clean, 29/29.
- `./out/jit_api` passes; `scripts/run_jit_diff.sh` matches (test-local,
  rosetta, modules); `test/run_local.sh` 39/39 on the full-ICU build.
- test262 subsets all green: unary-minus 14/14, unary-plus 17/17,
  logical-not 19/19, property-accessors 21/21, relational 1/1, delete 69/69,
  statements/if 69/69, statements/with 181/181.

## Remaining work

1. Box2D remains 0.75x. `SolveVelocityConstraints` (id=728, 605 ops, 63
   registers) rejects whole-body SSA at emission and falls to a region tier
   that makes 7.25M generic native reads per run; the bound now keeps it
   there by design, so the fix is either cheaper emission for very wide
   bodies or a typed access path in the region tier.
2. Crypto sits at 0.94x, unchanged since before this pass.
3. Review and measure the guarded integer-capture candidate 842bbca3
   (branch rat-ssa-continuations); cold-this helper fast path is still only
   in .worktrees/rat-ssa-optimization, unvalidated.
4. Full original Octane matched pairs at this head have not been collected
   yet; the mini screen is the only current evidence.
