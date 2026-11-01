module boomkat::vm;

import boomkat::heap;
import std::core::mem;

// Admission policy is separate from representation. Every graph allocation is
// charged before it is made; exhaustion declines compilation without exposing
// a partially built graph. Counts do not size native C3 stack arrays.
struct SsaBudget {
    uint max_words;
    uint max_instructions;
    uint max_values;
    uint max_blocks;
    uint max_edges;
    uint max_frames;
    uint max_recovery_entries;
    usz max_bytes;
}
const SsaBudget SSA_DEFAULT_BUDGET = { 65536, 65536, 262144, 8192, 65536, 131072, 1048576, 16 * 1024 * 1024 };
alias SsaFrameId = uint;
const SsaFrameId SSA_NO_FRAME = uint::max;
const uint SSA_NO_BLOCK = uint::max;

struct SsaFrameEntry @feat(SLJIT) {
    uint reg;
    int value;
}
struct SsaFrame @feat(SLJIT) {
    uint first;
    uint count;
    uint pc;
}
struct SsaStorageChunk @feat(SLJIT) {
    SsaStorageChunk* next;
    usz bytes;
}
struct SsaSafepoint @feat(SLJIT) {
    uint node;
    SsaFrameId before_frame;
    SsaFrameId after_frame;
    uint* live_before;
    uint before_count;
    uint* live_after;
    uint after_count;
}

fn void* ssa_storage_alloc(SsaGraph* g, usz count, usz item_size) @feat(SLJIT) {
    if (g.failed || count == 0) return null;
    if (g.budget.max_bytes == 0) g.budget = SSA_DEFAULT_BUDGET;
    usz header = SsaStorageChunk::size;
    if (item_size == 0 || count > (usz::max - header) / item_size) { g.failed = true; return null; }
    usz bytes = header + count * item_size;
    if (g.storage_bytes > g.budget.max_bytes || bytes > g.budget.max_bytes - g.storage_bytes) {
        g.failed = true;
        return null;
    }
    SsaStorageChunk* chunk = (SsaStorageChunk*)g.heap.alloc_func(g.heap.heap_udata, bytes);
    if (chunk == null) { g.failed = true; return null; }
    chunk.next = g.storage;
    chunk.bytes = bytes;
    g.storage = chunk;
    g.storage_bytes += bytes;
    void* data = (char*)chunk + header;
    mem::clear(data, (sz)(bytes - header));
    return data;
}
fn void ssa_storage_free(SsaGraph* g) @feat(SLJIT) {
    while (g.storage != null) {
        SsaStorageChunk* chunk = g.storage;
        g.storage = chunk.next;
        g.heap.free_func(g.heap.heap_udata, chunk);
    }
    g.storage_bytes = 0;
}
fn void* ssa_storage_grow(SsaGraph* g, void* prior, uint used, uint* capacity,
    uint needed, uint maximum, usz item_size) @feat(SLJIT) {
    if (needed <= *capacity) return prior;
    if (needed > maximum) { g.failed = true; return null; }
    uint next = *capacity == 0 ? 8 : *capacity;
    while (next < needed) {
        if (next > maximum / 2) { next = maximum; break; }
        next *= 2;
    }
    if (next > maximum) next = maximum;
    void* data = ssa_storage_alloc(g, next, item_size);
    if (data == null) return null;
    if (used != 0) mem::copy(data, prior, (sz)((usz)used * item_size));
    *capacity = next;
    return data;
}

