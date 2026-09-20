module boomkat::compiler;

import boomkat::bytecode;
import boomkat::heap;
import boomkat::types;

fn void retain_child_producer_name(CompilerContext* ctx, CompiledFunction* inner,
                                   uint name_idx, bool* referenced) {
    if (name_idx >= inner.const_count || !inner.constants[name_idx].is_string()) return;
    void* key = inner.constants[name_idx].get_heapptr();
    for (uint i = 0; i < ctx.const_count; i++) {
        if (ctx.constants[i].is_string() && ctx.constants[i].get_heapptr() == key) {
            referenced[i] = true;
        }
    }
}

// A same-spelled declaration in a child may shadow the parent. Retaining the
// parent in that case is conservative and keeps this pass independent of the
// child's popped scope ledger.
fn void retain_child_name_producers(CompilerContext* ctx, CompiledFunction* inner,
                                    bool* referenced) {
    if (inner == null) return;
    for (uint pc = 0; pc < inner.code_count; pc++) {
        Instruction ins = inner.code[pc];
        switch (ins.op) {
            case Opcode.DECLVAR:
            case Opcode.DECLVAR_HOIST:
            case Opcode.DECLGLOBALFUNC:
            case Opcode.DECLB33GLOBAL:
            case Opcode.PUTLEX:
            case Opcode.PUTLEX_C:
            case Opcode.INITTZ:
                retain_child_producer_name(ctx, inner, ins.get_bc(), referenced);
            default:
        }
    }
    for (uint i = 0; i < inner.inner_count; i++) {
        retain_child_name_producers(ctx, inner.inner_funcs[i], referenced);
    }
    if (inner.field_init_func != null) {
        retain_child_name_producers(ctx, inner.field_init_func, referenced);
    }
}

fn bool register_promotion_eligible(CompilerContext* ctx) {
    return !ctx.disable_optimize && !ctx.has_wide && !ctx.is_global
        && !ctx.has_direct_eval && !ctx.has_with_stmt && !ctx.outer_with
        && !ctx.capture_all && !ctx.uses_arguments && !ctx.has_rest
        && ctx.default_count == 0 && ctx.destruct_default_count == 0
        && !ctx.has_destructured_param && !ctx.is_named_func_expr
        && !ctx.in_class_body && !ctx.is_arrow
        && !ctx.is_async && !ctx.is_generator;
}

