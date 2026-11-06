// Optimizing tier: building the graph from the bytecode.
//
// The function's control flow graph is ordered in reverse postorder and built
// in one pass in that order, keeping for each JS register either Window or a
// numeric node (see opt_ir.c3). A merge makes a phi only where every
// predecessor holds a numeric node. A loop header speculates its phis from the
// states that reach it from before the loop, and the build starts over, with
// the choice overridden, when a back edge disagrees.
module boomkat::jit @feat(SLJIT);

import boomkat::vm;
import boomkat::bytecode;
import boomkat::compiler;
import boomkat::heap;
import boomkat::hobject;
import boomkat::types;
import std::collections::list;

// Largest graph a function may build into, and the rounds of loop repair.
const uint OPT_BLOCK_MAX = 1024;
const uint OPT_STATE_MAX = 256 * 1024;
const uint OPT_BUILD_ROUNDS = 5;

// A loop phi's decision, overriding the speculation from the preheader.
struct OptOverride {
    uint block;
    uint reg;
    OptRep rep;
}

struct OptRegState {
    uint node;
    bool dirty;
}

// Why a function was not optimized.
enum OptRefuse : char (String label) {
    NONE {"none"},
    FUNCTION {"function kind"},
    CFG {"control flow graph"},
    OPCODE {"opcode"},
    IRREDUCIBLE {"irreducible loop"},
    BUDGET {"graph size"},
    REPAIR {"loop repair rounds"},
    PRESSURE {"phi register pressure"},
    BRANCH_OPERANDS {"branch operands"},
    COMPILE {"code generation"},
}

struct OptBuild {
    Heap* h;
    CompiledFunction* f;
    DecodedCfg cfg;
    RegSet* live_in;
    RegSet* live_out;
    uint* live_words;
    RegSet* live_sets;
    OptGraph* g;
    uint nregs;
    // Basic blocks by CFG block id: their instruction range.
    uint nb;
    uint* b_first;
    uint* b_last;
    // Reverse postorder: block at each position, and each block's position
    // (NO_NODE when unreachable).
    uint* rpo;
    uint* pos_of;
    uint nrpo;
    uint* pred_off;
    uint* pred_list;
    // Immediate dominators by position.
    uint* idom;
    uint* loop_end;
    // By instruction: the target of a backward branch.
    bool* osr_target;
    OptRegState* cur;
    // Per JS register, and at index nregs for `this`: the shape id of the object it holds when the
    // last LOAD_FIELD or STORE_FIELD on it passed its guards and nothing since can have changed
    // that, else SHAPE_NONE; and whether that node also proved the object plain (GETTHISC only
    // proves it is not a proxy).
    uint* fact_shape;
    bool* fact_plain;
    // The pc of the GETCAP or GETPROP, still run as GENERIC, that last defined each register in
    // this block, or NO_NODE; a numeric use of the register asks for it to be a typed load.
    uint* load_def;
    // The rep a numeric use asked of the load at each pc (OptOverride.block); the next round
    // builds those as LOAD_CAP and LOAD_ELEM nodes.
    List {OptOverride} load_reps;
    bool load_changed;
    // The register states at the end and at the start of each block, by position.
    OptRegState* ends;
    OptRegState* entries;
    List{OptOverride} overrides;
    OptRefuse refused;
    Opcode refused_op;
    // The instruction being lowered.
    uint insn;
    uint pc;
    uint next_pc;
    DecodedInsn w;
    bool wide;
    uint pos;
    // False once a SETCONST can change the constant table.
    bool consts_ok;
}

fn bool opt_function_eligible(CompiledFunction* f) {
$if !types::USE_NANBOX:
    return false;
$else
    if (f.code == null || f.code_count == 0 || f.num_regs == 0 || f.num_regs >= compiler::BYTECODE_REGS_MAX) return false;
    if (f.flags.is_generator || f.flags.is_async || f.flags.has_direct_eval || f.flags.needs_lex_bridge) return false;
    return !f.mapped_arguments();
$endif
}

fn bool OptBuild.refuse(&self, OptRefuse why) {
    if (self.refused == OptRefuse.NONE) self.refused = why;
    return false;
}

fn bool OptBuild.refuse_op(&self, Opcode op) {
    if (self.refused == OptRefuse.NONE) self.refused_op = op;
    return self.refuse(OptRefuse.OPCODE);
}

fn void OptBuild.free(&self) {
    compiler::bytecode_cfg_free(&self.cfg);
    mem::free(self.live_sets);
    mem::free(self.live_words);
    mem::free(self.b_first);
    mem::free(self.b_last);
    mem::free(self.rpo);
    mem::free(self.pos_of);
    mem::free(self.pred_off);
    mem::free(self.pred_list);
    mem::free(self.idom);
    mem::free(self.loop_end);
    mem::free(self.osr_target);
    mem::free(self.cur);
    mem::free(self.load_def);
    mem::free(self.fact_shape);
    mem::free(self.fact_plain);
    mem::free(self.ends);
    mem::free(self.entries);
    self.overrides.free();
    self.load_reps.free();
}

// --- Control flow analysis ---

fn uint OptBuild.succ_block(&self, uint b, uint k) {
    DecodedCfgNode* last = &self.cfg.nodes[self.b_last[b]];
    return self.cfg.nodes[last.successors[k]].block;
}

fn uint OptBuild.succ_count(&self, uint b) => self.cfg.nodes[self.b_last[b]].successor_count;

// The reachable predecessors of the block at position `pos`.
fn uint[] OptBuild.preds(&self, uint b) {
    return self.pred_list[self.pred_off[b]:self.pred_off[b + 1] - self.pred_off[b]];
}

fn bool OptBuild.dominates(&self, uint a, uint b) {
    uint x = b;
    while (true) {
        if (x == a) return true;
        if (x == 0) return false;
        x = self.idom[x];
    }
}

fn uint OptBuild.intersect(&self, uint a, uint b) {
    while (a != b) {
        while (a > b) a = self.idom[a];
        while (b > a) b = self.idom[b];
    }
    return a;
}

