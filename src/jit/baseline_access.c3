// Baseline tier: inline cache-hit paths for property, global, variable and
// capture access, and register moves of objects.
//
// Each path mirrors its threaded handler's guards (src/vm/vm_execute_threaded.c3)
// for one common entry shape and jumps to the instruction's thunk on anything
// else: a miss, another entry shape, a string or BigInt on either side of a
// store, a string value read into a register, and any store or object read
// while incremental marking runs. Inline cache entries are addressed directly:
// CompiledFunction.alloc_caches creates both arrays once, and nothing but
// freeing the function releases or moves them.
module boomkat::jit @feat(SLJIT);

import boomkat::vm;
import boomkat::bytecode;
import boomkat::heap;
import boomkat::types;
import boomkat::hobject;
import boomkat::hstring;
import boomkat::features;
import std::io;

// Field offsets and bit masks the inline paths read, taken once from layout
// pointers that are never dereferenced.
struct Layout {
    long ds_act;
    long act_this;
    long act_hrc;
    long act_lex_env;
    long act_tv_func;
    long act_func;
    long heap_gc_phase;
    long heap_shapes;
    long heap_epoch;
    long obj_shape;
    long obj_gc;
    long obj_proto;
    long obj_prop_alloc;
    long obj_prop_count;
    long obj_array_len;
    long fn_capture_refs;
    long fn_comp_func;
    long cf_capture_count;
    long shape_gen;
    long ic_shape;
    long ic_gen;
    long ic_idx;
    long ic_flags;
    long ic_chain_len;
    long ic_has_proto;
    long ic_chain;
    long ic_key;
    long chain_proto0;
    long chain_shape0;
    long ep_value;
    long ep_current;
    long ep_first;
    long ep_owner;
    long ic_absent_next;
    long obj_prop_capacity;
    long obj_prop_hash;
    long obj_array_size;
    long obj_array_inline_cap;
    long plain_exotic_mask;
    long extensible_mask;
    long indexed_named_mask;
    long proto_observed_mask;
    long vic_bindings;
    long vic_epoch;
    long vic_flags;
    long vic_head;
    long vic_slot;
    long cr_idx;
    long cr_is_cell;
    long cr_guard;
    long cr_is_value;
    long str_flags;
    long str_length;
    long proxy_mask;
    long module_ns_mask;
    long deferred_ns_mask;
    long class_mask;
    long class_object;
    long class_array;
    long old_mask;
    long inline_words_shift;
    long inline_words_mask;
    long accessor_mask;
    long writable_mask;
    long symbol_mask;
}

Layout layout_data @private;
bool layout_ready @private;

fn Layout* layout() {
    if (layout_ready) return &layout_data;
    Layout* l = &layout_data;
    char* base = (char*)(usz)4096;
    Dispatch* d = (Dispatch*)base;
    Activation* act = (Activation*)base;
    Heap* h = (Heap*)base;
    HObject* o = (HObject*)base;
    CompiledFunction* cf = (CompiledFunction*)base;
    hobject::Shape* sh = (hobject::Shape*)base;
    hobject::ICEntry* ic = (hobject::ICEntry*)base;
    hobject::ICChain* ch = (hobject::ICChain*)base;
    hobject::VarICEntry* vic = (hobject::VarICEntry*)base;
    hobject::CaptureRef* cr = (hobject::CaptureRef*)base;
    hstring::HString* s = (hstring::HString*)base;
    l.ds_act = (char*)&d.act - base;
    l.act_this = (char*)&act.this_binding - base;
    l.act_hrc = (char*)&act.heap_reg_count - base;
    l.act_lex_env = (char*)&act.lex_env - base;
    l.act_tv_func = (char*)&act.tv_func - base;
    l.act_func = (char*)&act.func - base;
    l.heap_gc_phase = (char*)&h.gc_phase - base;
    l.heap_shapes = (char*)&h.shapes - base;
    l.heap_epoch = (char*)&h.shape_recycle_epoch - base;
    l.obj_shape = (char*)&o.shape_id - base;
    l.obj_gc = (char*)&o.gc - base;
    l.obj_proto = (char*)&o.prototype - base;
    l.obj_prop_alloc = (char*)&o.prop_alloc - base;
    l.obj_prop_count = (char*)&o.prop_count - base;
    l.obj_array_len = (char*)&o.extra.array_length - base;
    l.fn_capture_refs = (char*)&o.extra.func.capture_refs - base;
    l.fn_comp_func = (char*)&o.extra.func.comp_func - base;
    l.cf_capture_count = (char*)&cf.capture_count - base;
    l.shape_gen = (char*)&sh.generation - base;
    l.ic_shape = (char*)&ic.shape_id - base;
    l.ic_gen = (char*)&ic.shape_gen - base;
    l.ic_idx = (char*)&ic.prop_idx - base;
    l.ic_flags = (char*)&ic.prop_flags - base;
    l.ic_chain_len = (char*)&ic.chain_len - base;
    l.ic_has_proto = (char*)&ic.has_proto - base;
    l.ic_chain = (char*)&ic.chain - base;
    l.ic_key = (char*)&ic.key - base;
    l.chain_proto0 = (char*)&ch.snapshot.protos[0] - base;
    l.chain_shape0 = (char*)&ch.snapshot.shapes[0] - base;
    l.ep_value = (char*)&ch.epoch.value - base;
    l.ep_current = (char*)&ch.epoch.current - base;
    l.ep_first = (char*)&ch.epoch.first - base;
    l.ep_owner = (char*)&ch.epoch.owner - base;
    l.ic_absent_next = (char*)&ic.absent_next_shape - base;
    l.obj_prop_capacity = (char*)&o.prop_capacity - base;
    l.obj_prop_hash = (char*)&o.prop_hash - base;
    l.obj_array_size = (char*)&o.array_size - base;
    l.obj_array_inline_cap = (char*)o.array_inline_capacity_ptr() - base;
    l.vic_bindings = (char*)&vic.bindings - base;
    l.vic_epoch = (char*)&vic.recycle_epoch - base;
    l.vic_flags = (char*)&vic.prop_flags - base;
    l.vic_head = (char*)&vic.search_head - base;
    l.vic_slot = (char*)&vic.slot_ptr - base;
    l.cr_idx = (char*)&cr.prop_idx - base;
    l.cr_is_cell = (char*)&cr.is_cell - base;
    l.cr_guard = (char*)&cr.guard_shadow - base;
    l.cr_is_value = (char*)&cr.is_value - base;
    l.str_flags = (char*)&s.flags - base;
    l.str_length = (char*)&s.length - base;

    hobject::ObjFlags f;
    f.exotic_proxyobj = true;
    l.proxy_mask = (long)(uint)f;
    f = {};
    f.exotic_module_ns = true;
    l.module_ns_mask = (long)(uint)f;
    f = {};
    f.exotic_deferred_ns = true;
    l.deferred_ns_mask = (long)(uint)f;
    // plain_property_object's exotic flags.
    f.exotic_module_ns = true;
    $if features::PROXY:
        f.exotic_proxyobj = true;
    $endif
    f.exotic_array = true;
    f.exotic_arguments = true;
    f.exotic_stringobj = true;
    l.plain_exotic_mask = (long)(uint)f;
    f = {};
    f.extensible = true;
    l.extensible_mask = (long)(uint)f;
    f = {};
    f.has_indexed_named_prop = true;
    l.indexed_named_mask = (long)(uint)f;
    f = {};
    f.obj_class = hobject::ObjClass.OBJECT;
    l.class_object = (long)(uint)f;
    f.obj_class = hobject::ObjClass.ARRAY;
    l.class_array = (long)(uint)f;
    // The class field is bits 16..21.
    l.class_mask = 0x3FL << 16;
    assert(l.class_array == (long)hobject::ObjClass.ARRAY.ordinal << 16);
    types::GcBits g;
    g.old = true;
    l.old_mask = (long)(uint)g;
    g = {};
    g.prototype_observed = true;
    l.proto_observed_mask = (long)(uint)g;
    g = {};
    g.inline_words = 1;
    uint one = (uint)g;
    long shift = 0;
    while ((one >> shift) != 1) shift++;
    l.inline_words_shift = shift;
    g.inline_words = 31;
    l.inline_words_mask = (long)((uint)g >> shift);
    hobject::PropFlags pf;
    pf.is_accessor = true;
    l.accessor_mask = (long)(char)pf;
    pf = {};
    pf.writable = true;
    l.writable_mask = (long)(char)pf;
    hstring::HStringFlags sf;
    sf.is_symbol = true;
    l.symbol_mask = (long)(uint)sf;
    // The flag guards read the first word of an object or string.
    assert(l.str_flags == 0);
    layout_ready = true;
    return l;
}

