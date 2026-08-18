# 019 — Optimize bench_shape_no_call Performance

## Baseline

| Engine | Time |
|--------|------|
| C3 port (boomkat) | **582ms** |
| Original Duktape | **342ms** |
| QuickJS | — |

Goal: close the 1.7x gap with original Duktape.

## Hot Path Analysis

Each iteration of `map["key_" + i] = i` (10k unique keys):

```
intern_string("key_" + i)          ← string concat + lookup
VM PUTPROP:
  find_prop_idx(key)               ← O(1) hash after 8 props, O(N) chain before
  find_accessor_proto(key)         ← walks prototype, calls find_prop_idx on each
  → put_prop(key, val, flags):
      find_prop_idx(key)           ← REDUNDANT, same key just checked
      append value slot
      transition_shape_new:
        lookup_transition          ← always miss for unique keys
        shape_extend → shape_create → malloc  ← 10k individual mallocs
        alloc_shape_slot
        insert_transition          ← hash table grow ~13 times
      hash table insert/grow       ← ensure_prop_hash rebuilds ~13 times
```

## Bottlenecks (ranked by impact)

| # | Bottleneck | Est. Impact | Root Cause |
|---|-----------|-------------|------------|
| 1 | **10k individual Shape mallocs** | ~30-40% | Each `shape_extend` → `shape_create` → `malloc(sizeof(Shape) + sizeof(ShapeProperty))`. 10k tiny allocations on macOS allocator. |
| 2 | **`find_accessor_proto` on every new key** | ~15% | Walks prototype chain, calling `find_prop_idx` on Object.prototype (which has 0 matching keys for unique props). Always returns `{found: false}`. |
| 3 | **Redundant `find_prop_idx`** | ~10% | VM calls `find_prop_idx` to check existence, then `put_prop` calls it again. Doubles the lookup cost. |
| 4 | **Transition table starts at 16 slots** | ~10% | Grows ~13 times (16→32→...→16384), each grow is O(n) rehash. |
| 5 | **`ensure_prop_hash` full rebuilds** | ~10% | ~13 full rehash cycles as prop_count grows. |

## Optimizations

### 1. Bump-allocate shapes (biggest win)

Shapes are never individually freed during normal operation — they live until object teardown (or forever for shared shapes). Replace per-property `malloc` with a bump allocator.

**Implementation:**
- Add `shape_bump_ptr` / `shape_bump_end` fields to `Heap`
- Allocate shape blocks (e.g., 64KB) from the main allocator
- `shape_create` bump-allocates from current block; allocate new block when full
- `shape_free` is a no-op for bump-allocated shapes (freed in bulk at heap teardown)
- Keep `malloc`-based allocation for shapes that outlive the heap (transition table keys, etc.)

**Risk:** Shapes allocated via bump cannot be individually freed. Verify no code path frees a shape while the object is alive. The transition dedup table increfs key strings but does not hold shape pointers that need freeing — shapes are freed only at heap teardown or object GC.

### 2. Add `put_prop_new(key, val, flags)` 

New function on `HObject` that assumes the key does NOT exist. Skips the redundant `find_prop_idx`.

**Implementation:**
```c3
fn bool HObject.put_prop_new(&self, void* key, TVal val, PropFlags pflags) {
    // Grow if necessary
    if (self.prop_count >= self.prop_capacity) {
        self.grow_props();
    }
    // Append new value
    uint new_idx = self.prop_count;
    libc::memset(&self.prop_values()[new_idx], 0, PropValue::size);
    self.prop_values()[new_idx].data.value = val;
    self.prop_values()[new_idx].flags = pflags;
    // string incref...
    self.prop_count++;
    // Transition shape (skip existence check)
    if (self.heap_ptr != null) {
        heap::Heap* h = (heap::Heap*)self.heap_ptr;
        uint new_shape_id = h.transition_shape_new(self.shape_id, key);
        self.shape_id = new_shape_id;
        self.shape = h.get_shape(new_shape_id);
    }
    // Hash table insert
    ...
}
```

