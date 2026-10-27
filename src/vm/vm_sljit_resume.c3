module boomkat::vm;

import boomkat::bytecode;
import boomkat::types;
import boomkat::heap;
import boomkat::hobject;
import boomkat::hstring;
import boomkat::builtins;
import boomkat::jit;

// A nearby string literal selects concatenation, but the helper validates
// the live operands. It never performs observable ToPrimitive coercion.
fn bool function_string_add_candidate(CompiledFunction* cf, uint pc) @feat(SLJIT) {
    Instruction add = cf.code[pc];
    if (add.op != Opcode.ADD) return false;
    for (uint operand = 0; operand < 2; operand++) {
        uint reg = operand == 0 ? add.b : add.c;
        for (uint back = pc; back > 0 && pc - back < 8; back--) {
            Instruction ins = cf.code[back - 1];
            if (loop_target(ins, back - 1) >= 0 || function_call_op(ins.op)) break;
            if (ins.a != reg) continue;
            if (ins.op == Opcode.LDREG) { reg = ins.b; continue; }
            if (ins.op == Opcode.LDCONST && ins.get_bc() < cf.const_count
                && plain_string_of(&cf.constants[ins.get_bc()]) != null) return true;
            break;
        }
    }
    return false;
}

fn bool function_charcode_candidate(CompiledFunction* cf, uint pc) @feat(SLJIT) {
    Instruction call = cf.code[pc];
    if (call.op != Opcode.CALL || call.c != 1 || (uint)call.b + 2 >= cf.num_regs) return false;
    uint reg = call.b;
    for (uint back = pc; back > 0; back--) {
        Instruction ins = cf.code[back - 1];
        if (ins.a != reg) continue;
        if (ins.op == Opcode.LDREG) { reg = ins.b; continue; }
        if ((ins.op != Opcode.GETPROPC && ins.op != Opcode.GETPROPC_CACHED)
            || ins.c >= cf.const_count) return false;
        HString* key = plain_string_of(&cf.constants[ins.c]);
        return key != null && key.equals("charCodeAt");
    }
    return false;
}

fn bool function_alloc_op(Opcode op) @feat(SLJIT) {
    return op == Opcode.NEWOBJ || op == Opcode.NEWOBJ_SHAPE || op == Opcode.NEWARR
        || op == Opcode.NEWARR_CONST || op == Opcode.NEW_OBJ || op == Opcode.INIT_SLOT;
}