fn bool is_access_op(Opcode op) {
    switch (op) {
        case GETPROPC:
        case GETPROPC_CACHED:
        case GETPROP:
        case GETTHISC:
        case PUTPROP:
        case PUTPROPC:
        case PUTTHISC:
        case GETGLOBAL:
        case GETVAR:
        case GETCAP:
        case PUTCAP:
        case PUTVAR_ASSIGN:
        case LDREG:
        case LDTHIS:
            return true;
        default:
            return false;
    }
}

// Emit the inline path of an access instruction. False leaves it to the
// thunk.
fn bool Asm.emit_access(&self, bool consts_fixed) {
    CompiledFunction* f = self.f;
    Instruction w = self.w;
    Opcode op = w.op;
    bool has_ic = f.ic_entries != null && f.var_ic_entries != null;
    long ic = has_ic ? (long)(usz)&((hobject::ICEntry*)f.ic_entries)[self.i] : 0;
    long vic = has_ic ? (long)(usz)&((hobject::VarICEntry*)f.var_ic_entries)[self.i] : 0;
    switch (op) {
        case LDREG:
            self.emit_ldreg(w.a, w.b);
        case LDTHIS:
            // th_ldthis
            self.load_this(R0);
            self.guard_not_tdz();
            self.publish(w.a);
        case GETPROPC:
        case GETPROPC_CACHED:
            if (!has_ic || !consts_fixed || w.c >= f.const_count) return false;
            TVal key = f.constants[w.c];
            if (!key.is_string()) return false;
            self.load(R0, w.b);
            self.emit_get(w.a, ic, (long)(usz)key.get_heapptr(), -1, true, false, key.get_heapptr() == self.length_key);
        case GETPROP:
            if (!has_ic) return false;
            // th_getprop_array: an index into an array, or a string key.
            Jumps done;
            self.load(R3, w.c);
            sljit_emit_op2(self.c, SLJIT_XOR, R0, 0, R3, 0, SLJIT_IMM, K_INT);
            void* not_index = sljit_emit_cmp(self.c, SLJIT_GREATER_EQUAL, R0, 0, SLJIT_IMM, PAYLOAD_SPAN);
            self.emit_get_elem(w.a, w.b);
            done.add(sljit_emit_jump(self.c, SLJIT_JUMP));
            sljit_set_label(not_index, sljit_emit_label(self.c));
            self.load(R0, w.b);
            self.emit_get(w.a, ic, 0, (int)w.c, true, true, false);
            done.bind(sljit_emit_label(self.c));
        case GETTHISC:
            if (!has_ic) return false;
            self.load_this(R0);
            self.emit_get(w.a, ic, 0, -1, false, false, false);
        case PUTPROPC:
        case PUTTHISC:
            if (!has_ic || !consts_fixed || w.c >= f.const_count) return false;
            TVal key = f.constants[w.c];
            if (!key.is_string()) return false;
            if (op == PUTTHISC) {
                self.load_this(R0);
            } else {
                self.load(R0, w.a);
            }
            self.emit_put(ic, (long)(usz)key.get_heapptr(), -1, op == PUTTHISC ? w.a : w.b);
        case PUTPROP:
            if (!has_ic) return false;
            // th_putprop: an index into an array, or a string key.
            Jumps done;
            self.load(R3, w.b);
            sljit_emit_op2(self.c, SLJIT_XOR, R0, 0, R3, 0, SLJIT_IMM, K_INT);
            void* not_index = sljit_emit_cmp(self.c, SLJIT_GREATER_EQUAL, R0, 0, SLJIT_IMM, PAYLOAD_SPAN);
            self.emit_put_elem(w.a, w.c);
            done.add(sljit_emit_jump(self.c, SLJIT_JUMP));
            sljit_set_label(not_index, sljit_emit_label(self.c));
            self.load(R0, w.a);
            self.emit_put(ic, 0, (int)w.b, w.c);
            done.bind(sljit_emit_label(self.c));
        case GETGLOBAL:
            if (!has_ic) return false;
            self.emit_get_var(w.a, vic, false);
        case GETVAR:
            if (!has_ic) return false;
            self.emit_get_var(w.a, vic, true);
        case PUTVAR_ASSIGN:
            if (!has_ic) return false;
            self.emit_put_var(w.a, vic);
        case GETCAP:
            self.emit_get_cap(w.a, w.get_bc());
        case PUTCAP:
            self.emit_put_cap(w.a, w.get_bc());
        default:
            return false;
    }
    return true;
}

fn void Asm.load_this(&self, int reg) {
    Layout* l = self.lay;
    sljit_emit_op1(self.c, SLJIT_MOV, reg, 0, SLJIT_MEM | self.ds, l.ds_act);
    sljit_emit_op1(self.c, SLJIT_MOV, reg, 0, SLJIT_MEM | reg, l.act_this);
}

// dst = the HObject* `src` boxes; the slow path when it is not an object.
fn void Asm.unbox_object(&self, int dst, int src) {
    sljit_emit_op2(self.c, SLJIT_XOR, dst, 0, src, 0, SLJIT_IMM, K_OBJ);
    self.call.add(sljit_emit_cmp(self.c, SLJIT_GREATER_EQUAL, dst, 0, SLJIT_IMM, PAYLOAD_SPAN));
}

