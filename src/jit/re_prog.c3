// Native regexp backend: libregexp's bytecode, decoded.
//
// A compiled regexp carries libregexp's bytecode (vendor/libregexp): an eight-byte header and a
// sequence of instructions whose encoding is variable length, executed by a backtracking
// interpreter. Native compilation needs it as an array of instructions with resolved targets and
// class pairs unpacked, so the program is decoded once, when it is first considered for
// compilation. Anything the decoder does not model is refused here, which leaves that program on
// the interpreter: the native path may only decline, never guess.
module boomkat::jit @feat(SLJIT);

import std::core::mem;

// No instruction, target or pair index.
const uint RE_NONE = uint::max;

// Program header (`RE_HEADER_*` in vendor/libregexp/libregexp.c).
const uint RE_HEADER_FLAGS = 0;           // u16
const uint RE_HEADER_CAPTURE_COUNT = 2;   // u8
const uint RE_HEADER_REGISTER_COUNT = 3;  // u8
const uint RE_HEADER_BYTECODE_LEN = 4;    // u32
const uint RE_HEADER_LEN = 8;

// Header flags (`LRE_FLAG_*` in vendor/libregexp/libregexp.h).
const ushort RE_FLAG_GLOBAL = 1 << 0;
const ushort RE_FLAG_IGNORECASE = 1 << 1;
const ushort RE_FLAG_MULTILINE = 1 << 2;
const ushort RE_FLAG_DOTALL = 1 << 3;
const ushort RE_FLAG_UNICODE = 1 << 4;
const ushort RE_FLAG_STICKY = 1 << 5;
const ushort RE_FLAG_INDICES = 1 << 6;
const ushort RE_FLAG_NAMED_GROUPS = 1 << 7;
const ushort RE_FLAG_UNICODE_SETS = 1 << 8;

// One instruction, in the order `libregexp-opcode.h` declares them: the ordinal is the opcode byte.
enum ReOp : char {
    INVALID,
    CHAR,             // a: the code unit to match
    CHAR_I,           // a: the unit a canonicalized subject unit compares equal to
    CHAR32,           // a: the code point to match
    CHAR32_I,
    DOT,              // any code point but a line terminator
    ANY,              // any code point
    SPACE,
    NOT_SPACE,
    LINE_START,       // pos == 0
    LINE_START_M,     // pos == 0 or after a line terminator
    LINE_END,         // pos == len
    LINE_END_M,       // pos == len or before a line terminator
    GOTO,             // target
    SPLIT_GOTO_FIRST, // try target first, else fall through
    SPLIT_NEXT_FIRST, // fall through first, else try target
    MATCH,
    LOOKAHEAD_MATCH,  // stop of a lookahead body
    NEGATIVE_LOOKAHEAD_MATCH,
    SAVE_START,       // a: capture slot in the capture array
    SAVE_END,
    SAVE_RESET,       // a, b: reset that range of slots
    LOOP,             // a: register; b: the limit
    LOOP_SPLIT_GOTO_FIRST,
    LOOP_SPLIT_NEXT_FIRST,
    LOOP_CHECK_ADV_SPLIT_GOTO_FIRST,
    LOOP_CHECK_ADV_SPLIT_NEXT_FIRST,
    SET_I32,          // a: register; b: the value
    WORD_BOUNDARY,
    WORD_BOUNDARY_I,
    NOT_WORD_BOUNDARY,
    NOT_WORD_BOUNDARY_I,
    BACK_REFERENCE,
    BACK_REFERENCE_I,
    BACKWARD_BACK_REFERENCE,
    BACKWARD_BACK_REFERENCE_I,
    RANGE,            // pair_count class pairs from ReProgram.ranges
    RANGE_I,
    RANGE32,
    RANGE32_I,
    LOOKAHEAD,        // target: the stop of the lookahead body
    NEGATIVE_LOOKAHEAD,
    SET_CHAR_POS,     // a: register
    CHECK_ADVANCE,    // a: register
    PREV,             // back up one code point
    STAR,             // a: minimum; body_at/body_len: the atom this quantifies
}

