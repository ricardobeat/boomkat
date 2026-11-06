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
import std::io;

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

// Why a call site with a known callee is not inlined (--jit-stats counts them).
enum OptInlineReject : char (String label) {
    POLY {"polymorphic call"},
    WINDOW {"window beyond the caller's registers"},
    SELF {"recursive"},
    NO_JIT {"callee has no baseline code"},
    NO_JIT_TRIVIAL {"trivial callee has no baseline code"},
    INELIGIBLE {"callee not eligible"},
    NOT_LEAN {"callee not a lean call"},
    ARGS {"arguments or rest object"},
    SIZE {"callee too big"},
    FORMALS {"argument count differs"},
    TOP_LEVEL {"top level code"},
    WINDOW_LIVE {"call window live after the call"},
    BLOCKS {"branches in the callee"},
    WIDE {"wide instruction"},
    NO_RET {"no final return"},
    READ_UNDEF {"reads an unwritten register"},
    OPCODE {"opcode (see below)"},
    FEEDBACK {"arithmetic feedback not numeric"},
    FIELD {"field is not an own data field"},
    CONSTANT {"constant is not a number"},
    BUILD {"body not lowerable at build"},
    UNSAFE {"heap value in the callee window"},
    STATE {"call state not usable"},
}

// The words of bytecode an inlined callee may have.
const uint INLINE_WORDS_MAX = 40;

