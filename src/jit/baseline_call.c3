// Baseline tier: native calls and returns published in generated code.
//
// Every function the threaded handlers would enter as a lean call gets a
// second native entry, its call entry (BaselineCode.call_entry), which runs in
// its caller's native frame (Asm.set_frame) with the window, the result slot
// and the packed count in R1 to R3. It tests what th_lean_target, @lean_gate
// and the method shape test, then publishes the callee's Activation field for
// field as th_publish_lean does, with the callee's constants (code, register
// count, cache biases) baked in, records the call site's return address in
// Activation.native_ret and runs the body from its first instruction. A
// refusal returns JIT_CALL_SLOW to the site before anything is written.
//
// A CALL or CALL_UNDEF_THIS site loads the callee's call entry through the
// function object, tests the receiver as @lean_call_method does and jumps to
// the entry. JIT_CALL_SLOW takes the helper path (vm::jit_call), which covers
// every other callee and shape; BASELINE_RETURNED, the callee's return, makes
// the caller current again (the resume subroutine).
//
// RET and RETUNDEF pop the frame inline in th_leaf_return's plain case (emit_return_body) and
// return to native_ret with the result in R1: a frame a call entry pushed to its call site, which
// stores the result, and a frame C entered to the trampoline, the pop storing the result. Anything
// else calls vm::jit_ret, which returns there too when it pops the frame, having stored the result.
module boomkat::jit @feat(SLJIT);

import boomkat::vm;
import boomkat::bytecode;
import boomkat::heap;
import boomkat::types;
import boomkat::hobject;
import boomkat::env;
import boomkat::builtins;
import boomkat::hstring;

// Bits of a call entry's packed argument above the argument count: the call
// passes an undefined receiver (CALL_UNDEF_THIS), or a method call's receiver
// is not a heap value.
const long CALL_PLAIN = 1L << 16;
const long CALL_PRIM = 1L << 17;
// A call site's packed bit for a method call (CALL), cleared for the entry.
const long CALL_METHOD = 1L << 18;
// A NEW_OBJ of a constructor whose entry takes one (entry_constructs): the receiver slot holds the
// new object (emit_new_inline), which the frame takes as `this` with ACT_FLAG_CONSTRUCT and the
// function as new.target.
const long CALL_CONSTRUCT = 1L << 19;

// Whether `f`'s call entry takes a construction: a plain constructor that reads its `this`. One
// that never does builds nothing worth a path of its own, and its entry tests no receiver.
fn bool entry_constructs(CompiledFunction* f) {
    return f.plain_constructor() && !f.call_flags.ignores_this;
}

// Formals a call entry clears for a call that passes fewer arguments; a callee
// with more takes such calls through the helper.
const uint ENTRY_MISSING_MAX = 8;

// Whether the call entry of `f` takes a call with `nargs` arguments, plain or of a method on an
// object, as its tests of the count and the receiver kind would: a site that proved its callee
// and this enters at the entry's direct label, which skips those tests and the realm's.
fn bool entry_takes(CompiledFunction* f, uint nargs, bool plain) {
    uint nf = f.num_formals;
    if (f.call_flags.rest_length_only ? nargs != nf : (nf > ENTRY_MISSING_MAX && nargs < nf)) return false;
    if (entry_forwards(f) && nargs > nf + bytecode::FORWARD_ARGS_PAD) return false;
    return !plain || entry_plain(f);
}

// Whether the call entry of `f` takes a call with an undefined receiver, as a lean call or one
// that creates the function's scope (CompiledFunction.env_call_ok) would.
fn bool entry_plain(CompiledFunction* f) @inline {
    return f.call_flags.lean_plain || f.env_call_ok(true);
}


struct CallLayout {
    long ds_vm;
    long ds_heap;
    long act_parent;
    long act_var_env;
    long act_cat;
    long act_forin;
    long act_async_gen_state;
    long act_async_promise;
    long act_new_target;
    long act_curr_pc;
    long act_bottom;
    long act_retval;
    long act_flags;
    long act_serial;
    long act_caller_top;
    long act_native_ret;
    long ds_jit_waiter;
    long vm_storage;
    long vm_valstack_top;
    long vm_valstack_end;
    long heap_realm;
    long heap_gc_pending;
    long heap_gc_call_budget;
    long heap_gc_full_requested;
    long fn_var_env;
    long fn_lex_env;
    long fn_builtin;
    long cf_jit_code;
    long cf_func_index;
    long ic_prop_idx;
    long ic_feedback;
    long[hobject::IC_CALL_TARGETS] ic_call_slot;
    long cf_num_regs;
    long bc_call_entry;
    long bc_direct_entry;
    long bc_reg_entry;
    long env_flags;
    long fn_mask;
    long fn_want;
}

CallLayout call_layout_data @private;
bool call_layout_ready @private;

// Whether the call entry of `f` keeps the arguments in the frame's first
// registers for APPLY_ARGS, as bind_register_arguments leaves them.
fn bool entry_forwards(CompiledFunction* f) @inline {
    return f.call_flags.forward_args && f.num_args == f.num_formals
        && f.arguments_reg == (uint)f.num_formals + bytecode::FORWARD_ARGS_PAD;
}

// Whether the call entry of `f` makes its arguments object (jit_entry_arguments): a register
// `arguments` past the formals, which a forwarding function keeps as the count instead.
fn bool entry_builds_arguments(CompiledFunction* f) @inline {
    return f.arguments_in_reg() && !f.call_flags.forward_args && f.arguments_reg >= f.num_formals;
}

// The arguments object of a call the call entry of its function took (entry_builds_arguments),
// made from the `argc` arguments the frame's window starts with as bind_register_arguments makes
// it on the helper path. The entry cleared the slots past them; those past the formals are the
// body's locals, which start undefined once copied.
fn void jit_entry_arguments(Dispatch* ds, ulong argc) {
    Activation* act = ds.act;
    CompiledFunction* f = (CompiledFunction*)act.func;
    TVal* bottom = act.bottom;
    vm::bind_register_arguments(ds.vm, act, f, (HObject*)bottom[-2].get_heapptr(), bottom, (uint)argc);
    uint end = min((uint)argc, f.num_regs + vm::FRAME_SCRATCH_SLOTS);
    for (uint i = f.num_formals; i < end; i++) {
        if (i != f.arguments_reg) bottom[i].set_undefined();
    }
}

fn CallLayout* call_layout() {
    if (call_layout_ready) return &call_layout_data;
    CallLayout* l = &call_layout_data;
    char* base = (char*)(usz)4096;
    Dispatch* d = (Dispatch*)base;
    Activation* act = (Activation*)base;
    Vm* vm = (Vm*)base;
    Heap* h = (Heap*)base;
    HObject* o = (HObject*)base;
    CompiledFunction* cf = (CompiledFunction*)base;
    BaselineCode* bc = (BaselineCode*)base;
    env::EnvRecord* e = (env::EnvRecord*)base;
    l.ds_vm = (char*)&d.vm - base;
    l.ds_heap = (char*)&d.heap - base;
    l.act_parent = (char*)&act.parent - base;
    l.act_var_env = (char*)&act.var_env - base;
    l.act_cat = (char*)&act.cat - base;
    l.act_forin = (char*)&act.forin - base;
    l.act_async_gen_state = (char*)&act.async_gen_state - base;
    l.act_async_promise = (char*)&act.async_promise - base;
    l.act_new_target = (char*)&act.new_target - base;
    l.act_curr_pc = (char*)&act.curr_pc - base;
    l.act_bottom = (char*)&act.bottom - base;
    l.act_retval = (char*)&act.retval - base;
    l.act_flags = (char*)&act.flags - base;
    l.act_serial = (char*)&act.serial - base;
    l.act_caller_top = (char*)&act.caller_valstack_top - base;
    l.act_native_ret = (char*)&act.native_ret - base;
    l.ds_jit_waiter = (char*)&d.jit_waiter - base;
    l.vm_storage = (char*)&vm.activation_storage - base;
    l.vm_valstack_top = (char*)&vm.valstack_top - base;
    l.vm_valstack_end = (char*)&vm.valstack_end - base;
    l.heap_realm = (char*)&h.realm - base;
    l.heap_gc_pending = (char*)&h.gc_pending - base;
    l.heap_gc_call_budget = (char*)&h.gc_call_budget - base;
    l.heap_gc_full_requested = (char*)&h.gc_full_requested - base;
    l.fn_var_env = (char*)&o.extra.func.var_env - base;
    l.fn_lex_env = (char*)&o.extra.func.lex_env - base;
    l.fn_builtin = (char*)&o.extra.func.builtin_fn_index - base;
    l.cf_jit_code = (char*)&cf.jit_code - base;
    l.cf_func_index = (char*)&cf.func_index - base;
    hobject::ICEntry* ice = (hobject::ICEntry*)base;
    l.ic_prop_idx = (char*)&ice.prop_idx - base;
    l.ic_feedback = (char*)&ice.feedback - base;
    for (uint t = 1; t < hobject::IC_CALL_TARGETS; t++) l.ic_call_slot[t] = (char*)hobject::ic_call_slot(ice, t) - base;
    l.cf_num_regs = (char*)&cf.num_regs - base;
    l.bc_call_entry = (char*)&bc.call_entry - base;
    l.bc_direct_entry = (char*)&bc.direct_entry - base;
    l.bc_reg_entry = (char*)&bc.reg_entry - base;
    l.env_flags = (char*)&e.flags - base;
    // th_lean_target's callable_kind() == COMPILED_FN, narrowed as the
    // inline cache paths narrow objects: a callable, unbound, non-proxy
    // FUNCTION (comp_func and builtin_fn_index are tested after).
    hobject::ObjFlags m;
    m.callable = true;
    m.is_bound = true;
    m.exotic_proxyobj = true;
    l.fn_mask = (long)(uint)m | 0x3FL << 16;
    hobject::ObjFlags w;
    w.callable = true;
    w.obj_class = hobject::ObjClass.FUNCTION;
    l.fn_want = (long)(uint)w;
    call_layout_ready = true;
    return l;
}

// Whether `f` gets a call entry: a lean callee (classify_lean_call), or one that needs only its
// function scope created (env_call_ok), whose frame the entry can publish with plain stores. An
// `arguments` register must be the forwarding kind, which holds the count (CallFlags.forward_args).
// The entry clears the formals a call leaves out by Function.length, so a default value, which
// makes the parameters outnumber it, leaves the call to vm::jit_call.
fn bool call_entry_eligible(CompiledFunction* f) {
    f.classify_lean_call();
    return (f.call_flags.lean_call || f.env_call_ok(false)) && (!f.arguments_in_reg() || entry_forwards(f) || entry_builds_arguments(f)) && f.call_flags.trivial_call == 0
        && (f.num_args == f.num_formals || f.call_flags.rest_length_only)
        && f.ic_entries != null && f.var_ic_entries != null && f.num_formals <= f.num_regs
        && !is_top_level(f);
}

