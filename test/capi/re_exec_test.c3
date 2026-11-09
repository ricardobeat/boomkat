// The native matcher against libregexp's interpreter, case by case.
//
// Every pattern here is run from every start offset of every subject, in both
// subject forms the engine can hand the matcher, and the verdict, the match
// span and every capture must equal what `lre_exec` produces. A pattern the
// matcher declines is reported as such instead of being compared, which keeps
// the declined set visible: it is the set of instructions the matcher does not
// model.
module re_exec_test;

import boomkat::re_native;
import boomkat::re_bindings;
import libc;
import std::io;

int failures;
int compared;

fn void expect(bool ok, String what) {
    if (ok) return;
    failures++;
    io::printfn("FAIL %s", what);
}

// One run's result, in the form both matchers report.
struct Verdict {
    int match;
    int start;
    int end;
    int captures;
    int[8] caps_start;
    int[8] caps_end;
}

fn Verdict run_interpreted(void* re, void* input, int len, int start, bool wide) {
    Verdict v;
    v.match = re_bindings::re_run(re, input, len, start, wide ? 1 : 0,
                                  &v.start, &v.end, &v.captures,
                                  &v.caps_start, &v.caps_end, 8);
    return v;
}

fn Verdict run_native(void* native, void* input, int len, int start, bool wide) {
    Verdict v;
    v.match = re_native::re_native_exec(native, input, len, start, wide ? 1 : 0,
                                        &v.start, &v.end, &v.captures,
                                        &v.caps_start, &v.caps_end, 8, null);
    return v;
}

fn bool same(Verdict* a, Verdict* b) {
    if (a.match != b.match) return false;
    if (a.match != re_bindings::RE_MATCH) return true;
    if (a.start != b.start || a.end != b.end || a.captures != b.captures) return false;
    for (int i = 0; i < 8; i++) {
        if (a.caps_start[i] != b.caps_start[i] || a.caps_end[i] != b.caps_end[i]) return false;
    }
    return true;
}

fn void show(Verdict* v) {
    if (v.match != re_bindings::RE_MATCH) {
        io::printf("[no match]");
        return;
    }
    io::printf("[%d,%d] caps %d:", v.start, v.end, v.captures);
    for (int i = 0; i < 8; i++) io::printf(" %d-%d", v.caps_start[i], v.caps_end[i]);
}

// Compile `pattern`, then compare both matchers over `units` in both subject
// forms and at every start offset. `narrow` is false when a unit cannot be a
// Latin-1 byte.
fn void check(String pattern, ushort[] units, ushort flags, bool narrow) {
    re_bindings::re_set_native(0);
    char[128] err;
    void* re = re_bindings::re_compile(pattern.ptr, pattern.len, (int)flags, &err, 128);
    if (re == null) {
        failures++;
        io::printfn("FAIL compile /%s/: %s", pattern, (ZString)&err);
        return;
    }
    defer re_bindings::re_free(re);
    void* native = re_native::re_native_prepare(re);
    if (native == null) {
        io::printfn("note: /%s/ declined, staying on the interpreter", pattern);
        return;
    }
    defer re_native::re_native_free(native);

    char[300] narrow_buf;
    ushort[300] wide_buf;
    for (usz i = 0; i < units.len && i < 300; i++) {
        narrow_buf[i] = (char)(units[i] & 0xff);
        wide_buf[i] = units[i];
    }
    int len = (int)units.len;
    for (int start = 0; start <= len; start++) {
        re_bindings::re_set_native(0);
        Verdict want = run_interpreted(re, &narrow_buf, len, start, false);
        re_bindings::re_set_native(1);
        Verdict got = run_native(native, &narrow_buf, len, start, false);
        compared++;
        if (!same(&want, &got)) {
            failures++;
            io::printf("FAIL /%s/ narrow start %d: ", pattern, start);
            show(&want);
            io::print(" != ");
            show(&got);
            io::printn("");
        }
        if (!narrow) continue;
        re_bindings::re_set_native(0);
        want = run_interpreted(re, &wide_buf, len, start, true);
        re_bindings::re_set_native(1);
        got = run_native(native, &wide_buf, len, start, true);
        compared++;
        if (!same(&want, &got)) {
            failures++;
            io::printf("FAIL /%s/ wide start %d: ", pattern, start);
            show(&want);
            io::print(" != ");
            show(&got);
            io::printn("");
        }
    }
}