// The slow path when object `obj` has any of the flag bits `mask`.
fn void Asm.guard_flags_clear(&self, int obj, long mask, int tmp) {
    sljit_emit_op1(self.c, SLJIT_MOV_U32, tmp, 0, SLJIT_MEM | obj, 0);
    sljit_emit_op2(self.c, SLJIT_AND, tmp, 0, tmp, 0, SLJIT_IMM, mask);
    self.call.add(sljit_emit_cmp(self.c, SLJIT_NOT_EQUAL, tmp, 0, SLJIT_IMM, 0));
}

fn void Asm.guard_not_proxy(&self, int obj, int tmp) {
    $if features::PROXY:
        self.guard_flags_clear(obj, self.lay.proxy_mask, tmp);
    $endif
}

// dst = the property values of object `obj`, as HObject.prop_values.
fn void Asm.prop_base(&self, int dst, int obj) {
    void* c = self.c;
    Layout* l = self.lay;
    sljit_emit_op1(c, SLJIT_MOV, dst, 0, SLJIT_MEM | obj, l.obj_prop_alloc);
    void* done = sljit_emit_cmp(c, SLJIT_NOT_EQUAL, dst, 0, SLJIT_IMM, 0);
    sljit_emit_op1(c, SLJIT_MOV_U32, dst, 0, SLJIT_MEM | obj, l.obj_gc);
    sljit_emit_op2(c, SLJIT_LSHR, dst, 0, dst, 0, SLJIT_IMM, l.inline_words_shift);
    sljit_emit_op2(c, SLJIT_AND, dst, 0, dst, 0, SLJIT_IMM, l.inline_words_mask);
    sljit_emit_op2(c, SLJIT_SHL, dst, 0, dst, 0, SLJIT_IMM, 3);
    sljit_emit_op2(c, SLJIT_ADD, dst, 0, dst, 0, obj, 0);
    sljit_set_label(done, sljit_emit_label(c));
}

// The slow path while incremental marking runs.
fn void Asm.guard_not_marking(&self, int tmp) {
    sljit_emit_op1(self.c, SLJIT_MOV_U8, tmp, 0, SLJIT_MEM | self.heap, self.lay.heap_gc_phase);
    self.call.add(sljit_emit_cmp(self.c, SLJIT_EQUAL, tmp, 0, SLJIT_IMM, (long)heap::GcPhase.MARK.ordinal));
}

// The slow path when R0 holds a TDZ marker: undefined's tag with a payload.
fn void Asm.guard_not_tdz(&self) {
    void* c = self.c;
    sljit_emit_op2(c, SLJIT_XOR, R1, 0, R0, 0, SLJIT_IMM, K_UNDEF);
    void* plain = sljit_emit_cmp(c, SLJIT_EQUAL, R1, 0, SLJIT_IMM, 0);
    self.call.add(sljit_emit_cmp(c, SLJIT_LESS, R1, 0, SLJIT_IMM, PAYLOAD_SPAN));
    sljit_set_label(plain, sljit_emit_label(c));
}

// Store R0 into register `ra` as th_publish_read does for an inert value or an
// object: the object raises the frame's heap-register watermark, and anything
// else, or an object while marking, takes the slow path. Uses R1 and R2.
fn void Asm.publish(&self, uint ra) {
    void* c = self.c;
    Layout* l = self.lay;
    self.guard_dest(ra);
    void* inert = sljit_emit_cmp(c, SLJIT_LESS, R0, 0, SLJIT_IMM, K_STRING_START);
    sljit_emit_op2(c, SLJIT_XOR, R1, 0, R0, 0, SLJIT_IMM, K_OBJ);
    self.call.add(sljit_emit_cmp(c, SLJIT_GREATER_EQUAL, R1, 0, SLJIT_IMM, PAYLOAD_SPAN));
    self.guard_not_marking(R1);
    self.store(ra, R0);
    // track_heap_store
    sljit_emit_op1(c, SLJIT_MOV, R1, 0, SLJIT_MEM | self.ds, l.ds_act);
    sljit_emit_op1(c, SLJIT_MOV_U32, R2, 0, SLJIT_MEM | R1, l.act_hrc);
    void* covered = sljit_emit_cmp(c, SLJIT_GREATER, R2, 0, SLJIT_IMM, ra);
    sljit_emit_op1(c, SLJIT_MOV_U32, SLJIT_MEM | R1, l.act_hrc, SLJIT_IMM, (long)ra + 1);
    void* done = sljit_emit_jump(c, SLJIT_JUMP);
    sljit_set_label(inert, sljit_emit_label(c));
    self.store(ra, R0);
    void* end = sljit_emit_label(c);
    sljit_set_label(covered, end);
    sljit_set_label(done, end);
}

// LDREG of anything but a string or BigInt, as th_ldreg.
fn void Asm.emit_ldreg(&self, uint ra, uint rb) {
    self.load(R0, rb);
    self.publish(ra);
}

