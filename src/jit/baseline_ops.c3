// Baseline tier: operations whose threaded handler completes the common case
// but that the integer and number paths leave out. TYPEOF is answered inline;
// INSTANCEOF and the concatenating ADD call the helpers of vm_jit_ops.c3
// directly instead of relaying through the thunk.
module boomkat::jit @feat(SLJIT);

import boomkat::vm;
import boomkat::bytecode;
import boomkat::heap;
import boomkat::types;
import boomkat::hobject;

// Heap offset of the builtin string `s`.
fn long builtin_str_off(BuiltinStr s) {
    Heap* hl = (Heap*)(usz)4096;
    return (char*)&hl.strs[s] - (char*)hl;
}

// Load builtin string `s` into R0 and continue at `done`.
fn void Asm.typeof_pick(&self, BuiltinStr s, Jumps* done) {
    sljit_emit_op1(self.c, SLJIT_MOV, R0, 0, SLJIT_MEM | self.heap, builtin_str_off(s));
    done.add(sljit_emit_jump(self.c, SLJIT_JUMP));
}

// Continue at the label bound next unless R1 (the tag) is `tag`, else pick `s`.
fn void Asm.typeof_tag(&self, ulong tag, BuiltinStr s, Jumps* done) {
    void* c = self.c;
    void* other = sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R1, 0, SLJIT_IMM, (long)tag);
    self.typeof_pick(s, done);
    sljit_set_label(other, sljit_emit_label(c));
}

// TYPEOF as th_typeof: the interned name from the operand's tag, stored as a
// string constant is. A function is an object with the callable flag; the
// [[IsHTMLDDA]] object and the tags typeof_string does not name by tag take
// the thunk.
fn bool Asm.emit_typeof(&self) {
    self.load(R0, self.w.b);
    self.typeof_value(self.w.a);
    return true;
}

// The interned name for the value in R0, stored to window slot `dst`: the body
// of emit_typeof past the operand's load, which the optimizing tier also uses.
fn void Asm.typeof_value(&self, uint dst) {
    void* c = self.c;
    Layout* l = self.lay;
    Jumps done;
    sljit_emit_op2(c, SLJIT_LSHR, R1, 0, R0, 0, SLJIT_IMM, 48);
    void* tagged = sljit_emit_cmp(c, SLJIT_GREATER_EQUAL, R0, 0, k_int_op(), k_int_w());
    self.typeof_pick(BuiltinStr.NUMBER, &done);
    sljit_set_label(tagged, sljit_emit_label(c));
    self.typeof_tag(types::TAG_FASTINT, BuiltinStr.NUMBER, &done);
    self.typeof_tag(types::TAG_UNDEFINED, BuiltinStr.UNDEFINED, &done);
    self.typeof_tag(types::TAG_NULL_VAL, BuiltinStr.OBJECT, &done);
    self.typeof_tag(types::TAG_BOOLEAN, BuiltinStr.BOOLEAN, &done);
    self.typeof_tag(types::TAG_BIGINT, BuiltinStr.BIGINT, &done);
    void* not_string = sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R1, 0, SLJIT_IMM, (long)types::TAG_STRING);
    sljit_emit_op2(c, SLJIT_AND, R2, 0, R0, 0, SLJIT_IMM, PAYLOAD_SPAN - 1);
    sljit_emit_op1(c, SLJIT_MOV_U32, R3, 0, SLJIT_MEM | R2, 0);
    sljit_emit_op2(c, SLJIT_AND, R3, 0, R3, 0, SLJIT_IMM, l.symbol_mask);
    void* plain = sljit_emit_cmp(c, SLJIT_EQUAL, R3, 0, SLJIT_IMM, 0);
    self.typeof_pick(BuiltinStr.SYMBOL, &done);
    sljit_set_label(plain, sljit_emit_label(c));
    self.typeof_pick(BuiltinStr.STRING, &done);
    sljit_set_label(not_string, sljit_emit_label(c));
    self.call.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R1, 0, SLJIT_IMM, (long)types::TAG_OBJECT));
    sljit_emit_op2(c, SLJIT_AND, R2, 0, R0, 0, SLJIT_IMM, PAYLOAD_SPAN - 1);
    sljit_emit_op1(c, SLJIT_MOV, R1, 0, SLJIT_MEM | self.heap, self.htmldda_off);
    self.call.add(sljit_emit_cmp(c, SLJIT_EQUAL, R1, 0, R2, 0));
    sljit_emit_op1(c, SLJIT_MOV_U32, R3, 0, SLJIT_MEM | R2, 0);
    hobject::ObjFlags callable = { .callable = true };
    sljit_emit_op2(c, SLJIT_AND, R3, 0, R3, 0, SLJIT_IMM, (long)(uint)callable);
    void* plain_object = sljit_emit_cmp(c, SLJIT_EQUAL, R3, 0, SLJIT_IMM, 0);
    self.typeof_pick(BuiltinStr.FUNCTION, &done);
    sljit_set_label(plain_object, sljit_emit_label(c));
    sljit_emit_op1(c, SLJIT_MOV, R0, 0, SLJIT_MEM | self.heap, builtin_str_off(BuiltinStr.OBJECT));
    done.bind(sljit_emit_label(c));
    sljit_emit_op2(c, SLJIT_OR, R0, 0, R0, 0, SLJIT_IMM, K_STRING_START);
    self.store(dst, R0);
    self.track_heap_store(dst);
}

