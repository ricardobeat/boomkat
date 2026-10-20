module boomkat::vm;

import boomkat::bytecode;
import boomkat::types;
import boomkat::heap;
import boomkat::hobject;
import boomkat::hstring;
import boomkat::jit;
import std::io;

alias TemplateNative = fn long(TVal* rows, long count, char* output);
const uint TEMPLATE_MAX_PARTS = 16;
const uint TEMPLATE_FLAG_MASK = 0xFFFF_FFC3;
const long TEMPLATE_MAX_BYTES = 4 * 1024 * 1024;

struct TemplatePart @feat(SLJIT) {
    HString* literal;
    uint slot;
    bool integer;
}
struct TemplatePlan @feat(SLJIT) {
    TemplateNative measure;
    TemplateNative write;
    TemplatePart[TEMPLATE_MAX_PARTS] parts;
    uint count;
    uint shape;
    uint generation;
    uint flags;
    uint result_reg;
    uint return_pc;
    ulong hits @if($feat(SLJIT_STATS));
    ulong misses @if($feat(SLJIT_STATS));
    usz code_bytes @if($feat(SLJIT_STATS));
}
// Symbolic values describe the admitted loop without depending on its register
// allocation, property names, template spelling, or function name.
struct TemplateValue @feat(SLJIT) {
    uint kind; // 1 input, 2 index, 3 record, 4 literal, 5 field, 6 join, 7 accumulator
    uint constant;
    uint read_id;
}
struct TemplateEmitter @feat(SLJIT) {
    void* compiler;
    void*[128] guards;
    uint guard_count;
    bool failed;
}
fn void TemplateEmitter.mov(&self, int dst, long dw, int src, long sw, int op = jit::SLJIT_MOV) @feat(SLJIT) {
    if (jit::sljit_emit_op1(self.compiler, op, dst, dw, src, sw) != 0) self.failed = true;
}
fn void TemplateEmitter.op(&self, int op, int dst, int left, long lw, int right, long rw) @feat(SLJIT) {
    if (jit::sljit_emit_op2(self.compiler, op, dst, 0, left, lw, right, rw) != 0) self.failed = true;
}
fn void* TemplateEmitter.cmp(&self, int condition, int left, long lw, int right, long rw) @feat(SLJIT) {
    void* jump = jit::sljit_emit_cmp(self.compiler, condition, left, lw, right, rw);
    if (jump == null) self.failed = true;
    return jump;
}
fn void TemplateEmitter.guard(&self, int condition, int left, long lw, int right, long rw) @feat(SLJIT) {
    if (self.guard_count == 128) { self.failed = true; return; }
    self.guards[self.guard_count++] = self.cmp(condition, left, lw, right, rw);
}
fn void* TemplateEmitter.label(&self) @feat(SLJIT) {
    void* label = jit::sljit_emit_label(self.compiler);
    if (!label) self.failed = true;
    return label;
}
fn void TemplateEmitter.bind(&self, void* jump) @feat(SLJIT) {
    void* label = self.label();
    if (jump && label) jit::sljit_set_label(jump, label);
}
fn void TemplateEmitter.back(&self, void* label, int condition, int left, long lw, int right, long rw) @feat(SLJIT) {
    void* jump = self.cmp(condition, left, lw, right, rw);
    if (jump && label) jit::sljit_set_label(jump, label);
}

