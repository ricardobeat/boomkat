module boomkat::vm;

import boomkat::bytecode;
import boomkat::hobject;
import boomkat::heap;
import boomkat::jit;
import boomkat::types;

struct SsaBindingSite @feat(SLJIT) {
    CompiledFunction* function;
    Opcode opcode;
    uint index;
    uint payload_pc;
}

fn bool ssa_binding_native_site(SsaGraph* g, DecodedBytecode view) @feat(SLJIT) {
    Opcode op = view.insn.op;
    if (op != Opcode.GETCAP && op != Opcode.GETVAR && op != Opcode.GETGLOBAL) return false;
    // The legacy memory adapter still prepares binding-based array descriptors.
    // Refreshing such a binding must also refresh those descriptors. Scalable
    // ACCESS operations consume the actual SSA receiver and need no snapshot.
    uint binding = ssa_binding_site(g.plan, view.pc - g.plan.begin);
    if (binding != 0) for (uint m = 0; m < g.plan.memory_count; m++) {
        if (g.plan.memory[m].source == LOOP_REGS + binding - 1) return false;
    }
    return true;
}

// Feedback selects a representation, never a value or a lifetime assumption.
// Only inspect the current closure's direct capture slot: gathering feedback
// must not resolve a name, run a getter, or borrow another closure's IC.
fn bool ssa_binding_integer_feedback(SsaGraph* g, DecodedBytecode view) @feat(SLJIT) {
    if (view.insn.op != Opcode.GETCAP || !ssa_binding_native_site(g, view)
        || g.heap.curr_thread == null) return false;
    Vm* vm = (Vm*)g.heap.curr_thread;
    if (vm.heap != g.heap || vm.current_func != g.cf || vm.activation_count == 0) return false;
    Activation* act = &vm.activations[vm.activation_count - 1];
    if (act.func != g.cf || !act.tv_func.is_object()) return false;
    HObject* closure = act.tv_func.get_heapptr();
    if (closure == null || closure.get_class() != FUNCTION) return false;
    CaptureRef* ref = capture_ref(act, view.insn.get_bc());
    if (ref == null || ref.guard_shadow) return false;
    TVal sample;
    if (ref.is_value) { sample = ref.value; }
    else {
        HObject* owner = ref.owner;
        if (owner == null || owner.get_class() != OBJECT || owner.is_proxy()
            || owner.flags.exotic_module_ns || ref.prop_idx >= owner.prop_count) return false;
        sample = owner.prop_values()[ref.prop_idx].get();
    }
    if (sample.is_fastint()) return sample.get_fastint() >= -2147483648L
        && sample.get_fastint() <= 2147483647L;
    if (!sample.is_number()) return false;
    double number = sample.get_number();
    return number >= -2147483648.0 && number <= 2147483647.0
        && bitcast(number, ulong) != 0x8000000000000000UL && number == (double)(long)number;
}

fn bool ssa_binding_build(SsaGraph* g, DecodedBytecode view) @feat(SLJIT) {
    if (!ssa_binding_native_site(g, view)) return false;
    SsaBindingSite* site = ssa_storage_alloc(g, 1, SsaBindingSite::size);
    if (site == null) return false;
    *site = { g.cf, view.insn.op, view.insn.get_bc(), view.payload_pc };
    SsaRep rep = ssa_binding_integer_feedback(g, view) ? INT32 : BOXED;
    int value = ssa_value(g, FRESH_BINDING, rep, -1, -1, 0);
    g.values[value].binding_site = site;
    g.values[value].before_frame = ssa_frame_at_pc(g, view.pc);
    ssa_result(g, value, view.insn.a, view.pc);
    g.current[view.insn.a] = value;
    return true;
}

