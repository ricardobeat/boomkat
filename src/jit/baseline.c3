// Baseline tier: one native function per CompiledFunction, running the
// interpreter's own frames.
//
// The native function, `fn long(Dispatch* ds)`, runs instructions of the
// activation the Dispatch has loaded, starting at ds.curr_pc. There is no frame
// layout of its own. A throw that leaves the frame, a halt and every call the
// native call path declines return an OpStatus word to Vm.run, which reloads
// the top frame and enters its native code, or the interpreter when it has
// none.
//
// A CALL, CALL_UNDEF_THIS, CALL_VAR or CALL_GLOBAL whose callee the threaded
// handlers would enter as a lean call, and which has native code, runs it on
// the C stack (vm::jit_call_enter). The call site saves ds.jit_floor in its
// stack frame and sets it to the caller's activation count; the callee's
// frame sits one above. A thunk that leaves the activation count equal to
// the floor after switching frames returns BASELINE_RETURNED, and the call
// site restores the floor, reloads the caller's frame and continues at the
// following instruction, or through the entry table when a handler moved
// ds.curr_pc. Vm.run clears the floor (0, never a live count after a
// switch), so a frame it entered returns with RESTART. Any other status
// leaves every native frame on the way up unchanged; the activation stack
// describes the truth and each abandoned caller resumes later through the
// entry table at its saved curr_pc. Native calls nest at most
// vm::JIT_NATIVE_DEPTH_CAP deep per Dispatch.
//
// Instructions that need no runtime call in the common case (register
// loads, jumps and branches, number arithmetic, comparisons and bitwise ops)
// run inline. They guard their operand tags as the threaded handlers do, keep
// the destination's string release for the operation function, and take
// their slow path on any failed guard: out of line, a number path where the
// threaded handlers have one, then the thunk call. A backward branch charges
// the GC budget inline and takes the slow path when it expires or an
// interrupt hook is installed, so vm_branch runs the safepoint.
//
// Every other instruction, and every slow path, calls its opcode's thunk with
// the following instruction's address (bit 0 marks a WIDE pair). Each opcode
// has its own thunk, specialized at compile time over the Opcode enum, which
// stores that address into ds.curr_pc, decodes the instruction from the code
// and calls the operation function vm_dispatch calls. A nonzero result leaves
// the instruction stream for one shared exit: BASELINE_REDISPATCH when a jump,
// a switch op or a caught throw moved ds.curr_pc, which dispatches through the
// entry table, and any other status returns to Vm.run. The table maps every
// instruction word to its native address (null for words that do not start
// an instruction; a WIDE prefix and its payload are one instruction starting
// at the prefix), so the interpreter and native code can trade places at any
// instruction.
//
// Registers stay in memory; the window's base sits in a saved register,
// reloaded after every thunk call.
//
// Generated code holds no JS value across a thunk call; every operation
// function sees the real register window, and the interrupt and back-edge
// polls stay inside the operation functions.
//
// Not compiled: generators and async functions, script, module and eval
// top-level code, functions that open a `with` scope, and any function
// containing an opcode without a thunk.
module boomkat::jit @feat(SLJIT);

import boomkat::vm;
import boomkat::bytecode;
import boomkat::heap;
import boomkat::types;
import std::collections::list;

// Compiles of one function before it stays interpreted.
const char BASELINE_MAX_ATTEMPTS = 2;
// Frame entries before a function compiles without --jit-stress.
const uint BASELINE_ENTRY_THRESHOLD = 2;
// Generated code and entry tables, in bytes, past which compiles are refused.
const usz BASELINE_CODE_CAP = 64 * 1024 * 1024;
// A native run's result when its target is not an instruction start: the
// interpreter continues the frame.
const long BASELINE_INTERPRET = OpStatus::values.len;

struct JitStats {
    usz code_bytes;
    usz table_bytes;
    usz insns;
    uint compiled;
    uint excluded_suspending;
    uint excluded_top_level;
    uint excluded_with;
    uint excluded_opcode;
    uint failed;
    uint capped;
    // Native call sites: callees entered natively, trivial callees completed
    // in place, and calls left to the thunk because the callee had no native
    // code yet, the depth cap was reached, a method callee was not a compiled
    // function (builtins, bound functions), or the lean shape declined.
    ulong calls_native;
    ulong calls_trivial;
    ulong calls_no_code;
    ulong calls_depth;
    ulong calls_builtin;
    ulong calls_declined;
}

struct BaselineCode {
    void* exec;
    usz code_bytes;
    usz table_bytes;
    usz insns;
    // One native address per instruction word, parallel to the code.
    void*[*] entries;
}

alias BaselineFn = fn long(Dispatch* ds);
alias Thunk = fn long(Dispatch* ds, ulong next_pc);

// Native code for `f`, compiling it when the policy says so, or null when the
// frame runs in the interpreter.
fn void* baseline_code(Heap* h, CompiledFunction* f) @inline {
    if (f.jit_code != null) return ((BaselineCode*)f.jit_code).exec;
    if (f.jit_refused) return null;
    if (!h.jit_stress && ++f.jit_entries < BASELINE_ENTRY_THRESHOLD) return null;
    return baseline_try_compile(h, f);
}

fn long baseline_run(void* exec, Dispatch* ds) @inline {
    ds.jit_floor = 0;
    ds.jit_depth = 0;
    return ((BaselineFn)exec)(ds);
}

// The native entry of a compiled function.
fn void* baseline_entry(CompiledFunction* f) @inline => ((BaselineCode*)f.jit_code).exec;

fn void baseline_free(Heap* h, CompiledFunction* f) {
    BaselineCode* bc = f.jit_code;
    if (bc == null) return;
    sljit_free_code(bc.exec, null);
    h.free_func(h.heap_udata, bc);
    f.jit_code = null;
}

enum Refusal : char { NONE, SUSPENDING, TOP_LEVEL, WITH, OPCODE }

fn Refusal baseline_refusal(CompiledFunction* f) {
    if (f.flags.is_generator || f.flags.is_async) return SUSPENDING;
    if (f.flags.is_global || f.flags.is_module || f.flags.is_eval) return TOP_LEVEL;
    if (f.code == null || f.code_count == 0) return OPCODE;
    for (uint i = 0; i < f.code_count; i++) {
        Instruction w = f.code[i];
        if (w.op.ordinal >= Opcode::values.len) return OPCODE;
        if (w.op == Opcode.WIDE) {
            if (i + 1 >= f.code_count) return OPCODE;
            w = f.code[++i];
            if (w.op.ordinal >= Opcode::values.len) return OPCODE;
        }
        if (w.op == Opcode.WITH_START || w.op == Opcode.WITH_END) return WITH;
        if (thunks()[w.op.ordinal] == null) return OPCODE;
    }
    return NONE;
}

fn void* baseline_try_compile(Heap* h, CompiledFunction* f) @noinline {
    JitStats* st = &h.jit_stats;
    switch (baseline_refusal(f)) {
        case SUSPENDING: st.excluded_suspending++; f.jit_refused = true; return null;
        case TOP_LEVEL:  st.excluded_top_level++;  f.jit_refused = true; return null;
        case WITH:       st.excluded_with++;       f.jit_refused = true; return null;
        case OPCODE:     st.excluded_opcode++;     f.jit_refused = true; return null;
        case NONE: break;
    }
    if (st.code_bytes + st.table_bytes >= BASELINE_CODE_CAP) {
        st.capped++;
        f.jit_refused = true;
        return null;
    }
    BaselineCode* bc = baseline_compile(h, f);
    if (bc == null) {
        st.failed++;
        if (++f.jit_attempts >= BASELINE_MAX_ATTEMPTS) f.jit_refused = true;
        return null;
    }
    if (st.code_bytes + st.table_bytes + bc.code_bytes + bc.table_bytes > BASELINE_CODE_CAP) {
        sljit_free_code(bc.exec, null);
        h.free_func(h.heap_udata, bc);
        st.capped++;
        f.jit_refused = true;
        return null;
    }
    st.code_bytes += bc.code_bytes;
    st.table_bytes += bc.table_bytes;
    st.insns += bc.insns;
    st.compiled++;
    f.jit_code = bc;
    return bc.exec;
}

