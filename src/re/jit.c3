// The regexp matcher's native tier: the decoded program, emitted as machine code.
//
// The walk in exec.c3 re-reads an instruction, its operands and its branch on
// every step and returns to a dispatch loop after each one. Here the same
// semantics become a graph of blocks joined by direct jumps: the opcode is
// chosen once at compile time, a class is folded into a membership bitmap, and
// a failure jumps to a shared backtracking path instead of a switch arm.
// Semantics are unchanged, and the walk stays the reference: a program this
// compiler does not model keeps the decoded program on the walk, and a machine
// it cannot emit for keeps it on libregexp.
//
// The backtracking state is the walk's: a stack of frames holding a resume
// address, a position and an undo mark. A failure unwinds to the innermost
// frame's mark and jumps to that address, so an alternative costs one indirect
// jump instead of an instruction dispatch. A greedy run pushes one frame for the
// whole run and its resume address is a stub that gives back one code point per
// visit, which is the same economy the walk's run frames make.
//
// Two variants are compiled per program, one per subject form. A Latin-1
// subject is one byte per code unit and never holds a surrogate pair, so the
// narrow variant has none of the combining to do; the wide variant carries it.
// The form is chosen per call, so both live in the same code object.
// A comma in @feat is OR, so this gates on SLJIT alone: no target builds the JIT without regexps.
module boomkat::re_jit @feat(SLJIT);

import boomkat::jit;
import boomkat::re_bindings;
import boomkat::re_native;
import libc;
import std::core::mem;
import std::io;

// Set by the CLI's --jit-dump-feedback: each compiled body's address range goes to stderr as a
// `map re#N` line of the code map scripts/jit_profile.py reads (`w` marks a wide-subject body).
bool print_code_map;
// Set by --jit-dump-code: each body's bytes follow its map line as `ocode re#N <start> <hex>`.
bool print_code_bytes;
uint bodies_compiled;

// A compiled body: RE_MATCH with the captures written, RE_NO_MATCH, or
// RE_TIMEOUT when the interrupt fired.
alias ReJitFn = fn int(re_native::ReCall* call);

// A compiled body is refused beyond this many instructions, which bounds the
// code one pattern can hold: the emitter expands each instruction to a block of
// tens of bytes.
const uint RE_JIT_MAX_INSNS = 2048;

// One character class, in both forms the compiled code tests it with. The
// table, nonzero at each member, answers a Latin-1 unit, where a unit is a code
// point, so the whole membership test is one load; the descriptor answers a wide
// subject's code point above that range with the same test the walk performs.
//
// The table is keyed by subject unit rather than by canonical code point, so
// the ignore-case form needs no canonicalization in generated code: the
// pattern's own canonicalization is folded in when the table is built.
struct ReJitClass {
    char[256] units;
    re_native::ReClass wide;
}

// Per-program constants the compiled code addresses by immediate: the two
// predicate tables the assertions read, and one descriptor per class
// instruction. Owned by the program and freed with it.
struct ReJitData {
    char[256] space_units;
    // Nonzero at each Latin-1 word unit, for the inline word-boundary test.
    char[256] word_units;
    // Nonzero at each Latin-1 unit a match can begin with: the scan between
    // attempts reads one byte per subject unit.
    char[256] first_units;
    ReJitClass[] classes;
    // Class index per instruction, RE_NONE for the instructions that are not
    // class tests.
    uint[] class_at;
}

// The offsets of the state the emitted code reads and writes. The walk and the
// compiled body share one record, so these are the offsets the struct has on
// this build.
struct ReLayout {
    long in_data;
    long in_len;
    long depth;
    long undo_len;
    long frames;
    long frame_cap;
    long regs;
    long capture;
    long undo;
    long undo_cap;
    long heap_frames;
    long heap_undo;
}

// A greedy run's give-back path: the address its frame resumes at, the register
// holding the position the run must keep, and where the program continues.
struct ReJitStub {
    void* label;
    uint slot;
    uint after;
}

// A jump whose destination is not emitted yet.
struct ReJitFix {
    void* jump;
    uint target;
    int kind;
}

const int FIX_INSN = 0;
const int FIX_ATTEMPT = 1;
const int FIX_EXHAUSTED = 2;
const int FIX_BACKTRACK = 3;
const int FIX_STUB = 4;

// A frame's fields, and the stride between frames: the resume address, the
// position it resumes at, and the undo depth to restore first.
const long RE_JIT_FRAME_RESUME = 0;
const long RE_JIT_FRAME_POS = 8;
const long RE_JIT_FRAME_UNDO = 12;
const long RE_JIT_FRAME_STAR = 16;
const uint RE_JIT_FRAME_BYTES = 24;

// The compiled body's own storage, past the frame slots it uses for the attempt
// and for the frame it is unwinding.
const long SLOT_ATTEMPT = 0;
const long SLOT_FRAME = 8;
const long SLOT_RUN_START = 16;
const long SLOT_RUN_END = 24;
const long SLOT_SCRATCH = 32;
// Where the next attempt may start after this one fails (ReAsm.lead_star).
const long SLOT_SKIP = 40;
// The run state follows them in the body's frame: the ReExec, then the frame,
// undo and register buffers it starts with (ReAsm.frame_layout). SLJIT places
// its saved registers and what a call spills above that area.
const long SLOT_EXEC = SLOT_SKIP + 8;
// The most quantifier registers a body keeps in its frame.
const uint RE_JIT_MAX_REGS = 64;

// The emitter's registers. Saved registers hold state that must survive a
// helper call; scratch registers are the C ABI's argument and result registers,
// rebuilt from the saved ones around every call.
struct ReAsm {
    void* c;
    re_native::ReProgram* prog;
    ReJitData* data;
    bool wide;
    bool unicode;
    bool scanning;
    uint first_pc;
    // The greedy run every attempt of a Latin-1 scan opens with, or RE_NONE. Without a
    // back reference, an attempt that fails from p after the run reached q fails from every
    // start up to q as well: the run from there ends at q too and the rest of the pattern sees
    // the same positions. The next attempt starts past q.
    uint lead_star;
    int s_e;      // the ReExec being run
    int s_pos;    // the subject position
    int s_data;   // the subject base
    int s_len;    // the subject length in code units
    int s_polls;  // dispatches left before the interrupt is polled
    int s_n;      // the ReCall, until the run state is set up
    re_native::ReNative* native;
    // The run state is set up: a return releases what its stacks grew into.
    bool exec_ready;
    long off_frames;
    long off_undo;
    long off_regs;
    int locals;
    int t0;
    int t1;
    int t2;
    int t3;
    int t4;
    ReLayout lay;
    void*[] labels;
    ReJitFix[] fixes;
    uint fix_len;
    void* attempt;
    void* backtrack;
    void* exhausted;
    // Where a failed test goes instead of the backtracking path: the loop end of
    // a greedy run turns a mismatch into "the run is over", not "the attempt
    // failed".
    void*[] sink;
    uint sink_len;
    ReJitStub[] stubs;
    uint stub_len;
    // The table a greedy run's loop keeps in t4, or 0.
    usz loop_table;
}

// ---------------------------------------------------------------------------
// Helpers called from generated code
// ---------------------------------------------------------------------------


// The first position at or after `from` where a match could begin, or -1.
fn long re_jit_scan_first(re_native::ReNative* n, re_native::ReExec* e, long from) {
    uint at = re_native::re_scan_first(n, &e.in, (uint)from);
    return at == re_native::RE_NONE ? -1 : (long)at;
}

// The next candidate after a failed attempt at `attempt`, or -1.
fn long re_jit_scan_next(re_native::ReNative* n, re_native::ReExec* e, long attempt) {
    uint at = re_native::re_scan_next(n, &e.in, (uint)attempt);
    return at == re_native::RE_NONE ? -1 : (long)at;
}

// 1 when the interrupt fired, which ends the run as a timeout.
fn long re_jit_poll(re_native::ReExec* e) {
    re_bindings::ReInterrupt* it = e.interrupt;
    if (it == null || it.poll == null) return 0;
    return it.poll(it.opaque) != 0 ? 1 : 0;
}

// Whether a code point above the Latin-1 range is inside the class.
fn long re_jit_class_matches(re_native::ReClass* cls, long cp) {
    return cls.matches((uint)cp) ? 1 : 0;
}

// Make room for one more undo record before the emitted write stores it.
fn long re_jit_reserve_slots(re_native::ReExec* e, long n) {
    e.reserve_slots((uint)n);
    return 0;
}

// The code point ending just before `pos`, which a wide subject's give-back
// needs and the narrow form computes inline.
fn long re_jit_prev_code_point(re_native::ReExec* e, long pos) {
    uint at = (uint)pos;
    e.in.prev_code_point(&at);
    return (long)at;
}

// Free the heap buffers a run's stacks grew into.
fn void re_jit_release(re_native::ReExec* e) {
    e.release();
}

// Make room for one more frame before the emitted push stores it.
fn long re_jit_grow(re_native::ReExec* e) {
    e.reserve_frame();
    return 0;
}

// The offsets of the shared run state on this build.
fn ReLayout re_layout() {
    re_native::ReExec* e = (re_native::ReExec*)(usz)4096;
    ReLayout lay = {
        .in_data = (char*)&e.in.data - (char*)e,
        .in_len = (char*)&e.in.len - (char*)e,
        .depth = (char*)&e.depth - (char*)e,
        .undo_len = (char*)&e.undo_len - (char*)e,
        .frames = (char*)&e.frames - (char*)e,
        .frame_cap = (char*)&e.frame_cap - (char*)e,
        .regs = (char*)&e.regs - (char*)e,
        .capture = (char*)&e.capture - (char*)e,
        .undo = (char*)&e.undo - (char*)e,
        .undo_cap = (char*)&e.undo_cap - (char*)e,
        .heap_frames = (char*)&e.heap_frames - (char*)e,
        .heap_undo = (char*)&e.heap_undo - (char*)e,
    };
    // The emitted code stores through these offsets; a field reordered above
    // them would silently corrupt the run.
    assert(lay.capture == 8 && lay.regs == 16 && lay.frames == 24 && lay.undo == 32);
    assert(lay.frame_cap == 40 && lay.undo_cap == 44 && lay.depth == 48 && lay.undo_len == 52);
    assert(lay.in_data == 72 && lay.in_len == 80);
    re_native::ReFrame* f = (re_native::ReFrame*)(usz)4096;
    assert((char*)&f.resume - (char*)f == RE_JIT_FRAME_RESUME);
    assert((char*)&f.pos - (char*)f == RE_JIT_FRAME_POS);
    assert((char*)&f.undo - (char*)f == RE_JIT_FRAME_UNDO);
    assert((char*)&f.star - (char*)f == RE_JIT_FRAME_STAR);
    assert(re_native::ReFrame::size == RE_JIT_FRAME_BYTES);
    return lay;
}

// Whether the position is a word boundary, or, with `flags` bit 1, whether it is
// not one. Bit 0 is the ignore-case form.
fn long re_jit_word_boundary(re_native::ReExec* e, long pos, long flags) {
    bool boundary = e.in.word_boundary_at((uint)pos, (flags & 1) != 0);
    bool want = (flags & 2) == 0;
    return boundary == want ? 1 : 0;
}

// Whether a code point above the Latin-1 range is a space.
fn long re_jit_is_space(long cp) {
    return re_bindings::re_is_space((uint)cp) ? 1 : 0;
}

// ---------------------------------------------------------------------------
// Emitting
// ---------------------------------------------------------------------------

fn void ReAsm.mov(&self, int dst, long dstw, int src, long srcw) @inline {
    jit::sljit_emit_op1(self.c, jit::SLJIT_MOV, dst, dstw, src, srcw);
}

fn void ReAsm.mov_u8(&self, int dst, long dstw, int src, long srcw) @inline {
    jit::sljit_emit_op1(self.c, jit::SLJIT_MOV_U8, dst, dstw, src, srcw);
}

fn void ReAsm.mov_u16(&self, int dst, long dstw, int src, long srcw) @inline {
    jit::sljit_emit_op1(self.c, jit::SLJIT_MOV_U16, dst, dstw, src, srcw);
}

fn void ReAsm.mov_u32(&self, int dst, long dstw, int src, long srcw) @inline {
    jit::sljit_emit_op1(self.c, jit::SLJIT_MOV_U32, dst, dstw, src, srcw);
}

fn void ReAsm.store_u32(&self, int base, long off, int src) @inline {
    jit::sljit_emit_op1(self.c, jit::SLJIT_MOV_U32, jit::SLJIT_MEM | base, off, src, 0);
}

fn void ReAsm.load_u8(&self, int dst, int base, long off) @inline {
    jit::sljit_emit_op1(self.c, jit::SLJIT_MOV_U8, dst, 0, jit::SLJIT_MEM | base, off);
}

fn void ReAsm.op2(&self, int op, int dst, long dstw, int a, long aw, int b, long bw) @inline {
    jit::sljit_emit_op2(self.c, op, dst, dstw, a, aw, b, bw);
}

fn void* ReAsm.cmp(&self, int cond, int a, long aw, int b, long bw) @inline {
    return jit::sljit_emit_cmp(self.c, cond, a, aw, b, bw);
}

fn void* ReAsm.label(&self) @inline => jit::sljit_emit_label(self.c);

fn void* ReAsm.jump(&self) @inline => jit::sljit_emit_jump(self.c, jit::SLJIT_JUMP);

fn void ReAsm.bind(&self, void* jump, void* label) @inline => jit::sljit_set_label(jump, label);

// Leave the generated function with `value`, releasing the heap buffers the
// run's stacks grew into.
fn void ReAsm.leave(&self, int value) {
    if (self.exec_ready) {
        self.mov(self.t0, 0, jit::SLJIT_MEM | self.s_e, self.lay.heap_frames);
        self.op2(jit::SLJIT_OR, self.t0, 0, self.t0, 0, jit::SLJIT_MEM | self.s_e, self.lay.heap_undo);
        void* bare = self.cmp(jit::SLJIT_EQUAL, self.t0, 0, jit::SLJIT_IMM, 0);
        self.mov(self.t0, 0, self.s_e, 0);
        jit::sljit_emit_icall(self.c, jit::SLJIT_CALL, jit::SLJIT_ARGS1WW,
                              jit::SLJIT_IMM, (long)(usz)&re_jit_release);
        self.bind(bare, self.label());
    }
    jit::sljit_emit_return(self.c, jit::SLJIT_MOV, jit::SLJIT_IMM, (long)value);
}