// Frames are immutable sparse maps. IDs survive vector growth and SSA COPY
// rewrites; callers must reacquire slices after appending another frame.
fn SsaFrameId ssa_frame_capture(SsaGraph* g, uint pc, int* values, uint reg_count,
    uint* live_words = null, uint word_count = 0) @feat(SLJIT) {
    if (g.budget.max_bytes == 0) g.budget = SSA_DEFAULT_BUDGET;
    uint count;
    for (uint reg = 0; reg < reg_count; reg++) {
        if (values[reg] < 0) continue;
        if (live_words != null && (reg / 32 >= word_count || (live_words[reg / 32] & (1U << (reg % 32))) == 0)) continue;
        count++;
    }
    if (count > g.budget.max_recovery_entries - g.recovery_count) { g.failed = true; return SSA_NO_FRAME; }
    SsaFrame* frames = (SsaFrame*)ssa_storage_grow(g, g.frame_table, g.frame_count,
        &g.frame_capacity, g.frame_count + 1, g.budget.max_frames, SsaFrame::size);
    if (frames == null) return SSA_NO_FRAME;
    g.frame_table = frames;
    if (count != 0) {
        SsaFrameEntry* entries = (SsaFrameEntry*)ssa_storage_grow(g, g.recovery_entries, g.recovery_count,
            &g.recovery_capacity, g.recovery_count + count, g.budget.max_recovery_entries, SsaFrameEntry::size);
        if (entries == null) return SSA_NO_FRAME;
        g.recovery_entries = entries;
    }
    SsaFrameId id = g.frame_count++;
    g.frame_table[id] = { g.recovery_count, count, pc };
    for (uint reg = 0; reg < reg_count; reg++) {
        if (values[reg] < 0) continue;
        if (live_words != null && (reg / 32 >= word_count || (live_words[reg / 32] & (1U << (reg % 32))) == 0)) continue;
        g.recovery_entries[g.recovery_count++] = { reg, values[reg] };
    }
    return id;
}
fn SsaFrameEntry[] ssa_frame_entries(SsaGraph* g, SsaFrameId id) @feat(SLJIT) {
    if (id == SSA_NO_FRAME || id >= g.frame_count) return {};
    SsaFrame frame = g.frame_table[id];
    if (frame.count == 0) return {};
    return g.recovery_entries[frame.first:frame.count];
}
fn int ssa_frame_lookup(SsaGraph* g, SsaFrameId id, uint reg) @feat(SLJIT) {
    SsaFrameEntry[] entries = ssa_frame_entries(g, id);
    usz lo;
    usz hi = entries.len;
    while (lo < hi) {
        usz middle = lo + (hi - lo) / 2;
        if (entries[middle].reg < reg) { lo = middle + 1; }
        else { hi = middle; }
    }
    return lo < entries.len && entries[lo].reg == reg ? entries[lo].value : -1;
}
fn SsaFrameId ssa_frame_at_pc(SsaGraph* g, uint pc) @feat(SLJIT) {
    if (pc < g.plan.begin || pc > g.plan.end || g.frames == null) return SSA_NO_FRAME;
    return g.frames[pc - g.plan.begin];
}
fn SsaFrameId ssa_frame_after_pc(SsaGraph* g, uint pc) @feat(SLJIT) {
    // After states are attached explicitly to effectful definitions. They
    // cannot be guessed from PC+1 because WIDE and calls have distinct bounds.
    for (uint id = 0; id < g.value_count; id++) {
        if (g.values[id].pc == pc && g.values[id].after_frame != SSA_NO_FRAME) return g.values[id].after_frame;
    }
    return SSA_NO_FRAME;
}
fn void ssa_frame_restore(SsaGraph* g, SsaFrameId id, int* values, uint reg_count) @feat(SLJIT) {
    for (uint reg = 0; reg < reg_count; reg++) values[reg] = -1;
    foreach (entry : ssa_frame_entries(g, id)) if (entry.reg < reg_count) values[entry.reg] = entry.value;
}

// Helper liveness is supplied by the CFG allocator, not reconstructed from
// source-register snapshots or flat def/last stamps.
fn bool ssa_record_safepoint(SsaGraph* g, uint node, SsaFrameId before, SsaFrameId after,
    ulong* live_before, ulong* live_after, uint word_count) @feat(SLJIT) {
    if (g.budget.max_bytes == 0) g.budget = SSA_DEFAULT_BUDGET;
    SsaSafepoint* points = (SsaSafepoint*)ssa_storage_grow(g, g.safepoints, g.safepoint_count,
        &g.safepoint_capacity, g.safepoint_count + 1, g.budget.max_values, SsaSafepoint::size);
    if (points == null) return false;
    g.safepoints = points;
    SsaSafepoint* point = &g.safepoints[g.safepoint_count++];
    point.node = node;
    point.before_frame = before;
    point.after_frame = after;
    for (uint id = 0; id < g.value_count && id / 64 < word_count; id++) {
        if ((live_before[id / 64] & (1UL << (id % 64))) != 0) point.before_count++;
        if ((live_after[id / 64] & (1UL << (id % 64))) != 0) point.after_count++;
    }
    if (point.before_count != 0) point.live_before = (uint*)ssa_storage_alloc(g, point.before_count, uint::size);
    if (point.after_count != 0) point.live_after = (uint*)ssa_storage_alloc(g, point.after_count, uint::size);
    if (g.failed) return false;
    uint b, a;
    for (uint id = 0; id < g.value_count && id / 64 < word_count; id++) {
        if ((live_before[id / 64] & (1UL << (id % 64))) != 0) point.live_before[b++] = id;
        if ((live_after[id / 64] & (1UL << (id % 64))) != 0) point.live_after[a++] = id;
    }
    return true;
}
fn SsaSafepoint* ssa_live_at_helper(SsaGraph* g, uint node) @feat(SLJIT) {
    for (uint i = 0; i < g.safepoint_count; i++) if (g.safepoints[i].node == node) return &g.safepoints[i];
    return null;
}

fn void ssa_graph_free(SsaGraph* g) @feat(SLJIT) {
    ssa_storage_free(g);
    g.heap.free_func(g.heap.heap_udata, g);
}
