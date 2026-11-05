// Optimizing tier: code generation.
//
// The nodes are emitted in block order. A GENERIC node runs the baseline
// emitter's code for its instruction (Asm.emit_insn) between a store of the
// dirty registers it can read and a reload of the numeric registers live after
// it. Guards jump out of line to exit stubs that store the dirty registers
// live at the resume point and continue in the baseline code (opt.c3).
module boomkat::jit @feat(SLJIT);

import boomkat::heap;
import boomkat::bytecode;
import boomkat::types;
import std::collections::list;

// Where a jump leaves the optimized code from: the resume point and the
// (register, node) pairs to store first.
struct OptExitRef {
    void* jump;
    uint pc;
    uint dirty_first;
    uint dirty_count;
    uint reason;
}

struct OptGoto {
    void* jump;
    uint block;
}

// A conditional branch's taken edge, emitted after the blocks.
struct OptTaken {
    void*[8] jumps;
    uint jump_count;
    uint block;
}

// One phi move of an edge: registers are keyed with floating point ones offset
// so the two files do not collide.
struct OptMoveItem {
    uint dst;
    uint src;
    int dst_key;
    int src_key;
    int src_reg;
    bool done;
}

const int FLT_KEY = 1000;

struct OptCg {
    Asm* a;
    OptGraph* g;
    Heap* h;
    OptCode* oc;
    OptPools pools;
    void*[] labels;
    List{OptGoto} gotos;
    List{OptExitRef} exits;
    List{OptTaken} taken;
    bool forced_done;
}

fn void OptCg.init(&self) {
    self.gotos.init(mem);
    self.exits.init(mem);
    self.taken.init(mem);
}

fn void OptCg.free(&self) {
    self.gotos.free();
    self.exits.free();
    self.taken.free();
    mem::free(self.labels);
}

fn void* OptCg.c(&self) @inline => self.a.c;

// --- Operands ---

// The window slot's value of a spilled (or home-resident) INT32 node, loaded
// into `tmp` as the sign-extended integer.
fn void OptCg.load_unboxed(&self, int tmp, uint slot) {
    void* c = self.a.c;
    self.a.load(tmp, slot);
    sljit_emit_op2(c, SLJIT_SHL, tmp, 0, tmp, 0, SLJIT_IMM, 16);
    sljit_emit_op2(c, SLJIT_ASHR, tmp, 0, tmp, 0, SLJIT_IMM, 16);
}

// INT32 node `n` as a source operand: a register or an immediate; a spilled
// value is loaded into `tmp`.
fn void OptCg.int_src(&self, uint n, int tmp, int* r, long* rw) {
    OptNode* nd = &self.g.nodes[n];
    *rw = 0;
    if (nd.op == OptOp.CONST_I32) {
        *r = SLJIT_IMM;
        *rw = nd.imm;
    } else if (nd.reg >= 0) {
        *r = nd.reg;
    } else {
        self.load_unboxed(tmp, nd.home);
        *r = tmp;
    }
}

// INT32 node `n` in a register, an immediate moved into `tmp`.
fn int OptCg.int_reg(&self, uint n, int tmp) {
    int r;
    long rw;
    self.int_src(n, tmp, &r, &rw);
    if (r != SLJIT_IMM) return r;
    sljit_emit_op1(self.a.c, SLJIT_MOV, tmp, 0, SLJIT_IMM, rw);
    return tmp;
}

// FLOAT64 node `n` in a floating point register, a constant or a spilled
// value loaded into `ftmp`.
fn int OptCg.flt_reg(&self, uint n, int ftmp) {
    void* c = self.a.c;
    OptNode* nd = &self.g.nodes[n];
    if (nd.op == OptOp.CONST_F64) {
        sljit_emit_op1(c, SLJIT_MOV, R4, 0, SLJIT_IMM, nd.imm);
        sljit_emit_fcopy(c, SLJIT_COPY_TO_F64, ftmp, R4);
        return ftmp;
    }
    if (nd.reg >= 0) return nd.reg;
    sljit_emit_fop1(c, SLJIT_MOV_F64, ftmp, 0, SLJIT_MEM | self.a.regs, (long)nd.home * TVal::size);
    return ftmp;
}

