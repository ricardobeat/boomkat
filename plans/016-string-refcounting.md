# Plan 016: String Reference Counting

**Date:** 2026-06-08
**Branch:** `ref-counting`
**Goal:** Reduce GC pauses and improve memory determinism by making strings fully reference-counted, removing them from the mark-and-sweep cycle entirely.

---

## Background

The engine already uses a hybrid model: objects and buffers are primarily reclaimed by refcounting (`decref()` frees at zero), with mark-and-sweep (M&S) used only to collect cycles. Strings are the exception — they have a `refcount` field in `HString` but it is completely unused. Strings are allocated, tracked in `str_gc_array`, and freed exclusively by M&S via `sweep_strings()`.

This means every GC pause includes:
1. Clearing reachable flags on all tracked strings
2. Marking strings reachable from roots (valstack, compiled function constants, IC caches, symbol registry, builtin strs cache)
3. Sweeping `str_gc_array` and rebuilding `str_table` from scratch

Since strings are acyclic leaves (HString has no heap-pointer fields, data is inline), they cannot be part of reference cycles. This means RC is *complete* for strings — no cycle collector is needed for them. They are the ideal candidate to move to pure refcounting.

### Current asymmetry (the bug to fix)

- `incref()` (types.c3:629): generic — increments `refcount` on *any* `HeapHeader`, including strings
- `decref()` (heap.c3:1090): early-returns for strings, no-op
- `tval_copy_ref()` (heap.c3:1126): only handles OBJECT and BUFFER tags, skips STRING entirely
- `set_string()` macro (types.c3:410): sets tag+pointer bits but does **not** call `incref()` (unlike `set_object()` which does)

Result: string refcounts are always 0 (memset to zero in `hstring_alloc`, never incremented via the normal TVal paths). The field is dead weight.

---

## Scope

**This plan covers Phase 1 only: string refcounting + string removal from M&S.**

Phase 2 (slimming the M&S cycle collector for objects) is a separate plan, after we benchmark Phase 1.

---

## Implementation Steps

### Step 1: `hstring_alloc` — initialize refcount

**File:** `src/hstring.c3`, around line 334 (after header is zero-filled, before `track_string`)

Currently `hstring_alloc` calls `libc::memset(raw, 0, HSTRING_HDR_SIZE)` which zeros `refcount`. Add:

```c3
s.refcount = 1;
```

After the memset and before `track_string`. New strings start with refcount 1 — the caller (always `str_intern`) holds the first reference.

Remove the `track_string(raw)` call — strings no longer need GC tracking.

### Step 2: `str_intern` — do not incref on cache hit

**File:** `src/heap.c3`, lines 1748–1760

`str_intern` either returns an existing string (lookup hit) or a newly allocated one (refcount=1 from Step 1). The *caller* is responsible for incref'ing if it holds an additional reference beyond the intern table's own.

Wait — the intern table itself does **not** hold a refcount reference. Conceptual model:

> The string table is a weak cache. The refcount represents live references from TVal slots, compiled function constant pools, IC caches, and the builtin strs cache. When refcount reaches 0, the string is removed from the table and freed.

So: `str_intern` returns a pointer. The caller must incref if it will store the pointer somewhere that outlives the current expression. For the common case of `vm.heap.str_intern(data)` → immediately stored into a TVal via `set_string()`, the `set_string()` macro will do the incref (Step 4).

**Change:** No change to `str_intern` body itself. But its callers change (see Steps 4–6).

### Step 3: `str_table_remove` — open-addressing backshift deletion

**File:** `src/heap.c3`, new function after `str_table_insert`

Open-addressing tables with linear probing cannot use simple slot-clearing for deletion — it breaks lookup chains. The correct algorithm is Knuth's Algorithm R (backshift): after removing a slot, shift subsequent entries backward to fill any gaps that would break probe sequences.

