// Helpers baseline code calls directly for the operations whose threaded
// handler completes them but whose inline path would be long: each runs the
// handler's own logic without the thunk's frame and returns false, with the
// registers untouched, when the operation function has to run it.
module boomkat::vm @feat(SLJIT);

import boomkat::bytecode;
import boomkat::heap;
import boomkat::hobject;
import boomkat::hstring;
import boomkat::types;

// `v instanceof F` for the instruction before `next`, through th_instanceof.
fn bool jit_instanceof(Dispatch* ds, Instruction* next) {
    if (!jit_relay_ready) jit_relay_init();
    ds.curr_pc = next;
    return th_instanceof(next - 1, &jit_stop_table, ds.regs_base, &ds.cold) == next;
}

// An ADD whose operands are not both numbers, for the instruction before
// `next`: the concatenations th_add_concat completes, with the operand classes
// recorded as jit_relay records them.
fn bool jit_add_concat(Dispatch* ds, Instruction* next) {
    if (ds.ic_base == null) return false;
    Instruction* pc = next - 1;
    TVal* regs = ds.regs_base;
    ds.curr_pc = next;
    note_feedback(ds, { .op = pc.op, .a = pc.a, .b = pc.b, .c = pc.c }, false);
    return vm_concat_add(ds.vm, ds.act, regs + pc.a, regs + pc.b, regs + pc.c, (uint)pc.a, next, ds.code_end)
        == ConcatStatus.DONE;
}

// A GETPROP or GETPROP_CACHE of an element that the inline element read left,
// completed as dispatch_property completes it. The key is a fastint, or the
// array-index string a for-in loop yields. A fastint reads the character of a
// string, or an element th_getprop_array reads (an arguments object's among
// them). An array reads its element, or undefined for a hole or an index past
// its dense part when nothing on the chain can hold the index: a prototype
// that is Heap.index_clean_proto, and no indexed named property of its own.
fn bool jit_get_elem(Dispatch* ds, Instruction* next) {
    if (!jit_relay_ready) jit_relay_init();
    Instruction* pc = next - 1;
    TVal* regs = ds.regs_base;
    TVal* rb = regs + pc.b;
    TVal* rc = regs + pc.c;
    heap::Heap* h = ds.cold.heap;
    bool by_string = rc.is_string();
    long idx;
    if (rc.is_fastint()) {
        idx = rc.get_fastint();
    } else if (by_string && rb.is_object() && !((HString*)rc.get_heapptr()).is_symbol()
               && ((HString*)rc.get_heapptr()).is_arridx()) {
        idx = ((HString*)rc.get_heapptr()).array_index();
    } else {
        return false;
    }
    ds.curr_pc = next;
    if (rb.is_string()) {
        HString* s = (HString*)rb.get_heapptr();
        if (s.is_symbol() || idx < 0 || idx >= (long)s.unit_len()) return false;
        char[4] buf;
        HString* ch = h.str_intern(buf[:hstring::encode_codepoint(s.unit_at((uint)idx), buf[:4])]);
        if (ch == null) return false;
        h.set_reg_string(regs + pc.a, ch);
        return true;
    }
    if (!by_string && th_getprop_array(pc, &jit_stop_table, regs, &ds.cold) == next) return true;
    if (!rb.is_object() || idx < 0 || idx >= (long)hobject::MAX_ARRAY_INDEX_END) return false;
    HObject* obj = (HObject*)rb.get_heapptr();
    if (obj.get_class() != hobject::ObjClass.ARRAY || obj.is_proxy() || obj.flags.has_indexed_named_prop) return false;
    if (idx < (long)obj.array_size) {
        TVal element = obj.array_part()[idx].get();
        // A present element by number is the handler's, which declined to publish it.
        if (!element.is_undefined()) return by_string && th_publish_read(pc, &jit_stop_table, regs, &ds.cold, element) == next;
    }
    if (obj.prototype != h.index_clean_proto) return false;
    h.set_reg_undefined(regs + pc.a);
    return true;
}

