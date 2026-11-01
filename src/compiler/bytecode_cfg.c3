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
alias DecodedWorkCharge = fn bool(void* data, usz amount);

alias DecodedReadExtras = fn void(void* context, DecodedBytecode view, RegSet* reads);

struct DecodedCfgNode {
    DecodedReadExtras extra_reads;
    void* read_context;
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

// Positive control-flow contract: exception handlers, suspension, indirect
// returns, specialized skips, and unreviewed opcodes all refuse. LDINTX stays
// outside this shared contract until its legacy multiword/role assumptions are
// reconciled; callers must never infer fallthrough for an unknown operation.
fn bool bytecode_cfg_control_supported(Opcode op) {
    switch (op) {
        case LDREG..LDINT:
        case LDUNDEF..FREEZEOBJ:
        case CALL: case NEW_OBJ: case CALL_S: case CALL_UNDEF_THIS:
        case CALL_VAR: case CALL_GLOBAL: case SUPER_CALL: case SUPER_CALL_S:
        case RET: case RETUNDEF: case RET_GEN: case RETUNDEF_GEN:
        case THROW: case THROW_REF: case THROW_SYNTAX:
        case GETVAR: case GETGLOBAL: case GETBOUND: case TYPEOFIDENT:
        case PUTVAR: case PUTVAR_ASSIGN: case PUTGLOBAL:
        case DECLVAR: case DECLVAR_HOIST: case DECLGLOBALFUNC: case DECLB33GLOBAL:
        case NOP: case TOPROPKEY: case TOSTR: case BREAK: case CONTINUE:
        case INC: case DEC: case INC_VAR: case DEC_VAR: case INC_GLOBAL: case DEC_GLOBAL:
        case JMP_NLT..JMP_SNEQI: case GETPROPC_CACHED:
        case GETPROTO: case GETCAP: case PUTCAP: case TONUMERIC:
        case NEWOBJ_SHAPE: case INIT_SLOT: case PUTPROPC: case GETTHISC: case PUTTHISC:
        case CLOSURE:
        case ADD_FUSED: case INC_LT: return true;
        default: return false;
    }
}

// The ordinary semantic roles must not inherit a producer-retarget refusal.
// General call windows are described by reads() below; their counts and keys
// are immediates except C in the spread forms.
// dispatch_unary/th_inc_var write updated binding values into A, despite the
// legacy INC_VAR opcode comment calling A unused.
fn MoveelimRoles bytecode_cfg_roles(Opcode op) {
    switch (op) {
        case LDREG: case UNP: case UNM: case BNOT: case LNOT: case TYPEOF: case GETPROTO: case TONUMERIC:
        case GETPROPC: case GETPROPC_CACHED:
            return { .b_read = true, .a_write = true };
        case CLOSURE: case LDCONST: case LDINT: case LDUNDEF: case LDNULL: case LDTRUE: case LDFALSE:
        case LDTHIS: case GETTHISC: case VOID:
        case GETVAR: case GETGLOBAL: case GETBOUND: case GETCAP: case TYPEOFIDENT:
        case INC_VAR: case DEC_VAR: case INC_GLOBAL: case DEC_GLOBAL:
        case NEWOBJ: case NEWARR: case NEWARR_CONST: case NEWOBJ_SHAPE:
            return { .a_write = true };
        case INC: case INC_LT: case DEC: case TOPROPKEY: case TOSTR:
            return { .a_read = true, .a_write = true };
        case GETPROP: case GETPROP_CACHE: case DELPROP:
            return { .b_read = true, .c_read = true, .a_write = true };
        case PUTPROPC:
            return { .a_read = true, .b_read = true };
        case DECLVAR: case DECLVAR_HOIST: case DECLGLOBALFUNC:
            return { .a_read = true };
        case PUTVAR: case PUTVAR_ASSIGN: case PUTGLOBAL: case PUTCAP: case DECLB33GLOBAL:
            // The binding consumes A. Successful writes can clear its owned
            // register reference; generic helpers import the real post-value.
            return { .a_read = true, .a_write = true };
        case PUTTHISC: case SETALEN: case FREEZEOBJ: case SETCONST:
        case RET: case RET_GEN: case THROW: case IF_TRUE: case IF_FALSE:
            return { .a_read = true };
        case NOP: case RETUNDEF: case RETUNDEF_GEN: case THROW_REF: case THROW_SYNTAX:
        case JUMP: case BREAK: case CONTINUE:
            return {};
        case CALL: case CALL_UNDEF_THIS: case NEW_OBJ: case SUPER_CALL:
            return { .b_read = true, .a_write = true, .general = true };
        case CALL_S: case SUPER_CALL_S:
            return { .b_read = true, .c_read = true, .a_write = true, .general = true };
        case CALL_VAR: case CALL_GLOBAL:
            return { .a_write = true, .general = true };
        default: return moveelim_roles[op.ordinal];
    }
}

// A single bounded allocation owns nodes and the PC map. Decoding and target
// validation finish before a consumer sees a graph; failure releases everything.
// split_calls marks real interpreter reentry boundaries while retaining normal
// bytecode call fallthrough for liveness. A native consumer may end its CFG edge
// at node.call and use the external successor as another root.
fn bool bytecode_cfg_build(DecodedCfg* cfg, Instruction* code, uint count,
    heap::Heap* h = null, DecodedOpAllowed allowed = null, bool split_calls = false,
    DecodedCfgBudget budget = DEFAULT_CFG_BUDGET,
    DecodedOpAllowed boundary = null, DecodedReadExtras extra_reads = null, void* read_context = null) {
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
            || !bytecode_cfg_control_supported(view.insn.op)
            || (allowed != null && !allowed(view.insn.op))) return false;
        if (cfg.instruction_count == budget.max_instructions) return false;
        uint index = cfg.instruction_count++;
        cfg.pc_to_index[pc] = index;
        DecodedCfgNode* node = &cfg.nodes[index];
        node.view = view;
        node.extra_reads = extra_reads;
        node.read_context = read_context;
        node.roles = bytecode_cfg_roles(view.insn.op);
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
        bool helper_boundary = (split_calls && node.call) || (boundary != null && boundary(node.view.insn.op));
        if (branch || !fallthrough || helper_boundary) cfg.nodes[i + 1].block_entry = true;
        if (helper_boundary) cfg.nodes[i + 1].external = true;
    }
    for (uint i = 0; i < cfg.instruction_count; i++) {
        if (cfg.nodes[i].block_entry) cfg.block_count++;
        cfg.nodes[i].block = cfg.block_count - 1;
    }
    complete = true;
    return true;
}

