module boomkat::compiler;

import boomkat::bytecode;
import boomkat::heap;
import std::core::mem;
import libc;

// Canonical instruction indices are independent of bytecode word PCs. A WIDE
// prefix and payload form ONE node; recovery uses view.pc, caches use
// view.payload_pc, and relative edges start at view.next_pc.
const uint CFG_NO_INSTRUCTION = uint::max;
struct DecodedCfgBudget {
    uint max_words;
    uint max_instructions;
    usz max_bytes;
}
const DecodedCfgBudget DEFAULT_CFG_BUDGET = { 4096, 4096, 1024 * 1024 };
alias DecodedOpAllowed = fn bool(Opcode op);

struct DecodedCfgNode {
    DecodedBytecode view;
    MoveelimRoles roles;
    uint[2] successors;
    uint successor_count;
    uint branch_target;
    uint block;
    bool block_entry;
    bool external;
    bool call;
}
struct DecodedCfg {
    DecodedCfgNode* nodes;
    uint* pc_to_index; // CFG_NO_INSTRUCTION at WIDE payload words
    uint instruction_count;
    uint word_count;
    uint block_count;
    bool has_wide;
    bool has_backedge;
    void* storage;
    heap::Heap* owner;
}

fn void bytecode_cfg_free(DecodedCfg* cfg) {
    if (cfg.storage != null) {
        if (cfg.owner != null) { cfg.owner.free_func(cfg.owner.heap_udata, cfg.storage); }
        else { libc::free(cfg.storage); }
    }
    *cfg = {};
}

fn bool bytecode_cfg_branch(DecodedBytecode view, long* target) {
    Opcode op = view.insn.op;
    if (op == Opcode.JUMP || op == Opcode.BREAK || op == Opcode.CONTINUE) {
        *target = (long)view.next_pc + (long)view.insn.get_sabc();
        return true;
    }
    if (op == Opcode.IF_TRUE || op == Opcode.IF_FALSE) {
        *target = (long)view.next_pc + (long)view.insn.get_sbc();
        return true;
    }
    if (op >= Opcode.JMP_NLT && op <= Opcode.JMP_SNEQI) {
        *target = (long)view.next_pc + (long)(ichar)view.insn.a;
        return true;
    }
    return false;
}

fn bool bytecode_cfg_call(Opcode op) {
    switch (op) {
        case CALL: case CALL_PROP: case CALL_S: case CALL_UNDEF_THIS:
        case CALL_VAR: case CALL_GLOBAL: case NEW_OBJ: case SUPER_CALL: case SUPER_CALL_S: return true;
        default: return false;
    }
}

fn bool bytecode_cfg_fallthrough(Opcode op) {
    switch (op) {
        case JUMP: case BREAK: case CONTINUE:
        case RET: case RET_GEN: case RETUNDEF: case RETUNDEF_GEN:
        case THROW: case THROW_REF: case THROW_SYNTAX: return false;
        default: return true;
    }
}

// The instructions `objects` admits: the compiler's own regexp, closure and cell objects, and the
// element store of an array literal.
fn bool bytecode_cfg_object_op(Opcode op) @inline {
    return op == Opcode.NEWREGEXP || op == Opcode.CLOSURE || op == Opcode.NEWCELLS || op == Opcode.GETCELL
        || op == Opcode.SETCELL || op == Opcode.MOVECELL || op == Opcode.INITELEM;
}

// Positive control-flow contract: exception handlers, suspension, indirect
// returns, specialized skips, and unreviewed opcodes all refuse. The _SNAP
// stores are accepted: they store by name through an environment probe they
// read and fall through like the plain stores, with A the value, B the probe
// and C the name index. LDINTX stays outside this shared contract until its
// legacy multiword/role assumptions are reconciled; callers must never infer
// fallthrough for an unknown operation.
fn bool bytecode_cfg_control_supported(Opcode op) {
    switch (op) {
        case LDREG..LDINT:
        case LDUNDEF..FREEZEOBJ:
        case CALL: case NEW_OBJ: case CALL_S: case CALL_UNDEF_THIS:
        case CALL_VAR: case CALL_GLOBAL: case SUPER_CALL: case SUPER_CALL_S:
        case RET: case RETUNDEF: case RET_GEN: case RETUNDEF_GEN:
        case THROW: case THROW_REF: case THROW_SYNTAX:
        case GETVAR: case GETGLOBAL: case GETBOUND: case TYPEOFIDENT:
        case PUTVAR: case PUTVAR_ASSIGN: case PUTVAR_SNAP: case PUTGLOBAL: case PUTCAP_SNAP:
        case DECLVAR: case DECLVAR_HOIST: case DECLGLOBALFUNC: case DECLB33GLOBAL:
        case NOP: case TOPROPKEY: case TOSTR: case BREAK: case CONTINUE:
        case INC: case DEC: case INC_VAR: case DEC_VAR: case INC_GLOBAL: case DEC_GLOBAL:
        case JMP_NLT..JMP_SNEQI: case GETPROPC_CACHED:
        case GETPROTO: case GETCAP: case PUTCAP: case TONUMERIC:
        case NEWOBJ_SHAPE: case INIT_SLOT: case PUTPROPC: case GETTHISC: case PUTTHISC:
        case ADD_FUSED: case INC_LT: return true;
        default: return false;
    }
}