// A thunk's result when the operation left ds.curr_pc somewhere other than
// the following instruction: the code dispatches through the entry table.
const long BASELINE_REDISPATCH = OpStatus::values.len + 1;
// A native function's result when its activation returned to the native call
// site waiting at ds.jit_floor.
const long BASELINE_RETURNED = OpStatus::values.len + 2;

const int R0 = 1;
const int R1 = 2;
const int R2 = 3;
const int R3 = 4;
const int FR0 = 1;
const int FR1 = 2;

// NaN-boxed tag words and the signed tag (bits 63..48 read as a short) the
// guards compare with.
const long K_INT = (long)(types::TAG_FASTINT << 48);
const long K_BOOL = (long)(types::TAG_BOOLEAN << 48);
const long K_OBJ = (long)(types::TAG_OBJECT << 48);
const long K_UNDEF = (long)(types::TAG_UNDEFINED << 48);
const long K_NULL = (long)(types::TAG_NULL_VAL << 48);
const long K_STRING_START = (long)(types::TAG_STRING << 48);
const long STAG_INT = (long)types::TAG_FASTINT - 0x10000;
const long STAG_STRING = (long)types::TAG_STRING - 0x10000;
const long PAYLOAD_SPAN = 1L << 48;
const long CANONICAL_NAN = 0x7FF8000000000000;

// A jump to an instruction's label, bound once every label exists.
struct Goto {
    void* jump;
    uint target;
}

struct Jumps {
    void*[12] at;
    uint len;
}

fn void Jumps.add(&self, void* jump) @inline {
    assert(self.len < self.at.len);
    self.at[self.len++] = jump;
}

fn void Jumps.bind(&self, void* label) {
    for (uint k = 0; k < self.len; k++) sljit_set_label(self.at[k], label);
}

// An instruction's out-of-line code: `alt` jumps enter its number path,
// `call` jumps its thunk call.
struct Stub {
    uint insn;
    Jumps call;
    Jumps alt;
}

struct Asm {
    void* c;
    CompiledFunction* f;
    void*[] labels;
    bool[] starts;
    List{Goto} gotos;
    List{Stub} stubs;
    void* nonzero;
    int ds;
    int code;
    int regs;
    int thunks;
    int heap;
    long pc_off;
    long floor_off;
    long regs_off;
    long budget_off;
    long interrupt_off;
    long runtime_off;
    long htmldda_off;
    // The instruction being emitted.
    uint i;
    uint next;
    Instruction w;
    Jumps call;
    Jumps alt;
}

fn BaselineCode* baseline_compile(Heap* h, CompiledFunction* f) {
    uint count = f.code_count;
    usz table_bytes = BaselineCode::size + (usz)count * void*::size;
    BaselineCode* bc = h.alloc_func(h.heap_udata, table_bytes);
    if (bc == null) return null;
    mem::clear(bc, (sz)table_bytes);
    bc.table_bytes = table_bytes;

    void* c = sljit_create_compiler(null);
    if (c == null) { h.free_func(h.heap_udata, bc); return null; }
    defer sljit_free_compiler(c);

    // Field offsets, taken from a layout pointer that is never dereferenced.
    Dispatch* dl = (Dispatch*)(usz)4096;
    Heap* hl = (Heap*)(usz)4096;
    Asm a = {
        .c = c,
        .f = f,
        .labels = mem::new_array(void*, (usz)count + 1),
        .starts = mem::new_array(bool, (usz)count + 1),
        .ds = reg_s(0),
        .code = reg_s(1),
        .regs = reg_s(3),
        .thunks = reg_s(4),
        .heap = reg_s(5),
        .pc_off = (char*)&dl.curr_pc - (char*)dl,
        .floor_off = (char*)&dl.jit_floor - (char*)dl,
        .regs_off = (char*)&dl.regs_base - (char*)dl,
        .budget_off = (char*)&hl.bwd_gc_budget - (char*)hl,
        .interrupt_off = (char*)&hl.capi_interrupt_fn - (char*)hl,
        .runtime_off = (char*)&hl.capi_runtime - (char*)hl,
        .htmldda_off = (char*)&hl.htmldda_obj - (char*)hl,
    };
    a.gotos.init(mem);
    a.stubs.init(mem);
    defer {
        mem::free(a.labels);
        mem::free(a.starts);
        a.gotos.free();
        a.stubs.free();
    }
    bool consts_fixed = true;
    for (uint i = 0; i < count;) {
        a.starts[i] = true;
        if (f.code[i].op == Opcode.SETCONST) consts_fixed = false;
        i += f.code[i].op == Opcode.WIDE ? 2 : 1;
    }
    int table_reg = reg_s(2);
    int ds_mem = SLJIT_MEM | a.ds;

    sljit_emit_enter(c, 0, SLJIT_ARGS1WW, 4 | (2 << 8), 6, CALL_FRAME_BYTES);
    sljit_emit_op1(c, SLJIT_MOV, a.code, 0, ds_mem, (char*)&dl.code_base - (char*)dl);
    sljit_emit_op1(c, SLJIT_MOV, a.heap, 0, ds_mem, (char*)&dl.heap - (char*)dl);
    sljit_emit_op1(c, SLJIT_MOV, table_reg, 0, SLJIT_IMM, (long)(usz)&bc.entries[0]);
    sljit_emit_op1(c, SLJIT_MOV, a.thunks, 0, SLJIT_IMM, (long)(usz)&thunks()[0]);

    // Dispatch on ds.curr_pc through the entry table, with the register
    // window reloaded.
    void* dispatch = sljit_emit_label(c);
    sljit_emit_op1(c, SLJIT_MOV, a.regs, 0, ds_mem, a.regs_off);
    sljit_emit_op1(c, SLJIT_MOV, R1, 0, ds_mem, a.pc_off);
    sljit_emit_op2(c, SLJIT_SUB, R1, 0, R1, 0, a.code, 0);
    sljit_emit_op2(c, SLJIT_LSHR, R1, 0, R1, 0, SLJIT_IMM, 2);
    void* out_of_range = sljit_emit_cmp(c, SLJIT_GREATER_EQUAL, R1, 0, SLJIT_IMM, count);
    sljit_emit_op1(c, SLJIT_MOV, R0, 0, mem_index(table_reg, R1), 3);
    void* no_entry = sljit_emit_cmp(c, SLJIT_EQUAL, R0, 0, SLJIT_IMM, 0);
    sljit_emit_ijump(c, SLJIT_JUMP, R0, 0);
    void* interpret = sljit_emit_label(c);
    sljit_set_label(out_of_range, interpret);
    sljit_set_label(no_entry, interpret);
    sljit_emit_return(c, SLJIT_MOV, SLJIT_IMM, BASELINE_INTERPRET);
    // A thunk's nonzero result: redispatch, or leave with the status.
    a.nonzero = sljit_emit_label(c);
    sljit_set_label(sljit_emit_cmp(c, SLJIT_EQUAL, R0, 0, SLJIT_IMM, BASELINE_REDISPATCH), dispatch);
    sljit_emit_return(c, SLJIT_MOV, R0, 0);

    for (uint i = 0; i < count;) {
        a.i = i;
        a.w = f.code[i];
        a.next = i + (a.w.op == Opcode.WIDE ? 2 : 1);
        a.call.len = 0;
        a.alt.len = 0;
        a.labels[i] = sljit_emit_label(c);
        bc.insns++;
        if (!a.emit_call() && !a.emit_fast(consts_fixed)) a.emit_thunk_call(i);
        if (a.call.len != 0 || a.alt.len != 0) a.stubs.push({ .insn = i, .call = a.call, .alt = a.alt });
        i = a.next;
    }
    a.labels[count] = sljit_emit_label(c);
    sljit_set_label(sljit_emit_jump(c, SLJIT_JUMP), dispatch);

    // Out-of-line paths, each returning to the following instruction.
    foreach (&stub : a.stubs) {
        a.i = stub.insn;
        a.w = f.code[stub.insn];
        a.next = stub.insn + 1;
        a.call = stub.call;
        a.alt = {};
        if (stub.alt.len != 0) {
            stub.alt.bind(sljit_emit_label(c));
            a.emit_alt();
        }
        a.call.bind(sljit_emit_label(c));
        a.emit_thunk_call(stub.insn);
        a.go(sljit_emit_jump(c, SLJIT_JUMP), a.next);
    }
    foreach (g : a.gotos) sljit_set_label(g.jump, a.labels[g.target]);

    bc.exec = sljit_generate_code(c, 0, null);
    if (bc.exec == null) { h.free_func(h.heap_udata, bc); return null; }
    bc.code_bytes = sljit_shim_code_size(c);
    for (uint i = 0; i < count; i++) {
        if (a.starts[i]) bc.entries[i] = (void*)sljit_shim_label_addr(a.labels[i]);
    }
    return bc;
}

