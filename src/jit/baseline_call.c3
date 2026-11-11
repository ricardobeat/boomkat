// Baseline tier: native calls and returns published in generated code.
//
// Every function the threaded handlers would enter as a lean call gets a
// second native entry, its call entry
// (BaselineCode.call_entry), with the arguments (ds, bottom, retval, packed).
// It tests what th_lean_target, @lean_gate and the method shape test, then
// publishes the callee's Activation field for field as th_publish_lean does,
// with the callee's constants (code, register count, cache biases) baked in,
// and runs the body from its first instruction. A refusal returns
// JIT_CALL_SLOW before anything is written.
//
// A CALL or CALL_UNDEF_THIS site loads the callee's call entry through the
// function object, tests the receiver as @lean_call_method does, sets
// ds.jit_floor and ds.jit_depth around the call as vm::jit_call does and
// calls the entry directly. JIT_CALL_SLOW takes the helper path
// (vm::jit_call), which covers every other callee and shape; BASELINE_RETURNED
// reloads the caller's view with its constants (the resume subroutine).
//
// RET and RETUNDEF of a frame a native call site waits for pop the frame
// inline when th_leaf_return's plain case holds: no catcher, for-in state,
// construct or tail-call flags, tracked registers, collector work or heap
// result, and the result slot holds no count. Anything else calls
// vm::jit_ret.
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

// Stack offsets where the call subroutine keeps the floor it restores and
// the caller's resume point.
const long CALL_FLOOR_OFF = 16;
const long CALL_RESUME_OFF = 24;

struct CallLayout {
    long ds_vm;
    long ds_heap;
    long ds_code_base;
    long ds_code_count;
    long ds_code_end;
    long ds_constants;
    long ds_ic_base;
    long ds_var_ic_base;
    long ds_nregs;
    long ds_floor;
    long ds_depth;
    long ds_capture_refs;
    long ds_ic_bias;
    long ds_var_ic_bias;
    long ds_regs_base_ptr;
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
    long vm_activations;
    long vm_count;
    long vm_capacity;
    long vm_serial;
    long vm_valstack_top;
    long vm_valstack_end;
    long vm_valstack_bottom;
    long vm_current_func;
    long heap_realm;
    long heap_gc_pending;
    long fn_var_env;
    long fn_lex_env;
    long fn_builtin;
    long cf_jit_code;
    long cf_func_index;
    long ic_prop_idx;
    long ic_feedback;
    long[hobject::IC_CALL_TARGETS] ic_call_slot;
    long cf_num_regs;
    long cf_constants;
    long cf_ic_entries;
    long cf_var_ic_entries;
    long bc_call_entry;
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
    l.ds_code_base = (char*)&d.code_base - base;
    l.ds_code_count = (char*)&d.code_count - base;
    l.ds_code_end = (char*)&d.code_end - base;
    l.ds_constants = (char*)&d.constants - base;
    l.ds_ic_base = (char*)&d.ic_base - base;
    l.ds_var_ic_base = (char*)&d.var_ic_base - base;
    l.ds_nregs = (char*)&d.nregs - base;
    l.ds_floor = (char*)&d.jit_floor - base;
    l.ds_depth = (char*)&d.jit_depth - base;
    l.ds_capture_refs = (char*)&d.capture_refs - base;
    l.ds_ic_bias = (char*)&d.ic_bias - base;
    l.ds_var_ic_bias = (char*)&d.var_ic_bias - base;
    l.ds_regs_base_ptr = (char*)&d.regs_base_ptr - base;
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
    l.vm_activations = (char*)&vm.activations - base;
    l.vm_count = (char*)&vm.activation_count - base;
    l.vm_capacity = (char*)&vm.activation_capacity - base;
    l.vm_serial = (char*)&vm.activation_serial - base;
    l.vm_valstack_top = (char*)&vm.valstack_top - base;
    l.vm_valstack_end = (char*)&vm.valstack_end - base;
    l.vm_valstack_bottom = (char*)&vm.valstack_bottom - base;
    l.vm_current_func = (char*)&vm.current_func - base;
    l.heap_realm = (char*)&h.realm - base;
    l.heap_gc_pending = (char*)&h.gc_pending - base;
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
    l.cf_constants = (char*)&cf.constants - base;
    l.cf_ic_entries = (char*)&cf.ic_entries - base;
    l.cf_var_ic_entries = (char*)&cf.var_ic_entries - base;
    l.bc_call_entry = (char*)&bc.call_entry - base;
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
    // BaselineCode.view's order.
    assert(l.ds_ic_base == l.ds_code_base + 8 && l.ds_var_ic_base == l.ds_code_base + 16
           && l.ds_ic_bias == l.ds_code_base + 24 && l.ds_var_ic_bias == l.ds_code_base + 32
           && l.ds_code_end == l.ds_code_base + 40 && l.ds_constants == l.ds_code_base + 48
           && l.ds_code_count == l.ds_code_base + 56 && l.ds_nregs == l.ds_code_base + 60);
    call_layout_ready = true;
    return l;
}

// Whether `f` gets a call entry: a lean callee (classify_lean_call) whose
// frame the entry can publish with plain stores. An `arguments` register must
// be the forwarding kind, which holds the count (CallFlags.forward_args).
fn bool call_entry_eligible(CompiledFunction* f) {
    f.classify_lean_call();
    return f.call_flags.lean_call && (!f.arguments_in_reg() || entry_forwards(f)) && f.call_flags.trivial_call == 0
        && f.ic_entries != null && f.var_ic_entries != null && f.num_formals <= f.num_regs
        && !is_top_level(f);
}

fn void Asm.mov(&self, int dst, long dstw, int src, long srcw, int op = SLJIT_MOV) @inline {
    sljit_emit_op1(self.c, op, dst, dstw, src, srcw);
}

