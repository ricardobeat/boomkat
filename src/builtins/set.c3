// Set constructor and Set.prototype methods.
module boomkat::builtins;

import boomkat::types;
import boomkat::heap;
import boomkat::hobject;
import boomkat::hstring;
import boomkat::env;
import boomkat::vm;
import std::math;

// ============================================================================
// Set helpers
// ============================================================================

fn HObject* check_set(BuiltinContext* ctx) {
    return check_collection_class(ctx, hobject::ObjClass.SET, "Set.prototype method called on incompatible value");
}

// Find the index in array_part where a value matches. Returns -1 if not found.
// Set entries are stored as [v0, v1, ...] in array_part.
fn int set_find_value(HObject* set, TVal val, heap::Heap* h) {
    return coll_find(set, val, 1, h);
}

// Counts non-deleted entries, same logic as the .size getter, factored out
// for the set-methods algorithms that need this.size as a plain number.
fn uint set_live_count(HObject* set) {
    uint count = 0;
    TVal* arr = set.array_part();
    if (arr != null) {
        for (uint i = 0; i < set.array_used; i++) {
            if (!arr[i].is_deleted()) count++;
        }
    }
    return count;
}

// ============================================================================
// Set methods proposal (ES2025 §24.2.4), shared helpers
// ============================================================================

// GetSetRecord(obj) result, ES2025 §24.2.4.1.
struct SetRecord {
    TVal set_like;
    double size;
    TVal has_fn;
    TVal keys_fn;
}

// GetSetRecord(obj), ES2025 §24.2.4.1. Validates `obj` is an object with a
// numeric, non-NaN `size` and callable `has`/`keys`, in that exact order
// (each Get/ToNumber/callability check can throw before the next runs).
// Returns a fault on any failure, ctx.should_throw is set by the caller's
// standard error paths (builtin_throw / vm_to_number's throw_pending).
fn SetRecord? get_set_record(BuiltinContext* ctx, TVal obj) {
    if (!obj.is_object() || obj.get_heapptr() == null) {
        coll_throw(ctx, "Method Set.prototype method called on incompatible receiver");
        return hobject::PROP_NOT_FOUND~;
    }
    HObject* obj_hobj = (HObject*)obj.get_heapptr();

    HString* size_key = builtin_intern_string(ctx.heap, "size");
    TVal raw_size;
    raw_size.set_undefined();
    if (size_key != null) {
        if (try s = builtins_generic_get(obj_hobj, size_key, ctx)) { raw_size = s; }
    }
    if (ctx.should_throw) return hobject::PROP_NOT_FOUND~;

    Vm* v = (Vm*)ctx.vm;
    double num_size = vm::vm_to_number(v, &raw_size);
    if (v.throw_pending) {
        ctx.should_throw = true;
        ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value);
        v.throw_pending = false;
        return hobject::PROP_NOT_FOUND~;
    }
    if (math::is_nan(num_size)) {
        coll_throw(ctx, "size must be a non-NaN number");
        return hobject::PROP_NOT_FOUND~;
    }
    // ToIntegerOrInfinity(numSize): truncate toward zero; ±Infinity pass through.
    double int_size = math::is_inf(num_size) ? num_size : math::trunc(num_size);
    if (int_size < 0.0) {
        builtin_throw_no_result_change(ctx, ctx.heap.range_err_proto, "size must be a non-negative number");
        ctx.result.set_undefined();
        return hobject::PROP_NOT_FOUND~;
    }

    HString* has_key = builtin_intern_string(ctx.heap, "has");
    TVal has_fn;
    has_fn.set_undefined();
    if (has_key != null) {
        if (try h = builtins_generic_get(obj_hobj, has_key, ctx)) { has_fn = h; }
    }
    if (ctx.should_throw) return hobject::PROP_NOT_FOUND~;
    if (!tval_is_callable(has_fn)) {
        coll_throw(ctx, "has is not callable");
        return hobject::PROP_NOT_FOUND~;
    }

    HString* keys_key = builtin_intern_string(ctx.heap, "keys");
    TVal keys_fn;
    keys_fn.set_undefined();
    if (keys_key != null) {
        if (try k = builtins_generic_get(obj_hobj, keys_key, ctx)) { keys_fn = k; }
    }
    if (ctx.should_throw) return hobject::PROP_NOT_FOUND~;
    if (!tval_is_callable(keys_fn)) {
        coll_throw(ctx, "keys is not callable");
        return hobject::PROP_NOT_FOUND~;
    }

    SetRecord rec = { obj, int_size, has_fn, keys_fn };
    return rec;
}

// Call setRecord.[[SetHas]] with `value` (SameValueZero-normalized -0 → +0
// is the caller's responsibility per each algorithm's own step). Returns
// the ToBoolean of the call result; on error, ctx.should_throw is set and
// the return value should be discarded.
fn bool set_record_has(BuiltinContext* ctx, SetRecord* rec, TVal value) {
    if (rec != null) {
        rec.set_like.set_temproot();
        rec.has_fn.set_temproot();
    }
    value.set_temproot();
    TVal[1] args = { value };
    TVal result = ctx.heap.call_fn(ctx.vm, rec.has_fn, &args[0], 1, rec.set_like);
    if (ctx.heap.has_error) {
        ctx.should_throw = true;
        ctx.throw_value = ctx.heap.error_value;
        ctx.heap.has_error = false;
        return false;
    }
    return tval_to_boolean(result);
}

// Call setRecord.[[SetKeys]]() and return the resulting iterator value.
// The Object check from GetIteratorFromMethod step 2 happens in
// set_iter_step, so a non-object return throws on the first step.
fn TVal set_record_get_keys_iterator(BuiltinContext* ctx, SetRecord* rec) {
    if (rec != null) {
        rec.set_like.set_temproot();
        rec.keys_fn.set_temproot();
    }
    TVal result = ctx.heap.call_fn(ctx.vm, rec.keys_fn, null, 0, rec.set_like);
    if (ctx.heap.has_error) {
        ctx.should_throw = true;
        ctx.throw_value = ctx.heap.error_value;
        ctx.heap.has_error = false;
        result.set_undefined();
    }
    return result;
}

