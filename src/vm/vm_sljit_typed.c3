module boomkat::vm;

import boomkat::bytecode;
import boomkat::types;
import boomkat::heap;
import boomkat::hobject;
import boomkat::builtins;
import boomkat::jit;

const ObjClass[8] FUNCTION_TYPED_CLASSES = {INT8ARRAY, UINT8ARRAY, INT16ARRAY, UINT16ARRAY,
    INT32ARRAY, UINT32ARRAY, FLOAT32ARRAY, FLOAT64ARRAY};

// Invocation-local, never a GC root: native chunks cannot allocate, collect,
// invoke JS or detach buffers. A fresh zeroed FunctionRun discards every raw
// pointer before interpreter execution resumes. Read/write slots are separate
// so a read cannot accidentally authorize a write to an immutable buffer.
struct FunctionTypedCache {
    HObject* receiver;
    char* data;
    uint length;
}

// Observe the receiver at the instruction itself: its register need not even
// have been initialized when compilation started. Sampling stops after a small
// warmup window. Later changes remain safe through the emitted class guard.
fn void sljit_typed_observe(ICEntry* ic, TVal receiver, TVal index) @feat(SLJIT) @inline {
    if (ic == null || ic.typed_samples >= 16 || ic.typed_kind == 255 || !index.is_fastint()) return;
    ic.typed_samples++;
    char kind = 255;
    if (receiver.is_object()) {
        HObject* obj = (HObject*)receiver.get_heapptr();
        if (obj != null && !obj.is_proxy()) {
            foreach (cls : FUNCTION_TYPED_CLASSES) {
                if (obj.get_class() == cls) { kind = (char)(cls.ordinal + 1); break; }
            }
        }
    }
    if (ic.typed_kind == 0) { ic.typed_kind = kind; }
    else if (ic.typed_kind != kind) ic.typed_kind = 255;
}

fn void FunctionEmitter.typed_count(&self, uint kind) @feat(SLJIT) {
    $if $feat(SLJIT_STATS):
        TemplateEmitter* e = &self.out.e;
        ulong* counter = kind == 0 ? &self.plan.typed_reads : kind == 1 ? &self.plan.typed_writes : kind == 2 ? &self.plan.typed_lengths : kind == 3 ? &self.plan.flow_ops : &self.plan.math_calls;
        int r1 = jit::reg_r(1); int r3 = jit::reg_r(3);
        e.mov(r3, 0, jit::SLJIT_IMM, (long)counter);
        e.mov(r1, 0, jit::SLJIT_MEM | r3, 0);
        e.op(jit::SLJIT_ADD, r1, r1, 0, jit::SLJIT_IMM, 1);
        e.mov(jit::SLJIT_MEM | r3, 0, r1, 0);
    $endif
}