// Record a jump to be bound once every block and stub has a label.
fn void ReAsm.add_fix(&self, void* jump, uint target, int kind) {
    self.fixes[self.fix_len] = { .jump = jump, .target = target, .kind = kind };
    self.fix_len++;
}

// A jump to an instruction block, a helper label, or a failure path.
fn void ReAsm.go(&self, uint target, int kind) {
    void* jump = self.jump();
    if (kind == FIX_INSN && target < self.labels.len && self.labels[target] != null) {
        self.bind(jump, self.labels[target]);
        return;
    }
    self.add_fix(jump, target, kind);
}

// A backward jump to a label already emitted.
fn void ReAsm.go_label(&self, void* label) @inline => self.bind(self.jump(), label);

// Jump to the backtracking path, which resumes the innermost frame or, when
// there is none, tries the next candidate.
fn void ReAsm.fail(&self) @inline => self.go(0, FIX_BACKTRACK);

fn void ReAsm.fail_if(&self, void* jump) {
    if (self.sink.len != 0) {
        self.sink[self.sink_len] = jump;
        self.sink_len++;
        return;
    }
    self.add_fix(jump, 0, FIX_BACKTRACK);
}

fn void ReAsm.fail_if_equal(&self, int reg, long value) @inline {
    self.fail_if(self.cmp(jit::SLJIT_EQUAL, reg, 0, jit::SLJIT_IMM, value));
}

fn void ReAsm.fail_if_not(&self, int reg, long value) @inline {
    self.fail_if(self.cmp(jit::SLJIT_NOT_EQUAL, reg, 0, jit::SLJIT_IMM, value));
}

// Continue at the instruction after `pc`. The bytecode ends in a terminal
// instruction, so falling off the end is a program the decoder let through.
fn void ReAsm.next(&self, uint pc) {
    if ((usz)pc + 1 < self.prog.insns.len) {
        self.go(pc + 1, FIX_INSN);
    } else {
        self.leave(re_native::RE_ERROR);
    }
}

// The jump taken when the position has run past the subject.
fn void* ReAsm.emit_bounds(&self) @inline {
    return self.cmp(jit::SLJIT_GREATER_EQUAL, self.s_pos, 0, self.s_len, 0);
}

// The code unit at *pos into t0, leaving the position past it; the code point
// when the subject is wide and the pattern unicode, so that a surrogate pair
// reads as one code point. The caller has established that the position is
// inside the subject.
fn void ReAsm.emit_unit_read(&self) {
    int t0 = self.t0;
    int t1 = self.t1;
    if (!self.wide) {
        self.mov_u8(t0, 0, jit::mem_index(self.s_data, self.s_pos), 0);
        self.op2(jit::SLJIT_ADD, self.s_pos, 0, self.s_pos, 0, jit::SLJIT_IMM, 1);
        return;
    }
    self.mov_u16(t0, 0, jit::mem_index(self.s_data, self.s_pos), 1);
    self.op2(jit::SLJIT_ADD, self.s_pos, 0, self.s_pos, 0, jit::SLJIT_IMM, 1);
    if (!self.unicode) return;
    // A high surrogate followed by a low one is one code point over two units.
    void* not_high = self.cmp(jit::SLJIT_LESS, t0, 0, jit::SLJIT_IMM, 0xD800);
    void* above_high = self.cmp(jit::SLJIT_GREATER, t0, 0, jit::SLJIT_IMM, 0xDBFF);
    void* at_end = self.cmp(jit::SLJIT_GREATER_EQUAL, self.s_pos, 0, self.s_len, 0);
    self.mov_u16(t1, 0, jit::mem_index(self.s_data, self.s_pos), 1);
    void* low_below = self.cmp(jit::SLJIT_LESS, t1, 0, jit::SLJIT_IMM, 0xDC00);
    void* low_above = self.cmp(jit::SLJIT_GREATER, t1, 0, jit::SLJIT_IMM, 0xDFFF);
    self.op2(jit::SLJIT_SUB, t0, 0, t0, 0, jit::SLJIT_IMM, 0xD800);
    self.op2(jit::SLJIT_SHL, t0, 0, t0, 0, jit::SLJIT_IMM, 10);
    self.op2(jit::SLJIT_SUB, t1, 0, t1, 0, jit::SLJIT_IMM, 0xDC00);
    self.op2(jit::SLJIT_ADD, t0, 0, t0, 0, t1, 0);
    self.op2(jit::SLJIT_ADD, t0, 0, t0, 0, jit::SLJIT_IMM, 0x10000);
    self.op2(jit::SLJIT_ADD, self.s_pos, 0, self.s_pos, 0, jit::SLJIT_IMM, 1);
    void* done = self.label();
    self.bind(not_high, done);
    self.bind(above_high, done);
    self.bind(at_end, done);
    self.bind(low_below, done);
    self.bind(low_above, done);
}

// Consume one code point into t0, failing when the position is past the end.
fn void ReAsm.emit_read(&self) {
    self.fail_if(self.emit_bounds());
    self.emit_unit_read();
}

// Test the code point in t0 against `insn`. A mismatch is a failure of the
// region being emitted: the attempt, or a greedy run's loop end.
fn void ReAsm.emit_test(&self, re_native::ReInsn* insn, uint pc) {
    switch (insn.op) {
        case ReOp.CHAR: case ReOp.CHAR32:
            self.fail_if_not(self.t0, insn.a);
        case ReOp.CHAR_I: case ReOp.CHAR32_I:
            self.emit_canonicalize();
            self.fail_if_not(self.t0, insn.a);
        case ReOp.DOT:
            self.fail_if_equal(self.t0, '\n');
            self.fail_if_equal(self.t0, '\r');
            if (self.wide) {
                self.fail_if_equal(self.t0, 0x2028);
                self.fail_if_equal(self.t0, 0x2029);
            }
        case ReOp.ANY:
            break;
        case ReOp.SPACE:
            self.emit_space(self.t0, false);
        case ReOp.NOT_SPACE:
            self.emit_space(self.t0, true);
        case ReOp.RANGE: case ReOp.RANGE_I: case ReOp.RANGE32: case ReOp.RANGE32_I:
            self.emit_class(self.t0, self.data.class_at[pc]);
        default:
            // Only the single-character instructions reach here.
            self.fail();
    }
}

// The code unit at the position in `at` into `dst`, as a code unit: the wide
// form's surrogate combining belongs to emit_unit_read, not to a one-unit test.
fn void ReAsm.emit_unit(&self, int dst, int at) @inline {
    if (self.wide) {
        self.mov_u16(dst, 0, jit::mem_index(self.s_data, at), 1);
    } else {
        self.mov_u8(dst, 0, jit::mem_index(self.s_data, at), 0);
    }
}

// The entry for `unit` of the 256-unit table at `table` into `out`, zero for a
// unit outside the set. The unit must be below 256, which every caller
// establishes; t1 is scratch unless a greedy run keeps the table in t4.
fn void ReAsm.emit_bit(&self, int unit, usz table, int out) {
    int base = self.t4;
    if (table != self.loop_table) {
        self.mov(self.t1, 0, jit::SLJIT_IMM, (long)table);
        base = self.t1;
    }
    self.mov_u8(out, 0, jit::mem_index(base, unit), 0);
}

// The unit table the single-character test `insn` at index `pc` reads, or 0.
fn usz ReAsm.table_of(&self, re_native::ReInsn* insn, uint pc) {
    switch (insn.op) {
        case ReOp.SPACE: case ReOp.NOT_SPACE:
            return (usz)&self.data.space_units[0];
        case ReOp.RANGE: case ReOp.RANGE_I: case ReOp.RANGE32: case ReOp.RANGE32_I:
            return (usz)&self.data.classes[self.data.class_at[pc]].units[0];
        default:
            return 0;
    }
}

// Fail unless `unit` is in the class at `index` in the program's data.
fn void ReAsm.emit_class(&self, int unit, uint index) {
    ReJitClass* cls = &self.data.classes[index];
    if (!self.wide) {
        self.emit_bit(unit, (usz)&cls.units[0], self.t3);
        self.fail_if_equal(self.t3, 0);
        return;
    }
    void* above = self.cmp(jit::SLJIT_GREATER_EQUAL, unit, 0, jit::SLJIT_IMM, 256);
    self.emit_bit(unit, (usz)&cls.units[0], self.t3);
    self.fail_if_equal(self.t3, 0);
    void* skip = self.jump();
    self.bind(above, self.label());
    self.mov(self.t1, 0, unit, 0);
    self.mov(self.t0, 0, jit::SLJIT_IMM, (long)(usz)&cls.wide);
    jit::sljit_emit_icall(self.c, jit::SLJIT_CALL, jit::SLJIT_ARGS2WWW_R,
                     jit::SLJIT_IMM, (long)(usz)&re_jit_class_matches);
    self.fail_if_equal(self.t0, 0);
    self.bind(skip, self.label());
}

// Fail unless `unit` is a space, or fail if it is one when `invert`.
fn void ReAsm.emit_space(&self, int unit, bool invert) {
    if (!self.wide) {
        self.emit_bit(unit, (usz)&self.data.space_units[0], self.t3);
        if (invert) {
            self.fail_if_not(self.t3, 0);
        } else {
            self.fail_if_equal(self.t3, 0);
        }
        return;
    }
    void* above = self.cmp(jit::SLJIT_GREATER_EQUAL, unit, 0, jit::SLJIT_IMM, 256);
    self.emit_bit(unit, (usz)&self.data.space_units[0], self.t3);
    if (invert) {
        self.fail_if_not(self.t3, 0);
    } else {
        self.fail_if_equal(self.t3, 0);
    }
    void* skip = self.jump();
    self.bind(above, self.label());
    self.mov(self.t0, 0, unit, 0);
    jit::sljit_emit_icall(self.c, jit::SLJIT_CALL, jit::SLJIT_ARGS1WW_R,
                     jit::SLJIT_IMM, (long)(usz)&re_jit_is_space);
    if (invert) {
        self.fail_if_not(self.t0, 0);
    } else {
        self.fail_if_equal(self.t0, 0);
    }
    self.bind(skip, self.label());
}

// Fail unless the position sits at a line start, or, in multiline mode, just
// after a line terminator.
fn void ReAsm.emit_line_start(&self, bool multiline) {
    if (!multiline) {
        self.fail_if_not(self.s_pos, 0);
        return;
    }
    void* at_start = self.cmp(jit::SLJIT_EQUAL, self.s_pos, 0, jit::SLJIT_IMM, 0);
    self.op2(jit::SLJIT_SUB, self.t1, 0, self.s_pos, 0, jit::SLJIT_IMM, 1);
    self.emit_unit(self.t0, self.t1);
    void* lf = self.cmp(jit::SLJIT_EQUAL, self.t0, 0, jit::SLJIT_IMM, '\n');
    void* cr = self.cmp(jit::SLJIT_EQUAL, self.t0, 0, jit::SLJIT_IMM, '\r');
    void* separator_a = null;
    void* separator_b = null;
    if (self.wide) {
        separator_a = self.cmp(jit::SLJIT_EQUAL, self.t0, 0, jit::SLJIT_IMM, 0x2028);
        separator_b = self.cmp(jit::SLJIT_EQUAL, self.t0, 0, jit::SLJIT_IMM, 0x2029);
    }
    self.fail();
    void* ok = self.label();
    self.bind(at_start, ok);
    self.bind(lf, ok);
    self.bind(cr, ok);
    if (separator_a != null) self.bind(separator_a, ok);
    if (separator_b != null) self.bind(separator_b, ok);
}

// Fail unless the position sits at a line end, or, in multiline mode, just
// before a line terminator.
fn void ReAsm.emit_line_end(&self, bool multiline) {
    if (!multiline) {
        self.fail_if(self.cmp(jit::SLJIT_NOT_EQUAL, self.s_pos, 0, self.s_len, 0));
        return;
    }
    void* at_end = self.cmp(jit::SLJIT_EQUAL, self.s_pos, 0, self.s_len, 0);
    self.emit_unit(self.t0, self.s_pos);
    void* lf = self.cmp(jit::SLJIT_EQUAL, self.t0, 0, jit::SLJIT_IMM, '\n');
    void* cr = self.cmp(jit::SLJIT_EQUAL, self.t0, 0, jit::SLJIT_IMM, '\r');
    void* separator_a = null;
    void* separator_b = null;
    if (self.wide) {
        separator_a = self.cmp(jit::SLJIT_EQUAL, self.t0, 0, jit::SLJIT_IMM, 0x2028);
        separator_b = self.cmp(jit::SLJIT_EQUAL, self.t0, 0, jit::SLJIT_IMM, 0x2029);
    }
    self.fail();
    void* ok = self.label();
    self.bind(at_end, ok);
    self.bind(lf, ok);
    self.bind(cr, ok);
    if (separator_a != null) self.bind(separator_a, ok);
    if (separator_b != null) self.bind(separator_b, ok);
}

// Fail unless exactly one of the code points around the position is a word
// character; `invert` is the \B form, which requires the two to agree.
fn void ReAsm.emit_word_boundary(&self, bool ignore_case, bool invert) {
    if (self.wide) {
        self.mov(self.t0, 0, self.s_e, 0);
        self.mov_u32(self.t1, 0, self.s_pos, 0);
        self.mov(self.t2, 0, jit::SLJIT_IMM, (ignore_case ? 1 : 0) | (invert ? 2 : 0));
        jit::sljit_emit_icall(self.c, jit::SLJIT_CALL, jit::SLJIT_ARGS3WWW_R,
                              jit::SLJIT_IMM, (long)(usz)&re_jit_word_boundary);
        self.fail_if_equal(self.t0, 0);
        return;
    }
    // A Latin-1 unit is a word character by the table; past either end there is none.
    self.mov(self.t1, 0, jit::SLJIT_IMM, (long)(usz)&self.data.word_units);
    self.mov(self.t2, 0, jit::SLJIT_IMM, 0);
    self.mov(self.t3, 0, jit::SLJIT_IMM, 0);
    void* at_end = self.emit_bounds();
    self.mov_u8(self.t0, 0, jit::mem_index(self.s_data, self.s_pos), 0);
    self.mov_u8(self.t2, 0, jit::mem_index(self.t1, self.t0), 0);
    self.bind(at_end, self.label());
    void* at_start = self.cmp(jit::SLJIT_EQUAL, self.s_pos, 0, jit::SLJIT_IMM, 0);
    self.op2(jit::SLJIT_SUB, self.t4, 0, self.s_pos, 0, jit::SLJIT_IMM, 1);
    self.mov_u8(self.t0, 0, jit::mem_index(self.s_data, self.t4), 0);
    self.mov_u8(self.t3, 0, jit::mem_index(self.t1, self.t0), 0);
    self.bind(at_start, self.label());
    // A boundary when exactly one side is a word character.
    self.fail_if(self.cmp(invert ? jit::SLJIT_NOT_EQUAL : jit::SLJIT_EQUAL, self.t2, 0, self.t3, 0));
}

