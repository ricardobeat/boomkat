// Optimizing tier: the graph.
//
// A function is built into blocks of nodes in reverse postorder, which is also
// the order the code is emitted in. Every JS register is, at each point,
// either Window (its value lives only in the interpreter's register window and
// its type is not known) or a numeric node, INT32 or FLOAT64, in a machine
// register or a constant. A node is dirty while the window slot of the
// register that holds it is stale. Everything that is not numeric is done by
// GENERIC nodes: the baseline emitter's code on the window, run after the
// dirty registers it can read are stored.
//
// A node's "home" is the window slot of the register it was defined into. No
// node is held by two registers, so a register's slot is only ever the home of
// the node that register currently holds.
module boomkat::jit @feat(SLJIT);

import boomkat::bytecode;
import std::collections::list;
import std::io;

const uint NO_NODE = uint::max;

enum OptRep : char {
    NONE,
    // A sign-extended 64-bit register holding a value in int32 range.
    INT32,
    // A double in a floating point register.
    FLOAT64,
}

enum OptOp : char {
    // imm is the value: an int32, or the bits of a double.
    CONST_I32,
    CONST_F64,
    // Window slot imm, checked to hold an int32 (exit NOT_INT32) or a number
    // (exit NOT_NUMBER), as an INT32 or FLOAT64.
    CHECK_I32,
    CHECK_NUM,
    // A GETCAP (imm its pc) read as a number of the node's rep; exits when the capture is not
    // one of the plain cases or not that kind of number.
    LOAD_CAP,
    // A GETPROP (imm its pc) of the dense or typed array element at INT32 node a, as a number of
    // the node's rep; exits for any other object, an index out of range, a hole or another value.
    LOAD_ELEM,
    // A PUTPROP (imm its pc) of the number node b to the element at INT32 node a, exiting where
    // LOAD_ELEM would. It defines nothing.
    STORE_ELEM,
    // A GETPROPC, GETPROPC_CACHED or GETTHISC (imm its pc) read of the own data property its
    // cache names, from a non-proxy object of the cache's shapes; exits for any other receiver. Of rep
    // NONE it writes the value to the window, else it is a number of the node's rep.
    LOAD_FIELD,
    // A PUTPROPC or PUTTHISC (imm its pc) overwrite of the own writable data property its cache
    // names, in a plain object of the cache's shape; exits for any other receiver or a value that
    // needs a barrier. a is the number node stored, or NO_NODE for a value in the window. It
    // defines nothing.
    STORE_FIELD,
    PHI,
    // A new node holding the value of `a`.
    COPY,
    // INT32 operands a, b. These exit (OVERFLOW) on a result out of int32 range;
    // MUL also on -0.
    ADD_I32,
    SUB_I32,
    MUL_I32,
    AND_I32,
    OR_I32,
    XOR_I32,
    NOT_I32,
    // b is the count, masked to five bits.
    SHL_I32,
    SAR_I32,
    // `>>>`: exits (OVERFLOW) when the result is above the int32 range.
    SHR_I32,
    I32_TO_F64,
    // JS ToInt32 of a double; exits when the double is not within int64 range.
    F64_TO_I32,
    ADD_F64,
    SUB_F64,
    MUL_F64,
    DIV_F64,
    NEG_F64,
    // A call site's inlined callee (imm its CompiledFunction*, the call at pc, cc nonzero for a
    // method call): exits (CALLEE) before any effect unless the callee register holds a closure of
    // that function, the receiver and the frame a real call would publish are acceptable, and
    // there is room for it. The nodes after it, until the next such node, are the callee's body.
    CHECK_CALLEE,
    // The variable a CALL_VAR (cc nonzero) or CALL_GLOBAL (imm its pc) names, stored in the call's
    // callee register as a published value; exits (SLOW_PATH) when its cache does not hold.
    LOAD_VAR,
    // The window slot imm (a callee RET's register) copied to the window slot home (the call's
    // result register) as a published store; exits (SLOW_PATH) where publish does.
    COPY_WINDOW,
    // The boxed constant imm (undefined, null or a boolean) stored to the window slot home.
    STORE_CONST,
    // A jump to succ[0]; a conditional branch (BRANCH: JMP_* row cc over a and b
    // of rep imm, BRANCH_TRUTH: IF_TRUE/IF_FALSE over a, or the window slot imm
    // when a is NO_NODE, cc nonzero for IF_FALSE) takes succ[0] when it holds and
    // falls to succ[1].
    JUMP,
    BRANCH,
    BRANCH_TRUTH,
    // A branch on two window slots (imm: b | c << 20) by the baseline's equality test: cc is
    // 0 JMP_SEQ, 1 JMP_SNEQ, 2 JMP_EQ, 3 JMP_NEQ, 4 JMP_NULL, 5 JMP_NNULL.
    BRANCH_WINDOW,
    // The bytecode instruction at pc, through the baseline emitter.
    GENERIC,
}

// A window slot and the node whose value belongs in it.
struct OptDirty {
    uint reg;
    uint node;
}

// A function whose bytecode appears in the graph: fns[0] is the function being optimized, the
// others are inlined callees. A callee's registers are the caller's, shifted by reg_base: callee
// register r is register reg_base + r of the graph.
struct OptFn {
    CompiledFunction* f;
    uint reg_base;
    // For an inlined callee: the word of the caller after the call, where the caller resumes once
    // the callee frame that an exit from the body publishes returns.
    uint resume_pc;
    // The callee word whose result register is remap_reg of the caller, instead of its own
    // register (uint::max when none).
    uint remap_pc;
    uint remap_reg;
}