// r0 holds the live view. No JS, allocation, or safepoint may occur between
// checking the buffer and using its data. Fixed buffers keep view bounds valid.
fn void FunctionEmitter.typed_access(&self, Instruction ins, uint pc, ObjClass cls, bool write, bool length = false) @feat(SLJIT) {
    LoopEmitter* out = &self.out; TemplateEmitter* e = &out.e;
    int r0 = jit::reg_r(0); int r1 = jit::reg_r(1); int r2 = jit::reg_r(2); int r3 = jit::reg_r(3);
    int mem = jit::SLJIT_MEM; int imm = jit::SLJIT_IMM;
    HObjectBufferView view; HObjectArrayBuffer buffer;
    long base = HObjectBase::size;
    uint shift = builtins::ta_elem_shift(cls);
    if (!length) out.integer(write ? ins.b : ins.c, r1, pc);
    if (length) {
        e.mov(r2, 0, mem | r0, base + (char*)&view.buffer - (char*)&view);
        out.guard(jit::SLJIT_EQUAL, r2, 0, imm, 0, pc);
        e.mov(r3, 0, mem | r2, base + (char*)&buffer.resizable - (char*)&buffer, jit::SLJIT_MOV_U8);
        out.guard(jit::SLJIT_NOT_EQUAL, r3, 0, imm, 0, pc);
        e.mov(r3, 0, mem | r2, base + (char*)&buffer.is_shared - (char*)&buffer, jit::SLJIT_MOV_U8);
        out.guard(jit::SLJIT_NOT_EQUAL, r3, 0, imm, 0, pc);
        e.mov(r3, 0, mem | r0, base + (char*)&view.byte_length - (char*)&view, jit::SLJIT_MOV_U32);
        // Null data is also valid for an attached zero-length buffer; detached
        // buffers report zero through the interpreter instead.
        e.mov(r1, 0, mem | r2, base + (char*)&buffer.byte_length - (char*)&buffer, jit::SLJIT_MOV_U32);
        out.guard(jit::SLJIT_EQUAL, r1, 0, imm, uint::max, pc);
        e.op(jit::SLJIT_LSHR, r0, r3, 0, imm, shift);
        out.box(r0); self.store(ins.a, pc, true); self.typed_count(2); return;
    }
    // Key by the actual live receiver, not a bytecode register or an IC shape.
    // Aliases share metadata, rebinding misses, and element stores preserve it.
    // Keep the class guard in typed_cases: mixed classes remain independently
    // checked even when the receiver identity matches a previous access.
    FunctionRun run; FunctionTypedCache cache;
    long slot = (char*)&run.typed - (char*)&run + (write ? FunctionTypedCache::size : 0);
    int saved = jit::reg_s(2);
    e.mov(r2, 0, mem | saved, slot + (char*)&cache.receiver - (char*)&cache);
    void* hit = e.cmp(jit::SLJIT_EQUAL, r2, 0, r0, 0);
    e.mov(r2, 0, mem | r0, base + (char*)&view.buffer - (char*)&view);
    out.guard(jit::SLJIT_EQUAL, r2, 0, imm, 0, pc);
    e.mov(r3, 0, mem | r2, base + (char*)&buffer.resizable - (char*)&buffer, jit::SLJIT_MOV_U8);
    out.guard(jit::SLJIT_NOT_EQUAL, r3, 0, imm, 0, pc);
    e.mov(r3, 0, mem | r2, base + (char*)&buffer.is_shared - (char*)&buffer, jit::SLJIT_MOV_U8);
    out.guard(jit::SLJIT_NOT_EQUAL, r3, 0, imm, 0, pc);
    if (write) {
        e.mov(r3, 0, mem | r2, base + (char*)&buffer.immutable - (char*)&buffer, jit::SLJIT_MOV_U8);
        out.guard(jit::SLJIT_NOT_EQUAL, r3, 0, imm, 0, pc);
    }
    e.mov(r2, 0, mem | r2, base + (char*)&buffer.data - (char*)&buffer);
    out.guard(jit::SLJIT_EQUAL, r2, 0, imm, 0, pc);
    e.mov(r3, 0, mem | r0, base + (char*)&view.byte_offset - (char*)&view, jit::SLJIT_MOV_U32);
    e.op(jit::SLJIT_ADD, r2, r2, 0, r3, 0);
    e.mov(mem | saved, slot + (char*)&cache.data - (char*)&cache, r2, 0);
    e.mov(r3, 0, mem | r0, base + (char*)&view.byte_length - (char*)&view, jit::SLJIT_MOV_U32);
    // Cache byte length, so the independent class guard chooses its own shift.
    e.mov(mem | saved, slot + (char*)&cache.length - (char*)&cache, r3, 0, jit::SLJIT_MOV_U32);
    e.mov(mem | saved, slot + (char*)&cache.receiver - (char*)&cache, r0, 0);
    void* ready = jit::sljit_emit_jump(e.compiler, jit::SLJIT_JUMP);
    e.bind(hit);
    e.mov(r2, 0, mem | saved, slot + (char*)&cache.data - (char*)&cache);
    e.mov(r3, 0, mem | saved, slot + (char*)&cache.length - (char*)&cache, jit::SLJIT_MOV_U32);
    e.bind(ready);
    // Bounds and index representation are checked for every access. No
    // unchecked shifts can overflow before the unsigned element-count check.
    e.op(jit::SLJIT_LSHR, r3, r3, 0, imm, shift);
    out.guard(jit::SLJIT_GREATER_EQUAL, r1, 0, r3, 0, pc);
    if (shift != 0) e.op(jit::SLJIT_SHL, r1, r1, 0, imm, shift);
    e.op(jit::SLJIT_ADD, r2, r2, 0, r1, 0);
    bool floating = cls == FLOAT32ARRAY || cls == FLOAT64ARRAY;
    bool small = cls == FLOAT32ARRAY;
    if (write) {
        if (floating) {
            out.load(ins.c, r0); out.number(r0, 1, pc);
            if (small) out.fop(jit::SLJIT_CONV_F64_FROM_F32 | jit::SLJIT_32, 1, 0, 1, 0);
            out.fop(jit::SLJIT_MOV_F64 | (small ? jit::SLJIT_32 : 0), mem | r2, 0, 1, 0);
        } else {
            out.int32(ins.c, r0, pc);
            e.mov(mem | r2, 0, r0, 0, loop_load_op(cls));
        }
    } else {
        if (floating) {
            out.fop(jit::SLJIT_MOV_F64 | (small ? jit::SLJIT_32 : 0), 1, 0, mem | r2, 0);
            if (small) out.fop(jit::SLJIT_CONV_F64_FROM_F32, 1, 0, 1, 0);
            out.float_result(1);
        } else { e.mov(r0, 0, mem | r2, 0, loop_load_op(cls)); out.box(r0); }
        self.store(ins.a, pc, true);
    }
    self.typed_count(write ? 1 : 0);
}

