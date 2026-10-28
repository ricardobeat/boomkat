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
import boomkat::gcprofile;
import std::core::mem;
import libc;

// ============================================================================
// Constants
// ============================================================================

// FNV-1a 32-bit offset basis.
const uint FNV1A_OFFSET_BASIS = 0x811C_9DC5;
// FNV-1a 32-bit prime.
const uint FNV1A_PRIME        = 0x0100_0193;

// Maximum length of a single string in code units (2^30 - 1).
//
// This is an implementation limit, not a data layout one. `length` is a `uint`,
// so an unbounded `a.length + b.length` would wrap and corrupt the heap; capping
// well below 2^32 keeps every such sum representable, and a wide string's byte
// size still fits a `uint`. Sites that compute a new length must do so in 64
// bits and check it with `length_exceeds_max` before allocating.
const ulong MAX_STRING_LENGTH = 0x3FFF_FFFF;

// True when `len` is past the maximum representable string length.
//
// Takes a `ulong` so callers widen before they add: the whole point is that
// the sum being tested is computed in 64 bits.
macro bool length_exceeds_max(ulong len) => len > MAX_STRING_LENGTH;

// Maximum valid ECMAScript array index (2^32 - 2).
const uint MAX_ARRIDX = 0xFFFF_FFFE;

// Sentinel value indicating "not a valid array index".
const uint ARRIDX_NONE = 0xFFFF_FFFF;

// Word-at-a-time byte-scan constants: the high bit of each of the eight bytes,
// and 0x01 in each. Together they drive the classic
// `(w - ONE_BYTES) & ~w & HIGH_BITS` zero-byte test.
const ulong HIGH_BITS = 0x8080_8080_8080_8080;
const ulong ONE_BYTES = 0x0101_0101_0101_0101;

// Sentinel for `HString.hash`: the content hash has not been computed yet.
// A real FNV-1a hash that lands on this value is nudged to `HASH_DEFERRED + 1`
// so the sentinel stays unambiguous.
const uint HASH_DEFERRED = (uint)-1;

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

    // A narrow string whose units are all below 0x80.
    bool  is_ascii          : 7;
    // The string is a valid array index ("0" .. "4294967294").
    bool  is_arridx         : 8;
    // ECMA-262 Symbol value (internal or well-known). Set at creation, never
    // inferred from the stored characters.
    bool  is_symbol         : 9;
    // Hidden Symbol: a private class member key or an engine slot name. Also
    // set at creation; implies `is_symbol`.
    bool  is_hidden         : 10;
    // The units are two bytes each (UTF-16) rather than one (Latin-1).
    bool  is_wide           : 11;
    // A user-visible Symbol created with a description, possibly empty.
    // `Symbol()` has none, and the stored characters are the description.
    bool  has_desc          : 12;
    // String data lives in an external buffer, not inline.
    bool  has_extdata       : 13;
    // String has been inserted into the heap's string table.
    bool  is_interned       : 14;
    // A weak handle refers to this symbol (gc_weak.c3).
    bool  weak_target       : 15;
}

// ============================================================================
// HString struct
// ============================================================================

// Header size in bytes, used to locate the inline string data.
const usz HSTRING_HDR_SIZE = HString::size;

// A heap-allocated string.
//
// The code units sit immediately after the struct in the same allocation, a
// byte each in a narrow string (U+0000 to U+00FF, Latin-1) and two bytes each in
// a wide one (UTF-16, native endian). A string is wide only when some unit is
// above 0xFF, so equal contents always have the same width and the same bytes.
// A NUL terminator, one byte narrow and two wide, follows the last unit.
//
// An external string (`has_extdata`) keeps an `ExtData` record after the header
// instead of units. It points at a host buffer that is neither copied nor
// NUL-terminated, and is never ASCII-flagged, so no in-place text path sees it.
//
// Strings are immutable once they can be observed. The one exception is a
// non-interned concatenation accumulator that is provably referenced by a
// single VM register: `try_append_in_place` extends it in the spare bytes
// `capacity` reserves, which is what keeps `s += chunk` loops linear.
struct HString {
    // HeapHeader-compatible bits plus the string-specific ones.
    HStringFlags flags;
    uint         refcount;
    // Bytes of inline data this allocation can hold, excluding the terminator.
    // Equal to `byte_len()` for every ordinary string; only an over-allocated
    // concat accumulator has more.
    uint capacity;
    // One-based weak registry slot; zero means unregistered.
    uint registry_slot;

    // --- String-specific fields ---

    // FNV-1a content hash, or HASH_DEFERRED. Concatenation skips hashing until
    // a collection or property-key lookup calls Heap.content_hash. Equality
    // can reject unequal materialized hashes before comparing units.
    uint hash;
    // Length in UTF-16 code units.
    uint length;
}

fn void HString.set_temproot(&self) @inline {
    ((types::HeapHeader*)self).set_temproot();
}

// A run of code units in either width: the operand type of every builder.
struct Units {
    char* ptr;
    uint  len;
    bool  wide;
}

// The narrow units of `latin1`, each byte one unit.
fn Units narrow_units(char[] latin1) @inline {
    return { .ptr = latin1.ptr, .len = (uint)latin1.len, .wide = false };
}

fn Units wide_units(ushort[] utf16) @inline {
    return { .ptr = (char*)utf16.ptr, .len = (uint)utf16.len, .wide = true };
}

fn usz Units.byte_len(&self) @inline => (usz)self.len << (self.wide ? 1 : 0);

fn uint Units.at(&self, uint i) @inline {
    return self.wide ? (uint)((ushort*)self.ptr)[i] : (uint)self.ptr[i];
}

