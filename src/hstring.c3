// HString, the representation behind every ECMAScript string value.
//
// The byte content never changes once the string is created, and the raw UTF-8
// bytes follow the struct header in one contiguous allocation. Interning
// through the heap's string table makes pointer equality mean string equality.
//
// This module holds the struct and its flags, the allocation helpers, a
// standalone hash function, and the UTF-8 and array-index utilities.
module boomkat::hstring;

import boomkat::types;
import boomkat::heap;
import std::core::mem;

// ============================================================================
// Constants
// ============================================================================

// FNV-1a 32-bit offset basis.
const uint FNV1A_OFFSET_BASIS = 0x811C_9DC5;
// FNV-1a 32-bit prime.
const uint FNV1A_PRIME        = 0x0100_0193;

// Maximum byte length of a single string (2^30 - 1, matching QuickJS's cap).
//
// This is a deliberate implementation limit, not a consequence of the data
// layout. `blen` is a `uint`, so an unbounded `a.blen + b.blen` wraps and the
// undersized buffer that follows corrupts the heap; capping well below 2^32
// leaves every such sum representable. Every site that computes a new string
// length must do so in 64 bits and run it through `length_exceeds_max` before
// allocating, so the check itself cannot wrap.
const ulong MAX_STRING_BYTES = 0x3FFF_FFFF;

// True when `len` is past the maximum representable string length.
//
// Takes a `ulong` so callers widen before they add: the whole point is that
// the sum being tested is computed in 64 bits.
macro bool length_exceeds_max(ulong len) => len > MAX_STRING_BYTES;

// Maximum valid ECMAScript array index (2^32 - 2).
const uint MAX_ARRIDX = 0xFFFF_FFFE;

// Sentinel value indicating "not a valid array index".
const uint ARRIDX_NONE = 0xFFFF_FFFF;

// Sentinel for `HString.cached_charlen`: the character length has not yet
// been computed for this string.
const uint CHARLEN_NONE = (uint)-1;

// Word-at-a-time byte-scan constants: the high bit of each of the eight bytes,
// and 0x01 in each. Together they drive the classic
// `(w - ONE_BYTES) & ~w & HIGH_BITS` zero-byte test.
const ulong HIGH_BITS = 0x8080_8080_8080_8080;
const ulong ONE_BYTES = 0x0101_0101_0101_0101;

// Sentinel for `HString.hash`: the content hash has not been computed yet.
// A real FNV-1a hash that lands on this value is nudged to `HASH_DEFERRED + 1`
// so the sentinel stays unambiguous.
const uint HASH_DEFERRED = (uint)-1;

// Returned by `scan_backwards_n` when the back-walk ran past the start of the
// string, which happens on malformed UTF-8 whose character length outruns its
// byte sequence.
const uint SCAN_UNDERFLOW = (uint)-1;

// Unicode replacement character (U+FFFD).
const uint UNICODE_REPLACEMENT = 0xFFFD;

// First/last UTF-16 high (lead) surrogate codepoint.
const uint SURROGATE_HIGH_START = 0xD800;
const uint SURROGATE_HIGH_END   = 0xDBFF;
// First/last UTF-16 low (trail) surrogate codepoint.
const uint SURROGATE_LOW_START  = 0xDC00;
const uint SURROGATE_LOW_END    = 0xDFFF;
// First astral (non-BMP) codepoint, which UTF-16 needs a surrogate pair for.
const uint ASTRAL_START         = 0x1_0000;

// ============================================================================
// HStringFlags, the per-string bit-packed flags
// ============================================================================