// Decode the control flow graph and order its blocks. Fails, naming the
// reason, for a function the tier does not handle.
fn bool OptBuild.analyze(&self) {
    CompiledFunction* f = self.f;
    if (!compiler::bytecode_cfg_build(&self.cfg, f.code, f.code_count, self.h)) return self.refuse(OptRefuse.CFG);
    DecodedCfg* cfg = &self.cfg;
    uint count = cfg.instruction_count;
    self.nregs = f.num_regs;
    self.consts_ok = true;
    for (uint i = 0; i < f.code_count; i++) if (f.code[i].op == Opcode.SETCONST) self.consts_ok = false;
    self.nb = cfg.block_count;
    if (self.nb > OPT_BLOCK_MAX || (usz)self.nb * self.nregs > OPT_STATE_MAX) return self.refuse(OptRefuse.BUDGET);
    uint words = (self.nregs + 32) / 32;
    self.live_sets = mem::new_array(RegSet, (usz)count * 2);
    self.live_words = mem::new_array(uint, ((usz)count * 2 + 1) * words);
    for (uint i = 0; i < count * 2; i++) self.live_sets[i] = { .words = self.live_words + (usz)i * words, .word_count = words };
    RegSet scratch = { .words = self.live_words + (usz)count * 2 * words, .word_count = words };
    compiler::bytecode_cfg_liveness(cfg, self.live_sets, self.live_sets + count, &scratch, true, false);
    self.live_out = self.live_sets;
    self.live_in = self.live_sets + count;

    self.osr_target = mem::new_array(bool, count);
    for (uint i = 0; i < count; i++) {
        uint t = cfg.nodes[i].branch_target;
        if (t != compiler::CFG_NO_INSTRUCTION && t <= i) self.osr_target[t] = true;
    }
    uint nb = self.nb;
    self.b_first = mem::new_array(uint, nb);
    self.b_last = mem::new_array(uint, nb);
    for (uint i = 0; i < count; i++) {
        uint b = cfg.nodes[i].block;
        if (cfg.nodes[i].block_entry) self.b_first[b] = i;
        self.b_last[b] = i;
    }
    // Reverse postorder by an explicit-stack depth-first search.
    self.rpo = mem::new_array(uint, nb);
    self.pos_of = mem::new_array(uint, nb);
    uint* stack = mem::new_array(uint, nb);
    uint* stack_k = mem::new_array(uint, nb);
    bool* seen = mem::new_array(bool, nb);
    defer { mem::free(stack); mem::free(stack_k); mem::free(seen); }
    for (uint b = 0; b < nb; b++) self.pos_of[b] = NO_NODE;
    uint sp = 0;
    uint post = 0;
    stack[0] = 0;
    stack_k[0] = 0;
    seen[0] = true;
    sp = 1;
    while (sp > 0) {
        uint b = stack[sp - 1];
        if (stack_k[sp - 1] < self.succ_count(b)) {
            uint s = self.succ_block(b, stack_k[sp - 1]++);
            if (!seen[s]) {
                seen[s] = true;
                stack[sp] = s;
                stack_k[sp] = 0;
                sp++;
            }
        } else {
            // Postorder numbers count up; reverse them afterwards.
            self.rpo[post++] = b;
            sp--;
        }
    }
    self.nrpo = post;
    for (uint i = 0; i < post / 2; i++) {
        uint t = self.rpo[i];
        self.rpo[i] = self.rpo[post - 1 - i];
        self.rpo[post - 1 - i] = t;
    }
    for (uint i = 0; i < post; i++) self.pos_of[self.rpo[i]] = i;
    // Predecessors as positions, over the reachable blocks.
    self.pred_off = mem::new_array(uint, (sz)post + 1);
    for (uint i = 0; i < post; i++) {
        uint b = self.rpo[i];
        for (uint k = 0; k < self.succ_count(b); k++) self.pred_off[self.pos_of[self.succ_block(b, k)] + 1]++;
    }
    for (uint i = 0; i < post; i++) self.pred_off[i + 1] += self.pred_off[i];
    self.pred_list = mem::new_array(uint, (sz)self.pred_off[post] + 1);
    uint* fill = mem::new_array(uint, post);
    defer mem::free(fill);
    for (uint i = 0; i < post; i++) {
        uint b = self.rpo[i];
        for (uint k = 0; k < self.succ_count(b); k++) {
            uint s = self.pos_of[self.succ_block(b, k)];
            self.pred_list[self.pred_off[s] + fill[s]++] = i;
        }
    }
    // Dominators (Cooper, Harvey, Kennedy).
    self.idom = mem::new_array(uint, post);
    for (uint i = 1; i < post; i++) self.idom[i] = NO_NODE;
    bool changed = true;
    while (changed) {
        changed = false;
        for (uint i = 1; i < post; i++) {
            uint nd = NO_NODE;
            foreach (p : self.preds(i)) {
                if (self.idom[p] == NO_NODE && p != 0) continue;
                nd = nd == NO_NODE ? p : self.intersect(p, nd);
            }
            if (nd != self.idom[i]) { self.idom[i] = nd; changed = true; }
        }
    }
    return self.find_loops();
}

// Check that every back edge enters a block that dominates its source (the
// graph is reducible), and find the extent of each loop: the last position of
// any block that reaches a back edge without passing through the header.
fn bool OptBuild.find_loops(&self) {
    self.loop_end = mem::new_array(uint, self.nrpo);
    bool* in_loop = mem::new_array(bool, self.nrpo);
    uint* work = mem::new_array(uint, self.nrpo);
    defer { mem::free(in_loop); mem::free(work); }
    for (uint u = 0; u < self.nrpo; u++) {
        uint ub = self.rpo[u];
        for (uint k = 0; k < self.succ_count(ub); k++) {
            uint h = self.pos_of[self.succ_block(ub, k)];
            if (h > u) continue;
            if (!self.dominates(h, u)) return self.refuse(OptRefuse.IRREDUCIBLE);
            // The natural loop: walk predecessors back from u to h.
            for (uint i = 0; i < self.nrpo; i++) in_loop[i] = false;
            in_loop[h] = true;
            uint sp = 0;
            uint extent = u > self.loop_end[h] ? u : self.loop_end[h];
            if (!in_loop[u]) { in_loop[u] = true; work[sp++] = u; }
            while (sp > 0) {
                uint x = work[--sp];
                if (x > extent) extent = x;
                foreach (p : self.preds(x)) {
                    if (in_loop[p]) continue;
                    in_loop[p] = true;
                    work[sp++] = p;
                }
            }
            self.loop_end[h] = extent;
        }
    }
    return true;
}

// --- Registers ---

fn OptRep OptBuild.rep_of(&self, uint node) @inline => self.g.nodes[node].rep;

