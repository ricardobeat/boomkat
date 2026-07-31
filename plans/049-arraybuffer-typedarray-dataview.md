# Plan 049 — ArrayBuffer, TypedArrays, DataView

Status: PLANNED (session 268). Research: QuickJS (`quickjs/quickjs.c` ~4,400-line
subsystem) and Duktape (`duktape/src-separate/duk_bi_buffer.c` + `duk_hbufobj.h`,
~3,500 lines) surveyed by reference agents; findings distilled below with file:line
pointers into the vendored sources.

## Why / scope decision

`docs/engine-scope.md` lists TypedArrays/DataView/ArrayBuffer in the
required QuickJS-parity API surface, but the directories were never added to the
`PHASES` list in `scripts/run_test262.py` — they are outside the current 29,459-test
denominator. Landing this plan **deliberately grows the subset** (per plan 040's
no-silent-shrinkage rule, which cuts both ways):

| Directory | Raw tests | Excluded by existing flags | Executable added |
|---|---|---|---|
| built-ins/ArrayBuffer | 221 | resizable-arraybuffer, arraybuffer-transfer, immutable-arraybuffer, SAB | ~130 |
| built-ins/TypedArray | 1,446 | resizable (~326 across dirs), BigInt (~29 files), Float16Array | ~1,150 |
| built-ins/TypedArrayConstructors | 738 | BigInt ctors | ~700 |
| built-ins/DataView | 561 | BigInt get/set, Float16, resizable | ~480 |
| **Total** | **2,966** | | **~2,460** |

Engine state today: `ObjClass` already enumerates `ARRAYBUFFER`, `DATAVIEW`, and the
9 typed-array classes **contiguously** (src/hobject.c3:130-140 — keep this order, all
range checks exploit it, mirroring QuickJS's contiguous `JS_CLASS_UINT8C_ARRAY..DATAVIEW`
at quickjs.c:142-154). `src/builtins/typedarray.c3` (194 lines) registers 9 constructors
that return empty facade objects — no buffer, no element access, no ArrayBuffer at all.

### Out of scope (documented exclusions, all already feature-flag-skipped)

SharedArrayBuffer/Atomics, resizable/growable buffers (`maxByteLength`, `resize`,
`track_rab`), `transfer`/`transferToFixedLength`, BigInt64/BigUint64Array, Float16Array,
`Uint8Array.prototype.toBase64/fromHex` family. Add `Float16Array` and
`arraybuffer-transfer` to the feature-flag skip regex (run_test262.py:130) — the rest
are covered.

## Design

### D1. Data layout — Duktape's single view struct, QuickJS's real detach

Two new `HObjectExtra` variants (src/hobject.c3:485, union — verify sizeof stays ≤ the
current max member; both structs below are 24-32 bytes):

```c3
/// ArrayBuffer backing store. Active when obj_class == ARRAYBUFFER.
struct HObjectArrayBuffer {
    char*    data;          // heap.alloc_func'd, zeroed; null when detached
    uint     byte_length;   // 0 when detached
    HObject* views_head;    // intrusive list of views (QuickJS array_list)
}

/// TypedArray or DataView. Active for INT8ARRAY..FLOAT64ARRAY and DATAVIEW.
struct HObjectBufferView {
    HObject* buffer;        // backing ARRAYBUFFER object (GC-traced)
    HObject* next_view;     // intrusive list link (buffer.views_head chain)
    uint     byte_offset;
    uint     byte_length;   // in BYTES (Duktape convention, duk_hbufobj.h:85-118)
}
```

