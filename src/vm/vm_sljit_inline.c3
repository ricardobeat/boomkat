module boomkat::vm;

import boomkat::bytecode;
import boomkat::types;
import boomkat::hobject;
import boomkat::hstring;
import boomkat::heap;
import boomkat::env;
import boomkat::jit;

// A warmed binding or property layout supplies only a hypothesis. Native code
// checks the live callee before doing any work. Compiled templates are retained
// by the heap's compiled_funcs registry until reset, which destroys all native
// plans.
fn int function_inline_site(CompiledFunction* cf, uint pc) @feat(SLJIT) {
    Instruction call = cf.code[pc];
    if (call.op == Opcode.CALL_VAR || call.op == Opcode.CALL_GLOBAL) return (int)pc;
    if (call.op != Opcode.CALL && call.op != Opcode.CALL_UNDEF_THIS) return -1;
    uint reg = call.b;
    for (uint back = pc; back > 0; back--) {
        Instruction ins = cf.code[back - 1];
        if (ins.a != reg) continue;
        if (ins.op == Opcode.LDREG) {
            reg = ins.b;
            continue;
        }
        return ins.op == Opcode.GETVAR || ins.op == Opcode.GETGLOBAL ? (int)(back - 1) : -1;
    }
    return -1;
}
fn CompiledFunction* function_inline_binding(CompiledFunction* cf, uint site, Heap* h) @feat(SLJIT) {
    if (cf.var_ic_entries == null) return null;
    VarICEntry* vic = (VarICEntry*)cf.var_ic_entries + site;
    if (vic.recycle_epoch != h.shape_recycle_epoch || vic.slot_ptr == null || vic.prop_flags.is_accessor) return null;
    HObject* bindings = vic.bindings;
    if (bindings == null || bindings.shape_id != vic.shape_id || vic.prop_idx >= bindings.prop_count) return null;
    TVal value = vic.slot_ptr.get();
    if (!value.is_object() || value.get_heapptr() == null) return null;
    HObject* object = value.get_heapptr();
    if (object.flags.obj_class != ObjClass.FUNCTION || !object.flags.callable || object.flags.is_bound
        || object.flags.exotic_proxyobj
        || object.extra.func.comp_func == null) return null;
    return object.extra.func.comp_func;
}
// Resolve a callee loaded through a warmed property of a global namespace
// object. The property site already carries the receiver guards, and the call
// site still compares the live function identity.
fn CompiledFunction* function_inline_property(CompiledFunction* cf, uint pc, Heap* h) @feat(SLJIT) {
    Instruction call = cf.code[pc];
    if (call.op != Opcode.CALL && call.op != Opcode.CALL_UNDEF_THIS) return null;
    uint reg = call.b;
    for (uint back = pc; back > 0; back--) {
        Instruction ins = cf.code[back - 1];
        if (ins.a != reg) continue;
        if (ins.op == Opcode.LDREG) {
            reg = ins.b;
            continue;
        }
        if (ins.op != Opcode.GETPROPC && ins.op != Opcode.GETPROPC_CACHED) return null;
        if (ins.c >= cf.const_count || !cf.constants[ins.c].is_string()) return null;
        TVal keyv    = cf.constants[ins.c];
        HString* key = keyv.get_heapptr();
        if (key == null || key.is_symbol()) return null;
        uint base = ins.b;
        TVal base_value;
        bool found;
        for (uint inner = back - 1; inner > 0; inner--) {
            Instruction load = cf.code[inner - 1];
            if (load.a != base) continue;
            if (load.op == Opcode.LDREG) {
                base = load.b;
                continue;
            }
            if (load.op != Opcode.GETGLOBAL || cf.var_ic_entries == null) return null;
            VarICEntry* vic = (VarICEntry*)cf.var_ic_entries + (inner - 1);
            if (vic.recycle_epoch != h.shape_recycle_epoch || vic.slot_ptr == null
                || vic.prop_flags.is_accessor) return null;
            base_value = vic.slot_ptr.get();
            found = true;
            break;
        }
        if (!found || !base_value.is_object() || base_value.get_heapptr() == null) return null;
        HObject* object = base_value.get_heapptr();
        if (object.is_proxy() || object.get_class() != ObjClass.OBJECT) return null;
        TVal? value = object.get_prop(key, h);
        HObject* function;
        if (try actual = value) {
            if (!actual.is_object() || actual.get_heapptr() == null) return null;
            function = actual.get_heapptr();
        } else {
            return null;
        }
        if (function.get_class() != ObjClass.FUNCTION || !function.flags.callable || function.flags.is_bound
            || function.flags.exotic_proxyobj
            || function.extra.func.comp_func == null) return null;
        return function.extra.func.comp_func;
    }
    return null;
}
fn bool function_inline_undefined(CompiledFunction* target, uint pc) @feat(SLJIT) {
    Instruction ins = target.code[pc];
    if (ins.op != Opcode.GETGLOBAL || ins.get_bc() >= target.const_count) return false;
    TVal name = target.constants[ins.get_bc()];
    if (!name.is_string()) return false;
    HString* key = name.get_heapptr();
    return key != null && !key.is_symbol() && key.equals("undefined");
}
fn bool function_inline_body(CompiledFunction* target, uint nargs) @feat(SLJIT) {
    if (target == null || target.lazy_paren != 0 || target.code_count > 17 || target.code_count == 0
        || target.num_regs > 32
        || target.num_args != nargs
        || nargs > 8
        || target.is_class_ctor()
        || target.flags.is_generator
        || target.flags.is_async
        || target.flags.has_direct_eval
        || target.mapped_arguments()
        || target.capture_count != 0) return false;
    bool[32] reachable;
    reachable[0] = true;
    bool changed = true;
    while (changed) {
        changed = false;
        for (uint i = 0; i < target.code_count; i++) {
            if (!reachable[i]) continue;
            Instruction ins = target.code[i];
            int branch      = loop_target(ins, i);
            if (branch >= 0) {
                if (branch < (int)target.code_count && !reachable[branch]) {
                    reachable[branch] = true;
                    changed = true;
                }
                if (ins.op == Opcode.JUMP || ins.op == Opcode.RET) continue;
            } else if (ins.op == Opcode.RET) {
                continue;
            }
            if (i + 1 < target.code_count && !reachable[i + 1]) {
                reachable[i + 1] = true;
                changed = true;
            }
        }
    }
    bool[32] defined;
    bool[32] numeric;
    bool[32] undef;
    for (uint i = 0; i < nargs; i++) {
        defined[i] = true;
        numeric[i] = true;
    }
    bool returns;
    for (uint i = 0; i < target.code_count; i++) {
        if (!reachable[i]) continue;
        Instruction ins = target.code[i];
        if (ins.a >= 32) return false;
        switch (ins.op) {
            case NOP:
            case JUMP: continue;
            case RET:
                if (!numeric[ins.a]) return false;
                returns = true;
                continue;
            case LDINT:
                numeric[ins.a] = true;
                defined[ins.a] = true;
                continue;
            case LDCONST:
                if (ins.get_bc() >= target.const_count) return false;
                if (!target.constants[ins.get_bc()].is_number()
                    && !target.constants[ins.get_bc()].is_fastint()) return false;
                numeric[ins.a] = true;
                defined[ins.a] = true;
                continue;
            case GETGLOBAL:
                if (!function_inline_undefined(target, i)) return false;
                undef[ins.a] = true;
                defined[ins.a] = true;
                continue;
            case LDREG:
            case UNM:
            case UNP:
                if (ins.b >= 32 || !defined[ins.b] || !numeric[ins.b]) return false;
                numeric[ins.a] = true;
                defined[ins.a] = true;
                continue;
            case ADD:
            case ADD_FUSED:
            case SUB:
            case MUL:
            case DIV:
                if (ins.b >= 32 || ins.c >= 32 || !numeric[ins.b] || !numeric[ins.c]) return false;
                numeric[ins.a] = true;
                defined[ins.a] = true;
                continue;
            case ADDI:
            case SUBI:
            case MULI:
                if (ins.b >= 32 || !numeric[ins.b]) return false;
                numeric[ins.a] = true;
                defined[ins.a] = true;
                continue;
            default:
                if (ins.op >= Opcode.JMP_NLT && ins.op <= Opcode.JMP_SNEQ) {
                    if (ins.b >= 32 || ins.c >= 32 || (!numeric[ins.b] && !undef[ins.b])
                        || (!numeric[ins.c] && !undef[ins.c])) return false;
                    continue;
                }
                return false;
        }
    }
    return returns;
}
fn CompiledFunction* function_inline_candidate(CompiledFunction* cf, uint pc, Heap* h) @feat(SLJIT) {
    Instruction call = cf.code[pc];
    bool fused       = call.op == Opcode.CALL_VAR || call.op == Opcode.CALL_GLOBAL;
    if (!fused && call.op != Opcode.CALL && call.op != Opcode.CALL_UNDEF_THIS) return null;
    uint nargs = fused ? call.b : call.c;
    uint base  = fused ? call.a : call.b;
    if (base + 1 + nargs >= cf.num_regs) return null;
    CompiledFunction* target;
    int site = function_inline_site(cf, pc);
    if (site >= 0) {
        target = function_inline_binding(cf, (uint)site, h);
    } else {
        target = function_inline_property(cf, pc, h);
    }
    if (!function_inline_body(target, nargs)) return null;
    return target;
}
fn long function_inline_offset(uint reg) @feat(SLJIT) {
    FunctionRun layout;
    return (char*)&layout.inline_values - (char*)&layout + (long)reg * double::size;
}
fn int function_inline_condition(Opcode op) @feat(SLJIT) {
    uint index         = op >= Opcode.JMP_NLTI ? op.ordinal - Opcode.JMP_NLTI.ordinal
        : op.ordinal - Opcode.JMP_NLT.ordinal;
    int[10] conditions = { 27, 34, 29, 32, 26, 35, 28, 33, 24, 25 };
    return conditions[index];
}
fn void FunctionEmitter.inline_call(&self, CompiledFunction* cf, uint pc, Heap* h) @feat(SLJIT) {
    CompiledFunction* target = function_inline_candidate(cf, pc, h);
    if (target == null) {
        self.out.link(jit::sljit_emit_jump(self.out.e.compiler, jit::SLJIT_JUMP), pc, true);
        return;
    }
    Instruction call   = cf.code[pc];
    bool fused         = call.op == Opcode.CALL_VAR || call.op == Opcode.CALL_GLOBAL;
    uint base          = fused ? call.a : call.b;
    uint nargs         = fused ? call.b : call.c;
    LoopEmitter* out   = &self.out;
    TemplateEmitter* e = &out.e;
    int r0             = jit::reg_r(0);
    int r1             = jit::reg_r(1);
    int r2             = jit::reg_r(2);
    int r3             = jit::reg_r(3);
    int imm            = jit::SLJIT_IMM;
    int mem            = jit::SLJIT_MEM;
    int run            = jit::reg_s(2);
    if (fused) {
        VarICEntry* vic = (VarICEntry*)cf.var_ic_entries + pc;
        VarICEntry view;
        Activation activation;
        Heap heap_view;
        e.mov(r2, 0, imm, (long)vic);
        if (call.op == Opcode.CALL_VAR) {
            e.mov(r3, 0, mem | jit::reg_s(1), function_cold_offset(1));
            e.mov(r3, 0, mem | r3, (char*)&activation.lex_env - (char*)&activation);
            out.guard(jit::SLJIT_NOT_EQUAL, r3, 0, mem | r2, (char*)&view.search_head - (char*)&view, pc);
        }
        e.mov(r3, 0, mem | jit::reg_s(1), function_cold_offset(0));
        e.mov(r3, 0, mem | r3, (char*)&heap_view.shape_recycle_epoch - (char*)&heap_view, jit::SLJIT_MOV_U32);
        e.mov(r1, 0, mem | r2, (char*)&view.recycle_epoch - (char*)&view, jit::SLJIT_MOV_U32);
        out.guard(jit::SLJIT_NOT_EQUAL, r3, 0, r1, 0, pc);
        e.mov(r3, 0, mem | r2, (char*)&view.prop_flags - (char*)&view, jit::SLJIT_MOV_U8);
        e.op(jit::SLJIT_AND, r3, r3, 0, imm, 8);
        out.guard(jit::SLJIT_NOT_EQUAL, r3, 0, imm, 0, pc);
        HObject binding_layout;
        e.mov(r1, 0, mem | r2, (char*)&view.bindings - (char*)&view);
        out.guard(jit::SLJIT_EQUAL, r1, 0, imm, 0, pc);
        e.mov(r3, 0, mem | r1, (char*)&binding_layout.shape_id - (char*)&binding_layout, jit::SLJIT_MOV_U32);
        e.mov(r1, 0, mem | r2, (char*)&view.shape_id - (char*)&view, jit::SLJIT_MOV_U32);
        out.guard(jit::SLJIT_NOT_EQUAL, r3, 0, r1, 0, pc);
        e.mov(r2, 0, mem | r2, (char*)&view.slot_ptr - (char*)&view);
        out.guard(jit::SLJIT_EQUAL, r2, 0, imm, 0, pc);
        e.mov(r0, 0, mem | r2, 0);
    } else {
        out.load(base, r0);
    }
    e.op(jit::SLJIT_LSHR, r3, r0, 0, imm, 48);
    out.guard(jit::SLJIT_NOT_EQUAL, r3, 0, imm, (long)types::TAG_OBJECT, pc);
    e.op(jit::SLJIT_AND, r0, r0, 0, imm, (long)types::NANBOX_PAYLOAD_MASK);
    out.guard(jit::SLJIT_EQUAL, r0, 0, imm, 0, pc);
    HObject object;
    ObjFlags wanted;
    wanted.callable = true;
    wanted.obj_class = FUNCTION;
    ObjFlags forbidden;
    forbidden.is_bound = true;
    forbidden.exotic_proxyobj = true;
    e.mov(r1, 0, mem | r0, 0, jit::SLJIT_MOV_U32);
    e.op(jit::SLJIT_AND, r1, r1, 0, imm, 0x003F0000U | (uint)wanted | (uint)forbidden);
    out.guard(jit::SLJIT_NOT_EQUAL, r1, 0, imm, (uint)wanted, pc);
    e.mov(r1, 0, mem | r0, (char*)&object.extra.func.comp_func - (char*)&object);
    out.guard(jit::SLJIT_NOT_EQUAL, r1, 0, imm, (long)target, pc);
    e.mov(r1, 0, mem | r0, (char*)&object.extra.func.realm - (char*)&object);
    out.guard(jit::SLJIT_NOT_EQUAL, r1, 0, imm, (long)target.realm, pc);
    // Every guard exits at CALL. Only private invocation scratch is changed;
    // neither the caller's argument window nor a callee activation is touched.
    for (uint i = 0; i < nargs; i++) {
        if (out.flow != null) {
            self.flow_number(base + 2 + i, 1, pc);
        } else {
            out.load(base + 2 + i, r0);
            out.number(r0, 1, pc);
        }
        out.fop(jit::SLJIT_MOV_F64, mem | run, function_inline_offset(i), 1, 0);
    }
    void*[32] labels;
    void*[64] pending;
    uint[64] pending_target;
    uint pending_count;
    bool[32] numeric;
    bool[32] undef;
    for (uint i = 0; i < nargs; i++) numeric[i] = true;
    for (uint i = 0; i <= target.code_count; i++) {
        labels[i] = e.label();
        for (uint j = 0; j < pending_count; j++) {
            if (pending_target[j] != i) continue;
            jit::sljit_set_label(pending[j], labels[i]);
            pending[j] = null;
        }
        if (i == target.code_count) break;
        Instruction ins = target.code[i];
        int branch      = loop_target(ins, i);
        if (branch >= 0) {
            if (ins.op == Opcode.JUMP) {
                pending[pending_count] = jit::sljit_emit_jump(e.compiler, jit::SLJIT_JUMP);
                pending_target[pending_count++] = (uint)branch;
            } else if (ins.op >= Opcode.JMP_NLT && ins.op <= Opcode.JMP_SNEQ) {
                if (undef[ins.b] || undef[ins.c]) {
                    bool taken = ins.op == Opcode.JMP_SNEQ;
                    if (taken) {
                        pending[pending_count] = jit::sljit_emit_jump(e.compiler, jit::SLJIT_JUMP);
                        pending_target[pending_count++] = (uint)branch;
                    }
                } else {
                    out.fop(jit::SLJIT_MOV_F64, 1, 0, mem | run, function_inline_offset(ins.b));
                    out.fop(jit::SLJIT_MOV_F64, 2, 0, mem | run, function_inline_offset(ins.c));
                    void* jump = jit::sljit_emit_fcmp(e.compiler, function_inline_condition(ins.op), 1, 0, 2, 0);
                    if (jump == null) {
                        e.failed = true;
                    } else {
                        pending[pending_count] = jump;
                        pending_target[pending_count++] = (uint)branch;
                    }
                }
            }
            continue;
        }
        switch (ins.op) {
            case NOP: continue;
            case GETGLOBAL: continue;
            case LDINT:
            case LDCONST:

                {
                    double value;
                    if (ins.op == Opcode.LDINT) {
                        value = (double)ins.get_sbc();
                    } else {
                        value = target.constants[ins.get_bc()].get_number_or_fastint();
                    }
                    e.mov(r0, 0, imm, (long)bitcast(value, ulong));
                    out.fcopy(jit::SLJIT_COPY_TO_F64, 1, r0);
                    out.fop(jit::SLJIT_MOV_F64, mem | run, function_inline_offset(ins.a), 1, 0);
                    numeric[ins.a] = true;
                }
            case LDREG:

                {
                    out.fop(
                        jit::SLJIT_MOV_F64,
                        mem | run,
                        function_inline_offset(ins.a),
                        mem | run,
                        function_inline_offset(ins.b)
                    );
                    numeric[ins.a] = numeric[ins.b];
                }
            case RET:

                {
                    out.fop(jit::SLJIT_MOV_F64, 1, 0, mem | run, function_inline_offset(ins.a));
                    pending[pending_count] = jit::sljit_emit_jump(e.compiler, jit::SLJIT_JUMP);
                    pending_target[pending_count++] = target.code_count;
                }
            case UNM:

                {
                    out.fop(jit::SLJIT_MOV_F64, 1, 0, mem | run, function_inline_offset(ins.b));
                    out.fop(jit::SLJIT_NEG_F64, 1, 0, 1, 0);
                    out.fop(jit::SLJIT_MOV_F64, mem | run, function_inline_offset(ins.a), 1, 0);
                    numeric[ins.a] = true;
                }
            case UNP:

                {
                    out.fop(
                        jit::SLJIT_MOV_F64,
                        mem | run,
                        function_inline_offset(ins.a),
                        mem | run,
                        function_inline_offset(ins.b)
                    );
                    numeric[ins.a] = true;
                }
            default:

                {
                    out.fop(jit::SLJIT_MOV_F64, 1, 0, mem | run, function_inline_offset(ins.b));
                    if (ins.op == Opcode.ADDI || ins.op == Opcode.SUBI || ins.op == Opcode.MULI) {
                        e.mov(r0, 0, imm, (ichar)ins.c);
                        out.fop(jit::SLJIT_CONV_F64_FROM_SW, 2, 0, r0, 0);
                    } else {
                        out.fop(jit::SLJIT_MOV_F64, 2, 0, mem | run, function_inline_offset(ins.c));
                    }
                    int op = ins.op == Opcode.ADD || ins.op == Opcode.ADD_FUSED
                        || ins.op == Opcode.ADDI ? jit::SLJIT_ADD_F64
                        : (ins.op == Opcode.SUB || ins.op == Opcode.SUBI) ? jit::SLJIT_SUB_F64
                        : (ins.op == Opcode.MUL || ins.op == Opcode.MULI) ? jit::SLJIT_MUL_F64
                        : jit::SLJIT_DIV_F64;
                    if (jit::sljit_emit_fop2(e.compiler, op, 1, 0, 1, 0, 2, 0) != 0) e.failed = true;
                    out.fop(jit::SLJIT_MOV_F64, mem | run, function_inline_offset(ins.a), 1, 0);
                    numeric[ins.a] = true;
                }
        }
    }
    out.float_result(1);
    self.store(call.a, pc, true);
    $if $feat(SLJIT_STATS):
        e.mov(r3, 0, imm, (long)&self.plan.inline_calls);
        e.mov(r1, 0, mem | r3, 0);
        e.op(jit::SLJIT_ADD, r1, r1, 0, imm, 1);
        e.mov(mem | r3, 0, r1, 0);
    $endif
}