fn void DecodedCfgNode.reads(&self, RegSet* uses, bool call_windows = true) {
    if (self.extra_reads != null) self.extra_reads(self.read_context, self.view, uses);
    DecodedInsn ins = self.view.insn;
    switch (ins.op) {
        case CALL: case NEW_OBJ: case SUPER_CALL:
            uses.set(ins.b);
            if (call_windows) moveelim_mark_range(uses, ins.b + 1, ins.b + 1 + ins.c);
            return;
        case CALL_UNDEF_THIS:
            uses.set(ins.b);
            if (call_windows && ins.c != 0) moveelim_mark_range(uses, ins.b + 2, ins.b + 1 + ins.c);
            return;
        case CALL_VAR: case CALL_GLOBAL:
            // The fused resolver overwrites callee A and receiver A+1 before
            // dispatch. Only argument values enter from the previous frame.
            if (call_windows && ins.b != 0) moveelim_mark_range(uses, ins.a + 2, ins.a + 1 + ins.b);
            return;
        case CALL_S: case SUPER_CALL_S:
            uses.set(ins.b);
            uses.set(ins.c); // actual runtime argument-count register
            if (call_windows) moveelim_mark_range(uses, ins.b + 1, uses.word_count * 32 - 1);
            return;
        default: break;
    }
    if (self.roles.general) {
        moveelim_add_decoded_uses(ins, uses, call_windows);
    } else {
        moveelim_add_role_uses(self.roles, ins.a, ins.b, ins.c, uses);
    }
}

fn bool DecodedCfgNode.must_def(&self, uint* reg) {
    return moveelim_get_role_def(self.roles, self.view.insn.a, reg);
}

// By default liveness arrays are indexed by canonical instruction index.
// word_slots adapts existing callers whose arrays and recovery queries use PCs;
// WIDE payload slots are cleared but never traversed as instructions.
fn bool bytecode_cfg_liveness(DecodedCfg* cfg, RegSet* live_out, RegSet* live_in,
    RegSet* scratch, bool call_windows = true, bool word_slots = false,
    DecodedWorkCharge charge = null, void* charge_data = null) {
    uint slots = word_slots ? cfg.word_count : cfg.instruction_count;
    for (uint i = 0; i < slots; i++) { live_out[i].clear(); live_in[i].clear(); }
    bool first = true;
    bool changed = true;
    while (changed) {
        if (charge != null && !charge(charge_data, (usz)cfg.instruction_count * (usz)(scratch.word_count * 4 + 1))) return false;
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
            node.reads(&live_in[slot], call_windows);
        }
        first = false;
    }
    return true;
}
