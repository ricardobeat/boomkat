// The subject string a native regexp matcher walks.
//
// libregexp hands the matcher one of two forms: Latin-1 bytes, one code unit
// per byte, or native-endian UTF-16 code units. In unicode mode (the u or v
// flag) a surrogate pair counts as one code point. Every position the matcher
// records stays a code-unit index, never a byte index.
module boomkat::re_native @feat(!NO_REGEXP);

import boomkat::re_bindings;

struct ReInput {
    char* data;     // the subject: Latin-1 bytes, or UTF-16 code units, native endian
    uint  len;      // length in code units
    bool  wide;     // data holds 16-bit units
    bool  unicode;  // u or v flag: a surrogate pair is one code point
}

const uint RE_HIGH_SURROGATE_FIRST = 0xD800;
const uint RE_HIGH_SURROGATE_LAST = 0xDBFF;
const uint RE_LOW_SURROGATE_FIRST = 0xDC00;
const uint RE_LOW_SURROGATE_LAST = 0xDFFF;

fn bool re_is_high_surrogate(uint c) @inline => c >= RE_HIGH_SURROGATE_FIRST && c <= RE_HIGH_SURROGATE_LAST;

fn bool re_is_low_surrogate(uint c) @inline => c >= RE_LOW_SURROGATE_FIRST && c <= RE_LOW_SURROGATE_LAST;

// The line terminators of the language: LF, CR and the two Unicode separators.
fn bool re_is_line_terminator(uint c) @inline {
    return c == (uint)'\n' || c == (uint)'\r' || c == 0x2028 || c == 0x2029;
}

// The code unit at pos, or 0 past the end of the subject.
//
// The hot loops take the fields as arguments rather than through the struct, so
// that the subject form and the length stay in registers across an iteration.
fn uint re_unit_at(char* data, bool wide, uint len, uint pos) @inline {
    if (pos >= len) return 0;
    return wide ? (uint)((ushort*)data)[pos] : (uint)data[pos];
}

fn uint ReInput.unit(&self, uint pos) @inline => re_unit_at(self.data, self.wide, self.len, pos);

// The code point starting at *pos, advancing *pos past it. A high surrogate
// followed by a low surrogate is one code point over two units in unicode
// mode, and two separate units otherwise.
fn uint re_code_point_at(char* data, bool wide, bool unicode, uint len, uint* pos) @inline {
    if (*pos >= len) return 0;
    uint c = re_unit_at(data, wide, len, *pos);
    // Only a wide subject can hold a surrogate pair; a Latin-1 unit never does.
    if (unicode && wide && re_is_high_surrogate(c)) {
        uint lo = re_unit_at(data, wide, len, *pos + 1);
        if (re_is_low_surrogate(lo)) {
            *pos += 2;
            return 0x10000 + ((c - RE_HIGH_SURROGATE_FIRST) << 10) + (lo - RE_LOW_SURROGATE_FIRST);
        }
    }
    *pos += 1;
    return c;
}

fn uint ReInput.code_point(&self, uint* pos) @inline {
    return re_code_point_at(self.data, self.wide, self.unicode, self.len, pos);
}

// The code point ending just before *pos, moving *pos back onto its first
// unit. A surrogate pair is only recombined in unicode mode.
fn uint re_prev_code_point_at(char* data, bool wide, bool unicode, uint* pos) @inline {
    if (*pos == 0) return 0;
    uint c = re_unit_at(data, wide, *pos, *pos - 1);
    if (unicode && wide && re_is_low_surrogate(c) && *pos >= 2) {
        uint hi = re_unit_at(data, wide, *pos, *pos - 2);
        if (re_is_high_surrogate(hi)) {
            *pos -= 2;
            return 0x10000 + ((hi - RE_HIGH_SURROGATE_FIRST) << 10) + (c - RE_LOW_SURROGATE_FIRST);
        }
    }
    *pos -= 1;
    return c;
}

fn uint ReInput.prev_code_point(&self, uint* pos) @inline {
    return re_prev_code_point_at(self.data, self.wide, self.unicode, pos);
}

fn bool ReInput.at_end(&self, uint pos) @inline {
    return pos >= self.len;
}

fn uint ReInput.canonicalize(&self, uint c) @inline {
    return re_bindings::re_canonicalize(c, self.unicode);
}

fn bool ReInput.is_space(&self, uint c) @inline {
    return re_bindings::re_is_space(c);
}

fn bool ReInput.is_word(&self, uint c) @inline {
    return re_bindings::re_is_word_byte(c);
}
