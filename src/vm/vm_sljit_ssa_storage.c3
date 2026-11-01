module boomkat::vm;

import boomkat::heap;
import boomkat::compiler;
import boomkat::bytecode;
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
    ulong max_work;
}
const SsaBudget SSA_DEFAULT_BUDGET = { 65536, 65536, 262144, 8192, 65536, 131072, 1048576, 16 * 1024 * 1024, 50000000 };
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
    compiler::bytecode_cfg_free(&g.decoded);
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
    if (!ssa_charge_work(g, reg_count)) return SSA_NO_FRAME;
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

// Dynamic tables retain stable numeric identities. Builder code reacquires
// pointers after adding values; optimization runs only after construction.
fn bool ssa_reserve_values(SsaGraph* g, uint needed) @feat(SLJIT) {
    // Failed builders may still inspect their returned sink ID while unwinding.
    // It is never emitted, assigned a frame or treated as a successful node.
    if (g.values == null) g.values = &g.failed_value;
    if (needed <= g.value_capacity) return !g.failed;
    if (g.budget.max_bytes == 0) g.budget = SSA_DEFAULT_BUDGET;
    uint prior = g.value_capacity;
    uint capacity = prior;
    SsaValue* values = (SsaValue*)ssa_storage_grow(g, g.values, g.value_count,
        &capacity, needed, g.budget.max_values, SsaValue::size);
    if (values == null) return false;
    int* conv = (int*)ssa_storage_alloc(g, (usz)capacity * 4, int::size);
    bool* numeric = (bool*)ssa_storage_alloc(g, capacity, bool::size);
    if (g.failed) return false;
    if (prior != 0) {
        mem::copy(conv, g.conv, (sz)((usz)prior * 4 * int::size));
        mem::copy(numeric, g.numeric_load, (sz)((usz)prior * bool::size));
    }
    g.values = values;
    g.conv = conv;
    g.numeric_load = numeric;
    g.value_capacity = capacity;
    return true;
}
fn bool ssa_graph_tables(SsaGraph* g, uint span) @feat(SLJIT) {
    if (g.budget.max_bytes == 0) g.budget = SSA_DEFAULT_BUDGET;
    if (span > g.budget.max_words) { g.failed = true; return false; }
    uint blocks = span < g.budget.max_blocks ? span : g.budget.max_blocks;
    g.block_capacity = blocks;
    g.blocks = (SsaBlock*)ssa_storage_alloc(g, blocks, SsaBlock::size);
    g.joins = (SsaJoin*)ssa_storage_alloc(g, blocks, SsaJoin::size);
    g.cyclic_live = (compiler::RegSet*)ssa_storage_alloc(g, blocks, compiler::RegSet::size);
    g.recovery_live = (compiler::RegSet*)ssa_storage_alloc(g, span, compiler::RegSet::size);
    uint* live_words = (uint*)ssa_storage_alloc(g, (usz)(blocks + span + 1) * g.reg_words, uint::size);
    if (g.failed) return false;
    for (uint b = 0; b < blocks; b++) g.cyclic_live[b] = { .words = live_words + (usz)b * g.reg_words, .word_count = g.reg_words };
    for (uint pc = 0; pc < span; pc++) g.recovery_live[pc] = { .words = live_words + (usz)(blocks + pc) * g.reg_words, .word_count = g.reg_words };
    g.force_f64 = { .words = live_words + (usz)(blocks + span) * g.reg_words, .word_count = g.reg_words };
    g.current = (int*)ssa_storage_alloc(g, g.reg_count, int::size);
    g.header = (int*)ssa_storage_alloc(g, g.reg_count, int::size);
    g.phi = (int*)ssa_storage_alloc(g, g.reg_count, int::size);
    g.arg = (int*)ssa_storage_alloc(g, g.reg_count, int::size);
    g.rep = (SsaRep*)ssa_storage_alloc(g, g.reg_count, SsaRep::size);
    g.int_reg = (bool*)ssa_storage_alloc(g, g.reg_count, bool::size);
    g.cyclic_order = (uint*)ssa_storage_alloc(g, blocks, uint::size);
    g.block_built = (bool*)ssa_storage_alloc(g, blocks, bool::size);
    g.block_first = (uint*)ssa_storage_alloc(g, blocks, uint::size);
    g.block_last = (uint*)ssa_storage_alloc(g, blocks, uint::size);
    return !g.failed;
}
fn bool ssa_collect_predecessors(SsaGraph* g) @feat(SLJIT) {
    uint edges;
    for (uint b = 0; b < g.block_count; b++) g.blocks[b].pred_count = 0;
    for (uint p = 0; p < g.block_count; p++) {
        for (uint e = 0; e < ssa_succ_count(g, p); e++) {
            if (edges++ == g.budget.max_edges) { g.failed = true; return false; }
            g.blocks[ssa_succ(g, p, e)].pred_count++;
        }
    }
    for (uint b = 0; b < g.block_count; b++) {
        SsaBlock* block = &g.blocks[b];
        block.preds = (uint*)ssa_storage_alloc(g, block.pred_count, uint::size);
        block.pred_count = 0;
        if (g.failed) return false;
    }
    for (uint p = 0; p < g.block_count; p++) {
        for (uint e = 0; e < ssa_succ_count(g, p); e++) {
            SsaBlock* block = &g.blocks[ssa_succ(g, p, e)];
            block.preds[block.pred_count++] = p;
        }
    }
    return true;
}
fn bool ssa_join_storage(SsaGraph* g, SsaJoin* join, SsaBlock* block) @feat(SLJIT) {
    join.preds = block.preds;
    join.phi = (int*)ssa_storage_alloc(g, g.reg_count, int::size);
    join.entry_incoming = (int*)ssa_storage_alloc(g, g.reg_count, int::size);
    join.incoming = (int**)ssa_storage_alloc(g, block.pred_count, int*::size);
    if (g.failed) return false;
    for (uint p = 0; p < block.pred_count; p++) {
        join.incoming[p] = (int*)ssa_storage_alloc(g, g.reg_count, int::size);
        if (g.failed) return false;
    }
    return true;
}

// Canonical prefix PCs are the only SSA bytecode identities. Legacy loop
// adapters borrow a rewritten window but still use the same decoder contract.
fn DecodedBytecode ssa_decoded_view(SsaGraph* g, uint pc) @feat(SLJIT) {
    if (g.decoded.storage != null && pc < g.decoded.word_count) {
        uint index = g.decoded.pc_to_index[pc];
        if (index != compiler::CFG_NO_INSTRUCTION) return g.decoded.nodes[index].view;
        return {};
    }
    return bytecode::decode_bytecode(g.cf.code, g.cf.code_count, pc);
}
fn int ssa_decoded_target(DecodedBytecode view) @feat(SLJIT) {
    long target;
    if (!compiler::bytecode_cfg_branch(view, &target)) return -1;
    return target < 0 || target > int::max ? -1 : (int)target;
}

// Account compile work as well as memory. Callers charge a complete sweep
// before entering it, so adversarial CFGs cannot hide unbounded fixed points.
fn bool ssa_charge_work(SsaGraph* g, usz amount) @feat(SLJIT) {
    if (g.failed) return false;
    ulong limit = g.budget.max_work == 0 ? SSA_DEFAULT_BUDGET.max_work : g.budget.max_work;
    if (g.work > limit || (ulong)amount > limit - g.work) { g.failed = true; return false; }
    g.work += (ulong)amount;
    return true;
}
fn bool ssa_cfg_charge_work(void* data, usz amount) @feat(SLJIT) => ssa_charge_work((SsaGraph*)data, amount);