// Canonicalize the code point in t0 for the ignore-case comparisons: the ASCII
// letters fold inline, everything else takes libregexp's table lookup.
fn void ReAsm.emit_canonicalize(&self) {
    int t0 = self.t0;
    void* slow = self.cmp(jit::SLJIT_GREATER_EQUAL, t0, 0, jit::SLJIT_IMM, 128);
    void* low;
    void* high;
    if (self.unicode) {
        low = self.cmp(jit::SLJIT_LESS, t0, 0, jit::SLJIT_IMM, 'A');
        high = self.cmp(jit::SLJIT_GREATER, t0, 0, jit::SLJIT_IMM, 'Z');
        self.op2(jit::SLJIT_ADD, t0, 0, t0, 0, jit::SLJIT_IMM, 32);
    } else {
        low = self.cmp(jit::SLJIT_LESS, t0, 0, jit::SLJIT_IMM, 'a');
        high = self.cmp(jit::SLJIT_GREATER, t0, 0, jit::SLJIT_IMM, 'z');
        self.op2(jit::SLJIT_SUB, t0, 0, t0, 0, jit::SLJIT_IMM, 32);
    }
    void* skip = self.jump();
    self.bind(slow, self.label());
    self.mov(self.t1, 0, jit::SLJIT_IMM, self.unicode ? 1 : 0);
    jit::sljit_emit_icall(self.c, jit::SLJIT_CALL, jit::SLJIT_ARGS2WWW_R,
                     jit::SLJIT_IMM, (long)(usz)&re_bindings::re_canonicalize);
    self.mov_u32(t0, 0, t0, 0);
    void* done = self.label();
    self.bind(skip, done);
    self.bind(low, done);
    self.bind(high, done);
}

// Read the quantifier register `slot`, which sits past the captures in the
// run's slot array. One load, since the index is known here.
fn void ReAsm.emit_read_reg(&self, uint slot, int dst) {
    uint base = self.prog.capture_count * 2;
    int regs = dst == self.t0 ? self.t1 : self.t0;
    self.mov(regs, 0, jit::SLJIT_MEM | self.s_e, self.lay.regs);
    self.mov_u32(dst, 0, jit::SLJIT_MEM | regs, (long)(slot - base) * 4);
}

// Write the capture slot or register `slot` from a value in `value`, recording
// what it held so a failed attempt can restore it.
//
// The record is written here rather than by a helper: a capture write is once or
// twice per attempt, and a call per write showed up at the top of the profile.
// Every write is recorded, without the walk's scan for an earlier record of the
// same slot: restoring in reverse order undoes a repeated write just as exactly,
// and a run that rewrites a capture is bounded by the subject's length.
fn void ReAsm.emit_write(&self, uint slot, int value) {
    uint captures = self.prog.capture_count * 2;
    long array = slot < captures ? self.lay.capture : self.lay.regs;
    long off = (long)(slot < captures ? slot : slot - captures) * 4;
    // With no frame behind it, nothing can resume to before this write, and the
    // next attempt resets the captures itself: there is nothing to record.
    self.mov_u32(self.t1, 0, jit::SLJIT_MEM | self.s_e, self.lay.depth);
    void* bare = self.cmp(jit::SLJIT_EQUAL, self.t1, 0, jit::SLJIT_IMM, 0);
    // Room for one more record; the growth is rare, so it stays a call.
    self.mov_u32(self.t1, 0, jit::SLJIT_MEM | self.s_e, self.lay.undo_len);
    self.mov_u32(self.t2, 0, jit::SLJIT_MEM | self.s_e, self.lay.undo_cap);
    void* room = self.cmp(jit::SLJIT_LESS, self.t1, 0, self.t2, 0);
    // The helper takes the run in R0, and the value being written has to survive
    // the call: it is spilled here, which is why only the rare path pays.
    self.mov(jit::SLJIT_MEM | jit::reg_sp(), SLOT_SCRATCH, value, 0);
    self.mov(self.t0, 0, self.s_e, 0);
    self.mov(self.t1, 0, jit::SLJIT_IMM, 1);
    jit::sljit_emit_icall(self.c, jit::SLJIT_CALL, jit::SLJIT_ARGS2WWW_R,
                          jit::SLJIT_IMM, (long)(usz)&re_jit_reserve_slots);
    self.mov(value, 0, jit::SLJIT_MEM | jit::reg_sp(), SLOT_SCRATCH);
    self.bind(room, self.label());
    self.mov_u32(self.t1, 0, jit::SLJIT_MEM | self.s_e, self.lay.undo_len);
    // The record: the slot, and the value it held.
    self.mov(self.t2, 0, jit::SLJIT_MEM | self.s_e, self.lay.undo);
    self.op2(jit::SLJIT_SHL, self.t3, 0, self.t1, 0, jit::SLJIT_IMM, 3);
    self.op2(jit::SLJIT_ADD, self.t2, 0, self.t2, 0, self.t3, 0);
    self.mov(self.t3, 0, jit::SLJIT_IMM, (long)slot);
    self.store_u32(self.t2, 0, self.t3);
    self.mov(self.t3, 0, jit::SLJIT_MEM | self.s_e, array);
    self.mov_u32(self.t3, 0, jit::SLJIT_MEM | self.t3, off);
    self.store_u32(self.t2, 4, self.t3);
    self.op2(jit::SLJIT_ADD, self.t1, 0, self.t1, 0, jit::SLJIT_IMM, 1);
    self.store_u32(self.s_e, self.lay.undo_len, self.t1);
    // The value itself.
    self.bind(bare, self.label());
    self.mov(self.t1, 0, jit::SLJIT_MEM | self.s_e, array);
    self.mov_u32(jit::SLJIT_MEM | self.t1, off, value, 0);
}

// Whether the instruction only writes captures or registers, from the position
// or a constant: a run of them is emitted as one batch.
fn bool re_jit_write_op(ReOp op) @inline {
    return op == ReOp.SAVE_START || op == ReOp.SAVE_END || op == ReOp.SAVE_RESET
        || op == ReOp.SET_I32 || op == ReOp.SET_CHAR_POS;
}

// One write of a batch: the slot, and the constant it receives unless it takes
// the position.
struct ReJitWrite {
    uint slot;
    bool at_pos;
    uint value;
}

// The writes of the `n` instructions from `pc`, in order, into `out` when it is
// not empty; the count either way.
fn uint ReAsm.collect_writes(&self, uint pc, uint n, ReJitWrite[] out) {
    uint count = 0;
    uint regs = self.prog.capture_count * 2;
    for (uint i = pc; i < pc + n; i++) {
        re_native::ReInsn* insn = &self.prog.insns[i];
        switch (insn.op) {
            case ReOp.SAVE_START: case ReOp.SAVE_END:
                if (out.len) out[count] = { (uint)insn.a * 2 + (insn.op == ReOp.SAVE_END ? 1 : 0), true, 0 };
                count++;
            case ReOp.SAVE_RESET:
                for (uint slot = (uint)insn.a * 2; slot <= (uint)insn.b * 2 + 1; slot++) {
                    if (out.len) out[count] = { slot, false, re_native::RE_UNSET };
                    count++;
                }
            case ReOp.SET_I32:
                if (out.len) out[count] = { regs + insn.reg, false, (uint)insn.a };
                count++;
            case ReOp.SET_CHAR_POS:
                if (out.len) out[count] = { regs + insn.reg, true, 0 };
                count++;
            default:
                unreachable("not a write");
        }
    }
    return count;
}

// The `n` write instructions from `pc` as one batch: one check for a frame
// behind them and one for room, a record per distinct slot holding the value it
// had before the batch, then the stores. Restoring the records undoes the whole
// batch, whatever order its writes overwrite each other in.
fn void ReAsm.emit_writes(&self, uint pc, uint n) {
    uint count = self.collect_writes(pc, n, {});
    ReJitWrite[] writes = mem::new_array(ReJitWrite, (sz)count);
    defer mem::free(writes);
    self.collect_writes(pc, n, writes);
    uint captures = self.prog.capture_count * 2;
    bool any_reg = false;
    foreach (w : writes) if (w.slot >= captures) any_reg = true;
    // Only the first write of a slot needs its old value kept.
    bool[] first = mem::new_array(bool, (sz)count);
    defer mem::free(first);
    uint records = 0;
    foreach (i, w : writes) {
        first[i] = true;
        for (sz k = 0; k < i; k++) if (writes[k].slot == w.slot) first[i] = false;
        if (first[i]) records++;
    }
    // With no frame behind it, nothing can resume to before this batch, and the
    // next attempt resets the captures itself: there is nothing to record.
    self.mov_u32(self.t1, 0, jit::SLJIT_MEM | self.s_e, self.lay.depth);
    void* bare = self.cmp(jit::SLJIT_EQUAL, self.t1, 0, jit::SLJIT_IMM, 0);
    self.mov_u32(self.t1, 0, jit::SLJIT_MEM | self.s_e, self.lay.undo_len);
    self.mov_u32(self.t2, 0, jit::SLJIT_MEM | self.s_e, self.lay.undo_cap);
    self.op2(jit::SLJIT_ADD, self.t1, 0, self.t1, 0, jit::SLJIT_IMM, (long)records);
    void* room = self.cmp(jit::SLJIT_LESS_EQUAL, self.t1, 0, self.t2, 0);
    self.mov(self.t0, 0, self.s_e, 0);
    self.mov(self.t1, 0, jit::SLJIT_IMM, (long)records);
    jit::sljit_emit_icall(self.c, jit::SLJIT_CALL, jit::SLJIT_ARGS2WWW_R,
                          jit::SLJIT_IMM, (long)(usz)&re_jit_reserve_slots);
    self.bind(room, self.label());
    self.mov_u32(self.t1, 0, jit::SLJIT_MEM | self.s_e, self.lay.undo_len);
    self.mov(self.t2, 0, jit::SLJIT_MEM | self.s_e, self.lay.undo);
    self.op2(jit::SLJIT_SHL, self.t3, 0, self.t1, 0, jit::SLJIT_IMM, 3);
    self.op2(jit::SLJIT_ADD, self.t2, 0, self.t2, 0, self.t3, 0);
    self.op2(jit::SLJIT_ADD, self.t1, 0, self.t1, 0, jit::SLJIT_IMM, (long)records);
    self.store_u32(self.s_e, self.lay.undo_len, self.t1);
    self.mov(self.t0, 0, jit::SLJIT_MEM | self.s_e, self.lay.capture);
    if (any_reg) self.mov(self.t4, 0, jit::SLJIT_MEM | self.s_e, self.lay.regs);
    long at = 0;
    foreach (i, w : writes) {
        if (!first[i]) continue;
        int base = w.slot < captures ? self.t0 : self.t4;
        long off = (long)(w.slot < captures ? w.slot : w.slot - captures) * 4;
        self.mov(self.t3, 0, jit::SLJIT_IMM, (long)w.slot);
        self.store_u32(self.t2, at, self.t3);
        self.mov_u32(self.t3, 0, jit::SLJIT_MEM | base, off);
        self.store_u32(self.t2, at + 4, self.t3);
        at += 8;
    }
    self.bind(bare, self.label());
    self.mov(self.t0, 0, jit::SLJIT_MEM | self.s_e, self.lay.capture);
    if (any_reg) self.mov(self.t4, 0, jit::SLJIT_MEM | self.s_e, self.lay.regs);
    foreach (w : writes) {
        int base = w.slot < captures ? self.t0 : self.t4;
        long off = (long)(w.slot < captures ? w.slot : w.slot - captures) * 4;
        if (w.at_pos) {
            self.store_u32(base, off, self.s_pos);
        } else {
            self.mov(self.t3, 0, jit::SLJIT_IMM, (long)w.value);
            self.store_u32(base, off, self.t3);
        }
    }
}

// Restore every write recorded above the mark in t1, in place: the walk's undo
// loop, without a call. Records are few unless the attempt wrote a lot, and then
// there is nothing cheaper.
fn void ReAsm.emit_unwind(&self) {
    uint captures = self.prog.capture_count * 2;
    void* loop = self.label();
    self.mov_u32(self.t2, 0, jit::SLJIT_MEM | self.s_e, self.lay.undo_len);
    void* done = self.cmp(jit::SLJIT_LESS_EQUAL, self.t2, 0, self.t1, 0);
    self.op2(jit::SLJIT_SUB, self.t2, 0, self.t2, 0, jit::SLJIT_IMM, 1);
    self.store_u32(self.s_e, self.lay.undo_len, self.t2);
    // The record: the slot it wrote and the value it replaced.
    self.mov(self.t0, 0, jit::SLJIT_MEM | self.s_e, self.lay.undo);
    self.op2(jit::SLJIT_SHL, self.t3, 0, self.t2, 0, jit::SLJIT_IMM, 3);
    self.op2(jit::SLJIT_ADD, self.t0, 0, self.t0, 0, self.t3, 0);
    self.mov_u32(self.t4, 0, jit::SLJIT_MEM | self.t0, 0);
    self.mov_u32(self.t3, 0, jit::SLJIT_MEM | self.t0, 4);
    void* registers = self.cmp(jit::SLJIT_GREATER_EQUAL, self.t4, 0, jit::SLJIT_IMM, (long)captures);
    self.mov(self.t0, 0, jit::SLJIT_MEM | self.s_e, self.lay.capture);
    self.op2(jit::SLJIT_SHL, self.t4, 0, self.t4, 0, jit::SLJIT_IMM, 2);
    self.op2(jit::SLJIT_ADD, self.t0, 0, self.t0, 0, self.t4, 0);
    self.mov_u32(jit::SLJIT_MEM | self.t0, 0, self.t3, 0);
    self.go_label(loop);
    self.bind(registers, self.label());
    self.mov(self.t0, 0, jit::SLJIT_MEM | self.s_e, self.lay.regs);
    self.op2(jit::SLJIT_SUB, self.t4, 0, self.t4, 0, jit::SLJIT_IMM, (long)captures);
    self.op2(jit::SLJIT_SHL, self.t4, 0, self.t4, 0, jit::SLJIT_IMM, 2);
    self.op2(jit::SLJIT_ADD, self.t0, 0, self.t0, 0, self.t4, 0);
    self.mov_u32(jit::SLJIT_MEM | self.t0, 0, self.t3, 0);
    self.go_label(loop);
    self.bind(done, self.label());
}

