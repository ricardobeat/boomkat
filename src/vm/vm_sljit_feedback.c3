module boomkat::vm;

import boomkat::bytecode;
import boomkat::heap;
import boomkat::hobject;
import std::io;

// Bound feedback sampling, per-function recompilation, and waiting for IC fill.
const uint READ_REFRESH_MIN_HITS = 64;
const uint READ_REFRESH_MAX_ATTEMPTS = 2;
const uint READ_REFRESH_MAX_CHECKS = 32;

struct FunctionReadFeedback @feat(SLJIT_READ_REFRESH) {
    uint pc;
    uint shape;
    uint generation;
    uint hits;
}

// Observe only successful ordinary reads that are eligible for shape-based
// compilation. A collision resets the small counter; no object pointer is
// retained and the interpreter owns any resulting IC update.
fn bool sljit_read_refresh(ColdCtx* cold, uint offset, HObject* receiver) @feat(SLJIT_READ_REFRESH) {
    CompiledFunction* cf = cold.vm.current_func;
    FunctionPlan* plan = cf.sljit_function;
    if (plan == null || plan.read_refresh_requested || cf.sljit_read_refreshes >= READ_REFRESH_MAX_ATTEMPTS
        || !hobject::plain_property_object(receiver)) return false;
    Shape* shape = receiver.get_shape(cold.heap);
    if (shape == null || shape.dict) return false;
    FunctionReadFeedback* feedback = &plan.read_feedback[offset & 3];
    if (feedback.hits == 0 || feedback.pc != offset || feedback.shape != receiver.shape_id
        || feedback.generation != shape.generation) {
        *feedback = { .pc = offset, .shape = receiver.shape_id, .generation = shape.generation, .hits = 1 };
        return false;
    }
    if (++feedback.hits < READ_REFRESH_MIN_HITS) return false;
    cf.sljit_read_refreshes++;
    plan.read_refresh_requested = true;
    plan.read_refresh_pc = offset;
    plan.read_refresh_shape = receiver.shape_id;
    plan.read_refresh_generation = shape.generation;
    cold.heap.jit_dependencies_dirty = true;
    $if $feat(SLJIT_STATS):
        io::eprintfn("SLJIT read refresh requested line=%d pc=%d shape=%d generation=%d attempt=%d",
            cf.get_line(offset), offset, receiver.shape_id, shape.generation, cf.sljit_read_refreshes);
    $endif
    return true;
}

// Wait until the interpreter has made the observed receiver shape available
// to the emitter. A recycled shape or an unsupported cache cannot justify
// recompilation merely because a helper saw an object with the same ID.
fn bool sljit_read_refresh_ready(Heap* h, CompiledFunction* cf, FunctionPlan* plan)
    @feat(SLJIT_READ_REFRESH) {
    uint pc = plan.read_refresh_pc;
    if (pc >= cf.code_count || cf.ic_entries == null || !function_read_op(cf.code[pc].op)) return false;
    Shape* shape = h.get_shape(plan.read_refresh_shape);
    if (shape == null || shape.dict || shape.generation != plan.read_refresh_generation) return false;
    ICEntry* ic = (ICEntry*)cf.ic_entries + pc;
    uint key_index = cf.code[pc].c;
    if (key_index >= cf.const_count || ic.key.borrow() != cf.constants[key_index].get_heapptr()
        || ic.prop_flags.is_accessor || ic.prop_idx >= hobject::IC_PROP_MISSING) return false;
    Shape* primary = h.get_shape(ic.shape_id);
    if (primary == null || primary.generation != ic.shape_gen) return false;
    if (ic.shape_id == plan.read_refresh_shape) return true;
    if (ic.chain == null) return false;
    if (ic.chain_len == hobject::IC_CHAIN_POLY && !ic.has_proto) {
        if (ic.chain.poly.count > hobject::IC_POLY_MAX) return false;
        for (uint i = 0; i < ic.chain.poly.count; i++) {
            if (ic.chain.poly.shapes[i] == plan.read_refresh_shape) return true;
        }
    } else if (ic.chain_len == hobject::IC_CHAIN_PROTO && hobject::ic_epoch_live(ic)) {
        if (ic.chain.proto.count > hobject::IC_PROTO_ARMS) return false;
        for (uint i = 0; i < ic.chain.proto.count; i++) {
            if (ic.chain.proto.arms[i].shape_id == plan.read_refresh_shape) return true;
        }
    }
    return false;
}

