module boomkat::vm;

import boomkat::bytecode;
import boomkat::heap;
import boomkat::hobject;
import std::io;

// Shutdown-only inventory. Dynamic read counters already exist in stats
// builds; listing immutable helper sites adds no generated-code overhead.
fn void ssa_stats_accesses(Heap* h, CompiledFunction* cf, LoopPlan* region, uint id) @feat(SLJIT) {
    $if $feat(SLJIT_STATS):
    if (region == null || region.ssa_data == null) return;
    SsaPlanData* data = region.ssa_data;
    io::printfn("SLJIT SSA access id=%d sites=%d bindings=%d binding_reads=%d field_reads=%d field_writes=%d array_reads=%d",
        id, data.native_accesses, data.native_bindings, data.binding_reads, data.field_reads, data.field_writes, data.array_reads);
    for (SsaHelperSite* site = region.ssa_helpers; site != null; site = site.next) {
        DecodedBytecode view = bytecode::decode_bytecode(cf.code, cf.code_count, site.pc);
        if (!view.valid) continue;
        io::printfn("SLJIT SSA site id=%d pc=%d next=%d opcode=%s kind=%d resume=%d before=%d after=%d live=%d roots=%d calls=%d",
            id, site.pc, site.next_pc, view.insn.op, site.kind.ordinal, site.native_resume,
            site.before_count, site.after_count, site.live_count, site.root_count, site.calls);
        if (cf.ic_entries != null && view.payload_pc < cf.ic_count
            && (view.insn.op == Opcode.GETTHISC || view.insn.op == Opcode.PUTTHISC
                || view.insn.op == Opcode.GETPROPC || view.insn.op == Opcode.GETPROPC_CACHED)) {
            ICEntry* ic = (ICEntry*)cf.ic_entries + view.payload_pc;
            Shape* shape = h.get_shape(ic.shape_id);
            io::printfn("SLJIT SSA site_ic id=%d pc=%d key=%d shape=%d generation=%d present=%d dict=%d proto=%d chain=%d slot=%d accessor=%d",
                id, site.pc, ic.key.borrow() != null, ic.shape_id, ic.shape_gen,
                shape != null, shape != null && shape.dict, ic.has_proto, ic.chain_len,
                ic.prop_idx, ic.prop_flags.is_accessor);
        }
    }
    $endif
}