// The call entry of the function being compiled (see the top of this file).
// Emitted after the body; enters the body at its first instruction. `scratches`
// and `locals` are the frame the body was emitted for. With `count_opt` the entry
// counts toward the optimizing tier, and declines when the count reaches the
// threshold so that the helper path considers the function. `touch` marks the code as entered
// (BaselineCode.touched).
fn void* Asm.emit_call_entry(&self, int table_reg, BaselineCode* bc, int scratches = 5 | (2 << 8), int locals = CALL_FRAME_BYTES, bool count_opt = false, bool touch = false) {
    void* c = self.c;
    CompiledFunction* f = self.f;
    CallLayout* k = call_layout();
    Layout* l = self.lay;
    int m = SLJIT_MEM;
    int ds = self.ds;
    // Arguments arrive in S0..S3: ds, bottom, retval, packed.
    int bottom = reg_s(1);
    int retval = reg_s(2);
    int packed = reg_s(3);
    int vm = reg_s(4);
    int la = reg_s(5);
    Jumps decline;
    void* entry = sljit_emit_label(c);
    sljit_emit_enter(c, 0, SLJIT_ARGS4WWWW, scratches, 6, locals);
    if (count_opt) {
        long counter = (long)(usz)&f.opt_entries;
        self.mov(R0, 0, m, counter, SLJIT_MOV_U32);
        sljit_emit_op2(c, SLJIT_ADD, R0, 0, R0, 0, SLJIT_IMM, 1);
        self.mov(m, counter, R0, 0, SLJIT_MOV_U32);
        decline.add(sljit_emit_cmp(c, SLJIT_GREATER_EQUAL, R0, 0, SLJIT_IMM, OPT_ENTRY_THRESHOLD));
    }

    // th_lean_target, @lean_gate and the receiver test, before any write.
    self.mov(R0, 0, m | ds, k.ds_heap);
    self.mov(R1, 0, m | R0, k.heap_realm);
    decline.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R1, 0, SLJIT_IMM, (long)(usz)f.realm));
    self.mov(R1, 0, m | R0, k.heap_gc_pending, SLJIT_MOV_U8);
    decline.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R1, 0, SLJIT_IMM, 0));
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
    long forbidden = (f.call_flags.ignores_this ? 0 : CALL_PRIM) | (f.call_flags.lean_plain ? 0 : CALL_PLAIN);
    if (forbidden != 0) {
        sljit_emit_op2(c, SLJIT_AND, R1, 0, packed, 0, SLJIT_IMM, forbidden);
        decline.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R1, 0, SLJIT_IMM, 0));
    }
    self.mov(vm, 0, m | ds, k.ds_vm);
    self.mov(R0, 0, m | vm, k.vm_count, SLJIT_MOV_U32);
    self.mov(R1, 0, m | vm, k.vm_capacity, SLJIT_MOV_U32);
    decline.add(sljit_emit_cmp(c, SLJIT_GREATER_EQUAL, R0, 0, R1, 0));
    // publish_frame_top clears the scratch slots up to valstack_end; the
    // entry requires them all inside it.
    uint clear_end = f.num_regs + vm::FRAME_SCRATCH_SLOTS;
    sljit_emit_op2(c, SLJIT_ADD, R1, 0, bottom, 0, SLJIT_IMM, (long)clear_end * TVal::size);
    decline.add(sljit_emit_cmp(c, SLJIT_GREATER, R1, 0, m | vm, k.vm_valstack_end));
    // The function object, boxed, sits two slots below the window.
    self.mov(R3, 0, m | bottom, -2 * (long)TVal::size);
    sljit_emit_op2(c, SLJIT_XOR, R3, 0, R3, 0, SLJIT_IMM, K_OBJ);
    self.mov(R2, 0, m | R3, k.fn_var_env);
    decline.add(sljit_emit_cmp(c, SLJIT_EQUAL, R2, 0, SLJIT_IMM, 0));
    self.mov(R1, 0, m | R3, k.fn_lex_env);
    void* no_cap = sljit_emit_cmp(c, SLJIT_EQUAL, R1, 0, SLJIT_IMM, 0);
    env::EnvFlags with_flag;
    with_flag.is_with = true;
    self.mov(R4, 0, m | R1, k.env_flags, SLJIT_MOV_U8);
    sljit_emit_op2(c, SLJIT_AND, R4, 0, R4, 0, SLJIT_IMM, (long)(char)with_flag);
    decline.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R4, 0, SLJIT_IMM, 0));
    sljit_set_label(no_cap, sljit_emit_label(c));

    // th_publish_lean. R0 = activation_count, R1 = lex_env (cap), R2 =
    // var_env (env), R3 = the function object. Constants the stores share are
    // kept in registers once they are free: Z (R0) zero, U (packed) undefined,
    // F (R3) the function, C (retval) its code.
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
        sljit_emit_op2(c, SLJIT_OR, R4, 0, R4, 0, SLJIT_IMM, K_INT);
        self.mov(m | bottom, (long)f.arguments_reg * TVal::size, R4, 0);
    }
    sljit_emit_op2(c, SLJIT_AND, R4, 0, packed, 0, SLJIT_IMM, CALL_PLAIN);
    void* keep_this = sljit_emit_cmp(c, SLJIT_EQUAL, R4, 0, SLJIT_IMM, 0);
    self.mov(m | bottom, -(long)TVal::size, SLJIT_IMM, K_UNDEF);
    sljit_set_label(keep_this, sljit_emit_label(c));
    sljit_emit_op2(c, SLJIT_MUL, la, 0, R0, 0, SLJIT_IMM, (long)Activation::size);
    sljit_emit_op2(c, SLJIT_ADD, la, 0, la, 0, m | vm, k.vm_activations);
    sljit_emit_op2(c, SLJIT_ADD, R0, 0, R0, 0, SLJIT_IMM, 1);
    self.mov(m | vm, k.vm_count, R0, 0, SLJIT_MOV_U32);
    self.mov(R4, 0, m | ds, l.ds_act);
    self.store_pair(la, k.act_parent, R4, k.act_var_env, R2);
    self.mov(m | la, k.act_retval, retval, 0);
    // lex_env = cap unless cap is null, the env itself or not declarative.
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
    self.mov(m | la, l.act_lex_env, R1, 0);
    // A method call on an object receiver keeps it as this_binding unless the
    // callee ignores it; every other shape leaves `this` undefined.
    int zero = R0;
    int undef = packed;
    int fr = R3;
    int code = retval;
    bool takes_this = !f.call_flags.ignores_this;
    if (takes_this) sljit_emit_op2(c, SLJIT_AND, R4, 0, packed, 0, SLJIT_IMM, CALL_PLAIN | CALL_PRIM | CALL_CONSTRUCT);
    // R2 (env, stored) is a second zero, then a second undefined, for the
    // pair stores.
    self.mov(zero, 0, SLJIT_IMM, 0);
    self.mov(R2, 0, SLJIT_IMM, 0);
    self.mov(undef, 0, SLJIT_IMM, K_UNDEF);
    self.mov(code, 0, SLJIT_IMM, (long)(usz)f.code);
    self.store_pair(la, k.act_cat, zero, k.act_forin, R2);
    self.store_pair(la, k.act_new_target, zero, k.act_async_promise, R2);
    self.mov(m | la, k.act_async_gen_state, zero, 0);
    // No flags, and a heap_reg_count over the whole frame (Asm.frame_regs).
    self.mov(m | la, k.act_flags, zero, 0, SLJIT_MOV_U32);
    self.mov(m | la, l.act_hrc, SLJIT_IMM, f.num_regs, SLJIT_MOV_U32);
    self.store_pair(la, k.act_curr_pc, code, k.act_bottom, bottom);
    sljit_emit_op2(c, SLJIT_OR, R1, 0, fr, 0, SLJIT_IMM, K_OBJ);
    self.mov(m | la, l.act_tv_func, R1, 0);
    self.mov(fr, 0, SLJIT_IMM, (long)(usz)f);
    self.mov(m | la, l.act_func, fr, 0);
    self.mov(R1, 0, m | vm, k.vm_serial);
    sljit_emit_op2(c, SLJIT_ADD, R1, 0, R1, 0, SLJIT_IMM, 1);
    self.mov(m | vm, k.vm_serial, R1, 0);
    self.mov(m | la, k.act_serial, R1, 0);
    self.mov(R1, 0, m | vm, k.vm_valstack_top);
    self.mov(m | la, k.act_caller_top, R1, 0);
    self.mov(m | la, l.act_this, undef, 0);
    // A method call (R4 is 0) takes the receiver slot's value as `this`; so does a construction,
    // with the function as new.target.
    if (takes_this) {
        Jumps bound;
        if (!entry_constructs(f)) {
            bound.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R4, 0, SLJIT_IMM, 0));
        } else {
            void* method = sljit_emit_cmp(c, SLJIT_EQUAL, R4, 0, SLJIT_IMM, 0);
            bound.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R4, 0, SLJIT_IMM, CALL_CONSTRUCT));
            self.mov(R1, 0, m | la, l.act_tv_func);
            sljit_emit_op2(c, SLJIT_XOR, R1, 0, R1, 0, SLJIT_IMM, K_OBJ);
            self.mov(m | la, k.act_new_target, R1, 0);
            self.mov(R4, 0, SLJIT_IMM, vm::ACT_FLAG_CONSTRUCT);
            sljit_set_label(method, sljit_emit_label(c));
        }
        self.mov(R1, 0, m | bottom, -(long)TVal::size);
        self.mov(m | la, l.act_this, R1, 0);
        sljit_emit_op2(c, SLJIT_OR, R1, 0, R4, 0, SLJIT_IMM, vm::ACT_FLAG_THIS_VALID);
        self.mov(m | la, k.act_flags, R1, 0, SLJIT_MOV_U32);
        bound.bind(sljit_emit_label(c));
    }
    // Locals and the scratch slots start undefined, surplus arguments included
    // unless they are kept for forwarding.
    uint from = forwards ? f.arguments_reg + 1 : f.num_formals;
    self.mov(R2, 0, undef, 0);
    self.clear_slots(bottom, from, clear_end, undef, R2, R4, R1);
    if (f.call_flags.rest_length_only) self.mov(m | bottom, (long)from * TVal::size, SLJIT_IMM, K_INT);
    sljit_emit_op2(c, SLJIT_ADD, R1, 0, bottom, 0, SLJIT_IMM, (long)f.num_regs * TVal::size);
    self.mov(m | vm, k.vm_valstack_top, R1, 0);
    self.mov(m | vm, k.vm_valstack_bottom, bottom, 0);
    self.mov(m | ds, l.ds_act, la, 0);
    self.mov(m | ds, k.ds_capture_refs, zero, 0);
    self.mov(R1, 0, m | ds, k.ds_regs_base_ptr);
    self.mov(m | R1, 0, bottom, 0);
    self.mov(m | vm, k.vm_current_func, fr, 0);
    if (!self.emit_view_block(R4, R1, R2)) {
        self.mov(m | ds, k.ds_ic_bias, SLJIT_IMM, (long)((usz)f.ic_entries - (usz)f.code * vm::TH_IC_SCALE));
        self.mov(m | ds, k.ds_var_ic_bias, SLJIT_IMM, (long)((usz)f.var_ic_entries - (usz)f.code * vm::TH_VAR_IC_SCALE));
        self.emit_view(f, fr, code);
    }
    self.mov(m | ds, self.pc_off, code, 0);
    // The body's saved registers, as the main entry sets them.
    self.mov(self.regs, 0, bottom, 0);
    self.mov(self.code, 0, code, 0);
    self.mov(self.heap, 0, m | ds, k.ds_heap);
    self.mov(table_reg, 0, SLJIT_IMM, (long)(usz)&bc.entries[0]);
    // Optimized code records the entry for the eviction sweep (opt_make_room).
    if (touch) self.mov(m | table_reg, (long)(usz)&bc.touched - (long)(usz)&bc.entries[0], SLJIT_IMM, 1, SLJIT_MOV_U8);
    self.mov(self.thunks, 0, SLJIT_IMM, (long)(usz)&thunks()[0]);
    sljit_set_label(sljit_emit_jump(c, SLJIT_JUMP), self.labels[0]);

    decline.bind(sljit_emit_label(c));
    sljit_emit_return(c, SLJIT_MOV, SLJIT_IMM, vm::JIT_CALL_SLOW);
    return entry;
}

