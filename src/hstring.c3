/// Duktape string object (HString) — immutable, interned, UTF-8 strings.
///
/// HStrings are the internal representation for all ECMAScript string values.
/// They are:
///   - Immutable:  once created the byte content never changes.
///   - Interned:   deduplicated through the heap's string table so pointer
///                 equality implies string equality.
///   - Variable-length: the raw UTF-8 bytes are stored immediately after the
///                 struct header in a single contiguous allocation.
///
/// This module defines the HString struct, its bitstruct flags, allocation
/// helpers, a standalone hash function, and various UTF-8 / array-index
/// utilities.
module tinyduck::hstring;

import tinyduck::types;
import tinyduck::heap;
import std::core::mem;
import libc;

// ============================================================================
// Constants
// ============================================================================

/// FNV-1a 32-bit offset basis.
const uint FNV1A_OFFSET_BASIS = 0x811C_9DC5;
/// FNV-1a 32-bit prime.
const uint FNV1A_PRIME        = 0x0100_0193;

/// Maximum valid ECMAScript array index (2^32 - 2).
const uint MAX_ARRIDX = 0xFFFF_FFFE;

/// Sentinel value indicating "not a valid array index".
const uint ARRIDX_NONE = 0xFFFF_FFFF;

/// Maximum bytes for a single UTF-8 encoded codepoint.
const uint MAX_UTF8_BYTES = 4;

/// Unicode replacement character (U+FFFD).
const uint UNICODE_REPLACEMENT = 0xFFFD;

// ============================================================================
// HStringFlags — per-string bit-packed flags
// ============================================================================

/// Bit-packed flags word for HString.
///
/// Bits 0–6 are reserved for HeapHeader-compatible type/GC bits so that a
/// raw cast from HString* to HeapHeader* still reads the correct htype and
/// mark bits.  Bits 7+ carry string-specific metadata.
bitstruct HStringFlags : uint {
    /// HeapHeader-compatible type discriminator (always HType.STRING).
    HType htype             : 0..1;
    /// GC reachable flag (mirrors HeapHeader.flags.reachable).
    bool  reachable         : 2;
    /// GC temporary root flag.
    bool  temproot          : 3;
    /// Finaliser present flag.
    bool  finalizable       : 4;
    /// Finaliser already ran.
    bool  finalized         : 5;
    /// Read-only flag.
    bool  readonly          : 6;

    // --- String-specific flags (bits 7+) ---

    /// All bytes < 0x80: charlen == bytelen.
    bool  is_ascii          : 7;
    /// The string is a valid array index ("0" .. "4294967294").
    bool  is_arridx         : 8;
    /// ES2015 Symbol (internal or well-known).
    bool  is_symbol         : 9;
    /// Duktape hidden Symbol (\xFF prefix).
    bool  is_hidden         : 10;
    /// Strict-mode reserved word.
    bool  is_strict_reserved : 11;
    /// String data lives in an external buffer, not inline.
    bool  has_extdata       : 13;
    /// String has been inserted into the heap's string table.
    bool  is_interned       : 14;
}

// ============================================================================
// HString struct
// ============================================================================

/// Header size in bytes, used to locate the inline string data.
const usz HSTRING_HDR_SIZE = HString::size;

/// A heap-allocated, immutable, interned string.
///
/// The raw UTF-8 bytes are stored immediately after the struct in the same
/// allocation; use `get_data()` to obtain a slice over them.  A NUL
/// terminator is always written past the last byte so the data pointer is
/// safe to hand to C APIs that expect C-strings.
struct HString {
    /// Combined HeapHeader-compatible + string-specific flags.
    HStringFlags flags;
    uint         refcount;
    /// Next pointer in the string table chain (singly-linked).
    HString* next;

    // --- String-specific fields ---

    /// Pre-computed hash (FNV-1a over the raw bytes).
    uint hash;
    /// Byte length of the UTF-8 data (excluding the NUL terminator).
    uint blen;
}

// ============================================================================
// HString — data access
// ============================================================================

/// Returns a slice over the raw UTF-8 bytes stored inline after the header.
///
/// The returned slice has exactly `self.blen` elements.  A NUL terminator
/// sits at `data[blen]` but is *not* included in the slice length.
macro char[] HString.get_data(&self) {
    char* ptr = (char*)((usz)self + HSTRING_HDR_SIZE);
    return ptr[:self.blen];
}

/// Returns a raw C-string pointer to the inline data.  The data is always
/// NUL-terminated.
macro char* HString.get_cstr(&self) {
    return (char*)((usz)self + HSTRING_HDR_SIZE);
}

// ============================================================================
// HString — comparison
// ============================================================================

