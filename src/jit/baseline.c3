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
// handlers would enter as a lean call, and a NEW_OBJ or APPLY_ARGS the
// threaded handlers enter, whose callee has native code, runs it from C
// (vm::jit_call), the callee's frame returning to jit_enter's trampoline. The
// call saves ds.jit_floor in its C frame and sets it to the caller's
// activation count; the callee's frame sits one above. A thunk that leaves
// the activation count equal to the floor after switching frames returns
// BASELINE_RETURNED, and the call site restores the floor, reloads the
// caller's frame and continues at the following instruction, or through the
// entry table when a handler moved ds.curr_pc. Vm.run clears the floor (0,
// never a live count after a switch), so a frame it entered returns with
// RESTART. Any other status returns from the shared native frame
// (Asm.set_frame), abandoning every generated frame in it; the activation
// stack describes the truth and each abandoned caller resumes later through
// the entry table at its saved curr_pc. A RESTART from code Vm.run entered
// whose new frame has native code continues there instead (vm::jit_switch),
// and a plain return from such code pops its frame and restarts the same way
// (vm::jit_ret). Calls from C nest at most vm::JIT_NATIVE_DEPTH_CAP deep per
// Dispatch; calls between generated frames use no C stack.
//
// Instructions that need no runtime call in the common case (register
// loads, jumps and branches, number arithmetic, comparisons and bitwise ops)
// run inline. They guard their operand tags as the threaded handlers do and
// take their slow path on any failed guard: out of line, a number path where the
// threaded handlers have one, then the thunk call. A backward branch charges
// the GC budget inline and takes the slow path when it expires or an
// interrupt hook is installed, so vm_branch runs the safepoint. Property,
// global, variable and capture access run their inline cache hits inline
// (baseline_access.c3).
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
// Every opcode but the WIDE prefix has a thunk; a WIDE pair runs the inline
// path of its opcode where the operands read the same widened. Generators
// and async functions suspend through their thunks and resume through the
// entry table once the resume has restored the frame.
//
// Functions compile at their BASELINE_ENTRY_THRESHOLD-th entry. An
// interpreted backward branch that uses up the GC budget credits its function
// BASELINE_LOOP_CREDIT entries (vm_branch, which both dispatchers reach on
// expiry); once the function has code, Vm.run restarts and enters it at the
// branch target. Script, module and eval top-level code runs once and
// compiles only this way.
module boomkat::jit @feat(SLJIT);

import boomkat::vm;
import boomkat::bytecode;
import boomkat::builtins;
import boomkat::compiler;
import boomkat::heap;
import boomkat::hobject;
import boomkat::hstring;
import boomkat::types;
import std::collections::list;
import std::io;
import std::time::clock;

// Compiles of one function before it stays interpreted.
const char BASELINE_MAX_ATTEMPTS = 2;
// Frame entries before a function compiles without --jit-stress. Code is
// kept for the CompiledFunction's lifetime, so functions run only a few times
// (loaded code, initializers) stay interpreted rather than fill the cap.
const uint BASELINE_ENTRY_THRESHOLD = 32;
// Entries an eval-derived function needs before it compiles. A library
// evaled once (zlib) reaches this quickly; a source a loader recreates per
// load (CodeLoad) discards each body before it does, so its compiles, which
// would all be thrown away, never happen.
const uint BASELINE_EVAL_ENTRY_THRESHOLD = 256;
// Entries one expiry of the back-edge budget (heap::BWD_GC_INTERVAL backward
// branches, counted across all frames) credits to the function whose branch
// used it up. One expiry must not pay for a whole compile: a cold call needs
// two expiries of a genuinely hot loop before it compiles.
const uint BASELINE_LOOP_CREDIT = BASELINE_ENTRY_THRESHOLD - 1;
// Generated code and entry tables, in bytes, past which compiles are refused.
const usz BASELINE_CODE_CAP = 64 * 1024 * 1024;
// Instruction words past which a function stays interpreted. Code grows by
// about 80 bytes and the compile's transient memory by a few hundred bytes per
// word, and one compile is one pause, so a function this large (generated
// initializers, mostly) costs more than native code would save.
const uint BASELINE_MAX_WORDS = 65536;
// Maximum share of a body's instruction words that may emit a thunk call, in
// percent. A relay/thunk call pays the interpreter's dispatch plus the native
// frame's fast call, register reload and return, so a body past this share
// cannot repay that overhead with the inline work that remains. 60 keeps mixed
// bodies, whose loads, jumps and arithmetic still win, compiled: it rejects
// only the relay-dominated bodies that lose to plain interpretation.
const uint BASELINE_MAX_THUNK_FRACTION = 60;
// Code bytes per instruction word, used only to estimate a compile's size
// before codegen so a cap-full compile does not pay for code it will discard.
const usz BASELINE_BYTES_PER_WORD = 80;
// A native run's result when its target is not an instruction start: the
// interpreter continues the frame.
const long BASELINE_INTERPRET = OpStatus::values.len;

struct JitStats {
    // Bytes of every compile so far; live_bytes counts the code and tables
    // not yet freed, which BASELINE_CODE_CAP bounds, and peak_bytes its maximum.
    usz code_bytes;
    usz table_bytes;
    usz live_bytes;
    usz peak_bytes;
    usz insns;
    uint compiled;
    // Compiles made by a hot interpreted loop, which then continued natively.
    uint loop_entries;
    uint excluded_opcode;
    uint too_large;
    uint failed;
    uint capped;
    // Policy skips, not compile failures: a relay-dominated body and one-shot
    // eval code cannot repay a compile, so they stay interpreted without a
    // permanent refusal.
    uint skipped_unprofitable;
    uint skipped_eval;
    // Baseline bodies dropped to keep the cap transient, and the sweeps run.
    // An installed body is stamped with compile_seq; retired bodies wait on
    // retired_code until no native frame can still be running their code.
    ulong evicted;
    ulong sweeps;
    uint compile_seq;
    void* retired_code;
    // Native call sites: callees entered natively, trivial callees completed
    // in place, and calls left to the thunk because the callee had no native
    // code yet, the depth cap was reached, a method callee was not a compiled
    // function (builtins, bound functions), or the lean shape declined.
    ulong calls_native;
    ulong calls_trivial;
    ulong calls_no_code;
    ulong calls_depth;
    ulong calls_builtin;
    // The builtin calls a native call site completed itself
    // (vm::jit_call_builtin_native) instead of returning through the thunk.
    ulong calls_builtin_direct;
    ulong calls_declined;
    // Declined calls whose pushed frame ran nested natively (jit_enter_pushed), and those left
    // to the restart, which unwinds the native frames to Vm.run.
    ulong calls_pushed;
    ulong calls_restarted;
    // Restarts that continued in the new frame's native code without Vm.run.
    ulong switches;
    // Compile wall time, in nanoseconds, measured only while timing is set
    // (--jit-stats): the total, the longest single compile and its size.
    bool timing;
    ulong compile_ns;
    ulong compile_max_ns;
    uint compile_max_insns;
    // Per-opcode counts of inline completions and thunk calls, emitted only
    // into code compiled while count_ops is set (--jit-count-ops).
    bool count_ops;
    // Print every instruction's recorded operand feedback at exit (--jit-dump-feedback).
    bool dump_feedback;
    // Also print the bytes of each optimized body as it is compiled, for scripts/jit_disasm.py
    // (--jit-dump-code).
    bool dump_code;
    ulong[Opcode::values.len] fast_hits;
    ulong[Opcode::values.len] slow_calls;
    // Thunk calls the threaded handler or the builtin call path completed
    // without the operation function, moved out of slow_calls at run time.
    ulong[Opcode::values.len] relay_done;
    // Inline reads answered by an entry's polymorphic set.
    ulong[Opcode::values.len] poly_hits;
}

// The run-time state of one inlined NEW_OBJ (baseline_alloc.c3 Asm.emit_new_inline), armed by
// vm::jit_new_simple: for a simple constructor once it has built an object from the constructor's
// cached stores, which the emitted code then replays; for any other plain constructor with a call
// entry (count NEW_SITE_CALLS), whose body the emitted code calls with the object it allocated.
// The emitted code builds the object itself while the callee is a closure of `cf`, and the
// constructor's shape and `prototype` slot, the prototype's shape and the heap's prototype and
// shape-recycle epochs are those it was armed with: every object of the prototype chain is
// marked observed, so a change to any of them moves the prototype epoch.
struct NewSite {
    // The constructor's function; 0 while unarmed.
    CompiledFunction* cf;
    ulong proto_bits;
    ulong epoch;
    // The byte offset of the `prototype` slot in the constructor's values.
    ulong proto_off;
    // The object's block: its ObjectPool's offset in the Heap, its GcBits and its inline capacity.
    ulong pool;
    uint gc;
    uint capacity;
    uint ctor_shape;
    uint recycle;
    uint proto_shape;
    // The shape the replayed stores leave the object in, and how many there are.
    uint final_shape;
    uint count;
    // The argument each store reads: its index, NEW_ARG_UNDEF for one the site does not pass, or
    // NEW_ARG_NONE for a slot past the last store.
    uint[hobject::INLINE_PROPS] arg;
}

const uint NEW_ARG_UNDEF = 0xFFFFFFFE;
const uint NEW_ARG_NONE = 0xFFFFFFFF;
// NewSite.count of a site that calls the constructor's body.
const uint NEW_SITE_CALLS = 0xFFFFFFFF;

struct BaselineCode {
    // The code's first instruction: the entry jit_enter jumps to (Asm.emit_prologue).
    void* exec;
    // The entry generated code jumps to for a frame that is already running (emit_prologue).
    void* exec_jump;
    usz code_bytes;
    usz table_bytes;
    usz insns;
    // One native address per instruction word, parallel to the code.
    // The entry a native call site calls directly (baseline_call.c3), or null.
    void* call_entry;
    // The call entry's label for a call optimized code proved (Asm.emit_direct_call), or null.
    void* direct_entry;
    // The call entry's label for a register call (OptCg.emit_call_reg), or null.
    void* reg_entry;
    // The first shared subroutine, which ends the call entry (--jit-dump-feedback).
    void* subs;
    // Optimized code only: set by every entry, cleared by the eviction sweep (opt_make_room).
    char touched;
    // Instruction words emitted as a normal-instruction thunk call, read once
    // by the profitability filter before this body is installed.
    uint thunk_insns;
    // Sequence number of the install, used by the cold-code sweep to pick
    // older bodies. An evicted body waits on this link until it can be freed.
    uint compile_seq;
    BaselineCode* next_retired;
    void*[*] entries;
}

alias Thunk = fn long(Dispatch* ds, ulong next_pc);

// Native code for `f`, compiling it when the policy says so, or null when the
// frame runs in the interpreter.
// Top-level code runs once, so it compiles only from a hot loop.
fn void* baseline_code(Heap* h, CompiledFunction* f, Activation* act) @inline {
    if (f.jit_code != null) {
        if (@unlikely(h.opt.enabled)) opt_note_entry(h, f, act);
        return ((BaselineCode*)f.jit_code).exec;
    }
    if (f.jit_refused || is_top_level(f)) return null;
    // Nested functions of eval source can be the hot code of a library evaled
    // once (zlib), so they compile after more entries rather than never.
    uint threshold = f.jit_eval_derived ? BASELINE_EVAL_ENTRY_THRESHOLD : BASELINE_ENTRY_THRESHOLD;
    if (!h.jit_stress && ++f.jit_entries < threshold) return null;
    return baseline_try_compile(h, f, true, act);
}

fn bool is_top_level(CompiledFunction* f) @inline => f.flags.is_global || f.flags.is_module || f.flags.is_eval;

// Whether the interpreted frame of `f`, whose loop just used up the back-edge
// budget, should continue in native code, compiling `f` when the policy says
// so. Each expiry credits BASELINE_LOOP_CREDIT entries, and one expiry can
// never be enough on its own: a cold call must keep its loop hot for several
// expiries before the compile is worth it.
fn bool baseline_loop_hot(Heap* h, CompiledFunction* f, Activation* act) @noinline {
    if (f.jit_code != null) {
        if (h.opt.enabled) opt_note_entry(h, f, act, OPT_LOOP_CREDIT);
        return true;
    }
    if (f.jit_refused) return false;
    f.jit_entries += BASELINE_LOOP_CREDIT;
    uint need = f.jit_eval_derived ? BASELINE_EVAL_ENTRY_THRESHOLD : BASELINE_ENTRY_THRESHOLD;
    if (!h.jit_stress && f.jit_entries < need) return false;
    if (baseline_try_compile(h, f, true, act) == null) return false;
    h.jit_stats.loop_entries++;
    return true;
}

fn long baseline_run(void* exec, Dispatch* ds) @inline {
    ds.jit_floor = 0;
    ds.jit_depth = 0;
    ds.jit_native = true;
    ds.heap.opt.running++;
    long status = jit_enter(ds, exec, null);
    ds.jit_native = false;
    if (--ds.heap.opt.running == 0 && (ds.heap.opt.retired != null || ds.heap.jit_stats.retired_code != null)) {
        // A frame's native_ret may point into the code about to be freed.
        vm::jit_forget_returns(ds.vm);
        if (ds.heap.opt.retired != null) opt_reap(ds.heap);
        baseline_reap(ds.heap);
    }
    return status;
}

// The native entry of a compiled function, for jit_enter.
fn void* baseline_entry(CompiledFunction* f) @inline => ((BaselineCode*)f.jit_code).exec;

// The entry generated code jumps to, to continue the frame ds.act names in `f`'s code.
fn void* baseline_jump_entry(CompiledFunction* f) @inline => ((BaselineCode*)f.jit_code).exec_jump;

fn void baseline_free(Heap* h, CompiledFunction* f) {
    // Teardown is the last chance to free code that a sweep retired but no
    // native run ever got around to reaping.
    baseline_reap(h);
    opt_free(h, f);
    BaselineCode* bc = f.jit_code;
    if (bc == null) return;
    h.jit_stats.live_bytes -= bc.code_bytes + bc.table_bytes;
    sljit_free_code(bc.exec, null);
    h.free_func(h.heap_udata, bc);
    f.jit_code = null;
}

// A retired body is no longer reachable from f.jit_code, but a native frame
// may still be executing it. Its bytes stop counting toward the cap at once;
// the allocation is freed only when no native code is running.
fn void baseline_retire(Heap* h, CompiledFunction* f, BaselineCode* bc) {
    f.jit_code = null;
    h.jit_stats.live_bytes -= bc.code_bytes + bc.table_bytes;
    bc.next_retired = (BaselineCode*)h.jit_stats.retired_code;
    h.jit_stats.retired_code = (void*)bc;
    h.jit_stats.evicted++;
}