// Single-operation continuation contract: 0 means no observable effect, 1
// means completed, 2 means completed and must poll in the interpreter at pc+1.
// These helpers cannot call JS or collect. Allocation only schedules GC; the
// real activations/slots own all roots, and no virtual inline frame is live.
// Layout changes also force an exit before using embedded shape hypotheses.
fn long sljit_native_operation(ColdCtx* cold, uint offset) @feat(SLJIT) @noinline {
    Heap* h = cold.heap;
    CompiledFunction* cf = cold.vm.current_func;
    Instruction* pc = cf.code + offset;
    Instruction ins = *pc;
    TVal* regs = cold.act.bottom;
    TVal* dest = regs + ins.a;
    if (ins.op != Opcode.ADD && !th_can_release(dest)) return 0;
    uint clock = h.shape_gen_clock;
    uint epoch = h.shape_recycle_epoch;
    cold.act.curr_pc = pc;
    HObject* object;
    switch (ins.op) {
        case ADD:
            {
                ConcatStatus status = vm_concat_add(cold.vm, cold.act, dest, regs + ins.b, regs + ins.c,
                    ins.a, pc + 1, cf.code + cf.code_count);
                if (status != ConcatStatus.DONE) return 0;
                return h.gc_pending || clock != h.shape_gen_clock || epoch != h.shape_recycle_epoch ? 2 : 1;
            }
        case INIT_SLOT:
            {
                if (!dest.is_object() || dest.get_heapptr() == null) return 0;
                object = dest.get_heapptr();
                if (object.is_proxy() || object.get_class() != ObjClass.OBJECT
                    || ins.b >= object.prop_count) return 0;
                PropValue* slots = object.prop_values();
                if (slots == null || !slots[ins.b].get().is_undefined()) return 0;
                // Empty fixed-layout slots need neither a lookup nor a
                // release. Use the ordinary ownership/barrier operation;
                // it cannot call JS or collect, including for string values.
                h.store_slot_ref(object, &slots[ins.b], regs + ins.c);
                return h.gc_pending || clock != h.shape_gen_clock || epoch != h.shape_recycle_epoch ? 2 : 1;
            }
        case NEWOBJ:
        case NEWOBJ_SHAPE:
            object = ins.op == Opcode.NEWOBJ_SHAPE ? h.alloc_shaped_object(ins.get_bc()) ?? null
                : h.alloc_plain_object() ?? null;
            if (object == null) return 0;
            object.prototype = h.object_proto;
        case NEWARR:
            object = h.alloc_object(ObjClass.ARRAY, ins.get_bc()) ?? null;
            if (object == null) return 0;
            object.prototype = h.array_proto;
            if (ins.get_bc() > object.array_size) object.grow_array(ins.get_bc(), h);
        case NEWARR_CONST:
            object = h.alloc_constant_array(cf.constants + ins.get_bc()) ?? null;
            if (object == null) return 0;
        case NEW_OBJ:
            {
                TVal callee = regs[ins.b];
                if (!callee.is_object() || callee.get_heapptr() == null) return 0;
                HObject* ctor = callee.get_heapptr();
                if (!ctor.is_callable() || !ctor.is_constructable()
                    || ctor.callable_kind() != CallableKind.COMPILED_FN) return 0;
                CompiledFunction* target = ctor.extra.func.comp_func;
                if (target == null || !target.call_flags.simple_constructor || target.realm != h.realm
                    || target.is_arrow() || target.is_derived_ctor()
                    || target.brand_name_hstr != null || target.field_init_func != null) return 0;
                ICEntry* ic = (ICEntry*)cf.ic_entries + offset;
                if (ic.key.borrow() != (void*)h.strs[heap::BuiltinStr.PROTOTYPE] || ic.has_proto
                    || ic.shape_id != ctor.shape_id || ic.shape_gen != ctor.shape_generation(h)
                    || ic.prop_flags.is_accessor || ic.prop_idx >= ctor.prop_count) return 0;
                TVal proto = ctor.prop_values()[ic.prop_idx].get();
                if (!proto.is_object() || proto.get_heapptr() == null) return 0;
                object = h.alloc_plain_object() ?? null;
                if (object == null) return 0;
                h.set_prototype(object, proto.get_heapptr());
                if (!init_simple_constructor(cold.vm, target, object, regs + ins.b + 2, ins.c)) return 0;
            }
        case CALL:
            {
                if (ins.c != 1) return 0;
                TVal callee = regs[ins.b];
                int index = -1;
                if (callee.is_lightfunc()) { index = (int)(usz)callee.get_heapptr(); }
                else if (callee.is_object() && callee.get_heapptr() != null) {
                    HObject* function = callee.get_heapptr();
                    if (function.is_callable() && function.callable_kind() == CallableKind.BUILTIN_FN) {
                        index = function.extra.func.builtin_fn_index;
                    }
                }
                if (index == (int)builtins::Builtin.STRING_PROTO_CHARCODEAT.ordinal) {
                    HString* string = plain_string_of(regs + ins.b + 1);
                    TVal position = regs[ins.b + 2];
                    if (string == null || !position.is_fastint()) return 0;
                    long at = position.get_fastint();
                    TVal value;
                    if (at < 0 || at >= string.char_length()) { value.set_number(double::nan); }
                    else { value.set_fastint(string.char_at_unchecked((uint)at)); }
                    th_do_release(dest);
                    *dest = value;
                    return 1;
                }
                if (index != (int)builtins::Builtin.ARRAY_PROTO_PUSH.ordinal) return 0;
                TVal receiver = regs[ins.b + 1];
                TVal value = regs[ins.b + 2];
                if (!receiver.is_object() || receiver.get_heapptr() == null || value.is_undefined()) return 0;
                object = receiver.get_heapptr();
                if (object.is_proxy() || object.get_class() != ObjClass.ARRAY || object.prop_count != 0
                    || !object.flags.extensible || !object.flags.array_len_writable
                    || object.flags.has_indexed_named_prop || h.index_clean_proto == null
                    || object.prototype != h.index_clean_proto) return 0;
                uint length = *object.array_len_ptr();
                if (length >= 0x1000000) return 0;
                if (length < object.array_size && !object.array_part()[length].get().is_undefined()) return 0;
                if (!object.set_array_idx(length, value, h)) return 0;
                *object.array_len_ptr() = length + 1;
                th_do_release(dest);
                dest.set_fastint((long)length + 1);
                $if $feat(SLJIT_STATS):
                    ((FunctionPlan*)cf.sljit_function).resumed_pushes++;
                    h.jit_resumed_pushes++;
                $endif
                return h.gc_pending || clock != h.shape_gen_clock || epoch != h.shape_recycle_epoch ? 2 : 1;
            }
        default: return 0;
    }
    th_do_release(dest);
    dest.set_object(object);
    track_heap_store(cold.act, dest, ins.a);
    $if $feat(SLJIT_STATS): ((FunctionPlan*)cf.sljit_function).resumed_allocations++; $endif
    return h.gc_pending || clock != h.shape_gen_clock || epoch != h.shape_recycle_epoch ? 2 : 1;
}