// --- Emission helpers ---

fn void Asm.go(&self, void* jump, uint target) {
    if (target <= self.i) {
        sljit_set_label(jump, self.labels[target]);
    } else {
        self.gotos.push({ .jump = jump, .target = target });
    }
}

// Call instruction `i`'s thunk with the following instruction's address (bit
// 0 marks a WIDE pair), leave on a nonzero status and reload the registers.
fn void Asm.emit_thunk_call(&self, uint i) {
    void* c = self.c;
    Instruction w = self.f.code[i];
    bool wide = w.op == Opcode.WIDE;
    Opcode op = wide ? self.f.code[i + 1].op : w.op;
    uint next = i + (wide ? 2 : 1);
    sljit_emit_op2(c, SLJIT_ADD, R1, 0, self.code, 0, SLJIT_IMM, (long)next * Instruction::size + (wide ? 1 : 0));
    sljit_emit_op1(c, SLJIT_MOV, R0, 0, self.ds, 0);
    sljit_emit_icall(c, SLJIT_CALL, SLJIT_ARGS2WWW, SLJIT_MEM | self.thunks, (long)op.ordinal * Thunk::size);
    sljit_set_label(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R0, 0, SLJIT_IMM, 0), self.nonzero);
    sljit_emit_op1(c, SLJIT_MOV, self.regs, 0, SLJIT_MEM | self.ds, self.regs_off);
}

// Stack bytes of a native function's frame: the floor a native call site
// saves across its callee.
const int CALL_FRAME_BYTES = 16;

// A call the threaded handlers take as a lean call: jit_call_enter publishes
// the callee's frame and the callee's native code runs on the C stack. A
// declined call takes the thunk; a trivial callee completes in the helper.
fn bool Asm.emit_call(&self) {
    void* c = self.c;
    switch (self.w.op) {
        case CALL:
        case CALL_UNDEF_THIS:
        case CALL_VAR:
        case CALL_GLOBAL:
            break;
        default:
            return false;
    }
    int sp = SLJIT_MEM | reg_sp();
    long next = (long)self.next * Instruction::size;
    sljit_emit_op1(c, SLJIT_MOV_U32, R0, 0, SLJIT_MEM | self.ds, self.floor_off);
    sljit_emit_op1(c, SLJIT_MOV, sp, 0, R0, 0);
    sljit_emit_op2(c, SLJIT_ADD, R1, 0, self.code, 0, SLJIT_IMM, next);
    sljit_emit_op1(c, SLJIT_MOV, R0, 0, self.ds, 0);
    sljit_emit_icall(c, SLJIT_CALL, SLJIT_ARGS2WWW, SLJIT_IMM, (long)(usz)&vm::jit_call_enter);
    self.call.add(sljit_emit_cmp(c, SLJIT_EQUAL, R0, 0, SLJIT_IMM, 0));
    void* done = sljit_emit_cmp(c, SLJIT_EQUAL, R0, 0, SLJIT_IMM, (long)vm::JIT_CALL_DONE);
    sljit_emit_op1(c, SLJIT_MOV, R2, 0, R0, 0);
    sljit_emit_op1(c, SLJIT_MOV, R0, 0, self.ds, 0);
    sljit_emit_icall(c, SLJIT_CALL, SLJIT_ARGS1WW, R2, 0);
    sljit_emit_op1(c, SLJIT_MOV, R1, 0, R0, 0);
    sljit_emit_op1(c, SLJIT_MOV, R0, 0, self.ds, 0);
    sljit_emit_op1(c, SLJIT_MOV, R2, 0, sp, 0);
    sljit_emit_op2(c, SLJIT_ADD, R3, 0, self.code, 0, SLJIT_IMM, next);
    sljit_emit_icall(c, SLJIT_CALL, SLJIT_ARGS4WWWW, SLJIT_IMM, (long)(usz)&vm::jit_call_return);
    sljit_set_label(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R0, 0, SLJIT_IMM, 0), self.nonzero);
    sljit_set_label(done, sljit_emit_label(c));
    sljit_emit_op1(c, SLJIT_MOV, self.regs, 0, SLJIT_MEM | self.ds, self.regs_off);
    return true;
}

fn void Asm.load(&self, int reg, uint r) @inline {
    sljit_emit_op1(self.c, SLJIT_MOV, reg, 0, SLJIT_MEM | self.regs, (long)r * TVal::size);
}

fn void Asm.store(&self, uint r, int reg, long regw = 0) @inline {
    sljit_emit_op1(self.c, SLJIT_MOV, SLJIT_MEM | self.regs, (long)r * TVal::size, reg, regw);
}

// Jump to the slow path unless `reg` holds a fastint.
fn void Asm.guard_int(&self, int reg) {
    sljit_emit_op2(self.c, SLJIT_ASHR, R3, 0, reg, 0, SLJIT_IMM, 48);
    self.call.add(sljit_emit_cmp(self.c, SLJIT_NOT_EQUAL, R3, 0, SLJIT_IMM, STAG_INT));
}

// The same, entering the number path instead.
fn void Asm.guard_int_alt(&self, int reg) {
    sljit_emit_op2(self.c, SLJIT_ASHR, R3, 0, reg, 0, SLJIT_IMM, 48);
    self.alt.add(sljit_emit_cmp(self.c, SLJIT_NOT_EQUAL, R3, 0, SLJIT_IMM, STAG_INT));
}

// A register store releases a string the register held, which only the
// operation function does: a string destination takes the slow path.
fn void Asm.guard_dest(&self, uint r) {
    self.load(R2, r);
    sljit_emit_op2(self.c, SLJIT_ASHR, R2, 0, R2, 0, SLJIT_IMM, 48);
    self.call.add(sljit_emit_cmp(self.c, SLJIT_EQUAL, R2, 0, SLJIT_IMM, STAG_STRING));
}

// `reg`, a fastint payload shifted left by 16, boxed as a fastint.
fn void Asm.box_shifted(&self, int reg) {
    sljit_emit_op2(self.c, SLJIT_LSHR, reg, 0, reg, 0, SLJIT_IMM, 16);
    sljit_emit_op2(self.c, SLJIT_OR, reg, 0, reg, 0, SLJIT_IMM, K_INT);
}

// Charge a backward branch against the GC budget as vm_branch does, taking
// the slow path (which runs vm_branch) when the budget expires or an
// interrupt hook is installed.
fn void Asm.back_edge(&self) {
    void* c = self.c;
    int hm = SLJIT_MEM | self.heap;
    sljit_emit_op1(c, SLJIT_MOV_U32, R2, 0, hm, self.budget_off);
    self.call.add(sljit_emit_cmp(c, SLJIT_LESS_EQUAL, R2, 0, SLJIT_IMM, 1));
    sljit_emit_op1(c, SLJIT_MOV, R3, 0, hm, self.interrupt_off);
    sljit_emit_op2(c, SLJIT_OR, R3, 0, R3, 0, hm, self.runtime_off);
    self.call.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R3, 0, SLJIT_IMM, 0));
    sljit_emit_op2(c, SLJIT_SUB, R2, 0, R2, 0, SLJIT_IMM, 1);
    sljit_emit_op1(c, SLJIT_MOV_U32, hm, self.budget_off, R2, 0);
}

// The target of a branch `off` words past the following instruction, or -1
// when it is not an instruction start.
fn long Asm.target(&self, int off) {
    long t = (long)self.next + off;
    if (t < 0 || t >= (long)self.f.code_count || !self.starts[(usz)t]) return -1;
    return t;
}