// Print the decoded program, for working out which instruction a mismatch
// belongs to. Enabled with BOOMKAT_RE_DUMP, because it is not a test.
fn void dump(String pattern, ushort flags = 0) {
    char[128] err;
    void* re = re_bindings::re_compile(pattern.ptr, pattern.len, (int)flags, &err, 128);
    if (re == null) return;
    defer re_bindings::re_free(re);
    int len;
    char* bc = re_bindings::re_bytecode(re, &len);
    re_native::ReProgram prog;
    defer prog.free();
    if (!re_native::re_prog_decode(&prog, bc, (uint)len)) {
        io::printfn("/%s/ does not decode", pattern);
        return;
    }
    io::printfn("/%s/ captures %d registers %d%s:", pattern, prog.capture_count,
                prog.register_count, prog.executable() ? "" : " (declined)");
    for (usz i = 0; i < prog.insns.len; i++) {
        re_native::ReInsn insn = prog.insns[i];
        io::printf("  %d @%d %s", (int)i, (int)insn.at, re_op_name(insn.op));
        if (insn.target != re_native::RE_NONE) io::printf(" -> %d", (int)insn.target);
        if (insn.after != re_native::RE_NONE) io::printf(" then %d", (int)insn.after);
        if (insn.a != 0) io::printf(" a=%d", insn.a);
        if (insn.reg != 0) io::printf(" reg=%d", (int)insn.reg);
        if (insn.pair_count != 0) io::printf(" pairs=%d", (int)insn.pair_count);
        io::printn("");
    }
}

// The Octane RegExp benchmark's own patterns, which are what this backend exists
// for: anchored selector matchers full of captures, classes and alternations.
struct OctanePattern {
    String pattern;
    ushort flags;
}

