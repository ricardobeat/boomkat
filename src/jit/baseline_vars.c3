// Baseline tier: inline paths for the variable instructions the threaded
// handlers answer from a variable cache entry, a scope's declaration cache or
// a cells object: the entry re-armed for a new activation's scope chain, the
// resolve/assign pair of a plain assignment, INC_VAR, global stores, cell
// access and `var` declarations.
//
// Each path replays its handler's guards (src/vm/vm_execute_threaded.c3) for
// the common hit and takes the instruction's thunk on anything else.
module boomkat::jit @feat(SLJIT);

import boomkat::vm;
import boomkat::bytecode;
import boomkat::heap;
import boomkat::types;
import boomkat::hobject;
import boomkat::env;

const long K_ENVREF = (long)(types::TAG_ENVREF << 48);

// Field offsets and masks of the structures only these paths read.
struct VarLayout {
    long vic_env;
    long vic_shape;
    long vic_store_ok;
    long act_var_env;
    long env_bindings;
    long env_flags;
    long env_function_mask;
    long env_with_mask;
    long obj_nondefault_mask;
    long flags_we;
}

VarLayout var_layout_data @private;
bool var_layout_ready @private;

fn VarLayout* var_layout() @private {
    if (var_layout_ready) return &var_layout_data;
    VarLayout* v = &var_layout_data;
    char* base = (char*)(usz)4096;
    hobject::VarICEntry* vic = (hobject::VarICEntry*)base;
    Activation* act = (Activation*)base;
    env::EnvRecord* e = (env::EnvRecord*)base;
    v.vic_env = (char*)&vic.env - base;
    v.vic_shape = (char*)&vic.shape_id - base;
    v.vic_store_ok = (char*)&vic.varref_store_ok - base;
    v.act_var_env = (char*)&act.var_env - base;
    v.env_bindings = (char*)&e.bindings - base;
    v.env_flags = (char*)&e.flags - base;
    env::EnvFlags ef;
    ef.is_function_scope = true;
    v.env_function_mask = (long)(char)ef;
    ef = {};
    ef.is_with = true;
    v.env_with_mask = (long)(char)ef;
    hobject::ObjFlags of;
    of.has_nondefault_flags = true;
    v.obj_nondefault_mask = (long)(uint)of;
    v.flags_we = (long)(char)hobject::PROP_FLAGS_WE;
    var_layout_ready = true;
    return v;
}

// Whether `op` has a path here (see emit_var_access).
fn bool is_var_op(Opcode op) {
    switch (op) {
        case INC_VAR:
        case RESOLVEVAR:
        case THROW_UNRESOLVED:
        case PUTGLOBAL:
        case GETCELL:
        case SETCELL:
        case MOVECELL:
        case DECLVAR:
        case DECLVAR_HOIST:
            return true;
        default:
            return false;
    }
}

// The inline path of one of those instructions; false leaves it to the thunk.
fn bool Asm.emit_var_access(&self, bool has_ic, long ic, long vic, bool consts_fixed) {
    DecodedInsn w = self.w;
    switch (w.op) {
        case INC_VAR:
            if (!has_ic) return false;
            self.emit_inc_var(w.a, vic);
        case RESOLVEVAR:
            if (!has_ic) return false;
            self.emit_resolve_var(w.a, vic);
        case THROW_UNRESOLVED:
            self.emit_throw_unresolved(w.a);
        case PUTGLOBAL:
            if (!has_ic) return false;
            self.emit_put_global(w.a, vic);
        case GETCELL:
            self.cell_slot(w.b, w.c);
            sljit_emit_op1(self.c, SLJIT_MOV, R0, 0, SLJIT_MEM | R0, 0);
            self.publish(w.a);
        case SETCELL:
        case MOVECELL:
            self.cell_slot(w.b, w.c);
            self.store_slot(w.a);
            if (w.op == MOVECELL) self.store(w.a, SLJIT_IMM, K_UNDEF);
        case DECLVAR:
        case DECLVAR_HOIST:
            if (!has_ic || !consts_fixed) return false;
            return self.emit_declvar(w.a, w.get_bc(), ic);
        default:
            return false;
    }
    return true;
}

// The helper behind a re-arm: var_ic_rearm for the running activation's scope
// chain, 1 when the entry now describes it.
fn long var_rearm(Dispatch* ds, hobject::VarICEntry* vic) {
    return vm::var_ic_rearm(vic, ds.act.lex_env, ds.vm.heap) ? 1 : 0;
}

