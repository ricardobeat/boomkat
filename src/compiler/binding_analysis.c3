module boomkat::compiler;

import boomkat::bytecode;
import boomkat::heap;
import boomkat::types;

// Translate a string constant from an inner template into the enclosing
// context's pool. Strings are interned, so pointer identity is the canonical
// cross-pool name identity.
fn void retain_parent_name(CompilerContext* ctx, CompiledFunction* inner,
                           uint inner_name_idx, bool* retain) {
    if (inner_name_idx >= inner.const_count) return;
    TVal inner_name = inner.constants[inner_name_idx];
    if (!inner_name.is_string()) return;
    void* key = inner_name.get_heapptr();
    for (uint i = 0; i < ctx.const_count; i++) {
        if (ctx.constants[i].is_string() && ctx.constants[i].get_heapptr() == key) {
            retain[i] = true;
        }
    }
}

// Collect compiled name consumers recursively. This evidence does not depend
// on the token pre-scan and includes capture-slot rewrites already applied to
// an inner template.
fn void retain_inner_consumers(CompilerContext* ctx, CompiledFunction* inner,
                               bool* retain, bool* retain_all) {
    if (inner == null || *retain_all) return;
    for (uint i = 0; i < inner.code_count; i++) {
        Instruction ins = inner.code[i];
        if (ins.op == Opcode.WIDE) {
            *retain_all = true;
            return;
        }
        if (ins.op == Opcode.GETCAP || ins.op == Opcode.PUTCAP || ins.op == Opcode.PUTCAP_SNAP) {
            uint capture_idx = ins.op == Opcode.PUTCAP_SNAP ? ins.c : ins.get_bc();
            if (capture_idx < inner.capture_count) {
                retain_parent_name(ctx, inner, inner.capture_names[capture_idx], retain);
            }
            continue;
        }

        uint name_idx;
        switch (bytecode::get_env_name_operand(ins.op)) {
            case EnvNameOperand.NONE:
                continue;
            case EnvNameOperand.INDIRECT:
                *retain_all = true;
                return;
            case EnvNameOperand.BC:
                name_idx = ins.get_bc();
            case EnvNameOperand.C:
                name_idx = ins.c;
        }
        retain_parent_name(ctx, inner, name_idx, retain);
    }
    for (uint i = 0; i < inner.inner_count; i++) {
        retain_inner_consumers(ctx, inner.inner_funcs[i], retain, retain_all);
        if (*retain_all) return;
    }
    if (inner.field_init_func != null) {
        retain_inner_consumers(ctx, inner.field_init_func, retain, retain_all);
    }
}

