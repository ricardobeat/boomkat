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
import boomkat::compiler;
import boomkat::types;
import boomkat::features;
import boomkat::hobject;
import boomkat::env;
import boomkat::vm;
import boomkat::builtins;
import boomkat::hstring;
import boomkat::re_bindings;
import boomkat::re_native;
import std::math;
import std::collections::list;
import std::io;

// Where a jump leaves the optimized code from: the resume point and the
// (register, node) pairs to store first.
struct OptExitRef {
    void* jump;
    uint pc;
    // The OptGraph.fns entry that pc indexes.
    uint fidx;
    uint dirty_first;
    uint dirty_count;
    uint reason;
    // For an exit from an inlined body: the callee registers live at the resume point.
    uint mask;
    // The node the exit leaves from, whose sunk objects it allocates (OptMat), or NO_NODE.
    uint node;
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

// A back edge's poll: the jumps that take its slow path, and where the loop resumes.
struct OptPoll {
    void*[2] jumps;
    uint jump_count;
    void* resume;
    uint target;
}

struct OptCg {
    Asm* a;
    OptGraph* g;
    Heap* h;
    OptCode* oc;
    OptPools pools;
    void*[] labels;
    void*[] osr_labels;
    List{OptGoto} gotos;
    List{OptExitRef} exits;
    List{OptTaken} taken;
    List{OptPoll} polls;
    bool forced_done;
    // The native stack offset of the function's capture records (the running closure's), which
    // every entry loads once (emit_cap_refs); -1 when no read of the function's own uses it.
    long cap_slot;
}

fn void OptCg.init(&self) {
    self.gotos.init(mem);
    self.exits.init(mem);
    self.taken.init(mem);
    self.polls.init(mem);
}

fn void OptCg.free(&self) {
    self.gotos.free();
    self.exits.free();
    self.taken.free();
    self.polls.free();
    mem::free(self.labels);
    mem::free(self.osr_labels);
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
    void* not_double = sljit_emit_cmp(c, SLJIT_GREATER_EQUAL, R2, 0, k_int_op(), k_int_w());
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
    void* ok = sljit_emit_cmp(c, SLJIT_LESS, R0, 0, k_int_op(), k_int_w());
    sljit_emit_op1(c, SLJIT_MOV, R0, 0, SLJIT_IMM, CANONICAL_NAN);
    sljit_set_label(ok, sljit_emit_label(c));
    self.a.store(slot, R0);
}

// VALUE node `n` in a register: its own, or `tmp` loaded from its home slot (or for `this`, from
// the record).
fn int OptCg.value_reg(&self, uint n, int tmp) {
    OptNode* nd = &self.g.nodes[n];
    if (nd.op == OptOp.CONST_OBJ) {
        sljit_emit_op1(self.a.c, SLJIT_MOV, tmp, 0, SLJIT_IMM, nd.imm);
        return tmp;
    }
    if (nd.op == OptOp.THIS) {
        self.a.load_this(tmp);
        return tmp;
    }
    if (nd.reg >= 0) return nd.reg;
    self.a.load(tmp, nd.home);
    return tmp;
}

// The boxed object or inert value in `src` stored to window slot `slot`, raising the frame's
// heap_reg_count over it as Asm.publish does. Uses R2 and R3.
fn void OptCg.store_object(&self, uint slot, int src) {
    self.a.store(slot, src);
    self.a.track_heap_store(slot);
}

// The value of VALUE node `nd`, in `src`, stored to window slot `slot`: plainly when a boolean,
// and marked while the collector is marking when it may be a value the collector has not seen
// (OptGraph.unshaded), unless `shade` is false and the caller does that. Uses R2 and R3.
fn void OptCg.store_value_node(&self, OptNode* nd, uint slot, int src, bool shade = true) {
    if (self.g.is_boolean(nd)) {
        self.a.store(slot, src);
        return;
    }
    self.store_object(slot, src);
    if (!shade || !self.g.unshaded(nd)) return;
    assert(src != R3);
    void* quiet = self.not_marking();
    self.shade(src);
    sljit_set_label(quiet, sljit_emit_label(self.a.c));
}

// The value of node `n` stored to window slot `slot`, boxed; `shade` as store_value_node has it.
fn void OptCg.store_node(&self, uint n, uint slot, bool shade = true) {
    void* c = self.a.c;
    OptNode* nd = &self.g.nodes[n];
    if (nd.op == OptOp.CONST_I32) {
        self.a.store(slot, SLJIT_IMM, K_INT | (nd.imm & (PAYLOAD_SPAN - 1)));
    } else if (nd.op == OptOp.CONST_F64) {
        self.a.store(slot, SLJIT_IMM, nd.imm);
    } else if (nd.op == OptOp.CONST_OBJ) {
        self.a.store(slot, SLJIT_IMM, nd.imm);
        TVal v = { .bits = (ulong)nd.imm };
        if (!v.is_inert()) self.a.track_heap_store(slot);
    } else if (nd.op == OptOp.THIS) {
        self.store_value_node(nd, slot, self.value_reg(n, R0), shade);
    } else if (nd.reg < 0) {
        // Lives in its home slot already.
    } else if (nd.rep == OptRep.VALUE) {
        self.store_value_node(nd, slot, nd.reg, shade);
    } else if (nd.rep == OptRep.INT32) {
        sljit_emit_op2(c, SLJIT_AND, R0, 0, nd.reg, 0, SLJIT_IMM, PAYLOAD_SPAN - 1);
        sljit_emit_op2(c, SLJIT_OR, R0, 0, R0, 0, k_int_op(), k_int_w());
        self.a.store(slot, R0);
    } else {
        self.store_flt(slot, nd.reg);
    }
}

// The dirty registers `first`..+`count` stored, with one test of the collector's mark for the
// VALUE nodes among them that store_value_node would mark: those in a machine register, and `this`.
fn void OptCg.store_dirty(&self, uint first, uint count) {
    uint unshaded = 0;
    for (uint k = 0; k < count; k++) {
        OptDirty d = self.g.dirty[(sz)(first + k)];
        self.store_node(d.node, d.reg, false);
        if (self.batch_shaded(d.node)) unshaded++;
    }
    if (unshaded == 0) return;
    void* quiet = self.not_marking();
    for (uint k = 0; k < count; k++) {
        uint n = self.g.dirty[(sz)(first + k)].node;
        if (self.batch_shaded(n)) self.shade(self.value_reg(n, R0));
    }
    sljit_set_label(quiet, sljit_emit_label(self.a.c));
}

// Whether store_dirty marks node `n` after storing it (store_value_node with no `shade`).
fn bool OptCg.batch_shaded(&self, uint n) {
    OptNode* nd = &self.g.nodes[n];
    return (nd.reg >= 0 || nd.op == OptOp.THIS) && self.g.unshaded(nd);
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
    sljit_emit_op2(c, SLJIT_OR, R1, 0, R1, 0, k_int_op(), k_int_w());
    self.a.store(nd.home, R1);
}

// The result of VALUE node `n`, computed into register `src`.
fn void OptCg.def_value(&self, uint n, int src) {
    OptNode* nd = &self.g.nodes[n];
    if (nd.reg >= 0) {
        if (nd.reg != src) sljit_emit_op1(self.a.c, SLJIT_MOV, nd.reg, 0, src, 0);
        return;
    }
    self.store_value_node(nd, nd.home, src);
}

// The result of boolean node `n`: `yes` when the jump `taken` is, else `no`.
fn void OptCg.def_bool(&self, uint n, void* taken, long yes, long no) {
    void* c = self.a.c;
    int dst = self.int_dst(n, R0);
    sljit_emit_op1(c, SLJIT_MOV, dst, 0, SLJIT_IMM, no);
    void* done = sljit_emit_jump(c, SLJIT_JUMP);
    sljit_set_label(taken, sljit_emit_label(c));
    sljit_emit_op1(c, SLJIT_MOV, dst, 0, SLJIT_IMM, yes);
    sljit_set_label(done, sljit_emit_label(c));
    self.def_value(n, dst);
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

// Make the baseline emitter's current function the graph's `fidx`, whose bytecode a node's pc and
// imm index. A no-op for the function being compiled.
fn void OptCg.use_fn(&self, uint fidx) {
    CompiledFunction* f = self.g.fns[fidx].f;
    if (self.a.f != f) self.a.f = f;
}

// The instruction of node `n` as the baseline emitter decodes it: for a node of an inlined body
// the callee's, with its registers shifted to the caller's window.
fn void OptCg.decode(&self, OptNode* n) {
    self.a.decode((uint)n.imm);
    if (n.fidx != 0) {
        uint mask = inline_reg_mask(self.a.w.op);
        uint base = self.g.fns[n.fidx].reg_base;
        if ((mask & 1) != 0) self.a.w.a += base;
        if (n.pc == self.g.fns[n.fidx].remap_pc) self.a.w.a = self.g.fns[n.fidx].remap_reg;
        if ((mask & 2) != 0) self.a.w.b += base;
        if ((mask & 4) != 0) self.a.w.c += base;
    }
}

// --- Exits ---

fn void OptCg.exit_at(&self, void* jump, uint node, OptExit reason) {
    OptNode* n = &self.g.nodes[node];
    self.exits.push({ .jump = jump, .pc = n.pc, .fidx = n.fidx, .dirty_first = n.dirty_first, .dirty_count = n.dirty_count, .reason = (uint)reason.ordinal, .mask = n.live_mask, .node = node });
}

fn void OptCg.exit_clean_dirty(&self, void* jump, uint pc, uint first, uint count, OptExit reason) {
    self.exits.push({ .jump = jump, .pc = pc, .dirty_first = first, .dirty_count = count, .reason = (uint)reason.ordinal, .node = NO_NODE });
}

// An exit to the baseline code at `pc` with nothing to store: the window holds every value.
fn void OptCg.exit_clean(&self, void* jump, uint pc, OptExit reason) {
    self.exits.push({ .jump = jump, .pc = pc, .dirty_first = 0, .dirty_count = 0, .reason = (uint)reason.ordinal, .node = NO_NODE });
}

// An exit at node `i` with nothing to store: the window holds every value. From an inlined body it
// publishes the frames the node is nested in.
fn void OptCg.exit_stored(&self, void* jump, uint i, OptExit reason) {
    OptNode* n = &self.g.nodes[i];
    self.exits.push({ .jump = jump, .pc = n.pc, .fidx = n.fidx, .reason = (uint)reason.ordinal, .mask = n.live_mask, .node = NO_NODE });
}

// Every jump the helpers collected in `call` leaves for the baseline code at `pc`, with nothing to
// store.
fn void OptCg.exit_calls_clean(&self, uint pc, OptExit reason) {
    for (uint k = 0; k < self.a.call.len; k++) self.exit_clean(self.a.call.at[k], pc, reason);
    self.a.call.len = 0;
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
            if (x.pc != e.pc || x.fidx != e.fidx || x.dirty_first != e.dirty_first || x.reason != e.reason || x.mask != e.mask) break;
            if (x.node != e.node && self.g.mats.len() != 0) break;
            sljit_set_label(x.jump, label);
            i++;
        }
        self.store_dirty(e.dirty_first, e.dirty_count);
        self.materialize(e.node);
        self.use_fn(e.fidx);
        self.a.i = e.pc;
        if (e.fidx != 0) {
            self.emit_inline_exit(e.fidx, e.pc, e.mask, e.reason, false);
        } else {
            self.a.emit_opt_exit(self.oc, e.reason, false);
        }
    }
}

// The exit of an inlined body at its callee's word `pc` (the dirty registers already stored):
// publish the frames of the calls it is nested in (opt_inline_exit) and continue in the
// innermost callee's baseline code. With `counted`
// it is the test hook, which takes the exit `oc.forced` times and then falls through.
fn void OptCg.emit_inline_exit(&self, uint fidx, uint pc, uint mask, uint reason, bool counted) {
    void* c = self.a.c;
    // The frames from the innermost out: each one's caller is its entry's parent.
    uint depth = self.g.fns[fidx].depth;
    OptInlineExit* site = self.h.alloc_func(self.h.heap_udata, OptInlineExit::size + depth * OptInlineFrame::size);
    site.depth = depth;
    site.pc = pc;
    uint keep = mask;
    uint at = fidx;
    for (uint level = depth; level > 0; level--) {
        OptFn* fn_ = &self.g.fns[at];
        site.frames[level - 1] = { .callee = fn_.f, .resume = self.g.fns[fn_.parent].f.code + fn_.resume_pc,
                                   .base = fn_.reg_base, .nargs = fn_.f.num_formals, .argc = fn_.nargs, .keep = keep };
        keep = fn_.parent_keep;
        at = fn_.parent;
    }
    site.next = self.oc.inline_exits;
    self.oc.inline_exits = site;
    void* skip = null;
    if (counted) {
        sljit_emit_op1(c, SLJIT_MOV, R0, 0, SLJIT_IMM, (long)(usz)&self.oc.forced);
        sljit_emit_op1(c, SLJIT_MOV_U32, R1, 0, SLJIT_MEM | R0, 0);
        skip = sljit_emit_cmp(c, SLJIT_EQUAL, R1, 0, SLJIT_IMM, 0);
        sljit_emit_op2(c, SLJIT_SUB, R1, 0, R1, 0, SLJIT_IMM, 1);
        sljit_emit_op1(c, SLJIT_MOV_U32, SLJIT_MEM | R0, 0, R1, 0);
    }
    sljit_emit_op1(c, SLJIT_MOV, R0, 0, self.a.ds, 0);
    sljit_emit_op1(c, SLJIT_MOV, R1, 0, SLJIT_IMM, (long)(usz)self.oc);
    sljit_emit_op1(c, SLJIT_MOV, R2, 0, SLJIT_IMM, (long)reason);
    sljit_emit_op1(c, SLJIT_MOV, R3, 0, SLJIT_IMM, (long)(usz)site);
    self.a.c_call(SLJIT_ARGS4WWWW, SLJIT_IMM, (long)(usz)&opt_inline_exit);
    sljit_emit_ijump(c, SLJIT_JUMP, R0, 0);
    if (skip != null) sljit_set_label(skip, sljit_emit_label(c));
}

// --- Edges ---

fn void OptCg.emit_item(&self, OptMoveItem* m) {
    void* c = self.a.c;
    OptNode* d = &self.g.nodes[m.dst];
    OptNode* s = &self.g.nodes[m.src];
    bool is_const = s.is_const();
    if (d.rep == OptRep.VALUE) {
        if (is_const) {
            int r = self.value_reg(m.src, d.reg);
            if (r != d.reg) sljit_emit_op1(c, SLJIT_MOV, d.reg, 0, r, 0);
        } else if (m.src_reg >= 0) {
            sljit_emit_op1(c, SLJIT_MOV, d.reg, 0, m.src_reg, 0);
        } else {
            self.a.load(d.reg, s.home);
        }
    } else if (d.rep == OptRep.INT32) {
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

// The budget and interrupt poll of a back edge to block `target`. Its slow path
// runs out of line (emit_poll_stubs).
fn void OptCg.emit_poll(&self, uint target) {
    self.a.call.len = 0;
    self.a.back_edge();
    OptPoll p = { .jump_count = self.a.call.len, .target = target };
    for (uint k = 0; k < p.jump_count; k++) p.jumps[k] = self.a.call.at[k];
    self.a.call.len = 0;
    p.resume = sljit_emit_label(self.a.c);
    self.polls.push(p);
}

// The slow path of each poll: store the registers the header holds in the
// window, as the garbage collector reads it there, call opt_poll preserving
// the registers in use, and resume the loop or, when a hook is installed,
// leave for the baseline code at the header. A loop of an inlined body polls from records of the
// bodies' frames, as a call from one is made (emit_call_reg), so that the collector reads their
// windows; the slots of those that hold nothing live are cleared first.
fn void OptCg.emit_poll_stubs(&self) {
    Asm* a = self.a;
    void* c = a.c;
    CallLayout* k = call_layout();
    foreach (&p : self.polls) {
        OptBlock* h = &self.g.blocks[p.target];
        void* label = sljit_emit_label(c);
        for (uint j = 0; j < p.jump_count; j++) sljit_set_label(p.jumps[j], label);
        self.store_dirty(h.entry_first, h.entry_count);
        uint records = h.fidx == 0 ? 0 : self.g.fns[h.fidx].depth;
        for (uint d = 0; d < h.dead_count; d++) a.store(self.g.dirty[(sz)(h.dead_first + d)].reg, SLJIT_IMM, K_UNDEF);
        long off = CALL_FRAME_BYTES;
        for (int j = 0; j < self.pools.int_count; j++, off += 8) {
            sljit_emit_op1(c, SLJIT_MOV, SLJIT_MEM | reg_sp(), off, self.pools.int_first + j, 0);
        }
        for (int j = 0; j < self.pools.flt_count; j++, off += 8) {
            sljit_emit_fop1(c, SLJIT_MOV_F64, SLJIT_MEM | reg_sp(), off, self.pools.flt_first + j, 0);
        }
        if (records != 0) self.push_records(h.fidx);
        sljit_emit_op1(c, SLJIT_MOV, R1, 0, SLJIT_IMM, (long)(usz)self.g.fns[h.fidx].f.code + (long)h.pc * Instruction::size);
        if (records != 0) a.mov(SLJIT_MEM | a.la, k.act_curr_pc, R1, 0);
        sljit_emit_op1(c, SLJIT_MOV, SLJIT_MEM | a.ds, a.pc_off, R1, 0);
        sljit_emit_op1(c, SLJIT_MOV, R0, 0, a.ds, 0);
        a.c_call(SLJIT_ARGS1WW, SLJIT_IMM, (long)(usz)&opt_poll);
        sljit_emit_op1(c, SLJIT_MOV, R4, 0, R0, 0);
        if (records != 0) {
            // As after a call from a body: the VM's frame state names a record popped now.
            sljit_emit_op2(c, SLJIT_SUB, a.la, 0, a.la, 0, SLJIT_IMM, (long)records * Activation::size);
            void* below = sljit_emit_cmp(c, SLJIT_LESS_EQUAL, SLJIT_MEM | a.ds, a.lay.ds_act, a.la, 0);
            a.mov(SLJIT_MEM | a.ds, a.lay.ds_act, SLJIT_IMM, 0);
            sljit_set_label(below, sljit_emit_label(c));
            a.mov(a.regs, 0, SLJIT_MEM | a.la, k.act_bottom);
        }
        off = CALL_FRAME_BYTES;
        for (int j = 0; j < self.pools.int_count; j++, off += 8) {
            sljit_emit_op1(c, SLJIT_MOV, self.pools.int_first + j, 0, SLJIT_MEM | reg_sp(), off);
        }
        for (int j = 0; j < self.pools.flt_count; j++, off += 8) {
            sljit_emit_fop1(c, SLJIT_MOV_F64, self.pools.flt_first + j, 0, SLJIT_MEM | reg_sp(), off);
        }
        void* leave = sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R4, 0, SLJIT_IMM, 0);
        if (records != 0) {
            self.exits.push({ .jump = leave, .pc = h.pc, .fidx = h.fidx, .reason = (uint)OptExit.INTERRUPT.ordinal, .mask = h.live_mask, .node = NO_NODE });
        } else {
            self.exit_clean_dirty(leave, h.pc, h.entry_first, h.entry_count, OptExit.INTERRUPT);
        }
        sljit_set_label(sljit_emit_jump(c, SLJIT_JUMP), p.resume);
    }
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

// --- Entry from baseline code ---

// The entry of an OSR block: every numeric node live at its start is loaded
// from the window, guarded by the type the graph assumes.
fn void OptCg.emit_osr_entries(&self, void* to_base) {
    void* c = self.a.c;
    for (uint pos = 0; pos < self.g.blocks.len(); pos++) {
        OptBlock* blk = &self.g.blocks[pos];
        if (!blk.osr) continue;
        self.osr_labels[pos] = sljit_emit_label(c);
        self.emit_room_test(to_base);
        self.emit_cap_refs();
        self.emit_entry_facts(blk);
        for (uint k = 0; k < blk.osr_count; k++) {
            OptDirty d = self.g.dirty[(sz)(blk.osr_first + k)];
            OptNode* n = &self.g.nodes[d.node];
            // A spilled value is in its slot already.
            if (n.reg < 0) continue;
            if (n.rep == OptRep.VALUE) {
                // Whatever the baseline code left there, as the bytecode computed it.
                self.a.load(n.reg, d.reg);
            } else if (n.rep == OptRep.INT32) {
                self.a.load(R0, d.reg);
                self.int32_from_r0(d.reg);
                self.exit_calls_clean(blk.pc, OptExit.NOT_INT32);
                sljit_emit_op1(c, SLJIT_MOV, n.reg, 0, R0, 0);
            } else {
                self.a.load_number(n.reg, d.reg);
                self.exit_calls_clean(blk.pc, OptExit.NOT_NUMBER);
            }
        }
        self.gotos.push({ .jump = sljit_emit_jump(c, SLJIT_JUMP), .block = pos });
    }
}

// What the code of the loop an OSR entry enters assumes at its start (OptBuild.head_facts), proved
// for the frame the baseline code hands over before any value is loaded: the registers' objects
// (OptEntryFact), the folded bindings and the closure's capture records. A failure continues in the
// baseline code.
fn void OptCg.emit_entry_facts(&self, OptBlock* blk) {
    Asm* a = self.a;
    a.call.len = 0;
    for (uint k = 0; k < blk.fact_count; k++) {
        OptEntryFact fact = self.g.entry_facts[(sz)(blk.fact_first + k)];
        if (fact.reg == OPT_THIS) {
            a.load_this(R0);
        } else {
            a.load(R0, fact.reg);
        }
        a.unbox_object(R1, R0);
        if (fact.shape != heap::SHAPE_NONE) self.guard_shape(R1, fact.shape);
        if (fact.plain) self.guard_plain(R1);
        if (fact.elem != 0) a.call.add(a.array_or_typed(fact.elem == ELEM_ARRAY_STORE ? a.lay.indexed_named_mask : 0));
        self.exit_calls_clean(blk.pc, OptExit.ENTRY);
    }
    for (uint k = 0; k < 64; k++) {
        if ((blk.bindings & (1UL << k)) == 0) continue;
        self.binding_tests(1UL << k);
        self.exit_calls_clean(blk.pc, OptExit.ENTRY);
    }
    for (uint k = 0; k < 64; k++) {
        if ((blk.captures & (1UL << k)) == 0) continue;
        self.capture_tests(k);
        self.exit_calls_clean(blk.pc, OptExit.CAPTURE);
    }
    self.shade_bindings(blk.bindings, 0);
}

// An entry through the table, into a frame that is published: without the room the inlined bodies'
// exits need (Asm.room_acts, room_slots), the frame continues in the baseline code at `to_base`.
fn void OptCg.emit_room_test(&self, void* to_base) {
    Asm* a = self.a;
    if (a.room_acts == 0) return;
    void* c = a.c;
    CallLayout* k = call_layout();
    int m = SLJIT_MEM;
    sljit_emit_op1(c, SLJIT_MOV, R0, 0, m | a.ds, k.ds_vm);
    sljit_set_label(a.emit_record_room(a.la, R0, R1), to_base);
    sljit_emit_op2(c, SLJIT_ADD, R1, 0, a.regs, 0, SLJIT_IMM, (long)a.room_slots * TVal::size);
    sljit_set_label(sljit_emit_cmp(c, SLJIT_GREATER, R1, 0, m | R0, k.vm_valstack_end), to_base);
}

// --- Nodes ---

fn bool OptCg.force_here(&self, OptNode* n) {
    OptPolicy* p = &self.h.opt;
    return self.oc != null && p.force_reason != 0 && !self.forced_done && n.pc >= p.force_at && (!p.force_inline || (n.fidx != 0 && self.g.fns[n.fidx].depth >= p.force_depth));
}

// The int32 value of the number in R0, into R0: a fastint in the int32 range, or a double that
// holds an int32 other than -0 (an integer computed in doubles, which the baseline keeps boxed as
// one). Any other value jumps through the assembler's slow path list. With `slot`, the window slot
// the value was read from, a converted double is written back there as the fastint: the node that
// reads the slot takes it for holding its value unboxed (a reload after a call, an exit's frame).
// Uses R1, R3, FR0 and FR1.
fn void OptCg.int32_from_r0(&self, uint slot = uint::max) {
    void* c = self.a.c;
    // The fastint is tested first: its path runs nothing of the double's.
    sljit_emit_op2(c, SLJIT_ASHR, R3, 0, R0, 0, SLJIT_IMM, 48);
    void* fastint = sljit_emit_cmp(c, SLJIT_EQUAL, R3, 0, SLJIT_IMM, STAG_INT);
    self.a.call.add(sljit_emit_cmp(c, SLJIT_GREATER_EQUAL, R0, 0, k_int_op(), k_int_w()));
    sljit_emit_fcopy(c, SLJIT_COPY_TO_F64, FR0, R0);
    sljit_emit_fop1(c, SLJIT_CONV_SW_FROM_F64, R1, 0, FR0, 0);
    sljit_emit_op1(c, SLJIT_MOV_S32, R3, 0, R1, 0);
    self.a.call.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R3, 0, R1, 0));
    sljit_emit_fop1(c, SLJIT_CONV_F64_FROM_SW, FR1, 0, R1, 0);
    self.a.call.add(sljit_emit_fcmp(c, SLJIT_UNORDERED_OR_NOT_EQUAL, FR0, 0, FR1, 0));
    // -0 converts to 0 and back to +0, which compares equal.
    void* nonzero = sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R1, 0, SLJIT_IMM, 0);
    self.a.call.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R0, 0, SLJIT_IMM, 0));
    sljit_set_label(nonzero, sljit_emit_label(c));
    sljit_emit_op1(c, SLJIT_MOV, R0, 0, R1, 0);
    if (slot != uint::max) {
        sljit_emit_op2(c, SLJIT_SHL, R3, 0, R1, 0, SLJIT_IMM, 16);
        self.a.box_shifted(R3);
        self.a.store(slot, R3, 0);
    }
    void* done = sljit_emit_jump(c, SLJIT_JUMP);
    sljit_set_label(fastint, sljit_emit_label(c));
    sljit_emit_op2(c, SLJIT_SHL, R0, 0, R0, 0, SLJIT_IMM, 16);
    sljit_emit_op2(c, SLJIT_ASHR, R0, 0, R0, 0, SLJIT_IMM, 16);
    sljit_emit_op1(c, SLJIT_MOV_S32, R1, 0, R0, 0);
    self.a.call.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R1, 0, R0, 0));
    sljit_set_label(done, sljit_emit_label(c));
}

fn void OptCg.emit_check_int(&self, uint i, OptNode* n) {
    void* c = self.a.c;
    self.a.call.len = 0;
    self.a.load(R0, (uint)n.imm);
    self.int32_from_r0((uint)n.imm);
    self.exit_calls(i, OptExit.NOT_INT32);
    if (n.reg >= 0) sljit_emit_op1(c, SLJIT_MOV, n.reg, 0, R0, 0);
}