// The number in window slot `slot`, known to be one, as a double in `fr`: the
// slot may hold an int32 the node was converted from.
fn void OptCg.reload_flt(&self, int fr, uint slot) {
    void* c = self.a.c;
    self.a.load(R2, slot);
    void* not_double = sljit_emit_cmp(c, SLJIT_GREATER_EQUAL, R2, 0, SLJIT_IMM, K_INT);
    sljit_emit_fop1(c, SLJIT_MOV_F64, fr, 0, SLJIT_MEM | self.a.regs, (long)slot * TVal::size);
    void* done = sljit_emit_jump(c, SLJIT_JUMP);
    sljit_set_label(not_double, sljit_emit_label(c));
    sljit_emit_op2(c, SLJIT_SHL, R2, 0, R2, 0, SLJIT_IMM, 16);
    sljit_emit_op2(c, SLJIT_ASHR, R2, 0, R2, 0, SLJIT_IMM, 16);
    sljit_emit_fop1(c, SLJIT_CONV_F64_FROM_SW, fr, 0, R2, 0);
    sljit_set_label(done, sljit_emit_label(c));
}

// Store the double in `fsrc` to window slot `slot`, as TVal.set_number does: a
// NaN whose bits would read as a tag becomes the canonical NaN. Uses R0.
fn void OptCg.store_flt(&self, uint slot, int fsrc) {
    void* c = self.a.c;
    sljit_emit_fcopy(c, SLJIT_COPY_FROM_F64, fsrc, R0);
    void* ok = sljit_emit_cmp(c, SLJIT_LESS, R0, 0, SLJIT_IMM, K_INT);
    sljit_emit_op1(c, SLJIT_MOV, R0, 0, SLJIT_IMM, CANONICAL_NAN);
    sljit_set_label(ok, sljit_emit_label(c));
    self.a.store(slot, R0);
}

// The value of node `n` stored to window slot `slot`, boxed.
fn void OptCg.store_node(&self, uint n, uint slot) {
    void* c = self.a.c;
    OptNode* nd = &self.g.nodes[n];
    if (nd.op == OptOp.CONST_I32) {
        self.a.store(slot, SLJIT_IMM, K_INT | (nd.imm & (PAYLOAD_SPAN - 1)));
    } else if (nd.op == OptOp.CONST_F64) {
        self.a.store(slot, SLJIT_IMM, nd.imm);
    } else if (nd.reg < 0) {
        // Lives in its home slot already.
    } else if (nd.rep == OptRep.INT32) {
        sljit_emit_op2(c, SLJIT_AND, R0, 0, nd.reg, 0, SLJIT_IMM, PAYLOAD_SPAN - 1);
        sljit_emit_op2(c, SLJIT_OR, R0, 0, R0, 0, SLJIT_IMM, K_INT);
        self.a.store(slot, R0);
    } else {
        self.store_flt(slot, nd.reg);
    }
}

fn void OptCg.store_dirty(&self, uint first, uint count) {
    for (uint k = 0; k < count; k++) {
        OptDirty d = self.g.dirty[(sz)(first + k)];
        self.store_node(d.node, d.reg);
    }
}

// The result of INT32 node `n`, computed into register `src`.
fn void OptCg.def_int(&self, uint n, int src) {
    void* c = self.a.c;
    OptNode* nd = &self.g.nodes[n];
    if (nd.reg >= 0) {
        if (nd.reg != src) sljit_emit_op1(c, SLJIT_MOV, nd.reg, 0, src, 0);
        return;
    }
    sljit_emit_op2(c, SLJIT_AND, R1, 0, src, 0, SLJIT_IMM, PAYLOAD_SPAN - 1);
    sljit_emit_op2(c, SLJIT_OR, R1, 0, R1, 0, SLJIT_IMM, K_INT);
    self.a.store(nd.home, R1);
}