// Whether the code generator models `op`. Lookarounds, back references, quantifier registers and
// the non-BMP classes are declined: each needs state the matcher does not keep yet.
fn bool re_op_compilable(ReOp op) {
    switch (op) {
        case CHAR: case CHAR_I: case DOT: case ANY: case SPACE: case NOT_SPACE: case LINE_START:
        case LINE_START_M: case LINE_END: case LINE_END_M: case GOTO: case SPLIT_GOTO_FIRST:
        case SPLIT_NEXT_FIRST: case MATCH: case SAVE_START: case SAVE_END: case WORD_BOUNDARY:
        case WORD_BOUNDARY_I: case NOT_WORD_BOUNDARY: case NOT_WORD_BOUNDARY_I: case RANGE:
        case RANGE_I: case STAR:
            return true;
        case INVALID: case CHAR32: case CHAR32_I: case LOOKAHEAD_MATCH:
        case NEGATIVE_LOOKAHEAD_MATCH: case SAVE_RESET: case LOOP: case LOOP_SPLIT_GOTO_FIRST:
        case LOOP_SPLIT_NEXT_FIRST: case LOOP_CHECK_ADV_SPLIT_GOTO_FIRST:
        case LOOP_CHECK_ADV_SPLIT_NEXT_FIRST: case SET_I32: case BACK_REFERENCE:
        case BACK_REFERENCE_I: case BACKWARD_BACK_REFERENCE: case BACKWARD_BACK_REFERENCE_I:
        case RANGE32: case RANGE32_I: case LOOKAHEAD: case NEGATIVE_LOOKAHEAD:
        case SET_CHAR_POS: case CHECK_ADVANCE: case PREV:
            return false;
    }
}

struct ReInsn {
    // The opcode.
    ReOp op;
    // Byte offset in the program: the identity a backtracking frame records.
    uint at;
    // Branch target as an index into ReProgram.insns; RE_NONE when the instruction does not
    // branch. STAR's target is the first instruction of the atom it quantifies.
    uint target;
    // STAR only: the index the match continues at once the quantified atom has run, and the
    // byte offset and length of the atom itself.
    uint after;
    uint body_at;
    uint body_len;
    // RANGE and RANGE_I only: the first pair in ReProgram.ranges and how many pairs.
    uint ranges;
    uint pair_count;
    // CHAR and CHAR_I: the code unit. SAVE_START and SAVE_END: the capture slot. STAR: the
    // minimum number of repetitions. Otherwise unused.
    long a;
}

// A decoded pattern. Every array here is owned by the program and released by ReProgram.free.
struct ReProgram {
    ReInsn[] insns;
    // Class pairs, low and high interleaved, in code-unit order.
    uint[] ranges;
    ushort flags;
    // Captures, group 0 included: the matcher's capture array has twice as many entries.
    uint capture_count;
    // Quantifier and position registers that follow the captures in that array.
    uint register_count;
    // Bytes of instruction stream, header excluded: the last instruction ends here.
    uint bc_len;
}

fn bool ReProgram.ignore_case(&self) @inline => (self.flags & RE_FLAG_IGNORECASE) != 0;

fn bool ReProgram.multiline(&self) @inline => (self.flags & RE_FLAG_MULTILINE) != 0;

fn bool ReProgram.dotall(&self) @inline => (self.flags & RE_FLAG_DOTALL) != 0;

fn bool ReProgram.unicode(&self) @inline => (self.flags & (RE_FLAG_UNICODE | RE_FLAG_UNICODE_SETS)) != 0;

fn bool ReProgram.sticky(&self) @inline => (self.flags & RE_FLAG_STICKY) != 0;

// Whether every instruction is one the code generator models.
// Whether a class instruction's pairs are ascending and disjoint, which is what the class
// matcher's binary search assumes.
fn bool ReInsn.pairs_ascend(&self, ReProgram* prog) {
    if (self.ranges == RE_NONE || self.pair_count == 0) return true;
    for (uint k = 0; k < self.pair_count; k++) {
        uint low = prog.ranges[self.ranges + k * 2];
        uint high = prog.ranges[self.ranges + k * 2 + 1];
        if (low > high) return false;
        if (k != 0 && low <= prog.ranges[self.ranges + (k - 1) * 2 + 1]) return false;
    }
    return true;
}

fn bool ReProgram.compilable(&self) {
    foreach (insn : self.insns) if (!re_op_compilable(insn.op)) return false;
    return true;
}

fn void ReProgram.free(&self) {
    mem::free(self.insns);
    mem::free(self.ranges);
    *self = {};
}

