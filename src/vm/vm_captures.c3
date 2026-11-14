module boomkat::vm;

import boomkat::hobject;
import boomkat::env;
import boomkat::types;
import boomkat::heap;
import boomkat::bytecode;

// The running closure's capture records and their count, or null when the
// frame runs code other than the closure's own.
fn CaptureRef* capture_refs_of(Activation* act, uint* count) {
    if (!act.tv_func.is_object()) return null;
    HObjectFunction* fields = &(*((HObject*)act.tv_func.get_heapptr()).extra_ptr()).func;
    if (fields.capture_refs == null || fields.comp_func == null
        || fields.comp_func != (CompiledFunction*)act.func) return null;
    *count = fields.comp_func.capture_count;
    return fields.capture_refs;
}

// The capture record `index` of the running closure, or null when the frame
// runs code other than the closure's own.
fn CaptureRef* capture_ref(Activation* act, uint index) {
    uint count;
    CaptureRef* refs = capture_refs_of(act, &count);
    return refs != null && index < count ? &refs[index] : null;
}

// The read side of capture_value_slot without the shadow-guarded walk, which
// returns null so the caller can fall back to capture_value_slot. It makes no
// calls, so a handler built on it needs no stack frame.
macro hobject::PropValue* capture_read_slot(CaptureRef* ref) {
    if (ref.is_value) return (hobject::PropValue*)&ref.value;
    HObject* owner = ref.owner;
    if (owner == null || ref.guard_shadow || (ref.is_cell && ref.prop_idx >= owner.prop_count)) return null;
    hobject::PropValue* value = &owner.prop_values()[ref.prop_idx];
    if (!ref.is_cell && slot_is_tdz(value)) return null;
    return value;
}

// A capture whose binding did not exist when the closure was created is
// resolved again on use, as creation would have resolved it. Hoisted function
// declarations are published after every closure in the body is created, so a
// closure that calls a sibling declaration would otherwise look the name up on
// every read.
fn bool capture_resolve_late(Activation* act, CaptureRef* ref, uint index, Heap* h) @noinline {
    HObjectFunction* fields = &(*((HObject*)act.tv_func.get_heapptr()).extra_ptr()).func;
    CompiledFunction* template = fields.comp_func;
    if (template.capture_names == null) return false;
    uint name_idx = template.capture_names[index];
    if (name_idx >= template.const_count || !template.constants[name_idx].is_string()) return false;
    void* key = template.constants[name_idx].get_heapptr();
    Vm* vm = (Vm*)h.vm_ptr;
    CaptureRef found;
    int resolved = resolve_capture_ref(vm, fields.lex_env, key, &found);
    if (resolved == 0 && fields.var_env != fields.lex_env) {
        resolved = resolve_capture_ref(vm, fields.var_env, key, &found);
    }
    if (resolved <= 0 || found.owner == null) return false;
    if (index < 64 && (template.capture_fixed & (1UL << index)) != 0) found.guard_shadow = false;
    found.owner.as_header().incref();
    h.shade_root_object(found.owner);
    *ref = found;
    return true;
}

// Fetch the current slots because adding environment bindings can resize
// their storage. A writer passes `owner` to receive the object that
// holds the slot, for the write barrier.
fn hobject::PropValue* capture_value_slot(Activation* act, uint index, Heap* h, bool write = false,
                                          HObject** owner = null) @inline {
    CaptureRef* ref = capture_ref(act, index);
    if (ref == null) return null;
    if (ref.is_value) return write ? null : (hobject::PropValue*)&ref.value;
    if (ref.owner == null && !capture_resolve_late(act, ref, index, h)) return null;
    if (ref.is_cell) {
        if (ref.prop_idx >= ref.owner.prop_count) return null;
        if (owner != null) *owner = ref.owner;
        return &ref.owner.prop_values()[ref.prop_idx];
    }
    if (ref.guard_shadow) {
        HObjectFunction* fields = &(*((HObject*)act.tv_func.get_heapptr()).extra_ptr()).func;
        TVal name = fields.comp_func.constants[fields.comp_func.capture_names[index]];
        void* key = name.get_heapptr();
        EnvRecord* cur = act.lex_env;
        while (cur != null) {
            if (cur.is_with()) return null;
            if (cur.bindings != null) {
                int idx = cur.bindings.find_prop_idx(key, h);
                if (idx >= 0) {
                    if (cur.bindings != ref.owner || (uint)idx != ref.prop_idx) return null;
                    break;
                }
            }
            cur = cur.parent;
        }
        if (cur == null) return null;
    }
    if (write && !ref.owner.get_prop_flags(ref.prop_idx, h).writable) return null;
    hobject::PropValue* value = &ref.owner.prop_values()[ref.prop_idx];
    if (slot_is_tdz(value)) return null;
    if (owner != null) *owner = ref.owner;
    return value;
}

// Compact cell storage operations. NEWCELLS is cold and allocates; the three
// slot operations are also the switch fallback for threaded ownership cases.
fn TVal? dispatch_cells(Dispatch* ds, Opcode op, TVal* ra, TVal* rb,
                        TVal* rc, DecodedInsn insn) {
    Vm* vm = ds.vm;
    switch (op) {
        case Opcode.NEWCELLS: {
            vm.heap.decref_tval(ra);
            ra.set_undefined();
            uint count = insn.get_bc();
            HObject*? cells_raw = vm.heap.alloc_object(hobject::ObjClass.OBJECT);
            if (catch cells_raw) return (TVal){};
            HObject* cells = cells_raw;
            cells.prototype = null;
            // Private cells have values but no property keys. Inline slots
            // avoid a second allocation; ordinary object tracing owns values.
            if (count > cells.prop_capacity) {
                cells.props = vm.heap.pool_alloc((usz)count * hobject::PropValue::size)!;
                cells.prop_capacity = count;
            }
            for (uint i = 0; i < count; i++) cells.prop_values()[i].set_undefined();
            cells.prop_count = count;
            vm.heap.shade_root_object(cells);
            ra.set_object(cells);
            track_heap_store(ds.act, ra, (uint)insn.a);
            return (TVal){};
        }
        case Opcode.GETCELL: {
            if (!rb.is_object()) return (TVal){};
            HObject* cells = (HObject*)rb.get_heapptr();
            uint slot_idx = (uint)insn.c;
            if (cells == null || cells.get_class() != hobject::ObjClass.OBJECT
                || slot_idx >= cells.prop_count) return (TVal){};
            vm.heap.copy_slot_to_tval(ra, &cells.prop_values()[slot_idx]);
            track_heap_store(ds.act, ra, (uint)insn.a);
            return (TVal){};
        }
        case Opcode.SETCELL: {
            if (!rb.is_object()) return (TVal){};
            HObject* cells = (HObject*)rb.get_heapptr();
            uint slot_idx = (uint)insn.c;
            if (cells == null || cells.get_class() != hobject::ObjClass.OBJECT
                || slot_idx >= cells.prop_count) return (TVal){};
            vm.heap.store_slot_ref(cells, &cells.prop_values()[slot_idx], ra);
            return (TVal){};
        }
        case Opcode.MOVECELL: {
            if (!rb.is_object()) return (TVal){};
            HObject* cells = (HObject*)rb.get_heapptr();
            uint slot_idx = (uint)insn.c;
            if (cells == null || cells.get_class() != hobject::ObjClass.OBJECT
                || slot_idx >= cells.prop_count) return (TVal){};
            hobject::PropValue* slot = &cells.prop_values()[slot_idx];
            vm.heap.tval_move_slot_fast(cells, slot, ra);
            return (TVal){};
        }
        default: return (TVal){};
    }
}
