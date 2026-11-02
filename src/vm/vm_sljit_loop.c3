module boomkat::vm;

import boomkat::bytecode;
import boomkat::compiler;
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
// The straight-line tier keeps one label per bytecode in the loop, so its span
// is bounded by the emitter's label table. Whole loops of this size are common
// in generated code; a longer one stays in the interpreter.
const uint LOOP_SPAN      = 512;
// The shared SSA graph keeps an interpreter frame per bytecode and per register,
// which costs 64 words per op, so its span is bounded separately and a longer
// loop falls back to the straight-line tier.
const uint SSA_SPAN       = 128;
// Largest bytecode body the whole-body SSA tier attempts. A bigger body costs
// proportional compile and recovery work, and the baseline template region
// inlines the same property reads for less, so it keeps those functions.
const uint SSA_BODY_OPS   = 320;
// A specialization is abandoned for the baseline tier only after this many
// helper calls have shown it spends more entries in helpers than in its body.
const uint SSA_DEMOTE_HELPERS = 256;
const uint LOOP_MEMORY    = 8;
const uint LOOP_BINDINGS  = 16;
// Binding descriptors hold either invocation-local variables resolved through
// the variable IC or captures resolved through the callee's capture refs.
const char BINDING_VAR     = 0;
const char BINDING_CAPTURE = 1;
const uint LOOP_THIS      = LOOP_REGS + LOOP_BINDINGS;
// A fixup costs one arena block per four records; the directory that indexes
// them is heap-allocated per emitter, so this ceiling only bounds memory.
const uint LINK_LIMIT_MAX = 65536;
const uint LOOP_LINK_BLOCK = usz::size == 8 ? 4 : 2;

alias LoopNative = fn uint(void* state, long budget);
enum LoopMemoryKind : char {
    TYPED,
    DENSE,
    ASCII,
    INTRINSIC,
    // A data property of an object that does not change for the whole run.
    // The receiver's shape is revalidated on every native entry, so the read
    // needs no per-iteration guard.
    FIELD,
    // A data property of an object supplied by a register that the loop
    // rewrites, so each access guards the receiver's shape against the one
    // the site cache recorded.
    SHAPE_FIELD,
    PROTO_FIELD
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
    bool doubles;
    bool integers;
    // FIELD: the bytecode position (for the site cache's key), the constant
    // pool index of the key when it has one, the resolved slot and the shape
    // that made it valid.
    uint pc;
    uint key_const;
    int slot;
    uint shape;
    uint shape_gen;
    uint[hobject::IC_MAX_CHAIN] proto_shapes;
    uint[hobject::IC_MAX_CHAIN] proto_generations;
    uint proto_depth;
    // Borrowed only during graph construction, when an active receiver or
    // the rooted IC owner proves the first prototype remains live.
    HObject* proto_anchor;
}
struct LoopState @feat(SLJIT) {
    TVal[LOOP_REGS] values;
    TVal receiver;
    uint shape_epoch;
    uint resume_pc;
    LoopMemory[LOOP_MEMORY] memory;
    TVal[LOOP_BINDINGS] bindings;
    ulong dirty;
    long budget;
    double[128] ssa_spill;
    // Edge conversions finish before any phi home is changed. Raw bits here
    // are borrowed only while native code cannot collect or release strings.
    double[LOOP_REGS] ssa_edge;
    SsaExecution* execution;
}
struct LoopPlan @feat(SLJIT) {
    SsaPlanData* ssa_data;
    SsaDeoptSite* ssa_deopt_sites;
    SsaDeoptFrame* ssa_deopt_frames;
    SsaDeoptChain ssa_deopt_chain;
    SsaHelperSite* ssa_helpers;
    uint ssa_value_capacity;
    // Reusable invocation scratch, one block per concurrent activation.
    SsaScratch* ssa_scratch_free;
    // A helper site's feedback became native while this plan ran. The next
    // gateway outside generated code may recompile so the site joins the body.
    bool ssa_recompile_wanted;
    // This body spends most of its entries in helpers. Its CompiledFunction
    // recompiles on the baseline tier instead of keeping the specialization.
    bool ssa_demote;
    ulong ssa_helper_calls;
    ulong ssa_helper_continued @if($feat(SLJIT_STATS));
    uint ssa_inline_sites;
    ulong ssa_inline_entries @if($feat(SLJIT_STATS));
    ulong ssa_inline_recoveries @if($feat(SLJIT_STATS));
    LoopNative native;
    JitArtifact artifact;
    JitArtifact* code_owner;
    ulong ssa_inputs;
    uint ssa_shape_epoch;
    bool ssa_fields;
    bool ssa_calls;
    bool ssa_commit;
    // Published-frame bodies recover the exact bytecode state after effects.
    bool ssa_recoverable;
    ulong[2] ssa_resume_pcs;
    // The region contains a nested loop, so only the cyclic SSA emitter can
    // describe it and the straight-line template emitter must not try.
    bool ssa_cyclic;
    void* ssa_entry;
    CompiledFunction* ssa_function;
    void* ssa_map_begin @if($feat(SLJIT_MAP));
    void* ssa_map_end @if($feat(SLJIT_MAP));
    uint ssa_map_depth @if($feat(SLJIT_MAP));
    ulong ssa_binding_mask;
    ulong ssa_watched_bindings;
    bool ssa_watched_methods;
    FunctionPlan* dependency_owner;
    TVal[LOOP_BINDINGS] ssa_binding_constants;
    bool ssa_invalid;
    ulong ssa_completed @if($feat(SLJIT_STATS));
    ulong ssa_entry_misses @if($feat(SLJIT_STATS));
    ulong ssa_body_misses @if($feat(SLJIT_STATS));
    ulong ssa_epoch_updates @if($feat(SLJIT_STATS));
    ulong ssa_native_calls @if($feat(SLJIT_STATS));
    ulong ssa_native_returns @if($feat(SLJIT_STATS));
    ulong ssa_native_exits @if($feat(SLJIT_STATS));
    ulong ssa_native_overlaps @if($feat(SLJIT_STATS));
    void* ssa_epoch_constant;
    usz ssa_epoch_patch;
    long ssa_executable_offset;
    LoopPlan* next;
    uint begin;
    uint end;
    usz code_bytes;
    LoopMemorySpec[LOOP_MEMORY] memory;
    uint memory_count;
    uint[LOOP_BINDINGS] bindings;
    CompiledFunction*[LOOP_BINDINGS] binding_functions;
    char[LOOP_BINDINGS] binding_kind;
    uint binding_count;
    char[LOOP_SPAN] memory_at;
    char[LOOP_SPAN] binding_at;
    char[LOOP_SPAN] intrinsic_at;
    // General registers hold boxed bits; floating registers hold numeric values.
    // Canonical registers are loop-carried integers: an integral double is
    // rewritten to the fastint representation once at entry.
    ulong canonical;
    // Registers whose native representation is forced to a double after an
    // integer overflow exit. One bit per VM register.
    ulong ssa_double;
    uint ssa_retries;
    bool ssa;
    char[LOOP_REGS] cache;
    char[LOOP_REGS] float_cache;
    // Loop slot -> VM register. Identity for a normal loop; a high-register
    // loop aliases each high register to a free low slot.
    int[LOOP_REGS] slot_reg;
    ulong hits;
    ulong iterations;
    // Consecutive entries that completed no iteration.
    uint short_runs;
    ulong ssa_hits @if($feat(SLJIT_STATS));
    ulong ssa_iterations @if($feat(SLJIT_STATS));
}
struct LoopLink @feat(SLJIT) {
    void* jump;
    uint target;
    bool exit;
    ushort inline_id;
    ulong flow;
    void* resolved;
}
struct LoopEmitter @feat(SLJIT) {
    TemplateEmitter e;
    LoopPlan* plan;
    Heap* heap;
    // One label per emitted position, and a directory into arena-allocated
    // fixup blocks. Both are allocated by the emitter that records them, so a
    // nested emitter that only binds guards already set costs two pointers.
    void** labels;
    LoopLink** link_blocks;
    uint link_count;
    uint link_limit;
    // Highest capacity growth may reach; zero keeps the admission estimate as
    // a hard bound. Only whole-function bodies opt in.
    uint link_growth;
    bool link_limit_reached @if($feat(SLJIT_STATS));
    bool function_mode;
    // Inlined callees keep their registers in a private scratch window, so the
    // emitter needs a second base pointer and must not touch reference counts.
    bool raw_store;
    FunctionInlineFrame* inline_frame;
    int state_reg;
    FunctionFlow* flow;
}
fn int LoopEmitter.state_base(&self) @feat(SLJIT) => self.state_reg != 0 ? self.state_reg : jit::reg_s(0);

