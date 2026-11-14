// The native regexp matcher: a backtracking walk of the decoded program.
//
// libregexp runs its bytecode with an interpreter that re-decodes operands on
// every step: class pairs are read as 16-bit fields, branches are relative byte
// offsets, and a capture write records an undo entry on a value stack. The
// decoder (prog.c3) resolves all of that once, and this module walks the result:
// instructions are indexed, targets are indices, class pairs are unpacked, and
// the position walks a subject cursor instead of raw pointers.
//
// Semantics mirror vendor/libregexp/libregexp.c's `lre_exec_backtrack`. The same
// three-valued stack discipline drives it:
//
// - a frame records the instruction to resume, the subject position, and the
//   depth of the undo stack when it was pushed;
// - every capture or register write records the value it replaced, so a failed
//   attempt restores exactly what it overwrote;
// - a failure unwinds the current frame's writes, then resumes the frame below,
//   giving a greedy run one code point back each time it is resumed.
//
// The program is declined, not guessed at: anything the matcher does not model,
// or any program whose save slots or registers fall outside what the header
// declares, leaves the pattern on the interpreter (see `re_native_prepare`).
module boomkat::re_native @feat(!NO_REGEXP);

import std::core::mem;
import libc;
import boomkat::re_bindings;
import boomkat::re_jit;

// A capture slot no save instruction has written.
const uint RE_UNSET = uint::max;

// Dispatch steps between interrupt polls, as libregexp's INTERRUPT_COUNTER_INIT.
const uint RE_POLL_INTERVAL = 10000;

// Return values, matching re_wrapper.h and libregexp.h.
const int RE_MATCH = 1;
const int RE_NO_MATCH = 0;
const int RE_TIMEOUT = -2;
const int RE_ERROR = -1;

// The stack sizes that cover ordinary patterns without touching the heap. A
// match beyond them grows its own buffers.
const uint RE_SMALL_FRAMES = 48;
const uint RE_SMALL_SLOTS = 96;
const uint RE_SMALL_REGS = 16;

// One backtracking state: resume at `resume` with `pos`, after undoing every
// write recorded above `undo`. The walk resumes at an instruction index and a
// compiled body at a code address, so each matcher reads back what it pushed.
struct ReFrame {
    usz resume;
    uint pos;
    uint undo;
    // A greedy run: each resume gives back one code point, and the frame is
    // dropped once the run reaches the minimum it must keep.
    bool star;
}

// A capture or register write, with the value it replaced.
struct ReSlot {
    uint slot;   // capture index, or 2 * capture_count + register index
    uint old;
}

// A native program: the decoded instructions, and what the matcher reads on
// every step.
struct ReNative {
    ReProgram prog;
    // The program opens with the three-instruction position loop (split, any,
    // goto), so candidate start positions can be searched for instead of walked:
    // the loop's body starts here.
    bool scanning;
    uint body_pc;
    // The units that can begin a match, as libregexp computed them for this
    // program. When there is no such filter, the loop runs as code.
    bool has_first_set;
    uint[8] fs_bits;
    bool fs_wide;      // any unit above 255 can begin a match
    int  fs_single;    // the one unit that can begin a match, or -1
    bool fs_at_start;  // an empty match is possible at the start
    bool fs_at_end;    // and at the end
    // The literal re_prefilter checks, which the compiled body checks before
    // its first attempt (re_bindings::re_literal); lit_len is 0 for none.
    char[16] lit;
    uint lit_len;
    uint lit_rare;
    int lit_where;
    bool lit_whole;
    // The program as machine code, one body per subject form, and the bitmaps
    // those bodies address (src/re/jit.c3). All null when the emitter declined
    // the program, which leaves it on the walk.
    void* code_narrow @if($feat(SLJIT));
    void* code_wide @if($feat(SLJIT));
    void* jit_data @if($feat(SLJIT));
}

