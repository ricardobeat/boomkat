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
module duktape::hstring;

import duktape::types;
import duktape::heap;
import std::core::mem;

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

/// Sentinel for `HString.registry_slot`: the string holds no slot in the
/// heap's large-string registry.
const uint REGISTRY_SLOT_NONE = (uint)-1;

/// Sentinel for `HString.cached_charlen`: the character length has not yet
/// been computed for this string.
const uint CHARLEN_NONE = (uint)-1;

/// Sentinel used by `scan_backwards_n` to signal a back-walk that ran past
/// the start of the string (malformed UTF-8 input with a "wasted" character
/// length that outruns the byte sequence).
const uint SCAN_UNDERFLOW = (uint)-1;

/// Unicode replacement character (U+FFFD).
const uint UNICODE_REPLACEMENT = 0xFFFD;

/// First/last UTF-16 high (lead) surrogate codepoint.
const uint SURROGATE_HIGH_START = 0xD800;
const uint SURROGATE_HIGH_END   = 0xDBFF;
/// First/last UTF-16 low (trail) surrogate codepoint.
const uint SURROGATE_LOW_START  = 0xDC00;
const uint SURROGATE_LOW_END    = 0xDFFF;
/// First astral (non-BMP) codepoint — requires a surrogate pair in UTF-16.
const uint ASTRAL_START         = 0x1_0000;

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
    /// Slot held by a non-interned string in the heap's large-string
    /// registry, or `REGISTRY_SLOT_NONE` when the string is interned (the
    /// string table tracks those instead) or registration was declined.
    uint registry_slot;

    // --- String-specific fields ---

    /// Pre-computed hash (FNV-1a over the raw bytes).  Interned strings use
    /// it to index the string table; non-interned strings still need it as
    /// the fast-reject in `equals_hstring`, so it always holds the real
    /// content hash.
    uint hash;
    /// Byte length of the UTF-8 data (excluding the NUL terminator).
    uint blen;
    /// Cached character (UTF-16 code unit) length, or `CHARLEN_NONE` when
    /// not yet computed.  ASCII strings never populate this — `blen` is
    /// already the char length for them.  Write-once: strings are
    /// immutable, so the cache never needs invalidating.
    /// Cached character (UTF-16 code unit) length, or `CHARLEN_NONE` when
    /// not yet computed.  ASCII strings never populate this — `blen` is
    /// already the char length for them.  Write-once: strings are
    /// immutable, so the cache never needs invalidating.
    uint cached_charlen;
    /// Cached character offset for non-ASCII sequential scanning.
    uint cached_char_offset;
    /// Cached byte offset corresponding to `cached_char_offset`.
    uint cached_byte_offset;
}

/// Sets the temproot flag on this string.
fn void HString.set_temproot(&self) @inline {
    ((types::HeapHeader*)self).set_temproot();
}

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
    return mem::equals(self.get_cstr(), data.ptr, data.len);
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
        return mem::equals(self.get_cstr(), other.get_cstr(), self.blen);
    }
    return false;
}

/// Three-way byte comparison over `n` bytes: -1, 0, or 1.
fn int byte_compare(char* a, char* b, usz n) @local {
    for (usz i = 0; i < n; i++) {
        if (a[i] != b[i]) return a[i] < b[i] ? -1 : 1;
    }
    return 0;
}