// ToBoolean, ES2015 §7.1.2.
fn bool tval_to_boolean(TVal v) {
    switch (v.get_tag()) {
        case UNDEFINED: return false;
        case NULL_VAL:  return false;
        case BOOLEAN:   return v.get_boolean();
        case NUMBER:    return v.get_number() != 0.0 && !math::is_nan(v.get_number());
        case FASTINT:   return v.get_fastint() != 0;
        case STRING:    return ((HString*)v.get_heapptr()).blen > 0;
        default:        return true;  // objects, bigints, symbols
    }
}

// GetIteratorFromMethod's [[NextMethod]] slot, read once when the iterator
// is obtained (ES2022 §7.4.3 step 3: `Get(iterator, "next")`), not on every
// step. Set-like class tests observe a "getting next" log entry exactly
// once per keys() call, via a next getter that would fire on every access
// if re-fetched per iteration step.
fn TVal set_iter_get_next_fn(BuiltinContext* ctx, TVal iterator) {
    TVal next_fn;
    next_fn.set_undefined();
    if (!iterator.is_object() || iterator.get_heapptr() == null) return next_fn;
    HObject* iter_obj = (HObject*)iterator.get_heapptr();
    HString* next_key = builtin_intern_string(ctx.heap, "next");
    if (next_key == null) return next_fn;
    if (try nf = builtins_generic_get(iter_obj, next_key, ctx)) { next_fn = nf; }
    return next_fn;
}

// IteratorStep(iteratorRecord), ES2022 §7.4.6, poor man's variant for the
// set-like's keys() iterator. Calls the cached next_fn, then reads
// done/value via accessor-aware Get. On done (or a throw), *out_done is set
// true. Returns false only when next() itself throws (ctx.should_throw is
// set); callers should still check *out_done on a true return.
fn bool set_iter_step(BuiltinContext* ctx, TVal iterator, TVal next_fn, TVal* out_value, bool* out_done) {
    *out_done = true;
    iterator.set_temproot();
    next_fn.set_temproot();
    if (!iterator.is_object() || iterator.get_heapptr() == null) {
        // GetIteratorFromMethod step 2: a keys() result that is not an
        // object (a string primitive, a number) is a TypeError, never a
        // silently-exhausted iterator.
        coll_throw(ctx, "iterator is not an object");
        return false;
    }
    if (!tval_is_callable(next_fn)) {
        coll_throw(ctx, "iterator.next is not callable");
        return false;
    }
    TVal step = ctx.heap.call_fn(ctx.vm, next_fn, null, 0, iterator);
    if (ctx.heap.has_error) {
        ctx.should_throw = true;
        ctx.throw_value = ctx.heap.error_value;
        ctx.heap.has_error = false;
        return false;
    }
    if (!step.is_object() || step.get_heapptr() == null) {
        coll_throw(ctx, "iterator result is not an object");
        return false;
    }
    HObject* step_obj = (HObject*)step.get_heapptr();
    HString* done_key = ctx.heap.str(heap::BuiltinStr.DONE);
    TVal done_val;
    done_val.set_undefined();
    if (done_key != null) {
        if (try d = builtins_generic_get(step_obj, done_key, ctx)) { done_val = d; }
    }
    if (ctx.should_throw) return false;
    if (tval_to_boolean(done_val)) { *out_done = true; return true; }
    *out_done = false;

    HString* value_key = ctx.heap.str(heap::BuiltinStr.VALUE);
    TVal value_val;
    value_val.set_undefined();
    if (value_key != null) {
        if (try val = builtins_generic_get(step_obj, value_key, ctx)) { value_val = val; }
    }
    if (ctx.should_throw) return false;
    *out_value = value_val;
    return true;
}

// IteratorClose(iterator) for a normal (non-abrupt) early exit, calls
// .return() if present and callable, swallowing its result and any error it
// raises (the early-exit result already computed takes precedence).
fn void set_iter_close(BuiltinContext* ctx, TVal iterator) {
    if (!iterator.is_object() || iterator.get_heapptr() == null) return;
    HObject* iter_obj = (HObject*)iterator.get_heapptr();
    HString* return_key = builtin_intern_string(ctx.heap, "return");
    if (return_key == null) return;
    TVal return_fn;
    return_fn.set_undefined();
    if (try r = builtins_generic_get(iter_obj, return_key, ctx)) { return_fn = r; }
    ctx.should_throw = false;  // swallow any error from the return getter itself
    if (return_fn.is_undefined() || return_fn.is_null()) return;
    if (!tval_is_callable(return_fn)) return;
    ctx.heap.call_fn(ctx.vm, return_fn, null, 0, iterator);
    ctx.heap.has_error = false;  // swallow any error from calling return()
}

// Normalizes -0 to +0 per each set-methods algorithm's "if nextValue is -0,
// set nextValue to +0" step.
fn TVal set_normalize_neg_zero(TVal v) {
    if (v.is_number() && v.get_number() == 0.0 && 1.0 / v.get_number() < 0.0) {
        TVal zero; zero.set_fastint(0);
        return zero;
    }
    return v;
}

// Allocates a bare Set object (ObjClass.SET, heap.set_proto) with no entries.
// Used to build set-methods results directly via internal Set data, never
// via Set.prototype.add (add-not-called.js) or a species constructor
// (subclass-symbol-species.js, result is always a plain %Set%).
fn HObject* set_new_result(BuiltinContext* ctx) {
    HObject*? result_raw = ctx.heap.alloc_object(hobject::ObjClass.SET);
    if (catch err = result_raw) return null;
    HObject* result = result_raw;
    result.prototype = ctx.heap.set_proto;
    return result;
}

