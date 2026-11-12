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
import boomkat::features;
import boomkat::hobject;
import boomkat::env;
import boomkat::vm;
import boomkat::builtins;
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

// OBJECT node `n` in a register: its own, or `tmp` loaded from its home slot.
fn int OptCg.obj_reg(&self, uint n, int tmp) {
    OptNode* nd = &self.g.nodes[n];
    if (nd.reg >= 0) return nd.reg;
    self.a.load(tmp, nd.home);
    return tmp;
}

// The boxed object or inert value in `src` stored to window slot `slot`, raising the frame's
// heap_reg_count over it as Asm.publish does. Uses R2 and R3.
fn void OptCg.store_object(&self, uint slot, int src) {
    self.a.store(slot, src);
    self.a.track_heap_store(slot, R3, R2);
}

// The value of OBJECT node `nd`, in `src`, stored to window slot `slot`: plainly when a boolean.
fn void OptCg.store_obj(&self, OptNode* nd, uint slot, int src) {
    if (self.g.is_boolean(nd)) {
        self.a.store(slot, src);
    } else {
        self.store_object(slot, src);
    }
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
    } else if (nd.rep == OptRep.OBJECT) {
        self.store_obj(nd, slot, nd.reg);
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

// The result of OBJECT node `n`, computed into register `src`.
fn void OptCg.def_obj(&self, uint n, int src) {
    OptNode* nd = &self.g.nodes[n];
    if (nd.reg >= 0) {
        if (nd.reg != src) sljit_emit_op1(self.a.c, SLJIT_MOV, nd.reg, 0, src, 0);
        return;
    }
    self.store_obj(nd, nd.home, src);
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
    self.def_obj(n, dst);
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
    OptInlineExit* site = self.h.alloc_func(self.h.heap_udata, OptInlineExit::size);
    // The frames from the innermost out: each one's caller is its entry's parent.
    uint depth = self.g.fns[fidx].depth;
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
    if (d.rep == OptRep.OBJECT) {
        if (m.src_reg >= 0) {
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
// leave for the baseline code at the header.
fn void OptCg.emit_poll_stubs(&self) {
    void* c = self.a.c;
    int saved = 0;
    foreach (&p : self.polls) {
        OptBlock* h = &self.g.blocks[p.target];
        void* label = sljit_emit_label(c);
        for (uint k = 0; k < p.jump_count; k++) sljit_set_label(p.jumps[k], label);
        self.store_dirty(h.entry_first, h.entry_count);
        long off = CALL_FRAME_BYTES;
        for (int k = 0; k < self.pools.int_count; k++, off += 8) {
            sljit_emit_op1(c, SLJIT_MOV, SLJIT_MEM | reg_sp(), off, self.pools.int_first + k, 0);
        }
        for (int k = 0; k < self.pools.flt_count; k++, off += 8) {
            sljit_emit_fop1(c, SLJIT_MOV_F64, SLJIT_MEM | reg_sp(), off, self.pools.flt_first + k, 0);
        }
        sljit_emit_op1(c, SLJIT_MOV, R1, 0, SLJIT_IMM, (long)(usz)self.a.f.code + (long)h.pc * Instruction::size);
        sljit_emit_op1(c, SLJIT_MOV, SLJIT_MEM | self.a.ds, self.a.pc_off, R1, 0);
        sljit_emit_op1(c, SLJIT_MOV, R0, 0, self.a.ds, 0);
        self.a.c_call(SLJIT_ARGS1WW, SLJIT_IMM, (long)(usz)&opt_poll);
        sljit_emit_op1(c, SLJIT_MOV, R4, 0, R0, 0);
        off = CALL_FRAME_BYTES;
        for (int k = 0; k < self.pools.int_count; k++, off += 8) {
            sljit_emit_op1(c, SLJIT_MOV, self.pools.int_first + k, 0, SLJIT_MEM | reg_sp(), off);
        }
        for (int k = 0; k < self.pools.flt_count; k++, off += 8) {
            sljit_emit_fop1(c, SLJIT_MOV_F64, self.pools.flt_first + k, 0, SLJIT_MEM | reg_sp(), off);
        }
        self.exit_clean_dirty(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R4, 0, SLJIT_IMM, 0), h.pc, h.entry_first, h.entry_count, OptExit.INTERRUPT);
        sljit_set_label(sljit_emit_jump(c, SLJIT_JUMP), p.resume);
        saved++;
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
        for (uint k = 0; k < blk.osr_count; k++) {
            OptDirty d = self.g.dirty[(sz)(blk.osr_first + k)];
            OptNode* n = &self.g.nodes[d.node];
            // A spilled value is in its slot already.
            if (n.reg < 0) continue;
            self.a.call.len = 0;
            if (n.rep == OptRep.INT32) {
                self.a.load(R0, d.reg);
                self.int32_from_r0(d.reg);
                for (uint j = 0; j < self.a.call.len; j++) self.exit_clean(self.a.call.at[j], blk.pc, OptExit.NOT_INT32);
                self.a.call.len = 0;
                sljit_emit_op1(c, SLJIT_MOV, n.reg, 0, R0, 0);
            } else {
                self.a.load_number(n.reg, d.reg);
                for (uint j = 0; j < self.a.call.len; j++) self.exit_clean(self.a.call.at[j], blk.pc, OptExit.NOT_NUMBER);
                self.a.call.len = 0;
            }
        }
        self.gotos.push({ .jump = sljit_emit_jump(c, SLJIT_JUMP), .block = pos });
    }
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
    self.a.call.add(sljit_emit_cmp(c, SLJIT_GREATER_EQUAL, R0, 0, SLJIT_IMM, K_INT));
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
    void* not_double = sljit_emit_cmp(c, SLJIT_GREATER_EQUAL, R0, 0, SLJIT_IMM, K_INT);
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

// GETGLOBAL of an inlined body as a number or an OBJECT node: the baseline's cached read, leaving for the baseline
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
        closure = n.b != NO_NODE ? self.obj_reg(n.b, R3) : -1;
    }
    a.var_slot(vic, n.cc != 0, creg, closure);
    if (n.cc != 0) {
        sljit_emit_op1(self.a.c, SLJIT_MOV_U8, R1, 0, SLJIT_MEM | R2, a.lay.vic_flags);
        sljit_emit_op2(self.a.c, SLJIT_AND, R1, 0, R1, 0, SLJIT_IMM, a.lay.accessor_mask);
        a.call.add(sljit_emit_cmp(self.a.c, SLJIT_NOT_EQUAL, R1, 0, SLJIT_IMM, 0));
    }
    sljit_emit_op1(self.a.c, SLJIT_MOV, R0, 0, SLJIT_MEM | R0, 0);
    // A binding in its TDZ is no number: the numeric test below leaves for it too.
    if (n.rep == OptRep.OBJECT) a.guard_not_tdz();
    for (uint k = 0; k < a.alt.len; k++) self.exit_at(a.alt.at[k], i, OptExit.SLOW_PATH);
    a.alt.len = 0;
    self.exit_calls(i, OptExit.SLOW_PATH);
    if (n.rep == OptRep.OBJECT) {
        self.finish_object(i, n);
    } else {
        self.def_from_r0(i, n);
    }
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
        // A nested call's closure may be held in an OBJECT node (b) instead.
        int closure = n.b != NO_NODE ? self.obj_reg(n.b, R3) : -1;
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
    } else if (n.rep == OptRep.OBJECT) {
        self.finish_object(i, n);
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
    sljit_emit_op1(c, SLJIT_MOV, R1, 0, self.a.la, 0);
    sljit_emit_op1(c, SLJIT_MOV, R0, 0, SLJIT_MEM | R1, l.act_tv_func);
    sljit_emit_op2(c, SLJIT_XOR, R3, 0, R0, 0, SLJIT_IMM, K_OBJ);
    fail.add(sljit_emit_cmp(c, SLJIT_GREATER_EQUAL, R3, 0, SLJIT_IMM, PAYLOAD_SPAN));
    sljit_emit_op1(c, SLJIT_MOV, R0, 0, SLJIT_MEM | R3, l.fn_capture_refs);
    sljit_emit_op1(c, SLJIT_MOV, R3, 0, SLJIT_MEM | R3, l.fn_comp_func);
    fail.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R3, 0, SLJIT_MEM | R1, l.act_func));
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
    sljit_emit_op2(c, SLJIT_OR, R3, 0, R3, 0, SLJIT_IMM, K_INT);
}

