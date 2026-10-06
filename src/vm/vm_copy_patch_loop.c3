module boomkat::vm;

import boomkat::types;
import boomkat::bytecode;
import boomkat::heap;
import boomkat::hobject;

alias CopyPatchLoopFn = fn void(double* inputs, double* outputs, uint iterations);
struct CopyPatchLoop {
    CopyPatchLoopFn entry;
    Instruction* branch;
    Instruction* call;
    CompiledFunction* callee;
    uint reads;
    uint writes;
}
struct LoopBuilder {
    CopyPatchOp[128] ops;
    uint count;
    uint reads;
    uint writes;
    uint[16] write_count;
    bool failed;
}
ulong g_copy_patch_loop_compiles @feat(PROTO_REGION_STATS);
ulong g_copy_patch_loop_iterations @feat(PROTO_REGION_STATS);

fn void LoopBuilder.emit(&self, uint kind, uint dst, uint left, uint right, double constant) {
    if (self.count == 128 || dst >= 24) { self.failed = true; return; }
    self.ops[self.count++] = (CopyPatchOp){kind, dst, left, right, constant};
}
fn void LoopBuilder.read(&self, uint reg) {
    if (reg >= 24) { self.failed = true; return; }
    if (reg < 16 && (self.writes & (1u << reg)) == 0) self.reads |= 1u << reg;
}
fn void LoopBuilder.write(&self, uint reg) {
    if (reg >= 24) { self.failed = true; return; }
    if (reg < 16) { self.writes |= 1u << reg; self.write_count[reg]++; }
}
fn void LoopBuilder.move(&self, uint dst, uint source) {
    self.read(source);
    self.write(dst);
    self.emit(8, dst, source, 0, 0);
}
fn void LoopBuilder.constant(&self, uint dst, double value) {
    self.write(dst);
    self.emit(6, dst, 0, 0, value);
}
fn bool LoopBuilder.numeric(&self, Instruction ins, uint dst, uint left, uint right) {
    uint kind;
    bool immediate = false;
    switch (ins.op) {
        case ADD: case ADD_FUSED: kind = 2;
        case SUB: kind = 3;
        case MUL: kind = 4;
        case DIV: kind = 5;
        case ADDI: kind = 2; immediate = true;
        case SUBI: kind = 3; immediate = true;
        case MULI: kind = 4; immediate = true;
        default: return false;
    }
    self.read(left);
    if (immediate) {
        if ((ichar)ins.c == 1) { right = 23; }
        else { self.emit(6, 22, 0, 0, (double)(ichar)ins.c); right = 22; }
    } else { self.read(right); }
    self.write(dst);
    self.emit(kind, dst, left, right, 0);
    return true;
}

fn CompiledFunction* cp_loop_callee(Instruction* pc, TVal* regs, ColdCtx* cold) {
    hobject::VarICEntry* cache;
    if (pc.op == Opcode.CALL_VAR) { cache = th_var_ic_hit(pc, cold); }
    else if (pc.op == Opcode.CALL_GLOBAL) { cache = th_global_ic_hit(pc, cold); }
    else { return null; }
    if (cache == null || cache.prop_flags.is_accessor) return null;
    TVal callee = cache.slot_ptr.get();
    CompiledFunction* target = th_lean_target(cold.vm, callee, regs + pc.a + 2, true);
    if (target == null || !target.ignores_this() || target.num_regs > 6
        || target.num_args > pc.b || target.code_count > 24 || target.flags.has_rest) return null;
    return target;
}

fn bool LoopBuilder.inline_call(&self, CompiledFunction* callee, Instruction call) {
    uint[6] map;
    for (uint i = 0; i < 6; i++) map[i] = i < callee.num_args ? call.a + 2 + i : 0xFFFFFFFF;
    for (uint i = 0; i < callee.code_count; i++) {
        Instruction ins = callee.code[i];
        if (ins.op == Opcode.RET) {
            if (map[ins.a] == 0xFFFFFFFF) return false;
            self.move(call.a, map[ins.a]);
            return !self.failed;
        }
        if (ins.a < callee.num_args) return false;
        uint dst = 16 + ins.a;
        switch (ins.op) {
            case LDINT: self.constant(dst, (double)ins.get_sbc());
            case LDCONST:
                TVal value = callee.constants[ins.get_bc()];
                if (!value.is_numeric()) return false;
                self.constant(dst, value.is_fastint() ? (double)value.get_fastint() : value.get_number());
            case LDREG:
                if (map[ins.b] == 0xFFFFFFFF) return false;
                self.move(dst, map[ins.b]);
            default:
                if (ins.b >= 6 || map[ins.b] == 0xFFFFFFFF) return false;
                bool immediate = ins.op == Opcode.ADDI || ins.op == Opcode.SUBI || ins.op == Opcode.MULI;
                if (!immediate && (ins.c >= 6 || map[ins.c] == 0xFFFFFFFF)) return false;
                if (!self.numeric(ins, dst, map[ins.b], immediate ? 22 : map[ins.c])) return false;
        }
        map[ins.a] = dst;
    }
    return false;
}

