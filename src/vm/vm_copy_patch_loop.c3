module boomkat::vm;

import boomkat::types;
import boomkat::bytecode;
import boomkat::heap;
import boomkat::hobject;
import boomkat::env;

alias CopyPatchLoopFn = fn void(double* inputs, double* outputs, uint iterations, double** streams);
struct LoopCell {
    uint owner;
    uint index;
    uint native;
    bool capture;
    bool write;
    bool tagged;
}
struct LoopRead {
    uint root;
    uint parent;
    uint shape;
    uint generation;
    uint slot;
    bool array;
    bool tagged;
    bool boolean;
    bool varying;
}
struct CopyPatchLoop {
    CopyPatchLoopFn entry;
    Instruction* branch;
    Instruction* call;
    CompiledFunction* callee;
    uint reads;
    uint writes;
    uint tagged_reads;
    uint tagged_outputs;
    uint roots;
    uint call_root;
    Instruction* callee_load;
    uint callee_input;
    LoopCell[8] cells;
    uint cell_count;
    LoopRead[8] loads;
    uint load_count;
    bool varying_loads;
}
struct LoopBuilder {
    CopyPatchOp[128] ops;
    uint count;
    uint reads;
    uint writes;
    uint[16] write_count;
    uint tagged;
    uint tagged_reads;
    uint[24] refs;
    bool[24] index_alias;
    uint auxiliary;
    CopyPatchLoop* plan;
    TVal* regs;
    ColdCtx* cold;
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
    if (reg < 16 && (self.writes & (1u << reg)) == 0) {
        self.reads |= 1u << reg;
        if ((self.tagged & (1u << reg)) != 0) self.tagged_reads |= 1u << reg;
    }
}
fn void LoopBuilder.write(&self, uint reg) {
    if (reg >= 24) { self.failed = true; return; }
    self.index_alias[reg] = false;
    if (reg < 16) { self.writes |= 1u << reg; self.write_count[reg]++; }
}
fn void LoopBuilder.move(&self, uint dst, uint source) {
    bool index = self.index_alias[source];
    self.read(source);
    self.write(dst);
    self.index_alias[dst] = index;
    self.tagged = (self.tagged & ~(1u << dst)) | ((self.tagged & (1u << source)) != 0 ? 1u << dst : 0);
    self.refs[dst] = self.refs[source];
    self.emit(8, dst, source, 0, 0);
}
fn void LoopBuilder.constant(&self, uint dst, double value) {
    self.write(dst);
    self.tagged &= ~(1u << dst);
    self.refs[dst] = 0;
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
    if ((self.tagged & (1u << left)) != 0 || (!immediate && (self.tagged & (1u << right)) != 0)) return false;
    self.read(left);
    if (immediate) {
        if ((ichar)ins.c == 1) { right = 23; }
        else { self.emit(6, 22, 0, 0, (double)(ichar)ins.c); right = 22; }
    } else { self.read(right); }
    self.write(dst);
    self.tagged &= ~(1u << dst);
    self.refs[dst] = 0;
    self.emit(kind, dst, left, right, 0);
    return true;
}

fn HObject* cp_loop_function(Instruction* pc, uint root, TVal* regs, ColdCtx* cold, Instruction* load = null) {
    TVal callee;
    if (root < 16) { callee = regs[root]; }
    else {
        Instruction* site = root == 17 ? load : pc;
        if (site == null) return null;
        hobject::VarICEntry* cache = site.op == Opcode.CALL_GLOBAL || site.op == Opcode.GETGLOBAL ? th_global_ic_hit(site, cold) : th_var_ic_hit(site, cold);
        if (cache == null || cache.prop_flags.is_accessor) return null;
        callee = cache.slot_ptr.get();
    }
    if (!callee.is_object()) return null;
    HObject* function = (HObject*)callee.get_heapptr();
    if (function == null || !function.is_callable() || function.callable_kind() != hobject::CallableKind.COMPILED_FN) return null;
    return function;
}