// The boxed value of number node `n`, or the constant of STORE_CONST `n`, in `dst`.
fn void OptCg.box_node(&self, uint n, int dst) {
    void* c = self.a.c;
    OptNode* nd = &self.g.nodes[n];
    if (nd.op == OptOp.STORE_CONST) {
        sljit_emit_op1(c, SLJIT_MOV, dst, 0, SLJIT_IMM, nd.imm);
    } else if (nd.op == OptOp.CONST_I32) {
        sljit_emit_op1(c, SLJIT_MOV, dst, 0, SLJIT_IMM, K_INT | (nd.imm & (PAYLOAD_SPAN - 1)));
    } else if (nd.op == OptOp.CONST_F64) {
        sljit_emit_op1(c, SLJIT_MOV, dst, 0, SLJIT_IMM, nd.imm);
    } else if (nd.reg < 0) {
        self.a.load(dst, nd.home);
    } else if (nd.rep == OptRep.INT32) {
        sljit_emit_op2(c, SLJIT_AND, dst, 0, nd.reg, 0, SLJIT_IMM, PAYLOAD_SPAN - 1);
        sljit_emit_op2(c, SLJIT_OR, dst, 0, dst, 0, SLJIT_IMM, K_INT);
    } else {
        sljit_emit_fcopy(c, SLJIT_COPY_FROM_F64, nd.reg, dst);
        void* ok = sljit_emit_cmp(c, SLJIT_LESS, dst, 0, SLJIT_IMM, K_INT);
        sljit_emit_op1(c, SLJIT_MOV, dst, 0, SLJIT_IMM, CANONICAL_NAN);
        sljit_set_label(ok, sljit_emit_label(c));
    }
}

// LOAD_LENGTH: an array's length as emit_length reads it, as an INT32. Anything else, and a
// length above the int32 range, leaves for the baseline code.
fn void OptCg.emit_load_length(&self, uint i, OptNode* n) {
    void* c = self.a.c;
    Asm* a = self.a;
    Layout* l = a.lay;
    self.decode(n);
    a.call.len = 0;
    int rr = R0;
    if (n.b != NO_NODE) {
        rr = self.obj_reg(n.b, R0);
    } else {
        a.load(R0, a.w.b);
    }
    a.unbox_object(R1, rr);
    a.guard_not_proxy(R1, R2);
    sljit_emit_op1(c, SLJIT_MOV_U32, R2, 0, SLJIT_MEM | R1, 0);
    sljit_emit_op2(c, SLJIT_AND, R2, 0, R2, 0, SLJIT_IMM, l.class_mask);
    a.call.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R2, 0, SLJIT_IMM, l.class_array));
    sljit_emit_op1(c, SLJIT_MOV_U32, R0, 0, SLJIT_MEM | R1, l.obj_array_len);
    a.call.add(sljit_emit_cmp(c, SLJIT_GREATER, R0, 0, SLJIT_IMM, 0x7FFFFFFF));
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
    int rr = R0;
    if (n.c != NO_NODE) {
        rr = self.obj_reg(n.c, R0);
    } else {
        a.load(R0, a.w.b);
    }
    a.unbox_object(R1, rr);
    long flags;
    bool unseen;
    int k = self.typed_kind(0, &flags, &unseen);
    if (k >= 0) {
        self.emit_typed_load(i, n, TYPED_KINDS[k], flags);
        return;
    }
    self.box_index(n.a);
    void* other = a.array_or_typed(0);
    a.array_slot();
    sljit_emit_op1(c, SLJIT_MOV, R0, 0, SLJIT_MEM | R0, 0);
    a.call.add(sljit_emit_cmp(c, SLJIT_EQUAL, R0, 0, SLJIT_IMM, K_UNDEF));
    $if features::BUFFERS:
        void* done = sljit_emit_jump(c, SLJIT_JUMP);
        sljit_set_label(other, sljit_emit_label(c));
        if (unseen) {
            self.unprofiled_exit(i);
        } else {
            a.subs.push({ .jump = sljit_emit_jump(c, SLJIT_FAST_CALL), .sub = TYPED_GET_SUB });
            a.call.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R2, 0, SLJIT_IMM, SUB_TRUE));
        }
        sljit_set_label(done, sljit_emit_label(c));
    $else
        a.call.add(other);
    $endif
    self.exit_calls(i, OptExit.SLOW_PATH);
    if (n.rep == OptRep.NONE) {
        self.publish(i, a.w.a);
        return;
    }
    if (n.rep == OptRep.OBJECT) {
        self.finish_object(i, n);
        return;
    }
    self.def_from_r0(i, n);
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
    *unseen = recorded == 0;
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

// LOAD_ELEM of the typed array kind its site has met (OptCg.typed_kind): the element read in
// place, without the subroutine's dispatch over kinds; an int32 or double node takes it unboxed.
fn void OptCg.emit_typed_load(&self, uint i, OptNode* n, TypedKind kind, long flags) {
    void* c = self.a.c;
    Asm* a = self.a;
    int x = self.typed_elem_addr(n.a, kind, flags, 0, false);
    int elem = mem_index(R4, x);
    bool is_float = kind.cls == hobject::ObjClass.FLOAT32ARRAY || kind.cls == hobject::ObjClass.FLOAT64ARRAY;
    self.exit_calls(i, OptExit.SLOW_PATH);
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
        void* plain = sljit_emit_cmp(c, SLJIT_LESS, R0, 0, SLJIT_IMM, K_INT);
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
        sljit_emit_op2(c, SLJIT_OR, R0, 0, R0, 0, SLJIT_IMM, K_INT);
        if (boxed != null) sljit_set_label(boxed, sljit_emit_label(c));
    }
    if (n.rep == OptRep.NONE) {
        // A number, which needs no publication.
        a.store(a.w.a, R0);
        return;
    }
    // A number is an inert value, which an OBJECT node holds as it is.
    if (n.rep == OptRep.OBJECT) {
        self.def_obj(i, R0);
        return;
    }
    self.def_from_r0(i, n);
}