// A call site whose callee the graph may inline (OptBuild.find_sites): a straight-line body, found
// by the call's feedback, with its own control flow graph and liveness.
struct OptInlineSite {
    // The call's instruction in the caller's control flow graph.
    uint insn;
    CompiledFunction* cf;
    // Callee register r is graph register base + r: the window the call publishes.
    uint base;
    // A method call (CALL), whose receiver is the callee's `this`.
    bool method;
    // CALL_VAR or CALL_GLOBAL, which load the callee from a variable.
    bool var_call;
    DecodedCfg cfg;
    RegSet* live_in;
    RegSet* live_out;
    RegSet* live_sets;
    uint* live_words;
    // Per instruction: the callee registers written before it or arriving as arguments.
    uint* defined;
    // The instruction that writes the register the body returns, when it is the last before the
    // return and nothing else touches that register: it writes the call's result register
    // directly. uint::max when there is none.
    uint remap;
    // A build failure of this site is already counted in --jit-stats.
    bool counted;
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
    // The caller's register count; nregs also covers the callee windows of the inline sites.
    uint caller_regs;
    List{OptInlineSite} sites;
    // By caller instruction: its inline site plus one, or zero.
    uint* site_of;
    // While an inlined body is lowered: its site.
    uint cur_site;
    // Set by an inlined body that cannot be built as straight-line numeric nodes, and by one that
    // would leave a heap value in a window slot outside the caller's frame; the call then stays a call.
    bool inline_failed;
    bool inline_unsafe;
    bool no_inline;
    // Why the last inline_candidate refused (set with the opcode in rej_op for OPCODE).
    OptInlineReject rej;
    Opcode rej_op;
    uint inlined;
    OptRegState* cur;
    // Per JS register, and at index nregs for `this`: the shape id of the object it holds when the
    // last LOAD_FIELD or STORE_FIELD on it passed its guards and nothing since can have changed
    // that, else SHAPE_NONE; and whether that node also proved the object plain (a load only proves
    // it is not a proxy, which is all a load needs).
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
    // The OptGraph.fns entry of the instruction being lowered, which insn, pc and next_pc index.
    uint cur_fn;
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

// The function, control flow graph and liveness of the instruction being lowered. Until an inlined
// body is lowered these are the primary function's.
fn CompiledFunction* OptBuild.cur_f(&self) @inline => self.g.fns[self.cur_fn].f;
fn DecodedCfg* OptBuild.cur_cfg(&self) @inline => self.cur_fn == 0 ? &self.cfg : &self.sites[self.cur_site].cfg;

// Whether graph register `r` is live into the instruction being lowered. In an inlined body that is
// the callee's registers by the callee's liveness, and the caller's by what is live after the call.
fn bool OptBuild.live_in_at(&self, uint r) {
    if (self.cur_fn == 0) return self.live_in[self.insn].test(r);
    OptInlineSite* s = &self.sites[self.cur_site];
    if (r >= s.base) {
        uint k = r - s.base;
        return k < s.cf.num_regs && s.live_in[self.insn].test(k);
    }
    return self.live_out[s.insn].test(r);
}

// Whether graph register `r` is live after the instruction being lowered (not inside an inlined body).
fn bool OptBuild.live_out_at(&self, uint r) @inline => self.live_out[self.insn].test(r);

// The key a typed-load request (OptOverride.block) and a load_def entry give the instruction being
// lowered: its pc, and the function it belongs to.
fn uint OptBuild.pckey(&self) @inline => self.pc | (self.cur_fn << 24);

// The operands of `op` that are registers (bit 0 A, bit 1 B, bit 2 C), for the opcodes an inlined
// body may hold; zero for any other. The rest of the operands are not registers.
fn uint inline_reg_mask(Opcode op) {
    switch (op) {
        case LDINT: case LDCONST: case INC: case DEC: case GETTHISC: case PUTTHISC: case RET:
        case LDUNDEF: case LDNULL: case LDTRUE: case LDFALSE:
            return 1;
        case LDREG: case TONUMERIC: case UNM: case GETPROPC: case GETPROPC_CACHED: case PUTPROPC:
        case ADDI: case SUBI: case MULI: case BANDI: case BORI: case BXORI: case SHLI: case SHRI: case USHRI:
            return 3;
        case ADD: case SUB: case MUL: case DIV: case BAND: case BOR: case BXOR: case SHL: case SHR: case USHR:
            return 7;
        default:
            return 0;
    }
}

// Whether an inlined body may hold `op`: the opcodes with registers above, and RETUNDEF.
fn bool inline_op_ok(Opcode op) @inline => inline_reg_mask(op) != 0 || op == Opcode.RETUNDEF;

// The callee registers `w` (an instruction of an inlined body) reads and writes, as bit sets.
fn void inline_rw(DecodedInsn* w, uint* reads, uint* writes) {
    *reads = 0;
    *writes = 0;
    switch (w.op) {
        case LDINT: case LDCONST: case GETTHISC: case LDUNDEF: case LDNULL: case LDTRUE: case LDFALSE:
            *writes = 1u << w.a;
        case LDREG: case TONUMERIC: case UNM: case GETPROPC: case GETPROPC_CACHED:
        case ADDI: case SUBI: case MULI: case BANDI: case BORI: case BXORI: case SHLI: case SHRI: case USHRI:
            *reads = 1u << w.b;
            *writes = 1u << w.a;
        case ADD: case SUB: case MUL: case DIV: case BAND: case BOR: case BXOR: case SHL: case SHR: case USHR:
            *reads = (1u << w.b) | (1u << w.c);
            *writes = 1u << w.a;
        case INC: case DEC:
            *reads = 1u << w.a;
            *writes = 1u << w.a;
        case PUTPROPC:
            *reads = (1u << w.a) | (1u << w.b);
        case PUTTHISC: case RET:
            *reads = 1u << w.a;
        default:
            break;
    }
}

// The instruction of an inlined callee as the graph sees it: its registers shifted by `base`.
fn void inline_rebase(DecodedInsn* w, uint base) {
    uint mask = inline_reg_mask(w.op);
    if ((mask & 1) != 0) w.a += base;
    if ((mask & 2) != 0) w.b += base;
    if ((mask & 4) != 0) w.c += base;
}

fn bool OptBuild.reject(&self, OptInlineReject why) {
    self.rej = why;
    return false;
}

fn void OptBuild.count_reject(&self, OptInlineReject why, Opcode op) {
    self.h.opt.inline_rejected[why.ordinal]++;
    if (why == OptInlineReject.OPCODE) self.h.opt.inline_rejected_ops[op.ordinal]++;
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
    foreach (&s : self.sites) s.free_site();
    self.sites.free();
    mem::free(self.site_of);
}

fn void OptInlineSite.free_site(&self) {
    compiler::bytecode_cfg_free(&self.cfg);
    mem::free(self.live_sets);
    mem::free(self.live_words);
    mem::free(self.defined);
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
    self.caller_regs = f.num_regs;
    self.nregs = f.num_regs;
    self.consts_ok = true;
    for (uint i = 0; i < f.code_count; i++) if (f.code[i].op == Opcode.SETCONST) self.consts_ok = false;
    self.nb = cfg.block_count;
    if (self.nb > OPT_BLOCK_MAX || (usz)self.nb * self.nregs > OPT_STATE_MAX) return self.refuse(OptRefuse.BUDGET);
    uint words = (self.caller_regs + 32) / 32;
    self.live_sets = mem::new_array(RegSet, (usz)count * 2);
    self.live_words = mem::new_array(uint, ((usz)count * 2 + 1) * words);
    for (uint i = 0; i < count * 2; i++) self.live_sets[i] = { .words = self.live_words + (usz)i * words, .word_count = words };
    RegSet scratch = { .words = self.live_words + (usz)count * 2 * words, .word_count = words };
    compiler::bytecode_cfg_liveness(cfg, self.live_sets, self.live_sets + count, &scratch, true, false, true);
    self.live_out = self.live_sets;
    self.live_in = self.live_sets + count;
    self.find_sites();
    if ((usz)self.nb * self.nregs > OPT_STATE_MAX) return self.refuse(OptRefuse.BUDGET);

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
    OptNode n = { .op = op, .rep = rep, .a = a, .b = b, .imm = imm, .pc = self.pc, .fidx = self.cur_fn, .reg = -1 };
    self.g.nodes.push(n);
    return (uint)self.g.nodes.len() - 1;
}

// Record the dirty registers live into the current instruction on node `node`.
fn void OptBuild.snapshot(&self, uint node) {
    uint first = (uint)self.g.dirty.len();
    for (uint r = 0; r < self.nregs; r++) {
        OptRegState s = self.cur[r];
        if (s.node != NO_NODE && s.dirty && self.live_in_at(r)) {
            self.g.dirty.push({ .reg = r, .node = s.node });
        }
    }
    OptNode* n = &self.g.nodes[node];
    n.dirty_first = first;
    n.dirty_count = (uint)self.g.dirty.len() - first;
    if (self.cur_fn != 0) {
        OptInlineSite* s = &self.sites[self.cur_site];
        for (uint k = 0; k < s.cf.num_regs; k++) if (s.live_in[self.insn].test(k) && (s.defined[self.insn] & (1u << k)) != 0) n.live_mask |= 1u << k;
    }
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
        case GETTHISC: case PUTTHISC: return self.cur_fn == 0 ? self.nregs : self.sites[self.cur_site].base - 1;
        case GETPROPC: case GETPROPC_CACHED: return self.w.b;
        default: return self.w.a;
    }
}