// Called when an external string is freed. `length` counts units.
alias ExtRelease = fn void(void* udata, void* data, usz length);

// The record an external string keeps after its header.
struct ExtData {
    char*      data;
    // Null for a buffer that outlives the heap.
    ExtRelease release;
    void*      udata;
}

const usz EXT_DATA_SIZE = ExtData::size;

fn ExtData* HString.ext(&self) @inline => (ExtData*)((usz)self + HSTRING_HDR_SIZE);

// Where the units start: inline after the header, or in the host buffer of an
// external string.
macro char* HString.data_ptr(&self) {
    return self.flags.has_extdata ? self.ext().data : (char*)((usz)self + HSTRING_HDR_SIZE);
}

fn Units HString.units(&self) @inline {
    return { .ptr = self.data_ptr(), .len = self.length, .wide = self.flags.is_wide };
}

fn bool HString.is_wide(&self) @inline => self.flags.is_wide;

// Bytes of the whole allocation: header, capacity and terminator, or header and
// record for an external string.
fn usz HString.alloc_size(&self) @inline {
    if (self.flags.has_extdata) return HSTRING_HDR_SIZE + EXT_DATA_SIZE;
    return HSTRING_HDR_SIZE + (usz)self.capacity + (self.flags.is_wide ? 2u : 1u);
}

// Bytes the units occupy, excluding the terminator.
fn usz HString.byte_len(&self) @inline => (usz)self.length << (self.flags.is_wide ? 1 : 0);

// The units of a narrow string, which are also its Latin-1 bytes.
fn char[] HString.latin1(&self) @inline {
    assert(!self.flags.is_wide);
    return self.data_ptr()[:self.length];
}

// The units of a wide string.
fn ushort[] HString.utf16(&self) @inline {
    assert(self.flags.is_wide);
    return ((ushort*)self.data_ptr())[:self.length];
}

// ============================================================================
// HString: comparison
// ============================================================================

// The stored characters equal `text`, a UTF-8 or CESU-8 string, and this is not
// a symbol. Callers holding two HString pointers should use `equals_hstring`,
// which can compare by pointer.
fn bool HString.equals(&self, char[] text) {
    return !self.flags.is_symbol && self.equals_chars(text);
}

// The stored characters equal `text`, whatever kind of string this is.
fn bool HString.equals_chars(&self, char[] text) {
    if (self.flags.is_ascii) {
        return self.length == text.len && (text.len == 0 || mem::equals(self.data_ptr(), text.ptr, text.len));
    }
    // Each unit takes at least one byte of text.
    if (text.len < self.length) return false;
    uint pos = 0;
    for (usz i = 0; i < text.len;) {
        uint cp = decode_codepoint(text, (uint)i);
        i += utf8_seq_len(text[i]);
        if (cp >= ASTRAL_START) {
            uint high; uint low;
            codepoint_to_surrogates(cp, &high, &low);
            if (pos + 1 >= self.length || self.unit_at(pos) != high || self.unit_at(pos + 1) != low) return false;
            pos += 2;
        } else {
            if (pos >= self.length || self.unit_at(pos) != cp) return false;
            pos++;
        }
    }
    return pos == self.length;
}

// Compare two HStrings. The string table guarantees uniqueness, so two
// interned strings are equal exactly when their pointers match. If either is
// non-interned, such as a concatenation temporary, the comparison falls back
// to content, with the hash as a fast reject. A symbol is equal only to itself.
fn bool HString.equals_hstring(&self, HString* other) {
    if (self == other) return true;
    if (self.flags.is_symbol || other.flags.is_symbol) return false;
    if (!self.flags.is_interned || !other.flags.is_interned) {
        return self.same_units(other, true);
    }
    return false;
}

// Both strings hold the same units. With `use_hash` the hashes are a fast
// reject when both are materialized; a deferred one just falls through to the
// compare rather than forcing an O(length) hash of a string that may never need one.
fn bool HString.same_units(&self, HString* other, bool use_hash = false) @inline {
    if (self.length != other.length || self.flags.is_wide != other.flags.is_wide) return false;
    if (use_hash && self.hash != other.hash
        && self.hash != HASH_DEFERRED && other.hash != HASH_DEFERRED) return false;
    return mem::equals(self.data_ptr(), other.data_ptr(), (sz)self.byte_len());
}

// Lexicographic comparison of two HStrings by UTF-16 code unit, as the ECMAScript
// relational operators define it. Returns -1 if a < b, 0 if a == b, 1 if a > b.
fn int units_compare(HString* a, HString* b) {
    uint n = a.length < b.length ? a.length : b.length;
    if (!a.flags.is_wide && !b.flags.is_wide) {
        int cmp = libc::memcmp(a.data_ptr(), b.data_ptr(), n);
        if (cmp != 0) return cmp < 0 ? -1 : 1;
    } else {
        for (uint i = 0; i < n; i++) {
            uint ua = a.unit_at(i);
            uint ub = b.unit_at(i);
            if (ua != ub) return ua < ub ? -1 : 1;
        }
    }
    if (a.length == b.length) return 0;
    return a.length > b.length ? 1 : -1;
}

// ============================================================================
// HString: flag accessors
// ============================================================================

fn bool HString.is_ascii(&self)              { return self.flags.is_ascii; }
// ToBoolean of a string value: a symbol is always truthy, even with no description.
fn bool HString.is_truthy(&self)             { return self.length > 0 || self.flags.is_symbol; }
fn bool HString.is_arridx(&self)             { return self.flags.is_arridx; }
fn bool HString.is_symbol(&self)             { return self.flags.is_symbol; }
fn bool HString.is_hidden(&self)             { return self.flags.is_hidden; }
fn bool HString.has_extdata(&self)           { return self.flags.has_extdata; }
fn bool HString.is_interned(&self)           { return self.flags.is_interned; }