fn void OptCg.emit_check_num(&self, uint i, OptNode* n) {
    self.a.call.len = 0;
    int dst = n.reg >= 0 ? n.reg : FR0;
    self.a.load_number(dst, (uint)n.imm);
    self.exit_calls(i, OptExit.NOT_NUMBER);
    if (n.reg < 0) self.store_flt(n.home, dst);
}

// A double from the value in R0, which must be a number (exit NOT_NUMBER): into `fr`.
fn void OptCg.number_from_r0(&self, uint i, int fr) {
    void* c = self.a.c;
    void* not_double = sljit_emit_cmp(c, SLJIT_GREATER_EQUAL, R0, 0, k_int_op(), k_int_w());
    sljit_emit_fcopy(c, SLJIT_COPY_TO_F64, fr, R0);
    void* done = sljit_emit_jump(c, SLJIT_JUMP);
    sljit_set_label(not_double, sljit_emit_label(c));
    sljit_emit_op2(c, SLJIT_ASHR, R1, 0, R0, 0, SLJIT_IMM, 48);
    self.exit_at(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R1, 0, SLJIT_IMM, STAG_INT), i, OptExit.NOT_NUMBER);
    sljit_emit_op2(c, SLJIT_SHL, R0, 0, R0, 0, SLJIT_IMM, 16);
    sljit_emit_op2(c, SLJIT_ASHR, R0, 0, R0, 0, SLJIT_IMM, 16);
    sljit_emit_fop1(c, SLJIT_CONV_F64_FROM_SW, fr, 0, R0, 0);
    sljit_set_label(done, sljit_emit_label(c));
}

// The number in R0 as node `n`'s value, leaving for the baseline code when it is not of the
// node's kind. The jumps pending in the assembler's slow path list go to the same exit.
fn void OptCg.def_from_r0(&self, uint i, OptNode* n) {
    void* c = self.a.c;
    if (n.rep == OptRep.INT32) {
        self.int32_from_r0();
        self.exit_calls(i, OptExit.NOT_INT32);
        self.def_int(i, R0);
    } else {
        int dst = self.flt_dst(i, FR0);
        self.number_from_r0(i, dst);
        self.def_flt(i, dst);
    }
}

// GETGLOBAL of an inlined body as a number or a VALUE node: the baseline's cached read, leaving for the baseline
// code on the slow cases and on a value that is not of the node's kind.
fn void OptCg.emit_load_global(&self, uint i, OptNode* n) {
    Asm* a = self.a;
    a.decode((uint)n.imm);
    a.call.len = 0;
    a.alt.len = 0;
    long vic = (long)(usz)&((hobject::VarICEntry*)a.f.var_ic_entries)[a.next - 1];
    // A GETVAR (cc nonzero) is read through the scope of its body's closure.
    uint creg = uint::max;
    int closure = -1;
    if (n.cc != 0) {
        creg = self.g.fns[n.fidx].reg_base - 2;
        closure = n.b != NO_NODE ? self.value_reg(n.b, R3) : -1;
    }
    a.var_slot(vic, n.cc != 0, creg, closure);
    if (n.cc != 0) {
        sljit_emit_op1(self.a.c, SLJIT_MOV_U8, R1, 0, SLJIT_MEM | R2, a.lay.vic_flags);
        sljit_emit_op2(self.a.c, SLJIT_AND, R1, 0, R1, 0, SLJIT_IMM, a.lay.accessor_mask);
        a.call.add(sljit_emit_cmp(self.a.c, SLJIT_NOT_EQUAL, R1, 0, SLJIT_IMM, 0));
    }
    sljit_emit_op1(self.a.c, SLJIT_MOV, R0, 0, SLJIT_MEM | R0, 0);
    // A binding in its TDZ is no number: the numeric test below leaves for it too.
    if (n.rep == OptRep.VALUE) a.guard_not_tdz();
    for (uint k = 0; k < a.alt.len; k++) self.exit_at(a.alt.at[k], i, OptExit.SLOW_PATH);
    a.alt.len = 0;
    self.exit_calls(i, OptExit.SLOW_PATH);
    if (n.rep == OptRep.VALUE) {
        self.finish_value(i, n);
    } else {
        self.def_from_r0(i, n);
    }
}

// STORE_GLOBAL and STEP_GLOBAL: the baseline's global store path (Asm.global_store_slot), its
// misses exits, then the store of the value or of the stepped fastint.
fn void OptCg.emit_store_global(&self, uint i, OptNode* n) {
    void* c = self.a.c;
    Asm* a = self.a;
    a.decode((uint)n.imm);
    a.call.len = 0;
    a.global_store_slot((long)(usz)&((hobject::VarICEntry*)a.f.var_ic_entries)[a.next - 1]);
    if (n.op == OptOp.STORE_GLOBAL) {
        self.exit_calls(i, OptExit.SLOW_PATH);
        sljit_emit_op1(c, SLJIT_MOV, R1, 0, SLJIT_MEM | R2, a.lay.vic_bindings);
        self.store_slot_value(i, n.a, a.w.a);
        return;
    }
    sljit_emit_op1(c, SLJIT_MOV, R1, 0, SLJIT_MEM | R0, 0);
    a.guard_int(R1);
    sljit_emit_op2(c, SLJIT_SHL, R1, 0, R1, 0, SLJIT_IMM, 16);
    sljit_emit_op2(c, SLJIT_ADD | SLJIT_SET_OVERFLOW, R1, 0, R1, 0, SLJIT_IMM, (a.w.op == Opcode.INC_GLOBAL ? 1L : -1L) << 16);
    a.call.add(sljit_emit_jump(c, SLJIT_OVERFLOW));
    self.exit_calls(i, OptExit.SLOW_PATH);
    a.box_shifted(R1);
    sljit_emit_op1(c, SLJIT_MOV, SLJIT_MEM | R0, 0, R1, 0);
    self.def_value(i, R1);
}

// GETCAP as a number: the baseline's capture read, leaving for the baseline code on the slow
// cases and on a value that is not of the node's kind.
fn void OptCg.emit_load_cap(&self, uint i, OptNode* n) {
    self.decode(n);
    self.a.call.len = 0;
    uint index = self.a.w.get_bc();
    if (n.fidx != 0) {
        // An inlined body reads the callee's closure, which the call's guard checked in its register.
        OptFn* fn_ = &self.g.fns[n.fidx];
        // A nested call's closure may be held in a VALUE node (b) instead.
        int closure = n.b != NO_NODE ? self.value_reg(n.b, R3) : -1;
        self.a.emit_get_cap_value_of(index, fn_.reg_base - 2, fn_.f.capture_count, closure);
    } else if (self.cap_slot >= 0 && index < self.a.f.capture_count) {
        // The records the entry loaded; zero when the closure was not one the check accepts.
        void* c = self.a.c;
        sljit_emit_op1(c, SLJIT_MOV, R1, 0, SLJIT_MEM | reg_sp(), self.cap_slot);
        self.a.call.add(sljit_emit_cmp(c, SLJIT_EQUAL, R1, 0, SLJIT_IMM, 0));
        if (index != 0) sljit_emit_op2(c, SLJIT_ADD, R1, 0, R1, 0, SLJIT_IMM, (long)index * hobject::CaptureRef::size);
        self.a.emit_cap_record_value();
    } else {
        self.a.emit_get_cap_value(index);
    }
    self.exit_calls(i, OptExit.SLOW_PATH);
    if (n.rep == OptRep.NONE) {
        self.publish(i, self.a.w.a);
    } else if (n.rep == OptRep.VALUE) {
        self.finish_value(i, n);
    } else {
        self.def_from_r0(i, n);
    }
}

// Load the running closure's capture records into the cap_slot, as the capture record subroutine
// finds them for every read (Asm.emit_capture_ref_body): zero unless the frame's function value is
// a closure of the function being run that has records. The count is the function's own, which
// the reads check when they are compiled. Uses R0, R1 and R3.
fn void OptCg.emit_cap_refs(&self) {
    if (self.cap_slot < 0) return;
    void* c = self.a.c;
    Layout* l = self.a.lay;
    Jumps fail;
    self.a.reads_callee = true;
    sljit_emit_op1(c, SLJIT_MOV, R0, 0, SLJIT_MEM | self.a.la, l.act_tv_func);
    sljit_emit_op2(c, SLJIT_XOR, R3, 0, R0, 0, k_obj_op(), k_obj_w());
    fail.add(sljit_emit_cmp(c, SLJIT_GREATER_EQUAL, R3, 0, span_op(), span_w()));
    sljit_emit_op1(c, SLJIT_MOV, R0, 0, SLJIT_MEM | R3, l.fn_capture_refs);
    sljit_emit_op1(c, SLJIT_MOV, R3, 0, SLJIT_MEM | R3, l.fn_comp_func);
    fail.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R3, 0, SLJIT_MEM | self.a.la, l.act_func));
    void* done = sljit_emit_jump(c, SLJIT_JUMP);
    fail.bind(sljit_emit_label(c));
    sljit_emit_op1(c, SLJIT_MOV, R0, 0, SLJIT_IMM, 0);
    sljit_set_label(done, sljit_emit_label(c));
    sljit_emit_op1(c, SLJIT_MOV, SLJIT_MEM | reg_sp(), self.cap_slot, R0, 0);
}

// INT32 node `n` boxed as a fastint into R3.
fn void OptCg.box_index(&self, uint n) {
    void* c = self.a.c;
    int r = self.int_reg(n, R3);
    sljit_emit_op2(c, SLJIT_AND, R3, 0, r, 0, SLJIT_IMM, PAYLOAD_SPAN - 1);
    sljit_emit_op2(c, SLJIT_OR, R3, 0, R3, 0, k_int_op(), k_int_w());
}

// The address in R0 of the element at INT32 node `idx` of the array in R1, as the array slot
// subroutine finds it for a boxed index (Asm.emit_array_slot_body); an index out of range leaves
// through the slow path. Uses R2 and R3; returns the index register.
fn int OptCg.array_slot(&self, uint idx) {
    void* c = self.a.c;
    Layout* l = self.a.lay;
    int x = self.int_reg(idx, R3);
    sljit_emit_op1(c, SLJIT_MOV_U32, R2, 0, SLJIT_MEM | R1, l.obj_array_size);
    // Unsigned, so a negative index fails too.
    self.a.call.add(sljit_emit_cmp(c, SLJIT_GREATER_EQUAL, x, 0, R2, 0));
    // The dense part follows the property values.
    sljit_emit_op1(c, SLJIT_MOV_U32, R2, 0, SLJIT_MEM | R1, l.obj_prop_capacity);
    sljit_emit_op2(c, SLJIT_ADD, R2, 0, R2, 0, x, 0);
    sljit_emit_op2(c, SLJIT_SHL, R2, 0, R2, 0, SLJIT_IMM, 3);
    sljit_emit_op1(c, SLJIT_MOV, R0, 0, SLJIT_MEM | R1, l.obj_props);
    sljit_emit_op2(c, SLJIT_ADD, R0, 0, R0, 0, R2, 0);
    return x;
}

// The boxed value of number node `n`, or the constant of STORE_CONST `n`, in `dst`.
fn void OptCg.box_node(&self, uint n, int dst) {
    void* c = self.a.c;
    OptNode* nd = &self.g.nodes[n];
    if (nd.op == OptOp.STORE_CONST || nd.op == OptOp.CONST_OBJ) {
        sljit_emit_op1(c, SLJIT_MOV, dst, 0, SLJIT_IMM, nd.imm);
    } else if (nd.op == OptOp.CONST_I32) {
        sljit_emit_op1(c, SLJIT_MOV, dst, 0, SLJIT_IMM, K_INT | (nd.imm & (PAYLOAD_SPAN - 1)));
    } else if (nd.op == OptOp.CONST_F64) {
        sljit_emit_op1(c, SLJIT_MOV, dst, 0, SLJIT_IMM, nd.imm);
    } else if (nd.reg < 0) {
        self.a.load(dst, nd.home);
    } else if (nd.rep == OptRep.INT32) {
        sljit_emit_op2(c, SLJIT_AND, dst, 0, nd.reg, 0, SLJIT_IMM, PAYLOAD_SPAN - 1);
        sljit_emit_op2(c, SLJIT_OR, dst, 0, dst, 0, k_int_op(), k_int_w());
    } else {
        sljit_emit_fcopy(c, SLJIT_COPY_FROM_F64, nd.reg, dst);
        void* ok = sljit_emit_cmp(c, SLJIT_LESS, dst, 0, k_int_op(), k_int_w());
        sljit_emit_op1(c, SLJIT_MOV, dst, 0, SLJIT_IMM, CANONICAL_NAN);
        sljit_set_label(ok, sljit_emit_label(c));
    }
}

// LOAD_LENGTH: a string's or an array's length as emit_length reads it, as an INT32. Anything
// else, and a length above the int32 range, leaves for the baseline code.
fn void OptCg.emit_load_length(&self, uint i, OptNode* n) {
    void* c = self.a.c;
    Asm* a = self.a;
    Layout* l = a.lay;
    self.decode(n);
    a.call.len = 0;
    int rr = R0;
    if (n.b != NO_NODE) {
        rr = self.value_reg(n.b, R0);
    } else {
        a.load(R0, a.w.b);
    }
    sljit_emit_op2(c, SLJIT_XOR, R1, 0, rr, 0, SLJIT_IMM, K_STRING_START);
    void* not_string = sljit_emit_cmp(c, SLJIT_GREATER_EQUAL, R1, 0, span_op(), span_w());
    a.guard_flags_clear(R1, l.symbol_mask, R2);
    sljit_emit_op1(c, SLJIT_MOV_U32, R0, 0, SLJIT_MEM | R1, l.str_length);
    void* done = sljit_emit_jump(c, SLJIT_JUMP);
    sljit_set_label(not_string, sljit_emit_label(c));
    a.unbox_object(R1, rr);
    // The class test excludes a proxy, which has a class of its own.
    sljit_emit_op1(c, SLJIT_MOV_U32, R2, 0, SLJIT_MEM | R1, 0);
    sljit_emit_op2(c, SLJIT_AND, R2, 0, R2, 0, SLJIT_IMM, l.class_mask);
    a.call.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R2, 0, SLJIT_IMM, l.class_array));
    sljit_emit_op1(c, SLJIT_MOV_U32, R0, 0, SLJIT_MEM | R1, l.obj_array_len);
    a.call.add(sljit_emit_cmp(c, SLJIT_GREATER, R0, 0, SLJIT_IMM, 0x7FFFFFFF));
    sljit_set_label(done, sljit_emit_label(c));
    self.exit_calls(i, OptExit.SLOW_PATH);
    self.def_int(i, R0);
}

// GETPROP of an element as the baseline's emit_get_elem reads it, with the index in a node: a
// dense array's element or a typed array's. Everything else leaves for the baseline code.
fn void OptCg.emit_load_elem(&self, uint i, OptNode* n) {
    void* c = self.a.c;
    Asm* a = self.a;
    self.decode(n);
    a.call.len = 0;
    OptView view;
    if (self.const_view(n, false, &view)) {
        int x = self.const_elem(i, n.a, &view);
        self.emit_typed_load(i, n, TYPED_KINDS[view.kind], x);
        return;
    }
    int rr = R0;
    if (n.c != NO_NODE) {
        rr = self.value_reg(n.c, R0);
    } else {
        a.load(R0, a.w.b);
    }
    long flags;
    bool unseen;
    void* other = null;
    if ((n.cc & ELEM_KNOWN) != 0) {
        sljit_emit_op2(c, SLJIT_XOR, R1, 0, rr, 0, k_obj_op(), k_obj_w());
    } else {
        a.unbox_object(R1, rr);
        int k = self.typed_kind(0, &flags, &unseen);
        if (k >= 0) {
            int x = self.typed_elem_addr(n.a, TYPED_KINDS[k], flags, 0, false);
            self.exit_calls(i, OptExit.SLOW_PATH);
            self.emit_typed_load(i, n, TYPED_KINDS[k], x);
            return;
        }
        other = a.array_or_typed(0);
    }
    int x = self.array_slot(n.a);
    sljit_emit_op1(c, SLJIT_MOV, R0, 0, SLJIT_MEM | R0, 0);
    // An `undefined` leaves unless it is an element of a packed array.
    void* value = sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R0, 0, SLJIT_IMM, K_UNDEF);
    sljit_emit_op1(c, SLJIT_MOV_U32, R2, 0, SLJIT_MEM | R1, a.lay.obj_gc);
    sljit_emit_op2(c, SLJIT_AND, R2, 0, R2, 0, SLJIT_IMM, a.lay.packed_mask);
    a.call.add(sljit_emit_cmp(c, SLJIT_EQUAL, R2, 0, SLJIT_IMM, 0));
    sljit_emit_op1(c, SLJIT_MOV_U32, R2, 0, SLJIT_MEM | R1, a.lay.obj_array_len);
    a.call.add(sljit_emit_cmp(c, SLJIT_GREATER_EQUAL, x, 0, R2, 0));
    sljit_set_label(value, sljit_emit_label(c));
    if (other != null) {
        $if features::BUFFERS:
            void* done = sljit_emit_jump(c, SLJIT_JUMP);
            sljit_set_label(other, sljit_emit_label(c));
            if (unseen) {
                self.unprofiled_exit(i);
            } else {
                self.box_index(n.a);
                a.subs.push({ .jump = sljit_emit_jump(c, SLJIT_FAST_CALL), .sub = TYPED_GET_SUB });
                a.call.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R2, 0, SLJIT_IMM, SUB_TRUE));
            }
            sljit_set_label(done, sljit_emit_label(c));
        $else
            a.call.add(other);
        $endif
    }
    if ((n.cc & ELEM_STRING) != 0) self.string_elem(i, n);
    self.exit_calls(i, OptExit.SLOW_PATH);
    if (n.rep == OptRep.NONE) {
        self.publish(i, a.w.a);
        return;
    }
    if (n.rep == OptRep.VALUE) {
        self.finish_value(i, n);
        return;
    }
    self.def_from_r0(i, n);
}

// The jumps in a.call of element read `n` (cc ELEM_STRING) leaving with no element: a string
// receiver's unit (vm::jit_string_elem) into R0 where the value would be, else they leave.
fn void OptCg.string_elem(&self, uint i, OptNode* n) {
    Asm* a = self.a;
    void* c = a.c;
    if (a.call.len == 0) return;
    Jumps miss = a.call;
    a.call.len = 0;
    void* done = sljit_emit_jump(c, SLJIT_JUMP);
    miss.bind(sljit_emit_label(c));
    self.spill_live(i, true);
    int x = self.int_reg(n.a, R2);
    if (x != R2) sljit_emit_op1(c, SLJIT_MOV, R2, 0, x, 0);
    if (n.c != NO_NODE) {
        int rr = self.value_reg(n.c, R1);
        if (rr != R1) sljit_emit_op1(c, SLJIT_MOV, R1, 0, rr, 0);
    } else {
        a.load(R1, a.w.b);
    }
    sljit_emit_op1(c, SLJIT_MOV, R0, 0, a.heap, 0);
    a.c_call_frameless(SLJIT_ARGS3WWW, SLJIT_IMM, (long)(usz)&vm::jit_string_elem);
    self.spill_live(i, false);
    a.call.add(sljit_emit_cmp(c, SLJIT_EQUAL, R0, 0, SLJIT_IMM, 0));
    sljit_set_label(done, sljit_emit_label(c));
}

// The index into TYPED_KINDS of the typed array the element access being emitted has met, by the
// class flags its baseline code recorded (Asm.note_elem_class) under array_or_typed's mask with
// `extra`; -1 for none (an array, a proxy, Uint8Clamped stores, or no record). The flags the
// specialized access compares against go to `flags`. `unseen` is set when no class was recorded:
// the access has never met a receiver that is not an array.
fn int OptCg.typed_kind(&self, long extra, long* flags, bool* unseen) {
    *unseen = false;
$if features::BUFFERS:
    Asm* a = self.a;
    if (a.f.ic_entries == null) return -1;
    long recorded = (long)((hobject::ICEntry*)a.f.ic_entries)[a.next - 1].fwd_callee;
    *unseen = opt_elem_arrays_only(a.f, a.next - 1);
    recorded &= ~(long)ELEM_CLASS_SEEN;
    Layout* l = a.lay;
    long proxy = 0;
    $if features::PROXY:
        proxy = l.proxy_mask;
    $endif
    if (recorded == 0 || (recorded & proxy) != 0 || (recorded & ~(l.class_mask | extra | proxy)) != 0) return -1;
    long cls = (recorded & l.class_mask) >> 16;
    foreach (k, kind : TYPED_KINDS) {
        if ((long)kind.cls.ordinal != cls) continue;
        if (extra != 0 && kind.cls == hobject::ObjClass.UINT8CLAMPEDARRAY) return -1;
        *flags = recorded;
        return (int)k;
    }
    return -1;
$else
    return -1;
$endif
}

// At an element access with no recorded class, R2 holding the receiver's class flags as
// array_or_typed left them: record them, and leave for the baseline code (OptExit.UNPROFILED).
fn void OptCg.unprofiled_exit(&self, uint i) {
    void* c = self.a.c;
    Asm* a = self.a;
    hobject::ICEntry* entry = &((hobject::ICEntry*)a.f.ic_entries)[a.next - 1];
    sljit_emit_op2(c, SLJIT_OR, R2, 0, R2, 0, SLJIT_IMM, ELEM_CLASS_SEEN);
    sljit_emit_op1(c, SLJIT_MOV_U32, SLJIT_MEM, (long)(usz)&entry.fwd_callee, R2, 0);
    self.exit_at(sljit_emit_jump(c, SLJIT_JUMP), i, OptExit.UNPROFILED);
}

// The address of element `idx` (an INT32 node) of the object in R1, which must be a typed array of
// class flags `flags` (masked as typed_kind's) viewing a fixed-length, attached buffer, and the
// index below its length, as Asm.emit_typed_body checks: the base in R4 and the index register,
// returned (`put`: the buffer must be mutable too). Anything else jumps through the slow path
// list. Uses R2 to R4.
fn int OptCg.typed_elem_addr(&self, uint idx, TypedKind kind, long flags, long extra, bool put) {
    void* c = self.a.c;
    Asm* a = self.a;
    Layout* l = a.lay;
    long mask = l.class_mask | extra;
    $if features::PROXY:
        mask |= l.proxy_mask;
    $endif
    sljit_emit_op1(c, SLJIT_MOV_U32, R2, 0, SLJIT_MEM | R1, 0);
    sljit_emit_op2(c, SLJIT_AND, R2, 0, R2, 0, SLJIT_IMM, mask);
    a.call.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R2, 0, SLJIT_IMM, flags));
    sljit_emit_op1(c, SLJIT_MOV, R4, 0, SLJIT_MEM | R1, l.view_buffer);
    a.call.add(sljit_emit_cmp(c, SLJIT_EQUAL, R4, 0, SLJIT_IMM, 0));
    sljit_emit_op1(c, SLJIT_MOV_U8, R2, 0, SLJIT_MEM | R4, l.ab_resizable);
    a.call.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R2, 0, SLJIT_IMM, 0));
    if (put) {
        sljit_emit_op1(c, SLJIT_MOV_U8, R2, 0, SLJIT_MEM | R4, l.ab_immutable);
        a.call.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R2, 0, SLJIT_IMM, 0));
    }
    sljit_emit_op1(c, SLJIT_MOV, R4, 0, SLJIT_MEM | R4, l.ab_data);
    a.call.add(sljit_emit_cmp(c, SLJIT_EQUAL, R4, 0, SLJIT_IMM, 0));
    sljit_emit_op1(c, SLJIT_MOV_U32, R2, 0, SLJIT_MEM | R1, l.view_offset);
    sljit_emit_op2(c, SLJIT_ADD, R4, 0, R4, 0, R2, 0);
    sljit_emit_op1(c, SLJIT_MOV_U32, R2, 0, SLJIT_MEM | R1, l.view_length);
    if (kind.shift != 0) sljit_emit_op2(c, SLJIT_LSHR, R2, 0, R2, 0, SLJIT_IMM, kind.shift);
    int x = self.int_reg(idx, R3);
    // Unsigned, so a negative index fails too.
    a.call.add(sljit_emit_cmp(c, SLJIT_GREATER_EQUAL, x, 0, R2, 0));
    return x;
}

// The CONST_OBJ receiver of element access `n`, when its value is a typed array opt_const_view
// accepts, as `view`.
fn bool OptCg.const_view(&self, OptNode* n, bool store, OptView* view) {
    if (n.c == NO_NODE || self.g.nodes[n.c].op != OptOp.CONST_OBJ) return false;
    return opt_const_view((ulong)self.g.nodes[n.c].imm, store, view);
}

// The element at INT32 node `idx` of a constant view, whose store the guard of its binding has
// proven in place: the index register, checked against the view's length, with R4 the store.
fn int OptCg.const_elem(&self, uint i, uint idx, OptView* view) {
    void* c = self.a.c;
    int x = self.int_reg(idx, R3);
    // Unsigned, so a negative index fails too.
    self.exit_at(sljit_emit_cmp(c, SLJIT_GREATER_EQUAL, x, 0, SLJIT_IMM, view.length), i, OptExit.BOUNDS);
    sljit_emit_op1(c, SLJIT_MOV, R4, 0, SLJIT_IMM, (long)(usz)view.data);
    return x;
}

