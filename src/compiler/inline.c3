module boomkat::compiler;

import boomkat::bytecode;
import boomkat::types;
import boomkat::heap;
import boomkat::hstring;
import std::collections::list;

const uint INLINE_MAX_BODY = 32;
const uint INLINE_BUDGET = 256;

fn bool inline_numeric(Opcode op) {
    switch (op) {
        case Opcode.ADD..Opcode.EXP:
        case Opcode.ADDI..Opcode.USHRI:
        case Opcode.UNP: case Opcode.UNM: case Opcode.BNOT:
        case Opcode.BAND: case Opcode.BOR: case Opcode.BXOR:
        case Opcode.SHL: case Opcode.SHR: case Opcode.USHR:
        case Opcode.EQ: case Opcode.NEQ:
        case Opcode.LT: case Opcode.LE: case Opcode.GT: case Opcode.GE:
            return true;
        default: return false;
    }
}

fn bool inline_unary(Opcode op) {
    return op == Opcode.UNP || op == Opcode.UNM || op == Opcode.BNOT || op == Opcode.LNOT;
}

fn bool inline_candidate(CompiledFunction* f) {
    if (f.code_count == 0 || f.code_count > INLINE_MAX_BODY
        || f.num_regs > 32 || f.inner_count != 0
        || f.flags.is_generator || f.flags.is_async
        || f.flags.is_class_ctor || f.flags.has_rest || f.flags.uses_arguments
        || f.flags.has_direct_eval || f.flags.needs_env || f.flags.needs_lex_bridge) return false;
    bool returns = false;
    for (uint i = 0; i < f.code_count; i++) {
        Opcode op = f.code[i].op;
        if (inline_numeric(op) || bytecode::is_cmp_branch(op) || op == Opcode.ADD_FUSED) continue;
        switch (op) {
            case Opcode.NOP: case Opcode.LDREG: case Opcode.LDCONST: case Opcode.LDINT:
            case Opcode.LDUNDEF: case Opcode.LDNULL: case Opcode.LDTRUE: case Opcode.LDFALSE:
            case Opcode.GETVAR: case Opcode.GETGLOBAL: case Opcode.GETCAP:
            case Opcode.LDTHIS: case Opcode.GETTHISC: case Opcode.GETPROPC: case Opcode.GETPROP: case Opcode.GETPROP_CACHE:
            case Opcode.LNOT: case Opcode.SEQ: case Opcode.SNEQ:
            case Opcode.JUMP: case Opcode.IF_TRUE: case Opcode.IF_FALSE:
                break;
            case Opcode.RET: case Opcode.RETUNDEF:
                returns = true;
            default: return false;
        }
    }
    // A falling-through candidate could run into the fallback after partial evaluation.
    return returns && (f.code[f.code_count - 1].op == Opcode.RET
        || f.code[f.code_count - 1].op == Opcode.RETUNDEF);
}

struct InlineBuilder {
    List{Instruction} code;
    List{SourceEntry} source;
    List{TVal} constants;
    List{CompiledFunction*} inners;
    SourcePosition position;
}

fn uint InlineBuilder.emit(&self, Instruction ins) {
    uint pc = (uint)self.code.len();
    self.code.push(ins);
    self.source.push({ pc, self.position });
    return pc;
}
fn void InlineBuilder.jump_to(&self, uint pc, uint target) {
    self.code[pc] = bytecode::make_sabc(Opcode.JUMP, (int)target - (int)pc - 1);
}

// The name only selects a hypothesis; the identity guard proves it at runtime.
fn char[] inline_call_name(CompiledFunction* f, uint pc, Instruction call) {
    if (call.op == Opcode.CALL_VAR || call.op == Opcode.CALL_GLOBAL
        || call.op == Opcode.TAILCALL_VAR || call.op == Opcode.TAILCALL_GLOBAL) {
        TVal key = f.constants[call.c];
        if (key.is_string()) return ((HString*)key.get_heapptr()).get_data();
        return {};
    }
    uint reg = call.b;
    for (uint n = pc; n > 0 && pc - n < 64; ) {
        Instruction ins = f.code[--n];
        if (ins.op == Opcode.LDREG && ins.a == reg) { reg = ins.b; continue; }
        uint key;
        if ((ins.op == Opcode.GETPROPC || ins.op == Opcode.GETTHISC) && ins.a == reg) { key = ins.c; }
        else if ((ins.op == Opcode.GETVAR || ins.op == Opcode.GETGLOBAL) && ins.a == reg) { key = ins.get_bc(); }
        else if (ins.op == Opcode.CLOSURE && ins.a == reg) {
            CompiledFunction* inner = f.inner_funcs[ins.get_bc()];
            return inner.name_ptr[:inner.name_len];
        } else { continue; }
        if (key < f.const_count && f.constants[key].is_string()) {
            return ((HString*)f.constants[key].get_heapptr()).get_data();
        }
    }
    return {};
}