fn CopyPatchLoop* cp_loop_compile(Instruction* branch, TVal* regs, ColdCtx* cold) @feat(PROTO_COPY_PATCH_LOOPS) {
    CompiledFunction* function = cold.vm.current_func;
    if (function.num_regs > 16 || branch.op != Opcode.JMP_LT || (ichar)branch.a >= 0) return null;
    Instruction* start = branch + 1 + (int)(ichar)branch.a;
    if (start < function.code || branch - start > 48) return null;
    Instruction last = branch[-1];
    bool increment = (last.op == Opcode.INC_LT || last.op == Opcode.INC) && last.a == branch.b;
    increment = increment || (last.op == Opcode.ADDI && last.a == branch.b && last.b == branch.b && last.c == 1);
    if (!increment) return null;
    LoopBuilder builder;
    Instruction* call = null;
    CompiledFunction* callee = null;
    for (Instruction* pc = start; pc < branch && !builder.failed; pc++) {
        Instruction ins = *pc;
        switch (ins.op) {
            case LDINT: builder.constant(ins.a, (double)ins.get_sbc());
            case LDCONST:
                TVal value = function.constants[ins.get_bc()];
                if (!value.is_numeric()) return null;
                builder.constant(ins.a, value.is_fastint() ? (double)value.get_fastint() : value.get_number());
            case LDREG: builder.move(ins.a, ins.b);
            case INC: case INC_LT:
                builder.read(ins.a);
                builder.write(ins.a);
                builder.emit(2, ins.a, ins.a, 23, 0);
            case CALL_VAR: case CALL_GLOBAL:
                if (call != null) return null;
                callee = cp_loop_callee(pc, regs, cold);
                if (callee == null || !builder.inline_call(callee, ins)) return null;
                call = pc;
            default:
                if (!builder.numeric(ins, ins.a, ins.b, ins.c)) return null;
        }
    }
    if (builder.failed || builder.write_count[branch.b] != 1 || (builder.writes & (1u << branch.c)) != 0) return null;
    CopyPatchOp[192] ops;
    uint count = 0;
    for (uint i = 0; i < 16; i++) {
        if ((builder.reads & (1u << i)) != 0) ops[count++] = (CopyPatchOp){1, i, i, 0, 0};
    }
    ops[count++] = (CopyPatchOp){6, 23, 0, 0, 1};
    bool[128] hoisted;
    for (uint i = 0; i < builder.count; i++) {
        CopyPatchOp op = builder.ops[i];
        if (op.kind == 6 && op.dst < 16 && builder.write_count[op.dst] == 1
            && (builder.reads & (1u << op.dst)) == 0) {
            ops[count++] = op;
            hoisted[i] = true;
        }
    }
    ops[count++] = (CopyPatchOp){9, 0, 0, 0, 0};
    for (uint i = 0; i < builder.count; i++) { if (!hoisted[i]) ops[count++] = builder.ops[i]; }
    ops[count++] = (CopyPatchOp){10, 0, 0, 0, 0};
    for (uint i = 0; i < 16; i++) {
        if ((builder.writes & (1u << i)) != 0) ops[count++] = (CopyPatchOp){7, i, i, 0, 0};
    }
    Heap* heap = cold.heap;
    CopyPatchLoop* plan = (CopyPatchLoop*)heap.alloc_func(heap.heap_udata, CopyPatchLoop::size);
    if (plan == null) return null;
    *plan = (CopyPatchLoop){ .branch = branch, .call = call, .callee = callee, .reads = builder.reads, .writes = builder.writes };
    plan.entry = (CopyPatchLoopFn)bk_copy_patch_compile((CopyPatchOp*)&ops, count);
    if (plan.entry == null) { heap.free_func(heap.heap_udata, plan); return null; }
    $if $feat(PROTO_REGION_STATS):
        g_copy_patch_loop_compiles++;
    $endif
    return plan;
}