// LOAD_ELEM of a typed array of `kind`, whose store is in R4 and the checked index in `x`
// (OptCg.typed_elem_addr, OptCg.const_elem): the element read in place, without the subroutine's
// dispatch over kinds; an int32 or double node takes it unboxed.
fn void OptCg.emit_typed_load(&self, uint i, OptNode* n, TypedKind kind, int x) {
    void* c = self.a.c;
    Asm* a = self.a;
    int elem = mem_index(R4, x);
    bool is_float = kind.is_float();
    if (n.rep == OptRep.INT32 && !is_float && kind.cls != hobject::ObjClass.UINT32ARRAY) {
        sljit_emit_op1(c, kind.mov, R0, 0, elem, kind.shift);
        self.def_int(i, R0);
        return;
    }
    if (n.rep == OptRep.FLOAT64 && is_float) {
        int dst = self.flt_dst(i, FR0);
        bool f32 = kind.cls == hobject::ObjClass.FLOAT32ARRAY;
        sljit_emit_fop1(c, SLJIT_MOV_F64 | (f32 ? SLJIT_32 : 0), dst, 0, elem, kind.shift);
        if (f32) sljit_emit_fop1(c, SLJIT_CONV_F64_FROM_F32, dst, 0, dst, 0);
        self.def_flt(i, dst);
        return;
    }
    // The element boxed as ta_load_number boxes it, then as any loaded value.
    if (kind.cls == hobject::ObjClass.FLOAT32ARRAY) {
        sljit_emit_fop1(c, SLJIT_MOV_F64 | SLJIT_32, FR0, 0, elem, kind.shift);
        sljit_emit_fop1(c, SLJIT_CONV_F64_FROM_F32, FR0, 0, FR0, 0);
        sljit_emit_fcopy(c, SLJIT_COPY_FROM_F64, FR0, R0);
    } else {
        sljit_emit_op1(c, kind.mov, R0, 0, elem, kind.shift);
    }
    if (is_float) {
        // TVal.set_number: a NaN whose bits would read as a tag.
        void* plain = sljit_emit_cmp(c, SLJIT_LESS, R0, 0, k_int_op(), k_int_w());
        sljit_emit_op1(c, SLJIT_MOV, R0, 0, SLJIT_IMM, CANONICAL_NAN);
        sljit_set_label(plain, sljit_emit_label(c));
    } else {
        void* boxed = null;
        if (kind.cls == hobject::ObjClass.UINT32ARRAY) {
            // 2^31 and above reads as a double.
            void* small = sljit_emit_cmp(c, SLJIT_LESS, R0, 0, SLJIT_IMM, 1L << 31);
            sljit_emit_fop1(c, SLJIT_CONV_F64_FROM_SW, FR0, 0, R0, 0);
            sljit_emit_fcopy(c, SLJIT_COPY_FROM_F64, FR0, R0);
            boxed = sljit_emit_jump(c, SLJIT_JUMP);
            sljit_set_label(small, sljit_emit_label(c));
        }
        sljit_emit_op2(c, SLJIT_AND, R0, 0, R0, 0, SLJIT_IMM, PAYLOAD_SPAN - 1);
        sljit_emit_op2(c, SLJIT_OR, R0, 0, R0, 0, k_int_op(), k_int_w());
        if (boxed != null) sljit_set_label(boxed, sljit_emit_label(c));
    }
    if (n.rep == OptRep.NONE) {
        // A number, which needs no publication.
        a.store(a.w.a, R0);
        return;
    }
    // A number is an inert value, which a VALUE node holds as it is.
    if (n.rep == OptRep.VALUE) {
        self.def_value(i, R0);
        return;
    }
    self.def_from_r0(i, n);
}

// The value of STORE_ELEM `n` as a store to `kind` takes it, before the element's address takes R4:
// an int32 node in a register, whose low bits an integer kind stores, as ta_store_int; for a float
// kind the double (narrowed for Float32) in a float register, as ta_store_scalar.
fn int OptCg.typed_store_value(&self, OptNode* n, TypedKind kind) {
    void* c = self.a.c;
    if (!kind.is_float()) return self.int_reg(n.b, R0);
    int f32 = kind.cls == hobject::ObjClass.FLOAT32ARRAY ? SLJIT_32 : 0;
    if (self.g.nodes[n.b].rep == OptRep.INT32) {
        int r = self.int_reg(n.b, R0);
        sljit_emit_fop1(c, SLJIT_CONV_F64_FROM_SW | f32, FR0, 0, r, 0);
        return FR0;
    }
    int fr = self.flt_reg(n.b, FR0);
    if (f32 == 0) return fr;
    sljit_emit_fop1(c, SLJIT_CONV_F64_FROM_F32 | SLJIT_32, FR0, 0, fr, 0);
    return FR0;
}

// STORE_ELEM of the value `v` (OptCg.typed_store_value) into a typed array of `kind`, whose store
// is in R4 and the checked index in `x`.
fn void OptCg.emit_typed_store(&self, TypedKind kind, int v, int x) {
    int elem = mem_index(R4, x);
    if (!kind.is_float()) {
        sljit_emit_op1(self.a.c, kind.mov, elem, kind.shift, v, 0);
    } else {
        sljit_emit_fop1(self.a.c, SLJIT_MOV_F64 | (kind.cls == hobject::ObjClass.FLOAT32ARRAY ? SLJIT_32 : 0), elem, kind.shift, v, 0);
    }
}

// The id `shape` as the second operand of a 32-bit compare, its word in `w`. A shared shape is
// pinned, so its id never names another, and is compared as a constant. A private shape dies with
// its object: its id is read into R2 from a cell the heap clears when the id goes out of use.
fn int OptCg.shape_operand(&self, uint shape, long* w) {
    hobject::Shape* sh = self.h.get_shape(shape);
    if (sh != null && sh.parent != hobject::PRIVATE_SHAPE_PARENT) {
        sh.pinned = true;
        *w = (long)shape;
        return SLJIT_IMM;
    }
    uint* cell = &self.oc.cells[self.oc.cell_count++];
    *cell = shape;
    sljit_emit_op1(self.a.c, SLJIT_MOV_U32, R2, 0, SLJIT_MEM, (long)(usz)cell);
    *w = 0;
    return R2;
}

// The shape of the object in `obj` against `shape`, leaving for the baseline code on any other.
// Uses R2 and R3.
// The leave for the baseline code unless object `obj` is a plain object: class Object with no
// exotic or namespace flag. That holds for the object's life, and it passes Asm.guard_plain and the
// receiver tests of an inherited read (settled_chain_slots, select_chain_slot). Uses R2 and R3.
fn void OptCg.guard_plain(&self, int obj) {
    Layout* l = self.a.lay;
    sljit_emit_op1(self.a.c, SLJIT_MOV_U32, R2, 0, SLJIT_MEM | obj, 0);
    sljit_emit_op2(self.a.c, SLJIT_AND, R3, 0, R2, 0, SLJIT_IMM, l.class_mask | l.plain_exotic_mask | l.module_ns_mask | l.deferred_ns_mask);
    self.a.call.add(sljit_emit_cmp(self.a.c, SLJIT_NOT_EQUAL, R3, 0, SLJIT_IMM, l.class_object));
}

// guard_plain for a store, which a RegExp takes as ordinarily as a plain object: its lastIndex is
// an own data property. Uses R2 and R3.
fn void OptCg.guard_ordinary(&self, int obj) {
    Layout* l = self.a.lay;
    void* c = self.a.c;
    sljit_emit_op1(c, SLJIT_MOV_U32, R2, 0, SLJIT_MEM | obj, 0);
    sljit_emit_op2(c, SLJIT_AND, R3, 0, R2, 0, SLJIT_IMM, l.class_mask | l.plain_exotic_mask | l.module_ns_mask | l.deferred_ns_mask);
    void* plain = sljit_emit_cmp(c, SLJIT_EQUAL, R3, 0, SLJIT_IMM, l.class_object);
    self.a.call.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R3, 0, SLJIT_IMM, l.class_regexp));
    sljit_set_label(plain, sljit_emit_label(c));
}

// The receiver of field node `n`, boxed in `rr`, unboxed into R1: an object, which is tested
// unless the node knows it plain.
fn void OptCg.field_receiver(&self, OptNode* n, int rr) {
    if (n.plain) {
        sljit_emit_op2(self.a.c, SLJIT_XOR, R1, 0, rr, 0, k_obj_op(), k_obj_w());
    } else {
        self.a.unbox_object(R1, rr);
    }
}

fn void OptCg.guard_shape(&self, int obj, uint shape) {
    sljit_emit_op1(self.a.c, SLJIT_MOV_U32, R3, 0, SLJIT_MEM | obj, self.a.lay.obj_shape);
    long w;
    int op = self.shape_operand(shape, &w);
    self.a.call.add(sljit_emit_cmp(self.a.c, SLJIT_NOT_EQUAL | SLJIT_32, R3, 0, op, w));
}

// The slot address in R0 of the property of the plain object in R1, whose shape is one of those
// `p` names: the shapes are compared in order (shape_operand), and each has the slot its property
// has there. A shape none of them matches leaves for the
// baseline code. Uses R0 to R3.
fn void OptCg.select_slot(&self, OptPoly* p) {
    void* c = self.a.c;
    Asm* a = self.a;
    uint k = p.count;
    void*[OPT_POLY_MAX] hit;
    sljit_emit_op1(c, SLJIT_MOV_U32, R3, 0, SLJIT_MEM | R1, a.lay.obj_shape);
    for (uint i = 0; i < k; i++) {
        long w;
        int op = self.shape_operand(p.shape[i], &w);
        if (i + 1 < k) {
            hit[i] = sljit_emit_cmp(c, SLJIT_EQUAL | SLJIT_32, R3, 0, op, w);
        } else {
            a.call.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL | SLJIT_32, R3, 0, op, w));
        }
    }
    // The slot of the last shape is the fall-through body; shapes with that slot join it.
    uint last = p.idx[k - 1];
    void* label = sljit_emit_label(c);
    for (uint i = 0; i + 1 < k; i++) {
        if (p.idx[i] == last) { sljit_set_label(hit[i], label); hit[i] = null; }
    }
    a.prop_base(R0, R1);
    if (last != 0) sljit_emit_op2(c, SLJIT_ADD, R0, 0, R0, 0, SLJIT_IMM, (long)last * 8);
    void*[OPT_POLY_MAX] done;
    uint done_count = 0;
    for (uint i = 0; i + 1 < k; i++) {
        if (hit[i] == null) continue;
        uint idx = p.idx[i];
        done[done_count++] = sljit_emit_jump(c, SLJIT_JUMP);
        label = sljit_emit_label(c);
        // Every later shape with the same slot shares this body.
        for (uint j = i; j + 1 < k; j++) {
            if (hit[j] != null && p.idx[j] == idx) { sljit_set_label(hit[j], label); hit[j] = null; }
        }
        a.prop_base(R0, R1);
        if (idx != 0) sljit_emit_op2(c, SLJIT_ADD, R0, 0, R0, 0, SLJIT_IMM, (long)idx * 8);
    }
    if (done_count != 0) {
        label = sljit_emit_label(c);
        for (uint i = 0; i < done_count; i++) sljit_set_label(done[i], label);
    }
}

// Mark the value in `src` for the collector (Trampoline.shade), keeping every register.
fn void OptCg.shade(&self, int src) {
    void* c = self.a.c;
    sljit_emit_op1(c, SLJIT_MOV, SLJIT_MEM | reg_sp(), SUB_VALUE_OFF, src, 0);
    sljit_emit_ijump(c, SLJIT_FAST_CALL, SLJIT_IMM, (long)(usz)trampoline().shade);
}

// The jump taken while the collector is not marking. Uses R3.
fn void* OptCg.not_marking(&self) {
    void* c = self.a.c;
    sljit_emit_op1(c, SLJIT_MOV_U8, R3, 0, SLJIT_MEM | self.a.heap, self.a.lay.heap_gc_phase);
    return sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R3, 0, SLJIT_IMM, (long)heap::GcPhase.MARK.ordinal);
}

// Publish R0 into window slot `slot` as the baseline's store does, leaving for the baseline code
// where that takes its slow path, except for an object the collector's mark has not reached,
// which the store refuses: it is marked here and stored. A mark phase would otherwise turn each
// such load into an exit, and the exits into a discarded body.
fn void OptCg.publish(&self, uint i, uint slot) {
    void* c = self.a.c;
    Asm* a = self.a;
    assert(a.call.len == 0);
    a.publish(slot);
    if (a.call.len == 0) return;
    void* done = sljit_emit_jump(c, SLJIT_JUMP);
    a.call.bind(sljit_emit_label(c));
    a.call.len = 0;
    sljit_emit_op2(c, SLJIT_XOR, R2, 0, R0, 0, k_obj_op(), k_obj_w());
    self.exit_at(sljit_emit_cmp(c, SLJIT_GREATER_EQUAL, R2, 0, span_op(), span_w()), i, OptExit.SLOW_PATH);
    self.exit_at(self.not_marking(), i, OptExit.SLOW_PATH);
    self.shade(R0);
    a.store(slot, R0);
    a.track_heap_store(slot);
    sljit_set_label(done, sljit_emit_label(c));
}

// The VALUE result of a load, in R0: an object, an inert value or (from a counted holder) a
// string, the invariant of OptRep.VALUE; else leave for the baseline code. The object is tested
// first, as what such a node mostly holds; the tags above the object's are the other counted values.
fn void OptCg.finish_value(&self, uint i, OptNode* n) {
    void* c = self.a.c;
    sljit_emit_op2(c, SLJIT_XOR, R2, 0, R0, 0, k_obj_op(), k_obj_w());
    void* object = sljit_emit_cmp(c, SLJIT_LESS, R2, 0, span_op(), span_w());
    self.exit_at(sljit_emit_cmp(c, SLJIT_GREATER_EQUAL, R0, 0, SLJIT_IMM, n.counted ? K_OBJ : K_STRING_START), i, OptExit.SLOW_PATH);
    sljit_set_label(object, sljit_emit_label(c));
    self.def_value(i, R0);
}

// select_chain_slot's result for the receivers whose cases the epoch entry `ic` settled: the one it
// holds now and those it retained (hobject::ICProtoSet), when the heap's epoch is still theirs. Each
// is its shape, first prototype and the owner's slot as constants, under that epoch. The jumps
// taken, with the slot address in R0, go to `settled`; every other receiver, and a moved epoch,
// continue after them with R1 kept, but another shape leaves from the exact node `i`. Nothing is
// emitted for any other entry.
fn void OptCg.settled_chain_slots(&self, hobject::ICEntry* ic, uint i, Jumps* settled) {
    void* c = self.a.c;
    Asm* a = self.a;
    Layout* l = a.lay;
    hobject::Shape* sh = opt_settled_shape(self.h, ic);
    if (sh == null) return;
    hobject::ICChainEpoch* e = &ic.chain.epoch;
    sh.pinned = true;
    hobject::ICProtoCase[1 + hobject::IC_PROTO_MAX] cases;
    uint count = 0;
    cases[count++] = { .shape = ic.shape_id, .idx = ic.prop_idx, .first = e.first, .owner = e.owner };
    // An exact node has the one receiver shape.
    bool exact = self.g.nodes[i].exact;
    hobject::ICProtoSet* set = ic.chain.protos;
    if (!exact && set != null && set.epoch == e.value) {
        for (uint k = 0; k < set.count; k++) {
            hobject::Shape* other = self.h.get_shape(set.cases[k].shape);
            if (other == null || set.cases[k].first == null) continue;
            other.pinned = true;
            cases[count++] = set.cases[k];
        }
    }
    Jumps rest;
    sljit_emit_op1(c, SLJIT_MOV_U32, R3, 0, SLJIT_MEM | R1, l.obj_shape);
    if (exact) self.exit_at(sljit_emit_cmp(c, SLJIT_NOT_EQUAL | SLJIT_32, R3, 0, SLJIT_IMM, (long)ic.shape_id), i, OptExit.RECEIVER);
    // An ordinary object, no proxy among them; a plain one is known so (OptCg.guard_plain).
    if (!self.g.nodes[i].plain) {
        sljit_emit_op1(c, SLJIT_MOV_U32, R0, 0, SLJIT_MEM | R1, 0);
        sljit_emit_op2(c, SLJIT_AND, R0, 0, R0, 0, SLJIT_IMM, l.class_mask | l.plain_exotic_mask);
        rest.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R0, 0, SLJIT_IMM, l.class_object));
    }
    sljit_emit_op1(c, SLJIT_MOV, R0, 0, SLJIT_MEM | a.heap, l.heap_proto_epoch);
    rest.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R0, 0, SLJIT_IMM, (long)e.value));
    sljit_emit_op1(c, SLJIT_MOV, R0, 0, SLJIT_MEM | R1, l.obj_proto);
    for (uint k = 0; k < count; k++) {
        hobject::ICProtoCase* pc = &cases[k];
        void* shape = exact ? null : sljit_emit_cmp(c, SLJIT_NOT_EQUAL | SLJIT_32, R3, 0, SLJIT_IMM, (long)pc.shape);
        void* first = sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R0, 0, SLJIT_IMM, (long)(usz)pc.first);
        // An observed object's values stay where they are while the epoch stands (HObject.layout_moved).
        sljit_emit_op1(c, SLJIT_MOV, R0, 0, SLJIT_IMM, (long)(usz)&pc.owner.prop_values()[pc.idx]);
        settled.add(sljit_emit_jump(c, SLJIT_JUMP));
        void* next = sljit_emit_label(c);
        if (shape != null) sljit_set_label(shape, next);
        sljit_set_label(first, next);
    }
    rest.bind(sljit_emit_label(c));
}

// The slot address in R0 of the property the read entry `ic` names for the object in R1 (unboxed;
// known plain when `plain`): the data property of the prototype the entry's epoch guard or link
// snapshot describes, as Asm.emit_get does for a hit. The entry is read
// at run time, so a refill leaves the code right; a miss, a proxy, an accessor and any other chain
// leave for the baseline code. Uses R0 to R4.
fn void OptCg.select_chain_slot(&self, hobject::ICEntry* ic, bool plain) {
    void* c = self.a.c;
    Asm* a = self.a;
    Layout* l = a.lay;
    // An epoch entry that has moved between receivers keeps the earlier ones (hobject::ICProtoSet):
    // what the entry does not hold is looked up there, at run time too, before leaving.
    // Emit this path before the set exists too, so receivers learned after compilation can
    // use it immediately instead of repeatedly exiting until the function is rebuilt.
    uint kind0 = (uint)ic.chain_len & 0xFF;
    bool poly = ic.has_proto && kind0 == ((uint)hobject::IC_CHAIN_EPOCH & 0xFF) ;
    if (poly && self.h.opt.dump) {
        io::eprintfn("opt inherited poly: primary plus up to %d retained cases", hobject::IC_PROTO_MAX);
    }
    Jumps own_call = a.call;
    if (poly) a.call.len = 0;
    sljit_emit_op1(c, SLJIT_MOV, R2, 0, SLJIT_IMM, (long)(usz)ic);
    sljit_emit_op1(c, SLJIT_MOV_U32, R3, 0, SLJIT_MEM | R1, l.obj_shape);
    a.call.add(sljit_emit_cmp(c, SLJIT_EQUAL, SLJIT_MEM | R2, l.ic_key, SLJIT_IMM, 0));
    a.call.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL | SLJIT_32, R3, 0, SLJIT_MEM | R2, l.ic_shape));
    sljit_emit_op1(c, SLJIT_MOV_U8, R0, 0, SLJIT_MEM | R2, l.ic_flags);
    sljit_emit_op2(c, SLJIT_AND, R0, 0, R0, 0, SLJIT_IMM, l.accessor_mask);
    a.call.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R0, 0, SLJIT_IMM, 0));
    // The entry's kind at build time: one the code below replays, else an exit.
    uint kind = (uint)ic.chain_len & 0xFF;
    bool epoch = kind == ((uint)hobject::IC_CHAIN_EPOCH & 0xFF);
    if (!ic.has_proto || (!epoch && (kind == 0 || kind > hobject::IC_MAX_CHAIN))) {
        a.call.add(sljit_emit_jump(c, SLJIT_JUMP));
        return;
    }
    sljit_emit_op1(c, SLJIT_MOV_U8, R0, 0, SLJIT_MEM | R2, l.ic_has_proto);
    a.call.add(sljit_emit_cmp(c, SLJIT_EQUAL, R0, 0, SLJIT_IMM, 0));
    sljit_emit_op1(c, SLJIT_MOV_U8, R0, 0, SLJIT_MEM | R2, l.ic_chain_len);
    a.call.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R0, 0, SLJIT_IMM, (long)kind));
    sljit_emit_op1(c, SLJIT_MOV, R4, 0, SLJIT_MEM | R2, l.ic_chain);
    if (epoch) {
        if (!plain) {
            sljit_emit_op1(c, SLJIT_MOV_U32, R0, 0, SLJIT_MEM | R1, 0);
            sljit_emit_op2(c, SLJIT_AND, R0, 0, R0, 0, SLJIT_IMM, l.class_mask | l.plain_exotic_mask);
            a.call.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R0, 0, SLJIT_IMM, l.class_object));
        }
        sljit_emit_op1(c, SLJIT_MOV, R0, 0, SLJIT_MEM | R1, l.obj_proto);
        a.call.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R0, 0, SLJIT_MEM | R4, l.epoch_first));
        sljit_emit_op1(c, SLJIT_MOV, R0, 0, SLJIT_MEM | R4, l.epoch_current);
        sljit_emit_op1(c, SLJIT_MOV, R0, 0, SLJIT_MEM | R0, 0);
        a.call.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R0, 0, SLJIT_MEM | R4, l.epoch_value));
        sljit_emit_op1(c, SLJIT_MOV, R1, 0, SLJIT_MEM | R4, l.epoch_owner);
    } else {
        if (!plain) a.guard_not_proxy(R1, R0);
        // Each link by the identity and shape the entry snapshotted, as ic_resolve_owner.
        hobject::ICChain probe;
        long shapes = (long)((char*)&probe.snapshot.shapes[0] - (char*)&probe);
        long protos = (long)((char*)&probe.snapshot.protos[0] - (char*)&probe);
        for (uint k = 0; k < kind; k++) {
            sljit_emit_op1(c, SLJIT_MOV, R1, 0, SLJIT_MEM | R1, l.obj_proto);
            a.call.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R1, 0, SLJIT_MEM | R4, protos + (long)k * 8));
            sljit_emit_op1(c, SLJIT_MOV_U32, R3, 0, SLJIT_MEM | R1, l.obj_shape);
            a.call.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL | SLJIT_32, R3, 0, SLJIT_MEM | R4, shapes + (long)k * 4));
        }
    }
    a.guard_not_proxy(R1, R4);
    sljit_emit_op1(c, SLJIT_MOV_U32, R3, 0, SLJIT_MEM | R2, l.ic_idx);
    void* found = null;
    if (poly) {
        // The entry's misses, with the receiver still in R1: each case of the set by receiver
        // shape and first prototype, under the set's epoch.
        found = sljit_emit_jump(c, SLJIT_JUMP);
        Jumps miss = a.call;
        a.call = own_call;
        miss.bind(sljit_emit_label(c));
        hobject::ICChain chp;
        hobject::ICProtoSet psp;
        hobject::ICProtoCase pcp;
        // The epoch proves ordinary prototype chains only. Check the receiver before
        // using a retained case, just as on the primary epoch-entry path.
        sljit_emit_op1(c, SLJIT_MOV_U32, R0, 0, SLJIT_MEM | R1, 0);
        sljit_emit_op2(c, SLJIT_AND, R0, 0, R0, 0, SLJIT_IMM, l.class_mask | l.plain_exotic_mask);
        a.call.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R0, 0, SLJIT_IMM, l.class_object));
        sljit_emit_op1(c, SLJIT_MOV, R2, 0, SLJIT_IMM, (long)(usz)ic);
        sljit_emit_op1(c, SLJIT_MOV, R4, 0, SLJIT_MEM | R2, l.ic_chain);
        a.call.add(sljit_emit_cmp(c, SLJIT_EQUAL, R4, 0, SLJIT_IMM, 0));
        sljit_emit_op1(c, SLJIT_MOV, R4, 0, SLJIT_MEM | R4, (long)((char*)&chp.protos - (char*)&chp));
        a.call.add(sljit_emit_cmp(c, SLJIT_EQUAL, R4, 0, SLJIT_IMM, 0));
        sljit_emit_op1(c, SLJIT_MOV, R0, 0, SLJIT_MEM | a.heap, (long)((char*)&self.h.prototype_epoch - (char*)self.h));
        a.call.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R0, 0, SLJIT_MEM | R4, (long)((char*)&psp.epoch - (char*)&psp)));
        sljit_emit_op1(c, SLJIT_MOV_U32, R2, 0, SLJIT_MEM | R4, (long)((char*)&psp.count - (char*)&psp));
        sljit_emit_op1(c, SLJIT_MOV_U32, R3, 0, SLJIT_MEM | R1, l.obj_shape);
        sljit_emit_op1(c, SLJIT_MOV, R0, 0, SLJIT_MEM | R1, l.obj_proto);
        Jumps hits;
        for (uint k = 0; k < hobject::IC_PROTO_MAX; k++) {
            long at = (long)((char*)&psp.cases - (char*)&psp) + (long)k * hobject::ICProtoCase::size;
            a.call.add(sljit_emit_cmp(c, SLJIT_LESS_EQUAL, R2, 0, SLJIT_IMM, (long)k));
            void* other = sljit_emit_cmp(c, SLJIT_NOT_EQUAL | SLJIT_32, R3, 0, SLJIT_MEM | R4, at + (long)((char*)&pcp.shape - (char*)&pcp));
            void* other2 = sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R0, 0, SLJIT_MEM | R4, at + (long)((char*)&pcp.first - (char*)&pcp));
            sljit_emit_op1(c, SLJIT_MOV, R1, 0, SLJIT_MEM | R4, at + (long)((char*)&pcp.owner - (char*)&pcp));
            sljit_emit_op1(c, SLJIT_MOV_U32, R3, 0, SLJIT_MEM | R4, at + (long)((char*)&pcp.idx - (char*)&pcp));
            hits.add(sljit_emit_jump(c, SLJIT_JUMP));
            void* next = sljit_emit_label(c);
            sljit_set_label(other, next);
            sljit_set_label(other2, next);
        }
        a.call.add(sljit_emit_jump(c, SLJIT_JUMP));
        hits.bind(sljit_emit_label(c));
        sljit_set_label(found, sljit_emit_label(c));
    }
    a.prop_base(R0, R1);
    sljit_emit_op2(c, SLJIT_SHL, R3, 0, R3, 0, SLJIT_IMM, 3);
    sljit_emit_op2(c, SLJIT_ADD, R0, 0, R0, 0, R3, 0);
}