// A cached read of the object R0 boxes into register `ra`: the own data
// property, or one on the immediate prototype, that `ic` names for the
// receiver's shape, as th_getpropc, th_get_cached and ic_resolve_value. `key`
// is the site's constant key, or `key_reg` the register holding the key (a
// string), or neither for an entry whose key is the site's. A `length` key also
// reads an array's or string's length, as th_getpropc does before the cache.
// A computed key (`plain`) reads only from a plain object, as th_get_computed.
fn void Asm.emit_get(&self, uint ra, long ic, long key, int key_reg, bool check_key, bool plain, bool length) {
    void* c = self.c;
    Layout* l = self.lay;
    Jumps done;
    if (length) {
        // A string primitive's own length.
        sljit_emit_op2(c, SLJIT_XOR, R1, 0, R0, 0, SLJIT_IMM, K_STRING_START);
        void* not_string = sljit_emit_cmp(c, SLJIT_GREATER_EQUAL, R1, 0, SLJIT_IMM, PAYLOAD_SPAN);
        self.guard_flags_clear(R1, l.symbol_mask, R2);
        self.guard_dest(ra);
        sljit_emit_op1(c, SLJIT_MOV_U32, R0, 0, SLJIT_MEM | R1, l.str_length);
        sljit_emit_op2(c, SLJIT_OR, R0, 0, R0, 0, SLJIT_IMM, K_INT);
        self.store(ra, R0);
        done.add(sljit_emit_jump(c, SLJIT_JUMP));
        sljit_set_label(not_string, sljit_emit_label(c));
    }
    self.unbox_object(R1, R0);
    self.guard_not_proxy(R1, R2);
    if (plain) {
        sljit_emit_op1(c, SLJIT_MOV_U32, R2, 0, SLJIT_MEM | R1, 0);
        sljit_emit_op2(c, SLJIT_AND, R3, 0, R2, 0, SLJIT_IMM, l.class_mask);
        self.call.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R3, 0, SLJIT_IMM, l.class_object));
        sljit_emit_op2(c, SLJIT_AND, R3, 0, R2, 0, SLJIT_IMM, l.module_ns_mask | l.deferred_ns_mask);
        self.call.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R3, 0, SLJIT_IMM, 0));
    }
    if (length) {
        sljit_emit_op1(c, SLJIT_MOV_U32, R2, 0, SLJIT_MEM | R1, 0);
        sljit_emit_op2(c, SLJIT_AND, R2, 0, R2, 0, SLJIT_IMM, l.class_mask);
        void* not_array = sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R2, 0, SLJIT_IMM, l.class_array);
        self.guard_dest(ra);
        sljit_emit_op1(c, SLJIT_MOV_U32, R0, 0, SLJIT_MEM | R1, l.obj_array_len);
        sljit_emit_op2(c, SLJIT_OR, R0, 0, R0, 0, SLJIT_IMM, K_INT);
        self.store(ra, R0);
        done.add(sljit_emit_jump(c, SLJIT_JUMP));
        sljit_set_label(not_array, sljit_emit_label(c));
    }
    sljit_emit_op1(c, SLJIT_MOV, R2, 0, SLJIT_IMM, ic);
    if (key_reg >= 0) {
        self.load(R3, (uint)key_reg);
        sljit_emit_op2(c, SLJIT_XOR, R3, 0, R3, 0, SLJIT_IMM, K_STRING_START);
        self.call.add(sljit_emit_cmp(c, SLJIT_GREATER_EQUAL, R3, 0, SLJIT_IMM, PAYLOAD_SPAN));
        self.call.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R3, 0, SLJIT_MEM | R2, l.ic_key));
    } else if (check_key) {
        self.call.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, SLJIT_MEM | R2, l.ic_key, SLJIT_IMM, key));
    } else {
        self.call.add(sljit_emit_cmp(c, SLJIT_EQUAL, SLJIT_MEM | R2, l.ic_key, SLJIT_IMM, 0));
    }
    self.guard_shape(R1, R2);
    sljit_emit_op1(c, SLJIT_MOV_U8, R0, 0, SLJIT_MEM | R2, l.ic_flags);
    sljit_emit_op2(c, SLJIT_AND, R0, 0, R0, 0, SLJIT_IMM, l.accessor_mask);
    self.call.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R0, 0, SLJIT_IMM, 0));
    sljit_emit_op1(c, SLJIT_MOV_U8, R0, 0, SLJIT_MEM | R2, l.ic_has_proto);
    void* own = sljit_emit_cmp(c, SLJIT_EQUAL, R0, 0, SLJIT_IMM, 0);
    sljit_emit_op1(c, SLJIT_MOV_U8, R0, 0, SLJIT_MEM | R2, l.ic_chain_len);
    void* snapshot = sljit_emit_cmp(c, SLJIT_EQUAL, R0, 0, SLJIT_IMM, 1);
    self.call.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R0, 0, SLJIT_IMM, (long)hobject::IC_CHAIN_EPOCH));
    // The epoch payload: a plain receiver whose first link is the recorded
    // one while the mutation epoch holds, as ic_resolve_owner.
    sljit_emit_op1(c, SLJIT_MOV_U32, R0, 0, SLJIT_MEM | R1, 0);
    sljit_emit_op2(c, SLJIT_AND, R0, 0, R0, 0, SLJIT_IMM, l.class_mask | l.plain_exotic_mask);
    self.call.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R0, 0, SLJIT_IMM, l.class_object));
    sljit_emit_op1(c, SLJIT_MOV, R0, 0, SLJIT_MEM | R2, l.ic_chain);
    sljit_emit_op1(c, SLJIT_MOV, R3, 0, SLJIT_MEM | R1, l.obj_proto);
    self.call.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R3, 0, SLJIT_MEM | R0, l.ep_first));
    sljit_emit_op1(c, SLJIT_MOV, R3, 0, SLJIT_MEM | R0, l.ep_current);
    sljit_emit_op1(c, SLJIT_MOV, R3, 0, SLJIT_MEM | R3, 0);
    self.call.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R3, 0, SLJIT_MEM | R0, l.ep_value));
    sljit_emit_op1(c, SLJIT_MOV, R1, 0, SLJIT_MEM | R0, l.ep_owner);
    self.guard_not_proxy(R1, R0);
    void* epoch_done = sljit_emit_jump(c, SLJIT_JUMP);
    // One link up: the snapshot's prototype and its shape, as ic_resolve_owner.
    sljit_set_label(snapshot, sljit_emit_label(c));
    sljit_emit_op1(c, SLJIT_MOV, R0, 0, SLJIT_MEM | R2, l.ic_chain);
    sljit_emit_op1(c, SLJIT_MOV, R1, 0, SLJIT_MEM | R1, l.obj_proto);
    self.call.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R1, 0, SLJIT_MEM | R0, l.chain_proto0));
    self.call.add(sljit_emit_cmp(c, SLJIT_EQUAL, R1, 0, SLJIT_IMM, 0));
    sljit_emit_op1(c, SLJIT_MOV_U32, R3, 0, SLJIT_MEM | R1, l.obj_shape);
    sljit_emit_op1(c, SLJIT_MOV_U32, R0, 0, SLJIT_MEM | R0, l.chain_shape0);
    self.call.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R3, 0, R0, 0));
    self.guard_not_proxy(R1, R0);
    void* resolved = sljit_emit_label(c);
    sljit_set_label(own, resolved);
    sljit_set_label(epoch_done, resolved);
    sljit_emit_op1(c, SLJIT_MOV_U32, R3, 0, SLJIT_MEM | R2, l.ic_idx);
    self.prop_base(R0, R1);
    sljit_emit_op1(c, SLJIT_MOV, R0, 0, mem_index(R0, R3), 3);
    self.publish(ra);
    done.bind(sljit_emit_label(c));
}

// The slow path unless object `obj`'s shape is the one entry `ic` (in its
// register) holds. Uses R0 and R3.
fn void Asm.guard_shape(&self, int obj, int ic) {
    Layout* l = self.lay;
    sljit_emit_op1(self.c, SLJIT_MOV_U32, R3, 0, SLJIT_MEM | obj, l.obj_shape);
    sljit_emit_op1(self.c, SLJIT_MOV_U32, R0, 0, SLJIT_MEM | ic, l.ic_shape);
    self.call.add(sljit_emit_cmp(self.c, SLJIT_NOT_EQUAL, R3, 0, R0, 0));
}