// Bit-packed flags word for HString.
//
// Bits 0 to 6 mirror HeapHeader's type and GC bits, so a raw cast from
// HString* to HeapHeader* still reads the right htype and mark bits. Bits 7
// and up carry string-specific metadata.
bitstruct HStringFlags : uint {
    // HeapHeader-compatible type discriminator (always HType.STRING).
    HType htype             : 0..1;
    // GC reachable flag (mirrors HeapHeader.flags.reachable).
    bool  reachable         : 2;
    // GC temporary root flag.
    bool  temproot          : 3;
    // Finaliser present flag.
    bool  finalizable       : 4;
    // Finaliser already ran.
    bool  finalized         : 5;
    // Read-only flag.
    bool  readonly          : 6;

    // --- String-specific flags (bits 7+) ---

    // All bytes < 0x80: charlen == bytelen.
    bool  is_ascii          : 7;
    // The string is a valid array index ("0" .. "4294967294").
    bool  is_arridx         : 8;
    // ES2015 Symbol (internal or well-known).
    bool  is_symbol         : 9;
    // Hidden Symbol (\xFF prefix, Duktape's scheme).
    bool  is_hidden         : 10;
    // String data lives in an external buffer, not inline.
    bool  has_extdata       : 13;
    // String has been inserted into the heap's string table.
    bool  is_interned       : 14;
}

// ============================================================================
// HString struct
// ============================================================================

// Header size in bytes, used to locate the inline string data.
const usz HSTRING_HDR_SIZE = HString::size;

// A heap-allocated string.
//
// The raw UTF-8 bytes sit immediately after the struct in the same allocation;
// `get_data()` returns a slice over them. A NUL terminator is always written
// past the last byte, so the data pointer can go straight to a C API.
//
// Strings are immutable once they can be observed. The one exception is a
// non-interned concatenation accumulator that is provably referenced by a
// single VM register: `try_append_in_place` extends it in the spare bytes
// `capacity` reserves, which is what keeps `s += chunk` loops linear.
struct HString {
    // HeapHeader-compatible bits plus the string-specific ones.
    HStringFlags flags;
    uint         refcount;
    // Bytes of inline data this allocation can hold, excluding the NUL
    // terminator. Equal to `blen` for every ordinary string; only an
    // over-allocated concat accumulator has `capacity > blen`.
    uint capacity;

    // --- String-specific fields ---

    // FNV-1a hash of the raw bytes, or `HASH_DEFERRED` when it has not been
    // computed yet. Interned strings always carry the real hash, since the
    // string table indexes on it. A large non-interned string, such as the
    // running result of a `+=` loop, defers it: hashing is O(blen), and the
    // only consumers are the `equals_hstring` fast reject and a later
    // `ensure_interned`, both of which go through `content_hash`.
    uint hash;
    // Byte length of the UTF-8 data (excluding the NUL terminator).
    uint blen;
    // Character length in UTF-16 code units, or `CHARLEN_NONE` before it has
    // been computed. ASCII strings leave it unset, since `blen` is already
    // their character length. Written once, because an immutable string's
    // cache never needs invalidating.
    uint cached_charlen;
    // Cached character offset for non-ASCII sequential scanning.
    uint cached_char_offset;
    // Cached byte offset corresponding to `cached_char_offset`.
    uint cached_byte_offset;
}

fn void HString.set_temproot(&self) @inline {
    ((types::HeapHeader*)self).set_temproot();
}

// Returns a slice over the raw UTF-8 bytes stored inline after the header.
//
// The returned slice has exactly `self.blen` elements.  A NUL terminator
// sits at `data[blen]` but is *not* included in the slice length.
macro char[] HString.get_data(&self) {
    char* ptr = (char*)((usz)self + HSTRING_HDR_SIZE);
    return ptr[:self.blen];
}

// Returns a raw C-string pointer to the inline data.  The data is always
// NUL-terminated.
macro char* HString.get_cstr(&self) {
    return (char*)((usz)self + HSTRING_HDR_SIZE);
}

// ============================================================================
// HString: comparison
// ============================================================================

// Compare this string's raw bytes with `data`. Callers holding two HString
// pointers should use `equals_hstring`, which can compare by pointer.
fn bool HString.equals(&self, char[] data) {
    if (self.blen != (uint)data.len) {
        return false;
    }
    if (data.len == 0) {
        return true;
    }
    return mem::equals(self.get_cstr(), data.ptr, data.len);
}

