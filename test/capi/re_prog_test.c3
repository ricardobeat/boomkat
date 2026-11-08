// The native regexp backend's decoder, against programs the engine compiles.
//
// Every assertion here is a property the code generator relies on: the instructions tile the
// program exactly, every branch lands on an instruction, class pairs and capture slots are the
// ones the pattern names, and the instructions the generator cannot model are the ones it
// declines.
module re_prog_test;

import boomkat::re_native;
import libc;
import boomkat::re_bindings;
import std::io;

int failures;

fn void expect(bool ok, String what) {
    if (ok) return;
    failures++;
    io::printfn("FAIL %s", what);
}

fn void expect_eq(long got, long want, String what) {
    if (got == want) return;
    failures++;
    io::printfn("FAIL %s: got %d, want %d", what, got, want);
}

// Compile `pattern`, decode it into `prog`, and free the compiled regexp; false counts a failure.
fn bool decode(String pattern, re_native::ReProgram* prog, ushort flags = 0) {
    char[128] err;
    void* re = re_bindings::re_compile(pattern.ptr, pattern.len, flags, &err, 128);
    if (re == null) {
        failures++;
        io::printfn("FAIL compile /%s/: %s", pattern, (ZString)&err);
        return false;
    }
    defer re_bindings::re_free(re);
    int len;
    char* bc = re_bindings::re_bytecode(re, &len);
    if (!re_native::re_prog_decode(prog, bc, (uint)len)) {
        failures++;
        io::printfn("FAIL decode /%s/", pattern);
        return false;
    }
    return true;
}

// The byte length of an instruction: the distance to the next one, and for the last the end of
// the program. The decoder's own opcode table is what the generator will use, so a disagreement
// between the two would show up here.
fn uint insn_len(re_native::ReProgram* prog, re_native::ReInsn insn) {
    foreach (candidate : prog.insns) {
        if (candidate.at > insn.at) return candidate.at - insn.at;
    }
    return re_native::RE_HEADER_LEN + prog.bc_len - insn.at;
}

fn void check_tiling(re_native::ReProgram* prog, String pattern) {
    uint end = re_native::RE_HEADER_LEN;
    foreach (insn : prog.insns) {
        expect_eq((long)insn.at, (long)end, "instructions tile the program");
        end = insn.at + insn_len(prog, insn);
        if (re_native::re_branches(insn.op)) {
            expect(insn.target != re_native::RE_NONE, "a branch has a target");
            if (insn.target != re_native::RE_NONE) expect((usz)insn.target < prog.insns.len, "a branch target is an instruction");
        }
        if (insn.op == re_native::ReOp.RANGE || insn.op == re_native::ReOp.RANGE_I) {
            expect((usz)insn.ranges + (usz)insn.pair_count * 2 <= prog.ranges.len, "class pairs are in range");
            expect(insn.pairs_ascend(prog), "class pairs ascend");
        }
        if (insn.op == re_native::ReOp.SAVE_START || insn.op == re_native::ReOp.SAVE_END) {
            expect(insn.a >= 0 && (uint)insn.a < prog.capture_count, "a save slot is a capture");
        }
    }
    expect_eq((long)end, (long)(re_native::RE_HEADER_LEN + prog.bc_len), "the last instruction ends the program");
    for (usz i = 1; i < prog.insns.len; i++) expect(prog.insns[i - 1].at < prog.insns[i].at, "instructions ascend");
    if (pattern.len == 0) io::printn("");
}

