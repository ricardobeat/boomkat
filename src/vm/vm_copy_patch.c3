module boomkat::vm;

import boomkat::bytecode;
import boomkat::types;
import boomkat::hobject;
import boomkat::heap;
import boomkat::env;

const uint CP_ARGUMENT = 1;
const uint CP_CAPTURE = 2;
const uint CP_RECEIVER = 3;
const uint CP_CONSTANT = 4;
const uint CP_UNDEFINED = 5;
const uint CP_PROPERTY = 6;
const uint CP_NATIVE = 7;

alias CopyPatchFn = fn void(double* inputs, double* outputs);
struct CopyPatchOp { uint kind; uint dst; uint left; uint right; double constant; }
struct CopyPatchSource { uint kind; uint index; uint owner_kind; uint owner_index; uint key; uint ic; uint prior_writes; }
struct CopyPatchStore { CopyPatchSource source; uint value; }
struct CopyPatchPlan {
    CopyPatchFn entry;
    CopyPatchSource[24] inputs;
    CopyPatchStore[8] stores;
    uint input_count;
    uint store_count;
    CopyPatchSource result;
}
struct CopyPatchBuilder {
    CopyPatchPlan* plan;
    CopyPatchSource[16] regs;
    CopyPatchOp[64] ops;
    uint[24] input_values;
    uint op_count;
    uint value_count;
    CompiledFunction* target;
    bool failed;
}
extern fn void* bk_copy_patch_compile(CopyPatchOp* ops, uint count);
extern fn void bk_copy_patch_release(void* entry);
ulong g_copy_patch_compiles @feat(PROTO_REGION_STATS);
ulong g_copy_patch_hits @feat(PROTO_REGION_STATS);

fn bool cp_same(CopyPatchSource a, CopyPatchSource b) {
    return a.kind == b.kind && a.index == b.index && a.owner_kind == b.owner_kind
        && a.owner_index == b.owner_index && a.key == b.key;
}

fn void CopyPatchBuilder.emit(&self, CopyPatchOp op) {
    if (self.op_count == 64) { self.failed = true; return; }
    self.ops[self.op_count++] = op;
}

fn uint CopyPatchBuilder.value(&self, CopyPatchSource source) {
    if (source.kind == CP_NATIVE) return source.index;
    if (source.kind == CP_UNDEFINED || source.kind == CP_RECEIVER) { self.failed = true; return 0; }
    for (uint i = 0; i < self.plan.input_count; i++) {
        if (cp_same(self.plan.inputs[i], source)) {
            if (source.prior_writes > self.plan.inputs[i].prior_writes) {
                self.plan.inputs[i].prior_writes = source.prior_writes;
            }
            return self.input_values[i];
        }
    }
    if (self.value_count == 24) { self.failed = true; return 0; }
    uint result = self.value_count++;
    if (source.kind == CP_CONSTANT) {
        TVal value = self.target.constants[source.index];
        if (!value.is_numeric()) { self.failed = true; return 0; }
        self.emit((CopyPatchOp){6, result, 0, 0, value.is_fastint() ? (double)value.get_fastint() : value.get_number()});
    } else {
        if (self.plan.input_count == 24) { self.failed = true; return 0; }
        uint input = self.plan.input_count++;
        self.plan.inputs[input] = source;
        self.emit((CopyPatchOp){1, result, input, 0, 0});
        self.input_values[input] = result;
    }
    return result;
}

fn CopyPatchSource CopyPatchBuilder.property(&self, CopyPatchSource owner, uint key, uint ic) {
    if (owner.kind == CP_PROPERTY || owner.kind == CP_NATIVE || owner.kind == CP_UNDEFINED) self.failed = true;
    return (CopyPatchSource){ .kind = CP_PROPERTY, .owner_kind = owner.kind, .owner_index = owner.index,
                           .key = key, .ic = ic, .prior_writes = self.plan.store_count };
}

