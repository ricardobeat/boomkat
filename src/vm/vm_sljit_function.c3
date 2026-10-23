module boomkat::vm;

import boomkat::bytecode;
import boomkat::types;
import boomkat::heap;
import boomkat::hobject;
import boomkat::hstring;
import boomkat::env;
import boomkat::jit;
import std::io;
import std::core::mem;

const uint FUNCTION_OPS = 512;
const uint FUNCTION_CAPTURES = 8;
alias FunctionNative = fn uint(TVal* regs, ColdCtx* cold, void* entry);

// VM registers own every published value. Calls, allocation, backward edges,
// and exceptional operations return to the interpreter before executing them.
struct FunctionPlan @feat(SLJIT) {
    FunctionNative native;
    void** entries;
    char* short_runs;
    uint capture_writes;
    char[LOOP_REGS] cache;
    uint heap_regs;
    char[4] cached_regs;
    uint cache_count;
    uint[32] shapes;
    uint[32] generations;
    uint shape_count;
    uint shape_clock;
    uint shape_epoch;
    bool receiver;
    usz code_bytes;
    ulong hits @if($feat(SLJIT_STATS));
    ulong completed @if($feat(SLJIT_STATS));
    ulong stalled @if($feat(SLJIT_STATS));
}
struct FunctionEmitter @feat(SLJIT) {
    LoopEmitter out;
    FunctionPlan* plan;
}

fn bool function_op(Opcode op) @feat(SLJIT) {
    switch (op) {
        case NOP: case LDREG: case LDTHIS: case LDINT: case LDCONST:
        case LDTRUE: case LDFALSE: case LDNULL: case LDUNDEF: case VOID:
        case GETCAP: case PUTCAP: case INC_VAR: case DEC_VAR:
        case GETVAR: case GETGLOBAL: case GETPROPC: case GETPROPC_CACHED: case PUTPROPC:
        case GETPROP: case GETPROP_CACHE: case PUTPROP: case GETTHISC: case PUTTHISC:
        case TONUMERIC: case INC: case INC_LT: case DEC: case LNOT: case TYPEOF:
        case ADD: case ADD_FUSED: case ADDI: case SUB: case SUBI: case MUL: case MULI: case DIV:
        case LT: case LE: case GT: case GE: case SEQ: case SNEQ: case IF_TRUE: case IF_FALSE: case JUMP:
        case JMP_NLT..JMP_SNEQ: case JMP_NLTI..JMP_SNEQI:
            return true;
        default: return false;
    }
}
fn int function_capture(CompiledFunction* cf, uint name) @feat(SLJIT) {
    if (name >= cf.const_count) return -1;
    for (uint i = 0; i < cf.capture_count; i++) {
        if (cf.constants[cf.capture_names[i]].same_bits(&cf.constants[name])) return (int)i;
    }
    return -1;
}
fn int function_capture_index(CompiledFunction* cf, Instruction ins) @feat(SLJIT) {
    int index = ins.op == Opcode.GETCAP || ins.op == Opcode.PUTCAP
        ? (int)ins.get_bc() : function_capture(cf, ins.get_bc());
    return index >= 0 && index < (int)cf.capture_count ? index : -1;
}
fn bool function_analyze(CompiledFunction* cf, FunctionPlan* plan) @feat(SLJIT) {
    if (cf.code_count > FUNCTION_OPS || cf.num_regs > LOOP_REGS || cf.capture_count > FUNCTION_CAPTURES
        || cf.flags.is_generator || cf.flags.is_async || cf.flags.has_direct_eval || cf.mapped_arguments()
        || cf.sljit_loops != null) return false;
    uint useful;
    uint[LOOP_REGS] frequency;
    for (uint pos = 0; pos < cf.code_count; pos++) {
        Instruction ins = cf.code[pos];
        // WIDE payloads cannot be decoded independently on a native resume.
        if (ins.op == Opcode.WIDE) return false;
        if (!function_op(ins.op)) continue;
        if (ins.a < cf.num_regs) frequency[ins.a]++;
        if (ins.b < cf.num_regs) frequency[ins.b]++;
        if (ins.c < cf.num_regs) frequency[ins.c]++;
        if (ins.op == Opcode.GETCAP || ins.op == Opcode.GETVAR || ins.op == Opcode.GETGLOBAL || ins.op == Opcode.LDREG
            || ins.op == Opcode.LDCONST || ins.op == Opcode.GETPROPC || ins.op == Opcode.GETPROPC_CACHED
            || ins.op == Opcode.LDTHIS || ins.op == Opcode.TYPEOF || ins.op == Opcode.GETPROP || ins.op == Opcode.GETPROP_CACHE || ins.op == Opcode.GETTHISC) {
            if (ins.a + 1 > plan.heap_regs) plan.heap_regs = (uint)ins.a + 1;
        }
        if (ins.op == Opcode.GETCAP || ins.op == Opcode.PUTCAP || ins.op == Opcode.INC_VAR || ins.op == Opcode.DEC_VAR) {
            int cap = function_capture_index(cf, ins);
            if (cap < 0) continue;
            if (ins.op != Opcode.GETCAP) plan.capture_writes |= 1U << cap;
        }

        if (ins.op == Opcode.LDTHIS || ins.op == Opcode.GETTHISC || ins.op == Opcode.PUTTHISC) plan.receiver = true;
        if (ins.op == Opcode.GETPROPC || ins.op == Opcode.GETPROPC_CACHED || ins.op == Opcode.INC_VAR
            || ins.op == Opcode.PUTCAP || ins.op == Opcode.PUTPROPC || ins.op == Opcode.GETTHISC || ins.op == Opcode.PUTTHISC
            || ins.op == Opcode.GETPROP || ins.op == Opcode.GETPROP_CACHE || ins.op == Opcode.PUTPROP) useful++;
    }
    for (uint i = 0; i < 4; i++) {
        uint best;
        for (uint j = 1; j < cf.num_regs; j++) if (frequency[j] > frequency[best]) best = j;
        if (frequency[best] < 2) break;
        plan.cache[best] = (char)jit::reg_r((int)i + 4); frequency[best] = 0;
        plan.cached_regs[plan.cache_count++] = (char)best;
    }
    return useful >= 2;
}
fn long function_cold_offset(uint field) @feat(SLJIT) {
    ColdCtx cold;
    return field == 0 ? (char*)&cold.heap - (char*)&cold : (char*)&cold.act - (char*)&cold;
}
fn void function_store(LoopEmitter* out, uint reg, int source, uint pc, bool inert = false) @feat(SLJIT) {
    TemplateEmitter* e = &out.e;
    int r0 = jit::reg_r(0); int r1 = jit::reg_r(1); int r2 = jit::reg_r(2); int r3 = jit::reg_r(3);
    int imm = jit::SLJIT_IMM; int mem = jit::SLJIT_MEM;
    if (source != r0) e.mov(r0, 0, source, 0);
    if (out.plan.cache[reg] != 0) {
        // Cache values are borrowed until native exit. Original VM slots keep
        // their owners alive; no call, allocation or collection occurs here.
        e.mov(out.plan.cache[reg], 0, r0, 0);
        return;
    }
    out.load(reg, r1);
    HeapHeader header; long refs = (char*)&header.refcount - (char*)&header;
    e.op(jit::SLJIT_LSHR, r3, r1, 0, imm, 48);
    void* old_inert = e.cmp(jit::SLJIT_NOT_EQUAL, r3, 0, imm, (long)types::TAG_STRING);
    e.op(jit::SLJIT_AND, r2, r1, 0, imm, (long)types::NANBOX_PAYLOAD_MASK);
    void* old_null = e.cmp(jit::SLJIT_EQUAL, r2, 0, imm, 0);
    void* same = e.cmp(jit::SLJIT_EQUAL, r0, 0, r1, 0);
    e.mov(r3, 0, mem | r2, refs, jit::SLJIT_MOV_U32);
    out.guard(jit::SLJIT_LESS_EQUAL, r3, 0, imm, 1, pc);
    e.bind(same); e.bind(old_null); e.bind(old_inert);
    if (!inert) {
        e.op(jit::SLJIT_LSHR, r3, r0, 0, imm, 48);
        void* new_inert = e.cmp(jit::SLJIT_NOT_EQUAL, r3, 0, imm, (long)types::TAG_STRING);
        e.op(jit::SLJIT_AND, r2, r0, 0, imm, (long)types::NANBOX_PAYLOAD_MASK);
        void* new_null = e.cmp(jit::SLJIT_EQUAL, r2, 0, imm, 0);
        e.mov(r3, 0, mem | r2, refs, jit::SLJIT_MOV_U32);
        void* new_pinned = e.cmp(jit::SLJIT_EQUAL, r3, 0, imm, types::STRING_PINNED_REFCOUNT);
        e.op(jit::SLJIT_ADD, r3, r3, 0, imm, 1); e.mov(mem | r2, refs, r3, 0, jit::SLJIT_MOV_U32);
        e.bind(new_pinned); e.bind(new_null); e.bind(new_inert);
    }
    e.op(jit::SLJIT_LSHR, r3, r1, 0, imm, 48);
    void* release_inert = e.cmp(jit::SLJIT_NOT_EQUAL, r3, 0, imm, (long)types::TAG_STRING);
    e.op(jit::SLJIT_AND, r2, r1, 0, imm, (long)types::NANBOX_PAYLOAD_MASK);
    void* release_null = e.cmp(jit::SLJIT_EQUAL, r2, 0, imm, 0);
    e.mov(r3, 0, mem | r2, refs, jit::SLJIT_MOV_U32);
    void* release_pinned = e.cmp(jit::SLJIT_EQUAL, r3, 0, imm, types::STRING_PINNED_REFCOUNT);
    e.op(jit::SLJIT_SUB, r3, r3, 0, imm, 1); e.mov(mem | r2, refs, r3, 0, jit::SLJIT_MOV_U32);
    e.bind(release_pinned); e.bind(release_null); e.bind(release_inert);
    int cached = out.plan.cache[reg];
    e.mov(cached != 0 ? cached : mem | jit::reg_s(0), cached != 0 ? 0 : loop_value_offset(reg), r0, 0);
}
fn void FunctionEmitter.store(&self, uint reg, uint pc, bool known = false) @feat(SLJIT) {
    function_store(&self.out, reg, jit::reg_r(0), pc, known);
}

