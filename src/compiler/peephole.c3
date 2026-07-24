module duktape::jit;

import duktape::bytecode;
import duktape::types;
import duktape::heap;
import duktape::hobject;

// ============================================================================
// GETPROPC2 chain fusion
// ============================================================================

/// Fuse consecutive GETPROPC pairs where output of first is input of second.
/// Pattern: GETPROPC r_tmp, r_src, key1  /  GETPROPC r_dst, r_tmp, key2
/// → GETPROPC2 r_tmp, r_src, key1  /  (data: r_dst, key2) in next slot
fn void jit_fuse_getpropc_chains(CompiledFunction* f) {
    if (f == null || f.code_count < 2) return;

    for (uint i = 0; i + 1 < f.code_count; i++) {
        Instruction i1 = f.code[i];
        Instruction i2 = f.code[i + 1];

        if (i1.op != Opcode.GETPROPC) continue;
        if (i2.op != Opcode.GETPROPC) continue;

        // Check: output of i1 (i1.a) == input of i2 (i2.b)
        if (i1.a != i2.b) continue;

        // Fuse: rewrite i1 as GETPROPC2, repurpose i2 as data slot
        f.code[i] = bytecode::make_abc(Opcode.GETPROPC2, i1.a, i1.b, i1.c);
        // i2 stays as-is; GETPROPC2 handler will read A and C from it and skip past
    }
}

// ============================================================================
// Main JIT scan entry point
// ============================================================================

/// Run JIT optimizations on a compiled function's bytecode.
/// Called after compilation and before first execution.
fn void jit_scan(CompiledFunction* f, Heap* h) {
    if (f == null) return;

    // Fuse consecutive GETPROPC chains
    jit_fuse_getpropc_chains(f);
}