// Store register `rv` into the slot at R0, owned by the object in R1, as the
// non-heap case of th_put_cached extended to objects: the old value must not
// be counted, and an object value needs no barrier work (not marking, and an
// owner that is not old). Uses R2 and R3.
fn void Asm.store_slot(&self, uint rv) {
    void* c = self.c;
    Layout* l = self.lay;
    sljit_emit_op1(c, SLJIT_MOV, R3, 0, SLJIT_MEM | R0, 0);
    void* old_ok = sljit_emit_cmp(c, SLJIT_LESS, R3, 0, SLJIT_IMM, K_STRING_START);
    sljit_emit_op2(c, SLJIT_XOR, R3, 0, R3, 0, SLJIT_IMM, K_OBJ);
    self.call.add(sljit_emit_cmp(c, SLJIT_GREATER_EQUAL, R3, 0, SLJIT_IMM, PAYLOAD_SPAN));
    sljit_set_label(old_ok, sljit_emit_label(c));
    self.store_value(rv);
}

// Store register `rv` into the slot at R0 of the object in R1 when the value
// needs no count and no barrier work; the slow path otherwise. Uses R2, R3.
fn void Asm.store_value(&self, uint rv) {
    void* c = self.c;
    Layout* l = self.lay;
    self.load(R2, rv);
    void* inert = sljit_emit_cmp(c, SLJIT_LESS, R2, 0, SLJIT_IMM, K_STRING_START);
    sljit_emit_op2(c, SLJIT_XOR, R3, 0, R2, 0, SLJIT_IMM, K_OBJ);
    self.call.add(sljit_emit_cmp(c, SLJIT_GREATER_EQUAL, R3, 0, SLJIT_IMM, PAYLOAD_SPAN));
    self.guard_not_marking(R3);
    sljit_emit_op1(c, SLJIT_MOV_U32, R3, 0, SLJIT_MEM | R1, l.obj_gc);
    sljit_emit_op2(c, SLJIT_AND, R3, 0, R3, 0, SLJIT_IMM, l.old_mask);
    self.call.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R3, 0, SLJIT_IMM, 0));
    sljit_set_label(inert, sljit_emit_label(c));
    sljit_emit_op1(c, SLJIT_MOV, SLJIT_MEM | R0, 0, R2, 0);
}

// A cached overwrite of an existing own writable data property of the object
// R0 boxes, as th_put_cached: a plain object, the entry's key, shape and shape
// generation, no prototype owner and no absent-add entry.
fn void Asm.emit_put(&self, long ic, long key, int key_reg, uint rv) {
    void* c = self.c;
    Layout* l = self.lay;
    self.unbox_object(R1, R0);
    sljit_emit_op1(c, SLJIT_MOV_U32, R2, 0, SLJIT_MEM | R1, 0);
    sljit_emit_op2(c, SLJIT_AND, R3, 0, R2, 0, SLJIT_IMM, l.class_mask);
    self.call.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R3, 0, SLJIT_IMM, l.class_object));
    long exotic = l.module_ns_mask;
    $if features::PROXY:
        exotic |= l.proxy_mask;
    $endif
    sljit_emit_op2(c, SLJIT_AND, R3, 0, R2, 0, SLJIT_IMM, exotic);
    self.call.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R3, 0, SLJIT_IMM, 0));
    sljit_emit_op1(c, SLJIT_MOV, R2, 0, SLJIT_IMM, ic);
    sljit_emit_op1(c, SLJIT_MOV_U32, R3, 0, SLJIT_MEM | R2, l.ic_idx);
    void* absent = sljit_emit_cmp(c, SLJIT_EQUAL, R3, 0, SLJIT_IMM, (long)hobject::IC_PROP_ABSENT);
    self.put_key_check(key, key_reg);
    self.guard_shape(R1, R2);
    sljit_emit_op1(c, SLJIT_MOV_U8, R0, 0, SLJIT_MEM | R2, l.ic_has_proto);
    self.call.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R0, 0, SLJIT_IMM, 0));
    // live_shape_generation: heap.shapes[shape_id].generation.
    sljit_emit_op1(c, SLJIT_MOV, R0, 0, SLJIT_MEM | self.heap, l.heap_shapes);
    sljit_emit_op1(c, SLJIT_MOV, R0, 0, mem_index(R0, R3), 3);
    sljit_emit_op1(c, SLJIT_MOV_U32, R0, 0, SLJIT_MEM | R0, l.shape_gen);
    sljit_emit_op1(c, SLJIT_MOV_U32, R3, 0, SLJIT_MEM | R2, l.ic_gen);
    self.call.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R3, 0, R0, 0));
    sljit_emit_op1(c, SLJIT_MOV_U8, R0, 0, SLJIT_MEM | R2, l.ic_flags);
    sljit_emit_op2(c, SLJIT_AND, R0, 0, R0, 0, SLJIT_IMM, l.accessor_mask | l.writable_mask);
    self.call.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R0, 0, SLJIT_IMM, l.writable_mask));
    sljit_emit_op1(c, SLJIT_MOV_U32, R3, 0, SLJIT_MEM | R2, l.ic_idx);
    self.prop_base(R0, R1);
    sljit_emit_op2(c, SLJIT_SHL, R3, 0, R3, 0, SLJIT_IMM, 3);
    sljit_emit_op2(c, SLJIT_ADD, R0, 0, R0, 0, R3, 0);
    self.store_slot(rv);
    void* done = sljit_emit_jump(c, SLJIT_JUMP);
    sljit_set_label(absent, sljit_emit_label(c));
    self.emit_put_absent(ic, key, key_reg, rv);
    sljit_set_label(done, sljit_emit_label(c));
}

// The site key check of a store: the constant `key`, or the string in
// register `key_reg`, against the entry in R2. Uses R3.
fn void Asm.put_key_check(&self, long key, int key_reg) {
    void* c = self.c;
    Layout* l = self.lay;
    if (key_reg >= 0) {
        self.load(R3, (uint)key_reg);
        sljit_emit_op2(c, SLJIT_XOR, R3, 0, R3, 0, SLJIT_IMM, K_STRING_START);
        self.call.add(sljit_emit_cmp(c, SLJIT_GREATER_EQUAL, R3, 0, SLJIT_IMM, PAYLOAD_SPAN));
        self.call.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R3, 0, SLJIT_MEM | R2, l.ic_key));
    } else {
        self.call.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, SLJIT_MEM | R2, l.ic_key, SLJIT_IMM, key));
    }
}

// Stack offset of the spill slot an absent-add store uses; offset 0 holds a
// native call site's saved floor.
const long SPILL_OFF = 8;

