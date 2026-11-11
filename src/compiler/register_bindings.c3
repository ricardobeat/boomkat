module boomkat::compiler;

import boomkat::bytecode;
import boomkat::heap;
import boomkat::types;

fn void retain_child_producer_name(CompilerContext* ctx, CompiledFunction* inner,
                                   uint name_idx, bool* referenced) {
    if (name_idx >= inner.const_count || !inner.constants[name_idx].is_string()) return;
    mark_string_constant(ctx, inner.constants[name_idx].get_heapptr(), referenced);
}

// A same-spelled child declaration may shadow the parent. Retaining the parent
// anyway is conservative and avoids relying on the child's popped scope ledger.
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
        && !ctx.capture_all && !arguments_observes_bindings(ctx) && !ctx.has_rest
        && ctx.defaults.len() == 0 && ctx.destruct_defaults.len() == 0
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

// Marks a name or a register that more than one binding uses.
const uint SHARED_BINDING = uint::max;

// The pool slot that stands for the name at `name_idx`, the one its string was
// first given, or const_count when it is not a name.
fn uint name_slot(CompilerContext* ctx, uint name_idx) {
    if (name_idx >= ctx.const_count || !ctx.constants[name_idx].is_string()) return ctx.const_count;
    return ctx.find_string_constant(ctx.constants[name_idx].get_heapptr());
}

// Fill `by_name`, which has an entry per pool slot and one more, with one plus
// the index of the only binding of each name, or SHARED_BINDING.
fn void bindings_by_name(CompilerContext* ctx, uint[] by_name) {
    by_name[ctx.const_count] = SHARED_BINDING;
    for (sz bi = 0; bi < ctx.bindings.len(); bi++) {
        uint* owner = &by_name[name_slot(ctx, ctx.bindings[bi].name_idx)];
        *owner = *owner == 0 ? (uint)bi + 1 : SHARED_BINDING;
    }
}

// The selected binding named by `name_idx`, or -1. `by_name` holds, per name
// slot, one plus the index of the only binding with that name.
fn int selected_binding_for_name(CompilerContext* ctx, bool* selected, uint[] by_name, uint name_idx) {
    uint owner = by_name[name_slot(ctx, name_idx)];
    return owner != 0 && owner != SHARED_BINDING && selected[owner - 1] ? (int)(owner - 1) : -1;
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

    @pool() {
        // One plus the index of the only binding with a name or in a register.
        uint[] by_name = mem::temp_array(uint, (sz)ctx.const_count + 1);
        uint[] by_reg = mem::temp_array(uint, (sz)ctx.max_reg + 1);
        bindings_by_name(ctx, by_name);
        for (sz bi = 0; bi < ctx.bindings.len(); bi++) {
            uint* reg = &by_reg[ctx.bindings[bi].reg < ctx.max_reg ? ctx.bindings[bi].reg : ctx.max_reg];
            *reg = *reg == 0 ? (uint)bi + 1 : SHARED_BINDING;
        }

        for (sz bi = 0; bi < ctx.bindings.len(); bi++) {
            BindingInfo binding = ctx.bindings[bi];
            if (!binding.is_captured || binding.kind != ScopeKind.VAR
                || binding.is_catch_param || binding.name_idx >= ctx.const_count
                || referenced[binding.name_idx]) continue;
            selected[bi] = by_name[name_slot(ctx, binding.name_idx)] == (uint)bi + 1
                && binding.reg < ctx.max_reg && by_reg[binding.reg] == (uint)bi + 1;
        }

        // An indirect lookup cannot be tied to one ledger binding: the capture
        // descriptor pool is built later.
        for (uint pc = 0; pc < ctx.code_count; pc++) {
            Instruction ins = ctx.code[pc];
            if (ins.op == Opcode.GETBOUND) {
                mem::clear(selected, (sz)selected_bytes);
                break;
            }
            if (ins.op == Opcode.GETCAP || ins.op == Opcode.PUTCAP
                || ins.op == Opcode.PUTCAP_SNAP) {
                // Parent capture descriptors are known only after assembly, so
                // decline all candidates rather than infer identity from an index.
                mem::clear(selected, (sz)selected_bytes);
                break;
            }
            uint name_idx;
            if (!own_register_name_operand(ins, &name_idx)) continue;
            int bi = selected_binding_for_name(ctx, selected, by_name, name_idx);
            if (bi >= 0 && !register_name_use_supported(ins.op)) selected[bi] = false;
        }

        for (uint pc = 0; pc < ctx.code_count; pc++) {
            Instruction ins = ctx.code[pc];
            uint name_idx;
            if (!own_register_name_operand(ins, &name_idx)) continue;
            int bi = selected_binding_for_name(ctx, selected, by_name, name_idx);
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
    };

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