fn bool th_copy_patch_loop(Instruction* branch, TVal* regs, ColdCtx* cold) @feat(PROTO_COPY_PATCH_LOOPS) @noinline {
    Heap* heap = cold.heap;
    if (heap.gc_pending || heap.bwd_gc_budget <= 1 || heap.interrupt_due) return false;
    CompiledFunction* function = cold.vm.current_func;
    if (function.copy_patch_loop == null) {
        if (function.copy_patch_loop_calls == 0xFFFFFFFF || ++function.copy_patch_loop_calls < 64) return false;
        function.copy_patch_loop_calls = 0xFFFFFFFF;
        function.copy_patch_loop = cp_loop_compile(branch, regs, cold);
        if (function.copy_patch_loop == null) return false;
    }
    CopyPatchLoop* plan = (CopyPatchLoop*)function.copy_patch_loop;
    if (plan.branch != branch || !regs[branch.b].is_fastint() || !regs[branch.c].is_fastint()) return false;
    long remaining = regs[branch.c].get_fastint() - regs[branch.b].get_fastint();
    if (remaining <= 0) return false;
    uint count = heap.bwd_gc_budget - 1;
    if (count > 256) count = 256;
    if (remaining < count) count = (uint)remaining;
    if (heap.capi_interrupt_fn != null && heap.interrupt_budget - 1 < count) count = heap.interrupt_budget - 1;
    if (plan.call != null) {
        if (cp_loop_callee(plan.call, regs, cold) != plan.callee) return false;
        if (cold.call_burst >= TH_CALL_BURST - 1) return false;
        if (TH_CALL_BURST - cold.call_burst - 1 < count) count = TH_CALL_BURST - cold.call_burst - 1;
    }
    if (count == 0) return false;
    double[16] inputs;
    double[16] outputs;
    for (uint i = 0; i < 16; i++) {
        if ((plan.reads & (1u << i)) != 0) {
            if (!th_numeric_operand(&regs[i], &inputs[i])) return false;
        }
        if ((plan.writes & (1u << i)) != 0 && regs[i].is_heap_allocated()) return false;
    }
    plan.entry((double*)&inputs, (double*)&outputs, count);
    for (uint i = 0; i < 16; i++) {
        if ((plan.writes & (1u << i)) != 0) cp_number(&regs[i], outputs[i]);
    }
    heap.bwd_gc_budget -= count - 1;
    if (heap.capi_interrupt_fn != null) heap.interrupt_budget -= count - 1;
    // Returning the batch to the switch fulfils the call-burst yield.
    if (plan.call != null) cold.call_burst = 0;
    $if $feat(PROTO_REGION_STATS):
        g_copy_patch_loop_iterations += count;
    $endif
    return true;
}

fn void copy_patch_loop_free(Heap* heap, CompiledFunction* function) @feat(PROTO_COPY_PATCH_LOOPS) {
    CopyPatchLoop* plan = (CopyPatchLoop*)function.copy_patch_loop;
    if (plan == null) return;
    bk_copy_patch_release((void*)plan.entry);
    heap.free_func(heap.heap_udata, plan);
    function.copy_patch_loop = null;
}

fn Instruction* copy_patch_loop_entry(Instruction* pc, TVal* regs, ColdCtx* cold) @feat(PROTO_COPY_PATCH_LOOPS) {
    CompiledFunction* function = cold.vm.current_func;
    if (function.copy_patch_loop_calls == 0) {
        function.copy_patch_loop_calls = 0xFFFFFFFF;
        if (function.num_regs > 16) return null;
        for (uint i = 1; i < function.code_count; i++) {
            Instruction branch = function.code[i];
            if (branch.op != Opcode.JMP_LT || (ichar)branch.a >= 0) continue;
            Instruction last = function.code[i - 1];
            if (last.a != branch.b) continue;
            bool increment = last.op == Opcode.INC || last.op == Opcode.INC_LT
                || (last.op == Opcode.ADDI && last.b == branch.b && last.c == 1);
            if (!increment) continue;
            function.copy_patch_loop_header = i + 2 + (int)(ichar)branch.a;
            function.copy_patch_loop_branch = i;
            function.copy_patch_loop_calls = 1;
            break;
        }
    }
    if (function.copy_patch_loop_header != (uint)(pc - function.code) + 1) return null;
    Instruction* branch = function.code + function.copy_patch_loop_branch;
    return th_copy_patch_loop(branch, regs, cold) ? branch : null;
}