fn uint OptBuild.add(&self, OptOp op, OptRep rep, uint a = NO_NODE, uint b = NO_NODE, long imm = 0) {
    OptNode n = { .op = op, .rep = rep, .a = a, .b = b, .imm = imm, .pc = self.pc, .reg = -1 };
    self.g.nodes.push(n);
    return (uint)self.g.nodes.len() - 1;
}

// Record the dirty registers live into the current instruction on node `node`.
fn void OptBuild.snapshot(&self, uint node) {
    uint first = (uint)self.g.dirty.len();
    for (uint r = 0; r < self.nregs; r++) {
        OptRegState s = self.cur[r];
        if (s.node != NO_NODE && s.dirty && self.live_in[self.insn].test(r)) {
            self.g.dirty.push({ .reg = r, .node = s.node });
        }
    }
    OptNode* n = &self.g.nodes[node];
    n.dirty_first = first;
    n.dirty_count = (uint)self.g.dirty.len() - first;
}

fn uint OptBuild.guarded(&self, OptOp op, OptRep rep, uint reg) {
    uint n = self.add(op, rep, NO_NODE, NO_NODE, (long)reg);
    self.g.nodes[n].home = reg;
    self.snapshot(n);
    return n;
}

fn void OptBuild.set(&self, uint reg, uint node, bool dirty = true) {
    if (reg >= self.nregs) return;
    if (node != NO_NODE && !self.g.nodes[node].is_const() && self.g.nodes[node].op != OptOp.PHI) self.g.nodes[node].home = reg;
    self.cur[reg] = { .node = node, .dirty = dirty };
    self.load_def[reg] = NO_NODE;
    self.fact_shape[reg] = heap::SHAPE_NONE;
}

// Facts about objects are only held across nodes that neither run code nor allocate: LOAD_FIELD,
// STORE_FIELD (an overwrite, so never a shape change), LOAD_ELEM, STORE_ELEM, numeric ops and
// branches. Nothing then can collect an object, recycle a shape id or rebind a register, so the
// shape cell a node compared is still the receiver's. Every GENERIC, block start and write to the
// register drops its facts.
fn void OptBuild.forget_facts(&self) {
    for (uint r = 0; r <= self.nregs; r++) self.fact_shape[r] = heap::SHAPE_NONE;
}

// The register a field node reads its receiver from: nregs for `this`.
fn uint OptBuild.field_receiver(&self) {
    switch (self.w.op) {
        case GETTHISC: case PUTTHISC: return self.nregs;
        case GETPROPC: case GETPROPC_CACHED: return self.w.b;
        default: return self.w.a;
    }
}

// Whether the receiver of the field node being lowered is already known to be an object of
// `shape` that passes the node's guards.
fn bool OptBuild.guards_known(&self, uint reg, uint shape) {
    if (reg > self.nregs || self.fact_shape[reg] != shape) return false;
    return self.fact_plain[reg] || self.w.op == Opcode.GETTHISC;
}

fn void OptBuild.learn(&self, uint reg, uint shape) {
    if (reg > self.nregs) return;
    self.fact_shape[reg] = shape;
    self.fact_plain[reg] = self.w.op != Opcode.GETTHISC;
}

fn uint OptBuild.const_i32(&self, long v) => self.add(OptOp.CONST_I32, OptRep.INT32, NO_NODE, NO_NODE, v);

fn uint OptBuild.const_f64(&self, double v) {
    long bits;
    if (v != v) {
        bits = 0x7FF8000000000000;
    } else {
        mem::copy(&bits, &v, 8);
    }
    return self.add(OptOp.CONST_F64, OptRep.FLOAT64, NO_NODE, NO_NODE, bits);
}

// The register's value as a node of rep `want`, checking it when it is in the
// window; NO_NODE when the register is out of range.
fn uint OptBuild.operand(&self, uint reg, OptRep want) {
    if (reg >= self.nregs) return NO_NODE;
    OptRegState s = self.cur[reg];
    if (s.node == NO_NODE && self.load_def[reg] != NO_NODE) self.ask_load(self.load_def[reg], reg, want);
    if (s.node == NO_NODE) {
        uint n = self.guarded(want == OptRep.INT32 ? OptOp.CHECK_I32 : OptOp.CHECK_NUM, want, reg);
        self.set(reg, n, false);
        return n;
    }
    return self.convert(s.node, want);
}

// Node `node` as `want`: INT32 widens to FLOAT64; FLOAT64 narrows to INT32 by
// ToInt32 (the caller only asks for that for the bitwise operators).
fn uint OptBuild.convert(&self, uint node, OptRep want) {
    OptRep have = self.rep_of(node);
    if (have == want) return node;
    OptNode* n = &self.g.nodes[node];
    if (have == OptRep.INT32) {
        if (n.op == OptOp.CONST_I32) return self.const_f64((double)n.imm);
        return self.add(OptOp.I32_TO_F64, OptRep.FLOAT64, node);
    }
    if (n.op == OptOp.CONST_F64) {
        double d;
        long bits = n.imm;
        mem::copy(&d, &bits, 8);
        if (d >= -2147483648.0 && d <= 2147483647.0 && d == d) return self.const_i32((long)d);
    }
    uint c = self.add(OptOp.F64_TO_I32, OptRep.INT32, node);
    self.snapshot(c);
    return c;
}

fn bool OptBuild.state_float(&self, uint reg) {
    return reg < self.nregs && self.cur[reg].node != NO_NODE && self.rep_of(self.cur[reg].node) == OptRep.FLOAT64;
}

// The feedback the baseline recorded for the instruction being lowered.
fn char OptBuild.feedback(&self) {
    if (self.f.ic_entries == null) return 0;
    return ((hobject::ICEntry*)self.f.ic_entries)[self.next_pc - 1].feedback;
}

// The rep an arithmetic or comparison instruction runs in: FLOAT64 when an
// operand is one, a double was seen, or the integer result has left the
// integer range; NONE when a non-number was seen.
fn OptRep OptBuild.arith_rep(&self, uint rb, uint rc) {
    char fb = self.feedback();
    if ((fb & (hobject::FB_STR | hobject::FB_OTHER)) != 0) return OptRep.NONE;
    if ((fb & (hobject::FB_DBL | hobject::FB_OVF)) != 0) return OptRep.FLOAT64;
    if (self.state_float(rb) || self.state_float(rc)) return OptRep.FLOAT64;
    return OptRep.INT32;
}