fn void OptCg.def_flt(&self, uint n, int fsrc) {
    OptNode* nd = &self.g.nodes[n];
    if (nd.reg >= 0) {
        if (nd.reg != fsrc) sljit_emit_fop1(self.a.c, SLJIT_MOV_F64, nd.reg, 0, fsrc, 0);
        return;
    }
    self.store_flt(nd.home, fsrc);
}

fn int OptCg.int_dst(&self, uint n, int tmp) @inline {
    int r = self.g.nodes[n].reg;
    return r >= 0 ? r : tmp;
}

fn int OptCg.flt_dst(&self, uint n, int ftmp) @inline {
    int r = self.g.nodes[n].reg;
    return r >= 0 ? r : ftmp;
}

// --- Exits ---

fn void OptCg.exit_at(&self, void* jump, uint node, OptExit reason) {
    OptNode* n = &self.g.nodes[node];
    self.exits.push({ .jump = jump, .pc = n.pc, .dirty_first = n.dirty_first, .dirty_count = n.dirty_count, .reason = (uint)reason.ordinal });
}

// Every jump the baseline helpers collected in `call` leaves through `reason`.
fn void OptCg.exit_calls(&self, uint node, OptExit reason) {
    for (uint k = 0; k < self.a.call.len; k++) self.exit_at(self.a.call.at[k], node, reason);
    self.a.call.len = 0;
}

fn void OptCg.emit_exit_stubs(&self) {
    void* c = self.a.c;
    uint i = 0;
    uint count = (uint)self.exits.len();
    while (i < count) {
        OptExitRef e = self.exits[(sz)i];
        void* label = sljit_emit_label(c);
        // Jumps of one site share the stub.
        while (i < count) {
            OptExitRef x = self.exits[(sz)i];
            if (x.pc != e.pc || x.dirty_first != e.dirty_first || x.reason != e.reason) break;
            sljit_set_label(x.jump, label);
            i++;
        }
        self.store_dirty(e.dirty_first, e.dirty_count);
        self.a.i = e.pc;
        self.a.emit_opt_exit(self.oc, e.reason, false);
    }
}

// --- Edges ---

fn void OptCg.emit_item(&self, OptMoveItem* m) {
    void* c = self.a.c;
    OptNode* d = &self.g.nodes[m.dst];
    OptNode* s = &self.g.nodes[m.src];
    bool is_const = s.is_const();
    if (d.rep == OptRep.INT32) {
        if (is_const) {
            sljit_emit_op1(c, SLJIT_MOV, d.reg, 0, SLJIT_IMM, s.imm);
        } else if (m.src_reg >= 0) {
            sljit_emit_op1(c, SLJIT_MOV, d.reg, 0, m.src_reg, 0);
        } else {
            self.load_unboxed(d.reg, s.home);
        }
    } else if (s.rep == OptRep.FLOAT64) {
        if (is_const) {
            sljit_emit_op1(c, SLJIT_MOV, R4, 0, SLJIT_IMM, s.imm);
            sljit_emit_fcopy(c, SLJIT_COPY_TO_F64, d.reg, R4);
        } else if (m.src_reg >= 0) {
            sljit_emit_fop1(c, SLJIT_MOV_F64, d.reg, 0, m.src_reg, 0);
        } else {
            self.reload_flt(d.reg, s.home);
        }
    } else if (is_const) {
        sljit_emit_op1(c, SLJIT_MOV, R4, 0, SLJIT_IMM, s.imm);
        sljit_emit_fop1(c, SLJIT_CONV_F64_FROM_SW, d.reg, 0, R4, 0);
    } else if (m.src_reg >= 0) {
        sljit_emit_fop1(c, SLJIT_CONV_F64_FROM_SW, d.reg, 0, m.src_reg, 0);
    } else {
        self.load_unboxed(R0, s.home);
        sljit_emit_fop1(c, SLJIT_CONV_F64_FROM_SW, d.reg, 0, R0, 0);
    }
}

fn int OptCg.key_of(&self, OptNode* n) {
    return n.rep == OptRep.FLOAT64 ? FLT_KEY + n.reg : n.reg;
}