// A read of the own data property its cache names, as emit_get does for a hit on the entry's shape:
// the receiver a plain object (any object for GETTHISC) of that shape, the value at the slot.
// Everything else leaves for the baseline code.
fn void OptCg.emit_load_field(&self, uint i, OptNode* n) {
    void* c = self.a.c;
    Asm* a = self.a;
    self.decode(n);
    a.call.len = 0;
    OptPoly* poly = &self.g.polys[(sz)(n.poly - 1)];
    bool known_slot = false;
    int rr = R0;
    if (a.w.op == Opcode.GETTHISC && n.b != NO_NODE) {
        // The receiver of a nested inlined call, held in a VALUE node.
        rr = self.value_reg(n.b, R0);
    } else if (a.w.op == Opcode.GETTHISC) {
        if (n.fidx != 0) {
            a.load(R0, self.g.fns[n.fidx].reg_base - 1);
        } else {
            a.load_this(R0);
        }
    } else if (n.b != NO_NODE) {
        rr = self.value_reg(n.b, R0);
    } else {
        a.load(R0, a.w.b);
    }
    bool chain = n.cc == 2;
    if (n.cc == 3) {
        // A key the prototype chain of a sunk object answers: the data property its site validated.
        OptSinkSite* site = (OptSinkSite*)self.g.sinks[(sz)(n.c >> 8)].site;
        uint k = n.c & 0xFF;
        sljit_emit_op1(c, SLJIT_MOV, R1, 0, SLJIT_MEM, (long)(usz)&site.read_owner[k]);
        a.prop_base(R0, R1);
        sljit_emit_op1(c, SLJIT_MOV, R3, 0, SLJIT_MEM, (long)(usz)&site.read_off[k]);
        sljit_emit_op2(c, SLJIT_ADD, R0, 0, R0, 0, R3, 0);
        known_slot = true;
    } else if (n.cc == 4) {
        // A string primitive reads String.prototype's own property.
        sljit_emit_op2(c, SLJIT_XOR, R1, 0, rr, 0, SLJIT_IMM, K_STRING_START);
        a.call.add(sljit_emit_cmp(c, SLJIT_GREATER_EQUAL, R1, 0, span_op(), span_w()));
        a.guard_flags_clear(R1, a.lay.symbol_mask, R2);
        sljit_emit_op1(c, SLJIT_MOV, R1, 0, SLJIT_MEM | a.heap, a.lay.heap_string_proto);
        self.guard_shape(R1, poly.shape[0]);
    } else if (n.cc == 1) {
        // The receiver was proven an object of this shape by an earlier node (see OptBuild.forget_facts).
        sljit_emit_op2(c, SLJIT_XOR, R1, 0, rr, 0, k_obj_op(), k_obj_w());
    } else {
        self.field_receiver(n, rr);
        // An own field's shape holds the property, which no proxy's does (it has no own properties).
        if (chain) {
            hobject::ICEntry* ic = &((hobject::ICEntry*)a.f.ic_entries)[a.next - 1];
            Jumps settled;
            self.settled_chain_slots(ic, i, &settled);
            self.select_chain_slot(ic, n.plain);
            settled.bind(sljit_emit_label(c));
            known_slot = true;
        } else if (poly.count > 1) {
            self.select_slot(poly);
            known_slot = true;
        } else {
            self.guard_shape(R1, poly.shape[0]);
        }
    }
    if (known_slot) {
        sljit_emit_op1(c, SLJIT_MOV, R0, 0, SLJIT_MEM | R0, 0);
    } else {
        a.prop_base(R0, R1);
        sljit_emit_op1(c, SLJIT_MOV, R0, 0, SLJIT_MEM | R0, (long)poly.idx[0] * 8);
    }
    if (chain && n.fidx != 0) self.chain_miss(n);
    self.exit_calls(i, OptExit.SHAPE);
    if (n.rep == OptRep.NONE) {
        self.publish(i, a.w.a);
    } else if (n.rep == OptRep.VALUE) {
        self.finish_value(i, n);
    } else {
        self.def_from_r0(i, n);
    }
}

// The read of an inherited property in an inlined body when the entry's chain does not hold: the
// megamorphic cache, then vm::jit_get_missed, read a data property of a plain chain, with the value
// in R0. The entry is the callee's, which every caller shares (a forwarding constructor's
// `this.initialize` sees every class), while each inline site sees its own receivers. What neither
// answers leaves for the baseline code (the jumps in a.call). No code runs and nothing is allocated
// for the collector.
fn void OptCg.chain_miss(&self, OptNode* n) {
    void* c = self.a.c;
    Asm* a = self.a;
    CompiledFunction* f = a.f;
    hobject::ICEntry* ic = &((hobject::ICEntry*)f.ic_entries)[a.next - 1];
    // The key, a constant the function's code does not replace.
    if (a.w.c >= f.const_count || !f.constants[a.w.c].is_string() || f.constants[a.w.c].get_heapptr() != (void*)ic.key.borrow()) return;
    for (uint k = 0; k < f.code_count; k++) if (f.code[k].op == Opcode.SETCONST) return;
    void* key = f.constants[a.w.c].get_heapptr();
    void* done = sljit_emit_jump(c, SLJIT_JUMP);
    a.call.bind(sljit_emit_label(c));
    a.call.len = 0;
    int rr = R0;
    if (n.b != NO_NODE) {
        rr = self.value_reg(n.b, R0);
    } else if (a.w.op == Opcode.GETTHISC) {
        a.load(R0, self.g.fns[n.fidx].reg_base - 1);
    } else {
        a.load(R0, a.w.b);
    }
    a.unbox_object(R1, rr);
    a.guard_not_proxy(R1, R2);
    sljit_emit_op1(c, SLJIT_MOV, R2, 0, SLJIT_IMM, (long)(usz)ic);
    a.call.add(sljit_emit_cmp(c, SLJIT_EQUAL, SLJIT_MEM | R2, a.lay.ic_key, SLJIT_IMM, 0));
    a.subs.push({ .jump = sljit_emit_jump(c, SLJIT_FAST_CALL), .sub = MEGA_SUB });
    void* cached = sljit_emit_cmp(c, SLJIT_EQUAL, R2, 0, SLJIT_IMM, SUB_TRUE);
    // The mega subroutine keeps the receiver in R1 on a miss.
    uint at = (uint)(n - &self.g.nodes[0]);
    self.spill_live(at, true);
    sljit_emit_op1(c, SLJIT_MOV, R0, 0, a.heap, 0);
    sljit_emit_op1(c, SLJIT_MOV, R2, 0, SLJIT_IMM, (long)(usz)key);
    sljit_emit_op1(c, SLJIT_MOV, R3, 0, SLJIT_IMM, 0);
    self.a.c_call(SLJIT_ARGS4WWWW, SLJIT_IMM, (long)(usz)&vm::jit_get_missed);
    self.spill_live(at, false);
    a.call.add(sljit_emit_cmp(c, SLJIT_EQUAL, R0, 0, SLJIT_IMM, 0));
    sljit_emit_op1(c, SLJIT_MOV, R0, 0, SLJIT_MEM | R0, 0);
    sljit_set_label(cached, sljit_emit_label(c));
    sljit_set_label(done, sljit_emit_label(c));
}

// PUTPROP of a number or a VALUE node to an element, as emit_put_elem: it overwrites a present
// element of a dense array, or stores into a typed array; anything else leaves for the baseline code.
fn void OptCg.emit_store_elem(&self, uint i, OptNode* n) {
    void* c = self.a.c;
    Asm* a = self.a;
    if (n.b == NO_NODE) {
        self.emit_store_elem_window(i, n);
        return;
    }
    self.decode(n);
    a.call.len = 0;
    OptView view;
    // A typed array converts a number inline (an int32 one: the builder converts a double to the
    // integer kinds, OptBuild.put_elem); an object goes to the subroutine, as in the baseline code.
    OptRep rep = self.g.nodes[n.b].rep;
    bool boxed = rep == OptRep.VALUE;
    if (!boxed && self.const_view(n, true, &view) && (rep == OptRep.INT32 || TYPED_KINDS[view.kind].is_float())) {
        int v = self.typed_store_value(n, TYPED_KINDS[view.kind]);
        self.emit_typed_store(TYPED_KINDS[view.kind], v, self.const_elem(i, n.a, &view));
        return;
    }
    int rr = R0;
    if (n.c != NO_NODE) {
        rr = self.value_reg(n.c, R0);
    } else {
        a.load(R0, a.w.a);
    }
    long flags;
    bool unseen;
    void* other = null;
    if ((n.cc & ELEM_KNOWN) != 0) {
        sljit_emit_op2(c, SLJIT_XOR, R1, 0, rr, 0, k_obj_op(), k_obj_w());
    } else {
        a.unbox_object(R1, rr);
        int k = self.typed_kind(a.lay.indexed_named_mask, &flags, &unseen);
        // A double stored to an integer kind needs ta_store_int's modular conversion: the subroutine's.
        if (!boxed && k >= 0 && (rep == OptRep.INT32 || TYPED_KINDS[k].is_float())) {
            int v = self.typed_store_value(n, TYPED_KINDS[k]);
            int x = self.typed_elem_addr(n.a, TYPED_KINDS[k], flags, a.lay.indexed_named_mask, true);
            self.exit_calls(i, OptExit.SLOW_PATH);
            self.emit_typed_store(TYPED_KINDS[k], v, x);
            return;
        }
        other = a.array_or_typed(a.lay.indexed_named_mask);
    }
    self.array_slot(n.a);
    a.call.add(sljit_emit_cmp(c, SLJIT_EQUAL, SLJIT_MEM | R0, 0, SLJIT_IMM, K_UNDEF));
    self.value_to(n.b, R2);
    Jumps counted;
    a.guard_old_value(&counted, boxed);
    if (boxed) {
        a.store_value_r2(&counted, !self.g.nodes[n.b].counted);
    } else {
        sljit_emit_op1(c, SLJIT_MOV, SLJIT_MEM | R0, 0, R2, 0);
    }
    self.store_counted(i, &counted);
    if (other != null) {
        $if features::BUFFERS:
            void* done = sljit_emit_jump(c, SLJIT_JUMP);
            sljit_set_label(other, sljit_emit_label(c));
            if (unseen) {
                self.unprofiled_exit(i);
            } else {
                self.box_index(n.a);
                self.value_to(n.b, R0);
                a.subs.push({ .jump = sljit_emit_jump(c, SLJIT_FAST_CALL), .sub = TYPED_PUT_SUB });
                a.call.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R2, 0, SLJIT_IMM, SUB_TRUE));
            }
            sljit_set_label(done, sljit_emit_label(c));
        $else
            a.call.add(other);
        $endif
    }
    self.exit_calls(i, OptExit.SLOW_PATH);
}

// PUTPROP of the window value C to an element, as Asm.emit_put_elem.
fn void OptCg.emit_store_elem_window(&self, uint i, OptNode* n) {
    void* c = self.a.c;
    Asm* a = self.a;
    self.decode(n);
    a.call.len = 0;
    int rr = R0;
    if (n.c != NO_NODE) {
        rr = self.value_reg(n.c, R0);
    } else {
        a.load(R0, a.w.a);
    }
    long flags;
    bool unseen;
    void* other = null;
    if ((n.cc & ELEM_KNOWN) != 0) {
        sljit_emit_op2(c, SLJIT_XOR, R1, 0, rr, 0, k_obj_op(), k_obj_w());
    } else {
        a.unbox_object(R1, rr);
        self.typed_kind(a.lay.indexed_named_mask, &flags, &unseen);
        other = a.array_or_typed(a.lay.indexed_named_mask);
    }
    self.array_slot(n.a);
    a.call.add(sljit_emit_cmp(c, SLJIT_EQUAL, SLJIT_MEM | R0, 0, SLJIT_IMM, K_UNDEF));
    a.load(R2, a.w.c);
    a.call.add(sljit_emit_cmp(c, SLJIT_EQUAL, R2, 0, SLJIT_IMM, K_UNDEF));
    Jumps counted;
    a.guard_old_value(&counted);
    a.store_value_r2(&counted);
    self.store_counted(i, &counted);
    if (other != null) {
        $if features::BUFFERS:
            void* typed_done = sljit_emit_jump(c, SLJIT_JUMP);
            sljit_set_label(other, sljit_emit_label(c));
            if (unseen) {
                self.unprofiled_exit(i);
            } else {
                self.box_index(n.a);
                a.load(R0, a.w.c);
                a.subs.push({ .jump = sljit_emit_jump(c, SLJIT_FAST_CALL), .sub = TYPED_PUT_SUB });
                a.call.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R2, 0, SLJIT_IMM, SUB_TRUE));
            }
            sljit_set_label(typed_done, sljit_emit_label(c));
        $else
            a.call.add(other);
        $endif
    }
    self.exit_calls(i, OptExit.SLOW_PATH);
}

// PUTPROPC or PUTTHISC of an own writable data property, as emit_put does for a hit: a plain
// object of the cache's shape, an old value that needs no count, and a value that needs no
// barrier. Everything else leaves for the baseline code before anything is written.
fn void OptCg.emit_store_field(&self, uint i, OptNode* n) {
    void* c = self.a.c;
    Asm* a = self.a;
    self.decode(n);
    a.call.len = 0;
    OptPoly* poly = &self.g.polys[(sz)(n.poly - 1)];
    bool known_slot = false;
    bool this_op = a.w.op == Opcode.PUTTHISC;
    int rr = R0;
    if (this_op && n.b != NO_NODE) {
        rr = self.value_reg(n.b, R0);
    } else if (this_op) {
        if (n.fidx != 0) {
            a.load(R0, self.g.fns[n.fidx].reg_base - 1);
        } else {
            a.load_this(R0);
        }
    } else if (n.b != NO_NODE) {
        rr = self.value_reg(n.b, R0);
    } else {
        a.load(R0, a.w.a);
    }
    if (n.cc != 0) {
        sljit_emit_op2(c, SLJIT_XOR, R1, 0, rr, 0, k_obj_op(), k_obj_w());
    } else {
        self.field_receiver(n, rr);
        if (!n.plain) self.guard_ordinary(R1);
        if (poly.count > 1) {
            self.select_slot(poly);
            known_slot = true;
        } else {
            self.guard_shape(R1, poly.shape[0]);
        }
    }
    if (!known_slot) {
        a.prop_base(R0, R1);
        sljit_emit_op2(c, SLJIT_ADD, R0, 0, R0, 0, SLJIT_IMM, (long)poly.idx[0] * 8);
    }
    self.store_slot_value(i, n.a, this_op ? a.w.a : a.w.b);
    self.exit_calls(i, OptExit.SHAPE);
}

// The boxed value of node `v` in register `dst`: a VALUE node's own, a number boxed.
fn void OptCg.value_to(&self, uint v, int dst) {
    if (self.g.nodes[v].rep != OptRep.VALUE) {
        self.box_node(v, dst);
        return;
    }
    int r = self.value_reg(v, dst);
    if (r != dst) sljit_emit_op1(self.a.c, SLJIT_MOV, dst, 0, r, 0);
}

// Node `i`'s store into the slot at R0 of the object in R1: of node `v`, or of window register
// `rv` when it has none.
fn void OptCg.store_slot_value(&self, uint i, uint v, uint rv) {
    void* c = self.a.c;
    Asm* a = self.a;
    Jumps counted;
    if (v == NO_NODE) {
        a.load(R2, rv);
    } else {
        self.value_to(v, R2);
    }
    // A VALUE node mostly replaces an object; one that may hold a string has it counted.
    bool boxed = v != NO_NODE && self.g.nodes[v].rep == OptRep.VALUE;
    a.guard_old_value(&counted, boxed);
    if (v == NO_NODE || boxed) {
        a.store_value_r2(&counted, boxed && !self.g.nodes[v].counted);
    } else {
        // A number or a constant: inert.
        sljit_emit_op1(c, SLJIT_MOV, SLJIT_MEM | R0, 0, R2, 0);
    }
    self.store_counted(i, &counted);
}

// The store of the value in R2 into the slot at R0 of the object in R1 that the plain path of
// node `i` declined (`counted`): an old value to release, a string to count, an old owner or a
// running mark. It takes the counted and traced store of th_store_slot_ref, with the registers
// in use saved around the call. An old owner is the usual state of a long-lived object, so
// leaving for the baseline code here would discard the body.
fn void OptCg.store_counted(&self, uint i, Jumps* counted) {
    void* c = self.a.c;
    void* done = sljit_emit_jump(c, SLJIT_JUMP);
    counted.bind(sljit_emit_label(c));
    self.spill_live(i, true);
    sljit_emit_op1(c, SLJIT_MOV, R3, 0, R2, 0);
    sljit_emit_op1(c, SLJIT_MOV, R2, 0, R0, 0);
    sljit_emit_op1(c, SLJIT_MOV, R0, 0, self.a.heap, 0);
    self.a.c_call(SLJIT_ARGS4WWWW, SLJIT_IMM, (long)(usz)&vm::jit_opt_store_slot);
    self.spill_live(i, false);
    sljit_set_label(done, sljit_emit_label(c));
}

// The guard of an inlined call, run before anything of the call is: the callee register holds a
// closure of the inlined function that a real call would enter (th_lean_target and the checks
// around it), a method call's receiver is acceptable, and the frame it would publish has room.
// Any miss leaves for the baseline code at the call. A polymorphic call's closure may be of any of
// its functions.
fn void OptCg.emit_check_callee(&self, uint i, OptNode* n) {
    void* c = self.a.c;
    Asm* a = self.a;
    CallLayout* k = call_layout();
    OptCallees set = { .fns[0] = (CompiledFunction*)(usz)n.imm, .count = 1 };
    if (n.poly != 0) set = self.g.callees[(sz)n.poly - 1];
    a.decode(n.pc);
    // The call is an instruction of the node's function: of an inlined body for a nested call.
    OptFn* caller = &self.g.fns[n.fidx];
    uint callee_reg = ((a.w.op == Opcode.CALL_VAR || a.w.op == Opcode.CALL_GLOBAL) ? a.w.a : a.w.b) + caller.reg_base;
    // A forwarding call is guarded before its registers move: the function `apply` runs is in the
    // slot after the call's callee register, the receiver after it.
    if (a.w.op == Opcode.APPLY_ARGS || (n.cc & 4) != 0) callee_reg++;
    int m = SLJIT_MEM;
    void*[16] miss;
    uint misses = 0;
    uint most_regs = 0;
    for (uint f = 0; f < set.count; f++) most_regs = max(most_regs, set.fns[f].num_regs);
    void* proven = null;
    if ((n.cc & OPT_CALLEE_PROVEN) != 0) {
        proven = sljit_emit_jump(c, SLJIT_JUMP);
    } else if (n.a != NO_NODE) {
        int r = self.value_reg(n.a, R1);
        if (r != R1) sljit_emit_op1(c, SLJIT_MOV, R1, 0, r, 0);
    } else {
        a.load(R1, callee_reg);
    }
    // The function the builder found in the method's slot (OptBuild.method_constant) passes every
    // test below, and is that function while the epoch it was observed under stands.
    void* constant = null;
    void*[2] other;
    if (n.key != null) {
        other[0] = sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R1, 0, SLJIT_IMM, (long)(usz)n.key ^ K_OBJ);
        sljit_emit_op1(c, SLJIT_MOV, R4, 0, m | a.heap, a.lay.heap_proto_epoch);
        other[1] = sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R4, 0, SLJIT_IMM, (long)self.h.prototype_epoch);
        constant = sljit_emit_jump(c, SLJIT_JUMP);
        void* tests = sljit_emit_label(c);
        sljit_set_label(other[0], tests);
        sljit_set_label(other[1], tests);
    }
    sljit_emit_op2(c, SLJIT_XOR, R0, 0, R1, 0, k_obj_op(), k_obj_w());
    miss[misses++] = sljit_emit_cmp(c, SLJIT_GREATER_EQUAL, R0, 0, span_op(), span_w());
    miss[misses++] = sljit_emit_cmp(c, SLJIT_EQUAL, R0, 0, SLJIT_IMM, 0);
    sljit_emit_op1(c, SLJIT_MOV_U32, R4, 0, m | R0, 0);
    // A NEW_OBJ's constructor is also constructable.
    hobject::ObjFlags ctor_bit;
    ctor_bit.constructable = (n.cc & 3) == 2;
    sljit_emit_op2(c, SLJIT_AND, R4, 0, R4, 0, SLJIT_IMM, k.fn_mask | (long)(uint)ctor_bit);
    miss[misses++] = sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R4, 0, SLJIT_IMM, k.fn_want | (long)(uint)ctor_bit);
    sljit_emit_op1(c, SLJIT_MOV_S32, R4, 0, m | R0, k.fn_builtin);
    miss[misses++] = sljit_emit_cmp(c, SLJIT_SIG_GREATER_EQUAL, R4, 0, SLJIT_IMM, 0);
    sljit_emit_op1(c, SLJIT_MOV, R4, 0, m | R0, a.lay.fn_comp_func);
    void*[hobject::IC_CALL_TARGETS] found;
    for (uint f = 0; f < set.count; f++) {
        if (f + 1 < set.count) {
            found[f] = sljit_emit_cmp(c, SLJIT_EQUAL, R4, 0, SLJIT_IMM, (long)(usz)set.fns[f]);
        } else {
            miss[misses++] = sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R4, 0, SLJIT_IMM, (long)(usz)set.fns[f]);
        }
    }
    if (set.count > 1) {
        void* is_one = sljit_emit_label(c);
        for (uint f = 0; f + 1 < set.count; f++) sljit_set_label(found[f], is_one);
    }
    Jumps scope;
    a.emit_scope_test(R0, R4, &scope);
    for (uint j = 0; j < scope.len; j++) miss[misses++] = scope.at[j];
    if (constant != null) sljit_set_label(constant, sljit_emit_label(c));
    if (proven != null) sljit_set_label(proven, sljit_emit_label(c));
    // An exit from the body publishes its frame and those of the calls around it.
    a.room_acts = max(a.room_acts, caller.depth + 1);
    a.room_slots = max(a.room_slots, callee_reg + 2 + most_regs + vm::FRAME_SCRATCH_SLOTS);
    bool takes_this = false;
    for (uint f = 0; f < set.count; f++) takes_this = takes_this || !set.fns[f].call_flags.ignores_this;
    // A sunk receiver (c names its sink) is an object any exit allocates into the frame it publishes.
    if ((n.cc & 3) == 1 && takes_this && !(n.b == NO_NODE && n.c != NO_NODE)) {
        // The receiver: an object in a register the caller's frame tracks, or in a VALUE node
        // that any exit stores into a frame it publishes.
        // The read of the method proved it an object when it is that read's receiver (bit 3).
        if ((n.cc & 8) == 0) {
            if (n.b != NO_NODE) {
                int r = self.value_reg(n.b, R0);
                sljit_emit_op2(c, SLJIT_XOR, R0, 0, r, 0, k_obj_op(), k_obj_w());
            } else {
                a.load(R0, callee_reg + 1);
                sljit_emit_op2(c, SLJIT_XOR, R0, 0, R0, 0, k_obj_op(), k_obj_w());
            }
            miss[misses++] = sljit_emit_cmp(c, SLJIT_GREATER_EQUAL, R0, 0, span_op(), span_w());
            miss[misses++] = sljit_emit_cmp(c, SLJIT_EQUAL, R0, 0, SLJIT_IMM, 0);
        }
        if (n.b == NO_NODE && callee_reg + 1 >= a.frame_regs) {
            sljit_emit_op1(c, SLJIT_MOV_U32, R0, 0, m | a.la, a.lay.act_hrc);
            miss[misses++] = sljit_emit_cmp(c, SLJIT_LESS_EQUAL, R0, 0, SLJIT_IMM, (long)callee_reg + 1);
        }
    }
    for (uint j = 0; j < misses; j++) self.exit_at(miss[j], i, OptExit.CALLEE);
}

// The machine registers that hold a value at node `i` (a node defined before it whose last use is
// `i` or later occupies its register there) stored to the frame's save area, or loaded back from it,
// around a call of C from inside the node. The node's own operands count: an exit after the call
// publishes them. Uses no other register.
fn void OptCg.spill_live(&self, uint i, bool save) {
    void* c = self.a.c;
    for (uint j = 0; j < i; j++) {
        OptNode* nd = &self.g.nodes[j];
        if (!nd.allocated() || nd.reg < 0 || nd.last_use < i) continue;
        if (nd.rep.is_gpr()) {
            long off = CALL_FRAME_BYTES + 8 * (long)(nd.reg - self.pools.int_first);
            if (save) {
                sljit_emit_op1(c, SLJIT_MOV, SLJIT_MEM | reg_sp(), off, nd.reg, 0);
            } else {
                sljit_emit_op1(c, SLJIT_MOV, nd.reg, 0, SLJIT_MEM | reg_sp(), off);
            }
        } else {
            long off = CALL_FRAME_BYTES + 8 * (long)(self.pools.int_count + nd.reg - self.pools.flt_first);
            if (save) {
                sljit_emit_fop1(c, SLJIT_MOV_F64, SLJIT_MEM | reg_sp(), off, nd.reg, 0);
            } else {
                sljit_emit_fop1(c, SLJIT_MOV_F64, nd.reg, 0, SLJIT_MEM | reg_sp(), off);
            }
        }
    }
}

// The properties a constructor `cf` leaves on its objects, which a NEW_OBJ allocates room for: what
// its frames have left on them (CallFlags.constructor_capacity), or the adds its body holds if more.
fn uint opt_constructor_want(CompiledFunction* cf) {
    uint want = cf.call_flags.constructor_capacity;
    uint adds = 0;
    for (uint k = 0; k < cf.code_count; k++) if (cf.code[k].op == Opcode.PUTTHISC) adds++;
    return adds > want ? adds : want;
}

