// Self-tests for the native regexp matcher's class test and its zero-width
// assertions: the class range search, the case-folding forms, the line
// terminators in both subject forms, and the word boundary rules.
module re_class_test;

import boomkat::jit;
import boomkat::re_bindings;
import std::io;

int failures = 0;

fn void expect(bool ok, String what) {
    if (!ok) {
        failures++;
        io::eprintfn("re class: FAIL %s", what);
    }
}

// The same, but with the form the check belongs to named in front of it.
fn void expect_at(bool ok, String label, String what) {
    if (!ok) {
        failures++;
        io::eprintfn("re class: FAIL %s: %s", label, what);
    }
}

// The class range search: one pair, several pairs, both bounds of every pair
// and the units just outside them, and the empty class.
fn void test_class_matches() {
    uint[2] one = { 0x61, 0x7A };
    jit::ReClass single = { .pairs = &one[0], .count = 1, .ignore_case = false, .unicode = false };
    expect(single.matches(0x61), "single: low bound");
    expect(single.matches(0x7A), "single: high bound");
    expect(single.matches(0x6D), "single: inside");
    expect(!single.matches(0x60), "single: just below");
    expect(!single.matches(0x7B), "single: just above");

    uint[6] many = { 0x30, 0x39, 0x41, 0x5A, 0x61, 0x7A };
    jit::ReClass multi = { .pairs = &many[0], .count = 3, .ignore_case = false, .unicode = false };
    expect(multi.matches(0x30) && multi.matches(0x39), "multi: digit pair");
    expect(!multi.matches(0x2F) && !multi.matches(0x3A), "multi: outside digit pair");
    expect(multi.matches(0x41) && multi.matches(0x5A), "multi: upper pair");
    expect(!multi.matches(0x40) && !multi.matches(0x5B), "multi: outside upper pair");
    expect(multi.matches(0x61) && multi.matches(0x7A), "multi: lower pair");
    expect(!multi.matches(0x60) && !multi.matches(0x7B), "multi: outside lower pair");
    expect(!multi.matches(0x20) && !multi.matches(0x00), "multi: outside every pair");

    jit::ReClass empty = { .pairs = null, .count = 0, .ignore_case = false, .unicode = false };
    expect(!empty.matches(0x00), "empty: matches nothing");
    expect(!empty.matches(0x61), "empty: matches nothing (letter)");
}

// Whether a unit falls inside a pair, spelled out here so the canonicalizing
// forms can be checked against it.
fn bool in_pair(uint* pairs, uint unit) {
    return unit >= pairs[0] && unit <= pairs[1];
}

// The ignore-case form canonicalizes the unit before the search. Which way
// the fold goes is not assumed: the upper and the lower case member of a
// letter have to agree with each other, and the answer has to agree with the
// canonicalized unit falling inside the pair.
fn void test_class_ignore_case() {
    uint[2] lower = { 0x61, 0x7A };
    uint[2] upper = { 0x41, 0x5A };

    jit::ReClass plain_lower = { .pairs = &lower[0], .count = 1, .ignore_case = false, .unicode = false };
    jit::ReClass plain_upper = { .pairs = &upper[0], .count = 1, .ignore_case = false, .unicode = false };
    expect(plain_lower.matches(0x61) && !plain_lower.matches(0x41), "plain: the exact pair only");
    expect(plain_upper.matches(0x41) && !plain_upper.matches(0x61), "plain: the exact pair only (upper)");

    jit::ReClass fold_unicode_lower = { .pairs = &lower[0], .count = 1, .ignore_case = true, .unicode = true };
    jit::ReClass fold_unicode_upper = { .pairs = &upper[0], .count = 1, .ignore_case = true, .unicode = true };
    jit::ReClass fold_legacy_lower = { .pairs = &lower[0], .count = 1, .ignore_case = true, .unicode = false };
    jit::ReClass fold_legacy_upper = { .pairs = &upper[0], .count = 1, .ignore_case = true, .unicode = false };

    // The two case members of a letter must land on the same answer.
    expect(fold_unicode_lower.matches(0x41) == fold_unicode_lower.matches(0x61), "unicode fold: the case members agree (lower pair)");
    expect(fold_unicode_upper.matches(0x41) == fold_unicode_upper.matches(0x61), "unicode fold: the case members agree (upper pair)");
    expect(fold_legacy_lower.matches(0x41) == fold_legacy_lower.matches(0x61), "legacy fold: the case members agree (lower pair)");
    expect(fold_legacy_upper.matches(0x41) == fold_legacy_upper.matches(0x61), "legacy fold: the case members agree (upper pair)");

    // The answer is the one the canonicalized unit gives, whatever the fold
    // direction turns out to be.
    expect(fold_unicode_lower.matches(0x41) == in_pair(&lower[0], re_bindings::re_canonicalize(0x41, true)), "unicode fold: the canonicalized unit decides (lower pair)");
    expect(fold_unicode_upper.matches(0x41) == in_pair(&upper[0], re_bindings::re_canonicalize(0x41, true)), "unicode fold: the canonicalized unit decides (upper pair)");
    expect(fold_legacy_lower.matches(0x41) == in_pair(&lower[0], re_bindings::re_canonicalize(0x41, false)), "legacy fold: the canonicalized unit decides (lower pair)");
    expect(fold_legacy_upper.matches(0x41) == in_pair(&upper[0], re_bindings::re_canonicalize(0x41, false)), "legacy fold: the canonicalized unit decides (upper pair)");

    // Folding cannot leave the case-sensitive answer alone.
    expect(fold_unicode_lower.matches(0x61) != plain_lower.matches(0x61) || fold_unicode_lower.matches(0x41) != plain_lower.matches(0x41), "unicode fold: differs from the plain form");
    expect(fold_legacy_lower.matches(0x61) != plain_lower.matches(0x61) || fold_legacy_lower.matches(0x41) != plain_lower.matches(0x41), "legacy fold: differs from the plain form");
}