// The work of edge `e` of block `pos`: stores of dirty registers that are
// Window in the successor, then the phi moves as a parallel copy.
fn void OptCg.emit_moves(&self, OptBlock* blk, uint e) {
    List{OptMoveItem} items;
    items.init(mem);
    defer items.free();
    for (uint k = 0; k < blk.move_count[e]; k++) {
        OptMove m = self.g.moves[(sz)(blk.move_first[e] + k)];
        if (m.dst == NO_NODE) {
            self.store_node(m.src, m.slot);
            continue;
        }
        OptNode* d = &self.g.nodes[m.dst];
        OptNode* s = &self.g.nodes[m.src];
        OptMoveItem it = { .dst = m.dst, .src = m.src, .dst_key = self.key_of(d), .src_key = -1, .src_reg = -1 };
        if (!s.is_const() && s.reg >= 0) {
            it.src_key = self.key_of(s);
            it.src_reg = s.reg;
        }
        if (it.src_key == it.dst_key) continue;
        items.push(it);
    }
    sz remaining = items.len();
    while (remaining > 0) {
        bool progress = false;
        for (sz i = 0; i < items.len(); i++) {
            OptMoveItem* it = &items[i];
            if (it.done) continue;
            bool blocked = false;
            for (sz j = 0; j < items.len(); j++) {
                if (j != i && !items[j].done && items[j].src_key == it.dst_key) { blocked = true; break; }
            }
            if (blocked) continue;
            self.emit_item(it);
            it.done = true;
            remaining--;
            progress = true;
        }
        if (progress) continue;
        // Only cycles remain: save one destination and read it from there.
        OptMoveItem* first = null;
        for (sz i = 0; i < items.len(); i++) if (!items[i].done) { first = &items[i]; break; }
        bool flt = first.dst_key >= FLT_KEY;
        int reg = flt ? first.dst_key - FLT_KEY : first.dst_key;
        int tmp = flt ? FR1 : R1;
        if (flt) {
            sljit_emit_fop1(self.a.c, SLJIT_MOV_F64, tmp, 0, reg, 0);
        } else {
            sljit_emit_op1(self.a.c, SLJIT_MOV, tmp, 0, reg, 0);
        }
        int old_key = first.dst_key;
        for (sz j = 0; j < items.len(); j++) {
            OptMoveItem* x = &items[j];
            if (!x.done && x.src_key == old_key) {
                x.src_key = flt ? FLT_KEY + tmp : tmp;
                x.src_reg = tmp;
            }
        }
    }
}

// The budget and interrupt poll of a back edge to block `target`: when it
// fires the code leaves for the baseline code at the loop header.
fn void OptCg.emit_poll(&self, uint target) {
    OptBlock* h = &self.g.blocks[target];
    self.a.call.len = 0;
    self.a.back_edge();
    for (uint k = 0; k < self.a.call.len; k++) {
        self.exits.push({ .jump = self.a.call.at[k], .pc = h.pc, .dirty_first = h.entry_first, .dirty_count = h.entry_count,
                          .reason = (uint)OptExit.INTERRUPT.ordinal });
    }
    self.a.call.len = 0;
}

// Continue to block `target` from block `pos`: fall through when it is next.
fn void OptCg.transfer(&self, uint pos, uint target, bool may_fall) {
    void* c = self.a.c;
    if (target <= pos) {
        self.emit_poll(target);
        sljit_set_label(sljit_emit_jump(c, SLJIT_JUMP), self.labels[target]);
    } else if (!(may_fall && target == pos + 1)) {
        self.gotos.push({ .jump = sljit_emit_jump(c, SLJIT_JUMP), .block = target });
    }
}

fn void OptCg.emit_edge(&self, uint pos, uint e, bool may_fall) {
    OptBlock* blk = &self.g.blocks[pos];
    self.emit_moves(blk, e);
    self.transfer(pos, blk.succ[e], may_fall);
}