// STORE_ELEM of a numeric node into the typed array kind its site has met: an int32 node stores
// its low bits to an integer kind, as ta_store_int; a float kind takes the value as a double
// (narrowed for Float32), as ta_store_scalar.
fn void OptCg.emit_typed_store(&self, uint i, OptNode* n, TypedKind kind, long flags) {
    void* c = self.a.c;
    int x = self.typed_elem_addr(n.a, kind, flags, self.a.lay.indexed_named_mask, true);
    self.exit_calls(i, OptExit.SLOW_PATH);
    int elem = mem_index(R4, x);
    OptNode* v = &self.g.nodes[n.b];
    bool is_float = kind.cls == hobject::ObjClass.FLOAT32ARRAY || kind.cls == hobject::ObjClass.FLOAT64ARRAY;
    if (!is_float) {
        int r = self.int_reg(n.b, R0);
        sljit_emit_op1(c, kind.mov, elem, kind.shift, r, 0);
        return;
    }
    int f32 = kind.cls == hobject::ObjClass.FLOAT32ARRAY ? SLJIT_32 : 0;
    int fr;
    if (v.rep == OptRep.INT32) {
        int r = self.int_reg(n.b, R0);
        sljit_emit_fop1(c, SLJIT_CONV_F64_FROM_SW | f32, FR0, 0, r, 0);
        fr = FR0;
    } else {
        fr = self.flt_reg(n.b, FR0);
        if (f32 != 0) {
            sljit_emit_fop1(c, SLJIT_CONV_F64_FROM_F32 | SLJIT_32, FR0, 0, fr, 0);
            fr = FR0;
        }
    }
    sljit_emit_fop1(c, SLJIT_MOV_F64 | f32, elem, kind.shift, fr, 0);
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

// Mark the value in R0 for the collector (vm::jit_opt_shade), with the registers in use saved
// around the call. R0 keeps the value.
fn void OptCg.shade(&self, uint i) {
    void* c = self.a.c;
    self.spill_live(i, true);
    sljit_emit_op1(c, SLJIT_MOV, R1, 0, R0, 0);
    sljit_emit_op1(c, SLJIT_MOV, R0, 0, self.a.heap, 0);
    self.a.c_call(SLJIT_ARGS2WWW, SLJIT_IMM, (long)(usz)&vm::jit_opt_shade);
    self.spill_live(i, false);
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
    sljit_emit_op2(c, SLJIT_XOR, R2, 0, R0, 0, SLJIT_IMM, K_OBJ);
    self.exit_at(sljit_emit_cmp(c, SLJIT_GREATER_EQUAL, R2, 0, SLJIT_IMM, PAYLOAD_SPAN), i, OptExit.SLOW_PATH);
    sljit_emit_op1(c, SLJIT_MOV_U8, R3, 0, SLJIT_MEM | a.heap, a.lay.heap_gc_phase);
    self.exit_at(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R3, 0, SLJIT_IMM, (long)heap::GcPhase.MARK.ordinal), i, OptExit.SLOW_PATH);
    self.shade(i);
    a.store(slot, R0);
    a.track_heap_store(slot);
    sljit_set_label(done, sljit_emit_label(c));
}

// The OBJECT result of a load, in R0: an object or an inert value, else leave for the baseline code.
fn void OptCg.finish_object(&self, uint i, OptNode* n) {
    void* c = self.a.c;
    Asm* a = self.a;
    // An object or an inert value, while the collector is not marking: the invariant of OptRep.OBJECT.
    // The object is tested first, as what such a node mostly holds.
    sljit_emit_op2(c, SLJIT_XOR, R2, 0, R0, 0, SLJIT_IMM, K_OBJ);
    void* object = sljit_emit_cmp(c, SLJIT_LESS, R2, 0, SLJIT_IMM, PAYLOAD_SPAN);
    self.exit_at(sljit_emit_cmp(c, SLJIT_GREATER_EQUAL, R0, 0, SLJIT_IMM, K_STRING_START), i, OptExit.SLOW_PATH);
    void* inert = sljit_emit_jump(c, SLJIT_JUMP);
    sljit_set_label(object, sljit_emit_label(c));
    sljit_emit_op1(c, SLJIT_MOV_U8, R3, 0, SLJIT_MEM | a.heap, a.lay.heap_gc_phase);
    void* quiet = sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R3, 0, SLJIT_IMM, (long)heap::GcPhase.MARK.ordinal);
    // While marking the object is marked, and published at once unless its slot is beyond the
    // caller's frame, which the collector does not scan.
    self.shade(i);
    if (!self.g.pinned(n)) {
        sljit_emit_op1(c, SLJIT_MOV, R1, 0, SLJIT_IMM, (long)n.home);
        a.subs.push({ .jump = sljit_emit_jump(c, SLJIT_FAST_CALL), .sub = PUBLISH_SUB });
        self.exit_at(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R2, 0, SLJIT_IMM, 0), i, OptExit.SLOW_PATH);
    }
    sljit_set_label(quiet, sljit_emit_label(c));
    sljit_set_label(inert, sljit_emit_label(c));
    self.def_obj(i, R0);
}

// select_chain_slot's result for the receiver the entry `ic` holds now, when that is an epoch case the
// heap's epoch still proves: its shape, first prototype and the owner's slot as constants, under
// that epoch. Returns the jump taken with the slot address in R0; every other receiver, and a moved
// epoch, continue after it with R1 kept, but another shape leaves from the exact node `i`. Null,
// with nothing emitted, for any other entry.
fn void* OptCg.settled_chain_slot(&self, hobject::ICEntry* ic, uint i) {
    void* c = self.a.c;
    Asm* a = self.a;
    Layout* l = a.lay;
    hobject::Shape* sh = opt_settled_shape(self.h, ic);
    if (sh == null) return null;
    hobject::ICChainEpoch* e = &ic.chain.epoch;
    sh.pinned = true;
    void*[4] other;
    sljit_emit_op1(c, SLJIT_MOV_U32, R3, 0, SLJIT_MEM | R1, l.obj_shape);
    other[0] = sljit_emit_cmp(c, SLJIT_NOT_EQUAL | SLJIT_32, R3, 0, SLJIT_IMM, (long)ic.shape_id);
    bool exact = self.g.nodes[i].exact;
    if (exact) self.exit_at(other[0], i, OptExit.RECEIVER);
    sljit_emit_op1(c, SLJIT_MOV_U32, R0, 0, SLJIT_MEM | R1, 0);
    sljit_emit_op2(c, SLJIT_AND, R0, 0, R0, 0, SLJIT_IMM, l.class_mask | l.plain_exotic_mask);
    other[1] = sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R0, 0, SLJIT_IMM, l.class_object);
    sljit_emit_op1(c, SLJIT_MOV, R0, 0, SLJIT_MEM | R1, l.obj_proto);
    other[2] = sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R0, 0, SLJIT_IMM, (long)(usz)e.first);
    sljit_emit_op1(c, SLJIT_MOV, R0, 0, SLJIT_MEM | a.heap, l.heap_proto_epoch);
    other[3] = sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R0, 0, SLJIT_IMM, (long)e.value);
    // An observed object's values stay where they are while the epoch stands (HObject.layout_moved).
    sljit_emit_op1(c, SLJIT_MOV, R0, 0, SLJIT_IMM, (long)(usz)&e.owner.prop_values()[ic.prop_idx]);
    void* settled = sljit_emit_jump(c, SLJIT_JUMP);
    void* rest = sljit_emit_label(c);
    foreach (k, j : other) if (k != 0 || !exact) sljit_set_label(j, rest);
    return settled;
}