// Short fields use overlapping head/tail loads, with every load inside the
// source string. Source strings cannot alias the fresh output allocation.
fn void TemplateEmitter.copy_span(&self) @feat(SLJIT) {
    int r0 = jit::reg_r(0);
    int r1 = jit::reg_r(1);
    int r3 = jit::reg_r(3);
    int src = jit::reg_r(4);
    int len = jit::reg_r(5);
    int dst = jit::reg_r(6);
    int tail = jit::reg_r(7);
    int imm = jit::SLJIT_IMM;
    int mem = jit::SLJIT_MEM;
    void*[3] completed;
    void* large = self.cmp(jit::SLJIT_GREATER, len, 0, imm, 32);
    void* medium = self.cmp(jit::SLJIT_LESS, len, 0, imm, 16);
    self.op(jit::SLJIT_ADD, r3, src, 0, len, 0);
    self.op(jit::SLJIT_ADD, tail, dst, 0, len, 0);
    self.mov(r0, 0, mem | src, 0);
    self.mov(r1, 0, mem | src, 8);
    self.mov(mem | dst, 0, r0, 0);
    self.mov(mem | dst, 8, r1, 0);
    self.mov(r0, 0, mem | r3, -16);
    self.mov(r1, 0, mem | r3, -8);
    self.mov(mem | tail, -16, r0, 0);
    self.mov(mem | tail, -8, r1, 0);
    completed[0] = jit::sljit_emit_jump(self.compiler, jit::SLJIT_JUMP);
    self.bind(medium);
    void* small = self.cmp(jit::SLJIT_LESS, len, 0, imm, 8);
    self.op(jit::SLJIT_ADD, r3, src, 0, len, 0);
    self.op(jit::SLJIT_ADD, tail, dst, 0, len, 0);
    self.mov(r0, 0, mem | src, 0);
    self.mov(r1, 0, mem | r3, -8);
    self.mov(mem | dst, 0, r0, 0);
    self.mov(mem | tail, -8, r1, 0);
    completed[1] = jit::sljit_emit_jump(self.compiler, jit::SLJIT_JUMP);
    self.bind(small);
    void* tiny = self.cmp(jit::SLJIT_LESS, len, 0, imm, 4);
    self.op(jit::SLJIT_ADD, r3, src, 0, len, 0);
    self.op(jit::SLJIT_ADD, tail, dst, 0, len, 0);
    self.mov(r0, 0, mem | src, 0, jit::SLJIT_MOV_U32);
    self.mov(r1, 0, mem | r3, -4, jit::SLJIT_MOV_U32);
    self.mov(mem | dst, 0, r0, 0, jit::SLJIT_MOV_U32);
    self.mov(mem | tail, -4, r1, 0, jit::SLJIT_MOV_U32);
    completed[2] = jit::sljit_emit_jump(self.compiler, jit::SLJIT_JUMP);
    self.bind(large);
    self.bind(tiny);
    void* words = self.label();
    void* bytes_only = self.cmp(jit::SLJIT_LESS, len, 0, imm, 8);
    self.mov(r0, 0, mem | src, 0);
    self.mov(mem | dst, 0, r0, 0);
    self.op(jit::SLJIT_ADD, src, src, 0, imm, 8);
    self.op(jit::SLJIT_ADD, dst, dst, 0, imm, 8);
    self.op(jit::SLJIT_SUB, len, len, 0, imm, 8);
    self.back(words, jit::SLJIT_GREATER_EQUAL, len, 0, imm, 8);
    self.bind(bytes_only);
    void* empty = self.cmp(jit::SLJIT_EQUAL, len, 0, imm, 0);
    void* bytes = self.label();
    self.mov(r0, 0, mem | src, 0, jit::SLJIT_MOV_U8);
    self.mov(mem | dst, 0, r0, 0, jit::SLJIT_MOV_U8);
    self.op(jit::SLJIT_ADD, src, src, 0, imm, 1);
    self.op(jit::SLJIT_ADD, dst, dst, 0, imm, 1);
    self.op(jit::SLJIT_SUB, len, len, 0, imm, 1);
    self.back(bytes, jit::SLJIT_NOT_EQUAL, len, 0, imm, 0);
    void* end = self.label();
    if (empty && end) jit::sljit_set_label(empty, end);
    foreach (jump : completed) {
        if (jump && end) { jit::sljit_set_label(jump, end); }
        else { self.failed = true; }
    }
}