// Free the retired bodies, once no native frame can be running them.
fn void baseline_reap(Heap* h) @noinline {
    if (h.opt.running != 0) return;
    BaselineCode* bc = (BaselineCode*)h.jit_stats.retired_code;
    h.jit_stats.retired_code = null;
    while (bc != null) {
        BaselineCode* next = bc.next_retired;
        sljit_free_code(bc.exec, null);
        h.free_func(h.heap_udata, bc);
        bc = next;
    }
}

// Make room under the cap by retiring the older installed baseline bodies.
// compile_seq is the age signal: a body that is still hot recompiles after an
// eviction and so gets a fresh seq before the next sweep. Optimized bodies keep
// raw baseline exec addresses (emit_opt_exit, jit_inline_materialize), so a
// sweep that nulled jit_code would leave them dangling: only the baseline-only
// mode sweeps.
fn bool baseline_make_room(Heap* h, usz bytes = 0) @noinline {
    if (h.opt.enabled) return false;
    JitStats* st = &h.jit_stats;
    st.sweeps++;
    usz target = BASELINE_CODE_CAP / 2;
    uint oldest = st.compile_seq;
    for (uint fi = 0; fi < h.compiled_func_count; fi++) {
        CompiledFunction* cf = (CompiledFunction*)h.compiled_funcs[fi];
        if (cf == null || cf.jit_code == null || cf.opt_code != null) continue;
        BaselineCode* bc = (BaselineCode*)cf.jit_code;
        if (bc.compile_seq < oldest) oldest = bc.compile_seq;
    }
    uint cutoff = oldest + (st.compile_seq - oldest) / 2;
    for (uint fi = 0; fi < h.compiled_func_count && st.live_bytes > target; fi++) {
        CompiledFunction* cf = (CompiledFunction*)h.compiled_funcs[fi];
        if (cf == null || cf.jit_code == null || cf.opt_code != null) continue;
        BaselineCode* bc = (BaselineCode*)cf.jit_code;
        if (bc.compile_seq <= cutoff) baseline_retire(h, cf, bc);
    }
    // Optimized code cannot be freed here, so when the cold half is not enough,
    // drop the newer bodies too before giving up on this compile.
    if (st.live_bytes > target) {
        for (uint fi = 0; fi < h.compiled_func_count && st.live_bytes > target; fi++) {
            CompiledFunction* cf = (CompiledFunction*)h.compiled_funcs[fi];
            if (cf == null || cf.jit_code == null || cf.opt_code != null) continue;
            baseline_retire(h, cf, (BaselineCode*)cf.jit_code);
        }
    }
    return st.live_bytes + bytes <= BASELINE_CODE_CAP;
}

// Whether every instruction of `f` has a thunk.
fn bool baseline_compilable(CompiledFunction* f) {
    if (f.code == null || f.code_count == 0) return false;
    for (uint i = 0; i < f.code_count; i++) {
        Instruction w = f.code[i];
        if (w.op.ordinal >= Opcode::values.len) return false;
        if (w.op == Opcode.WIDE) {
            if (i + 1 >= f.code_count) return false;
            w = f.code[++i];
            if (w.op.ordinal >= Opcode::values.len) return false;
        }
        if (thunks()[w.op.ordinal] == null) return false;
    }
    return true;
}

fn void* baseline_try_compile(Heap* h, CompiledFunction* f, bool optimize = true, Activation* act = null) @noinline {
    JitStats* st = &h.jit_stats;
    // The eval body is one-shot: every eval call compiles a fresh one, so
    // native code for it can never be reused. Nested eval-derived functions
    // reach here only through baseline_code and baseline_loop_hot, whose entry
    // thresholds already reject bodies too short-lived to repay a compile.
    if (f.flags.is_eval) {
        st.skipped_eval++;
        return null;
    }
    if (!baseline_compilable(f)) {
        st.excluded_opcode++;
        f.jit_refused = true;
        return null;
    }
    if (f.code_count > BASELINE_MAX_WORDS) {
        st.too_large++;
        f.jit_refused = true;
        return null;
    }
    // Codegen is wasted work when the cap will only discard its result: use
    // the ~80 bytes of code plus the entry table per instruction word, and
    // sweep first so this estimate does not have to be exact.
    usz estimate = BaselineCode::size + (usz)f.code_count * (BASELINE_BYTES_PER_WORD + void*::size);
    if (st.live_bytes + estimate > BASELINE_CODE_CAP && !baseline_make_room(h, estimate)) {
        st.capped++;
        return null;
    }
    long t0 = st.timing ? (long)clock::now() : 0;
    BaselineCode* bc = baseline_compile(h, f);
    if (st.timing) {
        ulong ns = (ulong)((long)clock::now() - t0);
        st.compile_ns += ns;
        if (ns > st.compile_max_ns) { st.compile_max_ns = ns; st.compile_max_insns = f.code_count; }
    }
    if (bc == null) {
        st.failed++;
        if (++f.jit_attempts >= BASELINE_MAX_ATTEMPTS) f.jit_refused = true;
        return null;
    }
    if ((usz)bc.thunk_insns * 100 > bc.insns * (usz)BASELINE_MAX_THUNK_FRACTION) {
        sljit_free_code(bc.exec, null);
        h.free_func(h.heap_udata, bc);
        st.skipped_unprofitable++;
        f.jit_refused = true;
        return null;
    }
    usz bytes = bc.code_bytes + bc.table_bytes;
    if (st.live_bytes + bytes > BASELINE_CODE_CAP && !baseline_make_room(h, bytes)) {
        sljit_free_code(bc.exec, null);
        h.free_func(h.heap_udata, bc);
        st.capped++;
        return null;
    }
    st.code_bytes += bc.code_bytes;
    st.table_bytes += bc.table_bytes;
    st.insns += bc.insns;
    st.live_bytes += bytes;
    if (st.live_bytes > st.peak_bytes) st.peak_bytes = st.live_bytes;
    st.compiled++;
    bc.compile_seq = ++st.compile_seq;
    f.jit_code = bc;
    if (optimize && h.opt.always) opt_try_compile(h, f, act);
    return ((BaselineCode*)f.jit_code).exec;
}

// A thunk's result when the operation left ds.curr_pc somewhere other than
// the following instruction: the code dispatches through the entry table.
const long BASELINE_REDISPATCH = OpStatus::values.len + 1;
// A thunk result at least this is the address of code to continue in.
const long BASELINE_CODE_MIN = 65536;
// A frame's return to the generated code (Activation.native_ret) or C caller
// (ds.jit_floor) that waits for it.
const long BASELINE_RETURNED = OpStatus::values.len + 2;

const int R0 = 1;
const int R1 = 2;
const int R2 = 3;
const int R3 = 4;
// Used only by the typed-array subroutines.
const int R4 = 5;
const int FR0 = 1;
const int FR1 = 2;

// NaN-boxed tag words and the signed tag (bits 63..48 read as a short) the
// guards compare with.
const long K_INT = (long)(types::TAG_FASTINT << 48);
const long K_BOOL = (long)(types::TAG_BOOLEAN << 48);
const long K_OBJ = (long)(types::TAG_OBJECT << 48);
const long K_LIGHTFUNC = (long)(types::TAG_LIGHTFUNC << 48);
const long K_UNDEF = (long)(types::TAG_UNDEFINED << 48);
const long K_NULL = (long)(types::TAG_NULL_VAL << 48);
const long K_STRING_START = (long)(types::TAG_STRING << 48);
const long STAG_INT = (long)types::TAG_FASTINT - 0x10000;
const long PAYLOAD_SPAN = 1L << 48;
const long CANONICAL_NAN = 0x7FF8000000000000;

// A jump to an instruction's label, bound once every label exists.
struct Goto {
    void* jump;
    uint target;
}

struct Jumps {
    void*[64] at;
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
// `call` jumps its thunk call. The jumps sit in Asm.stub_jumps, `call` jumps
// first, so a stub costs a few words however many guards it has.
struct Stub {
    uint insn;
    uint at;
    char call_len;
    char alt_len;
    char poly_len;
    // Where the polymorphic arm resumes the inline path.
    void* poly_back;
}

// Load `n` jumps of the stub pool, starting at `at`, into `j`.
fn void Jumps.load(&self, List{void*}* pool, uint at, uint n) {
    for (uint k = 0; k < n; k++) self.at[k] = (*pool)[(sz)at + k];
    self.len = n;
}

// A fast call to one of the function's shared subroutines: an opcode's
// thunk call, or the heap-value register publish (PUBLISH_SUB).
struct SubCall {
    void* jump;
    int sub;
}

const int PUBLISH_SUB = -1;
const int TRUTH_SUB = -2;
const int STRICT_EQ_SUB = -3;
const int LOOSE_EQ_SUB = -4;
const int ARRAY_SLOT_SUB = -5;
const int CAPTURE_REF_SUB = -6;
const int TYPED_GET_SUB = -7;
const int TYPED_PUT_SUB = -8;
const int POLY_SUB = -9;
const int INDEX_SUB = -10;
const int CALL_SUB = -11;
const int RETURN_SUB = -12;
const int MEGA_SUB = -13;
const int PUT_ABSENT_SUB = -14;
// The put-absent subroutine without the helper call, for the optimizing tier (OptCg.emit_add_field).
const int PUT_ABSENT_FAST_SUB = -15;
// The inline object allocation's pool pop and accounting (Asm.emit_alloc_body).
const int ALLOC_SUB = -16;
// Subroutine results in R2 for the truth and equality subroutines.
const long SUB_FALSE = 0;
const long SUB_TRUE = 1;
const long SUB_SLOW = 2;

struct Asm {
    void* c;
    CompiledFunction* f;
    // The registers of the frame the code runs in. Its heap_reg_count covers
    // them all from the entry on (emit_prologue, emit_call_entry), so a store
    // to one raises nothing; only a slot beyond them is tracked (covers).
    uint frame_regs;
    // What an exit from the deepest inlined body publishes past the frame's own: activations, and
    // window slots from the frame's first. Every entry of the code tests the room for them once.
    uint room_acts;
    uint room_slots;
    // The code is the optimizing tier's, whose call sites record no callee: the build has read
    // what the baseline's recorded.
    bool opt;
    // The code allocation, whose entry table the frame's saved register holds.
    BaselineCode* bc;
    // BaselineCode.exec_jump's label.
    void* exec_jump;
    // Set by every call emitted through the call subroutine (emit_direct_call), which runs the
    // callee in this frame's native frame.
    bool direct_called;
    // The code reads its frame's scope (Activation.var_env, lex_env), which its call entry then
    // writes (emit_entry_env). The entry is emitted after the body.
    bool reads_env;
    // The code reads its frame's function (Activation.func, tv_func), which its call entry then
    // writes.
    bool reads_callee;
    // The call entry's direct label (emit_call_entry), for Asm.finish.
    void* direct_label;
    // The callee optimized code proved for the call being emitted (OptBuild.direct_callee), or null.
    CompiledFunction* direct_cf;
    // The call entry's register label (emit_call_entry), for Asm.finish.
    void* reg_label;
    void*[] labels;
    // The label of each shared subroutine, by sub_slot (--jit-dump-feedback).
    void*[Opcode::values.len + 16] sub_labels;
    bool[] starts;
    List{Goto} gotos;
    List{Stub} stubs;
    List{void*} stub_jumps;
    List{SubCall} subs;
    void* nonzero;
    int ds;
    // The Activation of the frame running (see jit_sync).
    int la;
    int regs;
    int thunks;
    int heap;
    long pc_off;
    long regs_off;
    long budget_off;
    long interrupt_off;
    long runtime_off;
    long htmldda_off;
    Layout* lay;
    // The heap the code is compiled for: its shape table sizes NEWOBJ_SHAPE's object.
    Heap* hp;
    void* length_key;
    bool counting;
    // False once a SETCONST can change the constant table.
    bool consts_fixed;
    JitStats* stats;
    // Normal instructions emitted through a thunk rather than an inline path.
    // Out-of-line stub fallbacks are excluded: they are slow paths of inline
    // work, not instructions the body dispatches through a thunk.
    uint thunk_insns;
    // The instruction being emitted.
    uint i;
    uint next;
    DecodedInsn w;
    bool wide;
    Jumps call;
    Jumps alt;
    // Receiver shapes other than a read entry's own, for the polymorphic arm
    // (emit_poly_arm), which continues at poly_back.
    Jumps poly;
    void* poly_back;
    // The NewSites the code has room for (null in optimized code), and how many are taken.
    NewSite* new_sites;
    uint new_site_count;
    uint new_site_next;
}

// The emitter state for compiling `f`, over compiler `c`: instruction labels
// and starts, the stub and subroutine pools, and the register conventions
// (ds, code, table, window, thunks and heap in the saved registers). Release
// it with Asm.release.
fn Asm asm_new(void* c, Heap* h, CompiledFunction* f) {
    uint count = f.code_count;
    // Field offsets, taken from a layout pointer that is never dereferenced.
    Dispatch* dl = (Dispatch*)(usz)4096;
    Heap* hl = (Heap*)(usz)4096;
    Asm a = {
        .c = c,
        .f = f,
        .frame_regs = f.num_regs,
        .labels = mem::new_array(void*, (usz)count + 1),
        .starts = mem::new_array(bool, (usz)count + 1),
        .ds = reg_s(0),
        .la = reg_s(1),
        .regs = reg_s(3),
        .thunks = reg_s(4),
        .heap = reg_s(5),
        .pc_off = (char*)&dl.curr_pc - (char*)dl,
        .regs_off = (char*)&dl.regs_base - (char*)dl,
        .budget_off = (char*)&hl.bwd_gc_budget - (char*)hl,
        .interrupt_off = (char*)&hl.capi_interrupt_fn - (char*)hl,
        .runtime_off = (char*)&hl.capi_runtime - (char*)hl,
        .htmldda_off = (char*)&hl.htmldda_obj - (char*)hl,
        .lay = layout(),
        .hp = h,
        .length_key = (void*)h.strs[heap::BuiltinStr.LENGTH],
        .counting = h.jit_stats.count_ops,
        .consts_fixed = true,
        .stats = &h.jit_stats,
    };
    a.gotos.init(mem);
    a.stubs.init(mem);
    a.stub_jumps.init(mem);
    a.subs.init(mem);
    for (uint i = 0; i < count;) {
        a.starts[i] = true;
        if (f.code[i].op == Opcode.SETCONST) a.consts_fixed = false;
        i += f.code[i].op == Opcode.WIDE ? 2 : 1;
    }
    return a;
}

fn void Asm.release(&self) {
    mem::free(self.labels);
    mem::free(self.starts);
    self.gotos.free();
    self.stubs.free();
    self.stub_jumps.free();
    self.subs.free();
}

// The function's entries. BaselineCode.exec, the code's first instruction, is
// where jit_enter jumps: it stores the native return the trampoline passes in
// R2 into the frame ds.act names. Generated code that continues a running
// frame in this code jumps past it, to BaselineCode.exec_jump (jit_switch,
// opt_osr, the optimized code's exits), which keeps the frame's own. Both
// require the frame state synced (vm::jit_sync), set up the saved registers
// and reach the first instruction's dispatch point.
// Returns the label that reloads the window and dispatches on ds.curr_pc
// through the entry table.
fn void* Asm.emit_prologue(&self, BaselineCode* bc) {
    void* c = self.c;
    int ds_mem = SLJIT_MEM | self.ds;
    Dispatch* dl = (Dispatch*)(usz)4096;
    self.bc = bc;
    self.set_frame();
    sljit_emit_op1(c, SLJIT_MOV, self.la, 0, ds_mem, self.lay.ds_act);
    // C now waits for the frame, or nothing does (a null R2): no call site does
    // (Activation.forget_return).
    CallLayout* k = call_layout();
    sljit_emit_op1(c, SLJIT_MOV, SLJIT_MEM | self.la, k.act_native_ret, R2, 0);
    sljit_emit_op1(c, SLJIT_MOV_U32, R1, 0, SLJIT_MEM | self.la, k.act_flags);
    sljit_emit_op2(c, SLJIT_AND, R1, 0, R1, 0, SLJIT_IMM, ~(long)vm::ACT_FLAG_JIT_CALLED & 0xFFFFFFFF);
    sljit_emit_op1(c, SLJIT_MOV_U32, SLJIT_MEM | self.la, k.act_flags, R1, 0);
    self.exec_jump = sljit_emit_label(c);
    sljit_emit_op1(c, SLJIT_MOV, self.la, 0, ds_mem, self.lay.ds_act);
    // A frame that ran in the interpreter tracked its registers one by one.
    void* covered = sljit_emit_cmp(c, SLJIT_GREATER_EQUAL | SLJIT_32, SLJIT_MEM | self.la, self.lay.act_hrc, SLJIT_IMM, self.frame_regs);
    sljit_emit_op1(c, SLJIT_MOV_U32, SLJIT_MEM | self.la, self.lay.act_hrc, SLJIT_IMM, self.frame_regs);
    sljit_set_label(covered, sljit_emit_label(c));
    sljit_emit_op1(c, SLJIT_MOV, self.heap, 0, ds_mem, (char*)&dl.heap - (char*)dl);
    sljit_emit_op1(c, SLJIT_MOV, self.thunks, 0, SLJIT_IMM, (long)(usz)&thunks()[0]);
    return sljit_emit_label(c);
}

// The shared exit: a thunk's nonzero result redispatches or leaves with the
// status. `dispatch` is the label that redispatches through the entry table.
fn void Asm.emit_nonzero_exit(&self, void* dispatch) {
    void* c = self.c;
    // A thunk's nonzero result: redispatch, or leave with the status.
    self.nonzero = sljit_emit_label(c);
    sljit_set_label(sljit_emit_cmp(c, SLJIT_EQUAL, R0, 0, SLJIT_IMM, BASELINE_REDISPATCH), dispatch);
    // An address: the optimized code to continue in (opt_osr).
    void* status = sljit_emit_cmp(c, SLJIT_LESS, R0, 0, SLJIT_IMM, BASELINE_CODE_MIN);
    sljit_emit_ijump(c, SLJIT_JUMP, R0, 0);
    sljit_set_label(status, sljit_emit_label(c));
    // A restart into a frame with native code continues there when Vm.run
    // would enter it directly (vm::jit_switch), and the native frame is the
    // entry's: below a register call's, the frame switched to would run on a
    // native frame not its own.
    void* leave = sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R0, 0, SLJIT_IMM, (long)OpStatus.RESTART.ordinal);
    void* deep = null;
    if (REG_CALLS) {
        sljit_shim_move_sp(c, R1, 0);
        deep = sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R1, 0, SLJIT_MEM | self.ds, self.lay.ds_enter_sp);
    }
    sljit_emit_op1(c, SLJIT_MOV, R0, 0, self.ds, 0);
    self.c_call(SLJIT_ARGS1WW, SLJIT_IMM, (long)(usz)&vm::jit_switch);
    void* stay = sljit_emit_cmp(c, SLJIT_EQUAL, R0, 0, SLJIT_IMM, 0);
    sljit_emit_ijump(c, SLJIT_JUMP, R0, 0);
    sljit_set_label(stay, sljit_emit_label(c));
    if (deep != null) sljit_set_label(deep, sljit_emit_label(c));
    sljit_emit_op1(c, SLJIT_MOV, R0, 0, SLJIT_IMM, (long)OpStatus.RESTART.ordinal);
    sljit_set_label(leave, sljit_emit_label(c));
    self.emit_leave(R0, 0);
}

