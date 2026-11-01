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
    compiler::DecodedCfg* cfg = &g.decoded;
    if (cfg.storage == null) {
        usz bytes = (usz)cf.code_count * (compiler::DecodedCfgNode::size + uint::size);
        if (g.persistent_bytes > g.budget.max_bytes - g.storage_bytes
            || bytes > g.budget.max_bytes - g.storage_bytes - g.persistent_bytes) { g.failed = true; return false; }
        compiler::DecodedCfgBudget budget = { g.budget.max_words, g.budget.max_instructions, bytes };
        if (!compiler::bytecode_cfg_build(cfg, cf.code, cf.code_count, g.heap, null, true, budget, &ssa_decoded_helper_op, &ssa_cfg_extra_reads, cf)) return false;
        g.storage_bytes += bytes;
    }
    if (cfg.block_count > g.block_capacity) return false;
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
            if (block.external) {
                if (g.plan.ssa_data != null) g.plan.ssa_data.resume_words[block.begin / 32] |= 1U << (block.begin % 32);
                if (block.begin < SSA_SPAN) g.plan.ssa_resume_pcs[block.begin >> 6] |= 1UL << (block.begin & 63);
            }
        }
        block.end = node.view.pc;
        if (i + 1 < cfg.instruction_count && cfg.nodes[i + 1].block == node.block) continue;
        Opcode op = node.view.insn.op;
        bool native_helper = op == Opcode.CALL || op == Opcode.CALL_UNDEF_THIS
            || op == Opcode.CALL_GLOBAL || op == Opcode.CALL_VAR;
        block.returns = op == Opcode.RET || op == Opcode.RETUNDEF || (node.call && !native_helper);
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
    uint count = cfg.instruction_count;
    compiler::RegSet* sets = (compiler::RegSet*)ssa_storage_alloc(g, (usz)count * 2, compiler::RegSet::size);
    uint* words = (uint*)ssa_storage_alloc(g, ((usz)count * 2 + 1) * g.reg_words, uint::size);
    if (g.failed) return false;
    for (uint i = 0; i < count * 2; i++) sets[i] = { .words = words + (usz)i * g.reg_words, .word_count = g.reg_words };
    compiler::RegSet scratch = { .words = words + (usz)count * 2 * g.reg_words, .word_count = g.reg_words };
    if (!compiler::bytecode_cfg_liveness(cfg, sets, sets + count, &scratch, true, false, &ssa_cfg_charge_work, g)) return false;
    for (uint index = 0; index < count; index++) {
        uint pc = cfg.nodes[index].view.pc;
        g.recovery_live[pc - g.plan.begin].copy_from(&sets[count + index]);
    }
    for (uint b = 0; b < g.block_count; b++) {
        g.cyclic_live[b].copy_from(&g.recovery_live[g.blocks[b].begin - g.plan.begin]);
    }
    return ssa_normalize_entries(g);
}

// The canonical instruction roles can depend on function metadata. Closure
// creation reads its parent capture owner/value even though no operand names it.
fn void ssa_cfg_extra_reads(void* context, DecodedBytecode view, compiler::RegSet* reads) @feat(SLJIT) {
    CompiledFunction* cf = (CompiledFunction*)context;
    if (view.insn.op != Opcode.CLOSURE) return;
    uint index = view.insn.get_bc();
    if (index >= cf.inner_count) return;
    CompiledFunction* child = cf.inner_funcs[index];
    if (child.capture_cells == null) return;
    for (uint i = 0; i < child.capture_count; i++) {
        if (child.capture_cells[i] != 0) { reads.set(child.capture_parent_reg); return; }
    }
}