fn bool sljit_template_candidate(CompiledFunction* cf) @feat(SLJIT) @inline {
    return cf.num_args == 1 && cf.num_regs <= 32 && cf.code_count >= 12 && cf.code_count <= 96
        && cf.code[0].op == Opcode.LDCONST && cf.code[1].op == Opcode.LDINT
        && cf.code[2].op == Opcode.JUMP && !cf.needs_env() && !cf.flags.uses_arguments
        && !cf.flags.is_generator && !cf.flags.is_async && cf.capture_count == 0;
}

fn bool sljit_template_analyze(CompiledFunction* cf, HObject* sample, Heap* h, TemplatePlan* plan) @feat(SLJIT) {
    if (!sljit_template_candidate(cf) || !hobject::plain_property_object(sample) || sample.in_dict_mode(h)) return false;
    Instruction* code = cf.code;
    uint out = code[0].a;
    uint index = code[1].a;
    if (out == 0 || index == 0 || out == index || code[1].get_sbc() != 0
        || code[0].get_bc() >= cf.const_count) return false;
    TVal empty = cf.constants[code[0].get_bc()];
    if (!empty.is_string() || ((HString*)empty.get_heapptr()).blen != 0) return false;
    int test = 3 + code[2].get_sabc();
    if (test < 6 || test + 3 >= (int)cf.code_count) return false;
    Instruction length = code[test];
    Instruction branch = code[test + 1];
    if ((length.op != Opcode.GETPROPC && length.op != Opcode.GETPROPC_CACHED) || length.b != 0
        || length.c >= cf.const_count || cf.constants[length.c].get_heapptr() != h.str(heap::BuiltinStr.LENGTH)
        || branch.op != Opcode.JMP_LT || branch.b != index || branch.c != length.a
        || test + 2 + (int)(ichar)branch.a != 3
        || code[test + 2].op != Opcode.RET || code[test + 2].a != out
        || code[test + 3].op != Opcode.RETUNDEF || (uint)test + 4 != cf.code_count
        || code[test - 1].op != Opcode.INC || code[test - 1].a != index) return false;
    TemplateValue[32] values;
    values[0].kind = 1;
    values[index].kind = 2;
    values[out].kind = 7;
    bool joined;
    bool appended;
    uint field_reads;
    bool[96] used_reads;
    for (uint pc = 3; pc < (uint)test - 1; pc++) {
        Instruction ins = code[pc];
        if (ins.a >= cf.num_regs || ins.a == 0 || ins.a == index) return false;
        switch (ins.op) {
            case LDREG:
                if (ins.b >= cf.num_regs || values[ins.b].kind == 0 || ins.a == out) return false;
                values[ins.a] = values[ins.b];
            case GETPROP: case GETPROP_CACHE:
                if (ins.b >= cf.num_regs || ins.c >= cf.num_regs || values[ins.b].kind != 1
                    || values[ins.c].kind != 2 || ins.a == out) return false;
                values[ins.a] = { .kind = 3 };
            case GETPROPC: case GETPROPC_CACHED:
                if (ins.b >= cf.num_regs || values[ins.b].kind != 3 || ins.c >= cf.const_count || ins.a == out) return false;
                values[ins.a] = { .kind = 5, .constant = ins.c, .read_id = field_reads++ };
            case LDCONST:
                if (ins.get_bc() >= cf.const_count || ins.a == out) return false;
                TVal value = cf.constants[ins.get_bc()];
                if (!value.is_string() || ((HString*)value.get_heapptr()).is_symbol()) return false;
                values[ins.a] = { .kind = 4, .constant = ins.get_bc() };
            case TOSTR:
                if (values[ins.a].kind != 5 && values[ins.a].kind != 4) return false;
            case STRJOIN:
                if (joined || ins.c < 2 || ins.c > TEMPLATE_MAX_PARTS || (uint)ins.b + ins.c > cf.num_regs || ins.a == out) return false;
                for (uint j = 0; j < ins.c; j++) {
                    TemplateValue val = values[(uint)ins.b + j];
                    TemplatePart* part = &plan.parts[j];
                    if (val.kind == 4) {
                        part.literal = cf.constants[val.constant].get_heapptr();
                    } else if (val.kind == 5) {
                        HString* key = cf.constants[val.constant].get_heapptr();
                        int slot = sample.find_prop_idx(key, h);
                        if (slot < 0 || sample.get_prop_flags((uint)slot, h).is_accessor) return false;
                        TVal field = sample.prop_values()[slot].get();
                        if (!field.is_fastint() && (!field.is_string() || ((HString*)field.get_heapptr()).is_symbol())) return false;
                        part.slot = (uint)slot;
                        part.integer = field.is_fastint();
                        used_reads[val.read_id] = true;
                    } else { return false; }
                }
                plan.count = ins.c;
                values[ins.a] = { .kind = 6 };
                joined = true;
            case ADD:
                if (appended || ins.a != out || ins.b != out || values[ins.b].kind != 7
                    || ins.c >= cf.num_regs || values[ins.c].kind != 6) return false;
                appended = true;
            default: return false;
        }
        if (appended && pc + 1 != (uint)test - 1) return false;
    }
    if (!joined || !appended) return false;
    for (uint i = 0; i < field_reads; i++) { if (!used_reads[i]) return false; }
    plan.shape = sample.shape_id;
    plan.generation = sample.live_shape_generation(h);
    plan.flags = (uint)sample.flags & TEMPLATE_FLAG_MASK;
    plan.result_reg = out;
    plan.return_pc = (uint)test + 2;
    return true;
}