// A single bounded allocation owns nodes and the PC map. Decoding and target
// validation finish before a consumer sees a graph; failure releases everything.
// split_calls marks real interpreter reentry boundaries while retaining normal
// bytecode call fallthrough for liveness. A native consumer may end its CFG edge
// at node.call and use the external successor as another root. With `forwarding` the graph may
// hold APPLY_ARGS, whose reads of the frame's arguments the liveness does not see: for a consumer
// that accounts for them itself. With `resolve` it may hold RESOLVEVAR, whose write of A the
// roles do not record, and THROW_UNRESOLVED: for a consumer that knows the write itself and only
// needs the liveness to over-approximate. With `objects` it may hold the instructions that build
// and fill the objects the compiler makes for itself (bytecode_cfg_object_op). None of them jumps,
// so the control flow is the ordinary one, and the roles leave A a use and no def, which
// over-approximates the register file for a consumer that lowers the instruction itself.
fn bool bytecode_cfg_build(DecodedCfg* cfg, Instruction* code, uint count,
    heap::Heap* h = null, DecodedOpAllowed allowed = null, bool split_calls = false,
    DecodedCfgBudget budget = DEFAULT_CFG_BUDGET, bool forwarding = false, bool resolve = false,
    bool objects = false) {
    *cfg = {};
    if (code == null || count == 0 || count > budget.max_words) return false;
    ulong bytes = (ulong)count * (DecodedCfgNode::size + uint::size);
    if (bytes > (ulong)budget.max_bytes || bytes > (ulong)usz::max) return false;
    void* storage = h != null ? h.alloc_func(h.heap_udata, (usz)bytes) : libc::malloc((usz)bytes);
    if (storage == null) return false;
    cfg.storage = storage;
    cfg.owner = h;
    cfg.nodes = (DecodedCfgNode*)storage;
    cfg.pc_to_index = (uint*)((char*)storage + (usz)count * DecodedCfgNode::size);
    cfg.word_count = count;
    mem::clear(storage, (sz)bytes);
    for (uint pc = 0; pc < count; pc++) cfg.pc_to_index[pc] = CFG_NO_INSTRUCTION;
    bool complete;
    defer if (!complete) bytecode_cfg_free(cfg);
    if (!moveelim_roles_ready) moveelim_init_roles();
    for (uint pc = 0; pc < count;) {
        DecodedBytecode view = bytecode::decode_bytecode(code, count, pc);
        if (!view.valid || view.insn.op.ordinal >= Opcode::values.len
            || (!bytecode_cfg_control_supported(view.insn.op) && !(forwarding && view.insn.op == Opcode.APPLY_ARGS)
                && !(resolve && (view.insn.op == Opcode.RESOLVEVAR || view.insn.op == Opcode.THROW_UNRESOLVED))
                && !(objects && bytecode_cfg_object_op(view.insn.op)))
            || (allowed != null && !allowed(view.insn.op))) return false;
        if (cfg.instruction_count == budget.max_instructions) return false;
        uint index = cfg.instruction_count++;
        cfg.pc_to_index[pc] = index;
        DecodedCfgNode* node = &cfg.nodes[index];
        node.view = view;
        node.roles = moveelim_roles[view.insn.op.ordinal];
        node.branch_target = CFG_NO_INSTRUCTION;
        node.call = bytecode_cfg_call(view.insn.op);
        cfg.has_wide |= view.wide;
        pc = view.next_pc;
    }
    cfg.nodes[0].block_entry = true;
    cfg.nodes[0].external = true;
    for (uint i = 0; i < cfg.instruction_count; i++) {
        DecodedCfgNode* node = &cfg.nodes[i];
        long target;
        bool branch = bytecode_cfg_branch(node.view, &target);
        bool fallthrough = bytecode_cfg_fallthrough(node.view.insn.op);
        if (branch) {
            if (target < 0 || target >= (long)count) return false;
            uint successor = cfg.pc_to_index[target];
            if (successor == CFG_NO_INSTRUCTION) return false;
            node.branch_target = successor;
            node.successors[node.successor_count++] = successor;
            cfg.nodes[successor].block_entry = true;
            cfg.has_backedge |= successor <= i;
        }
        if (i + 1 == cfg.instruction_count) continue;
        if (fallthrough) {
            if (!branch || node.branch_target != i + 1) node.successors[node.successor_count++] = i + 1;
        }
        if (branch || !fallthrough || (split_calls && node.call)) cfg.nodes[i + 1].block_entry = true;
        if (split_calls && node.call) cfg.nodes[i + 1].external = true;
    }
    bytecode_cfg_number_blocks(cfg);
    complete = true;
    return true;
}

fn void bytecode_cfg_number_blocks(DecodedCfg* cfg) {
    cfg.block_count = 0;
    for (uint i = 0; i < cfg.instruction_count; i++) {
        if (cfg.nodes[i].block_entry) cfg.block_count++;
        cfg.nodes[i].block = cfg.block_count - 1;
    }
}

