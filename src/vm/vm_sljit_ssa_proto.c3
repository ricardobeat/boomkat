module boomkat::vm;

import boomkat::heap;
import boomkat::hobject;
import boomkat::types;
import boomkat::jit;

// Pointer-free prototype dependencies. Guard every live link's layout instead
// of embedding weak objects or invalidating on unrelated prototype writes.
fn bool ssa_proto_layout_equal(LoopMemorySpec* a, LoopMemorySpec* b) @feat(SLJIT) {
    if (a.shape != b.shape || a.shape_gen != b.shape_gen || a.proto_depth != b.proto_depth) return false;
    for (uint i = 0; i < a.proto_depth; i++) {
        if (a.proto_shapes[i] != b.proto_shapes[i] || a.proto_generations[i] != b.proto_generations[i]) return false;
    }
    return true;
}

fn bool ssa_memory_layout_live(Heap* h, LoopMemorySpec* spec) @feat(SLJIT) {
    Shape* shape = h.get_shape(spec.shape);
    if (shape == null || shape.dict || shape.generation != spec.shape_gen) return false;
    for (uint i = 0; i < spec.proto_depth; i++) {
        shape = h.get_shape(spec.proto_shapes[i]);
        if (shape == null || shape.dict || shape.generation != spec.proto_generations[i]) return false;
    }
    return true;
}

fn int ssa_proto_memory(LoopPlan* plan, ICEntry* ic, void* key, Heap* h, HObject* receiver) @feat(SLJIT) {
    if (ic.key.borrow() != key || !ic.has_proto || ic.prop_flags.is_accessor || ic.chain == null
        || ic.prop_idx >= hobject::IC_PROP_MISSING) return -1;
    bool epoch = ic.chain_len == hobject::IC_CHAIN_EPOCH || ic.chain_len == hobject::IC_CHAIN_PROTO;
    if (epoch && !hobject::ic_epoch_live(ic)) return -1;
    if (!epoch && (ic.chain_len == 0 || ic.chain_len > hobject::IC_MAX_CHAIN)) return -1;
    HObject* owner = hobject::ic_cached_proto(ic);
    HObject* first = epoch ? ic.chain.epoch.first : ic.chain.snapshot.protos[0];
    Shape* shape = h.get_shape(ic.shape_id);
    if (owner == null || first == null || owner.is_proxy() || owner.get_class() != OBJECT
        || shape == null || shape.dict || shape.generation != ic.shape_gen) return -1;
    LoopMemorySpec spec = { .kind = PROTO_FIELD, .source = LOOP_THIS, .cls = OBJECT,
        .shape = ic.shape_id, .shape_gen = ic.shape_gen, .slot = (int)ic.prop_idx };
    if (epoch) {
        HObject* link;
        if (first == owner) { link = owner; }
        else {
            // Only the active receiver makes a weak first-link identity safe
            // to inspect at compile time. Dynamic receivers retain fallback.
            if (receiver == null || receiver.shape_id != ic.shape_id || receiver.prototype != first) return -1;
            link = receiver.prototype;
        }
        while (link != null && spec.proto_depth < hobject::IC_MAX_CHAIN) {
            Shape* layout = link.get_shape(h);
            if (layout == null || layout.dict || link.is_proxy() || link.get_class() != OBJECT) return -1;
            uint at = spec.proto_depth++;
            spec.proto_shapes[at] = link.shape_id;
            spec.proto_generations[at] = layout.generation;
            if (link == owner) break;
            link = link.prototype;
        }
        if (link != owner) return -1;
    } else {
        spec.proto_depth = ic.chain_len;
        for (uint i = 0; i < spec.proto_depth; i++) {
            uint id = ic.chain.snapshot.shapes[i];
            Shape* layout = h.get_shape(id);
            if (layout == null || layout.dict) return -1;
            spec.proto_shapes[i] = id;
            spec.proto_generations[i] = layout.generation;
        }
    }
    // The receiver and intermediate layouts must not shadow the property.
    PropFlags flags;
    if (function_shape_slot(shape, key, &flags) >= 0) return -1;
    for (uint i = 0; i < spec.proto_depth; i++) {
        int slot = function_shape_slot(h.get_shape(spec.proto_shapes[i]), key, &flags);
        if (i + 1 < spec.proto_depth) {
            if (slot >= 0) return -1;
        } else if (slot != spec.slot || flags.is_accessor) { return -1; }
    }
    for (uint i = 0; i < plan.memory_count; i++) {
        LoopMemorySpec* prior = &plan.memory[i];
        if (prior.kind == PROTO_FIELD && prior.slot == spec.slot && ssa_proto_layout_equal(prior, &spec)) return (int)i;
    }
    if (plan.memory_count == LOOP_MEMORY) return -1;
    uint id = plan.memory_count++;
    plan.memory[id] = spec;
    return (int)id;
}

fn void SsaEmitter.proto_storage(&self, int value) @feat(SLJIT) {
    SsaValue v = self.g.values[value];
    LoopMemorySpec spec = self.plan.memory[v.imm];
    int r0 = jit::reg_r(0);
    int r1 = jit::reg_r(1);
    int r2 = jit::reg_r(2);
    int r3 = jit::reg_r(3);
    int imm = jit::SLJIT_IMM;
    int mem = jit::SLJIT_MEM;
    HObject object;
    self.gpr(v.a, r0);
    self.e.op(jit::SLJIT_LSHR, r3, r0, 0, imm, 48);
    self.guard(jit::SLJIT_NOT_EQUAL, r3, 0, imm, (long)types::TAG_OBJECT, self.pc);
    self.e.op(jit::SLJIT_AND, r0, r0, 0, imm, (long)types::NANBOX_PAYLOAD_MASK);
    self.guard(jit::SLJIT_EQUAL, r0, 0, imm, 0, self.pc);
    self.ordinary_receiver(r0, self.pc);
    self.e.mov(r2, 0, mem | r0, (char*)&object.shape_id - (char*)&object, jit::SLJIT_MOV_U32);
    self.guard(jit::SLJIT_NOT_EQUAL, r2, 0, imm, spec.shape, self.pc);
    for (uint i = 0; i < spec.proto_depth; i++) {
        self.e.mov(r0, 0, mem | r0, (char*)&object.prototype - (char*)&object);
        self.guard(jit::SLJIT_EQUAL, r0, 0, imm, 0, self.pc);
        self.ordinary_receiver(r0, self.pc);
        self.e.mov(r2, 0, mem | r0, (char*)&object.shape_id - (char*)&object, jit::SLJIT_MOV_U32);
        self.guard(jit::SLJIT_NOT_EQUAL, r2, 0, imm, spec.proto_shapes[i], self.pc);
    }
    self.field_address(r0, r1);
    self.store_gpr(value, r1);
}