// The interned name `s` stored to window slot `dst`, for a `typeof` whose
// operand the graph already knows is a number.
fn void Asm.typeof_const(&self, BuiltinStr s, uint dst) {
    void* c = self.c;
    sljit_emit_op1(c, SLJIT_MOV, R0, 0, SLJIT_MEM | self.heap, builtin_str_off(s));
    sljit_emit_op2(c, SLJIT_OR, R0, 0, R0, 0, SLJIT_IMM, K_STRING_START);
    self.store(dst, R0);
    self.track_heap_store(dst);
}

// INSTANCEOF as th_instanceof answers it, from the site's cache (vm::jit_instanceof fills it):
// the right operand is a callable, unbound, non-proxy object on the filled shape (so with no
// own or shadowing @@hasInstance and an own `prototype` data slot at the cached index) whose
// [[Prototype]] is this realm's Function.prototype, whose @@hasInstance is the intrinsic. A
// non-object left operand answers false (a lightfunc is an object that takes the helper); an
// object's chain is walked inline, a proxy on it taking the helper. Every other case calls
// vm::jit_instanceof, then the thunk when it declines.
fn bool Asm.emit_instanceof(&self) {
    void* c = self.c;
    Jumps miss;
    Jumps done;
    if (!self.wide && self.f.ic_entries != null) self.instanceof_inline(&miss, &done);
    miss.bind(sljit_emit_label(c));
    sljit_emit_op1(c, SLJIT_MOV, R1, 0, SLJIT_IMM, (long)(usz)self.f.code + (long)self.next * Instruction::size);
    sljit_emit_op1(c, SLJIT_MOV, R0, 0, self.ds, 0);
    self.c_call(SLJIT_ARGS2WWW, SLJIT_IMM, (long)(usz)&vm::jit_instanceof);
    sljit_emit_op1(c, SLJIT_MOV_U8, R0, 0, R0, 0);
    self.call.add(sljit_emit_cmp(c, SLJIT_EQUAL, R0, 0, SLJIT_IMM, 0));
    done.bind(sljit_emit_label(c));
    return true;
}