// A monomorphic element site emits one class guard and one representation.
// Unobserved/mixed sites retain generic dispatch. Length getters use their
// independent property IC and do not consume element feedback.
fn void FunctionEmitter.typed_cases(&self, Instruction ins, uint pc, bool write, bool length = false) @feat(SLJIT) {
    TemplateEmitter* e = &self.out.e;
    int r0 = jit::reg_r(0); int r3 = jit::reg_r(3); int imm = jit::SLJIT_IMM;
    self.out.load(write ? ins.a : ins.b, r0);
    e.op(jit::SLJIT_LSHR, r3, r0, 0, imm, 48);
    self.out.guard(jit::SLJIT_NOT_EQUAL, r3, 0, imm, (long)types::TAG_OBJECT, pc);
    e.op(jit::SLJIT_AND, r0, r0, 0, imm, (long)types::NANBOX_PAYLOAD_MASK);
    self.out.guard(jit::SLJIT_EQUAL, r0, 0, imm, 0, pc);
    e.mov(r3, 0, jit::SLJIT_MEM | r0, 0, jit::SLJIT_MOV_U32);
    ObjFlags proxy; proxy.exotic_proxyobj = true;
    e.op(jit::SLJIT_AND, r3, r3, 0, imm, 0x003F0000U | (uint)proxy);
    if (!length && self.cf.ic_entries != null && pc < self.cf.ic_count) {
        ICEntry* ic = (ICEntry*)self.cf.ic_entries + pc;
        foreach (cls : FUNCTION_TYPED_CLASSES) {
            if (ic.typed_kind != (char)(cls.ordinal + 1)) continue;
            self.out.guard(jit::SLJIT_NOT_EQUAL, r3, 0, imm, (long)(cls.ordinal << 16), pc);
            self.typed_access(ins, pc, cls, write);
            return;
        }
    }
    void*[8] cases; void*[8] ends;
    foreach (i, cls : FUNCTION_TYPED_CLASSES) {
        cases[i] = e.cmp(jit::SLJIT_EQUAL, r3, 0, imm, (long)(cls.ordinal << 16));
    }
    self.out.link(jit::sljit_emit_jump(e.compiler, jit::SLJIT_JUMP), pc, true);
    foreach (i, cls : FUNCTION_TYPED_CLASSES) {
        e.bind(cases[i]); self.typed_access(ins, pc, cls, write, length);
        ends[i] = jit::sljit_emit_jump(e.compiler, jit::SLJIT_JUMP);
    }
    void* done = e.label(); foreach (end : ends) self.out.bind_to(end, done);
}

