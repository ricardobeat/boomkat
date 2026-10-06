module boomkat::vm;

import boomkat::hobject;
import boomkat::env;
import boomkat::types;
import boomkat::heap;
import boomkat::bytecode;

// Fetch the current slots because adding environment bindings can resize
// their storage. A writer passes `owner` to receive the object that
// holds the slot, for the write barrier.
fn hobject::PropValue* capture_value_slot(Activation* act, uint index, Heap* h, bool write = false,
                                          HObject** owner = null) @inline {
    if (!act.tv_func.is_object()) return null;
    HObject* fn_obj = (HObject*)act.tv_func.get_heapptr();
    HObjectFunction* fields = &(*fn_obj.extra_ptr()).func;
    if (fields.capture_refs == null || fields.comp_func == null
        || fields.comp_func != (CompiledFunction*)act.func
        || index >= fields.comp_func.capture_count) return null;
    CaptureRef* ref = &fields.capture_refs[index];
    if (ref.is_value) return write ? null : (hobject::PropValue*)&ref.value;
    if (ref.owner == null) return null;
    if (ref.is_cell) {
        if (ref.prop_idx >= ref.owner.prop_count) return null;
        if (owner != null) *owner = ref.owner;
        return &ref.owner.prop_values()[ref.prop_idx];
    }
    if (ref.guard_shadow) {
        TVal name = fields.comp_func.constants[fields.comp_func.capture_names[index]];
        void* key = name.get_heapptr();
        EnvRecord* cur = act.lex_env;
        while (cur != null) {
            if (cur.flags.is_with) return null;
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
                cells.prop_alloc = vm.heap.pool_alloc((usz)count * hobject::PropValue::size)!;
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
            vm.heap.decref_slot(slot);
            vm.heap.store_slot(cells, slot, *ra);
            ra.set_undefined();
            return (TVal){};
        }
        default: return (TVal){};
    }
}
