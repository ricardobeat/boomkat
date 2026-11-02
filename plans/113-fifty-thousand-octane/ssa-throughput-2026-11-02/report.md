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

## Second pass: dead jumps, the append guard, and where Box2D's time goes

Two commits after the pass above, both on rat: 360d596e drops the jump an `if`
emits over its alternative when the consequent cannot fall through, and
ac3e695d fixes an inverted prototype-chain guard in the template tier's
property append.

### Append guard

`FunctionEmitter.append_property` walks the receiver's prototype chain and then
must confirm the walk ended at the chain terminator. The guard tested `r3 == 0`
and bailed when it held, so the inline store bailed exactly when the chain was
the one the cache recorded and continued only when another link remained. No
constructor ever took the inlined append; every `this.x = ...` left to the
interpreter after the entry cost had been paid. On a fixture of 300k
`new P(...)` calls with six appends, the body moved from stalling at pc 0 on
every call to exiting at its ordinary `RETUNDEF` (283k of 284k runs), and the
plan stays active. The mini screen is insensitive to it (Box2D runs three
iterations, so ~50k constructor calls are amortised): Box2D 218 vs 218 ms,
Mandreel 565 vs 566, Gameboy 221 vs 222, DeltaBlue 91 vs 91, Richards 69 vs 70,
and 19.5 s vs 19.6 s on a 300-iteration Box2D fixture.

### Screen at this head

Two full screens, four and three alternating pairs, at load 2.7 and 5.7
(`/private/tmp/octane-20261102` and `...02b`); they agree to 0.2%.

| Benchmark | b85 ms | rat ms | ratio |
|---|---:|---:|---:|
| Richards | 69 | 70 | 0.986 |
| DeltaBlue | 89 | 91 | 0.978 |
| Crypto | 176 | 180 | 0.978 |
| RayTrace | 161 | 165 | 0.976 |
| EarleyBoyer | 175 | 174 | 1.006 |
| RegExp | 226 | 223 | 1.013 |
| Splay | 108 | 112 | 0.964 |
| NavierStokes | 299 | 106 | 2.821 |
| PdfJS | 362 | 347 | 1.043 |
| Mandreel | 551 | 565 | 0.975 |
| Gameboy | 272 | 219 | 1.242 |
| CodeLoad | 160 | 156 | 1.026 |
| Box2D | 201 | 218 | 0.922 |
| zlib | 3725 | 3549 | 1.050 |
| TypeScript | 1236 | 1265 | 0.977 |

Geometric mean **1.078**. That is the best measured against the historical
binary (previous passes: 1.058, then 1.069, then 1.066), and Box2D moves from
0.768 to 0.922 — still 8.5% behind, confirmed separately with nine interleaved
pairs (200 vs 217 ms) and on the 300-iteration fixture (18.3 s vs 19.3 s,
1.051). Both binaries' sample profiles are close: the head spends 14.5% against
12.8% in `th_getpropc_cached` and 2.5 points less in generated code, so the
remaining Box2D gap is about coverage rather than a new hot path.

### Where the interpreter time actually is

Box2D's mini run executes 31.5M interpreter dispatches. Grouped by the plan the
rejection census reports for each function:

| Plan state | Functions | Dispatches | Share |
|---|---:|---:|---:|
| compiled | 129 | 28.44M | 90.3% |
| code budget | 57 | 1.93M | 6.1% |
| not attempted | 150 | 0.26M | 0.8% |
| mapped arguments | 1 | 0.85M | 2.7% |

So the cost is not the functions the tiers refuse; it is the parts of compiled
functions their plans do not cover. The hottest body is `SolveVelocityConstraints`
(605 ops, id 728): its plan is a 256-op region from pc 33 that hit 78.5k times
and exited at a `CALL` 38.9k times, never returning natively. A sample of the
300-iteration fixture puts `th_getpropc_cached` at 918 of 6175 self samples
(14.9%), and every one of those samples has `vm_dispatch` as its parent: the
helper's cost is the threaded interpreter, not the native call-out path.

### The SSA read refusal is not the blocker

`ssa_body_reads_lowerable` refuses a body when any cached read cannot be
lowered, and instrumenting it over Box2D shows 22 refusals:

| IC chain form | Sites |
|---|---:|
| `IC_CHAIN_EPOCH` (one link plus a mutation epoch) | 16 |
| `IC_CHAIN_POLY` (own read over several receiver shapes) | 2 |
| `IC_CHAIN_PROTO` (epoch plus one arm per receiver shape) | 2 |
| one-link snapshot with `dict_count == 0` | 2 |