// Emit instruction `i`: its inline path, or a call to its thunk, and record
// its out-of-line paths for emit_stubs. Falls through to the instruction
// after it (self.next).
fn void Asm.emit_insn(&self, uint i) {
    self.decode(i);
    self.call.len = 0;
    self.alt.len = 0;
    self.poly.len = 0;
    if (self.emit_call()) {
    } else if (self.emit_alloc()) {
    } else if (self.emit_fast(self.consts_fixed)) {
        if (is_access_op(self.w.op)) self.count(&self.stats.fast_hits[0], self.w.op);
    } else {
        self.thunk_insns++;
        self.emit_thunk_call(i);
    }
    if (self.call.len != 0 || self.alt.len != 0 || self.poly.len != 0) {
        self.stubs.push({ .insn = i, .at = (uint)self.stub_jumps.len(), .call_len = (char)self.call.len,
                          .alt_len = (char)self.alt.len, .poly_len = (char)self.poly.len, .poly_back = self.poly_back });
        for (uint k = 0; k < self.call.len; k++) self.stub_jumps.push(self.call.at[k]);
        for (uint k = 0; k < self.alt.len; k++) self.stub_jumps.push(self.alt.at[k]);
        for (uint k = 0; k < self.poly.len; k++) self.stub_jumps.push(self.poly.at[k]);
    }
}

// The out-of-line paths of the emitted instructions, each returning to the
// instruction after its own.
fn void Asm.emit_stubs(&self) {
    void* c = self.c;
    foreach (&stub : self.stubs) {
        self.decode(stub.insn);
        self.call.load(&self.stub_jumps, stub.at, stub.call_len);
        self.alt.len = 0;
        if (stub.alt_len != 0) {
            Jumps alt;
            alt.load(&self.stub_jumps, stub.at + stub.call_len, stub.alt_len);
            alt.bind(sljit_emit_label(c));
            self.poly_back = stub.poly_back;
            self.emit_alt();
        }
        if (stub.poly_len != 0) {
            Jumps poly;
            poly.load(&self.stub_jumps, stub.at + stub.call_len + stub.alt_len, stub.poly_len);
            poly.bind(sljit_emit_label(c));
            self.emit_poly_arm(stub.poly_back);
        }
        self.call.bind(sljit_emit_label(c));
        self.emit_op_helper();
        self.emit_thunk_call(stub.insn);
        self.go(sljit_emit_jump(c, SLJIT_JUMP), self.next);
    }
}

// Generate the code: the shared subroutines, the pending jumps bound, and the
// native address of each entry. `entries` are the instruction words whose
// labels fill bc.entries.
fn BaselineCode* Asm.finish(&self, Heap* h, BaselineCode* bc, void* call_entry) {
    void* subs = sljit_emit_label(self.c);
    self.emit_subroutines();
    foreach (g : self.gotos) sljit_set_label(g.jump, self.labels[g.target]);
    bc.exec = sljit_generate_code(self.c, 0, null);
    if (bc.exec == null) { h.free_func(h.heap_udata, bc); return null; }
    bc.exec_jump = (void*)sljit_shim_label_addr(self.exec_jump);
    bc.code_bytes = sljit_shim_code_size(self.c);
    if (call_entry != null) bc.call_entry = (void*)sljit_shim_label_addr(call_entry);
    if (call_entry != null) bc.direct_entry = (void*)sljit_shim_label_addr(self.direct_label);
    if (self.reg_label != null) bc.reg_entry = (void*)sljit_shim_label_addr(self.reg_label);
    bc.subs = (void*)sljit_shim_label_addr(subs);
    if (h.jit_stats.dump_feedback) {
        foreach (slot, label : self.sub_labels) {
            if (label == null) continue;
            String[16] helpers = { "PUBLISH", "TRUTH", "STRICT_EQ", "LOOSE_EQ", "ARRAY_SLOT", "CAPTURE_REF", "TYPED_GET",
                                   "TYPED_PUT", "POLY", "INDEX", "CALL", "RETURN", "MEGA", "PUT_ABSENT", "PUT_ABSENT_FAST", "ALLOC" };
            if (slot < Opcode::values.len) {
                io::eprintfn("sub fn#%d %s %x", self.f.func_index, Opcode::values[slot], (usz)sljit_shim_label_addr(label));
            } else {
                io::eprintfn("sub fn#%d %s %x", self.f.func_index, helpers[slot - Opcode::values.len], (usz)sljit_shim_label_addr(label));
            }
        }
    }
    return bc;
}

// The prologue, then the code that dispatches on ds.curr_pc through the entry
// table with the register window reloaded. Returns the dispatch label; an
// instruction without an entry leaves for the interpreter.
fn void* Asm.emit_dispatch(&self, BaselineCode* bc, uint count) {
    void* c = self.c;
    int ds_mem = SLJIT_MEM | self.ds;
    void* dispatch = self.emit_prologue(bc);
    sljit_emit_op1(c, SLJIT_MOV, self.regs, 0, ds_mem, self.regs_off);
    sljit_emit_op1(c, SLJIT_MOV, R1, 0, ds_mem, self.pc_off);
    sljit_emit_op2(c, SLJIT_SUB, R1, 0, R1, 0, SLJIT_IMM, (long)(usz)self.f.code);
    sljit_emit_op2(c, SLJIT_LSHR, R1, 0, R1, 0, SLJIT_IMM, 2);
    void* out_of_range = sljit_emit_cmp(c, SLJIT_GREATER_EQUAL, R1, 0, SLJIT_IMM, count);
    sljit_emit_op1(c, SLJIT_MOV, R2, 0, SLJIT_IMM, (long)(usz)&bc.entries[0]);
    sljit_emit_op1(c, SLJIT_MOV, R0, 0, mem_index(R2, R1), 3);
    void* no_entry = sljit_emit_cmp(c, SLJIT_EQUAL, R0, 0, SLJIT_IMM, 0);
    sljit_emit_ijump(c, SLJIT_JUMP, R0, 0);
    void* interpret = sljit_emit_label(c);
    sljit_set_label(out_of_range, interpret);
    sljit_set_label(no_entry, interpret);
    self.emit_leave(SLJIT_IMM, BASELINE_INTERPRET);
    return dispatch;
}

// A code allocation: the entry table of `count` words, then `sites` NewSites.
fn BaselineCode* baseline_alloc(Heap* h, uint count, uint sites = 0) {
    usz table_bytes = BaselineCode::size + (usz)count * void*::size + (usz)sites * NewSite::size;
    BaselineCode* bc = h.alloc_func(h.heap_udata, table_bytes);
    if (bc == null) return null;
    mem::clear(bc, (sz)table_bytes);
    bc.table_bytes = table_bytes;
    return bc;
}

// The NEW_OBJ instructions of `f`, each of which may get a NewSite.
fn uint new_site_count(CompiledFunction* f) {
    uint news = 0;
    for (uint i = 0; i < f.code_count; i++) if (f.code[i].op == Opcode.NEW_OBJ) news++;
    return news;
}

// Give `a` the NewSites of `bc`, which baseline_alloc made for `news` of them.
fn void Asm.use_new_sites(&self, BaselineCode* bc, uint news) {
    self.new_sites = (NewSite*)((char*)bc + BaselineCode::size + (usz)self.f.code_count * void*::size);
    self.new_site_count = news;
}

fn BaselineCode* baseline_compile(Heap* h, CompiledFunction* f, OptCode* oc = null) {
    uint count = f.code_count;
    uint news = new_site_count(f);
    BaselineCode* bc = baseline_alloc(h, count, news);
    if (bc == null) return null;
    void* c = sljit_create_compiler(null);
    if (c == null) { h.free_func(h.heap_udata, bc); return null; }
    defer sljit_free_compiler(c);
    Asm a = asm_new(c, h, f);
    defer a.release();
    a.use_new_sites(bc, news);
    void* dispatch = a.emit_dispatch(bc, count);
    a.emit_nonzero_exit(dispatch);

    bool forced_done = false;
    for (uint i = 0; i < count;) {
        a.labels[i] = sljit_emit_label(c);
        if (oc != null && h.opt.force_reason != 0 && i >= h.opt.force_at && !forced_done) {
            forced_done = true;
            a.decode(i);
            a.emit_opt_exit(oc, h.opt.force_reason - 1, true);
        }
        bc.insns++;
        a.emit_insn(i);
        i = a.next;
    }
    a.labels[count] = sljit_emit_label(c);
    sljit_set_label(sljit_emit_jump(c, SLJIT_JUMP), dispatch);
    a.emit_stubs();
    void* call_entry = call_entry_eligible(f) ? a.emit_call_entry(bc, count_opt: h.opt.enabled && !h.opt.always) : null;
    if (a.finish(h, bc, call_entry) == null) return null;
    for (uint i = 0; i < count; i++) {
        if (a.starts[i]) bc.entries[i] = (void*)sljit_shim_label_addr(a.labels[i]);
    }
    bc.thunk_insns = a.thunk_insns;
    if (h.jit_stats.dump_feedback) dump_code_map(f, bc, false);
    return bc;
}

// --- Emission helpers ---

// Make instruction `i` the current one, its operands widened by a WIDE prefix
// as the thunk decodes them.
fn void Asm.decode(&self, uint i) {
    Instruction p = self.f.code[i];
    self.i = i;
    self.wide = p.op == Opcode.WIDE;
    if (!self.wide) {
        self.w = { .op = p.op, .a = p.a, .b = p.b, .c = p.c };
        self.next = i + 1;
        return;
    }
    Instruction x = self.f.code[i + 1];
    self.w = { .op = x.op, .a = x.a | (uint)p.a << 8, .b = x.b | (uint)p.b << 8, .c = x.c | (uint)p.c << 8 };
    self.next = i + 2;
}

// Whether the inline path of `op` reads its operands as the operation
// function does when a WIDE prefix widens them. Calls and returns decode
// their instruction again at run time, and the constant-key sites switch
// opcodes in place, so they keep the thunk. The keyed property sites and
// the captures take their widened registers, and their cache entry is the
// payload word's.
fn bool wide_inline(Opcode op) {
    switch (op) {
        case RET:
        case RETUNDEF:
            return false;
        case GETPROP:
        case GETPROP_CACHE:
        case PUTPROP:
        case GETCAP:
        case PUTCAP:
            return true;
        default:
            return !is_access_op(op) || op == Opcode.LDREG || op == Opcode.LDTHIS;
    }
}

fn void Asm.go(&self, void* jump, uint target) {
    if (target <= self.i) {
        sljit_set_label(jump, self.labels[target]);
    } else {
        self.gotos.push({ .jump = jump, .target = target });
    }
}