fn CompiledFunction* cp_loop_callee(Instruction* pc, uint root, TVal* regs, ColdCtx* cold, Instruction* load = null) {
    HObject* function = cp_loop_function(pc, root, regs, cold, load);
    if (function == null) return null;
    CompiledFunction* target = (*function.extra_ptr()).func.comp_func;
    if (target == null) return null;
    target.classify_lean_call();
    uint nargs = pc.op == Opcode.CALL_UNDEF_THIS ? pc.c : pc.b;
    if (!target.call_flags.lean_plain || !target.ignores_this() || target.num_regs > 12
        || target.num_args > nargs || target.code_count > 48 || target.flags.has_rest) return null;
    return target;
}

fn TVal* loop_cell_slot(LoopCell cell, CopyPatchLoop* plan, TVal* regs, ColdCtx* cold, HObject** stored_owner = null) {
    if (!cell.capture) {
        if (cell.owner >= 16 || !regs[cell.owner].is_object()) return null;
        HObject* owner = (HObject*)regs[cell.owner].get_heapptr();
        if (owner.get_class() != hobject::ObjClass.OBJECT || cell.index >= owner.prop_count) return null;
        if (stored_owner != null) *stored_owner = owner;
        return (TVal*)&owner.prop_values()[cell.index];
    }
    HObject* function = cp_loop_function(plan.call, plan.call_root, regs, cold, plan.callee_load);
    if (function == null) return null;
    HObjectFunction* fields = &(*function.extra_ptr()).func;
    if (fields.comp_func != plan.callee || fields.capture_refs == null || cell.index >= plan.callee.capture_count) return null;
    CaptureRef* ref = &fields.capture_refs[cell.index];
    if (ref.guard_shadow) return null;
    if (ref.is_value) return cell.write ? null : &ref.value;
    if (!ref.is_cell || ref.owner == null || ref.prop_idx >= ref.owner.prop_count) return null;
    if (stored_owner != null) *stored_owner = ref.owner;
    return (TVal*)&ref.owner.prop_values()[ref.prop_idx];
}

fn uint LoopBuilder.cell(&self, LoopCell cell) {
    TVal* slot = loop_cell_slot(cell, self.plan, self.regs, self.cold);
    if (slot == null || env::is_tdz_sentinel(slot) || self.plan.cell_count == 8) {
        self.failed = true; return 0;
    }
    uint native = 24;
    for (uint i = 0; i < self.plan.cell_count; i++) {
        if (loop_cell_slot(self.plan.cells[i], self.plan, self.regs, self.cold) == slot) native = self.plan.cells[i].native;
    }
    if (native == 24) {
        native = self.auxiliary++;
        if (native >= 22) { self.failed = true; return 0; }
        if (!slot.is_numeric()) self.tagged |= 1u << native;
    }
    cell.native = native;
    cell.tagged = !slot.is_numeric();
    self.plan.cells[self.plan.cell_count++] = cell;
    if (!cell.capture) self.plan.roots |= 1u << cell.owner;
    return native;
}

fn bool loop_cell_store(CopyPatchLoop* plan, uint index) {
    if (!plan.cells[index].write) return false;
    for (uint i = 0; i < index; i++) {
        if (plan.cells[i].write && plan.cells[i].native == plan.cells[index].native) return false;
    }
    return true;
}

fn double cp_tag_input(TVal value) {
    $if types::USE_NANBOX:
        return bitcast(value.bits, double);
    $else
        return 0;
    $endif
}
fn TVal cp_tag_output(double value) {
    TVal result;
    $if types::USE_NANBOX:
        result.bits = bitcast(value, ulong);
    $endif
    return result;
}

fn void LoopBuilder.literal(&self, uint dst, TVal value) {
    if (value.is_numeric()) { self.constant(dst, value.is_fastint() ? (double)value.get_fastint() : value.get_number()); }
    else {
        if (value.is_traced()) { self.failed = true; return; }
        self.write(dst);
        self.tagged |= 1u << dst;
        self.refs[dst] = 0;
        self.emit(6, dst, 0, 0, cp_tag_input(value));
    }
}

