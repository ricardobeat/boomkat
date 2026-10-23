module boomkat::vm;

import boomkat::bytecode;
import boomkat::types;
import boomkat::heap;
import boomkat::hobject;
import boomkat::hstring;
import boomkat::builtins;
import boomkat::env;
import boomkat::jit;
import std::io;

// Native chunks cannot allocate or enter JS. Guard exits resume at the failing
// instruction after publishing completed stores and dirty registers.
const uint LOOP_REGS      = 64;
const uint LOOP_OPS       = 128;
const uint LOOP_MEMORY    = 8;
const uint LOOP_BINDINGS  = 16;
const uint LOOP_THIS      = LOOP_REGS + LOOP_BINDINGS;
const usz LOOP_CODE_LIMIT = 1024 * 1024;

alias LoopNative = fn uint(void* state, long budget);
enum LoopMemoryKind : char {
    TYPED,
    DENSE,
    ASCII,
    INTRINSIC
}
struct LoopMemory @feat(SLJIT) {
    TVal source;
    char* data;
    long length;
    TVal method;
}
struct LoopMemorySpec @feat(SLJIT) {
    uint source;
    LoopMemoryKind kind;
    ObjClass cls;
    bool written;
    bool length_read;
    int builtin;
}
struct LoopState @feat(SLJIT) {
    TVal[LOOP_REGS] values;
    LoopMemory[LOOP_MEMORY] memory;
    TVal[LOOP_BINDINGS] bindings;
    ulong dirty;
    long budget;
    double[128] ssa_spill;
}
struct LoopPlan @feat(SLJIT) {
    LoopNative native;
    LoopPlan* next;
    uint begin;
    uint end;
    usz code_bytes;
    LoopMemorySpec[LOOP_MEMORY] memory;
    uint memory_count;
    uint[LOOP_BINDINGS] bindings;
    uint binding_count;
    char[LOOP_OPS] memory_at;
    char[LOOP_OPS] binding_at;
    char[LOOP_OPS] intrinsic_at;
    // General registers hold boxed bits; floating registers hold numeric values.
    // Canonical registers are loop-carried integers: an integral double is
    // rewritten to the fastint representation once at entry.
    ulong canonical;
    bool ssa;
    char[LOOP_REGS] cache;
    char[LOOP_REGS] float_cache;
    ulong hits @if($feat(SLJIT_STATS));
    ulong iterations @if($feat(SLJIT_STATS));
}
struct LoopLink @feat(SLJIT) {
    void* jump;
    uint target;
    bool exit;
    ulong flow;
}
struct LoopEmitter @feat(SLJIT) {
    TemplateEmitter e;
    LoopPlan* plan;
    void*[512] labels;
    LoopLink[2048] links;
    uint link_count;
    bool function_mode;
    FunctionFlow* flow;
}

fn ulong loop_bits(TVal v) @feat(SLJIT) {
    $if types::USE_NANBOX: return v.bits; $else return 0; $endif
}
fn int loop_target(Instruction ins, uint pc) @feat(SLJIT) {
    if (ins.op == Opcode.JUMP) return (int)pc + 1 + ins.get_sabc();
    if (ins.op == Opcode.IF_TRUE || ins.op == Opcode.IF_FALSE) return (int)pc + 1 + ins.get_sbc();
    if ((ins.op >= Opcode.JMP_NLT && ins.op <= Opcode.JMP_SNEQ)
        || (ins.op >= Opcode.JMP_NLTI && ins.op <= Opcode.JMP_SNEQI)) return (int)pc + 1 + (int)(ichar)ins.a;
    return -1;
}
// Lookup must never execute a getter or proxy while gathering native guards.
fn bool loop_lookup(Heap* h, HObject* start, void* key, bool getter, int builtin, TVal* result) @feat(SLJIT) {
    for (uint depth = 0; start != null && depth < hobject::MAX_PROTO_DEPTH; depth++, start = start.prototype) {
        if (start.is_proxy() || start.flags.exotic_module_ns) return false;
        int slot = start.find_prop_idx(key, h);
        if (slot < 0) continue;
        bool accessor = start.get_prop_flags((uint)slot, h).is_accessor;
        if (accessor != getter) return false;
        TVal value = start.prop_values()[slot].get();
        if (accessor) value = hobject::hobject_access_getter(value);
        if (!builtins::regexp_is_builtin(value, builtin)) return false;
        *result = value;
        return true;
    }
    return false;
}
fn bool loop_binding(Instruction* pc, ColdCtx* cold, TVal* result) @feat(SLJIT) {
    if (pc.op == Opcode.GETCAP) {
        hobject::PropValue* value = capture_value_slot(cold.act, pc.get_bc(), cold.heap);
        if (value != null) {
            *result = value.get();
            return !env::is_tdz_sentinel(result);
        }
    } else {
        hobject::VarICEntry* ic = pc.op == Opcode.GETGLOBAL ? th_global_ic_hit(pc, cold) : th_var_ic_hit(pc, cold);
        if (ic != null && !ic.prop_flags.is_accessor) {
            *result = ic.slot_ptr.get();
            return !env::is_tdz_sentinel(result);
        }
    }
    CompiledFunction* cf = cold.vm.current_func;
    uint constant        = pc.get_bc();
    if (pc.op == Opcode.GETCAP) {
        if (constant >= cf.capture_count) return false;
        constant = cf.capture_names[constant];
    }
    if (constant >= cf.const_count || !cf.constants[constant].is_string()) return false;
    void* key           = cf.constants[constant].get_heapptr();
    EnvRecord*[2] heads = { cold.act.lex_env, cold.act.var_env };
    foreach (head : heads) {
        for (EnvRecord* scope = head; scope != null; scope = scope.parent) {
            if (scope.is_with()) return false;
            if (scope.bindings == null) continue;
            if (scope.bindings.is_proxy() || scope.bindings.flags.exotic_module_ns) return false;
            int slot = scope.bindings.find_prop_idx(key, cold.heap);
            if (slot < 0) continue;
            if (scope.bindings.get_prop_flags((uint)slot, cold.heap).is_accessor) return false;
            *result = scope.bindings.prop_values()[slot].get();
            return !env::is_tdz_sentinel(result);
        }
    }
    return false;
}
fn TVal loop_source(uint source, LoopState* state, ColdCtx* cold) @feat(SLJIT) {
    if (source == LOOP_THIS) return cold.act.this_binding;
    return source < LOOP_REGS ? state.values[source] : state.bindings[source - LOOP_REGS];
}
fn int loop_memory(LoopPlan* plan, int source, TVal value) @feat(SLJIT) {
    if (source < 0) return -1;
    for (uint i = 0; i < plan.memory_count; i++) if (plan.memory[i].source == (uint)source) return (int)i;
    if (plan.memory_count == LOOP_MEMORY) return -1;
    LoopMemorySpec spec = { .source = (uint)source };
    if (value.is_string() && !((HString*)value.get_heapptr()).is_symbol()) {
        spec.kind = ASCII;
    } else if (value.is_object()) {
        HObject* object = value.get_heapptr();
        if (object == null || object.is_proxy()) return -1;
        spec.cls = object.get_class();
        if (spec.cls == ARRAY) {
            spec.kind = DENSE;
        } else if (spec.cls >= INT8ARRAY && spec.cls <= FLOAT64ARRAY && spec.cls != UINT8CLAMPEDARRAY
            && spec.cls != FLOAT16ARRAY) {
            spec.kind = TYPED;
        } else if (spec.cls == OBJECT || spec.cls == MATH) {
            spec.kind = INTRINSIC;
        } else {
            return -1;
        }
    } else {
        return -1;
    }
    uint index = plan.memory_count++;
    plan.memory[index] = spec;
    return (int)index;
}
fn bool loop_prepare(LoopPlan* plan, LoopState* state, ColdCtx* cold) @feat(SLJIT) {
    Heap* h = cold.heap;
    for (EnvRecord* scope = cold.act.lex_env; scope != null; scope = scope.parent) if (scope.is_with()) return false;
    for (uint i = 0; i < cold.vm.current_func.num_regs; i++) {
        if (plan.float_cache[i] != 0 && !state.values[i].is_fastint() && !state.values[i].is_number()) return false;
    }
    for (uint i = 0; i < plan.binding_count; i++) {
        if (!loop_binding(cold.vm.current_func.code + plan.bindings[i], cold, &state.bindings[i])) return false;
    }
    for (uint i = 0; i < plan.memory_count; i++) {
        LoopMemorySpec spec = plan.memory[i];
        LoopMemory* memory  = &state.memory[i];
        memory.source = loop_source(spec.source, state, cold);
        if (spec.kind == ASCII) {
            if (!memory.source.is_string()) return false;
            HString* text = memory.source.get_heapptr();
            if (text.is_symbol() || !text.is_ascii()) return false;
            memory.data = text.get_cstr();
            memory.length = text.blen;
            if (spec.builtin != 0 && !loop_lookup(
                h,
                h.string_proto,
                (void*)h.str_intern("charCodeAt"),
                false,
                spec.builtin,
                &memory.method
            )) return false;
            continue;
        }
        if (!memory.source.is_object()) return false;
        HObject* object = memory.source.get_heapptr();
        if (object == null || object.is_proxy() || object.get_class() != spec.cls) return false;
        if (spec.kind == INTRINSIC) {
            if (!loop_lookup(h, object, (void*)h.str_intern("imul"), false, spec.builtin, &memory.method)) return false;
        } else if (spec.kind == DENSE) {
            if (object.flags.has_indexed_named_prop
                || (spec.written && object.flags.has_nondefault_flags)) return false;
            memory.data = (char*)object.array_part();
            uint length = *object.array_len_ptr();
            if (length > object.array_size) return false;
            memory.length = length;
            if (memory.data == null) return false;
        } else {
            HObjectBufferView* view = &(*object.extra_ptr()).view;
            HObject* buffer         = view.buffer;
            if (buffer == null) return false;
            HObjectArrayBuffer* bytes = &(*buffer.extra_ptr()).ab;
            if (bytes.data == null || bytes.resizable || bytes.is_shared
                || (spec.written && bytes.immutable)) return false;
            if (view.byte_offset > bytes.byte_length
                || view.byte_length > bytes.byte_length - view.byte_offset) return false;
            memory.data = bytes.data + view.byte_offset;
            memory.length = (long)(view.byte_length >> builtins::ta_elem_shift(spec.cls));
            if (spec.length_read && !loop_lookup(
                h,
                object,
                h.str(heap::BuiltinStr.LENGTH),
                true,
                (int)builtins::Builtin.TYPEDARRAY_PROTO_LENGTH_GET.ordinal,
                &memory.method
            )) return false;
        }
    }
    return true;
}

