module boomkat::peephole;

import boomkat::bytecode;
import boomkat::types;
import boomkat::heap;
import boomkat::hobject;
import boomkat::compiler;

// ============================================================================
// GETPROPC2 chain fusion
// ============================================================================

// Fuse consecutive GETPROPC pairs where output of the first feeds the second.
// Pattern: GETPROPC r_tmp, r_src, key1 / GETPROPC r_dst, r_tmp, key2
// -> GETPROPC2 r_tmp, r_src, key1 / (data: r_dst, key2) in next slot
//
// Slot i+1 becomes a data word: the VM reads the second hop's destination
// register and key index directly from it and advances past it.
//
// Invariants:
//  1. The data slot cannot be a branch target. If control jumps directly to i+1,
//     the VM decodes the data word as an instruction.
//  2. The intermediate register r_tmp may be read later. The GETPROPC2 handler
//     must write the first hop's result back into r_tmp on every exit path.
//
// Runs after NOP compaction on final bytecode.
fn void fuse_getpropc_chains(CompiledFunction* f, bool* jump_targets) {
    if (f == null || f.code_count < 2) return;

    compiler::build_jump_targets(f.code, f.code_count, jump_targets);

    for (uint i = 0; i + 1 < f.code_count; i++) {
        Instruction i1 = f.code[i];
        Instruction i2 = f.code[i + 1];

        if (i1.op != Opcode.GETPROPC) continue;
        if (i2.op != Opcode.GETPROPC) continue;

        if (i1.a != i2.b) continue;

        // The data slot must not be a branch target.
        if (jump_targets[i + 1]) continue;

        // Rewrite i1 as GETPROPC2; i2 is left in place as the data word.
        f.code[i] = bytecode::make_abc(Opcode.GETPROPC2, i1.a, i1.b, i1.c);

        // Skip the data slot so consecutive three-hop chains (o.a.b.c) do not
        // treat slot i+1 as an instruction and create overlapping fusions.
        i++;
    }
}

// ============================================================================
// Main peephole scan entry point
// ============================================================================

// Run bytecode peephole optimizations on a compiled function.
// Called after compilation and before first execution.
fn void peephole_scan(CompiledFunction* f, Heap* h) {
    if (f == null || f.code_count < 2) return;

    // Shared jump-target bitset for fusion passes. If allocation fails,
    // passes are skipped to avoid transforming unguarded branch targets.
    bool* jump_targets = (bool*)h.alloc_func(h.heap_udata, (usz)f.code_count);
    if (jump_targets == null) return;

    fuse_getpropc_chains(f, jump_targets);

    h.free_func(h.heap_udata, jump_targets);
}