struct InlineCandidate {
    CompiledFunction* function;
    char[] name;
}

fn void inline_add_candidate(List{InlineCandidate}* candidates, CompiledFunction* f, char[] name) {
    if (name.len == 0 || !inline_candidate(f)) return;
    foreach (c : *candidates) if (c.function == f && c.name == name) return;
    candidates.push({ f, name });
}

fn CompiledFunction* inline_find(char[] name, List{InlineCandidate}* candidates) {
    if (name.len == 0) return null;
    CompiledFunction* found = null;
    foreach (c : *candidates) {
        if (c.name != name) continue;
        if (found != null && found != c.function) return null;
        found = c.function;
    }
    return found;
}

fn bool inline_is_call(Opcode op) {
    return op == Opcode.CALL || op == Opcode.CALL_UNDEF_THIS
        || op == Opcode.CALL_VAR || op == Opcode.CALL_GLOBAL
        || op == Opcode.TAILCALL_CALL || op == Opcode.TAILCALL_UNDEF_THIS
        || op == Opcode.TAILCALL_VAR || op == Opcode.TAILCALL_GLOBAL;
}

fn uint inline_initial_values(CompiledFunction* f) {
    uint defined = f.num_args >= 32 ? uint::max : (1u << f.num_args) - 1;
    uint needed = 0;
    for (uint i = 0; i < f.code_count; i++) {
        Instruction ins = f.code[i];
        if (ins.op == Opcode.JUMP || ins.op == Opcode.IF_TRUE || ins.op == Opcode.IF_FALSE
            || bytecode::is_cmp_branch(ins.op)) return uint::max;
        uint bits = 0;
        RegSet uses = { &bits, 1 };
        moveelim_add_uses(ins, &uses, false);
        needed |= bits & ~defined;
        uint reg;
        if (moveelim_get_def(ins, &reg) && reg < 32) defined |= 1u << reg;
    }
    return needed;
}