// The slot address in R0 of the property the read entry `ic` names for the plain object in R1
// (unboxed, not a proxy): the data property of the prototype the entry's epoch guard or link
// snapshot describes, as Asm.emit_get does for a hit. The entry is read
// at run time, so a refill leaves the code right; a miss, an accessor and any other chain leave for
// the baseline code. Uses R0 to R4.
fn void OptCg.select_chain_slot(&self, hobject::ICEntry* ic) {
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
        sljit_emit_op1(c, SLJIT_MOV_U32, R0, 0, SLJIT_MEM | R1, 0);
        sljit_emit_op2(c, SLJIT_AND, R0, 0, R0, 0, SLJIT_IMM, l.class_mask | l.plain_exotic_mask);
        a.call.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R0, 0, SLJIT_IMM, l.class_object));
        sljit_emit_op1(c, SLJIT_MOV, R0, 0, SLJIT_MEM | R1, l.obj_proto);
        a.call.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R0, 0, SLJIT_MEM | R4, l.epoch_first));
        sljit_emit_op1(c, SLJIT_MOV, R0, 0, SLJIT_MEM | R4, l.epoch_current);
        sljit_emit_op1(c, SLJIT_MOV, R0, 0, SLJIT_MEM | R0, 0);
        a.call.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R0, 0, SLJIT_MEM | R4, l.epoch_value));
        sljit_emit_op1(c, SLJIT_MOV, R1, 0, SLJIT_MEM | R4, l.epoch_owner);
    } else {
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
        // The receiver of a nested inlined call, held in an OBJECT node.
        rr = self.obj_reg(n.b, R0);
    } else if (a.w.op == Opcode.GETTHISC) {
        if (n.fidx != 0) {
            a.load(R0, self.g.fns[n.fidx].reg_base - 1);
        } else {
            a.load_this(R0);
        }
    } else if (n.b != NO_NODE) {
        rr = self.obj_reg(n.b, R0);
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
    } else if (n.cc == 1) {
        // The receiver was proven an object of this shape by an earlier node (see OptBuild.forget_facts).
        sljit_emit_op2(c, SLJIT_XOR, R1, 0, rr, 0, SLJIT_IMM, K_OBJ);
    } else {
        a.unbox_object(R1, rr);
        a.guard_not_proxy(R1, R2);
        if (chain) {
            hobject::ICEntry* ic = &((hobject::ICEntry*)a.f.ic_entries)[a.next - 1];
            void* settled = self.settled_chain_slot(ic, i);
            self.select_chain_slot(ic);
            if (settled != null) sljit_set_label(settled, sljit_emit_label(c));
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
    } else if (n.rep == OptRep.OBJECT) {
        self.finish_object(i, n);
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
        rr = self.obj_reg(n.b, R0);
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

// PUTPROP of a number to an element, as emit_put_elem: it overwrites a present element of a
// dense array, or stores into a typed array; anything else leaves for the baseline code.
fn void OptCg.emit_store_elem(&self, uint i, OptNode* n) {
    void* c = self.a.c;
    Asm* a = self.a;
    if (n.b == NO_NODE) {
        self.emit_store_elem_window(i, n);
        return;
    }
    self.decode(n);
    a.call.len = 0;
    int rr = R0;
    if (n.c != NO_NODE) {
        rr = self.obj_reg(n.c, R0);
    } else {
        a.load(R0, a.w.a);
    }
    a.unbox_object(R1, rr);
    long flags;
    bool unseen;
    int k = self.typed_kind(a.lay.indexed_named_mask, &flags, &unseen);
    // A double stored to an integer kind needs ta_store_int's modular conversion: the subroutine's.
    if (k >= 0 && (self.g.nodes[n.b].rep == OptRep.INT32 || TYPED_KINDS[k].cls == hobject::ObjClass.FLOAT32ARRAY || TYPED_KINDS[k].cls == hobject::ObjClass.FLOAT64ARRAY)) {
        self.emit_typed_store(i, n, TYPED_KINDS[k], flags);
        return;
    }
    self.box_index(n.a);
    void* other = a.array_or_typed(a.lay.indexed_named_mask);
    a.array_slot();
    a.call.add(sljit_emit_cmp(c, SLJIT_EQUAL, SLJIT_MEM | R0, 0, SLJIT_IMM, K_UNDEF));
    self.box_node(n.b, R2);
    Jumps counted;
    a.guard_old_value(&counted);
    sljit_emit_op1(c, SLJIT_MOV, SLJIT_MEM | R0, 0, R2, 0);
    self.store_counted(i, &counted);
    $if features::BUFFERS:
        void* done = sljit_emit_jump(c, SLJIT_JUMP);
        sljit_set_label(other, sljit_emit_label(c));
        if (unseen) {
            self.unprofiled_exit(i);
        } else {
            self.box_node(n.b, R0);
            a.subs.push({ .jump = sljit_emit_jump(c, SLJIT_FAST_CALL), .sub = TYPED_PUT_SUB });
            a.call.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R2, 0, SLJIT_IMM, SUB_TRUE));
        }
        sljit_set_label(done, sljit_emit_label(c));
    $else
        a.call.add(other);
    $endif
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
        rr = self.obj_reg(n.c, R0);
    } else {
        a.load(R0, a.w.a);
    }
    a.unbox_object(R1, rr);
    long flags;
    bool unseen;
    self.typed_kind(a.lay.indexed_named_mask, &flags, &unseen);
    self.box_index(n.a);
    void* other = a.array_or_typed(a.lay.indexed_named_mask);
    a.array_slot();
    a.call.add(sljit_emit_cmp(c, SLJIT_EQUAL, SLJIT_MEM | R0, 0, SLJIT_IMM, K_UNDEF));
    a.load(R2, a.w.c);
    a.call.add(sljit_emit_cmp(c, SLJIT_EQUAL, R2, 0, SLJIT_IMM, K_UNDEF));
    Jumps counted;
    a.guard_old_value(&counted);
    a.store_value_r2(&counted);
    self.store_counted(i, &counted);
    $if features::BUFFERS:
        void* typed_done = sljit_emit_jump(c, SLJIT_JUMP);
        sljit_set_label(other, sljit_emit_label(c));
        if (unseen) {
            self.unprofiled_exit(i);
        } else {
            a.load(R0, a.w.c);
            a.subs.push({ .jump = sljit_emit_jump(c, SLJIT_FAST_CALL), .sub = TYPED_PUT_SUB });
            a.call.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R2, 0, SLJIT_IMM, SUB_TRUE));
        }
        sljit_set_label(typed_done, sljit_emit_label(c));
    $else
        a.call.add(other);
    $endif
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
        rr = self.obj_reg(n.b, R0);
    } else if (this_op) {
        if (n.fidx != 0) {
            a.load(R0, self.g.fns[n.fidx].reg_base - 1);
        } else {
            a.load_this(R0);
        }
    } else if (n.b != NO_NODE) {
        rr = self.obj_reg(n.b, R0);
    } else {
        a.load(R0, a.w.a);
    }
    if (n.cc != 0) {
        sljit_emit_op2(c, SLJIT_XOR, R1, 0, rr, 0, SLJIT_IMM, K_OBJ);
    } else {
        a.unbox_object(R1, rr);
        a.guard_plain(R1);
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

// Node `i`'s store into the slot at R0 of the object in R1: of node `v`, or of window register
// `rv` when it has none.
fn void OptCg.store_slot_value(&self, uint i, uint v, uint rv) {
    void* c = self.a.c;
    Asm* a = self.a;
    Jumps counted;
    if (v == NO_NODE) {
        a.load(R2, rv);
    } else if (self.g.nodes[v].rep == OptRep.OBJECT) {
        int vr = self.obj_reg(v, R2);
        if (vr != R2) sljit_emit_op1(c, SLJIT_MOV, R2, 0, vr, 0);
    } else {
        self.box_node(v, R2);
    }
    // An OBJECT node (an object or an inert value) mostly replaces an object.
    bool object = v != NO_NODE && self.g.nodes[v].rep == OptRep.OBJECT;
    a.guard_old_value(&counted, object);
    if (v == NO_NODE || object) {
        a.store_value_r2(&counted, object);
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
// Any miss leaves for the baseline code at the call.
fn void OptCg.emit_check_callee(&self, uint i, OptNode* n) {
    void* c = self.a.c;
    Asm* a = self.a;
    CallLayout* k = call_layout();
    CompiledFunction* cf = (CompiledFunction*)(usz)n.imm;
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
    if (n.a != NO_NODE) {
        int r = self.obj_reg(n.a, R1);
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
    sljit_emit_op2(c, SLJIT_XOR, R0, 0, R1, 0, SLJIT_IMM, K_OBJ);
    miss[misses++] = sljit_emit_cmp(c, SLJIT_GREATER_EQUAL, R0, 0, SLJIT_IMM, PAYLOAD_SPAN);
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
    miss[misses++] = sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R4, 0, SLJIT_IMM, (long)(usz)cf);
    Jumps scope;
    a.emit_scope_test(R0, R4, &scope);
    for (uint j = 0; j < scope.len; j++) miss[misses++] = scope.at[j];
    if (constant != null) sljit_set_label(constant, sljit_emit_label(c));
    // An exit from the body publishes its frame and those of the calls around it.
    a.room_acts = max(a.room_acts, caller.depth + 1);
    a.room_slots = max(a.room_slots, callee_reg + 2 + cf.num_regs + vm::FRAME_SCRATCH_SLOTS);
    // A sunk receiver (c names its sink) is an object any exit allocates into the frame it publishes.
    if ((n.cc & 3) == 1 && !cf.call_flags.ignores_this && !(n.b == NO_NODE && n.c != NO_NODE)) {
        // The receiver: an object in a register the caller's frame tracks, or in an OBJECT node
        // that any exit stores into a frame it publishes.
        // The read of the method proved it an object when it is that read's receiver (bit 3).
        if ((n.cc & 8) == 0) {
            if (n.b != NO_NODE) {
                int r = self.obj_reg(n.b, R0);
                sljit_emit_op2(c, SLJIT_XOR, R0, 0, r, 0, SLJIT_IMM, K_OBJ);
            } else {
                a.load(R0, callee_reg + 1);
                sljit_emit_op2(c, SLJIT_XOR, R0, 0, R0, 0, SLJIT_IMM, K_OBJ);
            }
            miss[misses++] = sljit_emit_cmp(c, SLJIT_GREATER_EQUAL, R0, 0, SLJIT_IMM, PAYLOAD_SPAN);
            miss[misses++] = sljit_emit_cmp(c, SLJIT_EQUAL, R0, 0, SLJIT_IMM, 0);
        }
        if (n.b == NO_NODE && callee_reg + 1 >= a.frame_regs) {
            sljit_emit_op1(c, SLJIT_MOV, R0, 0, a.la, 0);
            sljit_emit_op1(c, SLJIT_MOV_U32, R0, 0, m | R0, a.lay.act_hrc);
            miss[misses++] = sljit_emit_cmp(c, SLJIT_LESS_EQUAL, R0, 0, SLJIT_IMM, (long)callee_reg + 1);
        }
    }
    for (uint j = 0; j < misses; j++) self.exit_at(miss[j], i, OptExit.CALLEE);
}

// The machine registers that hold a value across node `i` (a node defined before it whose last use
// is after it occupies its register there) stored to the frame's save area, or loaded back from it,
// around a call of C from inside the node. Uses no other register.
fn void OptCg.spill_live(&self, uint i, bool save) {
    void* c = self.a.c;
    for (uint j = 0; j < i; j++) {
        OptNode* nd = &self.g.nodes[j];
        if (!nd.allocated() || nd.reg < 0 || nd.last_use <= i) continue;
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

// The object of an inlined NEW_OBJ, built by vm::jit_opt_new_object with the registers in use saved
// around the call; a constructor or cache it refuses leaves for the baseline code at the NEW_OBJ.
fn void OptCg.emit_new_object(&self, uint i, OptNode* n) {
    void* c = self.a.c;
    Asm* a = self.a;
    CompiledFunction* cf = (CompiledFunction*)(usz)n.imm;
    a.decode(n.pc);
    OptFn* caller = &self.g.fns[n.fidx];
    uint callee_reg = a.w.b + caller.reg_base;
    long ic = (long)(usz)&((hobject::ICEntry*)caller.f.ic_entries)[a.next - 1];
    // The properties the body can add, or what the constructor's frames have left on their objects.
    uint want = cf.call_flags.constructor_capacity;
    uint adds = 0;
    for (uint k = 0; k < cf.code_count; k++) if (cf.code[k].op == Opcode.PUTTHISC) adds++;
    if (adds > want) want = adds;
    if (n.a != NO_NODE) {
        int r = self.obj_reg(n.a, R1);
        if (r != R1) sljit_emit_op1(c, SLJIT_MOV, R1, 0, r, 0);
    } else {
        a.load(R1, callee_reg);
    }
    // The guard before proved it an object.
    sljit_emit_op2(c, SLJIT_XOR, R1, 0, R1, 0, SLJIT_IMM, K_OBJ);
    // The common case builds the object inline, from the cache the helper would read. R0 to R4 hold
    // no values of the optimized code, so nothing is saved around it.
    Jumps slow;
    void* done = null;
    if (inline_alloc_ok() && want <= hobject::INLINE_PROPS) {
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
        sljit_emit_op2(c, SLJIT_XOR, R2, 0, R0, 0, SLJIT_IMM, K_OBJ);
        slow.add(sljit_emit_cmp(c, SLJIT_GREATER_EQUAL, R2, 0, SLJIT_IMM, PAYLOAD_SPAN));
        // Heap.set_prototype also walks the other realms when there are any.
        slow.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, m | a.heap, l.heap_realms, SLJIT_IMM, 0));
        sljit_emit_op1(c, SLJIT_MOV, m | reg_sp(), SUB_VALUE_OFF, R2, 0);
        InlineAlloc plan = a.plain_object_plan();
        a.emit_inline_alloc(&plan, &slow);
        sljit_emit_op2(c, SLJIT_OR, R0, 0, R0, 0, SLJIT_IMM, K_OBJ);
        done = sljit_emit_jump(c, SLJIT_JUMP);
        slow.bind(sljit_emit_label(c));
        // The slow path reloads the constructor.
        if (n.a != NO_NODE) {
            int r = self.obj_reg(n.a, R1);
            if (r != R1) sljit_emit_op1(c, SLJIT_MOV, R1, 0, r, 0);
        } else {
            a.load(R1, callee_reg);
        }
        sljit_emit_op2(c, SLJIT_XOR, R1, 0, R1, 0, SLJIT_IMM, K_OBJ);
    }
    self.spill_live(i, true);
    sljit_emit_op1(c, SLJIT_MOV, R0, 0, a.ds, 0);
    sljit_emit_op1(c, SLJIT_MOV, R2, 0, SLJIT_IMM, ic);
    sljit_emit_op1(c, SLJIT_MOV, R3, 0, SLJIT_IMM, (long)want);
    self.a.c_call(SLJIT_ARGS4WWWW, SLJIT_IMM, (long)(usz)&vm::jit_opt_new_object);
    self.spill_live(i, false);
    self.exit_at(sljit_emit_cmp(c, SLJIT_EQUAL, R0, 0, SLJIT_IMM, 0), i, OptExit.ALLOC_SLOW);
    if (done != null) sljit_set_label(done, sljit_emit_label(c));
    self.def_obj(i, R0);
    self.count_alloc(&self.h.opt.alloc_runs);
}

// The NEW_OBJECT of a sunk allocation: no object, only the check that the state its site validated
// (OptSinkSite) still holds, else vm::jit_opt_sink_check validates the site again with the registers
// in use saved around the call; what that refuses leaves for the baseline code at the NEW_OBJ.
fn void OptCg.emit_sunk_object(&self, uint i, OptNode* n) {
    void* c = self.a.c;
    Asm* a = self.a;
    CompiledFunction* cf = (CompiledFunction*)(usz)n.imm;
    a.decode(n.pc);
    OptFn* caller = &self.g.fns[n.fidx];
    uint callee_reg = a.w.b + caller.reg_base;
    OptSink* sk = &self.g.sinks[(sz)n.c];
    OptSinkSite* site = self.h.alloc_func(self.h.heap_udata, OptSinkSite::size);
    mem::clear(site, OptSinkSite::size);
    site.next = self.oc.sink_sites;
    self.oc.sink_sites = site;
    site.new_ic = &((hobject::ICEntry*)caller.f.ic_entries)[a.next - 1];
    uint want = cf.call_flags.constructor_capacity;
    uint adds = 0;
    for (uint k = 0; k < cf.code_count; k++) if (cf.code[k].op == Opcode.PUTTHISC) adds++;
    site.want = adds > want ? adds : want;
    site.add_count = sk.add_count;
    site.read_count = sk.read_count;
    for (uint k = 0; k < sk.add_count; k++) site.keys[k] = sk.keys[k];
    for (uint k = 0; k < sk.read_count; k++) site.read_keys[k] = sk.reads[k];
    sk.site = site;
    if (n.a != NO_NODE) {
        int r = self.obj_reg(n.a, R1);
        if (r != R1) sljit_emit_op1(c, SLJIT_MOV, R1, 0, r, 0);
    } else {
        a.load(R1, callee_reg);
    }
    // The guard before proved it an object.
    sljit_emit_op2(c, SLJIT_XOR, R1, 0, R1, 0, SLJIT_IMM, K_OBJ);
    sljit_emit_op1(c, SLJIT_MOV, R2, 0, SLJIT_IMM, (long)(usz)site);
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
            if (self.g.nodes[v].rep == OptRep.OBJECT) {
                r = self.obj_reg(v, R0);
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
    CompiledFunction* f = self.g.fns[n.fidx].f;
    long ic = (long)(usz)&((hobject::ICEntry*)f.ic_entries)[a.next - 1];
    long key = (long)(usz)f.constants[a.w.c].get_heapptr();
    // The value's address: its window slot, or OptCode.value for a boxed node.
    long boxed = (long)(usz)&self.oc.value;
    if (n.a == NO_NODE) {
        sljit_emit_op2(c, SLJIT_ADD, R3, 0, a.regs, 0, SLJIT_IMM, (long)a.w.a * TVal::size);
    } else {
        if (self.g.nodes[n.a].rep == OptRep.OBJECT) {
            int vr = self.obj_reg(n.a, R2);
            if (vr != R2) sljit_emit_op1(c, SLJIT_MOV, R2, 0, vr, 0);
        } else {
            self.box_node(n.a, R2);
        }
        sljit_emit_op1(c, SLJIT_MOV, SLJIT_MEM, boxed, R2, 0);
        sljit_emit_op1(c, SLJIT_MOV, R3, 0, SLJIT_IMM, boxed);
    }
    int rr = self.obj_reg(n.b, R1);
    sljit_emit_op2(c, SLJIT_XOR, R1, 0, rr, 0, SLJIT_IMM, K_OBJ);
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
            closure = n.b != NO_NODE ? self.obj_reg(n.b, R3) : -1;
        }
    }
    if (n.rep == OptRep.OBJECT) {
        // A callee register beyond the caller's frame: the value stays in a register.
        a.var_slot(vic, n.cc != 0, creg, closure);
        if (n.cc != 0) {
            sljit_emit_op1(self.a.c, SLJIT_MOV_U8, R1, 0, SLJIT_MEM | R2, a.lay.vic_flags);
            sljit_emit_op2(self.a.c, SLJIT_AND, R1, 0, R1, 0, SLJIT_IMM, a.lay.accessor_mask);
            a.call.add(sljit_emit_cmp(self.a.c, SLJIT_NOT_EQUAL, R1, 0, SLJIT_IMM, 0));
        }
        sljit_emit_op1(self.a.c, SLJIT_MOV, R0, 0, SLJIT_MEM | R0, 0);
        a.guard_not_tdz();
        for (uint k = 0; k < a.alt.len; k++) self.exit_at(a.alt.at[k], i, OptExit.SLOW_PATH);
        a.alt.len = 0;
        self.exit_calls(i, OptExit.SLOW_PATH);
        self.finish_object(i, n);
        return;
    }
    a.emit_get_var(ra, vic, n.cc != 0, creg, closure);
    // A moved entry re-arms in the baseline code.
    for (uint k = 0; k < a.alt.len; k++) self.exit_at(a.alt.at[k], i, OptExit.SLOW_PATH);
    a.alt.len = 0;
    self.exit_calls(i, OptExit.SLOW_PATH);
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
        int src = self.obj_reg(n.a, R0);
        if (src != R0) sljit_emit_op1(self.a.c, SLJIT_MOV, R0, 0, src, 0);
    } else {
        a.load(R0, (uint)n.imm);
    }
    a.typeof_value(n.home);
    // The instructions the name is not read off by tag, and the [[IsHTMLDDA]] object, are the thunk's.
    self.exit_calls(i, OptExit.SLOW_PATH);
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
    sljit_emit_op2(c, SLJIT_OR, R0, 0, R0, 0, SLJIT_IMM, K_OBJ);
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
        int or = self.obj_reg(n.b, R4);
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
    if (n.rep == OptRep.OBJECT) {
        self.finish_object(i, n);
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
        int r = self.obj_reg(n.a, R1);
        if (r != R1) sljit_emit_op1(c, SLJIT_MOV, R1, 0, r, 0);
    } else {
        a.load(R1, n.home);
    }
    // A builtin not yet given an object of its realm is a light function.
    void* light = sljit_emit_cmp(c, SLJIT_EQUAL, R1, 0, SLJIT_IMM, (long)((types::TAG_LIGHTFUNC << 48) | (ulong)n.imm));
    sljit_emit_op2(c, SLJIT_XOR, R0, 0, R1, 0, SLJIT_IMM, K_OBJ);
    self.exit_at(sljit_emit_cmp(c, SLJIT_GREATER_EQUAL, R0, 0, SLJIT_IMM, PAYLOAD_SPAN), i, OptExit.CALLEE);
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
    } else if (self.g.nodes[n.a].rep == OptRep.OBJECT) {
        int v = self.obj_reg(n.a, R2);
        if (v != R2) sljit_emit_op1(c, SLJIT_MOV, R2, 0, v, 0);
    } else {
        self.box_node(n.a, R2);
    }
    if (n.b == NO_NODE) {
        a.load(R1, callee + 1);
    } else {
        int r = self.obj_reg(n.b, R1);
        if (r != R1) sljit_emit_op1(c, SLJIT_MOV, R1, 0, r, 0);
    }
    sljit_emit_op2(c, SLJIT_XOR, R1, 0, R1, 0, SLJIT_IMM, K_OBJ);
    self.exit_at(sljit_emit_cmp(c, SLJIT_GREATER_EQUAL, R1, 0, SLJIT_IMM, PAYLOAD_SPAN), i, OptExit.SLOW_PATH);
    self.spill_live(i, true);
    sljit_emit_op1(c, SLJIT_MOV, R0, 0, a.ds, 0);
    self.a.c_call(SLJIT_ARGS3WWW, SLJIT_IMM, (long)(usz)&opt_array_push);
    self.spill_live(i, false);
    self.exit_at(sljit_emit_cmp(c, SLJIT_SIG_LESS, R0, 0, SLJIT_IMM, 0), i, OptExit.SLOW_PATH);
    self.def_int(i, R0);
}