// Length in UTF-16 code units.
fn uint HString.unit_len(&self) @inline => self.length;

// Returns the numeric array-index value if this string is a valid array
// index ("0" .. "4294967294"), or `ARRIDX_NONE` otherwise.
fn uint HString.array_index(&self) {
    if (!self.flags.is_arridx) return ARRIDX_NONE;
    uint idx_val;
    if (is_valid_array_index(self.latin1(), &idx_val)) {
        return idx_val;
    }
    return ARRIDX_NONE;
}

// The unit at `idx`, which must be below `unit_len()`. It may be a lone
// surrogate half.
fn uint HString.unit_at(&self, uint idx) @inline {
    char* data = self.data_ptr();
    return self.flags.is_wide ? (uint)((ushort*)data)[idx] : (uint)data[idx];
}

// ============================================================================
// Allocation
// ============================================================================

// Allocate and initialise an HString holding `data`, as one block of
// `HSTRING_HDR_SIZE + data.byte_len() + terminator` bytes. `data` must be in
// canonical width: wide only if some unit is above 0xFF.
//
// `heap_ptr` is an opaque Heap pointer the caller casts back. Interning is the
// caller's job; nothing here touches the string table.
//
// Returns the new HString, or a fault if allocation fails.
fn HString*? hstring_alloc(void* heap_ptr, Units data, uint hash) {
    return hstring_alloc_cap(heap_ptr, data, hash, data.len);
}

// Allocate an HString whose inline buffer holds `cap` units of its own width
// but whose logical length is `data.len`, so `try_append_in_place` can extend
// it without moving the allocation. `cap` must be at least `data.len`.
//
// Returns the new HString, or a fault if allocation fails.
fn HString*? hstring_alloc_cap(void* heap_ptr, Units data, uint hash, uint cap) {
    return hstring_alloc_concat_cap(heap_ptr, data, {}, hash, cap);
}

// The caller fills all units and finishes metadata before publishing storage.
// Fails when `len` or `cap` is past the string-length cap, as a backstop for a
// caller that did not check first to raise a catchable RangeError.
fn HString*? hstring_alloc_storage(void* heap_ptr, uint len, bool wide, uint hash, uint cap) {
    if (length_exceeds_max((ulong)len) || length_exceeds_max((ulong)cap)) return boomkat::types::ALLOC_ERROR~;
    if (cap < len) cap = len;
    usz cap_bytes = (usz)cap << (wide ? 1 : 0);
    usz total = HSTRING_HDR_SIZE + cap_bytes + (wide ? 2u : 1u);
    void* raw = ((heap::Heap*)heap_ptr).alloc_no_gc(total) ?? null;
    if (raw == null) return boomkat::types::ALLOC_ERROR~;
    gcprofile::gcprof_string_alloc(total);
    mem::clear(raw, (sz)HSTRING_HDR_SIZE);
    HString* s = (HString*)raw;
    s.flags.htype = HType.STRING;
    s.flags.is_wide = wide;
    s.hash = hash;
    s.length = len;
    s.capacity = (uint)cap_bytes;
    s.data_ptr()[s.byte_len()] = 0;
    if (wide) s.data_ptr()[s.byte_len() + 1] = 0;
    return s;
}

// Allocate an external string over `data`, which must be in canonical width and
// is neither copied nor terminated. The buffer stays untouched until `release`
// runs when the string is freed; a null `release` means it never needs one.
// The string is not interned and not registered.
//
// Returns the new HString, or a fault if allocation fails.
fn HString*? hstring_alloc_external(void* heap_ptr, Units data, ExtRelease release, void* udata) {
    if (length_exceeds_max((ulong)data.len)) return boomkat::types::ALLOC_ERROR~;
    usz total = HSTRING_HDR_SIZE + EXT_DATA_SIZE;
    void* raw = ((heap::Heap*)heap_ptr).alloc_no_gc(total) ?? null;
    if (raw == null) return boomkat::types::ALLOC_ERROR~;
    gcprofile::gcprof_string_alloc(total);
    mem::clear(raw, (sz)total);
    HString* s = (HString*)raw;
    s.flags.htype = HType.STRING;
    s.flags.is_wide = data.wide;
    s.flags.has_extdata = true;
    s.hash = HASH_DEFERRED;
    s.length = data.len;
    ExtData* ext = s.ext();
    ext.data = data.ptr;
    ext.release = release;
    ext.udata = udata;
    if (!data.wide) {
        uint index;
        s.flags.is_arridx = is_valid_array_index(s.latin1(), &index);
    }
    return s;
}

// Hand the host buffer back. Runs once, as the string is freed.
fn void HString.release_external(&self) {
    ExtData* ext = self.ext();
    if (ext.release != null) ext.release(ext.udata, ext.data, self.length);
}

fn void HString.finish_data(&self) {
    if (self.flags.is_wide) return;
    char[] data = self.latin1();
    self.flags.is_ascii = check_is_ascii(data);
    if (data.len == 1 && self.flags.is_ascii) gcprofile::gcprof_ascii_char_alloc();
    uint idx;
    self.flags.is_arridx = is_valid_array_index(data, &idx);
}