// Whether the receiver of the field node being lowered is already known to be an object of
// `shape` that passes the node's guards.
fn bool OptBuild.guards_known(&self, uint reg, uint shape) {
    if (reg > self.nregs || self.fact_shape[reg] != shape) return false;
    return self.fact_plain[reg] || (self.w.op != Opcode.PUTPROPC && self.w.op != Opcode.PUTTHISC);
}

fn void OptBuild.learn(&self, uint reg, uint shape) {
    if (reg > self.nregs) return;
    self.fact_shape[reg] = shape;
    self.fact_plain[reg] = self.w.op == Opcode.PUTPROPC || self.w.op == Opcode.PUTTHISC;
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
    CompiledFunction* f = self.cur_f();
    if (f.ic_entries == null) return 0;
    return ((hobject::ICEntry*)f.ic_entries)[self.next_pc - 1].feedback;
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
        if (c.block != self.pckey()) continue;
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
    if (self.w.a < self.nregs) self.load_def[self.w.a] = self.pckey();
    return true;
}

// Whether the instruction being lowered has been cached for a string key.
fn bool OptBuild.string_keyed(&self) {
    CompiledFunction* f = self.cur_f();
    if (f.ic_entries == null) return true;
    return ((hobject::ICEntry*)f.ic_entries)[self.next_pc - 1].key.borrow() != null;
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
    CompiledFunction* f = self.cur_f();
    if (f.ic_entries == null) return null;
    hobject::ICEntry* ic = &((hobject::ICEntry*)f.ic_entries)[self.next_pc - 1];
    void* key = (void*)ic.key.borrow();
    if (key == null || ic.shape_id == heap::SHAPE_NONE || ic.has_proto) return null;
    if (ic.chain_len != 0 && ic.chain_len != hobject::IC_CHAIN_POLY) return null;
    if (ic.prop_idx == hobject::IC_PROP_ABSENT || ic.prop_flags.is_accessor) return null;
    if (key == (void*)self.h.strs[heap::BuiltinStr.LENGTH]) return null;
    if (self.w.op != Opcode.GETTHISC) {
        if (self.w.c >= f.const_count || !f.constants[self.w.c].is_string()) return null;
        if (f.constants[self.w.c].get_heapptr() != key) return null;
    }
    // More shapes than the code compares leave the site to the baseline.
    OptPoly p;
    if (!field_shapes(ic, &p)) return null;
    return ic;
}

