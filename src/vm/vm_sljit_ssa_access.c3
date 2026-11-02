module boomkat::vm;

import boomkat::bytecode;
import boomkat::types;
import boomkat::heap;
import boomkat::hobject;
import boomkat::hstring;
import boomkat::builtins;
import boomkat::jit;

const long SSA_ACCESS_WRITE = 256;

// Addresses are graph values derived from the actual receiver at this operation.
// No raw pointer is imported from entry feedback or retained across a helper.
// Feedback chooses a class only; every access checks that class and its live
// storage. Unknown sites try ordinary dense arrays and deopt before the opcode
// for other receivers. Boxed loads reject holes and refcounted string borrows.
fn bool ssa_access_build(SsaGraph* g, DecodedBytecode view) @feat(SLJIT) {
    DecodedInsn ins = view.insn;
    bool write = ins.op == Opcode.PUTPROP;
    if (!write && ins.op != Opcode.GETPROP && ins.op != Opcode.GETPROP_CACHE) return ssa_access_field_build(g, view);
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
    bool bounds = (value.proof_bits & SSA_PROOF_INDEX_BOUNDS) != 0;
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
    if (cls == ARRAY) forbidden.has_indexed_named_prop = true;
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
        if (!bounds) self.guard(jit::SLJIT_GREATER_EQUAL, r1, 0, r3, 0, self.pc);
        self.e.mov(r3, 0, mem | r0, HObjectBase::size, jit::SLJIT_MOV_U32);
        if (!bounds) self.guard(jit::SLJIT_GREATER_EQUAL, r1, 0, r3, 0, self.pc);
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
        if (!bounds) self.guard(jit::SLJIT_GREATER_EQUAL, r1, 0, r3, 0, self.pc);
        if (shift != 0) self.e.op(jit::SLJIT_SHL, r1, r1, 0, imm, shift);
    }
    self.e.op(jit::SLJIT_ADD, r2, r2, 0, r1, 0);
    self.store_gpr(id, r2);
}

