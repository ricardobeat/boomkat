// Baseline tier: native calls and returns published in generated code.
//
// Every function the threaded handlers would enter as a lean call with an
// exact argument count gets a second native entry, its call entry
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

// Bits of a call entry's packed argument above the argument count: the call
// passes an undefined receiver (CALL_UNDEF_THIS), or a method call's receiver
// is not a heap value.
const long CALL_PLAIN = 1L << 16;
const long CALL_PRIM = 1L << 17;
// A call site's packed bit for a method call (CALL), cleared for the entry.
const long CALL_METHOD = 1L << 18;

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
    long cf_num_regs;
    long bc_call_entry;
    long env_flags;
    long fn_mask;
    long fn_want;
}

CallLayout call_layout_data @private;
bool call_layout_ready @private;

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
    l.cf_num_regs = (char*)&cf.num_regs - base;
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
    call_layout_ready = true;
    return l;
}

// Whether `f` gets a call entry: a lean callee (classify_lean_call) whose
// frame the entry can publish with plain stores.
fn bool call_entry_eligible(CompiledFunction* f) {
    f.classify_lean_call();
    return f.call_flags.lean_call && !f.arguments_in_reg() && f.call_flags.trivial_call == 0
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
// threshold so that the helper path considers the function.
fn void* Asm.emit_call_entry(&self, int table_reg, BaselineCode* bc, int scratches = 5 | (2 << 8), int locals = CALL_FRAME_BYTES, bool count_opt = false) {
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
    sljit_emit_op2(c, SLJIT_AND, R1, 0, packed, 0, SLJIT_IMM, CALL_PLAIN - 1);
    decline.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R1, 0, SLJIT_IMM, f.num_formals));
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
    // var_env (env), R3 = the function object.
    sljit_emit_op2(c, SLJIT_AND, R4, 0, packed, 0, SLJIT_IMM, CALL_PLAIN);
    void* keep_this = sljit_emit_cmp(c, SLJIT_EQUAL, R4, 0, SLJIT_IMM, 0);
    self.mov(m | bottom, -(long)TVal::size, SLJIT_IMM, K_UNDEF);
    sljit_set_label(keep_this, sljit_emit_label(c));
    sljit_emit_op2(c, SLJIT_MUL, la, 0, R0, 0, SLJIT_IMM, (long)Activation::size);
    sljit_emit_op2(c, SLJIT_ADD, la, 0, la, 0, m | vm, k.vm_activations);
    sljit_emit_op2(c, SLJIT_ADD, R0, 0, R0, 0, SLJIT_IMM, 1);
    self.mov(m | vm, k.vm_count, R0, 0, SLJIT_MOV_U32);
    self.mov(R4, 0, m | ds, l.ds_act);
    self.mov(m | la, k.act_parent, R4, 0);
    self.mov(m | la, l.act_func, SLJIT_IMM, (long)(usz)f);
    self.mov(m | la, k.act_var_env, R2, 0);
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
    self.mov(m | la, k.act_cat, SLJIT_IMM, 0);
    self.mov(m | la, k.act_forin, SLJIT_IMM, 0);
    self.mov(m | la, k.act_async_gen_state, SLJIT_IMM, 0);
    self.mov(m | la, k.act_async_promise, SLJIT_IMM, 0);
    self.mov(m | la, k.act_new_target, SLJIT_IMM, 0);
    self.mov(m | la, k.act_curr_pc, SLJIT_IMM, (long)(usz)f.code);
    self.mov(m | la, k.act_bottom, bottom, 0);
    self.mov(m | la, k.act_retval, retval, 0);
    sljit_emit_op2(c, SLJIT_OR, R1, 0, R3, 0, SLJIT_IMM, K_OBJ);
    self.mov(m | la, l.act_tv_func, R1, 0);
    self.mov(m | la, l.act_hrc, SLJIT_IMM, 0, SLJIT_MOV_U32);
    self.mov(R1, 0, m | vm, k.vm_serial);
    sljit_emit_op2(c, SLJIT_ADD, R1, 0, R1, 0, SLJIT_IMM, 1);
    self.mov(m | vm, k.vm_serial, R1, 0);
    self.mov(m | la, k.act_serial, R1, 0);
    self.mov(R1, 0, m | vm, k.vm_valstack_top);
    self.mov(m | la, k.act_caller_top, R1, 0);
    // A method call on an object receiver keeps it as this_binding unless the
    // callee ignores it; every other shape leaves `this` undefined.
    self.mov(m | la, k.act_flags, SLJIT_IMM, 0, SLJIT_MOV_U32);
    self.mov(m | la, l.act_this, SLJIT_IMM, K_UNDEF);
    if (!f.call_flags.ignores_this) {
        sljit_emit_op2(c, SLJIT_AND, R4, 0, packed, 0, SLJIT_IMM, CALL_PLAIN | CALL_PRIM);
        void* no_this = sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R4, 0, SLJIT_IMM, 0);
        self.mov(R1, 0, m | bottom, -(long)TVal::size);
        self.mov(m | la, l.act_this, R1, 0);
        self.mov(m | la, k.act_flags, SLJIT_IMM, vm::ACT_FLAG_THIS_VALID, SLJIT_MOV_U32);
        sljit_set_label(no_this, sljit_emit_label(c));
    }
    // Locals and the scratch slots start undefined (exact arity: no surplus).
    uint from = f.num_formals;
    if (clear_end - from <= 12) {
        for (uint i = from; i < clear_end; i++) self.mov(m | bottom, (long)i * TVal::size, SLJIT_IMM, K_UNDEF);
    } else {
        sljit_emit_op2(c, SLJIT_ADD, R0, 0, bottom, 0, SLJIT_IMM, (long)from * TVal::size);
        sljit_emit_op2(c, SLJIT_ADD, R1, 0, bottom, 0, SLJIT_IMM, (long)clear_end * TVal::size);
        void* loop = sljit_emit_label(c);
        self.mov(m | R0, 0, SLJIT_IMM, K_UNDEF);
        sljit_emit_op2(c, SLJIT_ADD, R0, 0, R0, 0, SLJIT_IMM, TVal::size);
        sljit_set_label(sljit_emit_cmp(c, SLJIT_LESS, R0, 0, R1, 0), loop);
    }
    if (f.call_flags.rest_length_only) self.mov(m | bottom, (long)from * TVal::size, SLJIT_IMM, K_INT);
    sljit_emit_op2(c, SLJIT_ADD, R1, 0, bottom, 0, SLJIT_IMM, (long)f.num_regs * TVal::size);
    self.mov(m | vm, k.vm_valstack_top, R1, 0);
    self.mov(m | vm, k.vm_valstack_bottom, bottom, 0);
    self.mov(m | ds, l.ds_act, la, 0);
    self.mov(m | ds, k.ds_capture_refs, SLJIT_IMM, 0);
    self.mov(R1, 0, m | ds, k.ds_regs_base_ptr);
    self.mov(m | R1, 0, bottom, 0);
    self.mov(m | vm, k.vm_current_func, SLJIT_IMM, (long)(usz)f);
    self.mov(m | ds, k.ds_ic_bias, SLJIT_IMM, (long)((usz)f.ic_entries - (usz)f.code * vm::TH_IC_SCALE));
    self.mov(m | ds, k.ds_var_ic_bias, SLJIT_IMM, (long)((usz)f.var_ic_entries - (usz)f.code * vm::TH_VAR_IC_SCALE));
    self.emit_view(f);
    self.mov(m | ds, self.pc_off, SLJIT_IMM, (long)(usz)f.code);
    // The body's saved registers, as the main entry sets them.
    self.mov(self.regs, 0, bottom, 0);
    self.mov(self.code, 0, SLJIT_IMM, (long)(usz)f.code);
    self.mov(self.heap, 0, m | ds, k.ds_heap);
    self.mov(table_reg, 0, SLJIT_IMM, (long)(usz)&bc.entries[0]);
    self.mov(self.thunks, 0, SLJIT_IMM, (long)(usz)&thunks()[0]);
    sljit_set_label(sljit_emit_jump(c, SLJIT_JUMP), self.labels[0]);

    decline.bind(sljit_emit_label(c));
    sljit_emit_return(c, SLJIT_MOV, SLJIT_IMM, vm::JIT_CALL_SLOW);
    return entry;
}