// The state of one match: the capture and register arrays, and the two stacks
// the walk grows. The subject and the position stay locals of the walk, so they
// live in registers across an instruction.
struct ReExec {
    ReProgram* prog;
    uint* capture;      // 2 * capture_count slots
    uint* regs;         // register_count slots
    ReFrame* frames;
    ReSlot* undo;
    uint frame_cap;
    uint undo_cap;
    uint depth;
    uint undo_len;
    // The heap buffer behind a stack that outgrew its fixed array, else null.
    void* heap_frames;
    void* heap_undo;
    // The subject this run reads, and the interrupt it polls. The walk keeps its
    // own copy of the subject in locals and polls on its own count; the compiled
    // body reads both from here, because neither fits in its registers.
    ReInput in;
    ReInterrupt* interrupt;
}

// The arguments of a compiled body: the subject, the position to start at,
// the capture buffer, which holds 2 * capture_count ints, and the interrupt.
// The body keeps the rest of the run in its own frame.
struct ReCall {
    char* data;
    uint len;
    uint start;
    int* caps;
    ReInterrupt* interrupt;
}

// The capture slots a match ends with, in code-unit positions.
struct ReOutcome {
    uint start;
    uint end;
}

// ---------------------------------------------------------------------------
// Single-character instructions
// ---------------------------------------------------------------------------

// Consume up to `max` code points matched by one single-character instruction,
// advancing *pos. The opcode is switched once so a quantified atom walks the
// subject in a tight loop, as libregexp's lre_run_char_op does; the subject
// fields are arguments so they stay in registers across the iteration. Returns
// how many code points it consumed.
fn uint re_run_chars(ReProgram* prog, char* data, uint len, bool wide, bool unicode,
                     ReInsn* insn, uint* pos, uint max) {
    uint at = *pos;
    uint n = 0;
    switch (insn.op) {
        case CHAR: case CHAR32:
            while (n < max && at < len) {
                uint prev = at;
                uint c = re_code_point_at(data, wide, unicode, len, &at);
                if (c != (uint)insn.a) { at = prev; break; }
                n++;
            }
            break;
        case CHAR_I: case CHAR32_I:
            while (n < max && at < len) {
                uint prev = at;
                uint c = re_code_point_at(data, wide, unicode, len, &at);
                if (re_bindings::re_canonicalize(c, unicode) != (uint)insn.a) { at = prev; break; }
                n++;
            }
            break;
        case DOT:
            while (n < max && at < len) {
                uint prev = at;
                uint c = re_code_point_at(data, wide, unicode, len, &at);
                if (re_is_line_terminator(c)) { at = prev; break; }
                n++;
            }
            break;
        case ANY:
            while (n < max && at < len) {
                re_code_point_at(data, wide, unicode, len, &at);
                n++;
            }
            break;
        case SPACE:
            while (n < max && at < len) {
                uint prev = at;
                uint c = re_code_point_at(data, wide, unicode, len, &at);
                if (!re_bindings::re_is_space(c)) { at = prev; break; }
                n++;
            }
            break;
        case NOT_SPACE:
            while (n < max && at < len) {
                uint prev = at;
                uint c = re_code_point_at(data, wide, unicode, len, &at);
                if (re_bindings::re_is_space(c)) { at = prev; break; }
                n++;
            }
            break;
        case RANGE: case RANGE_I: case RANGE32: case RANGE32_I:
            ReClass cls;
            cls.pairs = &prog.ranges[insn.ranges];
            cls.count = insn.pair_count;
            cls.ignore_case = insn.op == RANGE_I || insn.op == RANGE32_I;
            cls.unicode = unicode;
            cls.unbounded = insn.op == RANGE || insn.op == RANGE_I;
            if (insn.op == RANGE && !wide && insn.pair_count <= 8) {
                // A Latin-1 class with few pairs is faster scanned than bisected,
                // and a Latin-1 unit is one code point on its own.
                while (n < max && at < len) {
                    uint c = re_unit_at(data, false, len, at);
                    bool hit = false;
                    for (uint k = 0; k < insn.pair_count; k++) {
                        if (c >= prog.ranges[insn.ranges + k * 2]
                            && c <= prog.ranges[insn.ranges + k * 2 + 1]) {
                            hit = true;
                            break;
                        }
                    }
                    if (!hit) break;
                    at++;
                    n++;
                }
            } else {
                while (n < max && at < len) {
                    uint prev = at;
                    uint c = re_code_point_at(data, wide, unicode, len, &at);
                    if (!cls.matches(c)) { at = prev; break; }
                    n++;
                }
            }
            break;
        default:
            break;
    }
    *pos = at;
    return n;
}