fn CopyPatchPlan* cp_compile(Heap* heap, CompiledFunction* target) @feat(PROTO_COPY_PATCH) {
    CopyPatchPlan* plan = (CopyPatchPlan*)heap.alloc_func(heap.heap_udata, CopyPatchPlan::size);
    if (plan == null) return null;
    *plan = (CopyPatchPlan){};
    CopyPatchBuilder builder = { .plan = plan, .target = target };
    for (uint i = 0; i < 16; i++) builder.regs[i] = (CopyPatchSource){ .kind = i < target.num_args ? CP_ARGUMENT : CP_UNDEFINED, .index = i };
    bool returned = false;
    for (uint i = 0; i < target.code_count && !builder.failed && !returned; i++) {
        Instruction ins = target.code[i];
        switch (ins.op) {
            case LDINT:
                if (builder.value_count == 24) { builder.failed = true; break; }
                uint value = builder.value_count++;
                builder.emit((CopyPatchOp){6, value, 0, 0, (double)ins.get_sbc()});
                builder.regs[ins.a] = (CopyPatchSource){CP_NATIVE, value, 0, 0, 0, 0, 0};
            case LDCONST:
                builder.regs[ins.a] = (CopyPatchSource){CP_CONSTANT, ins.get_bc(), 0, 0, 0, 0, 0};
            case LDUNDEF:
                builder.regs[ins.a] = (CopyPatchSource){CP_UNDEFINED, 0, 0, 0, 0, 0, 0};
            case LDREG:
                builder.regs[ins.a] = builder.regs[ins.b];
            case LDTHIS:
                builder.regs[ins.a] = (CopyPatchSource){CP_RECEIVER, 0, 0, 0, 0, 0, 0};
            case GETCAP:
                builder.regs[ins.a] = (CopyPatchSource){CP_CAPTURE, ins.get_bc(), 0, 0, 0, 0, 0};
            case GETTHISC: case GETPROPC: case GETPROPC_CACHED:
                CopyPatchSource owner = ins.op == Opcode.GETTHISC ? (CopyPatchSource){CP_RECEIVER, 0, 0, 0, 0, 0, 0} : builder.regs[ins.b];
                CopyPatchSource source = builder.property(owner, ins.c, i);
                bool pending = false;
                for (uint j = 0; j < plan.store_count; j++) {
                    if (cp_same(plan.stores[j].source, source)) {
                        builder.regs[ins.a] = (CopyPatchSource){CP_NATIVE, plan.stores[j].value, 0, 0, 0, 0, 0};
                        pending = true;
                        break;
                    }
                }
                if (!pending) builder.regs[ins.a] = (CopyPatchSource){CP_NATIVE, builder.value(source), 0, 0, 0, 0, 0};
            case PUTTHISC: case PUTPROPC:
                bool on_this = ins.op == Opcode.PUTTHISC;
                CopyPatchSource owner = on_this ? (CopyPatchSource){CP_RECEIVER, 0, 0, 0, 0, 0, 0} : builder.regs[ins.a];
                CopyPatchSource source = builder.property(owner, ins.c, i);
                uint value = builder.value(builder.regs[on_this ? ins.a : ins.b]);
                uint index = 0;
                for (; index < plan.store_count && !cp_same(plan.stores[index].source, source); index++) {}
                if (index == plan.store_count) {
                    if (plan.store_count == 8) { builder.failed = true; break; }
                    plan.store_count++;
                }
                plan.stores[index] = (CopyPatchStore){ source, value };
            case ADD: case ADD_FUSED: case ADDI: case SUB: case SUBI: case MUL: case MULI: case DIV:
                uint left = builder.value(builder.regs[ins.b]);
                uint right;
                bool immediate = ins.op == Opcode.ADDI || ins.op == Opcode.SUBI || ins.op == Opcode.MULI;
                if (immediate) {
                    if (builder.value_count == 24) { builder.failed = true; break; }
                    right = builder.value_count++;
                    builder.emit((CopyPatchOp){6, right, 0, 0, (double)(ichar)ins.c});
                } else { right = builder.value(builder.regs[ins.c]); }
                if (builder.value_count == 24) { builder.failed = true; break; }
                uint value = builder.value_count++;
                uint kind = ins.op == Opcode.ADD || ins.op == Opcode.ADD_FUSED || ins.op == Opcode.ADDI ? 2
                    : ins.op == Opcode.SUB || ins.op == Opcode.SUBI ? 3 : ins.op == Opcode.DIV ? 5 : 4;
                builder.emit((CopyPatchOp){kind, value, left, right, 0});
                builder.regs[ins.a] = (CopyPatchSource){CP_NATIVE, value, 0, 0, 0, 0, 0};
            case RET: case RETUNDEF:
                plan.result = ins.op == Opcode.RET ? builder.regs[ins.a] : (CopyPatchSource){CP_UNDEFINED, 0, 0, 0, 0, 0, 0};
                if (plan.result.kind == CP_NATIVE) builder.emit((CopyPatchOp){7, plan.result.index, 0, 0, 0});
                for (uint j = 0; j < plan.store_count; j++) builder.emit((CopyPatchOp){7, plan.stores[j].value, j + 1, 0, 0});
                returned = true;
            default: builder.failed = true;
        }
    }
    if (!builder.failed && returned) {
        plan.entry = (CopyPatchFn)bk_copy_patch_compile((CopyPatchOp*)&builder.ops, builder.op_count);
    }
    if (plan.entry == null) { heap.free_func(heap.heap_udata, plan); return null; }
    $if $feat(PROTO_REGION_STATS):
        g_copy_patch_compiles++;
    $endif
    return plan;
}

fn bool cp_source(CompiledFunction* target, HObject* function, TVal* args, uint nargs,
                  TVal receiver, CopyPatchSource source, TVal* result) {
    switch (source.kind) {
        case CP_ARGUMENT:
            if (source.index >= nargs) return false;
            *result = args[source.index];
        case CP_CAPTURE:
            HObjectFunction* fields = &(*function.extra_ptr()).func;
            if (fields.capture_refs == null || source.index >= target.capture_count) return false;
            CaptureRef* ref = &fields.capture_refs[source.index];
            if (ref.guard_shadow) return false;
            if (ref.is_value) { *result = ref.value; }
            else {
                if (ref.owner == null || ref.prop_idx >= ref.owner.prop_count) return false;
                *result = ref.owner.prop_values()[ref.prop_idx].get();
            }
            if (env::is_tdz_sentinel(result)) return false;
        case CP_RECEIVER: *result = receiver;
        case CP_CONSTANT: *result = target.constants[source.index];
        case CP_UNDEFINED: result.set_undefined();
        default: return false;
    }
    return true;
}

