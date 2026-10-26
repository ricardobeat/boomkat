module boomkat::compiler;
import boomkat::bytecode;
import boomkat::heap;
import boomkat::hstring;
import boomkat::types;
import boomkat::ast;

// Publish free-name candidates after register and bytecode transformations.
// A name declared anywhere in this function stays conservative until lexical
// reference identities are carried through those transformations.
fn void CompilerContext.collect_capture_candidates(&self, CompiledFunction* func) {
    if (self.disable_optimize || self.has_direct_eval
        || self.has_with_stmt || self.outer_with || self.is_global
        || self.is_generator || self.is_async || self.uses_arguments) return;
    Heap* h = (Heap*)self.heap;
    uint* names = (uint*)h.alloc_func(h.heap_udata, (usz)func.const_count * uint::size);
    if (names == null) return;
    uint count = 0;
    for (uint pc = 0; pc < func.code_count; pc++) {
        uint name;
        if (!capture_name_operand(func.code, pc, &name)) continue;
        if (name >= func.const_count || !func.constants[name].is_string()) continue;
        bool local = false;
        for (sz bi = 0; bi < self.bindings.len(); bi++) {
            if (self.bindings[bi].name_idx == name) { local = true; break; }
        }
        if (self.is_named_func_expr
            && ((HString*)func.constants[name].get_heapptr()).equals(self.named_func_expr_name)) {
            local = true;
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

// The name a GETVAR, PUTVAR_ASSIGN or PUTVAR_SNAP at `pc` reads or writes,
// with any WIDE prefix bits. A prefixed PUTVAR_SNAP keeps its name lookup.
fn bool capture_name_operand(Instruction* code, uint pc, uint* name) {
    Opcode op = code[pc].op;
    if (op == Opcode.GETVAR || op == Opcode.PUTVAR_ASSIGN) {
        *name = bytecode::code_bc(code, pc);
        return true;
    }
    if (op != Opcode.PUTVAR_SNAP || (pc > 0 && code[pc - 1].op == Opcode.WIDE)) return false;
    *name = code[pc].c;
    return true;
}

// Only declarations visible at the closure definition can resolve a candidate.
// A var or function declared later in this function is visible too, since
// hoisting binds it before any code runs. Comparing interned keys links the
// two constant pools without borrowing names.
fn void CompilerContext.resolve_capture_candidates(&self, CompiledFunction* child) {
    uint count = 0;
    for (uint ci = 0; ci < child.capture_count; ci++) {
        uint name = child.capture_names[ci];
        bool found = false;
        bool scoped = false;
        if (!self.is_global && !self.has_direct_eval && !self.has_with_stmt
            && !self.outer_with && !self.capture_all) {
            for (uint si = self.scope_depth; si > 0; si--) {
                ScopeEntry entry = self.scope_stack[si - 1];
                if (entry.binding_id == 0) continue;
                BindingInfo binding = self.bindings[(sz)(entry.binding_id - 1)];
                if (self.constants[binding.name_idx].get_heapptr()
                    != child.constants[name].get_heapptr()) continue;
                found = binding.is_captured;
                scoped = true;
                break;
            }
            if (!scoped) found = self.declares_hoisted_name(child.constants[name]);
        }
        if (!found) continue;
        for (uint pc = 0; pc < child.code_count; pc++) {
            Instruction* ins = &child.code[pc];
            uint operand_name;
            if (!capture_name_operand(child.code, pc, &operand_name) || operand_name != name) continue;
            // A prefix word carries BC's high bits; an unprefixed BC holds 16.
            bool prefixed = pc > 0 && child.code[pc - 1].op == Opcode.WIDE;
            if (ins.op == Opcode.GETVAR || ins.op == Opcode.PUTVAR_ASSIGN) {
                if (!prefixed && count > 0xFFFF) continue;
                ins.op = ins.op == Opcode.GETVAR ? Opcode.GETCAP : Opcode.PUTCAP;
                bytecode::set_code_bc(child.code, pc, count);
            } else if (count <= 255) {
                *ins = bytecode::make_abc(Opcode.PUTCAP_SNAP, ins.a, ins.b, (char)count);
            }
        }
        child.capture_names[count++] = name;
    }
    child.capture_count = count;
}

// True when this function's top-level scope binds the name as a var or a
// function declaration, whether or not the compiler has reached it yet.
fn bool CompilerContext.declares_hoisted_name(&self, TVal name) {
    ast::AstIndex* idx = ast::index_state;
    if (idx == null || !idx.use || idx.unknown_outer || self.func_ast_scope == 0) return false;
    uint atom = idx.tree.atoms.find(((HString*)name.get_heapptr()).get_data());
    if (atom == 0) return false;
    uint b = idx.res.lookup(self.func_ast_scope, atom);
    if (b == 0) return false;
    ast::DeclKind kind = idx.res.bindings.data[b].kind;
    return kind == ast::DeclKind.VAR || kind == ast::DeclKind.FUNC;
}

fn void restore_dynamic_capture_names(CompiledFunction* func) {
    bool keeps_cells = false;
    for (uint ci = 0; ci < func.capture_count; ci++) {
        if (func.capture_cells != null && func.capture_cells[ci] != 0) keeps_cells = true;
    }
    for (uint pc = 0; pc < func.code_count; pc++) {
        Instruction* ins = &func.code[pc];
        if (ins.op == Opcode.GETCAP || ins.op == Opcode.PUTCAP) {
            uint index = bytecode::code_bc(func.code, pc);
            if (func.capture_cells != null && func.capture_cells[index] != 0) continue;
            ins.op = ins.op == Opcode.GETCAP ? Opcode.GETVAR : Opcode.PUTVAR_ASSIGN;
            bytecode::set_code_bc(func.code, pc, func.capture_names[index]);
        } else if (ins.op == Opcode.PUTCAP_SNAP) {
            if (func.capture_cells != null && func.capture_cells[ins.c] != 0) continue;
            *ins = bytecode::make_abc(Opcode.PUTVAR_SNAP, ins.a, ins.b, (char)func.capture_names[ins.c]);
        }
    }
    if (!keeps_cells) func.capture_count = 0;
    for (uint ci = 0; ci < func.inner_count; ci++) restore_dynamic_capture_names(func.inner_funcs[ci]);
}