// A PUTPROP of a fastint key that the inline element store left, completed
// as dispatch_property's dense array store completes it: a store into a hole,
// an append and a growth of the dense part, under the conditions of its index
// test (no indexed named property, and a chain that cannot shadow a new index).
// An empty array stores its first element as HObject.put_prop does.
fn bool jit_put_elem(Dispatch* ds, Instruction* next) {
    if (!jit_relay_ready) jit_relay_init();
    Instruction* pc = next - 1;
    TVal* regs = ds.regs_base;
    TVal* target = regs + pc.a;
    TVal* key = regs + pc.b;
    TVal* value = regs + pc.c;
    if (!key.is_fastint() || !target.is_object() || value.is_undefined()) return false;
    heap::Heap* h = ds.cold.heap;
    HObject* array = (HObject*)target.get_heapptr();
    long idx = key.get_fastint();
    if (array.get_class() != hobject::ObjClass.ARRAY || array.is_proxy() || array.flags.has_indexed_named_prop
        || idx < 0 || idx >= 0x1000000L) return false;
    // An array with no dense part is a sealed or frozen one (whose length is a
    // named entry) or an empty one, whose first element put_prop stores densely.
    if (array.array_part() == null
        && (array.prop_count != 0 || !array.flags.extensible || !hobject::dense_index_ok(0, (uint)idx))) return false;
    if (!array.dense_idx_present((uint)idx) && !array.index_store_unshadowed(h)) return false;
    ds.curr_pc = next;
    if (!array.set_array_idx((uint)idx, *value, h)) return false;
    if ((uint)idx >= *array.array_len_ptr()) {
        *array.array_len_ptr() = (uint)idx + 1;
        array.sync_named_length(h);
    }
    return true;
}

// A GETPROPC or GETPROPC_CACHED of `length` on an arguments object that still
// has the shape of its argument count (th_getprop_array's test), whose
// property table holds the arguments, then `length`: the value is the slot
// after them. The site's key is the constant `length`.
fn bool jit_get_args_length(Dispatch* ds, Instruction* next) {
    if (!jit_relay_ready) jit_relay_init();
    Instruction* pc = next - 1;
    TVal* regs = ds.regs_base;
    TVal* rb = regs + pc.b;
    heap::Heap* h = ds.cold.heap;
    if (!rb.is_object()) return false;
    HObject* obj = (HObject*)rb.get_heapptr();
    if (obj.get_class() != hobject::ObjClass.ARGUMENTS || obj.is_proxy()) return false;
    uint nargs = *obj.array_len_ptr();
    if (nargs >= h.args_shapes.len || obj.shape_id != h.args_shapes[nargs]) return false;
    ds.curr_pc = next;
    return th_publish_read(pc, &jit_stop_table, regs, &ds.cold, obj.prop_values()[nargs].get()) == next;
}

// A MOD the inline integer path left, as op_mod computes it for numbers: the
// operand classes are recorded as jit_relay records them, and anything but two
// numbers is the operation function's.
fn bool jit_mod(Dispatch* ds, Instruction* next) {
    Instruction* pc = next - 1;
    TVal* regs = ds.regs_base;
    TVal* rb = regs + pc.b;
    TVal* rc = regs + pc.c;
    if (!(rb.is_fastint() || rb.is_number()) || !(rc.is_fastint() || rc.is_number())) return false;
    ds.curr_pc = next;
    note_feedback(ds, { .op = pc.op, .a = pc.a, .b = pc.b, .c = pc.c }, false);
    heap::Heap* h = ds.cold.heap;
    TVal* ra = regs + pc.a;
    if (types::both_fastint(rb, rc) && rc.get_fastint() != 0) {
        long rem = rb.get_fastint() % rc.get_fastint();
        if (rem == 0 && rb.get_fastint() < 0) {
            h.set_reg_number(ra, -0.0);
        } else {
            h.set_reg_fastint(ra, rem);
        }
        return true;
    }
    double x = rb.is_fastint() ? (double)rb.get_fastint() : rb.get_number();
    double y = rc.is_fastint() ? (double)rc.get_fastint() : rc.get_number();
    h.set_reg_number(ra, x % y);
    return true;
}