Derived, not stored (Duktape's shift trick + our contiguous ObjClass):
- `shift(cls)`: INT8/UINT8/UINT8C→0, INT16/UINT16→1, INT32/UINT32/FLOAT32→2, FLOAT64→3
  — a `char[9]` table indexed by `cls - INT8ARRAY`.
- element count = `byte_length >> shift`; byte of element i = `byte_offset + (i << shift)`.
- element data pointer = `buffer.extra.ab.data + byte_offset`, **recomputed per access**
  (no cached pointer like QuickJS's `u.array.u.ptr` — our accesses go through the
  dispatch switch anyway, and skipping the cache removes the invalidation-walk
  complexity; revisit only if benchmarks demand it).

Detach (QuickJS semantics, quickjs.c:56755): `data` freed, `byte_length=0`,
`data=null`. Views need no update walk *because nothing is cached* — every access
re-validates `buffer.data != null && byte_offset + byte_length <= buffer.byte_length`.
The `views_head` list is still needed for GC marking direction and kept for a future
resizable implementation. OOB/detached behavior is **spec** (undefined read / ignored
write), NOT Duktape's zero-read (duk_hobject_props.c:2101 — a known ES5-era deviation;
test262 will fail on it).

GC integration (src/heap.c3): mark pass must trace `view.buffer` and `buffer.views_head`
chain; free pass for ARRAYBUFFER calls `free_func(data)` unless detached. Follow the
GENERATOR `generator_data` precedent (heap.c3:1626, 2059).

### D2. Element access fast path

Mirror the ARRAY dense-part fast path (src/vm/vm_property.c3:55) in GETPROP/PUTPROP/
GETPROPC dispatch: `cls >= INT8ARRAY && cls <= FLOAT64ARRAY` and numeric key →

- **Read**: `idx < (byte_length >> shift)` and buffer not detached → typed load,
  push as fastint (int types that fit) or number (uint32 large, floats).
  OOB/detached → **undefined** (fall through to normal lookup, which finds nothing —
  QuickJS gets this for free the same way, quickjs.c:9026-9077).
- **Write**: convert FIRST, bounds-check AFTER (conversion can run user code that
  detaches — QuickJS comment at quickjs.c:9978-9981). OOB/detached → silently succeed
  (quickjs.c:10038 `ta_out_of_bound`). Conversions per class:
  ToInt32/ToUint32 truncating for int kinds, `to_uint8_clamped` for UINT8CLAMPEDARRAY
  (NaN→0, <0→0, >255→255, half-to-even — QuickJS `JS_ToUint8ClampFree`
  quickjs.c:13372, Duktape `duk_to_uint8clamped` duk_api_stack.c:3044), float32 via
  double→float cast, float64 direct.
- **CanonicalNumericIndexString** (§9.4.5): string keys that are canonical numeric
  ("1.5", "-0", "NaN") on a typed array must NOT hit the ordinary property path —
  reads yield undefined, writes are ignored, defineProperty constrained. Handle in the
  slow path with a `is_canonical_numeric_index` helper; plain "0","1",… integer strings
  already funnel through the arridx machinery (same reuse as Duktape,
  duk_hobject_props.c:114).