// Appends `value` to a result Set being built directly (bypasses .add and
// the has-check other than the caller's own dedup responsibility), used
// when the caller already knows the value isn't a duplicate (union copy,
// fresh Set with only unique values found so far).
fn void set_result_append(HObject* result, TVal value, Heap* h) {
    uint idx = result.array_used;
    result.set_array_idx(idx, value, h);
    if (result.array_used <= idx) result.array_used = (uint)(idx + 1);
}

// Copies every live (non-deleted) entry of `set` into a freshly-allocated
// result Set, in insertion order. Used as the starting point for union,
// intersection, difference, and symmetricDifference, whose result data is
// built directly rather than via .add.
fn HObject* set_copy_live_entries(BuiltinContext* ctx, HObject* set) {
    HObject* result = set_new_result(ctx);
    if (result == null) return null;
    TVal* arr = set.array_part();
    uint used = set.array_used;
    if (arr != null) {
        for (uint i = 0; i < used; i++) {
            if (arr[i].is_deleted()) continue;
            set_result_append(result, arr[i], ctx.heap);
        }
    }
    return result;
}

// State for a live-index walk over O.[[SetData]], shared inline by
// isSubsetOf, isDisjointFrom's this.size<=other.size branch, and
// intersection's this.size<=other.size branch (ES2025 §24.2.4.9/.10/.11):
// "Let thisSize be the number of elements in O.[[SetData]]. Let index be 0.
// Repeat, while index < thisSize: let e be O.[[SetData]][index]; index +=
// 1; if e is not empty, call otherRec.[[Has]] ... thisSize is re-read (as a
// live count) after every Has call", so a hostile has() that mutates `set`
// mid-walk is fully observable: growing it extends the walk, shrinking it
// can end the walk early, and index always advances over raw (possibly
// tombstoned) array_part() slots.
struct SetLiveWalk {
    HObject* set;
    uint index;
    uint this_size;
}

// Initializes a live-index walk (ES2025's "Let thisSize be ...; Let index be 0").
fn SetLiveWalk set_live_walk_start(HObject* set) {
    SetLiveWalk w = { set, 0, set_live_count(set) };
    return w;
}

// Advances the walk to the next live element. Returns false when exhausted
// (index has reached the live count re-sampled after the caller's last
// otherRec.[[Has]] call, the caller must call set_live_walk_resample after
// each Has invocation before the next call to this function).
fn bool set_live_walk_next(SetLiveWalk* w, TVal* out_elem) {
    while (w.index < w.this_size) {
        TVal* arr = w.set.array_part();
        if (arr == null || w.index >= w.set.array_used) return false;
        TVal e = arr[w.index];
        w.index++;
        if (!e.is_deleted()) {
            *out_elem = e;
            return true;
        }
    }
    return false;
}

// Re-reads the live count after a otherRec.[[Has]] call, per the spec's
// "NOTE: The number of elements in O.[[SetData]] may have increased ...
// Set thisSize to the number of elements in O.[[SetData]]" step.
fn void set_live_walk_resample(SetLiveWalk* w) {
    w.this_size = set_live_count(w.set);
}

// ============================================================================
// Set constructor (ES6 §23.2.1)
// ============================================================================
fn void builtin_set(BuiltinContext* ctx) {
    coll_construct(ctx, hobject::ObjClass.SET, ctx.heap.set_proto,
        "Constructor Set requires 'new'",
        "Set constructor argument is not an object",
        "add", "Set.prototype.add is not callable",
        "Set: iterable argument is not iterable", false);
}

// ============================================================================
// Set.prototype.add(value), ES6 §23.2.3.1
// ============================================================================
fn void builtin_set_proto_add(BuiltinContext* ctx) {
    HObject* set = check_set(ctx);
    if (set == null) { ctx.result.set_undefined(); return; }
    coll_add_value(ctx, set, false, "", true);
}

// ============================================================================
// Set.prototype.size getter, ES6 §23.2.3.9
// Counts non-deleted entries (deleted slots use TAG_DELETED sentinel).
// ============================================================================
fn void builtin_set_proto_size_get(BuiltinContext* ctx) {
    HObject* set = check_set(ctx);
    if (set == null) return;
    uint count = 0;
    TVal* arr = set.array_part();
    if (arr != null) {
        for (uint i = 0; i < set.array_used; i++) {
            if (!arr[i].is_deleted()) count++;
        }
    }
    ctx.result.set_fastint((long)count);
}

// ============================================================================
// Set.prototype.has(value), ES6 §23.2.3.7
// ============================================================================
fn void builtin_set_proto_has(BuiltinContext* ctx) {
    HObject* set = check_set(ctx);
    if (set == null) { ctx.result.set_undefined(); return; }
    if (ctx.argc < 1) { ctx.result.set_boolean(false); return; }

    TVal value = ctx.regs[ctx.base_reg];
    int found = set_find_value(set, value, ctx.heap);
    ctx.result.set_boolean((found >= 0));
}

// ============================================================================
// Set.prototype.delete(value), ES6 §23.2.3.4
// Per ES6 spec, deletion marks the entry as "empty" rather than shifting so
// concurrent iteration sees the deletion and new entries appear at the end.
// ============================================================================
fn void builtin_set_proto_delete(BuiltinContext* ctx) {
    HObject* set = check_set(ctx);
    if (set == null) { ctx.result.set_undefined(); return; }
    if (ctx.argc < 1) { ctx.result.set_boolean(false); return; }
    coll_delete(ctx, set, ctx.regs[ctx.base_reg], 1, true);
}

// ============================================================================
// Set.prototype.clear(), ES6 §23.2.3.2
// ============================================================================
fn void builtin_set_proto_clear(BuiltinContext* ctx) {
    HObject* set = check_set(ctx);
    if (set == null) { ctx.result.set_undefined(); return; }

    uint cnt = set.array_used;
    for (uint i = 0; i < cnt; i++) {
        set.array_part()[i].set_undefined();
    }
    set.array_used = 0;

    ctx.result.set_undefined();
}

