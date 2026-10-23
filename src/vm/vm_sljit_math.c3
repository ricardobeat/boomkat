module boomkat::vm;

import boomkat::bytecode;
import boomkat::types;
import boomkat::hobject;
import boomkat::hstring;
import boomkat::builtins;
import boomkat::jit;

// A name chooses a hypothesis; the live builtin index guards its meaning.
fn int function_math_candidate(CompiledFunction* cf, uint pc) @feat(SLJIT) {
    Instruction call = cf.code[pc];
    if (call.op != Opcode.CALL || call.c < 1 || call.c > 2 || (uint)call.b + 1 + call.c >= cf.num_regs) return -1;
    uint reg = call.b;
    for (uint back = pc; back > 0; back--) {
        Instruction ins = cf.code[back - 1];
        if (ins.a != reg) continue;
        if (ins.op == Opcode.LDREG) {
            reg = ins.b;
            continue;
        }
        if (ins.op != Opcode.GETPROPC && ins.op != Opcode.GETPROPC_CACHED && ins.op != Opcode.GETTHISC) return -1;
        if (ins.c >= cf.const_count || !cf.constants[ins.c].is_string()) return -1;
        HString* key = cf.constants[ins.c].get_heapptr();
        if (key == null || key.is_symbol()) return -1;
        if (call.c == 1) {
            if (key.equals("abs")) return (int)Builtin.MATH_ABS.ordinal;
            if (key.equals("sqrt")) return (int)Builtin.MATH_SQRT.ordinal;
        } else {
            if (key.equals("min")) return (int)Builtin.MATH_MIN.ordinal;
            if (key.equals("max")) return (int)Builtin.MATH_MAX.ordinal;
            if (key.equals("imul")) return (int)Builtin.MATH_IMUL.ordinal;
        }
        return -1;
    }
    return -1;
}
fn void FunctionEmitter.builtin_index(&self, uint reg, uint pc) @feat(SLJIT) {
    TemplateEmitter* e = &self.out.e;
    int r0             = jit::reg_r(0);
    int r1             = jit::reg_r(1);
    int r2             = jit::reg_r(2);
    int imm            = jit::SLJIT_IMM;
    int mem            = jit::SLJIT_MEM;
    self.out.load(reg, r0);
    e.op(jit::SLJIT_LSHR, r1, r0, 0, imm, 48);
    void* object = e.cmp(jit::SLJIT_EQUAL, r1, 0, imm, (long)types::TAG_OBJECT);
    self.out.guard(jit::SLJIT_NOT_EQUAL, r1, 0, imm, (long)types::TAG_LIGHTFUNC, pc);
    e.op(jit::SLJIT_AND, r2, r0, 0, imm, (long)types::NANBOX_PAYLOAD_MASK);
    void* done = jit::sljit_emit_jump(e.compiler, jit::SLJIT_JUMP);
    e.bind(object);
    e.op(jit::SLJIT_AND, r0, r0, 0, imm, (long)types::NANBOX_PAYLOAD_MASK);
    self.out.guard(jit::SLJIT_EQUAL, r0, 0, imm, 0, pc);
    HObject layout;
    e.mov(r1, 0, mem | r0, 0, jit::SLJIT_MOV_U32);
    ObjFlags wanted;
    wanted.callable = true;
    wanted.obj_class = FUNCTION;
    ObjFlags forbidden;
    forbidden.is_bound = true;
    forbidden.exotic_proxyobj = true;
    e.op(jit::SLJIT_AND, r1, r1, 0, imm, 0x003F0000U | (uint)wanted | (uint)forbidden);
    self.out.guard(jit::SLJIT_NOT_EQUAL, r1, 0, imm, (uint)wanted, pc);
    e.mov(r2, 0, mem | r0, (char*)&layout.extra.func.builtin_fn_index - (char*)&layout, jit::SLJIT_MOV_S32);
    e.bind(done);
}
fn void FunctionEmitter.math_call(&self, CompiledFunction* cf, uint pc) @feat(SLJIT) {
    Instruction ins    = cf.code[pc];
    int builtin        = function_math_candidate(cf, pc);
    LoopEmitter* out   = &self.out;
    TemplateEmitter* e = &out.e;
    int r0             = jit::reg_r(0);
    int r1             = jit::reg_r(1);
    int imm            = jit::SLJIT_IMM;
    self.builtin_index(ins.b, pc);
    out.guard(jit::SLJIT_NOT_EQUAL, jit::reg_r(2), 0, imm, builtin, pc);
    if (builtin == (int)Builtin.MATH_IMUL.ordinal) {
        out.int32((uint)ins.b + 2, r0, pc);
        out.int32((uint)ins.b + 3, r1, pc);
        e.op(jit::SLJIT_MUL | jit::SLJIT_32, r0, r0, 0, r1, 0);
        e.mov(r0, 0, r0, 0, jit::SLJIT_MOV_S32);
        out.box(r0);
        self.store(ins.a, pc, true);
    } else {
        if (out.flow != null) {
            self.flow_number((uint)ins.b + 2, 1, pc);
        } else {
            out.load((uint)ins.b + 2, r0);
            out.number(r0, 1, pc);
        }
        if (builtin == (int)Builtin.MATH_SQRT.ordinal) {
            if (jit::sljit_shim_sqrt_f64(
                e.compiler,
                1
            ) != 0) out.link(jit::sljit_emit_jump(e.compiler, jit::SLJIT_JUMP), pc, true);
        } else if (builtin == (int)Builtin.MATH_ABS.ordinal) {
            out.fop(jit::SLJIT_ABS_F64, 1, 0, 1, 0);
        } else {
            if (out.flow != null) {
                self.flow_number((uint)ins.b + 3, 2, pc);
            } else {
                out.load((uint)ins.b + 3, r0);
                out.number(r0, 2, pc);
            }
            // Equal non-NaNs have identical bits except +/-0. OR selects -0
            // for min, AND selects +0 for max. Handle NaNs before the tie.
            bool minimum = builtin == (int)Builtin.MATH_MIN.ordinal;
            void* nan    = jit::sljit_emit_fcmp(e.compiler, 22, 1, 0, 2, 0);
            void* left   = jit::sljit_emit_fcmp(e.compiler, minimum ? 26 : 28, 1, 0, 2, 0);
            void* right  = jit::sljit_emit_fcmp(e.compiler, minimum ? 28 : 26, 1, 0, 2, 0);
            if (nan == null || left == null || right == null) e.failed = true;
            out.fcopy(jit::SLJIT_COPY_FROM_F64, 1, r0);
            out.fcopy(jit::SLJIT_COPY_FROM_F64, 2, r1);
            e.op(minimum ? jit::SLJIT_OR : jit::SLJIT_AND, r0, r0, 0, r1, 0);
            out.fcopy(jit::SLJIT_COPY_TO_F64, 1, r0);
            void* tie = jit::sljit_emit_jump(e.compiler, jit::SLJIT_JUMP);
            e.bind(right);
            out.fop(jit::SLJIT_MOV_F64, 1, 0, 2, 0);
            void* selected = jit::sljit_emit_jump(e.compiler, jit::SLJIT_JUMP);
            e.bind(nan);
            e.mov(r0, 0, imm, 0x7FF8000000000000L);
            out.fcopy(jit::SLJIT_COPY_TO_F64, 1, r0);
            void* done = e.label();
            out.bind_to(left, done);
            out.bind_to(tie, done);
            out.bind_to(selected, done);
        }
        if (out.flow != null) {
            self.flow_destination(ins.a, pc);
            self.flow.forget(ins.a);
            int slot = self.flow_slot(ins.a, pc);
            out.fop(jit::SLJIT_MOV_F64, slot, 0, 1, 0);
            self.flow.dirty |= 1U << (uint)(slot - 3);
        } else {
            out.float_result(1);
            self.store(ins.a, pc, true);
        }
    }
    self.typed_count(4);
}