fn bool loop_analyze(LoopPlan* plan, uint end, TVal* regs, ColdCtx* cold) @feat(SLJIT) {
    CompiledFunction* cf = cold.vm.current_func;
    int begin            = loop_target(cf.code[end], end);
    if (begin < 0 || begin >= (int)end || end - (uint)begin >= LOOP_OPS || cf.num_regs > LOOP_REGS
        || cf.flags.is_generator
        || cf.flags.is_async
        || cf.flags.has_direct_eval
        || cf.flags.needs_lex_bridge
        || cf.mapped_arguments()) return false;
    plan.begin = (uint)begin;
    plan.end = end;
    LoopState sample;
    for (uint i = 0; i < cf.num_regs; i++) sample.values[i] = regs[i];
    int[LOOP_REGS] origin;
    int[LOOP_REGS] method;
    for (uint i = 0; i < LOOP_REGS; i++) {
        origin[i] = (int)i;
        method[i] = -1;
    }
    uint[LOOP_REGS] frequency;
    ulong integer_required;
    ulong entry_canonical;
    ulong written;
    uint memory_ops;
    for (uint pos = plan.begin; pos <= end; pos++) {
        Instruction ins = cf.code[pos];
        uint at         = pos - plan.begin;
        if (ins.a >= LOOP_REGS || ins.b >= LOOP_REGS) {
            // Branch A and immediates do not name registers.
            if (loop_target(
                ins,
                pos
            ) < 0 && ins.op
                != Opcode.LDINT && ins.op
                    != Opcode.LDCONST && ins.op
                        != Opcode.GETVAR && ins.op != Opcode.GETGLOBAL && ins.op != Opcode.GETCAP) return false;
        }
        int target = loop_target(ins, pos);
        if (target >= 0) {
            if ((uint)target >= cf.code_count || (target <= (int)pos && pos != end)) return false;
            if (ins.op == Opcode.JUMP) continue;
            uint b = ins.op == Opcode.IF_TRUE || ins.op == Opcode.IF_FALSE ? ins.a : ins.b;
            if (b >= cf.num_regs) return false;
            frequency[b]++;
            if (ins.op >= Opcode.JMP_NLT && ins.op <= Opcode.JMP_SNEQ) {
                if (ins.c >= cf.num_regs) return false;
                frequency[ins.c]++;
            }
            continue;
        }
        if (ins.a >= cf.num_regs) return false;
        frequency[ins.a]++;
        switch (ins.op) {
            case NOP: continue;
            case LDREG:
                if (ins.b >= cf.num_regs) return false;
                origin[ins.a] = origin[ins.b];
                method[ins.a] = method[ins.b];
                frequency[ins.b]++;
                written |= 1UL << ins.a;
                continue;
            case LDTHIS:
                origin[ins.a] = (int)LOOP_THIS;
                method[ins.a] = -1;
                continue;
            case GETVAR:
            case GETGLOBAL:
            case GETCAP:

                {
                    if (plan.binding_count == LOOP_BINDINGS) return false;
                    uint id = plan.binding_count++;
                    plan.bindings[id] = pos;
                    if (!loop_binding(cf.code + pos, cold, &sample.bindings[id])) return false;
                    plan.binding_at[at] = (char)(id + 1);
                    origin[ins.a] = (int)(LOOP_REGS + id);
                    method[ins.a] = -1;
                    written |= 1UL << ins.a;
                    continue;
                }
            case GETPROP:
            case GETPROP_CACHE:
            case PUTPROP:

                {
                    bool write = ins.op == Opcode.PUTPROP;
                    uint base  = write ? ins.a : ins.b;
                    uint index = write ? ins.b : ins.c;
                    if (base >= cf.num_regs || index >= cf.num_regs || (write && ins.c >= cf.num_regs)
                        || origin[base] < 0) return false;
                    int memory = loop_memory(plan, origin[base], loop_source((uint)origin[base], &sample, cold));
                    if (memory < 0 || plan.memory[memory].kind == INTRINSIC
                        || plan.memory[memory].kind == ASCII) return false;
                    plan.memory_at[at] = (char)(memory + 1);
                    plan.memory[memory].written |= write;
                    memory_ops++;
                    frequency[base]++;
                    frequency[index]++;
                    integer_required |= (1UL << base) | (1UL << index);
                    if (write) {
                        frequency[ins.c]++;
                        continue;
                    }
                }
            case GETPROPC:
            case GETPROPC_CACHED:

                {
                    if (ins.b >= cf.num_regs || ins.c >= cf.const_count || !cf.constants[ins.c].is_string()
                        || origin[ins.b] < 0) return false;
                    int memory = loop_memory(plan, origin[ins.b], loop_source((uint)origin[ins.b], &sample, cold));
                    if (memory < 0) return false;
                    HString* key = cf.constants[ins.c].get_heapptr();
                    if (key.is_symbol()) return false;
                    String name = (String)key.get_data();
                    if (name == "length" && plan.memory[memory].kind != INTRINSIC) {
                        plan.memory[memory].length_read = true;
                    } else if ((name == "charCodeAt" && plan.memory[memory].kind == ASCII)
                        || (name == "imul" && plan.memory[memory].kind == INTRINSIC)) {
                        plan.memory[memory].builtin = name == "imul" ? (int)builtins::Builtin.MATH_IMUL.ordinal
                            : (int)builtins::Builtin.STRING_PROTO_CHARCODEAT.ordinal;
                        plan.intrinsic_at[at] = 1;
                        plan.memory_at[at] = (char)(memory + 1);
                        origin[ins.a] = -1;
                        method[ins.a] = memory;
                        frequency[ins.b]++;
                        continue;
                    } else {
                        return false;
                    }
                    plan.memory_at[at] = (char)(memory + 1);
                    frequency[ins.b]++;
                }
            case CALL:

                {
                    if ((uint)ins.b + 2 >= cf.num_regs || method[ins.b] < 0) return false;
                    uint memory = (uint)method[ins.b];
                    int builtin = plan.memory[memory].builtin;
                    uint nargs  = builtin == (int)builtins::Builtin.MATH_IMUL.ordinal ? 2 : 1;
                    if (ins.c != nargs || (uint)ins.b + 1 + nargs >= cf.num_regs
                        || origin[(uint)ins.b + 1] != (int)plan.memory[memory].source) return false;
                    plan.memory_at[at] = (char)(memory + 1);
                    memory_ops++;
                    for (uint i = 0; i <= nargs + 1; i++) integer_required |= 1UL << ((uint)ins.b + i);
                    for (uint i = 0; i <= nargs + 1; i++) frequency[(uint)ins.b + i]++;
                }
            case LDTRUE:
            case LDFALSE:
            case LDNULL:
            case LDUNDEF:
                integer_required |= 1UL << ins.a;
            case LDINT:
            case LDCONST:
            case TONUMERIC:
            case INC:
            case INC_LT:
            case DEC:
            case ADD:
            case ADD_FUSED:
            case ADDI:
            case SUB:
            case SUBI:
            case MUL:
            case MULI:
            case DIV:
            case UNM:
            case BNOT:
            case LT:
            case LE:
            case GT:
            case GE:
            case EQ:
            case NEQ:
            case SEQ:
            case SNEQ:
            case BAND:
            case BOR:
            case BXOR:
            case SHL:
            case SHR:
            case USHR:
            case BANDI:
            case BORI:
            case BXORI:
            case SHLI:
            case SHRI:
            case USHRI:
                if (ins.op != Opcode.LDINT && ins.op != Opcode.LDCONST && ins.op != Opcode.LDTRUE
                    && ins.op != Opcode.LDFALSE
                    && ins.op != Opcode.LDNULL
                    && ins.op != Opcode.LDUNDEF
                    && ins.op != Opcode.INC
                    && ins.op != Opcode.INC_LT
                    && ins.op != Opcode.DEC) {
                    if (ins.b >= cf.num_regs) return false;
                    frequency[ins.b]++;
                }
                if (ins.op == Opcode.ADD || ins.op == Opcode.ADD_FUSED || ins.op == Opcode.SUB || ins.op == Opcode.MUL
                    || ins.op == Opcode.DIV
                    || ins.op == Opcode.LT
                    || ins.op == Opcode.LE
                    || ins.op == Opcode.GT
                    || ins.op == Opcode.GE
                    || ins.op == Opcode.EQ
                    || ins.op == Opcode.NEQ
                    || ins.op == Opcode.SEQ
                    || ins.op == Opcode.SNEQ
                    || ins.op == Opcode.BAND
                    || ins.op == Opcode.BOR
                    || ins.op == Opcode.BXOR
                    || ins.op == Opcode.SHL
                    || ins.op == Opcode.SHR
                    || ins.op == Opcode.USHR) {
                    if (ins.c >= cf.num_regs) return false;
                    frequency[ins.c]++;
                }
                if (ins.op == Opcode.LDCONST && ins.get_bc() >= cf.const_count) return false;
            default: return false;
        }
        if (ins.op == Opcode.LT || ins.op == Opcode.LE || ins.op == Opcode.GT || ins.op == Opcode.GE
            || ins.op == Opcode.EQ
            || ins.op == Opcode.NEQ
            || ins.op == Opcode.SEQ
            || ins.op == Opcode.SNEQ) integer_required |= 1UL << ins.a;
        if (ins.op == Opcode.INC || ins.op == Opcode.INC_LT || ins.op == Opcode.DEC) {
            integer_required |= 1UL << ins.a;
            // Only a counter read before its first in-loop definition carries
            // an entry representation worth normalizing.
            if ((written & (1UL << ins.a)) == 0) entry_canonical |= 1UL << ins.a;
        }
        if (ins.op == Opcode.BNOT || ins.op == Opcode.BAND || ins.op == Opcode.BOR || ins.op == Opcode.BXOR
            || ins.op == Opcode.SHL
            || ins.op == Opcode.SHR
            || ins.op == Opcode.USHR
            || ins.op == Opcode.BANDI
            || ins.op == Opcode.BORI
            || ins.op == Opcode.BXORI
            || ins.op == Opcode.SHLI
            || ins.op == Opcode.SHRI
            || ins.op == Opcode.USHRI) {
            integer_required |= (1UL << ins.a) | (1UL << ins.b);
            if (ins.op == Opcode.BAND || ins.op == Opcode.BOR || ins.op == Opcode.BXOR || ins.op == Opcode.SHL
                || ins.op == Opcode.SHR
                || ins.op == Opcode.USHR) integer_required |= 1UL << ins.c;
        }
        origin[ins.a] = -1;
        method[ins.a] = -1;
        written |= 1UL << ins.a;
    }
    plan.canonical = entry_canonical;
    if (memory_ops == 0 || !loop_prepare(plan, &sample, cold)) return false;
    bool floating_memory;
    for (uint i = 0; i < plan.memory_count; i++) {
        if (plan.memory[i].kind == DENSE
            || (plan.memory[i].kind == TYPED && plan.memory[i].cls >= FLOAT32ARRAY)) floating_memory = true;
    }
    for (uint i = 0; i < 4; i++) {
        uint best = LOOP_REGS;
        for (uint j = 0; j < cf.num_regs; j++) {
            if ((integer_required & (1UL << j)) != 0 || (!regs[j].is_number() && !regs[j].is_fastint())
                || (!floating_memory && regs[j].is_fastint())) continue;
            if (best == LOOP_REGS || frequency[j] > frequency[best]) best = j;
        }
        if (best == LOOP_REGS || frequency[best] < 2) break;
        plan.float_cache[best] = (char)(3 + i);
        frequency[best] = 0;
        integer_required |= 1UL << best;
    }
    uint assigned;
    // A canonical counter needs a home so entry can rewrite its
    // representation without touching the interpreter's slot.
    for (uint j = 0; j < cf.num_regs && assigned < 6; j++) {
        if ((plan.canonical & (1UL << j)) == 0) continue;
        plan.cache[j] = (char)(assigned < 4 ? jit::reg_r((int)assigned + 4) : jit::reg_s((int)assigned - 1));
        frequency[j] = 0;
        assigned++;
    }
    for (uint i = assigned; i < 6; i++) {
        uint best;
        for (uint j = 1; j < cf.num_regs; j++) if (frequency[j] > frequency[best]) best = j;
        if (frequency[best] < 2) break;
        plan.cache[best] = (char)(i < 4 ? jit::reg_r((int)i + 4) : jit::reg_s((int)i - 1));
        frequency[best] = 0;
    }
    return true;
}

