// Optimizing tier: allocation sinking.
//
// An inlined `new C(...)` is a NEW_OBJECT node whose object the constructor body fills through
// ADD_FIELD nodes. When the object never escapes the graph, it is not allocated: its fields are the
// nodes stored into them, a read of one is a copy of that node, and a read the prototype chain
// answers is a load from the owner the site validated (OptSinkSite). The object may only flow
// through COPY nodes into
//   - the receiver of a LOAD_FIELD, STORE_FIELD or ADD_FIELD whose key the graph can follow,
//   - the receiver of an inlined call (CHECK_CALLEE.b), and
//   - the dirty registers of nodes whose only use of them is an exit, which allocates the object
//     there with the fields it has (an OptMat) and stores it to each register that holds it.
// Anything else (a GENERIC, a store to the window, an edge, a loop, a field value of another object,
// a key added on one path only) leaves the allocation in place.
module boomkat::jit @feat(SLJIT);

import std::collections::list;
import std::io;

const uint OPT_SINK_FIELDS = 16;
const uint OPT_SINK_READS = 8;
// Sunk allocations in one graph at most.
const uint OPT_SINK_MAX = 64;

// The fields of a sunk object at a point of the graph: defined, or no object (def false), or
// different on the paths that join there (conflict).
struct OptSinkState {
    bool def;
    bool conflict;
    uint count;
    uint[OPT_SINK_FIELDS] vals;
}

enum OptSinkAct : char {
    // A COPY of the object: sunk with it.
    ALIAS,
    // A field access done in the graph.
    FIELD,
    // A LOAD_FIELD of a field the object has: a copy of the value node `val`, of the load's rep.
    LOAD,
    // A LOAD_FIELD the prototype chain answers: read number `val` of the site.
    READ,
    // The receiver of an inlined call.
    RECV,
}

struct OptSinkEdit {
    OptSinkAct act;
    uint node;
    uint val;
}

// The scratch of the pass, over the whole graph.
struct OptSinkScratch {
    uint[] block_of;
    uint[] pred_first;
    uint[] pred_count;
    List{uint} preds;
    bool[] held_by;
    OptSinkState[] states;
    List{OptSinkEdit} edits;
}

// The node field c names a node only for the element accesses (sinking reuses it elsewhere).
fn uint OptNode.c_node(&self) @inline {
    return (self.op == OptOp.LOAD_ELEM || self.op == OptOp.STORE_ELEM || self.op == OptOp.STRING_REGEXP) ? self.c : NO_NODE;
}

fn bool OptGraph.sink_refs(&self, OptSinkScratch* s, OptNode* n) @inline {
    uint c = n.c_node();
    return (n.a != NO_NODE && s.held_by[n.a]) || (n.b != NO_NODE && s.held_by[n.b]) || (c != NO_NODE && s.held_by[c]);
}

fn bool OptGraph.sink_in_list(&self, OptSinkScratch* s, uint first, uint count) {
    for (uint k = 0; k < count; k++) {
        // A slot a call from an inlined body clears has no node.
        uint node = self.dirty[(sz)(first + k)].node;
        if (node != NO_NODE && s.held_by[node]) return true;
    }
    return false;
}

// Scalar-replace the allocations that never escape. Returns the count sunk.
// With `trace`, why each allocation stays is printed (--opt-dump).
fn uint OptGraph.sink(&self, bool trace = false) {
    uint count = (uint)self.nodes.len();
    uint nblocks = (uint)self.blocks.len();
    bool has_alloc = false;
    foreach (&n : self.nodes) if (n.op == OptOp.NEW_OBJECT) has_alloc = true;
    if (!has_alloc) return 0;
    OptSinkScratch s;
    s.block_of = mem::new_array(uint, count);
    s.pred_first = mem::new_array(uint, nblocks);
    s.pred_count = mem::new_array(uint, nblocks);
    s.held_by = mem::new_array(bool, count);
    s.states = mem::new_array(OptSinkState, nblocks);
    s.preds.init(mem);
    s.edits.init(mem);
    defer {
        mem::free(s.block_of);
        mem::free(s.pred_first);
        mem::free(s.pred_count);
        mem::free(s.held_by);
        mem::free(s.states);
        s.preds.free();
        s.edits.free();
    }
    foreach (pos, &blk : self.blocks) {
        for (uint i = blk.first; i < blk.end; i++) s.block_of[i] = (uint)pos;
    }
    for (uint b = 0; b < nblocks; b++) {
        s.pred_first[b] = (uint)s.preds.len();
        foreach (p, &blk : self.blocks) {
            for (uint e = 0; e < blk.succ_count; e++) {
                // A two-way branch to one block is one edge here.
                if (blk.succ[e] == b && (e == 0 || blk.succ[0] != b)) s.preds.push((uint)p);
            }
        }
        s.pred_count[b] = (uint)s.preds.len() - s.pred_first[b];
    }
    uint sunk = 0;
    for (uint v = 0; v < count && self.sinks.len() < OPT_SINK_MAX; v++) {
        if (self.nodes[v].op != OptOp.NEW_OBJECT) continue;
        if (self.try_sink(&s, v, trace)) sunk++;
    }
    return sunk;
}