// The sizing pass validates every row and bounds capacity before allocation; no JS, collection, or interrupt callback runs between
// sizing and writing, so borrowed source bytes and slot storage stay stable.
fn TemplateNative sljit_template_emit(TemplatePlan* plan, bool write) @feat(SLJIT) {
    TemplateEmitter e = { .compiler = jit::sljit_create_compiler(null) };
    if (!e.compiler) return null;
    defer jit::sljit_free_compiler(e.compiler);
    if (jit::sljit_emit_enter(e.compiler, 0, jit::SLJIT_ARGS3WWW, 8, 5, 0) != 0) return null;
    int r0 = jit::reg_r(0);
    int r1 = jit::reg_r(1);
    int r3 = jit::reg_r(3);
    int r4 = jit::reg_r(4);
    int r5 = jit::reg_r(5);
    int r6 = jit::reg_r(6);
    int r7 = jit::reg_r(7);
    int rows = jit::reg_s(0);
    int end = jit::reg_s(1);
    int output = jit::reg_s(2);
    int offset = jit::reg_s(3);
    int slots = jit::reg_s(4);
    int imm = jit::SLJIT_IMM;
    int mem = jit::SLJIT_MEM;
    HObject object;
    HString string;
    long shape_offset = (char*)&object.shape_id - (char*)&object;
    long props_offset = (char*)&object.prop_alloc - (char*)&object;
    long length_offset = (char*)&string.blen - (char*)&string;
    e.op(jit::SLJIT_SHL, end, end, 0, imm, 3);
    e.op(jit::SLJIT_ADD, end, rows, 0, end, 0);
    e.mov(offset, 0, imm, 0);
    void* empty = e.cmp(jit::SLJIT_EQUAL, rows, 0, end, 0);
    void* loop = e.label();
    e.mov(r4, 0, mem | rows, 0);
    if (!write) {
        e.op(jit::SLJIT_LSHR, r5, r4, 0, imm, 48);
        e.guard(jit::SLJIT_NOT_EQUAL, r5, 0, imm, (long)types::TAG_OBJECT);
    }
    e.op(jit::SLJIT_AND, r4, r4, 0, imm, 0x0000FFFFFFFFFFFF);
    if (!write) {
        e.mov(r5, 0, mem | r4, 0, jit::SLJIT_MOV_U32);
        e.op(jit::SLJIT_AND, r5, r5, 0, imm, TEMPLATE_FLAG_MASK);
        e.guard(jit::SLJIT_NOT_EQUAL, r5, 0, imm, plan.flags);
        e.mov(r5, 0, mem | r4, shape_offset, jit::SLJIT_MOV_U32);
        e.guard(jit::SLJIT_NOT_EQUAL, r5, 0, imm, plan.shape);
    }
    e.mov(slots, 0, mem | r4, props_offset);
    void* external = e.cmp(jit::SLJIT_NOT_EQUAL, slots, 0, imm, 0);
    e.op(jit::SLJIT_ADD, slots, r4, 0, imm, (long)HObjectBase::size);
    e.bind(external);
    for (uint i = 0; i < plan.count; i++) {
        TemplatePart part = plan.parts[i];
        if (part.literal) {
            uint len = part.literal.blen;
            if (write && len != 0) {
                e.op(jit::SLJIT_ADD, r6, output, 0, offset, 0);
                char* bytes = part.literal.get_cstr();
                uint j;
                while (j + 8 <= len) {
                    ulong word;
                    std::core::mem::copy(&word, bytes + j, 8);
                    e.mov(r0, 0, imm, (long)word);
                    e.mov(mem | r6, j, r0, 0);
                    j += 8;
                }
                while (j < len) {
                    e.mov(mem | r6, j, imm, bytes[j], jit::SLJIT_MOV_U8);
                    j++;
                }
            }
            e.op(jit::SLJIT_ADD, offset, offset, 0, imm, len);
            continue;
        }
        e.mov(r0, 0, mem | slots, (long)part.slot * 8);
        if (!write) {
            e.op(jit::SLJIT_LSHR, r1, r0, 0, imm, 48);
            e.guard(jit::SLJIT_NOT_EQUAL, r1, 0, imm, (long)(part.integer ? types::TAG_FASTINT : types::TAG_STRING));
        }
        if (part.integer) {
            if (!write) {
                // A signed 48-bit integer occupies at most sixteen bytes.
                // Reserving that bound avoids a separate decimal sizing loop.
                e.op(jit::SLJIT_ADD, offset, offset, 0, imm, 16);
                continue;
            }
            e.op(jit::SLJIT_SHL, r0, r0, 0, imm, 16);
            e.op(jit::SLJIT_ASHR, r0, r0, 0, imm, 16);
            void* positive = e.cmp(jit::SLJIT_SIG_GREATER_EQUAL, r0, 0, imm, 0);
            e.op(jit::SLJIT_ADD, r6, output, 0, offset, 0);
            e.mov(mem | r6, 0, imm, '-', jit::SLJIT_MOV_U8);
            e.op(jit::SLJIT_ADD, offset, offset, 0, imm, 1);
            e.op(jit::SLJIT_SUB, r0, imm, 0, r0, 0);
            e.bind(positive);
            // Format backwards in the reserved span, then compact into place.
            // Eight padding bytes make the short word loads valid at the end.
            e.op(jit::SLJIT_ADD, r7, output, 0, offset, 0);
            e.op(jit::SLJIT_ADD, r7, r7, 0, imm, 15);
            e.mov(r6, 0, r7, 0);
            void* decimal = e.label();
            e.mov(r3, 0, r0, 0);
            e.mov(r1, 0, imm, (long)0xCCCCCCCCCCCCCCCDUL);
            if (jit::sljit_emit_op0(e.compiler, jit::SLJIT_LMUL_UW) != 0) e.failed = true;
            e.op(jit::SLJIT_LSHR, r0, r1, 0, imm, 3);
            e.op(jit::SLJIT_MUL, r1, r0, 0, imm, 10);
            e.op(jit::SLJIT_SUB, r1, r3, 0, r1, 0);
            e.op(jit::SLJIT_ADD, r1, r1, 0, imm, '0');
            e.op(jit::SLJIT_SUB, r6, r6, 0, imm, 1);
            e.mov(mem | r6, 0, r1, 0, jit::SLJIT_MOV_U8);
            e.back(decimal, jit::SLJIT_NOT_EQUAL, r0, 0, imm, 0);
            e.op(jit::SLJIT_SUB, r5, r7, 0, r6, 0);
            e.op(jit::SLJIT_ADD, r4, output, 0, offset, 0);
            // Load both spans before either store: compaction can overlap.
            e.mov(r0, 0, mem | r6, 0);
            e.mov(r1, 0, mem | r7, -8);
            e.mov(mem | r4, 0, r0, 0);
            void* short_number = e.cmp(jit::SLJIT_LESS_EQUAL, r5, 0, imm, 8);
            e.op(jit::SLJIT_ADD, r4, r4, 0, r5, 0);
            e.mov(mem | r4, -8, r1, 0);
            e.bind(short_number);
            e.op(jit::SLJIT_ADD, offset, offset, 0, r5, 0);
        } else {
            e.op(jit::SLJIT_AND, r4, r0, 0, imm, 0x0000FFFFFFFFFFFF);
            if (!write) {
                e.mov(r5, 0, mem | r4, 0, jit::SLJIT_MOV_U32);
                HStringFlags flags;
                flags.is_symbol = true;
                e.op(jit::SLJIT_AND, r5, r5, 0, imm, (long)(uint)flags);
                e.guard(jit::SLJIT_NOT_EQUAL, r5, 0, imm, 0);
            }
            e.mov(r5, 0, mem | r4, length_offset, jit::SLJIT_MOV_U32);
            if (write) {
                e.op(jit::SLJIT_ADD, r4, r4, 0, imm, (long)hstring::HSTRING_HDR_SIZE);
                e.op(jit::SLJIT_ADD, r6, output, 0, offset, 0);
                e.op(jit::SLJIT_ADD, offset, offset, 0, r5, 0);
                e.copy_span();
            } else { e.op(jit::SLJIT_ADD, offset, offset, 0, r5, 0); }
        }
    }
    if (!write) e.guard(jit::SLJIT_GREATER_EQUAL, offset, 0, imm, TEMPLATE_MAX_BYTES + 1);
    e.op(jit::SLJIT_ADD, rows, rows, 0, imm, 8);
    e.back(loop, jit::SLJIT_LESS, rows, 0, end, 0);
    e.bind(empty);
    if (jit::sljit_emit_return(e.compiler, jit::SLJIT_MOV, offset, 0) != 0) e.failed = true;
    void* miss = e.label();
    foreach (guard : e.guards[:e.guard_count]) {
        if (guard && miss) jit::sljit_set_label(guard, miss);
    }
    if (jit::sljit_emit_return(e.compiler, jit::SLJIT_MOV, imm, -1) != 0) e.failed = true;
    if (e.failed) return null;
    void* code = jit::sljit_generate_code(e.compiler, 0, null);
    $if $feat(SLJIT_STATS):
        if (code) plan.code_bytes += jit::sljit_shim_code_size(e.compiler);
    $endif
    return (TemplateNative)code;
}