// The distinct receiver shapes the entry `ic` of an own data property caches, the entry's own
// first and then its polymorphic set, each with its slot. False when there are more than
// OPT_POLY_MAX.
fn bool field_shapes(hobject::ICEntry* ic, OptPoly* p) {
    p.count = 1;
    p.shape[0] = ic.shape_id;
    p.idx[0] = ic.prop_idx;
    if (ic.chain_len != hobject::IC_CHAIN_POLY) return true;
    hobject::ICPolySet* set = &ic.chain.poly;
    for (uint i = 0; i < set.count; i++) {
        bool dup = false;
        for (uint k = 0; k < p.count; k++) dup = dup || p.shape[k] == set.shapes[i];
        if (dup) continue;
        if (p.count == OPT_POLY_MAX) return false;
        p.shape[p.count] = set.shapes[i];
        p.idx[p.count] = set.prop_idx[i];
        p.count++;
    }
    return true;
}

// Record the shapes of the entry `ic` for the node `n` being lowered.
fn void OptBuild.set_poly(&self, uint n, hobject::ICEntry* ic) {
    OptPoly p;
    field_shapes(ic, &p);
    self.g.polys.push(p);
    self.g.nodes[n].poly = (uint)self.g.polys.len();
}

// GETPROPC, GETPROPC_CACHED and GETTHISC of an own property by the shape its cache holds: a
// typed load when a numeric use asked for one, else a read into the window.
fn bool OptBuild.get_field(&self) {
    hobject::ICEntry* ic = self.own_field();
    if (ic == null || (self.w.op != Opcode.GETTHISC && !self.in_window(self.w.b))) return self.generic();
    uint recv = self.field_receiver();
    bool mono = ic.chain_len == 0;
    bool known = mono && self.guards_known(recv, ic.shape_id);
    uint shape = ic.shape_id;
    uint n = self.typed_load(OptOp.LOAD_FIELD, NO_NODE);
    if (n == NO_NODE) {
        n = self.add(OptOp.LOAD_FIELD, OptRep.NONE, NO_NODE, NO_NODE, (long)self.pc);
        self.snapshot(n);
        uint ra = self.w.a;
        self.kill(ra);
        if (ra < self.nregs) self.load_def[ra] = self.pckey();
        // A value of any kind in a slot beyond the caller's frame would be out of the collector's sight.
        if (self.cur_fn != 0 && ra >= self.caller_regs) self.inline_unsafe = true;
    }
    self.g.nodes[n].cc = known ? 1 : 0;
    self.set_poly(n, ic);
    if (mono) self.learn(recv, shape);
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
    // A value in the window may be a heap value, which needs the counted and traced store: the
    // baseline's, with the registers stored and reloaded around it, not an exit on every store.
    if (rv >= self.nregs || self.cur[rv].node == NO_NODE) return self.generic();
    uint recv = self.field_receiver();
    uint n = self.add(OptOp.STORE_FIELD, OptRep.NONE, self.cur[rv].node, NO_NODE, (long)self.pc);
    self.snapshot(n);
    bool mono = ic.chain_len == 0;
    self.g.nodes[n].cc = (mono && self.guards_known(recv, ic.shape_id)) ? 1 : 0;
    self.set_poly(n, ic);
    if (mono) self.learn(recv, ic.shape_id);
    return true;
}