fn void Asm.mov(&self, int dst, long dstw, int src, long srcw, int op = SLJIT_MOV) @inline {
    sljit_emit_op1(self.c, op, dst, dstw, src, srcw);
}

// The call entry of the function being compiled (see the top of this file).
// Emitted after the body; enters the body at its first instruction. `scratches`
// and `locals` are the frame the body was emitted for. With `count_opt` the entry
// counts toward the optimizing tier, considering the function at the threshold
// (jit_entry_service). `touch` marks the code as entered (BaselineCode.touched).
fn void* Asm.emit_call_entry(&self, BaselineCode* bc, bool count_opt = false, bool touch = false) {
    void* c = self.c;
    CompiledFunction* f = self.f;
    CallLayout* k = call_layout();
    Layout* l = self.lay;
    int m = SLJIT_MEM;
    int ds = self.ds;
    // The free saved register and the window's, which the site reloads; the
    // record register keeps the caller's record until nothing declines.
    int bottom = reg_s(2);
    int packed = self.regs;
    int vm = R4 + 1;
    int la = R4 + 2;
    Jumps decline;
    // The call subroutine jumps here, in the caller's native frame, with the callee's window in
    // R1, the result slot in R2 and the packed count in R3. Its return address,
    // the call site's, is at SUB_RET_OFF: the frame returns there (Activation.native_ret), and
    // so does a decline.
    // A call optimized code proved (Asm.emit_direct_call) fast-calls the direct label, past the
    // tests of the realm, the argument count and the receiver kind (entry_takes).
    self.set_frame();
    self.direct_label = sljit_emit_label(c);
    sljit_emit_op_dst(c, SLJIT_FAST_ENTER, SLJIT_MEM | reg_sp(), SUB_RET_OFF);
    self.mov(bottom, 0, R1, 0);
    self.mov(packed, 0, R3, 0);
    Jumps proven;
    proven.add(sljit_emit_jump(c, SLJIT_JUMP));
    // A register call (OptCg.emit_call_reg) fast-calls the register label with the direct label's
    // arguments: the same path on a native frame of its own, whose return address its record
    // returns through (Trampoline.reg_ret pops the frame), as does a decline. The frame must lie
    // above the floor jit_enter set.
    if (REG_CALLS) {
        self.reg_label = sljit_emit_label(c);
        sljit_emit_op_dst(c, SLJIT_FAST_ENTER, R0, 0);
        sljit_shim_adjust_sp(c, -REG_FRAME_BYTES);
        self.mov(m | reg_sp(), jit_frame().link_off, R0, 0);
        self.mov(m | reg_sp(), SUB_RET_OFF, SLJIT_IMM, (long)(usz)trampoline().reg_ret);
        self.mov(bottom, 0, R1, 0);
        self.mov(packed, 0, R3, 0);
        sljit_get_local_base(c, R0, 0, 0);
        decline.add(sljit_emit_cmp(c, SLJIT_LESS, R0, 0, m | ds, l.ds_reg_floor));
        proven.add(sljit_emit_jump(c, SLJIT_JUMP));
    }
    void* entry = sljit_emit_label(c);
    self.mov(bottom, 0, R1, 0);
    self.mov(packed, 0, R3, 0);

    // th_lean_target, @lean_gate and the receiver test, before any write.
    self.mov(R1, 0, m | self.heap, k.heap_realm);
    decline.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R1, 0, SLJIT_IMM, (long)(usz)f.realm));
    // Any argument count, as th_publish_lean takes it: surplus arguments are
    // ignored, missing formals start undefined (cleared below, unrolled up to
    // ENTRY_MISSING_MAX formals). A rest parameter's length needs the count.
    uint nf = f.num_formals;
    if (f.call_flags.rest_length_only || nf > ENTRY_MISSING_MAX) {
        sljit_emit_op2(c, SLJIT_AND, R1, 0, packed, 0, SLJIT_IMM, CALL_PLAIN - 1);
        decline.add(sljit_emit_cmp(c, f.call_flags.rest_length_only ? SLJIT_NOT_EQUAL : SLJIT_LESS, R1, 0, SLJIT_IMM, nf));
    }
    // More arguments than the registers reserved for them take the arguments object.
    bool forwards = entry_forwards(f);
    uint kept = forwards ? nf + bytecode::FORWARD_ARGS_PAD : nf;
    if (forwards) {
        sljit_emit_op2(c, SLJIT_AND, R1, 0, packed, 0, SLJIT_IMM, CALL_PLAIN - 1);
        decline.add(sljit_emit_cmp(c, SLJIT_GREATER, R1, 0, SLJIT_IMM, kept));
    }
    long forbidden = (f.call_flags.ignores_this ? 0 : CALL_PRIM) | (entry_plain(f) ? 0 : CALL_PLAIN);
    if (forbidden != 0) {
        sljit_emit_op2(c, SLJIT_AND, R1, 0, packed, 0, SLJIT_IMM, forbidden);
        decline.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R1, 0, SLJIT_IMM, 0));
    }
    proven.bind(sljit_emit_label(c));
    // The record after the caller's, which takes the result slot (R2) once there is room for it.
    self.mov(vm, 0, m | ds, k.ds_vm);
    sljit_emit_op2(c, SLJIT_ADD, la, 0, self.la, 0, SLJIT_IMM, (long)Activation::size);
    decline.add(self.emit_record_room(la, vm, R1));
    self.mov(m | la, k.act_retval, R2, 0);
    // publish_frame_top clears the scratch slots up to valstack_end; the
    // entry requires them all inside it, and the slots of the inlined bodies.
    uint clear_end = f.num_regs + vm::FRAME_SCRATCH_SLOTS;
    sljit_emit_op2(c, SLJIT_ADD, R1, 0, bottom, 0, SLJIT_IMM, (long)max(clear_end, self.room_slots) * TVal::size);
    decline.add(sljit_emit_cmp(c, SLJIT_GREATER, R1, 0, m | vm, k.vm_valstack_end));
    // A function that needs a scope of its own gets it in the record now, the last test before
    // anything the caller would see is written (vm::jit_entry_scope); the call clobbers the
    // record's and the VM's registers.
    bool own_env = f.flags.needs_env;
    if (own_env) {
        self.mov(R1, 0, m | bottom, -2 * (long)TVal::size);
        sljit_emit_op2(c, SLJIT_XOR, R1, 0, R1, 0, k_obj_op(), k_obj_w());
        self.mov(R2, 0, la, 0);
        self.mov(R0, 0, ds, 0);
        sljit_emit_icall(c, SLJIT_CALL, SLJIT_ARGS3WWW, SLJIT_IMM, (long)(usz)&vm::jit_entry_scope);
        decline.add(sljit_emit_cmp(c, SLJIT_EQUAL, R0, 0, SLJIT_IMM, 0));
        self.mov(vm, 0, m | ds, k.ds_vm);
        sljit_emit_op2(c, SLJIT_ADD, la, 0, self.la, 0, SLJIT_IMM, (long)Activation::size);
    }
    // th_publish_lean; the caller has tested the function's scope (emit_scope_test). Constants
    // the stores share are kept in registers once they are free: U (packed) undefined, C (R2)
    // the code.
    if (kept != 0 && !f.call_flags.rest_length_only) {
        sljit_emit_op2(c, SLJIT_AND, R4, 0, packed, 0, SLJIT_IMM, CALL_PLAIN - 1);
        void* all_given = sljit_emit_cmp(c, SLJIT_GREATER_EQUAL, R4, 0, SLJIT_IMM, kept);
        for (uint i = 0; i < kept; i++) {
            void* given = sljit_emit_cmp(c, SLJIT_GREATER, R4, 0, SLJIT_IMM, i);
            self.mov(m | bottom, (long)i * TVal::size, SLJIT_IMM, K_UNDEF);
            sljit_set_label(given, sljit_emit_label(c));
        }
        sljit_set_label(all_given, sljit_emit_label(c));
    }
    // The `arguments` register of a forwarding function is the count.
    if (forwards) {
        sljit_emit_op2(c, SLJIT_AND, R4, 0, packed, 0, SLJIT_IMM, CALL_PLAIN - 1);
        sljit_emit_op2(c, SLJIT_OR, R4, 0, R4, 0, k_int_op(), k_int_w());
        self.mov(m | bottom, (long)f.arguments_reg * TVal::size, R4, 0);
    }
    self.mov(R4, 0, SLJIT_MEM | reg_sp(), SUB_RET_OFF);
    self.mov(m | la, k.act_native_ret, R4, 0);
    // The rest of the record waits for vm::jit_fill (ACT_FLAG_LAZY), but for what the body reads
    // itself: the scope (lex_env = cap unless cap is null, the env itself or not declarative), and
    // the function (capture records).
    if (self.reads_env || self.reads_callee) self.mov(R3, 0, m | bottom, -2 * (long)TVal::size);
    if (self.reads_callee) {
        self.mov(m | la, l.act_tv_func, R3, 0);
        self.mov(m | la, l.act_func, SLJIT_IMM, (long)(usz)f);
    }
    if (own_env) {
        self.mov(m | la, k.act_parent, self.la, 0);
    } else if (self.reads_env) {
        sljit_emit_op2(c, SLJIT_XOR, R3, 0, R3, 0, k_obj_op(), k_obj_w());
        self.mov(R2, 0, m | R3, k.fn_var_env);
        self.mov(R1, 0, m | R3, k.fn_lex_env);
        self.emit_entry_env(la);
    }
    int undef = packed;
    int code = R2;
    // The count jit_entry_arguments takes, kept past the reuse of its register.
    bool builds = entry_builds_arguments(f);
    if (builds) sljit_emit_op2(c, SLJIT_AND, vm, 0, packed, 0, SLJIT_IMM, CALL_PLAIN - 1);
    bool takes_this = !f.call_flags.ignores_this;
    if (takes_this) sljit_emit_op2(c, SLJIT_AND, R4, 0, packed, 0, SLJIT_IMM, CALL_PLAIN | CALL_PRIM | CALL_CONSTRUCT);
    self.mov(undef, 0, SLJIT_IMM, K_UNDEF);
    self.mov(code, 0, SLJIT_IMM, (long)(usz)f.code);
    // A lazy record, and a heap_reg_count over the whole frame (Asm.frame_regs), in one word.
    self.store_entry_flags(la, vm::ACT_FLAG_JIT_CALLED | vm::ACT_FLAG_LAZY);
    self.store_pair(la, k.act_curr_pc, code, k.act_bottom, bottom);
    self.mov(m | la, l.act_this, undef, 0);
    // A method call (R4 is 0) takes the receiver slot's value as `this`; so does a construction,
    // whose new.target, the function, jit_fill writes.
    if (takes_this) {
        Jumps bound;
        if (!entry_constructs(f)) {
            bound.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R4, 0, SLJIT_IMM, 0));
        } else {
            void* method = sljit_emit_cmp(c, SLJIT_EQUAL, R4, 0, SLJIT_IMM, 0);
            bound.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R4, 0, SLJIT_IMM, CALL_CONSTRUCT));
            self.mov(R4, 0, SLJIT_IMM, vm::ACT_FLAG_CONSTRUCT);
            sljit_set_label(method, sljit_emit_label(c));
        }
        self.mov(R1, 0, m | bottom, -(long)TVal::size);
        self.mov(m | la, l.act_this, R1, 0);
        sljit_emit_op2(c, SLJIT_OR, R1, 0, R4, 0, SLJIT_IMM, vm::ACT_FLAG_THIS_VALID | vm::ACT_FLAG_JIT_CALLED | vm::ACT_FLAG_LAZY);
        self.mov(m | la, k.act_flags, R1, 0, SLJIT_MOV_U32);
        bound.bind(sljit_emit_label(c));
    }
    // Locals and the scratch slots start undefined, surplus arguments included
    // unless they are kept for forwarding.
    uint from = forwards ? f.arguments_reg + 1 : f.num_formals;
    if (builds) {
        // The surplus arguments wait for jit_entry_arguments: the slots past them, or past the
        // formals, are cleared from a start known at run time. R1 keeps the count for the call.
        self.mov(R1, 0, vm, 0);
        self.mov(R4, 0, vm, 0);
        void* past = sljit_emit_cmp(c, SLJIT_GREATER_EQUAL, R4, 0, SLJIT_IMM, from);
        self.mov(R4, 0, SLJIT_IMM, from);
        sljit_set_label(past, sljit_emit_label(c));
        void* top = sljit_emit_label(c);
        void* done = sljit_emit_cmp(c, SLJIT_GREATER_EQUAL, R4, 0, SLJIT_IMM, clear_end);
        self.mov(mem_index(bottom, R4), 3, SLJIT_IMM, K_UNDEF);
        sljit_emit_op2(c, SLJIT_ADD, R4, 0, R4, 0, SLJIT_IMM, 1);
        sljit_set_label(sljit_emit_jump(c, SLJIT_JUMP), top);
        sljit_set_label(done, sljit_emit_label(c));
    } else {
        self.mov(R2, 0, undef, 0);
        self.clear_slots(bottom, from, clear_end, undef, R2, R4, R1);
    }
    if (f.call_flags.rest_length_only) self.mov(m | bottom, (long)from * TVal::size, k_int_op(), k_int_w());
    // The VM's frame state, the value stack's top included, waits for vm::jit_sync. The body's record and window
    // registers; the heap and thunk table registers are the caller's.
    self.mov(self.la, 0, la, 0);
    self.mov(self.regs, 0, bottom, 0);
    if (builds) {
        self.mov(m | ds, self.pc_off, SLJIT_IMM, (long)(usz)f.code);
        self.mov(R0, 0, ds, 0);
        self.c_call(SLJIT_ARGS2WWW, SLJIT_IMM, (long)(usz)&jit_entry_arguments);
    }
    // Optimized code records the entry for the eviction sweep (opt_make_room).
    if (touch) self.mov(m, (long)(usz)&bc.touched, SLJIT_IMM, 1, SLJIT_MOV_U8);
    // The count toward optimizing the function and the call-time safepoint run in the frame, so
    // that neither declines the call: a declined call from optimized code leaves that code.
    Jumps service;
    if (count_opt) {
        self.mov(R4, 0, SLJIT_IMM, (long)(usz)&f.opt_entries);
        self.mov(R0, 0, m | R4, 0, SLJIT_MOV_U32);
        sljit_emit_op2(c, SLJIT_ADD, R0, 0, R0, 0, SLJIT_IMM, 1);
        self.mov(m | R4, 0, R0, 0, SLJIT_MOV_U32);
        service.add(sljit_emit_cmp(c, SLJIT_GREATER_EQUAL, R0, 0, SLJIT_IMM, OPT_ENTRY_THRESHOLD));
    }
    self.mov(R1, 0, m | self.heap, k.heap_gc_pending, SLJIT_MOV_U8);
    void* pending = sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R1, 0, SLJIT_IMM, 0);
    void* body = sljit_emit_label(c);
    sljit_set_label(sljit_emit_jump(c, SLJIT_JUMP), self.labels[0]);
    // Heap.safepoint_gc_on_call's countdown, inline unless it expires or a full collection waits.
    sljit_set_label(pending, sljit_emit_label(c));
    if (!$feat(GC_STRESS)) {
        self.mov(R1, 0, m | self.heap, k.heap_gc_call_budget, SLJIT_MOV_U32);
        service.add(sljit_emit_cmp(c, SLJIT_LESS_EQUAL, R1, 0, SLJIT_IMM, 1));
        self.mov(R2, 0, m | self.heap, k.heap_gc_full_requested, SLJIT_MOV_U8);
        service.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R2, 0, SLJIT_IMM, 0));
        sljit_emit_op2(c, SLJIT_SUB, R1, 0, R1, 0, SLJIT_IMM, 1);
        self.mov(m | self.heap, k.heap_gc_call_budget, R1, 0, SLJIT_MOV_U32);
        sljit_set_label(sljit_emit_jump(c, SLJIT_JUMP), body);
    }
    service.bind(sljit_emit_label(c));
    self.mov(m | ds, self.pc_off, SLJIT_IMM, (long)(usz)f.code);
    self.mov(R0, 0, ds, 0);
    self.c_call(SLJIT_ARGS1WW, SLJIT_IMM, (long)(usz)&jit_entry_service);
    sljit_set_label(sljit_emit_jump(c, SLJIT_JUMP), body);

    decline.bind(sljit_emit_label(c));
    self.mov(R0, 0, SLJIT_IMM, vm::JIT_CALL_SLOW);
    sljit_emit_op_src(c, SLJIT_FAST_RETURN, SLJIT_MEM | reg_sp(), SUB_RET_OFF);
    return entry;
}