- `length`, `byteLength`, `byteOffset`, `buffer` are **prototype accessors** (ES2015),
  not own props — unlike arrays. No per-instance property writes at construction
  (delete the stub's `length:0` put_prop, src/builtins/typedarray.c3:44).
- Also patch: `[[OwnPropertyKeys]]`/for-in enumeration (integer indices are own keys),
  `Object.getOwnPropertyDescriptor` synthesis, `has` (`idx in ta`), delete semantics,
  and JSON.stringify's array-like handling — grep callers of `json_is_array` and the
  ARRAY exotic special cases added in B54/B58 for the checklist.

### D3. Constructors (src/builtins/arraybuffer.c3 — new; rewrite typedarray.c3)

- `ArrayBuffer(length)`: require `new` (constructor-only per class), ToIndex,
  RangeError on negative/ >2^31-1 (int cap like QuickJS quickjs.c:56454), zeroed
  allocation. Prototype: `byteLength` getter (0 when detached), `slice` (species-aware,
  re-check detach after species ctor runs — quickjs.c:56994), `detached` getter,
  static `isView` (class range check), `[Symbol.species]`, `[Symbol.toStringTag]`.
- `%TypedArray%(...)` four overloads, dispatch on argv[0]
  (quickjs.c:59693-59771; validation order = alignment → detached → bounds):
  1. number/absent → ToIndex, fresh buffer `len << shift`.
  2. ArrayBuffer → shared view; byteOffset must be multiple of element size
     (RangeError), length absent → remainder must divide evenly.
  3. TypedArray → fresh buffer, same-class → memcpy, else element loop
     (copy-compatibility table optional later, duk_bi_buffer.c:57).
  4. object → iterator protocol when `Symbol.iterator` present, else length +
     indexed Get (QuickJS `js_typed_array_constructor_obj` quickjs.c:59577;
     Duktape lacks this — don't copy Duktape here).
  Per-kind constructors stay thin wrappers passing their class (the existing
  `builtin_typed_array_shared(ctx, obj_class)` shape is already right).
- `DataView(buffer, byteOffset, byteLength)`: arg must be ARRAYBUFFER (TypeError),
  ToIndex offset, detach + bounds checks; re-check after any user-code hook.

### D4. %TypedArray%.prototype — reuse Array generics where QuickJS does

QuickJS shares `every/some/forEach/map/filter/reduce/reduceRight/join/toLocaleString/
toString` and the iterators with Array via a `special_TA` flag (quickjs.c:41892).
Our array builtins already work through generic Get/Set + `array_to_length`; a
`ta_validate` prelude (throw TypeError if detached/OOB — QuickJS `validate_typed_array`
quickjs.c:57096) + routing `length` reads to the view's element count covers the
shared set. Register them on %TypedArray%.prototype pointing at the same builtin
indices where behavior is identical; audit each against the TypedArray-specific spec
text (e.g. `map`/`filter` use ArraySpeciesCreate for Array but TypedArraySpeciesCreate
here).

Dedicated byte-level implementations (all with post-side-effect OOB re-checks):
- `set(src, offset)` — same-class → single memmove (handles overlap,
  quickjs.c:57259); cross-class same-buffer → stage a temp copy (Duktape's approach,
  duk_bi_buffer.c:1742); else element loop.
- `copyWithin` — clamp, re-validate, one memmove of `count << shift`.
- `fill` — convert once, memset for byte kinds, per-shift loop otherwise.
- `slice` — TypedArraySpeciesCreate; same-class memcpy when no overlap, forward
  byte copy when overlapping (quickjs.c:58192).
- `subarray` — **no copy**: new view, same buffer, recomputed offset/count.
- `sort` — copy elements out to a scratch TVal array, reuse the existing
  `array_sort_compare` machinery, write back; default comparator is numeric
  (not string!) per §23.2.3.29.
- getters `buffer`/`byteLength`/`byteOffset`/`length` (+ `[Symbol.toStringTag]`
  getter returning the class name, undefined for non-TA receivers).
- `at/with/indexOf/lastIndexOf/includes/find*/reverse/toReversed/toSorted` — start
  from the Array versions, specialize where the spec diverges (numeric fast compare).

### D5. DataView get/set (src/builtins/dataview.c3 — new)

`getInt8..getFloat64` / `setInt8..setFloat64` — one shared reader/writer pair with
the element class passed via the builtin dispatch index (QuickJS passes it as magic,
quickjs.c:59949/60061). ToIndex(pos), bounds vs view byte_length (RangeError),
detached (TypeError), `littleEndian` arg XOR host endianness → byte swap. We only
target little-endian hosts today, but write the swap against a `const IS_BIG_ENDIAN`
so it's not load-bearing. Reuse f32/f64 ↔ bits unions from TVal/dtoa plumbing.

### D6. Host hook for detach tests + phase wiring

- Engine primitive: `__detachArrayBuffer(buf)` — either a hidden global builtin or,
  cleaner, expose via the existing `$262`-prelude story: ~290 tests call
  `$DETACHBUFFER` → `$262.detachArrayBuffer` (harness/detachArrayBuffer.js). The
  runner currently defines no `$262`; add a tiny prelude object in
  `test262_runner/run_single_test.sh` + the batch runner harness concat:
  `var $262 = { detachArrayBuffer: __detachArrayBuffer, createRealm: undefined, ... }`.
  Without this, ~290 tests are un-runnable (they'd Test262Error, counting as FAIL).
- `scripts/run_test262.py`: new phase **22 — Buffers** with dirs
  `built-ins/ArrayBuffer`, `built-ins/TypedArray`, `built-ins/TypedArrayConstructors`,
  `built-ins/DataView`. Add `Float16Array|arraybuffer-transfer|immutable-arraybuffer`
  to the feature skip regex. Update plan 040's "what 100% means" arithmetic
  (+~2,460 executable) and `progress.md`'s phase table.

## Stages (each: build + local oracle + phase-22 slice + commit)

1. **Core representation + ArrayBuffer** (~350 lines): extra structs, GC trace/free,
   `ArrayBuffer` ctor + byteLength/slice/isView/species, detach primitive.
   Oracle: `test/arraybuffer_core.js` (alloc, zero-fill, slice, detach, GC stress loop).
   Fixes `test_tostring_tags.js` ArrayBuffer failure as a side effect.
2. **TypedArray construction + element access** (~600 lines): 4 ctor overloads,
   GETPROP/PUTPROP fast paths + conversions, CanonicalNumericIndexString, length
   getters, enumeration/descriptor/has/delete integration.
   Oracle: `test/typedarray_elems.js` (every class × read/write/OOB/detached/clamped
   rounding table from harness byteConversionValues.js).
3. **DataView** (~350 lines): ctor + 16 get/set methods + endianness.
   Oracle: `test/dataview_endian.js`.
4. **%TypedArray%.prototype wave A** (~500 lines): iterators, shared generics with
   `ta_validate`, getters, `set`, `subarray`, `fill`, `copyWithin`, `slice`.
5. **Wave B** (~400 lines): `sort/toSorted`, `from/of`, species plumbing,
   `indexOf/includes` numeric compare, `join`, remaining find/reverse family.
6. **Runner wiring + baseline**: phase 22 added, $262 prelude, feature-flag skips,
   full run re-baseline, plan 040 + BACKLOG + progress.md updates.

Estimated total: **~2,200-2,600 lines** (QuickJS's subsystem is ~4,400 for a superset
including SAB/RAB/BigInt/Float16/Atomics; Duktape's is ~3,500 including Node Buffer).

## Risks / open questions

- **HObjectExtra union growth**: both new structs must not exceed the current largest
  member (HObjectPromise/HObjectFunction, 32-40 bytes) or every HObject grows. They
  fit (24 bytes each) — assert with `$assert HObjectExtra.sizeof` guard.
- **IC interplay**: property ICs must never cache typed-array element hits (they're
  not shape-backed); confirm the fast path runs before IC lookup like the ARRAY
  dense path does, and that `length` accessor on the prototype doesn't get
  IC-poisoned by the old stub's own-property `length`.
- **needs_env/ENV_STRICT**: none — pure builtin/VM-dispatch work, no compiler changes.
- **2GB cap**: use `uint` byte lengths with an explicit `INT32_MAX` allocation cap
  (QuickJS does the same); rejects the memkill-style huge-length tests cheaply.
- **Detach-during-conversion reentrancy** is THE classic bug family here (valueOf
  detaching mid-`fill`/`set`/`copyWithin`): the convert-first-recheck-after pattern
  must be mechanical in every method. Test262 covers each; add a local oracle with a
  detaching valueOf for the byte-level five before running the phase.
- Sequencing: plan 048 (destructuring) and 047 (descriptors) yield more per line of
  code on the existing 81.9% denominator; this plan grows the denominator to buy its
  headroom (~2,460 tests, realistically ~85-90% of them passing by stage 6 → net
  effect on the global percentage is roughly neutral-to-positive, but the API-surface
  parity goal is the point).