/// Lexicographic comparison of two HStrings.
///
/// Returns -1 if a < b, 0 if a == b, 1 if a > b, comparing by
/// UTF-8 byte value (which matches code-point ordering for well-formed
/// UTF-8).
fn int hstring_compare(HString* a, HString* b) {
    int min_len = (int)(a.blen < b.blen ? a.blen : b.blen);
    int cmp = byte_compare(a.get_cstr(), b.get_cstr(), (usz)min_len);
    if (cmp != 0) return cmp;
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
/// are walked once to count codepoints and the result is cached — strings
/// are immutable, so the cache never needs invalidating.
fn uint HString.char_length(&self) {
    if (self.flags.is_ascii) return self.blen;
    if (self.cached_charlen != CHARLEN_NONE) return self.cached_charlen;
    uint clen = compute_charlen(self.get_data());
    self.cached_charlen = clen;
    self.cached_char_offset = clen;
    self.cached_byte_offset = self.blen;
    return clen;
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
    return self.char_at_unchecked(char_idx);
}

/// Same as `char_at`, but skips the bounds check against `char_length()`.
///
/// Only call this when the caller has already established
/// `char_idx < char_length()` (or an equivalent bound) — otherwise the walk
/// may run past the end of the string. Saves a redundant (possibly O(n))
/// `char_length()` call when the caller already has the length in hand.
fn uint HString.char_at_unchecked(&self, uint char_idx) {
    char[] data = self.get_data();

    // Fast path for ASCII strings.
    if (self.flags.is_ascii) {
        return (uint)data[char_idx];
    }

    uint byte_off = self.char_offset_to_byte_offset(char_idx);
    if (byte_off >= self.blen) {
        return UNICODE_REPLACEMENT;
    }

    return decode_codepoint(data, byte_off);
}

/// Converts a character (UTF-16 code-unit) offset to a byte offset within the
/// string's UTF-8 data.
///
/// Strategy, in order:
///   1. ASCII fast path — 1 byte per character.
///   2. Exact cursor-cache hit — single field load.
///   3. Pick the nearest scan origin among:
///      * string start (forward scan)
///      * string end   (backward scan — Duktape's scan-from-nearest-end trick)
///      * cache entry  (forward *or* backward depending on direction)
///      and walk the shortest distance. Each step skips continuation bytes
///      (0x80..0xBF), matching `compute_charlen` and `utf8_seq_len`.
///
/// Returns `self.blen` for `char_offset >= char_length()`. Strings are
/// immutable so the cache is never invalidated — only updated.
fn uint HString.char_offset_to_byte_offset(&self, uint char_offset) {
    if (self.flags.is_ascii) {
        // ASCII: 1 byte per character — trivial mapping.
        if (char_offset >= self.blen) {
            return self.blen;
        }
        return char_offset;
    }

    // Exact cache hit.
    if (char_offset == self.cached_char_offset) {
        return self.cached_byte_offset;
    }

    char[] data = self.get_data();
    uint blen = self.blen;

    // Find a scan origin. The cache's initial state is (0, 0), so a fresh
    // string (cache never warmed) behaves like "scan from start". Until
    // char_length() is called, cached_char_offset is still 0.
    uint char_length = self.char_length();

    // Out-of-range: clamp to end.
    if (char_offset >= char_length) {
        // Update cache so a follow-up char_length()/end lookup is O(1).
        self.cached_char_offset = char_length;
        self.cached_byte_offset = blen;
        return blen;
    }

    // Compute distances from {start, end, cache} to the target. Use uint
    // saturating subtraction; clen>char_offset and bidirectional compares
    // make this well-defined.
    uint dist_start = char_offset;
    uint dist_end = char_length - char_offset;
    uint dist_cache = char_offset > self.cached_char_offset
        ? char_offset - self.cached_char_offset
        : self.cached_char_offset - char_offset;

    uint byte_off;
    bool cache_usable = self.cached_byte_offset <= blen
                     && dist_cache <= dist_start
                     && dist_cache <= dist_end;
    if (cache_usable) {
        if (char_offset > self.cached_char_offset) {
            byte_off = scan_forwards_n(data, self.cached_byte_offset, blen, dist_cache);
        } else {
            byte_off = scan_backwards_n(data, self.cached_byte_offset, dist_cache);
        }
    } else if (dist_start <= dist_end) {
        byte_off = scan_forwards_n(data, 0, blen, dist_start);
    } else {
        byte_off = scan_backwards_n(data, blen, dist_end);
    }

    // Defensive fallback: malformed UTF-8 may diverge (a lone continuation
    // byte is treated as a 1-char unit by utf8_seq_len/compute_charlen but
    // missed by the backward-scanner's "non-continuation byte" test). In
    // practice this is rare — internal strings are normalized to CESU-8 at
    // intern time — but if a scan runs past one end, fall back to a fresh
    // forward walk that matches compute_charlen.
    if (byte_off == SCAN_UNDERFLOW || byte_off > blen) {
        byte_off = 0;
        for (uint ci = 0; ci < char_offset && byte_off < blen; ci++) {
            byte_off += utf8_seq_len(data[byte_off]);
        }
    }

    // Cache the result.
    self.cached_char_offset = char_offset;
    self.cached_byte_offset = byte_off;
    return byte_off;
}

/// Advance the cursor forward by exactly `n` non-continuation bytes
/// (UTF-16 code units under CESU-8), starting at `start`.
///
/// `start` must be a character-start byte offset (i.e. on a valid start byte
/// or `0` / `blen`). Returns the byte offset of the (n+1)-th character, or
/// `blen + 1` as an out-of-bounds sentinel when the scan ran past `blen`.
/// Sentinel value chosen so a single `> blen` check distinguishes "scan
/// overshoot" from "scanned to the very end" without aliasing either.
fn uint scan_forwards_n(char[] data, uint start, uint blen, uint n) @local {
    uint p = start;
    while (n > 0) {
        // 1 step forward, then skip continuation bytes.
        if (p >= blen) { return blen + 1; }
        p++;
        while (p < blen && ((uint)data[p] & 0xC0) == 0x80) { p++; }
        n--;
    }
    return p;
}

/// Step the cursor backward by exactly `n` non-continuation bytes (UTF-16
/// code units), starting at `start`. `start` must be a character-start byte
/// offset. Returns the byte offset of the n-th previous character start, or
/// `SCAN_UNDERFLOW` (UINT_MAX) if the walk ran past offset 0. The sentinel
/// lies outside any plausible cache value (always <= blen) so the caller can
/// detect it without a separate flag.
fn uint scan_backwards_n(char[] data, uint start, uint n) @local {
    uint p = start;
    while (n > 0) {
        if (p == 0) { return SCAN_UNDERFLOW; }
        p--;
        while (p > 0 && ((uint)data[p] & 0xC0) == 0x80) { p--; }
        n--;
    }
    return p;
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
        return duktape::types::ALLOC_ERROR~;
    }

    // Zero-fill the header portion.
    mem::clear(raw, (sz)(HSTRING_HDR_SIZE));

    HString* s = (HString*)raw;

    // --- Header flags ---
    s.flags.htype = HType.STRING;

    // --- Hash & lengths ---
    s.hash = hash;
    s.blen = (uint)data.len;

    // Unregistered until the caller decides the string needs a registry slot.
    s.registry_slot = REGISTRY_SLOT_NONE;
    // Charlen is computed lazily on first char_length() call.
    s.cached_charlen = CHARLEN_NONE;

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
        mem::copy(dest, data.ptr, (sz)(data.len));
    }
    dest[data.len] = 0;  // NUL terminator

    return s;
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
// UTF-16 code-unit / CESU-8 utilities
//
// ECMAScript strings are sequences of UTF-16 code units (spec: "String
// value" is a finite ordered sequence of 16-bit unsigned integers), not
// Unicode codepoints. Astral codepoints (>= U+10000) are represented in
// source/property/index semantics as a *pair* of surrogate code units.
//
// Internally we still store bytes as UTF-8-shaped sequences (so ASCII stays
// a fast 1-byte-per-unit path and non-BMP text stays readable to any tool
// that tolerates CESU-8), but every codepoint >= U+10000 is decomposed into
// its two surrogate halves *before* encoding, and each half is encoded as
// an independent 3-byte UTF-8 sequence (this is exactly CESU-8/WTF-8).
// Lone surrogates (unpaired half from \uD800-\uDFFF, e.g. via \u{D800}
// escapes) round-trip the same way — spec strings permit them.
//
// char_length()/char_at()/char_offset_to_byte_offset() therefore count and
// index by UTF-16 code unit: a 3-byte sequence in the D800-DFFF range
// counts as one unit (a surrogate half), matching `"\u{1F600}".length === 2`.
// ============================================================================