// The object of an inlined NEW_OBJ, built by vm::jit_opt_new_object with the registers in use saved
// around the call; a constructor or cache it refuses leaves for the baseline code at the NEW_OBJ.
// One whose adds the code knows (ADD_FIELD cc 1) is built under a validated site (emit_site_new).
fn void OptCg.emit_new_object(&self, uint i, OptNode* n) {
    void* c = self.a.c;
    Asm* a = self.a;
    CompiledFunction* cf = (CompiledFunction*)(usz)n.imm;
    OptSinkSite* site = self.known_adds_site(i, n, cf);
    if (site != null) {
        self.emit_site_new(i, site);
        return;
    }
    uint want = opt_constructor_want(cf);
    self.load_constructor(n);
    long ic = (long)(usz)&((hobject::ICEntry*)self.g.fns[n.fidx].f.ic_entries)[a.next - 1];
    // The common case builds the object inline, from the cache the helper would read. R0 to R4 hold
    // no values of the optimized code, so nothing is saved around it.
    Jumps slow;
    void* done = null;
    if (inline_alloc_ok() && want <= hobject::SHAPED_INLINE_MAX_PROPS && n.key != null) {
        // Heap.set_prototype also walks the other realms when there are any.
        slow.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, SLJIT_MEM | a.heap, a.lay.heap_realms, SLJIT_IMM, 0));
        sljit_emit_op1(c, SLJIT_MOV, SLJIT_MEM | reg_sp(), SUB_VALUE_OFF, SLJIT_IMM, (long)(usz)n.key);
        InlineAlloc plan = a.plain_object_plan(vm::constructor_inline_capacity(want));
        a.emit_inline_alloc(&plan, &slow);
        sljit_emit_op2(c, SLJIT_OR, R0, 0, R0, 0, k_obj_op(), k_obj_w());
        done = sljit_emit_jump(c, SLJIT_JUMP);
        slow.bind(sljit_emit_label(c));
        self.load_constructor(n);
    } else if (inline_alloc_ok() && want <= hobject::SHAPED_INLINE_MAX_PROPS) {
        Layout* l = a.lay;
        int m = SLJIT_MEM;
        // jit_opt_new_object's guards: a constructor, and the cache's own `prototype` data property.
        sljit_emit_op1(c, SLJIT_MOV_U32, R0, 0, m | R1, 0);
        sljit_emit_op2(c, SLJIT_AND, R0, 0, R0, 0, SLJIT_IMM, l.constructable_mask);
        slow.add(sljit_emit_cmp(c, SLJIT_EQUAL, R0, 0, SLJIT_IMM, 0));
        sljit_emit_op1(c, SLJIT_MOV, R2, 0, SLJIT_IMM, ic);
        slow.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, m | R2, l.ic_key, SLJIT_IMM, (long)(usz)a.hp.strs[heap::BuiltinStr.PROTOTYPE]));
        sljit_emit_op1(c, SLJIT_MOV_U8, R0, 0, m | R2, l.ic_has_proto);
        slow.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R0, 0, SLJIT_IMM, 0));
        sljit_emit_op1(c, SLJIT_MOV_U32, R3, 0, m | R1, l.obj_shape);
        slow.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL | SLJIT_32, R3, 0, m | R2, l.ic_shape));
        // live_shape_generation: heap.shapes[shape_id].generation.
        sljit_emit_op1(c, SLJIT_MOV, R0, 0, m | a.heap, l.heap_shapes);
        sljit_emit_op1(c, SLJIT_MOV, R0, 0, mem_index(R0, R3), 3);
        sljit_emit_op1(c, SLJIT_MOV_U32, R0, 0, m | R0, l.shape_gen);
        sljit_emit_op1(c, SLJIT_MOV_U32, R3, 0, m | R2, l.ic_gen);
        slow.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R0, 0, R3, 0));
        sljit_emit_op1(c, SLJIT_MOV_U8, R0, 0, m | R2, l.ic_flags);
        sljit_emit_op2(c, SLJIT_AND, R0, 0, R0, 0, SLJIT_IMM, l.accessor_mask);
        slow.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R0, 0, SLJIT_IMM, 0));
        sljit_emit_op1(c, SLJIT_MOV_U32, R3, 0, m | R2, l.ic_idx);
        sljit_emit_op1(c, SLJIT_MOV_U32, R0, 0, m | R1, l.obj_prop_count);
        slow.add(sljit_emit_cmp(c, SLJIT_GREATER_EQUAL, R3, 0, R0, 0));
        a.prop_base(R0, R1);
        sljit_emit_op1(c, SLJIT_MOV, R0, 0, mem_index(R0, R3), 3);
        sljit_emit_op2(c, SLJIT_XOR, R2, 0, R0, 0, k_obj_op(), k_obj_w());
        slow.add(sljit_emit_cmp(c, SLJIT_GREATER_EQUAL, R2, 0, span_op(), span_w()));
        // Heap.set_prototype also walks the other realms when there are any.
        slow.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, m | a.heap, l.heap_realms, SLJIT_IMM, 0));
        sljit_emit_op1(c, SLJIT_MOV, m | reg_sp(), SUB_VALUE_OFF, R2, 0);
        InlineAlloc plan = a.plain_object_plan(vm::constructor_inline_capacity(want));
        a.emit_inline_alloc(&plan, &slow);
        sljit_emit_op2(c, SLJIT_OR, R0, 0, R0, 0, k_obj_op(), k_obj_w());
        done = sljit_emit_jump(c, SLJIT_JUMP);
        slow.bind(sljit_emit_label(c));
        // The slow path reloads the constructor.
        self.load_constructor(n);
    }
    self.spill_live(i, true);
    sljit_emit_op1(c, SLJIT_MOV, R0, 0, a.ds, 0);
    sljit_emit_op1(c, SLJIT_MOV, R2, 0, SLJIT_IMM, ic);
    sljit_emit_op1(c, SLJIT_MOV, R3, 0, SLJIT_IMM, (long)want);
    self.a.c_call(SLJIT_ARGS4WWWW, SLJIT_IMM, (long)(usz)&vm::jit_opt_new_object);
    self.spill_live(i, false);
    self.exit_at(sljit_emit_cmp(c, SLJIT_EQUAL, R0, 0, SLJIT_IMM, 0), i, OptExit.ALLOC_SLOW);
    if (done != null) sljit_set_label(done, sljit_emit_label(c));
    self.def_value(i, R0);
    self.count_alloc(&self.h.opt.alloc_runs);
}

// A run-time site (OptSinkSite) for the inlined NEW_OBJ at node `n`, of constructor `cf`, kept with
// the code: the NEW_OBJ's cache and the room the object is built with. The caller adds the keys.
fn OptSinkSite* OptCg.new_site(&self, OptNode* n, CompiledFunction* cf) {
    Asm* a = self.a;
    a.decode(n.pc);
    OptSinkSite* site = self.h.alloc_func(self.h.heap_udata, OptSinkSite::size);
    mem::clear(site, OptSinkSite::size);
    site.next = self.oc.sink_sites;
    self.oc.sink_sites = site;
    site.new_ic = &((hobject::ICEntry*)self.g.fns[n.fidx].f.ic_entries)[a.next - 1];
    site.want = opt_constructor_want(cf);
    if (n.key != null) {
        site.fixed = true;
        site.proto = n.key;
    }
    return site;
}

// The site of NEW_OBJECT node `i` when the code knows the adds of its object (ADD_FIELD cc 1), with
// their keys, which the site validates against the prototype chain; else null.
fn OptSinkSite* OptCg.known_adds_site(&self, uint i, OptNode* n, CompiledFunction* cf) {
    void*[OPT_SINK_FIELDS] keys;
    uint count = 0;
    for (uint j = i + 1; j < self.g.nodes.len(); j++) {
        OptNode* m = &self.g.nodes[j];
        // A known add names the object by any copy of it (OptBuild.add_known).
        if (m.op != OptOp.ADD_FIELD || m.cc != 1 || self.g.copied(m.b) != i) continue;
        if (count == OPT_SINK_FIELDS) return null;
        keys[count++] = m.key;
    }
    if (count == 0) return null;
    OptSinkSite* site = self.new_site(n, cf);
    site.add_count = count;
    for (uint k = 0; k < count; k++) site.keys[k] = keys[k];
    return site;
}

// The untagged constructor of the NEW_OBJECT node `n` in R1; the guard before proved it an object.
fn void OptCg.load_constructor(&self, OptNode* n) {
    void* c = self.a.c;
    self.a.decode(n.pc);
    if (n.a != NO_NODE) {
        int r = self.value_reg(n.a, R1);
        if (r != R1) sljit_emit_op1(c, SLJIT_MOV, R1, 0, r, 0);
    } else {
        self.a.load(R1, self.a.w.b + self.g.fns[n.fidx].reg_base);
    }
    sljit_emit_op2(c, SLJIT_XOR, R1, 0, R1, 0, k_obj_op(), k_obj_w());
}

// Leave the code at node `i` (ALLOC_SLOW, for the baseline code at the NEW_OBJ) unless `site` holds
// for the constructor in R1: the state it recorded at its last validation, or else a validation
// again by vm::jit_opt_sink_check, with the registers in use saved around the call.
fn void OptCg.emit_site_check(&self, uint i, OptSinkSite* site) {
    void* c = self.a.c;
    Asm* a = self.a;
    if (self.g.nodes[i].key != null) {
        self.emit_const_site_check(i, site);
        return;
    }
    void*[5] slow;
    slow[0] = sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R1, 0, SLJIT_MEM, (long)(usz)&site.ctor);
    sljit_emit_op1(c, SLJIT_MOV_U32, R3, 0, SLJIT_MEM | R1, a.lay.obj_shape);
    slow[1] = sljit_emit_cmp(c, SLJIT_NOT_EQUAL | SLJIT_32, R3, 0, SLJIT_MEM, (long)(usz)&site.ctor_shape);
    sljit_emit_op1(c, SLJIT_MOV, R3, 0, SLJIT_MEM | a.heap, (long)((char*)&self.h.prototype_epoch - (char*)self.h));
    slow[2] = sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R3, 0, SLJIT_MEM, (long)(usz)&site.epoch);
    sljit_emit_op1(c, SLJIT_MOV_U32, R3, 0, SLJIT_MEM | a.heap, (long)((char*)&self.h.shape_recycle_epoch - (char*)self.h));
    slow[3] = sljit_emit_cmp(c, SLJIT_NOT_EQUAL | SLJIT_32, R3, 0, SLJIT_MEM, (long)(usz)&site.recycle);
    a.prop_base(R0, R1);
    sljit_emit_op1(c, SLJIT_MOV, R3, 0, SLJIT_MEM, (long)(usz)&site.proto_off);
    sljit_emit_op2(c, SLJIT_ADD, R0, 0, R0, 0, R3, 0);
    sljit_emit_op1(c, SLJIT_MOV, R0, 0, SLJIT_MEM | R0, 0);
    slow[4] = sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R0, 0, SLJIT_MEM, (long)(usz)&site.proto_bits);
    void* done = sljit_emit_jump(c, SLJIT_JUMP);
    void* label = sljit_emit_label(c);
    foreach (j : slow) sljit_set_label(j, label);
    self.spill_live(i, true);
    sljit_emit_op1(c, SLJIT_MOV, R0, 0, a.ds, 0);
    sljit_emit_op1(c, SLJIT_MOV, R2, 0, SLJIT_IMM, (long)(usz)site);
    self.a.c_call(SLJIT_ARGS3WWW, SLJIT_IMM, (long)(usz)&vm::jit_opt_sink_check);
    sljit_emit_op1(c, SLJIT_MOV_U8, R0, 0, R0, 0);
    self.spill_live(i, false);
    self.exit_at(sljit_emit_cmp(c, SLJIT_EQUAL, R0, 0, SLJIT_IMM, 0), i, OptExit.ALLOC_SLOW);
    sljit_set_label(done, sljit_emit_label(c));
}

// emit_site_check of a constant constructor whose `prototype` the code watches (NEW_OBJECT key): of
// the state the site recorded, only the prototype epoch, for the chain the adds shadow, and the
// recycle epoch, for the shape ids the site holds, can change.
fn void OptCg.emit_const_site_check(&self, uint i, OptSinkSite* site) {
    void* c = self.a.c;
    Asm* a = self.a;
    void*[2] slow;
    sljit_emit_op1(c, SLJIT_MOV, R2, 0, SLJIT_IMM, (long)(usz)site);
    sljit_emit_op1(c, SLJIT_MOV, R3, 0, SLJIT_MEM | a.heap, (long)((char*)&self.h.prototype_epoch - (char*)self.h));
    slow[0] = sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R3, 0, SLJIT_MEM | R2, (long)((char*)&site.epoch - (char*)site));
    sljit_emit_op1(c, SLJIT_MOV_U32, R3, 0, SLJIT_MEM | a.heap, (long)((char*)&self.h.shape_recycle_epoch - (char*)self.h));
    slow[1] = sljit_emit_cmp(c, SLJIT_NOT_EQUAL | SLJIT_32, R3, 0, SLJIT_MEM | R2, (long)((char*)&site.recycle - (char*)site));
    void* done = sljit_emit_jump(c, SLJIT_JUMP);
    void* label = sljit_emit_label(c);
    foreach (j : slow) sljit_set_label(j, label);
    self.spill_live(i, true);
    sljit_emit_op1(c, SLJIT_MOV, R0, 0, a.ds, 0);
    self.a.c_call(SLJIT_ARGS3WWW, SLJIT_IMM, (long)(usz)&vm::jit_opt_sink_check);
    sljit_emit_op1(c, SLJIT_MOV_U8, R0, 0, R0, 0);
    self.spill_live(i, false);
    self.exit_at(sljit_emit_cmp(c, SLJIT_EQUAL, R0, 0, SLJIT_IMM, 0), i, OptExit.ALLOC_SLOW);
    sljit_set_label(done, sljit_emit_label(c));
}

// The object of NEW_OBJECT node `i` whose adds the code knows, once `site` holds for the
// constructor: empty, with room for site.want properties and the prototype the site recorded, built
// inline, else by vm::jit_opt_site_object with the registers in use saved around the call.
fn void OptCg.emit_site_new(&self, uint i, OptSinkSite* site) {
    void* c = self.a.c;
    Asm* a = self.a;
    self.load_constructor(&self.g.nodes[i]);
    self.emit_site_check(i, site);
    void* done = null;
    if (inline_alloc_ok()) {
        Jumps slow;
        void* proto = self.g.nodes[i].key;
        if (proto != null) {
            sljit_emit_op1(c, SLJIT_MOV, SLJIT_MEM | reg_sp(), SUB_VALUE_OFF, SLJIT_IMM, (long)(usz)proto);
        } else {
            sljit_emit_op1(c, SLJIT_MOV, R2, 0, SLJIT_MEM, (long)(usz)&site.proto);
            sljit_emit_op1(c, SLJIT_MOV, SLJIT_MEM | reg_sp(), SUB_VALUE_OFF, R2, 0);
        }
        InlineAlloc plan = a.plain_object_plan(vm::constructor_inline_capacity(site.want));
        a.emit_inline_alloc(&plan, &slow);
        sljit_emit_op2(c, SLJIT_OR, R0, 0, R0, 0, k_obj_op(), k_obj_w());
        done = sljit_emit_jump(c, SLJIT_JUMP);
        slow.bind(sljit_emit_label(c));
    }
    self.spill_live(i, true);
    sljit_emit_op1(c, SLJIT_MOV, R0, 0, a.ds, 0);
    sljit_emit_op1(c, SLJIT_MOV, R1, 0, SLJIT_IMM, (long)(usz)site);
    self.a.c_call(SLJIT_ARGS2WWW, SLJIT_IMM, (long)(usz)&vm::jit_opt_site_object);
    self.spill_live(i, false);
    self.exit_at(sljit_emit_cmp(c, SLJIT_EQUAL, R0, 0, SLJIT_IMM, 0), i, OptExit.ALLOC_SLOW);
    if (done != null) sljit_set_label(done, sljit_emit_label(c));
    self.def_value(i, R0);
    self.count_alloc(&self.h.opt.alloc_runs);
}

// The NEW_OBJECT of a sunk allocation: no object, only the check that the state its site validated
// (OptSinkSite) still holds, else vm::jit_opt_sink_check validates the site again with the registers
// in use saved around the call; what that refuses leaves for the baseline code at the NEW_OBJ.
fn void OptCg.emit_sunk_object(&self, uint i, OptNode* n) {
    OptSink* sk = &self.g.sinks[(sz)n.c];
    OptSinkSite* site = self.new_site(n, (CompiledFunction*)(usz)n.imm);
    site.add_count = sk.add_count;
    site.read_count = sk.read_count;
    for (uint k = 0; k < sk.add_count; k++) site.keys[k] = sk.keys[k];
    for (uint k = 0; k < sk.read_count; k++) site.read_keys[k] = sk.reads[k];
    sk.site = site;
    self.load_constructor(n);
    self.emit_site_check(i, site);
    self.count_alloc(&self.h.opt.sink_runs);
}

// With --jit-count-ops, the count of `counter` raised where the code passes.
fn void OptCg.count_alloc(&self, ulong* counter) {
    if (!self.h.jit_stats.count_ops) return;
    long at = (long)(usz)counter;
    sljit_emit_op2(self.a.c, SLJIT_ADD, SLJIT_MEM, at, SLJIT_MEM, at, SLJIT_IMM, 1);
}

// The sunk objects an exit from node `node` sees (its OptMat entries), after its dirty registers
// are stored: each allocated by vm::jit_opt_sink_materialize with the fields it has there, and
// stored to every register that holds it.
fn bool OptCg.has_mats(&self, uint node) {
    foreach (&m : self.g.mats) if (m.node == node) return true;
    return false;
}

fn void OptCg.materialize(&self, uint node) {
    if (node == NO_NODE || self.g.mats.len() == 0) return;
    void* c = self.a.c;
    OptNode* n = &self.g.nodes[node];
    // The field values into each site first: the calls clobber the registers that hold them.
    foreach (&m : self.g.mats) {
        if (m.node != node) continue;
        OptSinkSite* site = (OptSinkSite*)self.g.sinks[(sz)m.sink].site;
        for (uint k = 0; k < m.count; k++) {
            uint v = self.g.mat_vals[(sz)(m.vals_first + k)];
            int r = R0;
            if (self.g.nodes[v].rep == OptRep.VALUE) {
                r = self.value_reg(v, R0);
            } else {
                self.box_node(v, R0);
            }
            sljit_emit_op1(c, SLJIT_MOV, SLJIT_MEM, (long)(usz)&site.values[k], r, 0);
        }
    }
    foreach (&m : self.g.mats) {
        if (m.node != node) continue;
        OptSinkSite* site = (OptSinkSite*)self.g.sinks[(sz)m.sink].site;
        sljit_emit_op1(c, SLJIT_MOV, R0, 0, self.a.ds, 0);
        sljit_emit_op1(c, SLJIT_MOV, R1, 0, SLJIT_IMM, (long)(usz)site);
        sljit_emit_op1(c, SLJIT_MOV, R2, 0, SLJIT_IMM, (long)m.count);
        self.a.c_call(SLJIT_ARGS3WWW, SLJIT_IMM, (long)(usz)&vm::jit_opt_sink_materialize);
        for (uint k = 0; k < n.dirty_count; k++) {
            OptDirty d = self.g.dirty[(sz)(n.dirty_first + k)];
            OptNode* nd = &self.g.nodes[d.node];
            if (nd.sunk && nd.c == m.sink) self.store_object(d.reg, R0);
        }
    }
}

// PUTTHISC of an inlined constructor that adds its key to an object, as the baseline's emit_put does
// through an absent-property entry: the key check, then the put-absent subroutine's inline add; a
// state it does not cover calls vm::jit_put_absent with the registers in use saved, and what that
// refuses leaves for the baseline code before anything is written.
fn void OptCg.emit_add_field(&self, uint i, OptNode* n) {
    void* c = self.a.c;
    Asm* a = self.a;
    self.decode(n);
    a.call.len = 0;
    void* known = null;
    if (n.cc == 1 && !self.emit_known_add(n, &known)) return;
    CompiledFunction* f = self.g.fns[n.fidx].f;
    long ic = (long)(usz)&((hobject::ICEntry*)f.ic_entries)[a.next - 1];
    long key = (long)(usz)f.constants[a.w.c].get_heapptr();
    // The value's address: its window slot, or OptCode.value for a boxed node.
    long boxed = (long)(usz)&self.oc.value;
    if (n.a == NO_NODE) {
        sljit_emit_op2(c, SLJIT_ADD, R3, 0, a.regs, 0, SLJIT_IMM, (long)a.w.a * TVal::size);
    } else {
        self.value_to(n.a, R2);
        sljit_emit_op1(c, SLJIT_MOV, SLJIT_MEM, boxed, R2, 0);
        sljit_emit_op1(c, SLJIT_MOV, R3, 0, SLJIT_IMM, boxed);
    }
    int rr = self.value_reg(n.b, R1);
    sljit_emit_op2(c, SLJIT_XOR, R1, 0, rr, 0, k_obj_op(), k_obj_w());
    sljit_emit_op1(c, SLJIT_MOV, R2, 0, SLJIT_IMM, ic);
    a.put_key_check(key, -1, &a.call);
    a.subs.push({ .jump = sljit_emit_jump(c, SLJIT_FAST_CALL), .sub = PUT_ABSENT_FAST_SUB });
    void* added = sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R0, 0, SLJIT_IMM, 0);
    // The subroutine leaves R1 and R2; R3 is the value's address again.
    if (n.a == NO_NODE) {
        sljit_emit_op2(c, SLJIT_ADD, R3, 0, a.regs, 0, SLJIT_IMM, (long)a.w.a * TVal::size);
    } else {
        sljit_emit_op1(c, SLJIT_MOV, R3, 0, SLJIT_IMM, boxed);
    }
    self.spill_live(i, true);
    sljit_emit_op1(c, SLJIT_MOV, R0, 0, a.heap, 0);
    self.a.c_call(SLJIT_ARGS4WWWW, SLJIT_IMM, (long)(usz)&vm::jit_put_absent);
    sljit_emit_op1(c, SLJIT_MOV_U8, R0, 0, R0, 0);
    self.spill_live(i, false);
    a.call.add(sljit_emit_cmp(c, SLJIT_EQUAL, R0, 0, SLJIT_IMM, 0));
    sljit_set_label(added, sljit_emit_label(c));
    self.exit_calls(i, OptExit.SHAPE);
    if (known != null) sljit_set_label(known, sljit_emit_label(c));
}

// A known ADD_FIELD (cc 1): the object is one this code is building, the NEW_OBJECT validated the
// key against the prototype chain, and its shape is the one the previous add left, so the value
// goes into the next slot and the object takes n.shape, pinned so that its id stays its own. The
// object is young and nothing has scanned it since it was allocated (shaded while marking), so the
// store needs no barrier. A value that is neither inert nor an object (from the window, or a node
// that may hold a string) needs its count and takes the cache's path, which the caller emits next: true then, with `done` the jump past it.
fn bool OptCg.emit_known_add(&self, OptNode* n, void** done) {
    void* c = self.a.c;
    Asm* a = self.a;
    hobject::Shape* sh = self.h.get_shape(n.shape);
    sh.pinned = true;
    uint slot = sh.offset + sh.own_count - 1;
    void* other = null;
    if (n.a == NO_NODE) {
        a.load(R2, a.w.a);
    } else {
        self.value_to(n.a, R2);
    }
    // A string is counted as Heap.init_slot_ref counts it, its object then marked for teardown
    // (Asm.emit_fill_elements: the fresh object needs no barrier).
    void* counted = null;
    int rr = self.value_reg(n.b, R1);
    if ((n.a == NO_NODE || self.g.nodes[n.a].counted) && !inline_alloc_ok()) {
        void* inert = sljit_emit_cmp(c, SLJIT_LESS, R2, 0, SLJIT_IMM, K_STRING_START);
        sljit_emit_op2(c, SLJIT_XOR, R0, 0, R2, 0, k_obj_op(), k_obj_w());
        other = sljit_emit_cmp(c, SLJIT_GREATER_EQUAL, R0, 0, span_op(), span_w());
        sljit_set_label(inert, sljit_emit_label(c));
    } else if (n.a == NO_NODE || self.g.nodes[n.a].counted) {
        Jumps plain;
        plain.add(sljit_emit_cmp(c, SLJIT_LESS, R2, 0, SLJIT_IMM, K_STRING_START));
        sljit_emit_op2(c, SLJIT_XOR, R0, 0, R2, 0, k_obj_op(), k_obj_w());
        plain.add(sljit_emit_cmp(c, SLJIT_LESS, R0, 0, span_op(), span_w()));
        sljit_emit_op2(c, SLJIT_XOR, R0, 0, R2, 0, SLJIT_IMM, K_STRING_START);
        other = sljit_emit_cmp(c, SLJIT_GREATER_EQUAL, R0, 0, span_op(), span_w());
        sljit_emit_op1(c, SLJIT_MOV_U32, R3, 0, SLJIT_MEM | R0, a.lay.str_refcount);
        plain.add(sljit_emit_cmp(c, SLJIT_EQUAL | SLJIT_32, R3, 0, SLJIT_IMM, (long)types::STRING_PINNED_REFCOUNT));
        sljit_emit_op2(c, SLJIT_ADD, R3, 0, R3, 0, SLJIT_IMM, 1);
        sljit_emit_op1(c, SLJIT_MOV_U32, SLJIT_MEM | R0, a.lay.str_refcount, R3, 0);
        counted = sljit_emit_jump(c, SLJIT_JUMP);
        plain.bind(sljit_emit_label(c));
    }
    sljit_emit_op2(c, SLJIT_XOR, R1, 0, rr, 0, k_obj_op(), k_obj_w());
    a.prop_base(R0, R1);
    sljit_emit_op1(c, SLJIT_MOV, SLJIT_MEM | R0, (long)slot * TVal::size, R2, 0);
    sljit_emit_op1(c, SLJIT_MOV_U32, SLJIT_MEM | R1, a.lay.obj_shape, SLJIT_IMM, (long)n.shape);
    sljit_emit_op1(c, SLJIT_MOV_U32, SLJIT_MEM | R1, a.lay.obj_prop_count, SLJIT_IMM, (long)slot + 1);
    if (counted != null) {
        void* stored = sljit_emit_jump(c, SLJIT_JUMP);
        sljit_set_label(counted, sljit_emit_label(c));
        sljit_emit_op2(c, SLJIT_XOR, R1, 0, rr, 0, k_obj_op(), k_obj_w());
        a.prop_base(R0, R1);
        sljit_emit_op1(c, SLJIT_MOV, SLJIT_MEM | R0, (long)slot * TVal::size, R2, 0);
        sljit_emit_op1(c, SLJIT_MOV_U32, SLJIT_MEM | R1, a.lay.obj_shape, SLJIT_IMM, (long)n.shape);
        sljit_emit_op1(c, SLJIT_MOV_U32, SLJIT_MEM | R1, a.lay.obj_prop_count, SLJIT_IMM, (long)slot + 1);
        // An object the pools could not place has no teardown bit: the sweep tears every such one down.
        hobject::ObjFlags fallback;
        fallback.pool_fallback = true;
        sljit_emit_op1(c, SLJIT_MOV_U32, R3, 0, SLJIT_MEM | R1, 0);
        sljit_emit_op2(c, SLJIT_AND, R3, 0, R3, 0, SLJIT_IMM, (long)(uint)fallback);
        void* unpooled = sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R3, 0, SLJIT_IMM, 0);
        sljit_emit_op1(c, SLJIT_MOV, R0, 0, R1, 0);
        a.emit_needs_teardown();
        sljit_set_label(unpooled, sljit_emit_label(c));
        sljit_set_label(stored, sljit_emit_label(c));
    }
    if (other == null) return false;
    *done = sljit_emit_jump(c, SLJIT_JUMP);
    sljit_set_label(other, sljit_emit_label(c));
    return true;
}

// The callee of a CALL_VAR or CALL_GLOBAL, read as GETVAR or GETGLOBAL read it and stored in the
// callee register.
fn void OptCg.emit_load_var(&self, uint i, OptNode* n) {
    Asm* a = self.a;
    a.decode((uint)n.imm);
    a.call.len = 0;
    a.alt.len = 0;
    long vic = (long)(usz)&((hobject::VarICEntry*)a.f.var_ic_entries)[a.next - 1];
    uint ra = a.w.a;
    // A scoped read of an inlined body takes the scope of that body's closure, not the running frame's.
    uint creg = uint::max;
    int closure = -1;
    if (n.fidx != 0) {
        ra += self.g.fns[n.fidx].reg_base;
        if (n.cc != 0) {
            creg = self.g.fns[n.fidx].reg_base - 2;
            closure = n.b != NO_NODE ? self.value_reg(n.b, R3) : -1;
        }
    }
    a.var_slot(vic, n.cc != 0, creg, closure);
    if (n.cc != 0) {
        sljit_emit_op1(self.a.c, SLJIT_MOV_U8, R1, 0, SLJIT_MEM | R2, a.lay.vic_flags);
        sljit_emit_op2(self.a.c, SLJIT_AND, R1, 0, R1, 0, SLJIT_IMM, a.lay.accessor_mask);
        a.call.add(sljit_emit_cmp(self.a.c, SLJIT_NOT_EQUAL, R1, 0, SLJIT_IMM, 0));
    }
    sljit_emit_op1(self.a.c, SLJIT_MOV, R0, 0, SLJIT_MEM | R0, 0);
    a.guard_not_tdz();
    // A moved entry re-arms in the baseline code.
    for (uint k = 0; k < a.alt.len; k++) self.exit_at(a.alt.at[k], i, OptExit.SLOW_PATH);
    a.alt.len = 0;
    self.exit_calls(i, OptExit.SLOW_PATH);
    // A callee register beyond the caller's frame: the value stays in a register.
    if (n.rep == OptRep.VALUE) {
        self.finish_value(i, n);
        return;
    }
    // Into the window as Asm.emit_get_var publishes it, with an object the collector's mark has not
    // reached marked here rather than left to the baseline code.
    self.publish(i, ra);
}