// An absent-property add to the plain object in R1 through the entry in R2,
// as th_put_absent and ic_matches_absent_put: the receiver keeps the entry's
// shape under the current recycle epoch and is extensible, its whole chain
// matches the snapshot and ends in null, and the property table has room.
fn void Asm.emit_put_absent(&self, long ic, long key, int key_reg, uint rv) {
    void* c = self.c;
    Layout* l = self.lay;
    sljit_emit_op1(c, SLJIT_MOV_U8, R0, 0, SLJIT_MEM | R2, l.ic_has_proto);
    self.call.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R0, 0, SLJIT_IMM, 0));
    self.put_key_check(key, key_reg);
    self.guard_shape(R1, R2);
    sljit_emit_op1(c, SLJIT_MOV_U32, R0, 0, SLJIT_MEM | R2, l.ic_gen);
    sljit_emit_op1(c, SLJIT_MOV_U32, R3, 0, SLJIT_MEM | self.heap, l.heap_epoch);
    self.call.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R0, 0, R3, 0));
    sljit_emit_op1(c, SLJIT_MOV_U32, R0, 0, SLJIT_MEM | R1, 0);
    sljit_emit_op2(c, SLJIT_AND, R3, 0, R0, 0, SLJIT_IMM, l.extensible_mask);
    self.call.add(sljit_emit_cmp(c, SLJIT_EQUAL, R3, 0, SLJIT_IMM, 0));
    sljit_emit_op2(c, SLJIT_AND, R3, 0, R0, 0, SLJIT_IMM, l.plain_exotic_mask);
    self.call.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R3, 0, SLJIT_IMM, 0));
    // ic_matches_absent_chain, unrolled: R1 counts the links, R0 holds the
    // snapshot and R3 walks the chain.
    int spill = SLJIT_MEM | reg_sp();
    sljit_emit_op1(c, SLJIT_MOV, spill, SPILL_OFF, R1, 0);
    sljit_emit_op1(c, SLJIT_MOV, R3, 0, SLJIT_MEM | R1, l.obj_proto);
    sljit_emit_op1(c, SLJIT_MOV, R0, 0, SLJIT_MEM | R2, l.ic_chain);
    sljit_emit_op1(c, SLJIT_MOV_U8, R1, 0, SLJIT_MEM | R2, l.ic_chain_len);
    self.call.add(sljit_emit_cmp(c, SLJIT_GREATER, R1, 0, SLJIT_IMM, (long)hobject::IC_MAX_CHAIN));
    Jumps ends;
    for (uint k = 0; k < hobject::IC_MAX_CHAIN; k++) {
        ends.add(sljit_emit_cmp(c, SLJIT_EQUAL, R1, 0, SLJIT_IMM, k));
        self.call.add(sljit_emit_cmp(c, SLJIT_EQUAL, R3, 0, SLJIT_IMM, 0));
        self.call.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R3, 0, SLJIT_MEM | R0, l.chain_proto0 + (long)k * 8));
        sljit_emit_op1(c, SLJIT_MOV_U32, R2, 0, SLJIT_MEM | R3, l.obj_shape);
        self.call.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL | SLJIT_32, R2, 0, SLJIT_MEM | R0, l.chain_shape0 + (long)k * 4));
        sljit_emit_op1(c, SLJIT_MOV_U32, R2, 0, SLJIT_MEM | R3, 0);
        sljit_emit_op2(c, SLJIT_AND, R2, 0, R2, 0, SLJIT_IMM, l.class_mask | l.plain_exotic_mask);
        self.call.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R2, 0, SLJIT_IMM, l.class_object));
        sljit_emit_op1(c, SLJIT_MOV, R3, 0, SLJIT_MEM | R3, l.obj_proto);
    }
    ends.bind(sljit_emit_label(c));
    self.call.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R3, 0, SLJIT_IMM, 0));
    sljit_emit_op1(c, SLJIT_MOV, R1, 0, spill, SPILL_OFF);
    // A prototype's layout change bumps an epoch, which the thunk does.
    sljit_emit_op1(c, SLJIT_MOV_U32, R0, 0, SLJIT_MEM | R1, l.obj_gc);
    sljit_emit_op2(c, SLJIT_AND, R0, 0, R0, 0, SLJIT_IMM, l.proto_observed_mask);
    self.call.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R0, 0, SLJIT_IMM, 0));
    self.call.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, SLJIT_MEM | R1, l.obj_prop_hash, SLJIT_IMM, 0));
    sljit_emit_op1(c, SLJIT_MOV_U32, R3, 0, SLJIT_MEM | R1, l.obj_prop_count);
    sljit_emit_op1(c, SLJIT_MOV_U32, R0, 0, SLJIT_MEM | R1, l.obj_prop_capacity);
    self.call.add(sljit_emit_cmp(c, SLJIT_GREATER_EQUAL, R3, 0, R0, 0));
    self.prop_base(R0, R1);
    sljit_emit_op2(c, SLJIT_SHL, R3, 0, R3, 0, SLJIT_IMM, 3);
    sljit_emit_op2(c, SLJIT_ADD, R0, 0, R0, 0, R3, 0);
    self.store_value(rv);
    sljit_emit_op1(c, SLJIT_MOV_U32, R3, 0, SLJIT_MEM | R1, l.obj_prop_count);
    sljit_emit_op2(c, SLJIT_ADD, R3, 0, R3, 0, SLJIT_IMM, 1);
    sljit_emit_op1(c, SLJIT_MOV_U32, SLJIT_MEM | R1, l.obj_prop_count, R3, 0);
    sljit_emit_op1(c, SLJIT_MOV, R2, 0, SLJIT_IMM, ic);
    sljit_emit_op1(c, SLJIT_MOV_U32, R3, 0, SLJIT_MEM | R2, l.ic_absent_next);
    sljit_emit_op1(c, SLJIT_MOV_U32, SLJIT_MEM | R1, l.obj_shape, R3, 0);
}

// R0 = the address of element R3 (a fastint) of the dense part of the array
// in R1, as HObject.array_part; the slow path for a negative index or one
// past the dense part. Uses R2.
fn void Asm.array_slot(&self) {
    void* c = self.c;
    Layout* l = self.lay;
    sljit_emit_op2(c, SLJIT_SHL, R3, 0, R3, 0, SLJIT_IMM, 16);
    sljit_emit_op2(c, SLJIT_ASHR, R3, 0, R3, 0, SLJIT_IMM, 16);
    sljit_emit_op1(c, SLJIT_MOV_U32, R2, 0, SLJIT_MEM | R1, l.obj_array_size);
    // Unsigned, so a negative index fails too.
    self.call.add(sljit_emit_cmp(c, SLJIT_GREATER_EQUAL, R3, 0, R2, 0));
    sljit_emit_op1(c, SLJIT_MOV, R0, 0, SLJIT_MEM | R1, l.obj_prop_alloc);
    void* allocated = sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R0, 0, SLJIT_IMM, 0);
    sljit_emit_op1(c, SLJIT_MOV_U32, R2, 0, SLJIT_MEM | R1, l.obj_array_inline_cap);
    self.call.add(sljit_emit_cmp(c, SLJIT_EQUAL, R2, 0, SLJIT_IMM, 0));
    sljit_emit_op2(c, SLJIT_ADD, R0, 0, R1, 0, SLJIT_IMM, (long)hobject::OBJ_SIZE_ARRAY);
    void* based = sljit_emit_jump(c, SLJIT_JUMP);
    sljit_set_label(allocated, sljit_emit_label(c));
    sljit_emit_op1(c, SLJIT_MOV_U32, R2, 0, SLJIT_MEM | R1, l.obj_prop_capacity);
    sljit_emit_op2(c, SLJIT_SHL, R2, 0, R2, 0, SLJIT_IMM, 3);
    sljit_emit_op2(c, SLJIT_ADD, R0, 0, R0, 0, R2, 0);
    sljit_set_label(based, sljit_emit_label(c));
    sljit_emit_op2(c, SLJIT_SHL, R3, 0, R3, 0, SLJIT_IMM, 3);
    sljit_emit_op2(c, SLJIT_ADD, R0, 0, R0, 0, R3, 0);
}