fn long loop_value_offset(uint reg) @feat(SLJIT) => (long)reg * (long)TVal::size;
fn long loop_memory_offset(uint memory, uint field) @feat(SLJIT) {
    LoopState state;
    LoopMemory* item = &state.memory[memory];
    switch (field) {
        case 0: return (char*)&item.source - (char*)&state;
        case 1: return (char*)&item.data - (char*)&state;
        case 2: return (char*)&item.length - (char*)&state;
        default: return (char*)&item.method - (char*)&state;
    }
}
// Function regions use physical VM slots above the numeric loop tier's
// register budget directly, without enlarging its fixed register caches.
fn int LoopEmitter.cached(&self, uint reg) @feat(SLJIT) => reg < LOOP_REGS ? self.plan.cache[reg] : 0;
fn int LoopEmitter.float_cached(&self, uint reg) @feat(SLJIT) => reg < LOOP_REGS ? self.plan.float_cache[reg] : 0;
fn void LoopEmitter.load(&self, uint reg, int dst) @feat(SLJIT) {
    if (self.flow != null && self.flow.registers[reg] != 0
        && (self.flow.dirty & (1U << ((uint)self.flow.registers[reg] - 3))) != 0) {
        self.float_bits(self.flow.registers[reg], dst);
        return;
    }
    if (self.float_cached(reg) != 0) {
        self.float_bits(self.float_cached(reg), dst);
        return;
    }
    int cached = self.cached(reg);
    self.e.mov(dst, 0, cached != 0 ? cached : jit::SLJIT_MEM | jit::reg_s(0), cached != 0 ? 0 : loop_value_offset(reg));
}
fn void LoopEmitter.store(&self, uint reg, int src, uint pc) @feat(SLJIT) {
    if (self.function_mode) {
        function_store(self, reg, src, pc, true);
        return;
    }
    if (self.float_cached(reg) != 0) {
        self.number(src, 1, pc);
        self.fop(jit::SLJIT_MOV_F64, self.float_cached(reg), 0, 1, 0);
    } else {
        int cached = self.cached(reg);
        self.e.mov(
            cached != 0 ? cached : jit::SLJIT_MEM | jit::reg_s(0),
            cached != 0 ? 0 : loop_value_offset(reg),
            src,
            0
        );
    }
    self.mark(reg);
}
fn void LoopEmitter.mark(&self, uint reg) @feat(SLJIT) {
    self.e.op(jit::SLJIT_OR, jit::reg_s(2), jit::reg_s(2), 0, jit::SLJIT_IMM, (long)(1UL << reg));
}
fn void LoopEmitter.link(&self, void* jump, uint target, bool exit) @feat(SLJIT) {
    if (jump == null || self.link_count == self.links.len) {
        self.e.failed = true;
        return;
    }
    self.links[self.link_count++] = { jump, target, exit, self.flow != null && exit ? self.flow.snapshot() : 0 };
}
fn void LoopEmitter.bind_to(&self, void* jump, void* label) @feat(SLJIT) {
    if (jump != null && label != null) {
        jit::sljit_set_label(jump, label);
    } else {
        self.e.failed = true;
    }
}
fn void LoopEmitter.guard(&self, int condition, int left, long lw, int right, long rw, uint pc) @feat(SLJIT) {
    self.link(self.e.cmp(condition, left, lw, right, rw), pc, true);
}
fn void LoopEmitter.integer(&self, uint reg, int dst, uint pc) @feat(SLJIT) {
    self.load(reg, dst);
    self.e.op(jit::SLJIT_LSHR, jit::reg_r(3), dst, 0, jit::SLJIT_IMM, 48);
    self.guard(jit::SLJIT_NOT_EQUAL, jit::reg_r(3), 0, jit::SLJIT_IMM, (long)types::TAG_FASTINT, pc);
    self.e.op(jit::SLJIT_SHL, dst, dst, 0, jit::SLJIT_IMM, 16);
    self.e.op(jit::SLJIT_ASHR, dst, dst, 0, jit::SLJIT_IMM, 16);
}
fn void LoopEmitter.box(&self, int value) @feat(SLJIT) {
    self.e.op(jit::SLJIT_AND, value, value, 0, jit::SLJIT_IMM, 0x0000FFFFFFFFFFFF);
    self.e.op(jit::SLJIT_OR, value, value, 0, jit::SLJIT_IMM, (long)(types::TAG_FASTINT << 48));
}
fn void LoopEmitter.range(&self, int value, uint pc) @feat(SLJIT) {
    self.e.op(jit::SLJIT_SHL, jit::reg_r(2), value, 0, jit::SLJIT_IMM, 16);
    self.e.op(jit::SLJIT_ASHR, jit::reg_r(2), jit::reg_r(2), 0, jit::SLJIT_IMM, 16);
    self.guard(jit::SLJIT_NOT_EQUAL, value, 0, jit::reg_r(2), 0, pc);
}
fn void LoopEmitter.memory_guard(&self, uint source, uint memory, uint pc) @feat(SLJIT) {
    self.load(source, jit::reg_r(0));
    self.guard(
        jit::SLJIT_NOT_EQUAL,
        jit::reg_r(0),
        0,
        jit::SLJIT_MEM | jit::reg_s(0),
        loop_memory_offset(memory, 0),
        pc
    );
}
fn void LoopEmitter.fop(&self, int op, int dst, long dw, int src, long sw) @feat(SLJIT) {
    if (jit::sljit_emit_fop1(self.e.compiler, op, dst, dw, src, sw) != 0) self.e.failed = true;
}
fn void LoopEmitter.fcopy(&self, int op, int freg, int reg) @feat(SLJIT) {
    if (jit::sljit_emit_fcopy(self.e.compiler, op, freg, reg) != 0) self.e.failed = true;
}
fn void LoopEmitter.number(&self, int reg, int freg, uint pc) @feat(SLJIT) {
    int temp = jit::reg_r(3);
    self.e.op(jit::SLJIT_LSHR, temp, reg, 0, jit::SLJIT_IMM, 48);
    self.guard(jit::SLJIT_GREATER, temp, 0, jit::SLJIT_IMM, (long)types::TAG_FASTINT, pc);
    void* floating = self.e.cmp(jit::SLJIT_NOT_EQUAL, temp, 0, jit::SLJIT_IMM, (long)types::TAG_FASTINT);
    self.e.op(jit::SLJIT_SHL, reg, reg, 0, jit::SLJIT_IMM, 16);
    self.e.op(jit::SLJIT_ASHR, reg, reg, 0, jit::SLJIT_IMM, 16);
    self.fop(jit::SLJIT_CONV_F64_FROM_SW, freg, 0, reg, 0);
    void* done = jit::sljit_emit_jump(self.e.compiler, jit::SLJIT_JUMP);
    self.e.bind(floating);
    self.fcopy(jit::SLJIT_COPY_TO_F64, freg, reg);
    self.e.bind(done);
}
fn void* LoopEmitter.fcmp(&self, int condition, int left, int right) @feat(SLJIT) {
    void* jump = jit::sljit_emit_fcmp(self.e.compiler, condition, left, 0, right, 0);
    if (jump == null) self.e.failed = true;
    return jump;
}
// Rewrite an integral double in a cached counter as the fastint the native
// loop already requires. JS numbers are primitives, so the value is unchanged;
// everything outside the exact 48-bit range exits instead of rounding.
fn void LoopEmitter.canonicalize(&self, int cache, uint pc) @feat(SLJIT) {
    int r0  = jit::reg_r(0);
    int r1  = jit::reg_r(1);
    int r2  = jit::reg_r(2);
    int r3  = jit::reg_r(3);
    int imm = jit::SLJIT_IMM;
    self.e.mov(r0, 0, cache, 0);
    self.e.op(jit::SLJIT_LSHR, r3, r0, 0, imm, 48);
    void* integer = self.e.cmp(jit::SLJIT_EQUAL, r3, 0, imm, (long)types::TAG_FASTINT);
    self.guard(jit::SLJIT_GREATER_EQUAL, r3, 0, imm, (long)types::TAG_FASTINT, pc);
    self.fcopy(jit::SLJIT_COPY_TO_F64, 1, r0);
    self.link(self.fcmp(jit::SLJIT_UNORDERED, 1, 1), pc, true);
    self.e.mov(r1, 0, imm, (long)bitcast((double)types::FASTINT_MIN, ulong));
    self.fcopy(jit::SLJIT_COPY_TO_F64, 2, r1);
    self.link(self.fcmp(jit::SLJIT_ORDERED_LESS, 1, 2), pc, true);
    self.e.mov(r1, 0, imm, (long)bitcast((double)(types::FASTINT_MAX + 1), ulong));
    self.fcopy(jit::SLJIT_COPY_TO_F64, 2, r1);
    self.link(self.fcmp(jit::SLJIT_ORDERED_GREATER_EQUAL, 1, 2), pc, true);
    self.e.op(jit::SLJIT_SHL, r3, r0, 0, imm, 1);
    void* nonzero = self.e.cmp(jit::SLJIT_NOT_EQUAL, r3, 0, imm, 0);
    self.guard(jit::SLJIT_SIG_LESS, r0, 0, imm, 0, pc);
    self.e.bind(nonzero);
    self.fop(jit::SLJIT_CONV_SW_FROM_F64, r2, 0, 1, 0);
    self.fop(jit::SLJIT_CONV_F64_FROM_SW, 2, 0, r2, 0);
    self.link(self.fcmp(jit::SLJIT_ORDERED_NOT_EQUAL, 1, 2), pc, true);
    self.box(r2);
    self.e.mov(cache, 0, r2, 0);
    self.e.bind(integer);
}
fn void LoopEmitter.float_bits(&self, int freg, int dst) @feat(SLJIT) {
    self.fcopy(jit::SLJIT_COPY_FROM_F64, freg, dst);
    self.e.op(jit::SLJIT_LSHR, jit::reg_r(3), dst, 0, jit::SLJIT_IMM, 48);
    void* ordinary = self.e.cmp(jit::SLJIT_LESS, jit::reg_r(3), 0, jit::SLJIT_IMM, (long)types::TAG_FASTINT);
    self.e.mov(dst, 0, jit::SLJIT_IMM, 0x7FF8000000000000L);
    self.e.bind(ordinary);
}
fn void LoopEmitter.float_result(&self, int freg) @feat(SLJIT) => self.float_bits(freg, jit::reg_r(0));
fn void LoopEmitter.number_reg(&self, uint reg, int freg, uint pc) @feat(SLJIT) {
    if (self.float_cached(reg) != 0) {
        self.fop(jit::SLJIT_MOV_F64, freg, 0, self.float_cached(reg), 0);
    } else {
        self.load(reg, jit::reg_r(0));
        self.number(jit::reg_r(0), freg, pc);
    }
}
// Narrow floating inputs convert exactly under ToInt32. Other doubles take
// the interpreter's modulo-2^32 conversion, including infinities and NaNs.
fn void LoopEmitter.int32(&self, uint reg, int dst, uint pc) @feat(SLJIT) {
    self.load(reg, dst);
    int temp = jit::reg_r(3);
    self.e.op(jit::SLJIT_LSHR, temp, dst, 0, jit::SLJIT_IMM, 48);
    void* integer = self.e.cmp(jit::SLJIT_EQUAL, temp, 0, jit::SLJIT_IMM, (long)types::TAG_FASTINT);
    self.guard(jit::SLJIT_GREATER, temp, 0, jit::SLJIT_IMM, (long)types::TAG_FASTINT, pc);
    self.e.op(jit::SLJIT_AND, temp, dst, 0, jit::SLJIT_IMM, 0x7FFFFFFFFFFFFFFFL);
    self.guard(jit::SLJIT_GREATER_EQUAL, temp, 0, jit::SLJIT_IMM, 0x41E0000000000000L, pc);
    self.fcopy(jit::SLJIT_COPY_TO_F64, 1, dst);
    self.fop(jit::SLJIT_CONV_SW_FROM_F64, dst, 0, 1, 0);
    self.e.bind(integer);
    self.e.mov(dst, 0, dst, 0, jit::SLJIT_MOV_S32);
}
fn void LoopEmitter.numeric(&self, Instruction ins, uint pc) @feat(SLJIT) {
    int r0               = jit::reg_r(0);
    int r1               = jit::reg_r(1);
    int r2               = jit::reg_r(2);
    int r3               = jit::reg_r(3);
    int imm              = jit::SLJIT_IMM;
    int op_float         = ins.op == Opcode.SUB || ins.op == Opcode.SUBI ? jit::SLJIT_SUB_F64
        : (ins.op == Opcode.MUL || ins.op == Opcode.MULI ? jit::SLJIT_MUL_F64
            : (ins.op == Opcode.DIV ? jit::SLJIT_DIV_F64 : jit::SLJIT_ADD_F64));
    bool immediate_float = ins.op == Opcode.ADDI || ins.op == Opcode.SUBI || ins.op == Opcode.MULI;
    if (self.float_cached(
        ins.a
    ) != 0 || self.float_cached(ins.b) != 0 || (!immediate_float && self.float_cached(ins.c) != 0)) {
        self.number_reg(ins.b, 1, pc);
        if (immediate_float) {
            self.e.mov(r0, 0, imm, (long)(ichar)ins.c);
            self.fop(jit::SLJIT_CONV_F64_FROM_SW, 2, 0, r0, 0);
        } else {
            self.number_reg(ins.c, 2, pc);
        }
        if (jit::sljit_emit_fop2(self.e.compiler, op_float, 1, 0, 1, 0, 2, 0) != 0) self.e.failed = true;
        if (self.float_cached(ins.a) != 0) {
            self.fop(jit::SLJIT_MOV_F64, self.float_cached(ins.a), 0, 1, 0);
            self.mark(ins.a);
        } else {
            self.float_result(1);
            self.store(ins.a, r0, pc);
        }
        return;
    }
    self.load(ins.b, r0);
    bool immediate = ins.op == Opcode.ADDI || ins.op == Opcode.SUBI || ins.op == Opcode.MULI;
    if (immediate) {
        TVal v;
        v.set_fastint((ichar)ins.c);
        self.e.mov(r1, 0, imm, (long)loop_bits(v));
    } else {
        self.load(ins.c, r1);
    }
    void* floating;
    void* done;
    if (ins.op != Opcode.DIV) {
        self.e.op(jit::SLJIT_XOR, r2, r0, 0, imm, (long)(types::TAG_FASTINT << 48));
        self.e.op(jit::SLJIT_XOR, r3, r1, 0, imm, (long)(types::TAG_FASTINT << 48));
        self.e.op(jit::SLJIT_OR, r2, r2, 0, r3, 0);
        self.e.op(jit::SLJIT_LSHR, r2, r2, 0, imm, 48);
        floating = self.e.cmp(jit::SLJIT_NOT_EQUAL, r2, 0, imm, 0);
        self.e.op(jit::SLJIT_SHL, r0, r0, 0, imm, 16);
        self.e.op(jit::SLJIT_ASHR, r0, r0, 0, imm, 16);
        self.e.op(jit::SLJIT_SHL, r1, r1, 0, imm, 16);
        self.e.op(jit::SLJIT_ASHR, r1, r1, 0, imm, 16);
        int op = ins.op == Opcode.SUB || ins.op == Opcode.SUBI ? jit::SLJIT_SUB
            : (ins.op == Opcode.MUL || ins.op == Opcode.MULI ? jit::SLJIT_MUL : jit::SLJIT_ADD);
        if (op == jit::SLJIT_MUL) {
            self.guard(jit::SLJIT_SIG_LESS, r0, 0, imm, -0x40000000L, pc);
            self.guard(jit::SLJIT_SIG_GREATER, r0, 0, imm, 0x3FFFFFFFL, pc);
            self.guard(jit::SLJIT_SIG_LESS, r1, 0, imm, -0x40000000L, pc);
            self.guard(jit::SLJIT_SIG_GREATER, r1, 0, imm, 0x3FFFFFFFL, pc);
            self.e.op(jit::SLJIT_XOR, r2, r0, 0, r1, 0);
        }
        self.e.op(op, r0, r0, 0, r1, 0);
        if (op == jit::SLJIT_MUL) {
            void* nonzero = self.e.cmp(jit::SLJIT_NOT_EQUAL, r0, 0, imm, 0);
            self.guard(jit::SLJIT_SIG_LESS, r2, 0, imm, 0, pc);
            self.e.bind(nonzero);
        }
        self.range(r0, pc);
        self.box(r0);
        done = jit::sljit_emit_jump(self.e.compiler, jit::SLJIT_JUMP);
        self.e.bind(floating);
    }
    self.number(r0, 1, pc);
    self.number(r1, 2, pc);
    int op = ins.op == Opcode.SUB || ins.op == Opcode.SUBI ? jit::SLJIT_SUB_F64
        : (ins.op == Opcode.MUL || ins.op == Opcode.MULI ? jit::SLJIT_MUL_F64
            : (ins.op == Opcode.DIV ? jit::SLJIT_DIV_F64 : jit::SLJIT_ADD_F64));
    if (jit::sljit_emit_fop2(self.e.compiler, op, 1, 0, 1, 0, 2, 0) != 0) self.e.failed = true;
    self.float_result(1);
    if (done != null) self.e.bind(done);
    self.store(ins.a, r0, pc);
}
fn void*[2] LoopEmitter.condition(&self, Instruction ins, uint pc) @feat(SLJIT) {
    int r0  = jit::reg_r(0);
    int r1  = jit::reg_r(1);
    int r2  = jit::reg_r(2);
    int r3  = jit::reg_r(3);
    int imm = jit::SLJIT_IMM;
    void* skip_integer;
    void* skip_float;
    if (ins.op == Opcode.IF_TRUE || ins.op == Opcode.IF_FALSE) {
        self.load(ins.a, r0);
        self.e.op(jit::SLJIT_LSHR, r3, r0, 0, imm, 48);
        void* boolean = self.e.cmp(jit::SLJIT_EQUAL, r3, 0, imm, (long)types::TAG_BOOLEAN);
        self.guard(jit::SLJIT_NOT_EQUAL, r3, 0, imm, (long)types::TAG_FASTINT, pc);
        self.e.bind(boolean);
        self.e.op(jit::SLJIT_SHL, r0, r0, 0, imm, 16);
        self.e.op(jit::SLJIT_ASHR, r0, r0, 0, imm, 16);
        skip_integer = self.e.cmp(ins.op == Opcode.IF_TRUE ? jit::SLJIT_EQUAL : jit::SLJIT_NOT_EQUAL, r0, 0, imm, 0);
    } else if (ins.op != Opcode.JUMP) {
        self.load(ins.b, r0);
        if (ins.op >= Opcode.JMP_NLTI) {
            TVal v;
            v.set_fastint((ichar)ins.c);
            self.e.mov(r1, 0, imm, (long)loop_bits(v));
        } else {
            self.load(ins.c, r1);
        }
        self.e.op(jit::SLJIT_XOR, r2, r0, 0, imm, (long)(types::TAG_FASTINT << 48));
        self.e.op(jit::SLJIT_XOR, r3, r1, 0, imm, (long)(types::TAG_FASTINT << 48));
        self.e.op(jit::SLJIT_OR, r2, r2, 0, r3, 0);
        self.e.op(jit::SLJIT_LSHR, r2, r2, 0, imm, 48);
        void* floating = self.e.cmp(jit::SLJIT_NOT_EQUAL, r2, 0, imm, 0);
        self.e.op(jit::SLJIT_SHL, r0, r0, 0, imm, 16);
        self.e.op(jit::SLJIT_ASHR, r0, r0, 0, imm, 16);
        self.e.op(jit::SLJIT_SHL, r1, r1, 0, imm, 16);
        self.e.op(jit::SLJIT_ASHR, r1, r1, 0, imm, 16);
        skip_integer = self.e.cmp(loop_condition(ins.op) ^ 1, r0, 0, r1, 0);
        void* take_integer = jit::sljit_emit_jump(self.e.compiler, jit::SLJIT_JUMP);
        self.e.bind(floating);
        self.number(r0, 1, pc);
        self.number(r1, 2, pc);
        uint index         = ins.op >= Opcode.JMP_NLTI ? ins.op.ordinal - Opcode.JMP_NLTI.ordinal
            : ins.op.ordinal - Opcode.JMP_NLT.ordinal;
        // Negated relations include unordered inputs; ordinary relations exclude NaNs.
        int[10] conditions = { 27, 34, 29, 32, 26, 35, 28, 33, 24, 25 };
        skip_float = jit::sljit_emit_fcmp(self.e.compiler, conditions[index] ^ 1, 1, 0, 2, 0);
        if (skip_float == null || take_integer == null) self.e.failed = true;
        self.e.bind(take_integer);
    }
    return { skip_integer, skip_float };
}
fn void LoopEmitter.branch(&self, Instruction ins, uint pc) @feat(SLJIT) {
    void*[2] skips = self.condition(ins, pc);
    int imm        = jit::SLJIT_IMM;
    uint target    = (uint)loop_target(ins, pc);
    if (target <= pc) {
        self.guard(jit::SLJIT_LESS_EQUAL, jit::reg_s(1), 0, imm, 1, pc);
        self.e.op(jit::SLJIT_SUB, jit::reg_s(1), jit::reg_s(1), 0, imm, 1);
    }
    self.link(
        jit::sljit_emit_jump(self.e.compiler, jit::SLJIT_JUMP),
        target,
        target < self.plan.begin || target > self.plan.end
    );
    void* skip = self.e.label();
    foreach (jump : skips) if (jump != null) self.bind_to(jump, skip);
}
fn Opcode loop_compare(Opcode op) @feat(SLJIT) {
    switch (op) {
        case LT: return Opcode.JMP_LT;
        case LE: return Opcode.JMP_LE;
        case GT: return Opcode.JMP_GT;
        case GE: return Opcode.JMP_GE;
        case EQ:
        case SEQ: return Opcode.JMP_SEQ;
        default: return Opcode.JMP_SNEQ;
    }
}
fn int loop_load_op(ObjClass cls) @feat(SLJIT) {
    switch (cls) {
        case INT8ARRAY: return jit::SLJIT_MOV_S8;
        case UINT8ARRAY: return jit::SLJIT_MOV_U8;
        case INT16ARRAY: return jit::SLJIT_MOV_S16;
        case UINT16ARRAY: return jit::SLJIT_MOV_U16;
        case INT32ARRAY: return jit::SLJIT_MOV_S32;
        default: return jit::SLJIT_MOV_U32;
    }
}
fn void LoopEmitter.index(&self, uint reg, uint memory, uint pc) @feat(SLJIT) {
    self.integer(reg, jit::reg_r(1), pc);
    self.guard(
        jit::SLJIT_GREATER_EQUAL,
        jit::reg_r(1),
        0,
        jit::SLJIT_MEM | jit::reg_s(0),
        loop_memory_offset(memory, 2),
        pc
    );
    uint shift = self.plan.memory[memory].kind == DENSE ? 3 : builtins::ta_elem_shift(self.plan.memory[memory].cls);
    if (shift != 0) self.e.op(jit::SLJIT_SHL, jit::reg_r(1), jit::reg_r(1), 0, jit::SLJIT_IMM, shift);
    self.e.mov(jit::reg_r(2), 0, jit::SLJIT_MEM | jit::reg_s(0), loop_memory_offset(memory, 1));
    self.e.op(jit::SLJIT_ADD, jit::reg_r(2), jit::reg_r(2), 0, jit::reg_r(1), 0);
}
fn int loop_condition(Opcode op) @feat(SLJIT) {
    uint index         = op >= Opcode.JMP_NLTI ? op.ordinal - Opcode.JMP_NLTI.ordinal
        : op.ordinal - Opcode.JMP_NLT.ordinal;
    int[10] conditions = { 7, 8, 9, 6, 6, 9, 8, 7, 0, 1 };
    return conditions[index];
}
fn LoopNative loop_emit(LoopPlan* plan, CompiledFunction* cf) @feat(SLJIT) {
    LoopEmitter out    = { .e = { .compiler = jit::sljit_create_compiler(null) }, .plan = plan };
    TemplateEmitter* e = &out.e;
    if (!e.compiler) return null;
    defer jit::sljit_free_compiler(e.compiler);
    if (jit::sljit_emit_enter(e.compiler, 0, jit::SLJIT_ARGS2WWW, 8 | (6 << 8), 5, 0) != 0) return null;
    int r0     = jit::reg_r(0);
    int r1     = jit::reg_r(1);
    int r2     = jit::reg_r(2);
    int r3     = jit::reg_r(3);
    int state  = jit::reg_s(0);
    int budget = jit::reg_s(1);
    int dirty  = jit::reg_s(2);
    int imm    = jit::SLJIT_IMM;
    int mem    = jit::SLJIT_MEM;
    e.mov(state, 0, r0, 0);
    e.mov(budget, 0, r1, 0);
    e.mov(dirty, 0, imm, 0);
    for (uint i = 0; i < cf.num_regs; i++) if (plan.cache[i] != 0) e.mov(
        plan.cache[i],
        0,
        mem | state,
        loop_value_offset(i)
    );
    for (uint i = 0; i < cf.num_regs; i++) if (plan.float_cache[i] != 0) {
        e.mov(r0, 0, mem | state, loop_value_offset(i));
        out.number(r0, plan.float_cache[i], plan.begin);
    }
    for (uint i = 0; i < cf.num_regs; i++) if (plan.cache[i] != 0 && (plan.canonical & (1UL << i)) != 0) {
        out.canonicalize(plan.cache[i], plan.begin);
    }
    for (uint pos = plan.begin; pos <= plan.end; pos++) {
        uint at         = pos - plan.begin;
        Instruction ins = cf.code[pos];
        out.labels[at] = e.label();
        int target = loop_target(ins, pos);
        if (target >= 0) {
            out.branch(ins, pos);
            continue;
        }
        uint memory = plan.memory_at[at] != 0 ? (uint)plan.memory_at[at] - 1 : 0;
        switch (ins.op) {
            case NOP: continue;
            case LDREG: out.load(ins.b, r0);
            case LDTHIS:

                {
                    // LDTHIS only feeds guarded invariant receivers in this tier.
                    int found = -1;
                    for (uint i = 0; i < plan.memory_count; i++) if (plan.memory[i].source == LOOP_THIS) found = (int)i;
                    if (found < 0) return null;
                    e.mov(r0, 0, mem | state, loop_memory_offset((uint)found, 0));
                }
            case LDINT:

                {
                    TVal v;
                    v.set_fastint(ins.get_sbc());
                    e.mov(r0, 0, imm, (long)loop_bits(v));
                }
            case LDTRUE:
            case LDFALSE:
            case LDNULL:
            case LDUNDEF:

                {
                    TVal v;
                    if (ins.op == Opcode.LDTRUE || ins.op == Opcode.LDFALSE) {
                        v.set_boolean(ins.op == Opcode.LDTRUE);
                    } else if (ins.op == Opcode.LDNULL) {
                        v.set_null();
                    } else {
                        v.set_undefined();
                    }
                    e.mov(r0, 0, imm, (long)loop_bits(v));
                }
            case LDCONST: e.mov(r0, 0, imm, (long)loop_bits(cf.constants[ins.get_bc()]));
            case GETVAR:
            case GETGLOBAL:
            case GETCAP:

                {
                    LoopState layout;
                    uint id     = (uint)plan.binding_at[at] - 1;
                    long offset = (char*)&layout.bindings[id] - (char*)&layout;
                    e.mov(r0, 0, mem | state, offset);
                }
            case GETPROPC:
            case GETPROPC_CACHED:
                out.memory_guard(ins.b, memory, pos);
                e.mov(r0, 0, mem | state, loop_memory_offset(memory, plan.intrinsic_at[at] != 0 ? 3 : 2));
                if (plan.intrinsic_at[at] == 0) out.box(r0);
            case GETPROP:
            case GETPROP_CACHE:
                out.memory_guard(ins.b, memory, pos);
                out.index(ins.c, memory, pos);
                if (plan.memory[memory].kind == TYPED && plan.memory[memory].cls >= FLOAT32ARRAY) {
                    bool small = plan.memory[memory].cls == FLOAT32ARRAY;
                    out.fop(jit::SLJIT_MOV_F64 | (small ? jit::SLJIT_32 : 0), 1, 0, mem | r2, 0);
                    if (small) out.fop(jit::SLJIT_CONV_F64_FROM_F32, 1, 0, 1, 0);
                    out.float_result(1);
                } else {
                    e.mov(
                        r0,
                        0,
                        mem | r2,
                        0,
                        plan.memory[memory].kind == DENSE ? jit::SLJIT_MOV : loop_load_op(plan.memory[memory].cls)
                    );
                    if (plan.memory[memory].kind == DENSE) {
                        e.op(jit::SLJIT_LSHR, r3, r0, 0, imm, 48);
                        out.guard(jit::SLJIT_EQUAL, r3, 0, imm, (long)types::TAG_UNDEFINED, pos);
                    } else {
                        out.box(r0);
                    }
                }
            case PUTPROP:
                out.memory_guard(ins.a, memory, pos);
                out.index(ins.b, memory, pos);
                if (plan.memory[memory].kind == DENSE) {
                    e.mov(r0, 0, mem | r2, 0);
                    e.op(jit::SLJIT_LSHR, r3, r0, 0, imm, 48);
                    out.guard(jit::SLJIT_GREATER, r3, 0, imm, (long)types::TAG_FASTINT, pos);
                    out.load(ins.c, r0);
                    e.op(jit::SLJIT_LSHR, r3, r0, 0, imm, 48);
                    out.guard(jit::SLJIT_GREATER, r3, 0, imm, (long)types::TAG_FASTINT, pos);
                    e.mov(mem | r2, 0, r0, 0);
                } else if (plan.memory[memory].cls >= FLOAT32ARRAY) {
                    out.load(ins.c, r0);
                    out.number(r0, 1, pos);
                    bool small = plan.memory[memory].cls == FLOAT32ARRAY;
                    if (small) out.fop(jit::SLJIT_CONV_F64_FROM_F32 | jit::SLJIT_32, 1, 0, 1, 0);
                    out.fop(jit::SLJIT_MOV_F64 | (small ? jit::SLJIT_32 : 0), mem | r2, 0, 1, 0);
                } else {
                    out.int32(ins.c, r0, pos);
                    e.mov(mem | r2, 0, r0, 0, loop_load_op(plan.memory[memory].cls));
                }
                continue;
            case CALL:
                out.load(ins.b, r0);
                out.guard(jit::SLJIT_NOT_EQUAL, r0, 0, mem | state, loop_memory_offset(memory, 3), pos);
                out.memory_guard((uint)ins.b + 1, memory, pos);
                if (plan.memory[memory].kind == ASCII) {
                    out.integer((uint)ins.b + 2, r1, pos);
                    out.guard(jit::SLJIT_GREATER_EQUAL, r1, 0, mem | state, loop_memory_offset(memory, 2), pos);
                    e.mov(r2, 0, mem | state, loop_memory_offset(memory, 1));
                    e.op(jit::SLJIT_ADD, r2, r2, 0, r1, 0);
                    e.mov(r0, 0, mem | r2, 0, jit::SLJIT_MOV_U8);
                } else {
                    out.int32((uint)ins.b + 2, r0, pos);
                    out.int32((uint)ins.b + 3, r1, pos);
                    e.op(jit::SLJIT_MUL | jit::SLJIT_32, r0, r0, 0, r1, 0);
                    e.mov(r0, 0, r0, 0, jit::SLJIT_MOV_S32);
                }
                out.box(r0);
            case LT:
            case LE:
            case GT:
            case GE:
            case EQ:
            case NEQ:
            case SEQ:
            case SNEQ:

                {
                    Instruction compare = ins;
                    compare.op = loop_compare(ins.op);
                    void*[2] skips = out.condition(compare, pos);
                    TVal yes;
                    yes.set_boolean(true);
                    TVal no;
                    no.set_boolean(false);
                    e.mov(r0, 0, imm, (long)loop_bits(yes));
                    void* done   = jit::sljit_emit_jump(e.compiler, jit::SLJIT_JUMP);
                    void* failed = e.label();
                    foreach (jump : skips) if (jump != null) out.bind_to(jump, failed);
                    e.mov(r0, 0, imm, (long)loop_bits(no));
                    e.bind(done);
                }
            case BNOT:
                out.int32(ins.b, r0, pos);
                e.op(jit::SLJIT_XOR, r0, r0, 0, imm, -1);
                out.box(r0);
            case UNM:
                out.number_reg(ins.b, 1, pos);
                out.fop(jit::SLJIT_NEG_F64, 1, 0, 1, 0);
                out.float_result(1);
            case TONUMERIC:
                out.integer(ins.b, r0, pos);
                out.box(r0);
            case INC:
            case INC_LT:
            case DEC:
                out.integer(ins.a, r0, pos);
                e.op(ins.op == Opcode.DEC ? jit::SLJIT_SUB : jit::SLJIT_ADD, r0, r0, 0, imm, 1);
                out.range(r0, pos);
                out.box(r0);
            case ADD:
            case ADD_FUSED:
            case ADDI:
            case SUB:
            case SUBI:
            case MUL:
            case MULI:
            case DIV:
                out.numeric(ins, pos);
                continue;
            default:

                {
                    out.int32(ins.b, r0, pos);
                    bool immediate = ins.op == Opcode.BANDI || ins.op == Opcode.BORI || ins.op == Opcode.BXORI
                        || ins.op == Opcode.SHLI
                        || ins.op == Opcode.SHRI
                        || ins.op == Opcode.USHRI;
                    if (immediate) {
                        e.mov(r1, 0, imm, (long)ins.c);
                    } else {
                        out.int32(ins.c, r1, pos);
                    }
                    if (ins.op == Opcode.BAND || ins.op == Opcode.BANDI || ins.op == Opcode.BOR
                        || ins.op == Opcode.BORI
                        || ins.op == Opcode.BXOR
                        || ins.op == Opcode.BXORI) {
                        int op = ins.op == Opcode.BAND || ins.op == Opcode.BANDI ? jit::SLJIT_AND
                            : (ins.op == Opcode.BOR || ins.op == Opcode.BORI ? jit::SLJIT_OR : jit::SLJIT_XOR);
                        e.op(op, r0, r0, 0, r1, 0);
                        e.mov(r0, 0, r0, 0, jit::SLJIT_MOV_S32);
                    } else {
                        e.op(jit::SLJIT_AND, r1, r1, 0, imm, 31);
                        bool right          = ins.op == Opcode.SHR || ins.op == Opcode.SHRI;
                        bool unsigned_right = ins.op == Opcode.USHR || ins.op == Opcode.USHRI;
                        if (unsigned_right) e.mov(r0, 0, r0, 0, jit::SLJIT_MOV_U32);
                        e.op(
                            right ? jit::SLJIT_ASHR : (unsigned_right ? jit::SLJIT_LSHR : jit::SLJIT_SHL),
                            r0,
                            r0,
                            0,
                            r1,
                            0
                        );
                        if (!unsigned_right) e.mov(r0, 0, r0, 0, jit::SLJIT_MOV_S32);
                    }
                    out.box(r0);
                }
        }
        out.store(ins.a, r0, pos);
    }
    if (e.failed) return null;
    out.link(jit::sljit_emit_jump(e.compiler, jit::SLJIT_JUMP), plan.end + 1, true);
    if (e.failed) return null;
    void*[512] exits;
    uint[512] exit_pcs;
    void*[512] epilog_jumps;
    uint exit_count;
    for (uint i = 0; i < out.link_count; i++) {
        LoopLink link = out.links[i];
        if (!link.exit) {
            out.bind_to(link.jump, out.labels[link.target - plan.begin]);
            continue;
        }
        uint j;
        while (j < exit_count && exit_pcs[j] != link.target) j++;
        if (j == exit_count) {
            exit_pcs[j] = link.target;
            exits[j] = e.label();
            e.mov(r0, 0, imm, link.target);
            epilog_jumps[j] = jit::sljit_emit_jump(e.compiler, jit::SLJIT_JUMP);
            exit_count++;
        }
        out.bind_to(link.jump, exits[j]);
    }
    void* epilog = e.label();
    for (uint i = 0; i < exit_count; i++) out.bind_to(epilog_jumps[i], epilog);
    for (uint i = 0; i < cf.num_regs; i++) if (plan.cache[i] != 0) e.mov(
        mem | state,
        loop_value_offset(i),
        plan.cache[i],
        0
    );
    for (uint i = 0; i < cf.num_regs; i++) if (plan.float_cache[i] != 0) {
        out.float_bits(plan.float_cache[i], r1);
        e.mov(mem | state, loop_value_offset(i), r1, 0);
    }
    LoopState layout;
    e.mov(mem | state, (char*)&layout.dirty - (char*)&layout, dirty, 0);
    e.mov(mem | state, (char*)&layout.budget - (char*)&layout, budget, 0);
    if (jit::sljit_emit_return(e.compiler, jit::SLJIT_MOV, r0, 0) != 0 || e.failed) return null;
    LoopNative native = (LoopNative)jit::sljit_generate_code(e.compiler, 0, null);
    if (native != null) plan.code_bytes = jit::sljit_shim_code_size(e.compiler);
    return native;
}