fn uint InlineBuilder.expand(&self, CompiledFunction* target, Instruction call, uint scratch) {
    bool named = call.op == Opcode.CALL_VAR || call.op == Opcode.CALL_GLOBAL
        || call.op == Opcode.TAILCALL_VAR || call.op == Opcode.TAILCALL_GLOBAL;
    bool method = call.op == Opcode.CALL || call.op == Opcode.TAILCALL_CALL;
    bool tail = call.op == Opcode.TAILCALL_CALL || call.op == Opcode.TAILCALL_UNDEF_THIS
        || call.op == Opcode.TAILCALL_VAR || call.op == Opcode.TAILCALL_GLOBAL;
    uint base = named ? call.a : call.b;
    uint argc = named ? call.b : call.c;
    uint kbase = (uint)self.constants.len();
    uint target_idx = (uint)self.inners.len();
    self.inners.push(target);
    foreach (v : target.constants[:target.const_count]) self.constants.push(v);
    SourcePosition call_pos = self.position;
    if (named) {
        bool global = call.op == Opcode.CALL_GLOBAL || call.op == Opcode.TAILCALL_GLOBAL;
        self.emit(bytecode::make_a_bc(global ? Opcode.GETGLOBAL : Opcode.GETVAR, base, call.c));
    }
    self.emit(bytecode::make_abc(Opcode.INLINE_GUARD, base, method ? 1 : 0, target_idx));
    List{uint} misses;
    misses.init(mem);
    defer misses.free();
    misses.push(self.emit(bytecode::make_sabc(Opcode.JUMP, 0)));
    uint recv = scratch + target.num_regs;
    self.emit(bytecode::make_abc(Opcode.INLINE_THIS, recv, base, method ? 1 : 0));
    uint initial = inline_initial_values(target);
    for (uint r = 0; r < target.num_regs; r++) {
        if (r < target.num_args && r < argc) { self.emit(bytecode::make_abc(Opcode.LDREG, scratch + r, base + 2 + r, 0)); }
        else if (r < target.num_args || (initial & (1u << r)) != 0) { self.emit(bytecode::make_abc(Opcode.LDUNDEF, scratch + r, 0, 0)); }
    }
    uint[INLINE_MAX_BODY + 1] map;
    uint[INLINE_MAX_BODY] body;
    List{uint} exits;
    exits.init(mem);
    defer exits.free();
    for (uint i = 0; i < target.code_count; i++) {
        self.position = target.get_source_position(i);
        map[i] = (uint)self.code.len();
        Instruction ins = target.code[i];
        Opcode op = ins.op == Opcode.ADD_FUSED ? Opcode.ADD : ins.op;
        bool branch = bytecode::is_cmp_branch(op);
        Opcode branch_reg = branch ? bytecode::reg_form(op) : Opcode.NOP;
        Opcode branch_op = branch_reg == Opcode.NOP ? op : branch_reg;
        bool numeric_branch = branch && branch_op != Opcode.JMP_SEQ && branch_op != Opcode.JMP_SNEQ;
        uint a = scratch + ins.a;
        uint b = scratch + ins.b;
        uint c = scratch + ins.c;
        if (op == Opcode.GETTHISC) { op = Opcode.GETPROPC; b = recv; }
        if (op == Opcode.GETPROPC || op == Opcode.GETPROP || op == Opcode.GETPROP_CACHE) {
            self.emit(bytecode::make_abc(Opcode.INLINE_READ_GUARD, b,
                op == Opcode.GETPROPC ? kbase + ins.c : c, op == Opcode.GETPROPC ? 1 : 0));
            misses.push(self.emit(bytecode::make_sabc(Opcode.JUMP, 0)));
        }
        if (inline_numeric(op) || numeric_branch) {
            bool one = inline_unary(op) || (op >= Opcode.ADDI && op <= Opcode.USHRI)
                || (numeric_branch && branch_reg != Opcode.NOP);
            self.emit(bytecode::make_abc(Opcode.INLINE_NUM_GUARD, one ? b : c, b, one ? 1 : 0));
            misses.push(self.emit(bytecode::make_sabc(Opcode.JUMP, 0)));
        }
        body[i] = (uint)self.code.len();
        switch (op) {
            case Opcode.RET: case Opcode.RETUNDEF:
                self.emit(bytecode::make_abc(Opcode.INLINE_COMMIT, 0, 0, 0));
                self.emit(bytecode::make_abc(op == Opcode.RET ? Opcode.LDREG : Opcode.LDUNDEF, call.a, op == Opcode.RET ? a : 0, 0));
                exits.push(self.emit(bytecode::make_sabc(Opcode.JUMP, 0)));
            case Opcode.LDTHIS:
                self.emit(bytecode::make_abc(Opcode.LDREG, a, recv, 0));
            case Opcode.GETVAR: case Opcode.GETGLOBAL: case Opcode.GETCAP:
                self.emit(bytecode::make_abc(op == Opcode.GETCAP ? Opcode.INLINE_GETCAP : Opcode.INLINE_GETFREE,
                    a, base, op == Opcode.GETCAP ? ins.get_bc() : kbase + ins.get_bc()));
                misses.push(self.emit(bytecode::make_sabc(Opcode.JUMP, 0)));
            case Opcode.JMP_NLT..Opcode.JMP_SNEQI:
                ins.a = 1;
                ins.b = b;
                if (branch_reg == Opcode.NOP) ins.c = c;
                self.emit(ins);
                self.emit(bytecode::make_sabc(Opcode.JUMP, 1));
                body[i] = self.emit(bytecode::make_sabc(Opcode.JUMP, 0));
            case Opcode.LDCONST:
                self.emit(bytecode::make_a_bc(op, a, kbase + ins.get_bc()));
            case Opcode.JUMP:
                self.emit(ins);
            case Opcode.IF_TRUE: case Opcode.IF_FALSE: case Opcode.LDINT:
                self.emit(bytecode::make_a_sbx(op, a, ins.get_sbc()));
            case Opcode.NOP:
                self.emit(ins);
            case Opcode.LDUNDEF: case Opcode.LDNULL: case Opcode.LDTRUE: case Opcode.LDFALSE:
                self.emit(bytecode::make_abc(op, a, 0, 0));
            default:
                if (op == Opcode.GETPROPC) { c = kbase + ins.c; }
                else if ((op >= Opcode.ADDI && op <= Opcode.USHRI) || inline_unary(op) || op == Opcode.LDREG) c = ins.c;
                self.emit(bytecode::make_abc(op, a, b, c));
        }
    }
    map[target.code_count] = (uint)self.code.len();
    for (uint i = 0; i < target.code_count; i++) {
        Instruction ins = target.code[i];
        int dst = fusion_branch_target(target.code, i);
        if (dst < 0) continue;
        uint at = body[i];
        int off = (int)map[(uint)dst] - (int)at - 1;
        if (ins.op == Opcode.JUMP) { self.code[at] = bytecode::make_sabc(ins.op, off); }
        else if (bytecode::is_cmp_branch(ins.op)) { self.jump_to(at, map[(uint)dst]); }
        else { self.code[at] = bytecode::make_a_sbx(ins.op, scratch + ins.a, off); }
    }
    self.position = call_pos;
    uint fallback = (uint)self.code.len();
    foreach (pc : misses) self.jump_to(pc, fallback);
    Opcode fallback_op = method ? (tail ? Opcode.TAILCALL_CALL : Opcode.CALL)
        : (tail ? Opcode.TAILCALL_UNDEF_THIS : Opcode.CALL_UNDEF_THIS);
    self.emit(bytecode::make_abc(fallback_op, call.a, base, argc));
    foreach (pc : exits) self.jump_to(pc, (uint)self.code.len());
    return fallback;
}