// Every speculative read is checked before native execution; no user code or
// property writes can run between preparation and consumption of the batch.
fn bool loop_read_value(LoopRead load, TVal receiver, long index, Heap* heap, TVal* out) {
    if (!receiver.is_object()) return false;
    HObject* object = (HObject*)receiver.get_heapptr();
    if (load.array) {
        if (object.get_class() != hobject::ObjClass.ARRAY || object.flags.exotic_proxyobj
            || index < 0 || index >= object.array_used || index >= object.extra.array_length) return false;
        hobject::PropValue* values = object.array_part();
        if (values == null) return false;
        *out = values[index].get();
        // Undefined dense entries need the interpreter's prototype/named lookup.
        return !out.is_undefined();
    }
    if (!hobject::plain_property_object(object) || object.in_dict_mode(heap) || object.shape_id != load.shape
        || object.shape_generation(heap) != load.generation || load.slot >= object.prop_count) return false;
    *out = object.prop_values()[load.slot].get();
    return !env::is_tdz_sentinel(out);
}

fn bool LoopBuilder.sample(&self, uint reference, TVal* out) {
    if (reference > 0 && reference <= 16) { *out = self.regs[reference - 1]; return true; }
    if (reference < 32 || reference - 32 >= self.plan.load_count) return false;
    LoopRead load = self.plan.loads[reference - 32];
    TVal receiver;
    if (!self.sample(load.parent != 0 ? load.parent : load.root + 1, &receiver)) return false;
    long index;
    if (!loop_integer(self.regs[self.plan.branch.b], &index)) return false;
    return loop_read_value(load, receiver, index, self.cold.heap, out);
}

fn bool LoopBuilder.property(&self, uint dst, uint source, CompiledFunction* function, uint pc, bool array) {
    if (source >= 24 || self.refs[source] == 0 || self.plan.load_count == 8) return false;
    uint reference = self.refs[source];
    TVal receiver;
    if (!self.sample(reference, &receiver) || !receiver.is_object()) return false;
    HObject* object = (HObject*)receiver.get_heapptr();
    LoopRead load = { .array = array };
    if (reference < 32) { load.root = reference - 1; self.plan.roots |= 1u << load.root; }
    else { load.parent = reference; }
    if (!array) {
        if (!hobject::plain_property_object(object) || function.ic_entries == null || pc >= function.ic_count) return false;
        hobject::ICEntry* cache = &((hobject::ICEntry*)function.ic_entries)[pc];
        if (cache.shape_id != object.shape_id || cache.shape_gen != object.shape_generation(self.cold.heap)
            || cache.proto != null || cache.prop_flags.is_accessor || cache.prop_idx >= object.prop_count) return false;
        load.shape = cache.shape_id; load.generation = cache.shape_gen; load.slot = cache.prop_idx;
    }
    long index;
    TVal value;
    if (!loop_integer(self.regs[self.plan.branch.b], &index)
        || !loop_read_value(load, receiver, index, self.cold.heap, &value)) return false;
    load.varying = array || (load.parent != 0 && self.plan.loads[load.parent - 32].varying);
    self.plan.varying_loads |= load.varying;
    load.tagged = !value.is_numeric();
    uint stream = self.plan.load_count++;
    self.plan.loads[stream] = load;
    self.write(dst);
    self.tagged = (self.tagged & ~(1u << dst)) | (load.tagged ? 1u << dst : 0);
    self.refs[dst] = 32 + stream;
    self.emit(load.varying ? 13 : 15, dst, stream, 0, 0);
    return true;
}