const OctanePattern[] OCTANE_PATTERNS = {
    { "^ba", 0 },   // re0
    { "(((\\w+):\\/\\/)([^\\/:]*)(:(\\d+))?)?([^#?]*)(\\?([^#]*))?(#(.*))?", 0 },   // re1
    { "^\\s*|\\s*$", 0 },   // re2
    { "\\bQBZPbageby_cynprubyqre\\b", 0 },   // re3
    { ",", 0 },   // re4
    { "\\bQBZPbageby_cynprubyqre\\b", 0 },   // re5
    { "^[\\s\\xa0]+|[\\s\\xa0]+$", 0 },   // re6
    { "(\\d*)(\\D*)", 0 },   // re7
    { "=", 0 },   // re8
    { "(^|\\s)lhv\\-h(\\s|$)", 0 },   // re9
    { "\\#", 0 },   // re10
    { "\\.", 0 },   // re11
    { "'", 0 },   // re12
    { "\\?[\\w\\W]*(sevraqvq|punaaryvq|tebhcvq)=([^\\&\\?#]*)", re_bindings::RE_FLAG_IGNORECASE },   // re13
    { "\\s+", 0 },   // re14
    { "^\\s*(\\S*(\\s+\\S+)*)\\s*$", 0 },   // re15
    { "(-[a-z])", re_bindings::RE_FLAG_IGNORECASE },   // re16
    { "(^|[^\\\\])\\\"\\\\\\/Qngr\\((-?[0-9]+)\\)\\\\\\/\\\"", 0 },   // re17
    { "^\\s+|\\s+$", 0 },   // re18
    { "(?:^|\\s+)ba(?:\\s+|$)", 0 },   // re19
    { "[+, ]", 0 },   // re20
    { "ybnqrq|pbzcyrgr", 0 },   // re21
    { "\\bso_zrah\\b", 0 },   // re22
    { "^(?:(?:[^:\\/?#]+):)?(?:\\/\\/(?:[^\\/?#]*))?([^?#]*)(?:\\?([^#]*))?(?:#(.*))?", 0 },   // re23
    { "uggcf?:\\/\\/([^\\/]+\\.)?snprobbx\\.pbz\\/", 0 },   // re24
    { "\"", 0 },   // re25
    { "^([^?#]+)(?:\\?([^#]*))?(#.*)?", 0 },   // re26
    { "-\\D", 0 },   // re27
    { "\\bnpgvingr\\b", 0 },   // re28
    { "%2R", re_bindings::RE_FLAG_IGNORECASE },   // re29
    { "%2S", re_bindings::RE_FLAG_IGNORECASE },   // re30
    { "^(mu-(PA|GJ)|wn|xb)$", 0 },   // re31
    { "\\s?;\\s?", 0 },   // re32
    { "%\\w?$", 0 },   // re33
    { "TNQP=([^;]*)", re_bindings::RE_FLAG_IGNORECASE },   // re34
    { "[<>]", 0 },   // re35
    { "uers|fep|fryrpgrq", 0 },   // re36
    { "\\s*([+>~\\s])\\s*([a-zA-Z#.*:\\[])", 0 },   // re37
    { "^(\\w+|\\*)$", 0 },   // re38
    { "\\\\", 0 },   // re39
    { " ", 0 },   // re40
    { "\\/\\xc4\\/t", 0 },   // re41
    { "\\/\\xd6\\/t", 0 },   // re42
    { "\\/\\xdc\\/t", 0 },   // re43
    { "\\/\\xdf\\/t", 0 },   // re44
    { "\\/\\xe4\\/t", 0 },   // re45
    { "\\/\\xf6\\/t", 0 },   // re46
    { "\\/\\xfc\\/t", 0 },   // re47
    { "\\W", 0 },   // re48
    { "uers|fep|fglyr", 0 },   // re49
    { "(?:^|\\s+)fryrpgrq(?:\\s+|$)", 0 },   // re50
    { "\\&", 0 },   // re51
    { "\\+", 0 },   // re52
    { "\\?", 0 },   // re53
    { "\\t", 0 },   // re54
    { "(\\$\\{nqiHey\\})|(\\$nqiHey\\b)", 0 },   // re55
    { "(\\$\\{cngu\\})|(\\$cngu\\b)", 0 },   // re56
    { "##yv4##", re_bindings::RE_FLAG_IGNORECASE },   // re57
    { "##yv16##", re_bindings::RE_FLAG_IGNORECASE },   // re58
    { "##yv19##", re_bindings::RE_FLAG_IGNORECASE },   // re59
    { "(?:^|\\s+)bss(?:\\s+|$)", 0 },   // re60
    { "^(([^:\\/?#]+):)?(\\/\\/([^\\/?#]*))?([^?#]*)(\\?([^#]*))?(#(.*))?$", 0 },   // re61
    { "^[^<]*(<(.|\\s)+>)[^>]*$|^#(\\w+)$", 0 },   // re62
    { "\\{0\\}", 0 },   // re63
    { "\\b[a-z]", 0 },   // re64
    { "^uggc:\\/\\/", 0 },   // re65
    { "(?:^|\\s+)qvfnoyrq(?:\\s+|$)", 0 },   // re66
    { "zrah_byq", 0 },   // re67
    { "^([#.]?)((?:[\\w\\u0128-\\uffff*_-]|\\\\.)*)", 0 },   // re68
    { "\\{1\\}", 0 },   // re69
    { "\\s+", 0 },   // re70
    { "(\\$\\{4\\})|(\\$4\\b)", 0 },   // re71
    { "(\\$\\{5\\})|(\\$5\\b)", 0 },   // re72
    { "\\{2\\}", 0 },   // re73
    { "[^+>] [^+>]", 0 },   // re74
    { "\\bucpyv\\s*=\\s*([^;]*)", re_bindings::RE_FLAG_IGNORECASE },   // re75
    { "\\bucuvqr\\s*=\\s*([^;]*)", re_bindings::RE_FLAG_IGNORECASE },   // re76
    { "\\bucfie\\s*=\\s*([^;]*)", re_bindings::RE_FLAG_IGNORECASE },   // re77
    { "\\bhfucjrn\\s*=\\s*([^;]*)", re_bindings::RE_FLAG_IGNORECASE },   // re78
    { "\\bmvc\\s*=\\s*([^;]*)", re_bindings::RE_FLAG_IGNORECASE },   // re79
    { "^((?:[\\w\\u0128-\\uffff*_-]|\\\\.)+)(#)((?:[\\w\\u0128-\\uffff*_-]|\\\\.)+)", 0 },   // re80
    { "^([>+~])\\s*(\\w*)", re_bindings::RE_FLAG_IGNORECASE },   // re81
    { "^>\\s*((?:[\\w\\u0128-\\uffff*_-]|\\\\.)+)", 0 },   // re82
    { "^[\\s[]?shapgvba", 0 },   // re83
    { "v\\/g.tvs#(.*)", re_bindings::RE_FLAG_IGNORECASE },   // re84
    { "eaq_zbqobkva", 0 },   // re85
    { ";\\s*", 0 },   // re86
    { "(\\$\\{inyhr\\})|(\\$inyhr\\b)", 0 },   // re87
    { "(\\$\\{abj\\})|(\\$abj\\b)", 0 },   // re88
    { "\\s+$", 0 },   // re89
    { "^\\s+", 0 },   // re90
    { "(\\\\\\\"|\\x00-|\\x1f|\\x7f-|\\x9f|\\u00ad|\\u0600-|\\u0604|\\u070f|\\u17b4|\\u17b5|\\u200c-|\\u200f|\\u2028-|\\u202f|\\u2060-|\\u206f|\\ufeff|\\ufff0-|\\uffff)", 0 },   // re91
    { "^(:)([\\w-]+)\\(\"?'?(.*?(\\(.*?\\))?[^(]*?)\"?'?\\)", 0 },   // re92
    { "^([:.#]*)((?:[\\w\\u0128-\\uffff*_-]|\\\\.)+)", 0 },   // re93
    { "^(\\[) *@?([\\w-]+) *([!*$^~=]*) *('?\"?)(.*?)\\4 *\\]", 0 },   // re94
};

