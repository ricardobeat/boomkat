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
    HString*[256] keys;
    foreach (i, slot : slots) {
        if (slot.key == uint::max || !self.constants[slot.key].is_string()) return;
        HString* key = (HString*)self.constants[slot.key].get_heapptr();
        // Indexed names carry additional enumeration and prototype metadata.
        if (key.is_arridx()) return;
        keys[i] = key;
        for (sz j = 0; j < i; j++) {
            if (slots[j].key == slot.key) return;
        }
    }

    Heap* heap = (Heap*)self.heap;
    uint shape = heap.intern_literal_shape(keys[:slots.len]);
    if (shape == heap::SHAPE_NONE) return;

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