// ============================================================================
// Set.prototype.data.values(), ES6 §23.2.3.10
// Returns a SetIterator with kind=0.
// ============================================================================
fn void builtin_set_proto_values(BuiltinContext* ctx) {
    create_set_iterator(ctx, 0);
}

// ============================================================================
// Set.prototype.entries(), ES6 §23.2.3.5
// Returns [value, value] pairs as a SetIterator with kind=2.
// ============================================================================
fn void builtin_set_proto_entries(BuiltinContext* ctx) {
    create_set_iterator(ctx, 2);
}

// ============================================================================
// SetIterator.prototype.next(), ES6 §23.2.5.2.1
// ============================================================================
fn void builtin_set_iterator_next(BuiltinContext* ctx) {
    TVal this_val = ctx.this_val;
    Heap* heap = ctx.heap;

    if (!this_val.is_object()) {
        builtin_throw(ctx, heap.type_err_proto, "this is not an object");
        return;
    }

    HObject* iter = (HObject*)this_val.get_heapptr();
    if (iter.get_class() != hobject::ObjClass.SET_ITERATOR) {
        builtin_throw(ctx, heap.type_err_proto, "this is not a Set Iterator");
        return;
    }

    HObject* target = (*iter.extra_ptr()).iter.target;
    if (target == null) {
        // Already exhausted, return {value: undefined, done: true}
        HObject*? result_raw = heap.alloc_object(hobject::ObjClass.OBJECT);
        if (catch err = result_raw) { ctx.result.set_undefined(); return; }
        HObject* result = result_raw;
        result.prototype = null;
        TVal undef; undef.set_undefined();
        HString* value_key = (HString*)heap.strs[heap::BuiltinStr.VALUE];
        result.put_prop(value_key, undef, hobject::PROP_FLAGS_WEC, ctx.heap);
        HString* done_key = (HString*)heap.strs[heap::BuiltinStr.DONE];
        TVal done_tv; done_tv.set_boolean(true);
        result.put_prop(done_key, done_tv, hobject::PROP_FLAGS_WEC, ctx.heap);
        ctx.result.set_object(result);
        return;
    }

    uint idx = (*iter.extra_ptr()).iter.index;
    uint kind = (*iter.extra_ptr()).iter.kind;

    bool done = false;
    TVal value;
    value.set_undefined();

    // Skip over deleted slots, array_used is high water mark,
    // and array_part() may contain TAG_DELETED slots from deletes.
    TVal* entries = target.array_part();
    if (entries != null) {
        while (idx < target.array_used && entries[idx].is_deleted()) {
            idx++;
        }
    }

    if (idx < target.array_used) {
        if (entries != null) {
            TVal item = entries[idx];
            if (kind == 1 || kind == 0) {
                // keys()/values(): return the value
                value = item;
            } else {
                // entries(): return [value, value]
                HObject*? pair_raw = heap.alloc_object(hobject::ObjClass.ARRAY);
                if (try pair = pair_raw) {
                    pair.prototype = heap.array_proto;
                    pair.set_array_idx(0, item, ctx.heap);
                    pair.set_array_idx(1, item, ctx.heap);
                    pair.array_used = 2;
                    HString* len_key = (HString*)heap.strs[heap::BuiltinStr.LENGTH];
                    if (len_key != null) {
                        TVal len_tv;
                        len_tv.set_fastint(2);
                        pair.put_prop(len_key, len_tv, hobject::PROP_FLAGS_WEC, ctx.heap);
                    }
                    value.set_object(pair);
                }
            }
            (*iter.extra_ptr()).iter.index = idx + 1;
        } else {
            done = true;
        }
    } else {
        done = true;
    }

    if (done) {
        value.set_undefined();
        (*iter.extra_ptr()).iter.target = null;  // mark exhausted, no yielding after done
    }

    // Create result object: {value, done}
    HObject*? result_raw = heap.alloc_object(hobject::ObjClass.OBJECT);
    if (catch err = result_raw) { ctx.result.set_undefined(); return; }
    HObject* result = result_raw;
    result.prototype = null;

    HString* value_key = (HString*)heap.strs[heap::BuiltinStr.VALUE];
    result.put_prop(value_key, value, hobject::PROP_FLAGS_WEC, ctx.heap);

    HString* done_key = (HString*)heap.strs[heap::BuiltinStr.DONE];
    TVal done_tv;
    done_tv.set_boolean(done);
    result.put_prop(done_key, done_tv, hobject::PROP_FLAGS_WEC, ctx.heap);

    ctx.result.set_object(result);
}

// ============================================================================
// Set.prototype.forEach(callbackfn[, thisArg]), ES6 §23.2.3.6
// ============================================================================
fn void builtin_set_proto_forEach(BuiltinContext* ctx) {
    HObject* set = check_set(ctx);
    if (set == null) { ctx.result.set_undefined(); return; }

    if (ctx.argc < 1) {
        builtin_throw_no_result_change(ctx, ctx.heap.type_err_proto,
            "missing argument 0 when calling function forEach");
        ctx.result.set_undefined();
        return;
    }

    TVal callback = ctx.regs[ctx.base_reg];

    // ES6 §23.2.3.6 step 4: If IsCallable(callbackfn) is false, throw TypeError.
    // IsCallable covers a lightfunc too, so `set.forEach(console.log)` and any
    // other native builtin passed as the callback must be accepted; testing
    // is_object() alone rejected every one of them.
    if (!tval_is_callable(callback)) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "object is not a function");
        return;
    }

    TVal thisArg;
    if (ctx.argc >= 2) { thisArg = ctx.regs[ctx.base_reg + 1]; } else { thisArg.set_undefined(); }

    TVal* entries = set.array_part();
    uint used = set.array_used;
    for (uint i = 0; i < used; i++) {
        TVal value = entries[i];
        if (value.is_deleted()) continue;  // skip deleted slot

        TVal[3] args;
        args[0] = value;
        args[1] = value;
        args[2].set_object((void*)set);
        ctx.heap.call_fn(ctx.vm, callback, &args[0], 3, thisArg);
        if (ctx.heap.has_error) {
            ctx.should_throw = true;
            ctx.throw_value = ctx.heap.error_value;
            ctx.heap.has_error = false;
            ctx.result.set_undefined();
            return;
        }
        // After callback, refresh used (entries may have been added).
        used = set.array_used;
        entries = set.array_part();
    }

    ctx.result.set_undefined();
}

