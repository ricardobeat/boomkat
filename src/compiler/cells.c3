module boomkat::compiler;

import boomkat::bytecode;
import boomkat::heap;
import boomkat::hobject;
import boomkat::types;

const uint MAX_LOWERED_CELLS = 255;

struct CellCandidate {
    void* key;
    bool selected;
}

fn void* function_name_key(CompiledFunction* func, uint name_idx) {
    if (name_idx >= func.const_count || !func.constants[name_idx].is_string()) return null;
    return func.constants[name_idx].get_heapptr();
}

fn void* context_name_key(CompilerContext* ctx, uint name_idx) {
    if (name_idx >= ctx.const_count || !ctx.constants[name_idx].is_string()) return null;
    return ctx.constants[name_idx].get_heapptr();
}

fn int find_cell_candidate(CellCandidate* candidates, uint count, void* key) {
    if (key == null) return -1;
    for (uint i = 0; i < count; i++) {
        if (candidates[i].key == key) return (int)i;
    }
    return -1;
}

fn bool instruction_name(Instruction ins, uint* name_idx) {
    switch (ins.op) {
        case Opcode.INITTZ:
        case Opcode.PUTLEX:
        case Opcode.PUTLEX_C:
        case Opcode.DECLVAR:
        case Opcode.DECLVAR_HOIST:
        case Opcode.DECLGLOBALFUNC:
        case Opcode.DECLB33GLOBAL:
        case Opcode.THROW_UNRESOLVED:
            *name_idx = ins.get_bc();
            return true;
        default:
    }
    switch (bytecode::get_env_name_operand(ins.op)) {
        case EnvNameOperand.BC:
            *name_idx = ins.get_bc();
            return true;
        case EnvNameOperand.C:
            *name_idx = ins.c;
            return true;
        default:
            return false;
    }
}

fn bool child_captures_key(CompiledFunction* child, void* key) {
    for (uint i = 0; i < child.capture_count; i++) {
        if (function_name_key(child, child.capture_names[i]) == key) return true;
    }
    return false;
}

fn void reject_all_cells(CellCandidate* candidates, uint count) {
    for (uint i = 0; i < count; i++) candidates[i].selected = false;
}

// A nested template may use a parent cell only through its resolved capture
// descriptors. Generic name lookup below the immediate child does not prove
// which environment owns the name.
fn void check_descendant_cell_uses(CompiledFunction* inner,
                                   CellCandidate* candidates, uint count,
                                   bool immediate) {
    if (inner == null) return;
    for (uint pc = 0; pc < inner.code_count; pc++) {
        Instruction ins = inner.code[pc];
        if (ins.op == Opcode.WIDE || ins.op == Opcode.GETBOUND) {
            reject_all_cells(candidates, count);
            continue;
        }
        if (ins.op == Opcode.GETCAP || ins.op == Opcode.PUTCAP
            || ins.op == Opcode.PUTCAP_SNAP) {
            uint capture_idx = ins.op == Opcode.PUTCAP_SNAP ? ins.c : ins.get_bc();
            if (capture_idx >= inner.capture_count) {
                reject_all_cells(candidates, count);
                continue;
            }
            void* key = function_name_key(inner, inner.capture_names[capture_idx]);
            // A matching resolved capture is the only nested access form that
            // can be redirected by capture_cells.
            if (find_cell_candidate(candidates, count, key) >= 0) continue;
            continue;
        }

        uint name_idx;
        if (!instruction_name(ins, &name_idx)) continue;
        void* key = function_name_key(inner, name_idx);
        int candidate_idx = find_cell_candidate(candidates, count, key);
        if (candidate_idx < 0) continue;
        bool resolvability_guard = ins.op == Opcode.RESOLVEVAR
            || ins.op == Opcode.THROW_UNRESOLVED;
        if (!(immediate && resolvability_guard && child_captures_key(inner, key))) {
            candidates[candidate_idx].selected = false;
        }
    }

    for (uint i = 0; i < inner.inner_count; i++) {
        check_descendant_cell_uses(inner.inner_funcs[i], candidates, count, false);
    }
    if (inner.field_init_func != null) {
        check_descendant_cell_uses(inner.field_init_func, candidates, count, false);
    }
}