// Push a backtracking frame that resumes at `target`, from the current
// position, undoing whatever is written from here on.
fn void ReAsm.emit_push(&self, int kind, uint target, bool run) {
    // Room for one more frame. Growth reallocates the stack and updates the run,
    // so it is a call, and the depth and the base are read again afterwards.
    self.mov_u32(self.t1, 0, jit::SLJIT_MEM | self.s_e, self.lay.depth);
    self.mov_u32(self.t2, 0, jit::SLJIT_MEM | self.s_e, self.lay.frame_cap);
    void* room = self.cmp(jit::SLJIT_LESS, self.t1, 0, self.t2, 0);
    self.mov(self.t0, 0, self.s_e, 0);
    jit::sljit_emit_icall(self.c, jit::SLJIT_CALL, jit::SLJIT_ARGS1WW,
                          jit::SLJIT_IMM, (long)(usz)&re_jit_grow);
    self.bind(room, self.label());
    self.mov_u32(self.t1, 0, jit::SLJIT_MEM | self.s_e, self.lay.depth);
    // The resume address, bound to the block or stub this frame returns to.
    void* resume = jit::sljit_emit_op_addr(self.c, jit::SLJIT_MOV_ADDR, self.t0, 0);
    self.add_fix(resume, target, kind);
    // The frame at depth, whose stride is the frame's size.
    self.mov(self.t2, 0, jit::SLJIT_MEM | self.s_e, self.lay.frames);
    self.op2(jit::SLJIT_SHL, self.t3, 0, self.t1, 0, jit::SLJIT_IMM, 1);
    self.op2(jit::SLJIT_ADD, self.t3, 0, self.t3, 0, self.t1, 0);
    self.op2(jit::SLJIT_SHL, self.t3, 0, self.t3, 0, jit::SLJIT_IMM, 3);
    self.op2(jit::SLJIT_ADD, self.t2, 0, self.t2, 0, self.t3, 0);
    self.mov(jit::SLJIT_MEM | self.t2, RE_JIT_FRAME_RESUME, self.t0, 0);
    self.store_u32(self.t2, RE_JIT_FRAME_POS, self.s_pos);
    self.mov_u32(self.t3, 0, jit::SLJIT_MEM | self.s_e, self.lay.undo_len);
    self.store_u32(self.t2, RE_JIT_FRAME_UNDO, self.t3);
    self.mov(self.t3, 0, jit::SLJIT_IMM, run ? 1 : 0);
    jit::sljit_emit_op1(self.c, jit::SLJIT_MOV_U8, jit::SLJIT_MEM | self.t2, RE_JIT_FRAME_STAR, self.t3, 0);
    self.op2(jit::SLJIT_ADD, self.t1, 0, self.t1, 0, jit::SLJIT_IMM, 1);
    self.store_u32(self.s_e, self.lay.depth, self.t1);
}

// The first instruction on the straight path from `pc` that tests the subject,
// passing over writes and gotos, with its index in *at; null when something else
// comes first or the test cannot be peeked at.
fn re_native::ReInsn* ReAsm.first_test(&self, uint pc, uint* at) {
    for (uint steps = 0; steps < 16 && pc < self.prog.insns.len; steps++) {
        re_native::ReInsn* insn = &self.prog.insns[pc];
        switch (insn.op) {
            case ReOp.GOTO:
                pc = insn.target;
            case ReOp.SAVE_START: case ReOp.SAVE_END: case ReOp.SAVE_RESET:
            case ReOp.SET_I32: case ReOp.SET_CHAR_POS:
                pc++;
            case ReOp.CHAR: case ReOp.DOT: case ReOp.SPACE: case ReOp.NOT_SPACE:
            case ReOp.RANGE: case ReOp.RANGE_I: case ReOp.RANGE32: case ReOp.RANGE32_I:
                *at = pc;
                return insn;
            case ReOp.CHAR_I:
                if (!((insn.a >= 'a' && insn.a <= 'z') || (insn.a >= 'A' && insn.a <= 'Z'))) return null;
                *at = pc;
                return insn;
            default:
                return null;
        }
    }
    return null;
}

// Go to `dest` when the code point at the position certainly fails `insn`, at
// index `pc`, which first_test found: the subject is exhausted, or its unit is
// outside the test. The position is not consumed. A wide unit above the Latin-1
// range is left to the test itself, except against a plain character.
fn void ReAsm.emit_peek(&self, re_native::ReInsn* insn, uint pc, uint dest) {
    self.add_fix(self.emit_bounds(), dest, FIX_INSN);
    self.emit_unit(self.t0, self.s_pos);
    void* above = null;
    if (self.wide && insn.op != ReOp.CHAR) above = self.cmp(jit::SLJIT_GREATER_EQUAL, self.t0, 0, jit::SLJIT_IMM, 256);
    switch (insn.op) {
        case ReOp.CHAR:
            // A unit that differs differs as a code point too: a pair combines
            // to a value no 16-bit character equals.
            self.add_fix(self.cmp(jit::SLJIT_NOT_EQUAL, self.t0, 0, jit::SLJIT_IMM, insn.a), dest, FIX_INSN);
        case ReOp.CHAR_I:
            self.op2(jit::SLJIT_OR, self.t0, 0, self.t0, 0, jit::SLJIT_IMM, 0x20);
            self.add_fix(self.cmp(jit::SLJIT_NOT_EQUAL, self.t0, 0, jit::SLJIT_IMM, insn.a | 0x20), dest, FIX_INSN);
        case ReOp.DOT:
            self.add_fix(self.cmp(jit::SLJIT_EQUAL, self.t0, 0, jit::SLJIT_IMM, '\n'), dest, FIX_INSN);
            self.add_fix(self.cmp(jit::SLJIT_EQUAL, self.t0, 0, jit::SLJIT_IMM, '\r'), dest, FIX_INSN);
        case ReOp.SPACE: case ReOp.NOT_SPACE:
            self.emit_bit(self.t0, (usz)&self.data.space_units[0], self.t3);
            int cond = insn.op == ReOp.SPACE ? jit::SLJIT_EQUAL : jit::SLJIT_NOT_EQUAL;
            self.add_fix(self.cmp(cond, self.t3, 0, jit::SLJIT_IMM, 0), dest, FIX_INSN);
        default:
            self.emit_bit(self.t0, (usz)&self.data.classes[self.data.class_at[pc]].units[0], self.t3);
            self.add_fix(self.cmp(jit::SLJIT_EQUAL, self.t3, 0, jit::SLJIT_IMM, 0), dest, FIX_INSN);
    }
    if (above != null) self.bind(above, self.label());
}

// One split: the alternative is pushed and the preferred side runs. A side whose
// first test the next code point certainly fails is not tried: the other runs
// without a frame.
fn void ReAsm.emit_split(&self, uint pc, re_native::ReInsn* insn, bool target_first) {
    uint preferred = target_first ? insn.target : pc + 1;
    uint other = target_first ? pc + 1 : insn.target;
    uint at;
    re_native::ReInsn* test = self.first_test(preferred, &at);
    if (test != null) self.emit_peek(test, at, other);
    test = self.first_test(other, &at);
    if (test != null) self.emit_peek(test, at, preferred);
    self.emit_push(FIX_INSN, other, false);
    self.go(preferred, FIX_INSN);
}

// A counted repeat: step the counter down, keep looping while it is above what
// the pattern requires, and split once it reaches it. The check-advance forms
// fail when the atom stopped advancing before the minimum was reached.
fn void ReAsm.emit_loop_split(&self, uint pc, re_native::ReInsn* insn) {
    uint base = self.prog.capture_count * 2;
    uint slot = base + insn.reg;
    bool checking = insn.op == ReOp.LOOP_CHECK_ADV_SPLIT_GOTO_FIRST
        || insn.op == ReOp.LOOP_CHECK_ADV_SPLIT_NEXT_FIRST;
    bool next_first = insn.op == ReOp.LOOP_SPLIT_NEXT_FIRST
        || insn.op == ReOp.LOOP_CHECK_ADV_SPLIT_NEXT_FIRST;
    self.emit_read_reg(slot, self.t3);
    self.op2(jit::SLJIT_SUB, self.t3, 0, self.t3, 0, jit::SLJIT_IMM, 1);
    self.mov(self.t0, 0, self.t3, 0);
    self.emit_write(slot, self.t0);
    // The write uses the scratch registers, so the counter is read back.
    self.emit_read_reg(slot, self.t3);
    // Still inside the count the pattern requires: keep looping.
    void* settled_down = self.cmp(jit::SLJIT_LESS_EQUAL, self.t3, 0, jit::SLJIT_IMM, insn.a);
    self.go(insn.target, FIX_INSN);
    self.bind(settled_down, self.label());
    if (checking) {
        self.emit_read_reg(slot + 1, self.t0);
        void* advanced = self.cmp(jit::SLJIT_NOT_EQUAL, self.t0, 0, self.s_pos, 0);
        void* at_minimum = self.cmp(jit::SLJIT_EQUAL, self.t3, 0, jit::SLJIT_IMM, insn.a);
        self.fail();
        void* settled = self.label();
        self.bind(advanced, settled);
        self.bind(at_minimum, settled);
    }
    // The count has reached the minimum: the rest of the pattern is tried once,
    // with the loop still available when that fails.
    void* looping = self.cmp(jit::SLJIT_NOT_EQUAL, self.t3, 0, jit::SLJIT_IMM, 0);
    self.next(pc);
    self.bind(looping, self.label());
    if (next_first) {
        self.emit_push(FIX_INSN, insn.target, false);
        self.next(pc);
    } else {
        self.emit_push(FIX_INSN, pc + 1, false);
        self.go(insn.target, FIX_INSN);
    }
}

// A greedy run over one single-character atom. The run takes everything the
// atom matches; what it consumed beyond the minimum is given back one code point
// at a time by the stub, which is the same frame economy the walk's runs make.
fn void ReAsm.emit_star(&self, uint pc) {
    re_native::ReInsn* insn = &self.prog.insns[pc];
    re_native::ReInsn* body = &self.prog.insns[insn.target];
    uint min = (uint)insn.a;
    uint slot = self.prog.capture_count * 2 + insn.reg;
    int sp = jit::reg_sp();
    self.mov(jit::SLJIT_MEM | sp, SLOT_RUN_START, self.s_pos, 0);
    void*[16] exits;
    self.sink = exits[..];
    self.sink_len = 0;
    if (!self.wide) self.loop_table = self.table_of(body, insn.target);
    if (self.loop_table != 0) self.mov(self.t4, 0, jit::SLJIT_IMM, (long)self.loop_table);
    void* loop = self.label();
    void* out_of_units = self.emit_bounds();
    self.emit_unit_read();
    self.emit_test(body, insn.target);
    self.go_label(loop);
    self.loop_table = 0;
    uint exits_len = self.sink_len;
    self.sink = {};
    // A test that fails leaves the position past the code point it read; the
    // run ends just before it.
    void* failed = self.label();
    for (uint i = 0; i < exits_len; i++) self.bind(exits[i], failed);
    if (self.wide) {
        self.mov(self.t0, 0, self.s_e, 0);
        self.mov(self.t1, 0, self.s_pos, 0);
        jit::sljit_emit_icall(self.c, jit::SLJIT_CALL, jit::SLJIT_ARGS2WWW_R,
                              jit::SLJIT_IMM, (long)(usz)&re_jit_prev_code_point);
        self.mov(self.s_pos, 0, self.t0, 0);
        self.mov_u32(self.s_pos, 0, self.t0, 0);
    } else {
        self.op2(jit::SLJIT_SUB, self.s_pos, 0, self.s_pos, 0, jit::SLJIT_IMM, 1);
    }
    void* ran = self.label();
    self.bind(out_of_units, ran);
    if (pc == self.lead_star) {
        self.op2(jit::SLJIT_ADD, self.t0, 0, self.s_pos, 0, jit::SLJIT_IMM, 1);
        self.mov(jit::SLJIT_MEM | sp, SLOT_SKIP, self.t0, 0);
    }
    // The run must cover the minimum the pattern requires.
    self.mov(self.t0, 0, jit::SLJIT_MEM | sp, SLOT_RUN_START);
    self.op2(jit::SLJIT_ADD, self.t0, 0, self.t0, 0, jit::SLJIT_IMM, (long)min);
    if (min != 0) {
        void* enough = self.cmp(jit::SLJIT_GREATER_EQUAL, self.s_pos, 0, self.t0, 0);
        self.fail();
        self.bind(enough, self.label());
    }
    if (insn.possessive) {
        self.go(insn.after, FIX_INSN);
        return;
    }
    // The position the minimum ends at is kept where a give-back reads it, and
    // across the write, which returns through registers the emitted code does
    // not own.
    self.mov(jit::SLJIT_MEM | sp, SLOT_RUN_END, self.t0, 0);
    self.emit_write(slot, self.t0);
    self.mov(self.t1, 0, jit::SLJIT_MEM | sp, SLOT_RUN_END);
    void* no_frame = self.cmp(jit::SLJIT_EQUAL, self.s_pos, 0, self.t1, 0);
    self.emit_push(FIX_STUB, self.stub_len, true);
    self.go(insn.after, FIX_INSN);
    self.bind(no_frame, self.label());
    self.go(insn.after, FIX_INSN);
    self.emit_giveback(self.stub_len, slot, insn.after);
}

