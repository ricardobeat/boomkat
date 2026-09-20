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
        && ctx.default_count == 0 && ctx.destruct_default_count == 0
        && !ctx.has_destructured_param && !ctx.is_named_func_expr
        && !ctx.in_class_body && !func.flags.is_class_ctor;
}

// Lower unique captured var bindings into a frame-owned cell vector. Every
// allocation is staged so an allocation failure leaves code and metadata
// untouched.
fn void lower_captured_var_cells(CompilerContext* ctx, CompiledFunction* func, Heap* h) {
    if (!cell_lowering_eligible(ctx, func)) return;

    CellCandidate[MAX_LOWERED_CELLS] candidate_storage;
    CellCandidate* candidates = &candidate_storage[0];
    uint candidate_count = 0;
    foreach (binding : ctx.bindings) {
        if (!binding.is_captured || binding.kind != ScopeKind.VAR
            || binding.is_catch_param) continue;
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
        if (ci >= 0 && !own_cell_opcode_supported(ins.op)) {
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

    uint new_code_count = func.code_count + 1;
    Instruction* new_code = (Instruction*)h.alloc_func(
        h.heap_udata, (usz)new_code_count * Instruction::size);
    if (new_code == null) return;
    uint* new_lines = null;
    void* new_ic = null;
    void* new_var_ic = null;
    ushort** child_maps = null;
    defer {
        if (new_code != null) h.free_func(h.heap_udata, new_code);
        if (new_lines != null) h.free_func(h.heap_udata, new_lines);
        if (new_ic != null) h.free_func(h.heap_udata, new_ic);
        if (new_var_ic != null) h.free_func(h.heap_udata, new_var_ic);
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
    new_ic = h.alloc_func(h.heap_udata, (usz)new_code_count * ICEntry::size);
    new_var_ic = h.alloc_func(h.heap_udata, (usz)new_code_count * VarICEntry::size);
    if (new_ic == null || new_var_ic == null) return;
    mem::clear(new_ic, (sz)((usz)new_code_count * ICEntry::size));
    mem::clear(new_var_ic, (sz)((usz)new_code_count * VarICEntry::size));

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
            if (ci >= 0 && candidates[ci].selected) child_maps[i][cap] = (ushort)slots[ci] + 1;
        }
    }

    uint frame_reg = ctx.cell_frame_reg;
    new_code[0] = bytecode::make_a_bc(Opcode.NEWCELLS, frame_reg, cell_count);
    if (new_lines != null) new_lines[0] = func.code_count > 0 ? func.line_table[0] : 0;
    for (uint pc = 0; pc < func.code_count; pc++) {
        Instruction ins = func.code[pc];
        uint name_idx;
        int ci = -1;
        if (instruction_name(ins, &name_idx)) {
            ci = find_cell_candidate(candidates, candidate_count,
                                     function_name_key(func, name_idx));
        }
        if (ci >= 0 && candidates[ci].selected) {
            switch (ins.op) {
                case Opcode.GETVAR:
                    ins = bytecode::make_abc(Opcode.GETCELL, ins.a, frame_reg, slots[ci]);
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
        new_code[pc + 1] = ins;
        if (new_lines != null) new_lines[pc + 1] = func.line_table[pc];
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
    if (func.ic_entries != null) h.free_func(h.heap_udata, func.ic_entries);
    if (func.var_ic_entries != null) h.free_func(h.heap_udata, func.var_ic_entries);
    func.code = new_code;
    func.code_count = new_code_count;
    func.line_table = new_lines;
    func.ic_entries = new_ic;
    func.ic_count = new_code_count;
    func.var_ic_entries = new_var_ic;
    func.var_ic_count = new_code_count;
    if (all_captured_selected && !surviving_env_producer) func.flags.needs_env = false;
    new_code = null;
    new_lines = null;
    new_ic = null;
    new_var_ic = null;
}