// The inline path of INSTANCEOF (see emit_instanceof), for an instruction with a cache entry: the
// boolean into A and a jump to `done`, or a jump to `miss` for every case it does not answer.
// `loaded`: the constructor is in R0 and the object in R4 already, rather than in B and C.
fn void Asm.instanceof_inline(&self, Jumps* miss, Jumps* done, bool loaded = false) {
    void* c = self.c;
    Layout* l = self.lay;
    long ic = (long)(usz)&((hobject::ICEntry*)self.f.ic_entries)[self.next - 1];
    hobject::ObjFlags callable = { .callable = true };
    hobject::ObjFlags bound = { .is_bound = true };
    long mask = (long)(uint)callable | (long)(uint)bound | l.proxy_mask;
    if (!loaded) self.load(R0, self.w.c);
    sljit_emit_op2(c, SLJIT_XOR, R1, 0, R0, 0, k_obj_op(), k_obj_w());
    miss.add(sljit_emit_cmp(c, SLJIT_GREATER_EQUAL, R1, 0, span_op(), span_w()));
    sljit_emit_op1(c, SLJIT_MOV_U32, R2, 0, SLJIT_MEM | R1, 0);
    sljit_emit_op2(c, SLJIT_AND, R2, 0, R2, 0, SLJIT_IMM, mask);
    miss.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R2, 0, SLJIT_IMM, (long)(uint)callable));
    sljit_emit_op1(c, SLJIT_MOV, R2, 0, SLJIT_IMM, ic);
    sljit_emit_op1(c, SLJIT_MOV_U32, R3, 0, SLJIT_MEM | R1, l.obj_shape);
    miss.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL | SLJIT_32, R3, 0, SLJIT_MEM | R2, l.ic_shape));
    // live_shape_generation: heap.shapes[shape_id].generation.
    sljit_emit_op1(c, SLJIT_MOV, R0, 0, SLJIT_MEM | self.heap, l.heap_shapes);
    sljit_emit_op1(c, SLJIT_MOV, R0, 0, mem_index(R0, R3), 3);
    sljit_emit_op1(c, SLJIT_MOV_U32, R0, 0, SLJIT_MEM | R0, l.shape_gen);
    sljit_emit_op1(c, SLJIT_MOV_U32, R3, 0, SLJIT_MEM | R2, l.ic_gen);
    miss.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R3, 0, R0, 0));
    sljit_emit_op1(c, SLJIT_MOV, R0, 0, SLJIT_MEM | R1, l.obj_proto);
    sljit_emit_op1(c, SLJIT_MOV, R3, 0, SLJIT_MEM | self.heap, l.heap_function_proto);
    miss.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R0, 0, R3, 0));
    // The `prototype` slot, which an assignment changes without a new shape: an object.
    sljit_emit_op1(c, SLJIT_MOV_U32, R3, 0, SLJIT_MEM | R2, l.ic_idx);
    self.prop_base(R0, R1);
    sljit_emit_op1(c, SLJIT_MOV, R0, 0, mem_index(R0, R3), 3);
    sljit_emit_op2(c, SLJIT_XOR, R3, 0, R0, 0, k_obj_op(), k_obj_w());
    miss.add(sljit_emit_cmp(c, SLJIT_GREATER_EQUAL, R3, 0, span_op(), span_w()));
    if (loaded) {
        sljit_emit_op1(c, SLJIT_MOV, R1, 0, R4, 0);
    } else {
        self.load(R1, self.w.b);
    }
    sljit_emit_op2(c, SLJIT_XOR, R2, 0, R1, 0, k_obj_op(), k_obj_w());
    void* object = sljit_emit_cmp(c, SLJIT_LESS, R2, 0, span_op(), span_w());
    sljit_emit_op2(c, SLJIT_XOR, R2, 0, R1, 0, SLJIT_IMM, K_LIGHTFUNC);
    miss.add(sljit_emit_cmp(c, SLJIT_LESS, R2, 0, span_op(), span_w()));
    Jumps no;
    no.add(sljit_emit_jump(c, SLJIT_JUMP));
    // The walk starts at the left operand's [[GetPrototypeOf]]: it is tested for a proxy,
    // never compared with the prototype.
    sljit_set_label(object, sljit_emit_label(c));
    sljit_emit_op1(c, SLJIT_MOV, R1, 0, R2, 0);
    // MAX_PROTO_DEPTH hops, as th_instanceof counts them: a longer chain takes the helper.
    sljit_emit_op1(c, SLJIT_MOV, R4, 0, SLJIT_IMM, (long)hobject::MAX_PROTO_DEPTH);
    void* loop = sljit_emit_label(c);
    sljit_emit_op1(c, SLJIT_MOV_U32, R2, 0, SLJIT_MEM | R1, 0);
    sljit_emit_op2(c, SLJIT_AND, R2, 0, R2, 0, SLJIT_IMM, l.proxy_mask);
    miss.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R2, 0, SLJIT_IMM, 0));
    sljit_emit_op1(c, SLJIT_MOV, R1, 0, SLJIT_MEM | R1, l.obj_proto);
    no.add(sljit_emit_cmp(c, SLJIT_EQUAL, R1, 0, SLJIT_IMM, 0));
    void* found = sljit_emit_cmp(c, SLJIT_EQUAL, R1, 0, R3, 0);
    sljit_emit_op2(c, SLJIT_SUB, R4, 0, R4, 0, SLJIT_IMM, 1);
    sljit_set_label(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R4, 0, SLJIT_IMM, 0), loop);
    miss.add(sljit_emit_jump(c, SLJIT_JUMP));
    sljit_set_label(found, sljit_emit_label(c));
    self.store(self.w.a, SLJIT_IMM, K_BOOL | 1);
    done.add(sljit_emit_jump(c, SLJIT_JUMP));
    no.bind(sljit_emit_label(c));
    self.store(self.w.a, SLJIT_IMM, K_BOOL);
    done.add(sljit_emit_jump(c, SLJIT_JUMP));
}