// One consuming instruction at `pos`: the position just past the code point it
// matched, or RE_NONE. Kept small and inlined: it is the common path, while a
// greedy run uses the out-of-line loop above so `re_walk` stays compact.
fn uint re_step_at(ReProgram* prog, char* data, uint len, bool wide, bool unicode,
                   ReInsn* insn, uint pos) @inline {
    if (pos >= len) return RE_NONE;
    uint at = pos;
    uint c = re_code_point_at(data, wide, unicode, len, &at);
    switch (insn.op) {
        case CHAR: case CHAR32:
            if (c != (uint)insn.a) return RE_NONE;
        case CHAR_I: case CHAR32_I:
            if (re_bindings::re_canonicalize(c, unicode) != (uint)insn.a) return RE_NONE;
        case DOT:
            if (re_is_line_terminator(c)) return RE_NONE;
        case ANY:
            break;
        case SPACE:
            if (!re_bindings::re_is_space(c)) return RE_NONE;
        case NOT_SPACE:
            if (re_bindings::re_is_space(c)) return RE_NONE;
        case RANGE: case RANGE_I: case RANGE32: case RANGE32_I:
            ReClass cls;
            cls.pairs = &prog.ranges[insn.ranges];
            cls.count = insn.pair_count;
            cls.ignore_case = insn.op == RANGE_I || insn.op == RANGE32_I;
            cls.unicode = unicode;
            cls.unbounded = insn.op == RANGE || insn.op == RANGE_I;
            if (!cls.matches(c)) return RE_NONE;
        default:
            return RE_NONE;
    }
    return at;
}

fn bool re_consumes(ReOp op) @inline {
    switch (op) {
        case CHAR: case CHAR_I: case CHAR32: case CHAR32_I: case DOT: case ANY: case SPACE:
        case NOT_SPACE: case RANGE: case RANGE_I: case RANGE32: case RANGE32_I:
            return true;
        default:
            return false;
    }
}

// ---------------------------------------------------------------------------
// Capture and register writes
// ---------------------------------------------------------------------------

fn uint ReExec.slot_count(&self) @inline => self.prog.capture_count * 2;

// The value of a capture slot or register.
fn uint ReExec.read(&self, uint slot) @inline {
    uint captures = self.slot_count();
    return slot < captures ? self.capture[slot] : self.regs[slot - captures];
}

// Write a capture slot or register, recording what it held so a failed attempt
// can restore it. The value recorded is the one from before the current frame,
// so a slot written many times in one attempt is restored in one step; that is
// the same economy libregexp's SAVE_CAPTURE_CHECK makes, and it matters for the
// captures a quantified group rewrites on every iteration.
fn void ReExec.write(&self, uint slot, uint value) @inline {
    uint captures = self.slot_count();
    uint mark = self.depth == 0 ? 0 : self.frames[self.depth - 1].undo;
    uint seen = self.undo_len;
    while (seen > mark) {
        seen--;
        if (self.undo[seen].slot == slot) break;
    }
    if (seen == mark) {
        self.reserve_slots();
        self.undo[self.undo_len].slot = slot;
        self.undo[self.undo_len].old = slot < captures ? self.capture[slot] : self.regs[slot - captures];
        self.undo_len++;
    }
    if (slot < captures) {
        self.capture[slot] = value;
    } else {
        self.regs[slot - captures] = value;
    }
}

// Restore every write recorded above `mark`.
fn void ReExec.unwind(&self, uint mark) @inline {
    uint captures = self.slot_count();
    while (self.undo_len > mark) {
        self.undo_len--;
        ReSlot* rec = &self.undo[self.undo_len];
        if (rec.slot < captures) {
            self.capture[rec.slot] = rec.old;
        } else {
            self.regs[rec.slot - captures] = rec.old;
        }
    }
}