// Record a taken edge to leave from the jumps in `jumps`, out of line when it
// has work to do or is a back edge.
fn void OptCg.defer_taken(&self, uint pos, void** jumps, uint count) {
    OptBlock* blk = &self.g.blocks[pos];
    uint target = blk.succ[0];
    if (blk.move_count[0] == 0 && target > pos) {
        for (uint k = 0; k < count; k++) self.gotos.push({ .jump = jumps[k], .block = target });
        return;
    }
    OptTaken t = { .jump_count = count, .block = pos };
    for (uint k = 0; k < count; k++) t.jumps[k] = jumps[k];
    self.taken.push(t);
}

fn void OptCg.emit_taken_stubs(&self) {
    void* c = self.a.c;
    foreach (&t : self.taken) {
        void* label = sljit_emit_label(c);
        for (uint k = 0; k < t.jump_count; k++) sljit_set_label(t.jumps[k], label);
        self.emit_edge(t.block, 0, false);
    }
}

// --- Nodes ---

fn bool OptCg.force_here(&self, OptNode* n) {
    OptPolicy* p = &self.h.opt;
    return self.oc != null && p.force_reason != 0 && !self.forced_done && n.pc >= p.force_at;
}

fn void OptCg.emit_check_int(&self, uint i, OptNode* n) {
    void* c = self.a.c;
    self.a.call.len = 0;
    self.a.load(R0, (uint)n.imm);
    self.a.guard_int(R0);
    self.exit_calls(i, OptExit.NOT_INT32);
    sljit_emit_op2(c, SLJIT_SHL, R0, 0, R0, 0, SLJIT_IMM, 16);
    sljit_emit_op2(c, SLJIT_ASHR, R0, 0, R0, 0, SLJIT_IMM, 16);
    sljit_emit_op1(c, SLJIT_MOV_S32, R1, 0, R0, 0);
    self.exit_at(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R1, 0, R0, 0), i, OptExit.NOT_INT32);
    if (n.reg >= 0) sljit_emit_op1(c, SLJIT_MOV, n.reg, 0, R0, 0);
}

fn void OptCg.emit_check_num(&self, uint i, OptNode* n) {
    self.a.call.len = 0;
    int dst = n.reg >= 0 ? n.reg : FR0;
    self.a.load_number(dst, (uint)n.imm);
    self.exit_calls(i, OptExit.NOT_NUMBER);
    if (n.reg < 0) self.store_flt(n.home, dst);
}

fn void OptCg.emit_copy(&self, OptNode* n, uint i) {
    void* c = self.a.c;
    if (n.rep == OptRep.INT32) {
        int r;
        long rw;
        self.int_src(n.a, R0, &r, &rw);
        int dst = self.int_dst(i, R0);
        sljit_emit_op1(c, SLJIT_MOV, dst, 0, r, rw);
        self.def_int(i, dst);
    } else {
        int f = self.flt_reg(n.a, FR0);
        int dst = self.flt_dst(i, FR0);
        if (dst != f) sljit_emit_fop1(c, SLJIT_MOV_F64, dst, 0, f, 0);
        self.def_flt(i, dst);
    }
}

// ADD_I32 and SUB_I32: the 64-bit result of two int32 values is exact; it exits
// when it is not an int32.
fn void OptCg.emit_addsub(&self, uint i, OptNode* n) {
    void* c = self.a.c;
    int x = self.int_reg(n.a, R0);
    int y;
    long yw;
    self.int_src(n.b, R1, &y, &yw);
    sljit_emit_op2(c, n.op == OptOp.ADD_I32 ? SLJIT_ADD : SLJIT_SUB, R2, 0, x, 0, y, yw);
    sljit_emit_op1(c, SLJIT_MOV_S32, R3, 0, R2, 0);
    self.exit_at(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R3, 0, R2, 0), i, OptExit.OVERFLOW);
    self.def_int(i, R2);
}

