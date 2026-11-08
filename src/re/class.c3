// The regexp matcher's class test and the assertions that read the subject:
// one code unit against a class instruction's range pairs, plus line start,
// line end and word boundary. Mirrors vendor/libregexp/libregexp.c.
module boomkat::re_native @feat(!NO_REGEXP);

import boomkat::re_bindings;

// A class instruction's ranges: ascending, disjoint and inclusive on both
// ends, in code points. The pairs are borrowed from the program.
struct ReClass {
    uint* pairs;       // low, high, low, high ... inclusive, ascending; borrowed
    uint  count;       // number of pairs
    bool  ignore_case; // the _i form: canonicalize the unit before the test
    bool  unicode;     // canonicalization mode for the _i form
    // The 16-bit form writes 0xffff as a pair's high bound to mean "and every
    // code point above it", mirroring libregexp's range test.
    bool  unbounded;
}

// A word character at the unit level: below 256 the ASCII word set, and above
// it only the two non-ASCII letters that case-fold to ASCII word characters,
// which the engine counts only in the ignore-case form.
fn bool re_is_word_unit(uint c, bool ignore_case) @inline {
    if (c < 256) return re_bindings::re_is_word_byte(c);
    return ignore_case && (c == 0x017F || c == 0x212A);
}

// Whether the code point falls inside one of the class' range pairs. It is
// canonicalized first in the ignore-case form; the pairs are used as they
// come from the program.
fn bool ReClass.matches(&self, uint cp) {
    if (self.count == 0) return false;
    if (self.ignore_case) {
        cp = re_bindings::re_canonicalize(cp, self.unicode);
    }
    if (self.unbounded && cp >= 0xffff && self.pairs[(self.count - 1) * 2 + 1] == 0xffff) return true;
    uint lo = 0;
    uint hi = self.count;
    while (lo < hi) {
        uint mid = lo + (hi - lo) / 2;
        uint low = self.pairs[mid * 2];
        uint high = self.pairs[mid * 2 + 1];
        if (cp < low) {
            hi = mid;
        } else if (cp > high) {
            lo = mid + 1;
        } else {
            return true;
        }
    }
    return false;
}

// Whether pos sits at the start of a line: at the very start of the subject,
// or, in multiline mode, just after a line terminator.
fn bool ReInput.line_start_at(&self, uint pos, bool multiline) {
    if (pos == 0) return true;
    if (!multiline) return false;
    return re_is_line_terminator(self.unit(pos - 1));
}

// Whether pos sits at the end of a line: at the very end of the subject, or,
// in multiline mode, just before a line terminator.
fn bool ReInput.line_end_at(&self, uint pos, bool multiline) {
    if (pos == self.len) return true;
    if (!multiline) return false;
    return re_is_line_terminator(self.unit(pos));
}

// Whether pos is a word boundary: exactly one of the code points around it is
// a word character.
fn bool ReInput.word_boundary_at(&self, uint pos, bool ignore_case) {
    bool after = pos < self.len && re_is_word_unit(self.unit(pos), ignore_case);
    bool before = pos > 0 && re_is_word_unit(self.unit(pos - 1), ignore_case);
    return before != after;
}