// The slow path unless R1 is an array that is not a proxy and has none of
// the flags `extra`.
fn void Asm.guard_array(&self, long extra) {
    void* c = self.c;
    Layout* l = self.lay;
    long mask = l.class_mask | extra;
    $if features::PROXY:
        mask |= l.proxy_mask;
    $endif
    sljit_emit_op1(c, SLJIT_MOV_U32, R2, 0, SLJIT_MEM | R1, 0);
    sljit_emit_op2(c, SLJIT_AND, R2, 0, R2, 0, SLJIT_IMM, mask);
    self.call.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R2, 0, SLJIT_IMM, l.class_array));
}

// A read of a dense array element, index in R3, as th_getprop_array: a hole
// takes the slow path, which consults the prototype chain.
fn void Asm.emit_get_elem(&self, uint ra, uint rb) {
    void* c = self.c;
    self.load(R0, rb);
    self.unbox_object(R1, R0);
    self.guard_array(0);
    self.array_slot();
    sljit_emit_op1(c, SLJIT_MOV, R0, 0, SLJIT_MEM | R0, 0);
    self.call.add(sljit_emit_cmp(c, SLJIT_EQUAL, R0, 0, SLJIT_IMM, K_UNDEF));
    self.publish(ra);
}

// An overwrite of a dense array element, index in R3, as
// th_put_array_element; a hole or an undefined value takes the slow path.
fn void Asm.emit_put_elem(&self, uint ra, uint rv) {
    void* c = self.c;
    self.load(R0, ra);
    self.unbox_object(R1, R0);
    self.guard_array(self.lay.indexed_named_mask);
    self.array_slot();
    self.call.add(sljit_emit_cmp(c, SLJIT_EQUAL, SLJIT_MEM | R0, 0, SLJIT_IMM, K_UNDEF));
    self.load(R2, rv);
    self.call.add(sljit_emit_cmp(c, SLJIT_EQUAL, R2, 0, SLJIT_IMM, K_UNDEF));
    self.store_slot(rv);
}

// R2 = the variable entry `vic`'s binding slot while the entry is valid, as
// th_var_ic_hit (and th_var_ic_moved when `scoped`); the slow path otherwise.
fn void Asm.var_slot(&self, long vic, bool scoped) {
    void* c = self.c;
    Layout* l = self.lay;
    sljit_emit_op1(c, SLJIT_MOV, R2, 0, SLJIT_IMM, vic);
    if (scoped) {
        sljit_emit_op1(c, SLJIT_MOV, R1, 0, SLJIT_MEM | self.ds, l.ds_act);
        sljit_emit_op1(c, SLJIT_MOV, R1, 0, SLJIT_MEM | R1, l.act_lex_env);
        self.call.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R1, 0, SLJIT_MEM | R2, l.vic_head));
    }
    sljit_emit_op1(c, SLJIT_MOV_U32, R0, 0, SLJIT_MEM | R2, l.vic_epoch);
    sljit_emit_op1(c, SLJIT_MOV_U32, R1, 0, SLJIT_MEM | self.heap, l.heap_epoch);
    self.call.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R0, 0, R1, 0));
    sljit_emit_op1(c, SLJIT_MOV, R0, 0, SLJIT_MEM | R2, l.vic_slot);
    self.call.add(sljit_emit_cmp(c, SLJIT_EQUAL, R0, 0, SLJIT_IMM, 0));
}

// GETGLOBAL as th_getglobal, GETVAR as th_getvar.
fn void Asm.emit_get_var(&self, uint ra, long vic, bool scoped) {
    void* c = self.c;
    self.var_slot(vic, scoped);
    if (scoped) {
        sljit_emit_op1(c, SLJIT_MOV_U8, R1, 0, SLJIT_MEM | R2, self.lay.vic_flags);
        sljit_emit_op2(c, SLJIT_AND, R1, 0, R1, 0, SLJIT_IMM, self.lay.accessor_mask);
        self.call.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R1, 0, SLJIT_IMM, 0));
    }
    sljit_emit_op1(c, SLJIT_MOV, R0, 0, SLJIT_MEM | R0, 0);
    self.guard_not_tdz();
    self.publish(ra);
}

// PUTVAR_ASSIGN as th_putvar_assign: a writable data binding that is not in
// its TDZ; the value moves out of register `rv`.
fn void Asm.emit_put_var(&self, uint rv, long vic) {
    void* c = self.c;
    Layout* l = self.lay;
    self.var_slot(vic, true);
    sljit_emit_op1(c, SLJIT_MOV_U8, R1, 0, SLJIT_MEM | R2, l.vic_flags);
    sljit_emit_op2(c, SLJIT_AND, R1, 0, R1, 0, SLJIT_IMM, l.accessor_mask | l.writable_mask);
    self.call.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R1, 0, SLJIT_IMM, l.writable_mask));
    sljit_emit_op1(c, SLJIT_MOV, R1, 0, SLJIT_MEM | R2, l.vic_bindings);
    // slot_is_tdz
    sljit_emit_op1(c, SLJIT_MOV, R3, 0, SLJIT_MEM | R0, 0);
    sljit_emit_op2(c, SLJIT_XOR, R3, 0, R3, 0, SLJIT_IMM, K_UNDEF);
    void* plain = sljit_emit_cmp(c, SLJIT_EQUAL, R3, 0, SLJIT_IMM, 0);
    self.call.add(sljit_emit_cmp(c, SLJIT_LESS, R3, 0, SLJIT_IMM, PAYLOAD_SPAN));
    sljit_set_label(plain, sljit_emit_label(c));
    self.store_slot(rv);
    self.store(rv, SLJIT_IMM, K_UNDEF);
}