// Point ds's code, constant and cache view at `f`, as Dispatch.load_frame
// does for a function that has run.
fn void Asm.emit_view(&self, CompiledFunction* f) {
    CallLayout* k = call_layout();
    int m = SLJIT_MEM;
    int ds = self.ds;
    self.mov(m | ds, k.ds_code_base, SLJIT_IMM, (long)(usz)f.code);
    self.mov(m | ds, k.ds_code_count, SLJIT_IMM, f.code_count, SLJIT_MOV_U32);
    self.mov(m | ds, k.ds_code_end, SLJIT_IMM, (long)(usz)(f.code + f.code_count));
    self.mov(R1, 0, SLJIT_MEM, (long)(usz)&f.constants);
    self.mov(m | ds, k.ds_constants, R1, 0);
    self.mov(m | ds, k.ds_ic_base, SLJIT_IMM, (long)(usz)f.ic_entries);
    self.mov(m | ds, k.ds_var_ic_base, SLJIT_IMM, (long)(usz)f.var_ic_entries);
    self.mov(m | ds, k.ds_nregs, SLJIT_IMM, f.num_regs, SLJIT_MOV_U32);
}

// A CALL, CALL_UNDEF_THIS or CALL_GLOBAL called directly through its callee's
// call entry (see the top of this file), by the shared call subroutine. `generic`
// collects the path that takes the helper call (vm::jit_call) instead.
fn void Asm.emit_direct_call(&self, Jumps* generic) {
    void* c = self.c;
    bool global = self.w.op == Opcode.CALL_GLOBAL;
    uint callee = global ? self.w.a : self.w.b;
    uint nargs = global ? self.w.b : self.w.c;
    long packed = (long)nargs | (self.w.op == Opcode.CALL ? CALL_METHOD : CALL_PLAIN);
    sljit_emit_op2(c, SLJIT_ADD, R1, 0, self.regs, 0, SLJIT_IMM, (long)(callee + 2) * TVal::size);
    sljit_emit_op2(c, SLJIT_ADD, R2, 0, self.regs, 0, SLJIT_IMM, (long)self.w.a * TVal::size);
    self.mov(R3, 0, SLJIT_IMM, packed);
    self.mov(R4, 0, SLJIT_IMM, (long)(usz)(self.f.code + self.next));
    self.subs.push({ .jump = sljit_emit_jump(c, SLJIT_FAST_CALL), .sub = CALL_SUB });
    generic.add(sljit_emit_cmp(c, SLJIT_EQUAL, R0, 0, SLJIT_IMM, vm::JIT_CALL_SLOW));
    sljit_set_label(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R0, 0, SLJIT_IMM, 0), self.nonzero);
    self.count(&self.stats.fast_hits[0], self.w.op);
}

