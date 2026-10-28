module boomkat::vm;

import boomkat::bytecode;
import boomkat::heap;
import boomkat::hobject;
import boomkat::types;
import boomkat::jit;
import std::io;

// Pure callees and callees with one terminal numeric write can refuse before
// any observable effect. The original argument window remains authoritative
// for interpreter recovery. Both reuse the complete SSA pipeline.
fn LoopPlan* FunctionEmitter.ssa_leaf(&self, CompiledFunction* target, Heap* h, bool calls = false) @feat(SLJIT) {
    if (target == null || target.code_count < 3 || target.code_count > 32 || target.num_regs > LOOP_REGS
        || target.capture_count != 0 || (target.code[target.code_count - 1].op != Opcode.RET
            && target.code[target.code_count - 1].op != Opcode.RETUNDEF)
        || target.is_class_ctor() || target.flags.is_generator || target.flags.is_async
        || target.flags.has_direct_eval || target.mapped_arguments()) return null;
    for (uint pc = 0; pc < target.code_count - 1; pc++) {
        Opcode op = target.code[pc].op;
        if ((function_call_op(op) && !calls) || op == Opcode.GETVAR || op == Opcode.GETCAP
            || op == Opcode.PUTPROP) return null;
    }
    TVal[LOOP_REGS] values;
    LoopPlan draft;
    if (!loop_analyze(&draft, target.code_count - 1, &values[0], self.cold, 0, calls, target)) {
        $if $feat(SLJIT_STATS): io::eprintfn("SLJIT SSA leaf reject line=%d stage=analysis", target.get_line(0)); $endif
        return null;
    }
    foreach (&home : draft.cache) *home = 0;
    foreach (&home : draft.float_cache) *home = 0;
    draft.canonical = 0;
    for (uint i = 0; i < draft.binding_count; i++) {
        VarICEntry* ic = (VarICEntry*)target.var_ic_entries + draft.bindings[i];
        if (ic.slot_ptr == null || ic.recycle_epoch != h.shape_recycle_epoch || ic.prop_flags.is_accessor) continue;
        TVal value = ic.slot_ptr.get();
        if (!value.is_fastint() && !value.is_number()) continue;
        draft.ssa_binding_mask |= 1UL << i;
        draft.ssa_binding_constants[i] = value;
    }
    draft.ssa_function = target;
    draft.dependency_owner = self.plan;
    draft.ssa_shape_epoch = h.shape_recycle_epoch;
    LoopPlan* leaf = h.alloc_func(h.heap_udata, LoopPlan::size);
    if (leaf == null) return null;
    *leaf = draft;
    leaf.next = self.plan.ssa_leaves;
    self.plan.ssa_leaves = leaf;
    return leaf;
}

fn bool FunctionEmitter.inline_ssa_leaf(&self, CompiledFunction* cf, uint pc, Heap* h) @feat(SLJIT) {
    if (self.depth + 1 >= INLINE_DEPTH || self.cold == null || self.plan.numeric_homes != 0) return false;
    CompiledFunction* target = function_inline_target(cf, pc, h);
    Instruction call = cf.code[pc];
    bool fused = call.op == Opcode.CALL_VAR || call.op == Opcode.CALL_GLOBAL;
    uint nargs = fused ? call.b : call.c;
    uint base = fused ? call.a : call.b;
    if (target == null || target.num_args != nargs || ((fused || call.op == Opcode.CALL_UNDEF_THIS) && !target.call_flags.ignores_this)) return false;
    LoopPlan* leaf = self.ssa_leaf(target, h);
    if (leaf == null) return false;
    $if $feat(SLJIT_MAP):
        leaf.ssa_map_begin = self.out.e.label();
        leaf.ssa_map_depth = self.depth + 1;
    $endif
    self.flow_materialize();
    self.inline_guards(cf, pc, target, h, base);
    TemplateEmitter* e = &self.out.e;
    int imm = jit::SLJIT_IMM;
    int r0 = jit::reg_r(0);
    if (leaf.ssa_commit) {
        // Result ownership must not refuse after the callee's write commits.
        self.out.load(call.a, r0);
        e.op(jit::SLJIT_LSHR, jit::reg_r(3), r0, 0, imm, 48);
        self.out.guard(jit::SLJIT_EQUAL, jit::reg_r(3), 0, imm, (long)types::TAG_STRING, pc);
    }
    JitWriteDependency* checkpoint = self.plan.dependencies;
    if (ssa_emit(leaf, target, h, true, true, e, base, self.depth) == null) {
        sljit_dependencies_rollback(h, self.plan, checkpoint);
        $if $feat(SLJIT_STATS): io::eprintfn("SLJIT SSA leaf reject line=%d stage=graph", target.get_line(0)); $endif
        self.plan.ssa_leaves = leaf.next;
        h.free_func(h.heap_udata, leaf);
        return false;
    }
    $if $feat(SLJIT_STATS): ssa_counter(e, &leaf.hits); $endif
    self.out.guard(jit::SLJIT_EQUAL, r0, 0, imm, (long)SSA_REFUSED, pc);
    $if $feat(SLJIT_STATS): ssa_counter(e, &leaf.ssa_completed); $endif
    self.store(call.a, pc, true);
    $if $feat(SLJIT_MAP): leaf.ssa_map_end = e.label(); $endif
    $if $feat(SLJIT_STATS):
        io::eprintfn("SLJIT SSA leaf line=%d caller_depth=%d commit=%d", target.get_line(0), self.depth, leaf.ssa_commit);
    $endif
    return true;
}

