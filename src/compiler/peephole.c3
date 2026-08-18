module boomkat::peephole;

import boomkat::bytecode;
import boomkat::types;
import boomkat::heap;
import boomkat::hobject;
import boomkat::compiler;

// ============================================================================
// GETPROPC2 chain fusion
// ============================================================================

/// Fuse consecutive GETPROPC pairs where output of first is input of second.
/// Pattern: GETPROPC r_tmp, r_src, key1  /  GETPROPC r_dst, r_tmp, key2
/// → GETPROPC2 r_tmp, r_src, key1  /  (data: r_dst, key2) in next slot
///
/// This pass turns slot i+1 into a DATA WORD: the VM reads the second hop's
/// destination register and key index out of it and skips past, so it is no
/// longer a decodable instruction. Two invariants make that legal, and both are
/// enforced here rather than assumed:
///
///  1. THE DATA SLOT MUST NOT BE A JUMP TARGET. Control arriving at i+1 from a
///     branch never executed the GETPROPC2 at i, so it would decode a data word
///     as an instruction. `jump_targets` is the shared bitset from
///     `build_jump_targets` — the same predicate every other fusion pass uses.
///     Measured over the test262 corpus this rejects nothing (33399 fusions
///     fire, zero data slots are branch destinations), because the compiler
///     emits both hops of a member expression as one unit with no statement
///     boundary between them. The check is kept anyway: it costs no fusion, and
///     the alternative is a silent miscompile the day a codegen change puts a
///     label, loop head or join between the hops. Three bugs of exactly this
///     shape (a pass rewriting i+1 while reasoning only about position) have
///     been found in this file's neighbours.
///
///  2. THE INTERMEDIATE TEMP MAY BE READ LATER, and usually is. This pass does
///     NOT check liveness of r_tmp and does not have to, because the GETPROPC2
///     handler writes the hop-1 result back into r_tmp on EVERY exit path (see
///     vm_property.c3, "store the intermediate result in ra"). That write-back
///     is the invariant that makes ignoring liveness legal — it is not an
///     optimization detail and must not be removed. It was once missing on the
///     hop-2 Proxy path, which made `o.m.z()` with a proxied `o.m` invoke `z`
///     with a stale `this`; test/getpropc2_proxy_chain.js pins that.
///
/// It runs AFTER NOP compaction, on final code, so slot indices here are the
/// ones the VM will see; there is no later pass to invalidate them, and the
/// bitset is built from that same final code.
fn void fuse_getpropc_chains(CompiledFunction* f, bool* jump_targets) {
    if (f == null || f.code_count < 2) return;

    compiler::build_jump_targets(f.code, f.code_count, jump_targets);

    for (uint i = 0; i + 1 < f.code_count; i++) {
        Instruction i1 = f.code[i];
        Instruction i2 = f.code[i + 1];

        if (i1.op != Opcode.GETPROPC) continue;
        if (i2.op != Opcode.GETPROPC) continue;

        // Check: output of i1 (i1.a) == input of i2 (i2.b)
        if (i1.a != i2.b) continue;

        // The consumer slot becomes data — it must be unreachable by branch.
        if (jump_targets[i + 1]) continue;

        // Fuse: rewrite i1 as GETPROPC2, repurpose i2 as data slot
        f.code[i] = bytecode::make_abc(Opcode.GETPROPC2, i1.a, i1.b, i1.c);
        // i2 stays as-is; GETPROPC2 handler will read A and C from it and skip past

        // Step over the data slot. Without this, a three-hop chain
        // (`o.a.b.c`, three consecutive GETPROPCs) fuses at i, then examines
        // the pair at i+1: the data word still decodes as a GETPROPC whose
        // A/B/C happen to satisfy the chain test, so it is rewritten to a
        // second GETPROPC2 and i+2 becomes ITS data slot. The result is two
        // overlapping fused pairs sharing a word that is an instruction to one
        // and data to the other -- exactly the "data slot decoded as an
        // instruction" hazard invariant 1 above exists to prevent.
        i++;
    }
}

// ============================================================================
// Main peephole scan entry point
// ============================================================================

/// Run bytecode peephole optimizations on a compiled function.
/// Called after compilation and before first execution.
fn void peephole_scan(CompiledFunction* f, Heap* h) {
    if (f == null || f.code_count < 2) return;

    // Shared jump-target bitset for the passes below. On allocation failure the
    // fusion is skipped entirely rather than run unguarded: an un-fused chain is
    // slower, an unguarded one can be wrong.
    bool* jump_targets = (bool*)h.alloc_func(h.heap_udata, (usz)f.code_count);
    if (jump_targets == null) return;

    // Fuse consecutive GETPROPC chains
    fuse_getpropc_chains(f, jump_targets);

    h.free_func(h.heap_udata, jump_targets);
}
