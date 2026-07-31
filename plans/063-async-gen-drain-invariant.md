# Plan 063 — Async-generator drain: separate the GC root from the re-entrancy guard

## Symptom

After any `throw()` that rejects, an async generator's request queue stops
draining permanently. Every later `next()` / `return()` / `throw()` returns a
promise that never settles.

Four probe shapes, each verified against node:

| | ours | node |
|---|---|---|
| A `throw` @ SUSPENDED_YIELD | matches | matches |
| B `throw` on COMPLETED gen | follow-up `next()` never settles | `{done:true}` |
| C two `throw`s queued @ SUSPENDED_START | 2nd throw *and* `next()` never settle | both settle |
| D `throw` @ START then `return()` | `return()` never settles | `{value:9,done:true}` |

test262 covers only the narrowest slice (2 tests:
`built-ins/AsyncGeneratorPrototype/throw/throw-suspendedStart{,-promise}.js`).
C and D have **no coverage at all**, which is why this survived a recorded
0-fail gate.

Sync generators are unaffected — all six sync variants (throw/return at start,
next-after-throw, next-after-return, next-after-done, throw-after-done) match
node. The defect is async-specific and confined to `async_gen_drain`.

## Root cause: one field, two lifetimes

`GeneratorState.ag_current_request` (`src/heap.c3:283`) is overloaded:

1. **GC root.** `mark_generator_state` (`src/heap.c3:2141-2144`) marks it. A
   dequeued request lives in a C3 local the mark phase cannot see, so
   `async_gen_dequeue` parks the promise here (documented at line 284) or the
   next allocation can sweep the promise it is about to settle.
2. **Re-entrancy guard.** `async_gen_drain` bails at line 325 on
   `ag_current_request != null`, meaning "a body resume is outstanding".

These two roles have **different required lifetimes**:

- as a *root*, the promise must stay reachable **through** the settle —
  `async_gen_settle_result` calls `async_gen_iter_result`, which allocates;
- as a *guard*, it must be released **before** the settle — settling runs
  `promise_trigger_reactions` synchronously, and a reaction may enqueue a new
  request and re-enter `async_gen_drain`.

The body-resume path satisfies both by accident of ordering: it clears at
lines 399-400, then settles inside `async_gen_finish_body`. Between the clear
and the settle it holds `promise` in a C3 local — **unrooted**. That path is
correct for re-entrancy and latently wrong for GC; it survives only because no
collection happens in that window today.

The four early-exit paths settle and `continue` without ever clearing:

| site | path |
|---|---|
| `async_generator.c3:332-347` | COMPLETED fast answers (NEXT / RETURN / THROW) |
| `async_generator.c3:359-363` | `.throw()` @ SUSPENDED_START |
| `async_generator.c3:366-371` | `.return()` @ SUSPENDED_START |
| `async_generator.c3:455-461` | `async_gen_await_return` PromiseResolve-threw |

so a reaction re-entering after one of those settles sees a stale marker,
returns immediately, the outer loop `continue`s onto a queue it will never
service, and the generator wedges.

The invariant is currently hand-maintained: **correct in 4 places**
(lines 399, 516, 531, 629) and **missing in 4 others**. This is the shape
BACKLOG records for session 302 — "an invariant hand-maintained in N places,
wrong in the copies that omit it" — now recurring in a second subsystem.

## Design

Split the two roles into two fields with honest names. This is a smaller change
than it sounds and removes the whole bug class rather than the four instances.

In `GeneratorState` (`src/heap.c3`), replace `ag_current_request` with:

- `ag_root_promise` — **GC root only**. Set by `async_gen_dequeue`, cleared at
  the single point where the request is fully done. Marked by
  `mark_generator_state` exactly as today (rename the two lines at 2141-2142).
- `ag_body_in_flight` (`bool`) — **re-entrancy guard only**. Set true only
  around an actual body resume or a paused await; false otherwise.