// GETPROP of an element at an integer index, from an object in the window.
fn bool OptBuild.get_elem(&self) {
    if (!self.in_window(self.w.b) || !self.index_ok(self.w.c)) return self.generic();
    bool asked = false;
    foreach (c : self.load_reps) asked |= c.block == self.pckey();
    if (asked) {
        uint idx = self.operand(self.w.c, OptRep.INT32);
        if (idx == NO_NODE) return self.generic();
        self.typed_load(OptOp.LOAD_ELEM, idx);
        return true;
    }
    if (!self.generic()) return false;
    if (self.w.a < self.nregs) self.load_def[self.w.a] = self.pckey();
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
    // An inlined body holds nothing that runs as a GENERIC: the site stays a call.
    if (self.cur_fn != 0) {
        self.inline_failed = true;
        return true;
    }
    // Which registers the instruction writes: only the opcodes whose effect on
    // the register file is known run as GENERIC.
    uint first_kill = NO_NODE;   // calls: this register and every one above it
    uint extra_kill = NO_NODE;
    uint key_kill = NO_NODE;     // GETPROP_CACHE writes the coerced key back to C
    uint def = NO_NODE;
    Opcode op = self.w.op;
    if (!self.cur_cfg().nodes[self.insn].must_def(&def)) {
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
        if (self.cur[r].node != NO_NODE && self.live_out_at(r)) {
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

// --- Inlining ---
//
// A CALL or CALL_UNDEF_THIS whose feedback names one callee, a lean function with a short straight-line
// body of field reads, numeric arithmetic and a return, is replaced by that body, built into the
// caller's block with the callee's registers at base + r (the window the call would publish). A
// CHECK_CALLEE node before it leaves for the baseline code, at the call, unless the callee is that
// function and the call could be published; an exit from inside the body publishes the callee's frame
// first (opt_inline_exit) and continues in the callee's baseline code.

// Set the lowering context to instruction `k` of an inline site's callee.
fn void OptBuild.inline_context(&self, OptInlineSite* s, uint k) {
    DecodedCfgNode* node = &s.cfg.nodes[k];
    self.insn = k;
    self.pc = node.view.pc;
    self.next_pc = node.view.next_pc;
    self.w = node.view.insn;
    self.wide = false;
    inline_rebase(&self.w, s.base);
    if (k == s.remap) self.w.a = self.g.fns[self.cur_fn].remap_reg;
}

// Whether every instruction of the callee of `s` is one the builder lowers without a GENERIC (given
// what the callee's caches and feedback say), so that nothing in the body can call, allocate or throw.
// The graph registers of the callee's window must lie in the caller's own register file when anything
// but a number is written to them (OptBuild.inline_unsafe); that is decided while building.
fn bool OptBuild.inline_body_ok(&self, OptInlineSite* s, uint nargs) {
    CompiledFunction* cf = s.cf;
    DecodedCfg* cfg = &s.cfg;
    if (cfg.has_wide || cfg.instruction_count == 0) return self.reject(OptInlineReject.WIDE);
    // The first opcode outside the whitelist is the better reason for a body that also branches.
    for (uint k = 0; k < cfg.instruction_count; k++) {
        Opcode op = cfg.nodes[k].view.insn.op;
        if (!inline_op_ok(op)) { self.rej_op = op; return self.reject(OptInlineReject.OPCODE); }
    }
    if (cfg.block_count != 1) return self.reject(OptInlineReject.BLOCKS);
    Opcode last_op = cfg.nodes[cfg.instruction_count - 1].view.insn.op;
    if (last_op != Opcode.RET && last_op != Opcode.RETUNDEF) return self.reject(OptInlineReject.NO_RET);
    // Nothing but the arguments may be read before it is written: the window slots are not cleared.
    s.defined = mem::new_array(uint, cfg.instruction_count);
    uint defined = nargs >= 32 ? ~0u : (1u << nargs) - 1;
    for (uint k = 0; k < cfg.instruction_count; k++) {
        DecodedInsn w = cfg.nodes[k].view.insn;
        uint reads;
        uint writes;
        inline_rw(&w, &reads, &writes);
        if ((reads & ~defined) != 0) return self.reject(OptInlineReject.READ_UNDEF);
        s.defined[k] = defined;
        defined |= writes;
    }
    s.remap = uint::max;
    if (cfg.instruction_count >= 2 && last_op == Opcode.RET) {
        uint last = cfg.instruction_count - 2;
        uint rr = cfg.nodes[last + 1].view.insn.a;
        uint reads;
        uint writes;
        DecodedInsn lw = cfg.nodes[last].view.insn;
        inline_rw(&lw, &reads, &writes);
        bool alone = writes == (1u << rr);
        for (uint k = 0; k < last && alone; k++) {
            DecodedInsn kw = cfg.nodes[k].view.insn;
            uint r2;
            uint w2;
            inline_rw(&kw, &r2, &w2);
            if (((r2 | w2) & (1u << rr)) != 0) alone = false;
        }
        if (alone) s.remap = last;
    }
    uint saved_fn = self.cur_fn;
    uint saved_site = self.cur_site;
    self.g.fns.push({ .f = cf, .reg_base = s.base, .remap_pc = uint::max });
    self.cur_fn = (uint)self.g.fns.len() - 1;
    self.cur_site = 0;
    bool ok = true;
    OptInlineReject why = OptInlineReject.FEEDBACK;
    for (uint k = 0; k < cfg.instruction_count && ok; k++) {
        self.inline_context(s, k);
        Opcode op = self.w.op;
        switch (op) {
            case ADD: case SUB: case MUL: case DIV: case BAND: case BOR: case BXOR: case SHL: case SHR: case USHR:
            case ADDI: case SUBI: case MULI: case BANDI: case BORI: case BXORI: case SHLI: case SHRI: case USHRI:
            case INC: case DEC: case UNM:
                ok = (self.feedback() & (hobject::FB_STR | hobject::FB_OTHER)) == 0;
            case GETPROPC: case GETPROPC_CACHED:
                ok = self.own_field() != null;
                why = OptInlineReject.FIELD;
            case GETTHISC:
                ok = s.method && self.own_field() != null;
                why = OptInlineReject.FIELD;
            case PUTPROPC:
                hobject::ICEntry* ic = self.own_field();
                ok = ic != null && ic.prop_flags.writable;
                why = OptInlineReject.FIELD;
            case PUTTHISC:
                hobject::ICEntry* ic = self.own_field();
                ok = s.method && ic != null && ic.prop_flags.writable;
                why = OptInlineReject.FIELD;
            case LDCONST:
                uint index = self.w.get_bc();
                ok = index < cf.const_count && (cf.constants[index].is_fastint() || cf.constants[index].is_number());
                why = OptInlineReject.CONSTANT;
            default:
                break;
        }
    }
    if (!ok) self.reject(why);
    self.g.fns.size = self.g.fns.len() - 1;
    self.cur_fn = saved_fn;
    self.cur_site = saved_site;
    return ok;
}

// Whether the call at caller instruction `i` is an inline site, filling `s` when it is.
fn bool OptBuild.inline_candidate(&self, uint i, OptInlineSite* s) {
    DecodedBytecode view = self.cfg.nodes[i].view;
    Opcode op = view.insn.op;
    CompiledFunction* f = self.f;
    bool var_call = op == Opcode.CALL_VAR || op == Opcode.CALL_GLOBAL;
    if ((op != Opcode.CALL && op != Opcode.CALL_UNDEF_THIS && !var_call) || view.wide || f.ic_entries == null) return false;
    if (var_call && f.var_ic_entries == null) return false;
    hobject::ICEntry* ic = &((hobject::ICEntry*)f.ic_entries)[view.next_pc - 1];
    if ((ic.feedback & hobject::FB_CALL) == 0) return false;
    if ((ic.feedback & hobject::FB_POLY) != 0) return self.reject(OptInlineReject.POLY);
    if (ic.prop_idx >= self.h.compiled_func_count) return false;
    CompiledFunction* cf = (CompiledFunction*)self.h.compiled_funcs[ic.prop_idx];
    uint callee_reg = var_call ? view.insn.a : view.insn.b;
    uint nargs = var_call ? view.insn.b : view.insn.c;
    bool method = op == Opcode.CALL;
    // The window the call publishes lies in the caller's registers as far as the arguments go.
    if (cf == null) return false;
    if (cf == f) return self.reject(OptInlineReject.SELF);
    if (callee_reg + 2 + nargs > self.caller_regs) return self.reject(OptInlineReject.WINDOW);
    cf.classify_lean_call();
    if (cf.realm != f.realm || !opt_function_eligible(cf)) return self.reject(OptInlineReject.INELIGIBLE);
    if (!cf.call_flags.lean_call || (!method && !cf.call_flags.lean_plain)) return self.reject(OptInlineReject.NOT_LEAN);
    if (cf.arguments_in_reg() || cf.call_flags.rest_length_only || cf.ic_entries == null || cf.var_ic_entries == null) return self.reject(OptInlineReject.ARGS);
    if (is_top_level(cf)) return self.reject(OptInlineReject.TOP_LEVEL);
    if (cf.num_formals != nargs) return self.reject(OptInlineReject.FORMALS);
    if (cf.num_regs > 32 || cf.code_count > INLINE_WORDS_MAX) return self.reject(OptInlineReject.SIZE);
    // What a call leaves behind is its result: the rest of its window is dead after it.
    // (A call that names no receiver leaves `this` implicit, which liveness takes for live around a loop.)
    for (uint r = callee_reg; r < self.caller_regs; r++) {
        if (r == view.insn.a || (!method && r == callee_reg + 1)) continue;
        if (self.live_out[i].test(r)) return self.reject(OptInlineReject.WINDOW_LIVE);
    }
    *s = { .insn = i, .cf = cf, .base = callee_reg + 2, .method = method, .var_call = var_call };
    bool ok = compiler::bytecode_cfg_build(&s.cfg, cf.code, cf.code_count, self.h);
    if (ok) {
        uint count = s.cfg.instruction_count;
        uint words = (cf.num_regs + 32) / 32;
        s.live_sets = mem::new_array(RegSet, (usz)count * 2);
        s.live_words = mem::new_array(uint, ((usz)count * 2 + 1) * words);
        for (uint k = 0; k < count * 2; k++) s.live_sets[k] = { .words = s.live_words + (usz)k * words, .word_count = words };
        RegSet scratch = { .words = s.live_words + (usz)count * 2 * words, .word_count = words };
        compiler::bytecode_cfg_liveness(&s.cfg, s.live_sets, s.live_sets + count, &scratch, true, false, true);
        s.live_out = s.live_sets;
        s.live_in = s.live_sets + count;
        ok = self.inline_body_ok(s, nargs);
    }
    // An exit from the body continues in the callee's baseline code: compile it now if it has none.
    if (ok && cf.jit_code == null) {
        ok = !cf.jit_refused && baseline_try_compile(self.h, cf, false) != null;
        if (!ok) self.reject(cf.call_flags.trivial_call != 0 ? OptInlineReject.NO_JIT_TRIVIAL : OptInlineReject.NO_JIT);
    }
    if (!ok) s.free_site();
    return ok;
}

// Find the inline sites, and widen nregs to hold their callee windows.
fn void OptBuild.find_sites(&self) {
    if (self.no_inline || self.h.opt.no_inline) return;
    uint count = self.cfg.instruction_count;
    for (uint i = 0; i < count; i++) {
        OptInlineSite s;
        self.rej = OptInlineReject.BUILD;
        if (!self.inline_candidate(i, &s)) {
            Opcode cop = self.cfg.nodes[i].view.insn.op;
            bool is_call = cop == Opcode.CALL || cop == Opcode.CALL_UNDEF_THIS || cop == Opcode.CALL_VAR || cop == Opcode.CALL_GLOBAL;
            if (is_call && self.rej != OptInlineReject.BUILD) self.count_reject(self.rej, self.rej_op);
            continue;
        }
        if (self.site_of == null) self.site_of = mem::new_array(uint, count);
        self.sites.push(s);
        self.site_of[i] = (uint)self.sites.len();
        uint need = s.base + s.cf.num_regs;
        if (need > self.nregs) self.nregs = need;
    }
}

// Store the boxed constant `bits` to window slot `reg` (a register of an inlined body or the call's
// result): nothing is known of the register after, as a read from the window.
fn void OptBuild.store_const(&self, uint reg, long bits) {
    uint n = self.add(OptOp.STORE_CONST, OptRep.NONE, NO_NODE, NO_NODE, bits);
    self.g.nodes[n].home = reg;
    self.kill(reg);
}

// The return of an inlined body: its value becomes the call's result register. A number is a new
// node in that register; a window value is copied to its slot.
fn bool OptBuild.inline_return(&self, uint result, uint* node) {
    if (self.sites[self.cur_site].remap != uint::max) {
        *node = NO_NODE;
        return true;
    }
    uint ra = self.w.a;
    if (ra >= self.nregs || result >= self.nregs) return false;
    uint src = self.cur[ra].node;
    if (src != NO_NODE) {
        if (!self.g.nodes[src].is_const()) src = self.add(OptOp.COPY, self.rep_of(src), src);
        *node = src;
        return true;
    }
    uint n = self.add(OptOp.COPY_WINDOW, OptRep.NONE, NO_NODE, NO_NODE, (long)self.pc);
    self.g.nodes[n].home = result;
    self.snapshot(n);
    *node = NO_NODE;
    return true;
}

// Replace the call being lowered by its callee's body when the call is an inline site and the state
// allows it; false leaves the graph as it was, for the call to be lowered as a GENERIC.
fn bool OptBuild.try_inline(&self) {
    if (self.cur_fn != 0 || self.site_of == null || self.site_of[self.insn] == 0) return false;
    uint si = self.site_of[self.insn] - 1;
    OptInlineSite* s = &self.sites[si];
    if (self.h.opt.inline_seen >= self.h.opt.inline_max) return false;
    self.h.opt.inline_seen++;
    uint callee_reg = s.base - 2;
    // The function and its receiver are read from the window by the guard and by an exit.
    if (!s.var_call && (!self.in_window(callee_reg) || !self.in_window(callee_reg + 1))) {
        if (!s.counted) self.count_reject(OptInlineReject.STATE, Opcode.NOP);
        s.counted = true;
        return false;
    }
    uint n = self.nregs;
    OptRegState* save_cur = mem::new_array(OptRegState, n);
    uint* save_def = mem::new_array(uint, n);
    uint* save_shape = mem::new_array(uint, (usz)n + 1);
    bool* save_plain = mem::new_array(bool, (usz)n + 1);
    defer { mem::free(save_cur); mem::free(save_def); mem::free(save_shape); mem::free(save_plain); }
    mem::copy(save_cur, self.cur, (usz)n * OptRegState::size);
    mem::copy(save_def, self.load_def, (usz)n * uint::size);
    mem::copy(save_shape, self.fact_shape, ((usz)n + 1) * uint::size);
    mem::copy(save_plain, self.fact_plain, (usz)n + 1);
    sz nodes0 = self.g.nodes.len();
    sz dirty0 = self.g.dirty.len();
    sz fns0 = self.g.fns.len();
    uint site_insn = self.insn;
    uint resume = self.next_pc;
    uint result = self.w.a;

    if (s.var_call) {
        // The callee is read from its variable into the callee register, as the call would.
        uint load = self.add(OptOp.LOAD_VAR, OptRep.NONE, NO_NODE, NO_NODE, (long)self.pc);
        self.g.nodes[load].cc = self.w.op == Opcode.CALL_VAR ? 1 : 0;
        self.snapshot(load);
        self.kill(callee_reg);
    }
    // The guard resumes the call itself, in the caller's context.
    uint chk = self.add(OptOp.CHECK_CALLEE, OptRep.NONE, NO_NODE, NO_NODE, (long)(usz)s.cf);
    self.g.nodes[chk].cc = s.method ? 1 : 0;
    self.snapshot(chk);

    uint remap_pc = s.remap == uint::max ? uint::max : s.cfg.nodes[s.remap].view.pc;
    self.g.fns.push({ .f = s.cf, .reg_base = s.base, .resume_pc = resume, .remap_pc = remap_pc, .remap_reg = result });
    self.cur_fn = (uint)self.g.fns.len() - 1;
    self.cur_site = si;
    self.inline_failed = false;
    self.inline_unsafe = false;
    // The locals and temporaries start as nothing known; the arguments keep their state.
    for (uint r = s.base + s.cf.num_formals; r < n; r++) self.kill(r);
    bool ok = true;
    uint result_node = NO_NODE;
    for (uint k = 0; k < s.cfg.instruction_count && ok; k++) {
        self.inline_context(s, k);
        if (self.w.op == Opcode.RET) {
            ok = self.inline_return(result, &result_node);
        } else if (self.w.op == Opcode.RETUNDEF) {
            self.store_const(result, K_UNDEF);
        } else {
            ok = self.lower();
        }
        if (self.inline_failed) ok = false;
    }
    bool unsafe = self.inline_unsafe;
    if (unsafe) ok = false;
    self.cur_fn = 0;
    self.context(site_insn);
    if (!ok) {
        if (!s.counted) self.count_reject(unsafe ? OptInlineReject.UNSAFE : OptInlineReject.BUILD, Opcode.NOP);
        s.counted = true;
        self.g.nodes.size = nodes0;
        self.g.dirty.size = dirty0;
        self.g.fns.size = fns0;
        mem::copy(self.cur, save_cur, (usz)n * OptRegState::size);
        mem::copy(self.load_def, save_def, (usz)n * uint::size);
        mem::copy(self.fact_shape, save_shape, ((usz)n + 1) * uint::size);
        mem::copy(self.fact_plain, save_plain, (usz)n + 1);
        self.inline_failed = false;
        self.inline_unsafe = false;
        self.refused = OptRefuse.NONE;
        return false;
    }
    // What a call leaves: its window and everything above it dead, then the result.
    bool remapped = s.remap != uint::max;
    for (uint r = callee_reg; r < n; r++) if (!remapped || r != result) self.kill(r);
    if (result_node != NO_NODE) {
        self.set(result, result_node);
    } else if (!remapped) {
        self.kill(result);
    }
    self.inlined++;
    return true;
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
            if (!self.consts_ok || index >= self.cur_f().const_count) return self.generic();
            TVal v = self.cur_f().constants[index];
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
        case LDUNDEF: case LDNULL: case LDTRUE: case LDFALSE:
            if (self.cur_fn == 0) return self.generic();
            TVal v;
            switch (op) {
                case LDUNDEF: v.set_undefined();
                case LDNULL: v.set_null();
                default: v.set_boolean(op == LDTRUE);
            }
            // A register the body never reads again needs no value.
            uint k = self.cur_cfg().nodes[self.insn].view.insn.a;
            if (self.w.a == k + self.sites[self.cur_site].base && !self.sites[self.cur_site].live_out[self.insn].test(k)) {
                self.kill(ra);
                return true;
            }
            self.store_const(ra, (long)v.bits);
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
        case CALL:
        case CALL_UNDEF_THIS:
        case CALL_VAR:
        case CALL_GLOBAL:
            if (self.try_inline()) return true;
            return self.generic();
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
    DecodedCfgNode* node = &self.cur_cfg().nodes[i];
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
    self.g.fns.size = 1;
    self.inlined = 0;
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
fn OptRefuse opt_build_graph(Heap* h, CompiledFunction* f, OptGraph* g, OptBuild* b, Opcode* refused_op, bool no_inline) {
    *b = {};
    b.no_inline = no_inline;
    b.h = h;
    b.f = f;
    b.g = g;
    g.fns.clear();
    g.fns.push({ .f = f, .reg_base = 0 });
    b.overrides.init(mem);
    b.load_reps.init(mem);
    b.sites.init(mem);
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