// The out-of-line path a greedy run's frame resumes at: hand one code point back
// and continue after the run, or drop the frame once only the minimum is left.
fn void ReAsm.emit_giveback(&self, uint stub, uint slot, uint after) {
    int sp = jit::reg_sp();
    self.stubs[stub].slot = slot;
    self.stubs[stub].after = after;
    self.stubs[stub].label = self.label();
    self.stub_len = stub + 1;
    // The position the run must keep, straight from its own register.
    self.emit_read_reg(slot, self.t0);
    self.mov(jit::SLJIT_MEM | sp, SLOT_RUN_END, self.t0, 0);
    // One code point back from the current position.
    if (self.wide) {
        self.mov(self.t0, 0, self.s_e, 0);
        self.mov(self.t1, 0, self.s_pos, 0);
        jit::sljit_emit_icall(self.c, jit::SLJIT_CALL, jit::SLJIT_ARGS2WWW_R,
                              jit::SLJIT_IMM, (long)(usz)&re_jit_prev_code_point);
        self.mov(self.t0, 0, self.t0, 0);
    } else {
        void* at_zero = self.cmp(jit::SLJIT_EQUAL, self.s_pos, 0, jit::SLJIT_IMM, 0);
        self.mov(self.t0, 0, self.s_pos, 0);
        self.op2(jit::SLJIT_SUB, self.t0, 0, self.t0, 0, jit::SLJIT_IMM, 1);
        self.bind(at_zero, self.label());
    }
    self.mov(self.t1, 0, jit::SLJIT_MEM | sp, SLOT_RUN_END);
    self.mov_u32(self.t0, 0, self.t0, 0);
    void* spent = self.cmp(jit::SLJIT_LESS_EQUAL, self.t0, 0, self.t1, 0);
    // Still above the minimum: the frame keeps the position it gave back to.
    self.mov(self.s_pos, 0, self.t0, 0);
    self.mov_u32(self.t2, 0, jit::SLJIT_MEM | self.s_e, self.lay.depth);
    self.op2(jit::SLJIT_SUB, self.t2, 0, self.t2, 0, jit::SLJIT_IMM, 1);
    self.mov(self.t3, 0, jit::SLJIT_MEM | self.s_e, self.lay.frames);
    self.op2(jit::SLJIT_SHL, self.t4, 0, self.t2, 0, jit::SLJIT_IMM, 1);
    self.op2(jit::SLJIT_ADD, self.t4, 0, self.t4, 0, self.t2, 0);
    self.op2(jit::SLJIT_SHL, self.t4, 0, self.t4, 0, jit::SLJIT_IMM, 3);
    self.op2(jit::SLJIT_ADD, self.t3, 0, self.t3, 0, self.t4, 0);
    self.store_u32(self.t3, RE_JIT_FRAME_POS, self.t0);
    self.go(after, FIX_INSN);
    // Only the minimum is left: the run is spent and the frame goes with it.
    self.bind(spent, self.label());
    self.mov(self.s_pos, 0, self.t1, 0);
    self.mov_u32(self.t2, 0, jit::SLJIT_MEM | self.s_e, self.lay.depth);
    self.op2(jit::SLJIT_SUB, self.t2, 0, self.t2, 0, jit::SLJIT_IMM, 1);
    self.store_u32(self.s_e, self.lay.depth, self.t2);
    self.go(after, FIX_INSN);
}

// Every failure lands here: resume the innermost frame after restoring what the
// failed attempt wrote, or, with no frame left, look for another candidate.
// Resuming polls as an attempt does: a single attempt can backtrack without
// bound, as `^(a+)+$` does against a long run of `a` with no match.
fn void ReAsm.emit_backtrack(&self) {
    int sp = jit::reg_sp();
    self.emit_poll();
    self.mov_u32(self.t0, 0, jit::SLJIT_MEM | self.s_e, self.lay.depth);
    void* empty = self.cmp(jit::SLJIT_EQUAL, self.t0, 0, jit::SLJIT_IMM, 0);
    // The innermost frame.
    self.op2(jit::SLJIT_SUB, self.t1, 0, self.t0, 0, jit::SLJIT_IMM, 1);
    self.mov(self.t2, 0, jit::SLJIT_MEM | self.s_e, self.lay.frames);
    self.op2(jit::SLJIT_SHL, self.t3, 0, self.t1, 0, jit::SLJIT_IMM, 1);
    self.op2(jit::SLJIT_ADD, self.t3, 0, self.t3, 0, self.t1, 0);
    self.op2(jit::SLJIT_SHL, self.t3, 0, self.t3, 0, jit::SLJIT_IMM, 3);
    self.op2(jit::SLJIT_ADD, self.t2, 0, self.t2, 0, self.t3, 0);
    self.mov(jit::SLJIT_MEM | sp, SLOT_FRAME, self.t2, 0);
    // A greedy run's frame stays where it is: its stub hands back one code point
    // per visit and drops the frame itself once only the minimum is left. Every
    // other frame is spent by resuming it.
    self.load_u8(self.t3, self.t2, RE_JIT_FRAME_STAR);
    void* run = self.cmp(jit::SLJIT_NOT_EQUAL, self.t3, 0, jit::SLJIT_IMM, 0);
    self.op2(jit::SLJIT_SUB, self.t0, 0, self.t0, 0, jit::SLJIT_IMM, 1);
    self.store_u32(self.s_e, self.lay.depth, self.t0);
    self.bind(run, self.label());
    self.mov_u32(self.t1, 0, jit::SLJIT_MEM | self.t2, RE_JIT_FRAME_UNDO);
    self.emit_unwind();
    self.mov(self.t2, 0, jit::SLJIT_MEM | sp, SLOT_FRAME);
    self.mov_u32(self.s_pos, 0, jit::SLJIT_MEM | self.t2, RE_JIT_FRAME_POS);
    self.mov(self.t0, 0, jit::SLJIT_MEM | self.t2, RE_JIT_FRAME_RESUME);
    jit::sljit_emit_ijump(self.c, jit::SLJIT_JUMP, self.t0, 0);
    self.bind(empty, self.label());
}

// Whether the single-character instruction at `pc` can continue a run: the same
// kind of test with nothing branching into it, and no surrogate in unicode mode,
// where a pattern char and a subject unit are not enough on their own.
fn bool ReAsm.run_char(&self, uint pc, bool* target) @inline {
    re_native::ReInsn* insn = &self.prog.insns[pc];
    if (insn.op != ReOp.CHAR && insn.op != ReOp.CHAR_I) return false;
    if (self.wide && self.unicode) {
        long c = insn.a;
        if (c >= 0xD800 && c <= 0xDFFF) return false;
    }
    if (insn.op == ReOp.CHAR_I) {
        // The folded comparison sets bit 5 of both sides, which is exact only
        // for ASCII letters.
        long c = insn.a;
        if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z'))) return false;
    }
    return true;
}

fn uint ReAsm.run_length(&self, uint pc, bool* target) {
    uint n = 0;
    while ((usz)pc + n < self.prog.insns.len && n < 8) {
        if (n != 0 && target[pc + n]) break;
        if (!self.run_char(pc + n, target)) break;
        n++;
    }
    return n;
}

// How many write instructions from `pc` form one batch: nothing may branch into
// the middle of it.
fn uint ReAsm.write_length(&self, uint pc, bool* target) {
    uint n = 0;
    while ((usz)pc + n < self.prog.insns.len) {
        if (n != 0 && target[pc + n]) break;
        if (!re_jit_write_op(self.prog.insns[pc + n].op)) break;
        n++;
    }
    return n;
}

// Emit a run of `n` single-character instructions: one bounds check and one base
// pointer, then a compare per character, each failing to the backtracking path.
fn void ReAsm.emit_char_run(&self, uint pc, uint n) {
    // pos + n must be inside the subject.
    self.op2(jit::SLJIT_ADD, self.t1, 0, self.s_pos, 0, jit::SLJIT_IMM, (long)n);
    self.fail_if(self.cmp(jit::SLJIT_GREATER, self.t1, 0, self.s_len, 0));
    // The base of the run, in units.
    if (self.wide) {
        self.op2(jit::SLJIT_SHL, self.t1, 0, self.s_pos, 0, jit::SLJIT_IMM, 1);
        self.op2(jit::SLJIT_ADD, self.t2, 0, self.s_data, 0, self.t1, 0);
    } else {
        self.op2(jit::SLJIT_ADD, self.t2, 0, self.s_data, 0, self.s_pos, 0);
    }
    for (uint i = 0; i < n; i++) {
        re_native::ReInsn* insn = &self.prog.insns[pc + i];
        long width = self.wide ? 2 : 1;
        if (self.wide) {
            self.mov_u16(self.t0, 0, jit::SLJIT_MEM | self.t2, (long)i * width);
        } else {
            self.mov_u8(self.t0, 0, jit::SLJIT_MEM | self.t2, (long)i * width);
        }
        if (insn.op == ReOp.CHAR_I) {
            self.op2(jit::SLJIT_OR, self.t0, 0, self.t0, 0, jit::SLJIT_IMM, 0x20);
            self.fail_if_not(self.t0, insn.a | 0x20);
        } else {
            self.fail_if_not(self.t0, insn.a);
        }
    }
    self.op2(jit::SLJIT_ADD, self.s_pos, 0, self.s_pos, 0, jit::SLJIT_IMM, (long)n);
}

// One instruction. Its label is emitted by the caller.
fn void ReAsm.emit_insn(&self, uint pc) {
    re_native::ReInsn* insn = &self.prog.insns[pc];
    switch (insn.op) {
        case ReOp.CHAR: case ReOp.CHAR_I: case ReOp.CHAR32: case ReOp.CHAR32_I:
        case ReOp.DOT: case ReOp.ANY: case ReOp.SPACE: case ReOp.NOT_SPACE:
        case ReOp.RANGE: case ReOp.RANGE_I: case ReOp.RANGE32: case ReOp.RANGE32_I:
            self.emit_read();
            self.emit_test(insn, pc);
        case ReOp.LINE_START:
            self.emit_line_start(false);
        case ReOp.LINE_START_M:
            self.emit_line_start(true);
        case ReOp.LINE_END:
            self.emit_line_end(false);
        case ReOp.LINE_END_M:
            self.emit_line_end(true);
        case ReOp.WORD_BOUNDARY:
            self.emit_word_boundary(false, false);
        case ReOp.WORD_BOUNDARY_I:
            self.emit_word_boundary(true, false);
        case ReOp.NOT_WORD_BOUNDARY:
            self.emit_word_boundary(false, true);
        case ReOp.NOT_WORD_BOUNDARY_I:
            self.emit_word_boundary(true, true);
        case ReOp.SAVE_START: case ReOp.SAVE_END: case ReOp.SAVE_RESET:
        case ReOp.SET_I32: case ReOp.SET_CHAR_POS:
            self.emit_writes(pc, 1);
        case ReOp.CHECK_ADVANCE:
            self.emit_read_reg(self.prog.capture_count * 2 + insn.reg, self.t0);
            self.fail_if(self.cmp(jit::SLJIT_EQUAL, self.t0, 0, self.s_pos, 0));
        case ReOp.LOOP:
            self.emit_read_reg(self.prog.capture_count * 2 + insn.reg, self.t3);
            self.op2(jit::SLJIT_SUB, self.t3, 0, self.t3, 0, jit::SLJIT_IMM, 1);
            self.mov(self.t0, 0, self.t3, 0);
            self.emit_write(self.prog.capture_count * 2 + insn.reg, self.t0);
            self.emit_read_reg(self.prog.capture_count * 2 + insn.reg, self.t3);
            void* spent = self.cmp(jit::SLJIT_EQUAL, self.t3, 0, jit::SLJIT_IMM, 0);
            self.go(insn.target, FIX_INSN);
            self.bind(spent, self.label());
        case ReOp.LOOP_SPLIT_GOTO_FIRST: case ReOp.LOOP_SPLIT_NEXT_FIRST:
        case ReOp.LOOP_CHECK_ADV_SPLIT_GOTO_FIRST: case ReOp.LOOP_CHECK_ADV_SPLIT_NEXT_FIRST:
            self.emit_loop_split(pc, insn);
            return;
        case ReOp.PREV:
            self.fail_if(self.cmp(jit::SLJIT_EQUAL, self.s_pos, 0, jit::SLJIT_IMM, 0));
            if (self.wide) {
                self.mov(self.t0, 0, self.s_e, 0);
                self.mov(self.t1, 0, self.s_pos, 0);
                jit::sljit_emit_icall(self.c, jit::SLJIT_CALL, jit::SLJIT_ARGS2WWW_R,
                                      jit::SLJIT_IMM, (long)(usz)&re_jit_prev_code_point);
                self.mov_u32(self.s_pos, 0, self.t0, 0);
            } else {
                self.op2(jit::SLJIT_SUB, self.s_pos, 0, self.s_pos, 0, jit::SLJIT_IMM, 1);
            }
        case ReOp.SPLIT_GOTO_FIRST:
            self.emit_split(pc, insn, true);
            return;
        case ReOp.SPLIT_NEXT_FIRST:
            self.emit_split(pc, insn, false);
            return;
        case ReOp.STAR:
            self.emit_star(pc);
            return;
        case ReOp.GOTO:
            self.go(insn.target, FIX_INSN);
            return;
        case ReOp.MATCH:
            self.leave(re_bindings::RE_MATCH);
            return;
        default:
            // A program with an instruction this emitter does not model is
            // refused before a block is emitted.
            self.leave(re_native::RE_ERROR);
            return;
    }
    self.next(pc);
}

// Count one dispatch against the poll budget, polling the interrupt and leaving
// with RE_TIMEOUT when it runs out and the interrupt fired. Clobbers the
// scratch registers.
fn void ReAsm.emit_poll(&self) {
    self.op2(jit::SLJIT_SUB, self.t0, 0, self.s_polls, 0, jit::SLJIT_IMM, 1);
    self.mov(self.s_polls, 0, self.t0, 0);
    void* counting = self.cmp(jit::SLJIT_NOT_EQUAL, self.t0, 0, jit::SLJIT_IMM, 0);
    self.mov(self.t0, 0, self.s_e, 0);
    jit::sljit_emit_icall(self.c, jit::SLJIT_CALL, jit::SLJIT_ARGS1WW_R,
                     jit::SLJIT_IMM, (long)(usz)&re_jit_poll);
    self.mov(self.s_polls, 0, jit::SLJIT_IMM, re_native::RE_POLL_INTERVAL);
    void* no_timeout = self.cmp(jit::SLJIT_EQUAL, self.t0, 0, jit::SLJIT_IMM, 0);
    self.leave(re_native::RE_TIMEOUT);
    self.bind(no_timeout, self.label());
    self.bind(counting, self.label());
}