// Point ds's code, constant and cache view at `f`, as Dispatch.load_frame
// does for a function that has run. `fr` holds `f` and `code` its code
// pointer, both loaded by the caller; the cache pointers and the constant
// pool are read through `fr` (one load each in place of a 48-bit immediate).
// Clobbers R1.
fn void Asm.emit_view(&self, CompiledFunction* f, int fr, int code) {
    CallLayout* k = call_layout();
    int m = SLJIT_MEM;
    int ds = self.ds;
    self.mov(m | ds, k.ds_code_base, code, 0);
    self.mov(R1, 0, SLJIT_IMM, f.code_count);
    self.mov(m | ds, k.ds_code_count, R1, 0, SLJIT_MOV_U32);
    sljit_emit_op2(self.c, SLJIT_ADD, R1, 0, code, 0, SLJIT_IMM, (long)f.code_count * Instruction::size);
    self.mov(m | ds, k.ds_code_end, R1, 0);
    self.mov(R1, 0, m | fr, k.cf_constants);
    self.mov(m | ds, k.ds_constants, R1, 0);
    self.mov(R1, 0, m | fr, k.cf_ic_entries);
    self.mov(m | ds, k.ds_ic_base, R1, 0);
    self.mov(R1, 0, m | fr, k.cf_var_ic_entries);
    self.mov(m | ds, k.ds_var_ic_base, R1, 0);
    self.mov(R1, 0, SLJIT_IMM, f.num_regs);
    self.mov(m | ds, k.ds_nregs, R1, 0, SLJIT_MOV_U32);
}