```c3
/**
 * Remove hstr from the string table using backshift deletion (Knuth R).
 * Must only be called when hstr is confirmed to be in the table.
 */
fn void Heap.str_table_remove(&self, HString* hstr) {
    if (self.str_table_size == 0) { return; }

    // Find the slot holding hstr
    uint mask = self.str_table_size - 1;
    uint i = hstr.hash & mask;
    while (self.str_table[i] != hstr) {
        i = (i + 1) & mask;
    }

    // Backshift: pull subsequent entries into the vacated slot if needed
    for (;;) {
        uint j = i;
        uint k = i;
        loop {
            k = (k + 1) & mask;
            if (self.str_table[k] == null) {
                self.str_table[j] = null;
                self.str_table_used--;
                return;
            }
            // Natural slot of the candidate
            uint nat = self.str_table[k].hash & mask;
            // Can we move str_table[k] to j?
            // We can if nat is not strictly between j and k (cyclically)
            if ((j < k && (nat <= j || nat > k)) ||
                (j > k && (nat <= j && nat > k))) {
                break;
            }
        }
        self.str_table[j] = self.str_table[k];
        i = k;
    }
}
```

> **Note:** `str_table_lookup` terminates on null slots (heap.c3:1708). Backshift preserves this invariant — entries that belong before the deleted slot are shifted to fill it, keeping the probe sequence intact. A simpler alternative (tombstones) degrades table quality over time and forces periodic rebuilds — exactly the GC pause we're removing.

### Step 4: `set_string()` macro — add incref

**File:** `src/types.c3`, line 410

Current:
```c3
macro void TVal.set_string(&self, void* ptr) {
$if USE_NANBOX:
    self.bits = nanbox_encode_tagged(TAG_STRING, (usz)ptr);
$else
    self.tag     = STRING;
    self.pointer = ptr;
$endif
}
```

New — mirror `set_object()` which calls `incref()`:
```c3
macro void TVal.set_string(&self, void* ptr) {
$if USE_NANBOX:
    self.bits = nanbox_encode_tagged(TAG_STRING, (usz)ptr);
$else
    self.tag     = STRING;
    self.pointer = ptr;
$endif
    if (ptr != null) { ((HeapHeader*)ptr).incref(); }
}
```

This means every `set_string(ptr)` call now increments the refcount. Every site that calls `set_string` must ensure a matching `decref` when that TVal slot is overwritten or goes out of scope — handled by Step 5.

### Step 5: `decref` and `decref_tval` — handle strings

**File:** `src/heap.c3`, lines 1090–1119

**`decref()`:** Remove the string early-return. When a string's refcount hits 0: remove from `str_table`, then free.

```c3
fn void Heap.decref(&self, HeapHeader* hdr) {
    if (--hdr.refcount == 0) {
        if (hdr.is_string()) {
            self.str_table_remove((HString*)hdr);
            self.free_string((HString*)hdr);
        } else if (hdr.is_object()) {
            hdr.unlink(&self.heap_allocated);
            hobject::hobject_free((HObject*)hdr);
        } else {
            // Buffer
            hdr.unlink(&self.heap_allocated);
            self.free_func(self.heap_udata, hdr);
        }
    }
}
```

**`decref_tval()`:** Extend to also handle STRING tag (currently only OBJECT and BUFFER):

```c3
fn void Heap.decref_tval(&self, TVal* tv) @inline {
    if (tv.is_object() || tv.is_buffer() || tv.is_string()) {
        void* ptr = tv.get_heapptr();
        if (ptr != null) {
            self.decref((HeapHeader*)ptr);
        }
    }
}
```

### Step 6: `tval_copy_ref()` — handle strings

**File:** `src/heap.c3`, lines 1126–1137

Current code only increfs OBJECT and BUFFER. Extend to include STRING:

```c3
fn void Heap.tval_copy_ref(&self, TVal* dst, TVal* src) @inline {
    if (dst != src) {
        self.decref_tval(dst);
        *dst = *src;
        if (src.is_object() || src.is_buffer() || src.is_string()) {
            void* ptr = src.get_heapptr();
            if (ptr != null) {
                ((HeapHeader*)ptr).incref();
            }
        }
    }
}
```

### Step 7: Pin builtin strings

**File:** `src/heap.c3`, `init_builtin_strs()` around line 465

Builtin strings in `Heap.strs[]` are live for the lifetime of the heap. If their TVal refcount temporarily drops to 0 (e.g., between operations on the valstack), `decref` would free "length", "prototype", etc. — catastrophic.