fn void sljit_loop_free(Heap* h, CompiledFunction* cf) @feat(SLJIT) {
    LoopPlan* plan = cf.sljit_loops;
    while (plan != null) {
        LoopPlan* next = plan.next;
        $if $feat(SLJIT_STATS):
            io::eprintfn(
                "SLJIT loop %s pc=%d..%d hits=%d iterations=%d code_bytes=%d",
                (String)cf.get_name(),
                plan.begin,
                plan.end,
                plan.hits,
                plan.iterations,
                plan.code_bytes
            );
        $endif
        jit::sljit_free_code((void*)plan.native, null);
        h.jit_code_bytes -= plan.code_bytes;
        h.free_func(h.heap_udata, plan);
        plan = next;
    }
    cf.sljit_loops = null;
    cf.sljit_loop_ready = 0;
}
fn bool sljit_loop_probe(Instruction* pc, CompiledFunction* cf) @feat(SLJIT) @inline {
    if (cf.num_regs > LOOP_REGS) return false;
    uint offset = (uint)(pc - cf.code);
    for (LoopPlan* plan = cf.sljit_loops; plan != null; plan = plan.next) {
        if (offset == plan.end) return true;
    }
    // Collisions only suppress compilation; the interpreter still executes the loop.
    if ((cf.sljit_loop_rejected & (1UL << (offset & 63))) != 0) return false;
    int target = loop_target(*pc, offset);
    return target >= 0 && target < (int)offset;
}
fn Instruction* sljit_loop_entry(Instruction* pc, Instruction* body, TVal* regs, ColdCtx* cold) @feat(SLJIT) @noinline {
    Heap* h              = cold.heap;
    CompiledFunction* cf = cold.vm.current_func;
    if (!h.jit_enabled || !types::USE_NANBOX || usz::size != 8 || cf.num_regs > LOOP_REGS || h.uncatchable_throw
        || std::core::mem::@atomic_load(
        h.interrupt_requested
    ) != 0) return body;
    uint offset = (uint)(pc - cf.code);
    if (loop_target(*pc, offset) != (int)(body - cf.code)) return body;
    long budget     = h.bwd_gc_budget;
    bool interrupts = h.capi_runtime != null || h.capi_interrupt_fn != null;
    if (interrupts && (long)h.interrupt_budget < budget) budget = h.interrupt_budget;
    LoopState state;
    for (uint i = 0; i < cf.num_regs; i++) state.values[i] = regs[i];
    LoopPlan* plan;
    bool prepared;
    uint plans;
    for (LoopPlan* candidate = cf.sljit_loops; candidate != null; candidate = candidate.next) {
        plans++;
        if (offset != candidate.end) continue;
        if (loop_prepare(candidate, &state, cold)) {
            plan = candidate;
            prepared = true;
            break;
        }
    }
    if (plan == null) {
        cf.sljit_loop_ready &= ~(1U << (offset & 31));
        int target = loop_target(*pc, offset);
        if (target < 0 || target >= (int)offset || (cf.sljit_loop_rejected & (1UL << (offset & 63))) != 0) return body;
        if (plans >= 4 || h.jit_code_bytes >= LOOP_CODE_LIMIT) {
            cf.sljit_loop_rejected |= 1UL << (offset & 63);
            return body;
        }
        LoopPlan draft;
        if (!loop_analyze(&draft, offset, regs, cold)) {
            cf.sljit_loop_rejected |= 1UL << (offset & 63);
            return body;
        }
        draft.native = ssa_loop_eligible(&draft, cf) ? ssa_loop_emit(&draft, cf, h) : null;
        draft.ssa = draft.native != null;
        if (draft.native == null) draft.native = loop_emit(&draft, cf);
        if (draft.native == null) {
            cf.sljit_loop_rejected |= 1UL << (offset & 63);
            return body;
        }
        if (h.jit_code_bytes + draft.code_bytes > LOOP_CODE_LIMIT) {
            jit::sljit_free_code((void*)draft.native, null);
            cf.sljit_loop_rejected |= 1UL << (offset & 63);
            return body;
        }
        plan = (LoopPlan*)h.alloc_func(h.heap_udata, LoopPlan::size);
        if (plan == null) {
            jit::sljit_free_code((void*)draft.native, null);
            cf.sljit_loop_rejected |= 1UL << (offset & 63);
            return body;
        }
        *plan = draft;
        plan.next = cf.sljit_loops;
        cf.sljit_loops = plan;
        h.jit_code_bytes += plan.code_bytes;
        $if $feat(SLJIT_STATS):
            io::eprintfn(
                "SLJIT loop compiled %s pc=%d..%d code_bytes=%d plan_bytes=%d",
                (String)cf.get_name(),
                plan.begin,
                plan.end,
                plan.code_bytes,
                LoopPlan::size
            );
        $endif
    }
    if (h.interrupt_due || budget <= 1) return body;
    if (!prepared && !loop_prepare(plan, &state, cold)) return body;
    uint resume_pc = plan.native(&state, budget);
    uint consumed  = (uint)(budget - state.budget);
    // A guard exit means the SSA speculation did not hold. Fall back to the
    // straight-line loop tier for this loop from now on instead of retrying
    // the same speculation at every safepoint.
    if (plan.ssa && resume_pc != plan.end + 1) {
        jit::sljit_free_code((void*)plan.native, null);
        h.jit_code_bytes -= plan.code_bytes;
        plan.native = loop_emit(plan, cf);
        plan.ssa = false;
        if (plan.native != null) h.jit_code_bytes += plan.code_bytes;
    }
    // Failed guards retry at ordinary interpreter safepoints. Hash collisions
    // can only add a switch dispatch or delay another region's native entry.
    uint ready     = 1U << (offset & 31);
    if (consumed == 0 && resume_pc >= plan.begin && resume_pc <= plan.end) {
        cf.sljit_loop_ready &= ~ready;
    } else {
        cf.sljit_loop_ready |= ready;
    }
    h.bwd_gc_budget -= consumed;
    if (interrupts) h.interrupt_budget -= consumed;
    // Retain every incoming string before releasing any overwritten register;
    // a native permutation can move its last reference between slots.
    for (uint i = 0; i < cf.num_regs; i++) {
        if ((state.dirty & (1UL << i)) != 0 && state.values[i].is_refcounted()
            && state.values[i].get_heapptr() != null) ((HeapHeader*)state.values[i].get_heapptr()).incref();
    }
    for (uint i = 0; i < cf.num_regs; i++) {
        if ((state.dirty & (1UL << i)) == 0) continue;
        h.tval_copy_ref(regs + i, &state.values[i]);
        h.decref_tval(&state.values[i]);
        if (regs[i].is_heap_allocated()) track_heap_store(cold.act, regs + i, i);
    }
    $if $feat(SLJIT_STATS):
        plan.hits++;
        plan.iterations += consumed;
        if (plan.hits == 1000) io::eprintfn(
            "SLJIT loop native %s pc=%d..%d hits=%d iterations=%d",
            (String)cf.get_name(),
            plan.begin,
            plan.end,
            plan.hits,
            plan.iterations
        );
    $endif
    return cf.code + resume_pc;
}