fn uint OptBuild.imm_operand(&self, long v, OptRep rep) {
    return rep == OptRep.FLOAT64 ? self.const_f64((double)v) : self.const_i32(v);
}

// `A = B op C` (or op imm) in the rep the feedback and operands select.
fn bool OptBuild.arith(&self, OptOp int_op, OptOp float_op, uint rb, uint rc, bool imm, long imm_value) {
    OptRep rep = self.arith_rep(rb, imm ? NO_NODE : rc);
    if (rep == OptRep.NONE) return self.generic();
    uint x = self.operand(rb, rep);
    uint y = imm ? self.imm_operand(imm_value, rep) : self.operand(rc, rep);
    if (x == NO_NODE || y == NO_NODE) return self.generic();
    uint n = self.add(rep == OptRep.INT32 ? int_op : float_op, rep, x, y);
    if (rep == OptRep.INT32) self.snapshot(n);
    self.set(self.w.a, n);
    return true;
}

// The bitwise operators: INT32 operands, a double taken through ToInt32 when
// one was seen.
fn bool OptBuild.bitop(&self, OptOp op, uint rb, uint rc, bool imm, long imm_value) {
    char fb = self.feedback();
    if ((fb & (hobject::FB_STR | hobject::FB_OTHER)) != 0) return self.generic();
    bool numbers = (fb & (hobject::FB_DBL | hobject::FB_OVF)) != 0 || self.state_float(rb) || (!imm && self.state_float(rc));
    uint x = self.bit_operand(rb, numbers);
    uint y = imm ? self.const_i32(imm_value) : self.bit_operand(rc, numbers);
    if (x == NO_NODE || y == NO_NODE) return self.generic();
    uint n = self.add(op, OptRep.INT32, x, y);
    if (op == OptOp.SHR_I32) self.snapshot(n);
    self.set(self.w.a, n);
    return true;
}

fn uint OptBuild.bit_operand(&self, uint reg, bool numbers) {
    if (reg >= self.nregs) return NO_NODE;
    if (self.cur[reg].node == NO_NODE && numbers) {
        uint c = self.operand(reg, OptRep.FLOAT64);
        return c == NO_NODE ? c : self.convert(c, OptRep.INT32);
    }
    return self.operand(reg, OptRep.INT32);
}

// A numeric use of `reg` found it still in the window, written by the GETCAP or GETPROP at `pc`:
// have the next round build that as a typed load of `want`.
fn void OptBuild.ask_load(&self, uint pc, uint reg, OptRep want) {
    foreach (&c : self.load_reps) {
        if (c.block != pc) continue;
        if (c.rep != want) {
            c.rep = want;
            self.load_changed = true;
        }
        return;
    }
    self.load_reps.push({ .block = pc, .reg = reg, .rep = want });
    self.load_changed = true;
}

// The typed load a numeric use asked of the instruction at this pc, or NO_NODE.
fn uint OptBuild.typed_load(&self, OptOp op, uint a) {
    foreach (c : self.load_reps) {
        if (c.block != self.pc) continue;
        uint n = self.add(op, c.rep, a, NO_NODE, (long)self.pc);
        self.snapshot(n);
        self.set(self.w.a, n);
        return n;
    }
    return NO_NODE;
}

// GETCAP: a typed load when a numeric use asked for one, else GENERIC.
fn bool OptBuild.get_cap(&self) {
    if (self.typed_load(OptOp.LOAD_CAP, NO_NODE) != NO_NODE) return true;
    if (!self.generic()) return false;
    if (self.w.a < self.nregs) self.load_def[self.w.a] = self.pc;
    return true;
}

// Whether the instruction being lowered has been cached for a string key.
fn bool OptBuild.string_keyed(&self) {
    if (self.f.ic_entries == null) return true;
    return ((hobject::ICEntry*)self.f.ic_entries)[self.next_pc - 1].key.borrow() != null;
}

// Whether register `r` can be an element index: an INT32 node, or the window while the
// instruction has seen no string key.
fn bool OptBuild.index_ok(&self, uint r) {
    if (r >= self.nregs) return false;
    if (self.cur[r].node == NO_NODE) return !self.string_keyed();
    return self.rep_of(self.cur[r].node) == OptRep.INT32;
}

// Whether register `r` holds an object (or other value) in the window.
fn bool OptBuild.in_window(&self, uint r) => r < self.nregs && self.cur[r].node == NO_NODE;

// The cache entry of the instruction being lowered when it names an own data property of a
// plain object that the optimized code can read by slot, else null.
fn hobject::ICEntry* OptBuild.own_field(&self) {
    if (self.f.ic_entries == null) return null;
    hobject::ICEntry* ic = &((hobject::ICEntry*)self.f.ic_entries)[self.next_pc - 1];
    void* key = (void*)ic.key.borrow();
    if (key == null || ic.shape_id == heap::SHAPE_NONE || ic.has_proto || ic.chain_len != 0) return null;
    if (ic.prop_idx == hobject::IC_PROP_ABSENT || ic.prop_flags.is_accessor) return null;
    if (key == (void*)self.h.strs[heap::BuiltinStr.LENGTH]) return null;
    if (self.w.op != Opcode.GETTHISC) {
        if (self.w.c >= self.f.const_count || !self.f.constants[self.w.c].is_string()) return null;
        if (self.f.constants[self.w.c].get_heapptr() != key) return null;
    }
    return ic;
}

// GETPROPC, GETPROPC_CACHED and GETTHISC of an own property by the shape its cache holds: a
// typed load when a numeric use asked for one, else a read into the window.
fn bool OptBuild.get_field(&self) {
    hobject::ICEntry* ic = self.own_field();
    if (ic == null || (self.w.op != Opcode.GETTHISC && !self.in_window(self.w.b))) return self.generic();
    uint recv = self.field_receiver();
    bool known = self.guards_known(recv, ic.shape_id);
    uint shape = ic.shape_id;
    uint n = self.typed_load(OptOp.LOAD_FIELD, NO_NODE);
    if (n == NO_NODE) {
        n = self.add(OptOp.LOAD_FIELD, OptRep.NONE, NO_NODE, NO_NODE, (long)self.pc);
        self.snapshot(n);
        uint ra = self.w.a;
        self.kill(ra);
        if (ra < self.nregs) self.load_def[ra] = self.pc;
    }
    self.g.nodes[n].cc = known ? 1 : 0;
    self.learn(recv, shape);
    // The load may have overwritten its own receiver register.
    if (recv < self.nregs && recv == self.w.a) self.fact_shape[recv] = heap::SHAPE_NONE;
    return true;
}

