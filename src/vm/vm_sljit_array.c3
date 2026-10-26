module boomkat::vm;

import boomkat::bytecode;
import boomkat::types;
import boomkat::heap;
import boomkat::hobject;
import boomkat::hstring;
import boomkat::builtins;
import boomkat::jit;

// Emit before property(), then bind the returned success jump after it. Type
// mismatches fall through to that property's existing path. Once a dense-array
// read is selected, every refusal resumes the original opcode before storing.
fn void* FunctionEmitter.array_read(&self, CompiledFunction* cf, uint pc) @feat(SLJIT) {
    Instruction ins = cf.code[pc];
    if (ins.op != Opcode.GETPROP && ins.op != Opcode.GETPROP_CACHE) return null;
    LoopEmitter* out = &self.out; TemplateEmitter* e = &out.e;
    int r0 = jit::reg_r(0); int r1 = jit::reg_r(1); int r2 = jit::reg_r(2); int r3 = jit::reg_r(3);
    int imm = jit::SLJIT_IMM; int mem = jit::SLJIT_MEM;
    HObject obj;
    out.load(ins.b, r0);
    e.op(jit::SLJIT_LSHR, r3, r0, 0, imm, 48);
    void* nonobject = e.cmp(jit::SLJIT_NOT_EQUAL, r3, 0, imm, (long)types::TAG_OBJECT);
    e.op(jit::SLJIT_AND, r0, r0, 0, imm, (long)types::NANBOX_PAYLOAD_MASK);
    void* nullobject = e.cmp(jit::SLJIT_EQUAL, r0, 0, imm, 0);
    e.mov(r2, 0, mem | r0, 0, jit::SLJIT_MOV_U32);
    e.op(jit::SLJIT_AND, r3, r2, 0, imm, 0x003F0000U);
    ObjFlags array; array.obj_class = ARRAY;
    void* nonarray = e.cmp(jit::SLJIT_NOT_EQUAL, r3, 0, imm, (uint)array);
    out.load(ins.c, r1);
    e.op(jit::SLJIT_LSHR, r3, r1, 0, imm, 48);
    void* nonindex = e.cmp(jit::SLJIT_NOT_EQUAL, r3, 0, imm, (long)types::TAG_FASTINT);
    e.op(jit::SLJIT_SHL, r1, r1, 0, imm, 16);
    e.op(jit::SLJIT_ASHR, r1, r1, 0, imm, 16);
    void* negative = e.cmp(jit::SLJIT_SIG_LESS, r1, 0, imm, 0);
    ObjFlags forbidden;
    forbidden.exotic_proxyobj = true; forbidden.exotic_module_ns = true; forbidden.exotic_deferred_ns = true;
    e.op(jit::SLJIT_AND, r2, r2, 0, imm, (uint)forbidden);
    out.guard(jit::SLJIT_NOT_EQUAL, r2, 0, imm, 0, pc);
    e.mov(r3, 0, mem | r0, (char*)&obj.array_size - (char*)&obj, jit::SLJIT_MOV_U32);
    out.guard(jit::SLJIT_GREATER_EQUAL, r1, 0, r3, 0, pc);
    e.mov(r3, 0, mem | r0, HObjectBase::size, jit::SLJIT_MOV_U32);
    out.guard(jit::SLJIT_GREATER_EQUAL, r1, 0, r3, 0, pc);
    // Resolve array_part() from the live object; named properties precede
    // external elements, while short literals keep elements in their header.
    e.mov(r2, 0, mem | r0, (char*)&obj.prop_alloc - (char*)&obj);
    void* external = e.cmp(jit::SLJIT_NOT_EQUAL, r2, 0, imm, 0);
    e.mov(r3, 0, mem | r0, HObjectBase::size + uint::size, jit::SLJIT_MOV_U32);
    out.guard(jit::SLJIT_EQUAL, r3, 0, imm, 0, pc);
    e.op(jit::SLJIT_ADD, r2, r0, 0, imm, hobject::OBJ_SIZE_ARRAY);
    void* base_ready = jit::sljit_emit_jump(e.compiler, jit::SLJIT_JUMP);
    e.bind(external);
    e.mov(r3, 0, mem | r0, (char*)&obj.prop_capacity - (char*)&obj, jit::SLJIT_MOV_U32);
    e.op(jit::SLJIT_SHL, r3, r3, 0, imm, 3);
    e.op(jit::SLJIT_ADD, r2, r2, 0, r3, 0);
    e.bind(base_ready);
    e.op(jit::SLJIT_SHL, r1, r1, 0, imm, 3);
    e.op(jit::SLJIT_ADD, r2, r2, 0, r1, 0);
    e.mov(r0, 0, mem | r2, 0);
    // Undefined denotes an absent dense slot, including values moved to the
    // named table by defineProperty. Prototype lookup belongs to the VM.
    e.op(jit::SLJIT_LSHR, r3, r0, 0, imm, 48);
    out.guard(jit::SLJIT_EQUAL, r3, 0, imm, (long)types::TAG_UNDEFINED, pc);
    self.store(ins.a, pc);
    void* done = jit::sljit_emit_jump(e.compiler, jit::SLJIT_JUMP);
    e.bind(nonobject); e.bind(nullobject); e.bind(nonarray); e.bind(nonindex); e.bind(negative);
    return done;
}