// The out-of-line arm of GETVAR, PUTVAR_ASSIGN and INC_VAR for an entry filled
// under another scope chain, as th_var_rearm: re-arm it and run the
// instruction again, or fall through to the thunk when the cached binding no
// longer applies. False for any other instruction.
fn bool Asm.emit_var_alt(&self) {
    Opcode op = self.w.op;
    if (op != GETVAR && op != PUTVAR_ASSIGN && op != INC_VAR) return false;
    void* c = self.c;
    sljit_emit_op1(c, SLJIT_MOV, R0, 0, self.ds, 0);
    sljit_emit_op1(c, SLJIT_MOV, R1, 0, SLJIT_IMM, (long)(usz)&((hobject::VarICEntry*)self.f.var_ic_entries)[self.next - 1]);
    sljit_emit_icall(c, SLJIT_CALL, SLJIT_ARGS2WWW, SLJIT_IMM, (long)(usz)&var_rearm);
    void* failed = sljit_emit_cmp(c, SLJIT_EQUAL, R0, 0, SLJIT_IMM, 0);
    sljit_set_label(sljit_emit_jump(c, SLJIT_JUMP), self.poly_back);
    sljit_set_label(failed, sljit_emit_label(c));
    return true;
}

// R1 = the scope chain head a lean call of the closure in window register `reg` (or in register
// `closure`, when not negative) starts with, as th_publish_lean: its captured scope while that is
// declarative, else its variable scope. Uses R1, R3 and R4; the call's guard has checked the value
// is a function with a variable scope and no `with` capture.
fn void Asm.closure_lex_env(&self, uint reg, int closure) {
    void* c = self.c;
    CallLayout* k = call_layout();
    if (closure >= 0) {
        if (closure != R3) sljit_emit_op1(c, SLJIT_MOV, R3, 0, closure, 0);
    } else {
        self.load(R3, reg);
    }
    sljit_emit_op2(c, SLJIT_XOR, R3, 0, R3, 0, SLJIT_IMM, K_OBJ);
    sljit_emit_op1(c, SLJIT_MOV, R4, 0, SLJIT_MEM | R3, k.fn_var_env);
    sljit_emit_op1(c, SLJIT_MOV, R1, 0, SLJIT_MEM | R3, k.fn_lex_env);
    env::EnvFlags decl_flag;
    decl_flag.is_declarative = true;
    Jumps use_env;
    use_env.add(sljit_emit_cmp(c, SLJIT_EQUAL, R1, 0, SLJIT_IMM, 0));
    sljit_emit_op1(c, SLJIT_MOV_U8, R3, 0, SLJIT_MEM | R1, k.env_flags);
    sljit_emit_op2(c, SLJIT_AND, R3, 0, R3, 0, SLJIT_IMM, (long)(char)decl_flag);
    use_env.add(sljit_emit_cmp(c, SLJIT_EQUAL, R3, 0, SLJIT_IMM, 0));
    void* done = sljit_emit_jump(c, SLJIT_JUMP);
    use_env.bind(sljit_emit_label(c));
    sljit_emit_op1(c, SLJIT_MOV, R1, 0, R4, 0);
    sljit_set_label(done, sljit_emit_label(c));
}

// INC_VAR as th_inc_var: a writable binding holding a fastint that stays one.
fn void Asm.emit_inc_var(&self, uint ra, long vic) {
    void* c = self.c;
    Layout* l = self.lay;
    self.var_slot(vic, true);
    sljit_emit_op1(c, SLJIT_MOV_U8, R1, 0, SLJIT_MEM | R2, l.vic_flags);
    sljit_emit_op2(c, SLJIT_AND, R1, 0, R1, 0, SLJIT_IMM, l.accessor_mask | l.writable_mask);
    self.call.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R1, 0, SLJIT_IMM, l.writable_mask));
    sljit_emit_op1(c, SLJIT_MOV, R1, 0, SLJIT_MEM | R0, 0);
    self.guard_int(R1);
    sljit_emit_op2(c, SLJIT_SHL, R1, 0, R1, 0, SLJIT_IMM, 16);
    sljit_emit_op2(c, SLJIT_ADD | SLJIT_SET_OVERFLOW, R1, 0, R1, 0, SLJIT_IMM, 1L << 16);
    self.call.add(sljit_emit_jump(c, SLJIT_OVERFLOW));
    self.box_shifted(R1);
    sljit_emit_op1(c, SLJIT_MOV, SLJIT_MEM | R0, 0, R1, 0);
    self.store(ra, R1);
}