// Room for `n` more write records.
fn void ReExec.reserve_slots(&self, uint n = 1) @inline {
    if (self.undo_len + n <= self.undo_cap) return;
    uint cap = self.undo_cap * 2;
    while (self.undo_len + n > cap) cap *= 2;
    ReSlot* grew;
    if (self.heap_undo == null) {
        grew = mem::new_array(ReSlot, (sz)cap).ptr;
        for (uint i = 0; i < self.undo_len; i++) grew[i] = self.undo[i];
    } else {
        grew = (ReSlot*)mem::realloc(self.heap_undo, (sz)cap * ReSlot::size);
    }
    self.heap_undo = grew;
    self.undo = grew;
    self.undo_cap = cap;
}

// ---------------------------------------------------------------------------
// Frames
// ---------------------------------------------------------------------------

// Grow the frame stack so that one more depth is available.
fn void ReExec.reserve_frame(&self) {
    if (self.depth < self.frame_cap) return;
    uint cap = self.frame_cap * 2;
    ReFrame* grew;
    if (self.heap_frames == null) {
        grew = mem::new_array(ReFrame, (sz)cap).ptr;
        for (uint i = 0; i < self.depth; i++) grew[i] = self.frames[i];
    } else {
        grew = (ReFrame*)mem::realloc(self.heap_frames, (sz)cap * ReFrame::size);
    }
    self.heap_frames = grew;
    self.frames = grew;
    self.frame_cap = cap;
}

fn void ReExec.push(&self, uint pc, uint pos, bool star) @inline {
    self.reserve_frame();
    self.frames[self.depth].resume = pc;
    self.frames[self.depth].pos = pos;
    self.frames[self.depth].undo = self.undo_len;
    self.frames[self.depth].star = star;
    self.depth++;
}

// Resume the innermost frame after unwinding what the failed attempt wrote.
// False when no frame is left, which is the end of one attempt.
fn bool ReExec.backtrack(&self, uint* pc, uint* pos, ReInput* in) @inline {
    if (self.depth == 0) {
        self.unwind(0);
        return false;
    }
    ReFrame* f = &self.frames[self.depth - 1];
    self.unwind(f.undo);
    if (f.star) {
        ReInsn* star = &self.prog.insns[(uint)f.resume];
        uint min_end = self.read(self.slot_count() + star.reg);
        uint gave_back = f.pos;
        in.prev_code_point(&gave_back);
        if (gave_back <= min_end) {
            // The run is down to what the minimum needs: the frame is spent, and
            // the walk continues after it at that position.
            *pos = min_end;
            self.depth--;
        } else {
            f.pos = gave_back;
            *pos = gave_back;
        }
        *pc = star.after;
        return true;
    }
    *pc = (uint)f.resume;
    *pos = f.pos;
    self.depth--;
    return true;
}

// ---------------------------------------------------------------------------
// The position loop
// ---------------------------------------------------------------------------

// Whether a match can begin with this code unit, per libregexp's first-unit
// filter.
fn bool re_fs_test(ReNative* n, uint unit) @inline {
    if (unit < 256) return (n.fs_bits[unit >> 5] & (1 << (unit & 31))) != 0;
    return n.fs_wide;
}

// The first position at or after `pos` where a match could begin, or RE_NONE.
// The two subject forms are separated here because a Latin-1 unit is a byte and
// a code point is too, which makes the skip a plain byte loop.
fn uint re_scan_first(ReNative* n, ReInput* in, uint pos) {
    char* data = in.data;
    uint len = in.len;
    if (pos > len) return RE_NONE;
    if (n.fs_at_start && pos == 0) return 0;
    if (!in.wide) {
        if (n.fs_single >= 0) {
            char* hit = libc::memchr(data + pos, (char)n.fs_single, (usz)(len - pos));
            if (hit != null) return (uint)(hit - data);
        } else {
            while (pos < len) {
                uint unit = (uint)data[pos];
                if ((n.fs_bits[unit >> 5] & (1 << (unit & 31))) != 0) return pos;
                pos++;
            }
        }
    } else {
        bool unicode = in.unicode;
        while (pos < len) {
            uint unit = re_unit_at(data, true, len, pos);
            if ((unit < 256 && (n.fs_bits[unit >> 5] & (1 << (unit & 31))) != 0)
                || (unit >= 256 && n.fs_wide)) {
                return pos;
            }
            if (unicode && re_is_high_surrogate(unit) && re_is_low_surrogate(re_unit_at(data, true, len, pos + 1))) {
                pos += 2;
            } else {
                pos++;
            }
        }
    }
    // The scan ran off the end: an empty match may still sit there.
    if (n.fs_at_end || (n.fs_at_start && len == 0)) return len;
    return RE_NONE;
}