Use a sentinel `refcount`: set builtins to `UINT_MAX / 2` (large enough to never decrement to 0 in practice, avoids overflow). This is simpler than a flag — no branch needed in `decref`, and `UINT_MAX / 2` decrements are not physically possible.

```c3
const uint STRING_PINNED_REFCOUNT = 0x7FFF_FFFF;
```

In `init_builtin_strs()`, after storing into `self.strs[i]`:
```c3
((HeapHeader*)self.strs[i]).refcount = STRING_PINNED_REFCOUNT;
```

Apply the same to `self.iterator_symbol` and `self.toprimitive_symbol` when they are created (see `mark_roots` at heap.c3:1472).

Also applies to `hobject::builtin_length_key` — it points to the same HString as `strs[LENGTH]`, so pinning via `strs[]` covers it.

**Also pin symbol registry entries?** The symbol registry (`symbol_registry_keys[]`, `symbol_registry_syms[]`) holds `HString*` roots that M&S currently marks. Under RC, these need to hold a reference. Options:
- Incref each entry when added to the registry, decref when removed — correct and clean.
- Pin them — overly broad.

**Decision:** Incref on registry insert, decref on registry remove/overwrite. This is already how objects work.

### Step 8: `CompiledFunction` constants and IC caches — incref/decref string references

**File:** `src/heap.c3`, function that creates/frees CompiledFunctions; `src/bytecode.c3`

CompiledFunctions hold `TVal constants[]` which may be STRING type. Currently these are GC roots (marked in `mark_roots` at heap.c3:1450). Under RC, they must hold actual refcounts.