// ============================================================================
// Set[Symbol.species] getter, ES6 §23.2.2.2. Returns the this value (the
// constructor itself), so a subclass like `class MySet extends Set {}` gets
// MySet back from SpeciesConstructor calls that inherit this accessor.
// ============================================================================
fn void builtin_set_species_getter(BuiltinContext* ctx) {
    *ctx.result = ctx.this_val;
}

// ============================================================================
// Set.prototype.union(other), ES2025 §24.2.4.16
// Always iterates other.[[SetKeys]] and appends every not-yet-present value
// to a copy of this.[[SetData]]; other.[[SetHas]] is never invoked.
// ============================================================================
fn void builtin_set_proto_union(BuiltinContext* ctx) {
    HObject* set = check_set(ctx);
    if (set == null) { ctx.result.set_undefined(); return; }
    TVal other; other.set_undefined();
    if (ctx.argc >= 1) other = ctx.regs[ctx.base_reg];

    SetRecord? rec_opt = get_set_record(ctx, other);
    if (catch err = rec_opt) { ctx.result.set_undefined(); return; }
    SetRecord rec = rec_opt;

    HObject* result = set_copy_live_entries(ctx, set);
    if (result == null) { ctx.result.set_undefined(); return; }

    TVal iterator = set_record_get_keys_iterator(ctx, &rec);
    if (ctx.should_throw) { ctx.result.set_undefined(); return; }
    TVal next_fn = set_iter_get_next_fn(ctx, iterator);
    if (ctx.should_throw) { ctx.result.set_undefined(); return; }

    while (true) {
        TVal next_value;
        bool done;
        if (!set_iter_step(ctx, iterator, next_fn, &next_value, &done)) { ctx.result.set_undefined(); return; }
        if (done) break;
        next_value = set_normalize_neg_zero(next_value);
        if (set_find_value(result, next_value, ctx.heap) < 0) {
            set_result_append(result, next_value, ctx.heap);
        }
    }

    ctx.result.set_object(result);
}

// ============================================================================
// Set.prototype.intersection(other), ES2025 §24.2.4.9
// If SetDataSize(this) <= otherRec.size, live-walk this's raw SetData and
// test each element with otherRec.[[SetHas]] (deduping into result, since a
// hostile has() can remove-and-re-add an element, causing it to be visited
// twice); otherwise iterate otherRec.[[SetKeys]] and test each value with
// this.[[SetHas]] (via find_in_array_part) instead.
// ============================================================================
fn void builtin_set_proto_intersection(BuiltinContext* ctx) {
    HObject* set = check_set(ctx);
    if (set == null) { ctx.result.set_undefined(); return; }
    TVal other; other.set_undefined();
    if (ctx.argc >= 1) other = ctx.regs[ctx.base_reg];

    SetRecord? rec_opt = get_set_record(ctx, other);
    if (catch err = rec_opt) { ctx.result.set_undefined(); return; }
    SetRecord rec = rec_opt;

    HObject* result = set_new_result(ctx);
    if (result == null) { ctx.result.set_undefined(); return; }

    if ((double)set_live_count(set) <= rec.size) {
        SetLiveWalk walk = set_live_walk_start(set);
        TVal elem;
        while (set_live_walk_next(&walk, &elem)) {
            bool has = set_record_has(ctx, &rec, elem);
            if (ctx.should_throw) { ctx.result.set_undefined(); return; }
            if (has && set_find_value(result, elem, ctx.heap) < 0) set_result_append(result, elem, ctx.heap);
            set_live_walk_resample(&walk);
        }
    } else {
        TVal iterator = set_record_get_keys_iterator(ctx, &rec);
        if (ctx.should_throw) { ctx.result.set_undefined(); return; }
        TVal next_fn = set_iter_get_next_fn(ctx, iterator);
        if (ctx.should_throw) { ctx.result.set_undefined(); return; }
        while (true) {
            TVal next_value;
            bool done;
            if (!set_iter_step(ctx, iterator, next_fn, &next_value, &done)) { ctx.result.set_undefined(); return; }
            if (done) break;
            next_value = set_normalize_neg_zero(next_value);
            if (set_find_value(set, next_value, ctx.heap) >= 0 && set_find_value(result, next_value, ctx.heap) < 0) {
                set_result_append(result, next_value, ctx.heap);
            }
        }
    }

    ctx.result.set_object(result);
}