/// Compares this string's raw bytes with `data`.
///
/// Because strings are interned, callers that already hold two HString
/// pointers should prefer `equals_hstring` (pointer comparison).
fn bool HString.equals(&self, char[] data) {
    if (self.blen != (uint)data.len) {
        return false;
    }
    if (data.len == 0) {
        return true;
    }
    return libc::memcmp(self.get_cstr(), data.ptr, data.len) == 0;
}

/// Compares two HStrings for equality.  When both are interned pointer
/// equality is sufficient (the string table guarantees uniqueness).  When
/// either is non-interned (e.g. a concatenation temporary), compare by
/// content, using the pre-computed hash as a fast-reject.
fn bool HString.equals_hstring(&self, HString* other) {
    if (self == other) return true;
    if (!self.flags.is_interned || !other.flags.is_interned) {
        if (self.blen != other.blen) return false;
        if (self.hash != other.hash) return false;
        return libc::memcmp(self.get_cstr(), other.get_cstr(), self.blen) == 0;
    }
    return false;
}

/// Lexicographic comparison of two HStrings.
///
/// Returns -1 if a < b, 0 if a == b, 1 if a > b, comparing by
/// UTF-8 byte value (which matches code-point ordering for well-formed
/// UTF-8).
fn int hstring_compare(HString* a, HString* b) {
    int min_len = (int)(a.blen < b.blen ? a.blen : b.blen);
    int cmp = libc::memcmp(a.get_cstr(), b.get_cstr(), (usz)min_len);
    if (cmp != 0) return cmp > 0 ? 1 : -1;
    if (a.blen == b.blen) return 0;
    return a.blen > b.blen ? 1 : -1;
}

// ============================================================================
// HString — flag accessors
// ============================================================================

/// Returns `true` when all bytes are in the ASCII range (< 0x80).
fn bool HString.is_ascii(&self)              { return self.flags.is_ascii; }

/// Returns `true` when the string is a valid ECMAScript array index.
fn bool HString.is_arridx(&self)             { return self.flags.is_arridx; }

/// Returns `true` when the string represents an ES2015 Symbol.
fn bool HString.is_symbol(&self)             { return self.flags.is_symbol; }

/// Returns `true` when the string is a Duktape hidden symbol.
fn bool HString.is_hidden(&self)             { return self.flags.is_hidden; }

/// Returns `true` when the string is a strict-mode reserved word.
fn bool HString.is_strict_reserved(&self)    { return self.flags.is_strict_reserved; }

/// Returns `true` when the data resides in an external buffer.
fn bool HString.has_extdata(&self)           { return self.flags.has_extdata; }

/// Returns `true` when the string has been inserted into the heap's string table.
fn bool HString.is_interned(&self)           { return self.flags.is_interned; }

// ============================================================================
// HString — lazy computed fields
// ============================================================================

/// Compute the character (codepoint) length on demand.
///
/// For ASCII strings this equals `blen`.  For multi-byte UTF-8 the bytes
/// are walked once to count codepoints.
fn uint HString.char_length(&self) {
    if (self.flags.is_ascii) return self.blen;
    return compute_charlen(self.get_data());
}

/// Returns the numeric array-index value if this string is a valid array
/// index ("0" .. "4294967294"), or `ARRIDX_NONE` otherwise.
fn uint HString.array_index(&self) {
    if (!self.flags.is_arridx) return ARRIDX_NONE;
    uint idx_val;
    if (is_valid_array_index(self.get_data(), &idx_val)) {
        return idx_val;
    }
    return ARRIDX_NONE;
}

// ============================================================================
// HString — Unicode helpers
// ============================================================================

/// Returns the Unicode codepoint at character index `char_idx`.
///
/// For pure-ASCII strings the operation is O(1).  For multi-byte strings
/// the function scans from the beginning in O(n) where n = char_idx.
/// Returns `UNICODE_REPLACEMENT` if `char_idx >= char_length()`.
fn uint HString.char_at(&self, uint char_idx) {
    if (char_idx >= self.char_length()) {
        return UNICODE_REPLACEMENT;
    }

    char[] data = self.get_data();

    // Fast path for ASCII strings.
    if (self.flags.is_ascii) {
        return (uint)data[char_idx];
    }

    // Slow path: walk UTF-8 sequences.
    uint byte_off = 0;
    uint ci = 0;
    while (ci < char_idx && byte_off < self.blen) {
        byte_off += utf8_seq_len(data[byte_off]);
        ci++;
    }

    if (byte_off >= self.blen) {
        return UNICODE_REPLACEMENT;
    }

    return decode_codepoint(data, byte_off);
}