// The call subroutine. In: R1 the callee's window (the function two slots
// below it, the receiver one below), R2 the result slot, R3 the argument
// count with CALL_METHOD or CALL_PLAIN, R4 the caller's resume point. Tests
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
    self.mov(R0, 0, m | R1, -2 * (long)TVal::size);
    sljit_emit_op2(c, SLJIT_XOR, R0, 0, R0, 0, SLJIT_IMM, K_OBJ);
    slow.add(sljit_emit_cmp(c, SLJIT_GREATER_EQUAL, R0, 0, SLJIT_IMM, PAYLOAD_SPAN));
    slow.add(sljit_emit_cmp(c, SLJIT_EQUAL, R0, 0, SLJIT_IMM, 0));
    // The caller's resume point, as th_publish_lean stores it (the slow
    // paths store it too), kept for the test after the return.
    self.mov(sp, CALL_RESUME_OFF, R4, 0);
    self.mov(R0, 0, m | ds, l.ds_act);
    self.mov(m | R0, k.act_curr_pc, R4, 0);
    self.mov(R0, 0, m | R1, -2 * (long)TVal::size);
    sljit_emit_op2(c, SLJIT_XOR, R0, 0, R0, 0, SLJIT_IMM, K_OBJ);
    self.mov(R4, 0, m | R0, 0, SLJIT_MOV_U32);
    sljit_emit_op2(c, SLJIT_AND, R4, 0, R4, 0, SLJIT_IMM, k.fn_mask);
    slow.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R4, 0, SLJIT_IMM, k.fn_want));
    self.mov(R4, 0, m | R0, k.fn_builtin, SLJIT_MOV_S32);
    slow.add(sljit_emit_cmp(c, SLJIT_SIG_GREATER_EQUAL, R4, 0, SLJIT_IMM, 0));
    self.mov(R4, 0, m | R0, l.fn_comp_func);
    slow.add(sljit_emit_cmp(c, SLJIT_EQUAL, R4, 0, SLJIT_IMM, 0));
    self.mov(R4, 0, m | R4, k.cf_jit_code);
    slow.add(sljit_emit_cmp(c, SLJIT_EQUAL, R4, 0, SLJIT_IMM, 0));
    self.mov(R4, 0, m | R4, k.bc_call_entry);
    slow.add(sljit_emit_cmp(c, SLJIT_EQUAL, R4, 0, SLJIT_IMM, 0));
    // A method call's receiver: an object in a register the caller's frame
    // tracks, or a value that is not on the heap (CALL_PRIM).
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
    // heap_reg_count > callee + 1: the receiver's slot lies below the
    // watermark, regs + heap_reg_count.
    self.mov(R0, 0, m | ds, l.ds_act);
    self.mov(R0, 0, m | R0, l.act_hrc, SLJIT_MOV_U32);
    sljit_emit_op2(c, SLJIT_SHL, R0, 0, R0, 0, SLJIT_IMM, 3);
    sljit_emit_op2(c, SLJIT_ADD, R0, 0, R0, 0, self.regs, 0);
    sljit_emit_op2(c, SLJIT_ADD, R0, 0, R0, 0, SLJIT_IMM, (long)TVal::size);
    slow.add(sljit_emit_cmp(c, SLJIT_LESS_EQUAL, R0, 0, R1, 0));
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
    Jumps done;
    done.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R0, 0, SLJIT_IMM, BASELINE_RETURNED));

    // The callee returned: the caller's activation is current again.
    CompiledFunction* f = self.f;
    self.mov(R0, 0, m | ds, l.ds_act);
    self.mov(self.regs, 0, m | R0, k.act_bottom);
    self.mov(m | ds, self.regs_off, self.regs, 0);
    self.mov(R0, 0, m | ds, k.ds_vm);
    self.mov(m | R0, k.vm_current_func, SLJIT_IMM, (long)(usz)f);
    self.mov(R1, 0, m | self.heap, k.heap_realm);
    void* same_realm = sljit_emit_cmp(c, SLJIT_EQUAL, R1, 0, SLJIT_IMM, (long)(usz)f.realm);
    self.mov(R0, 0, ds, 0);
    sljit_emit_icall(c, SLJIT_CALL, SLJIT_ARGS1WW, SLJIT_IMM, (long)(usz)&vm::jit_enter_frame_realm);
    sljit_set_label(same_realm, sljit_emit_label(c));
    self.emit_view(f);
    self.mov(R0, 0, m | ds, self.pc_off);
    self.mov(R1, 0, sp, CALL_RESUME_OFF);
    self.mov(R2, 0, R0, 0);
    self.mov(R0, 0, SLJIT_IMM, 0);
    done.add(sljit_emit_cmp(c, SLJIT_EQUAL, R2, 0, R1, 0));
    self.mov(R0, 0, SLJIT_IMM, BASELINE_REDISPATCH);
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
    sljit_set_label(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R0, 0, SLJIT_IMM, 0), self.nonzero);
    helper.add(sljit_emit_jump(c, SLJIT_JUMP));
}