fn uint LoopBuilder.return_operand(&self, CompiledFunction* callee, uint pc, uint* map) {
    if (pc >= callee.code_count) return 24;
    Instruction ins = callee.code[pc];
    if (ins.op == Opcode.RET && ins.a < 16) return map[ins.a];
    if (pc + 1 >= callee.code_count || callee.code[pc + 1].op != Opcode.RET || callee.code[pc + 1].a != ins.a) return 24;
    if (ins.op == Opcode.GETPROPC || ins.op == Opcode.GETPROPC_CACHED) {
        if (ins.b >= 16 || map[ins.b] >= 24) return 24;
        uint reg = self.auxiliary++;
        if (reg >= 22 || !self.property(reg, map[ins.b], callee, pc, false)) return 24;
        return reg;
    }
    if (ins.op == Opcode.GETCAP) return self.cell((LoopCell){.capture = true, .index = ins.get_bc()});
    if (ins.op == Opcode.LDCONST) {
        uint reg = self.auxiliary++;
        if (reg >= 22) return 24;
        self.literal(reg, callee.constants[ins.get_bc()]);
        return reg;
    }
    return 24;
}

fn bool LoopBuilder.inline_call(&self, CompiledFunction* callee, Instruction call) {
    uint[16] map;
    uint base = call.op == Opcode.CALL_UNDEF_THIS ? call.b : call.a;
    for (uint i = 0; i < 16; i++) map[i] = i < callee.num_args ? base + 2 + i : 0xFFFFFFFF;
    for (uint i = 0; i < callee.code_count; i++) {
        Instruction ins = callee.code[i];
        $if $feat(PROTO_TAGGED_LOOPS):
            if (ins.op == Opcode.IF_FALSE && ins.a < 16 && ins.get_sbc() >= 0) {
                uint condition = map[ins.a];
                if (condition >= 24) return false;
                uint left = self.return_operand(callee, i + 1, &map);
                uint right = self.return_operand(callee, i + 1 + (uint)ins.get_sbc(), &map);
                if (left >= 24 || right >= 24 || ((self.tagged >> left) & 1) != ((self.tagged >> right) & 1)) return false;
                if ((self.tagged & (1u << condition)) != 0) {
                    uint reference = self.refs[condition];
                    if (reference < 32 || reference - 32 >= self.plan.load_count) return false;
                    self.plan.loads[reference - 32].boolean = true;
                }
                self.read(condition); self.read(left); self.read(right); self.write(call.a);
                self.tagged = (self.tagged & ~(1u << call.a)) | ((self.tagged & (1u << left)) != 0 ? 1u << call.a : 0);
                self.refs[call.a] = 0;
                self.emit((self.tagged & (1u << condition)) != 0 ? 14 : 12, call.a, left, right, (double)condition);
                return !self.failed;
            }
        $endif
        if (ins.op == Opcode.RET) {
            if (map[ins.a] == 0xFFFFFFFF) return false;
            self.move(call.a, map[ins.a]);
            return !self.failed;
        }
        if (ins.a >= 16 || ins.a < callee.num_args) return false;
        uint dst = map[ins.a];
        if (dst == 0xFFFFFFFF) { dst = self.auxiliary++; if (dst >= 22) return false; }
        switch (ins.op) {
            case LDINT: self.constant(dst, (double)ins.get_sbc());
            case LDCONST:
                TVal value = callee.constants[ins.get_bc()];
                $if !$feat(PROTO_TAGGED_LOOPS):
                    if (!value.is_numeric()) return false;
                $endif
                self.literal(dst, value);
            case GETPROPC: case GETPROPC_CACHED:
                $if $feat(PROTO_TAGGED_LOOPS):
                    if (ins.b >= 16 || map[ins.b] >= 24 || dst >= 24
                        || !self.property(dst, map[ins.b], callee, i, false)) return false;
                $else
                    return false;
                $endif
            case GETCAP:
                $if $feat(PROTO_TAGGED_LOOPS):
                    uint cell = self.cell((LoopCell){.capture = true, .index = ins.get_bc()});
                    self.move(dst, cell);
                $else
                    return false;
                $endif
            case LDREG:
                if (map[ins.b] == 0xFFFFFFFF) return false;
                self.move(dst, map[ins.b]);
            default:
                if (ins.b >= 16 || map[ins.b] == 0xFFFFFFFF) return false;
                bool immediate = ins.op == Opcode.ADDI || ins.op == Opcode.SUBI || ins.op == Opcode.MULI;
                if (!immediate && (ins.c >= 16 || map[ins.c] == 0xFFFFFFFF)) return false;
                if (!self.numeric(ins, dst, map[ins.b], immediate ? 22 : map[ins.c])) return false;
        }
        map[ins.a] = dst;
    }
    return false;
}