fn void SsaEmitter.access_load(&self, int id) @feat(SLJIT) {
    SsaValue value = self.g.values[id];
    ObjClass cls = (ObjClass)value.imm;
    int r0 = jit::reg_r(0); int r1 = jit::reg_r(1); int r2 = jit::reg_r(2); int r3 = jit::reg_r(3);
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
        self.e.mov(r0, 0, jit::SLJIT_MEM | r2, 0, (cls == ARRAY || cls == OBJECT) ? jit::SLJIT_MOV : loop_load_op(cls));
        if (cls == ARRAY || cls == OBJECT) {
            self.e.op(jit::SLJIT_LSHR, r3, r0, 0, jit::SLJIT_IMM, 48);
            // Present dense elements and own data slots may contain any
            // collector-owned value or immediate. Refcounted string borrows
            // retain the VM path until their ownership can be proven.
            self.guard(jit::SLJIT_EQUAL, r3, 0, jit::SLJIT_IMM, (long)types::TAG_STRING, self.pc);
            self.guard(jit::SLJIT_GREATER_EQUAL, r3, 0, jit::SLJIT_IMM, (long)types::TAG_ENVREF, self.pc);
            if (cls == ARRAY) {
                // All undefined-tagged dense slots are holes in get_array_idx;
                // even canonical undefined needs named/prototype resolution.
                self.guard(jit::SLJIT_EQUAL, r3, 0, jit::SLJIT_IMM, (long)types::TAG_UNDEFINED, self.pc);
            } else {
                void* initialized = self.e.cmp(jit::SLJIT_NOT_EQUAL, r3, 0, jit::SLJIT_IMM, (long)types::TAG_UNDEFINED);
                self.guard(jit::SLJIT_NOT_EQUAL, r0, 0, jit::SLJIT_IMM, (long)(types::TAG_UNDEFINED << 48), self.pc);
                self.e.bind(initialized);
            }
        }
        self.store_gpr(id, r0);
        $if $feat(SLJIT_STATS):
            if ((cls == OBJECT || cls == ARRAY) && self.plan.ssa_data != null) {
                ulong* counter = cls == OBJECT ? &self.plan.ssa_data.field_reads : &self.plan.ssa_data.array_reads;
                self.e.mov(r1, 0, jit::SLJIT_IMM, (long)counter);
                self.e.mov(r2, 0, jit::SLJIT_MEM | r1, 0);
                self.e.op(jit::SLJIT_ADD, r2, r2, 0, jit::SLJIT_IMM, 1);
                self.e.mov(jit::SLJIT_MEM | r1, 0, r2, 0);
            }
        $endif
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
        if (cls == ARRAY || cls == OBJECT) {
            self.e.op(jit::SLJIT_LSHR, r3, r0, 0, jit::SLJIT_IMM, 48);
            if (cls == ARRAY) {
                self.guard(jit::SLJIT_GREATER, r3, 0, jit::SLJIT_IMM, (long)types::TAG_FASTINT, self.pc);
            } else {
                // No incoming traced pointer: these primitive writes need no
                // generational/incremental write barrier. Strings and newly
                // stored object/BigInt pointers retain the owning VM path.
                self.guard(jit::SLJIT_GREATER, r3, 0, jit::SLJIT_IMM, (long)types::TAG_BOOLEAN, self.pc);
                void* initialized = self.e.cmp(jit::SLJIT_NOT_EQUAL, r3, 0, jit::SLJIT_IMM, (long)types::TAG_UNDEFINED);
                self.guard(jit::SLJIT_NOT_EQUAL, r0, 0, jit::SLJIT_IMM, (long)(types::TAG_UNDEFINED << 48), self.pc);
                self.e.bind(initialized);
            }
            self.e.mov(r3, 0, jit::SLJIT_MEM | r2, 0);
            self.e.op(jit::SLJIT_LSHR, r3, r3, 0, jit::SLJIT_IMM, 48);
            if (cls == ARRAY) {
                // Dense holes/prototypes and reference-bearing slots use VM.
                self.guard(jit::SLJIT_GREATER, r3, 0, jit::SLJIT_IMM, (long)types::TAG_FASTINT, self.pc);
            } else {
                self.guard(jit::SLJIT_EQUAL, r3, 0, jit::SLJIT_IMM, (long)types::TAG_STRING, self.pc);
                self.guard(jit::SLJIT_GREATER_EQUAL, r3, 0, jit::SLJIT_IMM, (long)types::TAG_ENVREF, self.pc);
                self.e.mov(jit::reg_r(1), 0, jit::SLJIT_MEM | r2, 0);
                void* initialized = self.e.cmp(jit::SLJIT_NOT_EQUAL, r3, 0, jit::SLJIT_IMM, (long)types::TAG_UNDEFINED);
                self.guard(jit::SLJIT_NOT_EQUAL, jit::reg_r(1), 0, jit::SLJIT_IMM, (long)(types::TAG_UNDEFINED << 48), self.pc);
                self.e.bind(initialized);
            }
        }
        self.e.mov(jit::SLJIT_MEM | r2, 0, r0, 0, (cls == ARRAY || cls == OBJECT) ? jit::SLJIT_MOV : loop_load_op(cls));
        $if $feat(SLJIT_STATS):
            if (cls == OBJECT && self.plan.ssa_data != null) {
                int r1 = jit::reg_r(1);
                self.e.mov(r1, 0, jit::SLJIT_IMM, (long)&self.plan.ssa_data.field_writes);
                self.e.mov(r2, 0, jit::SLJIT_MEM | r1, 0);
                self.e.op(jit::SLJIT_ADD, r2, r2, 0, jit::SLJIT_IMM, 1);
                self.e.mov(jit::SLJIT_MEM | r1, 0, r2, 0);
            }
        $endif
    }
}

