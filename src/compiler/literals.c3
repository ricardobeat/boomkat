module boomkat::compiler;

import boomkat::features;
import boomkat::bytecode;
import boomkat::heap;
import boomkat::hstring;

struct LiteralSlot {
    uint key;
    uint key_pc;
    uint store_pc;
}

fn void CompilerContext.specialize_object_literal(&self, uint new_pc, LiteralSlot[] slots) {
    // Native shape IDs belong to one heap; portable images emit keyed stores.
    $if !features::PORTABLE_BYTECODE:
    if (self.has_wide || slots.len == 0 || slots.len > 256) return;
    foreach (i, slot : slots) {
        if (slot.key == uint::max || !self.constants[slot.key].is_string()) return;
        HString* key = (HString*)self.constants[slot.key].get_heapptr();
        // Indexed names carry additional enumeration and prototype metadata.
        if (key.is_arridx()) return;
        for (sz j = 0; j < i; j++) {
            if (slots[j].key == slot.key) return;
        }
    }

    Heap* heap = (Heap*)self.heap;
    uint shape = 0;
    foreach (slot : slots) {
        shape = heap.transition_shape_new(shape, self.constants[slot.key].get_heapptr());
        if (shape == heap::SHAPE_NONE) return;
        heap.get_shape(shape).shared = true;
    }
    if (shape > ushort::max) return;

    // The bytecode names this shape with no object to keep it alive, so the
    // shape sweep must treat it as a root.
    heap.get_shape(shape).pinned = true;
    self.code[new_pc] = bytecode::make_a_bc(Opcode.NEWOBJ_SHAPE, self.code[new_pc].a, shape);
    foreach (i, slot : slots) {
        Instruction store = self.code[slot.store_pc];
        self.code[slot.store_pc] = bytecode::make_abc(Opcode.INIT_SLOT, store.a, (uint)i, store.c);
        // A key load also releases the slot's previous string reference.
        // Keep that ownership effect when the key itself is unnecessary.
        self.code[slot.key_pc] = bytecode::make_abc(Opcode.LDUNDEF, self.code[slot.key_pc].a, 0, 0);
    }
    $endif
}