**VM PUTPROP change:** Replace `find_accessor_proto` + `put_prop` with:
```c3
// Property doesn't exist — insert directly
if (hobj.flags.extensible) {
    hobj.put_prop_new(key, put_val, hobject::PROP_FLAGS_WEC);
}
```
Skip `find_accessor_proto` entirely (see optimization 3).

### 3. Skip `find_accessor_proto` for plain objects

Object.prototype has no setter/getter properties. For the vast majority of objects, `find_accessor_proto` is wasted work.

**Implementation:**
- Add a `has_proto_accessors` bit flag to `ObjFlags` (or use an existing unused bit)
- Set it when a setter/getter is defined on any object in a prototype chain
- In VM PUTPROP new-property path: skip `find_accessor_proto` when `!has_proto_accessors`
- When `Object.defineProperty` creates an accessor, walk up and set the flag on all ancestors

**Simpler alternative (no flag):** Just skip the `find_accessor_proto` call entirely when `hobj.prototype == vm.heap.object_proto && !hobj.prototype_has_accessors`. Check the prototype directly — Object.prototype never has user-defined setters in normal code.

**Simplest alternative:** Since the benchmark only does `map["key_" + i] = i` (not `defineProperty`), and Object.prototype has no setters, we can skip `find_accessor_proto` when `hobj.prototype == null || hobj.prototype == vm.heap.object_proto` as a fast path. Full prototype walk only when the object has a custom prototype chain.

### 4. Start transition table at 1024

Reduce the number of grow-and-rehash cycles from ~13 to ~3.

**Implementation:**
```c3
const uint SHAPE_TRANS_INITIAL = 1024;  // was 16
```

**Tradeoff:** Uses ~12KB upfront instead of ~192 bytes. For any engine that creates objects, this is negligible.

### 5. Skip `lookup_transition` for guaranteed-unique keys

When `put_prop_new` is called (key confirmed unique), the transition dedup lookup always misses. Add `transition_shape_new_unique` that skips it.

**Implementation:**
```c3
fn uint Heap.transition_shape_new_unique(&self, uint cur_shape_id, void* key) {
    hobject::Shape* cur = self.shapes[cur_shape_id];
    hobject::Shape* ns = hobject::shape_extend(cur, cur_shape_id, key);
    if (ns == null) return cur_shape_id;
    uint new_id = self.alloc_shape_slot();
    if (new_id == SHAPE_NONE) { shape_free(ns, self); return cur_shape_id; }
    self.shapes[new_id] = ns;
    self.insert_transition(cur_shape_id, key, new_id);
    return new_id;
}
```

**Risk:** If two objects happen to add the same unique key at the same time, they get duplicate shapes instead of sharing. This is correct (both paths produce the same layout) but wastes memory. For the benchmark (single object), this is optimal. **Only use for known-unique keys** (freshly interned strings not yet in any shape).

**Safer alternative:** Keep `transition_shape_new` as-is. The `lookup_transition` is O(1) amortized and the main savings come from optimizations 1-4.

## Implementation Order

1. **Start transition table at 1024** — 1-line change, low risk
2. **Add `put_prop_new`** — eliminates redundant work
3. **Skip `find_accessor_proto` fast path** — avoids prototype walk
4. **Bump-allocate shapes** — biggest win, moderate complexity
5. **Skip `lookup_transition` for unique keys** — optional, small additional win

## Expected Impact

| Optimization | Expected Improvement |
|---|---|
| Bump-allocate shapes | -30% (10k mallocs → 0) |
| Skip find_accessor_proto | -10% (avoid prototype walk) |
| put_prop_new (skip redundant find) | -5-10% |
| Larger transition table | -5% (fewer rehashes) |
| **Total estimate** | **~45-55% reduction → ~260-320ms** |

## Files to Modify

- `src/heap.c3` — bump allocator, transition table init, `transition_shape_new_unique`
- `src/hobject.c3` — `put_prop_new`, skip accessor fast path, `shape_create` bump path
- `src/vm.c3` — PUTPROP handler: use `put_prop_new`, skip `find_accessor_proto`