// The service a call entry runs in the frame it pushed (Asm.emit_call_entry): the count toward
// optimizing the function at its threshold, and the call-time safepoint while a collection waits.
fn void jit_entry_service(Dispatch* ds) {
    CompiledFunction* f = (CompiledFunction*)ds.act.func;
    if (f.opt_entries >= OPT_ENTRY_THRESHOLD) opt_note_entry(ds.heap, f, ds.act, 0);
    ds.heap.safepoint_gc_on_call();
}

// Slots [from, end) of the window at `base` set to undefined, which `u1` and
// `u2` both hold. `cur`, which may be `base`, and `lim` are scratch.
fn void Asm.clear_slots(&self, int base, uint from, uint end, int u1, int u2, int cur, int lim) {
    void* c = self.c;
    // The extent is static: pairs, then the possible odd slot.
    uint pair_end = end - ((end - from) & 1);
    if (end - from <= 12) {
        for (uint i = from; i < pair_end; i += 2) {
            self.store_pair(base, (long)i * TVal::size, u1, (long)(i + 1) * TVal::size, u2);
        }
        if (pair_end < end) self.mov(SLJIT_MEM | base, (long)pair_end * TVal::size, u1, 0);
        return;
    }
    sljit_emit_op2(c, SLJIT_ADD, lim, 0, base, 0, SLJIT_IMM, (long)pair_end * TVal::size);
    sljit_emit_op2(c, SLJIT_ADD, cur, 0, base, 0, SLJIT_IMM, (long)from * TVal::size);
    void* loop = sljit_emit_label(c);
    self.store_pair(cur, 0, u1, TVal::size, u2);
    sljit_emit_op2(c, SLJIT_ADD, cur, 0, cur, 0, SLJIT_IMM, 2 * TVal::size);
    sljit_set_label(sljit_emit_cmp(c, SLJIT_LESS, cur, 0, lim, 0), loop);
    if (pair_end < end) self.mov(SLJIT_MEM | cur, 0, u1, 0);
}

// The jump taken unless the activation storage has room for the record at `rec` and the
// inlined bodies' records above it (room_acts). `vm` holds ds.vm; clobbers `tmp`. The limit is
// rounded down to a multiple of 4096, which a comparison takes as an immediate on every target:
// the last few records are left to the helper path, which pushes up to MAX_CALLS.
fn void* Asm.emit_record_room(&self, int rec, int vm, int tmp) {
    sljit_emit_op2(self.c, SLJIT_SUB, tmp, 0, rec, 0, vm, 0);
    long last = call_layout().vm_storage + (long)(vm::MAX_CALLS - 1 - self.room_acts) * Activation::size;
    return sljit_emit_cmp(self.c, SLJIT_GREATER, tmp, 0, SLJIT_IMM, last & ~4095L);
}

// th_lean_target's test of the scope of the function object `fun`: a variable scope, and a
// captured scope that is not a `with` object's. Anything else joins `fail`. Clobbers `tmp`.
fn void Asm.emit_scope_test(&self, int fun, int tmp, Jumps* fail) {
    void* c = self.c;
    CallLayout* k = call_layout();
    int m = SLJIT_MEM;
    self.mov(tmp, 0, m | fun, k.fn_var_env);
    fail.add(sljit_emit_cmp(c, SLJIT_EQUAL, tmp, 0, SLJIT_IMM, 0));
    self.mov(tmp, 0, m | fun, k.fn_lex_env);
    void* no_cap = sljit_emit_cmp(c, SLJIT_EQUAL, tmp, 0, SLJIT_IMM, 0);
    env::EnvFlags with_flag;
    with_flag.is_with = true;
    self.mov(tmp, 0, m | tmp, k.env_flags, SLJIT_MOV_U8);
    sljit_emit_op2(c, SLJIT_AND, tmp, 0, tmp, 0, SLJIT_IMM, (long)(char)with_flag);
    fail.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, tmp, 0, SLJIT_IMM, 0));
    sljit_set_label(no_cap, sljit_emit_label(c));
}

// The scope of the record at `la`, for a body that reads it (Asm.reads_env): its parent, the
// record register's, var_env from R2 and lex_env from the closure's in R1, unless that is null or
// not declarative. Clobbers R1 and R4.
fn void Asm.emit_entry_env(&self, int la) {
    void* c = self.c;
    CallLayout* k = call_layout();
    int m = SLJIT_MEM;
    self.store_pair(la, k.act_parent, self.la, k.act_var_env, R2);
    env::EnvFlags decl_flag;
    decl_flag.is_declarative = true;
    Jumps use_env;
    use_env.add(sljit_emit_cmp(c, SLJIT_EQUAL, R1, 0, SLJIT_IMM, 0));
    self.mov(R4, 0, m | R1, k.env_flags, SLJIT_MOV_U8);
    sljit_emit_op2(c, SLJIT_AND, R4, 0, R4, 0, SLJIT_IMM, (long)(char)decl_flag);
    use_env.add(sljit_emit_cmp(c, SLJIT_EQUAL, R4, 0, SLJIT_IMM, 0));
    void* lex_done = sljit_emit_jump(c, SLJIT_JUMP);
    use_env.bind(sljit_emit_label(c));
    self.mov(R1, 0, R2, 0);
    sljit_set_label(lex_done, sljit_emit_label(c));
    self.mov(m | la, self.lay.act_lex_env, R1, 0);
}