`ag_current_value` keeps its current role (root for the request's completion
value) and is cleared alongside `ag_root_promise`.

Then:

- line 325 guard becomes `if (gs.ag_body_in_flight) return;`
- the settle helpers (`async_gen_settle_result` / `async_gen_settle_reject`)
  become the chokepoint. Give each a `GeneratorState*` and have them, in order:
  1. read the promise,
  2. clear `ag_body_in_flight` (guard released — re-entry may now proceed),
  3. settle + trigger reactions **while `ag_root_promise` still roots it**,
  4. clear `ag_root_promise` / `ag_current_value` after reactions return.

  Step 3-before-4 is the ordering the current body-resume path gets wrong; doing
  it here fixes that latent GC hazard for free.

Every settle in the module then routes through these two functions, so a future
early-exit path cannot reintroduce either defect. Delete the now-redundant
manual clears at 399-400, 516, 531, 629 — the helpers own it.

Document the split at the field declarations: one sentence each on why a single
field cannot serve both roles. Comments describe current code only.

## Blast radius (measured, not assumed)

- **All 9 settle sites already funnel through the 2 helpers** at lines 301/310.
  The chokepoint exists; it simply does not carry the state today. This is why
  the fix is small — no call-site sweep is required.
- **`async_from_sync.c3` does NOT share the defect.** Probed directly: a
  `for await` over a sync iterator whose `next()` throws, and an async iterator
  whose `throw()` rejects followed by a further `next()`, both match node
  exactly. It manages no equivalent in-flight marker. Leave it alone.
- **Sync generators do not share it** (six variants verified). `generator.c3`
  and `vm_generators.c3` are untouched by this plan.

So the change is confined to `async_generator.c3` plus 3 lines in `heap.c3`.

## Scope

Nothing here is externally constrained — this is a new engine and any part of
it is open to change. The reason this plan is deliberately small is *evidence*,
not deference: the surrounding design is already the right one (a FIFO queue,
§27.6.3.x decomposition, a clean settle funnel), and the measurements above show
the defect does not extend past one module. Rewriting more would add risk
without addressing anything that is actually broken.

Two things are worth doing beyond the minimum, because they remove the bug
*class* rather than the four instances:

1. The field split itself (above) — makes the invariant structural.
2. Fixing the latent GC ordering in the body-resume path, which comes free
   with the helper change.

Explicitly rejected, with reasons:

- **Adding four more manual clears.** Reproduces the exact pattern that caused
  this bug (and the four session-302 codegen bugs). The whole point is to stop
  hand-maintaining the invariant.
- **Restructuring the queue or the resume split.** No evidence of a defect
  there; all four probe shapes trace to the marker alone.
- `heap::gs_acquire` refcounting and `is_async_state` flag discipline are
  unrelated — out of scope.

Target diff: ~2 field changes, 2 mark-phase lines, 2 settle helpers gaining a
parameter and ~4 lines each, 1 guard line, 4 deletions. If the change is growing
well past that, stop and report — it means the diagnosis was incomplete.

## Validation

1. Probe shapes A-D all match node byte-for-byte (A must not regress).
2. Both named test262 tests pass via `--single`.
3. `--phase 24 --phase 21`: baseline 5 fails / 3 fails (8 total) → expect 6
   total, zero new.
4. `just rosetta` 41/41 · `just test-golden-bytecode` 28/28 · `just test-local`
   green.
5. GC: run the A-D probes plus `test/async_gen_gc_lifetime.js` under an
   aggressive GC trigger. The clear-after-reactions ordering is the risky part
   of this change; a stale root shows up as a sweep of a live promise.
6. Regression test `test/test_async_gen_drain_reentry.js` covering A-D — C and
   D have no upstream coverage, so this file is the only thing that will hold
   the line.

Tight timeouts throughout: the failure mode is a hang, and a generous timeout
turns it into a "slow run".
