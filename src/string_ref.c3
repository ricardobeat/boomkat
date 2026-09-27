module boomkat::hstring;

import boomkat::types;
import boomkat::heap;

// A persistent string owner. Raw HString pointers returned by borrow are valid
// while this owner, or another counted owner, keeps the string alive.
typedef StringRef = HString*;

fn HString* StringRef.borrow(self) @inline {
    return (HString*)self;
}

// Acquire before releasing so replacement with the same string is safe.
fn void StringRef.set(&self, heap::Heap* h, HString* value) @inline {
    if (value != null) ((HeapHeader*)value).incref();
    self.release(h);
    *self = (StringRef)value;
}

fn void StringRef.release(&self, heap::Heap* h) @inline {
    HString* value = self.borrow();
    *self = (StringRef)null;
    // Heap teardown releases string allocations as a group.
    if (value != null && !h.tearing_down) h.decref((HeapHeader*)value);
}

// Construct one owner from a borrowed pointer.
fn StringRef string_ref(HString* value) @inline {
    if (value != null) ((HeapHeader*)value).incref();
    return (StringRef)value;
}

fn void free_string_refs(heap::Heap* h, StringRef[] refs) {
    foreach (&ref : refs) ref.release(h);
    if (refs.ptr != null) h.free_func(h.heap_udata, refs.ptr);
}