// Store `flags` and a heap_reg_count over the whole frame (Asm.frame_regs) in the record at `la`:
// one word when the count follows the flags in memory.
fn void Asm.store_entry_flags(&self, int la, uint flags) {
    CallLayout* k = call_layout();
    int m = SLJIT_MEM;
    if (!std::core::env::BIG_ENDIAN && self.lay.act_hrc == k.act_flags + 4) {
        self.mov(m | la, k.act_flags, SLJIT_IMM, (long)((ulong)self.f.num_regs << 32 | flags));
        return;
    }
    self.mov(m | la, k.act_flags, SLJIT_IMM, flags, SLJIT_MOV_U32);
    self.mov(m | la, self.lay.act_hrc, SLJIT_IMM, self.f.num_regs, SLJIT_MOV_U32);
}

// Store `r1` at base + off1 and `r2` at base + off2, as one pair move when
// the two words are adjacent.
fn void Asm.store_pair(&self, int base, long off1, int r1, long off2, int r2) {
    if (off2 == off1 + 8) {
        sljit_emit_mem(self.c, SLJIT_MOV | SLJIT_MEM_STORE, r1 | (r2 << 8), SLJIT_MEM | base, off1);
    } else if (off1 == off2 + 8) {
        sljit_emit_mem(self.c, SLJIT_MOV | SLJIT_MEM_STORE, r2 | (r1 << 8), SLJIT_MEM | base, off2);
    } else {
        self.mov(SLJIT_MEM | base, off1, r1, 0);
        self.mov(SLJIT_MEM | base, off2, r2, 0);
    }
}

// A CALL, CALL_UNDEF_THIS, CALL_GLOBAL or NEW_OBJ called directly through its callee's
// call entry (see the top of this file), by the shared call subroutine. `generic`
// collects the path that takes the helper call (vm::jit_call) instead.
fn void Asm.emit_direct_call(&self, Jumps* generic) {
    void* c = self.c;
    bool global = self.w.op == Opcode.CALL_GLOBAL || self.w.op == Opcode.CALL_VAR;
    bool construct = self.w.op == Opcode.NEW_OBJ;
    uint callee = global ? self.w.a : self.w.b;
    uint nargs = global ? self.w.b : self.w.c;
    long packed = (long)nargs | (construct ? CALL_CONSTRUCT : self.w.op == Opcode.CALL ? CALL_METHOD : CALL_PLAIN);
    // A cold site names no function number, so the subroutine's comparison with
    // the callee's cannot match before the feedback is recorded. A NEW_OBJ's entry
    // caches the constructor's prototype instead.
    if (self.f.ic_entries != null && !construct) {
        hobject::ICEntry* ic = &((hobject::ICEntry*)self.f.ic_entries)[self.i];
        if ((ic.feedback & hobject::FB_CALL) == 0) ic.prop_idx = hobject::IC_PROP_ABSENT;
    }
    // A plain call's receiver is undefined, as th_publish_lean's clear_this makes it.
    if ((packed & CALL_PLAIN) != 0) self.store(callee + 1, SLJIT_IMM, K_UNDEF);
    self.mov(R3, 0, SLJIT_IMM, packed);
    self.emit_call_sub(callee, self.w.a, self.next, generic);
}

// The call of the function in register `callee`, R3 its packed count and kind, through the shared
// call subroutine, or the direct label of the callee optimized code proved (direct_cf): the result
// into register `result`, the frame resuming at instruction `resume`. `generic` collects a call
// the callee did not take, which has done nothing.
fn void Asm.emit_call_sub(&self, uint callee, uint result, uint resume, Jumps* generic) {
    void* c = self.c;
    sljit_emit_op2(c, SLJIT_ADD, R1, 0, self.regs, 0, SLJIT_IMM, (long)(callee + 2) * TVal::size);
    sljit_emit_op2(c, SLJIT_ADD, R2, 0, self.regs, 0, SLJIT_IMM, (long)result * TVal::size);
    self.mov(R4, 0, SLJIT_IMM, (long)(usz)(self.f.code + resume));
    self.direct_called = true;
    void* proven = null;
    if (self.direct_cf != null) {
        // Optimized code proved the callee and the call's shape (OptBuild.direct_callee): into the
        // direct label of the callee's code as it stands, which the subroutine would reach after
        // its tests. Code without one takes the subroutine.
        CallLayout* k = call_layout();
        self.mov(SLJIT_MEM | self.la, k.act_curr_pc, R4, 0);
        self.mov(R0, 0, SLJIT_MEM, (long)(usz)&self.direct_cf.jit_code);
        void* no_code = sljit_emit_cmp(c, SLJIT_EQUAL, R0, 0, SLJIT_IMM, 0);
        self.mov(R0, 0, SLJIT_MEM | R0, k.bc_direct_entry);
        void* no_entry = sljit_emit_cmp(c, SLJIT_EQUAL, R0, 0, SLJIT_IMM, 0);
        sljit_emit_ijump(c, SLJIT_FAST_CALL, R0, 0);
        proven = sljit_emit_jump(c, SLJIT_JUMP);
        void* sub = sljit_emit_label(c);
        sljit_set_label(no_code, sub);
        sljit_set_label(no_entry, sub);
    }
    self.subs.push({ .jump = sljit_emit_jump(c, SLJIT_FAST_CALL), .sub = CALL_SUB });
    if (proven != null) sljit_set_label(proven, sljit_emit_label(c));
    // The callee's frame returned here (Activation.native_ret).
    void* returned = sljit_emit_cmp(c, SLJIT_EQUAL, R0, 0, SLJIT_IMM, BASELINE_RETURNED);
    // A declining call entry has used the window register.
    void* entered = sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R0, 0, SLJIT_IMM, vm::JIT_CALL_SLOW);
    self.mov(self.regs, 0, SLJIT_MEM | self.la, call_layout().act_bottom);
    generic.add(sljit_emit_jump(c, SLJIT_JUMP));
    sljit_set_label(entered, sljit_emit_label(c));
    // A builtin the subroutine completed.
    sljit_set_label(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R0, 0, SLJIT_IMM, 0), self.nonzero);
    void* done = sljit_emit_jump(c, SLJIT_JUMP);
    // The return left the caller's record in the record register and the result in R1, whose
    // store the subroutine has cleared as Asm.publish would.
    sljit_set_label(returned, sljit_emit_label(c));
    self.mov(self.regs, 0, SLJIT_MEM | self.la, call_layout().act_bottom);
    self.store(result, R1);
    self.track_heap_store(result);
    sljit_set_label(done, sljit_emit_label(c));
    self.count(&self.stats.fast_hits[0], self.w.op);
}

// Whether the APPLY_ARGS being emitted is the `f.apply(x, arguments)` of a forwarding function,
// fused with the CALL_S after it as OptBuild's forward_pair reads them, for emit_forward_call.
// Baseline code only, which can continue past the CALL_S.
fn bool Asm.forward_site(&self) {
    CompiledFunction* f = self.f;
    if (self.opt || self.w.op != Opcode.APPLY_ARGS || !f.call_flags.forward_args || !f.arguments_in_reg()
        || f.ic_entries == null || self.next >= f.code_count) return false;
    Instruction call = f.code[self.next];
    return self.w.b == self.w.a && call.op == Opcode.CALL_S && (uint)call.a == self.w.a
        && (uint)call.b == self.w.a && (uint)call.c == self.w.c;
}