// The attempt loop: poll the interrupt, reset the state a failed attempt left
// behind, remember where this attempt starts, and run the body.
fn void ReAsm.emit_attempt(&self) {
    self.emit_poll();
    // No frame survives a failed attempt, and the writes it made with none
    // behind them were never recorded: its records are dropped and its groups
    // reset outright. Group 0 is written before it is read, as is every
    // register.
    self.mov(self.t1, 0, jit::SLJIT_IMM, 0);
    self.store_u32(self.s_e, self.lay.undo_len, self.t1);
    if (self.prog.capture_count > 1) {
        self.mov(self.t0, 0, jit::SLJIT_MEM | self.s_e, self.lay.capture);
        self.mov(self.t1, 0, jit::SLJIT_IMM, (long)re_native::RE_UNSET);
        for (uint i = 2; i < self.prog.capture_count * 2; i++) self.store_u32(self.t0, (long)i * 4, self.t1);
    }
    self.mov(jit::SLJIT_MEM | jit::reg_sp(), 0, self.s_pos, 0);
    self.go(self.first_pc, FIX_INSN);
}

// Nothing left to resume: another candidate, or no match.
fn void ReAsm.emit_exhausted(&self) {
    if (!self.scanning) {
        self.leave(re_native::RE_NO_MATCH);
        return;
    }
    if (self.wide) {
        self.mov(self.t0, 0, jit::SLJIT_IMM, (long)(usz)self.native);
        self.mov(self.t1, 0, self.s_e, 0);
        self.mov_u32(self.t2, 0, jit::SLJIT_MEM | jit::reg_sp(), 0);
        jit::sljit_emit_icall(self.c, jit::SLJIT_CALL, jit::SLJIT_ARGS3WWW_R,
                         jit::SLJIT_IMM, (long)(usz)&re_jit_scan_next);
        void* none = self.cmp(jit::SLJIT_EQUAL, self.t0, 0, jit::SLJIT_IMM, -1);
        self.mov(self.s_pos, 0, self.t0, 0);
        self.go(0, FIX_ATTEMPT);
        self.bind(none, self.label());
        self.leave(re_native::RE_NO_MATCH);
        return;
    }
    if (self.lead_star != re_native::RE_NONE) {
        self.mov(self.s_pos, 0, jit::SLJIT_MEM | jit::reg_sp(), SLOT_SKIP);
        self.emit_scan();
        return;
    }
    // A Latin-1 unit is a code point: the next candidate is one unit on.
    self.mov_u32(self.s_pos, 0, jit::SLJIT_MEM | jit::reg_sp(), 0);
    void* last = self.cmp(jit::SLJIT_GREATER_EQUAL, self.s_pos, 0, self.s_len, 0);
    self.op2(jit::SLJIT_ADD, self.s_pos, 0, self.s_pos, 0, jit::SLJIT_IMM, 1);
    self.emit_scan();
    self.bind(last, self.label());
    self.leave(re_native::RE_NO_MATCH);
}

// The next position at or after s_pos where a match can begin, as re_scan_first
// finds it, and an attempt there; with none, the run ends without a match. A
// Latin-1 subject is scanned here: a single first unit by memchr, a set of them
// through its bitmap, one unit per step. A wide subject's code points take the
// walk's scan.
fn void ReAsm.emit_scan(&self) {
    re_native::ReNative* n = self.native;
    if (self.wide) {
        self.mov(self.t0, 0, jit::SLJIT_IMM, (long)(usz)self.native);
        self.mov(self.t1, 0, self.s_e, 0);
        self.mov(self.t2, 0, self.s_pos, 0);
        jit::sljit_emit_icall(self.c, jit::SLJIT_CALL, jit::SLJIT_ARGS3WWW_R,
                         jit::SLJIT_IMM, (long)(usz)&re_jit_scan_first);
        void* none = self.cmp(jit::SLJIT_EQUAL, self.t0, 0, jit::SLJIT_IMM, -1);
        self.mov(self.s_pos, 0, self.t0, 0);
        self.go(0, FIX_ATTEMPT);
        self.bind(none, self.label());
        self.leave(re_native::RE_NO_MATCH);
        return;
    }
    void* past = self.cmp(jit::SLJIT_GREATER, self.s_pos, 0, self.s_len, 0);
    if (n.fs_at_start) self.add_fix(self.cmp(jit::SLJIT_EQUAL, self.s_pos, 0, jit::SLJIT_IMM, 0), 0, FIX_ATTEMPT);
    if (n.fs_single >= 0) {
        self.op2(jit::SLJIT_ADD, self.t0, 0, self.s_data, 0, self.s_pos, 0);
        self.mov(self.t1, 0, jit::SLJIT_IMM, n.fs_single);
        self.op2(jit::SLJIT_SUB, self.t2, 0, self.s_len, 0, self.s_pos, 0);
        jit::sljit_emit_icall(self.c, jit::SLJIT_CALL, jit::SLJIT_ARGS3WWW_R,
                         jit::SLJIT_IMM, (long)(usz)&libc::memchr);
        void* miss = self.cmp(jit::SLJIT_EQUAL, self.t0, 0, jit::SLJIT_IMM, 0);
        self.op2(jit::SLJIT_SUB, self.s_pos, 0, self.t0, 0, self.s_data, 0);
        self.go(0, FIX_ATTEMPT);
        self.bind(miss, self.label());
        self.mov(self.s_pos, 0, self.s_len, 0);
    } else {
        self.mov(self.t1, 0, jit::SLJIT_IMM, (long)(usz)&self.data.first_units);
        void* loop = self.label();
        void* end = self.cmp(jit::SLJIT_GREATER_EQUAL, self.s_pos, 0, self.s_len, 0);
        self.mov_u8(self.t0, 0, jit::mem_index(self.s_data, self.s_pos), 0);
        self.mov_u8(self.t0, 0, jit::mem_index(self.t1, self.t0), 0);
        self.add_fix(self.cmp(jit::SLJIT_NOT_EQUAL, self.t0, 0, jit::SLJIT_IMM, 0), 0, FIX_ATTEMPT);
        self.op2(jit::SLJIT_ADD, self.s_pos, 0, self.s_pos, 0, jit::SLJIT_IMM, 1);
        self.bind(self.jump(), loop);
        self.bind(end, self.label());
    }
    // The scan ran off the end, where an empty match may still sit.
    if (n.fs_at_end) self.go(0, FIX_ATTEMPT);
    self.bind(past, self.label());
    self.leave(re_native::RE_NO_MATCH);
}

// The literal checks of re_prefilter, made before the first attempt: a start
// past the end fails, a prefix at the start offset is compared in place, a
// floating prefix is searched for and moves the start to its first occurrence,
// and a required substring must occur at or after the start. A prefix that is
// the whole pattern is the match. s_polls is scratch here.
fn void ReAsm.emit_literal(&self) {
    re_native::ReNative* n = self.native;
    int sh = self.wide ? 1 : 0;
    void*[24] none;
    usz nones = 0;
    none[nones++] = self.cmp(jit::SLJIT_GREATER, self.s_pos, 0, self.s_len, 0);
    if (n.lit_len > 0) {
        switch (n.lit_where) {
            case re_bindings::RE_LIT_AT_ZERO:
            case re_bindings::RE_LIT_AT:
                if (n.lit_where == re_bindings::RE_LIT_AT_ZERO) {
                    none[nones++] = self.cmp(jit::SLJIT_NOT_EQUAL, self.s_pos, 0, jit::SLJIT_IMM, 0);
                }
                self.op2(jit::SLJIT_SUB, self.t0, 0, self.s_len, 0, self.s_pos, 0);
                none[nones++] = self.cmp(jit::SLJIT_LESS, self.t0, 0, jit::SLJIT_IMM, n.lit_len);
                self.op2(jit::SLJIT_SHL, self.t1, 0, self.s_pos, 0, jit::SLJIT_IMM, sh);
                self.op2(jit::SLJIT_ADD, self.t1, 0, self.t1, 0, self.s_data, 0);
                for (uint k = 0; k < n.lit_len; k++) {
                    self.emit_lit_unit(self.t2, self.t1, k);
                    none[nones++] = self.cmp(jit::SLJIT_NOT_EQUAL, self.t2, 0, jit::SLJIT_IMM, (char)n.lit[k]);
                }
            default:
                self.mov(self.t0, 0, self.s_pos, 0);
                self.emit_find(&none, &nones);
                if (n.lit_where == re_bindings::RE_LIT_PREFIX) self.mov(self.s_pos, 0, self.t0, 0);
        }
        if (n.lit_whole) {
            self.mov(self.t1, 0, jit::SLJIT_MEM | self.s_n, re_call_offset(RE_CALL_CAPS));
            self.store_u32(self.t1, 0, self.s_pos);
            self.op2(jit::SLJIT_ADD, self.t2, 0, self.s_pos, 0, jit::SLJIT_IMM, n.lit_len);
            self.store_u32(self.t1, 4, self.t2);
            self.leave(re_bindings::RE_MATCH);
        }
    }
    void* go_on = self.jump();
    void* fail = self.label();
    foreach (j : none[:nones]) self.bind(j, fail);
    self.leave(re_native::RE_NO_MATCH);
    self.bind(go_on, self.label());
}

// Unit `k` of the subject from the address in `base` into `dst`.
fn void ReAsm.emit_lit_unit(&self, int dst, int base, uint k) @inline {
    if (self.wide) {
        self.mov_u16(dst, 0, jit::SLJIT_MEM | base, (long)k * 2);
    } else {
        self.mov_u8(dst, 0, jit::SLJIT_MEM | base, (long)k);
    }
}

// One AArch64 instruction, for the operations SLJIT has no form of.
fn void ReAsm.a64(&self, uint insn) @inline {
    jit::sljit_emit_op_custom(self.c, &insn, 4);
}

fn uint ReAsm.hw(&self, int reg) @inline => (uint)jit::sljit_get_register_index(jit::SLJIT_GP_REGISTER, reg);

// The first occurrence of the literal at or after the unit in t0, into t0; a
// subject without one appends its failure to `none`. On AArch64 a 32-byte block
// of candidates at a time is screened by comparing the literal's rarest unit,
// and a second one when it has two, across the block; only the candidates a
// block flags are compared in full. The last two 16-byte chunks overlap the end
// rather than leave a tail. A subject shorter than a chunk, and every subject
// elsewhere, is tested one candidate at a time. s_polls and t1 to t4 are
// scratch; the vector code uses v16 to v21, which no caller preserves.
fn void ReAsm.emit_find(&self, void*[24]* none, usz* nones) {
    re_native::ReNative* n = self.native;
    void* found;
    // t1: the last unit a match of the literal can start at.
    self.op2(jit::SLJIT_SUB, self.t1, 0, self.s_len, 0, jit::SLJIT_IMM, n.lit_len);
    (*none)[(*nones)++] = self.cmp(jit::SLJIT_SIG_GREATER, self.t0, 0, self.t1, 0);
    $if env::AARCH64:
        int sh = self.wide ? 1 : 0;
        uint rare = n.lit_rare;
        long block = (long)(32 >> sh);
        long half = block / 2;
        void*[5] hits;
        uint lanes = self.wide ? 0x4E020C00 : 0x4E010C00;   // DUP Vd.16B/8H, Wn
        self.mov(self.t2, 0, jit::SLJIT_IMM, (char)n.lit[rare]);
        self.a64(lanes | self.hw(self.t2) << 5 | 20);
        if (n.lit_len > 1) {
            self.mov(self.t2, 0, jit::SLJIT_IMM, (char)n.lit[self.lit_second()]);
            self.a64(lanes | self.hw(self.t2) << 5 | 21);
        }
        void* enter = self.label();
        // s_polls: the furthest the block pointer may stand and read a whole block.
        self.op2(jit::SLJIT_ADD, self.s_polls, 0, self.t1, 0, jit::SLJIT_IMM, (long)rare - block + 1);
        self.op2(jit::SLJIT_SHL, self.s_polls, 0, self.s_polls, 0, jit::SLJIT_IMM, sh);
        self.op2(jit::SLJIT_ADD, self.s_polls, 0, self.s_polls, 0, self.s_data, 0);
        self.emit_lit_address(self.t2, self.t0, 0, rare);
        void* narrow = self.cmp(jit::SLJIT_GREATER, self.t2, 0, self.s_polls, 0);
        if (n.lit_len > 1) {
            self.op2(jit::SLJIT_ADD, self.t3, 0, self.t2, 0, jit::SLJIT_IMM, ((long)self.lit_second() - rare) << sh);
        }
        void* loop = self.label();
        self.emit_lit_screen(self.t2, self.t3, true);
        self.a64(0x6EA0A400 | 17 << 16 | 16 << 5 | 16);         // UMAXP v16.4S, v16.4S, v17.4S
        self.a64(0x6EA0A400 | 16 << 16 | 16 << 5 | 16);         // UMAXP v16.4S, v16.4S, v16.4S
        self.a64(0x9E660000 | 16 << 5 | self.hw(self.t4));      // FMOV t4, d16
        void* hit = self.cmp(jit::SLJIT_NOT_EQUAL, self.t4, 0, jit::SLJIT_IMM, 0);
        self.bind(self.cmp(jit::SLJIT_LESS_EQUAL, self.t2, 0, self.s_polls, 0), loop);
        // No whole block left: t0 back from the block pointer.
        self.op2(jit::SLJIT_SUB, self.t0, 0, self.t2, 0, self.s_data, 0);
        self.op2(jit::SLJIT_LSHR, self.t0, 0, self.t0, 0, jit::SLJIT_IMM, sh);
        self.op2(jit::SLJIT_SUB, self.t0, 0, self.t0, 0, jit::SLJIT_IMM, rare);
        void* rest = self.jump();
        // A flagged block: its two chunks' candidates, then on past it.
        self.bind(hit, self.label());
        self.op2(jit::SLJIT_SUB, self.t0, 0, self.t2, 0, self.s_data, 0);
        self.op2(jit::SLJIT_LSHR, self.t0, 0, self.t0, 0, jit::SLJIT_IMM, sh);
        self.op2(jit::SLJIT_SUB, self.t0, 0, self.t0, 0, jit::SLJIT_IMM, (long)rare + block);
        hits[0] = self.emit_lit_chunk(self.t0, 0);
        hits[1] = self.emit_lit_chunk(self.t0, half);
        self.op2(jit::SLJIT_ADD, self.t0, 0, self.t0, 0, jit::SLJIT_IMM, block);
        self.bind(self.jump(), enter);
        // Fewer than two chunks of candidates are left: the chunk at t0 and the
        // one ending at the last candidate cover them.
        void* tail = self.label();
        self.bind(narrow, tail);
        self.bind(rest, tail);
        self.op2(jit::SLJIT_SUB, self.t2, 0, self.t1, 0, jit::SLJIT_IMM, half - 1);
        void* tiny = self.cmp(jit::SLJIT_SIG_LESS, self.t2, 0, jit::SLJIT_IMM, 0);
        void* late = self.cmp(jit::SLJIT_SIG_GREATER, self.t0, 0, self.t2, 0);
        hits[2] = self.emit_lit_chunk(self.t0, 0);
        self.bind(late, self.label());
        hits[3] = self.emit_lit_chunk(self.t1, 1 - half);
        (*none)[(*nones)++] = self.jump();
        self.bind(tiny, self.label());
        hits[4] = self.emit_find_units();
        (*none)[(*nones)++] = self.jump();
        found = self.label();
        foreach (j : hits) self.bind(j, found);
    $else
        void* hit = self.emit_find_units();
        (*none)[(*nones)++] = self.jump();
        self.bind(hit, self.label());
    $endif
}