// The line assertions over one subject, in both the Latin-1 and the UTF-16
// form: the same expectations have to hold for both.
fn void check_line_assertions(jit::ReInput subject, String label) {
    expect_at(subject.line_start_at(0, false), label, "line start at 0");
    expect_at(subject.line_start_at(0, true), label, "line start at 0 (multiline)");
    expect_at(!subject.line_start_at(1, false), label, "no line start at 1");
    expect_at(!subject.line_start_at(1, true), label, "no line start at 1 (multiline)");
    expect_at(!subject.line_start_at(2, false), label, "no line start at 2");
    expect_at(!subject.line_start_at(2, true), label, "no line start at 2 (multiline)");
    expect_at(!subject.line_start_at(3, false), label, "no line start at 3");
    expect_at(subject.line_start_at(3, true), label, "line start after LF");
    expect_at(!subject.line_start_at(4, false), label, "no line start at 4");
    expect_at(!subject.line_start_at(4, true), label, "no line start at 4 (multiline)");
    expect_at(!subject.line_start_at(5, false), label, "no line start at 5");
    expect_at(!subject.line_start_at(5, true), label, "no line start at 5 (multiline)");
    expect_at(!subject.line_start_at(6, false), label, "no line start at the end");
    expect_at(subject.line_start_at(6, true), label, "line start after CR");

    expect_at(!subject.line_end_at(0, false), label, "no line end at 0");
    expect_at(!subject.line_end_at(0, true), label, "no line end at 0 (multiline)");
    expect_at(!subject.line_end_at(1, false), label, "no line end at 1");
    expect_at(!subject.line_end_at(1, true), label, "no line end at 1 (multiline)");
    expect_at(!subject.line_end_at(2, false), label, "no line end at 2");
    expect_at(subject.line_end_at(2, true), label, "line end before LF");
    expect_at(!subject.line_end_at(3, false), label, "no line end at 3");
    expect_at(!subject.line_end_at(3, true), label, "no line end at 3 (multiline)");
    expect_at(!subject.line_end_at(4, false), label, "no line end at 4");
    expect_at(!subject.line_end_at(4, true), label, "no line end at 4 (multiline)");
    expect_at(!subject.line_end_at(5, false), label, "no line end at 5");
    expect_at(subject.line_end_at(5, true), label, "line end before CR");
    expect_at(subject.line_end_at(6, false), label, "line end at the end");
    expect_at(subject.line_end_at(6, true), label, "line end at the end (multiline)");
}

// A subject with an LF and a CR in it, in both forms.
fn void test_line_assertions() {
    char[6] latin1 = { 'a', 'b', '\n', 'c', 'd', '\r' };
    jit::ReInput narrow = { .data = &latin1[0], .len = 6, .wide = false };
    check_line_assertions(narrow, "latin1");

    ushort[6] wide = { 'a', 'b', '\n', 'c', 'd', '\r' };
    jit::ReInput utf16 = { .data = (char*)&wide[0], .len = 6, .wide = true };
    check_line_assertions(utf16, "utf16");
}