/// Converts a character (codepoint) offset to a byte offset within the
/// string's UTF-8 data.
///
/// For ASCII strings the two are identical.  Returns `self.blen` when
/// `char_offset` is past the end.
fn uint HString.char_offset_to_byte_offset(&self, uint char_offset) {
    if (self.flags.is_ascii) {
        // 1 byte per character — trivial mapping.
        if (char_offset >= self.blen) {
            return self.blen;
        }
        return char_offset;
    }

    char[] data = self.get_data();
    uint byte_off = 0;
    uint ci = 0;

    while (ci < char_offset && byte_off < self.blen) {
        byte_off += utf8_seq_len(data[byte_off]);
        ci++;
    }

    return byte_off;
}

// ============================================================================
// Allocation
// ============================================================================

/// Allocates and initialises a new HString.
///
/// The allocation is a single block of `HSTRING_HDR_SIZE + data.len + 1`
/// bytes.  The raw bytes from `data` are copied immediately after the
/// struct header and a NUL terminator is appended.
///
/// `heap_ptr` is an opaque pointer to the Heap (cast back by the caller).
/// This function does **not** insert the string into the string table —
/// the caller is responsible for interning.
///
/// Returns the new HString or a fault on allocation failure.
fn HString*? hstring_alloc(void* heap_ptr, char[] data, uint hash) {
    usz total = HSTRING_HDR_SIZE + (usz)data.len + 1;  // +1 for NUL

    void* raw = ((heap::Heap*)heap_ptr).alloc_no_gc(total) ?? null;
    if (raw == null) {
        return tinyduck::types::ALLOC_ERROR~;
    }

    // Zero-fill the header portion.
    libc::memset(raw, 0, HSTRING_HDR_SIZE);

    HString* s = (HString*)raw;

    // --- Header flags ---
    s.flags.htype = HType.STRING;

    // --- Hash & lengths ---
    s.hash = hash;
    s.blen = (uint)data.len;

    bool ascii = check_is_ascii(data);
    s.flags.is_ascii = ascii;

    // --- Array-index detection ---
    uint idx_val;
    if (is_valid_array_index(data, &idx_val)) {
        s.flags.is_arridx = true;
    }

    // --- Symbol / hidden-symbol detection ---
    // Symbols have a 0xFF first byte; hidden symbols have 0xFF 0xFF.
    if (data.len > 0 && (uint)data[0] == 0xFF) {
        s.flags.is_symbol = true;
        if (data.len > 1 && (uint)data[1] == 0xFF) {
            s.flags.is_hidden = true;
        }
    }

    // Reference count starts at 0 — the intern table is a weak reference.
    // The first real user (TVal assignment, shape key, etc.) increfs.
    s.refcount = 0;

    // --- Copy bytes + NUL terminate ---
    char* dest = (char*)((usz)raw + HSTRING_HDR_SIZE);
    if (data.len > 0) {
        libc::memcpy(dest, data.ptr, data.len);
    }
    dest[data.len] = 0;  // NUL terminator

    return s;
}

/// Concatenate two HStrings into a new HString.
///
/// Allocates a single block containing both strings' bytes.
/// Does not insert into the string table — caller must intern.
fn HString*? hstring_concat(void* heap_ptr, HString* a, HString* b) {
    usz a_len = (usz)a.blen;
    usz b_len = (usz)b.blen;
    usz total = HSTRING_HDR_SIZE + a_len + b_len + 1;

    void* raw = ((heap::Heap*)heap_ptr).alloc_no_gc(total) ?? null;
    if (raw == null) {
        return tinyduck::types::ALLOC_ERROR~;
    }

    libc::memset(raw, 0, HSTRING_HDR_SIZE);

    HString* s = (HString*)raw;
    s.flags.htype = HType.STRING;

    s.blen = (uint)(a_len + b_len);

    bool ascii = a.flags.is_ascii && b.flags.is_ascii;
    s.flags.is_ascii = ascii;

    s.hash = 0;  // caller must compute hash before interning

    char* dest = (char*)((usz)raw + HSTRING_HDR_SIZE);
    if (a_len > 0) {
        char* src_a = (char*)((usz)a + HSTRING_HDR_SIZE);
        libc::memcpy(dest, src_a, a_len);
    }
    if (b_len > 0) {
        char* src_b = (char*)((usz)b + HSTRING_HDR_SIZE);
        libc::memcpy(dest + a_len, src_b, b_len);
    }
    dest[a_len + b_len] = 0;

    // Reference count starts at 0 — intern table is a weak reference.
    s.refcount = 0;

    return s;
}