// The next candidate after a failed attempt at `pos`, or RE_NONE.
fn uint re_scan_next(ReNative* n, ReInput* in, uint pos) {
    if (pos >= in.len) return RE_NONE;
    uint at = pos;
    in.code_point(&at);
    // re_scan_first still has to run at `at == len`: an empty match may sit at
    // the end of the subject, which is the one candidate left after the step.
    return re_scan_first(n, in, at);
}

// ---------------------------------------------------------------------------
// The walk
// ---------------------------------------------------------------------------

fn void ReExec.release(&self) {
    if (self.heap_frames != null) mem::free(self.heap_frames);
    if (self.heap_undo != null) mem::free(self.heap_undo);
    self.heap_frames = null;
    self.heap_undo = null;
}

// Walk the program over the subject from `start`. RE_MATCH with `out` filled,
// RE_NO_MATCH, or RE_TIMEOUT when the interrupt fired.
//
// One attempt runs the instructions; when it fails and there is nothing left to
// backtrack to, the walk moves to the next position a match could begin at and
// starts again. A program that opens with the position loop can search for those
// positions: the instructions exist to try the body at one place, step, and try
// again, which is the same thing far more cheaply when libregexp's first-unit
// filter says where to look.
fn int re_walk(ReExec* e, ReNative* n, ReInput* in, uint start, ReInterrupt* interrupt, ReOutcome* out) {
    ReProgram* prog = e.prog;
    ReInsn* insns = prog.insns.ptr;
    uint reg_base = prog.capture_count * 2;
    char* data = in.data;
    uint len = in.len;
    bool wide = in.wide;
    bool unicode = in.unicode;
    bool scanning = n.scanning && n.has_first_set;
    uint polls = RE_POLL_INTERVAL;
    uint pc = 0;
    uint pos = start;
    // Where the current attempt began. A failed attempt leaves the position where
    // it stopped matching, so the next candidate is searched from here.
    uint attempt = start;
    if (scanning) {
        pos = re_scan_first(n, in, pos);
        if (pos == RE_NONE) return RE_NO_MATCH;
        attempt = pos;
        pc = n.body_pc;
    }

    while (true) {
        if (--polls == 0) {
            polls = RE_POLL_INTERVAL;
            if (interrupt != null && interrupt.poll != null && interrupt.poll(interrupt.opaque) != 0) {
                return RE_TIMEOUT;
            }
        }
        ReInsn* insn = &insns[pc];
        bool failed = false;
        switch (insn.op) {
            case CHAR: case CHAR_I: case CHAR32: case CHAR32_I: case DOT: case ANY: case SPACE:
            case NOT_SPACE: case RANGE: case RANGE_I: case RANGE32: case RANGE32_I:
                uint next = re_step_at(prog, data, len, wide, unicode, insn, pos);
                if (next != RE_NONE) {
                    pos = next;
                    pc++;
                } else {
                    failed = true;
                }
            case GOTO:
                pc = insn.target;
            case SPLIT_GOTO_FIRST:
                // Try the target; the position stays for the fall-through.
                e.push(pc + 1, pos, false);
                pc = insn.target;
            case SPLIT_NEXT_FIRST:
                e.push(insn.target, pos, false);
                pc++;
            case SAVE_START:
                e.write((uint)insn.a * 2, pos);
                pc++;
            case SAVE_END:
                e.write((uint)insn.a * 2 + 1, pos);
                pc++;
            case SAVE_RESET:
                for (uint group = (uint)insn.a; group <= (uint)insn.b; group++) {
                    e.write(group * 2, RE_UNSET);
                    e.write(group * 2 + 1, RE_UNSET);
                }
                pc++;
            case LINE_START:
                if (pos == 0) {
                    pc++;
                } else {
                    failed = true;
                }
            case LINE_START_M:
                if (in.line_start_at(pos, true)) {
                    pc++;
                } else {
                    failed = true;
                }
            case LINE_END:
                if (pos == len) {
                    pc++;
                } else {
                    failed = true;
                }
            case LINE_END_M:
                if (in.line_end_at(pos, true)) {
                    pc++;
                } else {
                    failed = true;
                }
            case WORD_BOUNDARY:
                if (in.word_boundary_at(pos, false)) {
                    pc++;
                } else {
                    failed = true;
                }
            case WORD_BOUNDARY_I:
                if (in.word_boundary_at(pos, true)) {
                    pc++;
                } else {
                    failed = true;
                }
            case NOT_WORD_BOUNDARY:
                if (in.word_boundary_at(pos, false)) {
                    failed = true;
                } else {
                    pc++;
                }
            case NOT_WORD_BOUNDARY_I:
                if (in.word_boundary_at(pos, true)) {
                    failed = true;
                } else {
                    pc++;
                }
            case STAR:
                // The atom is one character instruction, inline after the run.
                ReInsn* body = &insns[insn.target];
                uint ran = re_run_chars(prog, data, len, wide, unicode,
                                        body, &pos, (uint)insn.a);
                if (ran < (uint)insn.a) {
                    failed = true;
                } else {
                    uint min_end = pos;
                    if (!insn.possessive) e.write(reg_base + insn.reg, min_end);
                    if (body.op == ANY) {
                        // The common case: the run takes the rest of the subject.
                        pos = len;
                    } else {
                        re_run_chars(prog, data, len, wide, unicode,
                                     body, &pos, RE_NONE);
                    }
                    if (pos != min_end && !insn.possessive) e.push(pc, pos, true);
                    pc = insn.after;
                }
            case SET_I32:
                // Seed a counted repeat: `a` is the count it may run.
                e.write(reg_base + insn.reg, (uint)insn.a);
                pc++;
            case SET_CHAR_POS:
                // Remember where the atom started, so the next repeat can tell
                // whether it advanced.
                e.write(reg_base + insn.reg, pos);
                pc++;
            case CHECK_ADVANCE:
                if (e.read(reg_base + insn.reg) == pos) {
                    failed = true;
                } else {
                    pc++;
                }
            case LOOP:
                uint count = e.read(reg_base + insn.reg) - 1;
                e.write(reg_base + insn.reg, count);
                if (count != 0) {
                    pc = insn.target;
                } else {
                    pc++;
                }
            case LOOP_SPLIT_GOTO_FIRST: case LOOP_SPLIT_NEXT_FIRST:
            case LOOP_CHECK_ADV_SPLIT_GOTO_FIRST: case LOOP_CHECK_ADV_SPLIT_NEXT_FIRST:
                uint left = e.read(reg_base + insn.reg) - 1;
                e.write(reg_base + insn.reg, left);
                if (left > (uint)insn.a) {
                    // Still inside the count the pattern requires: keep looping.
                    pc = insn.target;
                } else if (
                    (insn.op == LOOP_CHECK_ADV_SPLIT_GOTO_FIRST
                        || insn.op == LOOP_CHECK_ADV_SPLIT_NEXT_FIRST)
                    && e.read(reg_base + insn.reg + 1) == pos && left != (uint)insn.a) {
                    // The atom stopped advancing before the minimum was reached.
                    failed = true;
                } else if (left != 0) {
                    bool next_first = insn.op == LOOP_SPLIT_NEXT_FIRST
                        || insn.op == LOOP_CHECK_ADV_SPLIT_NEXT_FIRST;
                    if (next_first) {
                        e.push(insn.target, pos, false);
                        pc++;
                    } else {
                        e.push(pc + 1, pos, false);
                        pc = insn.target;
                    }
                } else {
                    pc++;
                }
            case PREV:
                if (pos == 0) {
                    failed = true;
                } else {
                    in.prev_code_point(&pos);
                    pc++;
                }
            case MATCH:
                out.start = e.capture[0];
                out.end = e.capture[1];
                return RE_MATCH;
            default:
                // A program the preparation refused must never reach here.
                return RE_ERROR;
        }
        if (!failed) continue;
        if (e.backtrack(&pc, &pos, in)) continue;
        // Nothing left to resume: try the next position a match could begin at.
        if (!scanning) return RE_NO_MATCH;
        pos = re_scan_next(n, in, attempt);
        if (pos == RE_NONE) return RE_NO_MATCH;
        attempt = pos;
        e.depth = 0;
        e.undo_len = 0;
        pc = n.body_pc;
    }
}