fn void OptCg.emit_mul(&self, uint i, OptNode* n) {
    void* c = self.a.c;
    int x = self.int_reg(n.a, R0);
    int y = self.int_reg(n.b, R1);
    sljit_emit_op2(c, SLJIT_MUL, R2, 0, x, 0, y, 0);
    sljit_emit_op1(c, SLJIT_MOV_S32, R3, 0, R2, 0);
    self.exit_at(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R3, 0, R2, 0), i, OptExit.OVERFLOW);
    // A zero product of operands one of which is negative is -0.
    void* nonzero = sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R2, 0, SLJIT_IMM, 0);
    sljit_emit_op2(c, SLJIT_OR, R3, 0, x, 0, y, 0);
    self.exit_at(sljit_emit_cmp(c, SLJIT_SIG_LESS, R3, 0, SLJIT_IMM, 0), i, OptExit.OVERFLOW);
    sljit_set_label(nonzero, sljit_emit_label(c));
    self.def_int(i, R2);
}

fn void OptCg.emit_bitop(&self, uint i, OptNode* n) {
    void* c = self.a.c;
    int x = self.int_reg(n.a, R0);
    int y;
    long yw;
    self.int_src(n.b, R1, &y, &yw);
    int dst = self.int_dst(i, R2);
    switch (n.op) {
        case AND_I32: sljit_emit_op2(c, SLJIT_AND, dst, 0, x, 0, y, yw);
        case OR_I32:  sljit_emit_op2(c, SLJIT_OR, dst, 0, x, 0, y, yw);
        case XOR_I32: sljit_emit_op2(c, SLJIT_XOR, dst, 0, x, 0, y, yw);
        case NOT_I32: sljit_emit_op2(c, SLJIT_XOR, dst, 0, x, 0, SLJIT_IMM, -1);
        default:
            if (y == SLJIT_IMM) yw &= 0x1F;
            int sop = n.op == OptOp.SHL_I32 ? SLJIT_MSHL : (n.op == OptOp.SAR_I32 ? SLJIT_MASHR : SLJIT_MLSHR);
            sljit_emit_op2(c, sop | SLJIT_32, dst, 0, x, 0, y, yw);
            if (n.op == OptOp.SHR_I32) {
                sljit_emit_op1(c, SLJIT_MOV_U32, dst, 0, dst, 0);
                self.exit_at(sljit_emit_cmp(c, SLJIT_GREATER, dst, 0, SLJIT_IMM, 0x7FFFFFFF), i, OptExit.OVERFLOW);
            } else {
                sljit_emit_op1(c, SLJIT_MOV_S32, dst, 0, dst, 0);
            }
    }
    self.def_int(i, dst);
}

fn void OptCg.emit_f64_to_i32(&self, uint i, OptNode* n) {
    void* c = self.a.c;
    int x = self.flt_reg(n.a, FR0);
    // 2^63 and -2^63: outside them (or NaN) the conversion is not the modular ToInt32.
    sljit_emit_op1(c, SLJIT_MOV, R4, 0, SLJIT_IMM, 0x43E0000000000000);
    sljit_emit_fcopy(c, SLJIT_COPY_TO_F64, FR1, R4);
    self.exit_at(sljit_emit_fcmp(c, SLJIT_UNORDERED_OR_GREATER_EQUAL, x, 0, FR1, 0), i, OptExit.OVERFLOW);
    sljit_emit_op1(c, SLJIT_MOV, R4, 0, SLJIT_IMM, (long)0xC3E0000000000000);
    sljit_emit_fcopy(c, SLJIT_COPY_TO_F64, FR1, R4);
    self.exit_at(sljit_emit_fcmp(c, SLJIT_ORDERED_LESS, x, 0, FR1, 0), i, OptExit.OVERFLOW);
    sljit_emit_fop1(c, SLJIT_CONV_SW_FROM_F64, R0, 0, x, 0);
    sljit_emit_op1(c, SLJIT_MOV_S32, R0, 0, R0, 0);
    self.def_int(i, R0);
}

