module boomkat::vm;

import boomkat::bytecode;
import boomkat::compiler;
import boomkat::types;

// The typed SSA window consumes the compiler's canonical decoded CFG. Its
// bounds and WIDE refusal are lowering limits; instruction boundaries, calls,
// branch edges and register liveness come from the common representation.
fn bool ssa_split_recoverable(SsaGraph* g) @feat(SLJIT) {
    CompiledFunction* cf = g.cf;
    if (g.plan.begin != 0 || g.plan.end + 1 != cf.code_count) return false;
    compiler::DecodedCfg cfg;
    compiler::DecodedCfgBudget budget = { SSA_SPAN, SSA_SPAN, 128 * 1024 };
    if (!compiler::bytecode_cfg_build(&cfg, cf.code, cf.code_count, g.heap, null, true, budget)) return false;
    defer compiler::bytecode_cfg_free(&cfg);
    if (cfg.has_wide || cfg.block_count > g.block_capacity) return false;
    bool* loop_roots = (bool*)ssa_storage_alloc(g, cfg.block_count, bool::size);
    if (g.failed) return false;
    $if !$feat(SLJIT_NO_SSA_LOOP_ENTRY):
        // An ordinary VM backedge may resume here after a GC/interrupt poll.
        // Reuse the same external-frame import as a completed call instead of
        // running the rest of a long loop only through the baseline tier.
        for (uint i = 0; i < cfg.instruction_count; i++) {
            uint target = cfg.nodes[i].branch_target;
            if (target != compiler::CFG_NO_INSTRUCTION && target <= i) {
                loop_roots[cfg.nodes[target].block] = true;
            }
        }
    $endif
    g.block_count = cfg.block_count;
    g.plan.ssa_resume_pcs[0] = 0;
    g.plan.ssa_resume_pcs[1] = 0;
    for (uint i = 0; i < cfg.instruction_count; i++) {
        compiler::DecodedCfgNode* node = &cfg.nodes[i];
        SsaBlock* block = &g.blocks[node.block];
        if (node.block_entry) {
            block.begin = node.view.pc;
            block.external = node.external || loop_roots[node.block];
            if (block.external) g.plan.ssa_resume_pcs[block.begin >> 6] |= 1UL << (block.begin & 63);
        }
        block.end = node.view.pc;
        if (i + 1 < cfg.instruction_count && cfg.nodes[i + 1].block == node.block) continue;
        Opcode op = node.view.insn.op;
        block.returns = op == Opcode.RET || op == Opcode.RETUNDEF || node.call;
        block.branch_pc = node.branch_target == compiler::CFG_NO_INSTRUCTION ? uint::max : node.view.pc;
        block.jump = op == Opcode.JUMP;
        block.conditional = block.branch_pc != uint::max && !block.jump;
        block.succ0 = SSA_NO_BLOCK;
        block.succ1 = SSA_NO_BLOCK;
        // A call's semantic fallthrough stays in the decoded graph for
        // liveness; native control stops and later enters its successor fresh.
        if (block.returns) continue;
        if (block.jump) {
            block.succ0 = cfg.nodes[node.branch_target].block;
        } else if (block.conditional) {
            block.succ1 = cfg.nodes[node.branch_target].block;
            if (i + 1 < cfg.instruction_count) block.succ0 = cfg.nodes[i + 1].block;
        } else if (node.successor_count != 0) {
            block.succ0 = cfg.nodes[node.successors[0]].block;
        }
    }
    if (!ssa_collect_predecessors(g)) return false;
    // Keep semantic call edges when finding registers needed by deoptimization
    // and post-call entry. Native proof propagation uses the cut edges above.
    // Mapped arguments are rejected by loop analysis. Own locals observed by
    // closures require CELL/environment/closure opcodes, which eligibility
    // refuses; importing captures does not itself make these locals observable.
    compiler::RegSet[SSA_SPAN * 2] sets;
    uint[2][SSA_SPAN * 2 + 1] words;
    for (uint i = 0; i < cfg.instruction_count * 2; i++) {
        sets[i] = { .words = &words[i][0], .word_count = 2 };
    }
    compiler::RegSet scratch = { .words = &words[cfg.instruction_count * 2][0], .word_count = 2 };
    compiler::bytecode_cfg_liveness(&cfg, &sets[0], &sets[cfg.instruction_count], &scratch);
    for (uint index = 0; index < cfg.instruction_count; index++) {
        uint* live = sets[cfg.instruction_count + index].words;
        uint pc = cfg.nodes[index].view.pc;
        g.recovery_live[pc - g.plan.begin] = (ulong)live[0] | ((ulong)live[1] << 32);
    }
    for (uint b = 0; b < g.block_count; b++) {
        g.cyclic_live[b] = g.recovery_live[g.blocks[b].begin - g.plan.begin];
    }
    return true;
}