/// Free an HString previously created by `hstring_alloc`.
///
/// The caller must have already removed the string from the string table
/// and any other data structures.
fn void hstring_free(HString* s) {
    if (s == null) { return; }
    // The entire string (header + data + NUL) is one allocation.
    mem::free(s);
}

// ============================================================================
// Standalone hash function
// ============================================================================

/// Compute a 32-bit FNV-1a hash of the raw byte slice `data`.
///
/// This is the non-seeded version suitable for use outside of a heap
/// context (e.g., during bootstrap before the PRNG is initialised).
fn uint hash_string(char[] data) {
    uint h = FNV1A_OFFSET_BASIS;
    foreach (b : data) {
        h ^= (uint)b;
        h *= FNV1A_PRIME;
    }
    return h;
}

/// Compute a seeded 32-bit FNV-1a hash (HashDoS mitigation).
///
/// Mixes `seed` into the initial state so that hash values are
/// unpredictable without knowledge of the seed.
fn uint hash_string_seeded(char[] data, uint seed) {
    uint h = FNV1A_OFFSET_BASIS ^ seed;
    foreach (b : data) {
        h ^= (uint)b;
        h *= FNV1A_PRIME;
    }
    return h;
}

// ============================================================================
// UTF-8 utilities
// ============================================================================

/// Count the number of Unicode codepoints in a UTF-8 byte slice.
///
/// Counts leading bytes only (bytes that are not continuation bytes
/// 0x80..0xBF).  Malformed sequences are tolerated: each unexpected
/// continuation byte is counted as a separate character.
fn uint compute_charlen(char[] data) {
    uint count = 0;
    uint i = 0;
    uint len = (uint)data.len;

    while (i < len) {
        i += utf8_seq_len(data[i]);
        count++;
    }
    return count;
}

/// Returns `true` when every byte in `data` is in the ASCII range (< 0x80).
fn bool check_is_ascii(char[] data) {
    foreach (b : data) {
        if ((uint)b >= 0x80) {
            return false;
        }
    }
    return true;
}

/// Decode a single UTF-8 codepoint starting at `data[offset]`.
///
/// Returns `UNICODE_REPLACEMENT` on malformed input.  Does not advance an
/// offset — the caller is expected to know the sequence length.
fn uint decode_codepoint(char[] data, uint offset) {
    uint len = (uint)data.len;
    if (offset >= len) {
        return UNICODE_REPLACEMENT;
    }

    uint b0 = (uint)data[offset];

    // 1-byte (ASCII)
    if (b0 < 0x80) {
        return b0;
    }

    // 2-byte: 110xxxxx  10xxxxxx
    if ((b0 & 0xE0) == 0xC0) {
        if (offset + 1 >= len) { return UNICODE_REPLACEMENT; }
        uint b1 = (uint)data[offset + 1];
        if ((b1 & 0xC0) != 0x80) { return UNICODE_REPLACEMENT; }
        uint cp = ((b0 & 0x1F) << 6) | (b1 & 0x3F);
        if (cp < 0x80) { return UNICODE_REPLACEMENT; }  // overlong
        return cp;
    }

    // 3-byte: 1110xxxx  10xxxxxx  10xxxxxx
    if ((b0 & 0xF0) == 0xE0) {
        if (offset + 2 >= len) { return UNICODE_REPLACEMENT; }
        uint b1 = (uint)data[offset + 1];
        uint b2 = (uint)data[offset + 2];
        if ((b1 & 0xC0) != 0x80 || (b2 & 0xC0) != 0x80) {
            return UNICODE_REPLACEMENT;
        }
        uint cp = ((b0 & 0x0F) << 12) | ((b1 & 0x3F) << 6) | (b2 & 0x3F);
        if (cp < 0x800) { return UNICODE_REPLACEMENT; }  // overlong
        return cp;
    }

    // 4-byte: 11110xxx  10xxxxxx  10xxxxxx  10xxxxxx
    if ((b0 & 0xF8) == 0xF0) {
        if (offset + 3 >= len) { return UNICODE_REPLACEMENT; }
        uint b1 = (uint)data[offset + 1];
        uint b2 = (uint)data[offset + 2];
        uint b3 = (uint)data[offset + 3];
        if ((b1 & 0xC0) != 0x80 || (b2 & 0xC0) != 0x80 || (b3 & 0xC0) != 0x80) {
            return UNICODE_REPLACEMENT;
        }
        uint cp = ((b0 & 0x07) << 18) | ((b1 & 0x3F) << 12)
                | ((b2 & 0x3F) << 6)  | (b3 & 0x3F);
        if (cp < 0x1_0000 || cp > 0x10_FFFF) { return UNICODE_REPLACEMENT; }
        return cp;
    }

    return UNICODE_REPLACEMENT;
}