fn void inline_expand_function(Heap* h, CompiledFunction* f, List{InlineCandidate}* candidates, bool wide_branches = false) {
    if (f.flags.is_generator || f.flags.is_async || f.code_count > 16000 || f.num_regs > 200) return;
    // Wide operands require a wider relocation pass.
    foreach (ins : f.code[:f.code_count]) if (ins.op == Opcode.WIDE) return;
    InlineBuilder out;
    out.code.init(mem); out.source.init(mem); out.constants.init(mem); out.inners.init(mem);
    defer { out.code.free(); out.source.free(); out.constants.free(); out.inners.free(); }
    foreach (v : f.constants[:f.const_count]) out.constants.push(v);
    foreach (inner : f.inner_funcs[:f.inner_count]) out.inners.push(inner);
    uint[] map = mem::new_array(uint, (sz)f.code_count + 1);
    uint[] copies = mem::new_array(uint, f.code_count);
    defer { mem::free(map); mem::free(copies); }
    uint sites = 0;
    uint regs = f.num_regs;
    for (uint i = 0; i < f.code_count; i++) {
        map[i] = (uint)out.code.len();
        out.position = f.get_source_position(i);
        Instruction ins = f.code[i];
        CompiledFunction* target = inline_is_call(ins.op) ? inline_find(inline_call_name(f, i, ins), candidates) : null;
        if (target != null && out.inners.len() < 256 && out.constants.len() + target.const_count <= 256
            && out.code.len() - i + (sz)target.code_count * 6 + target.num_regs + 8 < INLINE_BUDGET) {
            copies[i] = out.expand(target, ins, f.num_regs);
            uint need = f.num_regs + target.num_regs + 1;
            if (need > regs) regs = need;
            sites++;
        } else if (wide_branches && bytecode::is_cmp_branch(ins.op)) {
            ins.a = 1;
            out.emit(ins);
            out.emit(bytecode::make_sabc(Opcode.JUMP, 1));
            copies[i] = out.emit(bytecode::make_sabc(Opcode.JUMP, 0));
        } else {
            copies[i] = out.emit(ins);
        }
        if (ins.op == Opcode.TRY) {
            i++;
            map[i] = (uint)out.code.len();
            copies[i] = out.emit(f.code[i]);
        }
    }
    if (sites == 0) return;
    map[f.code_count] = (uint)out.code.len();
    for (uint i = 0; i < f.code_count; i++) {
        Instruction ins = f.code[i];
        uint pc = copies[i];
        int dst = fusion_branch_target(f.code, i);
        if (dst >= 0) {
            if ((uint)dst > f.code_count) return;
            int off = (int)map[(uint)dst] - (int)pc - 1;
            if (wide_branches && bytecode::is_cmp_branch(ins.op)) {
                out.code[pc] = bytecode::make_sabc(Opcode.JUMP, off);
                continue;
            }
            switch (ins.op) {
                case Opcode.JUMP: case Opcode.BREAK: case Opcode.CONTINUE:
                    out.code[pc] = bytecode::make_sabc(ins.op, off);
                case Opcode.IF_TRUE: case Opcode.IF_FALSE:
                    if (off < -32768 || off > 32767) return;
                    out.code[pc] = bytecode::make_a_sbx(ins.op, ins.a, off);
                default:
                    if (off < -128 || off > 127) {
                        inline_expand_function(h, f, candidates, true);
                        return;
                    }
                    out.code[pc].a = (uint)(char)off;
            }
        }
        if (ins.op == Opcode.TRY) {
            out.code[pc] = bytecode::make_a_bc(ins.op, ins.a, map[i + ins.get_bc()] - pc);
            uint fin = bytecode::try_finally_offset(f.code[i + 1]);
            out.code[(sz)pc + 1] = bytecode::make_finally_slot(fin == 0 ? 0 : map[i + fin] - pc);
            i++;
        }
    }
    uint count = (uint)out.code.len();
    if (count > f.code_count + INLINE_BUDGET) return;
    Instruction* code = (Instruction*)h.alloc_func(h.heap_udata, (usz)count * Instruction::size);
    SourceEntry* source = (SourceEntry*)h.alloc_func(h.heap_udata, (usz)count * SourceEntry::size);
    TVal* constants = (TVal*)h.alloc_func(h.heap_udata, (usz)out.constants.len() * TVal::size);
    CompiledFunction** inners = (CompiledFunction**)h.alloc_func(h.heap_udata, (usz)out.inners.len() * CompiledFunction*::size);
    if (code == null || source == null || constants == null || inners == null) {
        if (code != null) h.free_func(h.heap_udata, code);
        if (source != null) h.free_func(h.heap_udata, source);
        if (constants != null) h.free_func(h.heap_udata, constants);
        if (inners != null) h.free_func(h.heap_udata, inners);
        return;
    }
    mem::copy(code, out.code.entries, (sz)count * Instruction::size);
    mem::copy(source, out.source.entries, (sz)count * SourceEntry::size);
    mem::copy(constants, out.constants.entries, (sz)out.constants.len() * TVal::size);
    mem::copy(inners, out.inners.entries, (sz)out.inners.len() * CompiledFunction*::size);
    // Pair fusion preserves PCs, source positions and guard/fallback boundaries.
    bool[] targets = mem::new_array(bool, count);
    defer mem::free(targets);
    fuse_threaded_pairs(code, count, targets);
    for (uint i = 0; i < f.direct_eval_offset_count; i++) f.direct_eval_offsets[i] = copies[f.direct_eval_offsets[i]];
    h.free_func(h.heap_udata, f.code);
    if (f.source_map != null) h.free_func(h.heap_udata, f.source_map);
    if (f.constants != null) h.free_func(h.heap_udata, f.constants);
    if (f.inner_funcs != null) h.free_func(h.heap_udata, f.inner_funcs);
    if (bytecode::inline_profile) { bytecode::inline_sites += sites; bytecode::inline_before += f.code_count; bytecode::inline_after += count; }
    f.code = code; f.code_count = count;
    f.source_map = source; f.source_map_count = count;
    f.constants = constants; f.const_count = (uint)out.constants.len();
    f.inner_funcs = inners; f.inner_count = (uint)out.inners.len();
    f.num_regs = (ushort)regs;
    f.compact_source_map();
}

