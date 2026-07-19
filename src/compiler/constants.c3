module duktape::compiler;

import duktape::types;
import duktape::lexer;
import duktape::bytecode;
import duktape::hstring;
import duktape::hbigint;
import duktape::hobject;
import duktape::heap;
import std::io;

// ============================================================================
// Constant pool
// ============================================================================

/// Look up a constant in the hash table and return its index, or const_count if not found.
fn uint CompilerContext.lookup_constant_hash(&self, ulong val_bits) {
    if (self.const_hash == null || self.const_hash_cap == 0) return self.const_count;
    // Use the low bits of the TVal as initial hash probe
    uint hash = (uint)(val_bits >> 1) % self.const_hash_cap;

    // Linear probe: find empty slot or matching entry
    for (uint attempt = 0; attempt < self.const_hash_cap; attempt++) {
        uint idx = (hash + attempt) % self.const_hash_cap;
        if (self.const_hash[idx].hash == 0) {
            // Empty slot: not found
            return self.const_count;
        }
        if (self.const_hash[idx].hash == val_bits) {
            // Found matching entry
            return self.const_hash[idx].index;
        }
    }
    // Hash table full (shouldn't happen if maintained correctly)
    return self.const_count;
}

/// Insert a constant into the hash table.
///
/// Skipped once the table reaches its fill cap (later constants are then
/// appended without dedup) and for all-zero bits, which are
/// indistinguishable from an empty slot.
fn void CompilerContext.insert_constant_hash(&self, ulong val_bits, uint idx) {
    if (self.const_hash == null || self.const_hash_count >= self.const_hash_fill || val_bits == 0) {
        return;
    }
    uint hash = (uint)(val_bits >> 1) % self.const_hash_cap;

    // Linear probe: find empty slot
    for (uint attempt = 0; attempt < self.const_hash_cap; attempt++) {
        uint slot = (hash + attempt) % self.const_hash_cap;
        if (self.const_hash[slot].hash == 0) {
            self.const_hash[slot].hash = val_bits;
            self.const_hash[slot].index = idx;
            self.const_hash_count++;
            return;
        }
    }
}

/// Add a TVal to the constant pool and return its index.
fn uint CompilerContext.add_constant(&self, TVal val) {
    ulong val_bits = val.get_raw_bits();
    TValTag tag = val.get_tag();

    // Only deduplicate numbers and fastints via hash table;
    // strings are handled separately via add_string_constant.
    if (tag == NUMBER || tag == FASTINT) {
        uint found_idx = self.lookup_constant_hash(val_bits);
        if (found_idx < self.const_count) {
            return found_idx;
        }
    }

    self.ensure_const_cap();
    if (self.const_count >= self.const_cap) {
        return self.const_count;  // hard cap
    }
    uint idx = self.const_count;
    self.constants[idx] = val;

    // Insert into hash table for future lookups
    if (tag == NUMBER || tag == FASTINT) {
        self.insert_constant_hash(val_bits, idx);
    }

    self.const_count++;
    return idx;
}

/// Add a string constant: intern the string and add a STRING TVal to the pool.
fn uint CompilerContext.add_string_constant(&self, char[] str) {
    // Intern via Heap.str_intern (not a hand-rolled lookup/alloc) so raw
    // 4-byte UTF-8 astral sequences in source literals get normalized to
    // CESU-8 the same way any other interned string does — otherwise a
    // literal emoji typed in source and the same character via `\u{...}`
    // would intern under two different byte encodings and fail `===`.
    Heap* hp = (Heap*)self.heap;
    HString* hstr = hp.str_intern(str);

    TVal tv;
    if (hstr != null) {
        tv.set_string(hstr);
    } else {
        // Fallback: store as pointer with null
        tv.set_string(null);
    }

    ulong val_bits = tv.get_raw_bits();

    // Check if this string (by pointer) is already in the constant pool
    uint found_idx = self.lookup_constant_hash(val_bits);
    if (found_idx < self.const_count) {
        // The pool entry already holds its references; release the one taken
        // by set_string above.
        if (hstr != null) { hp.decref((types::HeapHeader*)hstr); }
        return found_idx;
    }

    self.ensure_const_cap();
    if (self.const_count >= self.const_cap) {
        return self.const_count;
    }
    uint idx = self.const_count;
    self.constants[idx] = tv;
    // Insert into hash table for future lookups
    self.insert_constant_hash(val_bits, idx);
    if (hstr != null) { ((types::HeapHeader*)hstr).incref(); }
    self.const_count++;
    return idx;
}

/// Add a number constant and return its index.
fn uint CompilerContext.add_number_constant(&self, double val) {
    TVal tv;
    tv.set_number(val);
    return self.add_constant(tv);
}

/// Add a BigInt constant and return its index.
///
/// `digits` is the lexer's literal text (possibly carrying a `0x`/`0o`/`0b`
/// radix prefix and `_` separators).  It is parsed into a native int128 and
/// boxed as an HBigInt.  A literal exceeding ±(2^127 − 1) — beyond this
/// engine's fixed-width BigInt range — is a compile error (RangeError-ish).
fn uint? CompilerContext.add_bigint_constant(&self, char[] digits) {
    Heap* hp = (Heap*)self.heap;

    int128? parsed = hbigint::parse_bigint_literal(digits);
    if (catch excuse = parsed) {
        if (excuse == hbigint::BIGINT_OVERFLOW) {
            set_compile_error("BigInt value exceeds supported precision");
        } else {
            set_compile_error("Invalid BigInt literal");
        }
        return COMPILE_ERROR~;
    }

    // Box the value.  hbigint_alloc registers it on the mark-and-sweep list and
    // flags it a temproot; the constant-pool slot below is its anchoring ref.
    hbigint::HBigInt*? box_r = hbigint::hbigint_alloc(hp, parsed);
    if (catch box_r) {
        set_compile_error("out of memory allocating BigInt");
        return COMPILE_ERROR~;
    }
    hbigint::HBigInt* box = box_r;

    // Wrap as a BIGINT TVal (set_bigint does an incref → refcount now 2:
    // the alloc's initial ref + this one).  Release the alloc's initial ref so
    // the pool slot holds exactly one reference.
    TVal tv;
    tv.set_bigint(box);
    hp.decref((types::HeapHeader*)box);

    ulong val_bits = tv.get_raw_bits();

    self.ensure_const_cap();
    if (self.const_count >= self.const_cap) {
        // No pool slot available — drop our reference.
        hp.decref((types::HeapHeader*)box);
        return self.const_count;
    }
    uint idx = self.const_count;
    self.constants[idx] = tv;
    self.insert_constant_hash(val_bits, idx);
    self.const_count++;
    return idx;
}