fn void OptCg.emit_fop(&self, uint i, OptNode* n) {
    void* c = self.a.c;
    int x = self.flt_reg(n.a, FR0);
    int y = self.flt_reg(n.b, FR1);
    int dst = self.flt_dst(i, FR0);
    int op = n.op == OptOp.ADD_F64 ? SLJIT_ADD_F64 : (n.op == OptOp.SUB_F64 ? SLJIT_SUB_F64 : (n.op == OptOp.MUL_F64 ? SLJIT_MUL_F64 : SLJIT_DIV_F64));
    sljit_emit_fop2(c, op, dst, 0, x, 0, y, 0);
    self.def_flt(i, dst);
}

// A conditional branch: leave the taken jumps in `jumps`.
fn uint OptCg.emit_test(&self, uint i, OptNode* n, void** jumps) {
    void* c = self.a.c;
    if (n.op == OptOp.BRANCH) {
        if (n.imm == (long)OptRep.INT32.ordinal) {
            int x = self.int_reg(n.a, R0);
            int y;
            long yw;
            self.int_src(n.b, R1, &y, &yw);
            jumps[0] = sljit_emit_cmp(c, JMP_INT_COND[n.cc], x, 0, y, yw);
        } else {
            int x = self.flt_reg(n.a, FR0);
            int y = self.flt_reg(n.b, FR1);
            jumps[0] = sljit_emit_fcmp(c, JMP_FLOAT_COND[n.cc], x, 0, y, 0);
        }
        return 1;
    }
    bool negate = n.cc != 0;
    if (n.a != NO_NODE) {
        if (self.g.nodes[n.a].rep == OptRep.INT32) {
            int x = self.int_reg(n.a, R0);
            jumps[0] = sljit_emit_cmp(c, negate ? SLJIT_EQUAL : SLJIT_NOT_EQUAL, x, 0, SLJIT_IMM, 0);
        } else {
            int x = self.flt_reg(n.a, FR0);
            sljit_emit_op1(c, SLJIT_MOV, R4, 0, SLJIT_IMM, 0);
            sljit_emit_fcopy(c, SLJIT_COPY_TO_F64, FR1, R4);
            jumps[0] = sljit_emit_fcmp(c, negate ? SLJIT_UNORDERED_OR_EQUAL : SLJIT_ORDERED_NOT_EQUAL, x, 0, FR1, 0);
        }
        return 1;
    }
    // A value in the window: the baseline's truth test.
    Jumps truthy;
    Jumps falsy;
    self.a.call.len = 0;
    self.a.truth_test((uint)n.imm, &truthy, &falsy);
    self.exit_calls(i, OptExit.SLOW_PATH);
    Jumps* take = negate ? &falsy : &truthy;
    Jumps* skip = negate ? &truthy : &falsy;
    uint count = take.len > 8 ? 8 : take.len;
    for (uint k = 0; k < count; k++) jumps[k] = take.at[k];
    skip.bind(sljit_emit_label(c));
    return count;
}

fn void OptCg.emit_generic(&self, uint i, OptNode* n) {
    void* c = self.a.c;
    self.store_dirty(n.dirty_first, n.dirty_count);
    uint at = (uint)n.imm;
    self.a.emit_insn(at);
    // The out-of-line paths return here, before the reload.
    self.a.labels[self.a.next] = sljit_emit_label(c);
    for (uint k = 0; k < n.reload_count; k++) {
        OptDirty d = self.g.dirty[(sz)(n.reload_first + k)];
        OptNode* nd = &self.g.nodes[d.node];
        if (nd.reg < 0 || nd.is_const()) continue;
        if (nd.rep == OptRep.INT32) {
            self.load_unboxed(nd.reg, d.reg);
        } else {
            self.reload_flt(nd.reg, d.reg);
        }
    }
}

