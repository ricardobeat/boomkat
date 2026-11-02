module boomkat::vm;

import boomkat::bytecode;
import boomkat::heap;
import boomkat::jit;

// A full decoded body keeps the same published-frame call convention as the
// existing function tier. This adapter contains no bytecode lowering: the
// shared SSA runner executes the body, and the existing return emitter pops a
// completed lean activation. Every other outcome unwinds at its exact VM PC.
fn void ssa_function_call_entry(CompiledFunction* cf, ColdCtx* cold, FunctionPlan* plan) @feat(SLJIT) {
    $if $feat(SLJIT_NO_RECOVERABLE_CALL_ENTRY): return; $endif
    if (!cf.call_flags.lean_call || cf.arguments_in_reg() || cf.num_formals > 255) return;
    uint returns;
    for (uint pc = 0; pc < cf.code_count;) {
        DecodedBytecode view = bytecode::decode_bytecode(cf.code, cf.code_count, pc);
        if (!view.valid) return;
        if (view.insn.op == Opcode.RET || view.insn.op == Opcode.RETUNDEF) returns++;
        pc = view.next_pc;
    }
    // Return cleanup and entry initialization are unrolled by the existing
    // native ABI. Bound their compile work/code separately from graph storage.
    usz estimate = ((usz)returns * ((usz)cf.num_regs + 16) + cf.num_regs + 128) * 32;
    if (estimate > SSA_DEFAULT_BUDGET.max_bytes || plan.code_bytes + estimate >= sljit_code_limit(cold.heap)) return;
    LoopPlan layout;
    FunctionEmitter emitter = { .cf = cf, .cold = cold, .plan = plan,
        .out = { .e = { .compiler = jit::sljit_create_compiler(null) }, .heap = cold.heap,
            .plan = &layout, .function_mode = true, .link_limit = LINK_LIMIT_MAX } };
    FunctionEmitter* f = &emitter;
    TemplateEmitter* e = &f.out.e;
    if (e.compiler == null) return;
    defer jit::sljit_free_compiler(e.compiler);
    defer f.out.link_release();
    int r0 = jit::reg_r(0); int r1 = jit::reg_r(1);
    int r2 = jit::reg_r(2); int r3 = jit::reg_r(3);
    int state = jit::reg_s(1); int run = jit::reg_s(2);
    int mem = jit::SLJIT_MEM; int imm = jit::SLJIT_IMM;
    // emit_call_entry has this same context and jumps after the prologue.
    if (jit::sljit_emit_enter(e.compiler, jit::SLJIT_ENTER_REG_ARG | jit::enter_keep(3),
            1, jit::scratch_register_count(6) | (6 << 8), 6, 0) != 0) return;
    void* body = e.label();
    e.mov(jit::reg_s(3), 0, mem | state, $reflect(ColdCtx.act).offset);
    e.mov(r0, 0, state, 0);
    e.mov(r1, 0, imm, (long)plan.ssa_region);
    e.mov(r2, 0, run, 0);
    e.mov(r3, 0, imm, 0);
    if (jit::sljit_emit_icall(e.compiler, jit::SLJIT_CALL, jit::SLJIT_ARGS4WWWW,
            imm, (long)&sljit_function_ssa_run) != 0) return;
    // Calls/GC can move the register window or abandon this activation. Only
    // the original live activation may complete through the native return ABI.
    e.mov(r1, 0, mem | state, $reflect(ColdCtx.act).offset);
    void* lost = e.cmp(jit::SLJIT_NOT_EQUAL, r1, 0, jit::reg_s(3), 0);
    e.mov(jit::reg_s(0), 0, mem | r1, $reflect(Activation.bottom).offset);
    e.mov(r2, 0, mem | state, $reflect(ColdCtx.vm).offset);
    e.mov(r2, 0, mem | r2, $reflect(Vm.current_func).offset);
    void* other_function = e.cmp(jit::SLJIT_NOT_EQUAL, r2, 0, imm, (long)cf);
    void* handoff;
    $if $feat(THREADED_DISPATCH):
        e.mov(r2, 0, mem | state, $reflect(ColdCtx.vm).offset);
        e.mov(r2, 0, mem | r2, $reflect(Vm.threaded_handoff).offset, jit::SLJIT_MOV_U8);
        handoff = e.cmp(jit::SLJIT_NOT_EQUAL, r2, 0, imm, 0);
    $endif
    e.mov(r2, 0, mem | state, $reflect(ColdCtx.dispatch_ptr).offset);
    void* no_dispatch = e.cmp(jit::SLJIT_EQUAL, r2, 0, imm, 0);
    e.mov(r2, 0, mem | r2, $reflect(Dispatch.needs_restart).offset, jit::SLJIT_MOV_U8);
    void* restart = e.cmp(jit::SLJIT_NOT_EQUAL, r2, 0, imm, 0);
    e.bind(no_dispatch);
    for (uint pc = 0; pc < cf.code_count;) {
        DecodedBytecode view = bytecode::decode_bytecode(cf.code, cf.code_count, pc);
        if (view.insn.op == Opcode.RET || view.insn.op == Opcode.RETUNDEF) {
            void* other = e.cmp(jit::SLJIT_NOT_EQUAL, r0, 0, imm, (long)(cf.code + pc));
            f.native_return(pc, view.insn.op == Opcode.RET ? (int)view.insn.a : -1);
            e.bind(other);
        }
        pc = view.next_pc;
    }
    e.bind(lost); e.bind(other_function);
    if (handoff != null) e.bind(handoff);
    e.bind(restart);
    if (jit::sljit_emit_return(e.compiler, jit::SLJIT_MOV, r0, 0) != 0) return;
    // All native-return refusals precede cleanup and preserve their RET prefix.
    for (uint i = 0; i < f.out.link_count; i++) {
        LoopLink link = *f.out.link_at(i);
        f.out.bind_to(link.jump, e.label());
        e.mov(r0, 0, imm, (long)(cf.code + link.target));
        if (jit::sljit_emit_return(e.compiler, jit::SLJIT_MOV, r0, 0) != 0) return;
    }
    void* entry = f.emit_call_entry(body, false);
    void* call_from_c = f.emit_c_call_entry(entry);
    if (entry == null || e.failed) return;
    void* code = jit::sljit_generate_code(e.compiler, 0, null);
    if (code == null) return;
    usz bytes = jit::sljit_shim_code_size(e.compiler);
    if (!sljit_code_room(cold.heap, plan.code_bytes + bytes, true)) {
        jit::sljit_free_code(code, null);
        return;
    }
    plan.ssa_call_code = code;
    plan.call_entry = (void*)jit::sljit_shim_label_addr(entry);
    if (call_from_c != null) plan.call_from_c = (FunctionNativeCallEntry)jit::sljit_shim_label_addr(call_from_c);
    plan.code_bytes += bytes;
    $if $feat(SLJIT_MAP): plan.map_calls = plan.call_entry; $endif
}