// ---------------------------------------------------------------------------
// Entry points
// ---------------------------------------------------------------------------

// Run the walk, with every capture and register unset first. Kept out of
// re_native_exec, whose compiled path writes each before reading it.
fn int re_walk_fresh(ReExec* e, ReNative* n, uint start, ReInterrupt* interrupt) @noinline {
    uint captures = n.prog.capture_count * 2;
    for (uint i = 0; i < captures; i++) e.capture[i] = RE_UNSET;
    for (uint i = 0; i < n.prog.register_count; i++) e.regs[i] = RE_UNSET;
    ReOutcome out;
    return re_walk(e, n, &e.in, start, interrupt, &out);
}

// Run `n` over `in` from `start` with `code`, its compiled body for the
// subject's form, or with the walk when that is null: on a match, caps[2 * i]
// and caps[2 * i + 1] bound group i, -1 when it did not participate, for the
// groups `cap_slots` ints hold. The captures are written straight into `caps`
// when it holds every group.
fn int re_exec_run(ReNative* n, ReInput* in, uint start, void* code, int* caps, int cap_slots,
                   ReInterrupt* interrupt) @inline {
    uint captures = n.prog.capture_count * 2;
    int* out = caps;
    if (@unlikely(captures > (uint)cap_slots)) out = (int*)mem::new_array(uint, (sz)captures).ptr;
    int ret;
    $if $feat(SLJIT):
        if (code != null) {
            ReCall call = { in.data, in.len, start, out, interrupt };
            ret = ((boomkat::re_jit::ReJitFn)code)(&call);
        } else {
            ret = re_walk_run(n, in, start, out, interrupt);
        }
    $else
        ret = re_walk_run(n, in, start, out, interrupt);
    $endif
    if (@unlikely(out != caps)) {
        if (ret == RE_MATCH) mem::copy(caps, out, (usz)cap_slots * int::size);
        mem::free(out);
    }
    if (ret != RE_MATCH) return ret;
    re_normalize_caps(caps);
    return RE_MATCH;
}