// Subjects the benchmark matches those patterns against, spelled the way its
// rotating alphabet leaves them.
const String[] OCTANE_SUBJECTS = {
    " qg", ".pybfr", " n.svryqOgaPnapry", "#Ybtva_cnffjbeq", "sbez.nwnk",
    "shapgvba sbphc() { [angvir pbqr] }", "[anzr=nwnkHey]", "jva32", "*", "rzorq",
};

// Every benchmark pattern against every subject, in both matchers. Patterns the
// matcher declines print a note naming them, which keeps the declined set of the
// patterns that matter visible.
fn void octane_cases() {
    foreach (entry : OCTANE_PATTERNS) {
        bool narrow = true;
        foreach (subject : OCTANE_SUBJECTS) {
            narrow = true;
            ushort[64] units;
            if (subject.len > 64) continue;
            for (usz i = 0; i < subject.len; i++) units[i] = (ushort)subject.ptr[i];
            check((String)entry.pattern, units[0..subject.len], entry.flags, narrow);
        }
    }
}

// Subjects long enough that a repeated group needs more backtracking frames and
// undo records than the buffers a run starts with, which is where the growth of
// both stacks is exercised. The lengths straddle the initial capacities.
fn void deep_cases() {
    int[] lengths = { 4, 20, 40, 47, 48, 49, 60, 96, 97, 120, 200 };
    foreach (len : lengths) {
        ushort[300] units;
        for (int i = 0; i < len; i++) units[i] = (ushort)('a' + (i & 1));
        units[len] = 'b';
        check("(a)*b", units[0..len + 1], 0, true);
        check("a*b", units[0..len + 1], 0, true);
        check("(?:a|b)*c", units[0..len + 1], 0, true);
        check("(?:a|b)*$", units[0..len + 1], 0, true);
    }
}

