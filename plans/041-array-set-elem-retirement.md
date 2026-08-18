# Plan 041 — Retire the hidden-dense-write hazard (`set_array_idx` / `array_set_elem`) and finish the array-like migration

Status: PLANNED (session 251)
Oracle: `test/test_041_array_like_gaps.js` — **7 failing / 5 passing today; done when 12/12.**

## Context

B40 (commit 73c8b53) fixed the huge-length clusters by widening lengths to
2^53-1 and introducing class-guarded write/delete helpers
(`array_set_elem_ulong`, `arr_delete_elem_ulong`) — but it fixed the *methods
it touched* by routing around the root hazard, not by removing it:

`HObject.set_array_idx` (src/hobject.c3:1320) grows and writes a **dense array
part on any object class**. For a plain OBJECT whose numeric properties are
named props, that write is invisible: reads (VM and builtin alike) find the
named property first. Every builtin that still calls `array_set_elem` with a
potentially-plain target silently loses writes. `array_get_length` (ToUint32)
and `array_get_elem` (dense-first, no accessor ctx) have the sibling problems:
32-bit length wraps and hole/accessor blindness.

Concrete symptoms pinned by the oracle (all reproducible today):

- `Array.prototype.shift.call({0:"a",1:"b",length:2})` returns `"a"` but
  leaves `[0]==="a"`, never deletes `"1"` — writes went to a hidden dense part.
- `Array.prototype.sort.call({0:"b",1:"a",length:2})` does not sort.
- `Array.prototype.at.call({length:2^53-1}, -1)` → `undefined` (ToUint32 wrap).
- `includes` with a `fromIndex` near 2^53-1 → `false` (same wrap).

## Current call-site inventory (verified session 251)

Still on the legacy `uint`/dense-blind helpers inside `src/builtins/array.c3`:

| Function | Uses | Hazards |
|---|---|---|
| `builtin_array_proto_shift` | get_length, get_elem, set_elem, delete_elem | hidden writes, no named delete, ToUint32 |
| `builtin_array_proto_sort` | get_length, get_elem, set_elem | hidden writes, ToUint32 |
| `builtin_array_proto_at` | get_length | ToUint32 |
| `builtin_array_proto_includes` | get_length | ToUint32 |
| `builtin_array_proto_join` (+`toString`) | get_length, get_elem | ToUint32, accessor-blind reads |
| `builtin_array_proto_toReversed/toSorted/toSpliced/with` | get_length, get_elem (source reads); set_elem (targets are fresh ARRAYs — safe) | ToUint32, accessor-blind source reads |
| `builtin_array` (constructor), `flatten_into` inner reads, `Array.from` array-like branch | get_length/get_elem | uint-only; low priority |

Outside array.c3 (all targets are engine-created real ARRAYs — **safe**, no
change needed): `src/builtins/object.c3` (keys/getOwnPropertyNames result
arrays), `src/builtins/core.c3` (Map/Set-from-iterable reads of real arrays).

## Approach

### Step 1 — make the hazard unrepresentable
In `array_set_elem` (src/builtins/array.c3:~700), take the dense path only for
`ARRAY`/`ARGUMENTS` classes and fall through to `put_prop` otherwise — i.e.
move B40's guard from `array_set_elem_ulong` down into `array_set_elem` so
*every* caller inherits it. Then `array_set_elem_ulong` collapses to "widen +
call it". Do NOT change `set_array_idx` itself first — the VM also calls it;
audit those separately (grep `set_array_idx` in `src/vm/`) and only add a
class assert there once the builtins are clean.

### Step 2 — migrate the remaining methods to the B40 helper set
Pattern already established in B40 (see `pop`/`reverse`/`copyWithin` in
commit 73c8b53): `array_to_length` (ulong) + `arr_has_prop` /
`arr_get_elem_vm` (accessor + throw propagation) + `array_set_elem_ulong` /
`arr_delete_elem_ulong` + `tval_set_index` for produced indices/lengths.

- `shift`: spec §23.1.3.27 — Get(0), loop k=1..len-1 {HasProperty → move, else
  delete}, delete len-1, write length. Preserve the B30 incref pattern from
  `pop` for the returned element.
- `sort`: read phase collects present elements via `arr_has_prop`/
  `arr_get_elem_vm`; write-back via `array_set_elem_ulong`, then delete the
  tail slots that held undefineds/holes (§23.1.3.30 SortCompare semantics).
- `at`, `includes`: ToLength + ulong index math (copy the B40 `fill` shape,
  including the NaN→0 guards).
- `join`/`toString`: ToLength; keep iteration `uint`-bounded is NOT acceptable
  (wrap picks wrong elements) — use ulong; huge lengths will be slow per spec,
  which is what test262 expects.
- `toReversed`/`toSorted`/`toSpliced`/`with`: source reads via the vm helpers;
  ToLength; result stays a real ARRAY (lengths > 2^32-1 → RangeError per
  ArraySpeciesCreate — fold into plan 040 §A4 when species lands).
- `flatten_into` inner reads + `Array.from` array-like branch: widen reads,
  `tval_set_index` for the mapfn index argument.

### Step 3 — converge on plan 040 §A4
Once the above is mechanical-done, extract the recurring shapes into the
shared spec-op helpers (`LengthOfArrayLike`, hole-aware move/delete iteration)
so the next builtin can't regress. That extraction belongs to plan 040 §A4;
this plan only has to leave zero callers of the legacy trio
(`array_get_length` / `array_get_elem` / `array_set_elem`) inside
Array.prototype methods.

## Validation

1. `./out/test_vm test/test_041_array_like_gaps.js` → **12/12** (7 fail today:
   3× shift, 2× sort, at, includes). This file is the definition of done.
2. `./out/test_vm test/test_b40_huge_length.js` stays **50/50** (B40 must not
   regress — it covers the helpers this plan generalises).
3. `./out/test_vm test/array.js` ≥ 83 pass (was 82 pre-B40).
4. Full local sweep: all `test/*.js` diffed against a pre-change binary
   (build baseline via `git stash` — worktrees miss the vendored quickjs/
   sources); only intended diffs allowed.
5. test262 targeted clusters (single-test runner rebuilds nothing — build
   `out/boomkat` first):
   `built-ins/Array/prototype/{shift,sort,at,includes,join}/**` plus a re-run
   of the B40 cluster (`*maximum-index*`, `*integer-limit*`, 24/28 today —
   must not drop; the 4 fails are Proxy-gated).
6. `just rosetta` 100/100 and `bash scripts/run_bench_fast.sh 2` — watch
   `bench_array` (34ms) and `bench_ic_*`; sort/shift touch hot paths.

## Risks

- `sort` on real dense arrays is perf-sensitive (bench_array); keep an
  ARRAY-class fast path that bypasses the generic read/write helpers.
- `set_array_idx` is also the VM's dense write primitive — do not narrow it
  until the VM call sites are audited (Step 1 note); the OBJECT-class dense
  part may be load-bearing for arguments-object or literal fast paths.
- `join` on pathological lengths becomes spec-conformantly slow instead of
  wrong; the test262 runner's 2GB/10s guards handle it.
