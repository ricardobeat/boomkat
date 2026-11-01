module boomkat::vm;

import boomkat::bytecode;
import boomkat::types;
import boomkat::heap;
import boomkat::hobject;
import boomkat::builtins;
import boomkat::jit;

const long SSA_ACCESS_WRITE = 256;

// Addresses are graph values derived from the actual receiver at this operation.
// No raw pointer is imported from entry feedback or retained across a helper.
// Feedback chooses a class only; every access checks that class and its live
// storage. Unknown sites try ordinary dense arrays and deopt before the opcode
// for other receivers. Numeric dense loads cannot borrow a refcounted string.
fn bool ssa_access_build(SsaGraph* g, DecodedBytecode view) @feat(SLJIT) {
    DecodedInsn ins = view.insn;
    bool write = ins.op == Opcode.PUTPROP;
    if (!write && ins.op != Opcode.GETPROP && ins.op != Opcode.GETPROP_CACHE) return false;
    ObjClass cls = ARRAY;
    if (g.cf.ic_entries != null && view.payload_pc < g.cf.ic_count) {
        ICEntry* ic = (ICEntry*)g.cf.ic_entries + view.payload_pc;
        foreach (candidate : FUNCTION_TYPED_CLASSES) {
            if (ic.typed_kind == (char)(candidate.ordinal + 1)) { cls = candidate; break; }
        }
    }
    int receiver = g.current[write ? ins.a : ins.b];
    int index = g.current[write ? ins.b : ins.c];
    if (receiver < 0 || index < 0 || (write && g.current[ins.c] < 0)) return false;
    receiver = ssa_convert(g, receiver, BOXED, false);
    index = ssa_convert(g, index, INT32, true);
    int stored = -1;
    if (write) {
        stored = ssa_convert(g, g.current[ins.c], cls == ARRAY ? BOXED
            : cls == FLOAT32ARRAY || cls == FLOAT64ARRAY ? F64 : INT32, false);
    }
    ssa_use(g, receiver); ssa_use(g, index);
    int address = ssa_value(g, ACCESS_ADDRESS, RAW, receiver, index,
        (long)cls.ordinal | (write ? SSA_ACCESS_WRITE : 0));
    ssa_use(g, address);
    if (write) {
        ssa_use(g, stored);
        ssa_value(g, ACCESS_STORE, BOXED, address, stored, (long)cls.ordinal);
    } else {
        SsaRep rep = cls == ARRAY ? BOXED
            : cls == FLOAT32ARRAY || cls == FLOAT64ARRAY || cls == UINT32ARRAY ? F64 : INT32;
        int result = ssa_value(g, ACCESS_LOAD, rep, address, -1, (long)cls.ordinal);
        ssa_result(g, result, ins.a, view.pc);
        g.current[ins.a] = result;
    }
    return true;
}