fn bool FunctionEmitter.indexed(&self, CompiledFunction* cf, uint pc, bool write, Heap* h) @feat(SLJIT) {
    // The typed/named dispatch joins independently generated paths. Publish
    // before this join; only straight-line regions retain FP definitions.
    FunctionFlow* saved_flow = self.out.flow;
    if (saved_flow != null) { self.flow_materialize(); self.out.flow = null; }
    defer self.out.flow = saved_flow;
    void* dense = !write ? self.array_read(cf, pc) : null;
    TemplateEmitter* e = &self.out.e;
    Instruction ins = cf.code[pc];
    int r1 = jit::reg_r(1); int r3 = jit::reg_r(3);
    self.out.load(write ? ins.b : ins.c, r1);
    e.op(jit::SLJIT_LSHR, r3, r1, 0, jit::SLJIT_IMM, 48);
    void* named = e.cmp(jit::SLJIT_NOT_EQUAL, r3, 0, jit::SLJIT_IMM, (long)types::TAG_FASTINT);
    self.typed_cases(ins, pc, write);
    void* end = jit::sljit_emit_jump(e.compiler, jit::SLJIT_JUMP);
    e.bind(named); self.property(cf, pc, write, h); e.bind(end);
    if (dense != null) e.bind(dense);
    return true;
}