// The caller's result slot lies inside the caller's window, which the
// object result needs (R4 is the returning frame's activation). With `track`
// it also raises the caller's watermark to cover the slot, as
// track_heap_store does. Clobbers R1-R3.
fn void Asm.emit_result_window(&self, Jumps* helper, bool track) {
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
    if (track) {
        sljit_emit_op2(c, SLJIT_SUB, R4, 0, R4, 0, R2, 0);
        sljit_emit_op2(c, SLJIT_LSHR, R4, 0, R4, 0, SLJIT_IMM, 3);
        sljit_emit_op2(c, SLJIT_ADD, R4, 0, R4, 0, SLJIT_IMM, 1);
        self.mov(R3, 0, m | R1, l.act_hrc, SLJIT_MOV_U32);
        void* covered = sljit_emit_cmp(c, SLJIT_LESS_EQUAL, R4, 0, R3, 0);
        self.mov(m | R1, l.act_hrc, R4, 0, SLJIT_MOV_U32);
        sljit_set_label(covered, sljit_emit_label(c));
    }
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
    // th_frame_is_replaceable, with no tracked registers.
    self.mov(R4, 0, m | ds, l.ds_act);
    self.mov(R1, 0, m | R4, k.act_flags, SLJIT_MOV_U32);
    sljit_emit_op2(c, SLJIT_AND, R1, 0, R1, 0, SLJIT_IMM, ~(long)vm::TH_LEAN_FRAME_FLAGS & 0xFFFFFFFF);
    helper.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R1, 0, SLJIT_IMM, 0));
    self.mov(R1, 0, m | R4, k.act_cat);
    helper.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R1, 0, SLJIT_IMM, 0));
    self.mov(R1, 0, m | R4, k.act_forin);
    helper.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R1, 0, SLJIT_IMM, 0));
    self.mov(R1, 0, m | R3, k.vm_current_func);
    helper.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R1, 0, SLJIT_IMM, (long)(usz)self.f));
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
    self.mov(sp, SUB_VALUE_OFF, R0, 0);
    sljit_emit_op2(c, SLJIT_LSHR, R1, 0, R0, 0, SLJIT_IMM, 48);
    void* primitive = sljit_emit_cmp(c, SLJIT_LESS, R1, 0, SLJIT_IMM, (long)types::TAG_STRING);
    helper.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R1, 0, SLJIT_IMM, (long)types::TAG_OBJECT));
    sljit_emit_op2(c, SLJIT_AND, R1, 0, R0, 0, SLJIT_IMM, PAYLOAD_SPAN - 1);
    helper.add(sljit_emit_cmp(c, SLJIT_EQUAL, R1, 0, SLJIT_IMM, 0));
    self.emit_result_window(&helper, false);
    sljit_set_label(primitive, sljit_emit_label(c));
    // th_tracked_regs_uncounted: no tracked register holds a string.
    uint nregs = self.f.num_regs;
    self.mov(R1, 0, m | R4, l.act_hrc, SLJIT_MOV_U32);
    Jumps untracked;
    untracked.add(sljit_emit_cmp(c, SLJIT_EQUAL, R1, 0, SLJIT_IMM, 0));
    void* below = sljit_emit_cmp(c, SLJIT_LESS_EQUAL, R1, 0, SLJIT_IMM, (long)nregs);
    self.mov(R1, 0, SLJIT_IMM, (long)nregs);
    sljit_set_label(below, sljit_emit_label(c));
    sljit_emit_op2(c, SLJIT_SHL, R1, 0, R1, 0, SLJIT_IMM, 3);
    self.mov(R2, 0, m | R4, k.act_bottom);
    sljit_emit_op2(c, SLJIT_ADD, R1, 0, R1, 0, R2, 0);
    void* scan = sljit_emit_label(c);
    self.mov(R0, 0, m | R2, 0);
    sljit_emit_op2(c, SLJIT_LSHR, R0, 0, R0, 0, SLJIT_IMM, 48);
    helper.add(sljit_emit_cmp(c, SLJIT_EQUAL, R0, 0, SLJIT_IMM, (long)types::TAG_STRING));
    sljit_emit_op2(c, SLJIT_ADD, R2, 0, R2, 0, SLJIT_IMM, TVal::size);
    sljit_set_label(sljit_emit_cmp(c, SLJIT_LESS, R2, 0, R1, 0), scan);
    // Every check passed: track an object result, then clear the tracked
    // registers (th_clear_tracked_regs).
    untracked.bind(sljit_emit_label(c));
    self.mov(R0, 0, sp, SUB_VALUE_OFF);
    sljit_emit_op2(c, SLJIT_LSHR, R1, 0, R0, 0, SLJIT_IMM, 48);
    void* no_track = sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R1, 0, SLJIT_IMM, (long)types::TAG_OBJECT);
    self.emit_result_window(&helper, true);
    sljit_set_label(no_track, sljit_emit_label(c));
    self.mov(R1, 0, m | R4, l.act_hrc, SLJIT_MOV_U32);
    Jumps cleared;
    cleared.add(sljit_emit_cmp(c, SLJIT_EQUAL, R1, 0, SLJIT_IMM, 0));
    void* below2 = sljit_emit_cmp(c, SLJIT_LESS_EQUAL, R1, 0, SLJIT_IMM, (long)nregs);
    self.mov(R1, 0, SLJIT_IMM, (long)nregs);
    sljit_set_label(below2, sljit_emit_label(c));
    sljit_emit_op2(c, SLJIT_SHL, R1, 0, R1, 0, SLJIT_IMM, 3);
    self.mov(R2, 0, m | R4, k.act_bottom);
    sljit_emit_op2(c, SLJIT_ADD, R1, 0, R1, 0, R2, 0);
    void* clear = sljit_emit_label(c);
    self.mov(m | R2, 0, SLJIT_IMM, K_UNDEF);
    sljit_emit_op2(c, SLJIT_ADD, R2, 0, R2, 0, SLJIT_IMM, TVal::size);
    sljit_set_label(sljit_emit_cmp(c, SLJIT_LESS, R2, 0, R1, 0), clear);
    cleared.bind(sljit_emit_label(c));
    // th_leaf_return's write-back and th_pop_frame; the caller is the
    // activation below the frame.
    self.mov(R3, 0, m | ds, k.ds_vm);
    self.mov(R2, 0, m | R4, k.act_retval);
    self.mov(m | R2, 0, R0, 0);
    self.mov(R0, 0, m | R4, k.act_flags, SLJIT_MOV_U32);
    sljit_emit_op2(c, SLJIT_AND, R0, 0, R0, 0, SLJIT_IMM, ~(long)vm::ACT_FLAG_CALLEE_OWNED & 0xFFFFFFFF);
    self.mov(m | R4, k.act_flags, R0, 0, SLJIT_MOV_U32);
    self.mov(R2, 0, m | R3, k.vm_count, SLJIT_MOV_U32);
    sljit_emit_op2(c, SLJIT_SUB, R2, 0, R2, 0, SLJIT_IMM, 1);
    self.mov(m | R3, k.vm_count, R2, 0, SLJIT_MOV_U32);
    sljit_emit_op2(c, SLJIT_SUB, R2, 0, R2, 0, SLJIT_IMM, 1);
    sljit_emit_op2(c, SLJIT_MUL, R1, 0, R2, 0, SLJIT_IMM, (long)Activation::size);
    sljit_emit_op2(c, SLJIT_ADD, R1, 0, R1, 0, m | R3, k.vm_activations);
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
    self.mov(R0, 0, SLJIT_IMM, 0);
    sljit_set_label(done, sljit_emit_label(c));
}