// PUTPROPC and PUTTHISC of an own writable data property by the shape its cache holds, from an
// object in the window; a numeric value is stored without being published first.
fn bool OptBuild.put_field(&self) {
    hobject::ICEntry* ic = self.own_field();
    bool this_op = self.w.op == Opcode.PUTTHISC;
    if (ic == null || !ic.prop_flags.writable || (!this_op && !self.in_window(self.w.a))) return self.generic();
    uint rv = this_op ? self.w.a : self.w.b;
    if (rv >= self.nregs) return self.generic();
    uint recv = self.field_receiver();
    uint n = self.add(OptOp.STORE_FIELD, OptRep.NONE, self.cur[rv].node, NO_NODE, (long)self.pc);
    self.snapshot(n);
    self.g.nodes[n].cc = self.guards_known(recv, ic.shape_id) ? 1 : 0;
    self.learn(recv, ic.shape_id);
    return true;
}

// GETPROP of an element at an integer index, from an object in the window.
fn bool OptBuild.get_elem(&self) {
    if (!self.in_window(self.w.b) || !self.index_ok(self.w.c)) return self.generic();
    bool asked = false;
    foreach (c : self.load_reps) asked |= c.block == self.pc;
    if (asked) {
        uint idx = self.operand(self.w.c, OptRep.INT32);
        if (idx == NO_NODE) return self.generic();
        self.typed_load(OptOp.LOAD_ELEM, idx);
        return true;
    }
    if (!self.generic()) return false;
    if (self.w.a < self.nregs) self.load_def[self.w.a] = self.pc;
    return true;
}

// PUTPROP of a numeric node to an element at an integer index, into an object in the window.
fn bool OptBuild.put_elem(&self) {
    uint rv = self.w.c;
    if (!self.in_window(self.w.a) || !self.index_ok(self.w.b) || rv >= self.nregs || self.cur[rv].node == NO_NODE) return self.generic();
    uint idx = self.operand(self.w.b, OptRep.INT32);
    uint n = self.add(OptOp.STORE_ELEM, OptRep.NONE, idx, self.cur[rv].node, (long)self.pc);
    self.snapshot(n);
    return true;
}

// UNM of a number, as a double.
fn bool OptBuild.negate(&self) {
    char fb = self.feedback();
    if ((fb & (hobject::FB_STR | hobject::FB_OTHER)) != 0) return self.generic();
    uint x = self.operand(self.w.b, OptRep.FLOAT64);
    if (x == NO_NODE) return self.generic();
    self.set(self.w.a, self.add(OptOp.NEG_F64, OptRep.FLOAT64, x));
    return true;
}

// Register `r` no longer holds a numeric node.
fn void OptBuild.kill(&self, uint r) {
    if (r >= self.nregs) return;
    self.cur[r] = { .node = NO_NODE, .dirty = false };
    self.load_def[r] = NO_NODE;
    self.fact_shape[r] = heap::SHAPE_NONE;
}

// The instruction as the baseline emitter runs it: the registers it can read
// stored first, the registers it can write no longer numeric nodes, and the
// numeric registers live after it reloaded from the window.
fn bool OptBuild.generic(&self) {
    // Which registers the instruction writes: only the opcodes whose effect on
    // the register file is known run as GENERIC.
    uint first_kill = NO_NODE;   // calls: this register and every one above it
    uint extra_kill = NO_NODE;
    uint key_kill = NO_NODE;     // GETPROP_CACHE writes the coerced key back to C
    uint def = NO_NODE;
    Opcode op = self.w.op;
    if (!self.cfg.nodes[self.insn].must_def(&def)) {
        def = NO_NODE;
        switch (op) {
            case NEWOBJ: case NEWARR: case NEWARR_CONST: case CLOSURE: case NEWREGEXP:
            case NEWOBJ_SHAPE: case NEWTARGET: case DELPROP: case GETPROP_SUPER: case TOPROPKEY:
                extra_kill = self.w.a;
            case GETPROP_CACHE:
                extra_kill = self.w.a;
                key_kill = self.w.c;
            case CALL: case CALL_PROP: case CALL_UNDEF_THIS: case NEW_OBJ: case CALL_S: case NEW_OBJ_S:
                extra_kill = self.w.a;
                first_kill = self.w.b;
            case CALL_VAR: case CALL_GLOBAL:
                first_kill = self.w.a;
            case PUTPROP: case PUTPROP_NE: case PUTPROPC: case PUTTHISC: case PUTVAR: case PUTVAR_ASSIGN:
            case PUTVAR_SNAP: case PUTGLOBAL: case PUTCAP: case PUTCAP_SNAP: case PUTLEX: case PUTLEX_C:
            case RET: case RETUNDEF: case SETALEN: case INITPROP: case INITELEM: case CHKOBJ: case REQUIRE_OBJ:
            case NOP: case INC_VAR: case DEC_VAR: case INC_GLOBAL: case DEC_GLOBAL: case CHKGLOBALVAR:
            case CHKGLOBALFUNC: case CHKGLOBALLEX: case THROW:
                break;
            default:
                return self.refuse_op(op);
        }
    }
    uint n = self.add(OptOp.GENERIC, OptRep.NONE, NO_NODE, NO_NODE, (long)self.pc);
    self.forget_facts();
    self.snapshot(n);
    OptNode* node = &self.g.nodes[n];
    for (uint i = 0; i < node.dirty_count; i++) {
        self.cur[self.g.dirty[(sz)(node.dirty_first + i)].reg].dirty = false;
    }
    self.kill(extra_kill);
    self.kill(key_kill);
    if (first_kill < self.nregs) for (uint r = first_kill; r < self.nregs; r++) self.kill(r);
    self.kill(def);
    uint first = (uint)self.g.dirty.len();
    for (uint r = 0; r < self.nregs; r++) {
        if (self.cur[r].node != NO_NODE && self.live_out[self.insn].test(r)) {
            self.g.dirty.push({ .reg = r, .node = self.cur[r].node });
        }
    }
    node = &self.g.nodes[n];
    node.reload_first = first;
    node.reload_count = (uint)self.g.dirty.len() - first;
    return true;
}