fn void inline_unit(Heap* h, CompiledFunction* root) {
    if (!bytecode::inline_enabled || g_disable_optimize) return;
    List{CompiledFunction*} functions;
    List{InlineCandidate} candidates;
    functions.init(mem); candidates.init(mem);
    defer { functions.free(); candidates.free(); }
    functions.push(root);
    for (sz i = 0; i < functions.len(); i++) {
        CompiledFunction* f = functions[i];
        inline_add_candidate(&candidates, f, f.name_ptr[:f.name_len]);
        foreach (inner : f.inner_funcs[:f.inner_count]) {
            bool seen = false;
            foreach (existing : functions) if (existing == inner) { seen = true; break; }
            if (!seen) functions.push(inner);
        }
    }
    // Member assignments do not infer Function.name. Recover their static key
    // without changing the function's JavaScript-visible name.
    foreach (f : functions) {
        for (uint i = 0; i + 1 < f.code_count; i++) {
            Instruction closure = f.code[i];
            if (closure.op != Opcode.CLOSURE) continue;
            CompiledFunction* target = f.inner_funcs[closure.get_bc()];
            if (!inline_candidate(target)) continue;
            Instruction store = f.code[i + 1];
            uint key = 0xFFFFFFFF;
            if (store.op == Opcode.PUTPROPC && store.b == closure.a) {
                key = store.c;
            } else if (store.op == Opcode.PUTPROP && store.c == closure.a) {
                for (uint j = i; j > 0 && i - j < 8; ) {
                    Instruction load = f.code[--j];
                    if (load.op == Opcode.LDCONST && load.a == store.b) { key = load.get_bc(); break; }
                }
            }
            if (key < f.const_count && f.constants[key].is_string()) {
                inline_add_candidate(&candidates, target, ((HString*)f.constants[key].get_heapptr()).get_data());
            }
        }
    }
    if (candidates.len() == 0) return;
    foreach (f : functions) inline_expand_function(h, f, &candidates);
}