fn void FunctionEmitter.truth(&self, uint reg, uint pc) @feat(SLJIT) {
    TemplateEmitter* e = &self.out.e;
    int r0 = jit::reg_r(0); int r3 = jit::reg_r(3); int imm = jit::SLJIT_IMM;
    self.out.load(reg, r0);
    e.op(jit::SLJIT_LSHR, r3, r0, 0, imm, 48);
    void* integer = e.cmp(jit::SLJIT_EQUAL, r3, 0, imm, (long)types::TAG_FASTINT);
    void* boolean = e.cmp(jit::SLJIT_EQUAL, r3, 0, imm, (long)types::TAG_BOOLEAN);
    void* object = e.cmp(jit::SLJIT_EQUAL, r3, 0, imm, (long)types::TAG_OBJECT);
    self.out.guard(jit::SLJIT_LESS, r3, 0, imm, (long)types::TAG_UNDEFINED, pc);
    self.out.guard(jit::SLJIT_GREATER, r3, 0, imm, (long)types::TAG_NULL_VAL, pc);
    e.mov(r0, 0, imm, 0);
    void* done = jit::sljit_emit_jump(e.compiler, jit::SLJIT_JUMP);
    e.bind(object); e.mov(r0, 0, imm, 1);
    void* object_done = jit::sljit_emit_jump(e.compiler, jit::SLJIT_JUMP);
    e.bind(integer); e.bind(boolean);
    e.op(jit::SLJIT_SHL, r0, r0, 0, imm, 16);
    e.op(jit::SLJIT_ASHR, r0, r0, 0, imm, 16);
    e.bind(done); e.bind(object_done);
}
fn void FunctionEmitter.equal(&self, Instruction ins, bool immediate, bool negate, uint pc) @feat(SLJIT) {
    TemplateEmitter* e = &self.out.e;
    int r0 = jit::reg_r(0); int r1 = jit::reg_r(1); int r2 = jit::reg_r(2); int r3 = jit::reg_r(3);
    int imm = jit::SLJIT_IMM;
    self.out.load(ins.b, r0);
    if (immediate) { TVal v; v.set_fastint((ichar)ins.c); e.mov(r1, 0, imm, (long)loop_bits(v)); }
    else { self.out.load(ins.c, r1); }
    e.op(jit::SLJIT_LSHR, r2, r0, 0, imm, 48);
    e.op(jit::SLJIT_LSHR, r3, r1, 0, imm, 48);
    // Doubles retain the interpreter's numeric equality and NaN handling.
    self.out.guard(jit::SLJIT_LESS, r2, 0, imm, (long)types::TAG_FASTINT, pc);
    self.out.guard(jit::SLJIT_LESS, r3, 0, imm, (long)types::TAG_FASTINT, pc);
    void* same = e.cmp(jit::SLJIT_EQUAL, r0, 0, r1, 0);
    void* different_type = e.cmp(jit::SLJIT_NOT_EQUAL, r2, 0, r3, 0);
    self.out.guard(jit::SLJIT_EQUAL, r2, 0, imm, (long)types::TAG_STRING, pc);
    self.out.guard(jit::SLJIT_EQUAL, r2, 0, imm, (long)types::TAG_BIGINT, pc);
    e.bind(different_type);
    e.mov(r0, 0, imm, negate ? 1 : 0);
    void* done = jit::sljit_emit_jump(e.compiler, jit::SLJIT_JUMP);
    e.bind(same); e.mov(r0, 0, imm, negate ? 0 : 1); e.bind(done);
}
fn TVal* function_key_literal(CompiledFunction* cf, uint pc, uint reg) @feat(SLJIT) {
    for (uint back = pc; back > 0; back--) {
        Instruction ins = cf.code[back - 1];
        if (ins.a != reg || loop_target(ins, back - 1) >= 0 || ins.op == Opcode.PUTPROP || ins.op == Opcode.PUTPROPC
            || ins.op == Opcode.PUTTHISC) continue;
        if (ins.op == Opcode.LDREG) { reg = ins.b; continue; }
        if (ins.op == Opcode.LDCONST) return &cf.constants[ins.get_bc()];
        return null;
    }
    return null;
}
fn int function_shape_slot(Shape* shape, void* key, PropFlags* flags) @feat(SLJIT) {
    while (shape != null) {
        for (uint i = 0; i < shape.own_count; i++) {
            ShapeProperty* property = &shape.props()[i];
            if (property.key.borrow() == key) { *flags = property.flags; return (int)(shape.offset + i); }
        }
        shape = shape.parent_shape;
    }
    return -1;
}
fn bool FunctionEmitter.shape(&self, uint id, Heap* h) @feat(SLJIT) {
    Shape* shape = h.get_shape(id);
    if (shape == null) return false;
    for (uint i = 0; i < self.plan.shape_count; i++) if (self.plan.shapes[i] == id) return self.plan.generations[i] == shape.generation;
    if (self.plan.shape_count == self.plan.shapes.len) return false;
    uint slot = self.plan.shape_count++;
    self.plan.shapes[slot] = id; self.plan.generations[slot] = shape.generation;
    return true;
}
fn bool FunctionEmitter.property(&self, CompiledFunction* cf, uint pc, bool write, Heap* h) @feat(SLJIT) {
    TemplateEmitter* e = &self.out.e;
    Instruction ins = cf.code[pc];
    ICEntry* ic = (ICEntry*)cf.ic_entries + pc;
    bool receiver_this = ins.op == Opcode.GETTHISC || ins.op == Opcode.PUTTHISC;
    bool computed = ins.op == Opcode.GETPROP || ins.op == Opcode.GETPROP_CACHE || ins.op == Opcode.PUTPROP;
    uint value_reg = ins.op == Opcode.PUTTHISC ? ins.a : ins.op == Opcode.PUTPROP ? ins.c : ins.b;
    void* key = computed ? (void*)ic.key.borrow() : cf.constants[ins.c].get_heapptr();
    TVal* literal = computed ? function_key_literal(cf, pc, write ? ins.b : ins.c) : null;
    if (computed && literal != null && literal.is_string()) {
        HString* text = literal.get_heapptr();
        if (!text.is_symbol() && (String)text.get_data() == "length") key = h.str(heap::BuiltinStr.LENGTH);
    }
    // Shared read-cache hits can leave later sites unpopulated. Borrow a
    // warmed site's layout; generated guards still validate the live receiver.
    if (!computed && ic.key.borrow() == null) {
        for (uint i = 0; i < cf.code_count; i++) {
            if (cf.code[i].op != Opcode.GETPROPC && cf.code[i].op != Opcode.GETPROPC_CACHED) continue;
            ICEntry* candidate = (ICEntry*)cf.ic_entries + i;
            if (candidate.key.borrow() != key || candidate.prop_idx == hobject::IC_PROP_ABSENT
                || candidate.prop_flags.is_accessor) continue;
            Shape* layout = h.get_shape(candidate.shape_id);
            if (layout == null || layout.generation != candidate.shape_gen) continue;
            ic = candidate;
            break;
        }
    }
    int mem = jit::SLJIT_MEM; int imm = jit::SLJIT_IMM;
    int r0 = jit::reg_r(0); int r1 = jit::reg_r(1); int r2 = jit::reg_r(2); int r3 = jit::reg_r(3);
    if (computed) {
        self.out.load(write ? ins.b : ins.c, r1);
        bool matching = literal != null && literal.is_string();
        if (matching && literal.get_heapptr() != key) {
            HString* left = literal.get_heapptr(); HString* right = key;
            matching = right != null && !left.is_symbol() && !right.is_symbol() && (String)left.get_data() == (String)right.get_data();
        }
        self.out.guard(jit::SLJIT_NOT_EQUAL, r1, 0, imm, matching ? (long)loop_bits(*literal)
            : (long)((types::TAG_STRING << 48) | (ulong)key), pc);
    }
    if (receiver_this) { e.mov(r0, 0, jit::reg_s(3), 0); }
    else { self.out.load(write ? ins.a : ins.b, r0); }
    e.op(jit::SLJIT_LSHR, r3, r0, 0, imm, 48);
    self.out.guard(jit::SLJIT_NOT_EQUAL, r3, 0, imm, (long)types::TAG_OBJECT, pc);
    e.op(jit::SLJIT_AND, r0, r0, 0, imm, (long)types::NANBOX_PAYLOAD_MASK);
    self.out.guard(jit::SLJIT_EQUAL, r0, 0, imm, 0, pc);
    HObject obj;
    long shape_offset = (char*)&obj.shape_id - (char*)&obj;
    long proto_offset = (char*)&obj.prototype - (char*)&obj;
    ObjFlags forbidden; forbidden.exotic_proxyobj = true; forbidden.exotic_module_ns = true; forbidden.exotic_deferred_ns = true;
    ObjFlags ordinary; ordinary.obj_class = OBJECT;
    uint flag_mask = 0x003F0000U | (uint)forbidden;
    void* length_done;
    if (!write && key == h.str(heap::BuiltinStr.LENGTH)) {
        e.mov(r2, 0, mem | r0, 0, jit::SLJIT_MOV_U32);
        e.op(jit::SLJIT_AND, r2, r2, 0, imm, flag_mask);
        ObjFlags array; array.obj_class = ARRAY;
        void* other = e.cmp(jit::SLJIT_NOT_EQUAL, r2, 0, imm, (uint)array);
        e.mov(r0, 0, mem | r0, HObjectBase::size, jit::SLJIT_MOV_U32);
        self.out.box(r0); self.store(ins.a, pc, true);
        length_done = jit::sljit_emit_jump(e.compiler, jit::SLJIT_JUMP); e.bind(other);
    }
    Shape* shape = h.get_shape(ic.shape_id);
    bool usable = key != null && ic.key.borrow() == key && shape != null && shape.generation == ic.shape_gen
        && ic.chain_len <= hobject::IC_MAX_CHAIN && !ic.prop_flags.is_accessor
        && ic.prop_idx != hobject::IC_PROP_ABSENT && (!write || (ic.proto == null && ic.prop_flags.writable));
    if (usable) {
        usable = self.shape(ic.shape_id, h);
        PropFlags flags;
        int index = function_shape_slot(shape, key, &flags);
        if (ic.chain_len == 0) {
            usable = usable && index == (int)ic.prop_idx && !flags.is_accessor && (!write || flags.writable);
        } else {
            usable = usable && index < 0 && !shape.dict;
            for (uint i = 0; usable && i < ic.chain_len; i++) {
                // Cache links are weak. Validate layouts through the shape table;
                // generated code follows live links before dereferencing objects.
                Shape* proto_shape = h.get_shape(ic.chain_shapes[i]);
                usable = ic.chain_protos[i] != null && proto_shape != null && self.shape(ic.chain_shapes[i], h);
                if (!usable) break;
                index = function_shape_slot(proto_shape, key, &flags);
                if (i + 1 == ic.chain_len) { usable = index == (int)ic.prop_idx && !flags.is_accessor; }
                else { usable = index < 0 && !proto_shape.dict; }
            }
        }
    }
    if (!usable) { self.out.link(jit::sljit_emit_jump(e.compiler, jit::SLJIT_JUMP), pc, true); }
    else {
        e.mov(r2, 0, mem | r0, 0, jit::SLJIT_MOV_U32);
        e.op(jit::SLJIT_AND, r2, r2, 0, imm, flag_mask);
        self.out.guard(jit::SLJIT_NOT_EQUAL, r2, 0, imm, (uint)ordinary, pc);
        e.mov(r2, 0, mem | r0, shape_offset, jit::SLJIT_MOV_U32);
        self.out.guard(jit::SLJIT_NOT_EQUAL, r2, 0, imm, ic.shape_id, pc);
        for (uint i = 0; i < ic.chain_len; i++) {
            e.mov(r0, 0, mem | r0, proto_offset);
            self.out.guard(jit::SLJIT_NOT_EQUAL, r0, 0, imm, (long)ic.chain_protos[i], pc);
            e.mov(r2, 0, mem | r0, shape_offset, jit::SLJIT_MOV_U32);
            self.out.guard(jit::SLJIT_NOT_EQUAL, r2, 0, imm, ic.chain_shapes[i], pc);
            e.mov(r2, 0, mem | r0, 0, jit::SLJIT_MOV_U32);
            e.op(jit::SLJIT_AND, r2, r2, 0, imm, flag_mask);
            self.out.guard(jit::SLJIT_NOT_EQUAL, r2, 0, imm, (uint)ordinary, pc);
        }
        e.mov(r2, 0, mem | r0, (char*)&obj.prop_alloc - (char*)&obj);
        void* allocated = e.cmp(jit::SLJIT_NOT_EQUAL, r2, 0, imm, 0);
        e.op(jit::SLJIT_ADD, r2, r0, 0, imm, HObjectBase::size); e.bind(allocated);
        if (write) {
            e.mov(r0, 0, mem | r2, (long)ic.prop_idx * 8);
            e.op(jit::SLJIT_LSHR, r3, r0, 0, imm, 48);
            self.out.guard(jit::SLJIT_GREATER, r3, 0, imm, (long)types::TAG_BOOLEAN, pc);
            self.out.load(value_reg, r0);
            e.op(jit::SLJIT_LSHR, r3, r0, 0, imm, 48);
            self.out.guard(jit::SLJIT_GREATER, r3, 0, imm, (long)types::TAG_BOOLEAN, pc);
            e.mov(mem | r2, (long)ic.prop_idx * 8, r0, 0);
        } else { e.mov(r0, 0, mem | r2, (long)ic.prop_idx * 8); self.store(ins.a, pc); }
    }
    if (length_done != null) e.bind(length_done);
    return usable || length_done != null;
}

