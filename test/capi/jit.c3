module jit_test;

import boomkat;
import boomkat::bytecode;
import boomkat::compiler;
import boomkat::heap;
import boomkat::hobject;
import boomkat::vm;
import std::io;
import libc;

const String FUNCTION_SOURCE = $embed("../sljit_function.js");
const String REGION_SOURCE   = $embed("../sljit_regions.js");
const String LOOP_SOURCE     = $embed("../sljit_loop.js");
const String NATIVE_SOURCE   = $embed("../jit_native_calls.js");
const String RECOVERY_SOURCE = $embed("../jit_inline_recovery.js");
const String ALLOCATION_SOURCE = $embed("../jit_alloc_continuations.js");
const String LINK_SOURCE = $embed("../jit_linked_calls.js");
const String SSA_CALLS_SOURCE = $embed("../jit_function_ssa_calls.js");
const String SSA_REGIONS_SOURCE = $embed("../jit_ssa_call_regions.js");
const String CFG_SOURCE = $embed("../jit_cfg_numbers.js");
const String TEMPLATE_SOURCE = $embed("jit_render.js");
const String RUN             = "for(var i=0;i<64;i++){if(render(rows)!=='<li>1:one</li><li>2:two</li>')throw new Error('render');}";

macro void @check(#condition) {
    if (!(#condition)) {
        io::eprintfn("embedding JIT check failed: %s", $stringify(#condition));
        libc::exit(1);
    }
}

// Exercise the optimizer directly: a property key index can equal the local
// alias register even when earlier passes hide that pattern in source tests.
fn void check_parameter_alias_roles() {
    Opcode[3] ops = { Opcode.GETPROPC, Opcode.GETPROPC_CACHED, Opcode.GETTHISC };
    foreach (op : ops) {
        Instruction[5] code = {
            bytecode::make_abc(Opcode.LDREG, 1, 0, 0),
            bytecode::make_abc(op, 2, 1, 0),
            bytecode::make_abc(op, 3, 1, 1),
            bytecode::make_abc(Opcode.ADD, 2, 2, 3),
            bytecode::make_abc(Opcode.RET, 2, 0, 0)
        };
        bool[5] targets;
        CompilerContext ctx = { .code = &code[0], .code_count = 5, .num_args = 1, .max_reg = 4 };
        ctx.bindings.push({ .reg = 1, .kind = VAR });
        defer ctx.bindings.free();
        @check(compiler::eliminate_parameter_aliases(&ctx, &targets[0]));
        @check(code[0].op == Opcode.NOP && code[1].c == 0 && code[2].c == 1);
        if (op != Opcode.GETTHISC) @check(code[1].b == 0 && code[2].b == 0);
    }
}

// The shared decoder retains the prefix PC while exposing effective operands.
fn void check_decoded_bytecode() {
    Instruction[5] code = {
        bytecode::make_abc(Opcode.NOP, 0, 0, 0),
        bytecode::make_wide(1, 2, 3),
        bytecode::make_abc(Opcode.LDREG, 4, 5, 6),
        bytecode::make_wide(0, 0, 0), bytecode::make_wide(0, 0, 0)
    };
    DecodedBytecode narrow = bytecode::decode_bytecode(&code[0], 5, 0);
    @check(narrow.valid && !narrow.wide && narrow.pc == 0 && narrow.payload_pc == 0 && narrow.next_pc == 1);
    DecodedBytecode wide = bytecode::decode_bytecode(&code[0], 5, 1);
    @check(wide.valid && wide.wide && wide.pc == 1 && wide.payload_pc == 2 && wide.next_pc == 3);
    @check(wide.insn.op == Opcode.LDREG && wide.insn.a == 260 && wide.insn.b == 517 && wide.insn.c == 774);
    @check(wide.insn.get_bc() == 0x03020605);
    uint cursor = 1;
    DecodedBytecode once = bytecode::decode_bytecode(&code[0], 5, cursor++);
    @check(cursor == 2 && once.valid && once.pc == 1 && once.next_pc == 3);
    @check(!bytecode::decode_bytecode(&code[0], 2, 1).valid);
    @check(!bytecode::decode_bytecode(&code[0], 5, 3).valid);
    @check(!bytecode::decode_bytecode(&code[0], 5, 5).valid);

    // GETVAR's BC is a constant-pool index, not two register operands.
    Instruction[2] binding = { bytecode::make_wide(1, 0, 0), bytecode::make_a_bc(Opcode.GETVAR, 44, 0x1234) };
    uint[32] words;
    compiler::RegSet used = { .words = &words[0], .word_count = 32 };
    compiler::bytecode_register_set(&binding[0], 0, 1, &used);
    @check(used.test(300) && !used.test(0x34) && !used.test(0x12));
}

// Decoded uses include high-register windows and keep property constants and
// string-join counts distinct from register operands.
fn void check_decoded_register_uses() {
    if (!compiler::moveelim_roles_ready) compiler::moveelim_init_roles();
    uint[32] words;
    compiler::RegSet used = { .words = &words[0], .word_count = 32 };
    DecodedInsn property = { Opcode.GETPROPC, 300, 301, 23 };
    used.clear(); compiler::moveelim_add_decoded_uses(property, &used, true);
    @check(used.test(301) && !used.test(300) && !used.test(23));
    uint def;
    @check(compiler::moveelim_get_decoded_def(property, &def) && def == 300);
    DecodedInsn join = { Opcode.STRJOIN, 300, 500, 3 };
    used.clear(); compiler::moveelim_add_decoded_uses(join, &used, true);
    @check(used.test(500) && used.test(501) && used.test(502) && !used.test(503) && !used.test(3));
    DecodedInsn call = { Opcode.CALL, 300, 400, 3 };
    used.clear(); compiler::moveelim_add_decoded_uses(call, &used, true);
    @check(used.test(400) && used.test(401) && used.test(402) && used.test(403) && used.test(404));
    @check(!compiler::moveelim_get_decoded_def(call, &def));
}

// Independent path-exclusion oracle for four-block control-flow graphs.
fn uint dominance_reachable(uint edges, int excluded) {
    if (excluded == 0) return 0;
    uint reached = 1;
    bool changed = true;
    while (changed) {
        changed = false;
        for (uint from = 0; from < 4; from++) {
            if ((reached & (1U << from)) == 0) continue;
            for (uint to = 0; to < 4; to++) {
                if ((int)to == excluded || (edges & (1U << (from * 4 + to))) == 0) continue;
                if ((reached & (1U << to)) == 0) { reached |= 1U << to; changed = true; }
            }
        }
    }
    return reached;
}

fn void check_ssa_cyclic_dominance(JsRuntime* runtime) {
    Heap* h = runtime.rt.heap;
    SsaGraph* graph = (SsaGraph*)h.alloc_func(h.heap_udata, SsaGraph::size);
    @check(graph != null);
    defer vm::ssa_graph_free(graph);
    std::core::mem::clear(graph, (sz)SsaGraph::size);
    graph.heap = h;
    graph.reg_count = vm::LOOP_REGS;
    graph.reg_words = (graph.reg_count + 31) / 32;
    @check(vm::ssa_graph_tables(graph, 11));
    @check(vm::ssa_reserve_values(graph, 3));
    // The real splitter must not invent a successor to entry for a missing
    // second edge. A loop has only its actual latch as an entry predecessor.
    Instruction[5] code = {
        bytecode::make_a_sbx(Opcode.IF_FALSE, 0, 2),
        bytecode::make_abc(Opcode.LDINT, 1, 0, 0),
        bytecode::make_sabc(Opcode.JUMP, 1),
        bytecode::make_abc(Opcode.LDINT, 1, 0, 0),
        bytecode::make_abc(Opcode.LDINT, 2, 0, 0)
    };
    CompiledFunction cf = { .code = &code[0], .code_count = code.len };
    LoopPlan plan = { .begin = 0, .end = 4 };
    graph.cf = &cf; graph.plan = &plan; graph.single_pass = true;
    @check(vm::ssa_split_blocks(graph));
    @check(graph.block_count == 4 && graph.blocks[0].pred_count == 0);
    @check(graph.blocks[1].succ1 == vm::SSA_NO_BLOCK && graph.blocks[2].succ1 == vm::SSA_NO_BLOCK);
    @check(graph.blocks[3].succ0 == vm::SSA_NO_BLOCK && graph.blocks[3].succ1 == vm::SSA_NO_BLOCK);
    code[4] = bytecode::make_a_sbx(Opcode.IF_TRUE, 0, -5);
    graph.single_pass = false;
    @check(vm::ssa_split_blocks(graph));
    @check(graph.blocks[0].pred_count == 1 && graph.blocks[0].preds[0] == 3);

    // Several diamonds previously overflowed entry's four-predecessor
    // limit solely because each fallthrough block invented an entry edge.
    Instruction[11] diamonds = {
        bytecode::make_a_sbx(Opcode.IF_FALSE, 0, 1), bytecode::make_abc(Opcode.LDINT, 1, 0, 0),
        bytecode::make_a_sbx(Opcode.IF_FALSE, 0, 1), bytecode::make_abc(Opcode.LDINT, 1, 0, 0),
        bytecode::make_a_sbx(Opcode.IF_FALSE, 0, 1), bytecode::make_abc(Opcode.LDINT, 1, 0, 0),
        bytecode::make_a_sbx(Opcode.IF_FALSE, 0, 1), bytecode::make_abc(Opcode.LDINT, 1, 0, 0),
        bytecode::make_a_sbx(Opcode.IF_FALSE, 0, 1), bytecode::make_abc(Opcode.LDINT, 1, 0, 0),
        bytecode::make_abc(Opcode.LDINT, 2, 0, 0)
    };
    cf.code = &diamonds[0]; cf.code_count = diamonds.len;
    plan.end = diamonds.len - 1; graph.single_pass = true;
    @check(vm::ssa_split_blocks(graph));
    @check(graph.block_count == 11 && graph.blocks[0].pred_count == 0);

    graph.block_count = 4;
    uint[16] predecessors;
    for (uint b = 0; b < 4; b++) graph.blocks[b].preds = &predecessors[b * 4];
    // Exhaust all four-node graphs, including irreducible cycles, multiple
    // backedges, self loops, forward diamonds and unreachable blocks.
    for (uint edges = 0; edges < 65536; edges++) {
        uint reachable = dominance_reachable(edges, -1);
        for (uint b = 0; b < 4; b++) graph.blocks[b].pred_count = 0;
        for (uint from = 0; from < 4; from++) for (uint to = 0; to < 4; to++) {
            if ((edges & (1U << (from * 4 + to))) == 0) continue;
            SsaBlock* block = &graph.blocks[to];
            block.preds[block.pred_count++] = from;
        }
        vm::ssa_dominators(graph);
        for (uint b = 0; b < 4; b++) {
            if ((reachable & (1U << b)) == 0) {
                @check(graph.dominators[b] == (1U << b));
                continue;
            }
            uint expected;
            for (uint d = 0; d < 4; d++) {
                if ((dominance_reachable(edges, (int)d) & (1U << b)) == 0) expected |= 1U << d;
            }
            @check(graph.dominators[b] == expected);
        }
    }
    // An unreachable predecessor does not remove a reachable dominator.
    graph.block_count = 4;
    for (uint b = 0; b < 4; b++) graph.blocks[b].pred_count = 0;
    graph.blocks[1].preds[0] = 2; graph.blocks[1].pred_count = 1;
    graph.blocks[2].preds[0] = 0; graph.blocks[2].preds[1] = 1;
    graph.blocks[2].preds[2] = 3; graph.blocks[2].pred_count = 3;
    vm::ssa_dominators(graph);
    @check(graph.dominators[1] == 7 && graph.dominators[2] == 5 && graph.dominators[3] == 8);
    // The load optimizer consumes these dominance facts: block 2 dominates
    // block 1 even though its number is greater and the graph has a backedge.
    graph.value_count = 3;
    graph.values[0] = { .op = CONST_I, .rep = INT32, .block = 0 };
    graph.values[1] = { .op = LOAD, .rep = INT32, .a = 0, .imm = 0, .block = 2 };
    graph.values[2] = { .op = LOAD, .rep = INT32, .a = 0, .imm = 0, .block = 1 };
    vm::ssa_cse(graph);
    @check(graph.values[2].op == SsaOp.COPY && graph.values[2].a == 1);
}

// Exercise structural boundaries independently of JavaScript register reuse.
fn void check_ssa_dynamic_storage(JsRuntime* runtime) {
    Heap* h = runtime.rt.heap;
    SsaGraph* graph = (SsaGraph*)h.alloc_func(h.heap_udata, SsaGraph::size);
    @check(graph != null);
    *graph = { .heap = h, .reg_count = 70, .reg_words = 3 };
    defer vm::ssa_graph_free(graph);
    @check(vm::ssa_graph_tables(graph, 70));
    graph.block_count = 70;
    for (uint b = 0; b < graph.block_count; b++) {
        graph.blocks[b].succ0 = b == 69 ? 32 : b + 1;
        graph.blocks[b].succ1 = vm::SSA_NO_BLOCK;
    }
    @check(vm::ssa_collect_predecessors(graph));
    vm::ssa_dominators(graph);
    @check(!graph.failed && graph.dominator_words == 3);
    @check(vm::ssa_dominates(graph, 0, 69) && vm::ssa_dominates(graph, 32, 69));
    @check(vm::ssa_dominates(graph, 64, 69) && !vm::ssa_dominates(graph, 64, 32));
    graph.blocks[40].external = true;
    vm::ssa_dominators(graph);
    @check(!vm::ssa_dominates(graph, 0, 69) && !vm::ssa_dominates(graph, 32, 69));
    @check(vm::ssa_dominates(graph, 40, 69));
    int first = vm::ssa_value(graph, SsaOp.CONST_I, SsaRep.INT32, -1, -1, 123);
    int[2] registers = { first, -1 };
    SsaFrameId frame = vm::ssa_frame_capture(graph, 7, &registers[0], 2);
    for (uint value = 0; value < 1024; value++) {
        int id = vm::ssa_value(graph, SsaOp.CONST_I, SsaRep.INT32, -1, -1, value);
        @check(id == (int)value + 1);
    }
    @check(!graph.failed && graph.value_count == 1025);
    @check(graph.values[first].imm == 123 && graph.values[1024].imm == 1023);
    @check(vm::ssa_frame_lookup(graph, frame, 0) == first && vm::ssa_frame_lookup(graph, frame, 1) == -1);
    graph.budget.max_values = graph.value_count;
    @check(!vm::ssa_reserve_values(graph, graph.value_capacity + 1) && graph.failed);
    vm::ssa_result(graph, 0, 1, 2);
    vm::ssa_use(graph, 0);
    @check(vm::ssa_convert(graph, 0, SsaRep.F64, false) == 0);
    SsaGraph failed = { .heap = h, .budget = vm::SSA_DEFAULT_BUDGET };
    failed.budget.max_bytes = 1;
    @check(vm::ssa_value(&failed, SsaOp.CONST_I, SsaRep.INT32, -1, -1, 1) == 0);
    @check(failed.failed && failed.value_count == 0 && failed.values != null);
    vm::ssa_result(&failed, 0, 0, 0);
    vm::ssa_storage_free(&failed);
}

// Verify WIDE-aware CFG joins, loop fixed points and recovery from the real
// SSA continuation consumer. Targets into WIDE payloads must refuse.
fn void check_decoded_liveness(JsRuntime* runtime) {
    Instruction[11] code = {
        bytecode::make_wide(1, 0, 0), bytecode::make_a_sbx(Opcode.IF_FALSE, 44, 3),
        bytecode::make_wide(1, 0, 0), bytecode::make_abc(Opcode.LDREG, 45, 6, 0),
        bytecode::make_sabc(Opcode.JUMP, 2),
        bytecode::make_wide(1, 0, 0), bytecode::make_abc(Opcode.LDREG, 45, 7, 0),
        bytecode::make_wide(1, 1, 0), bytecode::make_abc(Opcode.LDREG, 48, 45, 0),
        bytecode::make_wide(1, 0, 0), bytecode::make_abc(Opcode.RET, 48, 0, 0)
    };
    compiler::RegSet[22] sets;
    uint[736] words;
    for (uint i = 0; i < sets.len; i++) sets[i] = { .words = &words[i * 32], .word_count = 32 };
    compiler::RegSet scratch = { .words = &words[704], .word_count = 32 };
    bool[11] boundary;
    @check(compiler::moveelim_compute_decoded_liveness(&code[0], code.len, &sets[0], &sets[11], &scratch, &boundary[0]));
    @check(sets[11].test(300) && sets[11].test(6) && sets[11].test(7) && !sets[11].test(301));
    @check(sets[18].test(301) && !sets[18].test(6) && !sets[18].test(7));
    @check(boundary[0] && !boundary[1] && boundary[5] && !boundary[6]);

    CompiledFunction cf = { .code = &code[0], .code_count = code.len, .num_regs = 512 };
    LoopPlan plan = { .end = 4 };
    for (uint i = 0; i < vm::LOOP_REGS; i++) plan.slot_reg[i] = (int)i;
    Heap* h = runtime.rt.heap;
    SsaGraph* graph = (SsaGraph*)h.alloc_func(h.heap_udata, SsaGraph::size);
    @check(graph != null);
    defer h.free_func(h.heap_udata, graph);
    std::core::mem::clear(graph, (sz)SsaGraph::size);
    graph.cf = &cf; graph.plan = &plan; graph.heap = h;
    graph.reg_count = vm::LOOP_REGS;
    graph.reg_words = (graph.reg_count + 31) / 32;
    bool[vm::LOOP_REGS] live;
    @check(vm::ssa_continuation_live(graph, &live[0]));
    @check(live[7] && !live[6]);
    // Aliased loop bodies are temporarily rewritten; their surrounding
    // bytecode still names original registers and must use the fallback.
    plan.slot_reg[0] = 300;
    @check(!vm::ssa_continuation_live(graph, &live[0]));
    plan.slot_reg[0] = 0;

    // Shared canonical nodes retain recovery/cache PCs and high register roles.
    compiler::DecodedCfg decoded;
    @check(compiler::bytecode_cfg_build(&decoded, &code[0], code.len, h));
    @check(decoded.instruction_count == 6 && decoded.word_count == 11 && decoded.has_wide);
    @check(decoded.nodes[0].view.pc == 0 && decoded.nodes[0].view.payload_pc == 1
        && decoded.nodes[0].view.next_pc == 2);
    @check(decoded.pc_to_index[1] == compiler::CFG_NO_INSTRUCTION && decoded.pc_to_index[5] == 3);
    @check(decoded.nodes[0].branch_target == 3 && decoded.nodes[0].successor_count == 2);
    compiler::bytecode_cfg_free(&decoded);
    compiler::DecodedCfgBudget tiny = { .max_words = 10, .max_instructions = 10, .max_bytes = 4096 };
    @check(!compiler::bytecode_cfg_build(&decoded, &code[0], code.len, h, budget: tiny));
    tiny = { .max_words = 20, .max_instructions = 2, .max_bytes = 4096 };
    @check(!compiler::bytecode_cfg_build(&decoded, &code[0], code.len, h, budget: tiny));
    tiny = { .max_words = 20, .max_instructions = 20, .max_bytes = 1 };
    @check(!compiler::bytecode_cfg_build(&decoded, &code[0], code.len, h, budget: tiny));
    Instruction[2] malformed = { bytecode::make_wide(1, 0, 0), bytecode::make_wide(0, 0, 0) };
    @check(!compiler::bytecode_cfg_build(&decoded, &malformed[0], 1, h));
    @check(!compiler::bytecode_cfg_build(&decoded, &malformed[0], malformed.len, h));
    malformed[0] = bytecode::make_a_bc(Opcode.TRY, 0, 1);
    malformed[1] = bytecode::make_abc(Opcode.RETUNDEF, 0, 0, 0);
    @check(!compiler::bytecode_cfg_build(&decoded, &malformed[0], malformed.len, h));
    malformed[0] = bytecode::make_a_bc(Opcode.LDINTX, 0, 1);
    @check(!compiler::bytecode_cfg_build(&decoded, &malformed[0], malformed.len, h));
    Instruction[2] calls = { bytecode::make_abc(Opcode.CALL, 0, 1, 0),
        bytecode::make_abc(Opcode.RET, 0, 0, 0) };
    @check(compiler::bytecode_cfg_build(&decoded, &calls[0], calls.len, h, split_calls: true));
    @check(decoded.nodes[0].call && decoded.nodes[0].successor_count == 1
        && decoded.nodes[1].external && decoded.nodes[1].block_entry && decoded.block_count == 2);
    compiler::bytecode_cfg_free(&decoded);

    // GETPROP_CACHE's semantic destination is independent of the compiler's
    // producer-retarget allow-list: a prior boolean in A is dead at this load.
    Instruction[2] property = { bytecode::make_abc(Opcode.GETPROP_CACHE, 5, 0, 3),
        bytecode::make_abc(Opcode.RETUNDEF, 0, 0, 0) };
    @check(compiler::moveelim_compute_decoded_liveness(&property[0], property.len,
        &sets[0], &sets[11], &scratch, &boundary[0], h));
    @check(!sets[11].test(5) && sets[11].test(0) && sets[11].test(3));
    Instruction[3] wide_property = { bytecode::make_wide(1, 1, 1),
        bytecode::make_abc(Opcode.GETPROP_CACHE, 5, 0, 3),
        bytecode::make_abc(Opcode.RETUNDEF, 0, 0, 0) };
    @check(compiler::moveelim_compute_decoded_liveness(&wide_property[0], wide_property.len,
        &sets[0], &sets[11], &scratch, &boundary[0], h));
    @check(!sets[11].test(261) && sets[11].test(256) && sets[11].test(259));

    // Named property stores read receiver/value, never their constant-pool C.
    property[0] = bytecode::make_abc(Opcode.PUTPROPC, 0, 8, 4);
    @check(compiler::moveelim_compute_decoded_liveness(&property[0], property.len,
        &sets[0], &sets[11], &scratch, &boundary[0], h));
    @check(sets[11].test(0) && sets[11].test(8) && !sets[11].test(4));
    wide_property[1] = bytecode::make_abc(Opcode.PUTPROPC, 0, 8, 4);
    @check(compiler::moveelim_compute_decoded_liveness(&wide_property[0], wide_property.len,
        &sets[0], &sets[11], &scratch, &boundary[0], h));
    @check(sets[11].test(256) && sets[11].test(264) && !sets[11].test(260));

    // Destination-only and unary operations must not import unused operand
    // bytes as registers (especially stale r0 or a prior branch condition).
    Opcode[] destination_ops = { Opcode.GETTHISC, Opcode.INC_VAR, Opcode.DEC_VAR,
        Opcode.INC_GLOBAL, Opcode.DEC_GLOBAL, Opcode.NEWOBJ, Opcode.LDTHIS, Opcode.VOID };
    foreach (op : destination_ops) {
        property[0] = bytecode::make_abc(op, 5, 7, 11);
        @check(compiler::bytecode_cfg_build(&decoded, &property[0], property.len, h));
        uint primary;
        @check(decoded.nodes[0].must_def(&primary) && primary == 5);
        scratch.clear(); decoded.nodes[0].reads(&scratch);
        @check(!scratch.test(0) && !scratch.test(5) && !scratch.test(7) && !scratch.test(11));
        compiler::bytecode_cfg_free(&decoded);
    }
    Opcode[] unary_ops = { Opcode.UNP, Opcode.UNM, Opcode.BNOT, Opcode.LNOT, Opcode.TYPEOF, Opcode.GETPROTO, Opcode.TONUMERIC };
    foreach (op : unary_ops) {
        property[0] = bytecode::make_abc(op, 5, 7, 11);
        @check(compiler::moveelim_compute_decoded_liveness(&property[0], property.len,
            &sets[0], &sets[11], &scratch, &boundary[0], h));
        @check(sets[11].test(7) && !sets[11].test(5) && !sets[11].test(11) && !sets[11].test(0));
    }
    Opcode[] inplace_ops = { Opcode.INC, Opcode.INC_LT, Opcode.DEC, Opcode.TOPROPKEY, Opcode.TOSTR };
    foreach (op : inplace_ops) {
        property[0] = bytecode::make_abc(op, 5, 7, 11);
        @check(compiler::moveelim_compute_decoded_liveness(&property[0], property.len,
            &sets[0], &sets[11], &scratch, &boundary[0], h));
        @check(sets[11].test(5) && !sets[11].test(7) && !sets[11].test(11) && !sets[11].test(0));
    }
    // Calls read real windows and spread counts, never literal counts/keys or
    // an overwritten result slot. Aliasing A with a genuine input remains live.
    property[0] = bytecode::make_abc(Opcode.CALL, 5, 10, 2);
    @check(compiler::moveelim_compute_decoded_liveness(&property[0], property.len,
        &sets[0], &sets[11], &scratch, &boundary[0], h));
    @check(sets[11].test(10) && sets[11].test(11) && sets[11].test(12) && sets[11].test(13)
        && !sets[11].test(2) && !sets[11].test(5));
    property[0] = bytecode::make_abc(Opcode.CALL_UNDEF_THIS, 5, 10, 2);
    @check(compiler::moveelim_compute_decoded_liveness(&property[0], property.len,
        &sets[0], &sets[11], &scratch, &boundary[0], h));
    @check(sets[11].test(10) && !sets[11].test(11) && sets[11].test(12) && sets[11].test(13)
        && !sets[11].test(2) && !sets[11].test(5));
    Opcode[] fused_calls = { Opcode.CALL_VAR, Opcode.CALL_GLOBAL };
    foreach (op : fused_calls) {
        property[0] = bytecode::make_abc(op, 10, 2, 7);
        @check(compiler::moveelim_compute_decoded_liveness(&property[0], property.len,
            &sets[0], &sets[11], &scratch, &boundary[0], h));
        @check(sets[11].test(12) && sets[11].test(13) && !sets[11].test(10)
            && !sets[11].test(11) && !sets[11].test(2) && !sets[11].test(7));
    }
    Opcode[] spread_calls = { Opcode.CALL_S, Opcode.SUPER_CALL_S };
    foreach (op : spread_calls) {
        property[0] = bytecode::make_abc(op, 5, 10, 3);
        @check(compiler::moveelim_compute_decoded_liveness(&property[0], property.len,
            &sets[0], &sets[11], &scratch, &boundary[0], h));
        @check(sets[11].test(3) && sets[11].test(10) && sets[11].test(11) && sets[11].test(1023)
            && !sets[11].test(5));
    }
    wide_property[0] = bytecode::make_wide(1, 1, 0);
    wide_property[1] = bytecode::make_abc(Opcode.CALL, 5, 10, 2);
    @check(compiler::moveelim_compute_decoded_liveness(&wide_property[0], wide_property.len,
        &sets[0], &sets[11], &scratch, &boundary[0], h));
    @check(sets[11].test(266) && sets[11].test(267) && sets[11].test(268) && sets[11].test(269)
        && !sets[11].test(261) && !sets[11].test(2));

    // This edge targets the LDREG payload, not its prefix.
    code[1] = bytecode::make_a_sbx(Opcode.IF_FALSE, 44, 4);
    @check(!compiler::moveelim_compute_decoded_liveness(&code[0], code.len, &sets[0], &sets[11], &scratch, &boundary[0]));
    @check(!vm::ssa_continuation_live(graph, &live[0]));

    Instruction[3] cyclic = {
        bytecode::make_wide(1, 1, 0), bytecode::make_abc(Opcode.LDREG, 44, 45, 0),
        bytecode::make_sabc(Opcode.JUMP, -3)
    };
    @check(compiler::moveelim_compute_decoded_liveness(&cyclic[0], cyclic.len, &sets[0], &sets[11], &scratch, &boundary[0]));
    @check(sets[2].test(301) && sets[11].test(301));
    Instruction[5] wide_backedge = {
        bytecode::make_wide(1, 1, 0), bytecode::make_abc(Opcode.LDREG, 44, 45, 0),
        bytecode::make_wide(1, 0, 0), bytecode::make_a_sbx(Opcode.IF_TRUE, 44, -4),
        bytecode::make_abc(Opcode.RET, 0, 0, 0)
    };
    @check(compiler::moveelim_compute_decoded_liveness(&wide_backedge[0], wide_backedge.len, &sets[0], &sets[11], &scratch, &boundary[0]));
    @check(sets[2].test(301) && sets[13].test(300) && sets[13].test(301));

    // On narrow bytecode, compare the decoded CFG against the established
    // liveness engine across a conditional and a backedge.
    Instruction[5] narrow = {
        bytecode::make_abc(Opcode.LDREG, 1, 0, 0), bytecode::make_a_sbx(Opcode.IF_FALSE, 1, 2),
        bytecode::make_abc(Opcode.ADD, 2, 1, 3), bytecode::make_sabc(Opcode.JUMP, -3),
        bytecode::make_abc(Opcode.RET, 2, 0, 0)
    };
    compiler::RegSet[10] original;
    uint[352] old_words;
    for (uint i = 0; i < original.len; i++) original[i] = { .words = &old_words[i * 32], .word_count = 32 };
    compiler::RegSet old_scratch = { .words = &old_words[320], .word_count = 32 };
    compiler::moveelim_compute_liveness(&narrow[0], narrow.len, &original[0], &original[5], true, &old_scratch);
    @check(compiler::moveelim_compute_decoded_liveness(&narrow[0], narrow.len, &sets[0], &sets[11], &scratch, &boundary[0]));
    for (uint i = 0; i < narrow.len; i++) {
        // The legacy RET reader conservatively marks unused B/C=0 as r0.
        // Canonical semantics intentionally remove that false dependency.
        for (uint reg = 1; reg < 1024; reg++) {
            @check(sets[i].test(reg) == original[i].test(reg));
            @check(sets[11 + i].test(reg) == original[5 + i].test(reg));
        }
    }
    @check(sets[11].test(0)); // The real LDREG source at function entry.
    @check(sets[15].test(2) && !sets[15].test(0)); // RET only reads its A.
}

// A WIDE call has a register window, not individually remappable fields. A
// refusal must conservatively reserve every low slot and every queried high
// register, even when the next instruction uses an otherwise free register.
fn void check_wide_alias_refusal() {
    Instruction[3] code = {
        bytecode::make_wide(1, 0, 0),
        bytecode::make_abc(Opcode.CALL, 0, 1, 0),
        bytecode::make_abc(Opcode.LDREG, 5, 7, 0)
    };
    @check(compiler::bytecode_low_register_mask(&code[0], 0, 2) == ulong::max);
    @check(compiler::bytecode_register_used(&code[0], 0, 2, 300));
    @check(compiler::bytecode_register_used(&code[0], 0, 2, 7));
}

// The alias window consumes one set for all low and high-register queries.
fn void check_alias_register_set() {
    Instruction[4] code = {
        bytecode::make_wide(1, 1, 0),
        bytecode::make_abc(Opcode.LDREG, 2, 3, 0),
        bytecode::make_abc(Opcode.GETPROPC, 4, 5, 7),
        bytecode::make_abc(Opcode.RET, 4, 0, 0)
    };
    uint[32] words;
    compiler::RegSet used = { .words = &words[0], .word_count = 32 };
    compiler::bytecode_register_set(&code[0], 0, 3, &used);
    @check(used.test(258) && used.test(259) && used.test(4) && used.test(5));
    @check(!used.test(7) && !used.test(2) && !used.test(3));
    ulong low = compiler::bytecode_low_register_mask(&code[0], 0, 3);
    @check((low & ((1UL << 4) | (1UL << 5))) == ((1UL << 4) | (1UL << 5)));
    @check((low & ((1UL << 7) | (1UL << 2) | (1UL << 3))) == 0);
    Instruction[1] call = { bytecode::make_abc(Opcode.CALL, 4, 10, 2) };
    compiler::bytecode_register_set(&call[0], 0, 0, &used);
    @check(used.test(4) && used.test(10) && used.test(11) && used.test(12) && used.test(13));
}

fn void eval(JsContext* ctx, String source) {
    JsValue? value = ctx.eval(source);
    if (catch err = value) {
        io::eprintfn("embedding JIT exception at %d: %s", ctx.last_error_line(), ctx.last_error());
        libc::exit(1);
        return;
    }
    ctx.release(value);
}

// Exercise real interpreter and generated stores against registered watches.
// An unrelated own slot must preserve the value dependency; changing layout
// must invalidate both slot and layout dependencies before storage can move.
fn void check_write_dependencies(JsRuntime* rt, JsContext* ctx) {
    eval(ctx, "var depObj={x:1,y:2};var depGlobal=1;function depPut(o,v){o.x=v;return o.x;}function depInc(){return ++depGlobal;}for(var i=0;i<200;i++){depPut(depObj,1);depInc();}");
    for (uint i = 0; i < 128; i++) eval(ctx, "depPut(depObj,1);");
    CompiledFunction* writer = named_function(rt, "depPut");
    @check(writer != null && writer.sljit_function != null);
    @check(((FunctionPlan*)writer.sljit_function).hits > 0);
    Heap* h = rt.rt.heap;
    HObject* globals = rt.rt.vm.global_env.bindings;
    int obj_idx = globals.find_prop_idx(h.str_intern("depObj"), h);
    @check(obj_idx >= 0);
    HObject* obj = globals.prop_values()[obj_idx].get().get_heapptr();
    int x = obj.find_prop_idx(h.str_intern("x"), h);
    int global_idx = globals.find_prop_idx(h.str_intern("depGlobal"), h);
    @check(x >= 0 && global_idx >= 0);
    bool value_live = true;
    bool layout_live = true;
    bool global_live = true;
    JitWriteDependency* value_watch = h.jit_watch_slot(obj, (uint)x, &value_live);
    JitWriteDependency* layout_watch = h.jit_watch_layout(obj, &layout_live);
    JitWriteDependency* global_watch = h.jit_watch_slot(globals, (uint)global_idx, &global_live);
    @check(value_watch != null && layout_watch != null && global_watch != null);
    eval(ctx, "depObj.y=17;");
    @check(value_live && layout_live && global_live);
    eval(ctx, "if(depPut(depObj,29)!==29)throw 'watched store';");
    @check(!value_live && layout_live && global_live);
    value_live = true;
    eval(ctx, "depObj.extra=3;");
    @check(!value_live && !layout_live && global_live);
    eval(ctx, "depInc();");
    @check(!global_live);
    h.jit_unwatch(value_watch);
    h.jit_unwatch(layout_watch);
    h.jit_unwatch(global_watch);
    // Rebind after the shape change, then exercise descriptor and prototype
    // mutations through their ordinary runtime APIs.
    x = obj.find_prop_idx(h.str_intern("x"), h);
    value_live = true;
    layout_live = true;
    value_watch = h.jit_watch_slot(obj, (uint)x, &value_live);
    layout_watch = h.jit_watch_layout(obj, &layout_live);
    @check(value_watch != null && layout_watch != null);
    eval(ctx, "Object.defineProperty(depObj,'x',{value:31});");
    @check(!value_live);
    eval(ctx, "Object.setPrototypeOf(depObj,null);");
    @check(!layout_live);
    h.jit_unwatch(value_watch);
    h.jit_unwatch(layout_watch);

    // Doubles force INC_VAR through the switch's variable-IC arithmetic
    // path rather than the threaded fastint handler.
    @check(rt.set_jit(false));
    eval(ctx, "function depFactory(){var n=0.5;return function depClosure(){return ++n;};}var depClosure=depFactory();for(var j=0;j<100;j++)depClosure();");
    CompiledFunction* closure = named_function(rt, "depClosure");
    @check(closure != null && closure.var_ic_entries != null);
    VarICEntry* inc_ic;
    for (uint pc = 0; pc < closure.code_count; pc++) {
        if (closure.code[pc].op == Opcode.INC_VAR) {
            inc_ic = (VarICEntry*)closure.var_ic_entries + pc;
            break;
        }
    }
    @check(inc_ic != null && inc_ic.env != null && inc_ic.bindings != null);
    HObject* binding_owner = (HObject*)inc_ic.bindings;
    bool binding_live = true;
    JitWriteDependency* binding_watch = h.jit_watch_slot(binding_owner, inc_ic.prop_idx, &binding_live);
    @check(binding_watch != null);
    eval(ctx, "depClosure();");
    @check(!binding_live);
    TVal integer;
    integer.set_fastint(3);
    h.store_slot(binding_owner, inc_ic.slot(), integer);
    binding_live = true;
    eval(ctx, "depClosure();");
    @check(!binding_live);
    integer.set_fastint(types::FASTINT_MAX);
    h.store_slot(binding_owner, inc_ic.slot(), integer);
    binding_live = true;
    eval(ctx, "depClosure();");
    @check(!binding_live);
    h.jit_unwatch(binding_watch);
    @check(rt.set_jit());
}

// A later stable receiver shape must refresh the compiled read, rather than
// merely return correct values through the helper forever.
fn void check_read_refresh(JsRuntime* rt, JsContext* ctx) @feat(SLJIT_READ_REFRESH) {
    eval(ctx, "var rrFirst={x:1},rrSecond={y:0,x:2};function rrRead(o){return o.x+1;}");
    for (uint i = 0; i < 160; i++) eval(ctx, "if(rrRead(rrFirst)!==2)throw 'first shape';");
    CompiledFunction* cf = named_function(rt, "rrRead");
    @check(cf != null && cf.sljit_function != null && cf.ic_entries != null);
    uint read_pc;
    bool found_read;
    for (uint pc = 0; pc < cf.code_count; pc++) {
        if (cf.code[pc].op == Opcode.GETPROPC || cf.code[pc].op == Opcode.GETPROPC_CACHED) {
            read_pc = pc;
            found_read = true;
            break;
        }
    }
    @check(found_read);
    FunctionPlan* initial = cf.sljit_function;
    @check(initial.hits > 0 && read_pc >= initial.begin && read_pc - initial.begin < vm::FUNCTION_OPS);
    ulong previous_hits = initial.hits;
    ulong old_misses;
    bool replaced;
    for (uint i = 0; i < 300 && !replaced; i++) {
        eval(ctx, "if(rrRead(rrSecond)!==3)throw 'later shape';");
        FunctionPlan* current = cf.sljit_function;
        if (current == null) continue;
        if (cf.sljit_read_refreshes != 0 && current.hits < previous_hits) {
            replaced = true;
        } else {
            previous_hits = current.hits;
            ulong misses = current.read_hits[read_pc - current.begin];
            if (misses > old_misses) old_misses = misses;
        }
    }
    @check(cf.sljit_read_refreshes > 0 && replaced && old_misses >= 32);
    FunctionPlan* refreshed = cf.sljit_function;
    @check(refreshed != null && !refreshed.read_refresh_requested);
    HObject* globals = rt.rt.vm.global_env.bindings;
    int index = globals.find_prop_idx(rt.rt.heap.str_intern("rrSecond"), rt.rt.heap);
    @check(index >= 0);
    HObject* receiver = globals.prop_values()[index].get().get_heapptr();
    Shape* shape = receiver.get_shape(rt.rt.heap);
    @check(shape != null);
    FunctionPlan probe = { .read_refresh_pc = read_pc, .read_refresh_shape = receiver.shape_id,
        .read_refresh_generation = shape.generation };
    @check(vm::sljit_read_refresh_ready(rt.rt.heap, cf, &probe));
    ulong misses_before = refreshed.read_hits[read_pc - refreshed.begin];
    ulong hits_before = refreshed.hits;
    for (uint i = 0; i < 80; i++) eval(ctx, "if(rrRead(rrSecond)!==3)throw 'refreshed shape';");
    @check(cf.sljit_function == refreshed && refreshed.hits > hits_before);
    @check(refreshed.read_hits[read_pc - refreshed.begin] - misses_before < 8);
    eval(ctx, "rrSecond.x=9;if(rrRead(rrSecond)!==10)throw 'updated value';rrSecond.z=5;if(rrRead(rrSecond)!==10)throw 'new layout';Object.defineProperty(rrSecond,'x',{get:function(){return 12;},configurable:true});if(rrRead(rrSecond)!==13)throw 'accessor fallback';");
    rt.rt.heap.mark_and_sweep(true, true);
    eval(ctx, "if(rrRead(rrSecond)!==13)throw 'read after GC';");
}

// A watch is the sole root of an object, including one installed after the
// incremental collector has passed its root list.
fn void check_dependency_gc() {
    Heap* h = heap::create(null, null, null, null, null)!!;
    HObject* obj = h.alloc_object(hobject::ObjClass.OBJECT)!!;
    bool live = true;
    h.jit_native_active = 1;
    @check(h.jit_watch_layout(obj, &live) == null);
    h.jit_native_active = 0;
    h.gc_begin_cycle(true);
    uint steps = 0;
    while (h.gc_root_stage <= 3 && h.gc_phase == heap::GcPhase.MARK && steps++ < 1000000) h.gc_step(1, true);
    @check(h.gc_phase == heap::GcPhase.MARK && h.gc_root_stage > 3);
    JitWriteDependency* first = h.jit_watch_layout(obj, &live);
    JitWriteDependency* second = h.jit_watch_layout(obj, &live);
    @check(first != null && second != null);
    steps = 0;
    while (h.gc_phase != heap::GcPhase.IDLE && steps++ < 1000000) h.gc_step(1, true);
    @check(h.gc_phase == heap::GcPhase.IDLE && h.live_obj_count == 1);
    h.jit_unwatch(first);
    h.mark_and_sweep(true, true);
    @check(h.live_obj_count == 1);
    h.jit_unwatch(second);
    h.mark_and_sweep(true, true);
    @check(h.live_obj_count == 0);

    // Reset and destruction free owners before compiled plans. Remaining
    // registrations invalidate their clients without touching dead owners.
    obj = h.alloc_object(hobject::ObjClass.OBJECT)!!;
    @check(h.jit_watch_layout(obj, &live) != null);
    h.reset();
    @check(!live && h.jit_write_buckets == null);
    live = true;
    obj = h.alloc_object(hobject::ObjClass.OBJECT)!!;
    @check(h.jit_watch_layout(obj, &live) != null);
    h.destroy();
    @check(!live);
}

fn ulong native_edges(JsRuntime* rt, String name, bool returns = false) {
    $if $feat(SLJIT) && $feat(SLJIT_STATS):
        for (uint i = 0; i < rt.rt.heap.compiled_func_count; i++) {
            CompiledFunction* cf = (CompiledFunction*)rt.rt.heap.compiled_funcs[i];
            if (cf == null || (String)cf.get_name() != name || cf.sljit_function == null) continue;
            FunctionPlan* plan = cf.sljit_function;
            return returns ? plan.direct_returns : plan.direct_calls;
        }
    $endif
    return 0;
}

fn ulong inline_recoveries(JsRuntime* rt) {
    ulong count;
    $if $feat(SLJIT) && $feat(SLJIT_STATS):
        for (uint i = 0; i < rt.rt.heap.compiled_func_count; i++) {
            CompiledFunction* cf = (CompiledFunction*)rt.rt.heap.compiled_funcs[i];
            if (cf != null && cf.sljit_function != null) count += ((FunctionPlan*)cf.sljit_function).inline_recoveries;
        }
    $endif
    return count;
}

fn CompiledFunction* named_function(JsRuntime* rt, String name) {
    for (uint i = 0; i < rt.rt.heap.compiled_func_count; i++) {
        CompiledFunction* cf = rt.rt.heap.compiled_funcs[i];
        if (cf != null && (String)cf.get_name() == name) return cf;
    }
    return null;
}

// Separate sites read the same shape/key: the second is answered from the
// shared cache on its first visit and must still acquire its own local entry.
fn bool local_read_warmed(JsRuntime* rt, String name) {
    for (uint i = 0; i < rt.rt.heap.compiled_func_count; i++) {
        CompiledFunction* cf = (CompiledFunction*)rt.rt.heap.compiled_funcs[i];
        if (cf == null || (String)cf.get_name() != name || cf.ic_entries == null) continue;
        for (uint pos = 0; pos < cf.code_count; pos++) {
            if (cf.code[pos].op != Opcode.GETPROPC && cf.code[pos].op != Opcode.GETPROPC_CACHED) continue;
            boomkat::hobject::ICEntry* ic = (boomkat::hobject::ICEntry*)cf.ic_entries + pos;
            return ic.key.borrow() == cf.constants[cf.code[pos].c].get_heapptr() && ic.shape_id != 0;
        }
    }
    return false;
}

fn uint plans(JsRuntime* rt) {
    uint result;
    $if $feat(SLJIT):
        for (uint i = 0; i < rt.rt.heap.compiled_func_count; i++) {
            CompiledFunction* cf = (CompiledFunction*)rt.rt.heap.compiled_funcs[i];
            if (cf != null && cf.sljit_template != null) result++;
        }
    $endif
    return result;
}

fn ulong native_hits(JsRuntime* rt) {
    ulong result;
    $if $feat(SLJIT) && $feat(SLJIT_STATS):
        for (uint i = 0; i < rt.rt.heap.compiled_func_count; i++) {
            CompiledFunction* cf = (CompiledFunction*)rt.rt.heap.compiled_funcs[i];
            if (cf == null) continue;
            if (cf.sljit_template != null) result += ((TemplatePlan*)cf.sljit_template).hits;
            if (cf.sljit_function != null) result += ((FunctionPlan*)cf.sljit_function).hits;
            for (LoopPlan* plan = cf.sljit_loops; plan != null; plan = plan.next) result += plan.hits;
        }
    $endif
    return result;
}

fn ulong function_hits(JsRuntime* rt, String name) {
    $if $feat(SLJIT) && $feat(SLJIT_STATS):
        for (uint i = 0; i < rt.rt.heap.compiled_func_count; i++) {
            CompiledFunction* cf = (CompiledFunction*)rt.rt.heap.compiled_funcs[i];
            if (cf != null && (String)cf.get_name() == name && cf.sljit_function != null) {
                return ((FunctionPlan*)cf.sljit_function).hits;
            }
        }
    $endif
    return 0;
}

// Native work done on behalf of a named function, by whichever tier compiled
// it: a whole function region, or the hot loop inside it. A loop that the loop
// tier can take is faster than compiling the enclosing function, so the tier
// that owns the work is not part of the contract this checks.
fn ulong region_work(JsRuntime* rt, String name, bool calls = false) {
    $if $feat(SLJIT) && $feat(SLJIT_STATS):
        for (uint i = 0; i < rt.rt.heap.compiled_func_count; i++) {
            CompiledFunction* cf = (CompiledFunction*)rt.rt.heap.compiled_funcs[i];
            if (cf == null || (String)cf.get_name() != name) continue;
            if (calls) {
                ulong work = cf.sljit_function != null ? ((FunctionPlan*)cf.sljit_function).inline_calls : 0;
                for (LoopPlan* plan = cf.sljit_loops; plan != null; plan = plan.next) {
                    if (plan.ssa_calls) work += plan.hits;
                }
                return work;
            }
            ulong work = 0;
            if (cf.sljit_function != null) work += ((FunctionPlan*)cf.sljit_function).charged_edges;
            for (LoopPlan* plan = cf.sljit_loops; plan != null; plan = plan.next) work += plan.hits;
            return work;
        }
    $endif
    return 0;
}

fn int stop_after_polls(void* runtime, void* opaque) {
    uint* polls = (uint*)opaque;
    (*polls)++;
    return *polls >= 3 ? 1 : 0;
}

// Detaching an owner during a suspended generated invocation must leave code
// and metadata alive and charged until its outer publication scope finishes.
fn void check_artifact_retirement() @feat(SLJIT) {
    JsRuntime runtime;
    runtime.create()!!;
    defer runtime.destroy();
    JsContext context;
    context.create(&runtime)!!;
    defer context.destroy();
    @check(runtime.set_jit());
    // These PCs collide in the former modulo-64 rejection mask. Capacity
    // retry must preserve the unsupported site and leave a third site open.
    CompiledFunction admission = { .code_count = 130 };
    Heap* admission_heap = runtime.rt.heap;
    vm::sljit_loop_decline(admission_heap, &admission, 1, true);
    vm::sljit_loop_decline(admission_heap, &admission, 65);
    @check(vm::sljit_loop_blocked(&admission, 1) && vm::sljit_loop_blocked(&admission, 65));
    @check(!vm::sljit_loop_blocked(&admission, 129));
    vm::sljit_budget_retry(admission_heap);
    vm::sljit_budget_retry_function(admission_heap, &admission);
    @check(!vm::sljit_loop_blocked(&admission, 1) && vm::sljit_loop_blocked(&admission, 65));
    admission_heap.free_func(admission_heap.heap_udata, admission.sljit_loop_admission);
    eval(&context, "function ownerTarget(x){return x+3;}");
    for (uint i = 0; i < 160; i++) eval(&context, "if(ownerTarget(4)!==7)throw 'owner';");
    Heap* h = runtime.rt.heap;
    CompiledFunction* cf = named_function(&runtime, "ownerTarget");
    @check(cf != null && cf.sljit_function != null);
    FunctionPlan* plan = cf.sljit_function;
    usz total = h.jit_code_bytes;
    usz bytes = plan.artifact.code_bytes;
    usz metadata = h.jit_metadata_bytes;
    usz owner_metadata = plan.artifact.metadata_bytes;
    ulong capacity = h.jit_capacity_generation;
    ulong generation = vm::sljit_artifact_enter(h, &plan.artifact);
    @check(generation != 0 && vm::sljit_artifact_is_live(&plan.artifact, generation));
    vm::sljit_function_free(h, cf);
    @check(cf.sljit_function == null && plan.artifact.state == JitArtifactState.RETIRED);
    @check(!vm::sljit_artifact_is_live(&plan.artifact, generation));
    @check(vm::sljit_artifact_enter(h, &plan.artifact) == 0);
    @check(h.jit_code_bytes == total && h.jit_retired_code_bytes == bytes);
    @check(h.jit_metadata_bytes == metadata && h.jit_capacity_generation == capacity);
    cf.sljit_budget_wait = true;
    cf.sljit_function_calls = uint::max;
    cf.sljit_capacity_seen = capacity;
    vm::sljit_budget_retry_function(h, cf);
    @check(cf.sljit_budget_wait && cf.sljit_function_calls == uint::max);
    vm::sljit_artifact_leave(h, &plan.artifact);
    @check(h.jit_code_bytes == total - bytes && h.jit_retired_code_bytes == 0);
    @check(h.jit_metadata_bytes == metadata - owner_metadata && h.jit_native_active == 0);
    @check(h.jit_capacity_generation != capacity);
    vm::sljit_budget_retry_function(h, cf);
    @check(!cf.sljit_budget_wait && cf.sljit_function_calls == 0);
    for (uint i = 0; i < 160; i++) eval(&context, "if(ownerTarget(4)!==7)throw 'recompile';");
    @check(cf.sljit_function != null);
    @check(((FunctionPlan*)cf.sljit_function).artifact.generation != generation);
}

// CALL_UNDEF_THIS clears its receiver before invoking, then writes the result.
// Hand-authored bytecode may place that result in the receiver slot itself.
fn void check_helper_result_receiver_alias() @feat(SLJIT) {
    JsRuntime runtime;
    runtime.create()!!;
    defer runtime.destroy();
    JsContext context;
    context.create(&runtime)!!;
    defer context.destroy();
    eval(&context, "function helperAlias(o,n,cb){var sum=0.25;for(var i=0;i<n;i++){o.count=o.count+1;var value=cb(i);sum=sum+value;}return sum;}function helperAliasCallback(i){return i+0.5;}");
    CompiledFunction* cf = named_function(&runtime, "helperAlias");
    @check(cf != null);
    bool changed;
    for (uint pc = 0; pc + 1 < cf.code_count; pc++) {
        Instruction* call = cf.code + pc;
        if (call.op != Opcode.CALL_UNDEF_THIS) continue;
        Instruction* copy = cf.code + pc + 1;
        @check(copy.op == Opcode.LDREG && copy.b == call.a);
        call.a = call.b + 1;
        copy.b = call.a;
        changed = true;
        break;
    }
    @check(changed && runtime.set_jit());
    // The fixture calls a helper per iteration, so the tier policy would move
    // it to the baseline tier and replace the specialization under test.
    runtime.rt.heap.jit_hold_tier = true;
    for (uint i = 0; i < 80; i++) eval(&context,
        "var helperAliasState={count:0};if(helperAlias(helperAliasState,20,helperAliasCallback)!==200.25||helperAliasState.count!==20)throw 'receiver/result alias';");
    FunctionPlan* plan = cf.sljit_function;
    @check(plan != null && plan.ssa_region != null && plan.ssa_region.ssa_helpers != null);
    $if $feat(SLJIT_STATS): @check(plan.ssa_region.ssa_helper_continued != 0); $endif
}

fn void check_artifact_inventory(Heap* h) @feat(SLJIT) {
    usz code, metadata, retired;
    JitArtifact* previous;
    for (JitArtifact* owner = h.jit_artifacts; owner != null; owner = owner.next) {
        @check(owner.previous == previous && owner.state == JitArtifactState.LIVE);
        code += owner.code_bytes;
        metadata += owner.metadata_bytes;
        previous = owner;
        if (owner.kind == JitArtifactKind.FUNCTION_CODE) {
            FunctionPlan* plan = owner.payload;
            @check(owner == &plan.artifact && owner.code_bytes == plan.code_bytes);
            @check(owner.function.sljit_function == plan);
            if (plan.ssa_region != null) {
                @check(plan.ssa_region.code_owner == owner);
                @check(owner.metadata_bytes >= FunctionPlan::size + vm::sljit_loop_metadata_bytes(plan.ssa_region));
            }
            for (FunctionCallLink* link = plan.calls; link != null; link = link.next) {
                @check(link.registered);
                bool found;
                for (FunctionCallLink* incoming = link.target.sljit_incoming_calls; incoming != null; incoming = incoming.target_next) {
                    if (incoming == link) { found = true; break; }
                }
                @check(found);
            }
        }
    }
    for (JitArtifact* owner = h.jit_retired_artifacts; owner != null; owner = owner.retired_next) {
        @check(owner.state == JitArtifactState.RETIRED);
        code += owner.code_bytes;
        metadata += owner.metadata_bytes;
        retired += owner.code_bytes;
    }
    @check(code == h.jit_code_bytes && metadata == h.jit_metadata_bytes && retired == h.jit_retired_code_bytes);
}

// Expose the lexical binding object's ordinary slots as a receiver. Native
// object stores and GETVAR then genuinely name the same backing slot.
fn void check_helper_binding_store_alias() @feat(SLJIT) {
    JsRuntime runtime;
    runtime.create()!!;
    defer runtime.destroy();
    JsContext context;
    context.create(&runtime)!!;
    defer context.destroy();
    eval(&context, "let aliasLexicalValue=1;function aliasLexicalLoop(o,n){var sum=0;for(var i=0;i<n;i++){o.aliasLexicalValue=o.aliasLexicalValue+1;sum=sum+aliasLexicalValue;}return sum;}");
    TVal bindings;
    bindings.set_object(runtime.rt.vm.global_lex_env.bindings);
    JsValue object = context.root(bindings)!!;
    defer context.release(object);
    JsValue global = context.global()!!;
    defer context.release(global);
    context.set(global, "aliasLexicalObject", object)!!;
    @check(runtime.set_jit());
    for (uint i = 0; i < 160; i++) eval(&context,
        "aliasLexicalValue=1;if(aliasLexicalLoop(aliasLexicalObject,8)!==44||aliasLexicalValue!==9)throw 'binding/store alias';");
    CompiledFunction* cf = named_function(&runtime, "aliasLexicalLoop");
    @check(cf != null && cf.sljit_function != null);
    FunctionPlan* plan = cf.sljit_function;
    @check(plan.ssa_region != null && plan.ssa_region.ssa_data.native_bindings != 0);
    $if $feat(SLJIT_STATS): @check(plan.ssa_region.ssa_data.binding_reads != 0); $endif
}

fn void check_numeric_pipeline() @feat(SLJIT) {
    // Earlier fixtures deliberately poison indexed prototypes. Use a fresh
    // runtime so this check requires successful compiled push continuations.
    JsRuntime runtime;
    runtime.create()!!;
    defer runtime.destroy();
    JsContext context;
    context.create(&runtime)!!;
    defer context.destroy();
    @check(runtime.set_jit());
    eval(&context, "var console={log:function(){}};");
    eval(&context, CFG_SOURCE);
    CompiledFunction* numeric = named_function(&runtime, "jitCfgNumbers");
    @check(numeric != null && numeric.sljit_function != null);
    FunctionPlan* numeric_plan = numeric.sljit_function;
    @check(numeric_plan.numeric_homes != 0
        || (numeric_plan.ssa_region != null && numeric_plan.ssa_region.hits != 0));
    CompiledFunction* calls = named_function(&runtime, "jitCfgCalls");
    @check(calls != null && calls.sljit_function != null);
    FunctionPlan* plan = calls.sljit_function;
    @check(plan.numeric_homes != 0);
    @check(plan.direct_calls != 0);
    @check(plan.direct_returns != 0);
    @check(plan.resumed_allocations != 0 && runtime.rt.heap.jit_resumed_pushes != 0);
}

fn void check_ic_gc_roots() {
    JsRuntime runtime;
    runtime.create()!!;
    defer runtime.destroy();
    JsContext context;
    context.create(&runtime)!!;
    defer context.destroy();
    eval(&context,
        "function gcRead(o){return o.value;}"
        "var gcP0={value:11},gcP1={value:22},gcP2={value:33};"
        "var gcR0=Object.create(gcP0),gcR1=Object.create(gcP1),gcR2=Object.create(gcP2);"
        "gcR0.a=1;gcR1.a=1;gcR1.b=2;gcR2.a=1;gcR2.b=2;gcR2.c=3;"
        "for(var g=0;g<10;g++){if(gcRead(gcR0)!==11||gcRead(gcR1)!==22||gcRead(gcR2)!==33)throw 'cache';}");
    CompiledFunction* cf = named_function(&runtime, "gcRead");
    @check(cf != null && cf.ic_entries != null);
    hobject::ICEntry* entries = cf.ic_entries;
    hobject::ICEntry* cache;
    uint slot;
    for (uint i = 0; i < cf.ic_count; i++) if (entries[i].chain_len == hobject::IC_CHAIN_PROTO) {
        cache = &entries[i]; slot = i; break;
    }
    @check(cache != null && cache.chain.proto.count == 2);
    Heap* h = runtime.rt.heap;
    h.mark_and_sweep(true, true);
    h.gc_begin_cycle(true);
    uint cursor = cf.const_count + slot;
    @check(!h.gc_scan_compiled_slot(cf, &cursor));
    @check(((HeapHeader*)cache.chain.proto.primary.owner).is_reachable());
    for (uint i = 0; i < cache.chain.proto.count; i++) {
        @check(((HeapHeader*)cache.chain.proto.arms[i].owner).is_reachable());
    }
    h.mark_and_sweep(true, true);

    // Point the entry at a real private receiver shape, then retire that shape.
    // Invalidation must clear the owner discriminator before a root scan can
    // interpret a zero chain length as a snapshot index of UINT_MAX.
    hobject::HObject* receiver = h.alloc_plain_object()!!;
    receiver.make_shape_private(h);
    cache.shape_id = receiver.shape_id;
    receiver.make_shape_private(h);
    h.purge_retired_shapes();
    @check(cache.shape_id == heap::SHAPE_NONE && cache.chain_len == 0 && !cache.has_proto);
    @check(hobject::ic_cached_proto(cache) == null);
    cursor = cf.const_count + slot;
    @check(!h.gc_scan_compiled_slot(cf, &cursor));
    h.mark_and_sweep(true, true);
}

// MAY-write effects must include destructive inputs and implicit call windows,
// while branch offsets and property receivers are not register destinations.
fn void check_register_effects() {
    uint[8] words;
    compiler::RegSet writes = { .words = &words[0], .word_count = 8 };
    compiler::register_may_writes(bytecode::make_abc(Opcode.PUTCAP, 7, 0, 0), &writes);
    @check(writes.test(7) && !writes.test(0));
    writes.clear();
    compiler::register_may_writes(bytecode::make_abc(Opcode.INC_LT, 4, 0, 0), &writes);
    @check(writes.test(4));
    writes.clear();
    compiler::register_may_writes(bytecode::make_abc(Opcode.CALL_UNDEF_THIS, 2, 10, 3), &writes);
    @check(writes.test(2) && writes.test(11) && writes.test(14) && !writes.test(9));
    writes.clear();
    compiler::register_may_writes(bytecode::make_abc(Opcode.JMP_NLT, 20, 2, 3), &writes);
    compiler::register_may_writes(bytecode::make_abc(Opcode.PUTPROPC, 5, 6, 7), &writes);
    for (uint i = 0; i < 256; i++) @check(!writes.test(i));
    compiler::register_may_writes(bytecode::make_abc(Opcode.WIDE, 0, 0, 0), &writes);
    @check(writes.test(0) && writes.test(255));
}

// Exercise the internal entry through a real C-to-shared-register gateway.
alias SsaDirectEntry = fn ulong(TVal* regs, ColdCtx* cold, FunctionRun* run);
fn void check_ssa_direct(JsRuntime* runtime) {
    Instruction[4] code = {
        bytecode::make_abc(Opcode.ADD, 2, 0, 1),
        bytecode::make_abc(Opcode.MUL, 3, 2, 2),
        bytecode::make_abc(Opcode.SUB, 4, 3, 0),
        bytecode::make_abc(Opcode.RET, 4, 0, 0)
    };
    CompiledFunction cf = { .code = &code[0], .code_count = 4, .num_regs = 5 };
    LoopPlan plan = { .begin = 0, .end = 2 };
    void* native = vm::ssa_function_emit(&plan, &cf, runtime.rt.heap);
    @check(native != null);
    defer jit::sljit_free_code(native, null);
    TemplateEmitter e = { .compiler = jit::sljit_create_compiler(null) };
    @check(e.compiler != null);
    defer jit::sljit_free_compiler(e.compiler);
    @check(jit::sljit_emit_enter(e.compiler, 0, jit::SLJIT_ARGS3WWW_R, 3, 3, 0) == 0);
    for (int i = 0; i < 3; i++) e.mov(jit::reg_s(i), 0, jit::reg_r(i), 0);
    @check(jit::sljit_emit_icall(e.compiler, jit::SLJIT_CALL_REG_ARG, 1,
        jit::SLJIT_IMM, (long)native) == 0);
    @check(jit::sljit_emit_return(e.compiler, jit::SLJIT_MOV, jit::reg_r(0), 0) == 0);
    @check(!e.failed);
    void* gateway = jit::sljit_generate_code(e.compiler, 0, null);
    @check(gateway != null);
    defer jit::sljit_free_code(gateway, null);
    SsaDirectEntry entry = (SsaDirectEntry)gateway;
    LoopState state;
    FunctionRun run = { .ssa_state = &state };
    TVal[5] regs;
    for (long i = 0; i < 1000; i++) {
        regs[0].set_fastint(i);
        regs[1].set_fastint(3);
        regs[4].set_fastint(-99);
        TVal result = { .bits = entry(&regs[0], null, &run) };
        @check(result.get_number_or_fastint() == (double)((i + 3) * (i + 3) - i));
        @check(regs[0].get_fastint() == i && regs[4].get_fastint() == -99);
    }
    regs[0].set_undefined();
    @check(entry(&regs[0], null, &run) == vm::SSA_REFUSED);
    @check(regs[0].is_undefined() && regs[4].get_fastint() == -99);
}

fn void check_ssa_epoch(JsRuntime* runtime, JsContext* context) {
    $if $feat(SLJIT_FUNCTION_SSA):
        eval(context, "function ssaDot(v){return this.x*v.x+this.y*v.y+this.z*v.z;}var ssaLeft={x:2,y:3,z:5,dot:ssaDot};var ssaRight={x:7,y:11,z:13};");
        for (uint i = 0; i < 64; i++) eval(context, "if(ssaLeft.dot(ssaRight)!==112)throw 'SSA dot';");
        CompiledFunction* cf = named_function(runtime, "ssaDot");
        @check(cf != null && cf.sljit_function != null);
        FunctionPlan* function = cf.sljit_function;
        LoopPlan* region = function.ssa_region;
        @check(region != null && region.ssa_entry != null && region.ssa_fields);
        Heap* h = runtime.rt.heap;
        h.shape_recycle_epoch++;
        vm::sljit_function_ssa_refresh(h);
        @check(region.ssa_shape_epoch == h.shape_recycle_epoch && !region.ssa_invalid);
        eval(context, "if(ssaLeft.dot(ssaRight)!==112)throw 'SSA epoch refresh';");
        $if $feat(SLJIT_STATS): @check(region.ssa_completed != 0); $endif
        // Model a recycled shape by invalidating the recorded generation,
        // then require the patched entry to choose baseline execution safely.
        region.memory[0].shape_gen++;
        h.shape_recycle_epoch++;
        vm::sljit_function_ssa_refresh(h);
        @check(region.ssa_invalid);
        eval(context, "if(ssaLeft.dot(ssaRight)!==112)throw 'SSA epoch refusal';");
    $endif
}

fn void check_ssa_calls(JsRuntime* runtime, JsContext* context) {
    $if $feat(SLJIT_FUNCTION_SSA):
        eval(context, "var print=function(){};");
        eval(context, SSA_CALLS_SOURCE);
        CompiledFunction* cf = named_function(runtime, "ssaMixRegion");
        @check(cf != null && cf.sljit_function != null);
        FunctionPlan* function = cf.sljit_function;
        @check(function.ssa_region != null && function.ssa_region.binding_count == 1);
        $if $feat(SLJIT_STATS): @check(function.ssa_region.ssa_completed != 0); $endif
        CompiledFunction* loop = named_function(runtime, "ssaLeafLoop");
        @check(loop != null && loop.sljit_loops != null);
        LoopPlan* kernel = loop.sljit_loops;
        @check(kernel.ssa && kernel.ssa_calls);
    $endif
}

fn void check_ssa_leaf(JsRuntime* runtime, JsContext* context) {
    $if !$feat(SLJIT_NO_SSA_LEAVES):
        eval(context, "function ssaSet(){this.state=this.state|3;}function SsaOwner(){this.state=0;}SsaOwner.prototype.set=ssaSet;var ssaOwner=new SsaOwner();for(var i=0;i<64;i++)ssaOwner.set();");
        eval(context, "function ssaCommit(o){o.set();return o.state;}");
        for (uint i = 0; i < 64; i++) eval(context, "if(ssaCommit(ssaOwner)!==3)throw 'SSA commit';");
        CompiledFunction* cf = named_function(runtime, "ssaCommit");
        @check(cf != null && cf.sljit_function != null);
        FunctionPlan* function = cf.sljit_function;
        LoopPlan* leaf = function.ssa_leaves;
        @check(leaf != null && leaf.ssa_commit && leaf.ssa_fields);
        $if $feat(SLJIT_STATS): @check(leaf.ssa_completed != 0); $endif
        Heap* h = runtime.rt.heap;
        h.shape_recycle_epoch++;
        vm::sljit_function_ssa_refresh(h);
        @check(leaf.ssa_shape_epoch == h.shape_recycle_epoch && !leaf.ssa_invalid);
        leaf.memory[0].shape_gen++;
        h.shape_recycle_epoch++;
        vm::sljit_function_ssa_refresh(h);
        @check(leaf.ssa_invalid);
        eval(context, "ssaOwner.state=4;if(ssaCommit(ssaOwner)!==7)throw 'SSA commit refusal';");
    $endif
}

// Re-establish the exact watched entry after each invalidation, then require
// native completion before the next mutation is tested.
fn void check_watch_method_live(JsRuntime* runtime, JsContext* context) {
    // Recompile the caller against the stub. Its guard then directs the real
    // target through the native call entry instead of inlining it into the caller.
    CompiledFunction* driver = named_function(runtime, "regionWatchDrive");
    @check(driver != null);
    if (driver.sljit_function != null) vm::sljit_function_free(runtime.rt.heap, driver);
    driver.sljit_function_calls = 0;
    eval(context, "RegionConstraint.prototype.execute=regionWatchStub;");
    for (uint i = 0; i < 80; i++) eval(context, "regionWatchDrive(regionWatch);");
    eval(context, "RegionConstraint.prototype.execute=regionWatchExecute;");
    for (uint i = 0; i < 160; i++) eval(context, "regionWatch.input();regionWatch.output();regionWatch.execute();");
    CompiledFunction* cf = named_function(runtime, "regionWatchExecute");
    @check(cf != null && cf.sljit_function != null);
    FunctionPlan* plan = cf.sljit_function;
    bool found;
    for (LoopPlan* leaf = plan.ssa_leaves; leaf != null; leaf = leaf.next) {
        if (leaf.ssa_watched_methods) found = true;
    }
    @check(found && plan.dependencies != null && plan.dependencies_live);
    $if $feat(SLJIT_STATS): ulong before = plan.ssa_fast_calls; $endif
    for (uint i = 0; i < 32; i++) eval(context, "regionWatchDrive(regionWatch);");
    $if $feat(SLJIT_STATS): @check(plan.ssa_fast_calls > before); $endif
}

fn void check_ssa_call_regions(JsRuntime* runtime, JsContext* context) {
    $if !$feat(SLJIT_NO_SSA_CALL_ENTRY) && !$feat(SLJIT_NO_SSA_FIELD_IR):
        Heap* h = runtime.rt.heap;
        $if $feat(SLJIT_STATS): ulong before = h.jit_ssa_call_commits; $endif
        eval(context, "var print=function(){};");
        eval(context, SSA_REGIONS_SOURCE);
        eval(context, "var regionWarm=new RegionConstraint({value:7},{value:0});");
        // The fixture deliberately invalidates its original plans. Warm a
        // fresh call body after those semantic fallback checks.
        for (uint i = 0; i < 64; i++) eval(context, "regionWarm.input();regionWarm.output();");
        eval(context, "RegionConstraint.prototype.execute=function(){this.output().value=this.input().value;};");
        for (uint i = 0; i < 64; i++) eval(context, "regionWarm.execute();");
        // Compile the caller against another callee. Replacing it must use
        // the guarded native call fallback, including its frameless entry.
        eval(context, "regionFunctions.execute=RegionConstraint.prototype.execute;RegionConstraint.prototype.execute=function(){};regionFunctions.drive=function(c){c.execute();return c;};");
        for (uint i = 0; i < 64; i++) eval(context, "regionFunctions.drive(regionWarm);");
        eval(context, "RegionConstraint.prototype.execute=regionFunctions.execute;");
        for (uint i = 0; i < 100; i++) eval(context, "regionFunctions.drive(regionWarm);");
        $if $feat(SLJIT_STATS): @check(h.jit_ssa_call_commits > before); $endif
        eval(context, "var regionNativeEffects=0;regionWarm.input=function(){regionNativeEffects++;return this.v1;};regionFunctions.drive(regionWarm);if(regionNativeEffects!==1||regionWarm.v2.value!==7)throw 'SSA native method fallback';delete regionWarm.input;");
        eval(context, "Object.defineProperty(regionWarm.v1,'value',{get:function(){regionNativeEffects++;return 23;}});regionFunctions.drive(regionWarm);if(regionNativeEffects!==2||regionWarm.v2.value!==23)throw 'SSA native getter replay';");
        h.mark_and_sweep(true, true);
        eval(context, "regionFunctions.drive(regionWarm);if(regionNativeEffects!==3||regionWarm.v2.value!==23)throw 'SSA native region after GC';");
        eval(context, "if(regionNumeric(regionFunctions,'choose',1)!==1.25)throw 'SSA call after GC';");

        // Use a fresh named target and train the caller against a different
        // method, so the subsequent guarded native call takes the target's
        // frameless entry. Require that watched entry to run before mutation.
        eval(context, "function regionWatchExecute(){this.output().value=this.input().value;}function regionWatchDrive(c){c.execute();return c;}function regionWatchStub(){}function RegionWatch(a,b){RegionConstraint.call(this,a,b);}RegionWatch.prototype=Object.create(RegionConstraint.prototype);var regionOriginProto=RegionWatch.prototype;var regionAltBase=Object.create(RegionConstraint.prototype);regionAltBase.input=function(){return {value:91};};var regionAlt=Object.create(regionAltBase);var regionSavedInput=RegionConstraint.prototype.input;var regionWatch=new RegionWatch({value:7},{value:0});RegionConstraint.prototype.execute=regionWatchStub;");
        HObject* globals = runtime.rt.vm.global_env.bindings;
        int original_slot = globals.find_prop_idx(h.str_intern("regionOriginProto"), h);
        int alternate_slot = globals.find_prop_idx(h.str_intern("regionAlt"), h);
        @check(original_slot >= 0 && alternate_slot >= 0);
        HObject* original_proto = globals.prop_values()[original_slot].get().get_heapptr();
        HObject* alternate_proto = globals.prop_values()[alternate_slot].get().get_heapptr();
        @check(original_proto != alternate_proto && original_proto.shape_id == alternate_proto.shape_id);
        for (uint i = 0; i < 80; i++) eval(context, "regionWatchDrive(regionWatch);");
        eval(context, "RegionConstraint.prototype.execute=regionWatchExecute;");
        for (uint i = 0; i < 80; i++) eval(context, "regionWatch.input();regionWatch.output();regionWatch.execute();");
        CompiledFunction* watched = named_function(runtime, "regionWatchExecute");
        @check(watched != null && watched.sljit_function != null);
        FunctionPlan* watched_plan = watched.sljit_function;
        bool has_watched_region;
        bool has_watched_methods;
        for (LoopPlan* leaf = watched_plan.ssa_leaves; leaf != null; leaf = leaf.next) {
            if (leaf.ssa_watched_bindings != 0) has_watched_region = true;
            if (leaf.ssa_watched_methods) has_watched_methods = true;
        }
        @check(has_watched_region && has_watched_methods && watched_plan.dependencies != null && watched_plan.dependencies_live);
        $if $feat(SLJIT_STATS): ulong calls_before = watched_plan.ssa_fast_calls; $endif
        for (uint i = 0; i < 100; i++) eval(context, "regionWatchDrive(regionWatch);");
        $if $feat(SLJIT_STATS): @check(watched_plan.ssa_fast_calls > calls_before); $endif
        $if $feat(SLJIT_ADAPTIVE) && $feat(SLJIT_STATS):
            // This completion returns before the ordinary call entry publishes
            // a frame. Its owning plan must still be marked as recently used.
            watched_plan.last_use = 0;
            ulong fast_before = watched_plan.ssa_fast_calls;
            eval(context, "regionWatchDrive(regionWatch);");
            @check(watched_plan.ssa_fast_calls == fast_before + 1);
            @check(watched_plan.last_use != 0);
        $endif
        // Both first prototypes have an empty own layout; only their identity
        // distinguishes the two chains.
        eval(context, "Object.setPrototypeOf(regionWatch,regionAlt);regionWatch.v2.value=0;regionWatchDrive(regionWatch);if(regionWatch.v2.value!==91)throw 'watched first prototype';Object.setPrototypeOf(regionWatch,regionOriginProto);");
        check_watch_method_live(runtime, context);
        eval(context, "regionOriginProto.input=function(){return {value:83};};regionWatch.v2.value=0;regionWatchDrive(regionWatch);if(regionWatch.v2.value!==83)throw 'watched intermediate shadow';delete regionOriginProto.input;");
        check_watch_method_live(runtime, context);
        eval(context, "RegionConstraint.prototype.input=function(){return {value:79};};regionWatch.v2.value=0;regionWatchDrive(regionWatch);if(regionWatch.v2.value!==79)throw 'watched method replacement';RegionConstraint.prototype.input=regionSavedInput;");
        check_watch_method_live(runtime, context);
        eval(context, "regionDirection.FORWARD=-1;regionWatch.v1.value=0;regionWatch.v2.value=31;regionWatchDrive(regionWatch);if(regionWatch.v1.value!==31)throw 'watched slot write';");
        check_watch_method_live(runtime, context);
        eval(context, "regionDirection={FORWARD:1};regionWatch.v1.value=47;regionWatch.v2.value=0;regionWatchDrive(regionWatch);if(regionWatch.v2.value!==47)throw 'watched binding write';");
        check_watch_method_live(runtime, context);
        eval(context, "Object.defineProperty(regionDirection,'FORWARD',{get:function(){return -1;},configurable:true});regionWatch.v1.value=0;regionWatch.v2.value=53;regionWatchDrive(regionWatch);if(regionWatch.v1.value!==53)throw 'watched accessor transition';");
    $endif
}

// Single-pass regions reuse the loop SSA graph, allocation and recovery code.
fn void check_ssa_region(JsRuntime* runtime) {
    Instruction[3] code = {
        bytecode::make_abc(Opcode.ADD, 2, 0, 1),
        bytecode::make_abc(Opcode.MUL, 3, 2, 2),
        bytecode::make_abc(Opcode.SUB, 4, 3, 0)
    };
    CompiledFunction cf = { .code = &code[0], .code_count = 3, .num_regs = 5 };
    LoopPlan plan = { .begin = 0, .end = 2 };
    LoopNative native = vm::ssa_region_emit(&plan, &cf, runtime.rt.heap);
    @check(native != null);
    defer jit::sljit_free_code((void*)native, null);
    LoopState state;
    for (long i = 0; i < 1000; i++) {
        state.values[0].set_fastint(i);
        state.values[1].set_fastint(3);
        @check(native(&state, 100) == 3);
        @check(state.values[4].get_number_or_fastint() == (double)((i + 3) * (i + 3) - i));
        @check(state.budget == 100);
    }
    state.values[0].set_undefined();
    state.dirty = 0;
    @check(native(&state, 100) == 0 && state.dirty == 0);
    // A branch at bytecode zero is a real branch, not the no-branch marker.
    Instruction[4] branches = {
        bytecode::make_abc(Opcode.JMP_NLTI, 1, 0, 0),
        bytecode::make_abc(Opcode.MULI, 0, 0, 255),
        bytecode::make_abc(Opcode.ADDI, 1, 0, 3),
        bytecode::make_abc(Opcode.MUL, 2, 1, 1)
    };
    cf.code = &branches[0]; cf.code_count = 4; cf.num_regs = 3;
    LoopPlan branch_plan = { .begin = 0, .end = 3 };
    LoopNative branch_native = vm::ssa_region_emit(&branch_plan, &cf, runtime.rt.heap);
    @check(branch_native != null);
    defer jit::sljit_free_code((void*)branch_native, null);
    for (long input = -3; input <= 3; input++) {
        state.values[0].set_fastint(input);
        long magnitude = input < 0 ? -input : input;
        @check(branch_native(&state, 100) == 4);
        @check(state.values[2].get_number_or_fastint() == (double)((magnitude + 3) * (magnitude + 3)));
    }
}

// Failed inline-cache allocation must not create fake nonnull region pointers.
fn void check_function_missing_caches(JsRuntime* runtime) {
    Instruction[3] code = {
        bytecode::make_abc(Opcode.NOP, 0, 0, 0),
        bytecode::make_abc(Opcode.NOP, 0, 0, 0),
        bytecode::make_abc(Opcode.RET, 0, 0, 0)
    };
    CompiledFunction cf = { .code = &code[0], .code_count = 3, .num_regs = 1 };
    ColdCtx cold = { .heap = runtime.rt.heap };
    @check(vm::sljit_function_compile(&cf, &cold, 1) == null);
    ICEntry only_property_cache; VarICEntry only_variable_cache;
    cf.ic_entries = &only_property_cache;
    @check(vm::sljit_function_compile(&cf, &cold, 1) == null);
    cf.ic_entries = null; cf.var_ic_entries = &only_variable_cache;
    @check(vm::sljit_function_compile(&cf, &cold, 1) == null);
}

fn void main() {
    check_ssa_lazy_roots();
    check_ssa_sparse_imports();
    check_ssa_helper_homes();
    check_ssa_boxed_truth();
    check_ssa_boolean_equality();
    check_scalable_ssa_closure_startup();
    check_scalable_ssa_gateway();
    check_ssa_native_scratch_ownership();
    check_scalable_ssa_access();
    check_scalable_ssa_bounds();
    check_scalable_ssa_remat();
    check_native_ssa_bindings();
    check_native_ssa_boxed_this();
    check_native_ssa_boxed_this(true);
    check_native_ssa_boxed_arrays();
    check_scalable_ssa_fields();
    check_scalable_ssa_memory_callbacks();
    check_effectful_ssa_inline();
    $if $feat(SSA_SCALABLE_ONLY):
        return;
    $endif
    check_dependency_gc();
    check_artifact_retirement();
    check_helper_result_receiver_alias();
    check_helper_binding_store_alias();
    check_parameter_alias_roles();
    check_decoded_bytecode();
    check_decoded_register_uses();
    check_wide_alias_refusal();
    check_alias_register_set();
    check_register_effects();
    check_native_convention();
    check_ic_gc_roots();
    JsRuntime first, second;
    @check(!first.set_jit());
    first.create()!!;
    defer first.destroy();
    check_ssa_region(&first);
    check_ssa_direct(&first);
    second.create()!!;
    defer second.destroy();
    JsContext a, b, isolated;
    a.create(&first)!!;
    defer a.destroy();
    check_function_missing_caches(&first);
    check_ssa_cyclic_dominance(&first);
    check_ssa_dynamic_storage(&first);
    check_decoded_liveness(&first);
    b.create(&first)!!;
    defer b.destroy();
    isolated.create(&second)!!;
    defer isolated.destroy();
    eval(
        &a,
        "function warmField(o){return o.warm;}function freshField(o){return o.warm;}var warmRecord={warm:17};if(warmField(warmRecord)!==17||freshField(warmRecord)!==17)throw 'warm';"
    );
    @check(local_read_warmed(&first, "freshField"));
    JsContext*[3] contexts = { &a, &b, &isolated };
    foreach (ctx : contexts) {
        eval(ctx, TEMPLATE_SOURCE);
        eval(ctx, RUN);
    }
    @check(plans(&first) == 0 && plans(&second) == 0);
    @check(first.set_jit(false));
    $if $feat(SLJIT):
        @check(first.set_jit());
        eval(&a, RUN);
        eval(&b, RUN);
        @check(plans(&first) == 2);
        @check(plans(&second) == 0);
        ulong before = native_hits(&first);
        @check(first.set_jit(false));
        @check(!first.rt.heap.jit_enabled && !second.rt.heap.jit_enabled);
        eval(&a, "rows[0].id=7;if(render(rows)!=='<li>7:one</li><li>2:two</li>')throw 'disabled';rows[0].id=1;");
        @check(plans(&first) == 2 && native_hits(&first) == before);
        @check(first.set_jit());
        eval(&a, RUN);
        @check(native_hits(&first) > before);
        check_write_dependencies(&first, &a);
        $if $feat(SLJIT_READ_REFRESH): check_read_refresh(&first, &a); $endif
        eval(&isolated, RUN);
        @check(plans(&second) == 0);
        eval(&isolated, "var console={log:function(){}};");
        eval(&isolated, LOOP_SOURCE);
        @check(second.rt.heap.jit_code_bytes == 0);
        eval(&a, "var console={log:function(){}};");
        eval(&a, LOOP_SOURCE);
        @check(first.rt.heap.jit_code_bytes > 0);
        before = native_hits(&first);
        @check(first.set_jit(false));
        eval(&a, "for(var j=0;j<64;j++)if(hash(bytes)!==expectedHash)throw 'disabled loop';");
        @check(native_hits(&first) == before);
        @check(first.set_jit());
        eval(&a, "for(var j=0;j<64;j++)if(hash(bytes)!==expectedHash)throw 'cached loop';");
        @check(native_hits(&first) > before);
        eval(&a, NATIVE_SOURCE);
        @check(native_edges(&first, "jitNativeDrive") > 0);
        @check(native_edges(&first, "jitNativeStep", true) > 0);
        ulong recovered = inline_recoveries(&first);
        eval(&a, RECOVERY_SOURCE);
        @check(inline_recoveries(&first) > recovered);
        uint inline_polls;
        recovered = inline_recoveries(&first);
        first.set_interrupt(&stop_after_polls, &inline_polls);
        bool inline_interrupted;
        if (catch err = a.eval("recoveryLoopDrive(recoveryLoopHolder,1000000000);")) inline_interrupted = true;
        @check(inline_interrupted && inline_polls == 3 && inline_recoveries(&first) > recovered);
        first.set_interrupt(null);
        JsValue inline_exception = a.get_exception()!!;
        a.release(inline_exception);
        // A fresh realm has an untouched indexed prototype chain. The fixture
        // later invalidates it deliberately, retiring its compiled append plan.
        JsContext allocation_context;
        allocation_context.create(&first)!!;
        defer allocation_context.destroy();
        eval(&allocation_context, "var console={log:function(){}};");
        ulong pushes = first.rt.heap.jit_resumed_pushes;
        eval(&allocation_context, ALLOCATION_SOURCE);
        CompiledFunction* allocator = named_function(&first, "resumeAllocate");
        @check(allocator != null && allocator.sljit_function != null);
        @check(((FunctionPlan*)allocator.sljit_function).resumed_allocations > 0);
        @check(first.rt.heap.jit_resumed_pushes > pushes);
        // Request collection during native allocation. Completion must resume
        // after that operation, with the new object rooted in its VM slot.
        first.rt.heap.gc_trigger_counter = 1;
        eval(&allocation_context, "resumeAssert(resumeAllocate(2000),4006000);");
        first.rt.heap.mark_and_sweep(true, true);
        eval(&allocation_context, "resumeAssert(resumeAllocate(200),40600);");
        eval(&a, LINK_SOURCE);
        CompiledFunction* driver = named_function(&first, "jitLinkDrive");
        CompiledFunction* linked = named_function(&first, "jitLinkTarget");
        @check(driver != null && linked != null && driver.sljit_function != null);
        @check(((FunctionPlan*)driver.sljit_function).calls != null);
        // Exercise incoming unlinking while the caller remains compiled.
        vm::sljit_function_free(first.rt.heap, linked);
        linked.sljit_function_calls = 0;
        eval(&a, "for(var linkWarm=0;linkWarm<80;linkWarm++)if(jitLinkDrive(jitLinkObject,100)!==5250)throw 'relink';");
        @check(linked.sljit_function != null);
        // The inline frame limit is an admission limit, not an emitter
        // failure. Exercise it with an actual warmed general-inline site.
        bool checked_inline_limit;
        for (uint index = 0; index < first.rt.heap.compiled_func_count && !checked_inline_limit; index++) {
            CompiledFunction* candidate = first.rt.heap.compiled_funcs[index];
            if (candidate == null) continue;
            for (uint pc = 0; pc < candidate.code_count; pc++) {
                if (vm::function_inline_general_candidate(candidate, pc, first.rt.heap) == null) continue;
                FunctionPlan limit_plan = { .inline_count = 128 };
                FunctionEmitter limit_emitter = { .plan = &limit_plan };
                @check(!limit_emitter.inline_general(candidate, pc, first.rt.heap));
                @check(!limit_emitter.out.e.failed && limit_emitter.out.link_count == 0);
                checked_inline_limit = true;
                break;
            }
        }
        @check(checked_inline_limit);
        $if $feat(SLJIT_ADAPTIVE):
        // Exercise the real cache reclaimer with a live linked caller. Make
        // every plan recent except this target, then force one eviction.
        FunctionPlan* target_plan = linked.sljit_function;
        target_plan.last_use = 0;
        eval(&a, "if(jitLinkDrive(jitLinkObject,100)!==5250)throw 'native use';");
        @check(target_plan.last_use != 0);
        first.rt.heap.jit_clock += 65537;
        for (uint index = 0; index < first.rt.heap.compiled_func_count; index++) {
            CompiledFunction* candidate = first.rt.heap.compiled_funcs[index];
            if (candidate != null && candidate.sljit_function != null) {
                ((FunctionPlan*)candidate.sljit_function).last_use = first.rt.heap.jit_clock;
            }
        }
        for (JitArtifact* artifact = first.rt.heap.jit_artifacts; artifact != null; artifact = artifact.next) {
            artifact.last_use = first.rt.heap.jit_clock;
        }
        target_plan.artifact.last_use = 1;
        target_plan.last_use = 1;
        // A region can leave the warmup counter at its terminal sentinel even
        // though its entry was never retired as unproductive. Eviction must
        // allow that function to warm and compile again.
        target_plan.begin = 1;
        linked.sljit_function_calls = uint::max;
        usz saved_limit = vm::sljit_code_limit(first.rt.heap);
        first.rt.heap.jit_code_limit = first.rt.heap.jit_code_bytes + 1;
        @check(vm::sljit_code_room(first.rt.heap, 2));
        first.rt.heap.jit_code_limit = saved_limit;
        @check(linked.sljit_function == null && driver.sljit_function != null);
        @check(linked.sljit_function_calls == 0);
        eval(&a, "for(var linkAgain=0;linkAgain<80;linkAgain++)if(jitLinkDrive(jitLinkObject,100)!==5250)throw 'cache relink';");
        @check(linked.sljit_function != null);
        $endif
        check_numeric_pipeline();
        eval(&a, FUNCTION_SOURCE);
        first.rt.heap.mark_and_sweep(true, true);
        for (uint i = 0; i < 128; i++) eval(&a, "if(jitFunctionWork(jitFunctionRecord)!==18)throw 'function';");
        @check(function_hits(&first, "functionFields") > 0);
        for (uint i = 0; i < 128; i++) eval(
            &a,
            "if(jitFunctionPump(jitFunctionSource,jitFunctionSink)!==4)throw 'continuation';"
        );
        @check(function_hits(&first, "serverPump") > 0);
        first.rt.heap.mark_and_sweep(true, true);
        for (uint i = 0; i < 128; i++) eval(
            &a,
            "if(jitFunctionWork(jitFunctionRecord)!==18)throw 'function after GC';"
        );
        @check(function_hits(&first, "functionFields") > 0);
        // Call-only native runs must not strand an exhausted backward-edge
        // budget: with no pending GC, subsequent callbacks can run natively.
        first.rt.heap.bwd_gc_budget = 1;
        before = native_hits(&first);
        @check(first.set_jit(false));
        eval(&a, "jitFunctionRecord.left=6;if(jitFunctionWork(jitFunctionRecord)!==22)throw 'disabled function';");
        @check(native_hits(&first) == before);
        @check(first.set_jit());
        eval(&a, "if(jitFunctionWork(jitFunctionRecord)!==22)throw 'cached function';");
        @check(native_hits(&first) > before);
        eval(&a, REGION_SOURCE);
        @check(region_work(&first, "jitRegionFields") > 0);
        @check(region_work(&first, "jitRegionCalls", true) > 0);
        first.rt.heap.mark_and_sweep(true, true);
        eval(&a, "if(jitRegionFields(jitRegionRecord,20000)!==35000.25)throw 'region after GC';");
        // The getter fallback deliberately disables the old field entry after
        // repeated misses. Warm a fresh native loop for the interrupt check.
        eval(
            &a,
            "function jitRegionPoll(o,n){var sum=0.25;for(var i=0;i<n;i++){sum=sum+o.x;sum=sum+o.y;}return sum;}for(var w=0;w<100;w++)jitRegionPoll(jitRegionRecord,32);"
        );
        uint region_polls;
        ulong region_before = region_work(&first, "jitRegionPoll");
        @check(region_before > 0);
        first.set_interrupt(&stop_after_polls, &region_polls);
        bool region_interrupted;
        if (catch err = a.eval("jitRegionPoll(jitRegionRecord,1000000000);")) region_interrupted = true;
        @check(region_interrupted && region_polls == 3 && region_work(&first, "jitRegionPoll") > region_before);
        first.set_interrupt(null);
        JsValue region_exception = a.get_exception()!!;
        a.release(region_exception);
        eval(&a, "1");
        uint polls;
        before = native_hits(&first);
        first.set_interrupt(&stop_after_polls, &polls);
        bool interrupted;
        if (catch err = a.eval(
            "function spin(a){var x=0;for(var i=0;i<1000000;i++)x+=a[i&511];return x;}spin(bytes);"
        )) {
            interrupted = true;
        }
        @check(interrupted && polls == 3 && native_hits(&first) > before);
        first.set_interrupt(null);
        JsValue exception = a.get_exception()!!;
        a.release(exception);
        eval(&a, "1");
    $else
        @check(!first.set_jit());
    $endif
    check_ssa_epoch(&first, &a);
    check_ssa_calls(&first, &a);
    check_ssa_leaf(&first, &a);
    check_ssa_call_regions(&first, &a);
    check_artifact_inventory(first.rt.heap);
    check_artifact_inventory(second.rt.heap);
    io::printn("embedding JIT: PASS");
}