// The line separators U+2028 and U+2029 only exist in the wide form.
fn void test_line_separators() {
    ushort[5] units = { 'a', 0x2028, 'b', 0x2029, 'c' };
    jit::ReInput subject = { .data = (char*)&units[0], .len = 5, .wide = true };

    expect(!subject.line_start_at(1, false), "U+2028: no line start without multiline");
    expect(!subject.line_start_at(2, false), "U+2028: no line start at 2 without multiline");
    expect(subject.line_start_at(2, true), "U+2028: line start after U+2028");
    expect(subject.line_start_at(4, true), "U+2029: line start after U+2029");
    expect(!subject.line_start_at(3, true), "U+2028: no line start after a plain letter");

    expect(!subject.line_end_at(1, false), "U+2028: no line end without multiline");
    expect(subject.line_end_at(1, true), "U+2028: line end before U+2028");
    expect(subject.line_end_at(3, true), "U+2029: line end before U+2029");
    expect(!subject.line_end_at(2, true), "U+2028: no line end after a plain letter");
}

// The word boundary rules over one subject, in both forms.
fn void check_word_boundaries(jit::ReInput subject, String label) {
    // The subject is "abc-de": the dash sits at index 3.
    expect_at(subject.word_boundary_at(0, false), label, "boundary at the start of a word");
    expect_at(!subject.word_boundary_at(1, false), label, "no boundary inside a word");
    expect_at(!subject.word_boundary_at(2, false), label, "no boundary inside a word (2)");
    expect_at(subject.word_boundary_at(3, false), label, "boundary at the end of a word");
    expect_at(subject.word_boundary_at(4, false), label, "boundary after the dash");
    expect_at(!subject.word_boundary_at(5, false), label, "no boundary inside the last word");
    expect_at(subject.word_boundary_at(6, false), label, "boundary at the end of the subject");
    expect_at(subject.word_boundary_at(6, true), label, "boundary at the end of the subject (ignore case)");
}

fn void test_word_boundary() {
    char[6] latin1 = { 'a', 'b', 'c', '-', 'd', 'e' };
    jit::ReInput narrow = { .data = &latin1[0], .len = 6, .wide = false };
    check_word_boundaries(narrow, "latin1");

    ushort[6] wide = { 'a', 'b', 'c', '-', 'd', 'e' };
    jit::ReInput utf16 = { .data = (char*)&wide[0], .len = 6, .wide = true };
    check_word_boundaries(utf16, "utf16");
}

// The underscore is a word character, so it never breaks a word run.
fn void test_underscore_is_a_word() {
    char[3] subject = { 'a', '_', 'b' };
    jit::ReInput s = { .data = &subject[0], .len = 3, .wide = false };
    expect(s.word_boundary_at(0, false), "underscore: boundary at the start");
    expect(!s.word_boundary_at(1, false), "underscore: no boundary before the underscore");
    expect(!s.word_boundary_at(2, false), "underscore: no boundary after the underscore");
    expect(s.word_boundary_at(3, false), "underscore: boundary at the end");
}

// Above 255 only the two case-folding non-ASCII letters are word characters,
// and only in the ignore-case form.
fn void test_non_ascii_word_units() {
    ushort[2] units = { 'a', 0x017F };
    jit::ReInput s = { .data = (char*)&units[0], .len = 2, .wide = true };
    expect(s.word_boundary_at(1, false), "U+017F: boundary without ignore case");
    expect(!s.word_boundary_at(1, true), "U+017F: no boundary with ignore case");

    ushort[2] kelvin = { 'a', 0x212A };
    jit::ReInput k = { .data = (char*)&kelvin[0], .len = 2, .wide = true };
    expect(k.word_boundary_at(1, false), "U+212A: boundary without ignore case");
    expect(!k.word_boundary_at(1, true), "U+212A: no boundary with ignore case");

    // A non-ASCII letter that does not case fold is never a word character.
    ushort[2] eacute = { 'a', 0x00E9 };
    jit::ReInput e = { .data = (char*)&eacute[0], .len = 2, .wide = true };
    expect(e.word_boundary_at(1, false), "U+00E9: boundary without ignore case");
    expect(e.word_boundary_at(1, true), "U+00E9: boundary with ignore case");
}

fn int main() {
    test_class_matches();
    test_class_ignore_case();
    test_line_assertions();
    test_line_separators();
    test_word_boundary();
    test_underscore_is_a_word();
    test_non_ascii_word_units();
    if (failures > 0) {
        io::eprintfn("re class: %d failure(s)", failures);
        return 1;
    }
    io::printn("re class: PASS");
    return 0;
}