// Copy `n` bytes like mem::copy, inline for short spans where the library call
// costs more than the copy. Each width uses two overlapping loads, so no tail
// loop is needed. The destination never overlaps the source.
fn void copy_short(char* dest, char* src, usz n) @inline {
    if (n > 16) {
        mem::copy(dest, src, (sz)n);
    } else if (n >= 8) {
        ulong head; ulong tail;
        mem::copy(&head, src, 8);
        mem::copy(&tail, src + n - 8, 8);
        mem::copy(dest, &head, 8);
        mem::copy(dest + n - 8, &tail, 8);
    } else if (n >= 4) {
        uint head; uint tail;
        mem::copy(&head, src, 4);
        mem::copy(&tail, src + n - 4, 4);
        mem::copy(dest, &head, 4);
        mem::copy(dest + n - 4, &tail, 4);
    } else if (n > 0) {
        char first = src[0];
        char mid = src[n >> 1];
        char last = src[n - 1];
        dest[0] = first;
        dest[n >> 1] = mid;
        dest[n - 1] = last;
    }
}

// Copy `src` to `dest`, which holds units of width `dest_wide`. A narrow source
// widens into a wide destination; the reverse never occurs.
fn void copy_units(char* dest, bool dest_wide, Units src) @inline {
    if (src.wide == dest_wide) {
        copy_short(dest, src.ptr, src.byte_len());
        return;
    }
    assert(dest_wide);
    ushort* wide = (ushort*)dest;
    for (uint i = 0; i < src.len; i++) wide[i] = src.ptr[i];
}

// Allocate an HString from two unit spans without assembling a temporary
// concatenation buffer. The result is wide when either span is. Metadata is
// derived from the completed sequence, including array-index recognition across
// the span boundary. `cap` is in units of the result's width.
fn HString*? hstring_alloc_concat_cap(void* heap_ptr, Units left, Units right,
                                      uint hash, uint cap) {
    ulong len = (ulong)left.len + (ulong)right.len;
    if (length_exceeds_max(len) || length_exceeds_max((ulong)cap)) {
        return boomkat::types::ALLOC_ERROR~;
    }
    bool wide = left.wide || right.wide;
    HString* s = hstring_alloc_storage(heap_ptr, (uint)len, wide, hash, cap)!;
    char* dest = s.data_ptr();
    copy_units(dest, wide, left);
    copy_units(dest + ((usz)left.len << (wide ? 1 : 0)), wide, right);
    s.finish_data();
    return s;
}