// GUARD_BINDING (OptBinding): its holder's layout and the folded-object epoch as the node's cc asks,
// then the binding itself (binding_tests).
fn void OptCg.emit_guard_binding(&self, uint i, OptNode* n) {
    OptBinding* b = &self.g.bindings[(usz)n.imm];
    ulong bits = 1UL << n.imm;
    if ((n.cc & OPT_GUARD_WATCH) != 0) {
        self.a.call.len = 0;
        self.binding_tests(OPT_FACT_WATCH);
        self.exit_calls(i, OptExit.WATCH);
        return;
    }
    if ((n.cc & OPT_GUARD_LAYOUT) != 0) bits |= 1UL << (OPT_FACT_HOLDER + b.holder);
    if ((n.cc & OPT_GUARD_EPOCH) != 0) bits |= OPT_FACT_EPOCH;
    self.a.call.len = 0;
    self.binding_tests(bits);
    self.exit_calls(i, OptExit.BINDING);
    self.shade_bindings(bits, i);
}

// The tests of the facts `bits` of OptBuild.fact_bindings, into the jumps Asm.call collects: each
// holder's layout, the folded-object and watch epochs, then each binding's value and a typed array
// value's store in place.
fn void OptCg.binding_tests(&self, ulong bits) {
    void* c = self.a.c;
    Asm* a = self.a;
    Layout* l = a.lay;
    for (uint k = 0; k < OPT_HOLDERS_MAX; k++) {
        if ((bits & (1UL << (OPT_FACT_HOLDER + k))) == 0) continue;
        OptHolder* ho = &self.g.holders[k];
        sljit_emit_op1(c, SLJIT_MOV_U32, R0, 0, SLJIT_MEM, (long)(usz)ho.obj + l.obj_shape);
        a.call.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL | SLJIT_32, R0, 0, SLJIT_IMM, ho.shape));
        sljit_emit_op1(c, SLJIT_MOV, R0, 0, SLJIT_MEM | a.heap, l.heap_shapes);
        sljit_emit_op1(c, SLJIT_MOV, R0, 0, SLJIT_MEM | R0, (long)ho.shape * 8);
        sljit_emit_op1(c, SLJIT_MOV_U32, R0, 0, SLJIT_MEM | R0, l.shape_gen);
        a.call.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL | SLJIT_32, R0, 0, SLJIT_IMM, ho.gen));
    }
    if ((bits & OPT_FACT_EPOCH) != 0) {
        sljit_emit_op1(c, SLJIT_MOV_U32, R0, 0, SLJIT_MEM | a.heap, (long)((char*)&self.h.folded_epoch - (char*)self.h));
        a.call.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL | SLJIT_32, R0, 0, SLJIT_IMM, self.g.folded_epoch));
    }
    if ((bits & OPT_FACT_WATCH) != 0) {
        sljit_emit_op1(c, SLJIT_MOV_U32, R0, 0, SLJIT_MEM | a.heap, (long)((char*)&self.h.opt.watch_epoch - (char*)self.h));
        a.call.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL | SLJIT_32, R0, 0, SLJIT_IMM, self.g.watch_epoch));
    }
    for (uint k = 0; k < OPT_BINDINGS_MAX; k++) {
        if ((bits & (1UL << k)) == 0) continue;
        OptBinding* b = &self.g.bindings[k];
        if (b.slot != null) {
            sljit_emit_op1(c, SLJIT_MOV, R0, 0, SLJIT_MEM, (long)(usz)b.slot);
            a.call.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R0, 0, SLJIT_IMM, (long)b.value));
        }
        OptView view;
        if (opt_const_view(b.value, false, &view)) {
            sljit_emit_op1(c, SLJIT_MOV, R1, 0, SLJIT_MEM, (long)(usz)view.buffer + l.ab_data);
            a.call.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R1, 0, SLJIT_IMM, (long)(usz)view.base));
        }
    }
}

// While the collector marks, the object values of the bindings among `bits` are shaded, as a load
// of one would be: the code may store it to the window. The registers live at node `i` are kept.
fn void OptCg.shade_bindings(&self, ulong bits, uint i) {
    void* c = self.a.c;
    for (uint k = 0; k < OPT_BINDINGS_MAX; k++) {
        if ((bits & (1UL << k)) == 0) continue;
        TVal v = { .bits = self.g.bindings[k].value };
        if (!v.is_object()) continue;
        void* quiet = self.not_marking();
        sljit_emit_op1(c, SLJIT_MOV, R0, 0, SLJIT_IMM, (long)v.bits);
        self.shade(R0);
        sljit_set_label(quiet, sljit_emit_label(c));
    }
}

// GUARD_CAPTURE (OptCapture): the running closure's capture record (capture_tests).
fn void OptCg.emit_guard_capture(&self, uint i, OptNode* n) {
    self.a.call.len = 0;
    self.capture_tests(self.g.captures[(usz)n.imm].index);
    self.exit_calls(i, OptExit.CAPTURE);
}

// The test of the running closure's capture record `index` against the one the code folded
// (OptCapture), from the records the entry loaded (emit_cap_refs), word by word, into the jumps
// Asm.call collects. Zero records, a frame running code other than the closure's own, fails it too.
fn void OptCg.capture_tests(&self, uint index) {
    void* c = self.a.c;
    OptCapture* cap;
    foreach (&x : self.g.captures) if (x.index == index) cap = x;
    long at = (long)index * hobject::CaptureRef::size;
    sljit_emit_op1(c, SLJIT_MOV, R1, 0, SLJIT_MEM | reg_sp(), self.cap_slot);
    self.a.call.add(sljit_emit_cmp(c, SLJIT_EQUAL, R1, 0, SLJIT_IMM, 0));
    for (uint w = 0; w < 2; w++) {
        sljit_emit_op1(c, SLJIT_MOV, R0, 0, SLJIT_MEM | R1, at + (long)w * 8);
        self.a.call.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R0, 0, SLJIT_IMM, (long)cap.words[w]));
    }
}

// A TYPEOF of an inlined body: the interned name for the operand's tag, into the node's home slot.
// The names are the heap's own builtin strings, which no collection reclaims, so a home beyond the
// caller's frame needs no scan extent (see the header of opt_ir.c3).
fn void OptCg.emit_typeof(&self, uint i, OptNode* n) {
    Asm* a = self.a;
    if (n.cc == 1) {
        a.typeof_const(heap::BuiltinStr.NUMBER, n.home);
        return;
    }
    if (n.a != NO_NODE) {
        int src = self.value_reg(n.a, R0);
        if (src != R0) sljit_emit_op1(self.a.c, SLJIT_MOV, R0, 0, src, 0);
    } else {
        a.load(R0, (uint)n.imm);
    }
    a.typeof_value(n.home);
    // The instructions the name is not read off by tag, and the [[IsHTMLDDA]] object, are the thunk's.
    self.exit_calls(i, OptExit.SLOW_PATH);
}

// An INSTANCEOF of an inlined body: the baseline's inline path on the window, its misses exits.
// Of rep VALUE, the walk of the prototype chain for the prototype object key (OptBuild.instance_of).
fn void OptCg.emit_instanceof(&self, uint i, OptNode* n) {
    void* c = self.a.c;
    if (n.rep == OptRep.VALUE) {
        self.emit_prototype_walk(i, n);
        return;
    }
    self.decode(n);
    if (n.a != NO_NODE) {
        int r = self.value_reg(n.a, R4);
        if (r != R4) sljit_emit_op1(c, SLJIT_MOV, R4, 0, r, 0);
    } else {
        self.a.load(R4, self.a.w.b);
    }
    if (n.b != NO_NODE) {
        int r = self.value_reg(n.b, R0);
        if (r != R0) sljit_emit_op1(c, SLJIT_MOV, R0, 0, r, 0);
    } else {
        self.a.load(R0, self.a.w.c);
    }
    Jumps miss;
    Jumps done;
    self.a.instanceof_inline(&miss, &done, true);
    miss.bind(sljit_emit_label(self.a.c));
    self.exit_at(sljit_emit_jump(self.a.c, SLJIT_JUMP), i, OptExit.SLOW_PATH);
    done.bind(sljit_emit_label(self.a.c));
}

// `x instanceof F` for the value of node a (or of window slot imm), as OrdinaryHasInstance with F's
// prototype object key: false for a primitive, else the walk of x's prototype chain. A proxy on the
// chain, a light function and a chain longer than MAX_PROTO_DEPTH leave for the baseline code.
fn void OptCg.emit_prototype_walk(&self, uint i, OptNode* n) {
    void* c = self.a.c;
    Asm* a = self.a;
    if (n.a != NO_NODE) {
        self.value_to(n.a, R0);
    } else {
        a.load(R0, (uint)n.imm);
    }
    a.call.len = 0;
    Jumps yes;
    Jumps no;
    sljit_emit_op2(c, SLJIT_XOR, R1, 0, R0, 0, k_obj_op(), k_obj_w());
    void* object = sljit_emit_cmp(c, SLJIT_LESS, R1, 0, span_op(), span_w());
    sljit_emit_op2(c, SLJIT_XOR, R2, 0, R0, 0, SLJIT_IMM, K_LIGHTFUNC);
    a.call.add(sljit_emit_cmp(c, SLJIT_LESS, R2, 0, span_op(), span_w()));
    no.add(sljit_emit_jump(c, SLJIT_JUMP));
    sljit_set_label(object, sljit_emit_label(c));
    sljit_emit_op1(c, SLJIT_MOV, R2, 0, SLJIT_IMM, (long)hobject::MAX_PROTO_DEPTH);
    void* loop = sljit_emit_label(c);
    sljit_emit_op1(c, SLJIT_MOV_U32, R3, 0, SLJIT_MEM | R1, 0);
    sljit_emit_op2(c, SLJIT_AND, R3, 0, R3, 0, SLJIT_IMM, a.lay.proxy_mask);
    a.call.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R3, 0, SLJIT_IMM, 0));
    sljit_emit_op1(c, SLJIT_MOV, R1, 0, SLJIT_MEM | R1, a.lay.obj_proto);
    yes.add(sljit_emit_cmp(c, SLJIT_EQUAL, R1, 0, SLJIT_IMM, (long)(usz)n.key));
    no.add(sljit_emit_cmp(c, SLJIT_EQUAL, R1, 0, SLJIT_IMM, 0));
    sljit_emit_op2(c, SLJIT_SUB, R2, 0, R2, 0, SLJIT_IMM, 1);
    sljit_set_label(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R2, 0, SLJIT_IMM, 0), loop);
    a.call.add(sljit_emit_jump(c, SLJIT_JUMP));
    self.exit_calls(i, OptExit.SLOW_PATH);
    self.def_bool_jumps(i, n, &yes, &no);
}

// The object an inlined body allocates, built inline as the baseline emitter builds it and stored
// boxed to its slot. The allocation adopts the object as a temporary root, so the slot needs no
// scan extent until an exit publishes the frame (see the header of opt_ir.c3); a case the inline
// allocator does not cover, and a failed allocation, leave for the baseline code at the instruction.
fn void OptCg.emit_alloc(&self, uint i, OptNode* n) {
    void* c = self.a.c;
    Asm* a = self.a;
    a.decode(n.pc);
    a.call.len = 0;
    InlineAlloc plan;
    if (!inline_alloc_ok() || !a.inline_alloc_plan(&plan)) {
        self.exit_at(sljit_emit_jump(c, SLJIT_JUMP), i, OptExit.ALLOC_SLOW);
        return;
    }
    Jumps slow;
    a.emit_inline_alloc(&plan, &slow);
    // The boxed object into the result register, which holds no count to release.
    sljit_emit_op2(c, SLJIT_OR, R0, 0, R0, 0, k_obj_op(), k_obj_w());
    a.store(n.home, R0);
    a.track_heap_store(n.home);
    void* done = sljit_emit_jump(c, SLJIT_JUMP);
    for (uint k = 0; k < slow.len; k++) self.exit_at(slow.at[k], i, OptExit.ALLOC_SLOW);
    sljit_set_label(done, sljit_emit_label(c));
    self.exit_calls(i, OptExit.ALLOC_SLOW);
    self.count_alloc(&self.h.opt.alloc_runs);
}

// The object's slot written from a value of the body, as th_init_slot's store_slot_ref, for an
// object the body just allocated: the slot index is the instruction's immediate.
fn void OptCg.emit_init_slot(&self, uint i, OptNode* n) {
    void* c = self.a.c;
    Asm* a = self.a;
    self.decode(n);
    a.call.len = 0;
    if (n.b != NO_NODE) {
        int or = self.value_reg(n.b, R4);
        if (or != R0) sljit_emit_op1(c, SLJIT_MOV, R0, 0, or, 0);
    } else {
        a.load(R0, a.w.a);
    }
    a.unbox_object(R1, R0);
    a.prop_base(R0, R1);
    sljit_emit_op2(c, SLJIT_ADD, R0, 0, R0, 0, SLJIT_IMM, (long)a.w.b * 8);
    self.store_slot_value(i, n.a, a.w.c);
    self.exit_calls(i, OptExit.SLOW_PATH);
}

// A callee's returned window slot copied to the call's result register: the store of an
// instruction that writes it from another, with publish's watermark and barrier.
fn void OptCg.emit_copy_window(&self, uint i, OptNode* n) {
    Asm* a = self.a;
    a.call.len = 0;
    uint base = self.g.fns[n.fidx].reg_base;
    if (n.cc == 3) {
        a.load(R0, (uint)n.imm);
    } else if (n.cc == 4) {
        a.load_this(R0);
    } else {
        a.decode((uint)n.imm);
        a.load(R0, n.cc == 1 ? base - 1 : (n.cc == 2 ? a.w.b : a.w.a) + base);
    }
    if (n.rep == OptRep.VALUE) {
        self.finish_value(i, n);
        return;
    }
    self.publish(i, n.home);
}

// The guard of an inlined forwarding call: the value is the builtin function numbered n.imm (an
// unbound, non-proxy builtin function object, as builtins::is_intrinsic_apply asks).
fn void OptCg.emit_check_builtin(&self, uint i, OptNode* n) {
    void* c = self.a.c;
    Asm* a = self.a;
    CallLayout* k = call_layout();
    if (n.a != NO_NODE) {
        int r = self.value_reg(n.a, R1);
        if (r != R1) sljit_emit_op1(c, SLJIT_MOV, R1, 0, r, 0);
    } else {
        a.load(R1, n.home);
    }
    // A builtin not yet given an object of its realm is a light function.
    void* light = sljit_emit_cmp(c, SLJIT_EQUAL, R1, 0, SLJIT_IMM, (long)((types::TAG_LIGHTFUNC << 48) | (ulong)n.imm));
    sljit_emit_op2(c, SLJIT_XOR, R0, 0, R1, 0, k_obj_op(), k_obj_w());
    self.exit_at(sljit_emit_cmp(c, SLJIT_GREATER_EQUAL, R0, 0, span_op(), span_w()), i, OptExit.CALLEE);
    self.exit_at(sljit_emit_cmp(c, SLJIT_EQUAL, R0, 0, SLJIT_IMM, 0), i, OptExit.CALLEE);
    sljit_emit_op1(c, SLJIT_MOV_U32, R4, 0, SLJIT_MEM | R0, 0);
    sljit_emit_op2(c, SLJIT_AND, R4, 0, R4, 0, SLJIT_IMM, k.fn_mask);
    self.exit_at(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R4, 0, SLJIT_IMM, k.fn_want), i, OptExit.CALLEE);
    sljit_emit_op1(c, SLJIT_MOV_S32, R4, 0, SLJIT_MEM | R0, k.fn_builtin);
    self.exit_at(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R4, 0, SLJIT_IMM, n.imm), i, OptExit.CALLEE);
    sljit_set_label(light, sljit_emit_label(c));
}

// MATH. The INT32 forms and FLOAT64 ABS, MIN and MAX are inline; SQRT, FLOOR and CEIL take the
// machine's instruction where the shim has one; everything else calls the function the builtin
// computes with, with the registers in use saved around the call.
fn void OptCg.emit_math(&self, uint i, OptNode* n) {
    void* c = self.a.c;
    OptMath m = (OptMath)n.imm;
    if (n.rep == OptRep.INT32) {
        self.emit_math_int(i, n, m);
        return;
    }
    int x = self.flt_reg(n.a, FR0);
    switch (m) {
        case ABS:
            int dst = self.flt_dst(i, FR0);
            sljit_emit_fop1(c, SLJIT_ABS_F64, dst, 0, x, 0);
            self.def_flt(i, dst);
            return;
        case MIN:
        case MAX:
            self.emit_math_minmax(i, n, x, m == MIN);
            return;
        case SQRT:
        case FLOOR:
        case CEIL:
            // The instruction works in place, on the result's register. Where there is none, nothing
            // was emitted and `x` is intact for the call.
            int dst = self.flt_dst(i, FR0);
            if (dst != x) sljit_emit_fop1(c, SLJIT_MOV_F64, dst, 0, x, 0);
            int done = m == SQRT ? sljit_shim_sqrt_f64(c, dst) : sljit_shim_round_f64(c, dst, m == FLOOR ? 1 : 0);
            if (done == 0) {
                self.def_flt(i, dst);
                return;
            }
        default:
    }
    self.spill_live(i, true);
    if (x != FR0) sljit_emit_fop1(c, SLJIT_MOV_F64, FR0, 0, x, 0);
    if (n.b != NO_NODE) {
        int y = self.flt_reg(n.b, FR1);
        if (y != FR1) sljit_emit_fop1(c, SLJIT_MOV_F64, FR1, 0, y, 0);
    }
    sljit_emit_icall(c, SLJIT_CALL, m.args == 2 ? SLJIT_ARGS2_F64 : SLJIT_ARGS1_F64, SLJIT_IMM, (long)(usz)opt_math_fn(m));
    self.spill_live(i, false);
    self.def_flt(i, FR0);
}

// The function a MATH call of `m` computes with: what the builtin calls.
fn void* opt_math_fn(OptMath m) {
    switch (m) {
        case FLOOR: return &opt_math_floor;
        case CEIL: return &opt_math_ceil;
        case ROUND: return &builtins::math_round;
        case SQRT: return &builtins::math_sqrt;
        case POW: return &builtins::math_pow_js;
        case SIN: return &builtins::math_sin;
        case COS: return &builtins::math_cos;
        case TAN: return &builtins::math_tan;
        case EXP: return &builtins::math_exp;
        case LOG: return &builtins::math_log;
        case ATAN: return &builtins::math_atan;
        case ATAN2: return &builtins::math_atan2;
        default: unreachable("MATH %s is inline", m);
    }
}

fn double opt_math_floor(double x) => math::floor(x);
fn double opt_math_ceil(double x) => math::ceil(x);

// FLOAT64 MIN or MAX of x (in register `x`) and n.b, as builtin_math_min and _max decide: NaN when
// either is, -0 below +0. Computed in FR0 from copies of the operands in FR0 and FR1, since the
// result's register may be either operand's.
fn void OptCg.emit_math_minmax(&self, uint i, OptNode* n, int x, bool min) {
    void* c = self.a.c;
    if (x != FR0) sljit_emit_fop1(c, SLJIT_MOV_F64, FR0, 0, x, 0);
    int y = self.flt_reg(n.b, FR1);
    if (y != FR1) sljit_emit_fop1(c, SLJIT_MOV_F64, FR1, 0, y, 0);
    void* nan = sljit_emit_fcmp(c, SLJIT_UNORDERED, FR0, 0, FR1, 0);
    // The other operand when it is the one on the result's side, the first otherwise.
    void* keep = sljit_emit_fcmp(c, min ? SLJIT_ORDERED_LESS : SLJIT_ORDERED_GREATER, FR0, 0, FR1, 0);
    void* other = sljit_emit_fcmp(c, min ? SLJIT_ORDERED_GREATER : SLJIT_ORDERED_LESS, FR0, 0, FR1, 0);
    // Equal: of +0 and -0 the sign bits decide, the minimum's set when either's is.
    sljit_emit_fcopy(c, SLJIT_COPY_FROM_F64, FR0, R0);
    sljit_emit_fcopy(c, SLJIT_COPY_FROM_F64, FR1, R1);
    sljit_emit_op2(c, min ? SLJIT_OR : SLJIT_AND, R0, 0, R0, 0, R1, 0);
    sljit_emit_fcopy(c, SLJIT_COPY_TO_F64, FR0, R0);
    void* done_eq = sljit_emit_jump(c, SLJIT_JUMP);
    sljit_set_label(nan, sljit_emit_label(c));
    sljit_emit_fop2(c, SLJIT_ADD_F64, FR0, 0, FR0, 0, FR1, 0);
    void* done_nan = sljit_emit_jump(c, SLJIT_JUMP);
    sljit_set_label(other, sljit_emit_label(c));
    sljit_emit_fop1(c, SLJIT_MOV_F64, FR0, 0, FR1, 0);
    void* end = sljit_emit_label(c);
    sljit_set_label(keep, end);
    sljit_set_label(done_eq, end);
    sljit_set_label(done_nan, end);
    self.def_flt(i, FR0);
}

// INT32 ABS, MIN and MAX. ABS exits (OVERFLOW) for -2^31, whose absolute value is no int32.
fn void OptCg.emit_math_int(&self, uint i, OptNode* n, OptMath m) {
    void* c = self.a.c;
    int x = self.int_reg(n.a, R0);
    int dst = self.int_dst(i, R2);
    if (m == ABS) {
        self.exit_at(sljit_emit_cmp(c, SLJIT_EQUAL | SLJIT_32, x, 0, SLJIT_IMM, (long)int::min), i, OptExit.OVERFLOW);
        if (dst != x) sljit_emit_op1(c, SLJIT_MOV, dst, 0, x, 0);
        void* pos = sljit_emit_cmp(c, SLJIT_SIG_GREATER_EQUAL | SLJIT_32, dst, 0, SLJIT_IMM, 0);
        sljit_emit_op2(c, SLJIT_SUB, dst, 0, SLJIT_IMM, 0, dst, 0);
        sljit_set_label(pos, sljit_emit_label(c));
        self.def_int(i, dst);
        return;
    }
    int y = self.int_reg(n.b, R1);
    // The result in R2 first: dst may be either operand's register.
    sljit_emit_op1(c, SLJIT_MOV, R2, 0, x, 0);
    void* keep = sljit_emit_cmp(c, (m == MIN ? SLJIT_SIG_LESS_EQUAL : SLJIT_SIG_GREATER_EQUAL) | SLJIT_32, x, 0, y, 0);
    sljit_emit_op1(c, SLJIT_MOV, R2, 0, y, 0);
    sljit_set_label(keep, sljit_emit_label(c));
    self.def_int(i, R2);
}

// ARRAY_PUSH: opt_array_push with the registers in use saved around the call; what it refuses
// leaves for the baseline code at the CALL.
fn void OptCg.emit_array_push(&self, uint i, OptNode* n) {
    void* c = self.a.c;
    Asm* a = self.a;
    self.decode(n);
    uint callee = a.w.b;
    if (n.a == NO_NODE) {
        a.load(R2, callee + 2);
    } else {
        self.value_to(n.a, R2);
    }
    if (n.b == NO_NODE) {
        a.load(R1, callee + 1);
    } else {
        int r = self.value_reg(n.b, R1);
        if (r != R1) sljit_emit_op1(c, SLJIT_MOV, R1, 0, r, 0);
    }
    sljit_emit_op2(c, SLJIT_XOR, R1, 0, R1, 0, k_obj_op(), k_obj_w());
    self.exit_at(sljit_emit_cmp(c, SLJIT_GREATER_EQUAL, R1, 0, span_op(), span_w()), i, OptExit.SLOW_PATH);
    self.spill_live(i, true);
    sljit_emit_op1(c, SLJIT_MOV, R0, 0, a.ds, 0);
    self.a.c_call(SLJIT_ARGS3WWW, SLJIT_IMM, (long)(usz)&opt_array_push);
    self.spill_live(i, false);
    self.exit_at(sljit_emit_cmp(c, SLJIT_SIG_LESS, R0, 0, SLJIT_IMM, 0), i, OptExit.SLOW_PATH);
    self.def_int(i, R0);
}

// REGEXP_EXEC with the registers in use saved around it: a non-global, non-sticky plain RegExp
// over a string runs its compiled body in line (emit_regexp_body), and anything else calls
// vm::jit_opt_regexp; what that refuses leaves for the baseline code at the CALL.
fn void OptCg.emit_regexp_exec(&self, uint i, OptNode* n) {
    void* c = self.a.c;
    Asm* a = self.a;
    self.decode(n);
    uint callee = a.w.b;
    if (n.a == NO_NODE) {
        a.load(R2, callee + 2);
    } else {
        self.value_to(n.a, R2);
    }
    if (n.b == NO_NODE) {
        a.load(R1, callee + 1);
    } else {
        int r = self.value_reg(n.b, R1);
        if (r != R1) sljit_emit_op1(c, SLJIT_MOV, R1, 0, r, 0);
    }
    self.spill_live(i, true);
    Jumps slow;
    void* done = null;
    if (types::USE_NANBOX && features::REGEXP) {
        self.emit_regexp_body(n.cc != 0, &slow);
        done = sljit_emit_jump(c, SLJIT_JUMP);
        slow.bind(sljit_emit_label(c));
        sljit_emit_op1(c, SLJIT_MOV, R1, 0, SLJIT_MEM | reg_sp(), REGEXP_RECV_OFF);
        sljit_emit_op1(c, SLJIT_MOV, R2, 0, SLJIT_MEM | reg_sp(), REGEXP_ARG_OFF);
    }
    sljit_emit_op1(c, SLJIT_MOV, R0, 0, a.ds, 0);
    sljit_emit_op1(c, SLJIT_MOV, R3, 0, SLJIT_IMM, (long)n.cc);
    self.a.c_call(SLJIT_ARGS4WWWW, SLJIT_IMM, (long)(usz)&vm::jit_opt_regexp);
    self.spill_live(i, false);
    self.exit_at(sljit_emit_cmp(c, SLJIT_EQUAL, R0, 0, SLJIT_IMM, 0), i, OptExit.SLOW_PATH);
    void* defined = sljit_emit_jump(c, SLJIT_JUMP);
    if (done != null) {
        sljit_set_label(done, sljit_emit_label(c));
        self.spill_live(i, false);
    }
    sljit_set_label(defined, sljit_emit_label(c));
    self.def_value(i, R0);
}

