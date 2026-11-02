# SSA throughput pass: scratch pooling, dictionary reads, self-healing tiers

Work is confined to rat (commits 29da643a, ea96005b, 1de6c8dd, 072cb547 and
9b34b0ee on top of 252ff89e); this evidence lives on plans/archive. Main was not modified. The 50,000 full-Octane
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
final head (median of interleaved runs; raw data in `summary.json`/`raw.json`
and the last screen in `final-summary.json`):

| Mini | b85ef0ba ms | rat ms | ratio |
|---|---:|---:|---:|
| Gameboy | 273 | 231 | 1.18x faster |
| Box2D | 202 | 271 | 0.75x (open regression) |
| DeltaBlue | 89 | 91 | ~equal |
| Crypto | 176 | 188 | 0.94x (pre-existing gap) |
| Mandreel | 551 | 563 | ~equal |
| NavierStokes | 302 | 137 | 2.20x faster |

Two later commits change the tier policy again. 1de6c8dd demotes a
specialization when helper calls merely *equal* its own entries, not only when
they exceed them (Gameboy 244 -> 229 ms, Mandreel 576 -> 559 ms, Box2D +2%).
9b34b0ee stops three ways the tier abandoned code it could run: a variable read
no longer bails when the value is plain undefined (only the TDZ sentinel, the
same tag with a nonzero payload, is uninitialized), the no-progress retirement
bound moved from 8 consecutive entries to 64 so cache refills and epoch bumps
cannot kill a hot entry, and an SSA body that refuses every entry abandons
itself for the baseline tier. Measured against the prior head: Box2D 268 -> 257
ms and Gameboy 230 -> 219 ms, with the other four unchanged.

The largest single win is 072cb547, which types a fresh capture read as INT32
from the running closure's own capture slot when that value is exactly an
int32, revalidating every read and resuming the original GETCAP otherwise. Loop
kernels that keep their dimensions in captured variables stop promoting indices
to doubles: NavierStokes drops 136 -> 106 ms, and the full screen puts it at
107 ms against 303 ms historically (2.8x). Score-relevant candidates for the
same treatment are the remaining capture sites typed boxed.

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

## All fifteen Octane benchmarks

The mini screen covers six benchmarks; this one runs the whole set that the
Octane score aggregates, three alternating pairs against the historical binary
(`full-octane-15-summary.json`). Speedup is b85_ms / rat_ms, and the Octane
score is the geometric mean of these rates, so the geometric mean of the time
ratios is the score ratio.

| Benchmark | b85 ms | rat ms | ratio |
|---|---:|---:|---:|
| Richards | 66 | 67 | 0.985 |
| DeltaBlue | 86 | 88 | 0.977 |
| Crypto | 166 | 176 | 0.943 |
| RayTrace | 161 | 161 | 1.000 |
| EarleyBoyer | 175 | 175 | 1.000 |
| RegExp | 221 | 220 | 1.005 |
| Splay | 110 | 114 | 0.965 |
| NavierStokes | 284 | 106 | 2.679 |
| PdfJS | 363 | 354 | 1.025 |
| Mandreel | 552 | 557 | 0.991 |
| Gameboy | 272 | 220 | 1.236 |
| CodeLoad | 160 | 154 | 1.039 |
| Box2D | 202 | 263 | 0.768 |
| zlib | 3721 | 3575 | 1.041 |
| TypeScript | 1238 | 1300 | 0.952 |

Geometric mean **1.058**: the score is about six percent above the historical
revision, carried by NavierStokes and Gameboy. The remaining deficits are Box2D
(23%), TypeScript (5%), Crypto (6%), Splay (3.5%), DeltaBlue (2%), Richards
(1.5%) and Mandreel (1%). TypeScript, zlib and PdfJS are dominated by parser and
allocation work rather than generated code; the four smallest deficits are
within a few milliseconds and were not attributed individually.

## Rejected budget experiments

Three ways of buying Box2D more native coverage were measured and discarded:

- Raising the function-tier ceiling from 2 MB to 4 MB: Box2D 263 -> 250 ms, but
  Mandreel 557 -> 580 ms. The extra coverage is a net loss because the newly
  compiled bodies exit at a `GETPROP` thousands of times each and cover only a
  fraction of their own body per entry.
- `SLJIT_ADAPTIVE` budget growth and eviction: Box2D 264 -> 312 ms and Mandreel
  556 -> 649 ms.
- Evicting cold function plans to stay under the 2 MB ceiling (new victim scan
  limited to function artifacts): Box2D 255 -> 259 ms, Mandreel 557 -> 598 ms.
  Thrash from re-warmed plans costs more than the coverage gains.

The post-call resume fast path was also reconsidered: sample attribution puts
`sljit_function_entry` at 3.6% of Box2D's samples, and its checks (dependency
retirement, read refresh, shape clock, artifact generation) are all load
bearing because a callee may have invalidated any of them. There is no safe
subset to skip, so this was not implemented.

## Box2D investigation findings (open)

Instrumented runs (`SLJIT_STATS --stats` plus sample attribution on both
binaries) located where Box2D loses its 25 percent:

- SolveVelocityConstraints (728) and SolvePositionConstraints (730) interpret
  2.0M extra instructions each against the historical binary. Both have
  compiled 256-op template regions, but 730's entries stall: 34-56 entries
  exit at pc=0 (GETGLOBAL) with zero budget consumed, hit the 8-short-run
  disable, and the entry is abandoned after seven rebuild generations
  (attempts=74 versus 4.9M historically). The same stall exists with the
  dictionary-read commit reverted, so it predates this pass.
- The 2 MB function-tier code budget (`JIT_MAX_CODE_LIMIT`) saturates in both
  binaries, but the historical binary packs 154 functions into it versus 114
  now: the pass spends budget on b2PositionSolverManifold (138 KB, previously
  refused) and on whole-body SSA plans for call-heavy collision helpers whose
  SSA bodies are then demoted. Raising the cap to 4 MB helped Box2D 263 -> 250
  ms but cost Mandreel 560 -> 584 ms, so it was not kept. 512-op regions were
  also tried and rejected (Box2D 251 -> 267 ms).
- Widening a warm region to its enclosing loop header was implemented and
  measured neutral (Box2D 263 -> 266 ms, others unchanged); not kept.

Remaining work

0. Box2D 0.76x after 9b34b0ee. The 2 MB function-tier budget still decides the
   outcome: at 4 MB Box2D reaches 248 ms but Mandreel regresses 557 -> 580 ms.
   Instrumented runs show why the extra coverage hurts Mandreel: the newly
   compiled bodies exit at a `GETPROP` four to forty thousand times each and
   cover only a fraction of their own body per entry, so partial coverage costs
   more than interpretation. A plan needs a release-mode coverage measure before
   the budget can grow, and 730 (SolvePositionConstraints) needs a template plan
   at all, which the full budget currently refuses.
1. Box2D 0.75x: debug why SolvePositionConstraints' template entries exit at
   pc=0 with zero consumed budget (GETGLOBAL IC fill suspected) instead of
   disabling after 8 stalls, and re-balance which functions claim the 2 MB
   function-tier budget.
2. Crypto sits at 0.94x, unchanged since before this pass.
3. Review and measure the guarded integer-capture candidate 842bbca3
   (branch rat-ssa-continuations); cold-this helper fast path is still only
   in .worktrees/rat-ssa-optimization, unvalidated.
4. Full original Octane matched pairs at this head have not been collected
   yet; the mini screen is the only current evidence.