// Append `tail` to a concat accumulator in place, if it has the spare capacity,
// widening the accumulator when `tail` is wide. Returns false when it does not,
// leaving the string untouched so the caller falls back to allocating a fresh one.
//
// The caller must have established that `self` is safe to mutate: non-interned,
// not a symbol, and reachable from exactly one VM register. See the guard in
// the ADD opcode's string path, which is the only caller.
fn bool HString.try_append_in_place(&self, Units tail) {
    ulong need = (ulong)self.length + (ulong)tail.len;
    bool widen = tail.wide && !self.flags.is_wide;
    bool wide = tail.wide || self.flags.is_wide;
    // Widening gives up the last byte of capacity to the longer terminator, so
    // `alloc_size` stays what the allocation was made with.
    ulong need_bytes = (need << (wide ? 1 : 0)) + (widen ? 1uL : 0uL);
    if (need_bytes > (ulong)self.capacity) { return false; }

    char* dest = self.data_ptr();
    if (widen) {
        ushort* wide_dest = (ushort*)dest;
        for (uint i = self.length; i > 0; i--) wide_dest[i - 1] = dest[i - 1];
        self.flags.is_wide = true;
        self.flags.is_ascii = false;
        self.capacity--;
    }
    usz tail_off = (usz)self.length << (wide ? 1 : 0);
    copy_units(dest + tail_off, wide, tail);
    self.length = (uint)need;
    dest[self.byte_len()] = 0;
    if (wide) dest[self.byte_len() + 1] = 0;

    // The units changed, so every content-derived field has to be rebuilt or
    // invalidated. A hash is O(length) and would reintroduce the quadratic cost
    // the in-place append exists to remove, so it is deferred to content_hash.
    self.hash = HASH_DEFERRED;
    if (self.flags.is_ascii && (tail.wide || !check_is_ascii(tail.ptr[:tail.len]))) {
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

// Continue a 32-bit FNV-1a hash from `h` over `data`, one unit at a time, so a
// string hashes by content whatever its width.
fn uint hash_units(uint h, Units data) {
    if (data.wide) {
        foreach (u : ((ushort*)data.ptr)[:data.len]) {
            h ^= (uint)u;
            h *= FNV1A_PRIME;
        }
    } else {
        foreach (b : data.ptr[:data.len]) {
            h ^= (uint)b;
            h *= FNV1A_PRIME;
        }
    }
    return h;
}

// Compute a 32-bit FNV-1a hash of the narrow units `data`.
//
// Unseeded, for use outside a heap context such as bootstrap, before the
// heap's hash seed exists. Heap.hash_units is the seeded version.
fn uint hash_string(char[] data) {
    return hash_units(FNV1A_OFFSET_BASIS, narrow_units(data));
}

// ============================================================================
// UTF-8 utilities
// ============================================================================

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

// True when every unit of `data` is at most 0xFF, so a wide run can be stored narrow.
fn bool fits_latin1(Units data) {
    if (!data.wide) return true;
    foreach (u : ((ushort*)data.ptr)[:data.len]) {
        if (u > 0xFF) return false;
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
// An ECMAScript string is a sequence of 16-bit code units, not Unicode
// codepoints. Source, property, and index semantics represent an astral
// codepoint (>= U+10000) as a pair of surrogate code units, which is what makes
// `"\u{1F600}".length === 2`. Lone surrogates, such as an unpaired half written
// as \u{D800}, are permitted.
//
// Text crossing the engine's byte boundaries, such as source, literals and
// StrBuf contents, is UTF-8 or CESU-8 (WTF-8): each surrogate half encoded as
// its own 3-byte sequence. Interning decodes it to units.
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

// Index of the first occurrence of `needle` in `haystack` at or after `from`,
// or -1. Both are narrow, so a byte is a unit.
fn int find_bytes(char[] haystack, char[] needle, uint from = 0) {
    if (needle.len == 0) return from <= haystack.len ? (int)from : -1;
    if (needle.len > haystack.len) return -1;
    sz last = haystack.len - needle.len;
    sz i = from;
    while (i <= last) {
        // Stop the scan where the needle no longer fits.
        char* hit = libc::memchr(&haystack[i], needle[0], (usz)(last - i + 1));
        if (hit == null) return -1;
        i = (sz)(hit - haystack.ptr);
        if (haystack[i : needle.len] == needle) return (int)i;
        i++;
    }
    return -1;
}

// Index of the last occurrence of `needle` that starts at or before `from`, or -1.
fn int rfind_bytes(char[] haystack, char[] needle, uint from) {
    if (needle.len > haystack.len) return -1;
    if (needle.len == 0) return (int)min((sz)from, haystack.len);
    sz start = min((sz)from, haystack.len - needle.len);
    for (sz i = start; i >= 0; i--) {
        if (haystack[i] == needle[0] && haystack[i : needle.len] == needle) return (int)i;
    }
    return -1;
}

// Byte length of the UTF-16 code unit starting at `data[offset]` in CESU-8
// storage. Every code unit, whether BMP or a surrogate half, is its own 1 to 4
// byte sequence, so this does what `utf8_seq_len` does. The separate name lets
// call sites read as "advance one code unit".
fn uint utf16_unit_byte_len(char[] data, uint offset) @inline {
    return utf8_seq_len(data[offset]);
}

// AdvanceStringIndex over units: the index after the character at `index`,
// which is a surrogate pair's two units when `unicode` is set.
fn uint advance_string_index(HString* s, uint index, bool unicode) {
    if (unicode && index + 1 < s.unit_len() && is_high_surrogate(s.unit_at(index))
        && is_low_surrogate(s.unit_at(index + 1))) return index + 2;
    return index + 1;
}

// ES `AdvanceStringIndex(S, index, unicode)`: the byte width to advance past
// a zero-length match at `data[offset]`. Under `unicode`, if the code unit
// at `offset` is a high surrogate immediately followed by a low surrogate,
// the pair advances together (matches astral characters); otherwise (or
// without `unicode`) a single code unit advances.
fn uint advance_string_index_byte_len(char[] data, uint offset, bool unicode) {
    // At offset == data.len (an empty global match past the last char), ECMA-262
    // AdvanceStringIndex advances by one. Return 1 without reading data[offset].
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

// The code point at `text[*pos]` in UTF-8 or CESU-8 text, advancing `*pos` past
// it. A malformed byte is U+FFFD and advances one byte. A surrogate half in
// 3-byte form is returned as the half, so the caller sees the unit it encodes.
fn uint next_text_codepoint(char[] text, usz* pos) {
    usz i = *pos;
    uint b0 = (uint)text[i];
    if (b0 < 0x80) {
        *pos = i + 1;
        return b0;
    }
    uint seq = utf8_seq_len(text[i]);
    uint cp = decode_codepoint(text, (uint)i);
    bool valid = cp != UNICODE_REPLACEMENT
        || (seq == 3 && i + 2 < text.len && text[i + 1] == 0xBF && text[i + 2] == 0xBD);
    *pos = i + (valid ? seq : 1);
    return cp;
}

// Decode UTF-8 or CESU-8 `text` to UTF-16 units: a 4-byte sequence or a
// surrogate pair of 3-byte ones becomes a pair, a lone surrogate stays one unit,
// and a malformed byte becomes U+FFFD. The units go to `out` as `ushort`s when
// `wide` and as bytes otherwise, or nowhere when `out` is null. Returns the unit
// count and sets `*above_latin1` when a unit exceeds 0xFF, which a counting pass
// uses to choose the width. When writing, `cap` bounds the units written; text
// that decodes to more returns `uint::max` with `out` filled only up to `cap`.
fn uint decode_text(char[] text, char* out, bool wide, bool* above_latin1, uint cap = uint::max) {
    uint n = 0;
    bool high = false;
    usz i = 0;
    usz len = text.len;
    char* p = text.ptr;
    while (i < len) {
        // Runs of ASCII move eight bytes at a time.
        while (i + 8 <= len) {
            ulong word;
            mem::copy(&word, p + i, 8);
            if ((word & HIGH_BITS) != 0) break;
            if (out != null) {
                if (cap - n < 8) return uint::max;
                if (wide) {
                    for (uint k = 0; k < 8; k++) ((ushort*)out)[n + k] = (ushort)p[i + k];
                } else {
                    mem::copy(out + n, p + i, 8);
                }
            }
            n += 8;
            i += 8;
        }
        if (i >= len) break;
        uint b0 = (uint)p[i];
        uint unit;
        if (b0 < 0x80) {
            unit = b0;
            i++;
        } else if (b0 >= 0xC2 && b0 < 0xE0 && i + 1 < len && ((uint)p[i + 1] & 0xC0) == 0x80) {
            unit = ((b0 & 0x1F) << 6) | ((uint)p[i + 1] & 0x3F);
            i += 2;
        } else if ((b0 & 0xF0) == 0xE0 && i + 2 < len
                   && ((uint)p[i + 1] & 0xC0) == 0x80 && ((uint)p[i + 2] & 0xC0) == 0x80
                   && (((b0 & 0x0F) << 12) | (((uint)p[i + 1] & 0x3F) << 6) | ((uint)p[i + 2] & 0x3F)) >= 0x800) {
            unit = ((b0 & 0x0F) << 12) | (((uint)p[i + 1] & 0x3F) << 6) | ((uint)p[i + 2] & 0x3F);
            i += 3;
        } else {
            // A 4-byte sequence or malformed input.
            uint cp = next_text_codepoint(text, &i);
            if (cp >= ASTRAL_START) {
                uint lead; uint trail;
                codepoint_to_surrogates(cp, &lead, &trail);
                if (out != null) {
                    if (cap - n < 2) return uint::max;
                    if (wide) { ((ushort*)out)[n] = (ushort)lead; ((ushort*)out)[n + 1] = (ushort)trail; }
                    else { out[n] = (char)lead; out[n + 1] = (char)trail; }
                }
                high = true;
                n += 2;
                continue;
            }
            unit = cp;
        }
        if (out != null) {
            if (n >= cap) return uint::max;
            if (wide) { ((ushort*)out)[n] = (ushort)unit; } else { out[n] = (char)unit; }
        }
        if (unit > 0xFF) high = true;
        n++;
    }
    *above_latin1 = high;
    return n;
}

// The unit count and width of `text` if it is well-formed: one unit per byte that
// does not continue a sequence, a second for each 4-byte lead, and a unit above
// 0xFF wherever a lead is 0xC4 or more. Malformed text can differ from what
// `decode_text` finds, so a caller checks the decode against these.
fn uint estimate_text_units(char[] text, bool* above_latin1) {
    uint units = 0;
    uint high = 0;
    foreach (b : text) {
        units += (uint)((b & 0xC0) != 0x80) + (uint)(b >= 0xF0);
        high |= (uint)(b >= 0xC4);
    }
    *above_latin1 = high != 0;
    return units;
}

// True when some unit of `data` exceeds 0xFF, so that a wide run is already in
// canonical width.
fn bool has_unit_above_latin1(Units data) {
    if (!data.wide) return false;
    foreach (u : ((ushort*)data.ptr)[:data.len]) {
        if (u > 0xFF) return true;
    }
    return false;
}

// Bytes the code unit `u` takes in UTF-8 form.
fn usz unit_text_len(uint u) @inline => u < 0x80 ? 1 : (u < 0x800 ? 2 : 3);

// Rewrite UTF-8 or CESU-8 `text` as canonical CESU-8: each UTF-16 unit encoded
// on its own, so two spellings of one string, such as an astral character typed
// raw and the same character as a surrogate pair, produce the same bytes.
// Writes to `dst` and returns the byte count, or only counts when `dst` is null.
fn usz canonical_cesu8(char[] text, char* dst) {
    usz n = 0;
    usz i = 0;
    while (i < text.len) {
        uint cp = next_text_codepoint(text, &i);
        uint[2] units;
        uint count = 1;
        if (cp >= ASTRAL_START) {
            codepoint_to_surrogates(cp, &units[0], &units[1]);
            count = 2;
        } else {
            units[0] = cp;
        }
        for (uint k = 0; k < count; k++) {
            if (dst != null) encode_codepoint(units[k], dst[n:3]);
            n += unit_text_len(units[k]);
        }
    }
    return n;
}

// Function pointer type for a single-byte output sink, used by
// `write_cesu8_as_utf8`. The `udata` pointer is passed through untouched, so a
// sink that accumulates into a caller-owned buffer needs no global to find it.
alias PutByteFn = fn void(char, void*);

// Write CESU-8 `data` to a byte sink as standard UTF-8. Surrogate pairs recombine into their astral codepoint
// and re-encode as one 4-byte sequence, and everything else passes through.
// Unpaired surrogates become U+FFFD, which standard UTF-8 has no way to
// represent, unless `keep_lone` writes each as its own 3-byte sequence (WTF-8)
// for a consumer that must see the exact code units.
//
// Text built in a StrBuf reaches the host through here, so nothing outside the
// engine sees a raw surrogate-half sequence.
fn void write_cesu8_as_utf8(char[] data, PutByteFn put_byte_fn, void* udata = null, bool keep_lone = false) {
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
        if (is_surrogate(cp) && !keep_lone) {
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
// Width-neutral accessors
//
// Builtins read strings through these and rarely see the stored width. A string
// is a sequence of `unit_len()` UTF-16 code units; `unit_at(i)` reads one. The
// sequence may hold lone surrogates, and an astral character is two units.
// ============================================================================

// The characters of an ASCII string as bytes, which are also valid UTF-8. Only
// meaningful when `is_ascii()` holds; callers branch on that for their fast path.
fn char[] HString.ascii_bytes(&self) @inline {
    assert(self.flags.is_ascii);
    return self.latin1();
}

// Text to match against ASCII tokens such as option values, unit names and
// language tags. A string with any non-ASCII unit yields a lone 0xFF byte, which
// is not UTF-8 and equals no token.
fn char[] HString.token_text(&self) @inline {
    return self.flags.is_ascii ? self.latin1() : (char[])"\xFF";
}

// Index of the first occurrence of `needle` in `hay` at or after unit `from`,
// or -1. `from` must not exceed `hay.unit_len()`.
fn int find_units(HString* hay, HString* needle, uint from) {
    if (needle.length == 0) return (int)from;
    // A wide needle holds a unit no narrow haystack can.
    if (needle.length > hay.length || (needle.flags.is_wide && !hay.flags.is_wide)) return -1;
    if (!hay.flags.is_wide) return find_bytes(hay.latin1(), needle.latin1(), from);
    ushort* data = (ushort*)hay.data_ptr();
    uint first = needle.unit_at(0);
    uint last = hay.length - needle.length;
    for (uint i = from; i <= last; i++) {
        if (data[i] != first) continue;
        uint k = 1;
        while (k < needle.length && data[i + k] == needle.unit_at(k)) k++;
        if (k == needle.length) return (int)i;
    }
    return -1;
}

// Index of the last occurrence of `needle` in `hay` that starts at or before
// unit `from`, or -1. `from` must not exceed `hay.unit_len()`.
fn int rfind_units(HString* hay, HString* needle, uint from) {
    if (needle.length > hay.length || (needle.flags.is_wide && !hay.flags.is_wide)) return -1;
    if (!hay.flags.is_wide) return rfind_bytes(hay.latin1(), needle.latin1(), from);
    ushort* data = (ushort*)hay.data_ptr();
    uint start = from < hay.length - needle.length ? from : hay.length - needle.length;
    for (int i = (int)start; i >= 0; i--) {
        uint k = 0;
        while (k < needle.length && data[(uint)i + k] == needle.unit_at(k)) k++;
        if (k == needle.length) return i;
    }
    return -1;
}

// True when the string holds no lone surrogate unit.
fn bool HString.is_well_formed(&self) {
    if (!self.flags.is_wide) return true;
    uint n = self.length;
    for (uint i = 0; i < n; i++) {
        uint u = self.unit_at(i);
        if (is_high_surrogate(u) && i + 1 < n && is_low_surrogate(self.unit_at(i + 1))) {
            i++;
        } else if (is_surrogate(u)) {
            return false;
        }
    }
    return true;
}

// True when both strings hold the same code units. Symbols compare by content
// here; use `equals_hstring` for identity-aware equality.
fn bool units_equal(HString* a, HString* b) {
    return a == b || a.same_units(b);
}

// Write the units `[from, to)`, which must not split a surrogate pair, to a
// byte sink as standard UTF-8. A lone surrogate is written as U+FFFD, or as its
// own 3-byte sequence when `keep_lone` is set.
//
// Every host-visible text boundary goes through here or `write_cesu8_as_utf8`,
// including print, console.log, and file I/O.
fn void HString.write_utf8_range(&self, uint from, uint to, PutByteFn put_byte_fn,
                                 void* udata = null, bool keep_lone = false) {
    self.units().write_utf8_range(from, to, put_byte_fn, udata, keep_lone);
}

// Write the units `[from, to)` to a byte sink as standard UTF-8; see
// `HString.write_utf8_range`.
fn void Units.write_utf8_range(&self, uint from, uint to, PutByteFn put_byte_fn,
                               void* udata = null, bool keep_lone = false) {
    for (uint i = from; i < to; i++) {
        uint u = self.at(i);
        if (u < 0x80) {
            put_byte_fn((char)u, udata);
            continue;
        }
        if (is_high_surrogate(u) && i + 1 < to && is_low_surrogate(self.at(i + 1))) {
            u = surrogates_to_codepoint(u, self.at(i + 1));
            i++;
        } else if (is_surrogate(u) && !keep_lone) {
            u = UNICODE_REPLACEMENT;
        }
        char[4] buf;
        uint n = encode_codepoint(u, buf[:4]);
        for (uint k = 0; k < n; k++) put_byte_fn(buf[k], udata);
    }
}

// Write the string to a byte sink as standard UTF-8; see `write_utf8_range`.
fn void HString.write_utf8(&self, PutByteFn put_byte_fn, void* udata = null, bool keep_lone = false) {
    self.write_utf8_range(0, self.length, put_byte_fn, udata, keep_lone);
}

struct Utf8Cursor @private {
    char* dst;
    usz   n;
}

fn void utf8_cursor_put(char c, void* udata) @private {
    Utf8Cursor* cur = (Utf8Cursor*)udata;
    if (cur.dst != null) cur.dst[cur.n] = c;
    cur.n++;
}

// The number of bytes `write_utf8` produces for this string with the same `keep_lone`.
fn usz HString.utf8_len(&self, bool keep_lone = false) {
    if (self.flags.is_ascii) return self.length;
    Utf8Cursor cur = {};
    self.write_utf8(&utf8_cursor_put, &cur, keep_lone);
    return cur.n;
}

// Write `utf8_len(keep_lone)` bytes of UTF-8 text to `dst`, with no terminator.
fn void HString.copy_utf8(&self, char* dst, bool keep_lone = false) {
    Utf8Cursor cur = { .dst = dst };
    self.write_utf8(&utf8_cursor_put, &cur, keep_lone);
}

// Write `unit_len()` UTF-16 code units to `dst`, with no terminator.
fn void HString.copy_utf16(&self, ushort* dst) {
    copy_units((char*)dst, true, self.units());
}

// True when `data` is well-formed UTF-8: no overlong forms, no surrogates, no
// code point above U+10FFFF, and no truncated sequence.
fn bool utf8_valid(char[] data) {
    usz i = 0;
    while (i < data.len) {
        uint b0 = (uint)data[i];
        if (b0 < 0x80) { i++; continue; }
        uint extra;
        uint min_cp;
        uint cp;
        if ((b0 & 0xE0) == 0xC0)      { extra = 1; min_cp = 0x80;    cp = b0 & 0x1F; }
        else if ((b0 & 0xF0) == 0xE0) { extra = 2; min_cp = 0x800;   cp = b0 & 0x0F; }
        else if ((b0 & 0xF8) == 0xF0) { extra = 3; min_cp = 0x10000; cp = b0 & 0x07; }
        else { return false; }
        if (i + (usz)extra >= data.len) return false;
        for (uint k = 1; k <= extra; k++) {
            uint b = (uint)data[i + (usz)k];
            if ((b & 0xC0) != 0x80) return false;
            cp = (cp << 6) | (b & 0x3F);
        }
        if (cp < min_cp || cp > 0x10FFFF || is_surrogate(cp)) return false;
        i += (usz)extra + 1;
    }
    return true;
}

struct Utf8Fill @private {
    char[] dst;
    usz    n;
    usz    fit;   // the last character boundary within `dst`
}

fn void utf8_fill_put(char c, void* udata) @private {
    Utf8Fill* fill = (Utf8Fill*)udata;
    if (((uint)c & 0xC0) != 0x80 && fill.n <= fill.dst.len) fill.fit = fill.n;
    if (fill.n < fill.dst.len) fill.dst[fill.n] = c;
    fill.n++;
}

// Write as much of the string's UTF-8 text into `dst` as fits without splitting
// a character, with no terminator. Returns the bytes written.
fn usz HString.utf8_copy_truncated(&self, char[] dst) {
    Utf8Fill fill = { .dst = dst };
    self.write_utf8(&utf8_fill_put, &fill);
    return fill.n <= dst.len ? fill.n : fill.fit;
}

// True when `needle` occurs in this string starting at unit `pos`.
fn bool HString.matches_at(&self, uint pos, HString* needle) {
    if ((ulong)pos + needle.length > self.length) return false;
    if (needle.flags.is_wide && !self.flags.is_wide) return false;
    if (self.flags.is_wide == needle.flags.is_wide) {
        return mem::equals(self.data_ptr() + ((usz)pos << (self.flags.is_wide ? 1 : 0)),
                           needle.data_ptr(), (sz)needle.byte_len());
    }
    for (uint k = 0; k < needle.length; k++) {
        if (self.unit_at(pos + k) != needle.unit_at(k)) return false;
    }
    return true;
}

// The string as a C string for a message, built in `buf` as `write_cesu8` does.
fn ZString HString.cesu8_zstr(&self, char[] buf) {
    self.write_cesu8(buf);
    return (ZString)buf.ptr;
}

// Copy the string into `dst` as CESU-8 text, always NUL-terminated, truncated at
// a unit boundary when it does not fit. Returns the bytes written before the NUL.
// `dst` must hold at least one byte.
fn usz HString.write_cesu8(&self, char[] dst) {
    usz n = 0;
    for (uint i = 0; i < self.length; i++) {
        char[3] buf;
        usz k = encode_codepoint(self.unit_at(i), buf[:3]);
        if (n + k > dst.len - 1) break;
        mem::copy(dst.ptr + n, &buf, (sz)k);
        n += k;
    }
    dst[n] = 0;
    return n;
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

// The decimal digits of 0 through 99, two bytes each.
const String DIGIT_PAIRS = "00010203040506070809101112131415161718192021222324252627282930313233343536373839404142434445464748495051525354555657585960616263646566676869707172737475767778798081828384858687888990919293949596979899";

// Write `val` into `buf` as decimal digits, returning how many bytes it wrote,
// or 0 if the buffer was too small. `cap` must be at least 2, and 21 bytes
// holds any int64.
fn int int_to_buf(long val, char* buf, usz cap) @inline {
    if (cap < 2) return 0;
    bool neg = val < 0;
    ulong uval = neg ? -(ulong)val : (ulong)val;
    // Count the digits first so they are written in place, last digit first,
    // with no shift of a right-aligned buffer afterwards.
    usz len = (usz)int_string_length(val);
    if (len > cap) return 0;
    char* out = buf + len;
    while (uval >= 100) {
        ulong quotient = uval / 100;
        usz pair = (usz)(uval - quotient * 100) * 2;
        uval = quotient;
        out -= 2;
        out[0] = DIGIT_PAIRS[pair];
        out[1] = DIGIT_PAIRS[pair + 1];
    }
    if (uval >= 10) {
        out -= 2;
        out[0] = DIGIT_PAIRS[uval * 2];
        out[1] = DIGIT_PAIRS[uval * 2 + 1];
    } else {
        *--out = (char)('0' + uval);
    }
    if (neg) buf[0] = '-';
    return (int)len;
}

fn uint int_string_length(long val) @inline {
    bool neg = val < 0;
    ulong magnitude = neg ? -(ulong)val : (ulong)val;
    uint digits = 1;
    for (ulong bound = 10; digits < 20 && magnitude >= bound; bound *= 10) digits++;
    return digits + (neg ? 1u : 0u);
}

// Parts have completed ToString, except fastints formatted into final storage.
// `len` is the total length in units and `wide` whether any part is wide.
fn HString*? hstring_alloc_join(void* heap_ptr, TVal[] parts, uint len, bool wide) {
    HString* s = hstring_alloc_storage(heap_ptr, len, wide, HASH_DEFERRED, len)!;
    char* dest = s.data_ptr();
    usz offset = 0;
    foreach (part : parts) {
        if (part.is_fastint()) {
            char[24] digits;
            usz n = (usz)int_to_buf(part.get_fastint(), &digits, digits.len);
            copy_units(dest + (offset << (wide ? 1 : 0)), wide, narrow_units(digits[:n]));
            offset += n;
        } else {
            HString* text = (HString*)part.get_heapptr();
            copy_units(dest + (offset << (wide ? 1 : 0)), wide, text.units());
            offset += text.length;
        }
    }
    s.finish_data();
    return s;
}