fn void SsaEmitter.access_address(&self, int id) @feat(SLJIT) {
    SsaValue value = self.g.values[id];
    ObjClass cls = (ObjClass)(value.imm & 255);
    bool write = (value.imm & SSA_ACCESS_WRITE) != 0;
    int r0 = jit::reg_r(0); int r1 = jit::reg_r(1);
    int r2 = jit::reg_r(2); int r3 = jit::reg_r(3);
    int mem = jit::SLJIT_MEM; int imm = jit::SLJIT_IMM;
    HObject object;
    self.gpr(value.a, r0);
    self.e.op(jit::SLJIT_LSHR, r3, r0, 0, imm, 48);
    self.guard(jit::SLJIT_NOT_EQUAL, r3, 0, imm, (long)types::TAG_OBJECT, self.pc);
    self.e.op(jit::SLJIT_AND, r0, r0, 0, imm, (long)types::NANBOX_PAYLOAD_MASK);
    self.guard(jit::SLJIT_EQUAL, r0, 0, imm, 0, self.pc);
    self.gpr(value.b, r1);
    ObjFlags forbidden;
    forbidden.exotic_proxyobj = true;
    forbidden.exotic_module_ns = true;
    forbidden.exotic_deferred_ns = true;
    if (cls == ARRAY && write) forbidden.has_indexed_named_prop = true;
    self.e.mov(r2, 0, mem | r0, 0, jit::SLJIT_MOV_U32);
    self.e.op(jit::SLJIT_AND, r3, r2, 0, imm, 0x003F0000U | (uint)forbidden);
    self.guard(jit::SLJIT_NOT_EQUAL, r3, 0, imm, (long)(cls.ordinal << 16), self.pc);
    if (cls == ARRAY) {
        if (write) {
            ObjFlags extensible; extensible.extensible = true;
            self.e.op(jit::SLJIT_AND, r3, r2, 0, imm, (uint)extensible);
            self.guard(jit::SLJIT_EQUAL, r3, 0, imm, 0, self.pc);
            self.commit_receiver(r0);
        }
        self.e.mov(r3, 0, mem | r0, (char*)&object.array_size - (char*)&object, jit::SLJIT_MOV_U32);
        self.guard(jit::SLJIT_GREATER_EQUAL, r1, 0, r3, 0, self.pc);
        self.e.mov(r3, 0, mem | r0, HObjectBase::size, jit::SLJIT_MOV_U32);
        self.guard(jit::SLJIT_GREATER_EQUAL, r1, 0, r3, 0, self.pc);
        self.e.mov(r2, 0, mem | r0, (char*)&object.prop_alloc - (char*)&object);
        void* external = self.e.cmp(jit::SLJIT_NOT_EQUAL, r2, 0, imm, 0);
        self.e.mov(r3, 0, mem | r0, HObjectBase::size + uint::size, jit::SLJIT_MOV_U32);
        self.guard(jit::SLJIT_EQUAL, r3, 0, imm, 0, self.pc);
        self.e.op(jit::SLJIT_ADD, r2, r0, 0, imm, hobject::OBJ_SIZE_ARRAY);
        void* ready = jit::sljit_emit_jump(self.e.compiler, jit::SLJIT_JUMP);
        self.e.bind(external);
        self.e.mov(r3, 0, mem | r0, (char*)&object.prop_capacity - (char*)&object, jit::SLJIT_MOV_U32);
        self.e.op(jit::SLJIT_SHL, r3, r3, 0, imm, 3);
        self.e.op(jit::SLJIT_ADD, r2, r2, 0, r3, 0);
        self.e.bind(ready);
        self.e.op(jit::SLJIT_SHL, r1, r1, 0, imm, 3);
    } else {
        HObjectBufferView view; HObjectArrayBuffer buffer;
        long base = HObjectBase::size;
        self.e.mov(r2, 0, mem | r0, base + (char*)&view.buffer - (char*)&view);
        self.guard(jit::SLJIT_EQUAL, r2, 0, imm, 0, self.pc);
        self.e.mov(r3, 0, mem | r2, base + (char*)&buffer.resizable - (char*)&buffer, jit::SLJIT_MOV_U8);
        self.guard(jit::SLJIT_NOT_EQUAL, r3, 0, imm, 0, self.pc);
        self.e.mov(r3, 0, mem | r2, base + (char*)&buffer.is_shared - (char*)&buffer, jit::SLJIT_MOV_U8);
        self.guard(jit::SLJIT_NOT_EQUAL, r3, 0, imm, 0, self.pc);
        if (write) {
            self.e.mov(r3, 0, mem | r2, base + (char*)&buffer.immutable - (char*)&buffer, jit::SLJIT_MOV_U8);
            self.guard(jit::SLJIT_NOT_EQUAL, r3, 0, imm, 0, self.pc);
        }
        self.e.mov(r2, 0, mem | r2, base + (char*)&buffer.data - (char*)&buffer);
        self.guard(jit::SLJIT_EQUAL, r2, 0, imm, 0, self.pc);
        self.e.mov(r3, 0, mem | r0, base + (char*)&view.byte_offset - (char*)&view, jit::SLJIT_MOV_U32);
        self.e.op(jit::SLJIT_ADD, r2, r2, 0, r3, 0);
        self.e.mov(r3, 0, mem | r0, base + (char*)&view.byte_length - (char*)&view, jit::SLJIT_MOV_U32);
        uint shift = builtins::ta_elem_shift(cls);
        if (shift != 0) self.e.op(jit::SLJIT_LSHR, r3, r3, 0, imm, shift);
        self.guard(jit::SLJIT_GREATER_EQUAL, r1, 0, r3, 0, self.pc);
        if (shift != 0) self.e.op(jit::SLJIT_SHL, r1, r1, 0, imm, shift);
    }
    self.e.op(jit::SLJIT_ADD, r2, r2, 0, r1, 0);
    self.store_gpr(id, r2);
}

