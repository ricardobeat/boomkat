module boomkat::vm;

import boomkat::bytecode;
import boomkat::heap;
import boomkat::hobject;
import boomkat::types;
import std::io;

// GETGLOBAL sites share the same slot/layout validation for primitive and
// property folds. The watch roots the binding owner and tracks value writes.
fn VarICEntry* ssa_watchable_binding(SsaGraph* g, uint binding, CompiledFunction* consumer) @feat(SLJIT) {
    if (!g.inplace || g.plan.dependency_owner == null || binding >= g.plan.binding_count) return null;
    CompiledFunction* source = g.plan.binding_functions[binding] != null ? g.plan.binding_functions[binding] : g.cf;
    uint site = g.plan.bindings[binding];
    if (source.var_ic_entries == null || source.code[site].op != Opcode.GETGLOBAL || source.realm != consumer.realm) return null;
    VarICEntry* ic = (VarICEntry*)source.var_ic_entries + site;
    HObject* bindings = (HObject*)ic.bindings;
    if (!hobject::plain_property_object(bindings) || ic.slot_ptr == null || ic.prop_flags.is_accessor
        || ic.recycle_epoch != g.heap.shape_recycle_epoch || ic.prop_idx >= bindings.prop_count
        || bindings.shape_id != ic.shape_id || &bindings.prop_values()[ic.prop_idx] != ic.slot_ptr) return null;
    return ic;
}

fn int ssa_watch_numeric_binding(SsaGraph* g, uint binding) @feat(SLJIT) {
    VarICEntry* ic = ssa_watchable_binding(g, binding, g.cf);
    if (ic == null) return -1;
    TVal value = ic.slot_ptr.get();
    if (!value.is_fastint() && !value.is_number()) return -1;
    FunctionPlan* owner = g.plan.dependency_owner;
    JitWriteDependency* checkpoint = owner.dependencies;
    if (!sljit_watch_property(g.heap, owner, (HObject*)ic.bindings, ic.prop_idx)) {
        sljit_dependencies_rollback(g.heap, owner, checkpoint);
        return -1;
    }
    g.plan.ssa_watched_bindings |= 1UL << binding;
    g.plan.ssa_binding_constants[binding] = value;
    $if $feat(SLJIT_STATS): io::eprintfn("SLJIT SSA watched binding line=%d id=%d", g.cf.get_line(0), binding); $endif
    if (value.is_fastint() && value.get_fastint() >= -2147483648L && value.get_fastint() <= 2147483647L) {
        return ssa_value(g, CONST_I, INT32, -1, -1, value.get_fastint());
    }
    return ssa_value(g, CONST_F, F64, -1, -1, (long)bitcast(value.get_number_or_fastint(), ulong));
}

// Fold only an own numeric data property of a stable global object. Both
// the binding and its object slot have independent value and layout watches.
// The object is rooted by its layout watch while embedded in generated code.
fn int ssa_watch_global_field(SsaGraph* g, CompiledFunction* cf, uint pc, int base, ICEntry* field) @feat(SLJIT) {
    if (!g.inplace || !g.direct_fields || g.plan.dependency_owner == null) return -1;
    base = ssa_alias(g, base);
    if (base < 0 || g.values[base].op != BINDING) return -1;
    uint binding = (uint)g.values[base].imm;
    VarICEntry* ic = ssa_watchable_binding(g, binding, cf);
    if (ic == null) return -1;
    HObject* bindings = (HObject*)ic.bindings;
    TVal object_value = ic.slot_ptr.get();
    if (!object_value.is_object() || object_value.get_heapptr() == null) return -1;
    HObject* object = object_value.get_heapptr();
    if (!hobject::plain_property_object(object) || object.shape_id != field.shape_id
        || field.prop_idx >= object.prop_count || field.has_proto || field.prop_flags.is_accessor) return -1;
    Shape* shape = g.heap.get_shape(object.shape_id);
    PropFlags flags;
    if (shape == null || shape.dict || shape.generation != field.shape_gen
        || function_shape_slot(shape, field.key.borrow(), &flags) != (int)field.prop_idx || flags.is_accessor) return -1;
    TVal constant = object.prop_values()[field.prop_idx].get();
    if (!constant.is_fastint() && !constant.is_number()) return -1;
    FunctionPlan* owner = g.plan.dependency_owner;
    JitWriteDependency* checkpoint = owner.dependencies;
    if (!sljit_watch_property(g.heap, owner, bindings, ic.prop_idx)
        || !sljit_watch_property(g.heap, owner, object, field.prop_idx)) {
        sljit_dependencies_rollback(g.heap, owner, checkpoint);
        return -1;
    }
    g.plan.ssa_watched_bindings |= 1UL << binding;
    g.plan.ssa_binding_constants[binding] = object_value;
    $if $feat(SLJIT_STATS): io::eprintfn("SLJIT SSA watched constant line=%d pc=%d", cf.get_line(0), pc); $endif
    if (constant.is_fastint() && constant.get_fastint() >= -2147483648L
        && constant.get_fastint() <= 2147483647L) {
        return ssa_value(g, CONST_I, INT32, -1, -1, constant.get_fastint());
    }
    return ssa_value(g, CONST_F, F64, -1, -1, (long)bitcast(constant.get_number_or_fastint(), ulong));
}

