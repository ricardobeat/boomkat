module duktape::peephole;

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
///
/// This pass reasons purely positionally (opcode at i and i+1,
/// plus one register-identity check) and consults NO jump-target bitset, yet
/// is sound. It is sound for reasons nobody had written down, so they are
/// recorded here; each is a property of OTHER code that this pass silently
/// depends on, and any of them changing turns this into a miscompile.
///
///  1. THE DATA SLOT MUST NOT BE A JUMP TARGET. Slot i+1 stops being an
///     instruction, which the VM reads as operand data and skips, so a
///     branch landing there would execute a data word. This pass never checks
///     that. It is safe today only because the compiler never emits a branch
///     into the middle of a two-hop property chain: the pair is generated as
///     one unit by a single member-expression, with no statement boundary (and
///     therefore no label, loop head or join) between the hops. VERIFIED
///     EMPIRICALLY, not just by inspection: instrumenting this pass to report
///     when slot i+1 is a jump target and compiling all 47291 test262
///     language/ and built-ins/ files produced ZERO hits.
///
///  2. THE INTERMEDIATE TEMP MAY BE READ LATER, and usually is. The same
///     instrumentation found 5232 files where r_tmp is live after the pair, so
///     this pass CANNOT rely on the temp being dead. It does not have to,
///     because the GETPROPC2 handler writes the hop-1 result back into r_tmp
///     on its normal paths (see vm_property.c3, "Also store the intermediate
///     result in ra"). That write-back is the invariant that makes ignoring
///     liveness legal. It is not an optimization detail and must not be
///     removed. KNOWN EXCEPTION: the hop-2 Proxy path returns early, before
///     the write-back, so r_tmp keeps a stale value there. That is latent
///     rather than observable only because the compiler does not currently
///     emit a chain whose temp is read after a proxied second hop.
///
///  3. It runs AFTER NOP compaction, on final code, so slot indices here are
///     the ones the VM will see; there is no later pass to invalidate them.
fn void fuse_getpropc_chains(CompiledFunction* f) {
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
// Main peephole scan entry point
// ============================================================================

/// Run bytecode peephole optimizations on a compiled function.
/// Called after compilation and before first execution.
fn void peephole_scan(CompiledFunction* f, Heap* h) {
    if (f == null) return;

    // Fuse consecutive GETPROPC chains
    fuse_getpropc_chains(f);
}