// Call instruction `i`'s thunk with the following instruction's address (bit
// 0 marks a WIDE pair) through the opcode's shared subroutine, which leaves
// on a nonzero status and reloads the registers.
fn void Asm.emit_thunk_call(&self, uint i) {
    void* c = self.c;
    Instruction w = self.f.code[i];
    bool wide = w.op == Opcode.WIDE;
    Opcode op = wide ? self.f.code[i + 1].op : w.op;
    uint next = i + (wide ? 2 : 1);
    self.count(&self.stats.slow_calls[0], op);
    sljit_emit_op1(c, SLJIT_MOV, R1, 0, SLJIT_IMM, (long)(usz)self.f.code + (long)next * Instruction::size + (wide ? 1 : 0));
    self.subs.push({ .jump = sljit_emit_jump(c, SLJIT_FAST_CALL), .sub = (int)op.ordinal });
}

fn usz sub_slot(int sub) @inline => sub < 0 ? Opcode::values.len + (usz)(-sub) - 1 : (usz)sub;

// Fast-call shared subroutine `sub` and branch on its R2 result: `yes`,
// `no`, or the slow path.
fn void Asm.call_test_sub(&self, int sub, Jumps* yes, Jumps* no) {
    void* c = self.c;
    self.subs.push({ .jump = sljit_emit_jump(c, SLJIT_FAST_CALL), .sub = sub });
    yes.add(sljit_emit_cmp(c, SLJIT_EQUAL, R2, 0, SLJIT_IMM, SUB_TRUE));
    no.add(sljit_emit_cmp(c, SLJIT_EQUAL, R2, 0, SLJIT_IMM, SUB_FALSE));
    self.call.add(sljit_emit_jump(c, SLJIT_JUMP));
}

// Stack offset of the return address a shared subroutine saves.
const long SUB_RET_OFF = 0;

// The shared subroutines the code fast-calls, one per opcode whose thunk it
// calls plus the publish: each saves its return address, which a nonzero
// thunk status abandons for the shared exit.
fn void Asm.emit_subroutines(&self) {
    void* c = self.c;
    int ret = SLJIT_MEM | reg_sp();
    int sp = ret;
    // One label per opcode, then the shared helpers by -id.
    void*[] labels = self.sub_labels[..];
    foreach (call : self.subs) {
        usz slot = sub_slot(call.sub);
        if (labels[slot] != null) continue;
        labels[slot] = sljit_emit_label(c);
        sljit_emit_op_dst(c, SLJIT_FAST_ENTER, ret, SUB_RET_OFF);
        switch (call.sub) {
            case PUBLISH_SUB:
                self.emit_publish_body();
            case ARRAY_SLOT_SUB:
                self.emit_array_slot_body();
            case CAPTURE_REF_SUB:
                self.emit_capture_ref_body();
            case TYPED_GET_SUB:
            case TYPED_PUT_SUB:
                self.emit_typed_body(call.sub == TYPED_PUT_SUB);
            case POLY_SUB:
                self.emit_poly_body();
            case INDEX_SUB:
                self.emit_index_body();
            case CALL_SUB:
                self.emit_call_body();
            case RETURN_SUB:
                self.emit_return_body();
            case MEGA_SUB:
                self.emit_mega_body();
            case PUT_ABSENT_SUB:
            case PUT_ABSENT_FAST_SUB:
                self.emit_put_absent_body(call.sub == PUT_ABSENT_SUB);
            case ALLOC_SUB:
                self.emit_alloc_body();
            case TRUTH_SUB:
            case STRICT_EQ_SUB:
            case LOOSE_EQ_SUB:
                Jumps yes;
                Jumps no;
                Jumps slow;
                if (call.sub == TRUTH_SUB) {
                    self.truth_rest(&yes, &no, &slow);
                } else {
                    self.equality(call.sub == STRICT_EQ_SUB, &yes, &no, &slow);
                }
                Jumps done;
                yes.bind(sljit_emit_label(c));
                sljit_emit_op1(c, SLJIT_MOV, R2, 0, SLJIT_IMM, SUB_TRUE);
                done.add(sljit_emit_jump(c, SLJIT_JUMP));
                slow.bind(sljit_emit_label(c));
                sljit_emit_op1(c, SLJIT_MOV, R2, 0, SLJIT_IMM, SUB_SLOW);
                done.add(sljit_emit_jump(c, SLJIT_JUMP));
                no.bind(sljit_emit_label(c));
                sljit_emit_op1(c, SLJIT_MOV, R2, 0, SLJIT_IMM, SUB_FALSE);
                done.bind(sljit_emit_label(c));
            default:
                // A relayed opcode first tries its threaded handler through
                // vm::jit_relay without the thunk's decode, as the thunk does
                // for a narrow instruction; a decline continues into the thunk.
                Opcode sub_op = Opcode::values[call.sub];
                void* wide_pair = null;
                void* declined = null;
                bool relayed_op = is_relayed_op(sub_op);
                if (relayed_op) {
                    self.mov(sp, SUB_VALUE_OFF, R1, 0);
                    sljit_emit_op2(c, SLJIT_AND, R2, 0, R1, 0, SLJIT_IMM, 1);
                    wide_pair = sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R2, 0, SLJIT_IMM, 0);
                    sljit_emit_op1(c, SLJIT_MOV, R0, 0, self.ds, 0);
                    self.c_call(SLJIT_ARGS2WWW, SLJIT_IMM, (long)(usz)&vm::jit_relay);
                    declined = sljit_emit_cmp(c, SLJIT_EQUAL, R0, 0, SLJIT_IMM, 0);
                    self.count(&self.stats.relay_done[0], sub_op);
                    self.count(&self.stats.slow_calls[0], sub_op, -1);
                    sljit_emit_op1(c, SLJIT_MOV, self.regs, 0, SLJIT_MEM | self.ds, self.regs_off);
                    sljit_emit_op_src(c, SLJIT_FAST_RETURN, ret, SUB_RET_OFF);
                    void* thunk_path = sljit_emit_label(c);
                    sljit_set_label(wide_pair, thunk_path);
                    sljit_set_label(declined, thunk_path);
                    self.mov(R1, 0, sp, SUB_VALUE_OFF);
                }
                sljit_emit_op1(c, SLJIT_MOV, R0, 0, self.ds, 0);
                self.c_call(SLJIT_ARGS2WWW, SLJIT_MEM | self.thunks, (long)call.sub * Thunk::size);
                sljit_set_label(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R0, 0, SLJIT_IMM, 0), self.nonzero);
                sljit_emit_op1(c, SLJIT_MOV, self.regs, 0, SLJIT_MEM | self.ds, self.regs_off);
        }
        sljit_emit_op_src(c, SLJIT_FAST_RETURN, ret, SUB_RET_OFF);
    }
    foreach (call : self.subs) {
        sljit_set_label(call.jump, labels[sub_slot(call.sub)]);
    }
}

// Stack offset where the typed-array store subroutine keeps the value.
const long SUB_VALUE_OFF = 8;

// Stack bytes every native frame starts with: a subroutine's return address,
// the value the typed-array store keeps and a call's result slot
// (CALL_RETVAL_OFF). Each holds a value only between a store and a load with no
// call of generated code between them.
const int CALL_FRAME_BYTES = 32;

// The one native frame generated code runs in, which jit_enter sets up for
// every entry from C: the optimizing tier's register pools (a per-platform
// constant), six saved registers, and the local area: CALL_FRAME_BYTES, the
// optimized code's register saves around C calls and its capture records
// (OptCg.cap_slot), then the sync routine's return address and the registers
// it keeps (Trampoline.sync). Calls between generated frames do not leave it
// (baseline_call.c3), and every way out of generated code returns from it.
// A register call (OptCg.emit_call_reg) runs its callee on a native frame of its
// own below its caller's: REG_FRAME_BYTES with the same local area and the
// return address after it (JitFrame.link_off), at most vm::JIT_REG_DEPTH of
// them below the entry from C (jit_enter). Its record returns through
// Trampoline.reg_ret, which pops it.
struct JitFrame {
    int scratches;
    int locals;
    int sync_off;
    int link_off;
}

const int REG_FRAME_BYTES = 512;

// The saved registers of the shared native frame: ds, the record, the native return, the window,
// the thunks and the heap, then the three pinned tag words where the target has the registers.
fn int jit_saveds() @inline => pinned_tags() ? 9 : 6;

// Whether generated code keeps K_OBJ, PAYLOAD_SPAN and K_INT in saved registers (reg_s(6) to
// reg_s(8)), loaded once by the trampoline, so that the tag test or boxing of a value is one
// register operation rather than a constant built for each. A target with few registers keeps them
// immediates.
fn bool pinned_tags() @inline => sljit_shim_info(0) >= 20;

// The sljit operand pairs of K_OBJ, PAYLOAD_SPAN and K_INT.
fn int k_obj_op() @inline => pinned_tags() ? reg_s(6) : SLJIT_IMM;
fn long k_obj_w() @inline => pinned_tags() ? 0 : K_OBJ;
fn int span_op() @inline => pinned_tags() ? reg_s(7) : SLJIT_IMM;
fn long span_w() @inline => pinned_tags() ? 0 : PAYLOAD_SPAN;
fn int k_int_op() @inline => pinned_tags() ? reg_s(8) : SLJIT_IMM;
fn long k_int_w() @inline => pinned_tags() ? 0 : K_INT;
// Words at JitFrame.sync_off: the return address and R0 to R4.
const int SYNC_WORDS = 6;

fn JitFrame jit_frame() {
    OptPools p = opt_pools();
    int sync_off = CALL_FRAME_BYTES + 8 * (p.int_count + p.flt_count + 1);
    int locals = sync_off + 8 * SYNC_WORDS;
    assert(locals + 8 <= REG_FRAME_BYTES);
    return { .scratches = p.scratches | (p.fscratches << 8), .locals = locals, .sync_off = sync_off, .link_off = locals };
}

// Declare the shared native frame for the code that follows, which has no
// prologue of its own.
fn void Asm.set_frame(&self) {
    JitFrame fr = jit_frame();
    sljit_set_context(self.c, 0, SLJIT_ARGS3WWW, fr.scratches, jit_saveds(), fr.locals);
}

// Make the VM's frame state describe the record register's frame, unless it
// does (vm::jit_sync). Keeps every register.
fn void Asm.emit_sync(&self) {
    void* c = self.c;
    void* synced = sljit_emit_cmp(c, SLJIT_EQUAL, SLJIT_MEM | self.ds, self.lay.ds_act, self.la, 0);
    sljit_emit_ijump(c, SLJIT_FAST_CALL, SLJIT_IMM, (long)(usz)trampoline().sync);
    sljit_set_label(synced, sljit_emit_label(c));
}

// Call C at `src`/`srcw` with `arg_types` after the sync, then take the record
// register from ds.act, which the call may have moved to another frame.
fn void Asm.c_call(&self, int arg_types, int src, long srcw) {
    self.emit_sync();
    sljit_emit_icall(self.c, SLJIT_CALL, arg_types, src, srcw);
    sljit_emit_op1(self.c, SLJIT_MOV, self.la, 0, SLJIT_MEM | self.ds, self.lay.ds_act);
}

// Call C that reads no frame state and switches no frame, such as a builtin's leaf entry
// (vm::jit_leaf_call): no sync before it and the record register kept.
fn void Asm.c_call_frameless(&self, int arg_types, int src, long srcw) {
    sljit_emit_icall(self.c, SLJIT_CALL, arg_types, src, srcw);
}

// Leave generated code with `src`/`srcw` as the status, the frame state synced: from the native
// frame of the entry from C, whatever register calls' frames lie below it.
fn void Asm.emit_leave(&self, int src, long srcw) {
    void* c = self.c;
    self.emit_sync();
    if (!REG_CALLS) {
        sljit_emit_return(c, SLJIT_MOV, src, srcw);
        return;
    }
    sljit_emit_op1(c, SLJIT_MOV, R0, 0, src, srcw);
    sljit_emit_op1(c, SLJIT_MOV, R1, 0, SLJIT_MEM | self.ds, self.lay.ds_enter_sp);
    sljit_shim_move_sp(c, R1, 1);
    sljit_emit_return(c, SLJIT_MOV, R0, 0);
}

// The entry from C into generated code: it saves the registers C expects
// kept and jumps to `target`, an exec entry, with `native_ret` in R2 for the
// frame ds.act names. Every way out of generated code is a return from this
// frame; `ret` is where a frame whose C caller waits for it returns
// (vm::jit_run_entered), which returns its status to that caller. `sync` is
// the routine generated code fast-calls to run vm::jit_sync, keeping R0 to R4.
// `reg_ret` is where the record of a register call returns (its native_ret):
// it pops the call's native frame and returns to the call, keeping R0 and R1.
// `shade` is the routine optimized code fast-calls to mark the value at
// SUB_VALUE_OFF (vm::jit_opt_shade), keeping R0 to R4 and its register pools.
struct Trampoline {
    void* code;
    void* ret;
    void* sync;
    void* reg_ret;
    void* shade;
}

Trampoline trampoline_data @private;

alias EnterFn = fn long(Dispatch* ds, void* target, void* native_ret);

fn Trampoline* trampoline() @inline {
    if (trampoline_data.code == null) init_trampoline();
    return &trampoline_data;
}

