// The regexp matcher's native tier: the decoded program, emitted as machine code.
//
// The walk in exec.c3 re-reads an instruction, its operands and its branch on
// every step and returns to a dispatch loop after each one. Here the same
// semantics become a graph of blocks joined by direct jumps: the opcode is
// chosen once at compile time, a class is folded into a membership bitmap, and
// a failure jumps to the shared attempt-failed path instead of a switch arm.
// Semantics are unchanged, and the walk stays the reference: a program this
// compiler does not model keeps the decoded program on the walk, and a machine
// it cannot emit for keeps it on libregexp.
//
// Two variants are compiled per program, one per subject form. A Latin-1
// subject is one byte per code unit and never holds a surrogate pair, so the
// narrow variant has none of the combining to do; the wide variant carries it.
// The form is chosen per call, so both live in the same code object.
module boomkat::re_jit @feat(!NO_REGEXP, SLJIT);

import boomkat::jit;
import boomkat::re_bindings;
import boomkat::re_native;
import std::core::mem;

// A compiled body: the program and the run, over the position to start at.
alias ReJitFn = fn int(re_native::ReNative* n, re_native::ReExec* e, usz start);

// A compiled body is refused beyond this many instructions, which bounds the
// code one pattern can hold: the emitter expands each instruction to a block of
// tens of bytes.
const uint RE_JIT_MAX_INSNS = 2048;

// Bitmap width: one bit per Latin-1 code unit.
const int RE_JIT_BITS = 32;

// One character class, in both forms the compiled code tests it with. The
// bitmap answers a Latin-1 unit, where a unit is a code point, so the whole
// membership test is one lookup; the descriptor answers a wide subject's code
// point above that range with the same test the walk performs.
//
// The bitmap is keyed by subject unit rather than by canonical code point, so
// the ignore-case form needs no canonicalization in generated code: the
// pattern's own canonicalization is folded in when the table is built.
struct ReJitClass {
    char[RE_JIT_BITS] bits;
    re_native::ReClass wide;
}

// Per-program constants the compiled code addresses by immediate: the two
// predicate tables the assertions read, and one descriptor per class
// instruction. Owned by the program and freed with it.
struct ReJitData {
    char[RE_JIT_BITS] space_bits;
    char[RE_JIT_BITS] word_bits;
    ReJitClass[] classes;
    // Class index per instruction, RE_NONE for the instructions that are not
    // class tests.
    uint[] class_at;
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
    int s_e;      // the ReExec being run
    int s_pos;    // the subject position
    int s_data;   // the subject base
    int s_len;    // the subject length in code units
    int s_polls;  // dispatches left before the interrupt is polled
    int s_n;      // the program's ReNative
    int t0;
    int t1;
    int t2;
    int t3;
    int t4;
    void*[] labels;
    ReJitFix[] fixes;
    uint fix_len;
    void* attempt;
    void* exhausted;
}

// ---------------------------------------------------------------------------
// Helpers called from generated code
// ---------------------------------------------------------------------------

fn void re_jit_bit(char* bits, uint unit) @inline {
    bits[unit >> 3] = bits[unit >> 3] | (char)(1 << (unit & 7));
}

// Record a capture or register write, as the walk does, so a failed attempt can
// restore what it overwrote.
fn long re_jit_write(re_native::ReExec* e, long slot, long value) {
    e.write((uint)slot, (uint)value);
    return 0;
}

// Start an attempt from a clean state: every value the last attempt wrote is
// restored, which is what the walk's backtrack does when no frame is left.
fn long re_jit_reset(re_native::ReExec* e) {
    e.unwind(0);
    e.depth = 0;
    return 0;
}

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

fn void ReAsm.op2(&self, int op, int dst, long dstw, int a, long aw, int b, long bw) @inline {
    jit::sljit_emit_op2(self.c, op, dst, dstw, a, aw, b, bw);
}

fn void* ReAsm.cmp(&self, int cond, int a, long aw, int b, long bw) @inline {
    return jit::sljit_emit_cmp(self.c, cond, a, aw, b, bw);
}

