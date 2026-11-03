# 109: Multi-agent Atomics and `$262.agent`

Status: done, closed 2026-11-03. `built-ins/Atomics` passes 389 of 389 tests with no
skips.

Goal: pass the 112 test262 files that drive a second
agent through `$262.agent`, and make `Atomics`/`SharedArrayBuffer` correct
across threads, not just on one agent. Maximum ES2017 compliance for the
`Atomics` surface.

## 1. Where things stand

`Atomics` and `SharedArrayBuffer` ship single-agent. A scan of test262 gives
`built-ins/Atomics` 275 pass, 0 fail, 114 skipped:

- 112 files call `$262.agent.*` (notify 16, wait 43, waitAsync 53), skipped by
  `AGENT_HARNESS_RE` in `scripts/run_test262.py`.
- 2 `CanBlockIsFalse` files (`wait/cannot-suspend-throws.js` and the bigint
  twin), skipped because the main agent can suspend.

The ES-edition reports count these skips as failures; they are not engine
bugs. `docs/engine-scope.md` called multi-agent coordination out of scope;
this plan reverses that, so the skips and the scope text go away with the
work (see §8). Stage 3 proposals are in scope too (docs fixed in 0d7bc851).

Current limits in the code:

- `ab.data` is a `heap.alloc_func` block owned by one heap; `ab.byte_length` is
  per object, so a grown SAB is not visible to another view of the same block.
- `Atomics.*` read-modify-write is plain `mem::copy`, not atomic.
- `wait` never blocks; `notify` only wakes this heap's `waitAsync` promises
  (`Heap.async_waiters`, a fixed `[64]` array); `waitAsync` timeouts are never
  driven, and a full table degrades to an immediate "timed-out".
- `$262.agent` is an empty object (`agent:{}` in `HOST262_HARNESS`).

Already in our favour: one runtime per thread works (state is `tlocal` or
per-heap; `g_next_rt_id` is already atomic), `NO_SHARED_MEMORY` already gates
the surface for tiny builds, and the interrupt flag is already shared with
watchdog threads via `mem::@atomic_*`.

## 2. Design

### 2.1 Shared block (`src/agent.c3`, module `boomkat::agent`)

A SharedArrayBuffer's bytes live in a libc-allocated block with a 16-byte
header in front of the data (so `ab.data` still points at the bytes and every
existing fast path keeps working):

    struct BlockHeader { uint refs; uint length; uint capacity; uint pad; }

- libc `calloc`/`free`, not the heap allocator: the last reference may be
  dropped by another thread, after the creating heap is gone. The memory limit
  is RSS-based (`boomkat_rss_bytes`), so bypassing `alloc_func` does not
  defeat it.
- `refs` is atomic; the object finalizer releases instead of freeing. A SAB
  object in another heap is created by `adopt` (retain + new object).
- Growable SABs allocate `capacity = maxByteLength` up front (already done)
  and keep the live `length` in the header. `grow` is a CAS loop that fails on
  shrink. Every read of a SAB's length goes through one accessor that reads
  the header for growable shared buffers and `ab.byte_length` otherwise. The
  43 uses of `ab.byte_length` in `typedarray.c3`, `dataview.c3` and
  `arraybuffer.c3` are audited.
- Zero-length SABs get a block too, so they can be shared.

### 2.2 Real atomics

`Atomics.add/and/or/sub/xor/exchange/compareExchange/store/load` use
`std::atomic`/`mem::compare_exchange`/`mem::@atomic_*` at the element width
(1, 2, 4, 8) on shared buffers. Plain ArrayBuffer-backed views keep the
current path (alignment of `alloc_func` blocks is not guaranteed for 8-byte
atomics; shared blocks are 16-aligned). `isLockFree` stays 1/2/4/8.

### 2.3 Waiter table

One process-wide table: a mutex plus 64 hash buckets keyed by the absolute
cell address, each bucket a FIFO list. One lock keeps the protocol simple;
contention is irrelevant at this scale.

    Waiter { next, prev, inbox_next, addr, port, cv, state, async, slot,
             deadline, block }       // state: QUEUED | NOTIFIED | TIMED_OUT | INTERRUPTED

- `Atomics.wait`: compare the cell under the lock (the futex rule: the check
  and the enqueue are atomic with respect to `notify`), enqueue a stack
  waiter, wait on its condition variable until notified or the deadline.
  Result "not-equal" / "ok" / "timed-out". Honours `Heap.agent_no_block`
  (CanBlock = false): throws TypeError, which makes the two CanBlockIsFalse
  files runnable.
- `Atomics.notify`: walk the bucket in arrival order, claim up to `count`
  QUEUED waiters at the address, wake sync ones, move async ones to the
  owner's port inbox. Returns the count.
- `Atomics.waitAsync`: precheck, then enqueue a heap-allocated waiter that
  retains the block and carries the owner heap's slot. Returns
  `{async:true, value: promise}`; `{async:false, value}` for not-equal and
  zero timeout.

### 2.4 Ports and polling

Each heap that waits gets a refcounted `Port` (created lazily; null cost
otherwise): condition variable, async inbox, a host-event flag, an atomic
`pending` word, and the currently blocked sync waiter. Because it is
refcounted, a host agent record can hold it past the heap's lifetime.

- `Heap.async_waiters` becomes a growable array of `{promise, node}`
  (no 64 cap). The node holds a block reference, so the entry no longer roots
  the buffer; the promise stays rooted until settled. Both GC root loops
  (`heap.c3`, `gc/gc_roots.c3`) are updated.
- `agent::poll(heap, vm)` settles inbox entries with "ok" and expired
  deadlines with "timed-out", claiming the waiter under the lock so a racing
  notify and timeout settle exactly once. It resolves promises only; no JS
  runs inside it.