// The start of an instruction's out-of-line path: the helper of vm_jit_ops.c3
// that completes what its inline path left, continuing at the next
// instruction, else the thunk that follows. The concatenating ADD, MOD's
// numbers, an element read or store and `arguments.length` have one.
fn void Asm.emit_op_helper(&self) {
    if (self.wide) return;
    void* helper;
    switch (self.w.op) {
        case ADD: helper = &vm::jit_add_concat;
        case MOD: helper = &vm::jit_mod;
        case GETPROP:
        case GETPROP_CACHE: helper = &vm::jit_get_elem;
        case PUTPROP: helper = &vm::jit_put_elem;
        case GETPROPC:
        case GETPROPC_CACHED:
            if (self.f.constants[self.w.c].get_heapptr() != self.length_key) return;
            helper = &vm::jit_get_length;
        default: return;
    }
    void* c = self.c;
    sljit_emit_op1(c, SLJIT_MOV, R1, 0, SLJIT_IMM, (long)(usz)self.f.code + (long)self.next * Instruction::size);
    sljit_emit_op1(c, SLJIT_MOV, R0, 0, self.ds, 0);
    self.c_call(SLJIT_ARGS2WWW, SLJIT_IMM, (long)(usz)helper);
    sljit_emit_op1(c, SLJIT_MOV_U8, R0, 0, R0, 0);
    self.go(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R0, 0, SLJIT_IMM, 0), self.next);
}

// MOD of two fastints with a non-negative dividend and a positive divisor,
// as th_mod: the remainder is a fastint and never -0 or NaN. Anything else is
// the operand-class cases of jit_mod.
fn void Asm.emit_mod(&self) {
    void* c = self.c;
    self.load(R0, self.w.b);
    self.guard_int(R0);
    self.load(R1, self.w.c);
    self.guard_int(R1);
    // The payloads, sign-extended.
    sljit_emit_op2(c, SLJIT_SHL, R0, 0, R0, 0, SLJIT_IMM, 16);
    sljit_emit_op2(c, SLJIT_ASHR, R0, 0, R0, 0, SLJIT_IMM, 16);
    sljit_emit_op2(c, SLJIT_SHL, R1, 0, R1, 0, SLJIT_IMM, 16);
    sljit_emit_op2(c, SLJIT_ASHR, R1, 0, R1, 0, SLJIT_IMM, 16);
    self.call.add(sljit_emit_cmp(c, SLJIT_SIG_LESS, R0, 0, SLJIT_IMM, 0));
    self.call.add(sljit_emit_cmp(c, SLJIT_SIG_LESS_EQUAL, R1, 0, SLJIT_IMM, 0));
    sljit_emit_op0(c, SLJIT_DIVMOD_UW);
    sljit_emit_op2(c, SLJIT_OR, R1, 0, R1, 0, k_int_op(), k_int_w());
    self.store(self.w.a, R1);
}