// The forwarding call of a forward_site, as @apply_args makes it: the function above `apply`'s
// register called as a method of the object above that, with the arguments the frame keeps in its
// first registers (vm::bind_register_arguments) and their count in the CALL_S's count register,
// through the shared call subroutine; then on past the CALL_S. What @apply_args refuses takes
// `generic` with nothing changed. A callee the subroutine does not enter leaves the registers as
// the CALL_S takes them, and continues there.
fn void Asm.emit_forward_call(&self, Jumps* generic) {
    void* c = self.c;
    CallLayout* k = call_layout();
    Layout* l = self.lay;
    int m = SLJIT_MEM;
    uint callee = self.w.a;
    uint kept = (uint)self.f.num_args + bytecode::FORWARD_ARGS_PAD;
    long apply = (long)builtins::Builtin.FUNCTION_PROTO_APPLY.ordinal;
    // Function.prototype.apply, a lightfunc or a builtin function object (builtins::is_intrinsic_apply).
    self.load(R0, callee);
    sljit_emit_op2(c, SLJIT_XOR, R1, 0, R0, 0, SLJIT_IMM, K_LIGHTFUNC);
    void* not_light = sljit_emit_cmp(c, SLJIT_GREATER_EQUAL, R1, 0, span_op(), span_w());
    generic.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL | SLJIT_32, R1, 0, SLJIT_IMM, apply));
    void* is_apply = sljit_emit_jump(c, SLJIT_JUMP);
    sljit_set_label(not_light, sljit_emit_label(c));
    sljit_emit_op2(c, SLJIT_XOR, R0, 0, R0, 0, k_obj_op(), k_obj_w());
    generic.add(sljit_emit_cmp(c, SLJIT_GREATER_EQUAL, R0, 0, span_op(), span_w()));
    generic.add(sljit_emit_cmp(c, SLJIT_EQUAL, R0, 0, SLJIT_IMM, 0));
    self.mov(R1, 0, m | R0, 0, SLJIT_MOV_U32);
    sljit_emit_op2(c, SLJIT_AND, R1, 0, R1, 0, SLJIT_IMM, k.fn_mask);
    generic.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R1, 0, SLJIT_IMM, k.fn_want));
    self.mov(R1, 0, m | R0, k.fn_builtin, SLJIT_MOV_S32);
    generic.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R1, 0, SLJIT_IMM, apply));
    sljit_set_label(is_apply, sljit_emit_label(c));
    // The count the arguments register holds in place of an arguments object, at most `kept`.
    self.load(R0, self.f.arguments_reg);
    sljit_emit_op2(c, SLJIT_XOR, R0, 0, R0, 0, k_int_op(), k_int_w());
    generic.add(sljit_emit_cmp(c, SLJIT_GREATER, R0, 0, SLJIT_IMM, kept));
    // The receiver, an object: one @apply_args drops for a callee that ignores it takes `generic`.
    self.load(R0, callee + 2);
    sljit_emit_op2(c, SLJIT_XOR, R0, 0, R0, 0, k_obj_op(), k_obj_w());
    generic.add(sljit_emit_cmp(c, SLJIT_GREATER_EQUAL, R0, 0, span_op(), span_w()));
    generic.add(sljit_emit_cmp(c, SLJIT_EQUAL, R0, 0, SLJIT_IMM, 0));
    // The moves are plain stores, as @apply_args makes them, with nothing to mark (th_can_publish).
    self.mov(R0, 0, m | self.heap, l.heap_gc_phase, SLJIT_MOV_U8);
    generic.add(sljit_emit_cmp(c, SLJIT_EQUAL, R0, 0, SLJIT_IMM, (long)heap::GcPhase.MARK.ordinal));
    // The window the arguments move to, inside the value stack.
    self.mov(R1, 0, m | self.ds, k.ds_vm);
    sljit_emit_op2(c, SLJIT_ADD, R0, 0, self.regs, 0, SLJIT_IMM, (long)(callee + 2 + kept) * TVal::size);
    generic.add(sljit_emit_cmp(c, SLJIT_GREATER, R0, 0, m | R1, k.vm_valstack_end));
    // The callee notes for the optimizing tier (vm::jit_note_forward).
    self.mov(R0, 0, m | self.ds, k.ds_vm);
    self.mov(R1, 0, self.la, 0);
    self.mov(R2, 0, SLJIT_IMM, (long)(usz)(self.f.code + self.next + 1));
    sljit_emit_icall(c, SLJIT_CALL, SLJIT_ARGS3WWW, SLJIT_IMM, (long)(usz)&vm::jit_note_forward);
    // The function and the receiver one register down, the arguments into the window above them
    // (its first slot undefined when there are none), and the count where the CALL_S reads it.
    self.load(R0, callee + 1);
    self.store(callee, R0);
    self.load(R0, callee + 2);
    self.store(callee + 1, R0);
    self.store(callee + 2, SLJIT_IMM, K_UNDEF);
    self.load(R4, self.f.arguments_reg);
    sljit_emit_op2(c, SLJIT_XOR, R4, 0, R4, 0, k_int_op(), k_int_w());
    Jumps moved;
    for (uint i = 0; i < kept; i++) {
        moved.add(sljit_emit_cmp(c, SLJIT_LESS_EQUAL, R4, 0, SLJIT_IMM, i));
        self.load(R0, i);
        self.store(callee + 2 + i, R0);
    }
    moved.bind(sljit_emit_label(c));
    if (callee + 2 + kept > self.frame_regs) {
        // The frame's heap-register watermark covers the window, as track_heap_store raises it.
        sljit_emit_op2(c, SLJIT_ADD, R0, 0, R4, 0, SLJIT_IMM, (long)(callee + 2));
        self.mov(R1, 0, m | self.la, l.act_hrc, SLJIT_MOV_U32);
        void* covered = sljit_emit_cmp(c, SLJIT_GREATER_EQUAL, R1, 0, R0, 0);
        self.mov(m | self.la, l.act_hrc, R0, 0, SLJIT_MOV_U32);
        sljit_set_label(covered, sljit_emit_label(c));
    }
    sljit_emit_op2(c, SLJIT_OR, R0, 0, R4, 0, k_int_op(), k_int_w());
    self.store(self.w.c, R0);
    sljit_emit_op2(c, SLJIT_OR, R3, 0, R4, 0, SLJIT_IMM, CALL_METHOD);
    Jumps declined;
    self.emit_call_sub(callee, callee, self.next + 1, &declined);
    self.go(sljit_emit_jump(c, SLJIT_JUMP), self.next + 1);
    for (uint j = 0; j < declined.len; j++) self.go(declined.at[j], self.next);
}

// Whether the CALL being emitted reads as `x.charCodeAt(i)`: one argument and
// a callee register a GETPROPC of that key loaded a few instructions before.
// Only a hint for emitting the inline path; the path tests the callee itself.
fn bool Asm.charcodeat_site(&self) {
    if (self.wide || self.w.op != Opcode.CALL || self.w.c != 1 || self.w.b + 2 >= self.f.num_regs) return false;
    if (!self.consts_fixed) return false;
    for (uint back = 1; back <= 8 && back <= self.i; back++) {
        Instruction p = self.f.code[self.i - back];
        if (p.op != Opcode.GETPROPC && p.op != Opcode.GETPROPC_CACHED) continue;
        if (p.a != self.w.b) continue;
        if (p.c >= self.f.const_count || !self.f.constants[p.c].is_string()) return false;
        hstring::HString* key = (hstring::HString*)self.f.constants[p.c].get_heapptr();
        return !key.is_symbol() && key.latin1() == "charCodeAt";
    }
    return false;
}

// `x.charCodeAt(i)` for a string primitive `x` whose units are its inline
// bytes and a fastint in range, as th_call_native completes it, without
// entering the call machinery.
// `miss` collects every other case, which nothing was written for.
fn void Asm.emit_charcodeat(&self, Jumps* miss) {
    void* c = self.c;
    CallLayout* k = call_layout();
    Layout* l = self.lay;
    int m = SLJIT_MEM;
    uint rb = self.w.b;
    self.load(R0, rb);
    sljit_emit_op2(c, SLJIT_XOR, R0, 0, R0, 0, k_obj_op(), k_obj_w());
    miss.add(sljit_emit_cmp(c, SLJIT_GREATER_EQUAL, R0, 0, span_op(), span_w()));
    miss.add(sljit_emit_cmp(c, SLJIT_EQUAL, R0, 0, SLJIT_IMM, 0));
    self.mov(R1, 0, m | R0, 0, SLJIT_MOV_U32);
    sljit_emit_op2(c, SLJIT_AND, R1, 0, R1, 0, SLJIT_IMM, k.fn_mask);
    miss.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R1, 0, SLJIT_IMM, k.fn_want));
    self.mov(R1, 0, m | R0, k.fn_builtin, SLJIT_MOV_S32);
    miss.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R1, 0, SLJIT_IMM, (long)builtins::Builtin.STRING_PROTO_CHARCODEAT.ordinal));
    self.load(R1, rb + 1);
    sljit_emit_op2(c, SLJIT_XOR, R1, 0, R1, 0, SLJIT_IMM, K_STRING_START);
    miss.add(sljit_emit_cmp(c, SLJIT_GREATER_EQUAL, R1, 0, span_op(), span_w()));
    self.mov(R2, 0, m | R1, 0, SLJIT_MOV_U32);
    sljit_emit_op2(c, SLJIT_AND, R2, 0, R2, 0, SLJIT_IMM, l.byte_units_mask);
    miss.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R2, 0, SLJIT_IMM, 0));
    self.load(R3, rb + 2);
    sljit_emit_op2(c, SLJIT_ASHR, R0, 0, R3, 0, SLJIT_IMM, 48);
    miss.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R0, 0, SLJIT_IMM, STAG_INT));
    sljit_emit_op2(c, SLJIT_SHL, R3, 0, R3, 0, SLJIT_IMM, 16);
    sljit_emit_op2(c, SLJIT_ASHR, R3, 0, R3, 0, SLJIT_IMM, 16);
    self.mov(R2, 0, m | R1, l.str_length, SLJIT_MOV_U32);
    miss.add(sljit_emit_cmp(c, SLJIT_GREATER_EQUAL, R3, 0, R2, 0));
    sljit_emit_op2(c, SLJIT_ADD, R1, 0, R1, 0, R3, 0);
    sljit_emit_op1(c, SLJIT_MOV_U8, R0, 0, m | R1, (long)hstring::HSTRING_HDR_SIZE);
    sljit_emit_op2(c, SLJIT_OR, R0, 0, R0, 0, k_int_op(), k_int_w());
    self.store(self.w.a, R0);
}

// Record the callee in R4 (its CompiledFunction) as the call feedback of the
// site that is calling through the subroutine, as hobject::ic_note_callee does
// for the calls the threaded handlers make. The site's cache is addressed from
// the resume point kept on the stack. A site that already named this callee
// costs one comparison. Keeps R1-R4; clobbers R0.
fn void Asm.emit_note_callee(&self) {
    if (self.f.ic_entries == null || self.opt) return;
    void* c = self.c;
    CallLayout* k = call_layout();
    Layout* l = self.lay;
    int m = SLJIT_MEM;
    // The cache of the call instruction before the resume point.
    self.mov(R0, 0, m | self.la, k.act_curr_pc);
    usz scale = vm::TH_IC_SCALE;
    if ((scale & (scale - 1)) == 0) {
        long shift = 0;
        while ((1uL << shift) < scale) shift++;
        sljit_emit_op2(c, SLJIT_SHL, R0, 0, R0, 0, SLJIT_IMM, shift);
    } else {
        sljit_emit_op2(c, SLJIT_MUL, R0, 0, R0, 0, SLJIT_IMM, (long)scale);
    }
    sljit_emit_op2(c, SLJIT_ADD, R0, 0, R0, 0, SLJIT_IMM,
                   (long)((usz)self.f.ic_entries - ((usz)self.f.code + Instruction::size) * scale));
    Jumps known;
    known.add(sljit_emit_cmp(c, SLJIT_EQUAL | SLJIT_32, m | R0, k.ic_prop_idx, m | R4, k.cf_func_index));
    // A NEW_OBJ's entry caches the constructor's prototype, and its site records the constructor.
    sljit_emit_op2u(c, SLJIT_AND | SLJIT_SET_Z, R3, 0, SLJIT_IMM, CALL_CONSTRUCT);
    known.add(sljit_emit_jump(c, SLJIT_NOT_EQUAL));
    // R0 = the cache. The test of FB_CALL and the stores use R4, which is
    // rebuilt from the function slot at the end.
    self.mov(R4, 0, m | R0, k.ic_feedback, SLJIT_MOV_U8);
    sljit_emit_op2(c, SLJIT_AND, R4, 0, R4, 0, SLJIT_IMM, hobject::FB_CALL);
    void* another = sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R4, 0, SLJIT_IMM, 0);
    self.emit_callee_cf(R4);
    self.mov(R4, 0, m | R4, k.cf_func_index, SLJIT_MOV_U32);
    self.mov(m | R0, k.ic_prop_idx, R4, 0, SLJIT_MOV_U32);
    self.mov(R4, 0, m | R0, k.ic_feedback, SLJIT_MOV_U8);
    sljit_emit_op2(c, SLJIT_OR, R4, 0, R4, 0, SLJIT_IMM, hobject::FB_CALL);
    void* stored = sljit_emit_jump(c, SLJIT_JUMP);
    // Another function: its number plus one in the first free further slot, as
    // hobject::ic_note_another does; FB_POLY when they are full, and at once for a
    // site of Function.prototype.call (FB_DOTCALL). Nothing for a site that is FB_POLY.
    sljit_set_label(another, sljit_emit_label(c));
    self.mov(R4, 0, m | R0, k.ic_feedback, SLJIT_MOV_U8);
    sljit_emit_op2u(c, SLJIT_AND | SLJIT_SET_Z, R4, 0, SLJIT_IMM, hobject::FB_POLY);
    void* done = sljit_emit_jump(c, SLJIT_NOT_EQUAL);
    sljit_emit_op2u(c, SLJIT_AND | SLJIT_SET_Z, R4, 0, SLJIT_IMM, hobject::FB_DOTCALL);
    void* dotcall = sljit_emit_jump(c, SLJIT_NOT_EQUAL);
    self.emit_callee_cf(R4);
    self.mov(R4, 0, m | R4, k.cf_func_index, SLJIT_MOV_U32);
    sljit_emit_op2(c, SLJIT_ADD, R4, 0, R4, 0, SLJIT_IMM, 1);
    void*[hobject::IC_CALL_TARGETS * 2] ends;
    uint nends = 0;
    for (uint t = 1; t < hobject::IC_CALL_TARGETS; t++) {
        ends[nends++] = sljit_emit_cmp(c, SLJIT_EQUAL | SLJIT_32, m | R0, k.ic_call_slot[t], R4, 0);
        void* used = sljit_emit_cmp(c, SLJIT_NOT_EQUAL | SLJIT_32, m | R0, k.ic_call_slot[t], SLJIT_IMM, 0);
        self.mov(m | R0, k.ic_call_slot[t], R4, 0, SLJIT_MOV_U32);
        ends[nends++] = sljit_emit_jump(c, SLJIT_JUMP);
        sljit_set_label(used, sljit_emit_label(c));
    }
    sljit_set_label(dotcall, sljit_emit_label(c));
    self.mov(R4, 0, m | R0, k.ic_feedback, SLJIT_MOV_U8);
    sljit_emit_op2(c, SLJIT_OR, R4, 0, R4, 0, SLJIT_IMM, hobject::FB_POLY);
    sljit_set_label(stored, sljit_emit_label(c));
    self.mov(m | R0, k.ic_feedback, R4, 0, SLJIT_MOV_U8);
    void* label = sljit_emit_label(c);
    for (uint j = 0; j < nends; j++) sljit_set_label(ends[j], label);
    sljit_set_label(done, label);
    self.emit_callee_cf(R4);
    known.bind(sljit_emit_label(c));
}

