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
            return self.const_count;
        }
        if (self.const_hash[idx].hash == val_bits) {
            return self.const_hash[idx].index;
        }
    }
    // Hash table full (shouldn't happen if maintained correctly)
    return self.const_count;
}

// Insert a constant into the hash table.
//
// Skipped once the table reaches its fill cap (later constants are then
// appended without dedup) and for all-zero bits, which are
// indistinguishable from an empty slot.
fn void CompilerContext.insert_constant_hash(&self, ulong val_bits, uint idx) {
    if (self.const_hash == null || self.const_hash_count >= self.const_hash_fill || val_bits == 0) {
        return;
    }
    uint hash = (uint)(val_bits >> 1) % self.const_hash_cap;

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

    if (tag == NUMBER || tag == FASTINT) {
        self.insert_constant_hash(val_bits, idx);
    }

    self.const_count++;
    return idx;
}

// Add a string constant: intern the text and add a STRING TVal to the pool.
fn uint CompilerContext.add_string_constant(&self, char[] str) {
    // Intern via Heap.str_intern so raw 4-byte UTF-8 astral sequences are
    // normalized to the stored form. Otherwise a literal emoji and the same
    // character written as `\u{...}` would intern under different encodings and
    // fail `===`.
    return self.add_string_constant_hstr(((Heap*)self.heap).str_intern(str));
}

// Add the string `hstr` to the pool, once per distinct string.
fn uint CompilerContext.add_string_constant_hstr(&self, HString* hstr) {
    Heap* hp = (Heap*)self.heap;
    // str_intern leaves strings over MAX_INTERN_BYTES un-interned, but names
    // are matched by pointer, so canonicalize them as runtime property keys are.
    // The fresh copy this may drop is freed via the large-string registry.
    if (hstr != null) hstr = hp.ensure_interned(hstr);

    TVal tv;
    tv.set_string_borrowed(hstr);

    ulong val_bits = tv.get_raw_bits();

    uint found_idx = self.lookup_constant_hash(val_bits);
    if (found_idx < self.const_count) {
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
//
// An integral value in fastint range is stored as a fastint, the form integer
// arithmetic and the bitwise fast paths test for. -0 stays a double.
fn uint CompilerContext.add_number_constant(&self, double val) {
    TVal tv;
    if (val >= (double)types::FASTINT_MIN && val <= (double)types::FASTINT_MAX
        && (double)(long)val == val && (val != 0.0 || 1.0 / val > 0.0)) {
        tv.set_fastint((long)val);
    } else {
        tv.set_number(val);
    }
    return self.add_constant(tv);
}

// Add a BigInt constant and return its index.
//
// `digits` is the lexer's literal text, including radix prefixes and `_`
// separators. A valid literal can still fail if its limbs exceed the
// allocation limit.
fn uint? CompilerContext.add_bigint_constant(&self, char[] digits) {
    Heap* hp = (Heap*)self.heap;

    // parse_bigint_literal boxes the value and flags it as a temproot; the
    // constant-pool slot below becomes its anchoring reference.
    hbigint::HBigInt*? box_r = hbigint::parse_bigint_literal(hp, digits);
    if (catch excuse = box_r) {
        if (excuse == hbigint::BIGINT_OVERFLOW) {
            self.set_compile_error("BigInt literal is too large to allocate");
        } else {
            self.set_compile_error("Invalid BigInt literal");
        }
        return COMPILE_ERROR~;
    }
    hbigint::HBigInt* box = box_r;

    // set_bigint increfs, so drop the allocation's initial reference and keep
    // exactly one, held by the pool slot.
    TVal tv;
    tv.set_bigint(box);
    hp.decref((types::HeapHeader*)box);

    ulong val_bits = tv.get_raw_bits();

    self.ensure_const_cap();
    if (self.const_count >= self.const_cap) {
        hp.decref((types::HeapHeader*)box);
        return self.const_count;
    }
    uint idx = self.const_count;
    self.constants[idx] = tv;
    self.insert_constant_hash(val_bits, idx);
    self.const_count++;
    return idx;
}