fn hobject::PropValue* cp_slot(ColdCtx* cold, CompiledFunction* target, HObject* function,
                             TVal* args, uint nargs, TVal receiver, CopyPatchSource source, bool write) {
    TVal owner;
    if (!cp_source(target, function, args, nargs, receiver,
        (CopyPatchSource){ source.owner_kind, source.owner_index , 0, 0, 0, 0, 0}, &owner) || !owner.is_object()) return null;
    HObject* object = (HObject*)owner.get_heapptr();
    if (!hobject::plain_property_object(object)) return null;
    hobject::ICEntry* cache = &((hobject::ICEntry*)target.ic_entries)[source.ic];
    if (cache.key.borrow() != target.constants[source.key].get_heapptr()
        || cache.shape_id != object.shape_id || cache.shape_gen != object.live_shape_generation(cold.heap)
        || cache.prop_flags.is_accessor) return null;
    if (write && (cache.proto != null || !cache.prop_flags.writable || cache.prop_idx == hobject::IC_PROP_ABSENT)) return null;
    return hobject::ic_resolve_value(cache, object);
}

macro void cp_number(TVal* result, double number) {
    if (number >= (double)types::FASTINT_MIN && number <= (double)types::FASTINT_MAX
        && bitcast(number, ulong) != 0x8000000000000000) {
        long integer = (long)number;
        if ((double)integer == number) { result.set_fastint(integer); }
        else { result.set_number(number); }
    } else { result.set_number(number); }
}

fn bool th_copy_patch(ColdCtx* cold, CompiledFunction* target, HObject* function,
                      TVal* args, uint nargs, TVal receiver, TVal* destination, uint result_reg) @feat(PROTO_COPY_PATCH) @noinline {
    if (target.copy_patch == null) {
        if (target.copy_patch_calls == 0xFFFFFFFF) return false;
        if (++target.copy_patch_calls < 64) return false;
        target.copy_patch_calls = 0xFFFFFFFF;
        target.copy_patch = cp_compile(cold.heap, target);
        if (target.copy_patch == null) return false;
    }
    CopyPatchPlan* plan = (CopyPatchPlan*)target.copy_patch;
    double[24] inputs;
    double[9] outputs;
    hobject::PropValue*[8] slots;
    for (uint i = 0; i < plan.store_count; i++) {
        slots[i] = cp_slot(cold, target, function, args, nargs, receiver, plan.stores[i].source, true);
        if (slots[i] == null || !slots[i].get().is_numeric()) return false;
        for (uint j = 0; j < i; j++) { if (slots[i] == slots[j]) return false; }
    }
    for (uint i = 0; i < plan.input_count; i++) {
        CopyPatchSource source = plan.inputs[i];
        TVal value;
        if (source.kind == CP_PROPERTY) {
            hobject::PropValue* slot = cp_slot(cold, target, function, args, nargs, receiver, source, false);
            if (slot == null) return false;
            // A dynamic alias to an earlier store requires the interpreter's sequencing.
            for (uint j = 0; j < source.prior_writes; j++) { if (slot == slots[j]) return false; }
            value = slot.get();
        } else if (!cp_source(target, function, args, nargs, receiver, source, &value)) { return false; }
        if (!value.is_numeric()) return false;
        inputs[i] = value.is_fastint() ? (double)value.get_fastint() : value.get_number();
    }
    TVal result;
    if (plan.result.kind != CP_NATIVE && !cp_source(target, function, args, nargs, receiver, plan.result, &result)) return false;
    if (!th_can_release(destination) || (plan.result.kind != CP_NATIVE && !th_can_publish(cold.heap, result))) return false;
    plan.entry((double*)&inputs, (double*)&outputs);
    if (plan.result.kind == CP_NATIVE) cp_number(&result, outputs[0]);
    th_do_retain(&result);
    for (uint i = 0; i < plan.store_count; i++) {
        TVal value;
        cp_number(&value, outputs[i + 1]);
        *slots[i] = (hobject::PropValue)value;
    }
    th_do_release(destination);
    *destination = result;
    if (result.is_heap_allocated()) track_heap_store(cold.act, destination, result_reg);
    $if $feat(PROTO_REGION_STATS):
        g_copy_patch_hits++;
    $endif
    return true;
}

fn void copy_patch_free(Heap* heap, CompiledFunction* target) @feat(PROTO_COPY_PATCH) {
    CopyPatchPlan* plan = (CopyPatchPlan*)target.copy_patch;
    if (plan == null) return;
    bk_copy_patch_release((void*)plan.entry);
    heap.free_func(heap.heap_udata, plan);
    target.copy_patch = null;
}