// Store `r1` at base + off1 and `r2` at base + off2, as one pair move when
// the two words are adjacent.
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

// Copy the code allocation's view block (BaselineCode.view) into ds's view
// with four pair moves, through `base` and the pair `r1`, `r2`. False, with
// nothing emitted, when the allocation has no block for self.f.
fn bool Asm.emit_view_block(&self, int base, int r1, int r2) {
    if (self.view == null || (*self.view)[0] != (usz)self.f.code) return false;
    long off = call_layout().ds_code_base;
    self.mov(base, 0, SLJIT_IMM, (long)(usz)self.view);
    for (long i = 0; i < 8; i += 2) {
        sljit_emit_mem(self.c, SLJIT_MOV | SLJIT_MEM_LOAD, r1 | (r2 << 8), SLJIT_MEM | base, i * 8);
        sljit_emit_mem(self.c, SLJIT_MOV | SLJIT_MEM_STORE, r1 | (r2 << 8), SLJIT_MEM | self.ds, off + i * 8);
    }
    return true;
}

// A CALL, CALL_UNDEF_THIS, CALL_GLOBAL or NEW_OBJ called directly through its callee's
// call entry (see the top of this file), by the shared call subroutine. `generic`
// collects the path that takes the helper call (vm::jit_call) instead.
fn void Asm.emit_direct_call(&self, Jumps* generic) {
    void* c = self.c;
    bool global = self.w.op == Opcode.CALL_GLOBAL;
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
    sljit_emit_op2(c, SLJIT_ADD, R1, 0, self.regs, 0, SLJIT_IMM, (long)(callee + 2) * TVal::size);
    sljit_emit_op2(c, SLJIT_ADD, R2, 0, self.regs, 0, SLJIT_IMM, (long)self.w.a * TVal::size);
    self.mov(R3, 0, SLJIT_IMM, packed);
    self.mov(R4, 0, SLJIT_IMM, (long)(usz)(self.f.code + self.next));
    self.subs.push({ .jump = sljit_emit_jump(c, SLJIT_FAST_CALL), .sub = CALL_SUB });
    generic.add(sljit_emit_cmp(c, SLJIT_EQUAL, R0, 0, SLJIT_IMM, vm::JIT_CALL_SLOW));
    sljit_set_label(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R0, 0, SLJIT_IMM, 0), self.nonzero);
    self.count(&self.stats.fast_hits[0], self.w.op);
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
    sljit_emit_op2(c, SLJIT_XOR, R0, 0, R0, 0, SLJIT_IMM, K_OBJ);
    miss.add(sljit_emit_cmp(c, SLJIT_GREATER_EQUAL, R0, 0, SLJIT_IMM, PAYLOAD_SPAN));
    miss.add(sljit_emit_cmp(c, SLJIT_EQUAL, R0, 0, SLJIT_IMM, 0));
    self.mov(R1, 0, m | R0, 0, SLJIT_MOV_U32);
    sljit_emit_op2(c, SLJIT_AND, R1, 0, R1, 0, SLJIT_IMM, k.fn_mask);
    miss.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R1, 0, SLJIT_IMM, k.fn_want));
    self.mov(R1, 0, m | R0, k.fn_builtin, SLJIT_MOV_S32);
    miss.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R1, 0, SLJIT_IMM, (long)builtins::Builtin.STRING_PROTO_CHARCODEAT.ordinal));
    self.load(R1, rb + 1);
    sljit_emit_op2(c, SLJIT_XOR, R1, 0, R1, 0, SLJIT_IMM, K_STRING_START);
    miss.add(sljit_emit_cmp(c, SLJIT_GREATER_EQUAL, R1, 0, SLJIT_IMM, PAYLOAD_SPAN));
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
    sljit_emit_op2(c, SLJIT_OR, R0, 0, R0, 0, SLJIT_IMM, K_INT);
    self.store(self.w.a, R0);
}