// The index of the unit the vector screen compares besides the rarest one.
fn uint ReAsm.lit_second(&self) @inline => self.native.lit_rare == 0 ? self.native.lit_len - 1 : 0;

// Into `dst` the address of unit `k` of the candidate `off` units past the one
// in `at`.
fn void ReAsm.emit_lit_address(&self, int dst, int at, long off, uint k) {
    self.op2(jit::SLJIT_ADD, dst, 0, at, 0, jit::SLJIT_IMM, off + k);
    self.op2(jit::SLJIT_SHL, dst, 0, dst, 0, jit::SLJIT_IMM, self.wide ? 1 : 0);
    self.op2(jit::SLJIT_ADD, dst, 0, dst, 0, self.s_data, 0);
}

// The screen's compares into v16 (and v17 for a whole block): every lane whose
// candidate has the rarest unit at `a`, and the second one at `b`, all ones.
// A whole block advances both addresses past it.
fn void ReAsm.emit_lit_screen(&self, int a, int b, bool whole) {
    uint cmeq = self.wide ? 0x6E608C00 : 0x6E208C00;        // CMEQ Vd.16B/8H
    uint ra = self.hw(a);
    uint rb = self.hw(b);
    uint chunks = whole ? 2 : 1;
    if (whole) {
        self.a64(0xACC10000 | 17 << 10 | ra << 5 | 16);     // LDP q16, q17, [a], #32
    } else {
        self.a64(0x3DC00000 | ra << 5 | 16);                // LDR q16, [a]
    }
    for (uint i = 16; i < 16 + chunks; i++) self.a64(cmeq | 20 << 16 | i << 5 | i);
    if (self.native.lit_len < 2) return;
    if (whole) {
        self.a64(0xACC10000 | 19 << 10 | rb << 5 | 18);     // LDP q18, q19, [b], #32
    } else {
        self.a64(0x3DC00000 | rb << 5 | 18);                // LDR q18, [b]
    }
    for (uint i = 18; i < 18 + chunks; i++) {
        self.a64(cmeq | 21 << 16 | i << 5 | i);
        self.a64(0x4E201C00 | i << 16 | (i - 2) << 5 | (i - 2));  // AND
    }
}

// The 16-byte chunk of candidates `off` units past the one in `at`, all of
// which are at most the last: the jump taken with the first one at or after
// t0 whose whole literal matches in t0, falling through without one. `at` is
// t0 or t1; t2 to t4 and s_polls are scratch.
fn void* ReAsm.emit_lit_chunk(&self, int at, long off) {
    re_native::ReNative* n = self.native;
    int unit_bits = self.wide ? 8 : 4;
    self.emit_lit_address(self.t2, at, off, n.lit_rare);
    if (n.lit_len > 1) self.emit_lit_address(self.t3, at, off, self.lit_second());
    self.emit_lit_screen(self.t2, self.t3, false);
    self.a64(0x0F0C8400 | 16 << 5 | 16);                    // SHRN v16.8B, v16.8H, #4
    self.a64(0x9E660000 | 16 << 5 | self.hw(self.t4));      // FMOV t4, d16
    // t4 holds `unit_bits` set bits per flagged candidate, lowest first.
    void* loop = self.label();
    void* done = self.cmp(jit::SLJIT_EQUAL, self.t4, 0, jit::SLJIT_IMM, 0);
    jit::sljit_emit_op1(self.c, jit::SLJIT_CTZ, self.t2, 0, self.t4, 0);
    self.mov(self.t3, 0, jit::SLJIT_IMM, (long)((1 << unit_bits) - 1));
    self.op2(jit::SLJIT_SHL, self.t3, 0, self.t3, 0, self.t2, 0);
    self.op2(jit::SLJIT_XOR, self.t4, 0, self.t4, 0, self.t3, 0);
    self.op2(jit::SLJIT_LSHR, self.t2, 0, self.t2, 0, jit::SLJIT_IMM, self.wide ? 3 : 2);
    self.op2(jit::SLJIT_ADD, self.t2, 0, self.t2, 0, at, 0);
    if (off != 0) self.op2(jit::SLJIT_ADD, self.t2, 0, self.t2, 0, jit::SLJIT_IMM, off);
    self.bind(self.cmp(jit::SLJIT_SIG_LESS, self.t2, 0, self.t0, 0), loop);
    void*[16] miss;
    usz misses = self.emit_lit_compare(self.t2, self.s_polls, &miss);
    foreach (j : miss[:misses]) self.bind(j, loop);
    self.mov(self.t0, 0, self.t2, 0);
    void* match = self.jump();
    self.bind(done, self.label());
    return match;
}

// The whole literal compared at the candidate in `at`, with t3 and `tmp` as
// scratch: the jumps a mismatch takes into `miss`, and their count.
fn usz ReAsm.emit_lit_compare(&self, int at, int tmp, void*[16]* miss) {
    re_native::ReNative* n = self.native;
    usz misses = 0;
    self.emit_lit_address(self.t3, at, 0, 0);
    self.emit_lit_unit(tmp, self.t3, n.lit_rare);
    (*miss)[misses++] = self.cmp(jit::SLJIT_NOT_EQUAL, tmp, 0, jit::SLJIT_IMM, (char)n.lit[n.lit_rare]);
    for (uint k = 0; k < n.lit_len; k++) {
        if (k == n.lit_rare) continue;
        self.emit_lit_unit(tmp, self.t3, k);
        (*miss)[misses++] = self.cmp(jit::SLJIT_NOT_EQUAL, tmp, 0, jit::SLJIT_IMM, (char)n.lit[k]);
    }
    return misses;
}

// The literal tested at each candidate from the unit in t0 through the last,
// in t1: the jump taken with the match's start in t0, falling through without
// one. t2 and t3 are scratch.
fn void* ReAsm.emit_find_units(&self) {
    void* loop = self.label();
    void* exhausted = self.cmp(jit::SLJIT_SIG_GREATER, self.t0, 0, self.t1, 0);
    void*[16] miss;
    usz misses = self.emit_lit_compare(self.t0, self.t2, &miss);
    void* match = self.jump();
    void* next = self.label();
    foreach (j : miss[:misses]) self.bind(j, next);
    self.op2(jit::SLJIT_ADD, self.t0, 0, self.t0, 0, jit::SLJIT_IMM, 1);
    self.bind(self.jump(), loop);
    self.bind(exhausted, self.label());
    return match;
}

const int RE_CALL_DATA = 0;
const int RE_CALL_LEN = 1;
const int RE_CALL_START = 2;
const int RE_CALL_CAPS = 3;
const int RE_CALL_INTERRUPT = 4;

// The offset of a ReCall field on this build.
fn long re_call_offset(int field) {
    re_native::ReCall* k = (re_native::ReCall*)(usz)4096;
    switch (field) {
        case RE_CALL_DATA: return (char*)&k.data - (char*)k;
        case RE_CALL_LEN: return (char*)&k.len - (char*)k;
        case RE_CALL_START: return (char*)&k.start - (char*)k;
        case RE_CALL_CAPS: return (char*)&k.caps - (char*)k;
        default: return (char*)&k.interrupt - (char*)k;
    }
}

// Where the run state sits in the body's frame, and the frame's size.
fn void ReAsm.frame_layout(&self) {
    self.off_frames = SLOT_EXEC + (long)((re_native::ReExec::size + 7) & ~(usz)7);
    self.off_undo = self.off_frames + (long)re_native::RE_SMALL_FRAMES * RE_JIT_FRAME_BYTES;
    self.off_regs = self.off_undo + (long)re_native::RE_SMALL_SLOTS * re_native::ReSlot::size;
    self.locals = (int)(self.off_regs + ((long)self.prog.register_count * 4 + 7) / 8 * 8);
}

// A wide unicode start inside a surrogate pair backs up to the pair's first
// unit, so a sticky match never begins mid-character.
fn void ReAsm.emit_pair_start(&self) {
    void* first = self.cmp(jit::SLJIT_EQUAL, self.s_pos, 0, jit::SLJIT_IMM, 0);
    void* end = self.cmp(jit::SLJIT_GREATER_EQUAL, self.s_pos, 0, self.s_len, 0);
    self.op2(jit::SLJIT_SHL, self.t1, 0, self.s_pos, 0, jit::SLJIT_IMM, 1);
    self.op2(jit::SLJIT_ADD, self.t1, 0, self.t1, 0, self.s_data, 0);
    self.mov_u16(self.t0, 0, jit::SLJIT_MEM | self.t1, 0);
    self.op2(jit::SLJIT_AND, self.t0, 0, self.t0, 0, jit::SLJIT_IMM, 0xFC00);
    void* not_low = self.cmp(jit::SLJIT_NOT_EQUAL, self.t0, 0, jit::SLJIT_IMM, 0xDC00);
    self.mov_u16(self.t0, 0, jit::SLJIT_MEM | self.t1, -2);
    self.op2(jit::SLJIT_AND, self.t0, 0, self.t0, 0, jit::SLJIT_IMM, 0xFC00);
    void* not_high = self.cmp(jit::SLJIT_NOT_EQUAL, self.t0, 0, jit::SLJIT_IMM, 0xD800);
    self.op2(jit::SLJIT_SUB, self.s_pos, 0, self.s_pos, 0, jit::SLJIT_IMM, 1);
    void* done = self.label();
    foreach (j : (void*[4]){ first, end, not_low, not_high }) self.bind(j, done);
}

// The run state in the body's frame, once the literal checks have passed: the
// subject, the captures and interrupt from the ReCall in s_n, and empty stacks
// over the frame's buffers. s_e addresses it from here on.
fn void ReAsm.emit_exec_setup(&self) {
    re_native::ReExec* e = (re_native::ReExec*)(usz)4096;
    long prog = (char*)&e.prog - (char*)e;
    long wide = (char*)&e.in.wide - (char*)e;
    long unicode = (char*)&e.in.unicode - (char*)e;
    long interrupt = (char*)&e.interrupt - (char*)e;
    jit::sljit_get_local_base(self.c, self.s_e, 0, SLOT_EXEC);
    self.mov(self.t0, 0, jit::SLJIT_MEM | self.s_n, re_call_offset(RE_CALL_CAPS));
    self.mov(jit::SLJIT_MEM | self.s_e, self.lay.capture, self.t0, 0);
    self.mov(self.t0, 0, jit::SLJIT_MEM | self.s_n, re_call_offset(RE_CALL_INTERRUPT));
    self.mov(jit::SLJIT_MEM | self.s_e, interrupt, self.t0, 0);
    self.mov(jit::SLJIT_MEM | self.s_e, prog, jit::SLJIT_IMM, (long)(usz)self.prog);
    self.mov(jit::SLJIT_MEM | self.s_e, self.lay.in_data, self.s_data, 0);
    self.store_u32(self.s_e, self.lay.in_len, self.s_len);
    jit::sljit_emit_op1(self.c, jit::SLJIT_MOV_U8, jit::SLJIT_MEM | self.s_e, wide, jit::SLJIT_IMM, self.wide ? 1 : 0);
    jit::sljit_emit_op1(self.c, jit::SLJIT_MOV_U8, jit::SLJIT_MEM | self.s_e, unicode, jit::SLJIT_IMM, self.unicode ? 1 : 0);
    jit::sljit_get_local_base(self.c, self.t0, 0, self.off_frames);
    self.mov(jit::SLJIT_MEM | self.s_e, self.lay.frames, self.t0, 0);
    jit::sljit_get_local_base(self.c, self.t0, 0, self.off_undo);
    self.mov(jit::SLJIT_MEM | self.s_e, self.lay.undo, self.t0, 0);
    jit::sljit_get_local_base(self.c, self.t0, 0, self.off_regs);
    self.mov(jit::SLJIT_MEM | self.s_e, self.lay.regs, self.t0, 0);
    self.mov(self.t0, 0, jit::SLJIT_IMM, 0);
    self.mov(jit::SLJIT_MEM | self.s_e, self.lay.heap_frames, self.t0, 0);
    self.mov(jit::SLJIT_MEM | self.s_e, self.lay.heap_undo, self.t0, 0);
    self.store_u32(self.s_e, self.lay.depth, self.t0);
    self.store_u32(self.s_e, self.lay.undo_len, self.t0);
    self.mov(self.t0, 0, jit::SLJIT_IMM, (long)re_native::RE_SMALL_FRAMES);
    self.store_u32(self.s_e, self.lay.frame_cap, self.t0);
    self.mov(self.t0, 0, jit::SLJIT_IMM, (long)re_native::RE_SMALL_SLOTS);
    self.store_u32(self.s_e, self.lay.undo_cap, self.t0);
    self.exec_ready = true;
}