// Branch to `target` when `cond` holds over R0 and (r2, r2w), or over FR0 and
// FR1 for a float condition, and fall through otherwise.
fn void Asm.branch(&self, bool fl, int cond, int r2, long r2w, uint target, bool backward) {
    void* c = self.c;
    if (!backward) {
        self.go(fl ? sljit_emit_fcmp(c, cond, FR0, 0, FR1, 0) : sljit_emit_cmp(c, cond, R0, 0, r2, r2w), target);
        return;
    }
    void* skip = fl ? sljit_emit_fcmp(c, cond ^ 1, FR0, 0, FR1, 0) : sljit_emit_cmp(c, cond ^ 1, R0, 0, r2, r2w);
    self.go(skip, self.next);
    self.back_edge();
    sljit_set_label(sljit_emit_jump(c, SLJIT_JUMP), self.labels[target]);
}

// Bind the outcome jumps of a multi-way test: `take` jumps branch, `skip`
// jumps fall to the following instruction.
fn void Asm.finish_test(&self, Jumps* take, Jumps* skip, uint target, bool backward) {
    for (uint k = 0; k < skip.len; k++) self.go(skip.at[k], self.next);
    if (!backward) {
        for (uint k = 0; k < take.len; k++) self.go(take.at[k], target);
        return;
    }
    take.bind(sljit_emit_label(self.c));
    self.back_edge();
    sljit_set_label(sljit_emit_jump(self.c, SLJIT_JUMP), self.labels[target]);
}

// FR(fr) = register `r` as a double, or the slow path when it is not a number.
fn void Asm.load_number(&self, int fr, uint r) {
    void* c = self.c;
    long off = (long)r * TVal::size;
    self.load(R2, r);
    void* not_double = sljit_emit_cmp(c, SLJIT_GREATER_EQUAL, R2, 0, SLJIT_IMM, K_INT);
    sljit_emit_fop1(c, SLJIT_MOV_F64, fr, 0, SLJIT_MEM | self.regs, off);
    void* done = sljit_emit_jump(c, SLJIT_JUMP);
    sljit_set_label(not_double, sljit_emit_label(c));
    sljit_emit_op2(c, SLJIT_ASHR, R3, 0, R2, 0, SLJIT_IMM, 48);
    self.call.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R3, 0, SLJIT_IMM, STAG_INT));
    sljit_emit_op2(c, SLJIT_SHL, R2, 0, R2, 0, SLJIT_IMM, 16);
    sljit_emit_op2(c, SLJIT_ASHR, R2, 0, R2, 0, SLJIT_IMM, 16);
    sljit_emit_fop1(c, SLJIT_CONV_F64_FROM_SW, fr, 0, R2, 0);
    sljit_set_label(done, sljit_emit_label(c));
}

fn void Asm.load_imm_number(&self, int fr, long value) {
    sljit_emit_op1(self.c, SLJIT_MOV, R2, 0, SLJIT_IMM, value);
    sljit_emit_fop1(self.c, SLJIT_CONV_F64_FROM_SW, fr, 0, R2, 0);
}

// Store FR0 into register `r` as TVal.set_number does: a NaN whose bits would
// read as a tag becomes the canonical NaN.
fn void Asm.store_number(&self, uint r) {
    void* c = self.c;
    sljit_emit_fcopy(c, SLJIT_COPY_FROM_F64, FR0, R2);
    void* ok = sljit_emit_cmp(c, SLJIT_LESS, R2, 0, SLJIT_IMM, K_INT);
    sljit_emit_op1(c, SLJIT_MOV, R2, 0, SLJIT_IMM, CANONICAL_NAN);
    sljit_set_label(ok, sljit_emit_label(c));
    self.store(r, R2);
}

// --- Fast paths ---

// The integer SLJIT condition and the float condition (NaN-aware) under which
// a compare-and-branch opcode, indexed from JMP_NLT, branches.
const int[10] JMP_INT_COND = {
    SLJIT_SIG_GREATER_EQUAL, SLJIT_SIG_GREATER, SLJIT_SIG_LESS_EQUAL, SLJIT_SIG_LESS,
    SLJIT_SIG_LESS, SLJIT_SIG_LESS_EQUAL, SLJIT_SIG_GREATER, SLJIT_SIG_GREATER_EQUAL,
    SLJIT_EQUAL, SLJIT_NOT_EQUAL,
};
const int[10] JMP_FLOAT_COND = {
    SLJIT_UNORDERED_OR_GREATER_EQUAL, SLJIT_UNORDERED_OR_GREATER,
    SLJIT_UNORDERED_OR_LESS_EQUAL, SLJIT_UNORDERED_OR_LESS,
    SLJIT_ORDERED_LESS, SLJIT_ORDERED_LESS_EQUAL, SLJIT_ORDERED_GREATER, SLJIT_ORDERED_GREATER_EQUAL,
    SLJIT_ORDERED_EQUAL, SLJIT_UNORDERED_OR_NOT_EQUAL,
};

fn bool is_jmp_reg(Opcode op) @inline => op.ordinal >= Opcode.JMP_NLT.ordinal && op.ordinal <= Opcode.JMP_SNEQ.ordinal;
fn bool is_jmp_imm(Opcode op) @inline => op.ordinal >= Opcode.JMP_NLTI.ordinal && op.ordinal <= Opcode.JMP_SNEQI.ordinal;