// `reg` = the CompiledFunction of the callee in the window R1 (the subroutine
// has checked that it is a compiled function with a body).
fn void Asm.emit_callee_cf(&self, int reg) {
    self.mov(reg, 0, SLJIT_MEM | R1, -2 * (long)TVal::size);
    sljit_emit_op2(self.c, SLJIT_XOR, reg, 0, reg, 0, k_obj_op(), k_obj_w());
    self.mov(reg, 0, SLJIT_MEM | reg, self.lay.fn_comp_func);
}

// The builtins vm::jit_call_string_regexp runs (vm::string_regexp_kind).
const int[5] STRING_REGEXP_BUILTINS = {
    builtins::Builtin.STRING_PROTO_REPLACE.ordinal, builtins::Builtin.STRING_PROTO_REPLACEALL.ordinal,
    builtins::Builtin.STRING_PROTO_SPLIT.ordinal, builtins::Builtin.STRING_PROTO_MATCH.ordinal,
    builtins::Builtin.STRING_PROTO_SEARCH.ordinal,
};

// The call subroutine. In: R1 the callee's window (the function two slots
// below it, the receiver one below), R2 the result slot, R3 the argument
// count with CALL_METHOD, CALL_PLAIN or CALL_CONSTRUCT, R4 the caller's resume point. Tests
// the callee as th_lean_target does and the receiver as @lean_call_method
// does, and jumps into the callee's call entry, whose frame returns to the
// call site with BASELINE_RETURNED. Out otherwise: R0 = 0 when a builtin
// completed the call, JIT_CALL_SLOW before anything was written, else a status
// for the shared exit.
fn void Asm.emit_call_body(&self) {
    void* c = self.c;
    CallLayout* k = call_layout();
    Layout* l = self.lay;
    int m = SLJIT_MEM;
    int ds = self.ds;
    int sp = SLJIT_MEM | reg_sp();
    Jumps slow;
    Jumps done;
    // The caller's resume point, as th_publish_lean stores it (the slow paths store it too).
    // R2, the result slot, stays for the call entry.
    self.mov(m | self.la, k.act_curr_pc, R4, 0);
    self.mov(R0, 0, m | R1, -2 * (long)TVal::size);
    sljit_emit_op2(c, SLJIT_XOR, R0, 0, R0, 0, k_obj_op(), k_obj_w());
    // A value that is not a heap object still may be a callee: a lightfunc has
    // that shape, so route it to the tag test below instead of to the slow
    // path here.
    void* tagged = sljit_emit_cmp(c, SLJIT_GREATER_EQUAL, R0, 0, span_op(), span_w());
    slow.add(sljit_emit_cmp(c, SLJIT_EQUAL, R0, 0, SLJIT_IMM, 0));
    self.mov(R4, 0, m | R0, 0, SLJIT_MOV_U32);
    sljit_emit_op2(c, SLJIT_AND, R4, 0, R4, 0, SLJIT_IMM, k.fn_mask);
    slow.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R4, 0, SLJIT_IMM, k.fn_want));
    self.mov(R4, 0, m | R0, k.fn_builtin, SLJIT_MOV_S32);
    // A builtin callee of a CALL or CALL_UNDEF_THIS completes here, through
    // vm::jit_call_builtin_native, as the CALL thunk would complete it, and the
    // site continues at its resume point without the thunk. The helper declines
    // every other call shape, and every other callee keeps the slow path.
    void* compiled = sljit_emit_cmp(c, SLJIT_SIG_LESS, R4, 0, SLJIT_IMM, 0);
    // RegExp.prototype.test and exec, adjacent builtin numbers, try
    // vm::jit_call_regexp first, which runs them without the builtin's frame.
    $assert builtins::Builtin.REGEXP_PROTO_EXEC.ordinal == builtins::Builtin.REGEXP_PROTO_TEST.ordinal + 1;
    sljit_emit_op2(c, SLJIT_SUB, R0, 0, R4, 0, SLJIT_IMM, builtins::Builtin.REGEXP_PROTO_TEST.ordinal);
    void* not_regexp = sljit_emit_cmp(c, SLJIT_GREATER, R0, 0, SLJIT_IMM, 1);
    self.mov(R2, 0, R4, 0);
    self.mov(R1, 0, m | self.la, k.act_curr_pc);
    self.mov(R0, 0, ds, 0);
    self.c_call(SLJIT_ARGS3WWW, SLJIT_IMM, (long)(usz)&vm::jit_call_regexp);
    done.add(sljit_emit_cmp(c, SLJIT_EQUAL, R0, 0, SLJIT_IMM, 0));
    void* declined = sljit_emit_jump(c, SLJIT_JUMP);
    sljit_set_label(not_regexp, sljit_emit_label(c));
    // String.prototype.replace, replaceAll, split, match and search with a RegExp try
    // vm::jit_call_string_regexp.
    Jumps string_regexp;
    foreach (b : STRING_REGEXP_BUILTINS) string_regexp.add(sljit_emit_cmp(c, SLJIT_EQUAL, R4, 0, SLJIT_IMM, b));
    void* not_replace = sljit_emit_jump(c, SLJIT_JUMP);
    string_regexp.bind(sljit_emit_label(c));
    self.mov(R2, 0, R4, 0);
    self.mov(R1, 0, m | self.la, k.act_curr_pc);
    self.mov(R0, 0, ds, 0);
    self.c_call(SLJIT_ARGS3WWW, SLJIT_IMM, (long)(usz)&vm::jit_call_string_regexp);
    done.add(sljit_emit_cmp(c, SLJIT_EQUAL, R0, 0, SLJIT_IMM, 0));
    sljit_set_label(not_replace, sljit_emit_label(c));
    sljit_set_label(declined, sljit_emit_label(c));
    self.mov(R1, 0, m | self.la, k.act_curr_pc);
    self.mov(R0, 0, ds, 0);
    self.c_call(SLJIT_ARGS2WWW, SLJIT_IMM, (long)(usz)&vm::jit_call_builtin_native);
    slow.add(sljit_emit_cmp(c, SLJIT_EQUAL, R0, 0, SLJIT_IMM, vm::JIT_CALL_SLOW));
    Jumps leave;
    leave.add(sljit_emit_cmp(c, SLJIT_EQUAL, R0, 0, SLJIT_IMM, BASELINE_RETURNED));
    done.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R0, 0, SLJIT_IMM, 0));
    // The builtin ran: the value stack may have moved, so the window the site
    // continues with is the one ds names now.
    self.mov(self.regs, 0, m | ds, self.regs_off);
    done.add(sljit_emit_jump(c, SLJIT_JUMP));
    sljit_set_label(compiled, sljit_emit_label(c));
    self.emit_scope_test(R0, R4, &slow);
    self.mov(R4, 0, m | R0, l.fn_comp_func);
    slow.add(sljit_emit_cmp(c, SLJIT_EQUAL, R4, 0, SLJIT_IMM, 0));
    self.emit_note_callee();
    self.mov(R4, 0, m | R4, k.cf_jit_code);
    slow.add(sljit_emit_cmp(c, SLJIT_EQUAL, R4, 0, SLJIT_IMM, 0));
    self.mov(R4, 0, m | R4, k.bc_call_entry);
    slow.add(sljit_emit_cmp(c, SLJIT_EQUAL, R4, 0, SLJIT_IMM, 0));
    // A method call's receiver: an object, in a register the caller's frame
    // tracks like all its registers, or a value that is not on the heap (CALL_PRIM).
    sljit_emit_op2(c, SLJIT_AND, R0, 0, R3, 0, SLJIT_IMM, CALL_METHOD);
    void* receiver_done = sljit_emit_cmp(c, SLJIT_EQUAL, R0, 0, SLJIT_IMM, 0);
    self.mov(R0, 0, m | R1, -(long)TVal::size);
    void* heap_value = sljit_emit_cmp(c, SLJIT_GREATER_EQUAL, R0, 0, SLJIT_IMM, K_STRING_START);
    sljit_emit_op2(c, SLJIT_OR, R3, 0, R3, 0, SLJIT_IMM, CALL_PRIM);
    void* prim_done = sljit_emit_jump(c, SLJIT_JUMP);
    sljit_set_label(heap_value, sljit_emit_label(c));
    sljit_emit_op2(c, SLJIT_XOR, R0, 0, R0, 0, k_obj_op(), k_obj_w());
    slow.add(sljit_emit_cmp(c, SLJIT_GREATER_EQUAL, R0, 0, span_op(), span_w()));
    slow.add(sljit_emit_cmp(c, SLJIT_EQUAL, R0, 0, SLJIT_IMM, 0));
    sljit_set_label(receiver_done, sljit_emit_label(c));
    sljit_set_label(prim_done, sljit_emit_label(c));
    // Into the callee's call entry, in this native frame: the callee's frame returns to the call
    // site (Activation.native_ret), and a decline returns JIT_CALL_SLOW there.
    sljit_emit_op2(c, SLJIT_AND, R3, 0, R3, 0, SLJIT_IMM, ~CALL_METHOD);
    sljit_emit_ijump(c, SLJIT_JUMP, R4, 0);
    // A lightfunc callee completes through the same helper:
    // vm::jit_call_builtin_native's th_call_native runs a lightfunc's builtin
    // from its payload index with the receiver slot below it, as the CALL thunk
    // does, and a decline returns JIT_CALL_SLOW having written at most the
    // undefined receiver of a plain call. Any other non-object value keeps the
    // slow path.
    sljit_set_label(tagged, sljit_emit_label(c));
    self.mov(R0, 0, m | R1, -2 * (long)TVal::size);
    sljit_emit_op2(c, SLJIT_XOR, R0, 0, R0, 0, SLJIT_IMM, K_LIGHTFUNC);
    slow.add(sljit_emit_cmp(c, SLJIT_GREATER_EQUAL, R0, 0, span_op(), span_w()));
    self.mov(R1, 0, R4, 0);
    self.mov(R0, 0, ds, 0);
    self.c_call(SLJIT_ARGS2WWW, SLJIT_IMM, (long)(usz)&vm::jit_call_builtin_native);
    slow.add(sljit_emit_cmp(c, SLJIT_EQUAL, R0, 0, SLJIT_IMM, vm::JIT_CALL_SLOW));
    leave.add(sljit_emit_cmp(c, SLJIT_EQUAL, R0, 0, SLJIT_IMM, BASELINE_RETURNED));
    done.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R0, 0, SLJIT_IMM, 0));
    self.mov(self.regs, 0, m | ds, self.regs_off);
    done.add(sljit_emit_jump(c, SLJIT_JUMP));
    // A builtin that returned to the frame a C caller waits for (vm::jit_call): it is the
    // caller's status, not a callee's return to this site.
    leave.bind(sljit_emit_label(c));
    self.emit_leave(R0, 0);
    slow.bind(sljit_emit_label(c));
    self.mov(R0, 0, SLJIT_IMM, vm::JIT_CALL_SLOW);
    done.bind(sljit_emit_label(c));
}