fn void cases() {
    // The position loop, a class and a greedy run over it.
    check("[a-c]+x", (ushort[]){'z', 'z', 'a', 'b', 'c', 'x', 'z'}, 0, true);
    check("[a-c]", (ushort[]){'z', 'a'}, 0, true);
    check("[^+>] [^+>]", (ushort[]){'a', 'a', 'a', 'a', ' ', 'a'}, 0, true);
    check("[^+>] [^+>]", (ushort[]){'s', 'h', 'a', 'p', 'g', 'v', 'b', 'a', ' ', 's', 'b'}, 0, true);
    check("[a-c]*", (ushort[]){'a', 'b', 'z'}, 0, true);
    check("a*b", (ushort[]){'a', 'a', 'b'}, 0, true);
    check("a*b", (ushort[]){'a', 'b', 'c'}, 0, true);
    check("(a)(b)", (ushort[]){'x', 'a', 'b', 'y'}, 0, true);
    check("(a)*b", (ushort[]){'a', 'a', 'b'}, 0, true);
    check("(a)*b", (ushort[]){'b'}, 0, true);
    check("(?:ab)+", (ushort[]){'x', 'a', 'b', 'a', 'b'}, 0, true);
    // Counted repeats: the loop, split and advance registers the decoder added.
    check("a{2,4}", (ushort[]){'a', 'a', 'a', 'a', 'a', 'b'}, 0, true);
    check("a{2,4}", (ushort[]){'a', 'b'}, 0, true);
    check("a{2,}", (ushort[]){'a', 'a', 'a', 'b'}, 0, true);
    check("(a){2,3}b", (ushort[]){'a', 'a', 'a', 'b'}, 0, true);
    check("(a|b){1,3}c", (ushort[]){'a', 'b', 'a', 'c'}, 0, true);
    check("a{0,2}b", (ushort[]){'a', 'a', 'b'}, 0, true);
    check("a|b", (ushort[]){'z', 'b'}, 0, true);
    check("x(a)", (ushort[]){'z', 'a'}, 0, true);
    check("(?:a)", (ushort[]){'z', 'a'}, 0, true);
    // Assertions.
    check("^foo$", (ushort[]){'f', 'o', 'o'}, 0, true);
    check("^foo$", (ushort[]){'x', 'f', 'o', 'o'}, 0, true);
    check("\\bword\\b", (ushort[]){'a', ' ', 'w', 'o', 'r', 'd'}, 0, true);
    check("\\Bord", (ushort[]){'w', 'o', 'r', 'd'}, 0, true);
    check("^b$", (ushort[]){'a', '\n', 'b', '\n', 'c'}, re_bindings::RE_FLAG_MULTILINE, true);
    // Dot, any and the space classes.
    check(".", (ushort[]){'a', '\n', 'b'}, 0, true);
    check(".", (ushort[]){'a', '\n', 'b'}, re_bindings::RE_FLAG_DOTALL, true);
    check("\\s+", (ushort[]){'a', ' ', ' ', 9, 'b'}, 0, true);
    check("\\S+", (ushort[]){' ', 'a', 'b'}, 0, true);
    // Ignore case: canonicalization on both sides.
    check("abc", (ushort[]){'x', 'A', 'B', 'C'}, re_bindings::RE_FLAG_IGNORECASE, true);
    check("[a-z]+", (ushort[]){'X', 'Y', 'Z'}, re_bindings::RE_FLAG_IGNORECASE, true);
    check("[^a-z]+", (ushort[]){'a', 'b', 'C'}, re_bindings::RE_FLAG_IGNORECASE, true);
    // Sticky: no position loop, the match is anchored where it starts.
    check("a+", (ushort[]){'b', 'a', 'a'}, re_bindings::RE_FLAG_STICKY, true);
    // Captures inside a run, which the run clears between attempts.
    check("(a)|(b)", (ushort[]){'b'}, 0, true);
    check("(a+)(b+)", (ushort[]){'a', 'a', 'b'}, 0, true);
    check("((a)(b))", (ushort[]){'a', 'b'}, 0, true);
    // Latin-1 high units, which only the narrow form can hold.
    check("[\\u00e0-\\u00ff]+", (ushort[]){0x41, 0xe0, 0xff}, 0, true);
    // Unicode mode: code points above the BMP, and surrogate pairs.
    check("\\u{1F600}", (ushort[]){'x', 0xD83D, 0xDE00, 'y'}, re_bindings::RE_FLAG_UNICODE, false);
    check("[\\u{10000}-\\u{10FFFF}]+", (ushort[]){'x', 0xD83D, 0xDE00}, re_bindings::RE_FLAG_UNICODE, false);
    check(".", (ushort[]){0xD83D, 0xDE00, 'y'}, re_bindings::RE_FLAG_UNICODE, false);
    // A pattern whose class would match the low surrogate alone in sloppy mode.
    check("[\\uDC00-\\uDFFF]", (ushort[]){0xD83D, 0xDE00}, 0, false);
    // Empty matches at the end: a failed attempt at the last unit must not hide
    // the candidate that sits just past it.
    check("a*$", (ushort[]){'a', 'b'}, 0, true);
    check("a*$", (ushort[]){'b', 'a', 'b'}, 0, true);
    check("(?:a|)*$", (ushort[]){'a', 'b', 'a'}, 0, true);
    check("a*\\b", (ushort[]){'a', ' ', 'b'}, 0, true);
    check("(?:a|b)*$", (ushort[]){'a', 'b', 'c'}, 0, true);
}