// The dense element storage of `object`, which the caller has already guarded
// as an ordinary extensible array. A short literal keeps its elements in the
// header block, marked by a non-zero inline capacity; once named properties or
// growth move them out, prop_alloc holds the block and the elements follow the
// named slots at prop_capacity.
fn void FunctionEmitter.dense_elements(&self, int object, int base, int scratch, uint pc) @feat(SLJIT) {
    TemplateEmitter* e = &self.out.e;
    int mem            = jit::SLJIT_MEM;
    int imm            = jit::SLJIT_IMM;
    HObject obj;
    e.mov(base, 0, mem | object, (char*)&obj.prop_alloc - (char*)&obj);
    void* external = e.cmp(jit::SLJIT_NOT_EQUAL, base, 0, imm, 0);
    e.mov(scratch, 0, mem | object, HObjectBase::size + uint::size, jit::SLJIT_MOV_U32);
    self.out.guard(jit::SLJIT_EQUAL, scratch, 0, imm, 0, pc);
    e.op(jit::SLJIT_ADD, base, object, 0, imm, hobject::OBJ_SIZE_ARRAY);
    void* ready = jit::sljit_emit_jump(e.compiler, jit::SLJIT_JUMP);
    e.bind(external);
    e.mov(scratch, 0, mem | object, (char*)&obj.prop_capacity - (char*)&obj, jit::SLJIT_MOV_U32);
    e.op(jit::SLJIT_SHL, scratch, scratch, 0, imm, 3);
    e.op(jit::SLJIT_ADD, base, base, 0, scratch, 0);
    e.bind(ready);
}

// A push or pop whose callee is the intrinsic array method: the call's callee
// register comes from a named read of "push" or "pop" in this code unit. The
// name only chooses the hypothesis; the live builtin index confirms it.
fn int function_array_candidate(CompiledFunction* cf, uint pc) @feat(SLJIT) {
    Instruction call = cf.code[pc];
    if (call.op != Opcode.CALL || call.c > 1) return -1;
    if ((uint)call.b + 2 + call.c > cf.num_regs) return -1;
    uint reg = call.b;
    for (uint back = pc; back > 0; back--) {
        Instruction ins = cf.code[back - 1];
        if (ins.a != reg) continue;
        if (ins.op == Opcode.LDREG) {
            reg = ins.b;
            continue;
        }
        if (ins.op != Opcode.GETPROPC && ins.op != Opcode.GETPROPC_CACHED) return -1;
        if (ins.c >= cf.const_count || !cf.constants[ins.c].is_string()) return -1;
        HString* key = cf.constants[ins.c].get_heapptr();
        if (key == null || key.is_symbol()) return -1;
        if (key.equals("push")) return call.c == 1 ? (int)builtins::Builtin.ARRAY_PROTO_PUSH.ordinal : -1;
        if (key.equals("pop")) return call.c == 0 ? (int)builtins::Builtin.ARRAY_PROTO_POP.ordinal : -1;
        return -1;
    }
    return -1;
}