struct SsaFieldAccess @feat(SLJIT) {
    uint shape;
    uint generation;
    uint slot;
    bool write;
    CompiledFunction* source;
    uint pc;
    bool live_ic;
    // An inherited read on a dictionary receiver. The live-IC emitter
    // revalidates the receiver's prop_count against dict_count, because a
    // dictionary appends keys without changing its shape id.
    bool has_proto;
    HString* key;
    uint dict_count;
}

fn bool ssa_access_field_spec(Heap* h, CompiledFunction* cf, DecodedBytecode view,
    SsaFieldAccess* access, CompiledFunction* source = null) @feat(SLJIT) {
    if (source == null) source = cf;
    DecodedInsn ins = view.insn;
    bool own_this = ins.op == Opcode.GETTHISC || ins.op == Opcode.PUTTHISC;
    bool write = ins.op == Opcode.PUTPROPC || ins.op == Opcode.PUTTHISC;
    if (!write && ins.op != Opcode.GETPROPC && ins.op != Opcode.GETPROPC_CACHED && !own_this) return false;
    uint constant = ins.c;
    if (source.ic_entries == null || view.payload_pc >= source.ic_count || constant >= source.const_count) return false;
    TVal key = source.constants[constant];
    if (!key.is_string()) return false;
    ICEntry* ic = (ICEntry*)source.ic_entries + view.payload_pc;
    if (ic.key.borrow() != key.get_heapptr()
        || ic.prop_idx >= hobject::IC_PROP_MISSING || ic.prop_flags.is_accessor) return false;
    if (ic.has_proto) {
        // One link only: the receiver's immediate prototype. The entry must
        // carry the dictionary prop_count guard, which is what makes caching
        // an inherited read against an append-only receiver sound.
        if (write || ic.chain == null || ic.chain_len != 1 || ic.dict_count == 0) return false;
        HObject* owner = hobject::ic_cached_proto(ic);
        if (owner == null || owner.is_proxy() || owner.get_class() != ObjClass.OBJECT) return false;
        if (ic.chain.snapshot.protos[0] != (void*)owner || owner.shape_id != ic.chain.snapshot.shapes[0]) return false;
        Shape* receiver_shape = h.get_shape(ic.shape_id);
        Shape* owner_shape    = h.get_shape(owner.shape_id);
        if (receiver_shape == null || owner_shape == null || receiver_shape.generation != ic.shape_gen) return false;
        PropFlags flags;
        if (function_shape_slot(owner_shape, key.get_heapptr(), &flags) != (int)ic.prop_idx || flags.is_accessor) return false;
        // An own property would already have answered this read.
        if (function_shape_slot(receiver_shape, key.get_heapptr(), &flags) >= 0) return false;
        *access = { ic.shape_id, ic.shape_gen, ic.prop_idx, write, source, view.payload_pc, true,
            true, key.get_heapptr(), ic.dict_count };
        return true;
    }
    if (ic.chain_len != 0) return false;
    Shape* shape = h.get_shape(ic.shape_id);
    if (shape == null || shape.generation != ic.shape_gen) return false;
    PropFlags flags;
    int slot = function_shape_slot(shape, key.get_heapptr(), &flags);
    if (slot < 0 || (uint)slot != ic.prop_idx || flags.is_accessor || (write && !flags.writable)) return false;
    *access = { ic.shape_id, ic.shape_gen, (uint)slot, write, source, view.payload_pc, shape.dict,
        false, key.get_heapptr(), 0 };
    return true;
}

// Would this instruction now be emitted as a native access? Helper execution
// asks after feedback fills so a plan compiled before its sites warmed can be
// rebuilt instead of paying a helper call per execution forever.
fn bool ssa_access_would_specialize(Heap* h, CompiledFunction* cf, uint pc) @feat(SLJIT) {
    if (pc >= cf.code_count) return false;
    DecodedBytecode view = bytecode::decode_bytecode(cf.code, cf.code_count, pc);
    if (!view.valid || view.wide) return false;
    switch (view.insn.op) {
        case Opcode.GETPROPC: case Opcode.GETPROPC_CACHED:
        case Opcode.GETTHISC: case Opcode.PUTTHISC: case Opcode.PUTPROPC: break;
        default: return false;
    }
    SsaFieldAccess access;
    return ssa_access_field_spec(h, cf, view, &access);
}

