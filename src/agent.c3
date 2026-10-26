// Memory shared between agents, and the machinery agents use to wait on it.
//
// An agent is one runtime on one thread. Runtimes share no heap objects; the
// only thing that crosses between them is a SharedArrayBuffer's data block.
// This module owns that block, and the process-wide waiter table behind
// Atomics.wait, Atomics.notify and Atomics.waitAsync.
module boomkat::agent;

import std::atomic;
import libc;

// ============================================================================
// Shared data blocks
// ============================================================================

// A SharedArrayBuffer's bytes live in a libc block with this header in front.
// `ab.data` keeps pointing at the bytes, so every typed array fast path reads
// a shared buffer exactly as it reads an ArrayBuffer.
//
// libc rather than the heap allocator: the last reference can be dropped by
// another agent's thread after the creating heap is gone, and a heap's
// allocator callbacks belong to that heap's embedder.
//
// `length` is the live byte length, which a growable buffer raises from any
// agent; `capacity` is the size of the data region and never changes.
struct BlockHeader {
    uint refs;
    uint length;
    uint capacity;
    uint pad;
}

const usz BLOCK_HEADER_SIZE = BlockHeader::size;

macro BlockHeader* block_header(char* data) @private => (BlockHeader*)(data - BLOCK_HEADER_SIZE);

// A zeroed block holding `capacity` bytes, `length` of them live, with one
// reference. Returns the data pointer, or null when memory is exhausted. The
// data is never null on success, even for an empty buffer, so that every
// SharedArrayBuffer can be shared.
fn char* block_alloc(uint length, uint capacity) {
    BlockHeader* header = (BlockHeader*)libc::calloc(1, BLOCK_HEADER_SIZE + (usz)capacity);
    if (header == null) return null;
    header.refs = 1;
    header.length = length;
    header.capacity = capacity;
    return (char*)header + BLOCK_HEADER_SIZE;
}

fn void block_retain(char* data) {
    atomic::fetch_add(&block_header(data).refs, 1u, RELAXED);
}

// Drops one reference and frees the block when it was the last.
fn void block_release(char* data) {
    BlockHeader* header = block_header(data);
    if (atomic::fetch_sub(&header.refs, 1u, ACQUIRE_RELEASE) == 1) libc::free(header);
}

fn uint block_length(char* data) {
    return mem::@atomic_load(block_header(data).length);
}

fn uint block_capacity(char* data) {
    return block_header(data).capacity;
}

// Raises the live length to `new_length`. False when that would shrink it.
// A concurrent grow can win the race, so the length is retried against the
// freshest value rather than overwritten.
fn bool block_grow(char* data, uint new_length) {
    BlockHeader* header = block_header(data);
    uint seen = mem::@atomic_load(header.length);
    while (seen <= new_length) {
        uint witnessed = mem::compare_exchange(&header.length, seen, new_length);
        if (witnessed == seen) return true;
        seen = witnessed;
    }
    return false;
}