**On CF registration** (`track_compiled_func`, heap.c3:955): after tracking, iterate `cf.constants` and incref any STRING (and OBJECT/BUFFER — they may already be incref'd, need to verify).

Actually: look at where `cf.constants` are populated in the compiler. Each constant is either a number, a string literal, or a compiled inner function reference. String constants should be incref'd when the constant pool is built, and decref'd when the CF is freed.

**Action:** In `hstring_alloc` or in the compiler where string constants are created, ensure the constant TVal uses `set_string()` (which will incref after Step 4). Then in `Heap.free()` and `Heap.reset()` where CFs are freed (heap.c3:699–711, 795–805), iterate constants and call `decref_tval` on each before freeing the constants array.

**IC cache entries** (`ICEntry.key`, `VarICEntry.key` — HString*): these are currently marked as GC roots. Under RC:
- Incref when an IC entry is populated (wherever `ic_entries[i].key = hstr` is written)
- Decref when an IC entry is invalidated or the CF is freed

Find all IC entry write sites via: `grep -n "ic_entries\[.*\]\." src/vm.c3 src/hobject.c3`

### Step 9: Remove strings from M&S

**File:** `src/heap.c3`

Once Steps 1–8 are complete and tested, remove:

1. **`str_gc_array`** tracking: remove the field from `Heap` struct, remove `track_string()` call from `hstring_alloc`, remove `str_gc_capacity` field.

2. **`sweep_strings()`**: delete the function entirely.

3. **M&S string phases** in `mark_and_sweep()`:
   - Remove: clearing reachable flags on `str_gc_array` (heap.c3:1597–1602)
   - Remove: call to `self.sweep_strings()` (heap.c3:1612)
   - Remove: string marking from `mark_roots()` — the `set_reachable()` calls on `strs[]`, symbol registry strings, CF constants strings, and IC key strings (heap.c3:1430–1470). These no longer need to be marked since M&S doesn't sweep them.

4. **Heap teardown / reset**: Replace `str_gc_array` iteration with `str_table` iteration to free all strings:
   ```c3
   // Free all interned strings via str_table
   for (uint i = 0; i < self.str_table_size; i++) {
       HString* s = self.str_table[i];
       if (s != null) {
           self.free_string(s);
           self.str_table[i] = null;
       }
   }
   self.str_table_used = 0;
   ```
   Pinned builtins live in `str_table` too — they get freed here correctly since teardown happens once and does not use `decref`.

### Step 10: Update `mark_roots` string marking

After Step 9, `mark_roots` no longer needs to mark strings — but it does need to **not crash** when it encounters string TVal. The `mark_tval` function (heap.c3:1253) currently calls `set_reachable()` on string HStrings — this is harmless but wasteful after RC. Remove the string branch from `mark_tval`:

```c3
fn void Heap.mark_tval(&self, TVal* v) {
    if (v.is_object()) {
        HObject* obj = (HObject*)v.get_heapptr();
        if (obj != null) {
            HeapHeader* hdr = (HeapHeader*)obj;
            if (!hdr.is_reachable()) {
                hdr.set_reachable();
                self.gray_push(obj);
            }
        }
    }
    // Strings no longer need marking — RC keeps them alive
}
```

---

## Hazard Summary

| Hazard | Mitigation |
|---|---|
| `str_table` backshift required for per-entry removal | Implement Knuth R in `str_table_remove` (Step 3) |
| Builtin strings freed when valstack temporarily empty | Sentinel `STRING_PINNED_REFCOUNT` on all `Heap.strs[]` entries (Step 7) |
| `set_string()` currently does not incref | Add incref to macro (Step 4) — mirrors `set_object()` |
| Asymmetric incref (currently strings are incref'd by `HeapHeader.incref()` but never decref'd — so refcounts are 0 due to memset, not accumulated garbage) | Confirmed: memset zeros refcount; `set_string()` never called `incref()`; `tval_copy_ref()` skips strings. Starting from clean 0. |
| CF constants hold string refs not captured by RC | Incref on CF creation, decref on CF free (Step 8) |
| IC cache holds `HString*` refs not captured by RC | Incref on IC write, decref on IC invalidate/CF free (Step 8) |
| Symbol registry holds `HString*` refs not captured by RC | Incref on insert, decref on remove (Step 7 extension) |
| Heap teardown must free strings without `str_gc_array` | Iterate `str_table` directly (Step 9) |

---

## Execution Order

Steps must be done in this order to avoid broken intermediate states:

1. Step 3 (`str_table_remove`) — implement first, no behavior change yet
2. Step 7 (pin builtins) — safe to do before RC is live
3. Step 1 (`hstring_alloc` refcount=1, remove `track_string`) + Step 4 (`set_string` incref) + Step 5 (`decref`/`decref_tval` handle strings) + Step 6 (`tval_copy_ref` handle strings) — **do atomically**: these must all land together or the invariants break
4. Step 8 (CF constants + IC incref/decref) — can be done before or after Step 3 atomically; must be done before Step 9
5. Step 9 (remove `sweep_strings`, `str_gc_array`) — only after all the above are validated with test262
6. Step 10 (clean up `mark_tval`) — cosmetic, after Step 9

---

## Test Strategy

1. After Steps 1–7 (RC live, M&S still present): run full test262 suite. M&S is still the backstop — any RC bugs show as crashes (double-free, use-after-free) not leaks.
2. After Step 8: run test262 again. Focus on function-heavy tests (closures, many string constants).
3. After Step 9 (M&S string sweep removed): run test262 again. Now leaks are visible — add valgrind/asan run to catch any missed decref sites.
4. Run the existing benchmark to measure pause reduction.

Key regression signals:
- Any test that was passing and now fails after Step 3 atomically = missed incref or decref site
- Crash at property lookup = `str_table` corrupted (backshift bug)
- "length" / "prototype" crashes = builtin pin not applied correctly
- Memory growth over time = missed decref (string leak)

---

## What This Does NOT Change

- Object and buffer refcounting — already working, unchanged
- M&S cycle collection for objects — unchanged (Phase 2)
- GC trigger logic — unchanged (still based on `live_obj_count`)
- String interning invariant — strings remain interned; `str_intern` still deduplicates

---

## Expected Impact

- GC pauses shorter: no string clear/mark/sweep/table-rebuild phase
- Memory more deterministic: short-lived strings freed immediately at zero refcount, not at next GC
- Hot paths (LDREG, CALL, RET): now pay incref/decref for strings too, but this is offset by removal of periodic `sweep_strings` table rebuilds
- `str_gc_array` allocation and tracking overhead eliminated