// Emit the inline path of the current instruction, falling through to the
// following one. False leaves it to the plain thunk call.
fn bool Asm.emit_fast(&self, bool consts_fixed) {
$if !types::USE_NANBOX:
    return false;
$else
    void* c = self.c;
    Instruction w = self.w;
    Opcode op = w.op;
    uint ra = w.a;
    uint rb = w.b;
    uint rc = w.c;
    if (is_jmp_reg(op) || is_jmp_imm(op)) {
        long t = self.target((int)(ichar)w.a);
        if (t < 0) return false;
        bool imm = is_jmp_imm(op);
        uint row = imm ? op.ordinal - Opcode.JMP_NLTI.ordinal : op.ordinal - Opcode.JMP_NLT.ordinal;
        self.load(R0, rb);
        self.guard_int_alt(R0);
        int r2 = R1;
        long r2w = 0;
        if (imm) {
            r2 = SLJIT_IMM;
            r2w = (long)(ichar)w.c << 16;
        } else {
            self.load(R1, rc);
            self.guard_int_alt(R1);
            sljit_emit_op2(c, SLJIT_SHL, R1, 0, R1, 0, SLJIT_IMM, 16);
        }
        sljit_emit_op2(c, SLJIT_SHL, R0, 0, R0, 0, SLJIT_IMM, 16);
        self.branch(false, JMP_INT_COND[row], r2, r2w, (uint)t, (ichar)w.a < 0);
        return true;
    }
    switch (op) {
        case LDINT:
            self.guard_dest(ra);
            self.store(ra, SLJIT_IMM, K_INT | ((long)w.get_sbc() & (PAYLOAD_SPAN - 1)));
        case LDINTX:
            // The LDINT before it left a fastint in A, so A holds no string.
            self.load(R0, ra);
            self.guard_int(R0);
            sljit_emit_op2(c, SLJIT_SHL, R0, 0, R0, 0, SLJIT_IMM, 16);
            sljit_emit_op2(c, SLJIT_OR, R0, 0, R0, 0, SLJIT_IMM, (long)w.get_bc());
            sljit_emit_op2(c, SLJIT_AND, R0, 0, R0, 0, SLJIT_IMM, PAYLOAD_SPAN - 1);
            sljit_emit_op2(c, SLJIT_OR, R0, 0, R0, 0, SLJIT_IMM, K_INT);
            self.store(ra, R0);
        case LDUNDEF:
        case LDNULL:
        case LDTRUE:
        case LDFALSE:
            TVal v;
            switch (op) {
                case LDUNDEF: v.set_undefined();
                case LDNULL: v.set_null();
                default: v.set_boolean(op == LDTRUE);
            }
            self.guard_dest(ra);
            self.store(ra, SLJIT_IMM, (long)v.bits);
        case LDCONST:
            uint index = w.get_bc();
            if (!consts_fixed || index >= self.f.const_count) return false;
            TVal v = self.f.constants[index];
            if (!v.is_inert()) return false;
            self.guard_dest(ra);
            self.store(ra, SLJIT_IMM, (long)v.bits);
        case LDREG:
            self.load(R0, rb);
            self.call.add(sljit_emit_cmp(c, SLJIT_GREATER_EQUAL, R0, 0, SLJIT_IMM, K_STRING_START));
            self.guard_dest(ra);
            self.store(ra, R0);
        case JUMP:
            int off = w.get_sabc();
            long t = self.target(off);
            if (t < 0) return false;
            if (off < 0) {
                self.back_edge();
                sljit_set_label(sljit_emit_jump(c, SLJIT_JUMP), self.labels[t]);
            } else {
                self.go(sljit_emit_jump(c, SLJIT_JUMP), (uint)t);
            }
        case IF_TRUE:
        case IF_FALSE:
            int off = w.get_sbc();
            long t = self.target(off);
            if (t < 0) return false;
            self.emit_if(op == IF_TRUE, ra, (uint)t, off < 0);
        case JMP_NULL:
        case JMP_NNULL:
            long t = self.target((int)(ichar)w.a);
            if (t < 0) return false;
            self.emit_jmp_null(op == JMP_NULL, rb, (uint)t, (ichar)w.a < 0);
        case JMP_EQ:
        case JMP_NEQ:
            long t = self.target((int)(ichar)w.a);
            if (t < 0) return false;
            self.load(R0, rb);
            self.guard_int(R0);
            self.load(R1, rc);
            self.guard_int(R1);
            self.branch(false, op == JMP_EQ ? SLJIT_EQUAL : SLJIT_NOT_EQUAL, R1, 0, (uint)t, (ichar)w.a < 0);
        case ADD:
        case ADD_FUSED:
        case SUB:
            self.load(R0, rb);
            self.guard_int_alt(R0);
            self.load(R1, rc);
            self.guard_int_alt(R1);
            if (ra != rb && ra != rc) self.guard_dest(ra);
            sljit_emit_op2(c, SLJIT_SHL, R0, 0, R0, 0, SLJIT_IMM, 16);
            sljit_emit_op2(c, SLJIT_SHL, R1, 0, R1, 0, SLJIT_IMM, 16);
            sljit_emit_op2(c, (op == SUB ? SLJIT_SUB : SLJIT_ADD) | SLJIT_SET_OVERFLOW, R0, 0, R0, 0, R1, 0);
            self.call.add(sljit_emit_jump(c, SLJIT_OVERFLOW));
            self.box_shifted(R0);
            self.store(ra, R0);
        case ADDI:
        case SUBI:
            self.load(R0, rb);
            self.guard_int_alt(R0);
            if (ra != rb) self.guard_dest(ra);
            long imm = (long)(ichar)w.c << 16;
            sljit_emit_op2(c, SLJIT_SHL, R0, 0, R0, 0, SLJIT_IMM, 16);
            sljit_emit_op2(c, (op == SUBI ? SLJIT_SUB : SLJIT_ADD) | SLJIT_SET_OVERFLOW, R0, 0, R0, 0, SLJIT_IMM, imm);
            self.call.add(sljit_emit_jump(c, SLJIT_OVERFLOW));
            self.box_shifted(R0);
            self.store(ra, R0);
        case INC:
        case INC_LT:
        case DEC:
            self.load(R0, ra);
            self.guard_int_alt(R0);
            sljit_emit_op2(c, SLJIT_SHL, R0, 0, R0, 0, SLJIT_IMM, 16);
            sljit_emit_op2(c, (op == DEC ? SLJIT_SUB : SLJIT_ADD) | SLJIT_SET_OVERFLOW, R0, 0, R0, 0, SLJIT_IMM, 1L << 16);
            self.call.add(sljit_emit_jump(c, SLJIT_OVERFLOW));
            self.box_shifted(R0);
            self.store(ra, R0);
        case TONUMERIC:
            // A number is its own ToNumeric.
            self.load(R0, rb);
            self.call.add(sljit_emit_cmp(c, SLJIT_GREATER_EQUAL, R0, 0, SLJIT_IMM, K_INT + PAYLOAD_SPAN));
            if (ra != rb) self.guard_dest(ra);
            self.store(ra, R0);
        case MUL:
        case MULI:
            self.emit_mul(op == MULI, ra, rb, rc);
        case DIV:
            self.emit_number_binop(SLJIT_DIV_F64, ra, rb, rc);
        case BAND:
        case BOR:
        case BXOR:
        case SHL:
        case SHR:
        case USHR:
        case BANDI:
        case BORI:
        case BXORI:
        case SHLI:
        case SHRI:
        case USHRI:
            self.emit_bitop(op, ra, rb, rc);
        case EQ:
        case NEQ:
        case SEQ:
        case SNEQ:
            bool negate = op == NEQ || op == SNEQ;
            self.emit_compare(negate ? SLJIT_NOT_EQUAL : SLJIT_EQUAL, false, ra, rb, rc);
        case LT:
        case LE:
        case GT:
        case GE:
            self.emit_compare(JMP_INT_COND[4 + op.ordinal - Opcode.LT.ordinal], true, ra, rb, rc);
        default:
            return false;
    }
    return true;
$endif
}

// The number path entered when an operand is not a fastint.
fn void Asm.emit_alt(&self) {
    void* c = self.c;
    Instruction w = self.w;
    Opcode op = w.op;
    if (is_jmp_reg(op) || is_jmp_imm(op)) {
        bool imm = is_jmp_imm(op);
        uint row = imm ? op.ordinal - Opcode.JMP_NLTI.ordinal : op.ordinal - Opcode.JMP_NLT.ordinal;
        self.load_number(FR0, w.b);
        if (imm) {
            self.load_imm_number(FR1, (long)(ichar)w.c);
        } else {
            self.load_number(FR1, w.c);
        }
        uint t = (uint)self.target((int)(ichar)w.a);
        self.branch(true, JMP_FLOAT_COND[row], 0, 0, t, (ichar)w.a < 0);
        self.go(sljit_emit_jump(c, SLJIT_JUMP), self.next);
        return;
    }
    switch (op) {
        case ADD:
        case ADD_FUSED: self.emit_number_binop(SLJIT_ADD_F64, w.a, w.b, w.c);
        case SUB:       self.emit_number_binop(SLJIT_SUB_F64, w.a, w.b, w.c);
        case MUL:       self.emit_number_binop(SLJIT_MUL_F64, w.a, w.b, w.c);
        case ADDI:
        case SUBI:
            self.guard_dest(w.a);
            self.load_number(FR0, w.b);
            self.load_imm_number(FR1, (long)(ichar)w.c);
            sljit_emit_fop2(c, op == SUBI ? SLJIT_SUB_F64 : SLJIT_ADD_F64, FR0, 0, FR0, 0, FR1, 0);
            self.store_number(w.a);
        case INC:
        case INC_LT:
        case DEC:
            // A number register holds no string to release.
            self.load_number(FR0, w.a);
            self.load_imm_number(FR1, 1);
            sljit_emit_fop2(c, op == DEC ? SLJIT_SUB_F64 : SLJIT_ADD_F64, FR0, 0, FR0, 0, FR1, 0);
            self.store_number(w.a);
        case LT:
        case LE:
        case GT:
        case GE:
            self.guard_dest(w.a);
            self.load_number(FR0, w.b);
            self.load_number(FR1, w.c);
            self.bool_result(true, JMP_FLOAT_COND[4 + op.ordinal - Opcode.LT.ordinal], w.a);
        default:
            unreachable("no number path for %s", op);
    }
    self.go(sljit_emit_jump(c, SLJIT_JUMP), self.next);
}

// A = B <fop> C on two numbers; anything else takes the slow path.
fn void Asm.emit_number_binop(&self, int fop, uint ra, uint rb, uint rc) {
    self.guard_dest(ra);
    self.load_number(FR0, rb);
    self.load_number(FR1, rc);
    sljit_emit_fop2(self.c, fop, FR0, 0, FR0, 0, FR1, 0);
    self.store_number(ra);
}

// Store the boolean `cond` over (R0, R1) or (FR0, FR1) into register `r`.
fn void Asm.bool_result(&self, bool fl, int cond, uint r) {
    void* c = self.c;
    sljit_emit_op1(c, SLJIT_MOV, R2, 0, SLJIT_IMM, K_BOOL | 1);
    void* holds = fl ? sljit_emit_fcmp(c, cond, FR0, 0, FR1, 0) : sljit_emit_cmp(c, cond, R0, 0, R1, 0);
    sljit_emit_op1(c, SLJIT_MOV, R2, 0, SLJIT_IMM, K_BOOL);
    sljit_set_label(holds, sljit_emit_label(c));
    self.store(r, R2);
}