fn void FunctionEmitter.typeof_value(&self, CompiledFunction* cf, uint pc, Heap* h) @feat(SLJIT) {
    TemplateEmitter* e = &self.out.e;
    int r0 = jit::reg_r(0); int r1 = jit::reg_r(1); int r3 = jit::reg_r(3); int imm = jit::SLJIT_IMM;
    self.out.load(cf.code[pc].b, r0);
    e.op(jit::SLJIT_LSHR, r3, r0, 0, imm, 48);
    void*[5] cases;
    cases[0] = e.cmp(jit::SLJIT_LESS_EQUAL, r3, 0, imm, (long)types::TAG_FASTINT);
    cases[1] = e.cmp(jit::SLJIT_EQUAL, r3, 0, imm, (long)types::TAG_UNDEFINED);
    cases[2] = e.cmp(jit::SLJIT_EQUAL, r3, 0, imm, (long)types::TAG_NULL_VAL);
    cases[3] = e.cmp(jit::SLJIT_EQUAL, r3, 0, imm, (long)types::TAG_BOOLEAN);
    self.out.guard(jit::SLJIT_NOT_EQUAL, r3, 0, imm, (long)types::TAG_OBJECT, pc);
    e.op(jit::SLJIT_AND, r1, r0, 0, imm, (long)types::NANBOX_PAYLOAD_MASK);
    self.out.guard(jit::SLJIT_EQUAL, r1, 0, imm, 0, pc);
    e.mov(r3, 0, jit::SLJIT_MEM | r1, 0, jit::SLJIT_MOV_U32);
    ObjFlags callable; callable.callable = true;
    e.op(jit::SLJIT_AND, r3, r3, 0, imm, (uint)callable);
    cases[4] = e.cmp(jit::SLJIT_NOT_EQUAL, r3, 0, imm, 0);
    TVal v; v.set_string_borrowed(h.str(heap::BuiltinStr.OBJECT));
    e.mov(r0, 0, imm, (long)loop_bits(v));
    void*[6] finished;
    finished[0] = jit::sljit_emit_jump(e.compiler, jit::SLJIT_JUMP);
    heap::BuiltinStr[5] names = {NUMBER, UNDEFINED, OBJECT, BOOLEAN, FUNCTION};
    for (uint i = 0; i < 5; i++) {
        e.bind(cases[i]); v.set_string_borrowed(h.str(names[i]));
        e.mov(r0, 0, imm, (long)loop_bits(v));
        finished[i + 1] = jit::sljit_emit_jump(e.compiler, jit::SLJIT_JUMP);
    }
    void* end = e.label(); foreach (jump : finished) self.out.bind_to(jump, end);
    self.store(cf.code[pc].a, pc, true);
}
// Resolve the mutable capture once in the native prologue. Private cells need
// no name lookup; named captures guard skipped scopes and the writable layout.
fn bool FunctionEmitter.capture(&self, CompiledFunction* cf, Activation* act, Heap* h) @feat(SLJIT) {
    uint mask = self.plan.capture_writes;
    if (mask == 0) return true;
    if ((mask & (mask - 1)) != 0 || !act.tv_func.is_object()) return false;
    uint index; while ((mask & (1U << index)) == 0) index++;
    HObject* function = act.tv_func.get_heapptr();
    CaptureRef* refs = function.extra.func.capture_refs;
    HObject* owner;
    PropValue* slot = capture_value_slot(act, index, h, true, &owner);
    if (slot == null || owner == null || !slot.get().is_fastint() || owner.get_class() != OBJECT) return false;
    CaptureRef* ref = &refs[index];
    if (ref.is_value || (!ref.is_cell && !self.shape(owner.shape_id, h))) return false;
    TemplateEmitter* e = &self.out.e;
    int mem = jit::SLJIT_MEM; int imm = jit::SLJIT_IMM;
    int r0 = jit::reg_r(0); int r1 = jit::reg_r(1); int r2 = jit::reg_r(2); int r3 = jit::reg_r(3);
    int capture = jit::reg_s(4);
    Activation activation; HObject object; CaptureRef layout; EnvRecord scope_layout;
    e.mov(r2, 0, mem | jit::reg_s(1), function_cold_offset(1));
    e.mov(r0, 0, mem | r2, (char*)&activation.tv_func - (char*)&activation);
    e.op(jit::SLJIT_LSHR, r3, r0, 0, imm, 48);
    self.out.guard(jit::SLJIT_NOT_EQUAL, r3, 0, imm, (long)types::TAG_OBJECT, FUNCTION_OPS);
    e.op(jit::SLJIT_AND, r0, r0, 0, imm, (long)types::NANBOX_PAYLOAD_MASK);
    e.mov(r1, 0, mem | r0, (char*)&object.extra.func.capture_refs - (char*)&object);
    self.out.guard(jit::SLJIT_EQUAL, r1, 0, imm, 0, FUNCTION_OPS);
    e.op(jit::SLJIT_ADD, r1, r1, 0, imm, (long)(index * CaptureRef::size));
    e.mov(r3, 0, mem | r1, (char*)&layout.is_value - (char*)&layout, jit::SLJIT_MOV_U8);
    self.out.guard(jit::SLJIT_NOT_EQUAL, r3, 0, imm, 0, FUNCTION_OPS);
    e.mov(r3, 0, mem | r1, (char*)&layout.is_cell - (char*)&layout, jit::SLJIT_MOV_U8);
    self.out.guard(jit::SLJIT_NOT_EQUAL, r3, 0, imm, ref.is_cell ? 1 : 0, FUNCTION_OPS);
    e.mov(r3, 0, mem | r1, (char*)&layout.guard_shadow - (char*)&layout, jit::SLJIT_MOV_U8);
    self.out.guard(jit::SLJIT_NOT_EQUAL, r3, 0, imm, ref.guard_shadow ? 1 : 0, FUNCTION_OPS);
    e.mov(capture, 0, mem | r1, (char*)&layout.owner - (char*)&layout);
    self.out.guard(jit::SLJIT_EQUAL, capture, 0, imm, 0, FUNCTION_OPS);
    e.mov(r3, 0, mem | r1, (char*)&layout.prop_idx - (char*)&layout, jit::SLJIT_MOV_U32);
    self.out.guard(jit::SLJIT_NOT_EQUAL, r3, 0, imm, ref.prop_idx, FUNCTION_OPS);
    e.mov(r0, 0, mem | capture, 0, jit::SLJIT_MOV_U32);
    ObjFlags flags; flags.obj_class = OBJECT;
    e.op(jit::SLJIT_AND, r0, r0, 0, imm, 0x003F0000);
    self.out.guard(jit::SLJIT_NOT_EQUAL, r0, 0, imm, (uint)flags, FUNCTION_OPS);
    if (ref.is_cell) {
        e.mov(r0, 0, mem | capture, (char*)&object.prop_count - (char*)&object, jit::SLJIT_MOV_U32);
        self.out.guard(jit::SLJIT_LESS_EQUAL, r0, 0, imm, ref.prop_idx, FUNCTION_OPS);
    } else {
        e.mov(r0, 0, mem | capture, (char*)&object.shape_id - (char*)&object, jit::SLJIT_MOV_U32);
        self.out.guard(jit::SLJIT_NOT_EQUAL, r0, 0, imm, owner.shape_id, FUNCTION_OPS);
        if (ref.guard_shadow) {
            e.mov(r0, 0, mem | r2, (char*)&activation.lex_env - (char*)&activation);
            self.out.guard(jit::SLJIT_EQUAL, r0, 0, imm, 0, FUNCTION_OPS);
            EnvRecord* scope = act.lex_env;
            uint depth;
            while (scope != null && scope.bindings != owner) {
                if (++depth > 8 || scope.is_with()) return false;
                EnvFlags with_flag; with_flag.is_with = true;
                e.mov(r3, 0, mem | r0, (char*)&scope_layout.flags - (char*)&scope_layout, jit::SLJIT_MOV_U8);
                e.op(jit::SLJIT_AND, r3, r3, 0, imm, (char)with_flag);
                self.out.guard(jit::SLJIT_NOT_EQUAL, r3, 0, imm, 0, FUNCTION_OPS);
                e.mov(r3, 0, mem | r0, (char*)&scope_layout.bindings - (char*)&scope_layout);
                if (scope.bindings == null) { self.out.guard(jit::SLJIT_NOT_EQUAL, r3, 0, imm, 0, FUNCTION_OPS); }
                else {
                    Shape* sh = scope.bindings.get_shape(h);
                    PropFlags ignored;
                    void* key = cf.constants[cf.capture_names[index]].get_heapptr();
                    if (sh == null || sh.dict || function_shape_slot(sh, key, &ignored) >= 0 || !self.shape(scope.bindings.shape_id, h)) return false;
                    self.out.guard(jit::SLJIT_EQUAL, r3, 0, imm, 0, FUNCTION_OPS);
                    e.mov(r3, 0, mem | r3, (char*)&object.shape_id - (char*)&object, jit::SLJIT_MOV_U32);
                    self.out.guard(jit::SLJIT_NOT_EQUAL, r3, 0, imm, scope.bindings.shape_id, FUNCTION_OPS);
                }
                e.mov(r0, 0, mem | r0, (char*)&scope_layout.parent - (char*)&scope_layout);
                self.out.guard(jit::SLJIT_EQUAL, r0, 0, imm, 0, FUNCTION_OPS);
                scope = scope.parent;
            }
            if (scope == null || scope.is_with()) return false;
            EnvFlags with_flag; with_flag.is_with = true;
            e.mov(r3, 0, mem | r0, (char*)&scope_layout.flags - (char*)&scope_layout, jit::SLJIT_MOV_U8);
            e.op(jit::SLJIT_AND, r3, r3, 0, imm, (char)with_flag);
            self.out.guard(jit::SLJIT_NOT_EQUAL, r3, 0, imm, 0, FUNCTION_OPS);
            e.mov(r3, 0, mem | r0, (char*)&scope_layout.bindings - (char*)&scope_layout);
            self.out.guard(jit::SLJIT_NOT_EQUAL, r3, 0, capture, 0, FUNCTION_OPS);
        }
    }
    e.mov(r0, 0, mem | capture, (char*)&object.prop_alloc - (char*)&object);
    void* allocated = e.cmp(jit::SLJIT_NOT_EQUAL, r0, 0, imm, 0);
    e.op(jit::SLJIT_ADD, r0, capture, 0, imm, HObjectBase::size); e.bind(allocated);
    e.op(jit::SLJIT_ADD, capture, r0, 0, imm, (long)ref.prop_idx * 8);
    e.mov(r0, 0, mem | capture, 0);
    e.op(jit::SLJIT_LSHR, r3, r0, 0, imm, 48);
    self.out.guard(jit::SLJIT_NOT_EQUAL, r3, 0, imm, (long)types::TAG_FASTINT, FUNCTION_OPS);
    return true;
}
fn bool function_emit(FunctionPlan* plan, CompiledFunction* cf, Heap* h, Activation* act) @feat(SLJIT) {
    LoopPlan layout_plan; layout_plan.cache = plan.cache;
    FunctionEmitter emitter = { .out = { .e = { .compiler = jit::sljit_create_compiler(null) }, .plan = &layout_plan }, .plan = plan };
    FunctionEmitter* f = &emitter;
    LoopEmitter* out = &f.out; out.function_mode = true;
    TemplateEmitter* e = &out.e;
    if (e.compiler == null) return false;
    defer jit::sljit_free_compiler(e.compiler);
    if (jit::sljit_emit_enter(e.compiler, 0, jit::SLJIT_ARGS3WWW, 8 | (6 << 8), plan.capture_writes != 0 ? 5 : plan.receiver ? 4 : 3, 0) != 0) return false;
    int r0 = jit::reg_r(0); int r1 = jit::reg_r(1); int r2 = jit::reg_r(2); int r3 = jit::reg_r(3);
    int imm = jit::SLJIT_IMM; int mem = jit::SLJIT_MEM;
    e.mov(jit::reg_s(0), 0, r0, 0); e.mov(jit::reg_s(1), 0, r1, 0); e.mov(jit::reg_s(2), 0, r2, 0);
    for (uint i = 0; i < cf.num_regs; i++) if (plan.cache[i] != 0) {
        e.mov(plan.cache[i], 0, mem | jit::reg_s(0), loop_value_offset(i));
    }
    if (plan.receiver) {
        Activation layout;
        e.mov(r0, 0, mem | jit::reg_s(1), function_cold_offset(1));
        e.mov(r1, 0, mem | r0, (char*)&layout.flags - (char*)&layout, jit::SLJIT_MOV_U32);
        e.op(jit::SLJIT_AND, r1, r1, 0, imm, ACT_FLAG_THIS_VALID);
        out.guard(jit::SLJIT_EQUAL, r1, 0, imm, 0, FUNCTION_OPS);
        e.mov(jit::reg_s(3), 0, mem | r0, (char*)&layout.this_binding - (char*)&layout);
    }
    if (!f.capture(cf, act, h)) return false;
    if (jit::sljit_emit_ijump(e.compiler, jit::SLJIT_JUMP, jit::reg_s(2), 0) != 0) return false;
    bool[FUNCTION_OPS] supported;
    for (uint pos = 0; pos < cf.code_count; pos++) {
        Instruction ins = cf.code[pos];
        out.labels[pos] = e.label();
        bool active = function_op(ins.op);
        if ((ins.op == Opcode.GETCAP || ins.op == Opcode.PUTCAP || ins.op == Opcode.INC_VAR || ins.op == Opcode.DEC_VAR)
            && function_capture_index(cf, ins) < 0) active = false;
        int target = loop_target(ins, pos);
        if (target >= 0 && (target <= (int)pos || target >= (int)cf.code_count)) active = false;
        if (!active) { out.link(jit::sljit_emit_jump(e.compiler, jit::SLJIT_JUMP), pos, true); continue; }
        supported[pos] = true;

        if (target >= 0) {
            if (ins.op == Opcode.JUMP) { out.link(jit::sljit_emit_jump(e.compiler, jit::SLJIT_JUMP), (uint)target, false); }
            else if (ins.op == Opcode.IF_TRUE || ins.op == Opcode.IF_FALSE) {
                f.truth(ins.a, pos);
                out.link(e.cmp(ins.op == Opcode.IF_TRUE ? jit::SLJIT_NOT_EQUAL : jit::SLJIT_EQUAL, r0, 0, imm, 0), (uint)target, false);
            } else if (ins.op == Opcode.JMP_SEQ || ins.op == Opcode.JMP_SNEQ || ins.op == Opcode.JMP_SEQI || ins.op == Opcode.JMP_SNEQI) {
                f.equal(ins, ins.op == Opcode.JMP_SEQI || ins.op == Opcode.JMP_SNEQI,
                    ins.op == Opcode.JMP_SNEQ || ins.op == Opcode.JMP_SNEQI, pos);
                out.link(e.cmp(jit::SLJIT_NOT_EQUAL, r0, 0, imm, 0), (uint)target, false);
            } else {
                void*[2] skips = out.condition(ins, pos);
                out.link(jit::sljit_emit_jump(e.compiler, jit::SLJIT_JUMP), (uint)target, false);
                void* next = e.label(); foreach (jump : skips) if (jump != null) out.bind_to(jump, next);
            }
            continue;
        }
        switch (ins.op) {
            case NOP: continue;
            case LDREG: out.load(ins.b, r0);
            case LDTHIS: e.mov(r0, 0, jit::reg_s(3), 0);
            case LDINT: { TVal v; v.set_fastint(ins.get_sbc()); e.mov(r0, 0, imm, (long)loop_bits(v)); }
            case LDCONST: e.mov(r0, 0, imm, (long)loop_bits(cf.constants[ins.get_bc()]));
            case LDTRUE: case LDFALSE: case LDNULL: case LDUNDEF: case VOID: {
                TVal v;
                if (ins.op == Opcode.LDTRUE || ins.op == Opcode.LDFALSE) { v.set_boolean(ins.op == Opcode.LDTRUE); }
                else if (ins.op == Opcode.LDNULL) { v.set_null(); }
                else { v.set_undefined(); }
                e.mov(r0, 0, imm, (long)loop_bits(v));
            }
            case GETCAP: {
                uint capture = ins.get_bc();
                if ((plan.capture_writes & (1U << capture)) != 0) {
                    e.mov(r0, 0, mem | jit::reg_s(4), 0);
                } else {
                    CaptureRef ref; HObject owner;
                    Activation activation; HObject function;
                    e.mov(r1, 0, mem | jit::reg_s(1), function_cold_offset(1));
                    e.mov(r1, 0, mem | r1, (char*)&activation.tv_func - (char*)&activation);
                    e.op(jit::SLJIT_AND, r1, r1, 0, imm, (long)types::NANBOX_PAYLOAD_MASK);
                    e.mov(r1, 0, mem | r1, (char*)&function.extra.func.capture_refs - (char*)&function);
                    out.guard(jit::SLJIT_EQUAL, r1, 0, imm, 0, pos);
                    e.op(jit::SLJIT_ADD, r1, r1, 0, imm, (long)(capture * CaptureRef::size));
                    e.mov(r3, 0, mem | r1, (char*)&ref.is_value - (char*)&ref, jit::SLJIT_MOV_U8);
                    void* indirect = e.cmp(jit::SLJIT_EQUAL, r3, 0, imm, 0);
                    e.mov(r0, 0, mem | r1, (char*)&ref.value - (char*)&ref);
                    void* done = jit::sljit_emit_jump(e.compiler, jit::SLJIT_JUMP);
                    e.bind(indirect);
                    e.mov(r3, 0, mem | r1, (char*)&ref.guard_shadow - (char*)&ref, jit::SLJIT_MOV_U8);
                    out.guard(jit::SLJIT_NOT_EQUAL, r3, 0, imm, 0, pos);
                    e.mov(r2, 0, mem | r1, (char*)&ref.owner - (char*)&ref);
                    out.guard(jit::SLJIT_EQUAL, r2, 0, imm, 0, pos);
                    e.mov(r0, 0, mem | r1, (char*)&ref.prop_idx - (char*)&ref, jit::SLJIT_MOV_U32);
                    e.mov(r3, 0, mem | r2, (char*)&owner.prop_count - (char*)&owner, jit::SLJIT_MOV_U32);
                    out.guard(jit::SLJIT_GREATER_EQUAL, r0, 0, r3, 0, pos);
                    // Capture owners use ordinary binding/cell objects.
                    e.mov(r3, 0, mem | r2, 0, jit::SLJIT_MOV_U32);
                    e.op(jit::SLJIT_AND, r3, r3, 0, imm, 0x003F0000);
                    out.guard(jit::SLJIT_NOT_EQUAL, r3, 0, imm, (long)(ObjClass.OBJECT.ordinal << 16), pos);
                    e.op(jit::SLJIT_SHL, r0, r0, 0, imm, 3);
                    e.mov(r3, 0, mem | r2, (char*)&owner.prop_alloc - (char*)&owner);
                    void* allocated = e.cmp(jit::SLJIT_NOT_EQUAL, r3, 0, imm, 0);
                    e.op(jit::SLJIT_ADD, r3, r2, 0, imm, HObjectBase::size); e.bind(allocated);
                    e.op(jit::SLJIT_ADD, r3, r3, 0, r0, 0); e.mov(r0, 0, mem | r3, 0);
                    e.bind(done);
                    e.op(jit::SLJIT_LSHR, r3, r0, 0, imm, 48);
                    void* initialized = e.cmp(jit::SLJIT_NOT_EQUAL, r3, 0, imm, (long)types::TAG_UNDEFINED);
                    out.guard(jit::SLJIT_NOT_EQUAL, r0, 0, imm, (long)(types::TAG_UNDEFINED << 48), pos);
                    e.bind(initialized);
                }
            }
            case GETVAR: case GETGLOBAL: {
                VarICEntry* vic = (VarICEntry*)cf.var_ic_entries + pos;
                VarICEntry view; Activation activation; Heap heap_view;
                e.mov(r2, 0, imm, (long)vic);
                if (ins.op == Opcode.GETVAR) {
                    e.mov(r3, 0, mem | jit::reg_s(1), function_cold_offset(1));
                    e.mov(r3, 0, mem | r3, (char*)&activation.lex_env - (char*)&activation);
                    out.guard(jit::SLJIT_NOT_EQUAL, r3, 0, mem | r2, (char*)&view.search_head - (char*)&view, pos);
                }
                e.mov(r3, 0, mem | jit::reg_s(1), function_cold_offset(0));
                e.mov(r3, 0, mem | r3, (char*)&heap_view.shape_recycle_epoch - (char*)&heap_view, jit::SLJIT_MOV_U32);
                e.mov(r1, 0, mem | r2, (char*)&view.recycle_epoch - (char*)&view, jit::SLJIT_MOV_U32);
                out.guard(jit::SLJIT_NOT_EQUAL, r3, 0, r1, 0, pos);
                e.mov(r3, 0, mem | r2, (char*)&view.prop_flags - (char*)&view, jit::SLJIT_MOV_U8);
                e.op(jit::SLJIT_AND, r3, r3, 0, imm, 8);
                out.guard(jit::SLJIT_NOT_EQUAL, r3, 0, imm, 0, pos);
                e.mov(r2, 0, mem | r2, (char*)&view.slot_ptr - (char*)&view);
                out.guard(jit::SLJIT_EQUAL, r2, 0, imm, 0, pos);
                e.mov(r0, 0, mem | r2, 0);
                e.op(jit::SLJIT_LSHR, r3, r0, 0, imm, 48);
                void* initialized = e.cmp(jit::SLJIT_NOT_EQUAL, r3, 0, imm, (long)types::TAG_UNDEFINED);
                out.guard(jit::SLJIT_NOT_EQUAL, r0, 0, imm, (long)(types::TAG_UNDEFINED << 48), pos);
                e.bind(initialized);
            }
            case PUTCAP:
                e.mov(r2, 0, jit::reg_s(4), 0);
                e.mov(r0, 0, mem | r2, 0);
                e.op(jit::SLJIT_LSHR, r3, r0, 0, imm, 48);
                out.guard(jit::SLJIT_GREATER, r3, 0, imm, (long)types::TAG_BOOLEAN, pos);
                out.load(ins.a, r0);
                e.op(jit::SLJIT_LSHR, r3, r0, 0, imm, 48);
                out.guard(jit::SLJIT_GREATER, r3, 0, imm, (long)types::TAG_BOOLEAN, pos);
                e.mov(mem | r2, 0, r0, 0);
                e.mov(plan.cache[ins.a] != 0 ? plan.cache[ins.a] : mem | jit::reg_s(0),
                    plan.cache[ins.a] != 0 ? 0 : loop_value_offset(ins.a), imm, (long)(types::TAG_UNDEFINED << 48));
                continue;
            case INC_VAR: case DEC_VAR:
                e.mov(r2, 0, jit::reg_s(4), 0);
                e.mov(r0, 0, mem | r2, 0);
                e.op(jit::SLJIT_LSHR, r3, r0, 0, imm, 48);
                out.guard(jit::SLJIT_NOT_EQUAL, r3, 0, imm, (long)types::TAG_FASTINT, pos);
                e.op(jit::SLJIT_SHL, r0, r0, 0, imm, 16); e.op(jit::SLJIT_ASHR, r0, r0, 0, imm, 16);
                e.op(ins.op == Opcode.INC_VAR ? jit::SLJIT_ADD : jit::SLJIT_SUB, r0, r0, 0, imm, 1);
                out.range(r0, pos); out.box(r0); f.store(ins.a, pos, true);
                e.mov(r2, 0, jit::reg_s(4), 0);
                e.mov(mem | r2, 0, r0, 0); continue;
            case GETPROPC: case GETPROPC_CACHED: case PUTPROPC:
            case GETPROP: case GETPROP_CACHE: case PUTPROP: case GETTHISC: case PUTTHISC:
                supported[pos] = f.property(cf, pos, ins.op == Opcode.PUTPROPC || ins.op == Opcode.PUTPROP || ins.op == Opcode.PUTTHISC, h); continue;
            case TONUMERIC:
                out.integer(ins.b, r0, pos); out.box(r0);
            case INC: case INC_LT: case DEC:
                out.integer(ins.a, r0, pos);
                e.op(ins.op == Opcode.DEC ? jit::SLJIT_SUB : jit::SLJIT_ADD, r0, r0, 0, imm, 1);
                out.range(r0, pos); out.box(r0);
            case LNOT: {
                f.truth(ins.b, pos);
                void* truthy = e.cmp(jit::SLJIT_NOT_EQUAL, r0, 0, imm, 0);
                e.mov(r0, 0, imm, (long)((types::TAG_BOOLEAN << 48) | 1));
                void* done = jit::sljit_emit_jump(e.compiler, jit::SLJIT_JUMP);
                e.bind(truthy); e.mov(r0, 0, imm, (long)(types::TAG_BOOLEAN << 48)); e.bind(done);
            }
            case TYPEOF: f.typeof_value(cf, pos, h); continue;
            case LT: case LE: case GT: case GE: {
                Instruction compare = ins; compare.op = loop_compare(ins.op);
                void*[2] skips = out.condition(compare, pos);
                e.mov(r0, 0, imm, (long)((types::TAG_BOOLEAN << 48) | 1));
                void* done = jit::sljit_emit_jump(e.compiler, jit::SLJIT_JUMP);
                void* failed = e.label();
                foreach (jump : skips) if (jump != null) out.bind_to(jump, failed);
                e.mov(r0, 0, imm, (long)(types::TAG_BOOLEAN << 48)); e.bind(done);
            }
            case SEQ: case SNEQ:
                f.equal(ins, false, ins.op == Opcode.SNEQ, pos);
                e.op(jit::SLJIT_OR, r0, r0, 0, imm, (long)(types::TAG_BOOLEAN << 48));
            default:
                out.numeric(ins, pos); continue;
        }
        bool known = ins.op == Opcode.LDINT || ins.op == Opcode.LDTRUE || ins.op == Opcode.LDFALSE || ins.op == Opcode.LDNULL
            || ins.op == Opcode.LDUNDEF || ins.op == Opcode.VOID || ins.op == Opcode.INC || ins.op == Opcode.INC_LT || ins.op == Opcode.DEC
            || ins.op == Opcode.TONUMERIC || ins.op == Opcode.LNOT || ins.op == Opcode.SEQ || ins.op == Opcode.SNEQ || (ins.op >= Opcode.LT && ins.op <= Opcode.GE)
            || (ins.op == Opcode.GETCAP && (plan.capture_writes & (1U << ins.get_bc())) != 0);
        if (ins.op == Opcode.LDCONST) {
            TVal value = cf.constants[ins.get_bc()];
            known = !value.is_refcounted() || value.get_heapptr() == null || ((HeapHeader*)value.get_heapptr()).is_pinned();
        }
        f.store(ins.a, pos, known);
    }
    out.link(jit::sljit_emit_jump(e.compiler, jit::SLJIT_JUMP), cf.code_count, true);
    if (e.failed) return false;
    void*[FUNCTION_OPS + 1] exits;
    for (uint i = 0; i < out.link_count; i++) {
        LoopLink link = out.links[i];
        if (!link.exit) { out.bind_to(link.jump, out.labels[link.target]); continue; }
        if (exits[link.target] != null) { out.bind_to(link.jump, exits[link.target]); continue; }
        void* label = e.label(); exits[link.target] = label; out.bind_to(link.jump, label);
        for (uint j = 0; j < cf.num_regs; j++) if (plan.cache[j] != 0) {
            e.mov(mem | jit::reg_s(0), loop_value_offset(j), plan.cache[j], 0);
        }
        if (link.target == FUNCTION_OPS) { e.mov(r0, 0, imm, uint::max); }
        else { e.mov(r0, 0, imm, link.target); }
        if (jit::sljit_emit_return(e.compiler, jit::SLJIT_MOV, r0, 0) != 0) e.failed = true;
    }
    if (e.failed) return false;
    plan.native = (FunctionNative)jit::sljit_generate_code(e.compiler, 0, null);
    if (plan.native == null) return false;
    plan.code_bytes = jit::sljit_shim_code_size(e.compiler);
    uint entries;
    uint[FUNCTION_OPS + 1] span;
    for (uint reverse = cf.code_count; reverse > 0; reverse--) {
        uint i = reverse - 1;
        if (!supported[i]) continue;
        uint following = span[i + 1];
        int target = loop_target(cf.code[i], i);
        if (target > (int)i && target < (int)cf.code_count && span[target] > following) following = span[target];
        span[i] = following + 1;
        if (span[i] >= 6) { plan.entries[i] = (void*)jit::sljit_shim_label_addr(out.labels[i]); entries++; }
    }
    if (entries == 0) { jit::sljit_free_code((void*)plan.native, null); plan.native = null; return false; }
    return true;
}
fn void sljit_function_free(Heap* h, CompiledFunction* cf) @feat(SLJIT) {
    FunctionPlan* plan = cf.sljit_function;
    if (plan == null) return;
    $if $feat(SLJIT_STATS):
        io::eprintfn("SLJIT function %s hits=%d returns=%d code_bytes=%d", (String)cf.get_name(), plan.hits, plan.completed, plan.code_bytes);
    $endif
    jit::sljit_free_code((void*)plan.native, null); h.jit_code_bytes -= plan.code_bytes;
    h.free_func(h.heap_udata, plan); cf.sljit_function = null;
}
macro bool sljit_function_resumes(Instruction* pc, CompiledFunction* cf) @feat(SLJIT) {
    return cf.sljit_function != null && ((FunctionPlan*)cf.sljit_function).entries[(uint)(pc - cf.code)] != null;
}
fn FunctionPlan* sljit_function_compile(CompiledFunction* cf, ColdCtx* cold) @feat(SLJIT) @noinline {
    Heap* h = cold.heap;
    if (cf.code_count > FUNCTION_OPS || h.jit_code_bytes >= LOOP_CODE_LIMIT) return null;
    usz bytes = FunctionPlan::size + cf.code_count * (void*::size + 1);
    FunctionPlan* plan = (FunctionPlan*)h.alloc_func(h.heap_udata, bytes);
    if (plan == null) return null;
    mem::clear(plan, (sz)bytes);
    plan.entries = (void**)((char*)plan + FunctionPlan::size);
    plan.short_runs = (char*)(plan.entries + cf.code_count);
    if (!function_analyze(cf, plan) || !function_emit(plan, cf, h, cold.act)
        || h.jit_code_bytes + plan.code_bytes > LOOP_CODE_LIMIT) {
        if (plan.native != null) jit::sljit_free_code((void*)plan.native, null);
        h.free_func(h.heap_udata, plan);
        return null;
    }
    cf.sljit_function = plan; h.jit_code_bytes += plan.code_bytes;
    plan.shape_clock = h.shape_gen_clock; plan.shape_epoch = h.shape_recycle_epoch;
    if (plan.entries[0] != null) cf.sljit_function_calls = uint::max - 1;
    $if $feat(SLJIT_STATS):
        io::eprintfn("SLJIT function compiled %s code_bytes=%d plan_bytes=%d", (String)cf.get_name(), plan.code_bytes, bytes);
    $endif
    return plan;
}
fn Instruction* sljit_function_entry(Instruction* pc, TVal* regs, ColdCtx* cold) @feat(SLJIT) @noinline {
    Heap* h = cold.heap; CompiledFunction* cf = cold.vm.current_func;
    if (!h.jit_enabled || !types::USE_NANBOX || usz::size != 8 || h.gc_phase != heap::GcPhase.IDLE
        || h.uncatchable_throw || std::core::mem::@atomic_load(h.interrupt_requested) != 0) return pc;
    uint offset = (uint)(pc - cf.code);
    FunctionPlan* plan = cf.sljit_function;
    if (plan == null) {
        if (offset != 0 || cf.sljit_function_calls == uint::max || ++cf.sljit_function_calls < 64) return pc;
        cf.sljit_function_calls = uint::max;
        plan = sljit_function_compile(cf, cold);
        if (plan == null) return pc;
    }
    if (offset >= cf.code_count || plan.entries[offset] == null) return pc;
    if (plan.shape_clock != h.shape_gen_clock || plan.shape_epoch != h.shape_recycle_epoch) {
        for (uint i = 0; i < plan.shape_count; i++) {
            Shape* shape = h.get_shape(plan.shapes[i]);
            if (shape == null || shape.generation != plan.generations[i]) {
                sljit_function_free(h, cf); cf.sljit_function_calls = 0; return pc;
            }
        }
        plan.shape_clock = h.shape_gen_clock; plan.shape_epoch = h.shape_recycle_epoch;
    }
    if (cold.act.heap_reg_count < plan.heap_regs) cold.act.heap_reg_count = plan.heap_regs;
    TVal[4] previous @noinit;
    for (uint i = 0; i < plan.cache_count; i++) previous[i] = regs[plan.cached_regs[i]];
    uint next = plan.native(regs, cold, plan.entries[offset]);
    // Native exit publishes the borrowed cache. Retain every new string before
    // releasing any old one: values can move between cached registers.
    for (uint i = 0; i < plan.cache_count; i++) {
        TVal value = regs[plan.cached_regs[i]];
        if (!value.same_bits(&previous[i]) && value.is_refcounted() && value.get_heapptr() != null) {
            ((HeapHeader*)value.get_heapptr()).incref();
        }
    }
    for (uint i = 0; i < plan.cache_count; i++) {
        if (!regs[plan.cached_regs[i]].same_bits(&previous[i])) h.decref_tval(&previous[i]);
    }
    if (next == uint::max) next = offset;
    if (next >= offset && next - offset < 6) {
        if (++plan.short_runs[offset] >= 8) {
            plan.entries[offset] = null;
            if (offset == 0) cf.sljit_function_calls = uint::max;
        }
    } else { plan.short_runs[offset] = 0; }
    $if $feat(SLJIT_STATS):
        plan.hits++;
        if (next == offset) plan.stalled++;
        if (next < cf.code_count && (cf.code[next].op == Opcode.RET || cf.code[next].op == Opcode.RETUNDEF)) plan.completed++;
        if (plan.hits == 1000) io::eprintfn("SLJIT function native %s hits=%d returns=%d stalled=%d pc=%d", (String)cf.get_name(), plan.hits, plan.completed, plan.stalled, next);
    $endif
    return cf.code + next;
}
fn Instruction* sljit_function_dispatch(Instruction* pc, HandlerTable* handlers, TVal* regs, ColdCtx* cold) @feat(SLJIT) @noinline {
    return th_next(sljit_function_entry(pc, regs, cold), handlers, regs, cold);
}