fn uint re_get_u16(char* bc, uint at) @inline {
    uint b0 = (uint)bc[at];
    uint b1 = (uint)bc[at + 1];
    return b0 | (b1 << 8);
}

fn uint re_get_u32(char* bc, uint at) @inline {
    uint b0 = (uint)bc[at];
    uint b1 = (uint)bc[at + 1];
    uint b2 = (uint)bc[at + 2];
    uint b3 = (uint)bc[at + 3];
    return b0 | (b1 << 8) | (b2 << 16) | (b3 << 24);
}

// The size in bytes of the instruction at `at`, or 0 when it is not one libregexp emits or runs
// past `stop`. RANGE, the back references and STAR are the variable-length forms.
fn uint re_insn_size(char* bc, uint at, uint stop) {
    if (at >= stop) return 0;
    switch ((ReOp)bc[at]) {
        case DOT: case ANY: case SPACE: case NOT_SPACE: case LINE_START: case LINE_START_M:
        case LINE_END: case LINE_END_M: case MATCH: case LOOKAHEAD_MATCH:
        case NEGATIVE_LOOKAHEAD_MATCH: case WORD_BOUNDARY: case WORD_BOUNDARY_I:
        case NOT_WORD_BOUNDARY: case NOT_WORD_BOUNDARY_I: case PREV:
            return 1;
        case SAVE_START: case SAVE_END: case SET_CHAR_POS: case CHECK_ADVANCE:
            return 2;
        case CHAR: case CHAR_I: case SAVE_RESET:
            return 3;
        case CHAR32: case CHAR32_I: case GOTO: case SPLIT_GOTO_FIRST: case SPLIT_NEXT_FIRST:
        case LOOKAHEAD: case NEGATIVE_LOOKAHEAD:
            return 5;
        case LOOP: case SET_I32:
            return 6;
        case STAR:
            return 7;
        case LOOP_SPLIT_GOTO_FIRST: case LOOP_SPLIT_NEXT_FIRST:
        case LOOP_CHECK_ADV_SPLIT_GOTO_FIRST: case LOOP_CHECK_ADV_SPLIT_NEXT_FIRST:
            return 10;
        case RANGE: case RANGE_I:
            return at + 3 > stop ? 0 : 3 + 4 * re_get_u16(bc, at + 1);
        case RANGE32: case RANGE32_I:
            return at + 3 > stop ? 0 : 3 + 8 * re_get_u16(bc, at + 1);
        case BACK_REFERENCE: case BACK_REFERENCE_I: case BACKWARD_BACK_REFERENCE:
        case BACKWARD_BACK_REFERENCE_I:
            return at + 2 > stop ? 0 : 2 + (uint)bc[at + 1];
        case INVALID:
            return 0;
    }
}

// How far past the instruction its relative branch reaches. Zero for instructions that do not
// branch; the caller distinguishes them by opcode.
fn uint re_branch_delta(char* bc, uint at) @inline {
    switch ((ReOp)bc[at]) {
        case GOTO: case SPLIT_GOTO_FIRST: case SPLIT_NEXT_FIRST: case LOOKAHEAD:
        case NEGATIVE_LOOKAHEAD:
            return re_get_u32(bc, at + 1);
        case LOOP:
            return re_get_u32(bc, at + 2);
        case LOOP_SPLIT_GOTO_FIRST: case LOOP_SPLIT_NEXT_FIRST:
        case LOOP_CHECK_ADV_SPLIT_GOTO_FIRST: case LOOP_CHECK_ADV_SPLIT_NEXT_FIRST:
            return re_get_u32(bc, at + 6);
        default:
            return 0;
    }
}

fn bool re_branches(ReOp op) @inline {
    return op == GOTO || op == SPLIT_GOTO_FIRST || op == SPLIT_NEXT_FIRST || op == LOOP
        || op == LOOP_SPLIT_GOTO_FIRST || op == LOOP_SPLIT_NEXT_FIRST
        || op == LOOP_CHECK_ADV_SPLIT_GOTO_FIRST || op == LOOP_CHECK_ADV_SPLIT_NEXT_FIRST
        || op == LOOKAHEAD || op == NEGATIVE_LOOKAHEAD || op == STAR;
}