// EQ..SNEQ and LT..GE on two fastints; relational operators also take
// numbers out of line.
fn void Asm.emit_compare(&self, int cond, bool relational, uint ra, uint rb, uint rc) {
    void* c = self.c;
    self.load(R0, rb);
    self.load(R1, rc);
    if (relational) {
        self.guard_int_alt(R0);
        self.guard_int_alt(R1);
        sljit_emit_op2(c, SLJIT_SHL, R0, 0, R0, 0, SLJIT_IMM, 16);
        sljit_emit_op2(c, SLJIT_SHL, R1, 0, R1, 0, SLJIT_IMM, 16);
    } else {
        self.guard_int(R0);
        self.guard_int(R1);
    }
    self.guard_dest(ra);
    self.bool_result(false, cond, ra);
}

// MUL and MULI as th_mul and th_muli: fastint operands within 31 bits whose
// product fits a fastint and is not -0.
fn void Asm.emit_mul(&self, bool imm, uint ra, uint rb, uint rc) {
    void* c = self.c;
    self.load(R0, rb);
    if (imm) {
        self.guard_int(R0);
    } else {
        self.guard_int_alt(R0);
        self.load(R1, rc);
        self.guard_int_alt(R1);
    }
    if (ra != rb && (imm || ra != rc)) self.guard_dest(ra);
    sljit_emit_op2(c, SLJIT_SHL, R0, 0, R0, 0, SLJIT_IMM, 16);
    sljit_emit_op2(c, SLJIT_ADD, R2, 0, R0, 0, SLJIT_IMM, 1L << 46);
    self.call.add(sljit_emit_cmp(c, SLJIT_GREATER_EQUAL, R2, 0, SLJIT_IMM, 1L << 47));
    if (imm) {
        sljit_emit_op1(c, SLJIT_MOV, R1, 0, SLJIT_IMM, (long)(ichar)rc);
    } else {
        sljit_emit_op2(c, SLJIT_SHL, R1, 0, R1, 0, SLJIT_IMM, 16);
        sljit_emit_op2(c, SLJIT_ADD, R2, 0, R1, 0, SLJIT_IMM, 1L << 46);
        self.call.add(sljit_emit_cmp(c, SLJIT_GREATER_EQUAL, R2, 0, SLJIT_IMM, 1L << 47));
        sljit_emit_op2(c, SLJIT_ASHR, R1, 0, R1, 0, SLJIT_IMM, 16);
    }
    sljit_emit_op2(c, SLJIT_XOR, R2, 0, R0, 0, R1, 0);
    sljit_emit_op2(c, SLJIT_MUL | SLJIT_SET_OVERFLOW, R0, 0, R0, 0, R1, 0);
    self.call.add(sljit_emit_jump(c, SLJIT_OVERFLOW));
    void* nonzero = sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R0, 0, SLJIT_IMM, 0);
    self.call.add(sljit_emit_cmp(c, SLJIT_SIG_LESS, R2, 0, SLJIT_IMM, 0));
    sljit_set_label(nonzero, sljit_emit_label(c));
    self.box_shifted(R0);
    self.store(ra, R0);
}

// The bitwise and shift operators on fastints, as th_bitop.
fn void Asm.emit_bitop(&self, Opcode op, uint ra, uint rb, uint rc) {
    void* c = self.c;
    bool imm = bytecode::is_imm_form(op);
    Opcode base = imm ? bytecode::reg_form(op) : op;
    self.load(R0, rb);
    self.guard_int(R0);
    int src = SLJIT_IMM;
    long srcw = (long)(rc & 0xFF);
    if (!imm) {
        self.load(R1, rc);
        self.guard_int(R1);
        src = R1;
        srcw = 0;
    }
    if (ra != rb && (imm || ra != rc)) self.guard_dest(ra);
    int sop;
    switch (base) {
        case BAND: sop = SLJIT_AND;
        case BOR:  sop = SLJIT_OR;
        case BXOR: sop = SLJIT_XOR;
        case SHL:  sop = SLJIT_MSHL;
        case SHR:  sop = SLJIT_MASHR;
        default:   sop = SLJIT_MLSHR;
    }
    if (src == SLJIT_IMM && sop != SLJIT_AND && sop != SLJIT_OR && sop != SLJIT_XOR) {
        // An immediate count is masked by the operation width.
        srcw &= 0x1F;
    }
    sljit_emit_op2(c, sop | SLJIT_32, R0, 0, R0, 0, src, srcw);
    sljit_emit_op1(c, base == USHR ? SLJIT_MOV_U32 : SLJIT_MOV_S32, R0, 0, R0, 0);
    sljit_emit_op2(c, SLJIT_AND, R0, 0, R0, 0, SLJIT_IMM, PAYLOAD_SPAN - 1);
    sljit_emit_op2(c, SLJIT_OR, R0, 0, R0, 0, SLJIT_IMM, K_INT);
    self.store(ra, R0);
}

// IF_TRUE / IF_FALSE on a boolean, fastint, double, object, undefined or null, as
// is_truthy decides them; anything else takes the slow path.
fn void Asm.emit_if(&self, bool on_true, uint r, uint target, bool backward) {
    void* c = self.c;
    Jumps truthy;
    Jumps falsy;
    self.load(R0, r);
    sljit_emit_op2(c, SLJIT_XOR, R1, 0, R0, 0, SLJIT_IMM, K_BOOL);
    void* not_bool = sljit_emit_cmp(c, SLJIT_GREATER_EQUAL, R1, 0, SLJIT_IMM, 2);
    truthy.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R1, 0, SLJIT_IMM, 0));
    falsy.add(sljit_emit_jump(c, SLJIT_JUMP));
    sljit_set_label(not_bool, sljit_emit_label(c));
    sljit_emit_op2(c, SLJIT_XOR, R1, 0, R0, 0, SLJIT_IMM, K_INT);
    void* not_int = sljit_emit_cmp(c, SLJIT_GREATER_EQUAL, R1, 0, SLJIT_IMM, PAYLOAD_SPAN);
    sljit_emit_op2(c, SLJIT_SHL, R1, 0, R1, 0, SLJIT_IMM, 16);
    truthy.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R1, 0, SLJIT_IMM, 0));
    falsy.add(sljit_emit_jump(c, SLJIT_JUMP));
    sljit_set_label(not_int, sljit_emit_label(c));
    // A double is truthy unless it is zero or NaN.
    void* not_double = sljit_emit_cmp(c, SLJIT_GREATER_EQUAL, R0, 0, SLJIT_IMM, K_INT);
    sljit_emit_fcopy(c, SLJIT_COPY_TO_F64, FR0, R0);
    self.load_imm_number(FR1, 0);
    truthy.add(sljit_emit_fcmp(c, SLJIT_ORDERED_NOT_EQUAL, FR0, 0, FR1, 0));
    falsy.add(sljit_emit_jump(c, SLJIT_JUMP));
    sljit_set_label(not_double, sljit_emit_label(c));
    falsy.add(sljit_emit_cmp(c, SLJIT_EQUAL, R0, 0, SLJIT_IMM, K_UNDEF));
    falsy.add(sljit_emit_cmp(c, SLJIT_EQUAL, R0, 0, SLJIT_IMM, K_NULL));
    sljit_emit_op2(c, SLJIT_XOR, R1, 0, R0, 0, SLJIT_IMM, K_OBJ);
    self.call.add(sljit_emit_cmp(c, SLJIT_GREATER_EQUAL, R1, 0, SLJIT_IMM, PAYLOAD_SPAN));
    // An object is truthy unless it is the realm's [[IsHTMLDDA]] object.
    sljit_emit_op1(c, SLJIT_MOV, R2, 0, SLJIT_MEM | self.heap, self.htmldda_off);
    self.call.add(sljit_emit_cmp(c, SLJIT_EQUAL, R1, 0, R2, 0));
    truthy.add(sljit_emit_jump(c, SLJIT_JUMP));
    if (on_true) {
        self.finish_test(&truthy, &falsy, target, backward);
    } else {
        self.finish_test(&falsy, &truthy, target, backward);
    }
}

