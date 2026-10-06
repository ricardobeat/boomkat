module boomkat::vm;

import boomkat::bytecode;
import boomkat::types;
import boomkat::hobject;
import boomkat::heap;
import boomkat::env;
import std::io;

ulong g_property_region_hits @feat(PROTO_REGION_STATS);
ulong g_property_region_misses @feat(PROTO_REGION_STATS);
ulong g_inline_region_attempts @feat(PROTO_REGION_STATS);
ulong g_inline_region_hits @feat(PROTO_REGION_STATS);

fn void dump_hot_region_stats() @feat(PROTO_REGION_STATS) {
    io::eprintfn("copy_patch: compiles=%s hits=%s", g_copy_patch_compiles, g_copy_patch_hits);
    io::eprintfn("regions: property_hits=%s property_misses=%s inline_attempts=%s inline_hits=%s",
        g_property_region_hits, g_property_region_misses, g_inline_region_attempts, g_inline_region_hits);
}

// Borrowed scratch cannot survive a safepoint. All refusals precede publication
// and all property stores wait until the body and return have been checked.
fn bool th_inline_numeric(ColdCtx* cold, CompiledFunction* target, HObject* function,
                         TVal* args, uint nargs, TVal receiver,
                         TVal* destination, uint result_reg) @feat(PROTO_INLINE_REGIONS) @noinline {
    $if $feat(PROTO_REGION_STATS):
        g_inline_region_attempts++;
    $endif
    TVal[16] values;
    for (uint i = 0; i < target.num_regs; i++) {
        if (i < nargs) { values[i] = args[i]; }
        else { values[i].set_undefined(); }
    }
    hobject::PropValue*[8] store_slots;
    TVal[8] store_values;
    uint store_count = 0;
    HObjectFunction* fields = &(*function.extra_ptr()).func;
    hobject::ICEntry* caches = (hobject::ICEntry*)target.ic_entries;
    TVal result;
    bool returned = false;
    for (uint i = 0; i < target.code_count; i++) {
        Instruction ins = target.code[i];
        switch (ins.op) {
            case LDINT:
                values[ins.a].set_fastint((long)ins.get_sbc());
            case LDUNDEF:
                values[ins.a].set_undefined();
            case LDCONST:
                values[ins.a] = target.constants[ins.get_bc()];
            case LDREG:
                values[ins.a] = values[ins.b];
            case LDTHIS:
                values[ins.a] = receiver;
            case GETCAP:
                uint index = ins.get_bc();
                if (fields.capture_refs == null || index >= target.capture_count) return false;
                CaptureRef* ref = &fields.capture_refs[index];
                if (ref.guard_shadow) return false;
                if (ref.is_value) { values[ins.a] = ref.value; }
                else {
                    if (ref.owner == null || ref.prop_idx >= ref.owner.prop_count) return false;
                    values[ins.a] = ref.owner.prop_values()[ref.prop_idx].get();
                }
                if (env::is_tdz_sentinel(&values[ins.a])) return false;
            case GETTHISC: case GETPROPC: case GETPROPC_CACHED:
            case PUTTHISC: case PUTPROPC:
                bool write = ins.op == Opcode.PUTTHISC || ins.op == Opcode.PUTPROPC;
                bool this_access = ins.op == Opcode.GETTHISC || ins.op == Opcode.PUTTHISC;
                TVal base = this_access ? receiver : values[write ? ins.a : ins.b];
                if (!base.is_object()) return false;
                HObject* object = (HObject*)base.get_heapptr();
                if (!hobject::plain_property_object(object)) return false;
                hobject::ICEntry* cache = &caches[i];
                if (cache.key.borrow() != target.constants[ins.c].get_heapptr()
                    || cache.shape_id != object.shape_id
                    || cache.shape_gen != object.live_shape_generation(cold.heap)
                    || cache.prop_flags.is_accessor) return false;
                if (write && (cache.proto != null || !cache.prop_flags.writable
                    || cache.prop_idx == hobject::IC_PROP_ABSENT)) return false;
                hobject::PropValue* slot = hobject::ic_resolve_value(cache, object);
                if (slot == null) return false;
                uint pending = 0;
                for (; pending < store_count && store_slots[pending] != slot; pending++) {}
                if (write) {
                    TVal value = values[this_access ? ins.a : ins.b];
                    if (!value.is_numeric() || !slot.get().is_numeric()) return false;
                    if (pending == store_count) {
                        if (store_count == 8) return false;
                        store_slots[store_count++] = slot;
                    }
                    store_values[pending] = value;
                } else {
                    values[ins.a] = pending < store_count ? store_values[pending] : slot.get();
                }
            case ADD: case ADD_FUSED: case ADDI: case SUB: case SUBI:
            case MUL: case MULI: case DIV:
                TVal left = values[ins.b];
                TVal right;
                bool immediate = ins.op == Opcode.ADDI || ins.op == Opcode.SUBI || ins.op == Opcode.MULI;
                if (immediate) { right.set_fastint((long)(ichar)ins.c); }
                else { right = values[ins.c]; }
                if (!left.is_numeric() || !right.is_numeric()) return false;
                bool add = ins.op == Opcode.ADD || ins.op == Opcode.ADD_FUSED || ins.op == Opcode.ADDI;
                bool subtract = ins.op == Opcode.SUB || ins.op == Opcode.SUBI;
                if (left.is_fastint() && right.is_fastint() && (add || subtract)) {
                    long l = left.get_fastint();
                    long r = right.get_fastint();
                    values[ins.a].set_fastint_or_number(add ? l + r : l - r);
                } else {
                    double l = left.is_fastint() ? (double)left.get_fastint() : left.get_number();
                    double r = right.is_fastint() ? (double)right.get_fastint() : right.get_number();
                    double value;
                    if (add) { value = l + r; }
                    else if (subtract) { value = l - r; }
                    else if (ins.op == Opcode.DIV) { value = l / r; }
                    else { value = l * r; }
                    values[ins.a].set_number(value);
                }
            case RET: case RETUNDEF:
                if (ins.op == Opcode.RET) { result = values[ins.a]; }
                else { result.set_undefined(); }
                returned = true;
            default:
                return false;
        }
        if (returned) break;
    }
    if (!returned || !th_can_publish(cold.heap, result) || !th_can_release(destination)) return false;
    th_do_retain(&result);
    for (uint i = 0; i < store_count; i++) *store_slots[i] = (hobject::PropValue)store_values[i];
    th_do_release(destination);
    *destination = result;
    if (result.is_heap_allocated()) track_heap_store(cold.act, destination, result_reg);
    $if $feat(PROTO_REGION_STATS):
        g_inline_region_hits++;
    $endif
    return true;
}