// Replace only a call whose callee came from an inherited data property.
// The receiver's shape and first link are checked at runtime. Every concrete
// link and the method slot are watched; no function-object pointer is embedded.
fn bool ssa_watch_method(SsaGraph* g, int callee, CompiledFunction* target) @feat(SLJIT) {
    if (!g.inplace || !g.direct_fields || g.plan.dependency_owner == null || g.cf.ic_entries == null) return false;
    callee = ssa_alias(g, callee);
    if (callee < 0 || g.values[callee].op != LOAD) return false;
    SsaValue load = g.values[callee];
    int storage = ssa_alias(g, load.a);
    if (storage < 0 || g.values[storage].op != PROTO_STORAGE || load.pc >= g.cf.code_count) return false;
    SsaValue path = g.values[storage];
    uint memory = (uint)path.imm;
    if (memory >= g.plan.memory_count || (uint)load.imm != memory) return false;
    LoopMemorySpec spec = g.plan.memory[memory];
    if (spec.kind != PROTO_FIELD || spec.proto_depth == 0 || spec.proto_depth > hobject::IC_MAX_CHAIN) return false;
    ICEntry* ic = (ICEntry*)g.cf.ic_entries + load.pc;
    if (!ic.has_proto || ic.chain == null || ic.prop_flags.is_accessor || ic.shape_id != spec.shape
        || ic.prop_idx != (uint)spec.slot) return false;
    bool epoch = ic.chain_len == hobject::IC_CHAIN_EPOCH || ic.chain_len == hobject::IC_CHAIN_PROTO;
    if (epoch && !hobject::ic_epoch_live(ic)) return false;
    if (!epoch && ic.chain_len != spec.proto_depth) return false;
    HObject* first = epoch ? ic.chain.epoch.first : ic.chain.snapshot.protos[0];
    HObject* owner = hobject::ic_cached_proto(ic);
    if (first == null || owner == null || first != spec.proto_anchor) return false;
    HObject* link = first;
    for (uint i = 0; i < spec.proto_depth; i++) {
        if (!hobject::plain_property_object(link) || link.shape_id != spec.proto_shapes[i]) return false;
        Shape* shape = g.heap.get_shape(link.shape_id);
        if (shape == null || shape.dict || shape.generation != spec.proto_generations[i]) return false;
        if (!epoch && ic.chain.snapshot.protos[i] != (void*)link) return false;
        if (i + 1 == spec.proto_depth) {
            if (link != owner) return false;
        } else { link = link.prototype; }
    }
    if ((uint)spec.slot >= owner.prop_count) return false;
    PropFlags flags;
    if (function_shape_slot(g.heap.get_shape(owner.shape_id), ic.key.borrow(), &flags) != spec.slot || flags.is_accessor) return false;
    TVal value = owner.prop_values()[spec.slot].get();
    if (!value.is_object() || value.get_heapptr() == null) return false;
    HObject* function = value.get_heapptr();
    if (function.get_class() != FUNCTION || !function.flags.callable || function.flags.is_bound
        || function.flags.exotic_proxyobj || function.extra.func.comp_func != target
        || function.extra.func.realm != target.realm) return false;
    FunctionPlan* plan = g.plan.dependency_owner;
    JitWriteDependency* checkpoint = plan.dependencies;
    link = first;
    for (uint i = 0; i < spec.proto_depth; i++) {
        if (!sljit_watch_layout(g.heap, plan, link)) {
            sljit_dependencies_rollback(g.heap, plan, checkpoint);
            return false;
        }
        link = link.prototype;
    }
    if (!sljit_watch_property(g.heap, plan, owner, (uint)spec.slot)) {
        sljit_dependencies_rollback(g.heap, plan, checkpoint);
        return false;
    }
    g.plan.ssa_watched_methods = true;
    g.values[callee].watched_method = true;
    g.values[storage].watched_method = true;
    ssa_use(g, path.a);
    int guard = ssa_value(g, CHECKPROTO, BOXED, path.a, -1, (long)first);
    g.values[guard].target = (int)memory;
    $if $feat(SLJIT_STATS): io::eprintfn("SLJIT SSA watched method line=%d pc=%d", g.cf.get_line(0), load.pc); $endif
    return true;
}