// RET and RETUNDEF: the result in R0 for the shared return subroutine, which
// pops the frame generated code waits for and returns to that code with
// BASELINE_RETURNED, or comes back for vm::jit_ret (`helper`).
fn void Asm.emit_return(&self, Jumps* helper) {
    void* c = self.c;
    if (self.f.maps_formals()) { helper.add(sljit_emit_jump(c, SLJIT_JUMP)); return; }
    if (self.w.op == Opcode.RET) {
        self.load(R0, self.w.a);
    } else {
        self.mov(R0, 0, SLJIT_IMM, K_UNDEF);
    }
    self.subs.push({ .jump = sljit_emit_jump(c, SLJIT_FAST_CALL), .sub = RETURN_SUB });
    // The subroutine's only nonzero status is BASELINE_RETURNED: the frame is gone, the result is
    // in R1, and R2 is the site that stores it.
    helper.add(sljit_emit_cmp(c, SLJIT_EQUAL, R0, 0, SLJIT_IMM, 0));
    self.return_to(R2);
}

// Return to the native_ret in `r`, keeping R0 and R1. The record of a register call returns
// through Trampoline.reg_ret; its frame is popped here instead and the return goes to the call
// itself, the return the processor predicts for its call.
fn void Asm.return_to(&self, int r) {
    void* c = self.c;
    if (REG_CALLS) {
        void* other = sljit_emit_cmp(c, SLJIT_NOT_EQUAL, r, 0, SLJIT_IMM, (long)(usz)trampoline().reg_ret);
        self.mov(r, 0, SLJIT_MEM | reg_sp(), jit_frame().link_off);
        sljit_shim_adjust_sp(c, REG_FRAME_BYTES);
        sljit_set_label(other, sljit_emit_label(c));
    }
    sljit_emit_op_src(c, SLJIT_FAST_RETURN, r, 0);
}

// Whether a frame of `f` can hold a catcher or for-in state (Activation.cat, forin): only TRY and
// INITFOR give it one. Every word is read as an instruction, so an operand word can only add a
// false yes.
fn bool frame_state_possible(CompiledFunction* f) {
    for (uint i = 0; i < f.code_count; i++) {
        Opcode op = f.code[i].op;
        if (op == Opcode.TRY || op == Opcode.INITFOR) return true;
    }
    return false;
}

// The return subroutine: with the result in R0, pop the frame in th_leaf_return's plain case and
// come back with BASELINE_RETURNED, the result in R1 and in R2 where the frame returns to;
// otherwise come back with 0, for vm::jit_ret. The plain case: no catcher or for-in state, no
// flags beyond the lean ones (or a base construction, which answers `this` unless the body
// returned an object), and a value with no heap pointer or an object while the collector is not
// marking. A frame a call entry pushed (ACT_FLAG_JIT_CALLED) returns to its call site, which
// stores the result, and its window keeps its values: the caller tracks its whole window
// (Asm.frame_regs), and every frame pushed above writes all of its own. A frame C entered
// returns to the trampoline (vm::jit_run_entered), the pop storing the result where the frame's
// caller tracks it and clearing the window, as th_leaf_return does.
fn void Asm.emit_return_body(&self) {
    void* c = self.c;
    CallLayout* k = call_layout();
    Layout* l = self.lay;
    int m = SLJIT_MEM;
    int ds = self.ds;
    int sp = SLJIT_MEM | reg_sp();
    long tramp_ret = (long)(usz)trampoline().ret;
    Jumps helper;
    // Null for a frame nothing waits for, which then carries no ACT_FLAG_JIT_CALLED either.
    self.mov(R2, 0, m | self.la, k.act_native_ret);
    if (frame_state_possible(self.f)) {
        helper.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, m | self.la, k.act_cat, SLJIT_IMM, 0));
        helper.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, m | self.la, k.act_forin, SLJIT_IMM, 0));
    }
    // The flags but the lean ones, which ask nothing of the pop.
    long lean = (long)((vm::TH_LEAN_FRAME_FLAGS & ~vm::ACT_FLAG_JIT_CALLED) | vm::ACT_FLAG_LAZY);
    self.mov(R1, 0, m | self.la, k.act_flags, SLJIT_MOV_U32);
    sljit_emit_op2(c, SLJIT_AND, R1, 0, R1, 0, SLJIT_IMM, ~lean & 0xFFFFFFFF);
    void* site = sljit_emit_cmp(c, SLJIT_EQUAL, R1, 0, SLJIT_IMM, vm::ACT_FLAG_JIT_CALLED);
    void* entered = sljit_emit_cmp(c, SLJIT_EQUAL, R1, 0, SLJIT_IMM, 0);
    void* site_value;
    void* c_value;
    if (!self.f.is_arrow() && !self.f.is_derived_ctor() && !self.f.is_generator()) {
        void* site_construct = sljit_emit_cmp(c, SLJIT_EQUAL, R1, 0, SLJIT_IMM, vm::ACT_FLAG_JIT_CALLED | vm::ACT_FLAG_CONSTRUCT);
        helper.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R1, 0, SLJIT_IMM, vm::ACT_FLAG_CONSTRUCT));
        helper.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R2, 0, SLJIT_IMM, tramp_ret));
        sljit_set_label(site_construct, sljit_emit_label(c));
        // [[Construct]] answers `this` unless the body returned an object (ES2015 §9.2.2 step 13).
        sljit_emit_op2(c, SLJIT_LSHR, R1, 0, R0, 0, SLJIT_IMM, 48);
        void* returned_object = sljit_emit_cmp(c, SLJIT_EQUAL, R1, 0, SLJIT_IMM, (long)types::TAG_OBJECT);
        self.mov(R0, 0, m | self.la, l.act_this);
        sljit_emit_op2(c, SLJIT_LSHR, R1, 0, R0, 0, SLJIT_IMM, 48);
        helper.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R1, 0, SLJIT_IMM, (long)types::TAG_OBJECT));
        sljit_set_label(returned_object, sljit_emit_label(c));
        // Idempotent, so a later decline to vm::jit_ret records it again harmlessly.
        self.mov(sp, SUB_VALUE_OFF, R0, 0);
        self.mov(R0, 0, self.la, 0);
        self.c_call(SLJIT_ARGS1WW, SLJIT_IMM, (long)(usz)&vm::record_constructor_capacity);
        self.mov(R0, 0, sp, SUB_VALUE_OFF);
        self.mov(R2, 0, m | self.la, k.act_native_ret);
        self.mov(R1, 0, m | self.la, k.act_flags, SLJIT_MOV_U32);
        sljit_emit_op2(c, SLJIT_AND, R1, 0, R1, 0, SLJIT_IMM, vm::ACT_FLAG_JIT_CALLED);
        site_value = sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R1, 0, SLJIT_IMM, 0);
        c_value = sljit_emit_jump(c, SLJIT_JUMP);
    } else {
        helper.add(sljit_emit_jump(c, SLJIT_JUMP));
    }
    // A frame C entered: the result slot must hold no count, unless the frame borrows its
    // callee, and an object result must land inside the caller's window, which tracks it.
    sljit_set_label(entered, sljit_emit_label(c));
    helper.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R2, 0, SLJIT_IMM, tramp_ret));
    if (c_value != null) sljit_set_label(c_value, sljit_emit_label(c));
    self.mov(R3, 0, m | self.la, k.act_retval);
    helper.add(sljit_emit_cmp(c, SLJIT_EQUAL, R3, 0, SLJIT_IMM, 0));
    self.mov(R1, 0, m | R3, 0);
    sljit_emit_op2(c, SLJIT_LSHR, R1, 0, R1, 0, SLJIT_IMM, 48);
    void* uncounted = sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R1, 0, SLJIT_IMM, (long)types::TAG_STRING);
    self.mov(R1, 0, m | self.la, k.act_flags, SLJIT_MOV_U32);
    sljit_emit_op2(c, SLJIT_AND, R1, 0, R1, 0, SLJIT_IMM, vm::ACT_FLAG_BORROWED_CALLEE);
    helper.add(sljit_emit_cmp(c, SLJIT_EQUAL, R1, 0, SLJIT_IMM, 0));
    sljit_set_label(uncounted, sljit_emit_label(c));
    void* c_inert = sljit_emit_cmp(c, SLJIT_LESS, R0, 0, SLJIT_IMM, K_STRING_START);
    self.emit_result_object(&helper);
    // R3 = [caller.bottom, caller.bottom + its register count) holds the result slot.
    sljit_emit_op2(c, SLJIT_SUB, R1, 0, self.la, 0, SLJIT_IMM, (long)Activation::size);
    self.mov(R4, 0, m | R1, l.act_func);
    helper.add(sljit_emit_cmp(c, SLJIT_EQUAL, R4, 0, SLJIT_IMM, 0));
    self.mov(R4, 0, m | R4, k.cf_num_regs, SLJIT_MOV_U16);
    self.mov(R1, 0, m | R1, k.act_bottom);
    helper.add(sljit_emit_cmp(c, SLJIT_GREATER, R1, 0, R3, 0));
    sljit_emit_op2(c, SLJIT_SHL, R4, 0, R4, 0, SLJIT_IMM, 3);
    sljit_emit_op2(c, SLJIT_ADD, R4, 0, R4, 0, R1, 0);
    helper.add(sljit_emit_cmp(c, SLJIT_GREATER_EQUAL, R3, 0, R4, 0));
    sljit_set_label(c_inert, sljit_emit_label(c));
    // th_clear_tracked_regs over the frame's whole window (Asm.frame_regs), then the write-back.
    // Registers hold no counts, so a string clears like an object, as vm::jit_ret clears it.
    self.mov(sp, SUB_VALUE_OFF, R0, 0);
    self.mov(R2, 0, m | self.la, k.act_bottom);
    self.mov(R1, 0, SLJIT_IMM, K_UNDEF);
    self.mov(R3, 0, R1, 0);
    self.clear_slots(R2, 0, self.f.num_regs, R1, R3, R2, R0);
    self.mov(R0, 0, sp, SUB_VALUE_OFF);
    self.mov(R2, 0, m | self.la, k.act_retval);
    self.mov(m | R2, 0, R0, 0);
    self.mov(R1, 0, m | self.la, k.act_flags, SLJIT_MOV_U32);
    sljit_emit_op2(c, SLJIT_AND, R1, 0, R1, 0, SLJIT_IMM, ~(long)vm::ACT_FLAG_CALLEE_OWNED & 0xFFFFFFFF);
    self.mov(m | self.la, k.act_flags, R1, 0, SLJIT_MOV_U32);
    // C keeps the value stack's top itself (th_pop_frame); generated code leaves it to jit_sync.
    self.mov(R3, 0, m | ds, k.ds_vm);
    self.mov(R1, 0, m | self.la, k.act_caller_top);
    self.mov(m | R3, k.vm_valstack_top, R1, 0);
    // vm::jit_run_entered reads the caller's resume point there.
    self.mov(R1, 0, m | self.la, k.act_curr_pc - (long)Activation::size);
    self.mov(m | ds, self.pc_off, R1, 0);
    self.mov(R2, 0, SLJIT_IMM, tramp_ret);
    void* pop = sljit_emit_jump(c, SLJIT_JUMP);
    // A frame a call entry pushed: its site stores the result as Asm.publish would.
    sljit_set_label(site, sljit_emit_label(c));
    if (site_value != null) sljit_set_label(site_value, sljit_emit_label(c));
    void* site_inert = sljit_emit_cmp(c, SLJIT_LESS, R0, 0, SLJIT_IMM, K_STRING_START);
    self.emit_result_object(&helper);
    sljit_set_label(site_inert, sljit_emit_label(c));
    // th_pop_frame: the caller is the record below, which becomes the record register's; the
    // activation count and the rest of the VM's frame state wait for vm::jit_sync. A frame state
    // synced for the popped record describes it no more, and the next frame pushed here must not
    // pass for it.
    sljit_set_label(pop, sljit_emit_label(c));
    void* stale = sljit_emit_cmp(c, SLJIT_NOT_EQUAL, m | ds, l.ds_act, self.la, 0);
    self.mov(m | ds, l.ds_act, SLJIT_IMM, 0);
    sljit_set_label(stale, sljit_emit_label(c));
    sljit_emit_op2(c, SLJIT_SUB, self.la, 0, self.la, 0, SLJIT_IMM, (long)Activation::size);
    self.mov(R1, 0, R0, 0);
    self.mov(R0, 0, SLJIT_IMM, BASELINE_RETURNED);
    void* done = sljit_emit_jump(c, SLJIT_JUMP);
    helper.bind(sljit_emit_label(c));
    self.mov(R0, 0, SLJIT_IMM, 0);
    sljit_set_label(done, sljit_emit_label(c));
}