// Compare two HStrings. The string table guarantees uniqueness, so two
// interned strings are equal exactly when their pointers match. If either is
// non-interned, such as a concatenation temporary, the comparison falls back
// to content, with the hash as a fast reject.
fn bool HString.equals_hstring(&self, HString* other) {
    if (self == other) return true;
    if (!self.flags.is_interned || !other.flags.is_interned) {
        if (self.blen != other.blen) return false;
        // The hash is only a fast reject here, so a deferred one on either side
        // just falls through to the byte compare rather than forcing an O(blen)
        // hash of a string that may never need one.
        if (self.hash != other.hash
            && self.hash != HASH_DEFERRED && other.hash != HASH_DEFERRED) return false;
        return mem::equals(self.get_cstr(), other.get_cstr(), self.blen);
    }
    return false;
}

// Three-way byte comparison over `n` bytes: -1, 0, or 1.
fn int byte_compare(char* a, char* b, usz n) @local {
    for (usz i = 0; i < n; i++) {
        if (a[i] != b[i]) return a[i] < b[i] ? -1 : 1;
    }
    return 0;
}

// Lexicographic comparison of two HStrings.
//
// Returns -1 if a < b, 0 if a == b, 1 if a > b, comparing by
// UTF-8 byte value (which matches code-point ordering for well-formed
// UTF-8).
fn int hstring_compare(HString* a, HString* b) {
    int min_len = (int)(a.blen < b.blen ? a.blen : b.blen);
    int cmp = byte_compare(a.get_cstr(), b.get_cstr(), (usz)min_len);
    if (cmp != 0) return cmp;
    if (a.blen == b.blen) return 0;
    return a.blen > b.blen ? 1 : -1;
}

// ============================================================================
// HString: flag accessors
// ============================================================================

fn bool HString.is_ascii(&self)              { return self.flags.is_ascii; }
fn bool HString.is_arridx(&self)             { return self.flags.is_arridx; }
fn bool HString.is_symbol(&self)             { return self.flags.is_symbol; }
fn bool HString.is_hidden(&self)             { return self.flags.is_hidden; }
fn bool HString.has_extdata(&self)           { return self.flags.has_extdata; }
fn bool HString.is_interned(&self)           { return self.flags.is_interned; }

// ============================================================================
// HString: lazily computed fields
// ============================================================================

// Character length, computed on demand. For an ASCII string this is `blen`.
// Multi-byte UTF-8 is walked once to count codepoints, then cached, which is
// safe because the string is immutable.
fn uint HString.char_length(&self) {
    if (self.flags.is_ascii) return self.blen;
    if (self.cached_charlen != CHARLEN_NONE) return self.cached_charlen;
    uint clen = compute_charlen(self.get_data());
    self.cached_charlen = clen;
    self.cached_char_offset = clen;
    self.cached_byte_offset = self.blen;
    return clen;
}

// Returns the numeric array-index value if this string is a valid array
// index ("0" .. "4294967294"), or `ARRIDX_NONE` otherwise.
fn uint HString.array_index(&self) {
    if (!self.flags.is_arridx) return ARRIDX_NONE;
    uint idx_val;
    if (is_valid_array_index(self.get_data(), &idx_val)) {
        return idx_val;
    }
    return ARRIDX_NONE;
}

// ============================================================================
// HString: Unicode helpers
// ============================================================================

// Returns the Unicode codepoint at character index `char_idx`.
//
// For pure-ASCII strings the operation is O(1).  For multi-byte strings
// the function scans from the beginning in O(n) where n = char_idx.
// Returns `UNICODE_REPLACEMENT` if `char_idx >= char_length()`.
fn uint HString.char_at(&self, uint char_idx) {
    if (char_idx >= self.char_length()) {
        return UNICODE_REPLACEMENT;
    }
    return self.char_at_unchecked(char_idx);
}

// `char_at` without the bounds check, for callers that have already
// established `char_idx < char_length()`. It saves a `char_length()` call that
// can itself be O(n). An unchecked index may walk past the end of the string.
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