fn bool own_register_name_operand(Instruction ins, uint* name_idx) {
    switch (ins.op) {
        case Opcode.DECLVAR:
        case Opcode.DECLVAR_HOIST:
        case Opcode.DECLGLOBALFUNC:
        case Opcode.DECLB33GLOBAL:
        case Opcode.PUTLEX:
        case Opcode.PUTLEX_C:
        case Opcode.INITTZ:
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

fn bool register_name_use_supported(Opcode op) {
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

fn int selected_binding_for_key(CompilerContext* ctx, bool* selected, void* key) {
    if (key == null) return -1;
    for (sz bi = 0; bi < ctx.bindings.len(); bi++) {
        BindingInfo binding = ctx.bindings[bi];
        if (!selected[bi] || binding.name_idx >= ctx.const_count) continue;
        if (ctx.constants[binding.name_idx].is_string()
            && ctx.constants[binding.name_idx].get_heapptr() == key) return (int)bi;
    }
    return -1;
}

fn int selected_binding_for_name(CompilerContext* ctx, bool* selected, uint name_idx) {
    if (name_idx >= ctx.const_count || !ctx.constants[name_idx].is_string()) return -1;
    return selected_binding_for_key(ctx, selected, ctx.constants[name_idx].get_heapptr());
}

// Restore register storage when the conservative token pre-scan marked a var
// captured but compiled descendants contain no reference to its name.
fn void promote_uncaptured_var_bindings(CompilerContext* ctx, Heap* h) {
    if (!register_promotion_eligible(ctx) || ctx.bindings.len() == 0) return;

    usz selected_bytes = (usz)ctx.bindings.len();
    usz referenced_bytes = ctx.const_count > 0 ? (usz)ctx.const_count : 1;
    bool* selected = (bool*)h.alloc_func(h.heap_udata, selected_bytes);
    bool* referenced = (bool*)h.alloc_func(h.heap_udata, referenced_bytes);
    if (selected == null || referenced == null) {
        if (selected != null) h.free_func(h.heap_udata, selected);
        if (referenced != null) h.free_func(h.heap_udata, referenced);
        return;
    }
    defer h.free_func(h.heap_udata, selected);
    defer h.free_func(h.heap_udata, referenced);
    mem::clear(selected, (sz)selected_bytes);
    mem::clear(referenced, (sz)referenced_bytes);

    bool retain_all = false;
    for (uint i = 0; i < ctx.inner_func_count; i++) {
        retain_inner_consumers(ctx, ctx.inner_funcs[i], referenced, &retain_all);
        retain_child_name_producers(ctx, ctx.inner_funcs[i], referenced);
    }
    if (retain_all) return;

    for (sz bi = 0; bi < ctx.bindings.len(); bi++) {
        BindingInfo binding = ctx.bindings[bi];
        if (!binding.is_captured || binding.kind != ScopeKind.VAR
            || binding.is_catch_param || binding.name_idx >= ctx.const_count
            || referenced[binding.name_idx]) continue;
        if (!ctx.constants[binding.name_idx].is_string()) continue;
        void* key = ctx.constants[binding.name_idx].get_heapptr();
        uint same_name = 0;
        uint same_reg = 0;
        foreach (other : ctx.bindings) {
            if (other.name_idx < ctx.const_count && ctx.constants[other.name_idx].is_string()
                && ctx.constants[other.name_idx].get_heapptr() == key) same_name++;
            if (other.reg == binding.reg) same_reg++;
        }
        if (same_name == 1 && same_reg == 1) selected[bi] = true;
    }

    // Own indirect lookup cannot be assigned to one ledger binding at this
    // point because the function's capture descriptor pool is assembled later.
    for (uint pc = 0; pc < ctx.code_count; pc++) {
        Instruction ins = ctx.code[pc];
        if (ins.op == Opcode.GETBOUND) {
            mem::clear(selected, (sz)selected_bytes);
            break;
        }
        if (ins.op == Opcode.GETCAP || ins.op == Opcode.PUTCAP
            || ins.op == Opcode.PUTCAP_SNAP) {
            // Parent capture descriptors belong to the function being
            // compiled only after its CompiledFunction is assembled. Decline
            // all candidates rather than infer identity from an index here.
            mem::clear(selected, (sz)selected_bytes);
            break;
        }
        uint name_idx;
        if (!own_register_name_operand(ins, &name_idx)) continue;
        int bi = selected_binding_for_name(ctx, selected, name_idx);
        if (bi >= 0 && !register_name_use_supported(ins.op)) selected[bi] = false;
    }

    for (uint pc = 0; pc < ctx.code_count; pc++) {
        Instruction ins = ctx.code[pc];
        uint name_idx;
        if (!own_register_name_operand(ins, &name_idx)) continue;
        int bi = selected_binding_for_name(ctx, selected, name_idx);
        if (bi < 0) continue;
        uint home = ctx.bindings[(sz)bi].reg;
        switch (ins.op) {
            case Opcode.GETVAR:
                ctx.code[pc] = ins.a == home
                    ? bytecode::make_abc(Opcode.NOP, 0, 0, 0)
                    : bytecode::make_abc(Opcode.LDREG, ins.a, home, 0);
            case Opcode.DECLVAR:
            case Opcode.DECLVAR_HOIST:
            case Opcode.PUTVAR:
            case Opcode.PUTVAR_ASSIGN:
            case Opcode.PUTVAR_SNAP:
                ctx.code[pc] = ins.a == home
                    ? bytecode::make_abc(Opcode.NOP, 0, 0, 0)
                    : bytecode::make_abc(Opcode.LDREG, home, ins.a, 0);
            case Opcode.RESOLVEVAR:
                ctx.code[pc] = bytecode::make_abc(Opcode.LDUNDEF, ins.a, 0, 0);
            case Opcode.THROW_UNRESOLVED:
                ctx.code[pc] = bytecode::make_abc(Opcode.NOP, 0, 0, 0);
            default:
        }
    }

    for (sz bi = 0; bi < ctx.bindings.len(); bi++) {
        if (selected[bi]) ctx.bindings[bi].is_captured = false;
    }
    ctx.has_captured_local = false;
    foreach (binding : ctx.bindings) {
        if (binding.is_captured) {
            ctx.has_captured_local = true;
            break;
        }
    }
}