// The analysis of one allocation, applied when it holds.
fn bool OptGraph.try_sink(&self, OptSinkScratch* s, uint v, bool trace) {
    uint count = (uint)self.nodes.len();
    uint nblocks = (uint)self.blocks.len();
    sz mats0 = self.mats.len();
    sz vals0 = self.mat_vals.len();
    uint sid = (uint)self.sinks.len();
    OptSink sk = { .node = v };
    s.edits.clear();
    mem::clear(s.held_by.ptr, (usz)count);
    mem::clear(s.states.ptr, (usz)nblocks * OptSinkState::size);
    s.held_by[v] = true;
    uint bv = s.block_of[v];
    bool ok = true;
    // The node the analysis stopped at.
    uint at = NO_NODE;
    for (uint b = bv; b < nblocks && ok; b++) {
        OptBlock* blk = &self.blocks[b];
        OptSinkState st;
        if (b != bv) {
            bool first = true;
            bool def_any = false;
            for (uint k = 0; k < s.pred_count[b]; k++) {
                uint p = s.preds[(sz)(s.pred_first[b] + k)];
                if (p >= b) continue;
                OptSinkState* ps = &s.states[p];
                if (ps.def) def_any = true;
                if (first) {
                    st = *ps;
                    first = false;
                    continue;
                }
                if (ps.def != st.def || ps.conflict || ps.count != st.count) {
                    st.conflict = true;
                    continue;
                }
                for (uint f = 0; f < st.count; f++) if (ps.vals[f] != st.vals[f]) st.conflict = true;
            }
            // A loop the object lives into.
            if (blk.header && def_any) { ok = false; at = blk.first; break; }
            if (st.conflict) st.def = true;
        }
        if (blk.osr && self.sink_in_list(s, blk.osr_first, blk.osr_count)) { ok = false; break; }
        for (uint j = blk.first; j < blk.end && ok; j++) {
            OptNode* n = &self.nodes[j];
            at = j;
            if (j == v) {
                st = { .def = true };
                continue;
            }
            bool operand = self.sink_refs(s, n);
            bool dirty = self.sink_in_list(s, n.dirty_first, n.dirty_count);
            if (!operand && !dirty) continue;
            if (!st.def || st.conflict || self.sink_in_list(s, n.reload_first, n.reload_count)) { ok = false; break; }
            if (dirty) {
                // The window store of a call or a counted element store publishes it as it is.
                if (n.op == OptOp.GENERIC || n.op == OptOp.CALL_REG || (n.op == OptOp.STORE_ELEM && n.b == NO_NODE)) { ok = false; break; }
                self.mats.push({ .node = j, .sink = sid, .count = st.count, .vals_first = (uint)self.mat_vals.len() });
                for (uint f = 0; f < st.count; f++) self.mat_vals.push(st.vals[f]);
            }
            if (!operand) continue;
            bool on_a = n.a != NO_NODE && s.held_by[n.a];
            bool on_b = n.b != NO_NODE && s.held_by[n.b];
            bool on_c = n.c_node() != NO_NODE && s.held_by[n.c_node()];
            if (n.op == OptOp.COPY && on_a) {
                s.held_by[j] = true;
                s.edits.push({ .act = ALIAS, .node = j });
                continue;
            }
            if (on_a || on_c || !on_b) { ok = false; break; }
            switch (n.op) {
                case LOAD_FIELD:
                    int idx = -1;
                    for (uint f = 0; f < st.count; f++) if (sk.keys[f] == n.key) idx = (int)f;
                    if (idx >= 0) {
                        uint val = st.vals[idx];
                        OptRep vr = self.nodes[val].rep;
                        bool fits = n.rep == OptRep.NONE || vr == n.rep || (n.rep == OptRep.FLOAT64 && vr == OptRep.INT32);
                        if (!fits) { ok = false; break; }
                        s.edits.push({ .act = LOAD, .node = j, .val = val });
                    } else if (n.cc == 2 && n.key != null) {
                        uint r = sk.read_count;
                        for (uint k = 0; k < sk.read_count; k++) if (sk.reads[k] == n.key) r = k;
                        if (r == sk.read_count) {
                            if (r == OPT_SINK_READS) { ok = false; break; }
                            sk.reads[sk.read_count++] = n.key;
                        }
                        s.edits.push({ .act = READ, .node = j, .val = r });
                    } else {
                        ok = false;
                    }
                case STORE_FIELD:
                    int idx = -1;
                    for (uint f = 0; f < st.count; f++) if (sk.keys[f] == n.key) idx = (int)f;
                    // A constant from the window (STORE_CONST) is not a node a read can copy.
                    if (idx < 0 || n.a == NO_NODE || self.nodes[n.a].rep == OptRep.NONE) { ok = false; break; }
                    st.vals[idx] = n.a;
                    s.edits.push({ .act = FIELD, .node = j });
                case ADD_FIELD:
                    if (n.a == NO_NODE || n.key == null || st.count == OPT_SINK_FIELDS) { ok = false; break; }
                    for (uint f = 0; f < st.count; f++) if (sk.keys[f] == n.key) ok = false;
                    if (!ok) break;
                    // The keys are added in one order on every path.
                    if (st.count < sk.add_count) {
                        if (sk.keys[st.count] != n.key) { ok = false; break; }
                    } else {
                        sk.keys[sk.add_count++] = n.key;
                    }
                    st.vals[st.count++] = n.a;
                    s.edits.push({ .act = FIELD, .node = j });
                case CHECK_CALLEE:
                    s.edits.push({ .act = RECV, .node = j });
                default:
                    ok = false;
            }
        }
        if (!ok) break;
        s.states[b] = st;
        for (uint e = 0; e < blk.succ_count && ok; e++) {
            for (uint k = 0; k < blk.move_count[e]; k++) {
                OptMove m = self.moves[(sz)(blk.move_first[e] + k)];
                if (s.held_by[m.src] || (m.dst != NO_NODE && s.held_by[m.dst])) { ok = false; break; }
            }
        }
    }
    if (!ok) {
        if (trace && at != NO_NODE) {
            OptNode* n = &self.nodes[at];
            if (n.op == OptOp.GENERIC) {
                io::eprintfn("sink: n%d stays: n%d GENERIC %s", v, at, self.fns[n.fidx].f.code[(uint)n.imm].op);
            } else {
                io::eprintfn("sink: n%d stays: n%d %s", v, at, n.op);
            }
        }
        self.mats.size = mats0;
        self.mat_vals.size = vals0;
        return false;
    }
    // A key the object's own fields hold is not one its chain answers on another path.
    for (uint k = 0; k < sk.read_count; k++) {
        for (uint f = 0; f < sk.add_count; f++) {
            if (sk.reads[k] != sk.keys[f]) continue;
            self.mats.size = mats0;
            self.mat_vals.size = vals0;
            return false;
        }
    }
    self.sinks.push(sk);
    OptNode* nv = &self.nodes[v];
    nv.sunk = true;
    nv.c = sid;
    foreach (e : s.edits) {
        OptNode* n = &self.nodes[e.node];
        switch (e.act) {
            case ALIAS:
                n.sunk = true;
                n.a = NO_NODE;
                n.c = sid;
            case FIELD:
                n.op = OptOp.SUNK;
                n.a = NO_NODE;
                n.b = NO_NODE;
            case LOAD:
                n.b = NO_NODE;
                n.a = e.val;
                if (n.rep == OptRep.NONE) {
                    n.op = OptOp.STORE_VALUE;
                    n.imm = n.home;
                    // Stored from its machine register (store_node), not its own slot.
                    self.nodes[e.val].held = true;
                } else if (n.rep == OptRep.FLOAT64 && self.nodes[e.val].rep == OptRep.INT32) {
                    n.op = OptOp.I32_TO_F64;
                } else {
                    n.op = OptOp.COPY;
                }
            case READ:
                n.cc = 3;
                n.b = NO_NODE;
                n.c = sid << 8 | e.val;
            case RECV:
                n.b = NO_NODE;
                n.c = sid;
        }
    }
    for (sz k = mats0; k < self.mats.len(); k++) {
        OptMat* m = &self.mats[k];
        for (uint f = 0; f < m.count; f++) self.nodes[self.mat_vals[(sz)(m.vals_first + f)]].held = true;
    }
    return true;
}

// Whether a value an exit stores into a sunk object was left without a register: it would be read
// from a slot another node may have taken. The graph is then built again without sinking.
fn bool OptGraph.sink_spilled(&self) {
    foreach (&n : self.nodes) {
        if (n.held && n.allocated() && n.reg < 0) return true;
    }
    return false;
}
