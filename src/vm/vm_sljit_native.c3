module boomkat::vm;

import boomkat::bytecode;
import boomkat::types;
import boomkat::heap;
import boomkat::hobject;
import boomkat::hstring;
import boomkat::env;
import boomkat::jit;

fn bool function_read_op(Opcode op) @feat(SLJIT) {
    return op == Opcode.GETPROPC || op == Opcode.GETPROPC_CACHED || op == Opcode.GETTHISC;
}

// Only the named data-property portion of these classes is ordinary. Keep
// lazy function fields and array length/indices with their exotic handlers.
fn bool native_data_object(HObject* object, HString* key, Heap* h) @feat(SLJIT) @inline {
    if (object == null || object.is_proxy() || object.flags.exotic_arguments
        || object.flags.exotic_stringobj || object.flags.exotic_module_ns
        || object.flags.exotic_deferred_ns) return false;
    switch (object.get_class()) {
        case OBJECT: return !object.flags.exotic_array;
        case ARRAY: return !key.flags.is_arridx && key != h.str(heap::BuiltinStr.LENGTH);
        case FUNCTION:
            return key != h.str(heap::BuiltinStr.LENGTH) && key != h.str(heap::BuiltinStr.NAME)
                && key != h.str(heap::BuiltinStr.PROTOTYPE) && key != h.str(heap::BuiltinStr.ARGUMENTS)
                && !key.equals("caller");
        default: return false;
    }
}

// An ordinary data read may miss a compiled shape hypothesis without ending
// the native run. This helper never invokes accessors, allocates or mutates
// objects. Anything with observable slow semantics escapes before the read.
fn long sljit_native_read(ColdCtx* cold, uint offset) @feat(SLJIT) @noinline {
    Instruction ins = cold.vm.current_func.code[offset];
    TVal* regs = cold.act.bottom;
    TVal base = ins.op == Opcode.GETTHISC ? cold.act.this_binding : regs[ins.b];
    HString* key = cold.vm.current_func.constants[ins.c].get_heapptr();
    if (key == null) return 0;
    HObject* object;
    if (base.is_object()) {
        object = base.get_heapptr();
    } else {
        HString* string = plain_string_of(&base);
        if (string == null || key.flags.is_arridx) return 0;
        if (key == cold.heap.str(heap::BuiltinStr.LENGTH)) {
            TVal* dest = regs + ins.a;
            if (!th_can_release(dest)) return 0;
            uint length = string.char_length();
            th_do_release(dest);
            dest.set_fastint(length);
            return 1;
        }
        object = cold.heap.string_proto;
    }
    if (!native_data_object(object, key, cold.heap)) return 0;
    HObject* receiver = object;
    bool cacheable = receiver.mega_cacheable(key, cold.heap);
    PropValue* slot;
    ICEntry* ic = (ICEntry*)cold.vm.current_func.ic_entries + offset;
    // Own slots remain usable on dictionary objects, even when the emitter
    // cannot embed that layout. Read current storage after validating the
    // site's generation, rather than searching the shape on every miss.
    if (ic.key.borrow() == key && ic.shape_id == receiver.shape_id
        && ic.shape_gen == receiver.shape_generation(cold.heap)
        && !ic.has_proto && !ic.prop_flags.is_accessor && ic.prop_idx < receiver.prop_count) {
        slot = &receiver.prop_values()[ic.prop_idx];
    }
    if (slot == null && cacheable) {
        MegamorphicEntry* entry;
        slot = hobject::mega_cache_lookup(cold.heap, receiver, key, &entry);
        if (slot != null && (entry.is_accessor || (entry.proto != null
            && !native_data_object((HObject*)entry.proto, key, cold.heap)))) return 0;
    }
    if (slot == null) for (uint depth = 0; object != null && depth < 64; depth++, object = object.prototype) {
        if (!native_data_object(object, key, cold.heap)) return 0;
        PropFlags flags;
        int index = function_shape_slot(object.get_shape(cold.heap), key, &flags);
        if (index < 0) continue;
        if (flags.is_accessor) return 0;
        slot = &object.prop_values()[index];
        // Reuse the bounded shared cache, including its shape-recycle and
        // prototype checks. Do not retarget a site's IC: existing generated
        // code may still embed the owners that entry keeps alive.
        if (cacheable) hobject::mega_cache_store(cold.heap, receiver, key, object, index, false);
        break;
    }
    if (slot == null) return 0;
    TVal value = slot.get();
    TVal* dest = regs + ins.a;
    if (!th_can_publish(cold.heap, value) || !th_can_release(dest)) return 0;
    th_do_retain(&value);
    th_do_release(dest);
    *dest = value;
    if (value.is_heap_allocated()) track_heap_store(cold.act, dest, ins.a);
    return 1;
}