Not one is a depth-2 chain, and none is a form the template tier cannot
already lower: `FunctionEmitter.property` has arms for the epoch, polynomial
and proto caches and for bounded snapshots. Teaching the SSA tier the same
forms would move those bodies between tiers, not remove interpreter work,
because those bodies already run native with inlined reads. The premise behind
"lower reads into the SSA tier" was wrong, and it was dropped after this
measurement rather than after an implementation.

### Code density, and three experiments that did not pay

Generated bodies run 220-700 bytes per bytecode op (about 350 on average), and
126 Box2D plans fill 2.10 MB of the 4 MB arena. The dominant contributors, by
per-op byte span (`SLJIT_MAP` maps): computed `GETPROP` at 3.2 KB per site (the
`indexed` path expands a `dense_element` copy, up to eight typed arms and a
guarded property fallback at every site: 344 KB, 23% of all body bytes), the
typed-read store at 208 B, and the counted-store sequence in `function_store`
at about 110 B repeated at every register store.

Three attempts to convert that into time were measured and discarded:

- Exiting to the interpreter whenever either side of a store is a string cut
  body bytes 7.6% and admitted nine more plans, and won on Gameboy (0.923) — but
  it stalls and retires any loop that assigns one string over another, so it
  was rejected on behaviour, not on speed.
- The sound version, an out-of-line counted store (`sljit_native_store`, called
  once per store that touches a string, fenced off when the body keeps a
  numeric value in a caller-saved float lane), is exactly what the interpreter's
  `th_move` does. It cut `LDREG` from 188 to 81 bytes per op, `LDINT` from 115 to
  67 and `GETPROPC_CACHED` from 208 to 156, total body bytes from 1.52 MB to
  1.44 MB, and admitted 139 plans instead of 130 — and was timing-neutral at
  load 2.1 (Box2D 1.005, Mandreel 0.996, Gameboy 1.000, DeltaBlue 0.989,
  Richards 0.986). Code size is not the bottleneck.
- A 512-op region window (`FUNCTION_REGION_OPS` 256 -> 512) cost Box2D 7.9%
  (216 -> 233 ms) while helping Mandreel 1.8%, confirming the earlier
  rejection.

Also confirmed: the body the dead-jump commit newly admits on Mandreel and
which demotes is `insertleaf` (line 19280). It is a real loop, but every one of
its 256 sampled entries takes one helper and leaves, so the helper-per-entry
demotion rule is doing the right thing; the cost is one wasted compile.

### The score in Octane terms

`scripts/octane_score.py` restores the missing measurement. It runs a matched
pair of mini binaries and multiplies each benchmark's recorded Octane score by
its measured time ratio, so the composite is the recorded composite scaled by
the geometric mean of the time ratios. Over the thirteen benchmarks the
historical log scored, this head projects **5694 against a recorded 5672**
(ratio 1.0038); Box2D is the largest single loss (7135 -> 6546) and Gameboy the
largest gain (13092 -> 16260).

The 1.078 screen figure is a different number: the screen also covers
NavierStokes, which the historical run failed on a checksum, and its 2.8x
accounts for almost the whole difference. Against the 50,000 target, the head
sits at roughly one ninth of the goal on the thirteen-benchmark basis, and the
earlier "six percent above the historical revision" was the mini geomean rather
than the score ratio — corrected here.

### Validation at this head

`./out/embedding_jit` 30/30, `just test-local` 39/39,
`scripts/run_jit_diff.sh` matches on test-local (pre-existing `status 1`),
rosetta and modules, and test262 `language/expressions/assignment` 485/485,
`built-ins/String` 1223/1223, `language/statements/class` 4353 pass with 14
skips and no failures.

Remaining work

0. Box2D 0.92x, 8.5% behind the historical binary. Coverage of compiled
   functions, not code size, is the cause: 90% of Box2D's interpreter
   dispatches happen inside functions whose plan covers a bounded region, and a
   body like SolveVelocityConstraints exits its region at a `CALL` on half its
   entries and never returns natively. The measured dead ends are code density
   (a 30% smaller store sequence is timing-neutral) and wider regions (512 ops
   costs 7.9%). What remains untried is making a region's `CALL` reach a
   compiled callee: the run links 114k direct calls but only 65k direct
   returns, so a third of the native calls fall back into the interpreter.
   Continuing to chase the 2 MB function-tier budget is not worthwhile now that
   the budget-rejected functions account for 6% of dispatches.
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
