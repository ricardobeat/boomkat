// UnitBuf: a growable buffer of UTF-16 code units for builtins that assemble a
// string whose size is not known up front.
module boomkat::builtins;

import boomkat::heap;
import boomkat::hstring;

// Bytes held inline before the first heap allocation, so short results never
// touch the allocator. A narrow buffer holds this many units, a wide one half.
const usz UNITBUF_INLINE_BYTES = 256;

// The units sit in one block, a byte each (Latin-1) while every unit is at most
// 0xFF and two bytes each (UTF-16, native endian) once one is not. The buffer
// widens on demand and only then, so its contents are always in canonical width
// and `units()` can become a string without a conversion or a rescan.
//
// Every append reports allocation failure through a `bool` return rather than
// truncating, and the first failure also sticks in `failed`. A builtin that
// stopped appending silently would hand back a well-formed-looking but corrupt
// result, which is worse than an error. An append that would pass the longest
// string fails the same way, since the result could only end as the RangeError
// `to_hstring` raises.
//
// Pass this by pointer, not by value: a buffer still in its inline storage
// points `data` at itself, so a copy would inherit a pointer into the original.
struct UnitBuf {
    Heap*  heap;
    char*  data;      /// Points at `inline_units` until the first growth.
    usz    len;       /// Units.
    usz    cap_bytes;
    bool   wide;
    bool   failed;
    ushort[UNITBUF_INLINE_BYTES / 2] inline_units;
}

fn void UnitBuf.init(&self, Heap* heap) {
    self.heap = heap;
    self.data = (char*)&self.inline_units[0];
    self.len = 0;
    self.cap_bytes = UNITBUF_INLINE_BYTES;
    self.wide = false;
    self.failed = false;
}

// Release the heap block, if the buffer ever outgrew its inline storage.
fn void UnitBuf.free(&self) {
    if (self.data != null && self.data != (char*)&self.inline_units[0]) {
        self.heap.free_func(self.heap.heap_udata, self.data);
    }
    self.data = (char*)&self.inline_units[0];
    self.len = 0;
    self.cap_bytes = UNITBUF_INLINE_BYTES;
    self.wide = false;
}

// Empty the buffer, keeping its storage. It narrows again only if the storage
// is the inline block, which has room for either width.
fn void UnitBuf.clear(&self) {
    self.len = 0;
    self.wide = false;
    self.failed = false;
}

// Drop the units from `len` on, keeping the first `len`. The buffer narrows
// again when no unit that remains needs two bytes, so its width stays canonical.
fn void UnitBuf.truncate(&self, usz len) {
    if (len >= self.len) return;
    self.len = len;
    if (!self.wide) return;
    ushort* units = (ushort*)self.data;
    for (usz i = 0; i < len; i++) {
        if (units[i] > 0xFF) return;
    }
    char* narrow = self.data;
    for (usz i = 0; i < len; i++) narrow[i] = (char)units[i];
    self.wide = false;
}

fn usz UnitBuf.cap(&self) @inline => self.cap_bytes >> (self.wide ? 1 : 0);

// The units appended so far, valid until the next append.
fn hstring::Units UnitBuf.units(&self) @inline {
    return { .ptr = self.data, .len = (uint)self.len, .wide = self.wide };
}

// Grow the block to at least `bytes`, keeping its contents.
fn bool UnitBuf.grow_bytes(&self, usz bytes) {
    if (bytes <= self.cap_bytes) return true;
    usz new_cap = self.cap_bytes;
    while (new_cap < bytes) {
        if (new_cap > (usz)-1 / 2) return false;
        new_cap *= 2;
    }
    // The callers have checked `bytes` against the longest string, so the clamp
    // keeps the capacity at least what is needed.
    usz limit = (usz)hstring::MAX_STRING_LENGTH << 1;
    if (new_cap > limit) new_cap = limit;
    char* grown;
    if (self.data == (char*)&self.inline_units[0]) {
        grown = (char*)self.heap.alloc_func(self.heap.heap_udata, new_cap);
        if (grown == null) return false;
        if (self.len > 0) mem::copy(grown, self.data, (sz)(self.len << (self.wide ? 1 : 0)));
    } else {
        grown = (char*)self.heap.realloc_func(self.heap.heap_udata, self.data, new_cap);
        if (grown == null) return false;
    }
    self.data = grown;
    self.cap_bytes = new_cap;
    return true;
}

// Ensure room for `extra` more units at the current width.
fn bool UnitBuf.reserve(&self, usz extra) {
    usz need = self.len + extra;
    if (need <= self.cap()) return true;
    if (!hstring::length_exceeds_max((ulong)need)
        && self.grow_bytes(need << (self.wide ? 1 : 0))) return true;
    self.failed = true;
    return false;
}

// Switch to two bytes per unit, with room for `extra` more units.
fn bool UnitBuf.widen(&self, usz extra) {
    if (self.wide) return self.reserve(extra);
    usz need = self.len + extra;
    if (hstring::length_exceeds_max((ulong)need) || !self.grow_bytes(need << 1)) {
        self.failed = true;
        return false;
    }
    char* narrow = self.data;
    ushort* units = (ushort*)self.data;
    for (usz i = self.len; i > 0; i--) units[i - 1] = (ushort)narrow[i - 1];
    self.wide = true;
    return true;
}

// Append one narrow unit, U+0000 to U+00FF.
fn bool UnitBuf.append_char(&self, char c) @inline {
    if (self.len >= self.cap() && !self.reserve(1)) return false;
    if (self.wide) {
        ((ushort*)self.data)[self.len++] = (ushort)(uint)c;
    } else {
        self.data[self.len++] = c;
    }
    return true;
}