// Array.prototype.push of the boxed `value` onto `obj` for ARRAY_PUSH, as the builtin's dense fast
// path appends it, growing the storage (which allocates without collecting); the new length, or -1
// with nothing done for any other receiver or value.
fn long opt_array_push(Dispatch* ds, HObject* obj, ulong value) {
$if types::USE_NANBOX:
    TVal v = { .bits = value };
    Heap* h = ds.heap;
    if (obj.get_class() != hobject::ObjClass.ARRAY || obj.prop_count != 0 || !obj.flags.extensible
        || !obj.flags.array_len_writable || obj.flags.has_indexed_named_prop || v.is_undefined()) return -1;
    uint len = *obj.array_len_ptr();
    if (len >= 0x1000000u) return -1;
    if (len < obj.array_size) {
        hobject::PropValue* dense = obj.array_part();
        if (dense == null || !dense[len].get().is_undefined()) return -1;
    } else if (obj.array_size != 0 && obj.array_part() == null) {
        return -1;
    }
    HObject* array_proto = h.array_proto;
    HObject* object_proto = h.object_proto;
    if (array_proto == null || object_proto == null || obj.prototype != array_proto
        || array_proto.get_class() != hobject::ObjClass.ARRAY
        || object_proto.get_class() != hobject::ObjClass.OBJECT
        || array_proto.prototype != object_proto || object_proto.prototype != null
        || array_proto.flags.has_indexed_named_prop || array_proto.array_used > 0
        || object_proto.flags.has_indexed_named_prop || object_proto.array_used > 0) return -1;
    if (!obj.set_array_idx(len, v, h)) return -1;
    *obj.array_len_ptr() = len + 1;
    return (long)len + 1;
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
    a.track_heap_store(n.home, R3, R2);
}