// Read current storage on every execution. These guards cannot allocate, call
// user code, or collect. A miss resumes the unperformed bytecode with its exact
// before-frame; generic resolution retains getters/with/TDZ semantics.
fn void SsaEmitter.fresh_binding(&self, int id) @feat(SLJIT) {
    SsaBindingSite* site = self.g.values[id].binding_site;
    if (site == null) { self.e.failed = true; return; }
    int r0 = jit::reg_r(0);
    int r1 = jit::reg_r(1);
    int r2 = jit::reg_r(2);
    int r3 = jit::reg_r(3);
    int mem = jit::SLJIT_MEM;
    int imm = jit::SLJIT_IMM;
    HObject object;
    CaptureRef ref;
    self.e.mov(r2, 0, mem | self.state, $reflect(LoopState.execution).offset);
    self.e.mov(r2, 0, mem | r2, $reflect(SsaExecution.cold).offset);
    self.e.mov(r1, 0, mem | r2, $reflect(ColdCtx.act).offset);
    self.e.mov(r0, 0, mem | r1, $reflect(Activation.func).offset);
    self.guard(jit::SLJIT_NOT_EQUAL, r0, 0, imm, (long)site.function, self.pc);
    if (site.opcode == Opcode.GETCAP) {
        if (site.index >= site.function.capture_count) { self.e.failed = true; return; }
        self.e.mov(r0, 0, mem | r1, $reflect(Activation.tv_func).offset);
        self.e.op(jit::SLJIT_LSHR, r3, r0, 0, imm, 48);
        self.guard(jit::SLJIT_NOT_EQUAL, r3, 0, imm, (long)types::TAG_OBJECT, self.pc);
        self.e.op(jit::SLJIT_AND, r0, r0, 0, imm, (long)types::NANBOX_PAYLOAD_MASK);
        self.guard(jit::SLJIT_EQUAL, r0, 0, imm, 0, self.pc);
        self.e.mov(r3, 0, mem | r0, (char*)&object.extra.func.comp_func - (char*)&object);
        self.guard(jit::SLJIT_NOT_EQUAL, r3, 0, imm, (long)site.function, self.pc);
        self.e.mov(r1, 0, mem | r0, (char*)&object.extra.func.capture_refs - (char*)&object);
        self.guard(jit::SLJIT_EQUAL, r1, 0, imm, 0, self.pc);
        if (site.index != 0) self.e.op(jit::SLJIT_ADD, r1, r1, 0, imm, (long)site.index * CaptureRef::size);
        self.e.mov(r3, 0, mem | r1, $reflect(CaptureRef.is_value).offset, jit::SLJIT_MOV_U8);
        void* indirect = self.e.cmp(jit::SLJIT_EQUAL, r3, 0, imm, 0);
        self.e.mov(r0, 0, mem | r1, $reflect(CaptureRef.value).offset);
        void* loaded = jit::sljit_emit_jump(self.e.compiler, jit::SLJIT_JUMP);
        self.e.bind(indirect);
        // Named refs are created only for non-configurable data bindings;
        // cells and by-value captures are private. A nearer dynamic scope
        // sets guard_shadow and must use ordinary name resolution.
        self.e.mov(r3, 0, mem | r1, $reflect(CaptureRef.guard_shadow).offset, jit::SLJIT_MOV_U8);
        self.guard(jit::SLJIT_NOT_EQUAL, r3, 0, imm, 0, self.pc);
        self.e.mov(r2, 0, mem | r1, $reflect(CaptureRef.owner).offset);
        self.guard(jit::SLJIT_EQUAL, r2, 0, imm, 0, self.pc);
        self.e.mov(r0, 0, mem | r1, $reflect(CaptureRef.prop_idx).offset, jit::SLJIT_MOV_U32);
        self.e.mov(r3, 0, mem | r2, (char*)&object.prop_count - (char*)&object, jit::SLJIT_MOV_U32);
        self.guard(jit::SLJIT_GREATER_EQUAL, r0, 0, r3, 0, self.pc);
        ObjFlags forbidden;
        forbidden.exotic_proxyobj = true;
        forbidden.exotic_module_ns = true;
        self.e.mov(r3, 0, mem | r2, 0, jit::SLJIT_MOV_U32);
        self.e.op(jit::SLJIT_AND, r3, r3, 0, imm, 0x003F0000U | (uint)forbidden);
        self.guard(jit::SLJIT_NOT_EQUAL, r3, 0, imm, (long)(ObjClass.OBJECT.ordinal << 16), self.pc);
        self.e.op(jit::SLJIT_SHL, r0, r0, 0, imm, 3);
        self.e.mov(r3, 0, mem | r2, (char*)&object.prop_alloc - (char*)&object);
        void* allocated = self.e.cmp(jit::SLJIT_NOT_EQUAL, r3, 0, imm, 0);
        self.e.op(jit::SLJIT_ADD, r3, r2, 0, imm, HObjectBase::size);
        self.e.bind(allocated);
        self.e.op(jit::SLJIT_ADD, r3, r3, 0, r0, 0);
        self.e.mov(r0, 0, mem | r3, 0);
        self.e.bind(loaded);
    } else {
        if (site.function.var_ic_entries == null || site.payload_pc >= site.function.var_ic_count) {
            self.publish_id(self.frame_id, self.pc);
            return;
        }
        VarICEntry* entry = (VarICEntry*)site.function.var_ic_entries + site.payload_pc;
        self.e.mov(r0, 0, mem | r1, $reflect(Activation.lex_env).offset);
        self.e.mov(r1, 0, imm, (long)entry);
        self.guard(jit::SLJIT_NOT_EQUAL, r0, 0, mem | r1, $reflect(VarICEntry.search_head).offset, self.pc);
        self.e.mov(r2, 0, mem | r2, $reflect(ColdCtx.heap).offset);
        self.e.mov(r0, 0, mem | r2, $reflect(Heap.shape_recycle_epoch).offset, jit::SLJIT_MOV_U32);
        self.e.mov(r3, 0, mem | r1, $reflect(VarICEntry.recycle_epoch).offset, jit::SLJIT_MOV_U32);
        self.guard(jit::SLJIT_NOT_EQUAL, r0, 0, r3, 0, self.pc);
        PropFlags accessor;
        accessor.is_accessor = true;
        self.e.mov(r3, 0, mem | r1, $reflect(VarICEntry.prop_flags).offset, jit::SLJIT_MOV_U8);
        self.e.op(jit::SLJIT_AND, r3, r3, 0, imm, (uint)accessor);
        self.guard(jit::SLJIT_NOT_EQUAL, r3, 0, imm, 0, self.pc);
        self.e.mov(r2, 0, mem | r1, $reflect(VarICEntry.slot_ptr).offset);
        self.guard(jit::SLJIT_EQUAL, r2, 0, imm, 0, self.pc);
        self.e.mov(r0, 0, mem | r2, 0);
    }
    self.e.op(jit::SLJIT_LSHR, r3, r0, 0, imm, 48);
    // String borrows can be released by an aliased native store before the
    // next collecting helper roots them. Keep their owning VM read path.
    self.guard(jit::SLJIT_EQUAL, r3, 0, imm, (long)types::TAG_STRING, self.pc);
    void* initialized = self.e.cmp(jit::SLJIT_NOT_EQUAL, r3, 0, imm, (long)types::TAG_UNDEFINED);
    // Canonical undefined is a value, so only the temporal dead zone sentinel,
    // the same tag with a nonzero payload, is an uninitialized binding that
    // must resume the read in the interpreter.
    self.e.op(jit::SLJIT_SHL, r3, r0, 0, imm, 16);
    self.guard(jit::SLJIT_NOT_EQUAL, r3, 0, imm, 0, self.pc);
    self.e.bind(initialized);
    // A different closure, aliasing write, callback, or later invocation may
    // change the capture. Check every fresh read before committing its result;
    // fractional numbers, -0, overflow and coercible values resume GETCAP.
    if (self.g.values[id].rep == INT32) self.exact_int(r0, r0, self.pc);
    self.store_gpr(id, r0);
    $if $feat(SLJIT_STATS):
        if (self.plan.ssa_data != null) {
            self.e.mov(r1, 0, imm, (long)&self.plan.ssa_data.binding_reads);
            self.e.mov(r2, 0, mem | r1, 0);
            self.e.op(jit::SLJIT_ADD, r2, r2, 0, imm, 1);
            self.e.mov(mem | r1, 0, r2, 0);
        }
    $endif
}