fn void SsaEmitter.access_load(&self, int id) @feat(SLJIT) {
    SsaValue value = self.g.values[id];
    ObjClass cls = (ObjClass)value.imm;
    int r0 = jit::reg_r(0); int r2 = jit::reg_r(2); int r3 = jit::reg_r(3);
    self.gpr(value.a, r2);
    if (cls == FLOAT32ARRAY || cls == FLOAT64ARRAY) {
        int dst = value.home != 0 ? value.home : 1;
        bool small = cls == FLOAT32ARRAY;
        if (jit::sljit_emit_fop1(self.e.compiler, jit::SLJIT_MOV_F64 | (small ? jit::SLJIT_32 : 0),
            dst, 0, jit::SLJIT_MEM | r2, 0) != 0) self.e.failed = true;
        if (small && jit::sljit_emit_fop1(self.e.compiler, jit::SLJIT_CONV_F64_FROM_F32,
            dst, 0, dst, 0) != 0) self.e.failed = true;
        if (value.home == 0) self.store_fpr(id, dst);
    } else if (cls == UINT32ARRAY) {
        int dst = value.home != 0 ? value.home : 1;
        self.e.mov(r0, 0, jit::SLJIT_MEM | r2, 0, jit::SLJIT_MOV_U32);
        if (jit::sljit_emit_fop1(self.e.compiler, jit::SLJIT_CONV_F64_FROM_SW, dst, 0, r0, 0) != 0) self.e.failed = true;
        if (value.home == 0) self.store_fpr(id, dst);
    } else {
        self.e.mov(r0, 0, jit::SLJIT_MEM | r2, 0, cls == ARRAY ? jit::SLJIT_MOV : loop_load_op(cls));
        if (cls == ARRAY) {
            self.e.op(jit::SLJIT_LSHR, r3, r0, 0, jit::SLJIT_IMM, 48);
            self.guard(jit::SLJIT_GREATER, r3, 0, jit::SLJIT_IMM, (long)types::TAG_FASTINT, self.pc);
        }
        self.store_gpr(id, r0);
    }
}

fn void SsaEmitter.access_store(&self, int id) @feat(SLJIT) {
    SsaValue value = self.g.values[id];
    ObjClass cls = (ObjClass)value.imm;
    int r0 = jit::reg_r(0); int r2 = jit::reg_r(2); int r3 = jit::reg_r(3);
    self.gpr(value.a, r2);
    if (cls == FLOAT32ARRAY || cls == FLOAT64ARRAY) {
        self.load_fpr(value.b, 1);
        bool small = cls == FLOAT32ARRAY;
        if (small && jit::sljit_emit_fop1(self.e.compiler, jit::SLJIT_CONV_F64_FROM_F32 | jit::SLJIT_32,
            1, 0, 1, 0) != 0) self.e.failed = true;
        if (jit::sljit_emit_fop1(self.e.compiler, jit::SLJIT_MOV_F64 | (small ? jit::SLJIT_32 : 0),
            jit::SLJIT_MEM | r2, 0, 1, 0) != 0) self.e.failed = true;
    } else {
        self.gpr(value.b, r0);
        if (cls == ARRAY) {
            self.e.op(jit::SLJIT_LSHR, r3, r0, 0, jit::SLJIT_IMM, 48);
            self.guard(jit::SLJIT_GREATER, r3, 0, jit::SLJIT_IMM, (long)types::TAG_FASTINT, self.pc);
            self.e.mov(r3, 0, jit::SLJIT_MEM | r2, 0);
            self.e.op(jit::SLJIT_LSHR, r3, r3, 0, jit::SLJIT_IMM, 48);
            // Existing numeric elements need neither ownership nor prototype
            // bookkeeping. Holes and reference-bearing slots use the VM.
            self.guard(jit::SLJIT_GREATER, r3, 0, jit::SLJIT_IMM, (long)types::TAG_FASTINT, self.pc);
        }
        self.e.mov(jit::SLJIT_MEM | r2, 0, r0, 0, cls == ARRAY ? jit::SLJIT_MOV : loop_load_op(cls));
    }
}