// RESOLVEVAR as th_resolvevar: the cached owner record, while the chain head,
// the owner's shape and the recycle epoch are those the entry was filled
// for, and the collector is not marking (an ENVREF is traced).
fn void Asm.emit_resolve_var(&self, uint ra, long vic) {
    void* c = self.c;
    Layout* l = self.lay;
    VarLayout* v = var_layout();
    sljit_emit_op1(c, SLJIT_MOV, R2, 0, SLJIT_IMM, vic);
    sljit_emit_op1(c, SLJIT_MOV, R0, 0, SLJIT_MEM | R2, v.vic_env);
    self.call.add(sljit_emit_cmp(c, SLJIT_EQUAL, R0, 0, SLJIT_IMM, 0));
    sljit_emit_op1(c, SLJIT_MOV, R1, 0, SLJIT_MEM | self.ds, l.ds_act);
    sljit_emit_op1(c, SLJIT_MOV, R1, 0, SLJIT_MEM | R1, l.act_lex_env);
    self.call.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R1, 0, SLJIT_MEM | R2, l.vic_head));
    sljit_emit_op1(c, SLJIT_MOV, R1, 0, SLJIT_MEM | R2, l.vic_bindings);
    sljit_emit_op1(c, SLJIT_MOV_U32, R1, 0, SLJIT_MEM | R1, l.obj_shape);
    sljit_emit_op1(c, SLJIT_MOV_U32, R3, 0, SLJIT_MEM | R2, v.vic_shape);
    self.call.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R1, 0, R3, 0));
    sljit_emit_op1(c, SLJIT_MOV_U32, R1, 0, SLJIT_MEM | R2, l.vic_epoch);
    sljit_emit_op1(c, SLJIT_MOV_U32, R3, 0, SLJIT_MEM | self.heap, l.heap_epoch);
    self.call.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R1, 0, R3, 0));
    self.guard_not_marking(R1);
    sljit_emit_op2(c, SLJIT_OR, R0, 0, R0, 0, SLJIT_IMM, K_ENVREF);
    self.store(ra, R0);
    self.track_heap_store(ra);
}

// THROW_UNRESOLVED as th_throw_unresolved: a resolved reference needs nothing.
fn void Asm.emit_throw_unresolved(&self, uint ra) {
    void* c = self.c;
    self.load(R0, ra);
    sljit_emit_op2(c, SLJIT_XOR, R0, 0, R0, 0, SLJIT_IMM, K_ENVREF);
    self.call.add(sljit_emit_cmp(c, SLJIT_GREATER_EQUAL, R0, 0, SLJIT_IMM, PAYLOAD_SPAN));
    self.call.add(sljit_emit_cmp(c, SLJIT_EQUAL, R0, 0, SLJIT_IMM, 0));
}

// PUTGLOBAL as th_putglobal: a writable non-configurable data global (the
// entry says so), the value moving out of register `rv`.
fn void Asm.emit_put_global(&self, uint rv, long vic) {
    void* c = self.c;
    Layout* l = self.lay;
    VarLayout* v = var_layout();
    sljit_emit_op1(c, SLJIT_MOV, R2, 0, SLJIT_IMM, vic);
    sljit_emit_op1(c, SLJIT_MOV_U32, R0, 0, SLJIT_MEM | R2, l.vic_layout);
    sljit_emit_op1(c, SLJIT_MOV_U32, R1, 0, SLJIT_MEM | self.heap, l.heap_layout);
    self.call.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R0, 0, R1, 0));
    sljit_emit_op1(c, SLJIT_MOV, R0, 0, SLJIT_MEM | R2, l.vic_slot);
    self.call.add(sljit_emit_cmp(c, SLJIT_EQUAL, R0, 0, SLJIT_IMM, 0));
    sljit_emit_op1(c, SLJIT_MOV_U8, R1, 0, SLJIT_MEM | R2, v.vic_store_ok);
    self.call.add(sljit_emit_cmp(c, SLJIT_EQUAL, R1, 0, SLJIT_IMM, 0));
    sljit_emit_op1(c, SLJIT_MOV, R1, 0, SLJIT_MEM | R2, l.vic_bindings);
    self.store_slot_moved(rv);
    self.store(rv, SLJIT_IMM, K_UNDEF);
}

