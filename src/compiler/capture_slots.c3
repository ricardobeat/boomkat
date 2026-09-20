module boomkat::compiler;
import boomkat::bytecode;
import boomkat::heap;

// Publish free-name candidates after register and bytecode transformations.
// A name declared anywhere in this function stays conservative until lexical
// reference identities are carried through those transformations.
fn void CompilerContext.collect_capture_candidates(&self, CompiledFunction* func) {
    if (self.disable_optimize || self.has_wide || self.has_direct_eval
        || self.has_with_stmt || self.outer_with || self.is_global
        || self.is_generator || self.is_async || self.uses_arguments) return;
    Heap* h = (Heap*)self.heap;
    uint* names = (uint*)h.alloc_func(h.heap_udata, (usz)func.const_count * uint::size);
    if (names == null) return;
    uint count = 0;
    for (uint pc = 0; pc < func.code_count; pc++) {
        Instruction ins = func.code[pc];
        if (ins.op != Opcode.GETVAR && ins.op != Opcode.PUTVAR_ASSIGN
            && ins.op != Opcode.PUTVAR_SNAP) continue;
        uint name = ins.op == Opcode.PUTVAR_SNAP ? ins.c : ins.get_bc();
        if (name >= func.const_count || !func.constants[name].is_string()) continue;
        bool local = false;
        for (sz bi = 0; bi < self.bindings.len(); bi++) {
            if (self.bindings[bi].name_idx == name) { local = true; break; }
        }
        if (local) continue;
        bool present = false;
        for (uint ci = 0; ci < count; ci++) {
            if (names[ci] == name) { present = true; break; }
        }
        if (!present) names[count++] = name;
    }
    func.capture_names = names;
    func.capture_count = count;
}

// Only declarations visible at the closure definition can resolve a candidate.
// Comparing interned keys links the two constant pools without borrowing names.
fn void CompilerContext.resolve_capture_candidates(&self, CompiledFunction* child) {
    uint count = 0;
    for (uint ci = 0; ci < child.capture_count; ci++) {
        uint name = child.capture_names[ci];
        bool found = false;
        if (!self.is_global && !self.has_direct_eval && !self.has_with_stmt
            && !self.outer_with && !self.capture_all) {
            for (uint si = self.scope_depth; si > 0; si--) {
                ScopeEntry entry = self.scope_stack[si - 1];
                if (entry.binding_id == 0) continue;
                BindingInfo binding = self.bindings[(sz)(entry.binding_id - 1)];
                if (self.constants[binding.name_idx].get_heapptr()
                    != child.constants[name].get_heapptr()) continue;
                found = binding.is_captured;
                break;
            }
        }
        if (!found) continue;
        for (uint pc = 0; pc < child.code_count; pc++) {
            Instruction* ins = &child.code[pc];
            uint operand_name = ins.op == Opcode.PUTVAR_SNAP ? ins.c : ins.get_bc();
            if (operand_name != name) continue;
            if (ins.op == Opcode.GETVAR) {
                *ins = bytecode::make_a_bc(Opcode.GETCAP, ins.get_a(), count);
            } else if (ins.op == Opcode.PUTVAR_ASSIGN) {
                *ins = bytecode::make_a_bc(Opcode.PUTCAP, ins.get_a(), count);
            } else if (ins.op == Opcode.PUTVAR_SNAP && count <= 255) {
                *ins = bytecode::make_abc(Opcode.PUTCAP_SNAP, ins.a, ins.b, (char)count);
            }
        }
        child.capture_names[count++] = name;
    }
    child.capture_count = count;
}

fn void restore_dynamic_capture_names(CompiledFunction* func) {
    bool keeps_cells = false;
    for (uint ci = 0; ci < func.capture_count; ci++) {
        if (func.capture_cells != null && func.capture_cells[ci] != 0) keeps_cells = true;
    }
    for (uint pc = 0; pc < func.code_count; pc++) {
        Instruction* ins = &func.code[pc];
        if (ins.op == Opcode.GETCAP || ins.op == Opcode.PUTCAP) {
            if (func.capture_cells != null && func.capture_cells[ins.get_bc()] != 0) continue;
            Opcode generic = ins.op == Opcode.GETCAP ? Opcode.GETVAR : Opcode.PUTVAR_ASSIGN;
            *ins = bytecode::make_a_bc(generic, ins.get_a(), func.capture_names[ins.get_bc()]);
        } else if (ins.op == Opcode.PUTCAP_SNAP) {
            if (func.capture_cells != null && func.capture_cells[ins.c] != 0) continue;
            *ins = bytecode::make_abc(Opcode.PUTVAR_SNAP, ins.a, ins.b, (char)func.capture_names[ins.c]);
        }
    }
    if (!keeps_cells) func.capture_count = 0;
    for (uint ci = 0; ci < func.inner_count; ci++) restore_dynamic_capture_names(func.inner_funcs[ci]);
}