/// True when `cp` is a UTF-16 surrogate codepoint (high or low half).
fn bool is_surrogate(uint cp) @inline {
    return cp >= SURROGATE_HIGH_START && cp <= SURROGATE_LOW_END;
}

/// True when `cp` is a UTF-16 high (lead) surrogate.
fn bool is_high_surrogate(uint cp) @inline {
    return cp >= SURROGATE_HIGH_START && cp <= SURROGATE_HIGH_END;
}

/// True when `cp` is a UTF-16 low (trail) surrogate.
fn bool is_low_surrogate(uint cp) @inline {
    return cp >= SURROGATE_LOW_START && cp <= SURROGATE_LOW_END;
}

/// Split an astral codepoint (>= U+10000) into its UTF-16 surrogate pair.
/// Caller must ensure `cp >= ASTRAL_START && cp <= 0x10FFFF`.
fn void codepoint_to_surrogates(uint cp, uint* high, uint* low) @inline {
    uint v = cp - ASTRAL_START;
    *high = SURROGATE_HIGH_START + (v >> 10);
    *low  = SURROGATE_LOW_START  + (v & 0x3FF);
}

/// Combine a UTF-16 surrogate pair back into its astral codepoint.
fn uint surrogates_to_codepoint(uint high, uint low) @inline {
    return ASTRAL_START + ((high - SURROGATE_HIGH_START) << 10) + (low - SURROGATE_LOW_START);
}