fn void init_trampoline() @noinline @private {
    void* c = sljit_create_compiler(null);
    assert(c != null, "no compiler for the trampoline");
    JitFrame fr = jit_frame();
    // ds, target and native_ret arrive in S0 to S2. Every way out of generated code returns from
    // this frame's stack pointer (Dispatch.enter_sp).
    Dispatch* dl = (Dispatch*)(usz)4096;
    long enter_sp = (char*)&dl.enter_sp - (char*)dl;
    sljit_emit_enter(c, 0, SLJIT_ARGS3WWW, fr.scratches, jit_saveds(), fr.locals);
    if (pinned_tags()) {
        sljit_emit_op1(c, SLJIT_MOV, k_obj_op(), 0, SLJIT_IMM, K_OBJ);
        sljit_emit_op1(c, SLJIT_MOV, span_op(), 0, SLJIT_IMM, PAYLOAD_SPAN);
        sljit_emit_op1(c, SLJIT_MOV, k_int_op(), 0, SLJIT_IMM, K_INT);
    }
    if (REG_CALLS) {
        sljit_shim_move_sp(c, R0, 0);
        sljit_emit_op1(c, SLJIT_MOV, SLJIT_MEM | reg_s(0), enter_sp, R0, 0);
    }
    sljit_emit_op1(c, SLJIT_MOV, R2, 0, reg_s(2), 0);
    sljit_emit_ijump(c, SLJIT_JUMP, reg_s(1), 0);
    int sp = SLJIT_MEM | reg_sp();
    int la = reg_s(1);
    // A frame's return to C: the caller the record register names becomes current.
    void* ret = sljit_emit_label(c);
    if (REG_CALLS) {
        sljit_emit_op1(c, SLJIT_MOV, R0, 0, SLJIT_MEM | reg_s(0), enter_sp);
        sljit_shim_move_sp(c, R0, 1);
    }
    sljit_emit_op1(c, SLJIT_MOV, R0, 0, reg_s(0), 0);
    sljit_emit_op1(c, SLJIT_MOV, R1, 0, la, 0);
    sljit_emit_icall(c, SLJIT_CALL, SLJIT_ARGS2WWW, SLJIT_IMM, (long)(usz)&vm::jit_sync);
    sljit_emit_return(c, SLJIT_MOV, SLJIT_IMM, BASELINE_RETURNED);
    void* sync = sljit_emit_label(c);
    sljit_emit_op_dst(c, SLJIT_FAST_ENTER, sp, fr.sync_off);
    for (int r = 0; r < SYNC_WORDS - 1; r++) sljit_emit_op1(c, SLJIT_MOV, sp, fr.sync_off + 8 * ((long)r + 1), R0 + r, 0);
    sljit_emit_op1(c, SLJIT_MOV, R0, 0, reg_s(0), 0);
    sljit_emit_op1(c, SLJIT_MOV, R1, 0, la, 0);
    sljit_emit_icall(c, SLJIT_CALL, SLJIT_ARGS2WWW, SLJIT_IMM, (long)(usz)&vm::jit_sync);
    for (int r = 0; r < SYNC_WORDS - 1; r++) sljit_emit_op1(c, SLJIT_MOV, R0 + r, 0, sp, fr.sync_off + 8 * ((long)r + 1));
    sljit_emit_op_src(c, SLJIT_FAST_RETURN, sp, fr.sync_off);
    void* shade = sljit_emit_label(c);
    sljit_emit_op_dst(c, SLJIT_FAST_ENTER, sp, fr.sync_off);
    for (int r = 0; r < SYNC_WORDS - 1; r++) sljit_emit_op1(c, SLJIT_MOV, sp, fr.sync_off + 8 * ((long)r + 1), R0 + r, 0);
    OptPools p = opt_pools();
    for (int r = 0; r < p.int_count; r++) sljit_emit_op1(c, SLJIT_MOV, sp, CALL_FRAME_BYTES + 8 * (long)r, p.int_first + r, 0);
    for (int r = 0; r < p.flt_count; r++) sljit_emit_fop1(c, SLJIT_MOV_F64, sp, CALL_FRAME_BYTES + 8 * (long)(p.int_count + r), p.flt_first + r, 0);
    sljit_emit_op1(c, SLJIT_MOV, R0, 0, reg_s(5), 0);
    sljit_emit_op1(c, SLJIT_MOV, R1, 0, sp, SUB_VALUE_OFF);
    sljit_emit_icall(c, SLJIT_CALL, SLJIT_ARGS2WWW, SLJIT_IMM, (long)(usz)&vm::jit_opt_shade);
    for (int r = 0; r < p.flt_count; r++) sljit_emit_fop1(c, SLJIT_MOV_F64, p.flt_first + r, 0, sp, CALL_FRAME_BYTES + 8 * (long)(p.int_count + r));
    for (int r = 0; r < p.int_count; r++) sljit_emit_op1(c, SLJIT_MOV, p.int_first + r, 0, sp, CALL_FRAME_BYTES + 8 * (long)r);
    for (int r = 0; r < SYNC_WORDS - 1; r++) sljit_emit_op1(c, SLJIT_MOV, R0 + r, 0, sp, fr.sync_off + 8 * ((long)r + 1));
    sljit_emit_op_src(c, SLJIT_FAST_RETURN, sp, fr.sync_off);
    void* reg_ret = sljit_emit_label(c);
    if (REG_CALLS) {
        sljit_emit_op1(c, SLJIT_MOV, R2, 0, sp, fr.link_off);
        sljit_shim_adjust_sp(c, REG_FRAME_BYTES);
        sljit_emit_op_src(c, SLJIT_FAST_RETURN, R2, 0);
    }
    void* code = sljit_generate_code(c, 0, null);
    assert(code != null, "no code for the trampoline");
    trampoline_data.ret = (void*)sljit_shim_label_addr(ret);
    trampoline_data.sync = (void*)sljit_shim_label_addr(sync);
    trampoline_data.shade = (void*)sljit_shim_label_addr(shade);
    trampoline_data.reg_ret = REG_CALLS ? (void*)sljit_shim_label_addr(reg_ret) : null;
    sljit_free_compiler(c);
    trampoline_data.code = code;
}

// Run generated code from C at `target` (BaselineCode.exec) for the frame ds.act names. Its
// register calls take at most vm::JIT_REG_DEPTH native frames below this one. Code that leaves
// rather than returning abandons the native frames of the register calls above that frame:
// their records then return through jit_ret's general path, and their callers continue in
// their baseline code from the window, where each call stored them.
fn long jit_enter(Dispatch* ds, void* target, void* native_ret) @inline {
    uptr floor = ds.reg_floor;
    uptr enter_sp = ds.enter_sp;
    Activation* base = ds.act;
    Activation* enter_act = ds.enter_act;
    ds.reg_floor = (uptr)&floor - vm::JIT_REG_DEPTH * REG_FRAME_BYTES;
    ds.enter_act = base;
    long status = ((EnterFn)trampoline().code)(ds, target, native_ret);
    ds.reg_floor = floor;
    ds.enter_sp = enter_sp;
    ds.enter_act = enter_act;
    if (REG_CALLS && status != BASELINE_RETURNED) jit_forget_reg_returns(ds.vm, base);
    return status;
}

// Forget the returns of the register calls' records above `base` (Trampoline.reg_ret), whose
// native frames are gone.
fn void jit_forget_reg_returns(Vm* vm, Activation* base) @noinline {
    void* reg_ret = trampoline().reg_ret;
    for (Activation* a = base + 1; a < vm.activations + vm.activation_count; a++) {
        if (a.native_ret == reg_ret) a.forget_return();
    }
}

// A call the threaded handlers take as a lean call: vm::jit_call publishes
// the callee's frame and runs the callee's native code on the C stack. A
// declined call takes the thunk; a trivial callee completes in the helper.
fn bool Asm.emit_call(&self) {
    void* c = self.c;
    if (self.wide) return false;
    // A tail call of a builtin with a leaf entry is a plain call that falls through to its RET;
    // anything else takes the thunk, which may reuse the frame and costs far more than the try.
    if (self.w.op == Opcode.TAILCALL_CALL || self.w.op == Opcode.TAILCALL_UNDEF_THIS) {
        if (self.f.ic_entries == null) return false;
        Jumps leaf_done;
        self.emit_leaf_call(&leaf_done);
        self.emit_thunk_call(self.i);
        leaf_done.bind(sljit_emit_label(c));
        return true;
    }
    switch (self.w.op) {
        case CALL:
        case CALL_UNDEF_THIS:
        case CALL_VAR:
        case CALL_GLOBAL:
        case NEW_OBJ:
        case APPLY_ARGS:
            break;
        default:
            return false;
    }
    Jumps done;
    if (self.charcodeat_site()) {
        Jumps miss;
        self.emit_charcodeat(&miss);
        self.count(&self.stats.fast_hits[0], self.w.op);
        done.add(sljit_emit_jump(c, SLJIT_JUMP));
        miss.bind(sljit_emit_label(c));
    }
    if (self.w.op == Opcode.NEW_OBJ) {
        Jumps miss;
        Jumps generic;
        NewSite* site = self.emit_new_inline(&miss, &generic);
        if (site != null) {
            done.add(sljit_emit_jump(c, SLJIT_JUMP));
            miss.bind(sljit_emit_label(c));
        }
        sljit_emit_op1(c, SLJIT_MOV, R1, 0, SLJIT_IMM, (long)(usz)self.f.code + (long)self.next * Instruction::size);
        sljit_emit_op1(c, SLJIT_MOV, R0, 0, self.ds, 0);
        sljit_emit_op1(c, SLJIT_MOV, R2, 0, SLJIT_IMM, (long)(usz)site);
        self.c_call(SLJIT_ARGS3WWW, SLJIT_IMM, (long)(usz)&vm::jit_new_simple);
        done.add(sljit_emit_cmp(c, SLJIT_EQUAL, R0, 0, SLJIT_IMM, 0));
        generic.bind(sljit_emit_label(c));
    }
    if (self.forward_site()) {
        Jumps generic;
        self.emit_forward_call(&generic);
        generic.bind(sljit_emit_label(c));
    }
    bool tables = self.f.ic_entries != null && self.f.var_ic_entries != null;
    bool global = self.w.op == Opcode.CALL_GLOBAL && tables && !self.global_callee_trivial();
    bool scoped = self.w.op == Opcode.CALL_VAR && tables;
    if (global || scoped || self.w.op == Opcode.CALL_UNDEF_THIS || (self.w.op == Opcode.CALL && self.w.b + 1 < self.f.num_regs)) {
        Jumps generic;
        // A direct call's guard (OptBuild.direct_callee) has read the callee into its register.
        if (global && self.direct_cf == null) self.load_global_callee(&generic);
        if (scoped && self.direct_cf == null) self.load_var_callee(&generic);
        if (self.direct_cf == null && self.leaf_site()) self.emit_leaf_call(&done);
        self.emit_direct_call(&generic);
        done.add(sljit_emit_jump(c, SLJIT_JUMP));
        generic.bind(sljit_emit_label(c));
    }
    sljit_emit_op1(c, SLJIT_MOV, R1, 0, SLJIT_IMM, (long)(usz)self.f.code + (long)self.next * Instruction::size);
    sljit_emit_op1(c, SLJIT_MOV, R0, 0, self.ds, 0);
    self.c_call(SLJIT_ARGS2WWW, SLJIT_IMM, (long)(usz)&vm::jit_call);
    self.call.add(sljit_emit_cmp(c, SLJIT_EQUAL, R0, 0, SLJIT_IMM, vm::JIT_CALL_SLOW));
    sljit_set_label(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R0, 0, SLJIT_IMM, 0), self.nonzero);
    sljit_emit_op1(c, SLJIT_MOV, self.regs, 0, SLJIT_MEM | self.ds, self.regs_off);
    done.bind(sljit_emit_label(c));
    return true;
}

// Whether the call being emitted (a CALL, CALL_UNDEF_THIS, CALL_GLOBAL or CALL_VAR, or the tail
// form of the first two) has only ever called one builtin, which has a leaf entry
// (builtins::leaf_of).
fn bool Asm.leaf_site(&self) {
    if (self.f.ic_entries == null) return false;
    hobject::ICEntry* ic = &((hobject::ICEntry*)self.f.ic_entries)[self.next - 1];
    if (hobject::ic_call_count(ic) != 1 || (ic.prop_idx & hobject::IC_BUILTIN_TARGET) == 0) return false;
    return builtins::leaf_of(ic.prop_idx & ~hobject::IC_BUILTIN_TARGET) != null;
}

// The call through the leaf entry of whichever builtin its callee register holds
// (vm::jit_leaf_call), which reads neither the frame state nor the collector's. A call it
// answered joins `done` with the result stored; anything else falls through, nothing written.
fn void Asm.emit_leaf_call(&self, Jumps* done) {
    void* c = self.c;
    sljit_emit_op1(c, SLJIT_MOV, R0, 0, self.heap, 0);
    sljit_emit_op1(c, SLJIT_MOV, R1, 0, self.regs, 0);
    sljit_emit_op1(c, SLJIT_MOV, R2, 0, SLJIT_IMM, (long)(usz)&((hobject::ICEntry*)self.f.ic_entries)[self.next - 1]);
    sljit_emit_op1(c, SLJIT_MOV, R3, 0, SLJIT_IMM, (long)vm::jit_leaf_meta(compiler::tailcall_base(self.w.op), self.w));
    self.c_call_frameless(SLJIT_ARGS4WWWW, SLJIT_IMM, (long)(usz)&vm::jit_leaf_call);
    done.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R0, 0, SLJIT_IMM, 0));
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

