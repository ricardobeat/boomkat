// Optimizing tier: register allocation.
//
// Linear scan over the nodes in emission order, one register for the whole
// life of a value. When the pool runs out the value with the furthest last use
// is spilled whole: it lives in its home window slot, boxed, from its
// definition on, so a spill costs a load and an unbox per use and nothing at a
// call or an exit. A phi is never spilled.
module boomkat::jit @feat(SLJIT);

import std::collections::list;

// The machine registers the optimized code may keep values in: the scratch
// registers above the five the baseline emitter uses, and the floating point
// registers above its two.
struct OptPools {
    int scratches;
    int fscratches;
    int int_first;
    int int_count;
    int flt_first;
    int flt_count;
}

fn OptPools opt_pools() {
    int total = sljit_shim_info(0);
    // The baseline frame keeps six registers saved (reg_s(0) to reg_s(5)).
    int scratches = total - 6;
    if (scratches > 20) scratches = 20;
    int fscratches = sljit_shim_info(2);
    if (fscratches > 26) fscratches = 26;
    return {
        .scratches = scratches,
        .fscratches = fscratches,
        .int_first = reg_r(5),
        .int_count = scratches - 5,
        .flt_first = 3,
        .flt_count = fscratches - 2,
    };
}

fn void OptGraph.use(&self, uint node, uint at) @inline {
    if (node == NO_NODE) return;
    OptNode* n = &self.nodes[node];
    if (n.last_use < at) n.last_use = at;
}

fn bool OptNode.allocated(&self) @inline {
    return self.rep != OptRep.NONE && !self.is_const();
}

// Compute each value's last use: operands, the registers an exit or a GENERIC
// reads, the edge moves at the end of a block, and, for a value live into a
// loop, the loop's end.
fn void OptGraph.compute_uses(&self) {
    uint count = (uint)self.nodes.len();
    for (uint i = 0; i < count; i++) self.nodes[i].last_use = i;
    for (uint i = 0; i < count; i++) {
        OptNode* n = &self.nodes[i];
        self.use(n.a, i);
        self.use(n.b, i);
        for (uint k = 0; k < n.dirty_count; k++) self.use(self.dirty[(sz)(n.dirty_first + k)].node, i);
        for (uint k = 0; k < n.reload_count; k++) self.use(self.dirty[(sz)(n.reload_first + k)].node, i);
    }
    foreach (&blk : self.blocks) {
        for (uint e = 0; e < blk.succ_count; e++) {
            for (uint k = 0; k < blk.move_count[e]; k++) {
                OptMove m = self.moves[(sz)(blk.move_first[e] + k)];
                self.use(m.src, blk.end - 1);
                self.use(m.dst, blk.end - 1);
            }
        }
    }
    // The nodes an entry from baseline code loads are all live together once the
    // block's phis are defined.
    foreach (&blk : self.blocks) {
        if (!blk.osr) continue;
        uint point = blk.first;
        while (point + 1 < blk.end && self.nodes[point].op == OptOp.PHI) point++;
        for (uint k = 0; k < blk.osr_count; k++) self.use(self.dirty[(sz)(blk.osr_first + k)].node, point);
    }
    foreach (&blk : self.blocks) {
        if (!blk.header) continue;
        uint end = self.blocks[(sz)blk.loop_end].end - 1;
        for (uint i = 0; i < blk.end; i++) {
            OptNode* n = &self.nodes[i];
            if (!n.allocated()) continue;
            bool phi_here = n.op == OptOp.PHI && i >= blk.first;
            if ((i < blk.first && n.last_use >= blk.first) || phi_here) {
                if (n.last_use < end) n.last_use = end;
            }
        }
    }
}

// Assign machine registers. False when a phi finds no register to take.
fn bool OptGraph.allocate(&self, OptPools* pools) {
    self.compute_uses();
    uint count = (uint)self.nodes.len();
    List{uint} active;
    active.init(mem);
    defer active.free();
    bool[32] ifree;
    bool[32] ffree;
    for (int k = 0; k < pools.int_count; k++) ifree[k] = true;
    for (int k = 0; k < pools.flt_count; k++) ffree[k] = true;
    for (uint i = 0; i < count; i++) {
        OptNode* n = &self.nodes[i];
        // Expire.
        for (sz k = 0; k < active.len();) {
            OptNode* a = &self.nodes[active[k]];
            if (a.last_use <= i) {
                if (a.rep == OptRep.INT32) { ifree[a.reg - pools.int_first] = true; } else { ffree[a.reg - pools.flt_first] = true; }
                active.remove_at(k);
            } else {
                k++;
            }
        }
        if (!n.allocated()) continue;
        bool is_int = n.rep == OptRep.INT32;
        bool* free = is_int ? &ifree[0] : &ffree[0];
        int first = is_int ? pools.int_first : pools.flt_first;
        int total = is_int ? pools.int_count : pools.flt_count;
        int found = -1;
        for (int k = 0; k < total; k++) if (free[k]) { found = k; break; }
        if (found >= 0) {
            free[found] = false;
            n.reg = first + found;
            active.push(i);
            continue;
        }
        // Spill the unprotected value with the furthest last use.
        sz victim = active.len();
        uint furthest = 0;
        for (sz k = 0; k < active.len(); k++) {
            OptNode* a = &self.nodes[active[k]];
            if (a.rep != n.rep || a.op == OptOp.PHI) continue;
            if (victim == active.len() || a.last_use > furthest) { victim = k; furthest = a.last_use; }
        }
        if (n.op != OptOp.PHI && (victim == active.len() || n.last_use >= furthest)) {
            n.reg = -1;
            continue;
        }
        if (victim == active.len()) return false;
        OptNode* v = &self.nodes[active[victim]];
        n.reg = v.reg;
        v.reg = -1;
        active.remove_at(victim);
        active.push(i);
    }
    return true;
}
