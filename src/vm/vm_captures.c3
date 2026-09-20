module boomkat::vm;

import boomkat::hobject;
import boomkat::env;
import boomkat::types;
import boomkat::heap;
import boomkat::bytecode;

// Fetch the current backing array because adding bindings or growing a cell
// frame can resize storage.
fn TVal* capture_value_slot(Activation* act, uint index, Heap* h, bool write = false) @inline {
    if (!act.tv_func.is_object()) return null;
    HObject* fn_obj = (HObject*)act.tv_func.get_heapptr();
    HObjectFunction* fields = &(*fn_obj.extra_ptr()).func;
    if (fields.capture_refs == null || fields.comp_func == null
        || fields.comp_func != (CompiledFunction*)act.func
        || index >= fields.comp_func.capture_count) return null;
    CaptureRef ref = fields.capture_refs[index];
    if (ref.owner == null) return null;
    if (ref.is_cell) {
        if (ref.prop_idx >= ref.owner.array_size || ref.owner.array_part() == null) return null;
        return &ref.owner.array_part()[ref.prop_idx];
    }
    if (write && !ref.owner.get_prop_flags(ref.prop_idx, h).writable) return null;
    TVal* value = &ref.owner.prop_values()[ref.prop_idx];
    if (env::is_tdz_sentinel(value)) return null;
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
            // Cells need dense storage only. A plain object plus zero named
            // property capacity avoids ARRAY's full HObjectExtra payload.
            cells.prop_capacity = 0;
            if (count > 0) {
                cells.grow_array(count, vm.heap);
                if (cells.array_size < count || cells.array_part() == null) return (TVal){};
            }
            cells.array_used = count;
            ra.set_object(cells);
            track_heap_store(ds.act, ra, (uint)insn.a);
            return (TVal){};
        }
        case Opcode.GETCELL: {
            if (!rb.is_object()) return (TVal){};
            HObject* cells = (HObject*)rb.get_heapptr();
            uint slot_idx = (uint)insn.c;
            if (cells == null || cells.get_class() != hobject::ObjClass.OBJECT
                || cells.array_part() == null || slot_idx >= cells.array_size) return (TVal){};
            vm.heap.tval_copy_ref(ra, &cells.array_part()[slot_idx]);
            track_heap_store(ds.act, ra, (uint)insn.a);
            return (TVal){};
        }
        case Opcode.SETCELL: {
            if (!rb.is_object()) return (TVal){};
            HObject* cells = (HObject*)rb.get_heapptr();
            uint slot_idx = (uint)insn.c;
            if (cells == null || cells.get_class() != hobject::ObjClass.OBJECT
                || cells.array_part() == null || slot_idx >= cells.array_size) return (TVal){};
            vm.heap.tval_copy_ref(&cells.array_part()[slot_idx], ra);
            return (TVal){};
        }
        case Opcode.MOVECELL: {
            if (!rb.is_object()) return (TVal){};
            HObject* cells = (HObject*)rb.get_heapptr();
            uint slot_idx = (uint)insn.c;
            if (cells == null || cells.get_class() != hobject::ObjClass.OBJECT
                || cells.array_part() == null || slot_idx >= cells.array_size) return (TVal){};
            TVal* slot = &cells.array_part()[slot_idx];
            vm.heap.decref_tval(slot);
            *slot = *ra;
            ra.set_undefined();
            return (TVal){};
        }
        default: return (TVal){};
    }
}