// `reg`, a fastint payload shifted left by 16, boxed as a fastint.
fn void Asm.box_shifted(&self, int reg) {
    sljit_emit_op2(self.c, SLJIT_LSHR, reg, 0, reg, 0, SLJIT_IMM, 16);
    sljit_emit_op2(self.c, SLJIT_OR, reg, 0, reg, 0, k_int_op(), k_int_w());
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
    void* not_double = sljit_emit_cmp(c, SLJIT_GREATER_EQUAL, R2, 0, k_int_op(), k_int_w());
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
    void* ok = sljit_emit_cmp(c, SLJIT_LESS, R2, 0, k_int_op(), k_int_w());
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
    DecodedInsn w = self.w;
    Opcode op = w.op;
    if (self.wide && !wide_inline(op)) return false;
    uint ra = w.a;
    uint rb = w.b;
    uint rc = w.c;
    if (is_access_op(op)) return self.emit_access(consts_fixed);
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
            self.store(ra, SLJIT_IMM, K_INT | ((long)w.get_sbc() & (PAYLOAD_SPAN - 1)));
        case LDINTX:
            // The LDINT before it left a fastint in A, so A holds no string.
            self.load(R0, ra);
            self.guard_int(R0);
            sljit_emit_op2(c, SLJIT_SHL, R0, 0, R0, 0, SLJIT_IMM, 16);
            sljit_emit_op2(c, SLJIT_OR, R0, 0, R0, 0, SLJIT_IMM, (long)w.get_bc());
            sljit_emit_op2(c, SLJIT_AND, R0, 0, R0, 0, SLJIT_IMM, PAYLOAD_SPAN - 1);
            sljit_emit_op2(c, SLJIT_OR, R0, 0, R0, 0, k_int_op(), k_int_w());
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
            self.store(ra, SLJIT_IMM, (long)v.bits);
        case LDCONST:
            uint index = w.get_bc();
            if (!consts_fixed || index >= self.f.const_count) return false;
            TVal v = self.f.constants[index];
            if (v.is_inert()) {
                self.store(ra, SLJIT_IMM, (long)v.bits);
            } else if (v.is_string()) {
                // th_ldconst: the constant table counts the string.
                self.store(ra, SLJIT_IMM, (long)v.bits);
                self.track_heap_store(ra);
            } else {
                return false;
            }
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
            self.guard_int_alt(R0);
            self.load(R1, rc);
            self.guard_int_alt(R1);
            self.branch(false, op == JMP_EQ ? SLJIT_EQUAL : SLJIT_NOT_EQUAL, R1, 0, (uint)t, (ichar)w.a < 0);
        case ADD:
        case ADD_FUSED:
        case SUB:
            self.load(R0, rb);
            self.guard_int_alt(R0);
            self.load(R1, rc);
            self.guard_int_alt(R1);
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
            self.store(ra, R0);
        case RET:
        case RETUNDEF:
            // The plain return to a waiting native call site inline, else
            // vm::jit_ret.
            Jumps ret_helper;
            self.emit_return(&ret_helper);
            ret_helper.bind(sljit_emit_label(c));
            sljit_emit_op1(c, SLJIT_MOV, R1, 0, SLJIT_IMM, (long)(usz)self.f.code + (long)self.next * Instruction::size);
            sljit_emit_op1(c, SLJIT_MOV, R0, 0, self.ds, 0);
            self.c_call(SLJIT_ARGS2WWW, SLJIT_IMM, (long)(usz)&vm::jit_ret);
            self.call.add(sljit_emit_cmp(c, SLJIT_EQUAL, R0, 0, SLJIT_IMM, 0));
            // Popped for the generated code that waits for the frame: return to it with the
            // result the pop stored, which the site stores again (emit_direct_call).
            void* other = sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R0, 0, SLJIT_IMM, BASELINE_RETURNED);
            sljit_emit_op1(c, SLJIT_MOV, R1, 0, SLJIT_MEM | self.la, (long)Activation::size + call_layout().act_retval);
            sljit_emit_op1(c, SLJIT_MOV, R1, 0, SLJIT_MEM | R1, 0);
            sljit_emit_op1(c, SLJIT_MOV, R2, 0, SLJIT_MEM | self.ds, call_layout().ds_jit_waiter);
            self.return_to(R2);
            sljit_set_label(other, sljit_emit_label(c));
            sljit_set_label(sljit_emit_jump(c, SLJIT_JUMP), self.nonzero);
        case MUL:
        case MULI:
            self.emit_mul(op == MULI, ra, rb, rc);
        case DIV:
            self.emit_number_binop(SLJIT_DIV_F64, ra, rb, rc);
        case MOD:
            self.emit_mod();
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
        case BNOT:
            self.emit_bitop(op, ra, rb, rc, false);
        case EQ:
        case NEQ:
        case SEQ:
        case SNEQ:
            bool negate = op == NEQ || op == SNEQ;
            self.emit_compare(negate ? SLJIT_NOT_EQUAL : SLJIT_EQUAL, false, ra, rb, rc);
        case LNOT:
            // th_lnot
            Jumps truthy;
            Jumps falsy;
            self.truth_test(rb, &truthy, &falsy);
            truthy.bind(sljit_emit_label(c));
            self.store(ra, SLJIT_IMM, K_BOOL);
            void* done = sljit_emit_jump(c, SLJIT_JUMP);
            falsy.bind(sljit_emit_label(c));
            self.store(ra, SLJIT_IMM, K_BOOL | 1);
            sljit_set_label(done, sljit_emit_label(c));
        case UNM:
            // th_unm: a nonzero fastint whose negation fits, -0 for zero, and
            // doubles out of line.
            self.load(R0, rb);
            self.guard_int_alt(R0);
            sljit_emit_op2(c, SLJIT_SHL, R0, 0, R0, 0, SLJIT_IMM, 16);
            void* nonzero = sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R0, 0, SLJIT_IMM, 0);
            self.store(ra, SLJIT_IMM, (long)(1UL << 63));
            void* done = sljit_emit_jump(c, SLJIT_JUMP);
            sljit_set_label(nonzero, sljit_emit_label(c));
            sljit_emit_op2(c, SLJIT_SUB | SLJIT_SET_OVERFLOW, R0, 0, SLJIT_IMM, 0, R0, 0);
            self.alt.add(sljit_emit_jump(c, SLJIT_OVERFLOW));
            self.box_shifted(R0);
            self.store(ra, R0);
            sljit_set_label(done, sljit_emit_label(c));
        case TYPEOF: return self.emit_typeof();
        case INSTANCEOF: return self.emit_instanceof();
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

// Record a double operand in the instruction's feedback byte, for the
// optimizing tier. An operand that then fails the number loads is recorded by
// the slow path as well. Uses R2 and R3.
fn void Asm.note_double(&self) {
    CompiledFunction* f = self.f;
    if (f.ic_entries == null) return;
    void* c = self.c;
    hobject::ICEntry* entry = &((hobject::ICEntry*)f.ic_entries)[self.next - 1];
    long at = (long)(usz)&entry.feedback;
    sljit_emit_op1(c, SLJIT_MOV, R2, 0, SLJIT_IMM, at);
    sljit_emit_op1(c, SLJIT_MOV_U8, R3, 0, SLJIT_MEM | R2, 0);
    sljit_emit_op2(c, SLJIT_OR, R3, 0, R3, 0, SLJIT_IMM, (long)hobject::FB_DBL);
    sljit_emit_op1(c, SLJIT_MOV_U8, SLJIT_MEM | R2, 0, R3, 0);
}

// Record the classes of the operands in R0 and R1 (hobject::fb_class: none for a fastint, a double,
// a string, anything else) in the instruction's feedback byte, as the interpreter's note_feedback
// does: an equality settled here without the handler would otherwise leave the optimizing tier no
// sign of an operand that is not a number. Uses R2 and R3.
fn void Asm.note_classes(&self) {
    CompiledFunction* f = self.f;
    if (f.ic_entries == null) return;
    void* c = self.c;
    hobject::ICEntry* entry = &((hobject::ICEntry*)f.ic_entries)[self.next - 1];
    sljit_emit_op1(c, SLJIT_MOV, R3, 0, SLJIT_IMM, 0);
    foreach (r : (int[2]){ R0, R1 }) {
        sljit_emit_op2(c, SLJIT_LSHR, R2, 0, r, 0, SLJIT_IMM, 48);
        void* fastint = sljit_emit_cmp(c, SLJIT_EQUAL, R2, 0, SLJIT_IMM, (long)types::TAG_FASTINT);
        void* dbl = sljit_emit_cmp(c, SLJIT_LESS, R2, 0, SLJIT_IMM, (long)types::TAG_FASTINT);
        void* str = sljit_emit_cmp(c, SLJIT_EQUAL, R2, 0, SLJIT_IMM, (long)types::TAG_STRING);
        sljit_emit_op2(c, SLJIT_OR, R3, 0, R3, 0, SLJIT_IMM, (long)hobject::FB_OTHER);
        void* done = sljit_emit_jump(c, SLJIT_JUMP);
        sljit_set_label(dbl, sljit_emit_label(c));
        sljit_emit_op2(c, SLJIT_OR, R3, 0, R3, 0, SLJIT_IMM, (long)hobject::FB_DBL);
        void* done2 = sljit_emit_jump(c, SLJIT_JUMP);
        sljit_set_label(str, sljit_emit_label(c));
        sljit_emit_op2(c, SLJIT_OR, R3, 0, R3, 0, SLJIT_IMM, (long)hobject::FB_STR);
        void* end = sljit_emit_label(c);
        sljit_set_label(fastint, end);
        sljit_set_label(done, end);
        sljit_set_label(done2, end);
    }
    sljit_emit_op1(c, SLJIT_MOV, R2, 0, SLJIT_IMM, (long)(usz)&entry.feedback);
    sljit_emit_op2(c, SLJIT_OR, R3, 0, R3, 0, SLJIT_MEM | R2, 0);
    sljit_emit_op1(c, SLJIT_MOV_U8, SLJIT_MEM | R2, 0, R3, 0);
}

// The number path entered when an operand is not a fastint.
fn void Asm.emit_alt(&self) {
    void* c = self.c;
    DecodedInsn w = self.w;
    Opcode op = w.op;
    if (self.emit_var_alt()) return;
    if (op == JMP_SEQ || op == JMP_SNEQ || op == JMP_EQ || op == JMP_NEQ) {
        Jumps eq;
        Jumps ne;
        self.load(R0, w.b);
        self.load(R1, w.c);
        self.note_classes();
        self.call_test_sub(op == JMP_SEQ || op == JMP_SNEQ ? STRICT_EQ_SUB : LOOSE_EQ_SUB, &eq, &ne);
        uint t = (uint)self.target((int)(ichar)w.a);
        bool on_eq = op == JMP_SEQ || op == JMP_EQ;
        self.finish_test(on_eq ? &eq : &ne, on_eq ? &ne : &eq, t, (ichar)w.a < 0);
        return;
    }
    if (is_jmp_reg(op) || is_jmp_imm(op)) {
        bool imm = is_jmp_imm(op);
        uint row = imm ? op.ordinal - Opcode.JMP_NLTI.ordinal : op.ordinal - Opcode.JMP_NLT.ordinal;
        self.load_number(FR0, w.b);
        if (imm) {
            self.load_imm_number(FR1, (long)(ichar)w.c);
        } else {
            self.load_number(FR1, w.c);
        }
        self.note_double();
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
            self.load_number(FR0, w.b);
            self.load_imm_number(FR1, (long)(ichar)w.c);
            self.note_double();
            sljit_emit_fop2(c, op == SUBI ? SLJIT_SUB_F64 : SLJIT_ADD_F64, FR0, 0, FR0, 0, FR1, 0);
            self.store_number(w.a);
        case INC:
        case INC_LT:
        case DEC:
            // A number register holds no string to release.
            self.load_number(FR0, w.a);
            self.note_double();
            self.load_imm_number(FR1, 1);
            sljit_emit_fop2(c, op == DEC ? SLJIT_SUB_F64 : SLJIT_ADD_F64, FR0, 0, FR0, 0, FR1, 0);
            self.store_number(w.a);
        case EQ:
        case NEQ:
        case SEQ:
        case SNEQ:
            Jumps eq;
            Jumps ne;
            self.load(R0, w.b);
            self.load(R1, w.c);
            self.note_classes();
            self.call_test_sub(op == SEQ || op == SNEQ ? STRICT_EQ_SUB : LOOSE_EQ_SUB, &eq, &ne);
            bool negate = op == NEQ || op == SNEQ;
            eq.bind(sljit_emit_label(c));
            self.store(w.a, SLJIT_IMM, K_BOOL | (negate ? 0 : 1));
            self.go(sljit_emit_jump(c, SLJIT_JUMP), self.next);
            ne.bind(sljit_emit_label(c));
            self.store(w.a, SLJIT_IMM, K_BOOL | (negate ? 1 : 0));
        case UNM:
            // A double, or a fastint whose negation is not a fastint.
            self.load_number(FR0, w.b);
            self.note_double();
            sljit_emit_fop1(c, SLJIT_NEG_F64, FR0, 0, FR0, 0);
            self.store_number(w.a);
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
        case BNOT:
            self.emit_bitop(op, w.a, w.b, w.c, true);
        case LT:
        case LE:
        case GT:
        case GE:
            self.load_number(FR0, w.b);
            self.load_number(FR1, w.c);
            self.note_double();
            self.bool_result(true, JMP_FLOAT_COND[4 + op.ordinal - Opcode.LT.ordinal], w.a);
        case GETPROPC:
        case GETPROPC_CACHED:
            self.emit_length(w.a, w.b);
        case GETPROP:
        case GETPROP_CACHE:
            self.emit_get_keyed(w.a, w.b, w.c);
        default:
            unreachable("no number path for %s", op);
    }
    self.go(sljit_emit_jump(c, SLJIT_JUMP), self.next);
}

// A = B <fop> C on two numbers; anything else takes the slow path.
fn void Asm.emit_number_binop(&self, int fop, uint ra, uint rb, uint rc) {
    self.load_number(FR0, rb);
    self.load_number(FR1, rc);
    self.note_double();
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
        self.guard_int_alt(R0);
        self.guard_int_alt(R1);
    }
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

// The bitwise and shift operators on fastints, as th_bitop, entering the
// number path otherwise. The number path (`numbers`) also takes doubles whose
// ToInt32 is their truncation, which holds within the int32 range. BNOT is the exclusive or
// with all ones.
fn void Asm.emit_bitop(&self, Opcode op, uint ra, uint rb, uint rc, bool numbers) {
    void* c = self.c;
    bool imm = op == BNOT || bytecode::is_imm_form(op);
    Opcode base = op == BNOT ? Opcode.BXOR : (imm ? bytecode::reg_form(op) : op);
    self.load(R0, rb);
    if (numbers) { self.int32_operand(R0); } else { self.guard_int_alt(R0); }
    int src = SLJIT_IMM;
    long srcw = op == BNOT ? -1 : (long)(rc & 0xFF);
    if (!imm) {
        self.load(R1, rc);
        if (numbers) { self.int32_operand(R1); } else { self.guard_int_alt(R1); }
        src = R1;
        srcw = 0;
    }
    if (numbers) self.note_double();
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
    sljit_emit_op2(c, SLJIT_OR, R0, 0, R0, 0, k_int_op(), k_int_w());
    self.store(ra, R0);
}

// IF_TRUE / IF_FALSE, as is_truthy decides them.
fn void Asm.emit_if(&self, bool on_true, uint r, uint target, bool backward) {
    Jumps truthy;
    Jumps falsy;
    self.truth_test(r, &truthy, &falsy);
    if (on_true) {
        self.finish_test(&truthy, &falsy, target, backward);
    } else {
        self.finish_test(&falsy, &truthy, target, backward);
    }
}

// Jump to `truthy` or `falsy` as is_truthy decides register `r`: a boolean,
// fastint, double, object, undefined, null or string; anything else takes the
// slow path. Uses R0 to R2, FR0 and FR1.
fn void Asm.truth_test(&self, uint r, Jumps* truthy, Jumps* falsy) {
    self.load(R0, r);
    self.truth_test_r0(truthy, falsy);
}

// truth_test of the value in R0.
// With `strings`, a non-empty string is found truthy in line as well.
fn void Asm.truth_test_r0(&self, Jumps* truthy, Jumps* falsy, bool strings = false) {
    void* c = self.c;
    sljit_emit_op2(c, SLJIT_XOR, R1, 0, R0, 0, SLJIT_IMM, K_BOOL);
    void* not_bool = sljit_emit_cmp(c, SLJIT_GREATER_EQUAL, R1, 0, SLJIT_IMM, 2);
    truthy.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R1, 0, SLJIT_IMM, 0));
    falsy.add(sljit_emit_jump(c, SLJIT_JUMP));
    sljit_set_label(not_bool, sljit_emit_label(c));
    sljit_emit_op2(c, SLJIT_XOR, R1, 0, R0, 0, k_int_op(), k_int_w());
    void* not_int = sljit_emit_cmp(c, SLJIT_GREATER_EQUAL, R1, 0, span_op(), span_w());
    sljit_emit_op2(c, SLJIT_SHL, R1, 0, R1, 0, SLJIT_IMM, 16);
    truthy.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R1, 0, SLJIT_IMM, 0));
    falsy.add(sljit_emit_jump(c, SLJIT_JUMP));
    sljit_set_label(not_int, sljit_emit_label(c));
    falsy.add(sljit_emit_cmp(c, SLJIT_EQUAL, R0, 0, SLJIT_IMM, K_UNDEF));
    falsy.add(sljit_emit_cmp(c, SLJIT_EQUAL, R0, 0, SLJIT_IMM, K_NULL));
    if (strings) {
        sljit_emit_op2(c, SLJIT_XOR, R1, 0, R0, 0, SLJIT_IMM, K_STRING_START);
        void* not_string = sljit_emit_cmp(c, SLJIT_GREATER_EQUAL, R1, 0, span_op(), span_w());
        sljit_emit_op1(c, SLJIT_MOV_U32, R2, 0, SLJIT_MEM | R1, self.lay.str_length);
        truthy.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R2, 0, SLJIT_IMM, 0));
        sljit_set_label(not_string, sljit_emit_label(c));
    }
    self.call_test_sub(TRUTH_SUB, truthy, falsy);
}