/// Encode a Unicode codepoint using CESU-8: astral codepoints are first
/// split into a UTF-16 surrogate pair and each half is encoded as its own
/// 3-byte UTF-8 sequence. BMP codepoints (including lone surrogates) are
/// encoded exactly like `encode_codepoint`. Returns the number of bytes
/// written (0, 3, or 6 for astral input; standard UTF-8 lengths otherwise),
/// or 0 if the buffer is too small / codepoint out of range.
fn uint encode_codepoint_cesu8(uint cp, char[] buf) {
    if (cp < ASTRAL_START) {
        return encode_codepoint(cp, buf);
    }
    if (cp > 0x10_FFFF) {
        return 0;
    }
    if (buf.len < 6) { return 0; }
    uint high; uint low;
    codepoint_to_surrogates(cp, &high, &low);
    uint n1 = encode_codepoint(high, buf[0..2]);
    uint n2 = encode_codepoint(low, buf[3..5]);
    if (n1 != 3 || n2 != 3) { return 0; }
    return 6;
}

/// Returns the byte length of the UTF-16 code unit sequence starting at
/// `data[offset]`, under CESU-8 storage. Because every code unit — BMP or
/// surrogate half — is encoded as a standalone 1-4 byte UTF-8 sequence,
/// this is identical to `utf8_seq_len`; kept as a distinct name so call
/// sites read as "advance one code unit" rather than "advance one UTF-8
/// sequence".
fn uint utf16_unit_byte_len(char[] data, uint offset) @inline {
    return utf8_seq_len(data[offset]);
}

/// ES `AdvanceStringIndex(S, index, unicode)`: the byte width to advance past
/// a zero-length match at `data[offset]`. Under `unicode`, if the code unit
/// at `offset` is a high surrogate immediately followed by a low surrogate,
/// the pair advances together (matches astral characters); otherwise (or
/// without `unicode`) a single code unit advances.
fn uint advance_string_index_byte_len(char[] data, uint offset, bool unicode) {
    // Guard the string end: a zero-width match can sit at offset == data.len
    // (e.g. an empty global match past the last char), and the regexp string
    // iterator still calls AdvanceStringIndex there. Per ES §22.2.7.2.2 that
    // advances by one, so return 1 without indexing data[offset] (which would
    // read one past the buffer).
    if ((usz)offset >= data.len) return 1;
    uint seq_len = utf16_unit_byte_len(data, offset);
    if (!unicode || (usz)(offset + seq_len) >= data.len) return seq_len;
    uint cp = decode_codepoint(data, offset);
    if (!is_high_surrogate(cp)) return seq_len;
    uint next_len = utf16_unit_byte_len(data, offset + seq_len);
    uint next_cp = decode_codepoint(data, offset + seq_len);
    if (is_low_surrogate(next_cp)) return seq_len + next_len;
    return seq_len;
}

