module boomkat::compiler;
import boomkat::types;
import boomkat::bytecode;
import boomkat::hobject;
import boomkat::hstring;
import boomkat::heap;

// The allow-list excludes control flow, calls, nested objects, methods, and
// object escape. Larger and dynamic literals keep INITPROP semantics.
fn void CompilerContext.specialize_literal_shape(&self, uint start, ushort obj_reg) {
    if (self.disable_optimize || self.has_wide || self.const_count >= 65535) return;
    HString*[256] known;
    HString*[16] keys;
    uint[16] sites;
    uint count = 0;
    for (uint pc = start + 1; pc < self.code_count; pc++) {
        Instruction ins = self.code[pc];
        switch (ins.op) {
            case Opcode.LDCONST:
                if (ins.a == obj_reg) return;
                TVal value = self.constants[ins.get_bc()];
                known[ins.a] = value.is_string() ? (HString*)value.get_heapptr() : null;
            case Opcode.LDREG:
                if (ins.b == obj_reg || ins.a == obj_reg) return;
                known[ins.a] = known[ins.b];
            case Opcode.LDINT:
            case Opcode.LDUNDEF:
            case Opcode.LDNULL:
            case Opcode.LDTRUE:
            case Opcode.LDFALSE:
            case Opcode.GETVAR:
            case Opcode.GETGLOBAL:
                if (ins.a == obj_reg) return;
                known[ins.a] = null;
            case Opcode.INITPROP:
                if (ins.a != obj_reg || ins.c == obj_reg || count == 16) return;
                HString* key = known[ins.b];
                if (key == null || key.is_arridx()) return;
                for (uint i = 0; i < count; i++) if (keys[i] == key) return;
                keys[count] = key;
                sites[count++] = pc;
            default: return;
        }
    }
    if (count == 0) return;
    Heap* h = (Heap*)self.heap;
    HObject*? raw = h.alloc_object(ObjClass.OBJECT);
    if (catch raw) return;
    HObject* shape_template = raw;
    TVal undef; undef.set_undefined();
    for (uint i = 0; i < count; i++) {
        if (!shape_template.put_prop_new(keys[i], undef, hobject::PROP_FLAGS_WEC, h)) return;
    }
    Shape* shared_shape = h.get_shape(shape_template.shape_id);
    if (shared_shape != null) shared_shape.shared = true;
    TVal template_value; template_value.set_object(shape_template);
    uint constant = self.add_constant(template_value);
    if (constant >= self.const_count || constant >= 65536) return;
    self.code[start] = bytecode::make_a_bc(Opcode.NEWOBJ_SHAPE, obj_reg, constant);
    for (uint i = 0; i < count; i++) {
        Instruction old = self.code[sites[i]];
        self.code[sites[i]] = bytecode::make_abc(Opcode.INIT_SLOT, obj_reg, i, old.c);
    }
}