// Record the callee in R4 (its CompiledFunction) as the call feedback of the
// site that is calling through the subroutine, as hobject::ic_note_callee does
// for the calls the threaded handlers make. The site's cache is addressed from
// the resume point kept on the stack. A site that already named this callee
// costs one comparison. Keeps R1-R4; clobbers R0.
fn void Asm.emit_note_callee(&self) {
    if (self.f.ic_entries == null) return;
    void* c = self.c;
    CallLayout* k = call_layout();
    Layout* l = self.lay;
    int m = SLJIT_MEM;
    // The cache of the call instruction before the resume point.
    self.mov(R0, 0, SLJIT_MEM | reg_sp(), CALL_RESUME_OFF);
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
    sljit_emit_op2(self.c, SLJIT_XOR, reg, 0, reg, 0, SLJIT_IMM, K_OBJ);
    self.mov(reg, 0, SLJIT_MEM | reg, self.lay.fn_comp_func);
}

// The call subroutine. In: R1 the callee's window (the function two slots
// below it, the receiver one below), R2 the result slot, R3 the argument
// count with CALL_METHOD, CALL_PLAIN or CALL_CONSTRUCT, R4 the caller's resume point. Tests
// the callee as th_lean_target does and the receiver as @lean_call_method
// does, sets ds.jit_floor and ds.jit_depth around the callee's call entry
// as vm::jit_call does, and makes the caller current again after it
// returned. Out: R0 = 0 to continue at the resume point, JIT_CALL_SLOW before
// anything was written, else a status for the shared exit (with
// BASELINE_REDISPATCH when a handler moved the resume point).
fn void Asm.emit_call_body(&self) {
    void* c = self.c;
    CallLayout* k = call_layout();
    Layout* l = self.lay;
    int m = SLJIT_MEM;
    int ds = self.ds;
    int sp = SLJIT_MEM | reg_sp();
    Jumps slow;
    Jumps done;
    // The caller's resume point, as th_publish_lean stores it (the slow
    // paths store it too), kept for the test after the return.
    self.mov(sp, CALL_RESUME_OFF, R4, 0);
    self.mov(R0, 0, m | ds, l.ds_act);
    self.mov(m | R0, k.act_curr_pc, R4, 0);
    self.mov(R0, 0, m | R1, -2 * (long)TVal::size);
    sljit_emit_op2(c, SLJIT_XOR, R0, 0, R0, 0, SLJIT_IMM, K_OBJ);
    // A value that is not a heap object still may be a callee: a lightfunc has
    // that shape, so route it to the tag test below instead of to the slow
    // path here.
    void* tagged = sljit_emit_cmp(c, SLJIT_GREATER_EQUAL, R0, 0, SLJIT_IMM, PAYLOAD_SPAN);
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
    self.mov(R1, 0, sp, CALL_RESUME_OFF);
    self.mov(R0, 0, ds, 0);
    sljit_emit_icall(c, SLJIT_CALL, SLJIT_ARGS2WWW, SLJIT_IMM, (long)(usz)&vm::jit_call_builtin_native);
    slow.add(sljit_emit_cmp(c, SLJIT_EQUAL, R0, 0, SLJIT_IMM, vm::JIT_CALL_SLOW));
    done.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R0, 0, SLJIT_IMM, 0));
    // The builtin ran: the value stack may have moved, so the window the site
    // continues with is the one ds names now.
    self.mov(self.regs, 0, m | ds, self.regs_off);
    done.add(sljit_emit_jump(c, SLJIT_JUMP));
    sljit_set_label(compiled, sljit_emit_label(c));
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
    sljit_emit_op2(c, SLJIT_XOR, R0, 0, R0, 0, SLJIT_IMM, K_OBJ);
    slow.add(sljit_emit_cmp(c, SLJIT_GREATER_EQUAL, R0, 0, SLJIT_IMM, PAYLOAD_SPAN));
    slow.add(sljit_emit_cmp(c, SLJIT_EQUAL, R0, 0, SLJIT_IMM, 0));
    sljit_set_label(receiver_done, sljit_emit_label(c));
    sljit_set_label(prim_done, sljit_emit_label(c));
    self.mov(R0, 0, m | ds, k.ds_depth, SLJIT_MOV_U32);
    slow.add(sljit_emit_cmp(c, SLJIT_GREATER_EQUAL, R0, 0, SLJIT_IMM, vm::JIT_NATIVE_DEPTH_CAP));

    // vm::jit_call's floor and depth, and the caller's resume point.
    sljit_emit_op2(c, SLJIT_ADD, R0, 0, R0, 0, SLJIT_IMM, 1);
    self.mov(m | ds, k.ds_depth, R0, 0, SLJIT_MOV_U32);
    self.mov(R0, 0, m | ds, k.ds_floor, SLJIT_MOV_U32);
    self.mov(sp, CALL_FLOOR_OFF, R0, 0);
    self.mov(R0, 0, m | ds, k.ds_vm);
    self.mov(R0, 0, m | R0, k.vm_count, SLJIT_MOV_U32);
    self.mov(m | ds, k.ds_floor, R0, 0, SLJIT_MOV_U32);
    sljit_emit_op2(c, SLJIT_AND, R3, 0, R3, 0, SLJIT_IMM, ~CALL_METHOD);
    self.mov(R0, 0, ds, 0);
    sljit_emit_icall(c, SLJIT_CALL, SLJIT_ARGS4WWWW, R4, 0);
    self.mov(R1, 0, sp, CALL_FLOOR_OFF);
    self.mov(m | ds, k.ds_floor, R1, 0, SLJIT_MOV_U32);
    self.mov(R1, 0, m | ds, k.ds_depth, SLJIT_MOV_U32);
    sljit_emit_op2(c, SLJIT_SUB, R1, 0, R1, 0, SLJIT_IMM, 1);
    self.mov(m | ds, k.ds_depth, R1, 0, SLJIT_MOV_U32);
    done.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R0, 0, SLJIT_IMM, BASELINE_RETURNED));

    // The callee returned: both pop paths (the inline return and vm::jit_ret)
    // already stored the caller's activation and ds.regs_base. Only the
    // cached window register the site continues with needs refreshing.
    CompiledFunction* f = self.f;
    self.mov(self.regs, 0, m | ds, self.regs_off);
    self.mov(R3, 0, SLJIT_IMM, (long)(usz)f);
    self.mov(R0, 0, m | ds, k.ds_vm);
    self.mov(m | R0, k.vm_current_func, R3, 0);
    self.mov(R1, 0, m | self.heap, k.heap_realm);
    void* same_realm = sljit_emit_cmp(c, SLJIT_EQUAL, R1, 0, SLJIT_IMM, (long)(usz)f.realm);
    self.mov(R0, 0, ds, 0);
    sljit_emit_icall(c, SLJIT_CALL, SLJIT_ARGS1WW, SLJIT_IMM, (long)(usz)&vm::jit_enter_frame_realm);
    self.mov(R3, 0, SLJIT_IMM, (long)(usz)f);
    sljit_set_label(same_realm, sljit_emit_label(c));
    if (!self.emit_view_block(R4, R1, R2)) {
        self.mov(R4, 0, SLJIT_IMM, (long)(usz)f.code);
        self.emit_view(f, R3, R4);
    }
    self.mov(R1, 0, sp, CALL_RESUME_OFF);
    self.mov(R0, 0, SLJIT_IMM, 0);
    done.add(sljit_emit_cmp(c, SLJIT_EQUAL, m | ds, self.pc_off, R1, 0));
    self.mov(R0, 0, SLJIT_IMM, BASELINE_REDISPATCH);
    done.add(sljit_emit_jump(c, SLJIT_JUMP));
    // A lightfunc callee completes through the same helper:
    // vm::jit_call_builtin_native's th_call_native runs a lightfunc's builtin
    // from its payload index with the receiver slot below it, as the CALL thunk
    // does, and a decline returns JIT_CALL_SLOW having written at most the
    // undefined receiver of a plain call. Any other non-object value keeps the
    // slow path.
    sljit_set_label(tagged, sljit_emit_label(c));
    self.mov(R0, 0, m | R1, -2 * (long)TVal::size);
    sljit_emit_op2(c, SLJIT_XOR, R0, 0, R0, 0, SLJIT_IMM, K_LIGHTFUNC);
    slow.add(sljit_emit_cmp(c, SLJIT_GREATER_EQUAL, R0, 0, SLJIT_IMM, PAYLOAD_SPAN));
    self.mov(R1, 0, R4, 0);
    self.mov(R0, 0, ds, 0);
    sljit_emit_icall(c, SLJIT_CALL, SLJIT_ARGS2WWW, SLJIT_IMM, (long)(usz)&vm::jit_call_builtin_native);
    slow.add(sljit_emit_cmp(c, SLJIT_EQUAL, R0, 0, SLJIT_IMM, vm::JIT_CALL_SLOW));
    done.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R0, 0, SLJIT_IMM, 0));
    self.mov(self.regs, 0, m | ds, self.regs_off);
    done.add(sljit_emit_jump(c, SLJIT_JUMP));
    slow.bind(sljit_emit_label(c));
    self.mov(R0, 0, SLJIT_IMM, vm::JIT_CALL_SLOW);
    done.bind(sljit_emit_label(c));
}