// JMP_NULL / JMP_NNULL, as th_jmp_null.
fn void Asm.emit_jmp_null(&self, bool on_null, uint r, uint target, bool backward) {
    void* c = self.c;
    Jumps nullish;
    Jumps other;
    self.load(R0, r);
    nullish.add(sljit_emit_cmp(c, SLJIT_EQUAL, R0, 0, SLJIT_IMM, K_UNDEF));
    nullish.add(sljit_emit_cmp(c, SLJIT_EQUAL, R0, 0, SLJIT_IMM, K_NULL));
    sljit_emit_op2(c, SLJIT_XOR, R1, 0, R0, 0, SLJIT_IMM, K_OBJ);
    other.add(sljit_emit_cmp(c, SLJIT_GREATER_EQUAL, R1, 0, SLJIT_IMM, PAYLOAD_SPAN));
    sljit_emit_op1(c, SLJIT_MOV, R2, 0, SLJIT_MEM | self.heap, self.htmldda_off);
    self.call.add(sljit_emit_cmp(c, SLJIT_EQUAL, R1, 0, R2, 0));
    other.add(sljit_emit_jump(c, SLJIT_JUMP));
    if (on_null) {
        self.finish_test(&nullish, &other, target, backward);
    } else {
        self.finish_test(&other, &nullish, target, backward);
    }
}

// The thunk of each opcode, null for those without one.
Thunk[Opcode::values.len] thunk_table @private;
bool thunks_ready @private;

fn Thunk[] thunks() @inline {
    if (!thunks_ready) init_thunks();
    return &thunk_table;
}

fn void init_thunks() @noinline @private {
    $foreach $op : Opcode::values:
        $if !@excluded($op):
            thunk_table[$op.ordinal] = fn long(Dispatch* ds, ulong arg) {
                Instruction* next = (Instruction*)(usz)(arg & ~1UL);
                ds.curr_pc = next;
                Instruction p = next[-1];
                DecodedInsn insn = { .op = $op, .a = p.a, .b = p.b, .c = p.c };
                if ((arg & 1) != 0) {
                    Instruction x = next[-2];
                    insn.a |= (uint)x.a << 8;
                    insn.b |= (uint)x.b << 8;
                    insn.c |= (uint)x.c << 8;
                }
                // The interpreter switches a constant-key read between its
                // cached and uncached forms by rewriting the opcode in place.
                $if $op == Opcode.GETPROPC || $op == Opcode.GETPROPC_CACHED:
                    insn.op = p.op;
                $endif
                Activation* act = ds.act;
                CompiledFunction* func = ds.vm.current_func;
                OpStatus s = @run_op($op, ds, insn);
                if (s == NEXT && ds.needs_restart) return (long)OpStatus.RESTART.ordinal;
                // A frame switched to in place is the caller a native call
                // site waits for when the depth is back at its floor, and is
                // otherwise entered through Vm.run.
                if (s == NEXT && (ds.act != act || ds.vm.current_func != func)
                    && ds.vm.activation_count == ds.jit_floor) {
                    ds.act.curr_pc = ds.curr_pc;
                    return BASELINE_RETURNED;
                }
                s = vm::jit_restart_switched(ds, act, func, s);
                if (s == NEXT && ds.curr_pc != next) return BASELINE_REDISPATCH;
                return (long)s.ordinal;
            };
        $endif
    $endforeach
    thunks_ready = true;
}

// Opcodes without a thunk: the WIDE prefix, which is never dispatched alone,
// the generator and async suspension ops, and `with` scope entry and exit.
macro bool @excluded(Opcode $op) @const {
    $switch $op:
        $case Opcode.WIDE:
        $case Opcode.LAST_OP:
        $case Opcode.LOAD_RESUME:
        $case Opcode.AWAIT:
        $case Opcode.YIELD:
        $case Opcode.YIELD_STAR:
        $case Opcode.YIELD_STAR_ASYNC:
        $case Opcode.GEN_START:
        $case Opcode.RET_GEN:
        $case Opcode.RETUNDEF_GEN:
        $case Opcode.WITH_START:
        $case Opcode.WITH_END:
            return true;
        $default:
            return false;
    $endswitch
}