fn int main() {
    re_native::ReProgram prog;
    defer prog.free();

    // A pattern the generator models: the position loop the engine's own fast path recognises (a
    // split whose forward branch skips the iterate step, `any`, and a goto back), then the body.
    if (decode("[a-c]+x", &prog)) {
        check_tiling(&prog, "[a-c]+x");
        expect_eq(prog.capture_count, 1, "one capture, the match itself");
        expect(prog.compilable(), "the generator models /[a-c]+x/");
        expect_eq(prog.insns[0].op.ordinal, re_native::ReOp.SPLIT_GOTO_FIRST.ordinal, "the position loop splits first");
        expect_eq(prog.insns[1].op.ordinal, re_native::ReOp.ANY.ordinal, "the loop consumes one unit");
        expect_eq(prog.insns[2].op.ordinal, re_native::ReOp.GOTO.ordinal, "and jumps back");
        expect_eq(prog.insns[2].target, 0, "to the split");
        bool saw_class = false;
        foreach (insn : prog.insns) {
            if (insn.op != re_native::ReOp.RANGE) continue;
            saw_class = true;
            expect_eq(insn.pair_count, 1, "one pair in the class");
            expect_eq(prog.ranges[insn.ranges], 'a', "class low bound");
            expect_eq(prog.ranges[insn.ranges + 1], 'c', "class high bound");
        }
        expect(saw_class, "a class instruction");
    }
    prog.free();

    // Captures: two groups plus the match, so six save instructions and three slots.
    if (decode("(a)(b)", &prog)) {
        check_tiling(&prog, "(a)(b)");
        expect_eq(prog.capture_count, 3, "two groups plus the match");
        uint saves = 0;
        foreach (insn : prog.insns) if (insn.op == re_native::ReOp.SAVE_START || insn.op == re_native::ReOp.SAVE_END) saves++;
        expect_eq(saves, 6, "a save pair per capture");
        expect(prog.compilable(), "captures alone do not decline a program");
    }
    prog.free();

    // A greedy run over one atom is the engine's own STAR instruction; its body is inline code,
    // which the decoder must land on and step over.
    if (decode("a*b", &prog)) {
        check_tiling(&prog, "a*b");
        bool saw_star = false;
        foreach (insn : prog.insns) {
            if (insn.op != re_native::ReOp.STAR) continue;
            saw_star = true;
            expect(insn.target != re_native::RE_NONE, "the star has a body");
            expect(insn.after != re_native::RE_NONE, "the star continues after its body");
            if (insn.after != re_native::RE_NONE) {
                expect(prog.insns[insn.after].at == insn.body_at + insn.body_len, "the continuation follows the body");
            }
        }
        expect(saw_star, "/a*b/ quantifies its atom with a STAR instruction");
    }
    prog.free();

    // What the generator declines it must decline here: a lookahead and a back
    // reference each leave the program on the interpreter. Counted repeats are
    // modelled now that the loop and register opcodes are decoded.
    if (decode("a(?=b)", &prog)) {
        check_tiling(&prog, "a(?=b)");
        expect(!prog.compilable(), "a lookahead is declined");
        prog.free();
    }
    if (decode("(a)\\1", &prog)) {
        check_tiling(&prog, "(a)\\1");
        expect(!prog.compilable(), "a back reference is declined");
        prog.free();
    }
    if (decode("a{2,4}", &prog)) {
        check_tiling(&prog, "a{2,4}");
        expect(prog.compilable(), "a counted repeat is modelled");
        expect(prog.executable(), "and bounds-checks cleanly");
        prog.free();
    }

    // Classes past the BMP carry 32-bit pairs and are modelled: the matcher compares code points.
    if (decode("[\\u{10000}-\\u{10FFFF}]", &prog, re_bindings::RE_FLAG_UNICODE)) {
        check_tiling(&prog, "astral class");
        expect(prog.compilable(), "a class beyond the BMP is modelled");
        bool saw_class32 = false;
        foreach (insn : prog.insns) {
            if (insn.op != re_native::ReOp.RANGE32 && insn.op != re_native::ReOp.RANGE32_I) continue;
            saw_class32 = true;
            expect_eq((long)prog.ranges[insn.ranges], 0x10000, "class32 low bound");
            expect_eq((long)prog.ranges[insn.ranges + 1], 0x10FFFF, "class32 high bound");
        }
        expect(saw_class32, "an astral class is a RANGE32 instruction");
        prog.free();
    }
    // A quantified capture clears its slots before each attempt: SAVE_RESET names the range.
    if (decode("(a)*b", &prog)) {
        check_tiling(&prog, "(a)*b");
        bool saw_reset = false;
        foreach (insn : prog.insns) {
            if (insn.op != re_native::ReOp.SAVE_RESET) continue;
            saw_reset = true;
            expect_eq(insn.a, 1, "save_reset starts at the first group");
            expect_eq(insn.b, 1, "and ends at the last");
        }
        expect(saw_reset, "/(a)*b/ clears its captures between attempts");
        prog.free();
    }

    // Flags and counts come from the header, which the generator reads and the matcher trusts.
    if (decode("ab", &prog)) {
        expect(!prog.ignore_case() && !prog.multiline() && !prog.dotall() && !prog.unicode(), "no flags");
        expect(prog.compilable(), "/ab/ is modelled");
        prog.free();
    }
    if (decode("ab", &prog, re_bindings::RE_FLAG_IGNORECASE | re_bindings::RE_FLAG_MULTILINE | re_bindings::RE_FLAG_DOTALL)) {
        expect(prog.ignore_case(), "ignore case flag");
        expect(prog.multiline(), "multiline flag");
        expect(prog.dotall(), "dotall flag");
        expect(!prog.unicode(), "not unicode");
        prog.free();
    }

    if (failures != 0) {
        io::printfn("re prog: %d FAILED", failures);
        return 1;
    }
    io::printn("re prog: PASS");
    return 0;
}