fn bool own_cell_opcode_supported(Opcode op) {
    switch (op) {
        case Opcode.GETVAR:
        case Opcode.DECLVAR:
        case Opcode.DECLVAR_HOIST:
        case Opcode.PUTVAR:
        case Opcode.PUTVAR_ASSIGN:
        case Opcode.PUTVAR_SNAP:
        case Opcode.RESOLVEVAR:
        case Opcode.THROW_UNRESOLVED:
            return true;
        default:
            return false;
    }
}

fn void rewrite_immediate_guards(CompiledFunction* child,
                                 CellCandidate* candidates, uint count) {
    for (uint pc = 0; pc < child.code_count; pc++) {
        Instruction ins = child.code[pc];
        if (ins.op != Opcode.RESOLVEVAR && ins.op != Opcode.THROW_UNRESOLVED) continue;
        void* key = function_name_key(child, ins.get_bc());
        int ci = find_cell_candidate(candidates, count, key);
        if (ci < 0 || !candidates[ci].selected || !child_captures_key(child, key)) continue;
        child.code[pc] = ins.op == Opcode.RESOLVEVAR
            ? bytecode::make_abc(Opcode.LDUNDEF, ins.a, 0, 0)
            : bytecode::make_abc(Opcode.NOP, 0, 0, 0);
    }
}

fn bool cell_lowering_eligible(CompilerContext* ctx, CompiledFunction* func) {
    return !ctx.disable_optimize && !ctx.has_wide && !ctx.is_global
        && ctx.cell_frame_reserved && ctx.cell_frame_reg < 256
        && !ctx.is_arrow && !ctx.is_async && !ctx.is_generator
        && !ctx.has_direct_eval && !ctx.has_with_stmt && !ctx.outer_with
        && !ctx.capture_all && !ctx.uses_arguments && !ctx.has_rest
        && ctx.defaults.len() == 0 && ctx.destruct_defaults.len() == 0
        && !ctx.has_destructured_param && !ctx.is_named_func_expr
        && !ctx.in_class_body && !func.flags.is_class_ctor;
}

// Lexical captures need an initializer that cannot observe TDZ, and no other
// environment-producing binding. Dynamic scope and exception restoration
// retain their environment storage.
fn bool lexical_cell_layout(CompiledFunction* func, void* key, uint* init_pc) {
    uint found = 0;
    for (uint pc = 0; pc < func.code_count; pc++) {
        Instruction ins = func.code[pc];
        switch (ins.op) {
            case Opcode.TRY:
            case Opcode.PUSH_VAR:
            case Opcode.POP_VAR:
            case Opcode.GETBOUND:
            case Opcode.PUTLEX_C:
            case Opcode.DECLVAR:
            case Opcode.DECLVAR_HOIST:
                return false;
            case Opcode.PUSH_LEX:
                if (ins.a != 0) return false;
            case Opcode.CLOSURE:
                if (found == 0) return false;
            case Opcode.INITTZ:
                if (found != 0 || function_name_key(func, ins.get_bc()) != key
                    || pc + 2 >= func.code_count) return false;
                Instruction load = func.code[pc + 1];
                Instruction put = func.code[pc + 2];
                if (load.op != Opcode.LDINT || put.op != Opcode.PUTLEX
                    || put.a != load.a || put.get_bc() != ins.get_bc()) return false;
                *init_pc = pc;
                found++;
            case Opcode.PUTLEX:
                if (function_name_key(func, ins.get_bc()) != key) return false;
            default:
        }
    }
    return found == 1;
}

// An iteration's value is stable between its publication and the next
// renewal. Snapshot only direct read-only captures; forwarding and writes
// keep shared storage.
fn bool lexical_capture_is_value(CompiledFunction* func, void* key) {
    for (uint pc = 0; pc < func.code_count; pc++) {
        Instruction ins = func.code[pc];
        uint name;
        if (!instruction_name(ins, &name) || function_name_key(func, name) != key) continue;
        switch (ins.op) {
            case Opcode.PUTVAR:
            case Opcode.PUTVAR_ASSIGN:
            case Opcode.PUTVAR_SNAP:
                return false;
            case Opcode.INC_VAR:
            case Opcode.DEC_VAR:
                if (pc == 0 || func.code[pc - 1].op != Opcode.PUTLEX
                    || func.code[pc - 1].get_bc() != name) return false;
            default:
        }
    }
    for (uint i = 0; i < func.inner_count; i++) {
        CompiledFunction* child = func.inner_funcs[i];
        if (child.inner_count != 0 || child.field_init_func != null) return false;
        for (uint pc = 0; pc < child.code_count; pc++) {
            Instruction ins = child.code[pc];
            if (ins.op != Opcode.PUTCAP && ins.op != Opcode.PUTCAP_SNAP) continue;
            uint cap = ins.op == Opcode.PUTCAP ? ins.get_bc() : ins.c;
            if (cap >= child.capture_count || function_name_key(child, child.capture_names[cap]) == key) return false;
        }
    }
    return true;
}

