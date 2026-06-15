module tinyduck::compiler;

import tinyduck::types;
import tinyduck::lexer;
import tinyduck::bytecode;
import tinyduck::hstring;
import tinyduck::hobject;
import tinyduck::heap;
import libc;
import std::io;

// ============================================================================
// Constant pool
// ============================================================================

/// Look up a constant in the hash table and return its index, or MAX_CONSTANTS if not found.
fn uint CompilerContext.lookup_constant_hash(&self, ulong val_bits) {
    // Use the low bits of the TVal as initial hash probe
    uint hash = (uint)(val_bits >> 1) % MAX_CONST_HASH;

    // Linear probe: find empty slot or matching entry
    for (uint attempt = 0; attempt < MAX_CONST_HASH; attempt++) {
        uint idx = (hash + attempt) % MAX_CONST_HASH;
        if (self.const_hash[idx].hash == 0) {
            // Empty slot: not found
            return MAX_CONSTANTS;
        }
        if (self.const_hash[idx].hash == val_bits) {
            // Found matching entry
            return self.const_hash[idx].index;
        }
    }
    // Hash table full (shouldn't happen if maintained correctly)
    return MAX_CONSTANTS;
}

/// Insert a constant into the hash table.
///
/// Skipped once the table reaches its fill cap (later constants are then
/// appended without dedup) and for all-zero bits, which are
/// indistinguishable from an empty slot.
fn void CompilerContext.insert_constant_hash(&self, ulong val_bits, uint idx) {
    if (self.const_hash_count >= MAX_CONST_HASH_FILL || val_bits == 0) {
        return;
    }
    uint hash = (uint)(val_bits >> 1) % MAX_CONST_HASH;

    // Linear probe: find empty slot
    for (uint attempt = 0; attempt < MAX_CONST_HASH; attempt++) {
        uint slot = (hash + attempt) % MAX_CONST_HASH;
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
    ulong val_bits = val.bits;
    TValTag tag = val.get_tag();

    // Only deduplicate numbers and fastints via hash table;
    // strings are handled separately via add_string_constant.
    if (tag == NUMBER || tag == FASTINT) {
        uint found_idx = self.lookup_constant_hash(val_bits);
        if (found_idx < MAX_CONSTANTS) {
            return found_idx;
        }
    }

    if (self.const_count >= MAX_CONSTANTS) {
        return self.const_count;  // cap
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
    // Intern the string via the heap's string table for pointer deduplication
    Heap* hp = (Heap*)self.heap;
    uint hash = hp.hash_string(str);

    // First, check if the string is already interned in the heap
    HString* hstr = hp.str_table_lookup(str, hash);
    if (hstr == null) {
        // Not found — allocate and insert
        hstr = hstring::hstring_alloc(self.heap, str, hash) ?? null;
        if (hstr != null) {
            hp.str_table_insert(hstr);
            ((types::HeapHeader*)hstr).incref();
            hstr.flags.is_interned = true;
        }
    }

    TVal tv;
    if (hstr != null) {
        tv.set_string(hstr);
    } else {
        // Fallback: store as pointer with null
        tv.set_string(null);
    }

    ulong val_bits = tv.bits;

    // Check if this string (by pointer) is already in the constant pool
    uint found_idx = self.lookup_constant_hash(val_bits);
    if (found_idx < MAX_CONSTANTS) {
        // The pool entry already holds its references; release the one taken
        // by set_string above.
        if (hstr != null) { hp.decref((types::HeapHeader*)hstr); }
        return found_idx;
    }

    if (self.const_count >= MAX_CONSTANTS) {
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
