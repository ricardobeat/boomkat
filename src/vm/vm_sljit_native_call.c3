module boomkat::vm;

import boomkat::jit;

// The C helper boundary already published and rooted its caller. Enter the
// existing native call convention without creating a second VM call path.
// This normal ABI prologue preserves the platform's saved GPR/FPR homes.
fn void* FunctionEmitter.emit_c_call_entry(&self, void* native) @feat(SLJIT) {
    if (native == null) return null;
    TemplateEmitter* e = &self.out.e;
    void* entry = e.label();
    if (jit::sljit_emit_enter(e.compiler, 0, jit::SLJIT_ARGS3WWW_R,
            jit::scratch_register_count(6) | (6 << 8), 6, 0) != 0) { e.failed = true; return null; }
    int r0 = jit::reg_r(0); int r1 = jit::reg_r(1);
    int r2 = jit::reg_r(2); int r3 = jit::reg_r(3);
    int args = jit::reg_r(4); int mem = jit::SLJIT_MEM;
    e.mov(jit::reg_s(1), 0, r0, 0);
    e.mov(jit::reg_s(2), 0, r1, 0);
    e.mov(jit::reg_s(0), 0, mem | r0, $reflect(ColdCtx.act).offset);
    e.mov(jit::reg_s(0), 0, mem | jit::reg_s(0), $reflect(Activation.bottom).offset);
    e.mov(args, 0, r2, 0);
    e.mov(r0, 0, mem | args, $reflect(FunctionNativeCall.callee).offset);
    e.mov(r1, 0, mem | args, $reflect(FunctionNativeCall.arguments).offset);
    e.mov(r2, 0, mem | args, $reflect(FunctionNativeCall.result).offset);
    e.mov(r3, 0, mem | args, $reflect(FunctionNativeCall.flags).offset, jit::SLJIT_MOV_U32);
    void* call = jit::sljit_emit_call(e.compiler, jit::SLJIT_CALL_REG_ARG, jit::SLJIT_ARGS4WWWW);
    if (call == null) { e.failed = true; return null; }
    jit::sljit_set_label(call, native);
    if (jit::sljit_emit_return(e.compiler, jit::SLJIT_MOV, r0, 0) != 0) e.failed = true;
    return entry;
}
