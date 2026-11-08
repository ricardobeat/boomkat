// Self-test for the native regexp matcher's subject cursor (src/jit/re_input.c3).
//
// The cursor walks a subject in the two forms libregexp uses: Latin-1 bytes
// and native-endian UTF-16 code units. Positions are code-unit indices, and
// in unicode mode a surrogate pair is a single code point.
module re_input_test;

import boomkat::jit;
import std::io;

int re_input_failures = 0;

macro void re_input_eq(uint got, uint want, String label) {
    if (got != want) {
        io::eprintfn("re input: FAIL %s: got %d, want %d", label, got, want);
        re_input_failures++;
    }
}

macro void re_input_yes(bool cond, String label) {
    if (!cond) {
        io::eprintfn("re input: FAIL %s", label);
        re_input_failures++;
    }
}

// Latin-1 subject: "caf" followed by U+00E9 as a single byte.
char[] re_input_latin1 = { 'c', 'a', 'f', (char)0xE9 };

// Wide subject: 'a', U+00E9, an astral character (U+1F600 as D83D DE00), 'z'.
ushort[] re_input_wide = { 'a', 0x00E9, 0xD83D, 0xDE00, 'z' };

// Wide subject with a lone high surrogate followed by an ordinary unit.
ushort[] re_input_lone = { 0xD83D, 'a' };

fn void re_input_test_units() {
    jit::ReInput narrow = {
        .data = (char*)re_input_latin1.ptr,
        .len = 4,
        .wide = false,
        .unicode = false,
    };
    jit::ReInput wide = {
        .data = (char*)re_input_wide.ptr,
        .len = 5,
        .wide = true,
        .unicode = true,
    };

    re_input_eq(narrow.unit(0), (uint)'c', "latin1 unit 0");
    re_input_eq(narrow.unit(3), 0xE9, "latin1 unit 3");
    re_input_eq(narrow.unit(4), 0, "latin1 unit past end");
    re_input_eq(narrow.unit(4000), 0, "latin1 unit far past end");

    re_input_eq(wide.unit(0), (uint)'a', "wide unit 0");
    re_input_eq(wide.unit(1), 0xE9, "wide unit 1");
    re_input_eq(wide.unit(2), 0xD83D, "wide unit 2");
    re_input_eq(wide.unit(4), (uint)'z', "wide unit 4");
    re_input_eq(wide.unit(5), 0, "wide unit past end");

    re_input_yes(!narrow.at_end(3), "latin1 not at end");
    re_input_yes(narrow.at_end(4), "latin1 at end");
    re_input_yes(!wide.at_end(4), "wide not at end");
    re_input_yes(wide.at_end(5), "wide at end");
}

fn void re_input_test_code_point() {
    jit::ReInput narrow = {
        .data = (char*)re_input_latin1.ptr,
        .len = 4,
        .wide = false,
        .unicode = false,
    };
    jit::ReInput wide_uni = {
        .data = (char*)re_input_wide.ptr,
        .len = 5,
        .wide = true,
        .unicode = true,
    };
    jit::ReInput wide_plain = {
        .data = (char*)re_input_wide.ptr,
        .len = 5,
        .wide = true,
        .unicode = false,
    };
    jit::ReInput lone_uni = {
        .data = (char*)re_input_lone.ptr,
        .len = 2,
        .wide = true,
        .unicode = true,
    };

    // ASCII over the Latin-1 subject.
    uint pos = 0;
    re_input_eq(narrow.code_point(&pos), (uint)'c', "ascii code point");
    re_input_eq(pos, 1, "ascii code point advances one unit");

    // Latin-1 byte 0xE9 is one code point in one unit.
    pos = 3;
    re_input_eq(narrow.code_point(&pos), 0xE9, "latin1 code point");
    re_input_eq(pos, 4, "latin1 code point advances one unit");

    // Past the end: no code point, and the position does not move.
    pos = 4;
    re_input_eq(narrow.code_point(&pos), 0, "code point at end");
    re_input_eq(pos, 4, "code point at end does not move");

    // An astral character in unicode mode is one code point over two units.
    pos = 2;
    re_input_eq(wide_uni.code_point(&pos), 0x1F600, "astral code point");
    re_input_eq(pos, 4, "astral code point advances two units");

    // Without the unicode flag the surrogate pair is two separate units.
    pos = 2;
    re_input_eq(wide_plain.code_point(&pos), 0xD83D, "non-unicode high surrogate");
    re_input_eq(pos, 3, "non-unicode high surrogate advances one unit");
    pos = 3;
    re_input_eq(wide_plain.code_point(&pos), 0xDE00, "non-unicode low surrogate");
    re_input_eq(pos, 4, "non-unicode low surrogate advances one unit");

    // A lone high surrogate followed by an ordinary unit stays one unit.
    pos = 0;
    re_input_eq(lone_uni.code_point(&pos), 0xD83D, "lone high surrogate");
    re_input_eq(pos, 1, "lone high surrogate advances one unit");
    pos = 1;
    re_input_eq(lone_uni.code_point(&pos), (uint)'a', "unit after lone high surrogate");
    re_input_eq(pos, 2, "unit after lone high surrogate advances one unit");
}