// R0=function object, R1=argument window, R2=result slot, R3=arity plus
// bit 8 for a plain call. S0..S2 remain the caller window, ColdCtx and run.
// This entry uses the body's register/stack context, so it can jump straight
// into that body after publishing an ordinary interpreter-visible frame.
fn void* FunctionEmitter.emit_call_entry(&self, void* body) @feat(SLJIT) {
    CompiledFunction* cf = self.cf;
    if (self.plan.begin != 0 || !cf.call_flags.lean_call || cf.arguments_in_reg()
        || cf.num_formals > 255) return null;
    TemplateEmitter* e = &self.out.e;
    LoopEmitter guards = { .e = *e };
    int r0 = jit::reg_r(0);
    int r1 = jit::reg_r(1);
    int r2 = jit::reg_r(2);
    int r3 = jit::reg_r(3);
    int vm = jit::reg_r(4);
    int act = jit::reg_r(5);
    int regs = jit::reg_s(0);
    int cold = jit::reg_s(1);
    int run = jit::reg_s(2);
    int object = jit::reg_s(3);
    int bottom = jit::reg_s(4);
    int result = jit::reg_s(5);
    int receiver = jit::reg_r(6);
    int mem = jit::SLJIT_MEM;
    int imm = jit::SLJIT_IMM;
    HObject layout;
    TVal undef;
    undef.set_undefined();
    void* entry = e.label();
    if (jit::sljit_emit_enter(e.compiler, jit::SLJIT_ENTER_REG_ARG | jit::enter_keep(3),
            jit::SLJIT_ARGS4WWWW_R, 7 | (6 << 8), 6, 0) != 0) { e.failed = true; return null; }
    e.mov(object, 0, r0, 0);
    e.mov(bottom, 0, r1, 0);
    e.mov(result, 0, r2, 0);
    e.mov(receiver, 0, r3, 0);
    e.mov(r0, 0, imm, (long)self.plan.entries);
    e.mov(r0, 0, mem | r0, 0);
    guards.guard(jit::SLJIT_EQUAL, r0, 0, imm, 0, 0);
    e.op(jit::SLJIT_AND, r0, r3, 0, imm, 255);
    // Exact arity lets the entry clear locals without a runtime loop. Other
    // arities retain the normal interpreter entry, including surplus args.
    guards.guard(jit::SLJIT_NOT_EQUAL, r0, 0, imm, cf.num_formals, 0);
    e.mov(r0, 0, mem | run, $reflect(FunctionRun.budget).offset);
    guards.guard(jit::SLJIT_LESS_EQUAL, r0, 0, imm, 1, 0);
    e.mov(r0, 0, mem | run, $reflect(FunctionRun.depth).offset, jit::SLJIT_MOV_U32);
    guards.guard(jit::SLJIT_GREATER_EQUAL, r0, 0, imm, 64, 0);
    e.mov(r3, 0, mem | cold, $reflect(ColdCtx.heap).offset);
    e.mov(r0, 0, mem | r3, $reflect(Heap.gc_pending).offset, jit::SLJIT_MOV_U8);
    guards.guard(jit::SLJIT_NOT_EQUAL, r0, 0, imm, 0, 0);
    e.mov(r0, 0, mem | r3, $reflect(Heap.realm).offset);
    guards.guard(jit::SLJIT_NOT_EQUAL, r0, 0, imm, (long)cf.realm, 0);
    e.mov(r2, 0, imm, (long)self.plan);
    e.mov(r0, 0, mem | r3, $reflect(Heap.shape_gen_clock).offset, jit::SLJIT_MOV_U32);
    e.mov(r1, 0, mem | r2, $reflect(FunctionPlan.shape_clock).offset, jit::SLJIT_MOV_U32);
    guards.guard(jit::SLJIT_NOT_EQUAL, r0, 0, r1, 0, 0);
    e.mov(r0, 0, mem | r3, $reflect(Heap.shape_recycle_epoch).offset, jit::SLJIT_MOV_U32);
    e.mov(r1, 0, mem | r2, $reflect(FunctionPlan.shape_epoch).offset, jit::SLJIT_MOV_U32);
    guards.guard(jit::SLJIT_NOT_EQUAL, r0, 0, r1, 0, 0);
    e.mov(vm, 0, mem | cold, $reflect(ColdCtx.vm).offset);
    e.mov(r0, 0, mem | vm, $reflect(Vm.activation_count).offset, jit::SLJIT_MOV_U32);
    e.mov(r1, 0, mem | vm, $reflect(Vm.activation_capacity).offset, jit::SLJIT_MOV_U32);
    guards.guard(jit::SLJIT_GREATER_EQUAL, r0, 0, r1, 0, 0);
    e.op(jit::SLJIT_ADD, r0, bottom, 0, imm, loop_value_offset(cf.num_regs + FRAME_SCRATCH_SLOTS));
    e.mov(r1, 0, mem | vm, $reflect(Vm.valstack_end).offset);
    guards.guard(jit::SLJIT_GREATER, r0, 0, r1, 0, 0);
    e.mov(r0, 0, mem | object, (char*)&layout.extra.func.var_env - (char*)&layout);
    guards.guard(jit::SLJIT_EQUAL, r0, 0, imm, 0, 0);
    e.mov(r0, 0, mem | object, (char*)&layout.extra.func.lex_env - (char*)&layout);
    void* no_lex = e.cmp(jit::SLJIT_EQUAL, r0, 0, imm, 0);
    e.mov(r1, 0, mem | r0, $reflect(EnvRecord.flags).offset, jit::SLJIT_MOV_U8);
    e.op(jit::SLJIT_AND, r1, r1, 0, imm, 4); // is_with
    guards.guard(jit::SLJIT_NOT_EQUAL, r1, 0, imm, 0, 0);
    e.bind(no_lex);
    if (!cf.call_flags.ignores_this) {
        e.op(jit::SLJIT_AND, r0, receiver, 0, imm, 256);
        void* plain = e.cmp(jit::SLJIT_NOT_EQUAL, r0, 0, imm, 0);
        e.mov(receiver, 0, mem | bottom, -8);
        e.op(jit::SLJIT_LSHR, r0, receiver, 0, imm, 48);
        guards.guard(jit::SLJIT_NOT_EQUAL, r0, 0, imm, (long)types::TAG_OBJECT, 0);
        e.op(jit::SLJIT_AND, r0, receiver, 0, imm, (long)types::NANBOX_PAYLOAD_MASK);
        guards.guard(jit::SLJIT_EQUAL, r0, 0, imm, 0, 0);
        void* method = jit::sljit_emit_jump(e.compiler, jit::SLJIT_JUMP);
        e.bind(plain);
        e.mov(receiver, 0, imm, (long)loop_bits(undef));
        e.bind(method);
    } else {
        e.mov(receiver, 0, imm, (long)loop_bits(undef));
    }
    for (uint i = cf.num_formals; i < cf.num_regs; i++) {
        e.mov(r0, 0, mem | bottom, loop_value_offset(i));
        e.op(jit::SLJIT_LSHR, r0, r0, 0, imm, 48);
        guards.guard(jit::SLJIT_EQUAL, r0, 0, imm, (long)types::TAG_STRING, 0);
    }
    // All refusals precede the first mutation. There are no allocations,
    // callbacks or safepoints between publication and a body side exit.
    $if $feat(SLJIT_ADAPTIVE):
        e.mov(r0, 0, mem | run, $reflect(FunctionRun.clock).offset);
        e.mov(mem, (long)&self.plan.last_use, r0, 0);
    $endif
    e.mov(r0, 0, mem | vm, $reflect(Vm.activation_count).offset, jit::SLJIT_MOV_U32);
    e.op(jit::SLJIT_MUL, r1, r0, 0, imm, Activation::size);
    e.mov(act, 0, mem | vm, $reflect(Vm.activations).offset);
    e.op(jit::SLJIT_ADD, act, act, 0, r1, 0);
    e.op(jit::SLJIT_ADD, r0, r0, 0, imm, 1);
    e.mov(mem | vm, $reflect(Vm.activation_count).offset, r0, 0, jit::SLJIT_MOV_U32);
    e.mov(r2, 0, mem | cold, $reflect(ColdCtx.act).offset);
    e.mov(mem | act, $reflect(Activation.parent).offset, r2, 0);
    e.mov(r0, 0, mem | run, $reflect(FunctionRun.start).offset);
    e.op(jit::SLJIT_ADD, r0, r0, 0, imm, Instruction::size);
    e.mov(mem | r2, $reflect(Activation.curr_pc).offset, r0, 0);
    $if $feat(SLJIT_STATS):
    e.mov(r0, 0, mem | r2, $reflect(Activation.func).offset);
    e.mov(r0, 0, mem | r0, $reflect(CompiledFunction.sljit_function).offset);
    e.mov(r1, 0, mem | r0, $reflect(FunctionPlan.direct_calls).offset);
    e.op(jit::SLJIT_ADD, r1, r1, 0, imm, 1);
    e.mov(mem | r0, $reflect(FunctionPlan.direct_calls).offset, r1, 0);
    $endif
    e.mov(r0, 0, mem | object, (char*)&layout.extra.func.comp_func - (char*)&layout);
    e.mov(mem | act, $reflect(Activation.func).offset, r0, 0);
    e.mov(mem | vm, $reflect(Vm.current_func).offset, r0, 0);
    e.mov(r0, 0, mem | object, (char*)&layout.extra.func.var_env - (char*)&layout);
    e.mov(mem | act, $reflect(Activation.var_env).offset, r0, 0);
    e.mov(r1, 0, mem | object, (char*)&layout.extra.func.lex_env - (char*)&layout);
    void* same_env = e.cmp(jit::SLJIT_EQUAL, r1, 0, imm, 0);
    e.mov(r2, 0, mem | r1, $reflect(EnvRecord.flags).offset, jit::SLJIT_MOV_U8);
    e.op(jit::SLJIT_AND, r2, r2, 0, imm, 1); // is_declarative
    void* object_env = e.cmp(jit::SLJIT_EQUAL, r2, 0, imm, 0);
    e.mov(r0, 0, r1, 0);
    e.bind(same_env);
    e.bind(object_env);
    e.mov(mem | act, $reflect(Activation.lex_env).offset, r0, 0);
    e.mov(mem | act, $reflect(Activation.cat).offset, imm, 0);
    e.mov(mem | act, $reflect(Activation.forin).offset, imm, 0);
    e.mov(mem | act, $reflect(Activation.async_gen_state).offset, imm, 0);
    e.mov(mem | act, $reflect(Activation.async_promise).offset, imm, 0);
    e.mov(mem | act, $reflect(Activation.new_target).offset, imm, 0);
    e.mov(mem | act, $reflect(Activation.curr_pc).offset, imm, (long)cf.code);
    e.mov(mem | act, $reflect(Activation.bottom).offset, bottom, 0);
    e.mov(mem | act, $reflect(Activation.retval).offset, result, 0);
    e.mov(mem | act, $reflect(Activation.flags).offset, imm,
        cf.call_flags.ignores_this ? 0 : ACT_FLAG_THIS_VALID, jit::SLJIT_MOV_U32);
    e.mov(mem | act, $reflect(Activation.heap_reg_count).offset, imm, cf.num_regs, jit::SLJIT_MOV_U32);
    e.mov(mem | act, $reflect(Activation.this_binding).offset, receiver, 0);
    e.op(jit::SLJIT_OR, r0, object, 0, imm, (long)((ulong)types::TAG_OBJECT << 48));
    e.mov(mem | act, $reflect(Activation.tv_func).offset, r0, 0);
    e.mov(r0, 0, mem | vm, $reflect(Vm.valstack_top).offset);
    e.mov(mem | act, $reflect(Activation.caller_valstack_top).offset, r0, 0);
    for (uint i = cf.num_formals; i < cf.num_regs + FRAME_SCRATCH_SLOTS; i++) {
        e.mov(mem | bottom, loop_value_offset(i), imm, (long)loop_bits(undef));
    }
    if (cf.call_flags.rest_length_only) {
        TVal length;
        length.set_fastint(0);
        e.mov(mem | bottom, loop_value_offset(cf.num_formals), imm, (long)loop_bits(length));
    }
    e.op(jit::SLJIT_ADD, r0, bottom, 0, imm, loop_value_offset(cf.num_regs));
    e.mov(mem | vm, $reflect(Vm.valstack_top).offset, r0, 0);
    e.mov(regs, 0, bottom, 0);
    e.mov(mem | vm, $reflect(Vm.valstack_bottom).offset, regs, 0);
    e.mov(mem | cold, $reflect(ColdCtx.act).offset, act, 0);
    e.mov(r0, 0, mem | cold, $reflect(ColdCtx.regs_base_ptr).offset);
    e.mov(mem | r0, 0, regs, 0);
    e.mov(mem | cold, $reflect(ColdCtx.ic_bias).offset, imm, (long)((usz)cf.ic_entries - (usz)cf.code * TH_IC_SCALE));
    e.mov(mem | cold, $reflect(ColdCtx.var_ic_bias).offset, imm, (long)((usz)cf.var_ic_entries - (usz)cf.code * TH_VAR_IC_SCALE));
    e.mov(r0, 0, mem | run, $reflect(FunctionRun.depth).offset, jit::SLJIT_MOV_U32);
    e.op(jit::SLJIT_ADD, r0, r0, 0, imm, 1);
    e.mov(mem | run, $reflect(FunctionRun.depth).offset, r0, 0, jit::SLJIT_MOV_U32);
    e.mov(r0, 0, mem | run, $reflect(FunctionRun.budget).offset);
    e.op(jit::SLJIT_SUB, r0, r0, 0, imm, 1);
    e.mov(mem | run, $reflect(FunctionRun.budget).offset, r0, 0);
    e.mov(mem | run, $reflect(FunctionRun.start).offset, imm, (long)cf.code);
    e.mov(r0, 0, imm, (long)self.plan.entries);
    e.mov(r0, 0, mem | r0, 0);
    e.mov(mem | run, $reflect(FunctionRun.entry).offset, r0, 0);
    FunctionRun state;
    e.mov(mem | run, (char*)&state.typed[0].receiver - (char*)&state, imm, 0);
    e.mov(mem | run, (char*)&state.typed[1].receiver - (char*)&state, imm, 0);
    jit::sljit_set_label(jit::sljit_emit_jump(e.compiler, jit::SLJIT_JUMP), body);
    void* failed = e.label();
    for (uint i = 0; i < guards.link_count; i++) guards.bind_to(guards.link_at(i).jump, failed);
    e.mov(r0, 0, mem | run, $reflect(FunctionRun.start).offset);
    if (jit::sljit_emit_return(e.compiler, jit::SLJIT_MOV, r0, 0) != 0 || guards.e.failed) e.failed = true;
    return entry;
}