fn CopyPatchLoop* cp_loop_compile(Instruction* branch, TVal* regs, ColdCtx* cold) @feat(PROTO_COPY_PATCH_LOOPS) {
    $if !types::USE_NANBOX && $feat(PROTO_TAGGED_LOOPS):
        return null;
    $endif
    CompiledFunction* function = cold.vm.current_func;
    if (function.num_regs > 16 || branch.op != Opcode.JMP_LT || (ichar)branch.a >= 0) return null;
    Instruction* start = branch + 1 + (int)(ichar)branch.a;
    if (start < function.code || branch - start > 48) return null;
    Instruction last = branch[-1];
    bool increment = (last.op == Opcode.INC_LT || last.op == Opcode.INC) && last.a == branch.b;
    increment = increment || (last.op == Opcode.ADDI && last.a == branch.b && last.b == branch.b && last.c == 1);
    if (!increment) return null;
    CopyPatchLoop draft;
    draft.branch = branch;
    LoopBuilder builder = { .plan = &draft, .regs = regs, .cold = cold, .auxiliary = 16 };
    builder.index_alias[branch.b] = true;
    for (uint i = 0; i < function.num_regs; i++) {
        if (!regs[i].is_numeric()) builder.tagged |= 1u << i;
        if (regs[i].is_object()) builder.refs[i] = i + 1;
    }
    Instruction* call = null;
    CompiledFunction* callee = null;
    for (Instruction* pc = start; pc < branch && !builder.failed; pc++) {
        Instruction ins = *pc;
        if (ins.a >= 16) return null;
        switch (ins.op) {
            case LDINT: builder.constant(ins.a, (double)ins.get_sbc());
            case LDCONST:
                TVal value = function.constants[ins.get_bc()];
                $if !$feat(PROTO_TAGGED_LOOPS):
                    if (!value.is_numeric()) return null;
                $endif
                builder.literal(ins.a, value);
            case LDUNDEF: case LDNULL: case LDTRUE: case LDFALSE:
                $if !$feat(PROTO_TAGGED_LOOPS):
                    return null;
                $endif
                TVal value;
                if (ins.op == Opcode.LDUNDEF) { value.set_undefined(); }
                else if (ins.op == Opcode.LDNULL) { value.set_null(); }
                else { value.set_boolean(ins.op == Opcode.LDTRUE); }
                builder.literal(ins.a, value);
            case GETVAR: case GETGLOBAL:
                $if !$feat(PROTO_TAGGED_LOOPS):
                    return null;
                $endif
                if (draft.callee_load != null) return null;
                hobject::VarICEntry* cache = ins.op == Opcode.GETGLOBAL ? th_global_ic_hit(pc, cold) : th_var_ic_hit(pc, cold);
                if (cache == null || cache.prop_flags.is_accessor) return null;
                TVal value = cache.slot_ptr.get();
                if (!value.is_object() || ((HObject*)value.get_heapptr()).callable_kind() != hobject::CallableKind.COMPILED_FN) return null;
                draft.callee_load = pc;
                draft.callee_input = builder.auxiliary++;
                if (draft.callee_input >= 22) return null;
                builder.tagged |= 1u << draft.callee_input;
                builder.move(ins.a, draft.callee_input);
                builder.refs[ins.a] = 18;
            case GETPROPC: case GETPROPC_CACHED: case GETPROP: case GETPROP_CACHE:
                $if !$feat(PROTO_TAGGED_LOOPS):
                    return null;
                $endif
                bool array = ins.op == Opcode.GETPROP || ins.op == Opcode.GETPROP_CACHE;
                if (array && (ins.c >= 24 || !builder.index_alias[ins.c])) return null;
                if (ins.op == Opcode.GETPROP_CACHE) {
                    // The compiler-owned key scratch is either immediately
                    // overwritten or dead at the loop's return continuation.
                    bool overwritten = pc + 1 < branch && pc[1].op == Opcode.LDREG && pc[1].a == ins.c;
                    bool dead = branch + 1 < function.code + function.code_count
                        && branch[1].op == Opcode.RET && branch[1].a != ins.c;
                    if (ins.c == branch.b || (!overwritten && !dead)) return null;
                    if (!overwritten) {
                        for (Instruction* after = pc + 1; after < branch; after++) {
                            if (after.op == Opcode.INC || after.op == Opcode.INC_LT) continue;
                            if (after.op == Opcode.LDREG && after.b != ins.c && after.a != ins.c) continue;
                            return null;
                        }
                    }
                }
                if (!builder.property(ins.a, ins.b, function, (uint)(pc - function.code), array)) return null;
            case LDREG: builder.move(ins.a, ins.b);
            case BANDI:
                $if !$feat(PROTO_TAGGED_LOOPS):
                    return null;
                $endif
                if (ins.b != branch.b || (builder.tagged & (1u << ins.b)) != 0) return null;
                builder.read(ins.b); builder.write(ins.a);
                builder.tagged &= ~(1u << ins.a); builder.refs[ins.a] = 0;
                builder.emit(11, ins.a, ins.b, ins.c, 0);
            case GETCELL: case SETCELL: case MOVECELL:
                $if !$feat(PROTO_TAGGED_LOOPS):
                    return null;
                $endif
                if (ins.b >= 16 || builder.refs[ins.b] == 0) return null;
                uint cell = builder.cell((LoopCell){ .owner = builder.refs[ins.b] - 1, .index = ins.c, .write = ins.op != Opcode.GETCELL });
                if (ins.op == Opcode.GETCELL) { builder.move(ins.a, cell); }
                else {
                    builder.move(cell, ins.a);
                    if (ins.op == Opcode.MOVECELL) { TVal value; value.set_undefined(); builder.literal(ins.a, value); }
                }
            case INC: case INC_LT:
                if ((builder.tagged & (1u << ins.a)) != 0) return null;
                builder.read(ins.a);
                builder.write(ins.a);
                builder.emit(2, ins.a, ins.a, 23, 0);
            case CALL_VAR: case CALL_GLOBAL: case CALL_UNDEF_THIS:
                if (call != null) return null;
                uint root = 16;
                if (ins.op == Opcode.CALL_UNDEF_THIS) {
                    $if !$feat(PROTO_TAGGED_LOOPS):
                        return null;
                    $endif
                    if (ins.b >= 16 || builder.refs[ins.b] == 0) return null;
                    root = builder.refs[ins.b] - 1;
                    if (root < 16) draft.roots |= 1u << root;
                }
                callee = cp_loop_callee(pc, root, regs, cold, draft.callee_load);
                draft.call = pc; draft.call_root = root; draft.callee = callee;
                if (callee == null || !builder.inline_call(callee, ins)) return null;
                call = pc;
            default:
                if (!builder.numeric(ins, ins.a, ins.b, ins.c)) return null;
        }
    }
    if (builder.failed || builder.write_count[branch.b] != 1 || (builder.writes & (1u << branch.c)) != 0) return null;
    if (draft.load_count != 0) {
        for (uint i = 0; i < draft.cell_count; i++) { if (draft.cells[i].write) return null; }
    }
    if ((draft.roots & builder.writes) != 0) return null;
    $if !types::USE_NANBOX:
        if (builder.tagged_reads != 0 || (builder.tagged & builder.writes) != 0) return null;
    $endif
    CopyPatchOp[192] ops;
    uint count = 0;
    for (uint i = 0; i < 16; i++) {
        if ((builder.reads & (1u << i)) != 0) ops[count++] = (CopyPatchOp){1, i, i, 0, 0};
    }
    if (draft.callee_load != null) ops[count++] = (CopyPatchOp){1, draft.callee_input, draft.callee_input, 0, 0};
    for (uint i = 0; i < draft.cell_count; i++) {
        uint native = draft.cells[i].native;
        ops[count++] = (CopyPatchOp){1, native, native, 0, 0};
    }
    ops[count++] = (CopyPatchOp){6, 23, 0, 0, 1};
    bool[128] hoisted;
    for (uint i = 0; i < builder.count; i++) {
        CopyPatchOp op = builder.ops[i];
        if (op.kind == 15) {
            bool unique = true;
            for (uint j = 0; j < builder.count; j++) {
                if (j != i && builder.ops[j].dst == op.dst && builder.ops[j].kind != 9 && builder.ops[j].kind != 10) unique = false;
            }
            if (unique) { op.kind = 15; ops[count++] = op; hoisted[i] = true; continue; }
        }
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
    for (uint i = 0; i < draft.cell_count; i++) {
        if (loop_cell_store(&draft, i)) { uint native = draft.cells[i].native; ops[count++] = (CopyPatchOp){7, native, native, 0, 0}; }
    }
    Heap* heap = cold.heap;
    CopyPatchLoop* plan = (CopyPatchLoop*)heap.alloc_func(heap.heap_udata, CopyPatchLoop::size);
    if (plan == null) return null;
    *plan = draft;
    plan.branch = branch; plan.call = call; plan.callee = callee;
    plan.reads = builder.reads; plan.writes = builder.writes;
    plan.tagged_reads = builder.tagged_reads; plan.tagged_outputs = builder.tagged;
    plan.entry = (CopyPatchLoopFn)bk_copy_patch_compile((CopyPatchOp*)&ops, count);
    if (plan.entry == null) { heap.free_func(heap.heap_udata, plan); return null; }
    $if $feat(PROTO_REGION_STATS):
        g_copy_patch_loop_compiles++;
    $endif
    return plan;
}

fn bool loop_integer(TVal value, long* integer) {
    if (value.is_fastint()) { *integer = value.get_fastint(); return true; }
    if (!value.is_number()) return false;
    double number = value.get_number();
    if (!(number >= (double)types::FASTINT_MIN && number <= (double)types::FASTINT_MAX)) return false;
    long exact = (long)number;
    if ((double)exact != number) return false;
    *integer = exact;
    return true;
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
    long limit;
    if (plan.branch != branch || !regs[branch.b].is_fastint() || !loop_integer(regs[branch.c], &limit)) return false;
    long remaining = limit - regs[branch.b].get_fastint();
    if (remaining <= 0) return false;
    uint count = heap.bwd_gc_budget - 1;
    if (count > 256) count = 256;
    if (remaining < count) count = (uint)remaining;
    if (heap.capi_interrupt_fn != null && heap.interrupt_budget - 1 < count) count = heap.interrupt_budget - 1;
    if (plan.call != null) {
        if (cp_loop_callee(plan.call, plan.call_root, regs, cold, plan.callee_load) != plan.callee) return false;
        if (cold.call_burst >= TH_CALL_BURST - 1) return false;
        if (TH_CALL_BURST - cold.call_burst - 1 < count) count = TH_CALL_BURST - cold.call_burst - 1;
    }
    if (count == 0) return false;
    double[24] inputs;
    double[24] outputs;
    if (plan.callee_load != null) {
        HObject* callee = cp_loop_function(plan.call, plan.call_root, regs, cold, plan.callee_load);
        if (callee == null) return false;
        TVal value; value.set_object_borrowed(callee);
        if (!th_can_publish(heap, value)) return false;
        inputs[plan.callee_input] = cp_tag_input(value);
    }
    TVal*[8] slots;
    HObject*[8] owners;
    for (uint i = 0; i < plan.cell_count; i++) {
        slots[i] = loop_cell_slot(plan.cells[i], plan, regs, cold, &owners[i]);
        if (slots[i] == null || env::is_tdz_sentinel(slots[i])) return false;
        for (uint j = 0; j < i; j++) {
            if ((slots[i] == slots[j]) != (plan.cells[i].native == plan.cells[j].native)) return false;
        }
        if (plan.cells[i].tagged) {
            if (!th_can_publish(heap, *slots[i])) return false;
            inputs[plan.cells[i].native] = cp_tag_input(*slots[i]);
        }
        else if (!th_numeric_operand(slots[i], &inputs[plan.cells[i].native])) { return false; }
        if (loop_cell_store(plan, i) && !th_can_release(slots[i])) return false;
    }
    for (uint i = 0; i < 16; i++) {
        if ((plan.reads & (1u << i)) != 0) {
            if ((plan.tagged_reads & (1u << i)) != 0) {
                if (!th_can_publish(heap, regs[i])) return false;
                inputs[i] = cp_tag_input(regs[i]);
            }
            else if (!th_numeric_operand(&regs[i], &inputs[i])) { return false; }
        }
        if ((plan.writes & (1u << i)) != 0 && !th_can_release(&regs[i])) return false;
    }
    double[8][256] stream_values @noinit;
    double*[8] streams;
    TVal[8] loaded;
    for (uint i = 0; i < plan.load_count; i++) streams[i] = (double*)&stream_values[i];
    for (uint step = 0; step < (plan.varying_loads ? count : 1) && plan.load_count != 0; step++) {
        for (uint i = 0; i < plan.load_count; i++) {
            LoopRead load = plan.loads[i];
            if (step != 0 && !load.varying) continue;
            TVal receiver = load.parent != 0 ? loaded[load.parent - 32] : regs[load.root];
            if (!loop_read_value(load, receiver, regs[branch.b].get_fastint() + step, heap, &loaded[i])) return false;
            if (load.boolean && !loaded[i].is_boolean()) return false;
            if (load.tagged) {
                if (!th_can_publish(heap, loaded[i])) return false;
                stream_values[i][step] = cp_tag_input(loaded[i]);
            } else if (!th_numeric_operand(&loaded[i], &stream_values[i][step])) { return false; }
        }
    }
    plan.entry((double*)&inputs, (double*)&outputs, count, (double**)&streams);
    TVal[24] results;
    for (uint i = 0; i < 16; i++) {
        if ((plan.writes & (1u << i)) == 0) continue;
        if ((plan.tagged_outputs & (1u << i)) != 0) { results[i] = cp_tag_output(outputs[i]); }
        else { cp_number(&results[i], outputs[i]); }
        th_do_retain(&results[i]);
    }
    for (uint i = 0; i < plan.cell_count; i++) {
        if (!loop_cell_store(plan, i)) continue;
        uint native = plan.cells[i].native;
        if ((plan.tagged_outputs & (1u << native)) != 0) { results[native] = cp_tag_output(outputs[native]); }
        else { cp_number(&results[native], outputs[native]); }
        th_do_retain(&results[native]);
    }
    // Retain every outgoing value before any incoming root is released.
    for (uint i = 0; i < 16; i++) {
        if ((plan.writes & (1u << i)) == 0) continue;
        th_do_release(&regs[i]);
        regs[i] = results[i];
        if (regs[i].is_heap_allocated()) track_heap_store(cold.act, &regs[i], i);
    }
    for (uint i = 0; i < plan.cell_count; i++) {
        if (!loop_cell_store(plan, i)) continue;
        th_do_release(slots[i]);
        heap.store_slot(owners[i], (hobject::PropValue*)slots[i], results[plan.cells[i].native]);
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