// CALL_GLOBAL's callee as @lean_call_global reads it: the global binding the
// instruction's variable entry caches, stored in the callee register. Any
// other state, and a callee that is not an object, joins `generic`.
fn void Asm.load_global_callee(&self, Jumps* generic) {
    void* c = self.c;
    long vic = (long)(usz)&((hobject::VarICEntry*)self.f.var_ic_entries)[self.next - 1];
    self.var_slot(vic, false);
    sljit_emit_op1(c, SLJIT_MOV, R0, 0, SLJIT_MEM | R0, 0);
    self.guard_not_tdz();
    sljit_emit_op2(c, SLJIT_XOR, R1, 0, R0, 0, SLJIT_IMM, K_OBJ);
    self.call.add(sljit_emit_cmp(c, SLJIT_GREATER_EQUAL, R1, 0, SLJIT_IMM, PAYLOAD_SPAN));
    for (uint k = 0; k < self.call.len; k++) generic.add(self.call.at[k]);
    self.call.len = 0;
    self.store(self.w.a, R0);
}

// Whether the global the CALL_GLOBAL's entry caches is a trivial function,
// which vm::jit_call completes in place faster than a direct call declines.
fn bool Asm.global_callee_trivial(&self) {
    hobject::VarICEntry* vic = &((hobject::VarICEntry*)self.f.var_ic_entries)[self.next - 1];
    if (vic.slot_ptr == null) return false;
    CompiledFunction* target = vm::jit_compiled_callee(vic.slot_ptr.get());
    if (target == null) return false;
    target.classify_lean_call();
    return target.call_flags.trivial_call != 0;
}