fn bool ssa_access_native_site(SsaGraph* g, DecodedBytecode view) @feat(SLJIT) {
    if (view.insn.op == Opcode.GETPROP || view.insn.op == Opcode.GETPROP_CACHE || view.insn.op == Opcode.PUTPROP) return true;
    SsaFieldAccess access;
    return ssa_access_field_spec(g.heap, g.cf, view, &access);
}

fn bool ssa_access_field_build(SsaGraph* g, DecodedBytecode view) @feat(SLJIT) {
    SsaFieldAccess spec;
    if (!ssa_access_field_spec(g.heap, g.cf, view, &spec)) return false;
    DecodedInsn ins = view.insn;
    bool write = spec.write;
    bool own_this = ins.op == Opcode.GETTHISC || ins.op == Opcode.PUTTHISC;
    int stored = write ? g.current[own_this ? ins.a : ins.b] : -1;
    int receiver = own_this ? ssa_value(g, RECEIVER, BOXED, -1, -1, 0) : g.current[write ? ins.a : ins.b];
    if (receiver < 0 || (write && stored < 0)) return false;
    SsaFieldAccess* access = (SsaFieldAccess*)ssa_storage_alloc(g, 1, SsaFieldAccess::size);
    if (access == null) return false;
    *access = spec;
    receiver = ssa_convert(g, receiver, BOXED, false);
    if (write) stored = ssa_convert(g, stored, BOXED, false);
    ssa_use(g, receiver);
    int address = ssa_value(g, ACCESS_FIELD, RAW, receiver, -1, 0);
    g.values[address].field_access = access;
    ssa_use(g, address);
    if (write) {
        ssa_use(g, stored);
        ssa_value(g, ACCESS_STORE, BOXED, address, stored, (long)ObjClass.OBJECT.ordinal);
    } else {
        int result = ssa_value(g, ACCESS_LOAD, BOXED, address, -1, (long)ObjClass.OBJECT.ordinal);
        ssa_result(g, result, ins.a, view.pc);
        g.current[ins.a] = result;
    }
    return true;
}

fn void SsaEmitter.access_field(&self, int id) @feat(SLJIT) {
    SsaValue value = self.g.values[id];
    SsaFieldAccess* access = value.field_access;
    int r0 = jit::reg_r(0); int r2 = jit::reg_r(2); int r3 = jit::reg_r(3);
    int mem = jit::SLJIT_MEM; int imm = jit::SLJIT_IMM;
    HObject object; Shape shape;
    self.gpr(value.a, r0);
    self.e.op(jit::SLJIT_LSHR, r3, r0, 0, imm, 48);
    self.guard(jit::SLJIT_NOT_EQUAL, r3, 0, imm, (long)types::TAG_OBJECT, self.pc);
    self.e.op(jit::SLJIT_AND, r0, r0, 0, imm, (long)types::NANBOX_PAYLOAD_MASK);
    self.guard(jit::SLJIT_EQUAL, r0, 0, imm, 0, self.pc);
    self.ordinary_receiver(r0, self.pc);
    if (access.write) self.commit_receiver(r0);
    if (access.live_ic) {
        self.access_own_ic(access, r0, r2);
        self.store_gpr(id, r2);
        return;
    }
    self.e.mov(r3, 0, mem | r0, (char*)&object.shape_id - (char*)&object, jit::SLJIT_MOV_U32);
    self.guard(jit::SLJIT_NOT_EQUAL, r3, 0, imm, access.shape, self.pc);
    // Shape IDs can be recycled and private shapes can change in place. Load
    // the live directory after every helper; never embed its movable address.
    self.e.mov(r2, 0, imm, (long)&self.g.heap.shapes);
    self.e.mov(r2, 0, mem | r2, 0);
    self.e.mov(r2, 0, mem | r2, (long)access.shape * void*::size);
    self.guard(jit::SLJIT_EQUAL, r2, 0, imm, 0, self.pc);
    self.e.mov(r3, 0, mem | r2, (char*)&shape.generation - (char*)&shape, jit::SLJIT_MOV_U32);
    self.guard(jit::SLJIT_NOT_EQUAL, r3, 0, imm, access.generation, self.pc);
    self.field_address(r0, r2);
    self.e.op(jit::SLJIT_ADD, r2, r2, 0, imm, (long)access.slot * TVal::size);
    self.store_gpr(id, r2);
}