// The truth subroutine's tests of R0 that truth_test leaves out: a double, a
// string or an object; anything else is slow. Uses R1, R2, FR0 and FR1.
fn void Asm.truth_rest(&self, Jumps* truthy, Jumps* falsy, Jumps* slow) {
    void* c = self.c;
    // A double is truthy unless it is zero or NaN.
    void* not_double = sljit_emit_cmp(c, SLJIT_GREATER_EQUAL, R0, 0, k_int_op(), k_int_w());
    sljit_emit_fcopy(c, SLJIT_COPY_TO_F64, FR0, R0);
    self.load_imm_number(FR1, 0);
    truthy.add(sljit_emit_fcmp(c, SLJIT_ORDERED_NOT_EQUAL, FR0, 0, FR1, 0));
    falsy.add(sljit_emit_jump(c, SLJIT_JUMP));
    sljit_set_label(not_double, sljit_emit_label(c));
    // A string is truthy when it is not empty or is a symbol.
    sljit_emit_op2(c, SLJIT_XOR, R1, 0, R0, 0, SLJIT_IMM, K_STRING_START);
    void* not_string = sljit_emit_cmp(c, SLJIT_GREATER_EQUAL, R1, 0, span_op(), span_w());
    sljit_emit_op1(c, SLJIT_MOV_U32, R2, 0, SLJIT_MEM | R1, self.lay.str_length);
    truthy.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R2, 0, SLJIT_IMM, 0));
    sljit_emit_op1(c, SLJIT_MOV_U32, R2, 0, SLJIT_MEM | R1, self.lay.str_flags);
    sljit_emit_op2(c, SLJIT_AND, R2, 0, R2, 0, SLJIT_IMM, self.lay.symbol_mask);
    truthy.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R2, 0, SLJIT_IMM, 0));
    falsy.add(sljit_emit_jump(c, SLJIT_JUMP));
    sljit_set_label(not_string, sljit_emit_label(c));
    sljit_emit_op2(c, SLJIT_XOR, R1, 0, R0, 0, k_obj_op(), k_obj_w());
    slow.add(sljit_emit_cmp(c, SLJIT_GREATER_EQUAL, R1, 0, span_op(), span_w()));
    // An object is truthy unless it is the realm's [[IsHTMLDDA]] object.
    sljit_emit_op1(c, SLJIT_MOV, R2, 0, SLJIT_MEM | self.heap, self.htmldda_off);
    slow.add(sljit_emit_cmp(c, SLJIT_EQUAL, R1, 0, R2, 0));
    truthy.add(sljit_emit_jump(c, SLJIT_JUMP));
}

// `reg`, a fastint, a double within the int32 range, a boolean, undefined
// or null, as its ToInt32 in the low 32 bits; the slow path otherwise. Uses
// R3 and FR0.
fn void Asm.int32_operand(&self, int reg) {
    void* c = self.c;
    Jumps done;
    sljit_emit_op2(c, SLJIT_ASHR, R3, 0, reg, 0, SLJIT_IMM, 48);
    done.add(sljit_emit_cmp(c, SLJIT_EQUAL, R3, 0, SLJIT_IMM, STAG_INT));
    // ToNumber gives 0 or 1 for a boolean and NaN, whose ToInt32 is 0, for
    // undefined and null.
    sljit_emit_op2(c, SLJIT_XOR, R3, 0, reg, 0, SLJIT_IMM, K_BOOL);
    void* not_bool = sljit_emit_cmp(c, SLJIT_GREATER_EQUAL, R3, 0, SLJIT_IMM, 2);
    sljit_emit_op1(c, SLJIT_MOV, reg, 0, R3, 0);
    done.add(sljit_emit_jump(c, SLJIT_JUMP));
    sljit_set_label(not_bool, sljit_emit_label(c));
    void* is_undef = sljit_emit_cmp(c, SLJIT_EQUAL, reg, 0, SLJIT_IMM, K_UNDEF);
    void* not_null = sljit_emit_cmp(c, SLJIT_NOT_EQUAL, reg, 0, SLJIT_IMM, K_NULL);
    sljit_set_label(is_undef, sljit_emit_label(c));
    sljit_emit_op1(c, SLJIT_MOV, reg, 0, SLJIT_IMM, 0);
    done.add(sljit_emit_jump(c, SLJIT_JUMP));
    sljit_set_label(not_null, sljit_emit_label(c));
    self.call.add(sljit_emit_cmp(c, SLJIT_GREATER_EQUAL, reg, 0, k_int_op(), k_int_w()));
    sljit_emit_fcopy(c, SLJIT_COPY_TO_F64, FR0, reg);
    // Out-of-range doubles, infinities and NaN either give a value outside the
    // int32 range or, for NaN on some targets, 0, which is NaN's ToInt32.
    sljit_emit_fop1(c, SLJIT_CONV_SW_FROM_F64, reg, 0, FR0, 0);
    sljit_emit_op2(c, SLJIT_ADD, R3, 0, reg, 0, SLJIT_IMM, 1L << 31);
    self.call.add(sljit_emit_cmp(c, SLJIT_GREATER_EQUAL, R3, 0, SLJIT_IMM, 1L << 32));
    done.bind(sljit_emit_label(c));
}

// Decide equality of R0 and R1, strict as th_strict_order or loose as
// th_loose_order, jumping to `eq`, `ne`, or `slow` for the pairs those
// handlers leave to the switch: the body of the equality subroutines. Uses
// R0 to R3, FR0 and FR1.
fn void Asm.equality(&self, bool strict, Jumps* eq, Jumps* ne, Jumps* slow) {
    void* c = self.c;
    Layout* l = self.lay;
    if (!strict) {
        // Null and undefined equal each other and the [[IsHTMLDDA]] object.
        Jumps nullish;
        sljit_emit_op2(c, SLJIT_LSHR, R2, 0, R0, 0, SLJIT_IMM, 48);
        sljit_emit_op2(c, SLJIT_SUB, R2, 0, R2, 0, SLJIT_IMM, (long)types::TAG_UNDEFINED);
        sljit_emit_op2(c, SLJIT_LSHR, R3, 0, R1, 0, SLJIT_IMM, 48);
        sljit_emit_op2(c, SLJIT_SUB, R3, 0, R3, 0, SLJIT_IMM, (long)types::TAG_UNDEFINED);
        void* b_nullish = sljit_emit_cmp(c, SLJIT_LESS_EQUAL, R2, 0, SLJIT_IMM, 1);
        void* c_nullish = sljit_emit_cmp(c, SLJIT_LESS_EQUAL, R3, 0, SLJIT_IMM, 1);
        void* neither = sljit_emit_jump(c, SLJIT_JUMP);
        // R1 nullish, R0 not: test R0.
        sljit_set_label(c_nullish, sljit_emit_label(c));
        sljit_emit_op1(c, SLJIT_MOV, R3, 0, R0, 0);
        void* test_other = sljit_emit_jump(c, SLJIT_JUMP);
        sljit_set_label(b_nullish, sljit_emit_label(c));
        eq.add(sljit_emit_cmp(c, SLJIT_LESS_EQUAL, R3, 0, SLJIT_IMM, 1));
        sljit_emit_op1(c, SLJIT_MOV, R3, 0, R1, 0);
        sljit_set_label(test_other, sljit_emit_label(c));
        sljit_emit_op2(c, SLJIT_XOR, R3, 0, R3, 0, k_obj_op(), k_obj_w());
        ne.add(sljit_emit_cmp(c, SLJIT_GREATER_EQUAL, R3, 0, span_op(), span_w()));
        sljit_emit_op1(c, SLJIT_MOV, R2, 0, SLJIT_MEM | self.heap, self.htmldda_off);
        eq.add(sljit_emit_cmp(c, SLJIT_EQUAL, R3, 0, R2, 0));
        ne.add(sljit_emit_jump(c, SLJIT_JUMP));
        sljit_set_label(neither, sljit_emit_label(c));
    }
    // Numbers: a fastint or a double on both sides compares numerically; one
    // number and one other value differ (strict) or coerce (loose).
    void* b_other = sljit_emit_cmp(c, SLJIT_GREATER_EQUAL, R0, 0, SLJIT_IMM, K_INT + PAYLOAD_SPAN);
    if (strict) {
        ne.add(sljit_emit_cmp(c, SLJIT_GREATER_EQUAL, R1, 0, SLJIT_IMM, K_INT + PAYLOAD_SPAN));
    } else {
        slow.add(sljit_emit_cmp(c, SLJIT_GREATER_EQUAL, R1, 0, SLJIT_IMM, K_INT + PAYLOAD_SPAN));
    }
    sljit_emit_op2(c, SLJIT_AND, R2, 0, R0, 0, R1, 0);
    void* not_ints = sljit_emit_cmp(c, SLJIT_LESS, R2, 0, k_int_op(), k_int_w());
    eq.add(sljit_emit_cmp(c, SLJIT_EQUAL, R0, 0, R1, 0));
    ne.add(sljit_emit_jump(c, SLJIT_JUMP));
    sljit_set_label(not_ints, sljit_emit_label(c));
    self.to_double(FR0, R0);
    self.to_double(FR1, R1);
    eq.add(sljit_emit_fcmp(c, SLJIT_ORDERED_EQUAL, FR0, 0, FR1, 0));
    ne.add(sljit_emit_jump(c, SLJIT_JUMP));
    sljit_set_label(b_other, sljit_emit_label(c));
    if (strict) {
        ne.add(sljit_emit_cmp(c, SLJIT_LESS, R1, 0, SLJIT_IMM, K_INT + PAYLOAD_SPAN));
    } else {
        slow.add(sljit_emit_cmp(c, SLJIT_LESS, R1, 0, SLJIT_IMM, K_INT + PAYLOAD_SPAN));
    }
    // Neither is a number: identical bits are equal, and values of different
    // tags differ (strict) or coerce (loose).
    eq.add(sljit_emit_cmp(c, SLJIT_EQUAL, R0, 0, R1, 0));
    sljit_emit_op2(c, SLJIT_LSHR, R2, 0, R0, 0, SLJIT_IMM, 48);
    sljit_emit_op2(c, SLJIT_LSHR, R3, 0, R1, 0, SLJIT_IMM, 48);
    if (strict) {
        ne.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R2, 0, R3, 0));
    } else {
        slow.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R2, 0, R3, 0));
    }
    // Two BigInts compare by value in the switch. Two strings differ when both are interned;
    // otherwise two of inline byte units compare by content, a word at a time. The last word
    // read ends at the last unit, so it starts in earlier units or in the header, and its bytes
    // below the units left over are shifted out (the low ones: little-endian).
    slow.add(sljit_emit_cmp(c, SLJIT_EQUAL, R2, 0, SLJIT_IMM, (long)types::TAG_BIGINT));
    ne.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R2, 0, SLJIT_IMM, (long)types::TAG_STRING));
    sljit_emit_op2(c, SLJIT_XOR, R0, 0, R0, 0, SLJIT_IMM, K_STRING_START);
    sljit_emit_op2(c, SLJIT_XOR, R1, 0, R1, 0, SLJIT_IMM, K_STRING_START);
    sljit_emit_op1(c, SLJIT_MOV_U32, R2, 0, SLJIT_MEM | R0, l.str_flags);
    sljit_emit_op1(c, SLJIT_MOV_U32, R3, 0, SLJIT_MEM | R1, l.str_flags);
    sljit_emit_op2(c, SLJIT_AND, R2, 0, R2, 0, R3, 0);
    sljit_emit_op2u(c, SLJIT_AND | SLJIT_SET_Z, R2, 0, SLJIT_IMM, l.interned_mask);
    ne.add(sljit_emit_jump(c, SLJIT_NOT_EQUAL));
    sljit_emit_op1(c, SLJIT_MOV_U32, R2, 0, SLJIT_MEM | R0, l.str_flags);
    sljit_emit_op2(c, SLJIT_OR, R2, 0, R2, 0, R3, 0);
    sljit_emit_op2u(c, SLJIT_AND | SLJIT_SET_Z, R2, 0, SLJIT_IMM, l.byte_units_mask);
    slow.add(sljit_emit_jump(c, SLJIT_NOT_EQUAL));
    sljit_emit_op1(c, SLJIT_MOV_U32, R2, 0, SLJIT_MEM | R0, l.str_length);
    sljit_emit_op1(c, SLJIT_MOV_U32, R3, 0, SLJIT_MEM | R1, l.str_length);
    ne.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R2, 0, R3, 0));
    sljit_emit_op2(c, SLJIT_ADD, R0, 0, R0, 0, SLJIT_IMM, (long)hstring::HSTRING_HDR_SIZE);
    sljit_emit_op2(c, SLJIT_ADD, R1, 0, R1, 0, SLJIT_IMM, (long)hstring::HSTRING_HDR_SIZE);
    void* words = sljit_emit_label(c);
    void* tail = sljit_emit_cmp(c, SLJIT_LESS, R2, 0, SLJIT_IMM, 8);
    sljit_emit_op1(c, SLJIT_MOV, R3, 0, SLJIT_MEM | R0, 0);
    sljit_emit_op2(c, SLJIT_XOR, R3, 0, R3, 0, SLJIT_MEM | R1, 0);
    ne.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R3, 0, SLJIT_IMM, 0));
    sljit_emit_op2(c, SLJIT_ADD, R0, 0, R0, 0, SLJIT_IMM, 8);
    sljit_emit_op2(c, SLJIT_ADD, R1, 0, R1, 0, SLJIT_IMM, 8);
    sljit_emit_op2(c, SLJIT_SUB, R2, 0, R2, 0, SLJIT_IMM, 8);
    sljit_set_label(sljit_emit_jump(c, SLJIT_JUMP), words);
    sljit_set_label(tail, sljit_emit_label(c));
    eq.add(sljit_emit_cmp(c, SLJIT_EQUAL, R2, 0, SLJIT_IMM, 0));
    sljit_emit_op2(c, SLJIT_ADD, R0, 0, R0, 0, R2, 0);
    sljit_emit_op2(c, SLJIT_ADD, R1, 0, R1, 0, R2, 0);
    sljit_emit_op1(c, SLJIT_MOV, R3, 0, SLJIT_MEM | R0, -8);
    sljit_emit_op2(c, SLJIT_XOR, R3, 0, R3, 0, SLJIT_MEM | R1, -8);
    sljit_emit_op2(c, SLJIT_SUB, R0, 0, SLJIT_IMM, 8, R2, 0);
    sljit_emit_op2(c, SLJIT_SHL, R0, 0, R0, 0, SLJIT_IMM, 3);
    sljit_emit_op2(c, SLJIT_LSHR, R3, 0, R3, 0, R0, 0);
    eq.add(sljit_emit_cmp(c, SLJIT_EQUAL, R3, 0, SLJIT_IMM, 0));
    ne.add(sljit_emit_jump(c, SLJIT_JUMP));
}