// parseInt of an exact integer is that integer. The call site keeps a live
// binding check; only the fastint path folds, other inputs still call.
fn bool function_parseint_candidate(CompiledFunction* cf, uint pc) @feat(SLJIT) {
    Instruction call = cf.code[pc];
    if ((call.op != Opcode.CALL && call.op != Opcode.CALL_UNDEF_THIS) || call.c != 1
        || (uint)call.b + 3 >= cf.num_regs) return false;
    int site = function_inline_site(cf, pc);
    if (site < 0) return false;
    Instruction load = cf.code[site];
    if (load.op != Opcode.GETGLOBAL && load.op != Opcode.GETVAR) return false;
    if (load.get_bc() >= cf.const_count) return false;
    TVal name = cf.constants[load.get_bc()];
    if (!name.is_string()) return false;
    HString* key = name.get_heapptr();
    return key != null && !key.is_symbol() && key.equals("parseInt");
}
fn void FunctionEmitter.parseint_call(&self, CompiledFunction* cf, uint pc) @feat(SLJIT) {
    Instruction ins    = cf.code[pc];
    LoopEmitter* out   = &self.out;
    TemplateEmitter* e = &out.e;
    int r0             = jit::reg_r(0);
    int r3             = jit::reg_r(3);
    int imm            = jit::SLJIT_IMM;
    self.builtin_index(ins.b, pc);
    out.guard(jit::SLJIT_NOT_EQUAL, jit::reg_r(2), 0, imm, (int)Builtin.PARSE_INT.ordinal, pc);
    out.load((uint)ins.b + 2, r0);
    e.op(jit::SLJIT_LSHR, r3, r0, 0, imm, 48);
    out.guard(jit::SLJIT_NOT_EQUAL, r3, 0, imm, (long)types::TAG_FASTINT, pc);
    self.store(ins.a, pc, true);
    self.typed_count(4);
}