// The index of the instruction starting at byte `at`, or RE_NONE.
fn uint ReProgram.index_at(&self, uint at) {
    usz lo = 0;
    usz hi = self.insns.len;
    while (lo < hi) {
        usz mid = (lo + hi) / 2;
        uint here = self.insns[mid].at;
        if (here == at) return (uint)mid;
        if (here < at) {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }
    return RE_NONE;
}

// Decode the libregexp program in `bc` into `prog`, replacing what it held. False when the program
// is malformed or an instruction runs past its stop; `prog` is then empty and the pattern stays on
// the interpreter.
fn bool re_prog_decode(ReProgram* prog, char* bc, uint bc_len) {
    prog.free();
    if (bc == null || bc_len <= RE_HEADER_LEN) return false;
    // The header states the length of the code, excluding any named-group trailer.
    uint declared = re_get_u32(bc, RE_HEADER_BYTECODE_LEN);
    if (declared > bc_len - RE_HEADER_LEN) return false;
    uint stop = RE_HEADER_LEN + declared;
    // First pass: where the instructions are, and how many class pairs the program carries.
    uint count = 0;
    uint pair_count = 0;
    for (uint at = RE_HEADER_LEN; at < stop; count++) {
        uint size = re_insn_size(bc, at, stop);
        if (size == 0 || size > stop - at) return false;
        ReOp op = (ReOp)bc[at];
        if (op == RANGE || op == RANGE_I) pair_count += re_get_u16(bc, at + 1);
        if (op == STAR && re_get_u32(bc, at + 3) > stop - at - 7) return false;
        at += size;
    }
    if (count == 0) return false;
    ReInsn[] insns = mem::new_array(ReInsn, (sz)count);
    uint[] ranges = mem::new_array(uint, (sz)pair_count * 2);
    prog.insns = insns;
    prog.ranges = ranges;
    prog.flags = (ushort)re_get_u16(bc, RE_HEADER_FLAGS);
    prog.capture_count = (uint)bc[RE_HEADER_CAPTURE_COUNT];
    prog.register_count = (uint)bc[RE_HEADER_REGISTER_COUNT];
    prog.bc_len = declared;
    // Second pass: the operands. Branch targets wait for every offset to be known.
    uint index = 0;
    uint pair_at = 0;
    for (uint at = RE_HEADER_LEN; at < stop;) {
        uint size = re_insn_size(bc, at, stop);
        ReInsn insn;
        insn.op = (ReOp)bc[at];
        insn.at = at;
        insn.target = RE_NONE;
        insn.after = RE_NONE;
        insn.body_at = 0;
        insn.body_len = 0;
        insn.ranges = RE_NONE;
        insn.pair_count = 0;
        insn.a = 0;
        switch (insn.op) {
            case CHAR: case CHAR_I:
                insn.a = (long)re_get_u16(bc, at + 1);
            case SAVE_START: case SAVE_END:
                insn.a = (long)(uint)bc[at + 1];
            case SET_I32:
                insn.a = (long)(uint)bc[at + 1];
            case STAR:
                insn.a = (long)(uint)bc[at + 2];
                insn.body_at = at + 7;
                insn.body_len = re_get_u32(bc, at + 3);
            case RANGE: case RANGE_I:
                uint pairs = re_get_u16(bc, at + 1);
                insn.ranges = pair_at;
                insn.pair_count = pairs;
                for (uint k = 0; k < pairs; k++) {
                    ranges[pair_at + k * 2] = re_get_u16(bc, at + 3 + k * 4);
                    ranges[pair_at + k * 2 + 1] = re_get_u16(bc, at + 5 + k * 4);
                }
                pair_at += pairs * 2;
            default:
        }
        insns[index] = insn;
        index++;
        at += size;
    }
    // Resolve the branches.
    foreach (&insn : prog.insns) {
        if (!re_branches(insn.op)) continue;
        uint dest = insn.op == STAR ? insn.body_at : insn.at + re_insn_size(bc, insn.at, stop) + re_branch_delta(bc, insn.at);
        insn.target = prog.index_at(dest);
        if (insn.target == RE_NONE) {
            // A branch outside the instruction stream: refuse rather than mis-compile.
            prog.free();
            return false;
        }
        if (insn.op == STAR) {
            insn.after = prog.index_at(insn.body_at + insn.body_len);
            if (insn.after == RE_NONE) {
                prog.free();
                return false;
            }
        }
    }
    return true;
}