fn bool OptBuild.terminator(&self, OptOp op, uint a = NO_NODE, uint b = NO_NODE, long imm = 0, char cc = 0) {
    uint n = self.add(op, OptRep.NONE, a, b, imm);
    self.g.nodes[n].cc = cc;
    return true;
}

// A compare-and-branch.
fn bool OptBuild.cmp_branch(&self) {
    Opcode op = self.w.op;
    bool imm = is_jmp_imm(op);
    if (imm && self.wide) return self.refuse(OptRefuse.BRANCH_OPERANDS);
    uint row = imm ? op.ordinal - Opcode.JMP_NLTI.ordinal : op.ordinal - Opcode.JMP_NLT.ordinal;
    OptRep rep = self.arith_rep(self.w.b, imm ? NO_NODE : self.w.c);
    if (rep == OptRep.NONE) return self.refuse(OptRefuse.BRANCH_OPERANDS);
    uint x = self.operand(self.w.b, rep);
    uint y = imm ? self.imm_operand((long)(ichar)self.w.c, rep) : self.operand(self.w.c, rep);
    if (x == NO_NODE || y == NO_NODE) return self.refuse(OptRefuse.BRANCH_OPERANDS);
    return self.terminator(OptOp.BRANCH, x, y, (long)rep.ordinal, (char)row);
}

// IF_TRUE / IF_FALSE over a numeric node or the window slot.
fn bool OptBuild.truth_branch(&self) {
    uint r = self.w.a;
    if (r >= self.nregs) return self.refuse(OptRefuse.BRANCH_OPERANDS);
    uint node = self.cur[r].node;
    bool negate = self.w.op == Opcode.IF_FALSE;
    if (!self.terminator(OptOp.BRANCH_TRUTH, node, NO_NODE, (long)r, negate ? 1 : 0)) return false;
    // A window value can leave through the slow path.
    if (node == NO_NODE) self.snapshot((uint)self.g.nodes.len() - 1);
    return true;
}

// JMP_SEQ/SNEQ/EQ/NEQ/NULL/NNULL: values in the window go through the baseline's tests; once
// either operand is a numeric node the operands compare as numbers.
fn bool OptBuild.equality_branch(&self) {
    Opcode op = self.w.op;
    bool unary = op == Opcode.JMP_NULL || op == Opcode.JMP_NNULL;
    uint rb = self.w.b;
    uint rc = unary ? rb : self.w.c;
    if (rb >= self.nregs || rc >= self.nregs) return self.refuse(OptRefuse.BRANCH_OPERANDS);
    if (self.cur[rb].node != NO_NODE || self.cur[rc].node != NO_NODE) {
        return unary ? self.refuse_op(op) : self.numeric_equality();
    }
    uint kind = op.ordinal - Opcode.JMP_SEQ.ordinal;
    if (!self.terminator(OptOp.BRANCH_WINDOW, NO_NODE, NO_NODE, (long)rb | ((long)rc << 20), (char)kind)) return false;
    self.snapshot((uint)self.g.nodes.len() - 1);
    return true;
}

// Loose or strict equality of two numeric nodes: the same compare as the strict branch.
fn bool OptBuild.numeric_equality(&self) {
    Opcode op = self.w.op;
    uint row = (op == Opcode.JMP_SEQ || op == Opcode.JMP_EQ) ? 8 : 9;
    OptRep rep = self.arith_rep(self.w.b, self.w.c);
    if (rep == OptRep.NONE) return self.refuse(OptRefuse.BRANCH_OPERANDS);
    uint x = self.operand(self.w.b, rep);
    uint y = self.operand(self.w.c, rep);
    if (x == NO_NODE || y == NO_NODE) return self.refuse(OptRefuse.BRANCH_OPERANDS);
    return self.terminator(OptOp.BRANCH, x, y, (long)rep.ordinal, (char)row);
}