// RET and RETUNDEF: the result in R0 for the shared return subroutine,
// which pops the frame of a waiting native call site and sends the function
// out with BASELINE_RETURNED, or comes back for vm::jit_ret (`helper`).
fn void Asm.emit_return(&self, Jumps* helper) {
    void* c = self.c;
    if (self.f.maps_formals()) { helper.add(sljit_emit_jump(c, SLJIT_JUMP)); return; }
    if (self.w.op == Opcode.RET) {
        self.load(R0, self.w.a);
    } else {
        self.mov(R0, 0, SLJIT_IMM, K_UNDEF);
    }
    self.subs.push({ .jump = sljit_emit_jump(c, SLJIT_FAST_CALL), .sub = RETURN_SUB });
    // The subroutine's only nonzero status is BASELINE_RETURNED, which leaves.
    sljit_set_label(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R0, 0, SLJIT_IMM, 0), self.leave_exit);
    // The subroutine returns the result in R1 for the helper, which reads it
    // from the register the subroutine may have cleared.
    if (self.w.op == Opcode.RET) self.store(self.w.a, R1);
    helper.add(sljit_emit_jump(c, SLJIT_JUMP));
}

// The caller's result slot lies inside the caller's window, which the
// object result needs (R4 is the returning frame's activation): the caller is
// a native frame, which tracks its whole window. Clobbers R1-R3.
fn void Asm.emit_result_window(&self, Jumps* helper) {
    void* c = self.c;
    CallLayout* k = call_layout();
    Layout* l = self.lay;
    int m = SLJIT_MEM;
    sljit_emit_op2(c, SLJIT_SUB, R1, 0, R4, 0, SLJIT_IMM, (long)Activation::size);
    self.mov(R3, 0, m | R1, l.act_func);
    helper.add(sljit_emit_cmp(c, SLJIT_EQUAL, R3, 0, SLJIT_IMM, 0));
    self.mov(R3, 0, m | R3, k.cf_num_regs, SLJIT_MOV_U16);
    sljit_emit_op2(c, SLJIT_SHL, R3, 0, R3, 0, SLJIT_IMM, 3);
    self.mov(R2, 0, m | R1, k.act_bottom);
    helper.add(sljit_emit_cmp(c, SLJIT_EQUAL, R2, 0, SLJIT_IMM, 0));
    sljit_emit_op2(c, SLJIT_ADD, R3, 0, R3, 0, R2, 0);
    self.mov(R4, 0, m | self.ds, self.lay.ds_act);
    self.mov(R4, 0, m | R4, k.act_retval);
    helper.add(sljit_emit_cmp(c, SLJIT_LESS, R4, 0, R2, 0));
    helper.add(sljit_emit_cmp(c, SLJIT_GREATER_EQUAL, R4, 0, R3, 0));
    self.mov(R4, 0, m | self.ds, self.lay.ds_act);
}

