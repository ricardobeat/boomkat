// The subject string a native regexp matcher walks.
//
// libregexp hands the matcher one of two forms: Latin-1 bytes, one code unit
// per byte, or native-endian UTF-16 code units. In unicode mode (the u or v
// flag) a surrogate pair counts as one code point. Every position the matcher
// records stays a code-unit index, never a byte index.
module boomkat::jit @feat(SLJIT);

import boomkat::re_bindings;

struct ReInput {
    char* data;     // the subject: Latin-1 bytes, or UTF-16 code units, native endian
    uint  len;      // length in code units
    bool  wide;     // data holds 16-bit units
    bool  unicode;  // u or v flag: a surrogate pair is one code point
}

// The code unit at pos, or 0 past the end of the subject.
fn uint ReInput.unit(&self, uint pos) @inline {
    if (pos >= self.len) return 0;
    return self.wide ? (uint)((ushort*)self.data)[pos] : (uint)self.data[pos];
}

// The code point starting at *pos, advancing *pos past it. A high surrogate
// followed by a low surrogate is one code point over two units in unicode
// mode, and two separate units otherwise.
fn uint ReInput.code_point(&self, uint* pos) {
    if (*pos >= self.len) return 0;
    uint c = self.unit(*pos);
    if (self.unicode && (c >> 10) == (0xD800 >> 10)) {
        uint lo = self.unit(*pos + 1);
        if ((lo >> 10) == (0xDC00 >> 10)) {
            *pos += 2;
            return 65536 + 1024 * (c & 1023) + (lo & 1023);
        }
    }
    *pos += 1;
    return c;
}

// The code point ending just before *pos, moving *pos back onto its first
// unit. A surrogate pair is only recombined in unicode mode.
fn uint ReInput.prev_code_point(&self, uint* pos) {
    if (*pos == 0) return 0;
    uint c = self.unit(*pos - 1);
    if (self.unicode && (c >> 10) == (0xDC00 >> 10) && *pos >= 2) {
        uint hi = self.unit(*pos - 2);
        if ((hi >> 10) == (0xD800 >> 10)) {
            *pos -= 2;
            return 65536 + 1024 * (hi & 1023) + (c & 1023);
        }
    }
    *pos -= 1;
    return c;
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