fn void OptCg.emit_node(&self, uint i, uint pos) {
    void* c = self.a.c;
    OptNode* n = &self.g.nodes[i];
    if (n.dirty_count != 0 || n.op == OptOp.GENERIC || n.op == OptOp.CHECK_I32 || n.op == OptOp.CHECK_NUM) {
        if (self.force_here(n)) {
            self.forced_done = true;
            self.store_dirty(n.dirty_first, n.dirty_count);
            self.a.i = n.pc;
            self.a.emit_opt_exit(self.oc, self.h.opt.force_reason - 1, true);
        }
    }
    switch (n.op) {
        case CONST_I32:
        case CONST_F64:
        case PHI:
        case NOT_I32:
            if (n.op == OptOp.NOT_I32) self.emit_bitop(i, n);
        case CHECK_I32:
            self.emit_check_int(i, n);
        case CHECK_NUM:
            self.emit_check_num(i, n);
        case COPY:
            self.emit_copy(n, i);
        case ADD_I32:
        case SUB_I32:
            self.emit_addsub(i, n);
        case MUL_I32:
            self.emit_mul(i, n);
        case AND_I32:
        case OR_I32:
        case XOR_I32:
        case SHL_I32:
        case SAR_I32:
        case SHR_I32:
            self.emit_bitop(i, n);
        case I32_TO_F64:
            int r = self.int_reg(n.a, R0);
            int dst = self.flt_dst(i, FR0);
            sljit_emit_fop1(c, SLJIT_CONV_F64_FROM_SW, dst, 0, r, 0);
            self.def_flt(i, dst);
        case F64_TO_I32:
            self.emit_f64_to_i32(i, n);
        case ADD_F64:
        case SUB_F64:
        case MUL_F64:
        case DIV_F64:
            self.emit_fop(i, n);
        case JUMP:
            self.emit_edge(pos, 0, true);
        case BRANCH:
        case BRANCH_TRUTH:
            void*[8] jumps;
            uint count = self.emit_test(i, n, &jumps[0]);
            self.emit_edge(pos, 1, true);
            self.defer_taken(pos, &jumps[0], count);
        case GENERIC:
            self.emit_generic(i, n);
    }
}

// Generate native code for the graph. Null when code generation fails.
fn BaselineCode* opt_emit(Heap* h, CompiledFunction* f, OptGraph* g, OptCode* oc, OptPools pools) {
    uint count = f.code_count;
    BaselineCode* bc = baseline_alloc(h, count);
    if (bc == null) return null;
    void* c = sljit_create_compiler(null);
    if (c == null) { h.free_func(h.heap_udata, bc); return null; }
    defer sljit_free_compiler(c);
    Asm a = asm_new(c, h, f);
    defer a.release();
    int table_reg = reg_s(2);
    void* dispatch = a.emit_dispatch(table_reg, bc, count, pools.scratches | (pools.fscratches << 8));
    a.emit_nonzero_exit(dispatch);
    // An entry that is not an entry of the optimized code continues in the baseline code.
    void* to_base = sljit_emit_label(c);
    sljit_emit_op1(c, SLJIT_MOV, R0, 0, a.ds, 0);
    sljit_emit_icall(c, SLJIT_CALL | SLJIT_CALL_RETURN, SLJIT_ARGS1WW, SLJIT_IMM, (long)(usz)oc.base.exec);

    OptCg cg = { .a = &a, .h = h, .g = g, .oc = oc, .pools = pools };
    cg.init();
    defer cg.free();
    uint blocks = (uint)g.blocks.len();
    cg.labels = mem::new_array(void*, blocks);
    for (uint pos = 0; pos < blocks; pos++) {
        OptBlock* blk = &g.blocks[pos];
        cg.labels[pos] = sljit_emit_label(c);
        for (uint i = blk.first; i < blk.end; i++) {
            cg.emit_node(i, pos);
            bc.insns++;
        }
    }
    a.emit_stubs();
    cg.emit_taken_stubs();
    cg.emit_exit_stubs();
    foreach (gt : cg.gotos) sljit_set_label(gt.jump, cg.labels[gt.block]);
    if (a.finish(h, bc, null) == null) return null;
    for (uint i = 0; i < count; i++) {
        if (a.starts[i]) bc.entries[i] = (void*)sljit_shim_label_addr(to_base);
    }
    bc.entries[0] = (void*)sljit_shim_label_addr(cg.labels[0]);
    return bc;
}
