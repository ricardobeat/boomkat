module boomkat::compiler;

import boomkat::types;
import boomkat::lexer;
import boomkat::bytecode;
import boomkat::hstring;
import boomkat::hbigint;
import boomkat::hobject;
import boomkat::heap;
import std::io;

// ============================================================================
// Constant pool
// ============================================================================

// Look up a constant in the hash table and return its index, or const_count if not found.
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

// Insert a constant into the hash table.
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

// Add a TVal to the constant pool and return its index.
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

// Add a string constant: intern the string and add a STRING TVal to the pool.
// Uses Heap.str_intern so raw 4-byte UTF-8 astral characters normalize to CESU-8,
// ensuring source literals and \u{...} escapes intern to identical byte sequences.
fn uint CompilerContext.add_string_constant(&self, char[] str) {
    Heap* hp = (Heap*)self.heap;
    HString* hstr = hp.str_intern(str);

    TVal tv;
    if (hstr != null) {
        tv.set_string(hstr);
    } else {
        tv.set_string(null);
    }

    ulong val_bits = tv.get_raw_bits();

    // Check if this string (by pointer) is already in the constant pool
    uint found_idx = self.lookup_constant_hash(val_bits);
    if (found_idx < self.const_count) {
        if (hstr != null) { hp.decref((types::HeapHeader*)hstr); }
        return found_idx;
    }

    self.ensure_const_cap();
    if (self.const_count >= self.const_cap) {
        return self.const_count;
    }
    uint idx = self.const_count;
    self.constants[idx] = tv;
    self.insert_constant_hash(val_bits, idx);
    if (hstr != null) { ((types::HeapHeader*)hstr).incref(); }
    self.const_count++;
    return idx;
}

// Add a number constant and return its index.
fn uint CompilerContext.add_number_constant(&self, double val) {
    TVal tv;
    tv.set_number(val);
    return self.add_constant(tv);
}

// Add a BigInt constant and return its index.
fn uint? CompilerContext.add_bigint_constant(&self, char[] digits) {
    Heap* hp = (Heap*)self.heap;

    int128? parsed = hbigint::parse_bigint_literal(digits);
    if (catch excuse = parsed) {
        if (excuse == hbigint::BIGINT_OVERFLOW) {
            self.set_compile_error("BigInt value exceeds supported precision");
        } else {
            self.set_compile_error("Invalid BigInt literal");
        }
        return COMPILE_ERROR~;
    }

    // Box the value. The constant pool slot holds the single anchoring reference.
    hbigint::HBigInt*? box_r = hbigint::hbigint_alloc(hp, parsed);
    if (catch box_r) {
        self.set_compile_error("out of memory allocating BigInt");
        return COMPILE_ERROR~;
    }
    hbigint::HBigInt* box = box_r;

    // Wrap as a BIGINT TVal (increfs). Decref the initial allocation reference so
    // the pool slot retains exactly one reference.
    TVal tv;
    tv.set_bigint(box);
    hp.decref((types::HeapHeader*)box);

    ulong val_bits = tv.get_raw_bits();

    self.ensure_const_cap();
    if (self.const_count >= self.const_cap) {
        // No pool slot available, so drop the reference.
        hp.decref((types::HeapHeader*)box);
        return self.const_count;
    }
    uint idx = self.const_count;
    self.constants[idx] = tv;
    self.insert_constant_hash(val_bits, idx);
    self.const_count++;
    return idx;
}
