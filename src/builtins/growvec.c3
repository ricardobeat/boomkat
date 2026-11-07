// A vector in a heap block that grows by doubling. The block comes from the
// heap's allocation hooks, so the heap accounts for it and a failed growth
// reports instead of aborting.
module boomkat::builtins::growvec <Type>;
import boomkat::heap;

struct GrowVec {
    Heap* heap;
    Type* items;
    usz   len;
    usz   cap;
    Type* stack;   /// Caller storage `items` started in; never freed, left on first growth.
}

// Starts the vector in caller storage of `n` items, so a small result never
// allocates.
fn void GrowVec.use_storage(&self, Type* storage, usz n) {
    self.items = storage;
    self.stack = storage;
    self.cap = n;
}

// Makes room for at least `n` items in total, leaving `len` alone.
fn bool GrowVec.reserve(&self, usz n) {
    if (n <= self.cap) return true;
    bool borrowed = self.stack != null && self.items == self.stack;
    Type* grown = (Type*)self.heap.realloc_func(self.heap.heap_udata, borrowed ? null : self.items, n * Type::size);
    if (grown == null) return false;
    if (borrowed) mem::copy(grown, self.items, (sz)(self.len * Type::size));
    self.items = grown;
    self.cap = n;
    return true;
}

fn bool GrowVec.push(&self, Type item) {
    if (self.len == self.cap && !self.reserve(self.cap == 0 ? 64 : self.cap * 2)) return false;
    self.items[self.len++] = item;
    return true;
}

fn void GrowVec.free(&self) {
    if (self.items != null && self.items != self.stack) self.heap.free_func(self.heap.heap_udata, self.items);
    self.items = null;
    self.stack = null;
}