// Cell lowering can grow an increment while removing scope instructions.
// Reject an expanded short branch rather than truncating its displacement.
fn bool relocate_cell_branch(Instruction* ins, uint pc, uint* map) {
    int offset;
    switch (ins.op) {
        case Opcode.JUMP:
        case Opcode.BREAK:
        case Opcode.CONTINUE:
            offset = (int)map[(uint)((int)pc + 1 + ins.get_sabc())] - (int)map[pc] - 1;
            if (offset < -0x800000 || offset > 0x7FFFFF) return false;
            *ins = bytecode::make_sabc(ins.op, offset);
        case Opcode.IF_TRUE:
        case Opcode.IF_FALSE:
            offset = (int)map[(uint)((int)pc + 1 + ins.get_sbc())] - (int)map[pc] - 1;
            if (offset < bytecode::MIN_SBC || offset > bytecode::MAX_SBC) return false;
            *ins = bytecode::make_a_sbx(ins.op, ins.a, offset);
        case Opcode.JMP_NLT..Opcode.JMP_SNEQI:
            offset = (int)map[(uint)((int)pc + 1 + (int)(ichar)ins.a)] - (int)map[pc] - 1;
            if (offset < -128 || offset > 127) return false;
            ins.a = (uint)(char)offset;
        default:
    }
    return true;
}