// The return subroutine: with a result in R0 that is not a string, buffer or
// BigInt, pop the frame for the native call site waiting at ds.jit_floor in
// th_leaf_return's plain case and leave with BASELINE_RETURNED; otherwise
// return to the site, which calls vm::jit_ret.
fn void Asm.emit_return_body(&self) {
    void* c = self.c;
    CallLayout* k = call_layout();
    Layout* l = self.lay;
    int m = SLJIT_MEM;
    int ds = self.ds;
    int sp = SLJIT_MEM | reg_sp();
    Jumps helper;
    // The result stays at SUB_VALUE_OFF: the sweep below clears the register
    // it came from.
    self.mov(sp, SUB_VALUE_OFF, R0, 0);
    // Waiting: jit_floor != 0 and activation_count == jit_floor + 1.
    self.mov(R1, 0, m | ds, k.ds_floor, SLJIT_MOV_U32);
    helper.add(sljit_emit_cmp(c, SLJIT_EQUAL, R1, 0, SLJIT_IMM, 0));
    self.mov(R3, 0, m | ds, k.ds_vm);
    self.mov(R2, 0, m | R3, k.vm_count, SLJIT_MOV_U32);
    sljit_emit_op2(c, SLJIT_ADD, R1, 0, R1, 0, SLJIT_IMM, 1);
    helper.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R2, 0, R1, 0));
    // No collector work: gc_safepoint_due is false and nothing marks.
    self.mov(R1, 0, m | self.heap, k.heap_gc_pending, SLJIT_MOV_U8);
    helper.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R1, 0, SLJIT_IMM, 0));
    self.mov(R1, 0, m | self.heap, l.heap_gc_phase, SLJIT_MOV_U8);
    helper.add(sljit_emit_cmp(c, SLJIT_EQUAL, R1, 0, SLJIT_IMM, (long)heap::GcPhase.MARK.ordinal));
    // th_frame_is_replaceable, with no tracked registers, or a base
    // constructor's frame as th_return_general pops it.
    bool constructs = !self.f.is_arrow() && !self.f.is_derived_ctor() && !self.f.is_generator();
    self.mov(R4, 0, m | ds, l.ds_act);
    self.mov(R1, 0, m | R4, k.act_flags, SLJIT_MOV_U32);
    sljit_emit_op2(c, SLJIT_AND, R1, 0, R1, 0, SLJIT_IMM, ~(long)vm::TH_LEAN_FRAME_FLAGS & 0xFFFFFFFF);
    void* lean_frame = sljit_emit_cmp(c, SLJIT_EQUAL, R1, 0, SLJIT_IMM, 0);
    helper.add(constructs ? sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R1, 0, SLJIT_IMM, vm::ACT_FLAG_CONSTRUCT) : sljit_emit_jump(c, SLJIT_JUMP));
    if (constructs) {
        // [[Construct]] answers `this` unless the body returned an object (ES2015 §9.2.2 step 13).
        sljit_emit_op2(c, SLJIT_LSHR, R1, 0, R0, 0, SLJIT_IMM, 48);
        void* returned_object = sljit_emit_cmp(c, SLJIT_EQUAL, R1, 0, SLJIT_IMM, (long)types::TAG_OBJECT);
        self.mov(R0, 0, m | R4, l.act_this);
        sljit_emit_op2(c, SLJIT_LSHR, R1, 0, R0, 0, SLJIT_IMM, 48);
        helper.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R1, 0, SLJIT_IMM, (long)types::TAG_OBJECT));
        self.mov(sp, SUB_VALUE_OFF, R0, 0);
        sljit_set_label(returned_object, sljit_emit_label(c));
        // Idempotent, so a later decline to vm::jit_ret records it again harmlessly.
        self.mov(R0, 0, R4, 0);
        sljit_emit_icall(c, SLJIT_CALL, SLJIT_ARGS1WW, SLJIT_IMM, (long)(usz)&vm::record_constructor_capacity);
        self.mov(R0, 0, sp, SUB_VALUE_OFF);
        self.mov(R4, 0, m | ds, l.ds_act);
        self.mov(R3, 0, m | ds, k.ds_vm);
    }
    sljit_set_label(lean_frame, sljit_emit_label(c));
    self.mov(R1, 0, m | R4, k.act_cat);
    helper.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R1, 0, SLJIT_IMM, 0));
    self.mov(R1, 0, m | R4, k.act_forin);
    helper.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R1, 0, SLJIT_IMM, 0));
    self.mov(R1, 0, m | R3, k.vm_current_func);
    self.mov(R2, 0, m | R4, l.act_func);
    helper.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R1, 0, R2, 0));
    // A result slot holding no count, unless the frame borrows its callee.
    self.mov(R2, 0, m | R4, k.act_retval);
    helper.add(sljit_emit_cmp(c, SLJIT_EQUAL, R2, 0, SLJIT_IMM, 0));
    self.mov(R1, 0, m | R2, 0);
    sljit_emit_op2(c, SLJIT_LSHR, R1, 0, R1, 0, SLJIT_IMM, 48);
    void* uncounted = sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R1, 0, SLJIT_IMM, (long)types::TAG_STRING);
    self.mov(R1, 0, m | R4, k.act_flags, SLJIT_MOV_U32);
    sljit_emit_op2(c, SLJIT_AND, R1, 0, R1, 0, SLJIT_IMM, vm::ACT_FLAG_BORROWED_CALLEE);
    helper.add(sljit_emit_cmp(c, SLJIT_EQUAL, R1, 0, SLJIT_IMM, 0));
    sljit_set_label(uncounted, sljit_emit_label(c));
    // The result: a value with no heap pointer, or an object (stored where
    // the caller's watermark tracks it, as th_leaf_return does). Strings and
    // the other heap kinds take the helper.
    sljit_emit_op2(c, SLJIT_LSHR, R1, 0, R0, 0, SLJIT_IMM, 48);
    void* primitive = sljit_emit_cmp(c, SLJIT_LESS, R1, 0, SLJIT_IMM, (long)types::TAG_STRING);
    helper.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R1, 0, SLJIT_IMM, (long)types::TAG_OBJECT));
    sljit_emit_op2(c, SLJIT_AND, R1, 0, R0, 0, SLJIT_IMM, PAYLOAD_SPAN - 1);
    helper.add(sljit_emit_cmp(c, SLJIT_EQUAL, R1, 0, SLJIT_IMM, 0));
    self.emit_result_window(&helper);
    sljit_set_label(primitive, sljit_emit_label(c));
    // th_clear_tracked_regs: the frame's whole window (Asm.frame_regs).
    // Registers hold no counts, so a string clears like an object, as
    // vm::jit_ret clears it (th_leaf_return's counted_ok).
    self.mov(R2, 0, m | R4, k.act_bottom);
    self.mov(R1, 0, SLJIT_IMM, K_UNDEF);
    self.mov(R3, 0, R1, 0);
    self.clear_slots(R2, 0, self.f.num_regs, R1, R3, R2, R0);
    self.mov(R0, 0, sp, SUB_VALUE_OFF);
    // th_leaf_return's write-back and th_pop_frame; the caller is the
    // activation below the frame.
    self.mov(R3, 0, m | ds, k.ds_vm);
    self.mov(R2, 0, m | R4, k.act_retval);
    self.mov(m | R2, 0, R0, 0);
    self.mov(R0, 0, m | R4, k.act_flags, SLJIT_MOV_U32);
    sljit_emit_op2(c, SLJIT_AND, R0, 0, R0, 0, SLJIT_IMM, ~(long)vm::ACT_FLAG_CALLEE_OWNED & 0xFFFFFFFF);
    self.mov(m | R4, k.act_flags, R0, 0, SLJIT_MOV_U32);
    // The frame is the last activation (activation_count == jit_floor + 1
    // was tested), so the caller is the one before it.
    self.mov(R2, 0, m | R3, k.vm_count, SLJIT_MOV_U32);
    sljit_emit_op2(c, SLJIT_SUB, R2, 0, R2, 0, SLJIT_IMM, 1);
    self.mov(m | R3, k.vm_count, R2, 0, SLJIT_MOV_U32);
    sljit_emit_op2(c, SLJIT_SUB, R1, 0, R4, 0, SLJIT_IMM, (long)Activation::size);
    self.mov(m | ds, l.ds_act, R1, 0);
    self.mov(m | ds, k.ds_capture_refs, SLJIT_IMM, 0);
    self.mov(R0, 0, m | R1, k.act_bottom);
    self.mov(m | R3, k.vm_valstack_bottom, R0, 0);
    self.mov(R2, 0, m | R4, k.act_caller_top);
    self.mov(m | R3, k.vm_valstack_top, R2, 0);
    self.mov(R2, 0, m | ds, k.ds_regs_base_ptr);
    self.mov(m | R2, 0, R0, 0);
    self.mov(R0, 0, m | R1, k.act_curr_pc);
    self.mov(m | ds, self.pc_off, R0, 0);
    // Return like any subroutine (a return from the function inside it would
    // leave the call's return address on the CPU's return stack): R0 says
    // which way the site goes on.
    self.mov(R0, 0, SLJIT_IMM, BASELINE_RETURNED);
    void* done = sljit_emit_jump(c, SLJIT_JUMP);
    helper.bind(sljit_emit_label(c));
    self.mov(R1, 0, sp, SUB_VALUE_OFF);
    self.mov(R0, 0, SLJIT_IMM, 0);
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
    sljit_emit_op2(c, SLJIT_XOR, R1, 0, R0, 0, SLJIT_IMM, K_OBJ);
    void* object = sljit_emit_cmp(c, SLJIT_LESS, R1, 0, SLJIT_IMM, PAYLOAD_SPAN);
    sljit_emit_op2(c, SLJIT_XOR, R1, 0, R0, 0, SLJIT_IMM, K_LIGHTFUNC);
    self.call.add(sljit_emit_cmp(c, SLJIT_GREATER_EQUAL, R1, 0, SLJIT_IMM, PAYLOAD_SPAN));
    sljit_set_label(object, sljit_emit_label(c));
    for (uint k = 0; k < self.call.len; k++) generic.add(self.call.at[k]);
    self.call.len = 0;
    self.store(self.w.a, R0);
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
