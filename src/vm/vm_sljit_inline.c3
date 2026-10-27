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
        if (ins.op != Opcode.GETPROPC && ins.op != Opcode.GETPROPC_CACHED) {
            return null;
        }
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
// A method read through a warmed property site whose owner is the receiver's
// immediate prototype. The site cache already carries the link, so the value in
// the owner's slot names the callee at compile time; the call still compares the
// live function identity before using the inlined body.
fn CompiledFunction* function_inline_method(CompiledFunction* cf, uint pc, Heap* h) @feat(SLJIT) {
    Instruction call = cf.code[pc];
    if (call.op != Opcode.CALL && call.op != Opcode.CALL_UNDEF_THIS || cf.ic_entries == null) {
        return null;
    }
    uint reg = call.b;
    for (uint back = pc; back > 0; back--) {
        Instruction ins = cf.code[back - 1];
        if (ins.a != reg) continue;
        if (ins.op == Opcode.LDREG) {
            reg = ins.b;
            continue;
        }
        if (ins.op != Opcode.GETPROPC && ins.op != Opcode.GETPROPC_CACHED) {
            return null;
        }
        if (ins.c >= cf.const_count || !cf.constants[ins.c].is_string()) return null;
        ICEntry* ic = (ICEntry*)cf.ic_entries + (back - 1);
        // An inherited read is either a one-link snapshot or an epoch-guarded
        // owner; both name the object holding the method.
        bool epoch = ic.chain_len == hobject::IC_CHAIN_EPOCH || ic.chain_len == hobject::IC_CHAIN_PROTO;
        if (ic.key.borrow() != cf.constants[ins.c].get_heapptr() || (!epoch && ic.chain_len != 1)
            || ic.prop_flags.is_accessor
            || !ic.has_proto
            || ic.prop_idx >= hobject::IC_PROP_MISSING) {
            return null;
        }
        HObject* owner = hobject::ic_cached_proto(ic);
        if (owner == null || owner.is_proxy() || owner.get_class() != ObjClass.OBJECT) return null;
        if (!epoch && owner.shape_id != ic.chain.snapshot.shapes[0]) return null;
        if (ic.prop_idx >= owner.prop_count) return null;
        TVal value = owner.prop_values()[ic.prop_idx].get();
        if (!value.is_object() || value.get_heapptr() == null) return null;
        HObject* function = value.get_heapptr();
        if (function.get_class() != ObjClass.FUNCTION || !function.flags.callable || function.flags.is_bound
            || function.flags.exotic_proxyobj
            || function.extra.func.comp_func == null) return null;
        return function.extra.func.comp_func;
    }
    return null;
}
fn CompiledFunction* function_inline_target(CompiledFunction* cf, uint pc, Heap* h) @feat(SLJIT) {
    Instruction call = cf.code[pc];
    bool fused       = call.op == Opcode.CALL_VAR || call.op == Opcode.CALL_GLOBAL;
    if (!fused && call.op != Opcode.CALL && call.op != Opcode.CALL_UNDEF_THIS) return null;
    uint nargs = fused ? call.b : call.c;
    uint base  = fused ? call.a : call.b;
    if (base + 1 + nargs >= cf.num_regs) return null;
    int site = function_inline_site(cf, pc);
    if (site >= 0) return function_inline_binding(cf, (uint)site, h);
    CompiledFunction* target = function_inline_property(cf, pc, h);
    if (target != null) return target;
    return function_inline_method(cf, pc, h);
}
fn CompiledFunction* function_inline_candidate(CompiledFunction* cf, uint pc, Heap* h) @feat(SLJIT) {
    Instruction call = cf.code[pc];
    bool fused       = call.op == Opcode.CALL_VAR || call.op == Opcode.CALL_GLOBAL;
    if (!fused && call.op != Opcode.CALL && call.op != Opcode.CALL_UNDEF_THIS) return null;
    uint nargs               = fused ? call.b : call.c;
    CompiledFunction* target = function_inline_target(cf, pc, h);
    if (!function_inline_body(target, nargs)) return null;
    return target;
}
fn long function_inline_offset(uint reg) @feat(SLJIT) {
    FunctionRun layout;
    return (char*)&layout.inline_values - (char*)&layout + (long)reg * double::size;
}
// Each nesting level owns a fixed window inside the run block, so a nested
// expansion cannot overwrite the caller's temporaries.
fn long function_inline_window(uint depth) @feat(SLJIT) {
    FunctionRun layout;
    return (char*)&layout.inline_values - (char*)&layout + (long)depth * 32 * double::size;
}
// The window slot that holds an expanded callee's receiver. Register slots
// above the inliner's limit are otherwise unused, and the window base is
// already a working address for the callee's own stores.
const uint INLINE_THIS_SLOT = 30;
fn void FunctionEmitter.inline_guards(
    &self,
    CompiledFunction* cf,
    uint pc,
    CompiledFunction* target,
    Heap* h,
    uint base
) @feat(SLJIT) {
    LoopEmitter* out   = &self.out;
    TemplateEmitter* e = &out.e;
    int r0             = jit::reg_r(0);
    int r1             = jit::reg_r(1);
    int r2             = jit::reg_r(2);
    int r3             = jit::reg_r(3);
    int imm            = jit::SLJIT_IMM;
    int mem            = jit::SLJIT_MEM;
    bool fused         = cf.code[pc].op == Opcode.CALL_VAR || cf.code[pc].op == Opcode.CALL_GLOBAL;
    if (fused) {
        VarICEntry* vic = (VarICEntry*)cf.var_ic_entries + pc;
        VarICEntry view;
        Activation activation;
        Heap heap_view;
        e.mov(r2, 0, imm, (long)vic);
        if (cf.code[pc].op == Opcode.CALL_VAR) {
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
}

fn void FunctionEmitter.inline_call(&self, CompiledFunction* cf, uint pc, Heap* h) @feat(SLJIT) {
    CompiledFunction* target = function_inline_candidate(cf, pc, h);
    if (target == null) {
        if (self.inline_general(cf, pc, h)) return;
        if (self.native_call(cf, pc, h)) return;
        $if $feat(SLJIT_STATS):
        {
            TemplateEmitter* se = &self.out.e;
            int sr3             = jit::reg_r(3);
            int sr1             = jit::reg_r(1);
            se.mov(sr3, 0, jit::SLJIT_IMM, (long)&self.plan.bail_calls);
            se.mov(sr1, 0, jit::SLJIT_MEM | sr3, 0);
            se.op(jit::SLJIT_ADD, sr1, sr1, 0, jit::SLJIT_IMM, 1);
            se.mov(jit::SLJIT_MEM | sr3, 0, sr1, 0);
        }
        $endif
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
    self.inline_guards(cf, pc, target, h, base);
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
                    void* jump = jit::sljit_emit_fcmp(e.compiler, loop_float_condition(ins.op), 1, 0, 2, 0);
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
// A bounded forward body with explicit recovery at every guard. Stores may
// precede later guards because exits resume the exact expanded instruction.
fn bool function_inline_general_body(CompiledFunction* target, uint nargs, Heap* h, uint depth) @feat(SLJIT) {
    if (target == null || target.lazy_paren != 0 || target.code_count == 0 || target.code_count > 48
        || target.num_regs > 24
        || target.num_args != nargs
        || nargs > 8
        || target.is_class_ctor()
        || target.flags.is_generator
        || target.flags.is_async
        || target.flags.has_direct_eval
        || target.mapped_arguments()
        || target.capture_count != 0
        || !target.call_flags.lean_call || target.arguments_in_reg() || target.call_flags.rest_length_only
        || target.ic_entries == null) return false;
    uint returns;
    for (uint i = 0; i < target.code_count; i++) {
        Instruction ins = target.code[i];
        int branch      = loop_target(ins, i);
        if (branch > (int)target.code_count) return false;
        switch (ins.op) {
            case NOP:
                continue;
            case LDREG:

                if (ins.a >= 24 || ins.b >= 24) return false;
                continue;
            case LDINT:
            case LDCONST:
            case LDTRUE:
            case LDFALSE:
            case LDNULL:
            case LDUNDEF:
            case VOID:
            case LDTHIS:

                if (ins.a >= 24 && branch < 0 && ins.op != LDINT && ins.op != LDCONST && ins.op != LDTRUE
                    && ins.op != LDFALSE
                    && ins.op != LDNULL
                    && ins.op != LDUNDEF
                    && ins.op != VOID) return false;
                continue;
            case GETTHISC:
            case GETPROPC:
            case GETPROPC_CACHED:
            case GETPROP:
            case GETPROP_CACHE:
            case GETVAR:
            case GETGLOBAL:

                if (ins.a >= 24 && branch < 0) return false;
                continue;
            case ADD:
            case ADD_FUSED:
            case ADDI:
            case SUB:
            case SUBI:
            case MUL:
            case MULI:
            case DIV:
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
            case LT:
            case LE:
            case GT:
            case GE:
            case EQ:
            case NEQ:
            case SEQ:
            case SNEQ:

                if (ins.a >= 24 && branch < 0) return false;
                continue;
            case BNOT:
            case UNM:
            case UNP:
            case TONUMERIC:
            case INC:
            case INC_LT:
            case DEC:
            case LNOT:

                if (ins.a >= 24 && branch < 0) return false;
                continue;
            case CALL:
            case CALL_VAR:
            case CALL_GLOBAL:
            case CALL_UNDEF_THIS:

                {
                    // Every nested call must have a recoverable expansion.
                    if (depth + 1 >= INLINE_DEPTH) return false;
                    CompiledFunction* inner = function_inline_general_candidate(target, i, h, depth + 1);
                    if (inner == null) return false;

                    continue;
                }
            case PUTTHISC:
            case PUTPROPC:
            case PUTPROP:

                {
                    uint value = ins.op == Opcode.PUTTHISC ? ins.a
                        : ins.op == Opcode.PUTPROP ? ins.c
                        : ins.b;
                    if (value >= 24) return false;
                    continue;
                }
            case IF_TRUE:
            case IF_FALSE:
            case JUMP:
            case JMP_NLT..JMP_SNEQ:
            case JMP_NLTI..JMP_SNEQI:
                if (branch < 0 && ins.a >= 24) return false;
                continue;
            case JMP_EQ:
            case JMP_NEQ:
            case JMP_NULL:
            case JMP_NNULL:
                continue;
            case RET:
            case RETUNDEF:
                returns++;
                continue;
            default:

                {
                    return false;
                }
        }
    }
    return returns > 0;
}
// A straight-line leaf that only computes from its arguments and fields of
// `this` can be expanded into the loop tier's flat SSA form. Reads of `this`
// become shape-guarded field loads, so the expansion needs no call machinery.
fn bool function_inline_ssa_leaf(CompiledFunction* target, uint nargs) @feat(SLJIT) {
    if (target == null || target.lazy_paren != 0 || target.code_count == 0 || target.code_count > 24
        || target.num_regs > 32
        || target.num_args != nargs
        || nargs > 8
        || target.is_class_ctor()
        || target.flags.is_generator
        || target.flags.is_async
        || target.flags.has_direct_eval
        || target.mapped_arguments()
        || target.capture_count != 0) return false;
    bool[32] defined;
    for (uint i = 0; i < nargs; i++) defined[i] = true;
    bool returns;
    for (uint i = 0; i < target.code_count; i++) {
        Instruction ins = target.code[i];
        if (loop_target(ins, i) >= 0) return false;
        if (ins.a >= 32) return false;
        switch (ins.op) {
            case NOP: continue;
            case RET:
                if (!defined[ins.a]) return false;
                returns = true;
                continue;
            case LDTHIS:
            case LDINT:
            case LDCONST: defined[ins.a] = true; continue;
            case LDREG:
            case UNP:
                if (ins.b >= 32 || !defined[ins.b]) return false;
                defined[ins.a] = true;
                continue;
            case GETPROPC:
            case GETPROPC_CACHED:
            case GETTHISC:

                {
                    bool receiver = ins.op == Opcode.GETTHISC;
                    if (!receiver) {
                        if (ins.b >= 32 || !defined[ins.b] || ins.c >= target.const_count
                            || !target.constants[ins.c].is_string()) return false;
                    }
                    if (target.ic_entries == null) return false;
                    ICEntry* ic = (ICEntry*)target.ic_entries + i;
                    if (ic.key.borrow() == null || ic.chain_len != 0 || ic.prop_flags.is_accessor
                        || ic.prop_idx >= hobject::IC_PROP_MISSING) return false;
                    defined[ins.a] = true;
                    continue;
                }
            case ADD:
            case ADD_FUSED:
            case SUB:
            case MUL:
            case DIV:
                if (ins.b >= 32 || ins.c >= 32 || !defined[ins.b] || !defined[ins.c]) return false;
                defined[ins.a] = true;
                continue;
            case ADDI:
            case SUBI:
            case MULI:
            case UNM:
                if (ins.b >= 32 || !defined[ins.b]) return false;
                defined[ins.a] = true;
                continue;
            default: return false;
        }
    }
    return returns;
}
fn CompiledFunction* function_inline_ssa_candidate(CompiledFunction* cf, uint pc, Heap* h) @feat(SLJIT) {
    Instruction call = cf.code[pc];
    if (call.op != Opcode.CALL && call.op != Opcode.CALL_UNDEF_THIS) return null;
    uint nargs               = call.c;
    CompiledFunction* target = function_inline_target(cf, pc, h);
    if (!function_inline_ssa_leaf(target, nargs)) return null;
    return target;
}
fn CompiledFunction* function_inline_general_candidate(CompiledFunction* cf, uint pc, Heap* h, uint depth = 1) @feat(SLJIT) {
    Instruction call = cf.code[pc];
    bool fused       = call.op == Opcode.CALL_VAR || call.op == Opcode.CALL_GLOBAL;
    if (!fused && call.op != Opcode.CALL && call.op != Opcode.CALL_UNDEF_THIS) return null;
    uint nargs               = fused ? call.b : call.c;
    CompiledFunction* target = function_inline_target(cf, pc, h);
    if (target == null) {
        return null;
    }
    // A plain call's sloppy receiver coercion is the interpreter's job.
    if ((call.op == Opcode.CALL_UNDEF_THIS || call.op == Opcode.CALL_GLOBAL || call.op == Opcode.CALL_VAR)
        && !target.call_flags.ignores_this) return null;
    if (!function_inline_general_body(target, nargs, h, depth)) return null;
    return target;
}
fn bool function_call_inlineable(CompiledFunction* cf, uint pc, Heap* h) @feat(SLJIT) {
    return function_inline_candidate(cf, pc, h) != null || function_inline_general_candidate(cf, pc, h) != null;
}

// Inline into a virtual register window. Counted values leave before being
// stored there; inert/traced values remain live without collection. Each
// guard carries the exact virtual frame and PC for reconstruction on escape.
fn bool FunctionEmitter.inline_general(&self, CompiledFunction* cf, uint pc, Heap* h) @feat(SLJIT) {
    if (self.depth + 1 >= INLINE_DEPTH) return false;
    CompiledFunction* target = function_inline_general_candidate(cf, pc, h, self.depth + 1);
    if (target == null) {
        return false;
    }
    LoopEmitter* out = &self.out;
    Instruction call = cf.code[pc];
    bool fused       = call.op == Opcode.CALL_VAR || call.op == Opcode.CALL_GLOBAL;
    uint base        = fused ? call.a : call.b;
    uint nargs       = fused ? call.b : call.c;
    if ((usz)out.link_count + (usz)target.code_count + 8 >= out.links.len) return false;
    int window   = jit::reg_s(5);
    int imm       = jit::SLJIT_IMM;
    int mem       = jit::SLJIT_MEM;
    int r0        = jit::reg_r(0);
    int r1        = jit::reg_r(1);
    int r2        = jit::reg_r(2);
    int r3        = jit::reg_r(3);
    self.flow_materialize();
    self.inline_guards(cf, pc, target, h, base);
    TemplateEmitter* e = &out.e;
    if (self.plan.inline_count == 128) { e.failed = true; return false; }
    FunctionInlineFrame* frame = h.alloc_func(h.heap_udata, FunctionInlineFrame::size);
    if (frame == null) { e.failed = true; return false; }
    *frame = { .id = ++self.plan.inline_count, .next = self.plan.inline_frames, .parent = out.inline_frame, .target = target,
        .call_pc = cf.code + pc, .depth = self.depth + 1,
        .bottom_offset = (out.inline_frame != null ? out.inline_frame.bottom_offset : 0) + base + 2 };
    self.plan.inline_frames = frame;
    int run = jit::reg_s(2);
    long offset = function_inline_window(frame.depth);
    // inline_guards leaves the live function object in R0.
    e.op(jit::SLJIT_OR, r0, r0, 0, imm, (long)((ulong)types::TAG_OBJECT << 48));
    e.mov(mem | run, offset + loop_value_offset(INLINE_CALLEE_SLOT), r0, 0);
    HObject function_layout;
    e.op(jit::SLJIT_AND, r0, r0, 0, imm, (long)types::NANBOX_PAYLOAD_MASK);
    e.mov(r1, 0, mem | r0, (char*)&function_layout.extra.func.var_env - (char*)&function_layout);
    out.guard(jit::SLJIT_EQUAL, r1, 0, imm, 0, pc);
    e.mov(r1, 0, mem | r0, (char*)&function_layout.extra.func.lex_env - (char*)&function_layout);
    void* no_lex = e.cmp(jit::SLJIT_EQUAL, r1, 0, imm, 0);
    e.mov(r1, 0, mem | r1, $reflect(EnvRecord.flags).offset, jit::SLJIT_MOV_U8);
    e.op(jit::SLJIT_AND, r1, r1, 0, imm, 4);
    out.guard(jit::SLJIT_NOT_EQUAL, r1, 0, imm, 0, pc);
    e.bind(no_lex);
    e.mov(r1, 0, mem | jit::reg_s(1), $reflect(ColdCtx.heap).offset);
    e.mov(r1, 0, mem | r1, $reflect(Heap.realm).offset);
    out.guard(jit::SLJIT_NOT_EQUAL, r1, 0, imm, (long)target.realm, pc);
    // Reserve recovery space before any observable effect. The virtual calls
    // cannot allocate or change the VM stack while this expansion is active.
    e.mov(r0, 0, mem | jit::reg_s(1), $reflect(ColdCtx.vm).offset);
    e.mov(r1, 0, mem | r0, $reflect(Vm.activation_count).offset, jit::SLJIT_MOV_U32);
    e.op(jit::SLJIT_ADD, r1, r1, 0, imm, frame.depth);
    e.mov(r2, 0, mem | r0, $reflect(Vm.activation_capacity).offset, jit::SLJIT_MOV_U32);
    out.guard(jit::SLJIT_GREATER, r1, 0, r2, 0, pc);
    e.mov(r1, 0, mem | r0, $reflect(Vm.valstack_end).offset);
    e.op(jit::SLJIT_ADD, r2, jit::reg_s(0), 0, imm,
        loop_value_offset(frame.bottom_offset + target.num_regs + FRAME_SCRATCH_SLOTS));
    out.guard(jit::SLJIT_GREATER, r2, 0, r1, 0, pc);
    // The result can be assigned without a late ownership guard after stores.
    out.load(call.a, r0);
    e.op(jit::SLJIT_LSHR, r3, r0, 0, imm, 48);
    out.guard(jit::SLJIT_EQUAL, r3, 0, imm, (long)types::TAG_STRING, pc);
    if (!target.call_flags.ignores_this) {
        out.load(base + 1, r0);
        e.op(jit::SLJIT_LSHR, r3, r0, 0, imm, 48);
        out.guard(jit::SLJIT_NOT_EQUAL, r3, 0, imm, (long)types::TAG_OBJECT, pc);
        e.op(jit::SLJIT_AND, r3, r0, 0, imm, (long)types::NANBOX_PAYLOAD_MASK);
        out.guard(jit::SLJIT_EQUAL, r3, 0, imm, 0, pc);
    } else {
        TVal ignored; ignored.set_undefined();
        e.mov(r0, 0, imm, (long)loop_bits(ignored));
    }
    e.mov(mem | run, offset + loop_value_offset(INLINE_THIS_SLOT), r0, 0);
    for (uint i = 0; i < nargs; i++) {
        out.load(base + 2 + i, r0);
        e.op(jit::SLJIT_LSHR, r3, r0, 0, imm, 48);
        out.guard(jit::SLJIT_EQUAL, r3, 0, imm, (long)types::TAG_STRING, pc);
        e.mov(mem | run, offset + loop_value_offset(i), r0, 0);
    }
    e.op(jit::SLJIT_ADD, window, run, 0, imm, offset);
    TVal undef;
    undef.set_undefined();
    for (uint i = nargs; i < target.num_regs; i++) {
        e.mov(mem | window, loop_value_offset(i), imm, (long)loop_bits(undef));
    }

    LoopPlan inner_loop;
    FunctionEmitter inner;
    inner.out.e.compiler = out.e.compiler;
    inner.out.plan = &inner_loop;
    inner.out.function_mode = true;
    inner.out.raw_store = true;
    inner.out.state_reg = window;
    inner.plan = self.plan;
    inner.out.inline_frame = frame;
    inner.out.flow = &inner.flow;
    inner.blocks[0] = true;
    for (uint i = 0; i < target.code_count; i++) {
        int destination = loop_target(target.code[i], i);
        if (destination >= 0 && destination < (int)target.code_count) inner.blocks[destination] = true;
        if ((destination >= 0 || function_call_op(target.code[i].op)) && i + 1 < target.code_count) inner.blocks[i + 1] = true;
    }
    inner.cf = target;
    inner.depth = self.depth + 1;
    inner.this_in_window = true;
    TemplateEmitter* ie = &inner.out.e;
    void*[64] labels;
    void*[64] pending;
    uint[64] pending_target;
    uint pending_count;
    for (uint i = 0; i <= target.code_count; i++) {
        if (i < target.code_count && inner.blocks[i]) inner.flow_flush();
        labels[i] = ie.label();
        $if $feat(SLJIT_MAP): frame.map_pcs[i] = labels[i]; $endif
        for (uint j = 0; j < pending_count; j++) {
            if (pending_target[j] != i) continue;
            jit::sljit_set_label(pending[j], labels[i]);
            pending[j] = null;
        }
        if (i == target.code_count) break;
        Instruction ins = target.code[i];
        int branch      = loop_target(ins, i);
        if (branch >= 0) {
            inner.flow_materialize();
            if (ins.op == Opcode.JUMP) {
                pending[pending_count] = inner.inline_jump(i, (uint)branch);
                pending_target[pending_count++] = (uint)branch;
            } else if (ins.op == Opcode.IF_TRUE || ins.op == Opcode.IF_FALSE) {
                inner.truth(ins.a, i);
                void* skip = ie.cmp(ins.op == Opcode.IF_TRUE ? jit::SLJIT_EQUAL : jit::SLJIT_NOT_EQUAL, r0, 0, imm, 0);
                pending[pending_count] = inner.inline_jump(i, (uint)branch);
                pending_target[pending_count++] = (uint)branch;
                ie.bind(skip);
            } else if (ins.op == Opcode.JMP_SEQ || ins.op == Opcode.JMP_SNEQ || ins.op == Opcode.JMP_SEQI
                || ins.op == Opcode.JMP_SNEQI) {
                inner.equal(
                    ins,
                    ins.op == Opcode.JMP_SEQI || ins.op == Opcode.JMP_SNEQI,
                    ins.op == Opcode.JMP_SNEQ || ins.op == Opcode.JMP_SNEQI,
                    i
                );
                void* skip = ie.cmp(jit::SLJIT_EQUAL, r0, 0, imm, 0);
                pending[pending_count] = inner.inline_jump(i, (uint)branch);
                pending_target[pending_count++] = (uint)branch;
                ie.bind(skip);
            } else if (ins.op == Opcode.JMP_EQ || ins.op == Opcode.JMP_NEQ) {
                inner.loose_equal(ins, ins.op == Opcode.JMP_NEQ, i);
                void* skip = ie.cmp(jit::SLJIT_EQUAL, r0, 0, imm, (long)types::TAG_BOOLEAN << 48);
                pending[pending_count] = inner.inline_jump(i, (uint)branch);
                pending_target[pending_count++] = (uint)branch;
                ie.bind(skip);
            } else if (ins.op == Opcode.JMP_NULL || ins.op == Opcode.JMP_NNULL) {
                inner.null_check(ins, ins.op == Opcode.JMP_NNULL, i);
                void* skip = ie.cmp(jit::SLJIT_EQUAL, r0, 0, imm, 0);
                pending[pending_count] = inner.inline_jump(i, (uint)branch);
                pending_target[pending_count++] = (uint)branch;
                ie.bind(skip);
            } else {
                void*[2] skips = inner.out.condition(ins, i);
                pending[pending_count] = inner.inline_jump(i, (uint)branch);
                pending_target[pending_count++] = (uint)branch;
                void* next = ie.label();
                foreach (jump : skips) if (jump != null) inner.out.bind_to(jump, next);
            }
            continue;
        }
        switch (ins.op) {
            case NOP: continue;
            case LDREG: {
                uint token = inner.flow.token(ins.b, false);
                uint shape = inner.flow.shapes[ins.b];
                inner.out.load(ins.b, r0); inner.store(ins.a, i);
                inner.flow.same_value(ins.a, token, shape);
                continue;
            }
            case LDTHIS: {
                inner.out.load(INLINE_THIS_SLOT, r0); inner.store(ins.a, i);
                inner.flow.same_value(ins.a, FLOW_THIS, inner.flow.this_shape);
                continue;
            }
            case LDINT: { TVal v; v.set_fastint(ins.get_sbc()); ie.mov(r0, 0, imm, (long)loop_bits(v)); }
            case LDCONST: ie.mov(r0, 0, imm, (long)loop_bits(target.constants[ins.get_bc()]));
            case LDTRUE:
            case LDFALSE:
            case LDNULL:
            case LDUNDEF:
            case VOID:

                {
                    TVal v;
                    if (ins.op == Opcode.LDTRUE || ins.op == Opcode.LDFALSE) {
                        v.set_boolean(ins.op == Opcode.LDTRUE);
                    } else if (ins.op == Opcode.LDNULL) {
                        v.set_null();
                    } else {
                        v.set_undefined();
                    }
                    ie.mov(r0, 0, imm, (long)loop_bits(v));
                }
            case GETTHISC:
            case GETPROPC:
            case GETPROPC_CACHED:
            case GETPROP:
            case GETPROP_CACHE:
                inner.property(target, i, false, h);
                continue;
            case PUTTHISC:
            case PUTPROPC:
            case PUTPROP:
                inner.property(target, i, true, h);
                continue;
            case GETVAR:
            case GETGLOBAL:

                {
                    VarICEntry* vic = (VarICEntry*)target.var_ic_entries + i;
                    VarICEntry view;
                    Heap heap_view;
                    ie.mov(r2, 0, imm, (long)vic);
                    if (ins.op == Opcode.GETVAR) {
                        // The virtual callee can close over a different scope
                        // from its real caller, even when both share bytecode.
                        ie.mov(r0, 0, mem | window, loop_value_offset(INLINE_CALLEE_SLOT));
                        ie.op(jit::SLJIT_AND, r0, r0, 0, imm, (long)types::NANBOX_PAYLOAD_MASK);
                        ie.mov(r3, 0, mem | r0, (char*)&function_layout.extra.func.var_env - (char*)&function_layout);
                        ie.mov(r1, 0, mem | r0, (char*)&function_layout.extra.func.lex_env - (char*)&function_layout);
                        void* same_env = ie.cmp(jit::SLJIT_EQUAL, r1, 0, imm, 0);
                        ie.mov(r0, 0, mem | r1, $reflect(EnvRecord.flags).offset, jit::SLJIT_MOV_U8);
                        ie.op(jit::SLJIT_AND, r0, r0, 0, imm, 1);
                        void* object_env = ie.cmp(jit::SLJIT_EQUAL, r0, 0, imm, 0);
                        ie.mov(r3, 0, r1, 0);
                        ie.bind(same_env);
                        ie.bind(object_env);
                        inner.out.guard(
                            jit::SLJIT_NOT_EQUAL,
                            r3,
                            0,
                            mem | r2,
                            (char*)&view.search_head - (char*)&view,
                            i
                        );
                    }
                    ie.mov(r3, 0, mem | jit::reg_s(1), function_cold_offset(0));
                    ie.mov(
                        r3,
                        0,
                        mem | r3,
                        (char*)&heap_view.shape_recycle_epoch - (char*)&heap_view,
                        jit::SLJIT_MOV_U32
                    );
                    ie.mov(r1, 0, mem | r2, (char*)&view.recycle_epoch - (char*)&view, jit::SLJIT_MOV_U32);
                    inner.out.guard(jit::SLJIT_NOT_EQUAL, r3, 0, r1, 0, i);
                    ie.mov(r3, 0, mem | r2, (char*)&view.prop_flags - (char*)&view, jit::SLJIT_MOV_U8);
                    ie.op(jit::SLJIT_AND, r3, r3, 0, imm, 8);
                    inner.out.guard(jit::SLJIT_NOT_EQUAL, r3, 0, imm, 0, i);
                    ie.mov(r2, 0, mem | r2, (char*)&view.slot_ptr - (char*)&view);
                    inner.out.guard(jit::SLJIT_EQUAL, r2, 0, imm, 0, i);
                    ie.mov(r0, 0, mem | r2, 0);
                    inner.store(ins.a, i);
                    continue;
                }
            case ADD:
            case ADD_FUSED:
            case ADDI:
            case SUB:
            case SUBI:
            case MUL:
            case MULI:
            case DIV:
                if (function_float_op(ins.op)) { inner.flow_numeric(ins, i); }
                else { inner.out.numeric(ins, i); }
                continue;
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
            case BNOT:
            case UNM:
            case UNP:
                inner.bitwise(ins, i);
                continue;
            case TONUMERIC:
                inner.out.integer(ins.b, r0, i);
                inner.out.box(r0);
                inner.store(ins.a, i);
                continue;
            case INC:
            case INC_LT:
            case DEC:
                inner.out.integer(ins.a, r0, i);
                ie.op(ins.op == Opcode.DEC ? jit::SLJIT_SUB : jit::SLJIT_ADD, r0, r0, 0, imm, 1);
                inner.out.range(r0, i);
                inner.out.box(r0);
                inner.store(ins.a, i);
                continue;
            case LNOT:

                {
                    inner.truth(ins.b, i);
                    void* truthy = ie.cmp(jit::SLJIT_NOT_EQUAL, r0, 0, imm, 0);
                    ie.mov(r0, 0, imm, (long)((types::TAG_BOOLEAN << 48) | 1));
                    void* done = jit::sljit_emit_jump(ie.compiler, jit::SLJIT_JUMP);
                    ie.bind(truthy);
                    ie.mov(r0, 0, imm, (long)(types::TAG_BOOLEAN << 48));
                    ie.bind(done);
                    inner.store(ins.a, i);
                    continue;
                }
            case LT:
            case LE:
            case GT:
            case GE:

                {
                    Instruction compare = ins;
                    compare.op = loop_compare(ins.op);
                    void*[2] skips = inner.out.condition(compare, i);
                    ie.mov(r0, 0, imm, (long)((types::TAG_BOOLEAN << 48) | 1));
                    void* done   = jit::sljit_emit_jump(ie.compiler, jit::SLJIT_JUMP);
                    void* failed = ie.label();
                    foreach (jump : skips) if (jump != null) inner.out.bind_to(jump, failed);
                    ie.mov(r0, 0, imm, (long)(types::TAG_BOOLEAN << 48));
                    ie.bind(done);
                    inner.store(ins.a, i);
                    continue;
                }
            case SEQ:
            case SNEQ:
                inner.equal(ins, false, ins.op == Opcode.SNEQ, i);
                ie.op(jit::SLJIT_OR, r0, r0, 0, imm, (long)(types::TAG_BOOLEAN << 48));
                inner.store(ins.a, i);
                continue;
            case EQ:
            case NEQ:
                inner.loose_equal(ins, ins.op == Opcode.NEQ, i);
                inner.store(ins.a, i);
                continue;
            case RET:
                inner.flow_materialize();
                inner.out.load(ins.a, r0);
                // A nested body's result belongs to its caller's window.
                // Restore that base before storing, not just at the join.
                if (self.depth > 0) ie.op(jit::SLJIT_ADD, window, jit::reg_s(2), 0,
                    imm, function_inline_window(self.depth));
                e.mov(mem | out.state_base(), loop_value_offset(call.a), r0, 0);
                pending[pending_count] = jit::sljit_emit_jump(ie.compiler, jit::SLJIT_JUMP);
                pending_target[pending_count++] = target.code_count;
                continue;
            case RETUNDEF:
                inner.flow_materialize();
                ie.mov(r0, 0, imm, (long)loop_bits(undef));
                if (self.depth > 0) ie.op(jit::SLJIT_ADD, window, jit::reg_s(2), 0,
                    imm, function_inline_window(self.depth));
                e.mov(mem | out.state_base(), loop_value_offset(call.a), r0, 0);
                pending[pending_count] = jit::sljit_emit_jump(ie.compiler, jit::SLJIT_JUMP);
                pending_target[pending_count++] = target.code_count;
                continue;
            case CALL:
            case CALL_VAR:
            case CALL_GLOBAL:
            case CALL_UNDEF_THIS:
                // The predicate already resolved this site and checked the
                // nesting bound. A failure here means the two analyses
                // disagree; fail the plan instead of emitting a partial body.
                if (!inner.inline_general(target, i, h)) out.e.failed = true;
                continue;
            default: continue;
        }
        inner.store(ins.a, i);
    }
    // Backward edges name labels emitted before the branch was encountered.
    for (uint j = 0; j < pending_count; j++) {
        if (pending[j] != null) jit::sljit_set_label(pending[j], labels[pending_target[j]]);
    }
    // A nested expansion used reg_s(5) for its own window; point it back at
    // this level's window before the caller's body continues.
    if (self.depth > 0) e.op(jit::SLJIT_ADD, window, jit::reg_s(2), 0, imm, function_inline_window(self.depth));
    if (inner.out.e.failed) out.e.failed = true;
    $if $feat(SLJIT_STATS):
    {
        TemplateEmitter* se = &self.out.e;
        int sr3             = jit::reg_r(3);
        int sr1             = jit::reg_r(1);
        se.mov(sr3, 0, jit::SLJIT_IMM, (long)&self.plan.general_inlines);
        se.mov(sr1, 0, jit::SLJIT_MEM | sr3, 0);
        se.op(jit::SLJIT_ADD, sr1, sr1, 0, jit::SLJIT_IMM, 1);
        se.mov(jit::SLJIT_MEM | sr3, 0, sr1, 0);
    }
    $endif
    for (uint i = 0; i < inner.out.link_count; i++) {
        if (out.link_count == out.links.len) {
            out.e.failed = true;
            break;
        }
        LoopLink link = inner.out.links[i];
        link.exit = true;
        out.links[out.link_count++] = link;
    }
    return true;
}

// Poll only on taken backward edges. Recovery publishes the virtual loop's
// induction variables before the interpreter owns the GC/interrupt poll.
fn void* FunctionEmitter.inline_jump(&self, uint pc, uint target) @feat(SLJIT) {
    TemplateEmitter* e = &self.out.e;
    if (target <= pc) {
        int r0 = jit::reg_r(0);
        int run = jit::reg_s(2);
        e.mov(r0, 0, jit::SLJIT_MEM | run, $reflect(FunctionRun.budget).offset);
        self.out.guard(jit::SLJIT_LESS_EQUAL, r0, 0, jit::SLJIT_IMM, 1, pc);
        e.op(jit::SLJIT_SUB, r0, r0, 0, jit::SLJIT_IMM, 1);
        e.mov(jit::SLJIT_MEM | run, $reflect(FunctionRun.budget).offset, r0, 0);
    }
    return jit::sljit_emit_jump(e.compiler, jit::SLJIT_JUMP);
}