// ============================================================================
// Set.prototype.difference(other), ES2025 §24.2.4.5
// resultSetData is always a copy of this.[[SetData]] made up front. If
// SetDataSize(this) <= otherRec.size, walk the *copy* by raw index, up to
// a thisSize fixed once at branch entry, not resampled, tombstoning each
// element found via otherRec.[[SetHas]] (this.[[SetHas]] calls only ever
// observe/mutate the live receiver, never the copy). Otherwise iterate
// otherRec.[[SetKeys]] and tombstone each matching value in the copy.
// ============================================================================
fn void builtin_set_proto_difference(BuiltinContext* ctx) {
    HObject* set = check_set(ctx);
    if (set == null) { ctx.result.set_undefined(); return; }
    TVal other; other.set_undefined();
    if (ctx.argc >= 1) other = ctx.regs[ctx.base_reg];

    SetRecord? rec_opt = get_set_record(ctx, other);
    if (catch err = rec_opt) { ctx.result.set_undefined(); return; }
    SetRecord rec = rec_opt;

    HObject* result = set_copy_live_entries(ctx, set);
    if (result == null) { ctx.result.set_undefined(); return; }

    if ((double)set_live_count(set) <= rec.size) {
        uint this_size = set_live_count(set);
        uint index = 0;
        TVal* result_arr = result.array_part();
        while (index < this_size && index < result.array_used) {
            TVal e = result_arr[index];
            if (!e.is_deleted()) {
                bool has = set_record_has(ctx, &rec, e);
                if (ctx.should_throw) { ctx.result.set_undefined(); return; }
                if (has) {
                    ctx.heap.decref_tval(&result_arr[index]);
                    result_arr[index].set_deleted();
                }
            }
            index++;
        }
        ctx.result.set_object(result);
    } else {
        TVal iterator = set_record_get_keys_iterator(ctx, &rec);
        if (ctx.should_throw) { ctx.result.set_undefined(); return; }
        TVal next_fn = set_iter_get_next_fn(ctx, iterator);
        if (ctx.should_throw) { ctx.result.set_undefined(); return; }
        while (true) {
            TVal next_value;
            bool done;
            if (!set_iter_step(ctx, iterator, next_fn, &next_value, &done)) { ctx.result.set_undefined(); return; }
            if (done) break;
            next_value = set_normalize_neg_zero(next_value);
            int found = set_find_value(result, next_value, ctx.heap);
            if (found >= 0) {
                ctx.heap.decref_tval(&result.array_part()[(uint)found]);
                result.array_part()[(uint)found].set_deleted();
            }
        }
        ctx.result.set_object(result);
    }
}

// ============================================================================
// Set.prototype.symmetricDifference(other), ES2025 §24.2.4.15
// Copies this once up front, then iterates otherRec.[[SetKeys]]: for each
// value, whether it is a live member of the *original* `this` (not the
// running copy) decides remove-vs-add, a value already shared with this
// is removed from the copy (if still present there), one not shared with
// this is added to the copy (if not already added by an earlier duplicate
// from the other's iterator). other.[[SetHas]] is never invoked.
// ============================================================================
fn void builtin_set_proto_symmetricDifference(BuiltinContext* ctx) {
    HObject* set = check_set(ctx);
    if (set == null) { ctx.result.set_undefined(); return; }
    TVal other; other.set_undefined();
    if (ctx.argc >= 1) other = ctx.regs[ctx.base_reg];

    SetRecord? rec_opt = get_set_record(ctx, other);
    if (catch err = rec_opt) { ctx.result.set_undefined(); return; }
    SetRecord rec = rec_opt;

    HObject* result = set_copy_live_entries(ctx, set);
    if (result == null) { ctx.result.set_undefined(); return; }

    TVal iterator = set_record_get_keys_iterator(ctx, &rec);
    if (ctx.should_throw) { ctx.result.set_undefined(); return; }
    TVal next_fn = set_iter_get_next_fn(ctx, iterator);
    if (ctx.should_throw) { ctx.result.set_undefined(); return; }

    while (true) {
        TVal next_value;
        bool done;
        if (!set_iter_step(ctx, iterator, next_fn, &next_value, &done)) { ctx.result.set_undefined(); return; }
        if (done) break;
        next_value = set_normalize_neg_zero(next_value);
        int found = set_find_value(result, next_value, ctx.heap);
        if (set_find_value(set, next_value, ctx.heap) >= 0) {
            if (found >= 0) {
                ctx.heap.decref_tval(&result.array_part()[(uint)found]);
                result.array_part()[(uint)found].set_deleted();
            }
        } else {
            if (found < 0) set_result_append(result, next_value, ctx.heap);
        }
    }

    ctx.result.set_object(result);
}

// ============================================================================
// Set.prototype.isSubsetOf(other), ES2025 §24.2.4.11
// If SetDataSize(this) > otherRec.size, return false without any iteration.
// Otherwise live-walk this's raw SetData, testing every element with
// otherRec.[[SetHas]], a hostile has() may mutate `this` mid-walk (see
// set_live_walk's doc comment).
// ============================================================================
fn void builtin_set_proto_isSubsetOf(BuiltinContext* ctx) {
    HObject* set = check_set(ctx);
    if (set == null) { ctx.result.set_undefined(); return; }
    TVal other; other.set_undefined();
    if (ctx.argc >= 1) other = ctx.regs[ctx.base_reg];

    SetRecord? rec_opt = get_set_record(ctx, other);
    if (catch err = rec_opt) { ctx.result.set_undefined(); return; }
    SetRecord rec = rec_opt;

    if ((double)set_live_count(set) > rec.size) { ctx.result.set_boolean(false); return; }

    SetLiveWalk walk = set_live_walk_start(set);
    TVal elem;
    while (set_live_walk_next(&walk, &elem)) {
        bool has = set_record_has(ctx, &rec, elem);
        if (ctx.should_throw) { ctx.result.set_undefined(); return; }
        if (!has) { ctx.result.set_boolean(false); return; }
        set_live_walk_resample(&walk);
    }
    ctx.result.set_boolean(true);
}

// ============================================================================
// Set.prototype.isSupersetOf(other), ES2025 §24.2.4.12
// If this.size < otherRec.size, return false without any iteration. Otherwise
// iterate otherRec.[[SetKeys]] and test each value against this via
// find_in_array_part, stopping (and closing the iterator) as soon as a value
// is missing from this.
// ============================================================================
fn void builtin_set_proto_isSupersetOf(BuiltinContext* ctx) {
    HObject* set = check_set(ctx);
    if (set == null) { ctx.result.set_undefined(); return; }
    TVal other; other.set_undefined();
    if (ctx.argc >= 1) other = ctx.regs[ctx.base_reg];

    SetRecord? rec_opt = get_set_record(ctx, other);
    if (catch err = rec_opt) { ctx.result.set_undefined(); return; }
    SetRecord rec = rec_opt;

    double this_size = (double)set_live_count(set);
    if (this_size < rec.size) { ctx.result.set_boolean(false); return; }

    TVal iterator = set_record_get_keys_iterator(ctx, &rec);
    if (ctx.should_throw) { ctx.result.set_undefined(); return; }
    TVal next_fn = set_iter_get_next_fn(ctx, iterator);
    if (ctx.should_throw) { ctx.result.set_undefined(); return; }

    while (true) {
        TVal next_value;
        bool done;
        if (!set_iter_step(ctx, iterator, next_fn, &next_value, &done)) { ctx.result.set_undefined(); return; }
        if (done) break;
        next_value = set_normalize_neg_zero(next_value);
        if (set_find_value(set, next_value, ctx.heap) < 0) {
            set_iter_close(ctx, iterator);
            ctx.result.set_boolean(false);
            return;
        }
    }
    ctx.result.set_boolean(true);
}