// Group 0 of a match whose bounds a lookbehind left unset.
fn void re_normalize_caps(int* caps) @inline {
    if (caps[0] == -1) caps[0] = 0;
    if (caps[1] == -1) caps[1] = caps[0];
}

// The walk of `n` over `in` from `start`, with its run state on this frame and
// the captures in `caps`, which holds every group.
fn int re_walk_run(ReNative* n, ReInput* in, uint start, int* caps, ReInterrupt* interrupt) @noinline {
    ReExec e @noinit;
    e.in = *in;
    // A start position inside a surrogate pair backs up to the pair's first
    // unit, so a sticky match never begins mid-character.
    if (start > 0 && start < in.len && in.wide && in.unicode) {
        if (re_is_low_surrogate(in.unit(start)) && re_is_high_surrogate(in.unit(start - 1))) start--;
    }
    e.prog = &n.prog;
    e.interrupt = interrupt;
    e.depth = 0;
    e.undo_len = 0;
    e.heap_frames = null;
    e.heap_undo = null;
    e.frame_cap = RE_SMALL_FRAMES;
    e.undo_cap = RE_SMALL_SLOTS;
    ReFrame[RE_SMALL_FRAMES] frame_buf @noinit;
    ReSlot[RE_SMALL_SLOTS] undo_buf @noinit;
    uint[RE_SMALL_REGS] regs_buf @noinit;
    e.frames = &frame_buf;
    e.undo = &undo_buf;
    e.regs = &regs_buf;
    e.capture = (uint*)caps;
    if (@unlikely(n.prog.register_count > RE_SMALL_REGS)) e.regs = mem::new_array(uint, (sz)n.prog.register_count).ptr;
    int ret = re_walk_fresh(&e, n, start, interrupt);
    if (@unlikely(e.heap_frames != null || e.heap_undo != null)) e.release();
    if (@unlikely(e.regs != &regs_buf)) mem::free(e.regs);
    return ret;
}