// The return's heap result R0 (no inert value): a string a counted holder or the queue already
// has, or an object while the collector is not marking, as Asm.publish stores one. Anything else
// joins `helper`. Clobbers R1.
fn void Asm.emit_result_object(&self, Jumps* helper) {
    void* c = self.c;
    Layout* l = self.lay;
    sljit_emit_op2(c, SLJIT_XOR, R1, 0, R0, 0, SLJIT_IMM, K_STRING_START);
    void* not_string = sljit_emit_cmp(c, SLJIT_GREATER_EQUAL, R1, 0, span_op(), span_w());
    sljit_emit_op1(c, SLJIT_MOV_U32, R1, 0, SLJIT_MEM | R1, l.str_flags);
    sljit_emit_op2(c, SLJIT_AND, R1, 0, R1, 0, SLJIT_IMM, l.interned_mask | l.queued_mask);
    void* queued = sljit_emit_cmp(c, SLJIT_GREATER_EQUAL, R1, 0, SLJIT_IMM, l.queued_mask);
    void* interned = sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R1, 0, SLJIT_IMM, 0);
    sljit_emit_op2(c, SLJIT_XOR, R1, 0, R0, 0, SLJIT_IMM, K_STRING_START);
    sljit_emit_op1(c, SLJIT_MOV_U32, R1, 0, SLJIT_MEM | R1, l.str_refcount);
    helper.add(sljit_emit_cmp(c, SLJIT_EQUAL, R1, 0, SLJIT_IMM, 0));
    void* counted = sljit_emit_jump(c, SLJIT_JUMP);
    // The intern table's own count is no holder's.
    sljit_set_label(interned, sljit_emit_label(c));
    sljit_emit_op2(c, SLJIT_XOR, R1, 0, R0, 0, SLJIT_IMM, K_STRING_START);
    sljit_emit_op1(c, SLJIT_MOV_U32, R1, 0, SLJIT_MEM | R1, l.str_refcount);
    helper.add(sljit_emit_cmp(c, SLJIT_LESS_EQUAL, R1, 0, SLJIT_IMM, 1));
    void* done = sljit_emit_jump(c, SLJIT_JUMP);
    sljit_set_label(not_string, sljit_emit_label(c));
    sljit_emit_op2(c, SLJIT_XOR, R1, 0, R0, 0, k_obj_op(), k_obj_w());
    helper.add(sljit_emit_cmp(c, SLJIT_GREATER_EQUAL, R1, 0, span_op(), span_w()));
    helper.add(sljit_emit_cmp(c, SLJIT_EQUAL, R1, 0, SLJIT_IMM, 0));
    self.mov(R1, 0, SLJIT_MEM | self.heap, self.lay.heap_gc_phase, SLJIT_MOV_U8);
    helper.add(sljit_emit_cmp(c, SLJIT_EQUAL, R1, 0, SLJIT_IMM, (long)heap::GcPhase.MARK.ordinal));
    sljit_set_label(queued, sljit_emit_label(c));
    sljit_set_label(counted, sljit_emit_label(c));
    sljit_set_label(done, sljit_emit_label(c));
}

// CALL_GLOBAL's callee as @lean_call_global reads it: the global binding the
// instruction's variable entry caches, stored in the callee register. Any
// other state, and a callee that is neither an object nor a lightfunc, joins `generic`.
fn void Asm.load_global_callee(&self, Jumps* generic) {
    void* c = self.c;
    long vic = (long)(usz)&((hobject::VarICEntry*)self.f.var_ic_entries)[self.next - 1];
    self.var_slot(vic, false);
    sljit_emit_op1(c, SLJIT_MOV, R0, 0, SLJIT_MEM | R0, 0);
    // Neither is a TDZ hole: the tag tests route that too.
    sljit_emit_op2(c, SLJIT_XOR, R1, 0, R0, 0, k_obj_op(), k_obj_w());
    void* object = sljit_emit_cmp(c, SLJIT_LESS, R1, 0, span_op(), span_w());
    sljit_emit_op2(c, SLJIT_XOR, R1, 0, R0, 0, SLJIT_IMM, K_LIGHTFUNC);
    self.call.add(sljit_emit_cmp(c, SLJIT_GREATER_EQUAL, R1, 0, span_op(), span_w()));
    sljit_set_label(object, sljit_emit_label(c));
    for (uint k = 0; k < self.call.len; k++) generic.add(self.call.at[k]);
    self.call.len = 0;
    self.store(self.w.a, R0);
}

// The callee of a CALL_VAR into its register, as lean_call_var reads it: a data binding the
// entry caches, not in its TDZ. A binding that is not permanent can be reassigned during the
// call, so the register is tracked and the frame keeps its own reference. Anything else, a moved
// entry included, takes `generic`.
fn void Asm.load_var_callee(&self, Jumps* generic) {
    void* c = self.c;
    long vic = (long)(usz)&((hobject::VarICEntry*)self.f.var_ic_entries)[self.next - 1];
    self.var_slot(vic, true);
    sljit_emit_op1(c, SLJIT_MOV_U8, R1, 0, SLJIT_MEM | R2, self.lay.vic_flags);
    sljit_emit_op2(c, SLJIT_AND, R1, 0, R1, 0, SLJIT_IMM, self.lay.accessor_mask);
    self.call.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R1, 0, SLJIT_IMM, 0));
    sljit_emit_op1(c, SLJIT_MOV, R0, 0, SLJIT_MEM | R0, 0);
    self.guard_not_tdz();
    for (uint k = 0; k < self.call.len; k++) generic.add(self.call.at[k]);
    for (uint k = 0; k < self.alt.len; k++) generic.add(self.alt.at[k]);
    self.call.len = 0;
    self.alt.len = 0;
    self.store(self.w.a, R0);
    self.track_heap_store(self.w.a);
}

// Whether the global the CALL_GLOBAL's entry caches is a trivial function,
// which vm::jit_call completes in place faster than a direct call declines.
fn bool Asm.global_callee_trivial(&self) {
    hobject::VarICEntry* vic = &((hobject::VarICEntry*)self.f.var_ic_entries)[self.next - 1];
    // A slot pointer filled before the binding's object last moved its storage
    // is stale, as th_ic_epoch_hit decides for the interpreter.
    if (vic.slot_ptr == null || vic.recycle_epoch != self.hp.shape_recycle_epoch) return false;
    CompiledFunction* target = vm::jit_compiled_callee(vic.slot_ptr.get());
    if (target == null) return false;
    target.classify_lean_call();
    return target.call_flags.trivial_call != 0;
}