// ============================================================================
// Set.prototype.isDisjointFrom(other), ES2025 §24.2.4.10
// If SetDataSize(this) <= otherRec.size, live-walk this's raw SetData and
// test each element with otherRec.[[SetHas]]; otherwise iterate
// otherRec.[[SetKeys]] and test each value against this via find_in_array_part.
// Stops (closing the set-like's iterator if one was obtained) at the first
// shared value found.
// ============================================================================
fn void builtin_set_proto_isDisjointFrom(BuiltinContext* ctx) {
    HObject* set = check_set(ctx);
    if (set == null) { ctx.result.set_undefined(); return; }
    TVal other; other.set_undefined();
    if (ctx.argc >= 1) other = ctx.regs[ctx.base_reg];

    SetRecord? rec_opt = get_set_record(ctx, other);
    if (catch err = rec_opt) { ctx.result.set_undefined(); return; }
    SetRecord rec = rec_opt;

    if ((double)set_live_count(set) <= rec.size) {
        SetLiveWalk walk = set_live_walk_start(set);
        TVal elem;
        while (set_live_walk_next(&walk, &elem)) {
            bool has = set_record_has(ctx, &rec, elem);
            if (ctx.should_throw) { ctx.result.set_undefined(); return; }
            if (has) { ctx.result.set_boolean(false); return; }
            set_live_walk_resample(&walk);
        }
        ctx.result.set_boolean(true);
    } else {
        TVal iterator = set_record_get_keys_iterator(ctx, &rec);
        if (ctx.should_throw) { ctx.result.set_undefined(); return; }
        TVal next_fn = set_iter_get_next_fn(ctx, iterator);
        if (ctx.should_throw) { ctx.result.set_undefined(); return; }
        while (true) {
            TVal next_value;
            bool done;
            if (!set_iter_step(ctx, iterator, next_fn, &next_value, &done)) { ctx.result.set_undefined(); return; }
            if (done) break;
            next_value = set_normalize_neg_zero(next_value);
            if (set_find_value(set, next_value, ctx.heap) >= 0) {
                set_iter_close(ctx, iterator);
                ctx.result.set_boolean(false);
                return;
            }
        }
        ctx.result.set_boolean(true);
    }
}

// ============================================================================
// Set constructor registration
// ============================================================================