// Mutable captures share a cell vector; proven stable lexical captures
// copy the value at closure creation. Stage allocations and branch relocation
// before publishing metadata, so refusals leave ordinary lowering intact.
fn void lower_captured_bindings(CompilerContext* ctx, CompiledFunction* func, Heap* h) {
    if (!cell_lowering_eligible(ctx, func)) return;

    CellCandidate[MAX_LOWERED_CELLS] candidate_storage;
    CellCandidate* candidates = &candidate_storage[0];
    uint candidate_count = 0;
    bool lexical = false;
    bool has_var_capture = false;
    foreach (binding : ctx.bindings) {
        has_var_capture |= binding.is_captured && binding.kind == ScopeKind.VAR
            && !binding.is_catch_param;
    }
    foreach (binding : ctx.bindings) {
        if (!binding.is_captured || binding.is_catch_param
            || (binding.kind != ScopeKind.VAR && (has_var_capture || binding.kind != ScopeKind.LET))) continue;
        lexical |= binding.kind == ScopeKind.LET;
        void* key = context_name_key(ctx, binding.name_idx);
        if (key == null) return;

        uint same_name_count = 0;
        foreach (other : ctx.bindings) {
            if (context_name_key(ctx, other.name_idx) == key) same_name_count++;
        }
        if (same_name_count != 1) continue;
        if (candidate_count == MAX_LOWERED_CELLS) return;
        candidates[candidate_count++] = {
            .key = key,
            .selected = true,
        };
    }
    if (candidate_count == 0) return;
    uint lexical_init = 0;
    if (lexical && (candidate_count != 1
        || !lexical_cell_layout(func, candidates[0].key, &lexical_init))) return;
    bool snapshot = lexical && lexical_capture_is_value(func, candidates[0].key);
    if (lexical && !snapshot) {
        // Mutable bindings receive a cell at declaration execution. Iteration
        // renewal and fused environment increments retain their checked path.
        for (uint pc = 0; pc < func.code_count; pc++) {
            Opcode op = func.code[pc].op;
            if ((op == Opcode.PUTLEX && pc != lexical_init + 2)
                || op == Opcode.INC_VAR || op == Opcode.DEC_VAR) return;
        }
    }

    for (uint pc = 0; pc < func.code_count; pc++) {
        Instruction ins = func.code[pc];
        if (ins.op == Opcode.WIDE || ins.op == Opcode.GETBOUND) {
            reject_all_cells(candidates, candidate_count);
            continue;
        }
        if (ins.op == Opcode.GETCAP || ins.op == Opcode.PUTCAP
            || ins.op == Opcode.PUTCAP_SNAP) {
            uint capture_idx = ins.op == Opcode.PUTCAP_SNAP ? ins.c : ins.get_bc();
            if (capture_idx >= func.capture_count) {
                reject_all_cells(candidates, candidate_count);
                continue;
            }
            int ci = find_cell_candidate(candidates, candidate_count,
                function_name_key(func, func.capture_names[capture_idx]));
            if (ci >= 0) candidates[ci].selected = false;
            continue;
        }
        uint name_idx;
        if (!instruction_name(ins, &name_idx)) continue;
        int ci = find_cell_candidate(candidates, candidate_count,
                                     function_name_key(func, name_idx));
        if (ci >= 0 && !own_cell_opcode_supported(ins.op)
            && !(lexical && (ins.op == Opcode.INITTZ || ins.op == Opcode.PUTLEX
                || ins.op == Opcode.INC_VAR || ins.op == Opcode.DEC_VAR))) {
            candidates[ci].selected = false;
        }
    }
    for (uint i = 0; i < func.inner_count; i++) {
        check_descendant_cell_uses(func.inner_funcs[i], candidates, candidate_count, true);
    }
    if (func.field_init_func != null) {
        check_descendant_cell_uses(func.field_init_func, candidates, candidate_count, true);
    }

    char[MAX_LOWERED_CELLS] slots;
    uint cell_count = 0;
    for (uint i = 0; i < candidate_count; i++) {
        if (candidates[i].selected) slots[i] = (char)cell_count++;
    }
    if (cell_count == 0) return;

    uint* pc_map = null;
    defer if (pc_map != null) h.free_func(h.heap_udata, pc_map);
    uint new_code_count = func.code_count + 1;
    if (lexical) {
        pc_map = (uint*)h.alloc_func(h.heap_udata, (usz)(func.code_count + 1) * uint::size);
        if (pc_map == null) return;
        new_code_count = 0;
        for (uint pc = 0; pc < func.code_count; pc++) {
            pc_map[pc] = new_code_count;
            Instruction ins = func.code[pc];
            if (ins.op == Opcode.PUSH_LEX || ins.op == Opcode.POP_LEX
                || (ins.op == Opcode.INITTZ && snapshot)
                || (ins.op == Opcode.PUTLEX && pc != lexical_init + 2)) continue;
            uint width = 1;
            if ((ins.op == Opcode.INC_VAR || ins.op == Opcode.DEC_VAR)
                && function_name_key(func, ins.get_bc()) == candidates[0].key) width = 2;
            new_code_count += width;
        }
        pc_map[func.code_count] = new_code_count;
    }
    Instruction* new_code = (Instruction*)h.alloc_func(
        h.heap_udata, (usz)new_code_count * Instruction::size);
    if (new_code == null) return;
    uint* new_lines = null;
    ushort** child_maps = null;
    defer {
        if (new_code != null) h.free_func(h.heap_udata, new_code);
        if (new_lines != null) h.free_func(h.heap_udata, new_lines);
        if (child_maps != null) {
            for (uint i = 0; i < func.inner_count; i++) {
                if (child_maps[i] != null) h.free_func(h.heap_udata, child_maps[i]);
            }
            h.free_func(h.heap_udata, child_maps);
        }
    }

    if (func.line_table != null) {
        new_lines = (uint*)h.alloc_func(h.heap_udata, (usz)new_code_count * uint::size);
        if (new_lines == null) return;
    }

    if (func.inner_count > 0) {
        child_maps = (ushort**)h.alloc_func(
            h.heap_udata, (usz)func.inner_count * ushort*::size);
        if (child_maps == null) return;
        mem::clear(child_maps, (sz)((usz)func.inner_count * ushort*::size));
    }
    for (uint i = 0; i < func.inner_count; i++) {
        CompiledFunction* child = func.inner_funcs[i];
        if (child.capture_count == 0) continue;
        if (child.capture_cells != null) return;
        child_maps[i] = (ushort*)h.alloc_func(
            h.heap_udata, (usz)child.capture_count * ushort::size);
        if (child_maps[i] == null) return;
        mem::clear(child_maps[i], (sz)((usz)child.capture_count * ushort::size));
        for (uint cap = 0; cap < child.capture_count; cap++) {
            int ci = find_cell_candidate(candidates, candidate_count,
                function_name_key(child, child.capture_names[cap]));
            if (ci >= 0 && candidates[ci].selected) {
                child_maps[i][cap] = snapshot ? bytecode::CAPTURE_VALUE_FLAG : (ushort)slots[ci] + 1;
            }
        }
    }

    uint frame_reg = ctx.cell_frame_reg;
    if (!lexical) {
        new_code[0] = bytecode::make_a_bc(Opcode.NEWCELLS, frame_reg, cell_count);
        if (new_lines != null) new_lines[0] = func.code_count > 0 ? func.line_table[0] : 0;
    }
    for (uint pc = 0; pc < func.code_count; pc++) {
        Instruction ins = func.code[pc];
        uint name_idx;
        int ci = -1;
        if (instruction_name(ins, &name_idx)) {
            ci = find_cell_candidate(candidates, candidate_count,
                                     function_name_key(func, name_idx));
        }
        uint out_pc = lexical ? pc_map[pc] : pc + 1;
        if (lexical) {
            if (pc_map[pc] == pc_map[pc + 1]) continue;
            if (!relocate_cell_branch(&ins, pc, pc_map)) return;
            if (new_lines != null) {
                for (uint dst = out_pc; dst < pc_map[pc + 1]; dst++) new_lines[dst] = func.line_table[pc];
            }
        }
        if (ci >= 0 && candidates[ci].selected) {
            switch (ins.op) {
                case Opcode.INITTZ:
                    ins = bytecode::make_a_bc(Opcode.NEWCELLS, frame_reg, cell_count);
                case Opcode.PUTLEX:
                    ins = snapshot ? bytecode::make_abc(Opcode.LDREG, frame_reg, ins.a, 0)
                        : bytecode::make_abc(Opcode.SETCELL, ins.a, frame_reg, slots[ci]);
                case Opcode.INC_VAR:
                case Opcode.DEC_VAR:
                    new_code[out_pc++] = bytecode::make_abc(ins.op == Opcode.INC_VAR ? Opcode.INC : Opcode.DEC, frame_reg, 0, 0);
                    ins = bytecode::make_abc(Opcode.LDREG, ins.a, frame_reg, 0);
                case Opcode.GETVAR:
                    ins = bytecode::make_abc(snapshot ? Opcode.LDREG : Opcode.GETCELL, ins.a, frame_reg, slots[ci]);
                case Opcode.DECLVAR:
                case Opcode.DECLVAR_HOIST:
                    ins = bytecode::make_abc(Opcode.SETCELL, ins.a, frame_reg, slots[ci]);
                case Opcode.PUTVAR:
                case Opcode.PUTVAR_ASSIGN:
                case Opcode.PUTVAR_SNAP:
                    ins = bytecode::make_abc(Opcode.MOVECELL, ins.a, frame_reg, slots[ci]);
                case Opcode.RESOLVEVAR:
                    ins = bytecode::make_abc(Opcode.LDUNDEF, ins.a, 0, 0);
                case Opcode.THROW_UNRESOLVED:
                    ins = bytecode::make_abc(Opcode.NOP, 0, 0, 0);
                default:
            }
        }
        new_code[out_pc] = ins;
        if (!lexical && new_lines != null) new_lines[out_pc] = func.line_table[pc];
    }

    for (uint i = 0; i < func.inner_count; i++) {
        CompiledFunction* child = func.inner_funcs[i];
        if (child_maps[i] == null) continue;
        child.capture_cells = child_maps[i];
        child.capture_parent_reg = (ushort)frame_reg;
        child_maps[i] = null;
        rewrite_immediate_guards(child, candidates, candidate_count);
    }

    bool all_captured_selected = true;
    foreach (binding : ctx.bindings) {
        if (!binding.is_captured) continue;
        int ci = find_cell_candidate(candidates, candidate_count,
                                     context_name_key(ctx, binding.name_idx));
        if (ci < 0 || !candidates[ci].selected) all_captured_selected = false;
    }
    bool surviving_env_producer = false;
    for (uint pc = 1; pc < new_code_count; pc++) {
        if (new_code[pc].op == Opcode.DECLVAR
            || new_code[pc].op == Opcode.DECLVAR_HOIST
            || new_code[pc].op == Opcode.DECLGLOBALFUNC
            || new_code[pc].op == Opcode.DECLB33GLOBAL) {
            surviving_env_producer = true;
        }
    }

    if (func.code != null) h.free_func(h.heap_udata, func.code);
    if (func.line_table != null) h.free_func(h.heap_udata, func.line_table);
    func.code = new_code;
    func.code_count = new_code_count;
    func.line_table = new_lines;
    if (all_captured_selected && !surviving_env_producer) func.flags.needs_env = false;
    new_code = null;
    new_lines = null;
}