// True for an ordinary double: the payload already holds its bits and no tag
// competes with them. Only NaN boxing has that representation.
fn bool loop_plain_double(TVal v) @feat(SLJIT) {
    $if types::USE_NANBOX:
        return ((ulong)v.bits >> 48) < (ulong)types::TAG_FASTINT;
    $else return false;
$endif
}
fn ulong loop_bits(TVal v) @feat(SLJIT) {
    $if types::USE_NANBOX: return v.bits; $else return 0; $endif
}
fn int loop_target(Instruction ins, uint pc) @feat(SLJIT) {
    if (ins.op == Opcode.JUMP) return (int)pc + 1 + ins.get_sabc();
    if (ins.op == Opcode.IF_TRUE || ins.op == Opcode.IF_FALSE) return (int)pc + 1 + ins.get_sbc();
    if ((ins.op >= Opcode.JMP_NLT && ins.op <= Opcode.JMP_NNULL)
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
    return loop_binding_effective(pc, { pc.op, pc.a, pc.b, pc.c }, cold, result);
}
fn bool loop_binding_effective(Instruction* pc, DecodedInsn ins, ColdCtx* cold, TVal* result) @feat(SLJIT) {
    if (ins.op == Opcode.GETCAP) {
        hobject::PropValue* value = capture_value_slot(cold.act, ins.get_bc(), cold.heap);
        if (value != null) {
            *result = value.get();
            return !env::is_tdz_sentinel(result);
        }
    } else {
        // The bytecode IC is shared by every closure of this function. The
        // threaded GETVAR handler checks the environment head before using
        // its cached slot; a loop entry must make the same check.
        hobject::VarICEntry* ic = (ins.op == Opcode.GETGLOBAL || ins.op == Opcode.CALL_GLOBAL) ? th_global_ic_hit(pc, cold)
            : (!th_var_ic_moved(pc, cold) ? th_var_ic_hit(pc, cold) : null);
        if (ic != null && !ic.prop_flags.is_accessor) {
            *result = ic.slot_ptr.get();
            return !env::is_tdz_sentinel(result);
        }
    }
    CompiledFunction* cf = cold.vm.current_func;
    uint constant        = ins.op == Opcode.CALL_GLOBAL || ins.op == Opcode.CALL_VAR ? ins.c : ins.get_bc();
    if (ins.op == Opcode.GETCAP) {
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
// An admitted region cannot mutate its lexical environment. Normalize fused
// callee reads to the same binding descriptor as an explicit variable read.
fn int loop_record_binding(LoopPlan* plan, uint pc, ColdCtx* cold, LoopState* sample, bool feedback = false, CompiledFunction* cf = null) @feat(SLJIT) {
    if (cf == null) cf = cold.vm.current_func;
    Instruction ins = cf.code[pc];
    Opcode kind = ins.op == Opcode.CALL_GLOBAL ? Opcode.GETGLOBAL
        : ins.op == Opcode.CALL_VAR ? Opcode.GETVAR : ins.op;
    uint key = ins.op == Opcode.CALL_GLOBAL || ins.op == Opcode.CALL_VAR ? ins.c : ins.get_bc();
    for (uint i = 0; i < plan.binding_count; i++) {
        Instruction prior = cf.code[plan.bindings[i]];
        Opcode prior_kind = prior.op == Opcode.CALL_GLOBAL ? Opcode.GETGLOBAL
            : prior.op == Opcode.CALL_VAR ? Opcode.GETVAR : prior.op;
        uint prior_key = prior.op == Opcode.CALL_GLOBAL || prior.op == Opcode.CALL_VAR ? prior.c : prior.get_bc();
        if (kind == prior_kind && key == prior_key) {
            plan.binding_at[pc - plan.begin] = (char)(i + 1);
            return (int)i;
        }
    }
    if (plan.binding_count == LOOP_BINDINGS) return -1;
    uint id = plan.binding_count;
    if (!feedback && !loop_binding(cf.code + pc, cold, &sample.bindings[id])) return -1;
    plan.binding_count++;
    plan.bindings[id] = pc;
    plan.binding_at[pc - plan.begin] = (char)(id + 1);
    return (int)id;
}
// A frameless leaf borrows the callee's closure refs instead of walking an
// activation. Captures are resolved once at entry, like variable IC slots.
fn int loop_record_capture(LoopPlan* plan, uint pc, CompiledFunction* cf) @feat(SLJIT) {
    uint index = cf.code[pc].get_bc();
    for (uint i = 0; i < plan.binding_count; i++) {
        if (plan.binding_kind[i] != BINDING_CAPTURE) continue;
        if (cf.code[plan.bindings[i]].get_bc() == index) {
            plan.binding_at[pc - plan.begin] = (char)(i + 1);
            return (int)i;
        }
    }
    if (plan.binding_count == LOOP_BINDINGS) return -1;
    uint id = plan.binding_count++;
    plan.bindings[id] = pc;
    plan.binding_kind[id] = BINDING_CAPTURE;
    plan.binding_at[pc - plan.begin] = (char)(id + 1);
    return (int)id;
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
// Dense array parts that hold ordinary doubles can take a much shorter element
// path: no representation branch, no conversion, and no reference to release.
// The generated code still checks each element, so this hint only chooses the
// better shape; a wrong guess falls back to the interpreter at the first
// element that is not a plain double.
fn bool loop_probe_doubles(LoopMemory* memory) @feat(SLJIT) {
    if (memory.data == null || memory.length <= 0) return false;
    hobject::PropValue* dense = (hobject::PropValue*)memory.data;
    ulong[3] at               = { 0, (ulong)(memory.length / 2), (ulong)(memory.length - 1) };
    for (uint i = 0; i < 3; i++) {
        if (!loop_plain_double(dense[at[i]].get())) return false;
    }
    return true;
}
fn int loop_memory_field(
    LoopPlan* plan,
    int source,
    TVal sample,
    HString* key,
    uint pc,
    uint key_const,
    Heap* h
) @feat(SLJIT) {
    if (source < 0 || key == null || !sample.is_object()) return -1;
    for (uint i = 0; i < plan.memory_count; i++) {
        if (plan.memory[i].kind == FIELD && plan.memory[i].source == (uint)source && plan.memory[i].pc == pc) {
            return (int)i;
        }
    }
    if (plan.memory_count == LOOP_MEMORY) return -1;
    HObject* object = sample.get_heapptr();
    if (object == null || object.is_proxy() || object.flags.exotic_module_ns) return -1;
    int slot = object.find_prop_idx((void*)key, h);
    if (slot < 0) return -1;
    if (object.get_prop_flags((uint)slot, h).is_accessor) return -1;
    LoopMemorySpec spec = {
        .source = (uint)source,
        .kind = FIELD,
        .cls = object.get_class(),
        .shape_gen = object.shape_generation(h),
        .pc = pc,
        .key_const = key_const,
        .slot = slot,
        .shape = object.shape_id,
    };
    TVal value = object.prop_values()[slot].get();
    spec.doubles = loop_plain_double(value);
    uint index = plan.memory_count++;
    plan.memory[index] = spec;
    return (int)index;
}
// Monomorphic site feedback for a receiver the loop rewrites: the layout is
// fixed, so every access only has to compare the live shape id.
fn int loop_memory_shape(
    LoopPlan* plan,
    int source,
    uint pc,
    uint shape,
    uint generation,
    int slot,
    bool doubles
) @feat(SLJIT) {
    if (source < 0) return -1;
    for (uint i = 0; i < plan.memory_count; i++) {
        if (plan.memory[i].kind == SHAPE_FIELD && plan.memory[i].source == (uint)source
            && plan.memory[i].pc == pc) return (int)i;
    }
    if (plan.memory_count == LOOP_MEMORY) return -1;
    LoopMemorySpec spec = {
        .source = (uint)source,
        .kind = SHAPE_FIELD,
        .pc = pc,
        .slot = slot,
        .shape = shape,
        .shape_gen = generation,
        .doubles = doubles,
    };
    uint index = plan.memory_count++;
    plan.memory[index] = spec;
    return (int)index;
}
// Layout-keyed descriptor for a field read inside an inlined callee: the
// receiver is an SSA value, so the descriptor only carries the layout.
fn int loop_memory_shape_layout(LoopPlan* plan, uint shape, uint generation, int slot, bool doubles) @feat(SLJIT) {
    for (uint i = 0; i < plan.memory_count; i++) {
        if (plan.memory[i].kind == SHAPE_FIELD && plan.memory[i].shape == shape && plan.memory[i].slot == slot) {
            return (int)i;
        }
    }
    if (plan.memory_count == LOOP_MEMORY) return -1;
    LoopMemorySpec spec = {
        .kind = SHAPE_FIELD,
        .slot = slot,
        .shape = shape,
        .shape_gen = generation,
        .doubles = doubles,
    };
    uint index = plan.memory_count++;
    plan.memory[index] = spec;
    return (int)index;
}
fn bool loop_prepare(LoopPlan* plan, LoopState* state, ColdCtx* cold, bool generated_fields = false) @feat(SLJIT) {
    Heap* h = cold.heap;
    for (EnvRecord* scope = cold.act.lex_env; scope != null; scope = scope.parent) if (scope.is_with()) return false;
    // Both tables are sized by the alias window, and an aliased register is
    // published in a low slot, so the window is the whole domain here. Bounding
    // this by the function's register count read past both arrays in a wide
    // function and refused the loop on whatever followed them.
    for (uint i = 0; i < LOOP_REGS; i++) {
        if (plan.float_cache[i] != 0 && !state.values[i].is_fastint() && !state.values[i].is_number()) return false;
    }
    for (uint i = 0; i < plan.binding_count; i++) {
        if (!loop_binding(cold.vm.current_func.code + plan.bindings[i], cold, &state.bindings[i])) return false;
    }
    for (uint i = 0; i < plan.memory_count; i++) {
        LoopMemorySpec spec = plan.memory[i];
        if (generated_fields && spec.kind == FIELD) continue;
        LoopMemory* memory  = &state.memory[i];
        if (spec.kind != SHAPE_FIELD) memory.source = loop_source(spec.source, state, cold);
        if (spec.kind == ASCII) {
            if (!memory.source.is_string()) return false;
            HString* text = memory.source.get_heapptr();
            if (text.is_symbol() || !text.is_ascii() || text.is_wide() || text.flags.has_extdata) return false;
            memory.data = text.data_ptr();
            memory.length = text.unit_len();
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
        if (spec.kind == SHAPE_FIELD) {
            // The receiver comes from a register, so only the recorded layout
            // needs revalidating: shape ids are recycled, generations are not.
            Shape* shape = h.get_shape(spec.shape);
            if (shape == null || shape.generation != spec.shape_gen) return false;
            continue;
        }
        if (!memory.source.is_object()) return false;
        HObject* object = memory.source.get_heapptr();
        if (object == null || object.is_proxy()) return false;
        if (spec.kind == FIELD) {
            if (object.shape_id != spec.shape || object.flags.exotic_module_ns) return false;
            void* key = spec.key_const != 0 ? (void*)cold.vm.current_func.constants[spec.key_const - 1].get_heapptr()
                : (void*)((ICEntry*)cold.vm.current_func.ic_entries + spec.pc).key.borrow();
            if (key == null) return false;
            int slot = object.find_prop_idx(key, cold.heap);
            if (slot != spec.slot) return false;
            if (object.get_prop_flags((uint)slot, cold.heap).is_accessor) return false;
            memory.data = (char*)(object.prop_values() + slot);
            continue;
        }
        if (object.get_class() != spec.cls) return false;
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

fn bool loop_analyze(LoopPlan* plan, uint end, TVal* regs, ColdCtx* cold, int region_begin = -1, bool inline_calls = false, CompiledFunction* target_cf = null, bool allow_backedges = false, bool multi_write = false) @feat(SLJIT) {
    bool feedback = target_cf != null;
    CompiledFunction* cf = feedback ? target_cf : cold.vm.current_func;
    int begin            = region_begin >= 0 ? region_begin : loop_target(cf.code[end], end);
    uint window = cf.num_regs < LOOP_REGS ? cf.num_regs : LOOP_REGS;
    if (begin < 0 || begin >= (int)end || end - (uint)begin >= LOOP_SPAN
        || cf.flags.is_generator
        || cf.flags.is_async
        || cf.flags.has_direct_eval
        || cf.flags.needs_lex_bridge
        || cf.mapped_arguments()) return false;
    plan.begin = (uint)begin;
    plan.end = end;
    for (uint i = 0; i < LOOP_REGS; i++) plan.slot_reg[i] = (int)i;
    LoopState sample;
    for (uint i = 0; i < window; i++) sample.values[i] = regs[i];
    int[LOOP_REGS] origin;
    int[LOOP_REGS] method;
    for (uint i = 0; i < LOOP_REGS; i++) {
        origin[i] = (int)i;
        method[i] = -1;
    }
    // Only VM registers participate in allocation; binding/this sources use
    // indices beyond LOOP_REGS and must not index this array.
    uint[LOOP_REGS] frequency;
    // Over-approximation of the registers any instruction may write; a field
    // read off a register that the loop rewrites needs a per-access guard.
    bool[LOOP_REGS] maybe_written;
    for (uint pos = plan.begin; pos <= end; pos++) {
        Instruction ins = cf.code[pos];
        if (ins.op == Opcode.RET || loop_target(ins, pos) >= 0) continue;
        switch (ins.op) {
            case PUTPROP:
            case PUTPROPC:
            case PUTTHISC:
            case PUTGLOBAL:
            case PUTCAP: continue;
            default: break;
        }
        if (ins.a < LOOP_REGS) maybe_written[ins.a] = true;
    }
    ulong integer_required;
    ulong entry_canonical;
    ulong written;
    for (uint pos = plan.begin; pos <= end; pos++) {
        Instruction ins = cf.code[pos];
        uint at         = pos - plan.begin;
        if (feedback && (ins.op == Opcode.RET || ins.op == Opcode.RETUNDEF)) continue;
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
            if ((uint)target >= cf.code_count || (target <= (int)pos && pos != end && !allow_backedges)) return false;
            if (ins.op == Opcode.JUMP) continue;
            // The template emitter's condition path carries the numeric
            // relations only, so the equality and null branches stay out of
            // this tier.
            if (ins.op == Opcode.JMP_NULL || ins.op == Opcode.JMP_NNULL
                || (!feedback && (ins.op == Opcode.JMP_EQ || ins.op == Opcode.JMP_NEQ))) return false;
            uint b = ins.op == Opcode.IF_TRUE || ins.op == Opcode.IF_FALSE ? ins.a : ins.b;
            if (b >= window) return false;
            frequency[b]++;
            if (ins.op >= Opcode.JMP_NLT && ins.op <= Opcode.JMP_NEQ) {
                if (ins.c >= window) return false;
                frequency[ins.c]++;
            }
            continue;
        }
        if (ins.a >= window) {
            return false;
        }
        frequency[ins.a]++;
        switch (ins.op) {
            case NOP: continue;
            case LDREG:
                if (ins.b >= window) return false;
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
                    // A whole-body leaf has no activation: its captures come
                    // from the callee object, not from the caller's env chain.
                    int id = ins.op == Opcode.GETCAP && feedback
                        ? loop_record_capture(plan, pos, cf)
                        : loop_record_binding(plan, pos, cold, &sample, feedback, cf);
                    if (id < 0) return false;
                    origin[ins.a] = (int)LOOP_REGS + id;
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
                    if (base >= window || index >= window || (write && ins.c >= window)
                        || origin[base] < 0) return false;
                    int memory = loop_memory(plan, origin[base], loop_source((uint)origin[base], &sample, cold));
                    if (memory < 0 || plan.memory[memory].kind == INTRINSIC
                        || plan.memory[memory].kind == ASCII) return false;
                    plan.memory_at[at] = (char)(memory + 1);
                    plan.memory[memory].written |= write;
                    frequency[base]++;
                    frequency[index]++;
                    integer_required |= (1UL << base) | (1UL << index);
                    if (write) {
                        frequency[ins.c]++;
                        continue;
                    }
                }
            case PUTTHISC:
            case PUTPROPC:
                {
                    // One final own-slot update commits after every fallible
                    // guard. A whole-body leaf may also write several slots
                    // when it reads no memory, so replaying it is idempotent.
                    if (!feedback || (!plan.ssa_recoverable && !multi_write && (pos + 1 != end
                        || cf.code[end].op != Opcode.RETUNDEF)) || cf.ic_entries == null) return false;
                    if (ins.op == Opcode.PUTPROPC && $feat(SLJIT_NO_SSA_FIELD_IR)) return false;
                    ICEntry* ic = (ICEntry*)cf.ic_entries + pos;
                    Shape* shape = cold.heap.get_shape(ic.shape_id);
                    if (ic.key.borrow() == null || ic.has_proto || ic.prop_flags.is_accessor || !ic.prop_flags.writable
                        || shape == null || shape.dict || shape.generation != ic.shape_gen) return false;
                    if (plan.memory_count == LOOP_MEMORY) return false;
                    uint memory = plan.memory_count++;
                    bool receiver = ins.op == Opcode.PUTTHISC;
                    plan.memory[memory] = { .kind = receiver ? FIELD : SHAPE_FIELD, .source = receiver ? LOOP_THIS : ins.a, .written = true,
                        .shape = ic.shape_id, .shape_gen = ic.shape_gen, .slot = (int)ic.prop_idx, .cls = OBJECT };
                    plan.memory_at[at] = (char)(memory + 1);
                    plan.ssa_commit = true;
                    continue;
                }
            case GETPROPC:
            case GETPROPC_CACHED:
            case GETTHISC:

                {
                    bool receiver = ins.op == Opcode.GETTHISC;
                    if (!receiver) {
                        if (ins.b >= window || ins.c >= cf.const_count || !cf.constants[ins.c].is_string()
                            || (!feedback && origin[ins.b] < 0)) return false;
                    }
                    int source = receiver ? (int)LOOP_THIS : origin[ins.b];
                    TVal base;
                    if (!feedback) base = loop_source((uint)source, &sample, cold);
                    HString* key;
                    uint key_const;
                    if (receiver) {
                        if (cf.ic_entries == null) return false;
                        key = (HString*)((ICEntry*)cf.ic_entries + pos).key.borrow();
                        if (feedback && key == null && ins.c < cf.const_count && cf.constants[ins.c].is_string()) {
                            key = cf.constants[ins.c].get_heapptr();
                        }
                        if (key == null) return false;
                    } else {
                        key = cf.constants[ins.c].get_heapptr();
                        key_const = ins.c + 1;
                    }
                    if (key.is_symbol()) return false;
                    if (feedback) {
                        if (cf.ic_entries == null) return false;
                        ICEntry* ic = (ICEntry*)cf.ic_entries + pos;
                        if (plan.ssa_recoverable && (ic.prop_flags.is_accessor || ic.has_proto)) {
                            // Observable property semantics use the same rooted
                            // helper boundary; surrounding scalar code remains SSA.
                            plan.memory_at[at] = 0;
                            origin[ins.a] = -1;
                            method[ins.a] = -1;
                            written |= 1UL << ins.a;
                            continue;
                        }
                        if (ic.has_proto && inline_calls) {
                            HObject* observed;
                            if (cold.vm.current_func.code == cf.code) {
                                TVal value;
                                if (source == (int)LOOP_THIS) { value = cold.act.this_binding; }
                                else if (source >= 0 && source < (int)cf.num_args) { value = cold.act.bottom[source]; }
                                if (value.is_object()) observed = value.get_heapptr();
                            }
                            int memory = ssa_proto_memory(plan, ic, key, cold.heap, observed);
                            if (memory < 0) return false;
                            plan.memory_at[at] = (char)(memory + 1);
                            origin[ins.a] = -1;
                            written |= 1UL << ins.a;
                            continue;
                        }
                        ICEntry inferred;
                        if (ic.key.borrow() == null && source >= 0) {
                            // A known receiver layout describes its other own
                            // fields even when an arm has not executed yet.
                            for (uint prior = 0; prior < plan.memory_count; prior++) {
                                LoopMemorySpec known = plan.memory[prior];
                                if (known.kind != FIELD || known.source != (uint)source) continue;
                                Shape* layout = cold.heap.get_shape(known.shape);
                                PropFlags flags;
                                int slot = function_shape_slot(layout, key, &flags);
                                if (slot < 0 || flags.is_accessor) continue;
                                inferred.shape_id = known.shape;
                                inferred.shape_gen = known.shape_gen;
                                inferred.prop_idx = (uint)slot;
                                inferred.prop_flags = flags;
                                inferred.key = (hstring::StringRef)key;
                                ic = &inferred;
                                break;
                            }
                        }
                        Shape* shape = cold.heap.get_shape(ic.shape_id);
                        if (ic.key.borrow() != key || ic.has_proto || ic.prop_flags.is_accessor
                            || shape == null || shape.dict || shape.generation != ic.shape_gen) return false;
                        uint memory;
                        if (source < 0) {
                            int layout = loop_memory_shape_layout(plan, ic.shape_id, ic.shape_gen, (int)ic.prop_idx, false);
                            if (layout < 0) return false;
                            memory = (uint)layout;
                        } else {
                            while (memory < plan.memory_count) {
                                LoopMemorySpec prior = plan.memory[memory];
                                if (prior.kind == FIELD && prior.source == (uint)source && prior.shape == ic.shape_id
                                    && prior.slot == (int)ic.prop_idx) break;
                                memory++;
                            }
                            if (memory == plan.memory_count) {
                                if (memory == LOOP_MEMORY) return false;
                                plan.memory_count++;
                                plan.memory[memory] = { .kind = FIELD, .source = (uint)source,
                                    .shape = ic.shape_id, .shape_gen = ic.shape_gen, .slot = (int)ic.prop_idx, .cls = OBJECT };
                            }
                        }
                        plan.memory[memory].integers = ic.read_rep == 1;
                        plan.memory_at[at] = (char)(memory + 1);
                        origin[ins.a] = -1;
                        method[ins.a] = -1;
                        written |= 1UL << ins.a;
                        continue;
                    }
                    // Element, string and builtin-method memories first.
                    int memory  = -1;
                    if (!receiver && base.is_string()) {
                        memory = loop_memory(plan, source, base);
                    } else if (!receiver && base.is_object()) {
                        HObject* probe = base.get_heapptr();
                        ObjClass cls   = probe == null ? OBJECT : probe.get_class();
                        bool element   = cls == ARRAY
                            || (cls >= INT8ARRAY && cls <= FLOAT64ARRAY && cls != UINT8CLAMPEDARRAY
                                && cls != FLOAT16ARRAY);
                        bool builtin   = cls == MATH || (key.equals("imul") || key.equals("charCodeAt"));
                        if (element || builtin) memory = loop_memory(plan, source, base);
                    }
                    if (memory >= 0 && plan.memory[memory].kind == ASCII) {
                        if (key.equals("length")) {
                            plan.memory[memory].length_read = true;
                        } else if (key.equals("charCodeAt")) {
                            plan.memory[memory].builtin = (int)builtins::Builtin.STRING_PROTO_CHARCODEAT.ordinal;
                            plan.intrinsic_at[at] = 1;
                            plan.memory_at[at] = (char)(memory + 1);
                            origin[ins.a] = -1;
                            method[ins.a] = memory;
                            if (source < (int)LOOP_REGS) frequency[(uint)source]++;
                            continue;
                        } else {
                            memory = -1;
                        }
                    } else if (memory >= 0 && plan.memory[memory].kind != INTRINSIC) {
                        if (key.equals("length")) {
                            plan.memory[memory].length_read = true;
                        } else {
                            memory = -1;
                        }
                    } else if (memory >= 0) {
                        if (key.equals("imul")) {
                            plan.memory[memory].builtin = (int)builtins::Builtin.MATH_IMUL.ordinal;
                            plan.intrinsic_at[at] = 1;
                            plan.memory_at[at] = (char)(memory + 1);
                            origin[ins.a] = -1;
                            method[ins.a] = memory;
                            if (source < (int)LOOP_REGS) frequency[(uint)source]++;
                            continue;
                        }
                        memory = -1;
                    }
                    if (memory < 0) {
                        // Linear origin propagation cannot merge assignments
                        // from different CFG arms. An unchanged origin alone
                        // does not prove a rewritten receiver still names it.
                        bool stable = receiver || (source >= 0 && source < (int)LOOP_REGS
                            && !maybe_written[source] && !maybe_written[ins.b]);
                        if (stable) {
                            // A field of an object that is stable for the whole
                            // run: one load per iteration with no guard.
                            memory = loop_memory_field(plan, source, base, key, pos, key_const, cold.heap);
                        } else if (cf.ic_entries != null) {
                            // The receiver changes, but the site is monomorphic:
                            // guard its shape and read the recorded slot.
                            ICEntry* ic  = (ICEntry*)cf.ic_entries + pos;
                            Shape* shape = cold.heap.get_shape(ic.shape_id);
                            if (ic.key.borrow() == (void*)key && ic.chain_len == 0 && shape != null
                                && shape.generation == ic.shape_gen
                                && !ic.prop_flags.is_accessor
                                && ic.prop_idx < hobject::IC_PROP_MISSING) {
                                bool doubles;
                                if (base.is_object()) {
                                    HObject* probe = base.get_heapptr();
                                    if (probe != null && (int)ic.prop_idx < (int)probe.prop_count) {
                                        TVal v = probe.prop_values()[ic.prop_idx].get();
                                        doubles = loop_plain_double(v);
                                    }
                                }
                                memory = loop_memory_shape(
                                    plan,
                                    source,
                                    pos,
                                    ic.shape_id,
                                    ic.shape_gen,
                                    (int)ic.prop_idx,
                                    doubles
                                );
                            }
                        }
                        if (memory < 0 && !plan.ssa_recoverable) return false;
                    }
                    plan.memory_at[at] = (char)(memory + 1);
                    if (source < (int)LOOP_REGS) frequency[(uint)source]++;
                }
            case CALL:
            case CALL_UNDEF_THIS:
            case CALL_GLOBAL:
            case CALL_VAR:

                {
                    // Calls in a recoverable body publish and return before the
                    // call bytecode. The interpreter owns its effects and roots.
                    if (plan.ssa_recoverable) break;
                    if (inline_calls && function_inline_ssa_candidate(cf, pos, cold.heap, feedback) != null) {
                        plan.ssa_calls = true;
                        bool fused = ins.op == Opcode.CALL_GLOBAL || ins.op == Opcode.CALL_VAR;
                        uint base = fused ? ins.a : ins.b;
                        uint nargs = fused ? ins.b : ins.c;
                        if (base + 1 + nargs >= window) return false;
                        if (fused) {
                            if (loop_record_binding(plan, pos, cold, &sample, feedback, cf) < 0) return false;
                        }
                        for (uint i = fused ? 2 : 0; i <= nargs + 1; i++) frequency[base + i]++;
                        break;
                    }
                    if (ins.op != Opcode.CALL || (uint)ins.b + 2 >= window || method[ins.b] < 0) return false;
                    uint memory = (uint)method[ins.b];
                    int builtin = plan.memory[memory].builtin;
                    uint nargs  = builtin == (int)builtins::Builtin.MATH_IMUL.ordinal ? 2 : 1;
                    if (ins.c != nargs || (uint)ins.b + 1 + nargs >= window
                        || origin[(uint)ins.b + 1] != (int)plan.memory[memory].source) return false;
                    plan.memory_at[at] = (char)(memory + 1);
                    for (uint i = 0; i <= nargs + 1; i++) integer_required |= 1UL << ((uint)ins.b + i);
                    for (uint i = 0; i <= nargs + 1; i++) frequency[(uint)ins.b + i]++;
                }
            case NEWOBJ:
            case NEWOBJ_SHAPE:
            case NEWARR:
            case NEWARR_CONST:
                if (!plan.ssa_recoverable) return false;
            case CLOSURE:
                if (!plan.ssa_recoverable || ins.get_bc() >= cf.inner_count) return false;
            case NEWCELLS:
            case GETCELL:
            case SETCELL:
            case MOVECELL:
                if (!plan.ssa_recoverable) return false;
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
            case MOD:
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
                    if (ins.b >= window) return false;
                    frequency[ins.b]++;
                }
                if (ins.op == Opcode.ADD || ins.op == Opcode.ADD_FUSED || ins.op == Opcode.SUB || ins.op == Opcode.MUL
                    || ins.op == Opcode.DIV
                    || ins.op == Opcode.MOD
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
                    if (ins.c >= window) return false;
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
    if (!feedback && !loop_prepare(plan, &sample, cold)) return false;
    bool floating_memory;
    for (uint i = 0; i < plan.memory_count; i++) {
        if (plan.memory[i].kind == DENSE
            || (plan.memory[i].kind == TYPED && plan.memory[i].cls >= FLOAT32ARRAY)) floating_memory = true;
    }
    for (uint i = 0; i < 4; i++) {
        uint best = LOOP_REGS;
        for (uint j = 0; j < window; j++) {
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
    for (uint j = 0; j < window && assigned < 6; j++) {
        if ((plan.canonical & (1UL << j)) == 0) continue;
        plan.cache[j] = (char)(assigned < 4 ? jit::reg_r((int)assigned + 4) : jit::reg_s((int)assigned - 1));
        frequency[j] = 0;
        assigned++;
    }
    for (uint i = assigned; i < 6; i++) {
        uint best;
        for (uint j = 1; j < window; j++) if (frequency[j] > frequency[best]) best = j;
        if (frequency[best] < 2) break;
        plan.cache[best] = (char)(i < 4 ? jit::reg_r((int)i + 4) : jit::reg_s((int)i - 1));
        frequency[best] = 0;
    }
    // Only the SSA tier emits the guarded double element path.
    if (ssa_loop_eligible(plan, cf, cold.heap)) {
        for (uint i = 0; i < plan.memory_count && i < LOOP_MEMORY; i++) {
            if (plan.memory[i].kind != DENSE) continue;
            LoopMemory probe;
            probe.source = loop_source(plan.memory[i].source, &sample, cold);
            if (!probe.source.is_object()) continue;
            HObject* object = probe.source.get_heapptr();
            if (object == null || object.get_class() != ARRAY) continue;
            probe.data = (char*)object.array_part();
            probe.length = (long)*object.array_len_ptr();
            plan.memory[i].doubles = loop_probe_doubles(&probe);
        }
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
    self.e.mov(
        dst,
        0,
        cached != 0 ? cached : jit::SLJIT_MEM | self.state_base(),
        cached != 0 ? 0 : loop_value_offset(reg)
    );
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
            cached != 0 ? cached : jit::SLJIT_MEM | self.state_base(),
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
    self.add_link({ .jump = jump, .target = target, .exit = exit,
        .inline_id = exit && self.inline_frame != null ? self.inline_frame.id : 0,
        .flow = self.flow != null && exit ? self.flow.snapshot() : 0 });
}
fn LoopLink* LoopEmitter.link_at(&self, uint index) @feat(SLJIT) {
    return self.link_blocks[index / LOOP_LINK_BLOCK] + index % LOOP_LINK_BLOCK;
}
fn uint LoopEmitter.link_capacity(&self) @feat(SLJIT) => self.link_limit != 0 ? self.link_limit : 2048;
fn void LoopEmitter.link_release(&self) @feat(SLJIT) {
    if (self.link_blocks != null) self.heap.free_func(self.heap.heap_udata, self.link_blocks);
    self.link_blocks = null;
    self.link_count = 0;
}
fn void** LoopEmitter.labels_alloc(&self, uint count) @feat(SLJIT) {
    void** labels = (void**)self.heap.alloc_func(self.heap.heap_udata, (usz)(count + 1) * void*::size);
    if (labels != null) for (uint i = 0; i <= count; i++) labels[i] = null;
    return labels;
}
fn void LoopEmitter.labels_free(&self) @feat(SLJIT) {
    if (self.labels == null) return;
    self.heap.free_func(self.heap.heap_udata, self.labels);
    self.labels = null;
}
fn bool LoopEmitter.reserve_links(&self, uint capacity, uint prior = 0) @feat(SLJIT) {
    uint blocks = (capacity + LOOP_LINK_BLOCK - 1) / LOOP_LINK_BLOCK;
    LoopLink** grown = (LoopLink**)self.heap.alloc_func(self.heap.heap_udata, (usz)blocks * void*::size);
    if (grown == null) return false;
    for (uint i = 0; i < blocks; i++) grown[i] = null;
    if (self.link_blocks != null && prior != 0) {
        uint used = (prior + LOOP_LINK_BLOCK - 1) / LOOP_LINK_BLOCK;
        if (used > blocks) used = blocks;
        for (uint i = 0; i < used; i++) grown[i] = self.link_blocks[i];
    }
    if (self.link_blocks != null) self.heap.free_func(self.heap.heap_udata, self.link_blocks);
    self.link_blocks = grown;
    return true;
}
// A body that needs more fixups than its admission estimate still compiles:
// the directory doubles instead of failing the whole function. Only the
// absolute ceiling ends native compilation.
fn bool LoopEmitter.grow_links(&self) @feat(SLJIT) {
    uint capacity = self.link_capacity();
    uint next = capacity * 2;
    if (next > self.link_growth) next = self.link_growth;
    if (next <= capacity) {
        $if $feat(SLJIT_STATS): self.link_limit_reached = true; $endif
        return false;
    }
    if (!self.reserve_links(next, capacity)) return false;
    self.link_limit = next;
    return true;
}
fn void LoopEmitter.add_link(&self, LoopLink link) @feat(SLJIT) {
    // SLJIT silently returns null above 128 bytes (64 on 32-bit hosts).
    // Growing a fixup must not accidentally disable all native compilation.
    $assert(LOOP_LINK_BLOCK * LoopLink::size <= 16 * usz::size);
    if (link.jump == null) {
        self.e.failed = true;
        return;
    }
    if (self.link_blocks == null) {
        if (!self.reserve_links(self.link_capacity())) { self.e.failed = true; return; }
    } else if (self.link_count == self.link_capacity()) {
        // The capacity is a memory estimate, not a semantic bound: a
        // guard-rich body (a long switch is the common case) simply needs
        // more fixups.
        if (!self.grow_links()) { self.e.failed = true; return; }
    }
    uint block = self.link_count / LOOP_LINK_BLOCK;
    if (self.link_blocks[block] == null) {
        self.link_blocks[block] = (LoopLink*)jit::sljit_alloc_memory(self.e.compiler,
            (int)(LOOP_LINK_BLOCK * LoopLink::size));
        if (self.link_blocks[block] == null) { self.e.failed = true; return; }
    }
    *self.link_at(self.link_count++) = link;
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
// ToInt32 of a fastint, a boolean, or a double inside int32's range. Narrow
// doubles convert exactly; anything else exits to the interpreter, which owns
// the modulo-2^32 conversion, infinities and NaNs included. TAG_BOOLEAN
// differs from TAG_FASTINT only in bit 2, so one mask folds both onto the
// fastint tail: a boolean's payload is already its 0 or 1, and the low 32 bits
// of a fastint are its ToInt32. Bitwise combinations of comparisons are the
// common source. Null masks down to an unused tag below TAG_FASTINT and
// undefined stays above it, so the magnitude guard rejects both.
fn void LoopEmitter.int32(&self, uint reg, int dst, uint pc) @feat(SLJIT) {
    self.load(reg, dst);
    int temp = jit::reg_r(3);
    self.e.op(jit::SLJIT_LSHR, temp, dst, 0, jit::SLJIT_IMM, 48);
    self.e.op(jit::SLJIT_AND, temp, temp, 0, jit::SLJIT_IMM, ~4L);
    void* integer = self.e.cmp(jit::SLJIT_EQUAL, temp, 0, jit::SLJIT_IMM, (long)types::TAG_FASTINT);
    self.guard(jit::SLJIT_GREATER, temp, 0, jit::SLJIT_IMM, (long)types::TAG_FASTINT, pc);
    self.e.op(jit::SLJIT_AND, temp, dst, 0, jit::SLJIT_IMM, 0x7FFFFFFFFFFFFFFFL);
    self.guard(jit::SLJIT_GREATER_EQUAL, temp, 0, jit::SLJIT_IMM, 0x41E0000000000000L, pc);
    self.fcopy(jit::SLJIT_COPY_TO_F64, 1, dst);
    self.fop(jit::SLJIT_CONV_SW_FROM_F64, dst, 0, 1, 0);
    self.e.bind(integer);
    self.e.mov(dst, 0, dst, 0, jit::SLJIT_MOV_S32);
}
// Modulo operands arrive as NaN-boxed values, but numeric homes hold doubles
// and counters are fastints. Take either: a fastint sign-extends, and a double
// is accepted only when it is exactly integral in fastint range (not -0).
// Everything else, including what fmod would need, exits to the interpreter.
fn void LoopEmitter.mod_operand(&self, int dst, uint pc) @feat(SLJIT) {
    int temp = jit::reg_r(3);
    int imm  = jit::SLJIT_IMM;
    self.e.op(jit::SLJIT_LSHR, temp, dst, 0, imm, 48);
    void* integer = self.e.cmp(jit::SLJIT_EQUAL, temp, 0, imm, (long)types::TAG_FASTINT);
    self.guard(jit::SLJIT_GREATER, temp, 0, imm, (long)types::TAG_FASTINT, pc);
    self.fcopy(jit::SLJIT_COPY_TO_F64, 1, dst);
    self.link(self.fcmp(jit::SLJIT_UNORDERED, 1, 1), pc, true);
    self.e.mov(temp, 0, imm, (long)bitcast((double)types::FASTINT_MIN, ulong));
    self.fcopy(jit::SLJIT_COPY_TO_F64, 2, temp);
    self.link(self.fcmp(jit::SLJIT_ORDERED_LESS, 1, 2), pc, true);
    self.e.mov(temp, 0, imm, (long)bitcast((double)(types::FASTINT_MAX + 1), ulong));
    self.fcopy(jit::SLJIT_COPY_TO_F64, 2, temp);
    self.link(self.fcmp(jit::SLJIT_ORDERED_GREATER_EQUAL, 1, 2), pc, true);
    self.e.op(jit::SLJIT_SHL, temp, dst, 0, imm, 1);
    void* nonzero = self.e.cmp(jit::SLJIT_NOT_EQUAL, temp, 0, imm, 0);
    self.guard(jit::SLJIT_SIG_LESS, dst, 0, imm, 0, pc);
    self.e.bind(nonzero);
    self.fop(jit::SLJIT_CONV_SW_FROM_F64, dst, 0, 1, 0);
    self.fop(jit::SLJIT_CONV_F64_FROM_SW, 2, 0, dst, 0);
    self.link(self.fcmp(jit::SLJIT_ORDERED_NOT_EQUAL, 1, 2), pc, true);
    self.e.bind(integer);
    self.e.op(jit::SLJIT_SHL, dst, dst, 0, imm, 16);
    self.e.op(jit::SLJIT_ASHR, dst, dst, 0, imm, 16);
}
fn void LoopEmitter.numeric(&self, Instruction ins, uint pc) @feat(SLJIT) {
    int r0               = jit::reg_r(0);
    int r1               = jit::reg_r(1);
    int r2               = jit::reg_r(2);
    int r3               = jit::reg_r(3);
    int imm              = jit::SLJIT_IMM;
    if (ins.op == Opcode.MOD) {
        // JavaScript's remainder is fmod, which SLJIT cannot express, so the
        // quotient runs only for exact integer operands and everything else
        // exits to the interpreter. The two integral results fmod would
        // rewrite are written directly: a zero divisor yields the canonical
        // NaN and a zero remainder of a negative dividend yields the boxed -0.
        self.load(ins.b, r0);
        self.load(ins.c, r1);
        self.mod_operand(r0, pc);
        self.mod_operand(r1, pc);
        void* divisor = self.e.cmp(jit::SLJIT_NOT_EQUAL, r1, 0, imm, 0);
        self.e.mov(r1, 0, imm, 0x7FF8000000000000L);
        void* done = jit::sljit_emit_jump(self.e.compiler, jit::SLJIT_JUMP);
        self.e.bind(divisor);
        self.e.mov(r2, 0, r0, 0);
        if (jit::sljit_emit_op0(self.e.compiler, jit::SLJIT_DIVMOD_SW) != 0) self.e.failed = true;
        void* negative = self.e.cmp(jit::SLJIT_SIG_GREATER_EQUAL, r2, 0, imm, 0);
        void* nonzero = self.e.cmp(jit::SLJIT_NOT_EQUAL, r1, 0, imm, 0);
        self.e.mov(r1, 0, imm, (long)(1UL << 63));
        void* finish = jit::sljit_emit_jump(self.e.compiler, jit::SLJIT_JUMP);
        self.e.bind(nonzero);
        self.e.bind(negative);
        self.box(r1);
        self.e.bind(finish);
        self.e.bind(done);
        self.store(ins.a, r1, pc);
        return;
    }
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
        skip_float = jit::sljit_emit_fcmp(self.e.compiler, loop_float_condition(ins.op) ^ 1, 1, 0, 2, 0);
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
    switch (op) {
        case JMP_NLT:
        case JMP_NLTI: return jit::SLJIT_SIG_GREATER_EQUAL;
        case JMP_NLE:
        case JMP_NLEI: return jit::SLJIT_SIG_GREATER;
        case JMP_NGT:
        case JMP_NGTI: return jit::SLJIT_SIG_LESS_EQUAL;
        case JMP_NGE:
        case JMP_NGEI: return jit::SLJIT_SIG_LESS;
        case JMP_LT:
        case JMP_LTI: return jit::SLJIT_SIG_LESS;
        case JMP_LE:
        case JMP_LEI: return jit::SLJIT_SIG_LESS_EQUAL;
        case JMP_GT:
        case JMP_GTI: return jit::SLJIT_SIG_GREATER;
        case JMP_GE:
        case JMP_GEI: return jit::SLJIT_SIG_GREATER_EQUAL;
        case JMP_EQ:
        case JMP_SEQ:
        case JMP_SEQI: return jit::SLJIT_EQUAL;
        case JMP_NEQ:
        case JMP_SNEQ:
        case JMP_SNEQI: return jit::SLJIT_NOT_EQUAL;
        default: unreachable("loop_condition relation opcode");
    }
}
// Negated relations include unordered inputs; ordinary relations exclude NaNs.
fn int loop_float_condition(Opcode op) @feat(SLJIT) {
    switch (op) {
        case JMP_NLT:
        case JMP_NLTI: return jit::SLJIT_UNORDERED_OR_GREATER_EQUAL;
        case JMP_NLE:
        case JMP_NLEI: return jit::SLJIT_UNORDERED_OR_GREATER;
        case JMP_NGT:
        case JMP_NGTI: return jit::SLJIT_UNORDERED_OR_LESS_EQUAL;
        case JMP_NGE:
        case JMP_NGEI: return jit::SLJIT_UNORDERED_OR_LESS;
        case JMP_LT:
        case JMP_LTI: return jit::SLJIT_ORDERED_LESS;
        case JMP_LE:
        case JMP_LEI: return jit::SLJIT_ORDERED_LESS_EQUAL;
        case JMP_GT:
        case JMP_GTI: return jit::SLJIT_ORDERED_GREATER;
        case JMP_GE:
        case JMP_GEI: return jit::SLJIT_ORDERED_GREATER_EQUAL;
        case JMP_EQ:
        case JMP_SEQ:
        case JMP_SEQI: return jit::SLJIT_ORDERED_EQUAL;
        case JMP_NEQ:
        case JMP_SNEQ:
        case JMP_SNEQI: return jit::SLJIT_UNORDERED_OR_NOT_EQUAL;
        default: unreachable("loop_float_condition relation opcode");
    }
}
fn LoopNative loop_emit(LoopPlan* plan, CompiledFunction* cf, Heap* h) @feat(SLJIT) {
    LoopEmitter out    = { .e = { .compiler = jit::sljit_create_compiler(null) }, .plan = plan, .heap = h };
    TemplateEmitter* e = &out.e;
    if (!e.compiler) return null;
    defer jit::sljit_free_compiler(e.compiler);
    out.labels = out.labels_alloc(plan.end - plan.begin);
    if (out.labels == null) return null;
    defer out.labels_free();
    defer out.link_release();
    if (jit::sljit_emit_enter(e.compiler, 0, jit::SLJIT_ARGS2WWW_R, 8 | (6 << 8), 5, 0) != 0) return null;
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
    for (uint i = 0; i < LOOP_REGS; i++) if (plan.cache[i] != 0) e.mov(
        plan.cache[i],
        0,
        mem | state,
        loop_value_offset(i)
    );
    for (uint i = 0; i < LOOP_REGS; i++) if (plan.float_cache[i] != 0) {
        e.mov(r0, 0, mem | state, loop_value_offset(i));
        out.number(r0, plan.float_cache[i], plan.begin);
    }
    for (uint i = 0; i < LOOP_REGS; i++) if (plan.cache[i] != 0 && (plan.canonical & (1UL << i)) != 0) {
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
            case GETTHISC:
            case GETPROPC:
            case GETPROPC_CACHED:
                if (plan.memory[memory].kind == SHAPE_FIELD) {
                    LoopMemorySpec spec = plan.memory[memory];
                    out.load(ins.b, r0);
                    e.op(jit::SLJIT_LSHR, r3, r0, 0, imm, 48);
                    out.guard(jit::SLJIT_NOT_EQUAL, r3, 0, imm, (long)types::TAG_OBJECT, pos);
                    e.op(jit::SLJIT_AND, r0, r0, 0, imm, (long)types::NANBOX_PAYLOAD_MASK);
                    out.guard(jit::SLJIT_EQUAL, r0, 0, imm, 0, pos);
                    HObject probe;
                    long shape_offset = (char*)&probe.shape_id - (char*)&probe;
                    long alloc_offset = (char*)&probe.prop_alloc - (char*)&probe;
                    e.mov(r2, 0, mem | r0, shape_offset, jit::SLJIT_MOV_U32);
                    out.guard(jit::SLJIT_NOT_EQUAL, r2, 0, imm, (long)spec.shape, pos);
                    e.mov(r1, 0, mem | r0, alloc_offset);
                    void* allocated = e.cmp(jit::SLJIT_NOT_EQUAL, r1, 0, imm, 0);
                    e.op(jit::SLJIT_ADD, r1, r0, 0, imm, HObjectBase::size);
                    e.bind(allocated);
                    e.mov(r0, 0, mem | r1, (long)spec.slot * 8);
                    if (spec.doubles) {
                        e.op(jit::SLJIT_LSHR, r3, r0, 0, imm, 48);
                        out.guard(jit::SLJIT_GREATER_EQUAL, r3, 0, imm, (long)types::TAG_FASTINT, pos);
                        out.fop(jit::SLJIT_MOV_F64, 1, 0, r1, (long)spec.slot * 8);
                        out.float_result(1);
                    }
                    break;
                }
                if (plan.memory[memory].kind == FIELD) {
                    e.mov(r1, 0, mem | state, loop_memory_offset(memory, 1));
                    if (plan.memory[memory].doubles) {
                        e.mov(r0, 0, mem | r1, 0);
                        e.op(jit::SLJIT_LSHR, r3, r0, 0, imm, 48);
                        out.guard(jit::SLJIT_GREATER_EQUAL, r3, 0, imm, (long)types::TAG_FASTINT, pos);
                        out.fop(jit::SLJIT_MOV_F64, 1, 0, mem | r1, 0);
                        out.float_result(1);
                    } else {
                        e.mov(r0, 0, mem | r1, 0);
                    }
                    break;
                }
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
            case MOD:
                out.numeric(ins, pos);
                continue;
            case BAND: case BOR: case BXOR: case SHL: case SHR: case USHR:
            case BANDI: case BORI: case BXORI: case SHLI: case SHRI: case USHRI:
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
            default: return null;
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
        LoopLink link = *out.link_at(i);
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
    for (uint i = 0; i < LOOP_REGS; i++) if (plan.cache[i] != 0) e.mov(
        mem | state,
        loop_value_offset(i),
        plan.cache[i],
        0
    );
    for (uint i = 0; i < LOOP_REGS; i++) if (plan.float_cache[i] != 0) {
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

fn void sljit_loop_release(Heap* h, JitArtifact* artifact) @feat(SLJIT) {
    LoopPlan* plan = artifact.payload;
    if (plan.native != null) jit::sljit_free_code((void*)plan.native, null);
    ssa_helper_sites_free(h, plan);
    ssa_plan_data_free(h, plan);
    ssa_scratch_free_all(h, plan);
    h.free_func(h.heap_udata, plan);
}

fn void sljit_loop_free(Heap* h, CompiledFunction* cf) @feat(SLJIT) {
    LoopPlan* plan = cf.sljit_loops;
    cf.sljit_loops = null;
    cf.sljit_loop_ready = 0;
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
        sljit_artifact_retire(h, &plan.artifact);
        plan = next;
    }
    cf.sljit_loops = null;
    cf.sljit_loop_ready = 0;
}
fn bool sljit_loop_probe(Instruction* pc, CompiledFunction* cf, Heap* h) @feat(SLJIT) @inline {
    uint offset = (uint)(pc - cf.code);
    for (LoopPlan* plan = cf.sljit_loops; plan != null; plan = plan.next) {
        if (offset == plan.end) return true;
    }
    // Unsupported and capacity-rejected sites are tracked independently by PC.
    if (sljit_loop_blocked(cf, offset)) return false;
    if (cf.num_regs > LOOP_REGS) {
        int target = loop_target(*pc, offset);
        if (target < 0 || target >= (int)offset || offset - (uint)target >= LOOP_SPAN) {
            sljit_loop_decline(h, cf, offset);
            return false;
        }
    }
    int target = loop_target(*pc, offset);
    return target >= 0 && target < (int)offset;
}
// Map every high register used by the loop to a free low slot. The chosen
// slots are unused in the loop, so their interpreter values need no recovery.
fn bool loop_highreg_prepare(CompiledFunction* cf, uint begin, uint end,
    uint[compiler::BYTECODE_REGS_MAX]* map, int[LOOP_REGS]* slot_reg, bool apply) @feat(SLJIT) {
    if (cf.num_regs > compiler::BYTECODE_REGS_MAX) return false;
    for (uint i = 0; i < compiler::BYTECODE_REGS_MAX; i++) (*map)[i] = i;
    for (uint i = 0; i < LOOP_REGS; i++) (*slot_reg)[i] = (int)i;
    uint[32] used_words;
    compiler::RegSet used = { .words = &used_words[0], .word_count = 32 };
    compiler::bytecode_register_set(cf.code, begin, end, &used);
    ulong low = (ulong)used_words[0] | ((ulong)used_words[1] << 32);
    bool aliased;
    for (uint reg = LOOP_REGS; reg < cf.num_regs; reg++) {
        if (!used.test(reg)) continue;
        uint slot;
        while (slot < LOOP_REGS && (low & (1UL << slot)) != 0) slot++;
        if (slot == LOOP_REGS) return false;
        (*map)[reg] = slot;
        (*slot_reg)[slot] = (int)reg;
        low |= 1UL << slot;
        aliased = true;
    }
    if (!aliased) return true;
    return !apply || compiler::bytecode_remap_registers(cf.code, begin, end, *map);
}

fn void loop_import_state(LoopPlan* plan, LoopState* state, TVal* regs, uint window) @feat(SLJIT) {
    for (uint i = 0; i < window; i++) {
        int reg = plan.slot_reg[i];
        state.values[i] = reg >= 0 && (uint)reg != i ? regs[reg] : regs[i];
    }
}

// Whether the region contains a backedge other than its own latch.
fn bool loop_inner_backedge(LoopPlan* plan, CompiledFunction* cf) @feat(SLJIT) {
    for (uint pos = plan.begin; pos < plan.end; pos++) {
        int target = loop_target(cf.code[pos], pos);
        if (target >= 0 && target <= (int)pos) return true;
    }
    return false;
}

// Analyze and emit one loop whose high registers are aliased to free low
// slots. The bytecode is remapped only while the graph and native body are
// being built; the caller's interpreter code is restored before return.
fn bool loop_highreg_compile(CompiledFunction* cf, uint offset, TVal* regs, ColdCtx* cold, Heap* h,
    LoopPlan* draft) @feat(SLJIT) {
    int target = loop_target(cf.code[offset], offset);
    if (target < 0 || offset - (uint)target >= LOOP_SPAN) return false;
    uint[compiler::BYTECODE_REGS_MAX] map;
    int[LOOP_REGS] slot_reg;
    Instruction[LOOP_SPAN] saved;
    if (!loop_highreg_prepare(cf, (uint)target, offset, &map, &slot_reg, false)) return false;
    for (uint q = 0; q <= offset - (uint)target; q++) saved[q] = cf.code[(uint)target + q];
    defer {
        for (uint q = 0; q <= offset - (uint)target; q++) cf.code[(uint)target + q] = saved[q];
    }
    if (!loop_highreg_prepare(cf, (uint)target, offset, &map, &slot_reg, true)) return false;
    TVal[LOOP_REGS] alias_regs;
    for (uint i = 0; i < LOOP_REGS; i++) alias_regs[i] = regs[i];
    for (uint i = 0; i < LOOP_REGS; i++) if (slot_reg[i] != (int)i) alias_regs[i] = regs[slot_reg[i]];
    if (!loop_analyze(draft, offset, &alias_regs[0], cold, -1, SSA_ENABLED, null, SSA_CYCLIC && SSA_CYCLIC_REGIONS)) return false;
    draft.slot_reg = slot_reg;
    draft.ssa_cyclic = SSA_CYCLIC && SSA_CYCLIC_REGIONS && loop_inner_backedge(draft, cf);
    draft.native = ssa_loop_eligible(draft, cf, h) ? ssa_loop_emit(draft, cf, h) : null;
    draft.ssa = draft.native != null;
    if (draft.native == null && !draft.ssa_calls && !draft.ssa_cyclic) {
        for (uint i = 0; i < draft.memory_count; i++) draft.memory[i].doubles = false;
        draft.native = loop_emit(draft, cf, h);
    }
    return draft.native != null;
}

// Rebuild a plan's native body from the function's bytecode. The interpreter's
// copy is never rewritten, so an aliased plan re-installs its slot mapping only
// while the emitter reads it.
fn LoopNative loop_reemit(LoopPlan* plan, CompiledFunction* cf, Heap* h, bool ssa) @feat(SLJIT) {
    uint[compiler::BYTECODE_REGS_MAX] map;
    for (uint i = 0; i < compiler::BYTECODE_REGS_MAX; i++) map[i] = i;
    bool aliased;
    for (uint i = 0; i < LOOP_REGS; i++) {
        int reg = plan.slot_reg[i];
        if (reg < 0 || (uint)reg == i) continue;
        map[reg] = i;
        aliased = true;
    }
    Instruction[LOOP_SPAN] saved;
    uint span = plan.end - plan.begin;
    if (aliased) for (uint q = 0; q <= span; q++) saved[q] = cf.code[plan.begin + q];
    defer if (aliased) for (uint q = 0; q <= span; q++) cf.code[plan.begin + q] = saved[q];
    if (aliased && !compiler::bytecode_remap_registers(cf.code, plan.begin, plan.end, map)) return null;
    return ssa ? ssa_loop_emit(plan, cf, h) : loop_emit(plan, cf, h);
}

fn Instruction* sljit_loop_entry(Instruction* pc, Instruction* body, TVal* regs, ColdCtx* cold) @feat(SLJIT) @noinline {
    Heap* h              = cold.heap;
    $if $feat(SLJIT_ADAPTIVE): h.jit_clock++; $endif
    CompiledFunction* cf = cold.vm.current_func;
    sljit_budget_retry_function(h, cf);
    if (!h.jit_enabled || !types::USE_NANBOX || usz::size != 8 || h.uncatchable_throw
        || std::core::mem::@atomic_load(
        h.interrupt_requested
    ) != 0) return body;
    uint offset = (uint)(pc - cf.code);
    uint window = cf.num_regs < LOOP_REGS ? cf.num_regs : LOOP_REGS;
    if (loop_target(*pc, offset) != (int)(body - cf.code)) return body;
    // A retired edge stays retired: the plan may still be linked below, but
    // re-entering it has been measured as a loss.
    if (sljit_loop_blocked(cf, offset)) return body;
    long budget     = h.bwd_gc_budget;
    bool interrupts = h.capi_runtime != null || h.capi_interrupt_fn != null;
    if (interrupts && (long)h.interrupt_budget < budget) budget = h.interrupt_budget;
    // Only the registers and descriptors filled below are read, so skip the
    // per-entry clear of a state area that is mostly scratch space.
    LoopState state @noinit;
    for (uint i = 0; i < window; i++) state.values[i] = regs[i];
    LoopPlan* plan;
    bool prepared;
    uint plans;
    for (LoopPlan* candidate = cf.sljit_loops; candidate != null; candidate = candidate.next) {
        plans++;
        if (offset != candidate.end || candidate.native == null) continue;
        loop_import_state(candidate, &state, regs, window);
        if (loop_prepare(candidate, &state, cold)) {
            plan = candidate;
            prepared = true;
            break;
        }
    }
    if (plan == null) {
        cf.sljit_loop_ready &= ~(1U << (offset & 31));
        int target = loop_target(*pc, offset);
        if (target < 0 || target >= (int)offset || sljit_loop_blocked(cf, offset)) return body;
        if (plans >= 4 || !sljit_code_room(h, 0)) {
            sljit_loop_decline(h, cf, offset, true);
            return body;
        }
        LoopPlan draft;
        bool compiled;
        if (cf.num_regs > LOOP_REGS) {
            compiled = loop_highreg_compile(cf, offset, regs, cold, h, &draft);
        } else {
            if (!loop_analyze(&draft, offset, regs, cold, -1, SSA_ENABLED, null, SSA_CYCLIC && SSA_CYCLIC_REGIONS)) {
                sljit_loop_decline(h, cf, offset);
                return body;
            }
            draft.ssa_cyclic = SSA_CYCLIC && SSA_CYCLIC_REGIONS && loop_inner_backedge(&draft, cf);
            draft.native = ssa_loop_eligible(&draft, cf, h) ? ssa_loop_emit(&draft, cf, h) : null;
            draft.ssa = draft.native != null;
            if (draft.native == null && !draft.ssa_calls && !draft.ssa_cyclic) {
                for (uint i = 0; i < draft.memory_count; i++) draft.memory[i].doubles = false;
                draft.native = loop_emit(&draft, cf, h);
            }
            compiled = draft.native != null;
        }
        if (!compiled) {
            sljit_loop_decline(h, cf, offset);
            return body;
        }
        if (!sljit_code_room(h, draft.code_bytes)) {
            sljit_loop_decline(h, cf, offset, true);
            jit::sljit_free_code((void*)draft.native, null);
            return body;
        }
        plan = (LoopPlan*)h.alloc_func(h.heap_udata, LoopPlan::size);
        if (plan == null) {
            jit::sljit_free_code((void*)draft.native, null);
            sljit_loop_decline(h, cf, offset);
            return body;
        }
        *plan = draft;
        plan.next = cf.sljit_loops;
        cf.sljit_loops = plan;
        sljit_artifact_publish(h, &plan.artifact, cf, plan, LOOP_CODE,
            plan.code_bytes, sljit_loop_metadata_bytes(plan), &sljit_loop_release);
        plan.code_owner = &plan.artifact;
        $if $feat(SLJIT_STATS):
            io::eprintfn(
                "SLJIT loop compiled %s pc=%d..%d code_bytes=%d plan_bytes=%d ssa=%d mem=%d",
                (String)cf.get_name(),
                plan.begin,
                plan.end,
                plan.code_bytes,
                LoopPlan::size,
                plan.ssa,
                plan.memory_count
            );
        $endif
    }
    if (h.interrupt_due || budget <= 1) return body;
    if (!prepared) {
        loop_import_state(plan, &state, regs, window);
        if (!loop_prepare(plan, &state, cold)) return body;
    }
    if (sljit_artifact_enter(h, &plan.artifact) == 0) return body;
    defer sljit_artifact_leave(h, &plan.artifact);
    uint resume_pc = plan.native(&state, budget);
    uint consumed  = (uint)(budget - state.budget);
    $if $feat(SLJIT_STATS):
    if (plan.ssa) { plan.ssa_hits++; plan.ssa_iterations += consumed; }
    $endif
    // A guard exit means the SSA speculation did not hold. When an integer
    // operation overflowed, retry once with that register held as a double:
    // JavaScript numbers are IEEE doubles, so the wider representation is
    // exact. Anything else falls back to the straight-line loop tier instead
    // of retrying the same speculation at every safepoint.
    // A depleted budget is a normal safepoint, including at an interior
    // backedge of a cyclic region; it does not disprove any speculation.
    // Call-expanded kernels have no straight-line template equivalent. Keep
    // their guarded code for future matching inputs and publish this miss's
    // exact caller state below before the interpreter replays the call.
    if (plan.ssa && !plan.ssa_calls && state.budget > 1
        && resume_pc >= plan.begin && resume_pc < plan.end
        && sljit_artifact_retire_fragment(h, &plan.artifact, (void*)plan.native, plan.code_bytes)) {
        $if $feat(SLJIT_STATS):
            io::eprintfn("SLJIT ssa fallback name=%s begin=%d pc=%d opcode=%s iterations=%d",
                (String)cf.get_name(), plan.begin, resume_pc, cf.code[resume_pc].op, consumed);
        $endif
        plan.native = null;
        plan.code_bytes = 0;
        // Widening only helps when an integer operation overflowed; any other
        // guard exit (a shape or tag mismatch) needs the straight-line tier.
        bool overflow;
        if (resume_pc < cf.code_count) {
            switch (cf.code[resume_pc].op) {
                case ADD:
                case ADD_FUSED:
                case ADDI:
                case SUB:
                case SUBI:
                case MUL:
                case MULI:
                case INC:
                case INC_LT:
                case DEC: overflow = true; break;
                default: break;
            }
        }
        uint widened = resume_pc < cf.code_count ? cf.code[resume_pc].a : LOOP_REGS;
        ulong want;
        if (plan.memory_count == 0) {
            // A pure numeric loop has no index arithmetic to spoil, so the
            // whole loop moves to doubles at once. Mixed representations would
            // convert on every iteration.
            want = (1UL << cf.num_regs) - 1;
            if (cf.num_regs >= 64) want = ~0UL;
        } else if (widened < LOOP_REGS) {
            want = 1UL << widened;
        }
        if (overflow && want != 0 && (want & ~plan.ssa_double) != 0 && plan.ssa_retries < 2) {
            plan.ssa_double |= want;
            plan.ssa_retries++;
            plan.native = loop_reemit(plan, cf, h, true);
        }
        plan.ssa = plan.native != null;
        if (plan.native == null && !plan.ssa_cyclic) {
            for (uint i = 0; i < plan.memory_count; i++) plan.memory[i].doubles = false;
            plan.native = loop_reemit(plan, cf, h, false);
        }
        if (plan.native != null && !sljit_code_room(h, plan.code_bytes)) {
            jit::sljit_free_code((void*)plan.native, null);
            plan.native = null;
            plan.code_bytes = 0;
            sljit_loop_decline(h, cf, offset, true);
        }
        if (plan.native == null) {
            if (!sljit_loop_blocked(cf, offset)) sljit_loop_decline(h, cf, offset);
        } else {
            h.jit_code_bytes += plan.code_bytes;
            plan.artifact.code_bytes += plan.code_bytes;
        }
        // A retired cyclic kernel may already have committed stores. Its
        // completed prefix and exact frame must still be published below.
    }
    // Failed guards retry at ordinary interpreter safepoints. Hash collisions
    // can only add a switch dispatch or delay another region's native entry.
    uint ready = 1U << (offset & 31);
    if (plan.native == null) {
        cf.sljit_loop_ready &= ~ready;
    } else if (consumed == 0 && resume_pc >= plan.begin && resume_pc <= plan.end) {
        cf.sljit_loop_ready &= ~ready;
        // The loop tier shares the function tier's rule: a plan that keeps
        // being entered without completing an iteration only pays for an entry
        // and a publication, so let the interpreter own the loop.
        if (++plan.short_runs >= 8) sljit_loop_decline(h, cf, offset);
    } else {
        plan.short_runs = 0;
        cf.sljit_loop_ready |= ready;
    }
    h.bwd_gc_budget -= consumed;
    sljit_budget_progress(h, consumed);
    if (interrupts) h.interrupt_budget -= consumed;
    sljit_publish_state(cold, regs, &state, window, plan);
    plan.hits++;
    plan.iterations += consumed;
    return cf.code + resume_pc;
}

// Publish after native frames return. Retain incoming strings before releasing
// any outgoing slot, preserving permutations and aliases in both SSA modes.
fn void sljit_publish_state(ColdCtx* cold, TVal* regs, LoopState* state, uint count, LoopPlan* plan = null) @feat(SLJIT) {
    Heap* h = cold.heap;
    for (uint i = 0; i < count; i++) {
        if ((state.dirty & (1UL << i)) != 0 && state.values[i].is_refcounted()
            && state.values[i].get_heapptr() != null) ((HeapHeader*)state.values[i].get_heapptr()).incref();
    }
    for (uint i = 0; i < count; i++) {
        if ((state.dirty & (1UL << i)) == 0) continue;
        uint reg = plan != null ? (uint)plan.slot_reg[i] : i;
        h.tval_copy_ref(regs + reg, &state.values[i]);
        h.decref_tval(&state.values[i]);
        if (regs[reg].is_heap_allocated()) track_heap_store(cold.act, regs + reg, reg);
    }
}
