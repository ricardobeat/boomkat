// Appended to a temporary cli/boomkat.c3 by run_probe.py.
// Original labels executed/executed_instructions mean cache-bearing functions
// and static positions, not dynamic execution counts; see plan 105 section 3.
fn void dump_shape_study(Heap* h) {
    ulong instructions = 0; ulong executed_instructions = 0; ulong cache_bytes = 0;
    ulong prop_filled = 0; ulong var_filled = 0; ulong own_entries = 0; ulong proto_entries = 0; ulong absent_entries = 0;
    uint executed_funcs = 0;
    for (uint i = 0; i < h.compiled_func_count; i++) {
        CompiledFunction* f = (CompiledFunction*)h.compiled_funcs[i];
        if (f == null) continue;
        instructions += f.code_count;
        if (f.ic_entries != null) {
            executed_funcs++;
            executed_instructions += f.code_count;
            cache_bytes += (ulong)f.ic_count * hobject::ICEntry::size;
            hobject::ICEntry* entries = (hobject::ICEntry*)f.ic_entries;
            for (uint j = 0; j < f.ic_count; j++) {
                hobject::ICEntry* e = entries + j;
                if (e.key.borrow() == null) continue;
                prop_filled++;
                if (e.prop_idx == hobject::IC_PROP_ABSENT) { absent_entries++; }
                else if (e.proto == null) { own_entries++; }
                else { proto_entries++; }
            }
        }
        if (f.var_ic_entries != null) {
            cache_bytes += (ulong)f.var_ic_count * hobject::VarICEntry::size;
            hobject::VarICEntry* entries = (hobject::VarICEntry*)f.var_ic_entries;
            for (uint j = 0; j < f.var_ic_count; j++) {
                if (entries[j].slot_ptr != null) var_filled++;
            }
        }
    }
    ulong shape_bytes = 0; ulong shape_hash_bytes = 0;
    uint live_shapes = 0; uint pinned = 0; uint dict = 0;
    for (uint i = 0; i < h.shape_count; i++) {
        if (!h.shape_slot_live(i)) continue;
        hobject::Shape* sh = h.shapes[i];
        live_shapes++;
        if (sh.pinned) pinned++;
        if (sh.dict) dict++;
        shape_bytes += hobject::shape_alloc_size(sh.capacity);
        if (sh.hash_table != null) shape_hash_bytes += (ulong)(hobject::prop_hash_mask_for(sh.offset + sh.own_count) + 1) * hobject::HashEntry::size;
    }
    io::eprintfn("STUDY sizes instruction=%d IC=%d VarIC=%d Shape=%d ShapeProperty=%d Transition=%d HObjectBase=%d PropValue=%d", Instruction::size, hobject::ICEntry::size, hobject::VarICEntry::size, hobject::Shape::size, hobject::ShapeProperty::size, heap::TransitionEntry::size, hobject::HObjectBase::size, hobject::PropValue::size);
    io::eprintfn("STUDY functions total=%d executed=%d instructions=%d executed_instructions=%d cache_bytes=%d prop_filled=%d var_filled=%d own=%d proto=%d absent=%d", h.compiled_func_count, executed_funcs, instructions, executed_instructions, cache_bytes, prop_filled, var_filled, own_entries, proto_entries, absent_entries);
    io::eprintfn("STUDY shapes count=%d pinned=%d dict=%d shape_bytes=%d hash_bytes=%d transition_bytes=%d", live_shapes, pinned, dict, shape_bytes, shape_hash_bytes, (ulong)(h.trans_mask + 1) * heap::TransitionEntry::size);
}