fn void OptCg.emit_copy(&self, OptNode* n, uint i) {
    void* c = self.a.c;
    if (n.rep == OptRep.OBJECT) {
        int r = self.obj_reg(n.a, R0);
        int dst = self.int_dst(i, R0);
        if (dst != r) sljit_emit_op1(c, SLJIT_MOV, dst, 0, r, 0);
        self.def_obj(i, dst);
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

// COMPARE_WINDOW: the baseline's equality test of two window slots, stored as a boolean.
fn void OptCg.emit_compare_window(&self, uint i, OptNode* n) {
    void* c = self.a.c;
    Jumps yes;
    Jumps no;
    self.a.call.len = 0;
    self.a.load(R0, (uint)(n.imm & 0xFFFFF));
    self.a.load(R1, (uint)(n.imm >> 20));
    self.a.call_test_sub(n.cc < 2 ? STRICT_EQ_SUB : LOOSE_EQ_SUB, &yes, &no);
    self.exit_calls(i, OptExit.SLOW_PATH);
    bool negate = (n.cc & 1) != 0;
    yes.bind(sljit_emit_label(c));
    self.a.store(n.home, SLJIT_IMM, K_BOOL | (negate ? 0 : 1));
    void* done = sljit_emit_jump(c, SLJIT_JUMP);
    no.bind(sljit_emit_label(c));
    self.a.store(n.home, SLJIT_IMM, K_BOOL | (negate ? 1 : 0));
    sljit_set_label(done, sljit_emit_label(c));
}

// LNOT: the negated truth of a number or boolean node, or of a window slot, stored as a boolean.
fn void OptCg.emit_lnot(&self, uint i, OptNode* n) {
    void* c = self.a.c;
    if (n.a != NO_NODE) {
        void* truthy;
        if (self.g.nodes[n.a].rep == OptRep.OBJECT) {
            int x = self.obj_reg(n.a, R0);
            int dst = self.int_dst(i, R0);
            sljit_emit_op2(c, SLJIT_XOR, dst, 0, x, 0, SLJIT_IMM, 1);
            self.def_obj(i, dst);
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
    self.a.call.len = 0;
    self.a.truth_test((uint)n.imm, &truthy, &falsy);
    self.exit_calls(i, OptExit.SLOW_PATH);
    truthy.bind(sljit_emit_label(c));
    self.a.store(n.home, SLJIT_IMM, K_BOOL);
    void* done = sljit_emit_jump(c, SLJIT_JUMP);
    falsy.bind(sljit_emit_label(c));
    self.a.store(n.home, SLJIT_IMM, K_BOOL | 1);
    sljit_set_label(done, sljit_emit_label(c));
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

// A conditional branch: leave the taken jumps in `jumps`.
// BRANCH_WINDOW: the baseline's equality or null test over two window slots; the rare cases
// leave through the slow path.
fn uint OptCg.emit_window_branch(&self, uint i, OptNode* n, void** jumps) {
    uint rb = (uint)(n.imm & 0xFFFFF);
    uint rc = (uint)(n.imm >> 20);
    Jumps yes;
    Jumps no;
    self.a.call.len = 0;
    void* c = self.a.c;
    // An operand held in an OBJECT node (a, b) is taken from its register.
    if (n.a != NO_NODE) {
        int x = self.obj_reg(n.a, R0);
        if (x != R0) sljit_emit_op1(c, SLJIT_MOV, R0, 0, x, 0);
    } else {
        self.a.load(R0, rb);
    }
    if (n.cc >= 4) {
        self.a.null_test_r0(&yes, &no);
    } else {
        if (n.b != NO_NODE) {
            int y = self.obj_reg(n.b, R1);
            if (y != R1) sljit_emit_op1(c, SLJIT_MOV, R1, 0, y, 0);
        } else {
            self.a.load(R1, rc);
        }
        self.a.call_test_sub(n.cc < 2 ? STRICT_EQ_SUB : LOOSE_EQ_SUB, &yes, &no);
    }
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
fn uint OptCg.emit_callee_test(&self, uint i, OptNode* n, void** jumps) {
    void* c = self.a.c;
    Asm* a = self.a;
    CallLayout* k = call_layout();
    a.decode(n.pc);
    if (n.a != NO_NODE) {
        int r = self.obj_reg(n.a, R1);
        if (r != R1) sljit_emit_op1(c, SLJIT_MOV, R1, 0, r, 0);
    } else {
        a.load(R1, a.w.b + self.g.fns[n.fidx].reg_base);
    }
    sljit_emit_op2(c, SLJIT_XOR, R0, 0, R1, 0, SLJIT_IMM, K_OBJ);
    jumps[0] = sljit_emit_cmp(c, SLJIT_GREATER_EQUAL, R0, 0, SLJIT_IMM, PAYLOAD_SPAN);
    jumps[1] = sljit_emit_cmp(c, SLJIT_EQUAL, R0, 0, SLJIT_IMM, 0);
    sljit_emit_op1(c, SLJIT_MOV_U32, R4, 0, SLJIT_MEM | R0, 0);
    sljit_emit_op2(c, SLJIT_AND, R4, 0, R4, 0, SLJIT_IMM, k.fn_mask);
    jumps[2] = sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R4, 0, SLJIT_IMM, k.fn_want);
    sljit_emit_op1(c, SLJIT_MOV, R4, 0, SLJIT_MEM | R0, a.lay.fn_comp_func);
    jumps[3] = sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R4, 0, SLJIT_IMM, n.imm);
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
    if (n.a != NO_NODE) {
        if (self.g.nodes[n.a].rep == OptRep.OBJECT) {
            // A boolean: its low bit.
            int x = self.obj_reg(n.a, R0);
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
        if (nd.rep == OptRep.OBJECT) {
            self.a.load(nd.reg, d.reg);
        } else if (nd.rep == OptRep.INT32) {
            self.load_unboxed(nd.reg, d.reg);
        } else {
            self.reload_flt(nd.reg, d.reg);
        }
    }
}

// CALL_REG: the call of n.key, which CHECK_CALLEE proved, through the register label of the
// callee's code as it stands (Asm.emit_call_entry): the direct label's path on a native frame of
// its own, so that the values live across the call wait in this frame's save area rather than
// boxed in the window. The callee's record is an ordinary one: it may exit, throw, collect or
// call as any frame does, and it returns its result in R1. The snapshot's stores and the resume
// point in this frame's record let the baseline code continue this frame from its window should
// the native frames be abandoned (jit_enter). A callee that declines (no native stack, record or
// value stack left) did nothing, and the baseline code makes the call (OptExit.DEEP).
fn void OptCg.emit_call_reg(&self, uint i, OptNode* n) {
    Asm* a = self.a;
    void* c = a.c;
    CallLayout* k = call_layout();
    self.store_dirty(n.dirty_first, n.dirty_count);
    a.decode((uint)n.imm);
    bool var_call = a.w.op == Opcode.CALL_VAR || a.w.op == Opcode.CALL_GLOBAL;
    bool method = a.w.op == Opcode.CALL;
    uint callee = var_call ? a.w.a : a.w.b;
    uint nargs = var_call ? a.w.b : a.w.c;
    CompiledFunction* cf = (CompiledFunction*)n.key;
    self.spill_live(i, true);
    // A plain call's receiver is undefined, as th_publish_lean's clear_this makes it.
    if (!method) a.store(callee + 1, SLJIT_IMM, K_UNDEF);
    a.mov(R0, 0, SLJIT_MEM, (long)(usz)&cf.jit_code);
    void* no_code = sljit_emit_cmp(c, SLJIT_EQUAL, R0, 0, SLJIT_IMM, 0);
    a.mov(R0, 0, SLJIT_MEM | R0, k.bc_reg_entry);
    void* no_entry = sljit_emit_cmp(c, SLJIT_EQUAL, R0, 0, SLJIT_IMM, 0);
    a.mov(R4, 0, SLJIT_IMM, (long)(usz)(a.f.code + (uint)n.imm + 1));
    a.mov(SLJIT_MEM | a.la, k.act_curr_pc, R4, 0);
    sljit_emit_op2(c, SLJIT_ADD, R1, 0, a.regs, 0, SLJIT_IMM, (long)(callee + 2) * TVal::size);
    sljit_emit_op2(c, SLJIT_ADD, R2, 0, a.regs, 0, SLJIT_IMM, (long)a.w.a * TVal::size);
    a.mov(R3, 0, SLJIT_IMM, (long)nargs | (method ? CALL_METHOD : CALL_PLAIN));
    sljit_emit_ijump(c, SLJIT_FAST_CALL, R0, 0);
    // The entry used the window register; the return left this frame's record in its register.
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
    self.exit_clean(sljit_emit_jump(c, SLJIT_JUMP), n.pc, OptExit.DEEP);
    self.exit_clean(no_code, n.pc, OptExit.DECLINED);
    self.exit_clean(no_entry, n.pc, OptExit.DECLINED);
    sljit_set_label(done, sljit_emit_label(c));
}

fn void OptCg.emit_node(&self, uint i, uint pos) {
    void* c = self.a.c;
    OptNode* n = &self.g.nodes[i];
    self.use_fn(n.fidx);
    if (n.dirty_count != 0 || n.op == OptOp.GENERIC || n.op == OptOp.CHECK_I32 || n.op == OptOp.CHECK_NUM || n.op == OptOp.LOAD_CAP || n.op == OptOp.LOAD_ELEM || n.op == OptOp.STORE_ELEM || n.op == OptOp.LOAD_FIELD || n.op == OptOp.LOAD_LENGTH || n.op == OptOp.STORE_FIELD || n.op == OptOp.CHECK_CALLEE || n.op == OptOp.COPY_WINDOW || n.op == OptOp.LOAD_VAR || n.op == OptOp.LOAD_GLOBAL || n.op == OptOp.COMPARE_WINDOW || n.op == OptOp.LNOT || n.op == OptOp.NEW_OBJECT || n.op == OptOp.ADD_FIELD || n.op == OptOp.CHECK_BUILTIN || n.op == OptOp.ARRAY_PUSH) {
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
        case COPY_WINDOW:
            self.emit_copy_window(i, n);
        case STORE_CONST:
            self.a.store(n.home, SLJIT_IMM, n.imm);
        case TYPEOF:
            self.emit_typeof(i, n);
        case ALLOC:
            self.emit_alloc(i, n);
        case INIT_SLOT:
            self.emit_init_slot(i, n);
        case STORE_OBJ:
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
    a.opt = true;
    // A slot past the spill area for the capture records, when a read of the function's own uses them.
    long cap_slot = -1;
    foreach (&nd : g.nodes) {
        if (nd.op == OptOp.LOAD_CAP && nd.fidx == 0 && f.capture_count != 0) cap_slot = CALL_FRAME_BYTES + 8 * (long)(pools.int_count + pools.flt_count);
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
    for (uint pos = 0; pos < blocks; pos++) {
        OptBlock* blk = &g.blocks[pos];
        cg.labels[pos] = sljit_emit_label(c);
        if (pos == 0) cg.emit_cap_refs();
        for (uint i = blk.first; i < blk.end; i++) {
            cg.emit_node(i, pos);
            bc.insns++;
        }
    }
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
    // A direct call enters at the first block, which holds no values in registers unless the
    // function starts with a loop.
    void* call_entry = null;
    if (call_entry_eligible(f) && !g.blocks[0].osr) {
        a.labels[0] = cg.labels[0];
        call_entry = a.emit_call_entry(bc, touch: true);
    }
    foreach (gt : cg.gotos) sljit_set_label(gt.jump, cg.labels[gt.block]);
    if (a.finish(h, bc, call_entry) == null) return null;
    for (uint i = 0; i < count; i++) {
        if (a.starts[i]) bc.entries[i] = (void*)sljit_shim_label_addr(to_base);
    }
    // A region's first block is its loop header, entered only through its OSR entry.
    if (g.region.end == 0) bc.entries[0] = (void*)sljit_shim_label_addr(start);
    for (uint pos = 0; pos < blocks; pos++) {
        if (g.blocks[pos].osr) bc.entries[g.blocks[pos].pc] = (void*)sljit_shim_label_addr(cg.osr_labels[pos]);
    }
    return bc;
}
