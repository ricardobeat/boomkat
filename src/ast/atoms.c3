// Interned byte strings: identifier names, decoded string values, template
// parts. An atom id is a `uint` index; 0 is reserved and means "none". The
// table borrows the bytes it is given, so they must stay valid for the
// table's lifetime (they point into the source or the lexer's string arena).
module boomkat::ast;

import boomkat::ast::vec;

struct AtomEntry {
    char* ptr;
    uint len;
    uint hash;
}

struct AtomTable {
    Vec{AtomEntry} entries;
    // Open addressing; each slot holds an atom id, 0 for empty. The size is a power of two.
    Vec{uint} slots;
}

const uint ATOM_NONE = 0;

fn void AtomTable.init(&self) {
    self.entries.init(256);
    self.slots.init(1024);
    for (sz i = 0; i < 1024; i++) self.slots.push(0);
    // Atom 0 is the "none" entry.
    self.entries.push({ null, 0, 0 });
}

fn void AtomTable.free(&self) {
    self.entries.free();
    self.slots.free();
}

fn uint AtomTable.count(&self) @inline {
    return (uint)self.entries.len;
}

fn uint hash_bytes(char[] s) @inline {
    uint h = 2166136261u;
    foreach (c : s) {
        h ^= (uint)c;
        h *= 16777619u;
    }
    return h;
}

fn char[] AtomTable.get(&self, uint atom) @inline {
    AtomEntry* e = &self.entries.data[atom];
    return e.ptr[:e.len];
}

fn bool AtomTable.equals(&self, uint atom, char[] s) @inline {
    AtomEntry* e = &self.entries.data[atom];
    if (e.len != s.len) return false;
    for (sz i = 0; i < s.len; i++) {
        if (e.ptr[i] != s[i]) return false;
    }
    return true;
}

fn void AtomTable.rehash(&self) {
    sz ncap = self.slots.len * 2;
    self.slots.len = 0;
    for (sz i = 0; i < ncap; i++) self.slots.push(0);
    sz mask = ncap - 1;
    for (uint id = 1; id < (uint)self.entries.len; id++) {
        sz at = self.entries.data[id].hash & mask;
        while (self.slots.data[at] != 0) at = (at + 1) & mask;
        self.slots.data[at] = id;
    }
}

// The atom for `s`, adding it when it is new.
fn uint AtomTable.intern(&self, char[] s) {
    uint h = hash_bytes(s);
    sz mask = self.slots.len - 1;
    sz at = h & mask;
    while (true) {
        uint id = self.slots.data[at];
        if (id == 0) break;
        AtomEntry* e = &self.entries.data[id];
        if (e.hash == h && self.equals(id, s)) return id;
        at = (at + 1) & mask;
    }
    uint id = (uint)self.entries.len;
    self.entries.push({ s.ptr, (uint)s.len, h });
    self.slots.data[at] = id;
    // Keep the load factor at or below one half.
    if (self.entries.len * 2 > self.slots.len) self.rehash();
    return id;
}