// Global bindings are borrowed snapshots for a pure leaf. Validate the live
// slot before reading it; no allocation or JS can occur before return.
fn void SsaEmitter.binding_entry(&self, uint id) @feat(SLJIT) {
    uint pc = self.plan.bindings[id];
    CompiledFunction* cf = self.plan.binding_functions[id] != null ? self.plan.binding_functions[id] : self.cf;
    if (cf.code[pc].op != Opcode.GETGLOBAL || cf.var_ic_entries == null) {
        self.e.failed = true;
        return;
    }
    VarICEntry* ic = (VarICEntry*)cf.var_ic_entries + pc;
    VarICEntry layout;
    int r0 = jit::reg_r(0);
    int r1 = jit::reg_r(1);
    int r2 = jit::reg_r(2);
    int r3 = jit::reg_r(3);
    int mem = jit::SLJIT_MEM;
    int imm = jit::SLJIT_IMM;
    self.e.mov(r2, 0, imm, (long)ic);
    self.e.mov(r0, 0, mem | jit::reg_s(1), $reflect(ColdCtx.heap).offset);
    self.e.mov(r0, 0, mem | r0, $reflect(Heap.shape_recycle_epoch).offset, jit::SLJIT_MOV_U32);
    self.e.mov(r1, 0, mem | r2, (char*)&layout.recycle_epoch - (char*)&layout, jit::SLJIT_MOV_U32);
    self.snapshot_none(self.e.cmp(jit::SLJIT_NOT_EQUAL, r0, 0, r1, 0), self.plan.begin);
    self.e.mov(r0, 0, mem | r2, (char*)&layout.prop_flags - (char*)&layout, jit::SLJIT_MOV_U8);
    self.e.op(jit::SLJIT_AND, r0, r0, 0, imm, 8);
    self.snapshot_none(self.e.cmp(jit::SLJIT_NOT_EQUAL, r0, 0, imm, 0), self.plan.begin);
    self.e.mov(r2, 0, mem | r2, (char*)&layout.slot_ptr - (char*)&layout);
    self.snapshot_none(self.e.cmp(jit::SLJIT_EQUAL, r2, 0, imm, 0), self.plan.begin);
    self.e.mov(r0, 0, mem | r2, 0);
    if ((self.plan.ssa_binding_mask & (1UL << id)) != 0) {
        self.snapshot_none(self.e.cmp(jit::SLJIT_NOT_EQUAL, r0, 0, imm,
            (long)loop_bits(self.plan.ssa_binding_constants[id])), self.plan.begin);
        return;
    }
    self.e.op(jit::SLJIT_LSHR, r3, r0, 0, imm, 48);
    void* initialized = self.e.cmp(jit::SLJIT_NOT_EQUAL, r3, 0, imm, (long)types::TAG_UNDEFINED);
    self.snapshot_none(self.e.cmp(jit::SLJIT_NOT_EQUAL, r0, 0, imm, (long)(types::TAG_UNDEFINED << 48)), self.plan.begin);
    self.e.bind(initialized);
    if (self.g.inplace) {
        self.e.op(jit::SLJIT_LSHR, r3, r0, 0, imm, 48);
        self.snapshot_none(self.e.cmp(jit::SLJIT_EQUAL, r3, 0, imm, (long)types::TAG_STRING), self.plan.begin);
    }
    self.e.mov(mem | self.state, self.binding_offset(id), r0, 0);
}
