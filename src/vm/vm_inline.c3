module boomkat::vm;

import boomkat::bytecode;
import boomkat::heap;
import boomkat::hobject;
import boomkat::hstring;
import boomkat::types;
import boomkat::env;

fn bool vm_inline_guard(Vm* vm, Activation* act, TVal* regs_base, DecodedInsn ins) {
    if (bytecode::inline_profile) bytecode::inline_attempts++;
    TVal fnval = regs_base[ins.a];
    if (!fnval.is_object() || fnval.get_heapptr() == null) return false;
    HObject* obj = (HObject*)fnval.get_heapptr();
    if (!obj.is_callable()) return false;
    if (obj.callable_kind() != CallableKind.COMPILED_FN) return false;
    CompiledFunction* expected = ((CompiledFunction*)act.func).inner_funcs[ins.c];
    if (obj.extra_ptr().func.comp_func != expected || expected.realm != vm.heap.realm) return false;
    if (expected.is_arrow()) {
        if (env::is_tdz_sentinel(&obj.extra_ptr().func.captured_this)) return false;
    } else if (!expected.flags.is_strict && !expected.call_flags.ignores_this) {
        // Plain calls substitute the realm's global object without boxing.
        if (ins.b != 0 && !regs_base[ins.a + 1].is_object()) return false;
    }
    if (bytecode::inline_profile) bytecode::inline_hits++;
    return true;
}

// No getter, Proxy, exotic lookup or key coercion may run before fallback:
// such code can observe Function.caller and the callee's missing activation.
fn bool vm_inline_read_guard(Vm* vm, Activation* act, TVal* regs_base, DecodedInsn ins) {
    TVal objval = regs_base[ins.a];
    if (!objval.is_object() || objval.get_heapptr() == null) return false;
    HObject* obj = (HObject*)objval.get_heapptr();
    TVal key = ins.c != 0 ? ((CompiledFunction*)act.func).constants[ins.b] : regs_base[ins.b];
    if (obj.is_proxy()) return false;
    if (key.is_number() || key.is_fastint()) {
        double n = key.get_number_or_fastint();
        return obj.get_class() == ObjClass.ARRAY && n >= 0 && n < 4294967295.0
            && n == (double)(uint)n && obj.dense_idx_present((uint)n);
    }
    if (!key.is_string() || key.get_heapptr() == null) return false;
    void* name = key.get_heapptr();
    Heap* h = vm.heap;
    uint depth = 0;
    for (HObject* cur = obj; cur != null && depth++ < hobject::MAX_PROTO_DEPTH; cur = cur.prototype) {
        if (cur.flags.exotic_stringobj || cur.flags.exotic_arguments || cur.flags.exotic_module_ns
            || cur.flags.exotic_deferred_ns || cur.is_proxy() || (cur.get_class() != ObjClass.OBJECT && cur.get_class() != ObjClass.ARRAY)) return false;
        int idx = cur.find_prop_idx(name, h);
        if (idx >= 0) return !cur.get_prop_flags((uint)idx, h).is_accessor;
        if (cur.get_class() == ObjClass.ARRAY && name == (void*)h.strs[heap::BuiltinStr.LENGTH]) return true;
        TVal dense;
        if (cur.dense_arridx_lookup(name, &dense)) return true;
    }
    return depth < hobject::MAX_PROTO_DEPTH;
}

// The receiver an inlined body sees: the arrow's lexical this, the call's
// receiver, or what a call without one substitutes.
fn TVal vm_inline_this_value(Vm* vm, TVal* regs_base, DecodedInsn ins) {
    HObject* callee = (HObject*)regs_base[ins.b].get_heapptr();
    CompiledFunction* target = callee.extra_ptr().func.comp_func;
    TVal value;
    if (target.is_arrow()) {
        value = callee.extra_ptr().func.captured_this;
    } else if (ins.c != 0) {
        value = regs_base[ins.b + 1];
    } else if (!target.is_strict()) {
        value.set_object(vm.global_env.bindings);
    } else {
        value.set_undefined();
    }
    return value;
}

fn void vm_inline_this(Dispatch* ds, DecodedInsn ins) {
    TVal value = vm_inline_this_value(ds.vm, ds.regs_base, ins);
    ds.vm.heap.tval_copy_ref(&ds.regs_base[ins.a], &value);
    track_heap_store(ds.act, &ds.regs_base[ins.a], ins.a);
}

// Read a side-effect-free binding of the callee into `out`, or refuse.
//
// A name that resolves in the global environment arms `fill`, the entry of this
// instruction, so the threaded handler reads it by slot afterwards.
fn bool vm_inline_binding_read(Vm* vm, Activation* act, TVal* regs_base, DecodedInsn ins, bool capture, TVal* out,
                               hobject::VarICEntry* fill = null) {
    HObject* callee = (HObject*)regs_base[ins.b].get_heapptr();
    HObjectFunction* fields = &callee.extra_ptr().func;
    CompiledFunction* target = fields.comp_func;
    EnvRecord* var_env = fields.var_env;
    EnvRecord* lex_env = fields.lex_env;
    if (!target.is_arrow() && (lex_env == null || (!lex_env.is_with() && !lex_env.flags.is_declarative))) lex_env = var_env;
    if (capture) {
        // The capture reader also validates cells, shadowing and slot lifetime.
        Activation view;
        view.tv_func = regs_base[ins.b];
        view.func = target;
        view.lex_env = lex_env;
        hobject::PropValue* slot = capture_value_slot(&view, ins.c, vm.heap);
        if (slot != null) {
            *out = slot.get();
            return !env::is_tdz_sentinel(out);
        }
    }
    TVal key = capture ? target.constants[target.capture_names[ins.c]] : ((CompiledFunction*)act.func).constants[ins.c];
    if (!key.is_string()) return false;
    EnvRecord*[2] chains = { lex_env, var_env != lex_env ? var_env : null };
    foreach (head : chains) {
        for (EnvRecord* cur = head; cur != null; cur = cur.parent) {
            if (cur.is_with() || cur.bindings == null || cur.bindings.is_proxy()) return false;
            int idx = cur.bindings.find_prop_idx(key.get_heapptr(), vm.heap);
            if (idx < 0) continue;
            if (cur.bindings.get_prop_flags((uint)idx, vm.heap).is_accessor) return false;
            *out = cur.bindings.prop_values()[idx].get();
            if (env::is_tdz_sentinel(out)) return false;
            if (fill != null && !capture && (cur == vm.global_env || cur == vm.global_lex_env)) {
                hobject::var_ic_fill(fill, (void*)cur, (void*)cur.bindings, cur.bindings.shape_id, (uint)idx,
                    (void*)lex_env, false, vm.heap);
            }
            return true;
        }
    }
    return false;
}

fn bool vm_inline_binding(Dispatch* ds, DecodedInsn ins, bool capture) {
    TVal value;
    hobject::VarICEntry* fill = !capture && ds.var_ic_base != null
        ? ds.var_ic_base + (ds.curr_pc - 1 - ds.code_base) : null;
    if (!vm_inline_binding_read(ds.vm, ds.act, ds.regs_base, ins, capture, &value, fill)) return false;
    ds.vm.heap.tval_copy_ref(&ds.regs_base[ins.a], &value);
    track_heap_store(ds.act, &ds.regs_base[ins.a], ins.a);
    return true;
}