// The helper behind a heavy slot store: Heap.tval_move_slot_fast, which the
// threaded handlers and the switch run for a move into a binding.
fn long move_slot(Heap* h, HObject* owner, hobject::PropValue* slot, TVal* src) {
    h.tval_move_slot_fast(owner, slot, src);
    return 0;
}

// Move register `rv` into the slot at R0 of the object in R1 (which the
// caller then clears): store_slot's cases inline, and the move helper for the
// others, a counted value or a barrier.
fn void Asm.store_slot_moved(&self, uint rv) {
    void* c = self.c;
    uint mark = self.call.len;
    self.store_slot(rv);
    Jumps heavy;
    for (uint k = mark; k < self.call.len; k++) heavy.add(self.call.at[k]);
    self.call.len = mark;
    void* done = sljit_emit_jump(c, SLJIT_JUMP);
    heavy.bind(sljit_emit_label(c));
    sljit_emit_op1(c, SLJIT_MOV, R2, 0, R0, 0);
    sljit_emit_op1(c, SLJIT_MOV, R0, 0, self.heap, 0);
    sljit_emit_op2(c, SLJIT_ADD, R3, 0, self.regs, 0, SLJIT_IMM, (long)rv * TVal::size);
    sljit_emit_icall(c, SLJIT_CALL, SLJIT_ARGS4WWWW, SLJIT_IMM, (long)(usz)&move_slot);
    sljit_set_label(done, sljit_emit_label(c));
}

// R0 = the address of slot `index` of the cells object register `rb` holds, as
// th_cell_slot; R1 the cells object. The slow path for anything but an object
// of class Object with that slot.
fn void Asm.cell_slot(&self, uint rb, uint index) {
    void* c = self.c;
    Layout* l = self.lay;
    self.load(R0, rb);
    self.unbox_object(R1, R0);
    sljit_emit_op1(c, SLJIT_MOV_U32, R2, 0, SLJIT_MEM | R1, 0);
    sljit_emit_op2(c, SLJIT_AND, R2, 0, R2, 0, SLJIT_IMM, l.class_mask);
    self.call.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R2, 0, SLJIT_IMM, l.class_object));
    sljit_emit_op1(c, SLJIT_MOV_U32, R2, 0, SLJIT_MEM | R1, l.obj_prop_count);
    self.call.add(sljit_emit_cmp(c, SLJIT_LESS_EQUAL, R2, 0, SLJIT_IMM, index));
    self.prop_base(R0, R1);
    sljit_emit_op2(c, SLJIT_ADD, R0, 0, R0, 0, SLJIT_IMM, (long)index * TVal::size);
}