// Convert a character offset, in UTF-16 code units, to a byte offset into the
// string's UTF-8 data.
//
// Three cases, in order:
//   1. ASCII, where one byte is one character.
//   2. An exact hit on the cursor cache, which is a single field load.
//   3. Otherwise, walk from whichever origin is nearest: the string start
//      scanning forward, the string end scanning backward, or the cache entry
//      in either direction. Each step skips continuation bytes (0x80 to 0xBF),
//      matching `compute_charlen` and `utf8_seq_len`.
//
// Returns `self.blen` when `char_offset >= char_length()`. The cache is only
// ever updated, never invalidated, since the string is immutable.
fn uint HString.char_offset_to_byte_offset(&self, uint char_offset) {
    if (self.flags.is_ascii) {
        // One byte per character.
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

    // Distance from each candidate origin to the target. char_offset is below
    // char_length here, and each subtraction picks its larger operand, so none
    // of these underflow.
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

    // Malformed UTF-8 can make the scanners disagree: utf8_seq_len and
    // compute_charlen count a lone continuation byte as one character, while
    // the backward scanner's non-continuation test skips it. Interning
    // normalizes to CESU-8, so this is rare, but a scan that runs past either
    // end falls back to a forward walk that matches compute_charlen.
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

// Convert a byte offset into this string's data to a character (UTF-16 code
// unit) offset, the inverse of `char_offset_to_byte_offset`.
//
// For an ASCII string the two offsets are equal, so this answers in constant
// time; regexp match paths convert offsets for every match and capture, and a
// full `compute_charlen` scan there would be quadratic in the subject length.
// Non-ASCII strings fall back to counting characters up to `byte_offset`, and
// warm the same offset cache the forward conversion uses.
fn uint HString.byte_offset_to_char_offset(&self, uint byte_offset) {
    uint blen = self.blen;
    if (byte_offset > blen) byte_offset = blen;
    if (self.flags.is_ascii) {
        // One byte per character.
        return byte_offset;
    }

    // Exact cache hit.
    if (byte_offset == self.cached_byte_offset) {
        return self.cached_char_offset;
    }

    uint char_offset = compute_charlen(self.get_data()[:byte_offset]);
    self.cached_char_offset = char_offset;
    self.cached_byte_offset = byte_offset;
    return char_offset;
}

// Advance from `start` by exactly `n` non-continuation bytes, which are UTF-16
// code units under CESU-8.
//
// `start` must be a character-start byte offset, meaning a valid start byte,
// `0`, or `blen`. Returns the byte offset of the (n+1)-th character, or
// `blen + 1` if the scan ran past `blen`. That sentinel lets one `> blen` check
// tell an overshoot apart from a scan that reached exactly the end.
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

// Step back from `start` by exactly `n` non-continuation bytes. `start` must be
// a character-start byte offset. Returns the byte offset of the n-th previous
// character start, or `SCAN_UNDERFLOW` if the walk ran past offset 0. Since any
// real offset is at most `blen`, that sentinel needs no separate flag.
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

// Allocate and initialise an HString as one block of
// `HSTRING_HDR_SIZE + data.len + 1` bytes, copying `data` in after the header
// and appending a NUL terminator.
//
// `heap_ptr` is an opaque Heap pointer the caller casts back. Interning is the
// caller's job; nothing here touches the string table.
//
// Returns the new HString, or a fault if allocation fails.
fn HString*? hstring_alloc(void* heap_ptr, char[] data, uint hash) {
    return hstring_alloc_cap(heap_ptr, data, hash, (uint)data.len);
}

// Allocate an HString whose inline buffer holds `cap` bytes but whose logical
// length is `data.len`, so `try_append_in_place` can extend it without moving
// the allocation. `cap` must be at least `data.len`.
//
// Returns the new HString, or a fault if allocation fails.
fn HString*? hstring_alloc_cap(void* heap_ptr, char[] data, uint hash, uint cap) {
    // Backstop for the string-length cap. Callers are expected to check first,
    // so they can raise a catchable RangeError naming the operation; refusing
    // here as an allocation failure keeps a missed caller from writing a
    // wrapped `blen` into the header.
    if (length_exceeds_max((ulong)data.len) || length_exceeds_max((ulong)cap)) {
        return boomkat::types::ALLOC_ERROR~;
    }
    if (cap < (uint)data.len) { cap = (uint)data.len; }

    usz total = HSTRING_HDR_SIZE + (usz)cap + 1;  // +1 for NUL

    void* raw = ((heap::Heap*)heap_ptr).alloc_no_gc(total) ?? null;
    if (raw == null) {
        return boomkat::types::ALLOC_ERROR~;
    }

    // Zero-fill the header portion.
    mem::clear(raw, (sz)(HSTRING_HDR_SIZE));

    HString* s = (HString*)raw;

    s.flags.htype = HType.STRING;
    s.hash = hash;
    s.blen = (uint)data.len;
    s.capacity = cap;

    // char_length() fills this in on first use.
    s.cached_charlen = CHARLEN_NONE;

    bool ascii = check_is_ascii(data);
    s.flags.is_ascii = ascii;

    uint idx_val;
    if (is_valid_array_index(data, &idx_val)) {
        s.flags.is_arridx = true;
    }

    // A symbol starts with 0xFF, and a hidden symbol with 0xFF 0xFF.
    if (data.len > 0 && (uint)data[0] == 0xFF) {
        s.flags.is_symbol = true;
        if (data.len > 1 && (uint)data[1] == 0xFF) {
            s.flags.is_hidden = true;
        }
    }

    // Starts at 0: the first owner increfs, whether that is str_table_insert
    // taking the table's reference or a TVal assignment.
    s.refcount = 0;

    char* dest = (char*)((usz)raw + HSTRING_HDR_SIZE);
    if (data.len > 0) {
        mem::copy(dest, data.ptr, (sz)(data.len));
    }
    dest[data.len] = 0;  // NUL terminator

    return s;
}

// Append `data` to a concat accumulator in place, if it has the spare capacity.
// Returns false when it does not, leaving the string untouched so the caller
// falls back to allocating a fresh one.
//
// The caller must have established that `self` is safe to mutate: non-interned,
// not a symbol, and reachable from exactly one VM register. See the guard in
// the ADD opcode's string path, which is the only caller.
fn bool HString.try_append_in_place(&self, char[] data) {
    ulong need = (ulong)self.blen + (ulong)data.len;
    if (need > (ulong)self.capacity) { return false; }

    char* dest = self.get_cstr();
    if (data.len > 0) {
        mem::copy(dest + self.blen, data.ptr, (sz)(data.len));
    }
    self.blen = (uint)need;
    dest[need] = 0;  // NUL terminator

    // The bytes changed, so every content-derived field has to be rebuilt or
    // invalidated. A hash is O(blen) and would reintroduce the quadratic cost
    // the in-place append exists to remove, so it is deferred to content_hash.
    self.hash = HASH_DEFERRED;
    self.cached_charlen = CHARLEN_NONE;
    self.cached_char_offset = 0;
    self.cached_byte_offset = 0;
    if (self.flags.is_ascii && !check_is_ascii(data)) {
        self.flags.is_ascii = false;
    }
    // is_arridx and is_symbol cannot newly become true: the accumulator is
    // already longer than any array index, and a symbol prefix is decided by
    // byte 0, which an append never touches.
    return true;
}

// ============================================================================
// Standalone hash function
// ============================================================================

// Compute a 32-bit FNV-1a hash of the raw byte slice `data`.
//
// Unseeded, for use outside a heap context such as bootstrap, before the
// heap's hash seed exists. Heap.hash_string is the seeded version.
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

// Count the number of Unicode codepoints in a UTF-8 byte slice.
//
// Only leading bytes count, meaning those outside the 0x80 to 0xBF
// continuation range. Malformed input is tolerated, with each unexpected
// continuation byte counting as its own character.
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

// Returns `true` when every byte in `data` is in the ASCII range (< 0x80).
//
// Eight bytes at a time: a non-ASCII byte is exactly one with its high bit
// set, so masking a whole word against `HIGH_BITS` tests eight at once. Every
// concatenation result is scanned once over its full length, so this runs on
// the accumulated string on each step of a `s += chunk` loop.
fn bool check_is_ascii(char[] data) {
    usz len = data.len;
    usz i = 0;
    for (; i + 8 <= len; i += 8) {
        // A string's bytes carry no alignment guarantee: an HString's payload
        // starts right after its header, and a slice can begin at any offset.
        // A plain ulong* deref is an unaligned read, which the sanitising
        // builds trap on.
        ulong w = mem::load((ulong*)(data.ptr + i), 1);
        if ((w & HIGH_BITS) != 0) return false;
    }
    for (; i < len; i++) {
        if ((uint)data[i] >= 0x80) return false;
    }
    return true;
}

// Decode a single UTF-8 codepoint starting at `data[offset]`.
//
// Returns `UNICODE_REPLACEMENT` on malformed input. The caller tracks the
// sequence length itself, since this advances no offset.
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

// Encode a Unicode codepoint as UTF-8 into `buf`, returning how many bytes it
// wrote, from 1 to 4. Returns 0 for a codepoint out of range or a buffer too
// small to hold it.
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
// UTF-16 code units and CESU-8
//
// An ECMAScript string is a sequence of UTF-16 code units, which the spec
// defines as a finite ordered sequence of 16-bit unsigned integers, rather than
// a sequence of Unicode codepoints. Source, property, and index semantics all
// represent an astral codepoint (>= U+10000) as a pair of surrogate code units.
//
// The bytes here are still UTF-8 shaped, which keeps ASCII on a fast
// one-byte-per-unit path and leaves non-BMP text readable to anything that
// tolerates CESU-8. Every codepoint >= U+10000 is split into its two surrogate
// halves before encoding, and each half is encoded as its own 3-byte sequence.
// That is exactly CESU-8, or WTF-8. Lone surrogates, such as an unpaired half
// written as \u{D800}, round-trip the same way, and the spec permits them.
//
// char_length(), char_at(), and char_offset_to_byte_offset() therefore count and
// index by UTF-16 code unit: a 3-byte sequence in the D800 to DFFF range is one
// unit, a surrogate half, which is what makes `"\u{1F600}".length === 2`.
// ============================================================================

// True when `cp` is a UTF-16 surrogate codepoint (high or low half).
fn bool is_surrogate(uint cp) @inline {
    return cp >= SURROGATE_HIGH_START && cp <= SURROGATE_LOW_END;
}

// True when `cp` is a UTF-16 high (lead) surrogate.
fn bool is_high_surrogate(uint cp) @inline {
    return cp >= SURROGATE_HIGH_START && cp <= SURROGATE_HIGH_END;
}

// True when `cp` is a UTF-16 low (trail) surrogate.
fn bool is_low_surrogate(uint cp) @inline {
    return cp >= SURROGATE_LOW_START && cp <= SURROGATE_LOW_END;
}

// Split an astral codepoint (>= U+10000) into its UTF-16 surrogate pair.
// Caller must ensure `cp >= ASTRAL_START && cp <= 0x10FFFF`.
fn void codepoint_to_surrogates(uint cp, uint* high, uint* low) @inline {
    uint v = cp - ASTRAL_START;
    *high = SURROGATE_HIGH_START + (v >> 10);
    *low  = SURROGATE_LOW_START  + (v & 0x3FF);
}

// Combine a UTF-16 surrogate pair back into its astral codepoint.
fn uint surrogates_to_codepoint(uint high, uint low) @inline {
    return ASTRAL_START + ((high - SURROGATE_HIGH_START) << 10) + (low - SURROGATE_LOW_START);
}

// Encode a Unicode codepoint using CESU-8: astral codepoints are first
// split into a UTF-16 surrogate pair and each half is encoded as its own
// 3-byte UTF-8 sequence. BMP codepoints (including lone surrogates) are
// encoded exactly like `encode_codepoint`. Returns the number of bytes
// written (0, 3, or 6 for astral input; standard UTF-8 lengths otherwise),
// or 0 if the buffer is too small / codepoint out of range.
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

// ES2024 §6.1.4 `IsStringWellFormedUnicode(string)`: true iff the UTF-16
// code-unit sequence contains no lone (unpaired) surrogate. `data` is this
// engine's CESU-8 storage, where each code unit — including a surrogate half —
// is its own byte sequence.
//
// Shared by String.prototype.isWellFormed and by the ModuleExportName early
// error (§16.2.3.1), which rejects a StringLiteral export name that is not
// well-formed.
fn bool is_well_formed_unicode(char[] data) {
    uint len = (uint)data.len;
    uint i = 0;
    while (i < len) {
        uint seq_len = utf8_seq_len(data[i]);
        uint cp = decode_codepoint(data, i);
        if (is_high_surrogate(cp)) {
            // Must be paired with an immediately following low surrogate.
            uint next_off = i + seq_len;
            if (next_off >= len) return false;
            if (!is_low_surrogate(decode_codepoint(data, next_off))) return false;
            i = next_off + utf8_seq_len(data[next_off]);
        } else if (is_low_surrogate(cp)) {
            // Low surrogate with no preceding high surrogate.
            return false;
        } else {
            i += seq_len;
        }
    }
    return true;
}

// Byte length of the UTF-16 code unit starting at `data[offset]` in CESU-8
// storage. Every code unit, whether BMP or a surrogate half, is its own 1 to 4
// byte sequence, so this does what `utf8_seq_len` does. The separate name lets
// call sites read as "advance one code unit".
fn uint utf16_unit_byte_len(char[] data, uint offset) @inline {
    return utf8_seq_len(data[offset]);
}

// ES `AdvanceStringIndex(S, index, unicode)`: the byte width to advance past
// a zero-length match at `data[offset]`. Under `unicode`, if the code unit
// at `offset` is a high surrogate immediately followed by a low surrogate,
// the pair advances together (matches astral characters); otherwise (or
// without `unicode`) a single code unit advances.
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

// True when `data` holds a raw 4-byte UTF-8 lead byte (0xF0 to 0xF7), meaning
// an astral codepoint in standard UTF-8 rather than CESU-8. Internal strings
// are CESU-8 canonical (see `normalize_to_cesu8`), and this check lets callers
// skip normalization for the common case of no 4-byte sequences.
fn bool has_raw_utf8_astral(char[] data) {
    // Eight bytes at a time. Masking with 0xF8 per byte leaves each byte equal
    // to 0xF0 exactly when it starts a 4-byte sequence; XOR-ing against a word
    // of 0xF0 turns those into zero bytes, and the standard
    // `(w - ONES) & ~w & HIGH_BITS` idiom reports whether any zero byte exists.
    // ASCII text takes the early-out on every word, which matters because every
    // interned string is scanned over its full length.
    const ulong MASK_F8 = 0xF8F8_F8F8_F8F8_F8F8;
    const ulong ALL_F0  = 0xF0F0_F0F0_F0F0_F0F0;
    usz len = data.len;
    usz i = 0;
    for (; i + 8 <= len; i += 8) {
        // Unaligned, for the same reason as check_is_ascii above.
        ulong w = (mem::load((ulong*)(data.ptr + i), 1) & MASK_F8) ^ ALL_F0;
        if (((w - ONE_BYTES) & ~w & HIGH_BITS) != 0) return true;
    }
    for (; i < len; i++) {
        if (((uint)data[i] & 0xF8) == 0xF0) return true;
    }
    return false;
}

// Re-encode `data` into CESU-8-canonical form: every raw 4-byte UTF-8
// astral sequence is decoded and re-emitted as a UTF-16 surrogate pair
// (two 3-byte sequences). All other bytes pass through unchanged.
//
// Interning normalizes here and nowhere else. Strings are compared and hashed
// by raw bytes, so without this one logical string could reach the table in two
// encodings, a literal astral character in source against the same character
// from a `\u{...}` escape or `String.fromCodePoint`, breaking `===` and
// property-key dedup.
//
// Returns the number of bytes written into `out`, which the caller supplies and
// which must hold `data.len + data.len/4*2` in the worst case, since each
// 4-byte sequence grows to 6.
fn uint normalize_to_cesu8(char[] data, char[] out) {
    uint len = (uint)data.len;
    uint i = 0;
    uint o = 0;
    while (i < len) {
        uint b0 = (uint)data[i];
        if ((b0 & 0xF8) == 0xF0) {
            // Decode the astral codepoint and re-emit it as a surrogate pair.
            // Malformed or truncated input falls through to the raw byte copy
            // below, matching how decode_codepoint tolerates it elsewhere.
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

// Function pointer type for a single-byte output sink, used by
// `write_cesu8_as_utf8`. The `udata` pointer is passed through untouched, so a
// sink that accumulates into a caller-owned buffer needs no global to find it.
alias PutByteFn = fn void(char, void*);

// Write CESU-8-canonical `data` to a byte sink as standard UTF-8, inverting
// `normalize_to_cesu8`. Surrogate pairs recombine into their astral codepoint
// and re-encode as one 4-byte sequence, and everything else passes through.
// Unpaired surrogates become U+FFFD, which standard UTF-8 has no way to
// represent.
//
// Every host-visible text boundary goes through here, including print,
// console.log, and file I/O, so nothing outside the engine sees a raw
// surrogate-half sequence.
fn void write_cesu8_as_utf8(char[] data, PutByteFn put_byte_fn, void* udata = null) {
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
                for (uint k = 0; k < n; k++) put_byte_fn(obuf[k], udata);
                i += seq_len + next_len;
                continue;
            }
        }
        if (is_surrogate(cp)) {
            char[4] obuf;
            uint n = encode_codepoint(UNICODE_REPLACEMENT, obuf[:4]);
            for (uint k = 0; k < n; k++) put_byte_fn(obuf[k], udata);
            i += seq_len;
            continue;
        }
        for (uint k = 0; k < seq_len && i + k < len; k++) {
            put_byte_fn(data[i + k], udata);
        }
        i += seq_len;
    }
}

// ============================================================================
// Array-index utilities
// ============================================================================

// Determine whether `data` is a valid ECMAScript array index string.
//
// A valid index is the canonical decimal form of an integer from 0 to 2^32-2,
// so "0" through "4294967294". Only the string "0" may start with a zero.
//
// On success the numeric value goes to `*out_index`.
fn bool is_valid_array_index(char[] data, uint* out_index) {
    uint len = (uint)data.len;

    // The largest index, "4294967294", is 10 digits.
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

    // MAX_ARRIDX is 0xFFFF_FFFE, or 4294967294.
    if (val > (ulong)MAX_ARRIDX) {
        return false;
    }

    *out_index = (uint)val;
    return true;
}

// ============================================================================
// Internal helpers
// ============================================================================

// Returns the byte length of the UTF-8 sequence that begins with `lead`.
// Tolerant: returns 1 for unexpected continuation bytes or invalid leads.
fn uint utf8_seq_len(char lead) @inline {
    uint b = (uint)lead;
    if (b < 0x80)          { return 1; }
    if ((b & 0xE0) == 0xC0) { return 2; }
    if ((b & 0xF0) == 0xE0) { return 3; }
    if ((b & 0xF8) == 0xF0) { return 4; }
    return 1;  // an unexpected continuation byte advances one
}

// Write `val` into `buf` as decimal digits, returning how many bytes it wrote,
// or 0 if the buffer was too small. `cap` must be at least 2, and 21 bytes
// holds any int64.
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