// Remove environment producers only when the binding ledger identifies their
// name and no captured declaration or name-based bytecode consumer can observe
// it. Constant-pool identity merges shadowed bindings with the same spelling;
// one captured declaration therefore retains every producer for that name.
fn void prune_unobserved_environment_stores(CompilerContext* ctx, Heap* heap,
                                             bool can_remove_empty_arrow_scopes) {
    bool ordinary_ok = !ctx.is_global && !ctx.is_arrow
        && !ctx.is_generator && !ctx.is_async
        && !ctx.has_direct_eval && !ctx.has_with_stmt && !ctx.outer_with
        && !ctx.uses_arguments && !ctx.has_rest
        && ctx.default_count == 0 && ctx.destruct_default_count == 0;
    if (ctx.disable_optimize || ctx.has_wide
        || (!ordinary_ok && !can_remove_empty_arrow_scopes)) return;

    usz map_bytes = (usz)ctx.const_count * 2;
    if (map_bytes == 0) map_bytes = 1;
    bool* maps = (bool*)heap.alloc_func(heap.heap_udata, map_bytes);
    if (maps == null) return;
    defer heap.free_func(heap.heap_udata, maps);
    mem::clear(maps, (sz)map_bytes);
    bool* known = maps;
    bool* retain = maps + ctx.const_count;

    foreach (binding : ctx.bindings) {
        if (binding.name_idx >= ctx.const_count) continue;
        known[binding.name_idx] = true;
        if (binding.is_captured) retain[binding.name_idx] = true;
    }

    bool allow_same_reg_pair = !ctx.has_captured_local && !ctx.has_closures;
    bool retain_all = ctx.capture_all;
    for (uint i = 0; i < ctx.code_count; i++) {
        // The matching rewrite below removes both consumers together, so they
        // do not make their name observable to the producer-retention pass.
        if (allow_same_reg_pair && ctx.code[i].op == Opcode.PUTVAR
            && i + 1 < ctx.code_count && ctx.code[i + 1].op == Opcode.GETVAR
            && ctx.code[i].get_a() == ctx.code[i + 1].get_a()
            && ctx.code[i].get_bc() == ctx.code[i + 1].get_bc()) {
            i++;
            continue;
        }
        uint name_idx;
        switch (bytecode::get_env_name_operand(ctx.code[i].op)) {
            case EnvNameOperand.NONE:
                continue;
            case EnvNameOperand.INDIRECT:
                retain_all = true;
                continue;
            case EnvNameOperand.BC:
                name_idx = ctx.code[i].get_bc();
            case EnvNameOperand.C:
                name_idx = ctx.code[i].c;
        }
        if (name_idx < ctx.const_count) retain[name_idx] = true;
    }
    for (uint i = 0; i < ctx.inner_func_count; i++) {
        retain_inner_consumers(ctx, ctx.inner_funcs[i], retain, &retain_all);
        if (retain_all) break;
    }

    for (uint i = 0; i < ctx.code_count; i++) {
        Opcode op = ctx.code[i].op;
        if (op == Opcode.DECLVAR || op == Opcode.DECLVAR_HOIST
            || op == Opcode.PUTLEX || op == Opcode.INITTZ || op == Opcode.PUTLEX_C) {
            uint name_idx = ctx.code[i].get_bc();
            if (!retain_all && name_idx < ctx.const_count
                && known[name_idx] && !retain[name_idx]) {
                ctx.code[i] = bytecode::make_abc(Opcode.NOP, 0, 0, 0);
            }
            continue;
        }

        // This pair is known to be function-local only under the original
        // capture-free, closure-free condition.
        if (allow_same_reg_pair && op == Opcode.PUTVAR && i + 1 < ctx.code_count
            && ctx.code[i + 1].op == Opcode.GETVAR
            && ctx.code[i].get_a() == ctx.code[i + 1].get_a()
            && ctx.code[i].get_bc() == ctx.code[i + 1].get_bc()) {
            ctx.code[i] = bytecode::make_abc(Opcode.NOP, 0, 0, 0);
            ctx.code[i + 1] = bytecode::make_abc(Opcode.NOP, 0, 0, 0);
            i++;
        }
    }

    // Scope depth is structural. One surviving lexical producer, depth-based
    // lookup, special lexical scope, or ordinary variable scope keeps every
    // push/pop so abrupt exits retain the same layout.
    bool needs_scope_layout = false;
    for (uint i = 0; i < ctx.code_count; i++) {
        switch (ctx.code[i].op) {
            case Opcode.INITTZ:
            case Opcode.PUTLEX:
            case Opcode.PUTLEX_C:
            case Opcode.GETBOUND:
                needs_scope_layout = true;
            case Opcode.PUSH_VAR:
            case Opcode.POP_VAR:
                if (!can_remove_empty_arrow_scopes) needs_scope_layout = true;
            case Opcode.PUSH_LEX:
                if (ctx.code[i].a != 0) needs_scope_layout = true;
            default:
        }
        if (needs_scope_layout) break;
    }
    if (needs_scope_layout) return;

    for (uint i = 0; i < ctx.code_count; i++) {
        if (ctx.code[i].op == Opcode.PUSH_LEX || ctx.code[i].op == Opcode.POP_LEX
            || ctx.code[i].op == Opcode.PUSH_VAR || ctx.code[i].op == Opcode.POP_VAR) {
            ctx.code[i] = bytecode::make_abc(Opcode.NOP, 0, 0, 0);
        }
    }
}

// Prove that the function has no own binding which still needs the function
// environment after producer pruning. The narrow eligibility guard preserves
// the existing decision for every dynamic or structurally complex function.
fn bool can_reuse_binding_environment(CompilerContext* ctx) {
    if (ctx.disable_optimize || ctx.has_wide || ctx.is_global || ctx.is_arrow
        || ctx.is_generator || ctx.is_async || ctx.is_named_func_expr
        || ctx.has_direct_eval || ctx.has_with_stmt || ctx.outer_with
        || ctx.capture_all
        || ctx.uses_arguments || ctx.has_rest || ctx.default_count != 0
        || ctx.destruct_default_count != 0 || ctx.has_destructured_param) {
        return false;
    }

    // Captured parameters and vars are initialized or read through the
    // function environment. Captured lexical entries remain conservative in
    // this first integration even when their block scope is independently
    // represented by PUSH_LEX.
    foreach (binding : ctx.bindings) {
        if (binding.is_captured) return false;
    }

    // Any surviving function-scope producer, including one whose name has no
    // ledger entry, proves that calls still need a private binding object.
    for (uint i = 0; i < ctx.code_count; i++) {
        switch (ctx.code[i].op) {
            case Opcode.DECLVAR:
            case Opcode.DECLVAR_HOIST:
            case Opcode.DECLGLOBALFUNC:
            case Opcode.DECLB33GLOBAL:
                return false;
            default:
        }
    }
    return true;
}