// Specialize the actual builtin getter, checking the live receiver chain and
// getter value. A custom own length, prototype change, or replacement getter
// returns to the interpreter before executing any part of the property read.
fn bool FunctionEmitter.typed_length(&self, CompiledFunction* cf, uint pc, ICEntry* ic, Heap* h) @feat(SLJIT) {
    if (!ic.prop_flags.is_accessor || ic.chain_len == 0 || ic.chain_len > hobject::IC_MAX_CHAIN
        || hobject::ic_cached_proto(ic) != h.typedarray_proto || ic.key.borrow() != h.str(heap::BuiltinStr.LENGTH)) return false;
    HObject* proto = h.typedarray_proto;
    int slot = proto.find_prop_idx(ic.key.borrow(), h);
    if (slot < 0 || (uint)slot != ic.prop_idx || !proto.get_prop_flags((uint)slot, h).is_accessor) return false;
    TVal getter = hobject::hobject_access_getter(proto.prop_values()[slot].get());
    if (!builtins::regexp_is_builtin(getter, (int)builtins::Builtin.TYPEDARRAY_PROTO_LENGTH_GET.ordinal)) return false;
    Shape* root = h.get_shape(ic.shape_id); PropFlags flags;
    if (root == null || root.generation != ic.shape_gen || root.dict
        || function_shape_slot(root, ic.key.borrow(), &flags) >= 0 || !self.shape(ic.shape_id, h)) return false;
    for (uint i = 0; i < ic.chain_len; i++) {
        Shape* layout = h.get_shape(ic.chain.snapshot.shapes[i]);
        if (layout == null || layout.dict || ic.chain.snapshot.protos[i] == null || !self.shape(ic.chain.snapshot.shapes[i], h)) return false;
        int found = function_shape_slot(layout, ic.key.borrow(), &flags);
        if (i + 1 < ic.chain_len) { if (found >= 0) return false; }
        else { if (found != slot || !flags.is_accessor || proto.shape_id != ic.chain.snapshot.shapes[i]) return false; }
    }
    TemplateEmitter* e = &self.out.e;
    int r0 = jit::reg_r(0); int r2 = jit::reg_r(2); int r3 = jit::reg_r(3);
    int mem = jit::SLJIT_MEM; int imm = jit::SLJIT_IMM;
    HObject obj; HObjectGetterSetter pair;
    self.out.load(cf.code[pc].b, r0);
    e.op(jit::SLJIT_LSHR, r3, r0, 0, imm, 48);
    self.out.guard(jit::SLJIT_NOT_EQUAL, r3, 0, imm, (long)types::TAG_OBJECT, pc);
    e.op(jit::SLJIT_AND, r0, r0, 0, imm, (long)types::NANBOX_PAYLOAD_MASK);
    self.out.guard(jit::SLJIT_EQUAL, r0, 0, imm, 0, pc);
    for (uint i = 0; i <= ic.chain_len; i++) {
        e.mov(r3, 0, mem | r0, (char*)&obj.shape_id - (char*)&obj, jit::SLJIT_MOV_U32);
        self.out.guard(jit::SLJIT_NOT_EQUAL, r3, 0, imm, i == 0 ? ic.shape_id : ic.chain.snapshot.shapes[i - 1], pc);
        e.mov(r3, 0, mem | r0, 0, jit::SLJIT_MOV_U32);
        ObjFlags proxy; proxy.exotic_proxyobj = true; proxy.exotic_module_ns = true; proxy.exotic_deferred_ns = true;
        e.op(jit::SLJIT_AND, r3, r3, 0, imm, (uint)proxy);
        self.out.guard(jit::SLJIT_NOT_EQUAL, r3, 0, imm, 0, pc);
        if (i < ic.chain_len) {
            e.mov(r0, 0, mem | r0, (char*)&obj.prototype - (char*)&obj);
            self.out.guard(jit::SLJIT_NOT_EQUAL, r0, 0, imm, (long)ic.chain.snapshot.protos[i], pc);
        }
    }
    e.mov(r2, 0, mem | r0, (char*)&obj.prop_alloc - (char*)&obj);
    void* allocated = e.cmp(jit::SLJIT_NOT_EQUAL, r2, 0, imm, 0);
    e.op(jit::SLJIT_ADD, r2, r0, 0, imm, HObjectBase::size); e.bind(allocated);
    e.mov(r2, 0, mem | r2, (long)slot * 8);
    e.op(jit::SLJIT_AND, r2, r2, 0, imm, (long)types::NANBOX_PAYLOAD_MASK);
    e.mov(r3, 0, mem | r2, HObjectBase::size + (char*)&pair.getter - (char*)&pair);
    if (getter.is_lightfunc()) {
        self.out.guard(jit::SLJIT_NOT_EQUAL, r3, 0, imm, (long)loop_bits(getter), pc);
    } else {
        // Check the live builtin index as well as the object kind. A collected
        // function address being reused cannot turn a JS getter into this one.
        e.op(jit::SLJIT_LSHR, r2, r3, 0, imm, 48);
        self.out.guard(jit::SLJIT_NOT_EQUAL, r2, 0, imm, (long)types::TAG_OBJECT, pc);
        e.op(jit::SLJIT_AND, r2, r3, 0, imm, (long)types::NANBOX_PAYLOAD_MASK);
        self.out.guard(jit::SLJIT_EQUAL, r2, 0, imm, 0, pc);
        e.mov(r3, 0, mem | r2, 0, jit::SLJIT_MOV_U32);
        ObjFlags bound; bound.is_bound = true; bound.obj_class = FUNCTION;
        e.op(jit::SLJIT_AND, r3, r3, 0, imm, 0x003F0000U | ((uint)bound & ~0x003F0000U));
        self.out.guard(jit::SLJIT_NOT_EQUAL, r3, 0, imm, (long)(ObjClass.FUNCTION.ordinal << 16), pc);
        e.mov(r3, 0, mem | r2, (char*)&obj.extra.func.builtin_fn_index - (char*)&obj, jit::SLJIT_MOV_S32);
        self.out.guard(jit::SLJIT_NOT_EQUAL, r3, 0, imm, (long)builtins::Builtin.TYPEDARRAY_PROTO_LENGTH_GET.ordinal, pc);
    }
    self.typed_cases(cf.code[pc], pc, false, true);
    return true;
}