fn void re_input_test_prev_code_point() {
    jit::ReInput narrow = {
        .data = (char*)re_input_latin1.ptr,
        .len = 4,
        .wide = false,
        .unicode = false,
    };
    jit::ReInput wide_uni = {
        .data = (char*)re_input_wide.ptr,
        .len = 5,
        .wide = true,
        .unicode = true,
    };
    jit::ReInput wide_plain = {
        .data = (char*)re_input_wide.ptr,
        .len = 5,
        .wide = true,
        .unicode = false,
    };
    jit::ReInput lone_uni = {
        .data = (char*)re_input_lone.ptr,
        .len = 2,
        .wide = true,
        .unicode = true,
    };

    // Mirrors code_point over the same subjects.
    uint pos = 1;
    re_input_eq(narrow.prev_code_point(&pos), (uint)'c', "ascii prev code point");
    re_input_eq(pos, 0, "ascii prev code point steps back one unit");

    pos = 4;
    re_input_eq(narrow.prev_code_point(&pos), 0xE9, "latin1 prev code point");
    re_input_eq(pos, 3, "latin1 prev code point steps back one unit");

    // Never moves before the start of the subject.
    pos = 0;
    re_input_eq(narrow.prev_code_point(&pos), 0, "prev code point at start");
    re_input_eq(pos, 0, "prev code point at start does not move");

    // In unicode mode the pair is recombined over two units.
    pos = 4;
    re_input_eq(wide_uni.prev_code_point(&pos), 0x1F600, "astral prev code point");
    re_input_eq(pos, 2, "astral prev code point steps back two units");

    // One unit before the pair is only the high surrogate.
    pos = 3;
    re_input_eq(wide_uni.prev_code_point(&pos), 0xD83D, "prev code point before the pair");
    re_input_eq(pos, 2, "prev code point before the pair steps back one unit");

    // Without the unicode flag the pair is never recombined.
    pos = 4;
    re_input_eq(wide_plain.prev_code_point(&pos), 0xDE00, "non-unicode prev low surrogate");
    re_input_eq(pos, 3, "non-unicode prev low surrogate steps back one unit");
    pos = 3;
    re_input_eq(wide_plain.prev_code_point(&pos), 0xD83D, "non-unicode prev high surrogate");
    re_input_eq(pos, 2, "non-unicode prev high surrogate steps back one unit");

    // A lone high surrogate is one unit even in unicode mode.
    pos = 1;
    re_input_eq(lone_uni.prev_code_point(&pos), 0xD83D, "lone high surrogate prev");
    re_input_eq(pos, 0, "lone high surrogate prev steps back one unit");
}

fn void re_input_test_predicates() {
    jit::ReInput uni = {
        .data = (char*)re_input_latin1.ptr,
        .len = 4,
        .wide = false,
        .unicode = true,
    };
    jit::ReInput plain = {
        .data = (char*)re_input_latin1.ptr,
        .len = 4,
        .wide = false,
        .unicode = false,
    };

    re_input_eq(uni.canonicalize((uint)'A'), uni.canonicalize((uint)'a'), "canonicalize folds case");
    re_input_eq(plain.canonicalize((uint)'A'), plain.canonicalize((uint)'a'), "canonicalize folds case without unicode");
    re_input_eq(uni.canonicalize((uint)'0'), (uint)'0', "canonicalize leaves digits alone");
    re_input_eq(plain.canonicalize((uint)'0'), (uint)'0', "canonicalize leaves digits alone without unicode");

    re_input_yes(uni.is_space((uint)' '), "space is a space");
    re_input_yes(uni.is_space((uint)'\t'), "tab is a space");
    re_input_yes(uni.is_space((uint)'\n'), "newline is a space");
    re_input_yes(!uni.is_space((uint)'x'), "x is not a space");

    re_input_yes(uni.is_word((uint)'a'), "a is a word byte");
    re_input_yes(uni.is_word((uint)'Z'), "Z is a word byte");
    re_input_yes(uni.is_word((uint)'0'), "0 is a word byte");
    re_input_yes(uni.is_word((uint)'_'), "_ is a word byte");
    re_input_yes(!uni.is_word((uint)'-'), "- is not a word byte");
    re_input_yes(!uni.is_word(256), "a unit above 255 is not a word byte");
}

fn int main() {
    re_input_test_units();
    re_input_test_code_point();
    re_input_test_prev_code_point();
    re_input_test_predicates();

    if (re_input_failures != 0) {
        io::eprintfn("re input: %d failure(s)", re_input_failures);
        return 1;
    }
    io::printn("re input: PASS");
    return 0;
}