// DECLVAR and DECLVAR_HOIST as th_declvar for an inert value or an object:
// the append the site's declaration entry (ic) names, into the activation's
// function scope when it is on the shape the entry was filled for. A heap value
// other than an object takes the thunk.
fn bool Asm.emit_declvar(&self, uint ra, uint index, long ic) {
    void* c = self.c;
    Layout* l = self.lay;
    VarLayout* v = var_layout();
    CompiledFunction* f = self.f;
    if (index >= f.const_count || !f.constants[index].is_string() || f.is_eval_fn()) return false;
    long key = (long)(usz)f.constants[index].get_heapptr();
    int m = SLJIT_MEM;
    // R1 = the scope's bindings.
    sljit_emit_op1(c, SLJIT_MOV, R0, 0, m | self.ds, l.ds_act);
    sljit_emit_op1(c, SLJIT_MOV, R1, 0, m | R0, v.act_var_env);
    self.call.add(sljit_emit_cmp(c, SLJIT_EQUAL, R1, 0, SLJIT_IMM, 0));
    sljit_emit_op1(c, SLJIT_MOV_U8, R0, 0, m | R1, v.env_flags);
    sljit_emit_op2(c, SLJIT_AND, R0, 0, R0, 0, SLJIT_IMM, v.env_function_mask | v.env_with_mask);
    self.call.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R0, 0, SLJIT_IMM, v.env_function_mask));
    sljit_emit_op1(c, SLJIT_MOV, R1, 0, m | R1, v.env_bindings);
    // The entry: an absent-key add of this name from the scope's shape.
    sljit_emit_op1(c, SLJIT_MOV, R2, 0, SLJIT_IMM, ic);
    sljit_emit_op1(c, SLJIT_MOV_U32, R0, 0, m | R2, l.ic_idx);
    self.call.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R0, 0, SLJIT_IMM, (long)hobject::IC_PROP_ABSENT));
    sljit_emit_op1(c, SLJIT_MOV_U8, R0, 0, m | R2, l.ic_flags);
    self.call.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R0, 0, SLJIT_IMM, v.flags_we));
    self.call.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, m | R2, l.ic_key, SLJIT_IMM, key));
    sljit_emit_op1(c, SLJIT_MOV_U32, R0, 0, m | R1, l.obj_shape);
    sljit_emit_op1(c, SLJIT_MOV_U32, R3, 0, m | R2, l.ic_shape);
    self.call.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R0, 0, R3, 0));
    sljit_emit_op1(c, SLJIT_MOV_U32, R0, 0, m | self.heap, l.heap_epoch);
    sljit_emit_op1(c, SLJIT_MOV_U32, R3, 0, m | R2, l.ic_gen);
    self.call.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R0, 0, R3, 0));
    self.call.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, m | R1, l.obj_prop_hash, SLJIT_IMM, 0));
    // Spare capacity and a scope never observed as a prototype.
    sljit_emit_op1(c, SLJIT_MOV_U32, R0, 0, m | R1, l.obj_prop_count);
    sljit_emit_op1(c, SLJIT_MOV_U32, R4, 0, m | R1, l.obj_prop_capacity);
    self.call.add(sljit_emit_cmp(c, SLJIT_GREATER_EQUAL, R0, 0, R4, 0));
    sljit_emit_op1(c, SLJIT_MOV_U32, R4, 0, m | R1, l.obj_gc);
    sljit_emit_op2(c, SLJIT_AND, R3, 0, R4, 0, SLJIT_IMM, l.proto_observed_mask);
    self.call.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R3, 0, SLJIT_IMM, 0));
    // The value: inert, or an object while not marking into a young scope.
    self.load(R3, ra);
    void* inert = sljit_emit_cmp(c, SLJIT_LESS, R3, 0, SLJIT_IMM, K_STRING_START);
    sljit_emit_op2(c, SLJIT_XOR, R4, 0, R3, 0, SLJIT_IMM, K_OBJ);
    self.call.add(sljit_emit_cmp(c, SLJIT_GREATER_EQUAL, R4, 0, SLJIT_IMM, PAYLOAD_SPAN));
    self.guard_not_marking(R4);
    sljit_emit_op1(c, SLJIT_MOV_U32, R4, 0, m | R1, l.obj_gc);
    sljit_emit_op2(c, SLJIT_AND, R4, 0, R4, 0, SLJIT_IMM, l.old_mask);
    self.call.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R4, 0, SLJIT_IMM, 0));
    sljit_set_label(inert, sljit_emit_label(c));
    // A var binding is not configurable, which reads of the shape take from
    // the object's flag.
    sljit_emit_op1(c, SLJIT_MOV_U32, R4, 0, m | R1, 0);
    sljit_emit_op2(c, SLJIT_OR, R4, 0, R4, 0, SLJIT_IMM, v.obj_nondefault_mask);
    sljit_emit_op1(c, SLJIT_MOV_U32, m | R1, 0, R4, 0);
    // Append: the slot at prop_count was never owned.
    self.prop_base(R4, R1);
    sljit_emit_op2(c, SLJIT_SHL, R0, 0, R0, 0, SLJIT_IMM, 3);
    sljit_emit_op2(c, SLJIT_ADD, R4, 0, R4, 0, R0, 0);
    sljit_emit_op1(c, SLJIT_MOV, m | R4, 0, R3, 0);
    sljit_emit_op1(c, SLJIT_MOV_U32, R0, 0, m | R1, l.obj_prop_count);
    sljit_emit_op2(c, SLJIT_ADD, R0, 0, R0, 0, SLJIT_IMM, 1);
    sljit_emit_op1(c, SLJIT_MOV_U32, m | R1, l.obj_prop_count, R0, 0);
    sljit_emit_op1(c, SLJIT_MOV_U32, R0, 0, m | R2, l.ic_absent_next);
    sljit_emit_op1(c, SLJIT_MOV_U32, m | R1, l.obj_shape, R0, 0);
    return true;
}