// R1 = capture record `index` of the running closure, as capture_refs_of; the
// slow path when the frame runs other code or the index is out of range.
fn void Asm.capture_ref(&self, uint index) {
    void* c = self.c;
    Layout* l = self.lay;
    sljit_emit_op1(c, SLJIT_MOV, R1, 0, SLJIT_MEM | self.ds, l.ds_act);
    sljit_emit_op1(c, SLJIT_MOV, R0, 0, SLJIT_MEM | R1, l.act_tv_func);
    self.unbox_object(R3, R0);
    sljit_emit_op1(c, SLJIT_MOV, R0, 0, SLJIT_MEM | R3, l.fn_capture_refs);
    self.call.add(sljit_emit_cmp(c, SLJIT_EQUAL, R0, 0, SLJIT_IMM, 0));
    sljit_emit_op1(c, SLJIT_MOV, R2, 0, SLJIT_MEM | R3, l.fn_comp_func);
    self.call.add(sljit_emit_cmp(c, SLJIT_EQUAL, R2, 0, SLJIT_IMM, 0));
    self.call.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R2, 0, SLJIT_MEM | R1, l.act_func));
    sljit_emit_op1(c, SLJIT_MOV_U32, R2, 0, SLJIT_MEM | R2, l.cf_capture_count);
    self.call.add(sljit_emit_cmp(c, SLJIT_LESS_EQUAL, R2, 0, SLJIT_IMM, index));
    sljit_emit_op2(c, SLJIT_ADD, R1, 0, R0, 0, SLJIT_IMM, (long)index * hobject::CaptureRef::size);
}

// GETCAP as th_getcap and capture_read_slot: a value snapshot, a cell, or an
// unshadowed binding outside its TDZ.
fn void Asm.emit_get_cap(&self, uint ra, uint index) {
    void* c = self.c;
    Layout* l = self.lay;
    Jumps loaded;
    self.capture_ref(index);
    sljit_emit_op1(c, SLJIT_MOV_U8, R2, 0, SLJIT_MEM | R1, l.cr_is_value);
    void* not_value = sljit_emit_cmp(c, SLJIT_EQUAL, R2, 0, SLJIT_IMM, 0);
    sljit_emit_op1(c, SLJIT_MOV, R0, 0, SLJIT_MEM | R1, 0);
    loaded.add(sljit_emit_jump(c, SLJIT_JUMP));
    sljit_set_label(not_value, sljit_emit_label(c));
    sljit_emit_op1(c, SLJIT_MOV, R3, 0, SLJIT_MEM | R1, 0);
    self.call.add(sljit_emit_cmp(c, SLJIT_EQUAL, R3, 0, SLJIT_IMM, 0));
    sljit_emit_op1(c, SLJIT_MOV_U8, R2, 0, SLJIT_MEM | R1, l.cr_guard);
    self.call.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R2, 0, SLJIT_IMM, 0));
    sljit_emit_op1(c, SLJIT_MOV_U32, R2, 0, SLJIT_MEM | R1, l.cr_idx);
    sljit_emit_op1(c, SLJIT_MOV_U8, R0, 0, SLJIT_MEM | R1, l.cr_is_cell);
    void* binding = sljit_emit_cmp(c, SLJIT_EQUAL, R0, 0, SLJIT_IMM, 0);
    sljit_emit_op1(c, SLJIT_MOV_U32, R0, 0, SLJIT_MEM | R3, l.obj_prop_count);
    self.call.add(sljit_emit_cmp(c, SLJIT_GREATER_EQUAL, R2, 0, R0, 0));
    self.prop_base(R0, R3);
    sljit_emit_op1(c, SLJIT_MOV, R0, 0, mem_index(R0, R2), 3);
    loaded.add(sljit_emit_jump(c, SLJIT_JUMP));
    sljit_set_label(binding, sljit_emit_label(c));
    self.prop_base(R0, R3);
    sljit_emit_op1(c, SLJIT_MOV, R0, 0, mem_index(R0, R2), 3);
    self.guard_not_tdz();
    loaded.bind(sljit_emit_label(c));
    self.publish(ra);
}

// PUTCAP into a cell, as th_putcap and capture_value_slot's cell case; a value
// snapshot or a binding (whose writability needs a shape lookup) takes the
// slow path. The value moves out of register `rv`.
fn void Asm.emit_put_cap(&self, uint rv, uint index) {
    void* c = self.c;
    Layout* l = self.lay;
    self.capture_ref(index);
    sljit_emit_op1(c, SLJIT_MOV_U8, R2, 0, SLJIT_MEM | R1, l.cr_is_value);
    self.call.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R2, 0, SLJIT_IMM, 0));
    sljit_emit_op1(c, SLJIT_MOV_U8, R2, 0, SLJIT_MEM | R1, l.cr_is_cell);
    self.call.add(sljit_emit_cmp(c, SLJIT_EQUAL, R2, 0, SLJIT_IMM, 0));
    sljit_emit_op1(c, SLJIT_MOV_U32, R2, 0, SLJIT_MEM | R1, l.cr_idx);
    sljit_emit_op1(c, SLJIT_MOV, R1, 0, SLJIT_MEM | R1, 0);
    self.call.add(sljit_emit_cmp(c, SLJIT_EQUAL, R1, 0, SLJIT_IMM, 0));
    sljit_emit_op1(c, SLJIT_MOV_U32, R0, 0, SLJIT_MEM | R1, l.obj_prop_count);
    self.call.add(sljit_emit_cmp(c, SLJIT_GREATER_EQUAL, R2, 0, R0, 0));
    self.prop_base(R0, R1);
    sljit_emit_op2(c, SLJIT_SHL, R2, 0, R2, 0, SLJIT_IMM, 3);
    sljit_emit_op2(c, SLJIT_ADD, R0, 0, R0, 0, R2, 0);
    self.store_slot(rv);
    self.store(rv, SLJIT_IMM, K_UNDEF);
}

// Count one execution of `op` in `counts` when --jit-stats asked for counts.
fn void Asm.count(&self, ulong* counts, Opcode op) {
    if (!self.counting) return;
    long at = (long)(usz)&counts[op.ordinal];
    sljit_emit_op2(self.c, SLJIT_ADD, SLJIT_MEM, at, SLJIT_MEM, at, SLJIT_IMM, 1);
}

// The --jit-stats counts: inline completions against thunk calls of each
// access opcode, then the opcodes with the most thunk calls.
fn void baseline_print_counts(JitStats* st) {
    if (!st.count_ops) return;
    foreach (op : Opcode::values) {
        if (!is_access_op(op)) continue;
        ulong fast = st.fast_hits[op.ordinal];
        ulong slow = st.slow_calls[op.ordinal];
        if (fast + slow == 0) continue;
        io::eprintfn("jit op %s: inline %d, thunk %d (%.1f%% inline)", op, fast, slow,
                     100.0 * (double)fast / (double)(fast + slow));
    }
    bool[Opcode::values.len] shown;
    for (uint rank = 0; rank < 10; rank++) {
        int best = -1;
        foreach (k, n : st.slow_calls) {
            if (!shown[k] && n != 0 && (best < 0 || n > st.slow_calls[best])) best = (int)k;
        }
        if (best < 0) break;
        shown[best] = true;
        io::eprintfn("jit slow %d: %s %d", rank + 1, Opcode::values[best], st.slow_calls[best]);
    }
}