// Emit one subject form's body and generate its code. Null when SLJIT refuses
// to generate.
fn void* re_jit_emit(re_native::ReNative* n, ReJitData* data, bool wide) {
    void* c = jit::sljit_create_compiler(null);
    if (c == null) return null;
    defer jit::sljit_free_compiler(c);
    ReAsm a;
    a.c = c;
    a.prog = &n.prog;
    a.data = data;
    a.wide = wide;
    a.unicode = n.prog.unicode();
    a.scanning = n.scanning && n.has_first_set;
    a.first_pc = a.scanning ? n.body_pc : 0;
    a.s_e = jit::reg_s(0);
    a.s_pos = jit::reg_s(1);
    a.s_data = jit::reg_s(2);
    a.s_len = jit::reg_s(3);
    a.s_polls = jit::reg_s(4);
    a.s_n = jit::reg_s(5);
    a.native = n;
    a.t0 = jit::reg_r(0);
    a.t1 = jit::reg_r(1);
    a.t2 = jit::reg_r(2);
    a.t3 = jit::reg_r(3);
    a.t4 = jit::reg_r(4);
    a.lay = re_layout();
    a.labels = mem::new_array(void*, (sz)n.prog.insns.len);
    defer mem::free(a.labels);
    a.fixes = mem::new_array(ReJitFix, (sz)n.prog.insns.len * 16 + 64);
    defer mem::free(a.fixes);
    a.fix_len = 0;
    a.attempt = null;
    a.backtrack = null;
    a.exhausted = null;
    a.sink = {};
    a.sink_len = 0;
    a.stubs = mem::new_array(ReJitStub, (sz)n.prog.insns.len);
    defer mem::free(a.stubs);
    a.stub_len = 0;

    // The ReCall arrives in S0; the subject and the start are read from it.
    a.frame_layout();
    jit::sljit_emit_enter(c, 0, jit::SLJIT_ARGS1WW, 5, 6, a.locals);
    a.mov(a.s_n, 0, a.s_e, 0);
    a.mov(a.s_data, 0, jit::SLJIT_MEM | a.s_n, re_call_offset(RE_CALL_DATA));
    a.mov_u32(a.s_len, 0, jit::SLJIT_MEM | a.s_n, re_call_offset(RE_CALL_LEN));
    a.mov_u32(a.s_pos, 0, jit::SLJIT_MEM | a.s_n, re_call_offset(RE_CALL_START));
    if (wide && a.unicode) a.emit_pair_start();
    a.emit_literal();
    a.emit_exec_setup();
    a.mov(a.s_polls, 0, jit::SLJIT_IMM, re_native::RE_POLL_INTERVAL);
    if (a.scanning) {
        a.emit_scan();
    } else {
        a.go(0, FIX_ATTEMPT);
    }
    // Every block a branch lands on starts its own code; a run may only cover
    // instructions nothing jumps into.
    bool[] target = mem::new_array(bool, (sz)n.prog.insns.len);
    defer mem::free(target);
    foreach (insn : n.prog.insns) {
        if (insn.op == ReOp.GOTO || insn.op == ReOp.SPLIT_GOTO_FIRST
            || insn.op == ReOp.SPLIT_NEXT_FIRST || insn.op == ReOp.LOOP
            || insn.op == ReOp.LOOP_SPLIT_GOTO_FIRST || insn.op == ReOp.LOOP_SPLIT_NEXT_FIRST
            || insn.op == ReOp.LOOP_CHECK_ADV_SPLIT_GOTO_FIRST
            || insn.op == ReOp.LOOP_CHECK_ADV_SPLIT_NEXT_FIRST || insn.op == ReOp.STAR) {
            target[insn.target] = true;
            if (insn.op == ReOp.STAR) target[insn.after] = true;
        }
    }
    a.lead_star = a.scanning && !wide ? re_jit_lead_star(&n.prog, a.first_pc, target) : re_native::RE_NONE;
    for (uint pc = a.first_pc; pc < n.prog.insns.len;) {
        a.labels[pc] = a.label();
        uint writes = a.write_length(pc, target);
        uint run = a.run_length(pc, target);
        if (writes > 1) {
            a.emit_writes(pc, writes);
            a.next(pc + writes - 1);
            pc += writes;
        } else if (run > 1) {
            a.emit_char_run(pc, run);
            a.next(pc + run - 1);
            pc += run;
        } else {
            a.emit_insn(pc);
            pc++;
        }
    }
    a.attempt = a.label();
    a.emit_attempt();
    a.backtrack = a.label();
    a.emit_backtrack();
    a.exhausted = a.label();
    a.emit_exhausted();
    foreach (fix : a.fixes[..a.fix_len]) {
        void* label;
        switch (fix.kind) {
            case FIX_INSN: label = a.labels[fix.target];
            case FIX_ATTEMPT: label = a.attempt;
            case FIX_BACKTRACK: label = a.backtrack;
            case FIX_EXHAUSTED: label = a.exhausted;
            case FIX_STUB: label = a.stubs[fix.target].label;
            default: label = a.exhausted;
        }
        jit::sljit_set_label(fix.jump, label);
    }
    void* code = jit::sljit_generate_code(c, 0, null);
    if (code != null && print_code_map) {
        usz end = (usz)code + jit::sljit_shim_code_size(c);
        io::eprintfn("map re#%d%s n%d %x %x %x %x", bodies_compiled, wide ? "w" : "", n.prog.insns.len, (usz)code, end, end, end);
        if (print_code_bytes) {
            DString out;
            out.init(mem, 256);
            defer out.free();
            out.appendf("ocode re#%d%s %x ", bodies_compiled, wide ? "w" : "", (usz)code);
            foreach (b : ((char*)code)[:end - (usz)code]) out.appendf("%02x", b);
            io::eprintn(out.str_view());
        }
        bodies_compiled++;
    }
    return code;
}

// The greedy run at the start of every attempt from `pc` that nothing jumps back into
// (ReAsm.lead_star), in a program with no back reference; else RE_NONE.
fn uint re_jit_lead_star(re_native::ReProgram* prog, uint pc, bool[] target) {
    foreach (insn : prog.insns) {
        switch (insn.op) {
            case ReOp.BACK_REFERENCE: case ReOp.BACK_REFERENCE_I:
            case ReOp.BACKWARD_BACK_REFERENCE: case ReOp.BACKWARD_BACK_REFERENCE_I:
                return re_native::RE_NONE;
            default:
        }
    }
    // The position loop enters the body at its first instruction.
    for (uint first = pc; pc < prog.insns.len && (pc == first || !target[pc]); pc++) {
        ReOp op = prog.insns[pc].op;
        if (op == ReOp.STAR) return pc;
        if (op != ReOp.SAVE_START && op != ReOp.SAVE_END) break;
    }
    return re_native::RE_NONE;
}

// ---------------------------------------------------------------------------
// Compiling a program
// ---------------------------------------------------------------------------

fn bool re_jit_class_op(ReOp op) @inline {
    return op == ReOp.RANGE || op == ReOp.RANGE_I
        || op == ReOp.RANGE32 || op == ReOp.RANGE32_I;
}

// Whether the emitter models this instruction. The rest of the walk's set, the
// branches that need a backtracking stack and the counted repeats, is left to
// the walk.
fn bool re_jit_op_supported(ReOp op) {
    switch (op) {
        case ReOp.CHAR: case ReOp.CHAR_I: case ReOp.CHAR32:
        case ReOp.CHAR32_I: case ReOp.DOT: case ReOp.ANY:
        case ReOp.SPACE: case ReOp.NOT_SPACE: case ReOp.LINE_START:
        case ReOp.LINE_START_M: case ReOp.LINE_END: case ReOp.LINE_END_M:
        case ReOp.GOTO: case ReOp.MATCH: case ReOp.SAVE_START:
        case ReOp.SAVE_END: case ReOp.SAVE_RESET: case ReOp.WORD_BOUNDARY:
        case ReOp.WORD_BOUNDARY_I: case ReOp.NOT_WORD_BOUNDARY:
        case ReOp.NOT_WORD_BOUNDARY_I: case ReOp.RANGE: case ReOp.RANGE_I:
        case ReOp.RANGE32: case ReOp.RANGE32_I: case ReOp.SPLIT_GOTO_FIRST:
        case ReOp.SPLIT_NEXT_FIRST: case ReOp.STAR: case ReOp.SET_I32:
        case ReOp.SET_CHAR_POS: case ReOp.CHECK_ADVANCE: case ReOp.PREV: case ReOp.LOOP:
        case ReOp.LOOP_SPLIT_GOTO_FIRST: case ReOp.LOOP_SPLIT_NEXT_FIRST:
        case ReOp.LOOP_CHECK_ADV_SPLIT_GOTO_FIRST: case ReOp.LOOP_CHECK_ADV_SPLIT_NEXT_FIRST:
            return true;
        default:
            return false;
    }
}

// Whether the whole program is one the emitter can turn into blocks: every
// instruction modelled, every branch inside the emitted range, and the size
// inside the bound.
fn bool re_jit_program_ok(re_native::ReNative* n, uint first_pc) {
    if (n.prog.insns.len == 0 || n.prog.insns.len > RE_JIT_MAX_INSNS) return false;
    if (first_pc >= n.prog.insns.len || n.prog.register_count > RE_JIT_MAX_REGS) return false;
    // The position loop stays code: the attempt loop performs it with the
    // first-unit filter, so its three instructions are outside the body.
    for (uint i = first_pc; i < n.prog.insns.len; i++) {
        re_native::ReInsn* insn = &n.prog.insns[i];
        if (!re_jit_op_supported(insn.op)) return false;
        bool branches = insn.op == ReOp.GOTO || insn.op == ReOp.SPLIT_GOTO_FIRST
            || insn.op == ReOp.SPLIT_NEXT_FIRST || insn.op == ReOp.LOOP
            || insn.op == ReOp.LOOP_SPLIT_GOTO_FIRST || insn.op == ReOp.LOOP_SPLIT_NEXT_FIRST
            || insn.op == ReOp.LOOP_CHECK_ADV_SPLIT_GOTO_FIRST
            || insn.op == ReOp.LOOP_CHECK_ADV_SPLIT_NEXT_FIRST;
        if (branches && insn.target < first_pc) return false;
        // A split's fall-through, and the instruction a greedy run continues at,
        // have to exist: both are emitted as a jump.
        if (insn.op == ReOp.SPLIT_GOTO_FIRST || insn.op == ReOp.SPLIT_NEXT_FIRST
            || insn.op == ReOp.LOOP_SPLIT_GOTO_FIRST || insn.op == ReOp.LOOP_SPLIT_NEXT_FIRST
            || insn.op == ReOp.LOOP_CHECK_ADV_SPLIT_GOTO_FIRST
            || insn.op == ReOp.LOOP_CHECK_ADV_SPLIT_NEXT_FIRST) {
            if ((usz)i + 1 >= n.prog.insns.len) return false;
        }
        if (insn.op == ReOp.STAR) {
            if (insn.target < first_pc) return false;
            if (insn.after >= n.prog.insns.len) return false;
        }
    }
    return true;
}

// The bitmaps and class descriptors the compiled code addresses.
fn ReJitData* re_jit_data_build(re_native::ReNative* n) {
    re_native::ReProgram* prog = &n.prog;
    ReJitData* data = mem::new(ReJitData);
    for (uint unit = 0; unit < 256; unit++) {
        if (re_bindings::re_is_space(unit)) data.space_units[unit] = 1;
        if (re_bindings::re_is_word_byte(unit)) data.word_units[unit] = 1;
        if (n.has_first_set && re_native::re_fs_test(n, unit)) data.first_units[unit] = 1;
    }
    uint classes = 0;
    foreach (insn : prog.insns) if (re_jit_class_op(insn.op)) classes++;
    data.classes = mem::new_array(ReJitClass, (sz)classes);
    data.class_at = mem::new_array(uint, prog.insns.len);
    for (uint i = 0; i < prog.insns.len; i++) data.class_at[i] = re_native::RE_NONE;
    uint next = 0;
    foreach (i, insn : prog.insns) {
        if (!re_jit_class_op(insn.op)) continue;
        ReJitClass* cls = &data.classes[next];
        cls.wide = {
            .pairs = &prog.ranges[insn.ranges],
            .count = insn.pair_count,
            .ignore_case = insn.op == ReOp.RANGE_I || insn.op == ReOp.RANGE32_I,
            .unicode = prog.unicode(),
            .unbounded = insn.op == ReOp.RANGE || insn.op == ReOp.RANGE_I,
        };
        for (uint unit = 0; unit < 256; unit++) {
            if (cls.wide.matches(unit)) cls.units[unit] = 1;
        }
        data.class_at[i] = next;
        next++;
    }
    return data;
}

fn void re_jit_data_free(ReJitData* data) {
    if (data == null) return;
    mem::free(data.classes);
    mem::free(data.class_at);
    mem::free(data);
}

// Compile both subject forms of a program into `n`, which owns them until it is
// freed. Both are left null for a program the emitter declines.
fn void re_jit_compile(re_native::ReNative* n) {
    n.code_narrow = null;
    n.code_wide = null;
    n.jit_data = null;
    uint first_pc = n.scanning && n.has_first_set ? n.body_pc : 0;
    if (!re_jit_program_ok(n, first_pc)) return;
    ReJitData* data = re_jit_data_build(n);
    n.code_narrow = re_jit_emit(n, data, false);
    n.code_wide = re_jit_emit(n, data, true);
    if (n.code_narrow == null && n.code_wide == null) {
        re_jit_data_free(data);
        return;
    }
    n.jit_data = data;
}

// Release what re_jit_compile produced.
fn void re_jit_free(re_native::ReNative* n) {
    if (n.code_narrow != null) jit::sljit_free_code(n.code_narrow, null);
    if (n.code_wide != null) jit::sljit_free_code(n.code_wide, null);
    re_jit_data_free((ReJitData*)n.jit_data);
    n.code_narrow = null;
    n.code_wide = null;
    n.jit_data = null;
}