/// True when `data` contains any raw 4-byte UTF-8 lead byte (0xF0-0xF7),
/// i.e. an astral codepoint encoded as standard UTF-8 rather than CESU-8.
/// Every internal string is expected to be CESU-8-canonical (see
/// `normalize_to_cesu8`); this is the fast-path check callers use to skip
/// normalization for the overwhelmingly common case (no 4-byte sequences).
fn bool has_raw_utf8_astral(char[] data) {
    foreach (b : data) {
        if (((uint)b & 0xF8) == 0xF0) return true;
    }
    return false;
}

/// Re-encode `data` into CESU-8-canonical form: every raw 4-byte UTF-8
/// astral sequence is decoded and re-emitted as a UTF-16 surrogate pair
/// (two 3-byte sequences). All other bytes pass through unchanged.
///
/// This is the single normalization chokepoint for string interning —
/// without it, the same logical string could reach the intern table in two
/// different byte encodings (a literal astral character typed directly in
/// source vs. the same character via a `\u{...}` escape or
/// `String.fromCodePoint`), breaking both `===` and property-key dedup
/// since strings are compared/hashed by raw bytes. Mirrors Duktape's own
/// "everything is CESU-8 at intern time" invariant (duk_heap_stringtable.c).
///
/// Writes into `out` (caller-provided, must be large enough — worst case
/// `data.len + data.len/4*2` since each 4-byte sequence grows to 6 bytes)
/// and returns the number of bytes written.
fn uint normalize_to_cesu8(char[] data, char[] out) {
    uint len = (uint)data.len;
    uint i = 0;
    uint o = 0;
    while (i < len) {
        uint b0 = (uint)data[i];
        if ((b0 & 0xF8) == 0xF0) {
            // 4-byte lead — decode the astral codepoint and re-emit as a
            // surrogate pair. Falls back to copying the raw byte on
            // malformed/truncated input (matches decode_codepoint's
            // tolerant behavior elsewhere).
            uint cp = decode_codepoint(data, i);
            if (cp >= ASTRAL_START && cp <= 0x10_FFFF) {
                o += encode_codepoint_cesu8(cp, out[o..]);
                i += 4;
                continue;
            }
        }
        out[o] = data[i];
        o++;
        i++;
    }
    return o;
}

/// Function pointer type for a single-byte output sink, used by
/// `write_cesu8_as_utf8`.
alias PutByteFn = fn void(char);

/// Write CESU-8-canonical `data` to a byte sink as standard, valid UTF-8 —
/// the inverse of `normalize_to_cesu8`. Surrogate pairs are recombined into
/// their astral codepoint and re-encoded as a single 4-byte UTF-8 sequence;
/// everything else passes through unchanged. Lone (unpaired) surrogates are
/// replaced with U+FFFD, since standard UTF-8 cannot represent them.
///
/// Use this at every host-visible text boundary (print/console.log, file
/// I/O, etc.) — internal storage is CESU-8, but nothing outside the engine
/// should ever observe raw surrogate-half byte sequences.
fn void write_cesu8_as_utf8(char[] data, PutByteFn put_byte_fn) {
    uint len = (uint)data.len;
    uint i = 0;
    while (i < len) {
        uint seq_len = utf8_seq_len(data[i]);
        uint cp = decode_codepoint(data, i);
        if (is_high_surrogate(cp) && i + seq_len < len) {
            uint next_len = utf8_seq_len(data[i + seq_len]);
            uint low = decode_codepoint(data, i + seq_len);
            if (is_low_surrogate(low)) {
                uint astral = surrogates_to_codepoint(cp, low);
                char[4] obuf;
                uint n = encode_codepoint(astral, obuf[:4]);
                for (uint k = 0; k < n; k++) put_byte_fn(obuf[k]);
                i += seq_len + next_len;
                continue;
            }
        }
        if (is_surrogate(cp)) {
            char[4] obuf;
            uint n = encode_codepoint(UNICODE_REPLACEMENT, obuf[:4]);
            for (uint k = 0; k < n; k++) put_byte_fn(obuf[k]);
            i += seq_len;
            continue;
        }
        for (uint k = 0; k < seq_len && i + k < len; k++) {
            put_byte_fn(data[i + k]);
        }
        i += seq_len;
    }
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
        mem::move(buf, buf + pos, (sz)len);
    }
    return (int)len;
}