// Derive the blocks of a graph whose nodes carry their edges (successors, branch_target) but not
// yet their block structure, as when a callee's nodes have been spliced into a caller's: a node
// starts a block when it is the first, has several incoming edges, or is reached by anything but
// the plain fallthrough of its predecessor. `scratch` holds instruction_count words.
fn void bytecode_cfg_finish(DecodedCfg* cfg, uint* scratch) {
    uint count = cfg.instruction_count;
    for (uint i = 0; i < count; i++) { scratch[i] = 0; cfg.nodes[i].block_entry = false; }
    cfg.has_backedge = false;
    for (uint i = 0; i < count; i++) {
        DecodedCfgNode* node = &cfg.nodes[i];
        bool plain = node.successor_count == 1 && node.successors[0] == i + 1 && node.branch_target == CFG_NO_INSTRUCTION;
        for (uint k = 0; k < node.successor_count; k++) {
            uint s = node.successors[k];
            scratch[s]++;
            if (!plain) cfg.nodes[s].block_entry = true;
            cfg.has_backedge |= s <= i;
        }
        if (!plain && i + 1 < count) cfg.nodes[i + 1].block_entry = true;
    }
    for (uint i = 0; i < count; i++) if (scratch[i] != 1) cfg.nodes[i].block_entry = true;
    cfg.nodes[0].block_entry = true;
    bytecode_cfg_number_blocks(cfg);
}

// With `exact`, the operands of CALL_VAR, CALL_GLOBAL and PUTPROPC that are constant indices or counts
// are not taken for registers, as the conservative analysis of move elimination does.
fn void DecodedCfgNode.reads(&self, RegSet* uses, bool call_windows = true, bool exact = false) {
    if (exact) {
        DecodedInsn ins = self.view.insn;
        switch (ins.op) {
            case CALL_VAR: case CALL_GLOBAL:
                // The call loads its callee into A and stores undefined into the receiver slot: only
                // the arguments are read.
                if (call_windows && ins.b != 0) moveelim_mark_range(uses, (uint)ins.a + 2, (uint)ins.a + 1 + (uint)ins.b);
                return;
            case PUTPROPC:
                uses.set((uint)ins.a);
                uses.set((uint)ins.b);
                return;
            case IF_TRUE: case IF_FALSE:
                uses.set((uint)ins.a);
                return;
            case JMP_NLT..JMP_NNULL:
                // A is the offset; JMP_NULL and JMP_NNULL repeat B in C.
                uses.set((uint)ins.b);
                uses.set((uint)ins.c);
                return;
            case JMP_NLTI..JMP_SNEQI:
                uses.set((uint)ins.b);
                return;
            default:
                break;
        }
    }
    // General windows and read/modify/write operands use the same canonical
    // routines as packed move elimination; high registers stay ordinary bits.
    moveelim_add_decoded_uses(self.view.insn, uses, call_windows);
}
fn bool DecodedCfgNode.must_def(&self, uint* reg) {
    return moveelim_get_role_def(self.roles, self.view.insn.a, reg);
}

// By default liveness arrays are indexed by canonical instruction index.
// word_slots adapts existing callers whose arrays and recovery queries use PCs;
// WIDE payload slots are cleared but never traversed as instructions.
fn void bytecode_cfg_liveness(DecodedCfg* cfg, RegSet* live_out, RegSet* live_in,
    RegSet* scratch, bool call_windows = true, bool word_slots = false, bool exact = false) {
    uint slots = word_slots ? cfg.word_count : cfg.instruction_count;
    for (uint i = 0; i < slots; i++) { live_out[i].clear(); live_in[i].clear(); }
    bool first = true;
    bool changed = true;
    while (changed) {
        if (!first && !cfg.has_backedge) break;
        changed = first;
        uint index = cfg.instruction_count;
        while (index > 0) {
            DecodedCfgNode* node = &cfg.nodes[--index];
            uint slot = word_slots ? node.view.pc : index;
            scratch.clear();
            for (uint edge = 0; edge < node.successor_count; edge++) {
                uint successor = node.successors[edge];
                uint successor_slot = word_slots ? cfg.nodes[successor].view.pc : successor;
                scratch.union_with(&live_in[successor_slot]);
            }
            if (!scratch.equals(&live_out[slot])) {
                live_out[slot].copy_from(scratch);
                changed = true;
            } else if (!first) { continue; }
            live_in[slot].copy_from(scratch);
            uint def;
            if (node.must_def(&def)) live_in[slot].unset(def);
            // Exactly, CALL_VAR and CALL_GLOBAL load their callee into A and store undefined into the
            // receiver slot, which writes both before any argument is read.
            if (exact && (node.view.insn.op == Opcode.CALL_VAR || node.view.insn.op == Opcode.CALL_GLOBAL)) {
                live_in[slot].unset((uint)node.view.insn.a);
                live_in[slot].unset((uint)node.view.insn.a + 1);
            }
            node.reads(&live_in[slot], call_windows, exact);
        }
        first = false;
    }
}
