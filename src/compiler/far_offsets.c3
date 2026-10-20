module boomkat::compiler;

import boomkat::bytecode;
import boomkat::heap;

// ============================================================================
// Far branch widening
// ============================================================================

// Give every conditional branch and TRY catch offset that does not fit its
// 16-bit field a WIDE prefix, whose C byte carries the offset's bits 16-23. Inserting a prefix moves the code after it, which can push another
// branch out of range, so the layout is recomputed until no branch grows.
// Every offset is then rewritten against the new layout. The optimization
// passes never see this stream: recording a far offset set has_wide.
fn void? CompilerContext.widen_far_offsets(&self) {
    uint n = self.code_count;
    Heap* h = (Heap*)self.heap;
    // target[i]: the old index an IF_TRUE / IF_FALSE / TRY catch at i lands on, or -1.
    int* target = (int*)h.alloc_func(h.heap_udata, (usz)n * int::size);
    // start[i]: the new index of the first word of old instruction i.
    uint* start = (uint*)h.alloc_func(h.heap_udata, (usz)(n + 1) * uint::size);
    bool* grow = (bool*)h.alloc_func(h.heap_udata, (usz)n);
    defer {
        if (target != null) h.free_func(h.heap_udata, target);
        if (start != null) h.free_func(h.heap_udata, start);
        if (grow != null) h.free_func(h.heap_udata, grow);
    }
    if (target == null || start == null || grow == null) return self.fail("out of memory widening branches")~;
    mem::clear(grow, (sz)n);

    for (uint i = 0; i < n; i++) {
        Instruction ins = self.code[i];
        target[i] = -1;
        switch (ins.op) {
            case Opcode.IF_TRUE:
            case Opcode.IF_FALSE:
                target[i] = (int)i + 1 + ins.get_sbc();
            case Opcode.TRY:
                if ((ins.a & 1) != 0) target[i] = (int)(i + ins.get_bc());
            default:
        }
    }
    foreach (far : self.far_offsets) target[far.addr] = (int)far.target;

    bool changed = true;
    while (changed) {
        changed = false;
        uint extra = 0;
        for (uint i = 0; i < n; i++) {
            start[i] = i + extra;
            if (grow[i]) extra++;
        }
        start[n] = n + extra;
        for (uint i = 0; i < n; i++) {
            if (target[i] < 0 || grow[i] || (i > 0 && self.code[i - 1].op == Opcode.WIDE)) continue;
            long offset = (long)start[(uint)target[i]] - (long)start[i];
            if (self.code[i].op != Opcode.TRY) {
                offset--;
                // A prefix carries forward offsets only. A back-edge is emitted
                // narrow or as a JUMP, and only prefixes inside its span push it out.
                if (offset < bytecode::MIN_SBC) return self.fail("function too large: a loop branches back too far")~;
            }
            if (offset > (self.code[i].op == Opcode.TRY ? 0xFFFF : bytecode::MAX_SBC)) {
                grow[i] = true;
                changed = true;
            }
        }
    }

    uint new_count = start[n];
    if (new_count > MAX_CODE_HARD) return self.fail("function too large (bytecode limit exceeded)")~;
    Instruction* code = (Instruction*)h.alloc_func(h.heap_udata, (usz)new_count * Instruction::size);
    SourcePosition* positions = null;
    if (self.source_positions != null) {
        positions = (SourcePosition*)h.alloc_func(h.heap_udata, (usz)new_count * SourcePosition::size);
    }
    if (code == null || (self.source_positions != null && positions == null)) {
        if (code != null) h.free_func(h.heap_udata, code);
        if (positions != null) h.free_func(h.heap_udata, positions);
        return self.fail("out of memory widening branches")~;
    }

    for (uint i = 0; i < n; i++) {
        uint pc = start[i];
        if (grow[i]) {
            code[pc] = bytecode::make_wide(0, 0, 0);
            if (positions != null) positions[pc] = self.source_positions[i];
            pc++;
        }
        Instruction ins = self.code[i];
        code[pc] = ins;
        if (positions != null) positions[pc] = self.source_positions[i];
        switch (ins.op) {
            case Opcode.JUMP:
            case Opcode.BREAK:
            case Opcode.CONTINUE:
                uint jump_target = (uint)((int)i + 1 + ins.get_sabc());
                code[pc] = bytecode::make_sabc(ins.op, (int)start[jump_target] - (int)pc - 1);
            case Opcode.IF_TRUE:
            case Opcode.IF_FALSE:
                int offset = (int)start[(uint)target[i]] - (int)pc - 1;
                bytecode::set_code_bc(code, pc, (uint)(offset + (int)bytecode::BC_BIAS));
            case Opcode.TRY:
                if (target[i] >= 0) bytecode::set_code_bc(code, pc, start[(uint)target[i]] - pc);
                uint finally_off = bytecode::try_finally_offset(self.code[i + 1]);
                if (finally_off != 0) {
                    self.code[i + 1] = bytecode::make_finally_slot(start[i + finally_off] - pc);
                }
            default:
        }
    }

    foreach (&offset : self.direct_eval_offsets) *offset = start[*offset];

    h.free_func(h.heap_udata, self.code);
    if (self.source_positions != null) h.free_func(h.heap_udata, self.source_positions);
    self.code = code;
    self.source_positions = positions;
    self.code_count = new_count;
    self.code_cap = new_count;
    self.far_offsets.clear();
}