// Run `native` over `input_len` units of `input` from `start_offset`, as
// re_run (re_wrapper.h) runs it once the literal checks have passed.
fn int re_native_exec(void* native, void* input, int input_len, int start_offset, int input_wide,
                      int* caps, int cap_slots, ReInterrupt* interrupt) @export("re_native_exec") {
    ReNative* n = (ReNative*)native;
    if (start_offset < 0 || start_offset > input_len) return RE_NO_MATCH;
    ReInput in = { input, (uint)input_len, input_wide != 0, n.prog.unicode() };
    void* code = null;
    $if $feat(SLJIT):
        code = in.wide ? n.code_wide : n.code_narrow;
    $endif
    return re_exec_run(n, &in, (uint)start_offset, code, caps, cap_slots, interrupt);
}

// Run the compiled regexp `re` (re_bindings::re_compile) over `len` units of
// `data` from `start`, as re_run runs it, straight into its compiled body:
// RE_MATCH or RE_NO_MATCH, or RE_ERROR when it has no
// compiled body for the subject's form or the body gave up, which leaves the
// run to re_run.
fn int re_run_compiled(void* re, char* data, uint len, bool wide, uint start, int* caps, int cap_slots,
                       ReInterrupt* interrupt) @inline {
    $if $feat(SLJIT):
        // re_wrapper.c keeps the native program first, null until re_run prepares it.
        ReNative* n = *(ReNative**)re;
        if (n == null) return RE_ERROR;
        void* code = wide ? n.code_wide : n.code_narrow;
        if (code == null) return RE_ERROR;
        if (start > len) return RE_NO_MATCH;
        ReInput in = { data, len, wide, n.prog.unicode() };
        int ret = re_exec_run(n, &in, start, code, caps, cap_slots, interrupt);
        return ret == RE_MATCH || ret == RE_NO_MATCH ? ret : RE_ERROR;
    $else
        return RE_ERROR;
    $endif
}

// Decode the pattern behind `re` and keep the program if this matcher models it.
// Null leaves the pattern on libregexp's interpreter, now and for every later
// run: the answer is remembered rather than re-derived.
fn void* re_native_prepare(void* re) @export("re_native_prepare") {
    int len;
    char* bc = re_bindings::re_bytecode(re, &len);
    if (bc == null || len <= 0) return null;
    ReProgram prog;
    if (!re_prog_decode(&prog, bc, (uint)len)) return null;
    if (!prog.executable()) {
        prog.free();
        return null;
    }
    ReNative* n = mem::new(ReNative);
    n.prog = prog;
    // The position loop is the three instructions libregexp's own fast path
    // recognises: a split whose target is the body, `any` to step with, and the
    // goto back to the split.
    n.scanning = prog.insns.len > 3
        && prog.insns[0].op == SPLIT_GOTO_FIRST && prog.insns[0].target == 3
        && prog.insns[1].op == ANY
        && prog.insns[2].op == GOTO && prog.insns[2].target == 0;
    n.body_pc = 3;
    n.fs_single = -1;
    int rare, where, whole;
    n.lit_len = (uint)re_bindings::re_literal(re, &n.lit, &rare, &where, &whole);
    n.lit_rare = (uint)rare;
    n.lit_where = where;
    n.lit_whole = whole != 0;
    if (n.scanning) {
        int wide, single, at_start, at_end;
        n.has_first_set = re_bindings::re_first_set(re, &n.fs_bits[0], &wide, &single, &at_start, &at_end);
        n.fs_wide = wide != 0;
        n.fs_single = single;
        n.fs_at_start = at_start != 0;
        n.fs_at_end = at_end != 0;
    }
    // Compile what the emitter models to machine code, once, here: a run may
    // not pay for a compiler, and a refused program is refused for good.
    $if $feat(SLJIT):
        boomkat::re_jit::re_jit_compile(n);
    $endif
    return n;
}

fn void re_native_free(void* native) @export("re_native_free") {
    ReNative* n = (ReNative*)native;
    if (n == null) return;
    $if $feat(SLJIT):
        boomkat::re_jit::re_jit_free(n);
    $endif
    n.prog.free();
    mem::free(n);
}