// Lower instruction `self.insn`.
fn bool OptBuild.lower(&self) {
    DecodedInsn w = self.w;
    Opcode op = w.op;
    uint ra = w.a;
    uint rb = w.b;
    uint rc = w.c;
    switch (op) {
        case LDINT:
            self.set(ra, self.const_i32((long)w.get_sbc()));
        case LDCONST:
            uint index = w.get_bc();
            if (!self.consts_ok || index >= self.f.const_count) return self.generic();
            TVal v = self.f.constants[index];
            if (v.is_fastint()) {
                long x = v.get_fastint();
                if (x >= -2147483648 && x <= 2147483647) {
                    self.set(ra, self.const_i32(x));
                } else {
                    self.set(ra, self.const_f64((double)x));
                }
            } else if (v.is_number()) {
                self.set(ra, self.const_f64(v.get_number()));
            } else {
                return self.generic();
            }
        case LDREG:
        case TONUMERIC:
            if (rb >= self.nregs || self.cur[rb].node == NO_NODE) return self.generic();
            uint src = self.cur[rb].node;
            if (!self.g.nodes[src].is_const()) src = self.add(OptOp.COPY, self.rep_of(src), src);
            self.set(ra, src);
        case ADD:
            return self.arith(OptOp.ADD_I32, OptOp.ADD_F64, rb, rc, false, 0);
        case SUB:
            return self.arith(OptOp.SUB_I32, OptOp.SUB_F64, rb, rc, false, 0);
        case MUL:
            return self.arith(OptOp.MUL_I32, OptOp.MUL_F64, rb, rc, false, 0);
        case ADDI:
            if (self.wide) return self.generic();
            return self.arith(OptOp.ADD_I32, OptOp.ADD_F64, rb, NO_NODE, true, (long)(ichar)rc);
        case SUBI:
            if (self.wide) return self.generic();
            return self.arith(OptOp.SUB_I32, OptOp.SUB_F64, rb, NO_NODE, true, (long)(ichar)rc);
        case MULI:
            if (self.wide) return self.generic();
            return self.arith(OptOp.MUL_I32, OptOp.MUL_F64, rb, NO_NODE, true, (long)(ichar)rc);
        case INC:
        case INC_LT:
            return self.arith(OptOp.ADD_I32, OptOp.ADD_F64, ra, NO_NODE, true, 1);
        case DEC:
            return self.arith(OptOp.SUB_I32, OptOp.SUB_F64, ra, NO_NODE, true, 1);
        case DIV:
            char fb = self.feedback();
            if ((fb & (hobject::FB_STR | hobject::FB_OTHER)) != 0) return self.generic();
            uint x = self.operand(rb, OptRep.FLOAT64);
            uint y = self.operand(rc, OptRep.FLOAT64);
            if (x == NO_NODE || y == NO_NODE) return self.generic();
            self.set(ra, self.add(OptOp.DIV_F64, OptRep.FLOAT64, x, y));
        case BAND:
            return self.bitop(OptOp.AND_I32, rb, rc, false, 0);
        case BOR:
            return self.bitop(OptOp.OR_I32, rb, rc, false, 0);
        case BXOR:
            return self.bitop(OptOp.XOR_I32, rb, rc, false, 0);
        case SHL:
            return self.bitop(OptOp.SHL_I32, rb, rc, false, 0);
        case SHR:
            return self.bitop(OptOp.SAR_I32, rb, rc, false, 0);
        case USHR:
            return self.bitop(OptOp.SHR_I32, rb, rc, false, 0);
        case BANDI:
            if (self.wide) return self.generic();
            return self.bitop(OptOp.AND_I32, rb, NO_NODE, true, bytecode::imm_value(op, rc));
        case BORI:
            if (self.wide) return self.generic();
            return self.bitop(OptOp.OR_I32, rb, NO_NODE, true, bytecode::imm_value(op, rc));
        case BXORI:
            if (self.wide) return self.generic();
            return self.bitop(OptOp.XOR_I32, rb, NO_NODE, true, bytecode::imm_value(op, rc));
        case SHLI:
            if (self.wide) return self.generic();
            return self.bitop(OptOp.SHL_I32, rb, NO_NODE, true, bytecode::imm_value(op, rc));
        case SHRI:
            if (self.wide) return self.generic();
            return self.bitop(OptOp.SAR_I32, rb, NO_NODE, true, bytecode::imm_value(op, rc));
        case USHRI:
            if (self.wide) return self.generic();
            return self.bitop(OptOp.SHR_I32, rb, NO_NODE, true, bytecode::imm_value(op, rc));
        case JUMP:
            return self.terminator(OptOp.JUMP);
        case IF_TRUE:
        case IF_FALSE:
            return self.truth_branch();
        case BREAK:
        case CONTINUE:
            return self.refuse_op(op);
        case GETCAP:
            return self.get_cap();
        case GETPROP:
            return self.get_elem();
        case GETPROPC:
        case GETPROPC_CACHED:
        case GETTHISC:
            return self.get_field();
        case PUTPROP:
            return self.put_elem();
        case PUTPROPC:
        case PUTTHISC:
            return self.put_field();
        case UNM:
            return self.negate();
        default:
            if (op == Opcode.JMP_SEQ || op == Opcode.JMP_SNEQ || (op.ordinal >= Opcode.JMP_EQ.ordinal && op.ordinal <= Opcode.JMP_NNULL.ordinal)) return self.equality_branch();
            if (is_jmp_reg(op) || is_jmp_imm(op)) return self.cmp_branch();
            if (bytecode::is_cmp_branch(op)) return self.refuse_op(op);
            return self.generic();
    }
    return true;
}


// --- Building ---

// The override recorded for register `reg` of the block at `pos`: 0 for none,
// else the rep's ordinal (NONE meaning the register is Window).
fn int OptBuild.override_of(&self, uint pos, uint reg) {
    foreach (o : self.overrides) if (o.block == pos && o.reg == reg) return (int)o.rep.ordinal + 1;
    return 0;
}

// Record that the phi for `reg` at `pos` is `rep`; whether that changed anything.
fn bool OptBuild.set_override(&self, uint pos, uint reg, OptRep rep) {
    foreach (&o : self.overrides) {
        if (o.block != pos || o.reg != reg) continue;
        if (o.rep == rep) return false;
        o.rep = rep;
        return true;
    }
    self.overrides.push({ .block = pos, .reg = reg, .rep = rep });
    return true;
}

fn void OptBuild.context(&self, uint i) {
    DecodedCfgNode* node = &self.cfg.nodes[i];
    self.insn = i;
    self.pc = node.view.pc;
    self.next_pc = node.view.next_pc;
    self.w = node.view.insn;
    self.wide = node.view.wide;
}

// The state a block starts in: inherited from its single predecessor, or merged
// from its predecessors with phis where all of them hold a numeric node.
fn void OptBuild.begin_block(&self, uint pos) {
    uint b = self.rpo[pos];
    uint first_insn = self.b_first[b];
    self.context(first_insn);
    OptBlock blk = { .first = (uint)self.g.nodes.len(), .pc = self.pc };
    for (uint r = 0; r < self.nregs; r++) {
        self.cur[r] = { .node = NO_NODE, .dirty = false };
        self.load_def[r] = NO_NODE;
    }
    // Facts do not cross a block start: a back edge or a join may come from any generic.
    self.forget_facts();
    uint fwd = 0;
    uint back = 0;
    uint single = 0;
    foreach (p : self.preds(pos)) {
        if (p < pos) { fwd++; single = p; } else { back++; }
    }
    blk.header = back > 0;
    blk.loop_end = self.loop_end[pos];
    if (pos != 0) {
        bool merge = fwd + back >= 2;
        for (uint r = 0; r < self.nregs; r++) {
            if (!self.live_in[first_insn].test(r)) continue;
            if (!merge) {
                self.cur[r] = self.ends[(usz)single * self.nregs + r];
                continue;
            }
            bool numeric = true;
            OptRep rep = OptRep.INT32;
            foreach (p : self.preds(pos)) {
                if (p >= pos) continue;
                OptRegState s = self.ends[(usz)p * self.nregs + r];
                if (s.node == NO_NODE) { numeric = false; break; }
                if (self.rep_of(s.node) == OptRep.FLOAT64) rep = OptRep.FLOAT64;
            }
            if (!numeric) continue;
            int ov = self.override_of(pos, r);
            if (ov == (int)OptRep.NONE.ordinal + 1) continue;
            if (ov == (int)OptRep.FLOAT64.ordinal + 1) rep = OptRep.FLOAT64;
            uint phi = self.add(OptOp.PHI, rep, NO_NODE, NO_NODE, (long)r);
            self.g.nodes[phi].home = r;
            self.cur[r] = { .node = phi, .dirty = true };
        }
    }
    if (blk.header) {
        blk.entry_first = (uint)self.g.dirty.len();
        for (uint r = 0; r < self.nregs; r++) {
            if (self.cur[r].node != NO_NODE && self.cur[r].dirty) self.g.dirty.push({ .reg = r, .node = self.cur[r].node });
        }
        blk.entry_count = (uint)self.g.dirty.len() - blk.entry_first;
    }
    if (self.osr_target[first_insn]) {
        blk.osr = true;
        blk.osr_first = (uint)self.g.dirty.len();
        for (uint r = 0; r < self.nregs; r++) {
            uint node = self.cur[r].node;
            if (node != NO_NODE && !self.g.nodes[node].is_const()) self.g.dirty.push({ .reg = r, .node = node });
        }
        blk.osr_count = (uint)self.g.dirty.len() - blk.osr_first;
    }
    mem::copy(&self.entries[(usz)pos * self.nregs], self.cur, (usz)self.nregs * OptRegState::size);
    self.g.blocks.push(blk);
}