fn void sljit_template_free(Heap* h, CompiledFunction* cf) @feat(SLJIT) {
    TemplatePlan* plan = (TemplatePlan*)cf.sljit_template;
    if (!plan) return;
    $if $feat(SLJIT_STATS):
        io::eprintfn("SLJIT template %s hits=%d misses=%d parts=%d", (String)cf.get_name(), plan.hits, plan.misses, plan.count);
    $endif
    if (plan.measure) jit::sljit_free_code((void*)plan.measure, null);
    if (plan.write) jit::sljit_free_code((void*)plan.write, null);
    h.free_func(h.heap_udata, plan);
    cf.sljit_template = null;
}

fn Instruction* sljit_template_entry(Instruction* pc, TVal* regs, ColdCtx* cold) @feat(SLJIT) @noinline {
    CompiledFunction* cf = cold.vm.current_func;
    Heap* h = cold.heap;
    if (!h.jit_enabled || pc != cf.code || !sljit_template_candidate(cf) || !types::USE_NANBOX || usz::size != 8
        || h.capi_interrupt_fn != null || h.interrupt_due || h.uncatchable_throw
        || std::core::mem::@atomic_load(h.interrupt_requested) != 0) return pc;
    if (!regs[0].is_object()) return pc;
    HObject* array = regs[0].get_heapptr();
    if (array.get_class() != ARRAY || array.flags.exotic_proxyobj || array.prop_count != 0) return pc;
    uint count = *array.array_len_ptr();
    if (count == 0 || count > 4096 || count > array.array_size || count > array.array_used) return pc;
    TVal* rows = (TVal*)array.array_part();
    if (!rows || !rows[0].is_object()) return pc;
    TemplatePlan* plan = (TemplatePlan*)cf.sljit_template;
    if (!plan) {
        if (cf.sljit_template_calls == 0xFFFFFFFF || cf.sljit_template_calls++ < 16) return pc;
        cf.sljit_template_calls = 0xFFFFFFFF;
        if (!jit::bind_sljit_runtime()) return pc;
        TemplatePlan draft;
        if (!sljit_template_analyze(cf, rows[0].get_heapptr(), h, &draft)) return pc;
        plan = (TemplatePlan*)h.alloc_func(h.heap_udata, TemplatePlan::size);
        if (!plan) return pc;
        *plan = draft;
        cf.sljit_template = plan;
        plan.measure = sljit_template_emit(plan, false);
        plan.write = sljit_template_emit(plan, true);
        if (!plan.measure || !plan.write) { sljit_template_free(h, cf); return pc; }
        $if $feat(SLJIT_STATS):
            io::eprintfn("SLJIT template compiled %s: parts=%d code_bytes=%d plan_bytes=%d", (String)cf.get_name(), plan.count, plan.code_bytes, TemplatePlan::size);
        $endif
    }
    Shape* shape = h.get_shape(plan.shape);
    if (shape == null || shape.generation != plan.generation) return pc;
    long length = plan.measure(rows, count, null);
    if (length < 0) {
        $if $feat(SLJIT_STATS): plan.misses++; $endif
        return pc;
    }
    // alloc_no_gc and registry growth cannot enter JS or move source objects.
    HString* result = hstring::hstring_alloc_storage(h, (uint)length, hstring::HASH_DEFERRED, (uint)length + 8) ?? null;
    if (!result) return pc;
    long written = plan.write(rows, count, result.get_cstr());
    result.blen = (uint)written;
    result.get_cstr()[written] = 0;
    result.finish_data();
    h.large_string_register(result);
    h.set_reg_string(regs + plan.result_reg, result);
    track_heap_store(cold.act, regs + plan.result_reg, plan.result_reg);
    $if $feat(SLJIT_STATS):
        plan.hits++;
        if (plan.hits == 1000) io::eprintfn("SLJIT template native %s: hits=%d misses=%d rows=%d", (String)cf.get_name(), plan.hits, plan.misses, count);
    $endif
    // Publish the result before an incremental collection can advance.
    if (count >= h.bwd_gc_budget) {
        uint elapsed = count - h.bwd_gc_budget;
        uint slices = 1 + elapsed / heap::BWD_GC_INTERVAL;
        h.bwd_gc_budget = heap::BWD_GC_INTERVAL - elapsed % heap::BWD_GC_INTERVAL;
        // A batch crossing several backedge budgets owes each collection slice.
        for (uint i = 0; i < slices && h.gc_pending; i++) h.safepoint_gc();
    } else { h.bwd_gc_budget -= count; }
    vm_charge_interrupt(h);
    return cf.code + plan.return_pc;
}
fn Instruction* sljit_template_dispatch(Instruction* pc, HandlerTable* handlers, TVal* regs, ColdCtx* cold) @feat(SLJIT) @noinline {
    return th_next(sljit_template_entry(pc, regs, cold), handlers, regs, cold);
}