/// Encode a Unicode codepoint as UTF-8 into `buf` and return the number of
/// bytes written (1–4).  Returns 0 if the codepoint is out of range or the
/// buffer is too small.
fn uint encode_codepoint(uint cp, char[] buf) {
    if (cp < 0x80) {
        if (buf.len < 1) { return 0; }
        buf[0] = (char)cp;
        return 1;
    }
    if (cp < 0x800) {
        if (buf.len < 2) { return 0; }
        buf[0] = (char)(0xC0 | (cp >> 6));
        buf[1] = (char)(0x80 | (cp & 0x3F));
        return 2;
    }
    if (cp < 0x1_0000) {
        if (buf.len < 3) { return 0; }
        buf[0] = (char)(0xE0 | (cp >> 12));
        buf[1] = (char)(0x80 | ((cp >> 6) & 0x3F));
        buf[2] = (char)(0x80 | (cp & 0x3F));
        return 3;
    }
    if (cp <= 0x10_FFFF) {
        if (buf.len < 4) { return 0; }
        buf[0] = (char)(0xF0 | (cp >> 18));
        buf[1] = (char)(0x80 | ((cp >> 12) & 0x3F));
        buf[2] = (char)(0x80 | ((cp >> 6) & 0x3F));
        buf[3] = (char)(0x80 | (cp & 0x3F));
        return 4;
    }
    return 0;  // out of range
}

// ============================================================================
// Array-index utilities
// ============================================================================

/// Determine whether `data` is a valid ECMAScript array index string.
///
/// Valid array indices are the canonical decimal representations of
/// integers in the range 0 .. 2^32-2 (i.e., "0" through "4294967294").
/// Leading zeros are **not** allowed except for the string "0" itself.
///
/// On success, stores the numeric index in `*out_index` and returns `true`.
fn bool is_valid_array_index(char[] data, uint* out_index) {
    uint len = (uint)data.len;

    // Empty string or unreasonably long — not an index.
    // Max is "4294967294" = 10 digits.
    if (len == 0 || len > 10) {
        return false;
    }

    // Reject leading zeros (except bare "0").
    if (data[0] == '0') {
        if (len == 1) {
            *out_index = 0;
            return true;
        }
        return false;  // leading zero
    }

    // Parse digits, accumulating in a ulong to detect overflow.
    ulong val = 0;
    for (uint i = 0; i < len; i++) {
        uint d = (uint)data[i] - '0';
        if (d > 9) {
            return false;  // non-digit
        }
        val = val * 10 + (ulong)d;
    }

    // Must be ≤ MAX_ARRIDX (0xFFFF_FFFE = 4294967294).
    if (val > (ulong)MAX_ARRIDX) {
        return false;
    }

    *out_index = (uint)val;
    return true;
}

// ============================================================================
// Internal helpers
// ============================================================================

/// Returns the byte length of the UTF-8 sequence that begins with `lead`.
/// Tolerant: returns 1 for unexpected continuation bytes or invalid leads.
fn uint utf8_seq_len(char lead) @inline {
    uint b = (uint)lead;
    if (b < 0x80)          { return 1; }
    if ((b & 0xE0) == 0xC0) { return 2; }
    if ((b & 0xF0) == 0xE0) { return 3; }
    if ((b & 0xF8) == 0xF0) { return 4; }
    return 1;  // unexpected continuation byte — skip one
}

/// Compare two byte slices for equality.
fn bool bytes_eq(char[] a, char[] b) @inline {
    if (a.len != b.len) { return false; }
    if (a.len == 0) { return true; }
    return libc::memcmp(a.ptr, b.ptr, a.len) == 0;
}

/// Fast integer-to-buffer conversion — writes decimal digits into buf.
/// Returns the number of bytes written (excluding NUL), or 0 on overflow.
/// buf must have capacity >= 2 bytes; 21 bytes suffices for any int64.
fn int int_to_buf(long val, char* buf, usz cap) {
    if (cap < 2) return 0;
    usz pos = cap;
    bool neg = false;
    if (val < 0) {
        neg = true;
        val = -val;
    }
    ulong uval = (ulong)val;
    do {
        if (pos == 0) return 0;
        pos--;
        buf[pos] = (char)('0' + (uval % 10));
        uval /= 10;
    } while (uval != 0);
    if (neg) {
        if (pos == 0) return 0;
        pos--;
        buf[pos] = '-';
    }
    usz len = cap - pos;
    if (pos > 0) {
        libc::memmove(buf, buf + pos, len);
    }
    return (int)len;
}