// FR(fr) = the number `reg` holds, a double or a fastint. Uses R3.
fn void Asm.to_double(&self, int fr, int reg) {
    void* c = self.c;
    void* is_int = sljit_emit_cmp(c, SLJIT_GREATER_EQUAL, reg, 0, k_int_op(), k_int_w());
    sljit_emit_fcopy(c, SLJIT_COPY_TO_F64, fr, reg);
    void* done = sljit_emit_jump(c, SLJIT_JUMP);
    sljit_set_label(is_int, sljit_emit_label(c));
    sljit_emit_op2(c, SLJIT_SHL, R3, 0, reg, 0, SLJIT_IMM, 16);
    sljit_emit_op2(c, SLJIT_ASHR, R3, 0, R3, 0, SLJIT_IMM, 16);
    sljit_emit_fop1(c, SLJIT_CONV_F64_FROM_SW, fr, 0, R3, 0);
    sljit_set_label(done, sljit_emit_label(c));
}

// Sort register `r` into `nullish` (null, undefined or the [[IsHTMLDDA]] object) and `other`,
// as th_jmp_null; the rare cases take the slow path.
fn void Asm.null_test(&self, uint r, Jumps* nullish, Jumps* other) {
    self.load(R0, r);
    self.null_test_r0(nullish, other);
}

// null_test of the value in R0.
fn void Asm.null_test_r0(&self, Jumps* nullish, Jumps* other) {
    void* c = self.c;
    nullish.add(sljit_emit_cmp(c, SLJIT_EQUAL, R0, 0, SLJIT_IMM, K_UNDEF));
    nullish.add(sljit_emit_cmp(c, SLJIT_EQUAL, R0, 0, SLJIT_IMM, K_NULL));
    sljit_emit_op2(c, SLJIT_XOR, R1, 0, R0, 0, k_obj_op(), k_obj_w());
    other.add(sljit_emit_cmp(c, SLJIT_GREATER_EQUAL, R1, 0, span_op(), span_w()));
    sljit_emit_op1(c, SLJIT_MOV, R2, 0, SLJIT_MEM | self.heap, self.htmldda_off);
    self.call.add(sljit_emit_cmp(c, SLJIT_EQUAL, R1, 0, R2, 0));
    other.add(sljit_emit_jump(c, SLJIT_JUMP));
}

// JMP_NULL / JMP_NNULL.
fn void Asm.emit_jmp_null(&self, bool on_null, uint r, uint target, bool backward) {
    Jumps nullish;
    Jumps other;
    self.null_test(r, &nullish, &other);
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

// The CALL thunk's work, shared with the native call site's builtin path
// (vm::jit_call_builtin_native): run the call through th_call_native when the
// callee is a builtin (vm::jit_call_builtin), else through the operation
// function, and map the outcome as the interpreter continues.
fn long jit_call_thunk(Dispatch* ds, ulong arg) {
    Instruction* next = (Instruction*)(usz)(arg & ~1UL);
    ds.curr_pc = next;
    Instruction p = next[-1];
    DecodedInsn insn = { .op = p.op, .a = p.a, .b = p.b, .c = p.c };
    if ((arg & 1) != 0) {
        Instruction x = next[-2];
        insn.a |= (uint)x.a << 8;
        insn.b |= (uint)x.b << 8;
        insn.c |= (uint)x.c << 8;
    }
    Activation* act = ds.act;
    CompiledFunction* func = ds.vm.current_func;
    uint count_before = ds.vm.activation_count;
    OpStatus s;
    long raw = vm::JIT_NO_RAW;
    if ((arg & 1) == 0 && vm::jit_call_builtin(ds, next, &s, &raw)) {
        count_relayed(ds, p.op);
        if (raw != vm::JIT_NO_RAW) return raw;
    } else {
        s = vm::op_call(ds, insn);
    }
    return jit_call_status(ds, next, act, func, count_before, s);
}

// How a completed CALL leaves its caller, as the thunk's status: the operation
// asked for a restart, a frame switch left the caller current at the native
// call site's floor, a pushed callee runs natively here, the frame continues
// in optimized code, it redispatches, or it leaves with the operation's own
// status. `act`, `func` and `count_before` are the caller's, read before the
// call ran.
fn long jit_call_status(Dispatch* ds, Instruction* next, Activation* act, CompiledFunction* func,
                        uint count_before, OpStatus s) {
    if (s == NEXT && ds.needs_restart) return (long)OpStatus.RESTART.ordinal;
    // A frame switched to in place is the caller a native call site waits for
    // when the depth is back at its floor, and is otherwise entered through
    // Vm.run.
    if (s == NEXT && (ds.act != act || ds.vm.current_func != func)
        && ds.vm.activation_count == ds.jit_floor) {
        ds.act.curr_pc = ds.curr_pc;
        return BASELINE_RETURNED;
    }
    s = vm::jit_restart_switched(ds, act, func, s);
    // A callee the lean shapes declined, entered by pushing its frame: run its native
    // code here rather than unwinding every native frame above to Vm.run.
    if (ds.needs_restart && s == RESTART) {
        long entered = vm::jit_enter_pushed(ds, next, count_before);
        if (entered != vm::JIT_NO_RAW) return entered;
    }
    if (s == NEXT && ds.curr_pc != next) {
        // A taken backward branch may continue in optimized code.
        if (@unlikely(ds.heap.opt.enabled) && ds.curr_pc < next && ds.act == act) {
            void* code = opt_osr(ds, func);
            if (code != null) return (long)(usz)code;
        }
        return BASELINE_REDISPATCH;
    }
    return (long)s.ordinal;
}

fn void init_thunks() @noinline @private {
    $foreach $op : Opcode::values:
        $if !@excluded($op):
            $if $op == Opcode.CALL || $op == Opcode.CALL_UNDEF_THIS:
                // The CALL and CALL_UNDEF_THIS thunk body is shared with the
                // native call site's direct builtin path (jit_call_thunk).
                thunk_table[$op.ordinal] = fn long(Dispatch* ds, ulong arg) {
                    return jit_call_thunk(ds, arg);
                };
            $else
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
                $if @relayed($op):
                    if ((arg & 1) == 0 && vm::jit_relay(ds, next)) {
                        count_relayed(ds, $op);
                        return 0;
                    }
                $endif
                Activation* act = ds.act;
                CompiledFunction* func = ds.vm.current_func;
                OpStatus s;
                uint count_before = ds.vm.activation_count;
                if (vm::has_feedback($op)) vm::note_feedback(ds, insn);
                s = @run_op($op, ds, insn);
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
                $if @pushes_frame($op):
                    // A callee the lean shapes declined, entered by pushing its frame: run its native
                    // code here rather than unwinding every native frame above to Vm.run.
                    if (ds.needs_restart && s == RESTART) {
                        long entered = vm::jit_enter_pushed(ds, next, count_before);
                        if (entered != vm::JIT_NO_RAW) return entered;
                    }
                $endif
                if (s == NEXT && ds.curr_pc != next) {
                    // A taken backward branch may continue in optimized code.
                    if (@unlikely(ds.heap.opt.enabled) && ds.curr_pc < next && ds.act == act) {
                        void* code = opt_osr(ds, func);
                        if (code != null) return (long)(usz)code;
                    }
                    return BASELINE_REDISPATCH;
                }
                return (long)s.ordinal;
            };
            $endif
        $endif
    $endforeach
    thunks_ready = true;
}

// Print the operand feedback every function recorded, one line per
// instruction with any: "feedback fn#<index> +<word> <op> <classes>".
fn void baseline_dump_feedback(Heap* h) {
    for (uint fi = 0; fi < h.compiled_func_count; fi++) {
        CompiledFunction* cf = (CompiledFunction*)h.compiled_funcs[fi];
        if (cf == null || cf.ic_entries == null) continue;
        hobject::ICEntry* entries = (hobject::ICEntry*)cf.ic_entries;
        for (uint i = 0; i < cf.code_count; i++) {
            char fb = entries[i].feedback;
            if ((fb & hobject::FB_CALL) != 0) {
                io::eprintf("feedback fn#%d +%d %s -> fn#%d", fi, i, cf.code[i].op, entries[i].prop_idx);
                uint n = hobject::ic_call_count(&entries[i]);
                for (uint k = 1; k < n; k++) io::eprintf(" fn#%d", hobject::ic_call_target(&entries[i], k));
                io::eprintfn("%s", (fb & hobject::FB_POLY) != 0 ? " poly" : "");
                continue;
            }
            hobject::ICEntry* pe = &entries[i];
            if (pe.key.borrow() != null && pe.chain != null && pe.chain.protos != null && pe.chain.protos.count != 0) {
                io::eprintfn("feedback fn#%d +%d %s protos %d%s%s", fi, i, cf.code[i].op, pe.chain.protos.count,
                             pe.chain.protos.mega ? " mega" : "", pe.chain.protos.epoch == h.prototype_epoch ? "" : " stale");
            }
            if (fb == 0 || !vm::has_feedback(cf.code[i].op)) continue;
            io::eprintfn("feedback fn#%d +%d %s %s%s%s%s", fi, i, cf.code[i].op,
                         (fb & hobject::FB_OVF) != 0 ? "ovf " : "", (fb & hobject::FB_DBL) != 0 ? "dbl " : "",
                         (fb & hobject::FB_STR) != 0 ? "str " : "", (fb & hobject::FB_OTHER) != 0 ? "other" : "");
        }
    }
}

// Print where native code of `cf` lives, for attributing profiler samples, as each compile
// finishes (--jit-dump-feedback): "map fn#<index> n<instructions> <start> <end> <call entry>
// <subroutines> [opt]" then "ents fn#<index> <address:op:pc of each instruction word>". Code
// freed later may be reused by another compile, whose lines come after.
fn void dump_code_map(CompiledFunction* cf, BaselineCode* bc, bool opt) {
    uint fi = cf.func_index;
    // One write: a large function's line would otherwise take a write per instruction, which
    // shows in the profile it is for.
    DString out;
    out.init(mem, 256);
    defer out.free();
    out.appendf("map fn#%d n%d %x %x %x %x%s\nents fn#%d", fi, cf.code_count, (usz)bc.exec,
                (usz)bc.exec + bc.code_bytes, (usz)bc.call_entry, (usz)bc.subs, opt ? " opt" : "", fi);
    for (usz i = 0; i < cf.code_count; i++) {
        usz at = (usz)bc.entries[i];
        if (at >= (usz)bc.exec && at < (usz)bc.exec + bc.code_bytes) out.appendf(" %x:%s:%d", at, cf.code[i].op, i);
    }
    io::eprintn(out.str_view());
}

// Move one thunk call of `op` from the slow count to the relayed completions.
fn void count_relayed(Dispatch* ds, Opcode op) @inline {
    JitStats* st = &ds.heap.jit_stats;
    if (!st.count_ops) return;
    st.slow_calls[op.ordinal]--;
    st.relay_done[op.ordinal]++;
}

// Opcodes without a thunk: the WIDE prefix, which is never dispatched alone,
// and the enum's end marker.
macro bool @excluded(Opcode $op) @const {
    $switch $op:
        $case Opcode.WIDE:
        $case Opcode.LAST_OP:
            return true;
        $default:
            return false;
    $endswitch
}

// Opcodes whose operation function may enter a callee by pushing its frame and asking for a restart.
macro bool @pushes_frame(Opcode $op) @const {
    $switch $op:
        $case Opcode.CALL:
        $case Opcode.CALL_UNDEF_THIS:
        $case Opcode.CALL_VAR:
        $case Opcode.CALL_GLOBAL:
        $case Opcode.NEW_OBJ:
            return true;
        $default:
            return false;
    $endswitch
}

// Opcodes whose thunk first runs the threaded handler (vm::jit_relay), which
// completes the common cases the inline paths leave out without the
// operation function: megamorphic property sites, typed-array elements,
// concatenation and mixed number additions, integer remainders, cells,
// variable sites filled under another activation's scope chain, scope
// declarations, global stores, instanceof and allocation. None of these
// handlers switches frames or continues past its own instruction.
macro bool @relayed(Opcode $op) @const {
    $switch $op:
        $case Opcode.GETPROPC:
        $case Opcode.GETPROPC_CACHED:
        $case Opcode.GETPROP:
        $case Opcode.GETPROP_CACHE:
        $case Opcode.GETTHISC:
        $case Opcode.PUTPROP:
        $case Opcode.PUTPROPC:
        $case Opcode.PUTTHISC:
        $case Opcode.PUTGLOBAL:
        $case Opcode.ADD:
        $case Opcode.GETVAR:
        $case Opcode.PUTVAR_ASSIGN:
        $case Opcode.PUTVAR_SNAP:
        $case Opcode.RESOLVEVAR:
        $case Opcode.THROW_UNRESOLVED:
        $case Opcode.INC_VAR:
        $case Opcode.DECLVAR:
        $case Opcode.DECLVAR_HOIST:
        $case Opcode.GETCELL:
        $case Opcode.SETCELL:
        $case Opcode.MOVECELL:
        $case Opcode.MOD:
        $case Opcode.INSTANCEOF:
        $case Opcode.TYPEOF:
        $case Opcode.NEWOBJ:
        $case Opcode.NEWOBJ_SHAPE:
        $case Opcode.NEWARR:
        $case Opcode.NEWARR_CONST:
        $case Opcode.NEWARR_FILL:
        $case Opcode.INIT_SLOT:
            return true;
        $default:
            return false;
    $endswitch
}

// Whether `op` is relayed (@relayed), for the code generator's use at run time.
fn bool is_relayed_op(Opcode op) {
    $foreach $op : Opcode::values:
        $if !@excluded($op) && @relayed($op):
            if (op == $op) return true;
        $endif
    $endforeach
    return false;
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
        $case Opcode.NEWARR_FILL:
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
        $case Opcode.RET_GEN:
        $case Opcode.RETUNDEF_GEN: return vm::op_ret_gen(ds, insn);
        $case Opcode.LOAD_RESUME:
        $case Opcode.AWAIT:
        $case Opcode.YIELD:
        $case Opcode.YIELD_STAR:
        $case Opcode.YIELD_STAR_ASYNC:
        $case Opcode.GEN_START: return vm::op_generators(ds, insn);
        $case Opcode.WITH_START: return vm::op_with_start(ds, insn);
        $case Opcode.WITH_END: return vm::op_with_end(ds, insn);

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