- `Heap.drain_microtasks` calls the poll hook between jobs when a port exists
  (`agent_poll_fn`; a null check otherwise). This is what lets the harness's
  busy-polling `setTimeout` polyfill observe cross-agent notifications.
- `agent::wait_events(heap, max_ns)` blocks on the port until an inbox entry,
  a host event, an interrupt or the earliest deadline.
- `agent::run_event_loop(heap, vm)` for hosts: drain, poll, then wait while
  async waiters remain, stopping when none remain or when only deadline-less
  waiters remain and no other agent is registered (`agent_enter`/`agent_exit`
  keep an atomic live count). Used by the CLI, the test262 runner and agent
  threads.
- Same-agent `notify` of a same-agent `waitAsync` keeps its current
  behaviour (promise settled before `notify` returns) by polling the own
  inbox right after the notify.
- `bk_request_interrupt`/`JsRuntime.request_interrupt` also call
  `agent::wake_interrupt`, so a watchdog can break a blocked `Atomics.wait`.
  The woken wait throws the existing uncatchable interrupt.

### 2.5 `$262.agent` (test262 host, `src/builtins/test262_agent.c3`)

Installed with the other `$262` host hooks, gated by `SHARED_MEMORY`.

Main side: `start(src)`, `broadcast(sab[, id])`, `getReport()`, `sleep(ms)`,
`monotonicNow()`. Agent side: `receiveBroadcast(cb)`, `report(v)`,
`leaving()`, `sleep`, `monotonicNow`.

- An `AgentGroup` (thread-local on the main thread) owns the agent records and
  the report queue, so a lingering agent can never leak a report into the next
  test. Records reference a `Port`.
- `start` copies the source, spawns a thread with a large stack, and blocks
  until the agent has created its heap and VM. The agent evaluates the source
  as a sloppy script in its own heap, then loops: poll, take host events,
  run `receiveBroadcast`'s callback with an adopted SAB (+ id), drain, wait.
  `leaving()` ends the loop after the current job.
- `broadcast` retains the block once per live agent, posts, and blocks until
  every agent has taken the message.
- Shutdown (end of each test, and CLI exit): flag every agent, interrupt-wake
  its port, join. The runner and CLI call it from a `defer`.
- `$262.agent.start` is main-only; agent heaps get the agent-side object.

### 2.6 Runner

- `HOST262_HARNESS` takes `agent` from the C-level `$262` instead of `{}`.
- Before each test, `agent_no_block` is set iff the frontmatter has
  `CanBlockIsFalse`.
- After the script phase, the runner calls `agent::run_event_loop`, then
  verifies `$DONE` as today. Replace the 1000-iteration drain cap.
- Remove `AGENT_HARNESS_RE`, its skip, and the `CanBlockIsFalse` skip from
  `scripts/run_test262.py`.

## 3. Build matrix

`boomkat` (threaded dispatch), `boomkat_slim`, `boomkat_tiny*`
(`NO_SHARED_MEMORY`), `boomkat-full-icu`, nonanbox, ASAN, the C ABI libraries
and the examples must all still build. The new module compiles everywhere
and is unused under `NO_SHARED_MEMORY`.

## 4. Verification

1. Focused: `built-ins/Atomics`, `built-ins/SharedArrayBuffer`,
   `built-ins/ArrayBuffer`, `built-ins/TypedArray*`, with the skips removed.
2. Repeat the 112 agent files 20 times each; the harness timeouts are
   generous but real, so flakiness is the main risk.
3. Full test262 before and after: no regressions in the pass counts.
4. `just test-local`, `rosetta`, `modules`; Linux/ASAN via the container
   workflow (see the local-validation notes). A thread sanitizer pass over the
   agent tests if the toolchain allows it.
5. Memory: `just check-heap-drift` for the new `Heap` fields; leak checks on
   the agent tests (blocks, ports, waiter nodes, threads joined).
6. Single-agent perf: a null check in the drain loop only; confirm with
   `just bench-fast`.

## 5. Phases (each committed separately)

1. Shared block + accessor audit + real atomics (no threads yet).
2. Waiter table, blocking `wait`/`notify`, `agent_no_block`.
3. Ports, growable async waiters, timeouts, `poll`/`run_event_loop`, drain
   hook, interrupt wake; CLI and runner event loop.
4. `$262.agent` host and agent threads; runner wiring.
5. Remove the skips, update docs (`engine-scope.md`, `features.md`,
   `test262-comparison.md` if affected, CHANGELOG), full validation.

## 6. Risks

- Spurious wakeups and lost wakeups: the cell compare and enqueue share one
  critical section, and every wait loops on waiter state.
- Teardown races: nodes are unlinked under the table lock before a heap is
  reset or destroyed; ports are refcounted; blocks are refcounted.
- GC: the promise is rooted by its heap entry until settled, and settling
  clears the entry before resolving, as the existing code does.
- Non-atomic reads of shared memory from plain typed array loads are
  relaxed, as in other engines.
- Test duration: `getReportAsync` polls at 1 s through the harness polyfill,
  so each async agent test takes seconds. Parallel workers absorb it.

## 7. Out of scope

Structured clone of arbitrary objects between agents, Worker APIs, and a
public C API for sharing buffers between runtimes (the `adopt`/`share`
primitives are the seam for it, to be exposed separately).

## 8. Documentation to change when done

`docs/engine-scope.md` (the multi-agent bullet and the single-agent
SharedArrayBuffer line), `docs/features.md` (Multi-agent row),
`scripts/run_test262.py` comments, `docs/architecture.md` if it describes
the buffer model, and the changelog.