struct OptNode {
    OptOp op;
    OptRep rep;
    char cc;
    uint a;
    uint b;
    long imm;
    // The bytecode word the node came from; an exit resumes there.
    uint pc;
    // The OptGraph.fns entry whose bytecode pc and imm (for the nodes that carry one) index.
    uint fidx;
    // The dirty registers live at the node: an exit stores them, a GENERIC
    // stores them before it runs.
    uint dirty_first;
    uint dirty_count;
    // GENERIC: the numeric registers live after it, reloaded from the window.
    uint reload_first;
    uint reload_count;
    // Inside an inlined callee: the callee registers (bit r for callee register r) live at the
    // node, which the callee frame an exit publishes must keep.
    uint live_mask;
    // LOAD_FIELD, STORE_FIELD: 1 + the index in OptGraph.polys of the receiver shapes it accepts.
    uint poly;
    // The window slot a node was defined into.
    uint home;
    // Allocation: the machine register, or -1 for a constant or a value that
    // lives in its home slot.
    int reg;
    // The last node position that uses this value.
    uint last_use;
}

// An edge's work: a phi receives `src`, converted when its rep differs; with
// dst NO_NODE the dirty value `src` is stored to window slot `slot`.
struct OptMove {
    uint dst;
    uint src;
    uint slot;
}

struct OptBlock {
    // Node positions [first, end).
    uint first;
    uint end;
    // The bytecode word of the first instruction.
    uint pc;
    uint succ_count;
    uint[2] succ;
    // The moves of each outgoing edge: [first, first + count) in OptGraph.moves.
    uint[2] move_first;
    uint[2] move_count;
    bool header;
    // The last block position of the loop this block heads.
    uint loop_end;
    // For a header: the phis' (register, node) pairs, which a poll's exit stores.
    uint entry_first;
    uint entry_count;
    // Entered from baseline code (the target of a backward branch): the numeric
    // nodes live at its start, which the entry reloads from the window.
    bool osr;
    uint osr_first;
    uint osr_count;
}

const uint OPT_POLY_MAX = 4;

// The receiver shapes a field access accepts, in the order its code compares them, each with the
// slot its property has in an object of that shape.
struct OptPoly {
    uint count;
    uint[OPT_POLY_MAX] shape;
    uint[OPT_POLY_MAX] idx;
}

struct OptGraph {
    List{OptPoly} polys;
    List{OptNode} nodes;
    List{OptBlock} blocks;
    List{OptMove} moves;
    List{OptDirty} dirty;
    List{OptFn} fns;
}

fn void OptGraph.init(&self) {
    self.polys.init(mem);
    self.nodes.init(mem);
    self.blocks.init(mem);
    self.moves.init(mem);
    self.dirty.init(mem);
    self.fns.init(mem);
}

fn void OptGraph.clear(&self) {
    self.polys.clear();
    self.nodes.clear();
    self.blocks.clear();
    self.moves.clear();
    self.dirty.clear();
}

fn void OptGraph.free(&self) {
    self.polys.free();
    self.nodes.free();
    self.blocks.free();
    self.moves.free();
    self.dirty.free();
    self.fns.free();
}

fn bool OptNode.is_const(&self) @inline => self.op == OptOp.CONST_I32 || self.op == OptOp.CONST_F64;

// Print the graph to stderr: one line per node, with the register allocation
// and the moves of each edge.
fn void OptGraph.dump(&self, CompiledFunction* f) {
    io::eprintfn("opt graph: %d nodes, %d blocks, code %d words", self.nodes.len(), self.blocks.len(), f.code_count);
    for (uint i = 1; i < self.fns.len(); i++) {
        io::eprintfn("inline fn=%d cf=fn#%d base=%d resume=%d", i, self.fns[i].f.func_index, self.fns[i].reg_base, self.fns[i].resume_pc);
    }
    foreach (pos, &blk : self.blocks) {
        io::eprintfn("block %d pc=%d%s succ=[%d %d] n=%d", pos, blk.pc, blk.header ? " loop-header" : "", blk.succ[0], blk.succ[1], blk.succ_count);
        for (uint i = blk.first; i < blk.end; i++) {
            OptNode* n = &self.nodes[i];
            if (n.op == OptOp.GENERIC) io::eprintf("  [%s]", self.fns[n.fidx].f.code[(uint)n.imm].op);
            io::eprintf("  n%d %s rep=%s a=%d b=%d imm=%d pc=%d reg=%d home=%d last=%d cc=%d", i, n.op, n.rep, (int)n.a, (int)n.b, n.imm, n.pc, n.reg, n.home, n.last_use, n.cc);
            if (n.fidx != 0) io::eprintf(" fn=%d", n.fidx);
            if (n.dirty_count != 0) {
                io::eprintf(" dirty=");
                for (uint k = 0; k < n.dirty_count; k++) io::eprintf("r%d:n%d ", self.dirty[(sz)(n.dirty_first + k)].reg, self.dirty[(sz)(n.dirty_first + k)].node);
            }
            if (n.reload_count != 0) {
                io::eprintf(" reload=");
                for (uint k = 0; k < n.reload_count; k++) io::eprintf("r%d:n%d ", self.dirty[(sz)(n.reload_first + k)].reg, self.dirty[(sz)(n.reload_first + k)].node);
            }
            io::eprintfn("");
        }
        for (uint e = 0; e < blk.succ_count; e++) {
            for (uint k = 0; k < blk.move_count[e]; k++) {
                OptMove m = self.moves[(sz)(blk.move_first[e] + k)];
                io::eprintfn("  edge%d -> b%d: dst=%d src=%d slot=%d", e, blk.succ[e], (int)m.dst, (int)m.src, m.slot);
            }
        }
    }
}