fn void* ReAsm.label(&self) @inline => jit::sljit_emit_label(self.c);

fn void* ReAsm.jump(&self) @inline => jit::sljit_emit_jump(self.c, jit::SLJIT_JUMP);

fn void ReAsm.bind(&self, void* jump, void* label) @inline => jit::sljit_set_label(jump, label);

// Leave the generated function with `value`.
fn void ReAsm.leave(&self, int value) @inline {
    jit::sljit_emit_return(self.c, jit::SLJIT_MOV, jit::SLJIT_IMM, (long)value);
}

// A jump to an instruction block, a helper label, or the failure path.
fn void ReAsm.go(&self, uint target, int kind) {
    void* jump = self.jump();
    if (kind == FIX_INSN && target < self.labels.len && self.labels[target] != null) {
        self.bind(jump, self.labels[target]);
        return;
    }
    self.fixes[self.fix_len] = { .jump = jump, .target = target, .kind = kind };
    self.fix_len++;
}

// Jump to the attempt-failed path.
fn void ReAsm.fail(&self) @inline => self.go(0, FIX_EXHAUSTED);

fn void ReAsm.fail_if(&self, void* jump) {
    self.fixes[self.fix_len] = { .jump = jump, .target = 0, .kind = FIX_EXHAUSTED };
    self.fix_len++;
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

// The code unit at *pos into `dst`, leaving the position past it; the code
// point when the subject is wide and the pattern unicode, so a surrogate pair
// reads as one code point.
fn void ReAsm.emit_read(&self) {
    int t0 = self.t0;
    int t1 = self.t1;
    self.fail_if(self.cmp(jit::SLJIT_GREATER_EQUAL, self.s_pos, 0, self.s_len, 0));
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

// The unit at the position in `at` into `dst`, as a code unit: the wide form's
// surrogate combining belongs to emit_read, not to these one-unit tests.
fn void ReAsm.emit_unit(&self, int dst, int at) @inline {
    if (self.wide) {
        self.mov_u16(dst, 0, jit::mem_index(self.s_data, at), 1);
    } else {
        self.mov_u8(dst, 0, jit::mem_index(self.s_data, at), 0);
    }
}

// Bit `unit` of the bitmap at `bits` into `out`, as 0 or 1. The unit must be
// below 256, which every caller establishes; t1 and t2 are scratch.
fn void ReAsm.emit_bit(&self, int unit, usz bits, int out) {
    self.mov(self.t1, 0, jit::SLJIT_IMM, (long)bits);
    self.op2(jit::SLJIT_LSHR, self.t2, 0, unit, 0, jit::SLJIT_IMM, 3);
    self.mov_u8(out, 0, jit::mem_index(self.t1, self.t2), 0);
    self.op2(jit::SLJIT_AND, self.t2, 0, unit, 0, jit::SLJIT_IMM, 7);
    self.op2(jit::SLJIT_MLSHR, out, 0, out, 0, self.t2, 0);
    self.op2(jit::SLJIT_AND, out, 0, out, 0, jit::SLJIT_IMM, 1);
}

// Fail unless `unit` is in the class at `index` in the program's data.
fn void ReAsm.emit_class(&self, int unit, uint index) {
    ReJitClass* cls = &self.data.classes[index];
    if (!self.wide) {
        self.emit_bit(unit, (usz)&cls.bits[0], self.t3);
        self.fail_if_equal(self.t3, 0);
        return;
    }
    void* above = self.cmp(jit::SLJIT_GREATER_EQUAL, unit, 0, jit::SLJIT_IMM, 256);
    self.emit_bit(unit, (usz)&cls.bits[0], self.t3);
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
        self.emit_bit(unit, (usz)&self.data.space_bits[0], self.t3);
        if (invert) {
            self.fail_if_not(self.t3, 0);
        } else {
            self.fail_if_equal(self.t3, 0);
        }
        return;
    }
    void* above = self.cmp(jit::SLJIT_GREATER_EQUAL, unit, 0, jit::SLJIT_IMM, 256);
    self.emit_bit(unit, (usz)&self.data.space_bits[0], self.t3);
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

// Whether the unit in `unit` is a word character, into `out` as 0 or 1.
fn void ReAsm.emit_word_unit(&self, int unit, int out, bool ignore_case) {
    if (!self.wide) {
        self.emit_bit(unit, (usz)&self.data.word_bits[0], out);
        return;
    }
    void* above = self.cmp(jit::SLJIT_GREATER_EQUAL, unit, 0, jit::SLJIT_IMM, 256);
    self.emit_bit(unit, (usz)&self.data.word_bits[0], out);
    void* skip = self.jump();
    self.bind(above, self.label());
    // Above Latin-1 only the two code points that case-fold to an ASCII word
    // character count, and only in the ignore-case form.
    self.mov(out, 0, jit::SLJIT_IMM, 0);
    if (ignore_case) {
        void* long_s = self.cmp(jit::SLJIT_EQUAL, unit, 0, jit::SLJIT_IMM, 0x017F);
        void* kelvin = self.cmp(jit::SLJIT_EQUAL, unit, 0, jit::SLJIT_IMM, 0x212A);
        self.bind(long_s, self.label());
        self.bind(kelvin, self.label());
        self.mov(out, 0, jit::SLJIT_IMM, 1);
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
    int after = self.t3;
    int before = self.t4;
    self.mov(after, 0, jit::SLJIT_IMM, 0);
    void* after_done = self.cmp(jit::SLJIT_GREATER_EQUAL, self.s_pos, 0, self.s_len, 0);
    self.emit_unit(self.t0, self.s_pos);
    self.emit_word_unit(self.t0, after, ignore_case);
    self.bind(after_done, self.label());
    self.mov(before, 0, jit::SLJIT_IMM, 0);
    void* before_done = self.cmp(jit::SLJIT_EQUAL, self.s_pos, 0, jit::SLJIT_IMM, 0);
    self.op2(jit::SLJIT_SUB, self.t1, 0, self.s_pos, 0, jit::SLJIT_IMM, 1);
    self.emit_unit(self.t0, self.t1);
    self.emit_word_unit(self.t0, before, ignore_case);
    self.bind(before_done, self.label());
    if (invert) {
        self.fail_if(self.cmp(jit::SLJIT_NOT_EQUAL, before, 0, after, 0));
    } else {
        self.fail_if(self.cmp(jit::SLJIT_EQUAL, before, 0, after, 0));
    }
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

// Write the capture slot or register `slot` from the current position.
fn void ReAsm.emit_save(&self, uint slot) {
    self.mov(self.t0, 0, self.s_e, 0);
    self.mov(self.t1, 0, jit::SLJIT_IMM, (long)slot);
    self.mov_u32(self.t2, 0, self.s_pos, 0);
    jit::sljit_emit_icall(self.c, jit::SLJIT_CALL, jit::SLJIT_ARGS3WWW,
                     jit::SLJIT_IMM, (long)(usz)&re_jit_write);
}

// Write the capture slot or register `slot` from a constant.
fn void ReAsm.emit_value(&self, uint slot, uint value) {
    self.mov(self.t0, 0, self.s_e, 0);
    self.mov(self.t1, 0, jit::SLJIT_IMM, (long)slot);
    self.mov(self.t2, 0, jit::SLJIT_IMM, (long)value);
    jit::sljit_emit_icall(self.c, jit::SLJIT_CALL, jit::SLJIT_ARGS3WWW,
                     jit::SLJIT_IMM, (long)(usz)&re_jit_write);
}

// One instruction. Its label is emitted by the caller.
fn void ReAsm.emit_insn(&self, uint pc) {
    re_native::ReInsn* insn = &self.prog.insns[pc];
    switch (insn.op) {
        case ReOp.CHAR: case ReOp.CHAR32:
            self.emit_read();
            self.fail_if_not(self.t0, insn.a);
        case ReOp.CHAR_I: case ReOp.CHAR32_I:
            self.emit_read();
            self.emit_canonicalize();
            self.fail_if_not(self.t0, insn.a);
        case ReOp.DOT:
            self.emit_read();
            self.fail_if_equal(self.t0, '\n');
            self.fail_if_equal(self.t0, '\r');
            if (self.wide) {
                self.fail_if_equal(self.t0, 0x2028);
                self.fail_if_equal(self.t0, 0x2029);
            }
        case ReOp.ANY:
            self.emit_read();
        case ReOp.SPACE:
            self.emit_read();
            self.emit_space(self.t0, false);
        case ReOp.NOT_SPACE:
            self.emit_read();
            self.emit_space(self.t0, true);
        case ReOp.RANGE: case ReOp.RANGE_I:
        case ReOp.RANGE32: case ReOp.RANGE32_I:
            self.emit_read();
            self.emit_class(self.t0, self.data.class_at[pc]);
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
        case ReOp.SAVE_START:
            self.emit_save((uint)insn.a * 2);
        case ReOp.SAVE_END:
            self.emit_save((uint)insn.a * 2 + 1);
        case ReOp.SAVE_RESET:
            for (uint group = (uint)insn.a; group <= (uint)insn.b; group++) {
                self.emit_value(group * 2, re_native::RE_UNSET);
                self.emit_value(group * 2 + 1, re_native::RE_UNSET);
            }
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

// The attempt loop: poll the interrupt, reset the state a failed attempt left
// behind, remember where this attempt starts, and run the body.
fn void ReAsm.emit_attempt(&self) {
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
    self.mov(self.t0, 0, self.s_e, 0);
    jit::sljit_emit_icall(self.c, jit::SLJIT_CALL, jit::SLJIT_ARGS1WW,
                     jit::SLJIT_IMM, (long)(usz)&re_jit_reset);
    self.mov(jit::SLJIT_MEM | jit::reg_sp(), 0, self.s_pos, 0);
    self.go(self.first_pc, FIX_INSN);
}

// Nothing left to resume: another candidate, or no match.
fn void ReAsm.emit_exhausted(&self) {
    if (!self.scanning) {
        self.leave(re_native::RE_NO_MATCH);
        return;
    }
    self.mov(self.t0, 0, self.s_n, 0);
    self.mov(self.t1, 0, self.s_e, 0);
    self.mov_u32(self.t2, 0, jit::SLJIT_MEM | jit::reg_sp(), 0);
    jit::sljit_emit_icall(self.c, jit::SLJIT_CALL, jit::SLJIT_ARGS3WWW_R,
                     jit::SLJIT_IMM, (long)(usz)&re_jit_scan_next);
    void* none = self.cmp(jit::SLJIT_EQUAL, self.t0, 0, jit::SLJIT_IMM, -1);
    self.mov(self.s_pos, 0, self.t0, 0);
    self.go(0, FIX_ATTEMPT);
    self.bind(none, self.label());
    self.leave(re_native::RE_NO_MATCH);
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
    a.t0 = jit::reg_r(0);
    a.t1 = jit::reg_r(1);
    a.t2 = jit::reg_r(2);
    a.t3 = jit::reg_r(3);
    a.t4 = jit::reg_r(4);
    a.labels = mem::new_array(void*, (sz)n.prog.insns.len);
    defer mem::free(a.labels);
    a.fixes = mem::new_array(ReJitFix, (sz)n.prog.insns.len * 4 + 32);
    defer mem::free(a.fixes);
    a.fix_len = 0;
    a.attempt = null;
    a.exhausted = null;

    // The arguments arrive in S0, S1 and S2: the program, the run being
    // resumed, and the position to start at.
    jit::sljit_emit_enter(c, 0, jit::SLJIT_ARGS3WWW, 5, 6, 16);
    a.mov(a.t0, 0, a.s_e, 0);
    a.mov(a.t1, 0, a.s_pos, 0);
    a.mov(a.s_pos, 0, a.s_data, 0);
    a.mov(a.s_e, 0, a.t1, 0);
    a.mov(a.s_n, 0, a.t0, 0);
    // The subject is reached through the run, at the offsets the struct has on
    // this build.
    re_native::ReExec* el = (re_native::ReExec*)(usz)4096;
    a.mov(a.s_data, 0, jit::SLJIT_MEM | a.s_e, (char*)&el.in.data - (char*)el);
    a.mov_u32(a.s_len, 0, jit::SLJIT_MEM | a.s_e, (char*)&el.in.len - (char*)el);
    a.mov(a.s_polls, 0, jit::SLJIT_IMM, re_native::RE_POLL_INTERVAL);
    if (a.scanning) {
        a.mov(a.t0, 0, a.s_n, 0);
        a.mov(a.t1, 0, a.s_e, 0);
        a.mov(a.t2, 0, a.s_pos, 0);
        jit::sljit_emit_icall(c, jit::SLJIT_CALL, jit::SLJIT_ARGS3WWW_R,
                         jit::SLJIT_IMM, (long)(usz)&re_jit_scan_first);
        void* none = a.cmp(jit::SLJIT_EQUAL, a.t0, 0, jit::SLJIT_IMM, -1);
        a.mov(a.s_pos, 0, a.t0, 0);
        a.go(0, FIX_ATTEMPT);
        a.bind(none, a.label());
        a.leave(re_native::RE_NO_MATCH);
    } else {
        a.go(0, FIX_ATTEMPT);
    }
    for (uint pc = a.first_pc; pc < a.prog.insns.len; pc++) {
        a.labels[pc] = a.label();
        a.emit_insn(pc);
    }
    a.attempt = a.label();
    a.emit_attempt();
    a.exhausted = a.label();
    a.emit_exhausted();
    foreach (fix : a.fixes[..a.fix_len]) {
        void* label = fix.kind == FIX_INSN ? a.labels[fix.target]
            : (fix.kind == FIX_ATTEMPT ? a.attempt : a.exhausted);
        jit::sljit_set_label(fix.jump, label);
    }
    return jit::sljit_generate_code(c, 0, null);
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
        case ReOp.RANGE32: case ReOp.RANGE32_I:
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
    if (first_pc >= n.prog.insns.len) return false;
    // The position loop stays code: the attempt loop performs it with the
    // first-unit filter, so its three instructions are outside the body.
    foreach (insn : n.prog.insns[first_pc..]) {
        if (!re_jit_op_supported(insn.op)) return false;
        if (insn.op == ReOp.GOTO && insn.target < first_pc) return false;
    }
    return true;
}

// The bitmaps and class descriptors the compiled code addresses.
fn ReJitData* re_jit_data_build(re_native::ReProgram* prog) {
    ReJitData* data = mem::new(ReJitData);
    for (uint unit = 0; unit < 256; unit++) {
        if (re_bindings::re_is_space(unit)) re_jit_bit(&data.space_bits, unit);
        if (re_bindings::re_is_word_byte(unit)) re_jit_bit(&data.word_bits, unit);
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
            if (cls.wide.matches(unit)) re_jit_bit(&cls.bits, unit);
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
    ReJitData* data = re_jit_data_build(&n.prog);
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

// Run the compiled body for the subject's form. False sends the run back to the
// walk, which is where a program the emitter declined or could not generate for
// stays.
fn bool re_jit_run(re_native::ReNative* n, re_native::ReExec* e, uint start,
                   re_native::ReOutcome* out, int* status) {
    void* code = e.in.wide ? n.code_wide : n.code_narrow;
    if (code == null) return false;
    int ret = ((ReJitFn)code)(n, e, (usz)start);
    if (ret == re_bindings::RE_MATCH) {
        out.start = e.capture[0];
        out.end = e.capture[1];
    }
    *status = ret;
    return true;
}