// STRING_REGEXP: vm::jit_opt_string_regexp over the call's receiver and arguments, copied from the
// window to the frame's CALL_FRAME_BYTES, with the registers in use saved around it; what it
// refuses leaves for the baseline code at the CALL.
fn void OptCg.emit_string_regexp(&self, uint i, OptNode* n) {
    void* c = self.a.c;
    Asm* a = self.a;
    self.decode(n);
    uint callee = a.w.b;
    for (uint k = 1; k <= 3; k++) {
        a.load(R0, callee + k);
        sljit_emit_op1(c, SLJIT_MOV, SLJIT_MEM | reg_sp(), (long)k * 8, R0, 0);
    }
    self.spill_live(i, true);
    sljit_emit_op1(c, SLJIT_MOV, R0, 0, a.ds, 0);
    sljit_get_local_base(c, R1, 0, 8);
    sljit_emit_op2(c, SLJIT_ADD, R2, 0, a.regs, 0, SLJIT_IMM, (long)a.w.a * TVal::size);
    sljit_emit_op1(c, SLJIT_MOV, R3, 0, SLJIT_IMM, (long)n.cc);
    a.c_call(SLJIT_ARGS4WWWW, SLJIT_IMM, (long)(usz)&vm::jit_opt_string_regexp);
    self.spill_live(i, false);
    self.exit_at(sljit_emit_cmp(c, SLJIT_EQUAL, R0, 0, SLJIT_IMM, 0), i, OptExit.SLOW_PATH);
}

// BUILTIN_LEAF: vm::jit_leaf_call over the call's window slots, with the dirty registers stored
// and the registers in use saved around it; what it declines leaves for the baseline code at the
// CALL, which nothing was written for.
fn void OptCg.emit_builtin_leaf(&self, uint i, OptNode* n) {
    void* c = self.a.c;
    Asm* a = self.a;
    self.store_dirty(n.dirty_first, n.dirty_count);
    self.decode(n);
    self.spill_live(i, true);
    sljit_emit_op1(c, SLJIT_MOV, R0, 0, a.heap, 0);
    sljit_emit_op1(c, SLJIT_MOV, R1, 0, a.regs, 0);
    sljit_emit_op1(c, SLJIT_MOV, R2, 0, SLJIT_IMM, (long)(usz)&((hobject::ICEntry*)a.f.ic_entries)[a.next - 1]);
    sljit_emit_op1(c, SLJIT_MOV, R3, 0, SLJIT_IMM, (long)vm::jit_leaf_meta(compiler::tailcall_base(a.w.op), a.w));
    a.c_call_frameless(SLJIT_ARGS4WWWW, SLJIT_IMM, (long)(usz)&vm::jit_leaf_call);
    self.spill_live(i, false);
    self.exit_at(sljit_emit_cmp(c, SLJIT_EQUAL, R0, 0, SLJIT_IMM, 0), i, OptExit.SLOW_PATH);
}

// Where emit_regexp_body keeps the boxed receiver and argument across the body's call, in the
// frame's CALL_FRAME_BYTES, which no subroutine uses meanwhile.
const long REGEXP_RECV_OFF = 8;
const long REGEXP_ARG_OFF = 16;

// RegExpBuiltinExec, or test's boolean, of the boxed receiver in R1 over the boxed argument in R2,
// into R0 boxed, without leaving generated code unless the match builds an array: a RegExp of the
// shared plain shape, whose lastIndex g or y read and write as an int,
// for test with the pristine prototype it is created with, a flat string, and a compiled body for
// the string's width and at most re_bindings::RE_CALL_GROUPS groups. The body runs from 0 through
// Heap.regexp_call. Any other case, and an interrupted run, takes the jumps in `slow` with R1 and
// R2 saved at REGEXP_RECV_OFF and REGEXP_ARG_OFF and nothing done.
fn void OptCg.emit_regexp_body(&self, bool test, Jumps* slow) {
$if features::REGEXP:
    void* c = self.a.c;
    Asm* a = self.a;
    Layout* l = a.lay;
    Heap* h = a.hp;
    int m = SLJIT_MEM;
    int hp = m | a.heap;
    int sp = m | reg_sp();
    HObject* o = (HObject*)(usz)4096;
    hobject::HObjectExtra* x = o.extra_ptr();
    re_native::ReNative* nat = (re_native::ReNative*)(usz)4096;
    hstring::HString* str = (hstring::HString*)(usz)4096;
    hstring::HStringFlags odd = { .is_symbol = true, .has_extdata = true };
    hstring::HStringFlags wide = { .is_wide = true };
    sljit_emit_op1(c, SLJIT_MOV, sp, REGEXP_RECV_OFF, R1, 0);
    sljit_emit_op1(c, SLJIT_MOV, sp, REGEXP_ARG_OFF, R2, 0);
    sljit_emit_op2(c, SLJIT_XOR, R3, 0, R1, 0, k_obj_op(), k_obj_w());
    slow.add(sljit_emit_cmp(c, SLJIT_GREATER_EQUAL, R3, 0, span_op(), span_w()));
    slow.add(sljit_emit_cmp(c, SLJIT_EQUAL, R3, 0, SLJIT_IMM, 0));
    sljit_emit_op1(c, SLJIT_MOV_U32, R0, 0, m | R3, 0);
    sljit_emit_op2(c, SLJIT_AND, R0, 0, R0, 0, SLJIT_IMM, l.class_mask | l.proxy_mask);
    slow.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R0, 0, SLJIT_IMM, l.class_regexp));
    sljit_emit_op1(c, SLJIT_MOV_U32, R0, 0, hp, (char*)&h.regexp_shape - (char*)h);
    slow.add(sljit_emit_cmp(c, SLJIT_EQUAL, R0, 0, SLJIT_IMM, 0));
    slow.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL | SLJIT_32, R0, 0, m | R3, l.obj_shape));
    sljit_emit_op1(c, SLJIT_MOV_U32, R0, 0, hp, (char*)&h.regexp_shape_epoch - (char*)h);
    slow.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL | SLJIT_32, R0, 0, hp, l.heap_epoch));
    // The start: 0, or with g or y a lastIndex the plain shape holds as an int, from 0 up.
    re_bindings::ReCall* call = &h.regexp_call;
    long start = (char*)&call.start - (char*)h;
    sljit_emit_op1(c, SLJIT_MOV_S32, R0, 0, m | R3, (char*)&x.regexp.flags - (char*)o);
    sljit_emit_op2(c, SLJIT_AND, R0, 0, R0, 0, SLJIT_IMM, 1 | 32);
    void* from_zero = sljit_emit_cmp(c, SLJIT_EQUAL, R0, 0, SLJIT_IMM, 0);
    a.prop_base(R0, R3);
    sljit_emit_op1(c, SLJIT_MOV, R0, 0, m | R0, 0);
    sljit_emit_op2(c, SLJIT_XOR, R0, 0, R0, 0, SLJIT_IMM, K_INT);
    slow.add(sljit_emit_cmp(c, SLJIT_GREATER, R0, 0, SLJIT_IMM, int::max));
    sljit_emit_op1(c, SLJIT_MOV_U32, hp, start, R0, 0);
    void* started = sljit_emit_jump(c, SLJIT_JUMP);
    sljit_set_label(from_zero, sljit_emit_label(c));
    sljit_emit_op1(c, SLJIT_MOV_U32, hp, start, SLJIT_IMM, 0);
    sljit_set_label(started, sljit_emit_label(c));
    if (test) {
        // test's RegExpExec must find the intrinsic exec.
        sljit_emit_op1(c, SLJIT_MOV, R0, 0, m | R3, l.obj_proto);
        slow.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R0, 0, hp, (char*)&h.regexp_proto - (char*)h));
        sljit_emit_op1(c, SLJIT_MOV_U8, R0, 0, hp, (char*)&h.regexp_pristine - (char*)h);
        slow.add(sljit_emit_cmp(c, SLJIT_EQUAL, R0, 0, SLJIT_IMM, 0));
    }
    sljit_emit_op1(c, SLJIT_MOV, R4, 0, m | R3, (char*)&x.regexp.regexp_data - (char*)o);
    slow.add(sljit_emit_cmp(c, SLJIT_EQUAL, R4, 0, SLJIT_IMM, 0));
    // re_wrapper.c keeps the native program first, null until a run prepares it.
    sljit_emit_op1(c, SLJIT_MOV, R4, 0, m | R4, 0);
    slow.add(sljit_emit_cmp(c, SLJIT_EQUAL, R4, 0, SLJIT_IMM, 0));
    sljit_emit_op1(c, SLJIT_MOV_U32, R0, 0, m | R4, (char*)&nat.prog.capture_count - (char*)nat);
    slow.add(sljit_emit_cmp(c, SLJIT_GREATER, R0, 0, SLJIT_IMM, re_bindings::RE_CALL_GROUPS));
    // The argument: a string with its units in line.
    sljit_emit_op2(c, SLJIT_XOR, R2, 0, R2, 0, SLJIT_IMM, K_STRING_START);
    slow.add(sljit_emit_cmp(c, SLJIT_GREATER_EQUAL, R2, 0, span_op(), span_w()));
    sljit_emit_op1(c, SLJIT_MOV_U32, R0, 0, m | R2, 0);
    sljit_emit_op2(c, SLJIT_AND, R1, 0, R0, 0, SLJIT_IMM, (long)(uint)odd);
    slow.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R1, 0, SLJIT_IMM, 0));
    sljit_emit_op2(c, SLJIT_AND, R0, 0, R0, 0, SLJIT_IMM, (long)(uint)wide);
    void* narrow = sljit_emit_cmp(c, SLJIT_EQUAL, R0, 0, SLJIT_IMM, 0);
    sljit_emit_op1(c, SLJIT_MOV, R4, 0, m | R4, (char*)&nat.code_wide - (char*)nat);
    void* picked = sljit_emit_jump(c, SLJIT_JUMP);
    sljit_set_label(narrow, sljit_emit_label(c));
    sljit_emit_op1(c, SLJIT_MOV, R4, 0, m | R4, (char*)&nat.code_narrow - (char*)nat);
    sljit_set_label(picked, sljit_emit_label(c));
    slow.add(sljit_emit_cmp(c, SLJIT_EQUAL, R4, 0, SLJIT_IMM, 0));
    // The call block: the units and their count, past which a start leaves for the slow path.
    sljit_emit_op2(c, SLJIT_ADD, R0, 0, a.heap, 0, SLJIT_IMM, (char*)call - (char*)h);
    sljit_emit_op2(c, SLJIT_ADD, R1, 0, R2, 0, SLJIT_IMM, (long)hstring::HSTRING_HDR_SIZE);
    sljit_emit_op1(c, SLJIT_MOV, m | R0, (char*)&call.data - (char*)call, R1, 0);
    sljit_emit_op1(c, SLJIT_MOV_U32, R1, 0, m | R2, (char*)&str.length - (char*)str);
    sljit_emit_op1(c, SLJIT_MOV_U32, m | R0, (char*)&call.len - (char*)call, R1, 0);
    slow.add(sljit_emit_cmp(c, SLJIT_LESS | SLJIT_32, R1, 0, hp, start));
    sljit_emit_icall(c, SLJIT_CALL, SLJIT_ARGS1WW_R, R4, 0);
    TVal v;
    void* matched = sljit_emit_cmp(c, SLJIT_EQUAL, R0, 0, SLJIT_IMM, re_bindings::RE_MATCH);
    slow.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R0, 0, SLJIT_IMM, re_bindings::RE_NO_MATCH));
    // A failure resets lastIndex of g or y.
    sljit_emit_op1(c, SLJIT_MOV, R0, 0, SLJIT_IMM, K_INT);
    self.emit_regexp_last_index();
    v.set_null();
    if (test) v.set_boolean(false);
    sljit_emit_op1(c, SLJIT_MOV, R0, 0, SLJIT_IMM, (long)v.bits);
    void* failed = sljit_emit_jump(c, SLJIT_JUMP);
    sljit_set_label(matched, sljit_emit_label(c));
    // A match moves lastIndex of g or y to its end; an end the body left unset is the slow path's,
    // which runs the body again before any effect.
    sljit_emit_op1(c, SLJIT_MOV_S32, R0, 0, hp, (char*)&h.regexp_caps[1] - (char*)h);
    slow.add(sljit_emit_cmp(c, SLJIT_SIG_LESS, R0, 0, SLJIT_IMM, 0));
    sljit_emit_op2(c, SLJIT_OR, R0, 0, R0, 0, SLJIT_IMM, K_INT);
    self.emit_regexp_last_index();
    if (test) {
        v.set_boolean(true);
        sljit_emit_op1(c, SLJIT_MOV, R0, 0, SLJIT_IMM, (long)v.bits);
    } else {
        sljit_emit_op1(c, SLJIT_MOV, R1, 0, sp, REGEXP_RECV_OFF);
        sljit_emit_op2(c, SLJIT_XOR, R1, 0, R1, 0, k_obj_op(), k_obj_w());
        sljit_emit_op1(c, SLJIT_MOV, R2, 0, sp, REGEXP_ARG_OFF);
        sljit_emit_op2(c, SLJIT_XOR, R2, 0, R2, 0, SLJIT_IMM, K_STRING_START);
        sljit_emit_op1(c, SLJIT_MOV, R0, 0, a.heap, 0);
        a.c_call(SLJIT_ARGS3WWW, SLJIT_IMM, (long)(usz)&vm::jit_regexp_match);
    }
    sljit_set_label(failed, sljit_emit_label(c));
$endif
}

// The boxed int in R0 stored to lastIndex of the receiver emit_regexp_body saved, when its flags
// have g or y; the plain shape keeps lastIndex in the first slot. Uses R1 and R2.
fn void OptCg.emit_regexp_last_index(&self) {
$if features::REGEXP:
    void* c = self.a.c;
    HObject* o = (HObject*)(usz)4096;
    hobject::HObjectExtra* x = o.extra_ptr();
    sljit_emit_op1(c, SLJIT_MOV, R1, 0, SLJIT_MEM | reg_sp(), REGEXP_RECV_OFF);
    sljit_emit_op2(c, SLJIT_XOR, R1, 0, R1, 0, k_obj_op(), k_obj_w());
    sljit_emit_op1(c, SLJIT_MOV_S32, R2, 0, SLJIT_MEM | R1, (char*)&x.regexp.flags - (char*)o);
    sljit_emit_op2(c, SLJIT_AND, R2, 0, R2, 0, SLJIT_IMM, 1 | 32);
    void* keep = sljit_emit_cmp(c, SLJIT_EQUAL, R2, 0, SLJIT_IMM, 0);
    self.a.prop_base(R2, R1);
    sljit_emit_op1(c, SLJIT_MOV, SLJIT_MEM | R2, 0, R0, 0);
    sljit_set_label(keep, sljit_emit_label(c));
$endif
}

// Array.prototype.push of the boxed `value` onto `obj` for ARRAY_PUSH, as the builtin's dense fast
// path appends it, growing the storage (which allocates without collecting); the new length, or -1
// with nothing done for any other receiver or value.
fn long opt_array_push(Dispatch* ds, HObject* obj, ulong value) {
$if types::USE_NANBOX:
    return builtins::array_push_dense(ds.heap, obj, { .bits = value });
$else
    return -1;
$endif
}

// A register move of a forwarding call within the caller's frame: the value is one the frame
// holds already, so only the heap-register count may have to cover the new slot.
fn void OptCg.emit_move_window(&self, OptNode* n) {
    Asm* a = self.a;
    a.load(R0, (uint)n.imm);
    a.store(n.home, R0);
    a.track_heap_store(n.home);
}