// The decoder's own names, for the dump.
fn String re_op_name(re_native::ReOp op) {
    switch (op) {
        case INVALID: return "invalid";
        case CHAR: return "char";
        case CHAR_I: return "char_i";
        case CHAR32: return "char32";
        case CHAR32_I: return "char32_i";
        case DOT: return "dot";
        case ANY: return "any";
        case SPACE: return "space";
        case NOT_SPACE: return "not_space";
        case LINE_START: return "line_start";
        case LINE_START_M: return "line_start_m";
        case LINE_END: return "line_end";
        case LINE_END_M: return "line_end_m";
        case GOTO: return "goto";
        case SPLIT_GOTO_FIRST: return "split_goto_first";
        case SPLIT_NEXT_FIRST: return "split_next_first";
        case MATCH: return "match";
        case LOOKAHEAD_MATCH: return "lookahead_match";
        case NEGATIVE_LOOKAHEAD_MATCH: return "negative_lookahead_match";
        case SAVE_START: return "save_start";
        case SAVE_END: return "save_end";
        case SAVE_RESET: return "save_reset";
        case LOOP: return "loop";
        case LOOP_SPLIT_GOTO_FIRST: return "loop_split_goto_first";
        case LOOP_SPLIT_NEXT_FIRST: return "loop_split_next_first";
        case LOOP_CHECK_ADV_SPLIT_GOTO_FIRST: return "loop_check_adv_split_goto_first";
        case LOOP_CHECK_ADV_SPLIT_NEXT_FIRST: return "loop_check_adv_split_next_first";
        case SET_I32: return "set_i32";
        case WORD_BOUNDARY: return "word_boundary";
        case WORD_BOUNDARY_I: return "word_boundary_i";
        case NOT_WORD_BOUNDARY: return "not_word_boundary";
        case NOT_WORD_BOUNDARY_I: return "not_word_boundary_i";
        case BACK_REFERENCE: return "back_reference";
        case BACK_REFERENCE_I: return "back_reference_i";
        case BACKWARD_BACK_REFERENCE: return "backward_back_reference";
        case BACKWARD_BACK_REFERENCE_I: return "backward_back_reference_i";
        case RANGE: return "range";
        case RANGE_I: return "range_i";
        case RANGE32: return "range32";
        case RANGE32_I: return "range32_i";
        case LOOKAHEAD: return "lookahead";
        case NEGATIVE_LOOKAHEAD: return "negative_lookahead";
        case SET_CHAR_POS: return "set_char_pos";
        case CHECK_ADVANCE: return "check_advance";
        case PREV: return "prev";
        case STAR: return "star";
    }
}

fn void main() {
    if (libc::getenv("BOOMKAT_RE_DUMP") != null) {
        dump("[^+>] [^+>]");
        dump("[Q]");
        dump("[0-9]{5}-[0-9]{5}");
        dump("([0-9]*)([^0-9]*)");
        dump("[a-c]+x");
        dump("(a)(b)");
        dump("\\bword\\b");
        dump(".");
        dump("a{2,4}");
        dump("(a)|(b)");
        dump("\\u{1F600}", re_bindings::RE_FLAG_UNICODE);
        foreach (entry : OCTANE_PATTERNS) dump(entry.pattern, entry.flags);
        return;
    }
    deep_cases();
    cases();
    octane_cases();
    if (failures != 0) {
        io::printfn("re exec: %d FAILED in %d comparisons", failures, compared);
        return;
    }
    io::printfn("re exec: PASS (%d comparisons)", compared);
}