fn bool register_set_constructor(EnvRecord* global_env, Heap* heap) {
    // Create Set prototype (an ordinary object per ES6 §23.2.3, must NOT
    // carry the SET ObjClass flag, otherwise set_check() would accept it as
    // a valid Set and methods like clear() would skip the TypeError guard).
    HObject*? proto_raw = heap.alloc_object(hobject::ObjClass.OBJECT);
    if (catch err = proto_raw) return false;
    HObject* proto = proto_raw;
    proto.prototype = heap.object_proto;
    heap.set_proto = proto;

    // Add .add(value) method
    if (!register_string_proto_method(proto, heap, "add", Builtin.SET_PROTO_ADD.ordinal)) return false;
    // Add .has(value) method
    if (!register_string_proto_method(proto, heap, "has", Builtin.SET_PROTO_HAS.ordinal)) return false;
    // Add .delete(value) method
    if (!register_string_proto_method(proto, heap, "delete", Builtin.SET_PROTO_DELETE.ordinal)) return false;
    // Add .clear() method
    if (!register_string_proto_method(proto, heap, "clear", Builtin.SET_PROTO_CLEAR.ordinal)) return false;
    // Add .values() method (register FIRST so .keys can alias it)
    if (!register_string_proto_method(proto, heap, "values", Builtin.SET_PROTO_VALUES.ordinal)) return false;
    // .keys() must be the same function object as .values() per ES6 §23.2.3.8
    {
        HString* values_key = builtin_intern_string(heap, "values");
        HString* keys_key = builtin_intern_string(heap, "keys");
        if (values_key != null && keys_key != null) {
            PropValue*? values_prop_opt = proto.find_prop(values_key, heap);
            if (try values_prop = values_prop_opt) {
                proto.put_prop(keys_key, *values_prop, hobject::PROP_FLAGS_WC, heap);
            }
        }
    }
    // Add .entries() method
    if (!register_string_proto_method(proto, heap, "entries", Builtin.SET_PROTO_ENTRIES.ordinal)) return false;
    // Add .forEach() method
    if (!register_string_proto_method(proto, heap, "forEach", Builtin.SET_PROTO_FOREACH.ordinal)) return false;
    // Set methods proposal (ES2025 §24.2.4)
    if (!register_string_proto_method(proto, heap, "union", Builtin.SET_PROTO_UNION.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "intersection", Builtin.SET_PROTO_INTERSECTION.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "difference", Builtin.SET_PROTO_DIFFERENCE.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "symmetricDifference", Builtin.SET_PROTO_SYMMETRICDIFFERENCE.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "isSubsetOf", Builtin.SET_PROTO_ISSUBSETOF.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "isSupersetOf", Builtin.SET_PROTO_ISSUPERSETOF.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "isDisjointFrom", Builtin.SET_PROTO_ISDISJOINTFROM.ordinal)) return false;
    // Set.prototype[Symbol.iterator] must be the *same function object* as
    // .values (ES6 §23.2.3.11), not merely an equivalent implementation.
    {
        HString* iter_sym = ensure_iterator_symbol(heap);
        HString* values_key = builtin_intern_string(heap, "values");
        if (iter_sym != null && values_key != null) {
            PropValue*? values_prop_opt = proto.find_prop(values_key, heap);
            if (try values_prop = values_prop_opt) {
                proto.put_prop(iter_sym, *values_prop, hobject::PROP_FLAGS_WC, heap);
            }
        }
    }
    
    // Set @@toStringTag on Set.prototype
    HString* tag_key = ensure_tostringtag_symbol(heap);
    if (tag_key != null) {
        TVal tag_tv;
        tag_tv.set_string(builtin_intern_string(heap, "Set"));
        proto.put_prop(tag_key, tag_tv, hobject::PROP_FLAGS_NWC, heap);
    }

    // Register .size as a getter accessor property (ES6 §23.2.3.9)
    {
        HString* size_key = builtin_intern_string(heap, "size");
        if (size_key != null) {
            HObject*? fn_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
            if (catch err = fn_raw) return false;
            HObject* fn_obj = fn_raw;
            (*fn_obj.extra_ptr()).func.builtin_fn_index = (int)Builtin.SET_PROTO_SIZE_GET.ordinal;
            fn_obj.flags.callable = true;
            fn_obj.prototype = heap.function_proto;
            // Set .name = "get size"
            char[] fn_name = "get size";
            HString* name_str = builtin_intern_string(heap, fn_name);
            if (name_str != null) {
                TVal name_tv;
                name_tv.set_string(name_str);
                HString* name_key = heap.str(heap::BuiltinStr.NAME);
                fn_obj.put_prop(name_key, name_tv, hobject::PROP_FLAGS_NWC, heap);
            }
            HString* length_key = (HString*)heap.strs[heap::BuiltinStr.LENGTH];
            if (length_key != null) {
                TVal len_tv;
                len_tv.set_fastint(0);
                fn_obj.put_prop(length_key, len_tv, hobject::PROP_FLAGS_NWC, heap);
            }
            TVal getter_tv;
            getter_tv.set_object(fn_obj);
            TVal undef;
            undef.set_undefined();
            hobject::PropFlags acc_flags;
            acc_flags.writable = false;
            acc_flags.enumerable = false;
            acc_flags.configurable = true;
            acc_flags.is_accessor = true;
            proto.put_prop(size_key, hobject::hobject_create_accessors(heap, getter_tv, undef), acc_flags, heap);
        }
    }

    // Create Set constructor as a proper function object
    HObject*? ctor_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
    if (catch err = ctor_raw) return false;
    HObject* ctor = ctor_raw;
    ctor.prototype = heap.function_proto;
    (*ctor.extra_ptr()).func.builtin_fn_index = (int)Builtin.SET.ordinal;

    // Set .constructor on Set.prototype
    HString* constructor_key = (HString*)heap.strs[heap::BuiltinStr.CONSTRUCTOR];
    TVal constructor_tv;
    constructor_tv.set_object(ctor);
    proto.put_prop(constructor_key, constructor_tv, hobject::PROP_FLAGS_WC, heap);

    // Set Set.prototype on the constructor (non-writable, non-enumerable, non-configurable)
    HString* prototype_key = (HString*)heap.strs[heap::BuiltinStr.PROTOTYPE];
    TVal proto_tv;
    proto_tv.set_object(proto);
    PropFlags proto_pflags;
    proto_pflags.writable = false;
    proto_pflags.enumerable = false;
    proto_pflags.configurable = false;
    proto_pflags.is_accessor = false;
    ctor.put_prop(prototype_key, proto_tv, proto_pflags, heap);

    // Set Set.length
    HString* length_key = (HString*)heap.strs[heap::BuiltinStr.LENGTH];
    TVal length_tv;
    length_tv.set_fastint(0);
    ctor.put_prop(length_key, length_tv, hobject::PROP_FLAGS_NWC, heap);

    // Set[Symbol.species] accessor, ES6 §23.2.2.2: getter returns `this`.
    {
        HString* species_sym = ensure_species_symbol(heap);
        if (species_sym != null) {
            HObject*? getter_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
            if (try getter = getter_raw) {
                getter.flags.callable = true;
                getter.flags.constructable = false;
                getter.prototype = heap.function_proto;
                (*getter.extra_ptr()).func.builtin_fn_index = (int)Builtin.SET_SPECIES_GETTER.ordinal;
                HString* getter_name_key = heap.str(heap::BuiltinStr.NAME);
                HString* getter_name_str = builtin_intern_string(heap, "get [Symbol.species]");
                if (getter_name_key != null && getter_name_str != null) {
                    TVal gn_tv; gn_tv.set_string(getter_name_str);
                    getter.put_prop(getter_name_key, gn_tv, hobject::PROP_FLAGS_NWC, heap);
                }
                HString* getter_len_key = (HString*)heap.strs[heap::BuiltinStr.LENGTH];
                if (getter_len_key != null) {
                    TVal gl_tv; gl_tv.set_fastint(0);
                    getter.put_prop(getter_len_key, gl_tv, hobject::PROP_FLAGS_NWC, heap);
                }
                TVal getter_tv; getter_tv.set_object(getter);
                TVal undef_tv; undef_tv.set_undefined();
                PropFlags acc_flags;
                acc_flags.writable = false;
                acc_flags.enumerable = false;
                acc_flags.configurable = true;
                acc_flags.is_accessor = true;
                ctor.put_prop(species_sym, hobject::hobject_create_accessors(heap, getter_tv, undef_tv), acc_flags, heap);
            }
        }
    }

    // Register Set constructor globally
    HString* set_key = heap.str_intern("Set");
    if (set_key == null) return false;
    TVal set_val;
    set_val.set_object(ctor);
    set_func_ctor_name(ctor, heap, "Set");
    env::env_declare_nonenum(global_env, set_key, set_val);

    return true;
}