// A dense array append or removal with no interpreter round trip. Both claim
// only the shape the builtin's own fast path accepts: a plain extensible array
// with a writable length, no named properties at all, spare dense capacity and
// a hole (push) or a present, uncounted element (pop) at the end. Anything
// else exits at the call, where the interpreter runs the general algorithm.
fn void FunctionEmitter.array_call(&self, CompiledFunction* cf, uint pc) @feat(SLJIT) {
    Instruction ins    = cf.code[pc];
    int builtin        = function_array_candidate(cf, pc);
    bool push          = builtin == (int)builtins::Builtin.ARRAY_PROTO_PUSH.ordinal;
    LoopEmitter* out   = &self.out;
    TemplateEmitter* e = &out.e;
    int r0             = jit::reg_r(0);
    int r1             = jit::reg_r(1);
    int r2             = jit::reg_r(2);
    int r3             = jit::reg_r(3);
    int imm            = jit::SLJIT_IMM;
    int mem            = jit::SLJIT_MEM;
    uint receiver      = (uint)ins.b + 1;
    if (ins.a == receiver && !push) return;
    self.builtin_index(ins.b, pc);
    out.guard(jit::SLJIT_NOT_EQUAL, r2, 0, imm, builtin, pc);
    out.load(receiver, r0);
    e.op(jit::SLJIT_LSHR, r1, r0, 0, imm, 48);
    out.guard(jit::SLJIT_NOT_EQUAL, r1, 0, imm, (long)types::TAG_OBJECT, pc);
    e.op(jit::SLJIT_AND, r0, r0, 0, imm, (long)types::NANBOX_PAYLOAD_MASK);
    out.guard(jit::SLJIT_EQUAL, r0, 0, imm, 0, pc);
    HObject obj;
    HObjectBase base_view;
    Heap heap_view;
    long len_offset = (char*)obj.array_len_ptr() - (char*)&obj;
    ObjFlags wanted;
    wanted.obj_class            = ARRAY;
    wanted.extensible           = true;
    wanted.array_len_writable   = true;
    ObjFlags forbidden;
    forbidden.exotic_proxyobj      = true;
    forbidden.exotic_module_ns     = true;
    forbidden.exotic_deferred_ns   = true;
    forbidden.has_indexed_named_prop = true;
    e.mov(r1, 0, mem | r0, 0, jit::SLJIT_MOV_U32);
    e.op(jit::SLJIT_AND, r1, r1, 0, imm, (uint)wanted | (uint)forbidden);
    out.guard(jit::SLJIT_NOT_EQUAL, r1, 0, imm, (uint)wanted, pc);
    // A named property (materialised "length" included) would need its own
    // sync, and a promoted index would shadow the dense slot.
    e.mov(r1, 0, mem | r0, (char*)&obj.prop_count - (char*)&obj, jit::SLJIT_MOV_U32);
    out.guard(jit::SLJIT_NOT_EQUAL, r1, 0, imm, 0, pc);
    self.dense_elements(r0, r2, r3, pc);
    e.mov(r1, 0, mem | r0, len_offset, jit::SLJIT_MOV_U32);
    if (push) {
        // Spare capacity keeps the append from growing storage, which is the
        // only way this path could allocate.
        e.mov(r3, 0, mem | r0, (char*)&obj.array_size - (char*)&obj, jit::SLJIT_MOV_U32);
        out.guard(jit::SLJIT_GREATER_EQUAL, r1, 0, r3, 0, pc);
        out.guard(jit::SLJIT_GREATER_EQUAL, r1, 0, imm, 0x1000000, pc);
        e.op(jit::SLJIT_SHL, r3, r1, 0, imm, 3);
        e.op(jit::SLJIT_ADD, r2, r2, 0, r3, 0);
        // The slot must be a hole: a present value would have to be released,
        // and a hole keeps the hole count in step with a plain increment.
        e.mov(r3, 0, mem | r2, 0);
        e.op(jit::SLJIT_LSHR, r3, r3, 0, imm, 48);
        out.guard(jit::SLJIT_NOT_EQUAL, r3, 0, imm, (long)types::TAG_UNDEFINED, pc);
        // A new index runs OrdinarySet, which must consult the prototype
        // chain. The heap's clean-chain sentinel is null as soon as any
        // prototype could intercept an index.
        e.mov(r3, 0, mem | jit::reg_s(1), function_cold_offset(0));
        e.mov(r3, 0, mem | r3, (char*)&heap_view.index_clean_proto - (char*)&heap_view);
        out.guard(jit::SLJIT_EQUAL, r3, 0, imm, 0, pc);
        e.mov(r1, 0, mem | r0, (char*)&base_view.prototype - (char*)&base_view);
        out.guard(jit::SLJIT_NOT_EQUAL, r1, 0, r3, 0, pc);
        if (out.flow != null) out.flow.heap_write();
        self.slot_store(r0, r2, 0, (uint)ins.b + 2, pc);
        // The store may have clobbered every scratch register, so the receiver
        // comes back from its slot: a live TVal, whose payload is the object.
        out.load(receiver, r0);
        e.op(jit::SLJIT_AND, r0, r0, 0, imm, (long)types::NANBOX_PAYLOAD_MASK);
        e.mov(r1, 0, mem | r0, (char*)&obj.array_used - (char*)&obj, jit::SLJIT_MOV_U32);
        e.op(jit::SLJIT_ADD, r1, r1, 0, imm, 1);
        e.mov(mem | r0, (char*)&obj.array_used - (char*)&obj, r1, 0, jit::SLJIT_MOV_U32);
        e.mov(r1, 0, mem | r0, len_offset, jit::SLJIT_MOV_U32);
        e.op(jit::SLJIT_ADD, r1, r1, 0, imm, 1);
        e.mov(mem | r0, len_offset, r1, 0, jit::SLJIT_MOV_U32);
        e.mov(r0, 0, r1, 0);
    } else {
        out.guard(jit::SLJIT_LESS_EQUAL, r1, 0, imm, 0, pc);
        e.op(jit::SLJIT_SUB, r1, r1, 0, imm, 1);
        e.mov(r3, 0, mem | r0, (char*)&obj.array_size - (char*)&obj, jit::SLJIT_MOV_U32);
        out.guard(jit::SLJIT_GREATER_EQUAL, r1, 0, r3, 0, pc);
        e.op(jit::SLJIT_SHL, r3, r1, 0, imm, 3);
        e.op(jit::SLJIT_ADD, r3, r2, 0, r3, 0);
        // A hole is not undefined: [[Get]] would continue up the prototype
        // chain, which this path cannot answer. Strings are reference counted
        // and need a release pair, so they stay with the interpreter.
        e.mov(r0, 0, mem | r3, 0);
        e.op(jit::SLJIT_LSHR, r2, r0, 0, imm, 48);
        void* element_object = e.cmp(jit::SLJIT_EQUAL, r2, 0, imm, (long)types::TAG_OBJECT);
        out.guard(jit::SLJIT_GREATER, r2, 0, imm, (long)types::TAG_BOOLEAN, pc);
        e.bind(element_object);
        out.guard(jit::SLJIT_EQUAL, r2, 0, imm, (long)types::TAG_UNDEFINED, pc);
        if (out.flow != null) out.flow.heap_write();
        self.store(ins.a, pc, true);
        // The element moved into its result register, so the slot keeps no
        // reference: clear it, step the hole count back and shorten the array.
        out.load(receiver, r0);
        e.op(jit::SLJIT_AND, r0, r0, 0, imm, (long)types::NANBOX_PAYLOAD_MASK);
        self.dense_elements(r0, r2, r3, pc);
        e.mov(r1, 0, mem | r0, len_offset, jit::SLJIT_MOV_U32);
        e.op(jit::SLJIT_SUB, r1, r1, 0, imm, 1);
        e.mov(mem | r0, len_offset, r1, 0, jit::SLJIT_MOV_U32);
        e.mov(r3, 0, mem | r0, (char*)&obj.array_used - (char*)&obj, jit::SLJIT_MOV_U32);
        void* unused = e.cmp(jit::SLJIT_LESS_EQUAL, r3, 0, imm, 0);
        e.op(jit::SLJIT_SUB, r3, r3, 0, imm, 1);
        e.mov(mem | r0, (char*)&obj.array_used - (char*)&obj, r3, 0, jit::SLJIT_MOV_U32);
        e.bind(unused);
        TVal hole;
        hole.set_undefined();
        e.mov(r3, 0, imm, (long)loop_bits(hole));
        e.op(jit::SLJIT_SHL, r1, r1, 0, imm, 3);
        e.op(jit::SLJIT_ADD, r2, r2, 0, r1, 0);
        e.mov(mem | r2, 0, r3, 0);
        return;
    }
    out.box(r0);
    self.store(ins.a, pc, true);
    self.typed_count(4);
}