// The operation function vm_dispatch runs for `$op`.
macro OpStatus @run_op(Opcode $op, Dispatch* ds, DecodedInsn insn) {
    $if ($op.ordinal >= Opcode.JMP_NLT.ordinal && $op.ordinal <= Opcode.JMP_SNEQ.ordinal)
            || ($op.ordinal >= Opcode.JMP_NLTI.ordinal && $op.ordinal <= Opcode.JMP_SNEQI.ordinal):
        return vm::op_jmp_cmp(ds, insn);
    $else
    $switch $op:
        $case Opcode.LDREG:    return vm::op_ldreg(ds, insn);
        $case Opcode.LDCONST:  return vm::op_ldconst(ds, insn);
        $case Opcode.SETCONST: return vm::op_setconst(ds, insn);
        $case Opcode.LDINT:    return vm::op_ldint(ds, insn);
        $case Opcode.LDINTX:   return vm::op_ldintx(ds, insn);
        $case Opcode.LDUNDEF:  return vm::op_ldundef(ds, insn);
        $case Opcode.LDNULL:   return vm::op_ldnull(ds, insn);
        $case Opcode.LDTRUE:   return vm::op_ldtrue(ds, insn);
        $case Opcode.LDFALSE:  return vm::op_ldfalse(ds, insn);
        $case Opcode.LDTHIS:
        $case Opcode.GETTHISC:
        $case Opcode.PUTTHISC: return vm::op_ldthis(ds, insn);

        $case Opcode.ADD_FUSED:
        $case Opcode.ADD:      return vm::op_add(ds, insn);
        $case Opcode.SUB:      return vm::op_sub(ds, insn);
        $case Opcode.ADDI:     return vm::op_addi(ds, insn);
        $case Opcode.STRJOIN:
        $case Opcode.STRJOIN_LENGTH: return vm::op_strjoin(ds, insn);
        $case Opcode.SUBI:     return vm::op_subi(ds, insn);
        $case Opcode.MUL:
        $case Opcode.MULI:     return vm::op_mul(ds, insn);
        $case Opcode.DIV:      return vm::op_div(ds, insn);
        $case Opcode.MOD:      return vm::op_mod(ds, insn);
        $case Opcode.EXP:      return vm::op_exp(ds, insn);

        $case Opcode.UNP:
        $case Opcode.UNM:
        $case Opcode.BNOT:
        $case Opcode.LNOT:
        $case Opcode.TYPEOF:
        $case Opcode.VOID:
        $case Opcode.TONUMERIC:
        $case Opcode.INC:
        $case Opcode.INC_LT:
        $case Opcode.DEC:
        $case Opcode.PUTARG:
        $case Opcode.INC_VAR:
        $case Opcode.DEC_VAR:
        $case Opcode.INC_GLOBAL:
        $case Opcode.DEC_GLOBAL: return vm::op_unary(ds, insn);

        $case Opcode.BAND:
        $case Opcode.BANDI:    return vm::op_band(ds, insn);
        $case Opcode.BOR:
        $case Opcode.BORI:     return vm::op_bor(ds, insn);
        $case Opcode.BXOR:
        $case Opcode.BXORI:    return vm::op_bxor(ds, insn);
        $case Opcode.SHL:
        $case Opcode.SHLI:     return vm::op_shl(ds, insn);
        $case Opcode.SHR:
        $case Opcode.SHRI:     return vm::op_shr(ds, insn);
        $case Opcode.USHR:
        $case Opcode.USHRI:    return vm::op_ushr(ds, insn);

        $case Opcode.EQ:       return vm::op_eq(ds, insn);
        $case Opcode.NEQ:      return vm::op_neq(ds, insn);
        $case Opcode.SEQ:      return vm::op_seq(ds, insn);
        $case Opcode.SNEQ:     return vm::op_sneq(ds, insn);
        $case Opcode.LT:
        $case Opcode.LE:
        $case Opcode.GT:
        $case Opcode.GE:       return vm::op_lt(ds, insn);
        $case Opcode.JMP_EQ:
        $case Opcode.JMP_NEQ:  return vm::op_jmp_eq(ds, insn);
        $case Opcode.JMP_NULL:
        $case Opcode.JMP_NNULL: return vm::op_jmp_null(ds, insn);
        $case Opcode.INSTANCEOF: return vm::op_instanceof(ds, insn);
        $case Opcode.IN:       return vm::op_in(ds, insn);

        $case Opcode.JUMP:     return vm::op_jump(ds, insn);
        $case Opcode.IF_TRUE:
        $case Opcode.IF_FALSE: return vm::op_if(ds, insn);

        $case Opcode.GETPROPC_CACHED:
        $case Opcode.GETPROP:
        $case Opcode.GETPROP_CACHE:
        $case Opcode.GETPROPC:
        $case Opcode.PUTPROP:
        $case Opcode.PUTPROP_NE:
        $case Opcode.PUTPROP_SUPER:
        $case Opcode.GETPROP_SUPER:
        $case Opcode.DELPROP:  return vm::op_property(ds, insn);
        $case Opcode.PUTPROPC: return vm::op_putpropc(ds, insn);
        $case Opcode.TOPROPKEY: return vm::op_topropkey(ds, insn);
        $case Opcode.TOSTR:    return vm::op_tostr(ds, insn);
        $case Opcode.RETEST:   return vm::op_retest(ds, insn);
        $case Opcode.HOF_GUARD: return vm::op_hof_guard(ds, insn);
        $case Opcode.HOF_ELEM: return vm::op_hof_elem(ds, insn);
        $case Opcode.HOF_GET:  return vm::op_hof_get(ds, insn);
        $case Opcode.HOF_NEWARR: return vm::op_hof_newarr(ds, insn);
        $case Opcode.HOF_PUT:  return vm::op_hof_put(ds, insn);

        $case Opcode.SPREAD_PROJECTION:
        $case Opcode.NEWOBJ_SHAPE:
        $case Opcode.INIT_SLOT:
        $case Opcode.NEWOBJ:
        $case Opcode.NEWARR:
        $case Opcode.NEWARR_CONST:
        $case Opcode.NEWREGEXP:
        $case Opcode.SETALEN:
        $case Opcode.FREEZEOBJ:
        $case Opcode.ARRSPRD:
        $case Opcode.OBJSPRD:
        $case Opcode.OBJREST:
        $case Opcode.SPREAD_ARG:
        $case Opcode.FWD_ARGS:
        $case Opcode.APPLY_ARGS: return vm::op_objects(ds, insn);

        $case Opcode.CALL:
        $case Opcode.CALL_S:
        $case Opcode.CALL_UNDEF_THIS:
        $case Opcode.CALL_VAR:
        $case Opcode.CALL_GLOBAL:
        $case Opcode.TAILCALL_UNDEF_THIS:
        $case Opcode.TAILCALL_VAR:
        $case Opcode.TAILCALL_GLOBAL:
        $case Opcode.TAILCALL_CALL:
        $case Opcode.TAILCALL_CALL_S: return vm::op_call(ds, insn);

        $case Opcode.CALL_PROP:
        $case Opcode.SETPROTO:
        $case Opcode.GETPROTO:
        $case Opcode.SUPER_CALL:
        $case Opcode.SUPER_CALL_S:
        $case Opcode.NEWTARGET:
        $case Opcode.CLASS_SCALAR_GUARD:
        $case Opcode.NEW_OBJ:
        $case Opcode.NEW_OBJ_S:
        $case Opcode.TAILCALL: return vm::op_calls(ds, insn);

        $case Opcode.DYN_IMPORT:
        $case Opcode.DYN_IMPORT_DEFER:
        $case Opcode.DYN_IMPORT_SOURCE: return vm::op_dyn_import(ds, insn);
        $case Opcode.IMPORT_META: return vm::op_import_meta(ds, insn);

        $case Opcode.RET:
        $case Opcode.RETUNDEF: return vm::op_ret(ds, insn);

        $case Opcode.RESOLVEVAR: return vm::op_resolvevar(ds, insn);
        $case Opcode.THROW_UNRESOLVED: return vm::op_throw_unresolved(ds, insn);

        $case Opcode.GETCAP:
        $case Opcode.GETVAR:
        $case Opcode.GETGLOBAL:
        $case Opcode.TYPEOFIDENT: return vm::op_getvar(ds, insn);
        $case Opcode.PUTGLOBAL: return vm::op_putglobal(ds, insn);
        $case Opcode.PUTVAR:   return vm::op_putvar(ds, insn);
        $case Opcode.PUTCAP:
        $case Opcode.PUTVAR_ASSIGN: return vm::op_putvar_assign(ds, insn);
        $case Opcode.PUTCAP_SNAP:
        $case Opcode.PUTVAR_SNAP: return vm::op_putvar_snap(ds, insn);
        $case Opcode.DECLGLOBALFUNC: return vm::op_declglobalfunc(ds, insn);
        $case Opcode.DECLB33GLOBAL: return vm::op_declb33global(ds, insn);
        $case Opcode.DECLVAR_HOIST: return vm::op_declvar_hoist(ds, insn);
        $case Opcode.DECLVAR:  return vm::op_declvar(ds, insn);
        $case Opcode.PUTLEX:   return vm::op_putlex(ds, insn);
        $case Opcode.PUTLEX_C: return vm::op_putlex_c(ds, insn);
        $case Opcode.INITTZ:   return vm::op_inittz(ds, insn);
        $case Opcode.CHKGLOBALLEX:
        $case Opcode.CHKGLOBALVAR:
        $case Opcode.CHKGLOBALFUNC: return vm::op_chkglobal(ds, insn);
        $case Opcode.DELVAR:   return vm::op_delvar(ds, insn);

        $case Opcode.WITHGET:  return vm::op_withget(ds, insn);
        $case Opcode.WITHBASE: return vm::op_withbase(ds, insn);
        $case Opcode.WTWR:     return vm::op_wtwr(ds, insn);

        $case Opcode.NEWCELLS:
        $case Opcode.GETCELL:
        $case Opcode.SETCELL:
        $case Opcode.MOVECELL: return vm::op_cells(ds, insn);
        $case Opcode.CLOSURE:
        $case Opcode.GETBOUND: return vm::op_closure(ds, insn);

        $case Opcode.INITFOR:
        $case Opcode.NEXTFOR:
        $case Opcode.ITER_NEXT_FAST:
        $case Opcode.ITER_ENTRY_FAST:
        $case Opcode.ARRAY_PATTERN_GUARD:
        $case Opcode.ITER_OPEN_FAST:
        $case Opcode.DESTRUCT_ARRAY_FAST:
        $case Opcode.DESTRUCT_ARRAY_REST_FAST: return vm::op_iterator(ds, insn);

        $case Opcode.TRY:
        $case Opcode.ENDTRY:
        $case Opcode.THROW:
        $case Opcode.THROW_REF:
        $case Opcode.THROW_SYNTAX:
        $case Opcode.CATCH:
        $case Opcode.FINALLY:
        $case Opcode.ENDFINALLY: return vm::op_exceptions(ds, insn);

        $case Opcode.NOP:
        $case Opcode.DEBUGGER:
        $case Opcode.BREAK:
        $case Opcode.CONTINUE:
        $case Opcode.INITGET:
        $case Opcode.INITSET:
        $case Opcode.INITSETI:
        $case Opcode.INITPROP:
        $case Opcode.INITELEM:
        $case Opcode.INITPROPN:
        $case Opcode.CLASS_INITGET:
        $case Opcode.CLASS_INITSET:
        $case Opcode.CLASS_INITPROP:
        $case Opcode.CSVARI:
        $case Opcode.PUSH_LEX:
        $case Opcode.POP_LEX:
        $case Opcode.PUSH_VAR:
        $case Opcode.POP_VAR:
        $case Opcode.REQUIRE_OBJ:
        $case Opcode.CHKOBJ:
        $case Opcode.CHKITER:
        $case Opcode.ITER_CLOSE:
        $case Opcode.ITER_CLOSE_ESCAPE:
        $case Opcode.GET_ITER_ASYNC:
        $case Opcode.ITER_CLOSE_ASYNC:
        $case Opcode.CHKCTOR:
        $case Opcode.CHK_PROT:
        $case Opcode.NEW_PRIV_SYM:
        $case Opcode.ADD_BRAND:
        $case Opcode.CHK_BRAND:
        $case Opcode.HAS_BRAND:
        $case Opcode.INITPROP_PRIV:
        $case Opcode.GETPROP_PRIVATE: return vm::op_misc(ds, insn);

        $default:
            $error "Opcode has no baseline thunk; add it to @run_op or @excluded.";
    $endswitch
    $endif
}