fn void OptCg.emit_copy(&self, OptNode* n, uint i) {
    void* c = self.a.c;
    if (n.rep == OptRep.VALUE) {
        int r = self.value_reg(n.a, R0);
        int dst = self.int_dst(i, R0);
        if (dst != r) sljit_emit_op1(c, SLJIT_MOV, dst, 0, r, 0);
        self.def_value(i, dst);
    } else if (n.rep == OptRep.INT32) {
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
    if (n.cc != 0) {
        // Only ToInt32 reads it (OptBuild.wraps): the wrapped sum.
        sljit_emit_op1(c, SLJIT_MOV_S32, R2, 0, R2, 0);
        self.def_int(i, R2);
        return;
    }
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

// MOD_I32: the baseline's unsigned remainder, once the dividend is known to be non-negative and the
// divisor positive.
fn void OptCg.emit_mod(&self, uint i, OptNode* n) {
    void* c = self.a.c;
    int x = self.int_reg(n.a, R0);
    int y = self.int_reg(n.b, R1);
    self.exit_at(sljit_emit_cmp(c, SLJIT_SIG_LESS, x, 0, SLJIT_IMM, 0), i, OptExit.OVERFLOW);
    self.exit_at(sljit_emit_cmp(c, SLJIT_SIG_LESS_EQUAL, y, 0, SLJIT_IMM, 0), i, OptExit.OVERFLOW);
    if (x != R0) sljit_emit_op1(c, SLJIT_MOV, R0, 0, x, 0);
    if (y != R1) sljit_emit_op1(c, SLJIT_MOV, R1, 0, y, 0);
    sljit_emit_op0(c, SLJIT_DIVMOD_UW);
    self.def_int(i, R1);
}

// Store `yes` to window slot `home` where the jumps in `taken` land, `no` on the way through.
// COMPARE: the boolean of a numeric comparison.
fn void OptCg.emit_compare(&self, uint i, OptNode* n) {
    void* c = self.a.c;
    void* holds;
    if (n.imm == (long)OptRep.INT32.ordinal) {
        int x = self.int_reg(n.a, R0);
        int y;
        long yw;
        self.int_src(n.b, R1, &y, &yw);
        holds = sljit_emit_cmp(c, JMP_INT_COND[n.cc], x, 0, y, yw);
    } else {
        int x = self.flt_reg(n.a, FR0);
        int y = self.flt_reg(n.b, FR1);
        holds = sljit_emit_fcmp(c, JMP_FLOAT_COND[n.cc], x, 0, y, 0);
    }
    self.def_bool(i, holds, K_BOOL | 1, K_BOOL);
}

// COMPARE_WINDOW: the baseline's equality test, as a boolean.
fn void OptCg.emit_compare_window(&self, uint i, OptNode* n) {
    Jumps yes;
    Jumps no;
    self.equality_test(i, n, &yes, &no);
    self.exit_calls(i, OptExit.SLOW_PATH);
    if ((n.cc & 1) != 0) {
        self.def_bool_jumps(i, n, &no, &yes);
    } else {
        self.def_bool_jumps(i, n, &yes, &no);
    }
}

// The boolean of node `i`, true at the jumps of `t` and false at those of `f`: a VALUE node's,
// in its register, or one stored to window slot `n.home`.
fn void OptCg.def_bool_jumps(&self, uint i, OptNode* n, Jumps* t, Jumps* f) {
    void* c = self.a.c;
    int dst = n.rep == OptRep.VALUE ? self.int_dst(i, R0) : R0;
    t.bind(sljit_emit_label(c));
    sljit_emit_op1(c, SLJIT_MOV, dst, 0, SLJIT_IMM, K_BOOL | 1);
    void* done = sljit_emit_jump(c, SLJIT_JUMP);
    f.bind(sljit_emit_label(c));
    sljit_emit_op1(c, SLJIT_MOV, dst, 0, SLJIT_IMM, K_BOOL);
    sljit_set_label(done, sljit_emit_label(c));
    if (n.rep == OptRep.VALUE) {
        self.def_value(i, dst);
    } else {
        self.a.store(n.home, dst, 0);
    }
}

// LNOT: the negated truth of a node or of a window slot, as a boolean.
fn void OptCg.emit_lnot(&self, uint i, OptNode* n) {
    void* c = self.a.c;
    if (self.known_truth(n)) {
        void* truthy;
        if (self.g.nodes[n.a].rep == OptRep.VALUE) {
            int x = self.value_reg(n.a, R0);
            int dst = self.int_dst(i, R0);
            sljit_emit_op2(c, SLJIT_XOR, dst, 0, x, 0, SLJIT_IMM, 1);
            self.def_value(i, dst);
            return;
        }
        if (self.g.nodes[n.a].rep == OptRep.INT32) {
            int x = self.int_reg(n.a, R0);
            truthy = sljit_emit_cmp(c, SLJIT_NOT_EQUAL, x, 0, SLJIT_IMM, 0);
        } else {
            int x = self.flt_reg(n.a, FR0);
            sljit_emit_op1(c, SLJIT_MOV, R4, 0, SLJIT_IMM, 0);
            sljit_emit_fcopy(c, SLJIT_COPY_TO_F64, FR1, R4);
            truthy = sljit_emit_fcmp(c, SLJIT_ORDERED_NOT_EQUAL, x, 0, FR1, 0);
        }
        self.def_bool(i, truthy, K_BOOL, K_BOOL | 1);
        return;
    }
    Jumps truthy;
    Jumps falsy;
    self.truth_test(n, &truthy, &falsy);
    self.exit_calls(i, OptExit.SLOW_PATH);
    self.def_bool_jumps(i, n, &falsy, &truthy);
}

// Whether the operand of LNOT or BRANCH_TRUTH `n` is a number or a boolean, whose truth the code
// reads directly.
fn bool OptCg.known_truth(&self, OptNode* n) {
    if (n.a == NO_NODE) return false;
    OptNode* x = &self.g.nodes[n.a];
    return x.rep != OptRep.VALUE || self.g.is_boolean(x);
}

// The baseline's truth test of the operand of `n`: a VALUE node, or window slot `n.imm`.
fn void OptCg.truth_test(&self, OptNode* n, Jumps* truthy, Jumps* falsy) {
    if (n.a != NO_NODE) {
        self.value_to(n.a, R0);
    } else {
        self.a.load(R0, (uint)n.imm);
    }
    self.a.call.len = 0;
    self.a.truth_test_r0(truthy, falsy, true);
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
            if (n.op == OptOp.SHR_I32 && n.cc == 2) {
                // Read only by ToInt32 (OptBuild.bitop).
                sljit_emit_op1(c, SLJIT_MOV_S32, dst, 0, dst, 0);
            } else if (n.op == OptOp.SHR_I32) {
                // cc 1: the zero-extended uint32, which only its I32_TO_F64 reads.
                sljit_emit_op1(c, SLJIT_MOV_U32, dst, 0, dst, 0);
                if (n.cc == 0) self.exit_at(sljit_emit_cmp(c, SLJIT_GREATER, dst, 0, SLJIT_IMM, 0x7FFFFFFF), i, OptExit.OVERFLOW);
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

// The equality test of cc (opt_ir.c3, COMPARE_WINDOW) of the value in R0 with window slot rc: a
// strict test against a constant compares the bits, the null test (kinds 4 and 5) R0 alone, and the
// rest the baseline's subroutine.
fn void OptCg.window_equality(&self, char cc, uint rc, Jumps* yes, Jumps* no) {
    char kind = cc & WINDOW_KIND_MASK;
    char id = cc >> WINDOW_CONST_SHIFT;
    if (kind >= 4) {
        self.a.null_test_r0(yes, no);
    } else if (id != 0) {
        void* c = self.a.c;
        yes.add(sljit_emit_cmp(c, SLJIT_EQUAL, R0, 0, SLJIT_IMM, window_const_bits(id)));
        no.add(sljit_emit_jump(c, SLJIT_JUMP));
    } else {
        self.a.load(R1, rc);
        self.a.call_test_sub(kind < 2 ? STRICT_EQ_SUB : LOOSE_EQ_SUB, yes, no);
    }
}

// The equality test of BRANCH_WINDOW or COMPARE_WINDOW `n`: its VALUE operands (a, b) from their
// registers, the others from their window slots (imm), as window_equality tests them.
// What the subroutine leaves undecided goes to vm::jit_equality, and leaves only when that cannot
// answer without running code.
fn void OptCg.equality_test(&self, uint i, OptNode* n, Jumps* yes, Jumps* no) {
    self.a.call.len = 0;
    self.equality_operands(n);
    char kind = n.cc & WINDOW_KIND_MASK;
    if (n.b == NO_NODE) {
        self.window_equality(n.cc, (uint)(n.imm >> 20), yes, no);
        if (kind >= 4 || (n.cc >> WINDOW_CONST_SHIFT) != 0) return;
    } else {
        self.value_to(n.b, R1);
        self.a.call_test_sub(kind < 2 ? STRICT_EQ_SUB : LOOSE_EQ_SUB, yes, no);
    }
    void* c = self.a.c;
    Jumps rare = self.a.call;
    self.a.call.len = 0;
    rare.bind(sljit_emit_label(c));
    self.spill_live(i, true);
    self.equality_operands(n);
    if (n.b == NO_NODE) {
        self.a.load(R1, (uint)(n.imm >> 20));
    } else {
        self.value_to(n.b, R1);
    }
    sljit_emit_op1(c, SLJIT_MOV, R2, 0, R1, 0);
    sljit_emit_op1(c, SLJIT_MOV, R1, 0, R0, 0);
    sljit_emit_op1(c, SLJIT_MOV, R0, 0, self.a.ds, 0);
    sljit_emit_op1(c, SLJIT_MOV, R3, 0, SLJIT_IMM, kind < 2 ? 0 : 1);
    self.a.c_call_frameless(SLJIT_ARGS4WWWW, SLJIT_IMM, (long)(usz)&vm::jit_equality);
    self.spill_live(i, false);
    yes.add(sljit_emit_cmp(c, SLJIT_EQUAL, R0, 0, SLJIT_IMM, 1));
    no.add(sljit_emit_cmp(c, SLJIT_EQUAL, R0, 0, SLJIT_IMM, 0));
    self.a.call.add(sljit_emit_jump(c, SLJIT_JUMP));
}

// The first operand of BRANCH_WINDOW or COMPARE_WINDOW `n` into R0.
fn void OptCg.equality_operands(&self, OptNode* n) {
    if (n.a != NO_NODE) {
        self.value_to(n.a, R0);
    } else {
        self.a.load(R0, (uint)(n.imm & 0xFFFFF));
    }
}

// A conditional branch: leave the taken jumps in `jumps`.
// BRANCH_WINDOW: the baseline's equality or null test over two window slots; the rare cases
// leave through the slow path.
fn uint OptCg.emit_window_branch(&self, uint i, OptNode* n, void** jumps) {
    Jumps yes;
    Jumps no;
    self.equality_test(i, n, &yes, &no);
    self.exit_calls(i, OptExit.SLOW_PATH);
    bool on_yes = (n.cc & 1) == 0;
    Jumps* take = on_yes ? &yes : &no;
    Jumps* skip = on_yes ? &no : &yes;
    uint count = take.len > 8 ? 8 : take.len;
    for (uint k = 0; k < count; k++) jumps[k] = take.at[k];
    skip.bind(sljit_emit_label(self.a.c));
    return count;
}

// BRANCH_CALLEE: jumps unless the call's callee is a plain closure of the case's function (the
// tests of emit_check_callee that name the function; the CHECK_CALLEE of the case does the rest).
// The closure the method read names (OptBuild.read_constant), when there is one, is that at once.
fn uint OptCg.emit_callee_test(&self, uint i, OptNode* n, void** jumps) {
    void* c = self.a.c;
    Asm* a = self.a;
    CallLayout* k = call_layout();
    a.decode(n.pc);
    if (n.a != NO_NODE) {
        int r = self.value_reg(n.a, R1);
        if (r != R1) sljit_emit_op1(c, SLJIT_MOV, R1, 0, r, 0);
    } else {
        a.load(R1, a.w.b + self.g.fns[n.fidx].reg_base);
    }
    void* known = n.key == null ? null : sljit_emit_cmp(c, SLJIT_EQUAL, R1, 0, SLJIT_IMM, (long)(usz)n.key ^ K_OBJ);
    sljit_emit_op2(c, SLJIT_XOR, R0, 0, R1, 0, k_obj_op(), k_obj_w());
    jumps[0] = sljit_emit_cmp(c, SLJIT_GREATER_EQUAL, R0, 0, span_op(), span_w());
    jumps[1] = sljit_emit_cmp(c, SLJIT_EQUAL, R0, 0, SLJIT_IMM, 0);
    sljit_emit_op1(c, SLJIT_MOV_U32, R4, 0, SLJIT_MEM | R0, 0);
    sljit_emit_op2(c, SLJIT_AND, R4, 0, R4, 0, SLJIT_IMM, k.fn_mask);
    jumps[2] = sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R4, 0, SLJIT_IMM, k.fn_want);
    sljit_emit_op1(c, SLJIT_MOV, R4, 0, SLJIT_MEM | R0, a.lay.fn_comp_func);
    jumps[3] = sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R4, 0, SLJIT_IMM, n.imm);
    if (known != null) sljit_set_label(known, sljit_emit_label(c));
    return 4;
}

fn uint OptCg.emit_test(&self, uint i, OptNode* n, void** jumps) {
    void* c = self.a.c;
    if (n.op == OptOp.BRANCH_WINDOW) return self.emit_window_branch(i, n, jumps);
    if (n.op == OptOp.BRANCH_CALLEE) return self.emit_callee_test(i, n, jumps);
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
    if (self.known_truth(n)) {
        if (self.g.nodes[n.a].rep == OptRep.VALUE) {
            // A boolean: its low bit.
            int x = self.value_reg(n.a, R0);
            sljit_emit_op2u(c, SLJIT_AND | SLJIT_SET_Z, x, 0, SLJIT_IMM, 1);
            jumps[0] = sljit_emit_jump(c, negate ? SLJIT_EQUAL : SLJIT_NOT_EQUAL);
        } else if (self.g.nodes[n.a].rep == OptRep.INT32) {
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
    // Any other value: the baseline's truth test.
    Jumps truthy;
    Jumps falsy;
    self.truth_test(n, &truthy, &falsy);
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
    self.a.direct_called = false;
    self.a.direct_cf = (CompiledFunction*)n.key;
    self.a.emit_insn(at);
    self.a.direct_cf = null;
    // The out-of-line paths return here, before the reload.
    self.a.labels[self.a.next] = sljit_emit_label(c);
    // A callee run in this native frame has used the local area the capture records are kept in.
    if (self.a.direct_called) self.emit_cap_refs();
    for (uint k = 0; k < n.reload_count; k++) {
        OptDirty d = self.g.dirty[(sz)(n.reload_first + k)];
        OptNode* nd = &self.g.nodes[d.node];
        if (nd.reg < 0 || nd.is_const()) continue;
        if (nd.rep == OptRep.VALUE) {
            self.a.load(nd.reg, d.reg);
        } else if (nd.rep == OptRep.INT32) {
            self.load_unboxed(nd.reg, d.reg);
        } else {
            self.reload_flt(nd.reg, d.reg);
        }
    }
}

// CALL_REG: the call of n.key, which CHECK_CALLEE proved (or of the function the callee holds,
// for a polymorphic call's null key), through the register label of the callee's code as it stands
// (Asm.emit_call_entry): the direct label's path on a native frame of
// its own, so that the values live across the call wait in this frame's save area rather than
// boxed in the window. The callee's record is an ordinary one: it may exit, throw, collect or
// call as any frame does, and it returns its result in R1. The snapshot's stores and the resume
// point in this frame's record let the baseline code continue this frame from its window should
// the native frames be abandoned (jit_enter). A callee that declines (no native stack, record or
// value stack left) did nothing, and the baseline code makes the call (OptExit.DEEP).
//
// A call from an inlined body runs from records of the bodies' frames (push_records), which exist
// for its length only: what the callee does sees the frames the inlined calls would have made, and
// a callee that leaves rather than returns leaves them to continue in their baseline code. The
// slots those records expose to the collector that hold nothing live are cleared first
// (OptBuild.dead_slots). A decline leaves from the innermost body (opt_inline_exit).
fn void OptCg.emit_call_reg(&self, uint i, OptNode* n) {
    Asm* a = self.a;
    void* c = a.c;
    CallLayout* k = call_layout();
    self.store_dirty(n.dirty_first, n.dirty_count);
    self.decode(n);
    bool var_call = a.w.op == Opcode.CALL_VAR || a.w.op == Opcode.CALL_GLOBAL;
    bool method = a.w.op == Opcode.CALL;
    uint callee = var_call ? a.w.a : a.w.b;
    uint nargs = var_call ? a.w.b : a.w.c;
    CompiledFunction* cf = (CompiledFunction*)n.key;
    self.spill_live(i, true);
    // A plain call's receiver is undefined, as th_publish_lean's clear_this makes it.
    if (!method) a.store(callee + 1, SLJIT_IMM, K_UNDEF);
    if (cf != null) {
        a.mov(R0, 0, SLJIT_MEM, (long)(usz)&cf.jit_code);
    } else {
        a.load(R0, callee);
        sljit_emit_op2(c, SLJIT_XOR, R0, 0, R0, 0, k_obj_op(), k_obj_w());
        a.mov(R0, 0, SLJIT_MEM | R0, a.lay.fn_comp_func);
        a.mov(R0, 0, SLJIT_MEM | R0, k.cf_jit_code);
    }
    void* no_code = sljit_emit_cmp(c, SLJIT_EQUAL, R0, 0, SLJIT_IMM, 0);
    a.mov(R0, 0, SLJIT_MEM | R0, k.bc_reg_entry);
    void* no_entry = sljit_emit_cmp(c, SLJIT_EQUAL, R0, 0, SLJIT_IMM, 0);
    uint records = self.g.fns[n.fidx].depth;
    if (records != 0) {
        for (uint d = 0; d < n.reload_count; d++) a.store(self.g.dirty[(sz)(n.reload_first + d)].reg, SLJIT_IMM, K_UNDEF);
        self.push_records(n.fidx);
    }
    a.mov(R4, 0, SLJIT_IMM, (long)(usz)(a.f.code + (uint)n.imm + 1));
    a.mov(SLJIT_MEM | a.la, k.act_curr_pc, R4, 0);
    sljit_emit_op2(c, SLJIT_ADD, R1, 0, a.regs, 0, SLJIT_IMM, (long)(callee + 2) * TVal::size);
    sljit_emit_op2(c, SLJIT_ADD, R2, 0, a.regs, 0, SLJIT_IMM, (long)a.w.a * TVal::size);
    a.mov(R3, 0, SLJIT_IMM, (long)nargs | (method ? CALL_METHOD : CALL_PLAIN));
    sljit_emit_ijump(c, SLJIT_FAST_CALL, R0, 0);
    // The entry used the window register; the return left this frame's record in its register,
    // above which the records of the bodies' frames end with the call. A callee that returned
    // through vm::jit_ret leaves the VM's frame state synced for the innermost: that describes it
    // no more, and the next frame pushed there must not pass for it (as Asm.emit_return_body pops).
    if (records != 0) {
        sljit_emit_op2(c, SLJIT_SUB, a.la, 0, a.la, 0, SLJIT_IMM, (long)records * Activation::size);
        void* below = sljit_emit_cmp(c, SLJIT_LESS_EQUAL, SLJIT_MEM | a.ds, a.lay.ds_act, a.la, 0);
        a.mov(SLJIT_MEM | a.ds, a.lay.ds_act, SLJIT_IMM, 0);
        sljit_set_label(below, sljit_emit_label(c));
    }
    a.mov(a.regs, 0, SLJIT_MEM | a.la, k.act_bottom);
    void* declined = sljit_emit_cmp(c, SLJIT_EQUAL, R0, 0, SLJIT_IMM, vm::JIT_CALL_SLOW);
    a.store(a.w.a, R1);
    a.track_heap_store(a.w.a);
    self.spill_live(i, false);
    void* done = sljit_emit_jump(c, SLJIT_JUMP);
    // The window holds every value (store_dirty), and the registers the snapshot names may not:
    // the entry uses them before it declines.
    sljit_set_label(declined, sljit_emit_label(c));
    self.spill_live(i, false);
    self.exit_stored(sljit_emit_jump(c, SLJIT_JUMP), i, OptExit.DEEP);
    self.exit_stored(no_code, i, OptExit.DECLINED);
    self.exit_stored(no_entry, i, OptExit.DECLINED);
    sljit_set_label(done, sljit_emit_label(c));
}

// The records of the frames of the inlined calls that the body of OptGraph.fns entry `fidx` is
// nested in, for a call made from it (emit_call_reg), and the record register moved to the innermost.
// Each is the lazy record a register call's entry pushes (Asm.emit_call_entry): no native return
// (a frame nothing in generated code waits for), the frame's registers tracked, its result slot,
// window, `this`, and the word after its own inlined call; vm::jit_fill completes it should anything
// read it. The innermost's resume word is the call's (emit_call_reg), the caller's frame's that
// after the outermost inlined call. Each call's callee slot holds the function (OptBuild.live_in_at).
// Uses R1 to R4.
fn void OptCg.push_records(&self, uint fidx) {
    Asm* a = self.a;
    void* c = a.c;
    CallLayout* k = call_layout();
    Layout* l = a.lay;
    int m = SLJIT_MEM;
    uint depth = self.g.fns[fidx].depth;
    uint[OPT_INLINE_DEPTH] chain;
    uint at = fidx;
    for (uint level = depth; level > 0; level--) {
        chain[level - 1] = at;
        at = self.g.fns[at].parent;
    }
    a.mov(R4, 0, SLJIT_IMM, (long)(usz)(self.g.fns[0].f.code + self.g.fns[chain[0]].resume_pc));
    a.mov(m | a.la, k.act_curr_pc, R4, 0);
    for (uint level = 0; level < depth; level++) {
        OptFn* fn_ = &self.g.fns[chain[level]];
        OptFn* parent = &self.g.fns[fn_.parent];
        Instruction call = parent.f.code[fn_.resume_pc - 1];
        bool construct = call.op == Opcode.NEW_OBJ;
        bool takes_this = construct || (call.op == Opcode.CALL && !fn_.f.call_flags.ignores_this);
        long rec = (long)(level + 1) * Activation::size;
        sljit_emit_op2(c, SLJIT_ADD, R1, 0, a.regs, 0, SLJIT_IMM, (long)(parent.reg_base + call.a) * TVal::size);
        a.mov(m | a.la, rec + k.act_retval, R1, 0);
        a.mov(m | a.la, rec + k.act_native_ret, SLJIT_IMM, 0);
        uint flags = vm::ACT_FLAG_LAZY | (takes_this ? vm::ACT_FLAG_THIS_VALID : 0) | (construct ? vm::ACT_FLAG_CONSTRUCT : 0);
        if (!std::core::env::BIG_ENDIAN && l.act_hrc == k.act_flags + 4) {
            a.mov(m | a.la, rec + k.act_flags, SLJIT_IMM, (long)((ulong)fn_.f.num_regs << 32 | flags));
        } else {
            a.mov(m | a.la, rec + k.act_flags, SLJIT_IMM, flags, SLJIT_MOV_U32);
            a.mov(m | a.la, rec + l.act_hrc, SLJIT_IMM, fn_.f.num_regs, SLJIT_MOV_U32);
        }
        sljit_emit_op2(c, SLJIT_ADD, R2, 0, a.regs, 0, SLJIT_IMM, (long)fn_.reg_base * TVal::size);
        if (level + 1 < depth) {
            a.mov(R1, 0, SLJIT_IMM, (long)(usz)(fn_.f.code + self.g.fns[chain[level + 1]].resume_pc));
            a.store_pair(a.la, rec + k.act_curr_pc, R1, rec + k.act_bottom, R2);
        } else {
            a.mov(m | a.la, rec + k.act_bottom, R2, 0);
        }
        if (takes_this) {
            a.load(R3, fn_.reg_base - 1);
            a.mov(m | a.la, rec + l.act_this, R3, 0);
        } else {
            a.mov(m | a.la, rec + l.act_this, SLJIT_IMM, K_UNDEF);
        }
    }
    sljit_emit_op2(c, SLJIT_ADD, a.la, 0, a.la, 0, SLJIT_IMM, (long)depth * Activation::size);
}

fn void OptCg.emit_node(&self, uint i, uint pos) {
    void* c = self.a.c;
    OptNode* n = &self.g.nodes[i];
    self.use_fn(n.fidx);
    if (n.dirty_count != 0 || n.op == OptOp.GENERIC || n.op == OptOp.CHECK_I32 || n.op == OptOp.CHECK_NUM || n.op == OptOp.LOAD_CAP || n.op == OptOp.LOAD_ELEM || n.op == OptOp.STORE_ELEM || n.op == OptOp.LOAD_FIELD || n.op == OptOp.LOAD_LENGTH || n.op == OptOp.STORE_FIELD || n.op == OptOp.CHECK_CALLEE || n.op == OptOp.COPY_WINDOW || n.op == OptOp.LOAD_VAR || n.op == OptOp.LOAD_GLOBAL || n.op == OptOp.STORE_GLOBAL || n.op == OptOp.STEP_GLOBAL || n.op == OptOp.GUARD_BINDING || n.op == OptOp.GUARD_CAPTURE || n.op == OptOp.COMPARE_WINDOW || n.op == OptOp.LNOT || n.op == OptOp.NEW_OBJECT || n.op == OptOp.ADD_FIELD || n.op == OptOp.CHECK_BUILTIN || n.op == OptOp.ARRAY_PUSH || n.op == OptOp.REGEXP_EXEC || n.op == OptOp.STRING_REGEXP || n.op == OptOp.BUILTIN_LEAF) {
        if (self.force_here(n)) {
            self.forced_done = true;
            // The hook falls through once its count is spent: an allocation for the exit must not run then.
            void* spent = null;
            if (self.has_mats(i)) {
                sljit_emit_op1(c, SLJIT_MOV, R0, 0, SLJIT_IMM, (long)(usz)&self.oc.forced);
                sljit_emit_op1(c, SLJIT_MOV_U32, R1, 0, SLJIT_MEM | R0, 0);
                spent = sljit_emit_cmp(c, SLJIT_EQUAL, R1, 0, SLJIT_IMM, 0);
            }
            self.store_dirty(n.dirty_first, n.dirty_count);
            self.materialize(i);
            self.a.i = n.pc;
            if (n.fidx != 0) {
                self.emit_inline_exit(n.fidx, n.pc, n.live_mask, self.h.opt.force_reason - 1, true);
            } else {
                self.a.emit_opt_exit(self.oc, self.h.opt.force_reason - 1, true);
            }
            if (spent != null) sljit_set_label(spent, sljit_emit_label(c));
        }
    }
    switch (n.op) {
        case CONST_I32:
        case CONST_F64:
        case CONST_OBJ:
        case THIS:
        case PHI:
        case NOT_I32:
            if (n.op == OptOp.NOT_I32) self.emit_bitop(i, n);
        case CHECK_I32:
            self.emit_check_int(i, n);
        case CHECK_NUM:
            self.emit_check_num(i, n);
        case LOAD_CAP:
            self.emit_load_cap(i, n);
        case LOAD_ELEM:
            self.emit_load_elem(i, n);
        case STORE_ELEM:
            self.emit_store_elem(i, n);
        case LOAD_FIELD:
            self.emit_load_field(i, n);
        case LOAD_LENGTH:
            self.emit_load_length(i, n);
        case STORE_FIELD:
            self.emit_store_field(i, n);
        case CHECK_CALLEE:
            self.emit_check_callee(i, n);
        case LOAD_VAR:
            self.emit_load_var(i, n);
        case LOAD_GLOBAL:
            self.emit_load_global(i, n);
        case STORE_GLOBAL:
        case STEP_GLOBAL:
            self.emit_store_global(i, n);
        case GUARD_BINDING:
            self.emit_guard_binding(i, n);
        case GUARD_CAPTURE:
            self.emit_guard_capture(i, n);
        case COPY_WINDOW:
            self.emit_copy_window(i, n);
        case STORE_CONST:
            self.a.store(n.home, SLJIT_IMM, n.imm);
            TVal v = { .bits = (ulong)n.imm };
            if (!v.is_inert()) self.a.track_heap_store(n.home);
        case TYPEOF:
            self.emit_typeof(i, n);
        case INSTANCEOF:
            self.emit_instanceof(i, n);
        case ALLOC:
            self.emit_alloc(i, n);
        case INIT_SLOT:
            self.emit_init_slot(i, n);
        case STORE_VALUE:
            self.store_node(n.a, (uint)n.imm);
        case COPY:
            if (!n.sunk) self.emit_copy(n, i);
        case ADD_I32:
        case SUB_I32:
            self.emit_addsub(i, n);
        case MUL_I32:
            self.emit_mul(i, n);
        case MOD_I32:
            self.emit_mod(i, n);
        case COMPARE:
            self.emit_compare(i, n);
        case COMPARE_WINDOW:
            self.emit_compare_window(i, n);
        case LNOT:
            self.emit_lnot(i, n);
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
        case MATH:
            self.emit_math(i, n);
        case NEG_F64:
            int x = self.flt_reg(n.a, FR0);
            int dst = self.flt_dst(i, FR0);
            sljit_emit_fop1(c, SLJIT_NEG_F64, dst, 0, x, 0);
            self.def_flt(i, dst);
        case JUMP:
            self.emit_edge(pos, 0, true);
        case BRANCH:
        case BRANCH_TRUTH:
        case BRANCH_WINDOW:
        case BRANCH_CALLEE:
            void*[8] jumps;
            uint count = self.emit_test(i, n, &jumps[0]);
            self.emit_edge(pos, 1, true);
            self.defer_taken(pos, &jumps[0], count);
        case GENERIC:
            self.emit_generic(i, n);
        case CALL_REG:
            self.emit_call_reg(i, n);
        case NEW_OBJECT:
            if (n.sunk) {
                self.emit_sunk_object(i, n);
            } else {
                self.emit_new_object(i, n);
            }
        case SUNK:
            break;
        case ADD_FIELD:
            self.emit_add_field(i, n);
        case CHECK_BUILTIN:
            self.emit_check_builtin(i, n);
        case ARRAY_PUSH:
            self.emit_array_push(i, n);
        case REGEXP_EXEC:
            self.emit_regexp_exec(i, n);
        case STRING_REGEXP:
            self.emit_string_regexp(i, n);
        case BUILTIN_LEAF:
            self.emit_builtin_leaf(i, n);
        case MOVE_WINDOW:
            self.emit_move_window(n);
        case EXIT:
            self.store_dirty(n.dirty_first, n.dirty_count);
            self.materialize(i);
            self.a.i = n.pc;
            if (n.fidx != 0) {
                self.emit_inline_exit(n.fidx, n.pc, n.live_mask, OptExit.COLD.ordinal, false);
            } else if (n.cc == OPT_EXIT_LEAVE) {
                self.a.emit_opt_leave(self.oc);
            } else {
                self.a.emit_opt_exit(self.oc, OptExit.COLD.ordinal, false);
            }
    }
}

// Print where the code of each node of the optimized code `bc` starts, for attributing profiler
// samples to nodes: "onodes fn#<index> <start> <end> <address>:<op>:<pc>:<fn>:<node>:<opcode> ..." in
// node order, with the opcode of the bytecode instruction the node came from, then "end:<address>"
// past the last node, where the stubs begin (--jit-dump-feedback). With
// --jit-dump-code, "ocode fn#<index> <start> <hex bytes>" follows.
fn void opt_dump_nodes(Heap* h, CompiledFunction* f, OptGraph* g, BaselineCode* bc, void*[] labels) {
    // One write, as dump_code_map makes it.
    DString out;
    out.init(mem, 256);
    defer out.free();
    out.appendf("onodes fn#%d %x %x", f.func_index, (usz)bc.exec, (usz)bc.exec + bc.code_bytes);
    for (sz i = 0; i < g.nodes.len(); i++) {
        if (labels[i] == null) continue;
        OptNode* n = &g.nodes[i];
        CompiledFunction* nf = g.fns[n.fidx].f;
        bytecode::DecodedBytecode d = bytecode::decode_bytecode(nf.code, nf.code_count, n.pc);
        out.appendf(" %x:%s:%d:%d:%d:%s", (usz)sljit_shim_label_addr(labels[i]), n.op, n.pc, n.fidx, i, d.valid ? d.insn.op : Opcode.NOP);
    }
    out.appendf(" end:%x", (usz)sljit_shim_label_addr(labels[g.nodes.len()]));
    if (h.jit_stats.dump_code) {
        out.appendf("\nocode fn#%d %x ", f.func_index, (usz)bc.exec);
        foreach (b : ((char*)bc.exec)[:bc.code_bytes]) out.appendf("%02x", b);
    }
    io::eprintn(out.str_view());
}

// Generate native code for the graph. Null when code generation fails.
fn BaselineCode* opt_emit(Heap* h, CompiledFunction* f, OptGraph* g, OptCode* oc, OptPools pools) {
    uint count = f.code_count;
    // A NEW_OBJ left GENERIC allocates and enters its constructor through a site, as in baseline code.
    uint news = new_site_count(f);
    BaselineCode* bc = baseline_alloc(h, count, news);
    if (bc == null) return null;
    void* c = sljit_create_compiler(null);
    if (c == null) { h.free_func(h.heap_udata, bc); return null; }
    defer sljit_free_compiler(c);
    Asm a = asm_new(c, h, f);
    defer a.release();
    a.opt = true;
    a.use_new_sites(bc, news);
    // A slot past the spill area for the capture records, when a read of the function's own uses them.
    long cap_slot = -1;
    foreach (&nd : g.nodes) {
        if ((nd.op == OptOp.LOAD_CAP || nd.op == OptOp.GUARD_CAPTURE) && nd.fidx == 0 && f.capture_count != 0) cap_slot = CALL_FRAME_BYTES + 8 * (long)(pools.int_count + pools.flt_count);
    }
    void* dispatch = a.emit_dispatch(bc, count);
    a.emit_nonzero_exit(dispatch);
    // An entry that is not an entry of the optimized code continues in the baseline code.
    void* to_base = sljit_emit_label(c);
    a.emit_sync();
    sljit_emit_ijump(c, SLJIT_JUMP, SLJIT_IMM, (long)(usz)oc.base.exec_jump);

    uint fields = 0;
    foreach (&nd : g.nodes) {
        if (nd.op == OptOp.LOAD_FIELD || nd.op == OptOp.STORE_FIELD) fields += g.polys[(sz)(nd.poly - 1)].count;
    }
    if (fields != 0) {
        oc.cells = h.alloc_func(h.heap_udata, fields * uint::size);
        if (oc.cells == null) return null;
    }
    OptCg cg = { .a = &a, .h = h, .g = g, .oc = oc, .pools = pools, .cap_slot = cap_slot };
    cg.init();
    defer cg.free();
    uint blocks = (uint)g.blocks.len();
    cg.labels = mem::new_array(void*, blocks);
    cg.osr_labels = mem::new_array(void*, blocks);
    // Where each node's code starts, and the end of the last (--jit-dump-feedback).
    void*[] node_labels;
    if (h.jit_stats.dump_feedback) node_labels = mem::new_array(void*, g.nodes.len() + 1);
    defer if (node_labels.len != 0) mem::free(node_labels);
    for (uint pos = 0; pos < blocks; pos++) {
        OptBlock* blk = &g.blocks[pos];
        cg.labels[pos] = sljit_emit_label(c);
        if (pos == 0) cg.emit_cap_refs();
        for (uint i = blk.first; i < blk.end; i++) {
            if (node_labels.len != 0) node_labels[i] = sljit_emit_label(c);
            cg.emit_node(i, pos);
            bc.insns++;
        }
    }
    if (node_labels.len != 0) node_labels[g.nodes.len()] = sljit_emit_label(c);
    cg.use_fn(0);
    a.emit_stubs();
    cg.emit_taken_stubs();
    cg.emit_poll_stubs();
    cg.emit_osr_entries(to_base);
    // The function's start, entered through the table.
    void* start = sljit_emit_label(c);
    cg.emit_room_test(to_base);
    cg.gotos.push({ .jump = sljit_emit_jump(c, SLJIT_JUMP), .block = 0 });
    cg.emit_exit_stubs();
    // The exit stubs of inlined bodies leave the emitter on a callee; the call entry, its
    // subroutines and the code after a native call's return belong to the function being compiled.
    cg.use_fn(0);
    // A direct call enters at the first block, through its OSR entry when the function starts with
    // a loop, whose values that entry loads from the window. A region's code has no function start.
    void* call_entry = null;
    if (call_entry_eligible(f) && g.region.end == 0) {
        a.labels[0] = g.blocks[0].osr ? cg.osr_labels[0] : cg.labels[0];
        call_entry = a.emit_call_entry(bc, touch: true);
    }
    foreach (gt : cg.gotos) sljit_set_label(gt.jump, cg.labels[gt.block]);
    if (a.finish(h, bc, call_entry) == null) return null;
    if (node_labels.len != 0) opt_dump_nodes(h, f, g, bc, node_labels);
    for (uint i = 0; i < count; i++) {
        if (a.starts[i]) bc.entries[i] = (void*)sljit_shim_label_addr(to_base);
    }
    // A region's first block is its loop header, entered only through its OSR entry.
    if (g.region.end == 0) bc.entries[0] = (void*)sljit_shim_label_addr(start);
    for (uint pos = 0; pos < blocks; pos++) {
        if (g.blocks[pos].osr) bc.entries[g.blocks[pos].pc] = (void*)sljit_shim_label_addr(cg.osr_labels[pos]);
    }
    if (h.jit_stats.dump_feedback) dump_code_map(f, bc, true);
    return bc;
}