// A dictionary can append keys and move its property buffer without changing
// its shape ID. Reload the site's current IC and current receiver storage on
// every access; never turn dictionary feedback into a raw slot pointer. An
// inherited read additionally replays its one recorded link and revalidates
// the receiver's prop_count, which is what an appended own key would change.
fn void SsaEmitter.access_own_ic(&self, SsaFieldAccess* access, int receiver, int storage) @feat(SLJIT) {
    int r1 = jit::reg_r(1); int r3 = jit::reg_r(3);
    int mem = jit::SLJIT_MEM; int imm = jit::SLJIT_IMM;
    HObject object; Shape shape; ICChain chain_view;
    HString* key = access.key;
    self.e.mov(r1, 0, imm, (long)&access.source.ic_entries);
    self.e.mov(r1, 0, mem | r1, 0);
    self.guard(jit::SLJIT_EQUAL, r1, 0, imm, 0, self.pc);
    self.e.op(jit::SLJIT_ADD, r1, r1, 0, imm, (long)access.pc * ICEntry::size);
    self.e.mov(r3, 0, mem | r1, $reflect(ICEntry.key).offset);
    self.guard(jit::SLJIT_NOT_EQUAL, r3, 0, imm, (long)key, self.pc);
    self.e.mov(r3, 0, mem | receiver, (char*)&object.shape_id - (char*)&object, jit::SLJIT_MOV_U32);
    self.guard(jit::SLJIT_NOT_EQUAL | jit::SLJIT_32, r3, 0, mem | r1, $reflect(ICEntry.shape_id).offset, self.pc);
    self.e.mov(storage, 0, imm, (long)&self.g.heap.shapes);
    self.e.mov(storage, 0, mem | storage, 0);
    self.e.op(jit::SLJIT_SHL, r3, r3, 0, imm, 3);
    self.e.op(jit::SLJIT_ADD, storage, storage, 0, r3, 0);
    self.e.mov(storage, 0, mem | storage, 0);
    self.guard(jit::SLJIT_EQUAL, storage, 0, imm, 0, self.pc);
    self.e.mov(r3, 0, mem | storage, (char*)&shape.generation - (char*)&shape, jit::SLJIT_MOV_U32);
    self.guard(jit::SLJIT_NOT_EQUAL | jit::SLJIT_32, r3, 0, mem | r1, $reflect(ICEntry.shape_gen).offset, self.pc);
    if (access.has_proto) {
        self.e.mov(r3, 0, mem | r1, $reflect(ICEntry.has_proto).offset, jit::SLJIT_MOV_U8);
        self.guard(jit::SLJIT_EQUAL, r3, 0, imm, 0, self.pc);
        self.e.mov(r3, 0, mem | r1, $reflect(ICEntry.chain_len).offset, jit::SLJIT_MOV_U8);
        self.guard(jit::SLJIT_NOT_EQUAL, r3, 0, imm, 1, self.pc);
        self.e.mov(r3, 0, mem | r1, $reflect(ICEntry.chain).offset);
        self.guard(jit::SLJIT_EQUAL, r3, 0, imm, 0, self.pc);
        // The receiver must not have gained the key since the entry filled.
        self.e.mov(storage, 0, mem | receiver, (char*)&object.prop_count - (char*)&object, jit::SLJIT_MOV_U32);
        self.e.op(jit::SLJIT_ADD, storage, storage, 0, imm, 1);
        self.guard(jit::SLJIT_NOT_EQUAL | jit::SLJIT_32, storage, 0, mem | r1, $reflect(ICEntry.dict_count).offset, self.pc);
        // Replay the recorded link: its identity and its layout.
        self.e.mov(storage, 0, mem | r3, (char*)&chain_view.snapshot.protos - (char*)&chain_view);
        self.e.mov(receiver, 0, mem | receiver, (char*)&object.prototype - (char*)&object);
        self.guard(jit::SLJIT_NOT_EQUAL, receiver, 0, storage, 0, self.pc);
        self.e.mov(storage, 0, mem | receiver, (char*)&object.shape_id - (char*)&object, jit::SLJIT_MOV_U32);
        self.e.mov(r3, 0, mem | r3, (char*)&chain_view.snapshot.shapes - (char*)&chain_view, jit::SLJIT_MOV_U32);
        self.guard(jit::SLJIT_NOT_EQUAL | jit::SLJIT_32, storage, 0, r3, 0, self.pc);
        self.ordinary_receiver(receiver, self.pc);
        PropFlags flags; flags.is_accessor = true;
        self.e.mov(r3, 0, mem | r1, $reflect(ICEntry.prop_flags).offset, jit::SLJIT_MOV_U8);
        self.e.op(jit::SLJIT_AND, r3, r3, 0, imm, (char)flags);
        self.guard(jit::SLJIT_NOT_EQUAL, r3, 0, imm, 0, self.pc);
        self.e.mov(r1, 0, mem | r1, $reflect(ICEntry.prop_idx).offset, jit::SLJIT_MOV_U32);
        self.e.mov(r3, 0, mem | receiver, (char*)&object.prop_count - (char*)&object, jit::SLJIT_MOV_U32);
        self.guard(jit::SLJIT_GREATER_EQUAL, r1, 0, r3, 0, self.pc);
        self.field_address(receiver, storage);
        self.e.op(jit::SLJIT_SHL, r1, r1, 0, imm, 3);
        self.e.op(jit::SLJIT_ADD, storage, storage, 0, r1, 0);
        return;
    }
    self.e.mov(r3, 0, mem | r1, $reflect(ICEntry.has_proto).offset, jit::SLJIT_MOV_U8);
    self.guard(jit::SLJIT_NOT_EQUAL, r3, 0, imm, 0, self.pc);
    self.e.mov(r3, 0, mem | r1, $reflect(ICEntry.chain_len).offset, jit::SLJIT_MOV_U8);
    self.guard(jit::SLJIT_NOT_EQUAL, r3, 0, imm, 0, self.pc);
    PropFlags flags; flags.is_accessor = true;
    if (access.write) flags.writable = true;
    self.e.mov(r3, 0, mem | r1, $reflect(ICEntry.prop_flags).offset, jit::SLJIT_MOV_U8);
    self.e.op(jit::SLJIT_AND, r3, r3, 0, imm, (char)flags);
    self.guard(jit::SLJIT_NOT_EQUAL, r3, 0, imm, access.write ? 1 : 0, self.pc);
    self.e.mov(r1, 0, mem | r1, $reflect(ICEntry.prop_idx).offset, jit::SLJIT_MOV_U32);
    self.e.mov(r3, 0, mem | receiver, (char*)&object.prop_count - (char*)&object, jit::SLJIT_MOV_U32);
    self.guard(jit::SLJIT_GREATER_EQUAL, r1, 0, r3, 0, self.pc);
    self.field_address(receiver, storage);
    self.e.op(jit::SLJIT_SHL, r1, r1, 0, imm, 3);
    self.e.op(jit::SLJIT_ADD, storage, storage, 0, r1, 0);
}