// Append one UTF-16 code unit, which may be a lone surrogate.
fn bool UnitBuf.append_unit(&self, uint unit) {
    if (unit > 0xFF && !self.wide && !self.widen(1)) return false;
    if (self.len >= self.cap() && !self.reserve(1)) return false;
    if (self.wide) {
        ((ushort*)self.data)[self.len++] = (ushort)unit;
    } else {
        self.data[self.len++] = (char)unit;
    }
    return true;
}

// Append one code point, an astral one as its surrogate pair.
fn bool UnitBuf.append_codepoint(&self, uint cp) {
    if (cp < hstring::ASTRAL_START) return self.append_unit(cp);
    uint high; uint low;
    hstring::codepoint_to_surrogates(cp, &high, &low);
    return self.append_unit(high) && self.append_unit(low);
}

// Append `text`, one unit per byte. A literal is ASCII, and any byte is a
// Latin-1 unit.
fn bool UnitBuf.append_latin1(&self, char[] text) @inline {
    if (!self.wide && self.len + text.len <= self.cap_bytes) {
        hstring::copy_short(self.data + self.len, text.ptr, text.len);
        self.len += text.len;
        return true;
    }
    return self.append_latin1_slow(text);
}

fn bool UnitBuf.append_latin1_slow(&self, char[] text) @noinline {
    if (text.len == 0) return true;
    if (!self.reserve(text.len)) return false;
    if (self.wide) {
        ushort* dst = (ushort*)self.data + self.len;
        foreach (i, c : text) dst[i] = (ushort)(uint)c;
    } else {
        hstring::copy_short(self.data + self.len, text.ptr, text.len);
    }
    self.len += text.len;
    return true;
}

// Append `count` copies of the narrow unit `c`.
fn bool UnitBuf.append_fill(&self, char c, usz count) {
    if (count == 0) return true;
    if (!self.reserve(count)) return false;
    if (self.wide) {
        ushort* dst = (ushort*)self.data + self.len;
        for (usz i = 0; i < count; i++) dst[i] = (ushort)(uint)c;
    } else {
        mem::set(self.data + self.len, c, (sz)count);
    }
    self.len += count;
    return true;
}

// Append the UTF-16 units `run` of which `has_high` says some exceed 0xFF.
fn bool UnitBuf.append_wide(&self, ushort[] run, bool has_high) {
    if (run.len == 0) return true;
    if (has_high && !self.wide) {
        if (!self.widen(run.len)) return false;
    } else if (!self.reserve(run.len)) {
        return false;
    }
    if (self.wide) {
        mem::copy((ushort*)self.data + self.len, run.ptr, (sz)run.len * 2);
    } else {
        char* dst = self.data + self.len;
        foreach (i, u : run) dst[i] = (char)u;
    }
    self.len += run.len;
    return true;
}

// Append units of either width, narrowing nothing it does not have to: a wide
// run joins a narrow buffer as narrow units unless one of them needs two bytes.
fn bool UnitBuf.append_units(&self, hstring::Units run) @inline {
    if (!run.wide) return self.append_latin1(run.ptr[:run.len]);
    return self.append_wide_units(run);
}

fn bool UnitBuf.append_wide_units(&self, hstring::Units run) @noinline {
    if (run.len == 0) return true;
    ushort[] units = ((ushort*)run.ptr)[:run.len];
    bool high = false;
    if (!self.wide) high = hstring::has_unit_above_latin1(run);
    return self.append_wide(units, high);
}

// Append the whole string.
fn bool UnitBuf.append_hstring(&self, HString* s) {
    return self.append_units(s.units());
}

// Append the units `[from, to)` of `s`.
fn bool UnitBuf.append_hstring_range(&self, HString* s, uint from, uint to) {
    if (from >= to) return true;
    hstring::Units run = s.units();
    run.ptr += (usz)from << (run.wide ? 1 : 0);
    run.len = to - from;
    return self.append_units(run);
}

// Append UTF-8 or CESU-8 `text`, decoded as `Heap.alloc_text` decodes it: a
// 4-byte sequence or a pair of 3-byte surrogate halves becomes a pair, a lone
// half stays one unit, and a malformed byte becomes U+FFFD.
fn bool UnitBuf.append_text(&self, char[] text) {
    if (text.len == 0) return true;
    if (hstring::check_is_ascii(text)) return self.append_latin1(text);
    bool above;
    uint count = hstring::decode_text(text, null, false, &above);
    if (above && !self.wide) {
        if (!self.widen(count)) return false;
    } else if (!self.reserve(count)) {
        return false;
    }
    bool ignored;
    hstring::decode_text(text, self.data + (self.len << (self.wide ? 1 : 0)), self.wide, &ignored, count);
    self.len += count;
    return true;
}

// The units as a string. Like a concatenation result it is not interned:
// hashing and the string table wait until something uses it as a key. Throws a
// RangeError and returns null when an append failed.
fn HString* UnitBuf.to_hstring(&self, BuiltinContext* ctx) {
    HString* result = null;
    if (!self.failed && !hstring::length_exceeds_max((ulong)self.len)) {
        result = self.len == 0 ? ctx.heap.str(heap::BuiltinStr.EMPTY)
            : ctx.heap.alloc_concat_string(self.units(), (uint)self.len);
    }
    if (result == null) builtin_throw(ctx, ctx.heap.range_err_proto, "Invalid string length");
    return result;
}

// The units as an interned string, or null when an append failed or allocation
// did. The caller reports the failure.
fn HString* UnitBuf.intern(&self, Heap* heap) {
    if (self.failed) return null;
    return heap.str_intern_units(self.units());
}

// Make the accumulated string the builtin's result, or throw as `to_hstring` does.
fn void UnitBuf.finish(&self, BuiltinContext* ctx) {
    HString* result = self.to_hstring(ctx);
    if (result != null) ctx.result_string(result);
}