fn bool is_terminator_op(Opcode op) {
    return op == Opcode.JUMP || op == Opcode.IF_TRUE || op == Opcode.IF_FALSE || bytecode::is_cmp_branch(op);
}

fn void OptBuild.end_block(&self, uint pos) {
    uint b = self.rpo[pos];
    uint last = self.b_last[b];
    self.context(last);
    DecodedCfgNode* node = &self.cfg.nodes[last];
    OptBlock* blk = &self.g.blocks[pos];
    blk.succ_count = node.successor_count;
    for (uint k = 0; k < blk.succ_count; k++) blk.succ[k] = self.pos_of[self.succ_block(b, k)];
    if (blk.succ_count == 1 && is_terminator_op(node.view.insn.op) && node.view.insn.op != Opcode.JUMP) {
        blk.succ[1] = blk.succ[0];
        blk.succ_count = 2;
    }
    if (blk.succ_count != 0 && !is_terminator_op(node.view.insn.op)) self.terminator(OptOp.JUMP);
    blk.end = (uint)self.g.nodes.len();
    mem::copy(&self.ends[(usz)pos * self.nregs], self.cur, (usz)self.nregs * OptRegState::size);
}

fn bool OptBuild.build_round(&self) {
    self.g.clear();
    for (uint pos = 0; pos < self.nrpo; pos++) {
        self.pos = pos;
        self.begin_block(pos);
        uint b = self.rpo[pos];
        for (uint i = self.b_first[b]; i <= self.b_last[b]; i++) {
            self.context(i);
            if (!self.lower()) {
                if (self.refused == OptRefuse.NONE) self.refuse(OptRefuse.FUNCTION);
                return false;
            }
        }
        self.end_block(pos);
    }
    return true;
}

// Check each back edge against the phis its header speculated; record an
// override for each that disagrees. Returns whether any was recorded.
fn bool OptBuild.repair(&self) {
    bool changed = false;
    for (uint pos = 0; pos < self.nrpo; pos++) {
        if (!self.g.blocks[pos].header) continue;
        uint first_node = self.g.blocks[pos].first;
        uint end_node = self.g.blocks[pos].end;
        foreach (p : self.preds(pos)) {
            if (p < pos) continue;
            for (uint r = 0; r < self.nregs; r++) {
                uint phi = self.entries[(usz)pos * self.nregs + r].node;
                if (phi == NO_NODE || phi < first_node || phi >= end_node || self.g.nodes[phi].op != OptOp.PHI) continue;
                uint src = self.ends[(usz)p * self.nregs + r].node;
                if (src == NO_NODE) {
                    changed |= self.set_override(pos, r, OptRep.NONE);
                } else if (self.rep_of(src) == OptRep.FLOAT64 && self.g.nodes[phi].rep == OptRep.INT32) {
                    changed |= self.set_override(pos, r, OptRep.FLOAT64);
                }
            }
        }
    }
    return changed;
}

// The moves along each edge: the phi inputs, and the dirty registers that are
// Window in the successor.
fn void OptBuild.compute_edges(&self) {
    for (uint pos = 0; pos < self.nrpo; pos++) {
        OptBlock* blk = &self.g.blocks[pos];
        for (uint e = 0; e < blk.succ_count; e++) {
            uint s = blk.succ[e];
            uint first_insn = self.b_first[self.rpo[s]];
            uint s_first = self.g.blocks[s].first;
            uint s_end = self.g.blocks[s].end;
            blk.move_first[e] = (uint)self.g.moves.len();
            for (uint r = 0; r < self.nregs; r++) {
                if (!self.live_in[first_insn].test(r)) continue;
                OptRegState sn = self.entries[(usz)s * self.nregs + r];
                OptRegState pn = self.ends[(usz)pos * self.nregs + r];
                if (sn.node != NO_NODE) {
                    if (sn.node >= s_first && sn.node < s_end && self.g.nodes[sn.node].op == OptOp.PHI) {
                        self.g.moves.push({ .dst = sn.node, .src = pn.node, .slot = r });
                    }
                } else if (pn.node != NO_NODE && pn.dirty) {
                    self.g.moves.push({ .dst = NO_NODE, .src = pn.node, .slot = r });
                }
            }
            blk.move_count[e] = (uint)self.g.moves.len() - blk.move_first[e];
        }
    }
}

// Build the graph of `f` into `g`. Returns NONE on success, else why not.
fn OptRefuse opt_build_graph(Heap* h, CompiledFunction* f, OptGraph* g, OptBuild* b, Opcode* refused_op) {
    *b = {};
    b.h = h;
    b.f = f;
    b.g = g;
    b.overrides.init(mem);
    b.load_reps.init(mem);
    if (!b.analyze()) return b.refused;
    uint n = b.nregs;
    b.cur = mem::new_array(OptRegState, n);
    b.load_def = mem::new_array(uint, n);
    b.fact_shape = mem::new_array(uint, (usz)n + 1);
    b.fact_plain = mem::new_array(bool, (usz)n + 1);
    b.ends = mem::new_array(OptRegState, (usz)b.nrpo * n);
    b.entries = mem::new_array(OptRegState, (usz)b.nrpo * n);
    for (uint round = 0; round < OPT_BUILD_ROUNDS; round++) {
        if (!b.build_round()) { *refused_op = b.refused_op; return b.refused; }
        bool again = b.repair();
        again |= b.load_changed;
        b.load_changed = false;
        if (!again) {
            b.compute_edges();
            return OptRefuse.NONE;
        }
    }
    return OptRefuse.REPAIR;
}
