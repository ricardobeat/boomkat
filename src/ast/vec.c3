// A growable array with O(1) truncation, used for the AST's columns.
module boomkat::ast::vec <Type>;

struct Vec {
    Type* data;
    sz len;
    sz cap;
}

fn void Vec.init(&self, sz cap = 64) {
    self.data = mem::alloc_array(Type, cap).ptr;
    self.len = 0;
    self.cap = cap;
}

// Initialise with `n` zeroed elements already present, for tables that start
// fully populated.
fn void Vec.init_zero(&self, sz n) {
    self.data = mem::alloc_array(Type, n).ptr;
    self.cap = n;
    mem::clear(self.data, (sz)(n * Type::size));
    self.len = n;
}

// Reset to `n` zeroed elements, reusing the current storage when it is large
// enough. Used to rebuild a table after a rehash or a grow.
fn void Vec.zero(&self, sz n) {
    if (n > self.cap) {
        self.data = mem::realloc(self.data, n * Type::size);
        self.cap = n;
    }
    mem::clear(self.data, (sz)(n * Type::size));
    self.len = n;
}

fn void Vec.free(&self) {
    if (self.data != null) mem::free(self.data);
    self.data = null;
    self.len = 0;
    self.cap = 0;
}

fn void Vec.grow(&self) {
    sz ncap = self.cap < 16 ? 16 : self.cap * 2;
    self.data = mem::realloc(self.data, ncap * Type::size);
    self.cap = ncap;
}

fn void Vec.push(&self, Type v) @inline {
    if (self.len == self.cap) self.grow();
    self.data[self.len] = v;
    self.len++;
}

fn Type Vec.get(&self, uint i) @operator([]) @inline {
    return self.data[i];
}

fn Type* Vec.get_ref(&self, uint i) @operator(&[]) @inline {
    return &self.data[i];
}

fn void Vec.set(&self, uint i, Type v) @operator([]=) @inline {
    self.data[i] = v;
}

// Drop every element at index `n` and above.
fn void Vec.truncate(&self, sz n) @inline {
    if (n < self.len) self.len = n;
}

fn Type[] Vec.slice(&self, sz from, sz to) @inline {
    return self.data[from:to - from];
}