fn void FunctionEmitter.allocating_operation(&self, uint pc) @feat(SLJIT) {
    self.flow_materialize();
    TemplateEmitter* e = &self.out.e;
    if (!sljit_resume_fragment(self.plan)) { e.failed = true; return; }
    int r0 = jit::reg_r(0);
    int r1 = jit::reg_r(1);
    int imm = jit::SLJIT_IMM;
    e.mov(r0, 0, jit::reg_s(1), 0);
    e.mov(r1, 0, imm, (long)(self.plan.begin + pc));
    e.mov(jit::SLJIT_MEM | jit::reg_s(2), $reflect(FunctionRun.helper_pc).offset,
        imm, (long)(self.cf.code + pc));
    void* continuation = jit::sljit_emit_op_addr(e.compiler, 0,
        jit::SLJIT_MEM | jit::reg_s(2), $reflect(FunctionRun.helper_continuation).offset);
    if (continuation == null || jit::sljit_emit_ijump(e.compiler, jit::SLJIT_JUMP,
            imm, (long)self.plan.resume_fragment) != 0) { e.failed = true; return; }
    jit::sljit_set_label(continuation, e.label());
    self.flow_reload(pc + 1);
}

// A separately compiled fragment inherits the body's complete register/stack
// context. It owns no frame: success jumps to the compiled continuation;
// refusal/completed-poll unwind the existing body to the appropriate VM PC.
fn bool sljit_resume_fragment(FunctionPlan* plan) @feat(SLJIT) {
    if (plan.resume_fragment != null) return true;
    TemplateEmitter emitter = { .compiler = jit::sljit_create_compiler(null) };
    TemplateEmitter* e = &emitter;
    if (e.compiler == null) return false;
    defer jit::sljit_free_compiler(e.compiler);
    if (jit::sljit_set_context(e.compiler, jit::SLJIT_ENTER_REG_ARG | jit::enter_keep(3),
            1, 7 | (6 << 8), 6, 0) != 0) return false;
    int r0 = jit::reg_r(0);
    int r1 = jit::reg_r(1);
    int imm = jit::SLJIT_IMM;
    int mem = jit::SLJIT_MEM;
    if (jit::sljit_emit_icall(e.compiler, jit::SLJIT_CALL, jit::SLJIT_ARGS2WWW,
            imm, (long)&sljit_native_operation) != 0) return false;
    void* completed = e.cmp(jit::SLJIT_EQUAL, r0, 0, imm, 1);
    e.mov(r1, 0, mem | jit::reg_s(2), $reflect(FunctionRun.helper_pc).offset);
    void* refused = e.cmp(jit::SLJIT_EQUAL, r0, 0, imm, 0);
    e.op(jit::SLJIT_ADD, r1, r1, 0, imm, Instruction::size);
    e.bind(refused);
    if (jit::sljit_emit_return(e.compiler, jit::SLJIT_MOV, r1, 0) != 0) return false;
    e.bind(completed);
    e.mov(r0, 0, mem | jit::reg_s(2), $reflect(FunctionRun.helper_continuation).offset);
    if (jit::sljit_emit_ijump(e.compiler, jit::SLJIT_JUMP, r0, 0) != 0 || e.failed) return false;
    plan.resume_fragment = jit::sljit_generate_code(e.compiler, 0, null);
    if (plan.resume_fragment == null) return false;
    plan.resume_bytes = jit::sljit_shim_code_size(e.compiler);
    return true;
}
