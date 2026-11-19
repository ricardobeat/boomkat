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
import boomkat::pagepool;
import boomkat::features;
import std::io;

// Field offsets and bit masks the inline paths read, taken once from layout
// pointers that are never dereferenced.
struct Layout {
    long ds_act;
    long ds_reg_floor;
    long ds_enter_sp;
    long act_this;
    long act_hrc;
    long act_lex_env;
    long act_tv_func;
    long act_func;
    long heap_gc_phase;
    long heap_shapes;
    long heap_epoch;
    long heap_proto_epoch;
    long heap_site_key;
    long obj_shape;
    long obj_gc;
    long obj_proto;
    long obj_props;
    long obj_prop_count;
    long obj_array_len;
    long fn_capture_refs;
    long fn_comp_func;
    long gs_getter;
    long cf_capture_count;
    long shape_gen;
    long ic_shape;
    long ic_gen;
    long ic_idx;
    long ic_flags;
    long ic_chain_len;
    long poly_count;
    long poly_shapes;
    long poly_idx;
    long ic_has_proto;
    long ic_chain;
    long ic_key;
    long chain_proto0;
    long chain_absent_epoch;
    long epoch_value;
    long epoch_current;
    long epoch_first;
    long epoch_owner;
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
    long packed_mask;
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
    long class_regexp;
    long old_mask;
    long remembered_mask;

    long heap_gc_kind;
    long heap_gc_oracle;
    long accessor_mask;
    long writable_mask;
    long symbol_mask;
    // The string flags any of which keeps a string's units from being its inline bytes: a symbol,
    // UTF-16 units, data in an external buffer.
    long byte_units_mask;
    long interned_mask;
    long queued_mask;
    long interned_shift;
    long str_refcount;
    long view_buffer;
    long view_offset;
    long view_length;
    long ab_data;
    long ab_resizable;
    long ab_immutable;
    long heap_mega;
    long heap_string_proto;
    long heap_function_proto;
    long me_key;
    long me_shape;
    long me_idx;
    long me_proto;
    long me_proto_shape;
    long me_epoch;
    long me_accessor;
    // Inline allocation (baseline_alloc.c3): the heap's counters and pools, and
    // the pool and page fields the bump allocation and its mark read.
    long heap_trigger;
    long heap_alloc_since;
    long heap_live;
    long heap_mem_budget;
    long heap_gc_requested;
    long heap_gray_items;
    long heap_gray_len;
    long heap_gray_cap;
    long heap_gray_count;
    long heap_marked_count;
    long heap_object_proto;
    long heap_array_proto;
    long heap_realms;
    long heap_pool_plain;
    long heap_pool_compact;
    long heap_pool_shaped;
    long heap_pool_arrays;
    long pool_size;
    long pool_bump;
    long pool_limit;
    long pool_block_size;
    long page_mark_epoch;
    long page_mark;
    long page_teardown;
    long heap_major_epoch;
    long heap_alloc_bitmap;
    long undefined_bits;
    long obj_array_used;
    long obj_size_array;
    long constructable_mask;
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
    hobject::MegamorphicEntry* me = (hobject::MegamorphicEntry*)base;
    hobject::ICChain* ch = (hobject::ICChain*)base;
    hobject::VarICEntry* vic = (hobject::VarICEntry*)base;
    hobject::CaptureRef* cr = (hobject::CaptureRef*)base;
    hstring::HString* s = (hstring::HString*)base;
    l.ds_act = (char*)&d.act - base;
    l.ds_reg_floor = (char*)&d.reg_floor - base;
    l.ds_enter_sp = (char*)&d.enter_sp - base;
    l.act_this = (char*)&act.this_binding - base;
    l.act_hrc = (char*)&act.heap_reg_count - base;
    l.act_lex_env = (char*)&act.lex_env - base;
    l.act_tv_func = (char*)&act.tv_func - base;
    l.act_func = (char*)&act.func - base;
    l.heap_gc_phase = (char*)&h.gc_phase - base;
    l.heap_gc_kind = (char*)&h.gc_kind - base;
    l.heap_gc_oracle = (char*)&h.gc_oracle_running - base;
    l.heap_shapes = (char*)&h.shapes - base;
    l.heap_epoch = (char*)&h.shape_recycle_epoch - base;
    l.heap_proto_epoch = (char*)&h.prototype_epoch - base;
    l.heap_site_key = (char*)&h.jit_site_key - base;
    l.heap_mega = (char*)&h.mega_cache - base;
    l.heap_string_proto = (char*)&h.string_proto - base;
    l.heap_function_proto = (char*)&h.function_proto - base;
    l.me_key = (char*)&me.key - base;
    l.me_shape = (char*)&me.shape_id - base;
    l.me_idx = (char*)&me.prop_idx - base;
    l.me_proto = (char*)&me.proto - base;
    l.me_proto_shape = (char*)&me.proto_shape_id - base;
    l.me_epoch = (char*)&me.recycle_epoch - base;
    l.me_accessor = (char*)&me.is_accessor - base;
    l.obj_shape = (char*)&o.shape_id - base;
    l.obj_gc = (char*)&o.gc - base;
    l.obj_proto = (char*)&o.prototype - base;
    l.obj_props = (char*)&o.props - base;
    l.obj_prop_count = (char*)&o.prop_count - base;
    l.obj_array_len = (char*)&o.extra.array_length - base;
    l.fn_capture_refs = (char*)&o.extra.func.capture_refs - base;
    l.fn_comp_func = (char*)&o.extra.func.comp_func - base;
    l.gs_getter = (char*)&o.extra.gs.getter - base;
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
    l.chain_absent_epoch = (char*)&ch.absent_epoch - base;
    hobject::ICChainEpoch* ep = (hobject::ICChainEpoch*)(usz)4096;
    l.epoch_value = (char*)&ep.value - (char*)ep;
    l.epoch_current = (char*)&ep.current - (char*)ep;
    l.epoch_first = (char*)&ep.first - (char*)ep;
    l.epoch_owner = (char*)&ep.owner - (char*)ep;
    l.ep_value = (char*)&ch.epoch.value - base;
    l.poly_count = (char*)&ch.poly.count - base;
    l.poly_shapes = (char*)&ch.poly.shapes - base;
    l.poly_idx = (char*)&ch.poly.prop_idx - base;
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
    l.str_refcount = (char*)&s.refcount - base;
    l.view_buffer = (char*)&o.extra.view.buffer - base;
    l.view_offset = (char*)&o.extra.view.byte_offset - base;
    l.view_length = (char*)&o.extra.view.byte_length - base;
    l.ab_data = (char*)&o.extra.ab.data - base;
    l.ab_resizable = (char*)&o.extra.ab.resizable - base;
    l.ab_immutable = (char*)&o.extra.ab.immutable - base;
    l.heap_trigger = (char*)&h.gc_trigger_counter - base;
    l.heap_alloc_since = (char*)&h.gc_alloc_since_begin - base;
    l.heap_live = (char*)&h.live_obj_count - base;
    l.heap_mem_budget = (char*)&h.mem_check_budget - base;
    l.heap_gc_requested = (char*)&h.gc_requested - base;
    l.heap_gray_items = (char*)&h.gc_gray.items - base;
    l.heap_gray_len = (char*)&h.gc_gray.len - base;
    l.heap_gray_cap = (char*)&h.gc_gray.cap - base;
    l.heap_gray_count = (char*)&h.gray_count - base;
    l.heap_marked_count = (char*)&h.marked_obj_count - base;
    l.heap_object_proto = (char*)&h.object_proto - base;
    l.heap_array_proto = (char*)&h.array_proto - base;
    l.heap_realms = (char*)&h.realms - base;
    l.heap_pool_plain = (char*)&h.obj_pool_plain - base;
    l.heap_pool_compact = (char*)&h.obj_pool_compact - base;
    l.heap_pool_shaped = (char*)&h.obj_pool_shaped - base;
    l.heap_pool_arrays = (char*)&h.obj_pool_inline_arrays - base;
    pagepool::ObjectPool* pool = (pagepool::ObjectPool*)base;
    pagepool::ObjPage* page = (pagepool::ObjPage*)base;
    l.pool_size = pagepool::ObjectPool::size;
    l.pool_bump = (char*)&pool.bump - base;
    l.pool_limit = (char*)&pool.limit - base;
    l.pool_block_size = (char*)&pool.block_size - base;
    l.page_mark_epoch = (char*)&page.mark_epoch - base;
    l.page_mark = (char*)&page.mark - base;
    l.page_teardown = (char*)&page.teardown - base;
    l.heap_major_epoch = (char*)&h.gc_major_epoch - base;
    l.heap_alloc_bitmap = (char*)&h.gc_alloc_bitmap - base;
    l.obj_array_used = (char*)&o.array_used - base;
    l.obj_size_array = hobject::OBJ_SIZE_ARRAY;
    hobject::PropValue undef;
    undef.set_undefined();
    l.undefined_bits = *(long*)&undef;

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
    f.constructable = true;
    l.constructable_mask = (long)(uint)f;
    f = {};
    f.extensible = true;
    l.extensible_mask = (long)(uint)f;
    f = {};
    f.has_indexed_named_prop = true;
    l.indexed_named_mask = (long)(uint)f;
    types::GcBits packed = { .packed = true };
    l.packed_mask = (long)(uint)packed;
    f = {};
    f.obj_class = hobject::ObjClass.OBJECT;
    l.class_object = (long)(uint)f;
    f.obj_class = hobject::ObjClass.ARRAY;
    l.class_array = (long)(uint)f;
    f = {};
    f.obj_class = hobject::ObjClass.REGEXP;
    l.class_regexp = (long)(uint)f;
    // The class field is bits 16..21.
    l.class_mask = 0x3FL << 16;
    // emit_typed_body reads the proxy bit and the class as one field.
    assert(l.proxy_mask == 1L << 15);
    // guard_plain tests the class and these flags as one field.
    assert(((l.proxy_mask | l.module_ns_mask | l.deferred_ns_mask) & l.class_mask) == 0);
    assert(l.class_array == (long)hobject::ObjClass.ARRAY.ordinal << 16);
    assert(l.class_regexp == (long)hobject::ObjClass.REGEXP.ordinal << 16);
    types::GcBits g;
    g.old = true;
    l.old_mask = (long)(uint)g;
    g = {};
    g.remembered = true;
    l.remembered_mask = (long)(uint)g;
    $assert heap::GcKind::size == 1 && bool::size == 1;
    g = {};
    g.prototype_observed = true;
    l.proto_observed_mask = (long)(uint)g;
    hobject::PropFlags pf;
    pf.is_accessor = true;
    l.accessor_mask = (long)(char)pf;
    pf = {};
    pf.writable = true;
    l.writable_mask = (long)(char)pf;
    hstring::HStringFlags sf;
    sf.is_symbol = true;
    l.symbol_mask = (long)(uint)sf;
    sf = {};
    sf.is_symbol = true;
    sf.is_wide = true;
    sf.has_extdata = true;
    l.byte_units_mask = (long)(uint)sf;
    sf = {};
    sf.is_interned = true;
    l.interned_mask = (long)(uint)sf;
    sf = {};
    sf.zct_queued = true;
    l.queued_mask = (long)(uint)sf;
    while ((l.interned_mask >> l.interned_shift) != 1) l.interned_shift++;
    // publish orders the two bits.
    assert(l.queued_mask > l.interned_mask);
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
        case GETPROP_CACHE:
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
        case INIT_SLOT:
            return true;
        default:
            return is_var_op(op);
    }
}

// Emit the inline path of an access instruction. False leaves it to the
// thunk.
fn bool Asm.emit_access(&self, bool consts_fixed) {
    CompiledFunction* f = self.f;
    DecodedInsn w = self.w;
    Opcode op = w.op;
    bool has_ic = f.ic_entries != null && f.var_ic_entries != null;
    // The cache entry of the instruction word the operation function sees,
    // the payload of a WIDE pair.
    uint at = self.next - 1;
    long ic = has_ic ? (long)(usz)&((hobject::ICEntry*)f.ic_entries)[at] : 0;
    long vic = has_ic ? (long)(usz)&((hobject::VarICEntry*)f.var_ic_entries)[at] : 0;
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
            // The entry of a constant key holds that key or none (every fill passes the
            // instruction's own), so a filled entry needs no comparison of the key, as GETTHISC's.
            self.emit_get(w.a, ic, (long)(usz)key.get_heapptr(), -1, false, false, key.get_heapptr() == self.length_key);
        case GETPROP:
        case GETPROP_CACHE:
            // GETPROP_CACHE writes its key back coerced, which leaves an
            // integer or string key as it is.
            if (!has_ic) return false;
            // th_getprop_array: an index into an array, or a string key.
            Jumps done;
            self.load(R3, w.c);
            sljit_emit_op2(self.c, SLJIT_XOR, R0, 0, R3, 0, k_int_op(), k_int_w());
            void* not_index = sljit_emit_cmp(self.c, SLJIT_GREATER_EQUAL, R0, 0, span_op(), span_w());
            void* elem = sljit_emit_label(self.c);
            self.emit_get_elem(w.a, w.b);
            done.add(sljit_emit_jump(self.c, SLJIT_JUMP));
            sljit_set_label(not_index, sljit_emit_label(self.c));
            self.index_from_double(elem);
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
            long key_ptr = (long)(usz)key.get_heapptr();
            // `lastIndex` is an ordinary own writable data property even on a
            // RegExp, whose only relevant exotic state is its class; the site
            // entry still guards the key, shape, generation and writability.
            bool regexp_lastindex = key_ptr == (long)(usz)self.hp.strs[heap::BuiltinStr.LAST_INDEX];
            if (op == PUTTHISC) {
                self.load_this(R0);
            } else {
                self.load(R0, w.a);
            }
            self.emit_put(ic, key_ptr, -1, op == PUTTHISC ? w.a : w.b, regexp_lastindex);
        case PUTPROP:
            if (!has_ic) return false;
            // th_putprop: an index into an array, or a string key.
            Jumps done;
            self.load(R3, w.b);
            sljit_emit_op2(self.c, SLJIT_XOR, R0, 0, R3, 0, k_int_op(), k_int_w());
            void* not_index = sljit_emit_cmp(self.c, SLJIT_GREATER_EQUAL, R0, 0, span_op(), span_w());
            void* elem = sljit_emit_label(self.c);
            self.emit_put_elem(w.a, w.c);
            done.add(sljit_emit_jump(self.c, SLJIT_JUMP));
            sljit_set_label(not_index, sljit_emit_label(self.c));
            self.index_from_double(elem);
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
        case INIT_SLOT:
            self.emit_init_slot(w.a, w.b, w.c);
        case GETCAP:
            self.emit_get_cap(w.a, w.get_bc());
        case PUTCAP:
            self.emit_put_cap(w.a, w.get_bc());
        default:
            return self.emit_var_access(has_ic, ic, vic, consts_fixed);
    }
    return true;
}

fn void Asm.load_this(&self, int reg) {
    Layout* l = self.lay;
    sljit_emit_op1(self.c, SLJIT_MOV, reg, 0, SLJIT_MEM | self.la, l.act_this);
}

// dst = the HObject* `src` boxes; the slow path when it is not an object.
fn void Asm.unbox_object(&self, int dst, int src) {
    sljit_emit_op2(self.c, SLJIT_XOR, dst, 0, src, 0, k_obj_op(), k_obj_w());
    self.call.add(sljit_emit_cmp(self.c, SLJIT_GREATER_EQUAL, dst, 0, span_op(), span_w()));
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

// The slow path unless object `obj` is a plain object: class Object and no proxy or namespace
// flag. Uses R2 and R3.
fn void Asm.guard_plain(&self, int obj) {
    Layout* l = self.lay;
    long mask = l.class_mask | l.module_ns_mask | l.deferred_ns_mask;
    $if features::PROXY:
        mask |= l.proxy_mask;
    $endif
    sljit_emit_op1(self.c, SLJIT_MOV_U32, R2, 0, SLJIT_MEM | obj, 0);
    sljit_emit_op2(self.c, SLJIT_AND, R3, 0, R2, 0, SLJIT_IMM, mask);
    self.call.add(sljit_emit_cmp(self.c, SLJIT_NOT_EQUAL, R3, 0, SLJIT_IMM, l.class_object));
}

// dst = the property values of object `obj`, as HObject.prop_values.
fn void Asm.prop_base(&self, int dst, int obj) {
    void* c = self.c;
    Layout* l = self.lay;
    sljit_emit_op1(self.c, SLJIT_MOV, dst, 0, SLJIT_MEM | obj, self.lay.obj_props);
}

// Jump to `to` while incremental marking runs.
fn void Asm.guard_not_marking_to(&self, Jumps* to, int tmp) {
    sljit_emit_op1(self.c, SLJIT_MOV_U8, tmp, 0, SLJIT_MEM | self.heap, self.lay.heap_gc_phase);
    to.add(sljit_emit_cmp(self.c, SLJIT_EQUAL, tmp, 0, SLJIT_IMM, (long)heap::GcPhase.MARK.ordinal));
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
    self.call.add(sljit_emit_cmp(c, SLJIT_LESS, R1, 0, span_op(), span_w()));
    sljit_set_label(plain, sljit_emit_label(c));
}

// Store R0 into register `ra` as th_move and th_publish_read do: an inert
// value is a plain store, and anything else goes through the shared publish
// subroutine. Uses R1 to R3.
fn void Asm.publish(&self, uint ra) {
    void* c = self.c;
    Layout* l = self.lay;
    if (self.early_publish(ra)) {
        // Baseline code stores first, so that an object while the collector is not marking runs
        // on with no taken branch; anything else but an inert value takes the cold path
        // (emit_publish_cold).
        self.store(ra, R0);
        void* inert_early = sljit_emit_cmp(c, SLJIT_LESS, R0, 0, SLJIT_IMM, K_STRING_START);
        Jumps cold;
        sljit_emit_op2(c, SLJIT_XOR, R2, 0, R0, 0, k_obj_op(), k_obj_w());
        cold.add(sljit_emit_cmp(c, SLJIT_GREATER_EQUAL, R2, 0, span_op(), span_w()));
        sljit_emit_op1(c, SLJIT_MOV_U8, R3, 0, SLJIT_MEM | self.heap, l.heap_gc_phase);
        cold.add(sljit_emit_cmp(c, SLJIT_EQUAL, R3, 0, SLJIT_IMM, (long)heap::GcPhase.MARK.ordinal));
        self.track_heap_store(ra);
        void* back = sljit_emit_label(c);
        sljit_set_label(inert_early, back);
        self.add_cold(PUBLISH, back, ra, &cold);
        return;
    }
    void* inert = sljit_emit_cmp(c, SLJIT_LESS, R0, 0, SLJIT_IMM, K_STRING_START);
    // An object while the collector is not marking is the common case: store it
    // and raise the watermark here, as the subroutine does.
    sljit_emit_op2(c, SLJIT_XOR, R2, 0, R0, 0, k_obj_op(), k_obj_w());
    void* not_object = sljit_emit_cmp(c, SLJIT_GREATER_EQUAL, R2, 0, span_op(), span_w());
    sljit_emit_op1(c, SLJIT_MOV_U8, R3, 0, SLJIT_MEM | self.heap, l.heap_gc_phase);
    void* marking = sljit_emit_cmp(c, SLJIT_EQUAL, R3, 0, SLJIT_IMM, (long)heap::GcPhase.MARK.ordinal);
    self.store(ra, R0);
    self.track_heap_store(ra);
    void* done_obj = sljit_emit_jump(c, SLJIT_JUMP);
    sljit_set_label(not_object, sljit_emit_label(c));
    sljit_set_label(marking, sljit_emit_label(c));
    sljit_emit_op1(c, SLJIT_MOV, R1, 0, SLJIT_IMM, ra);
    self.subs.push({ .jump = sljit_emit_jump(c, SLJIT_FAST_CALL), .sub = PUBLISH_SUB });
    self.call.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R2, 0, SLJIT_IMM, 0));
    void* done = sljit_emit_jump(c, SLJIT_JUMP);
    sljit_set_label(inert, sljit_emit_label(c));
    self.store(ra, R0);
    sljit_set_label(done, sljit_emit_label(c));
    sljit_set_label(done_obj, sljit_emit_label(c));
}

// Whether baseline code may store the value it publishes into `ra` before the publish's tests
// (Asm.publish): only where the slow path the publish may take, which runs the instruction again,
// reads no register `ra` overwrites.
fn bool Asm.early_publish(&self, uint ra) {
    if (!self.cold_ok) return false;
    switch (self.w.op) {
        case LDREG:
        case GETPROPC:
        case GETPROPC_CACHED:
            return ra != self.w.b;
        case GETTHISC:
            return true;
        default:
            return false;
    }
}

// The cold path of an early_publish, entered with the heap value R0 stored into `ra` and not an
// object, or any while the collector marks: the register cleared, so that a collection the slow
// path runs never scans a value the publish has not settled, then the publish as such and back.
fn void Asm.emit_publish_cold(&self, uint ra, void* back) {
    self.store(ra, SLJIT_IMM, K_UNDEF);
    self.publish(ra);
    sljit_set_label(sljit_emit_jump(self.c, SLJIT_JUMP), back);
}

// The publish subroutine: store the heap value R0 into the register whose
// index R1 holds, raising the frame's heap-register watermark, and set R2 to
// 0; or set R2 nonzero for the slow path. An object needs no work beyond the
// watermark unless incremental marking still has to mark it; a string needs
// no ZCT entry when
// a counted holder or the queue already has it (Heap.note_unowned).
fn void Asm.emit_publish_body(&self) {
    void* c = self.c;
    Layout* l = self.lay;
    Jumps fail;
    sljit_emit_op2(c, SLJIT_XOR, R2, 0, R0, 0, SLJIT_IMM, K_STRING_START);
    void* not_string = sljit_emit_cmp(c, SLJIT_GREATER_EQUAL, R2, 0, span_op(), span_w());
    // Queued already, or counted beyond the intern table's own count.
    sljit_emit_op1(c, SLJIT_MOV_U32, R3, 0, SLJIT_MEM | R2, l.str_flags);
    sljit_emit_op2(c, SLJIT_AND, R3, 0, R3, 0, SLJIT_IMM, l.interned_mask | l.queued_mask);
    void* queued = sljit_emit_cmp(c, SLJIT_GREATER_EQUAL, R3, 0, SLJIT_IMM, l.queued_mask);
    sljit_emit_op2(c, SLJIT_LSHR, R3, 0, R3, 0, SLJIT_IMM, l.interned_shift);
    sljit_emit_op1(c, SLJIT_MOV_U32, R2, 0, SLJIT_MEM | R2, l.str_refcount);
    fail.add(sljit_emit_cmp(c, SLJIT_LESS_EQUAL, R2, 0, R3, 0));
    void* counted = sljit_emit_jump(c, SLJIT_JUMP);
    sljit_set_label(not_string, sljit_emit_label(c));
    sljit_emit_op2(c, SLJIT_XOR, R2, 0, R0, 0, k_obj_op(), k_obj_w());
    fail.add(sljit_emit_cmp(c, SLJIT_GREATER_EQUAL, R2, 0, span_op(), span_w()));
    Jumps publishable;
    publishable.add(counted);
    publishable.add(queued);
    sljit_emit_op1(c, SLJIT_MOV_U8, R3, 0, SLJIT_MEM | self.heap, l.heap_gc_phase);
    publishable.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R3, 0, SLJIT_IMM, (long)heap::GcPhase.MARK.ordinal));
    // While marking, as th_can_publish: an object the collector has no mark
    // left to give. In a minor that is an old one, marked objects among them;
    // in a major a pooled object whose page bitmap has its mark. Others call.
    publishable.add(sljit_emit_cmp(c, SLJIT_EQUAL, R2, 0, SLJIT_IMM, 0));
    sljit_emit_op1(c, SLJIT_MOV_U8, R3, 0, SLJIT_MEM | self.heap, l.heap_gc_oracle);
    fail.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R3, 0, SLJIT_IMM, 0));
    sljit_emit_op1(c, SLJIT_MOV_U8, R3, 0, SLJIT_MEM | self.heap, l.heap_gc_kind);
    void* major = sljit_emit_cmp(c, SLJIT_EQUAL, R3, 0, SLJIT_IMM, (long)heap::GcKind.MAJOR.ordinal);
    sljit_emit_op1(c, SLJIT_MOV_U32, R3, 0, SLJIT_MEM | R2, l.obj_gc);
    sljit_emit_op2(c, SLJIT_AND, R3, 0, R3, 0, SLJIT_IMM, l.old_mask);
    fail.add(sljit_emit_cmp(c, SLJIT_EQUAL, R3, 0, SLJIT_IMM, 0));
    publishable.add(sljit_emit_jump(c, SLJIT_JUMP));
    sljit_set_label(major, sljit_emit_label(c));
    hobject::ObjFlags fallback;
    fallback.pool_fallback = true;
    sljit_emit_op1(c, SLJIT_MOV_U32, R3, 0, SLJIT_MEM | R2, 0);
    sljit_emit_op2(c, SLJIT_AND, R3, 0, R3, 0, SLJIT_IMM, (long)(uint)fallback);
    fail.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R3, 0, SLJIT_IMM, 0));
    // The page's mark byte for the object: its granule over eight, with the
    // bit the granule's low three bits pick, taken from the value in R0.
    sljit_emit_op2(c, SLJIT_AND, R3, 0, R2, 0, SLJIT_IMM, pagepool::PAGE_SIZE - 1);
    sljit_emit_op2(c, SLJIT_XOR, R2, 0, R2, 0, R3, 0);
    fail.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL | SLJIT_32, SLJIT_MEM | R2, l.page_mark_epoch, SLJIT_MEM | self.heap, l.heap_major_epoch));
    sljit_emit_op2(c, SLJIT_LSHR, R3, 0, R3, 0, SLJIT_IMM, pagepool::GRANULE_SHIFT + 3);
    sljit_emit_op2(c, SLJIT_ADD, R2, 0, R2, 0, SLJIT_IMM, l.page_mark);
    sljit_emit_op1(c, SLJIT_MOV_U8, R2, 0, mem_index(R2, R3), 0);
    sljit_emit_op2(c, SLJIT_LSHR, R3, 0, R0, 0, SLJIT_IMM, pagepool::GRANULE_SHIFT);
    sljit_emit_op2(c, SLJIT_AND, R3, 0, R3, 0, SLJIT_IMM, 7);
    sljit_emit_op2(c, SLJIT_LSHR, R2, 0, R2, 0, R3, 0);
    sljit_emit_op2(c, SLJIT_AND, R2, 0, R2, 0, SLJIT_IMM, 1);
    fail.add(sljit_emit_cmp(c, SLJIT_EQUAL, R2, 0, SLJIT_IMM, 0));
    publishable.bind(sljit_emit_label(c));
    sljit_emit_op1(c, SLJIT_MOV, mem_index(self.regs, R1), 3, R0, 0);
    // track_heap_store
    sljit_emit_op1(c, SLJIT_MOV_U32, R2, 0, SLJIT_MEM | self.la, l.act_hrc);
    void* covered = sljit_emit_cmp(c, SLJIT_GREATER, R2, 0, R1, 0);
    sljit_emit_op2(c, SLJIT_ADD, R2, 0, R1, 0, SLJIT_IMM, 1);
    sljit_emit_op1(c, SLJIT_MOV_U32, SLJIT_MEM | self.la, l.act_hrc, R2, 0);
    sljit_set_label(covered, sljit_emit_label(c));
    sljit_emit_op1(c, SLJIT_MOV, R2, 0, SLJIT_IMM, 0);
    void* ok = sljit_emit_jump(c, SLJIT_JUMP);
    fail.bind(sljit_emit_label(c));
    sljit_emit_op1(c, SLJIT_MOV, R2, 0, SLJIT_IMM, 1);
    sljit_set_label(ok, sljit_emit_label(c));
}

// track_heap_store for slot `ra`, which only a slot beyond the frame's own
// registers needs (Asm.frame_regs). Uses `tmp`.
fn void Asm.track_heap_store(&self, uint ra, int tmp = R2) {
    if (ra < self.frame_regs) return;
    void* c = self.c;
    Layout* l = self.lay;
    sljit_emit_op1(c, SLJIT_MOV_U32, tmp, 0, SLJIT_MEM | self.la, l.act_hrc);
    void* covered = sljit_emit_cmp(c, SLJIT_GREATER, tmp, 0, SLJIT_IMM, ra);
    sljit_emit_op1(c, SLJIT_MOV_U32, SLJIT_MEM | self.la, l.act_hrc, SLJIT_IMM, (long)ra + 1);
    sljit_set_label(covered, sljit_emit_label(c));
}

// LDREG as th_ldreg and th_move, through the publish; a string in a
// register is counted or queued already, so only an unqueued one, a BigInt,
// or a traced value while marking takes the slow path.
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
    if (length) {
        // A string or an array takes its length out of line (emit_length).
        sljit_emit_op2(c, SLJIT_XOR, R1, 0, R0, 0, k_obj_op(), k_obj_w());
        self.alt.add(sljit_emit_cmp(c, SLJIT_GREATER_EQUAL, R1, 0, span_op(), span_w()));
    } else if (key != 0 && !((hstring::HString*)key).is_arridx()) {
        // A string primitive reads through String.prototype, whose entry the
        // site holds (th_getpropc); a symbol and any other value go to the thunk.
        sljit_emit_op2(c, SLJIT_XOR, R1, 0, R0, 0, k_obj_op(), k_obj_w());
        if (self.cold_ok) {
            // Baseline code takes the string out of line (emit_string_receiver), and an object
            // falls through.
            Jumps other;
            other.add(sljit_emit_cmp(c, SLJIT_GREATER_EQUAL, R1, 0, span_op(), span_w()));
            self.add_cold(STRING_RECEIVER, sljit_emit_label(c), 0, &other);
        } else {
            void* object = sljit_emit_cmp(c, SLJIT_LESS, R1, 0, span_op(), span_w());
            self.emit_string_receiver();
            sljit_set_label(object, sljit_emit_label(c));
        }
    } else {
        self.unbox_object(R1, R0);
    }
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
        self.alt.add(sljit_emit_cmp(c, SLJIT_EQUAL, R2, 0, SLJIT_IMM, l.class_array));
    }
    sljit_emit_op1(c, SLJIT_MOV, R2, 0, SLJIT_IMM, ic);
    sljit_emit_op1(c, SLJIT_MOV_U32, R3, 0, SLJIT_MEM | R1, l.obj_shape);
    if (key_reg >= 0) {
        // Another string key takes the keyed read out of line (emit_get_keyed).
        self.load(R4, (uint)key_reg);
        sljit_emit_op2(c, SLJIT_XOR, R4, 0, R4, 0, SLJIT_IMM, K_STRING_START);
        self.call.add(sljit_emit_cmp(c, SLJIT_GREATER_EQUAL, R4, 0, span_op(), span_w()));
        self.alt.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R4, 0, SLJIT_MEM | R2, l.ic_key));
    } else if (check_key) {
        self.call.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, SLJIT_MEM | R2, l.ic_key, SLJIT_IMM, key));
    } else {
        self.call.add(sljit_emit_cmp(c, SLJIT_EQUAL, SLJIT_MEM | R2, l.ic_key, SLJIT_IMM, 0));
    }
    self.poly.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL | SLJIT_32, R3, 0, SLJIT_MEM | R2, l.ic_shape));
    // Baseline code tests the accessor bit, chain_len and has_proto together, and takes the kind
    // of property the entry names as the code is made with no branch: an inherited data property
    // an epoch describes (a method, most often), or else an own data property. Any other entry
    // takes the cold path (emit_get_cold).
    long chain_shift = (l.ic_chain_len - l.ic_flags) * 8;
    long has_proto_shift = (l.ic_has_proto - l.ic_flags) * 8;
    if (self.cold_ok && !std::core::env::BIG_ENDIAN && (l.ic_flags & 3) == 0 && chain_shift > 0
        && has_proto_shift > 0 && has_proto_shift < 32) {
        hobject::ICEntry* e = (hobject::ICEntry*)ic;
        bool inherited = e.has_proto && e.chain_len == hobject::IC_CHAIN_EPOCH && !e.prop_flags.is_accessor;
        Jumps cold;
        sljit_emit_op1(c, SLJIT_MOV_U32, R0, 0, SLJIT_MEM | R2, l.ic_flags);
        if (inherited) {
            $assert bool::size == 1;
            sljit_emit_op2(c, SLJIT_AND, R0, 0, R0, 0, SLJIT_IMM, l.accessor_mask | 0xFFL << chain_shift | 0xFFL << has_proto_shift);
            cold.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R0, 0, SLJIT_IMM,
                                    (long)hobject::IC_CHAIN_EPOCH << chain_shift | 1L << has_proto_shift));
            self.emit_epoch_owner(&self.poly);
        } else {
            sljit_emit_op2u(c, SLJIT_AND | SLJIT_SET_Z, R0, 0, SLJIT_IMM, l.accessor_mask | 0xFFL << has_proto_shift);
            cold.add(sljit_emit_jump(c, SLJIT_NOT_EQUAL));
        }
        self.add_cold(inherited ? GET_INHERITED : GET, sljit_emit_label(c), ic, &cold);
    } else {
        self.emit_get_kinds(ra, ic, &self.poly);
    }
    sljit_emit_op1(c, SLJIT_MOV_U32, R3, 0, SLJIT_MEM | R2, l.ic_idx);
    self.poly_back = sljit_emit_label(c);
    self.prop_base(R0, R1);
    sljit_emit_op1(c, SLJIT_MOV, R0, 0, mem_index(R0, R3), 3);
    self.publish(ra);
}

// A cached read's receiver R0 that is not an object (emit_get): a string reads through
// String.prototype, whose entry the site holds (th_getpropc), into R1; a symbol and any other value
// go to the thunk.
fn void Asm.emit_string_receiver(&self) {
    void* c = self.c;
    Layout* l = self.lay;
    sljit_emit_op2(c, SLJIT_XOR, R1, 0, R0, 0, SLJIT_IMM, K_STRING_START);
    self.call.add(sljit_emit_cmp(c, SLJIT_GREATER_EQUAL, R1, 0, span_op(), span_w()));
    self.guard_flags_clear(R1, l.symbol_mask, R2);
    sljit_emit_op1(c, SLJIT_MOV, R1, 0, SLJIT_MEM | self.heap, l.heap_string_proto);
}

// A cached read's entry `ic` (in R2, the receiver in R1, its shape matched) for anything but an own
// data property: an accessor's getter call or the thunk, an absent read to `poly`, and an inherited
// data property's owner into R1, after which the read continues.
fn void Asm.emit_get_kinds(&self, uint ra, long ic, Jumps* poly) {
    void* c = self.c;
    Layout* l = self.lay;
    sljit_emit_op1(c, SLJIT_MOV_U8, R0, 0, SLJIT_MEM | R2, l.ic_flags);
    sljit_emit_op2(c, SLJIT_AND, R0, 0, R0, 0, SLJIT_IMM, l.accessor_mask);
    // An absent read (whose entry carries the accessor bit as its marker)
    // goes to the arm, whose helper settles it: the arm's caches and chain
    // walk only ever find data properties.
    void* data = sljit_emit_cmp(c, SLJIT_EQUAL, R0, 0, SLJIT_IMM, 0);
    sljit_emit_op1(c, SLJIT_MOV_U32, R0, 0, SLJIT_MEM | R2, l.ic_idx);
    poly.add(sljit_emit_cmp(c, SLJIT_GREATER_EQUAL | SLJIT_32, R0, 0, SLJIT_IMM, (long)hobject::IC_PROP_MISSING));
    if (self.getter_site(ra)) {
        self.emit_getter_call(ra, ic);
    } else {
        // An accessor the entry names for this shape goes to the thunk.
        self.call.add(sljit_emit_jump(c, SLJIT_JUMP));
    }
    sljit_set_label(data, sljit_emit_label(c));
    self.emit_ic_owner(ic, poly);
}

// The cold path of a cached read (Asm.emit_get), out of line with the instruction's other stubs,
// for an entry `ic` (in R2) with the accessor bit or has_proto, or with `own` any entry: an own
// data property straight back to the read at `back`, then emit_get_kinds laid out so that an
// inherited data property an epoch describes runs straight back too, with the owner in R1 and the
// entry in R2. An absent read joins `poly`.
fn void Asm.emit_get_cold(&self, long ic, void* back, Jumps* poly, bool own) {
    void* c = self.c;
    Layout* l = self.lay;
    if (own) {
        // The read's inline path took an inherited property: an own data property reads the
        // receiver itself.
        sljit_emit_op1(c, SLJIT_MOV_U8, R0, 0, SLJIT_MEM | R2, l.ic_flags);
        sljit_emit_op2(c, SLJIT_AND, R0, 0, R0, 0, SLJIT_IMM, l.accessor_mask);
        void* accessor = sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R0, 0, SLJIT_IMM, 0);
        sljit_emit_op1(c, SLJIT_MOV_U8, R0, 0, SLJIT_MEM | R2, l.ic_has_proto);
        sljit_set_label(sljit_emit_cmp(c, SLJIT_EQUAL, R0, 0, SLJIT_IMM, 0), back);
        sljit_set_label(accessor, sljit_emit_label(c));
    }
    sljit_emit_op1(c, SLJIT_MOV_U8, R0, 0, SLJIT_MEM | R2, l.ic_flags);
    sljit_emit_op2u(c, SLJIT_AND | SLJIT_SET_Z, R0, 0, SLJIT_IMM, l.accessor_mask);
    void* accessor = sljit_emit_jump(c, SLJIT_NOT_EQUAL);
    // A data property, so has_proto is set: inherited.
    sljit_emit_op1(c, SLJIT_MOV_U8, R0, 0, SLJIT_MEM | R2, l.ic_chain_len);
    void* general = sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R0, 0, SLJIT_IMM, (long)hobject::IC_CHAIN_EPOCH & 0xFF);
    self.emit_epoch_owner(poly);
    sljit_set_label(sljit_emit_jump(c, SLJIT_JUMP), back);
    sljit_set_label(general, sljit_emit_label(c));
    self.emit_owner_helper(ic);
    sljit_set_label(sljit_emit_jump(c, SLJIT_JUMP), back);
    // An accessor, or an absent read (whose entry carries the accessor bit as its marker).
    sljit_set_label(accessor, sljit_emit_label(c));
    sljit_emit_op1(c, SLJIT_MOV_U32, R0, 0, SLJIT_MEM | R2, l.ic_idx);
    poly.add(sljit_emit_cmp(c, SLJIT_GREATER_EQUAL | SLJIT_32, R0, 0, SLJIT_IMM, (long)hobject::IC_PROP_MISSING));
    if (self.getter_site(self.w.a)) {
        self.emit_getter_call(self.w.a, ic);
    } else {
        self.call.add(sljit_emit_jump(c, SLJIT_JUMP));
    }
}

// The owner of the property entry `ic` names for the receiver in R1 (whose
// shape the site has matched), into R1 with the entry in R2: the receiver
// itself, or a prototype owner resolved as ic_resolve_slot does. An epoch
// entry is replayed inline (ic_resolve_owner's epoch case: a plain receiver
// whose prototype is the recorded first link and no prototype mutation
// since); a receiver it does not describe takes `other`. Any other chain
// takes the helper, and a chain it no longer validates the thunk.
fn void Asm.emit_ic_owner(&self, long ic, Jumps* other) {
    void* c = self.c;
    Layout* l = self.lay;
    sljit_emit_op1(c, SLJIT_MOV_U8, R0, 0, SLJIT_MEM | R2, l.ic_has_proto);
    void* own = sljit_emit_cmp(c, SLJIT_EQUAL, R0, 0, SLJIT_IMM, 0);
    sljit_emit_op1(c, SLJIT_MOV_U8, R0, 0, SLJIT_MEM | R2, l.ic_chain_len);
    void* general = sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R0, 0, SLJIT_IMM, (long)hobject::IC_CHAIN_EPOCH & 0xFF);
    self.emit_epoch_owner(other);
    void* resolved = sljit_emit_jump(c, SLJIT_JUMP);
    sljit_set_label(general, sljit_emit_label(c));
    self.emit_owner_helper(ic);
    sljit_set_label(resolved, sljit_emit_label(c));
    sljit_set_label(own, sljit_emit_label(c));
}

// An epoch entry's replay (emit_ic_owner) for the entry in R2 and the receiver in R1: the owner
// into R1, or `other`. Clobbers R0 and R4.
fn void Asm.emit_epoch_owner(&self, Jumps* other) {
    void* c = self.c;
    Layout* l = self.lay;
    sljit_emit_op1(c, SLJIT_MOV, R4, 0, SLJIT_MEM | R2, l.ic_chain);
    sljit_emit_op1(c, SLJIT_MOV_U32, R0, 0, SLJIT_MEM | R1, 0);
    sljit_emit_op2(c, SLJIT_AND, R0, 0, R0, 0, SLJIT_IMM, l.class_mask | l.plain_exotic_mask);
    other.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R0, 0, SLJIT_IMM, l.class_object));
    sljit_emit_op1(c, SLJIT_MOV, R0, 0, SLJIT_MEM | R1, l.obj_proto);
    other.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R0, 0, SLJIT_MEM | R4, l.epoch_first));
    // The epoch an entry records is always the heap's (vm::ic_fill_read_heap), and its owner,
    // like every link, a plain property object (hobject::plain_property_object): no proxy.
    sljit_emit_op1(c, SLJIT_MOV, R0, 0, SLJIT_MEM | self.heap, l.heap_proto_epoch);
    other.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R0, 0, SLJIT_MEM | R4, l.epoch_value));
    sljit_emit_op1(c, SLJIT_MOV, R1, 0, SLJIT_MEM | R4, l.epoch_owner);
}

// The owner of any other chain through vm::jit_ic_owner, for the entry `ic` (in R2) and the
// receiver in R1: into R1 with the entry back in R2, or the thunk when the chain no longer holds.
fn void Asm.emit_owner_helper(&self, long ic) {
    void* c = self.c;
    sljit_emit_op1(c, SLJIT_MOV, R0, 0, R2, 0);
    self.c_call(SLJIT_ARGS2WWW, SLJIT_IMM, (long)(usz)&vm::jit_ic_owner);
    self.call.add(sljit_emit_cmp(c, SLJIT_EQUAL, R0, 0, SLJIT_IMM, 0));
    sljit_emit_op1(c, SLJIT_MOV, R1, 0, R0, 0);
    sljit_emit_op1(c, SLJIT_MOV, R2, 0, SLJIT_IMM, ic);
}

// Whether the read being emitted into `ra` calls a getter its entry names
// natively, as th_call_getter does: GETTHISC, whose receiver the frame roots,
// or GETPROPC(_CACHED) of a receiver register below `ra`, which the getter's
// frame (from ra + 2 up, over registers dead past the read) leaves intact for
// the thunk a declined call falls back to. An optimized body's GENERIC read
// reloads every live value after it, as after a GENERIC call.
fn bool Asm.getter_site(&self, uint ra) {
    if (ra + 1 >= self.f.num_regs) return false;
    switch (self.w.op) {
        case GETTHISC: return true;
        case GETPROPC:
        case GETPROPC_CACHED: return self.w.b < ra;
        default: return false;
    }
}

// The getter call of a getter_site whose entry (R2, its slot index in R0
// below IC_PROP_MISSING) names an accessor for the receiver's shape (the
// object in R1): the getter into `ra`, the receiver into ra + 1, and a
// method call with no arguments through the shared call subroutine, whose
// result lands in `ra`; then on to the next instruction. A getter the
// subroutine does not enter (a builtin, an undefined getter, a callee
// without an entry, a primitive receiver of one reading `this`) takes the
// thunk, which reads the receiver again and runs it. CALL_GETTER keeps the
// subroutine from noting the callee in the entry, which names the property.
fn void Asm.emit_getter_call(&self, uint ra, long ic) {
    void* c = self.c;
    Layout* l = self.lay;
    self.emit_ic_owner(ic, &self.call);
    sljit_emit_op1(c, SLJIT_MOV_U32, R3, 0, SLJIT_MEM | R2, l.ic_idx);
    self.prop_base(R0, R1);
    sljit_emit_op1(c, SLJIT_MOV, R0, 0, mem_index(R0, R3), 3);
    self.unbox_object(R0, R0);
    sljit_emit_op1(c, SLJIT_MOV, R0, 0, SLJIT_MEM | R0, l.gs_getter);
    if (self.w.op == Opcode.GETTHISC) {
        self.load_this(R1);
    } else {
        self.load(R1, self.w.b);
    }
    // Plain stores, as th_call_getter makes them: the getter is reachable
    // from its owner and the receiver from its register or the frame.
    self.store(ra + 1, R1);
    self.store(ra, R0);
    self.track_heap_store(ra + 1);
    self.mov(R3, 0, SLJIT_IMM, CALL_METHOD | CALL_GETTER);
    self.emit_call_sub(ra, ra, self.next, &self.call);
    self.go(sljit_emit_jump(c, SLJIT_JUMP), self.next);
}

// Another receiver shape at a read site, as th_get_other_shape and
// ic_poly_slot: an own data read of the entry's polymorphic set. Entered with
// the receiver in R1, its shape in R3 and the entry in R2; continues at
// `back` with the slot index in R3.
fn void Asm.emit_poly_arm(&self, void* back) {
    void* c = self.c;
    self.subs.push({ .jump = sljit_emit_jump(c, SLJIT_FAST_CALL), .sub = POLY_SUB });
    void* missed = sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R2, 0, SLJIT_IMM, SUB_TRUE);
    self.count(&self.stats.poly_hits[0], self.w.op);
    sljit_set_label(sljit_emit_jump(c, SLJIT_JUMP), back);
    sljit_set_label(missed, sljit_emit_label(c));
    if (self.w.op == Opcode.GETPROPC || self.w.op == Opcode.GETPROPC_CACHED || self.w.op == Opcode.GETTHISC) {
        // The receiver is still in R1 (the poly subroutine keeps it).
        sljit_emit_op1(c, SLJIT_MOV, R2, 0, SLJIT_IMM, (long)(usz)&((hobject::ICEntry*)self.f.ic_entries)[self.next - 1]);
        self.subs.push({ .jump = sljit_emit_jump(c, SLJIT_FAST_CALL), .sub = MEGA_SUB });
        void* cached = sljit_emit_cmp(c, SLJIT_EQUAL, R2, 0, SLJIT_IMM, SUB_TRUE);
        // The cache has no entry: the helper reads the data property and notes
        // it there, as the switch's lookup does.
        sljit_emit_op1(c, SLJIT_MOV, R2, 0, SLJIT_IMM, (long)(usz)&((hobject::ICEntry*)self.f.ic_entries)[self.next - 1]);
        sljit_emit_op1(c, SLJIT_MOV, R3, 0, R2, 0);
        sljit_emit_op1(c, SLJIT_MOV, R2, 0, SLJIT_MEM | R2, self.lay.ic_key);
        sljit_emit_op1(c, SLJIT_MOV, R0, 0, self.heap, 0);
        self.c_call(SLJIT_ARGS4WWWW, SLJIT_IMM, (long)(usz)&vm::jit_get_missed);
        self.call.add(sljit_emit_cmp(c, SLJIT_EQUAL, R0, 0, SLJIT_IMM, 0));
        sljit_emit_op1(c, SLJIT_MOV, R0, 0, SLJIT_MEM | R0, 0);
        void* published = sljit_emit_jump(c, SLJIT_JUMP);
        // A hit of the megamorphic cache, which another site may have filled, still joins the
        // receiver's shape to this entry's polymorphic set (vm::jit_poly_note). The sub kept the
        // receiver at SUB_VALUE_OFF.
        sljit_set_label(cached, sljit_emit_label(c));
        sljit_emit_op1(c, SLJIT_MOV, R3, 0, R0, 0);
        // jit_poly_note changes nothing for an entry that names a prototype owner or whose
        // polymorphic set is full, which is most of its calls: the checks run here.
        sljit_emit_op1(c, SLJIT_MOV, R2, 0, SLJIT_IMM, (long)(usz)&((hobject::ICEntry*)self.f.ic_entries)[self.next - 1]);
        Jumps no_note;
        sljit_emit_op1(c, SLJIT_MOV_U8, R0, 0, SLJIT_MEM | R2, self.lay.ic_has_proto);
        no_note.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R0, 0, SLJIT_IMM, 0));
        sljit_emit_op1(c, SLJIT_MOV_U8, R0, 0, SLJIT_MEM | R2, self.lay.ic_chain_len);
        void* not_poly = sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R0, 0, SLJIT_IMM, (long)hobject::IC_CHAIN_POLY & 0xFF);
        sljit_emit_op1(c, SLJIT_MOV, R0, 0, SLJIT_MEM | R2, self.lay.ic_chain);
        sljit_emit_op1(c, SLJIT_MOV_U32, R0, 0, SLJIT_MEM | R0, 0);
        no_note.add(sljit_emit_cmp(c, SLJIT_EQUAL, R0, 0, SLJIT_IMM, (long)hobject::IC_POLY_MAX));
        sljit_set_label(not_poly, sljit_emit_label(c));
        self.mov(R1, 0, SLJIT_MEM | reg_sp(), SUB_VALUE_OFF);
        sljit_emit_op1(c, SLJIT_MOV, R0, 0, self.heap, 0);
        self.c_call(SLJIT_ARGS4WWWW, SLJIT_IMM, (long)(usz)&vm::jit_poly_note);
        void* noted = sljit_emit_jump(c, SLJIT_JUMP);
        no_note.bind(sljit_emit_label(c));
        sljit_emit_op1(c, SLJIT_MOV, R0, 0, R3, 0);
        sljit_set_label(noted, sljit_emit_label(c));
        sljit_set_label(published, sljit_emit_label(c));
        self.publish(self.w.a);
        self.go(sljit_emit_jump(c, SLJIT_JUMP), self.next);
    } else {
        self.call.add(sljit_emit_jump(c, SLJIT_JUMP));
    }
}

// The megamorphic cache subroutine, as hobject::mega_cache_lookup for a read
// th_get_shared would answer with a data property: R1 the receiver (a plain
// object), R2 its read entry (whose key the site has matched). R2 is SUB_TRUE
// with the value in R0, or SUB_FALSE with R1 intact. Uses R0 to R4.
fn void Asm.emit_mega_body(&self) {
    void* c = self.c;
    Layout* l = self.lay;
    int m = SLJIT_MEM;
    int sp = m | reg_sp();
    self.mov(sp, SUB_VALUE_OFF, R1, 0);
    const long HASH_SHAPE = 2654435761;
    const long HASH_PROTO = 2246822519;
    Jumps miss;
    // A plain object: th_get_shared's mega_cacheable, narrowed as the epoch case is.
    sljit_emit_op1(c, SLJIT_MOV_U32, R0, 0, m | R1, 0);
    sljit_emit_op2(c, SLJIT_AND, R0, 0, R0, 0, SLJIT_IMM, l.class_mask | l.plain_exotic_mask);
    miss.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R0, 0, SLJIT_IMM, l.class_object));
    sljit_emit_op1(c, SLJIT_MOV_U32, R3, 0, m | R1, l.obj_shape);
    sljit_emit_op1(c, SLJIT_MOV, R2, 0, m | R2, l.ic_key);
    sljit_emit_op1(c, SLJIT_MOV, R4, 0, m | self.heap, l.heap_mega);
    miss.add(sljit_emit_cmp(c, SLJIT_EQUAL, R4, 0, SLJIT_IMM, 0));
    // The own entry, hashed by key and shape.
    sljit_emit_op2(c, SLJIT_MUL | SLJIT_32, R0, 0, R3, 0, SLJIT_IMM, HASH_SHAPE);
    sljit_emit_op2(c, SLJIT_XOR | SLJIT_32, R0, 0, R0, 0, R2, 0);
    sljit_emit_op2(c, SLJIT_AND, R0, 0, R0, 0, SLJIT_IMM, heap::MEGA_CACHE_SIZE - 1);
    sljit_emit_op2(c, SLJIT_MUL, R0, 0, R0, 0, SLJIT_IMM, (long)hobject::MegamorphicEntry::size);
    sljit_emit_op2(c, SLJIT_ADD, R0, 0, R0, 0, R4, 0);
    Jumps own_miss;
    own_miss.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R2, 0, m | R0, l.me_key));
    own_miss.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL | SLJIT_32, R3, 0, m | R0, l.me_shape));
    own_miss.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, m | R0, l.me_proto, SLJIT_IMM, 0));
    sljit_emit_op1(c, SLJIT_MOV_U32, R4, 0, m | R0, l.me_epoch);
    miss.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL | SLJIT_32, R4, 0, m | self.heap, l.heap_epoch));
    sljit_emit_op1(c, SLJIT_MOV_U8, R4, 0, m | R0, l.me_accessor);
    miss.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R4, 0, SLJIT_IMM, 0));
    sljit_emit_op1(c, SLJIT_MOV_U32, R3, 0, m | R0, l.me_idx);
    self.prop_base(R0, R1);
    sljit_emit_op1(c, SLJIT_MOV, R0, 0, mem_index(R0, R3), 3);
    Jumps hit;
    hit.add(sljit_emit_jump(c, SLJIT_JUMP));
    // The entry for a property of the receiver's prototype, which also hashes it.
    own_miss.bind(sljit_emit_label(c));
    sljit_emit_op1(c, SLJIT_MOV, R4, 0, m | R1, l.obj_proto);
    miss.add(sljit_emit_cmp(c, SLJIT_EQUAL, R4, 0, SLJIT_IMM, 0));
    sljit_emit_op2(c, SLJIT_MUL | SLJIT_32, R0, 0, R3, 0, SLJIT_IMM, HASH_SHAPE);
    sljit_emit_op2(c, SLJIT_XOR | SLJIT_32, R0, 0, R0, 0, R2, 0);
    sljit_emit_op1(c, SLJIT_MOV_U32, R1, 0, R4, 0);
    sljit_emit_op2(c, SLJIT_LSHR | SLJIT_32, R1, 0, R1, 0, SLJIT_IMM, 4);
    sljit_emit_op2(c, SLJIT_MUL | SLJIT_32, R1, 0, R1, 0, SLJIT_IMM, HASH_PROTO);
    sljit_emit_op2(c, SLJIT_XOR | SLJIT_32, R0, 0, R0, 0, R1, 0);
    sljit_emit_op2(c, SLJIT_AND, R0, 0, R0, 0, SLJIT_IMM, heap::MEGA_CACHE_SIZE - 1);
    sljit_emit_op2(c, SLJIT_MUL, R0, 0, R0, 0, SLJIT_IMM, (long)hobject::MegamorphicEntry::size);
    sljit_emit_op2(c, SLJIT_ADD, R0, 0, R0, 0, m | self.heap, l.heap_mega);
    miss.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R2, 0, m | R0, l.me_key));
    miss.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL | SLJIT_32, R3, 0, m | R0, l.me_shape));
    miss.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R4, 0, m | R0, l.me_proto));
    sljit_emit_op1(c, SLJIT_MOV_U32, R1, 0, m | R0, l.me_epoch);
    miss.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL | SLJIT_32, R1, 0, m | self.heap, l.heap_epoch));
    sljit_emit_op1(c, SLJIT_MOV_U32, R1, 0, m | R4, l.obj_shape);
    miss.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL | SLJIT_32, R1, 0, m | R0, l.me_proto_shape));
    sljit_emit_op1(c, SLJIT_MOV_U8, R1, 0, m | R0, l.me_accessor);
    miss.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R1, 0, SLJIT_IMM, 0));
    sljit_emit_op1(c, SLJIT_MOV_U32, R3, 0, m | R0, l.me_idx);
    self.prop_base(R0, R4);
    sljit_emit_op1(c, SLJIT_MOV, R0, 0, mem_index(R0, R3), 3);
    hit.bind(sljit_emit_label(c));
    sljit_emit_op1(c, SLJIT_MOV, R2, 0, SLJIT_IMM, SUB_TRUE);
    void* done = sljit_emit_jump(c, SLJIT_JUMP);
    miss.bind(sljit_emit_label(c));
    self.mov(R1, 0, sp, SUB_VALUE_OFF);
    sljit_emit_op1(c, SLJIT_MOV, R2, 0, SLJIT_IMM, SUB_FALSE);
    sljit_set_label(done, sljit_emit_label(c));
}

// A computed read whose string key is not the site entry's, as th_getprop
// reaches the switch for it: an own or inherited data property of a plain
// object, or undefined for a key absent from the chain, found by the helper
// without disturbing the entry.
fn void Asm.emit_get_keyed(&self, uint ra, uint rb, uint rkey) {
    void* c = self.c;
    self.load(R2, rkey);
    sljit_emit_op2(c, SLJIT_XOR, R2, 0, R2, 0, SLJIT_IMM, K_STRING_START);
    self.load(R1, rb);
    sljit_emit_op2(c, SLJIT_XOR, R1, 0, R1, 0, k_obj_op(), k_obj_w());
    sljit_emit_op1(c, SLJIT_MOV, R3, 0, SLJIT_IMM, 0);
    sljit_emit_op1(c, SLJIT_MOV, R0, 0, self.heap, 0);
    self.c_call(SLJIT_ARGS4WWWW, SLJIT_IMM, (long)(usz)&vm::jit_get_missed);
    self.call.add(sljit_emit_cmp(c, SLJIT_EQUAL, R0, 0, SLJIT_IMM, 0));
    sljit_emit_op1(c, SLJIT_MOV, R0, 0, SLJIT_MEM | R0, 0);
    self.publish(ra);
}

// The polymorphic set subroutine: R2 SUB_TRUE with the slot index of shape R3
// in R3 when entry R2's set holds the shape, whose shapes are distinct, and
// SUB_FALSE otherwise. Uses R0.
fn void Asm.emit_poly_body(&self) {
    void* c = self.c;
    Layout* l = self.lay;
    Jumps miss;
    sljit_emit_op1(c, SLJIT_MOV_U8, R0, 0, SLJIT_MEM | R2, l.ic_chain_len);
    miss.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R0, 0, SLJIT_IMM, (long)(char)hobject::IC_CHAIN_POLY));
    sljit_emit_op1(c, SLJIT_MOV, R2, 0, SLJIT_MEM | R2, l.ic_chain);
    sljit_emit_op1(c, SLJIT_MOV_U32, R0, 0, SLJIT_MEM | R2, l.poly_count);
    sljit_emit_op2(c, SLJIT_ADD, R2, 0, R2, 0, SLJIT_IMM, l.poly_shapes);
    void* next_arm = sljit_emit_label(c);
    miss.add(sljit_emit_cmp(c, SLJIT_EQUAL, R0, 0, SLJIT_IMM, 0));
    sljit_emit_op2(c, SLJIT_SUB, R0, 0, R0, 0, SLJIT_IMM, 1);
    sljit_set_label(sljit_emit_cmp(c, SLJIT_NOT_EQUAL | SLJIT_32, mem_index(R2, R0), 2, R3, 0), next_arm);
    sljit_emit_op2(c, SLJIT_ADD, R2, 0, R2, 0, SLJIT_IMM, l.poly_idx - l.poly_shapes);
    sljit_emit_op1(c, SLJIT_MOV_U32, R3, 0, mem_index(R2, R0), 2);
    sljit_emit_op1(c, SLJIT_MOV, R2, 0, SLJIT_IMM, SUB_TRUE);
    void* done = sljit_emit_jump(c, SLJIT_JUMP);
    miss.bind(sljit_emit_label(c));
    sljit_emit_op1(c, SLJIT_MOV, R2, 0, SLJIT_IMM, SUB_FALSE);
    sljit_set_label(done, sljit_emit_label(c));
}

// The length of the string or array register `rb` holds, as th_getpropc
// reads it before the cache; anything else takes the slow path.
fn void Asm.emit_length(&self, uint ra, uint rb) {
    void* c = self.c;
    Layout* l = self.lay;
    self.load(R0, rb);
    sljit_emit_op2(c, SLJIT_XOR, R1, 0, R0, 0, SLJIT_IMM, K_STRING_START);
    void* not_string = sljit_emit_cmp(c, SLJIT_GREATER_EQUAL, R1, 0, span_op(), span_w());
    self.guard_flags_clear(R1, l.symbol_mask, R2);
    sljit_emit_op1(c, SLJIT_MOV_U32, R0, 0, SLJIT_MEM | R1, l.str_length);
    void* store = sljit_emit_jump(c, SLJIT_JUMP);
    sljit_set_label(not_string, sljit_emit_label(c));
    self.unbox_object(R1, R0);
    // The class test excludes a proxy, which has a class of its own.
    sljit_emit_op1(c, SLJIT_MOV_U32, R2, 0, SLJIT_MEM | R1, 0);
    sljit_emit_op2(c, SLJIT_AND, R2, 0, R2, 0, SLJIT_IMM, l.class_mask);
    self.call.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R2, 0, SLJIT_IMM, l.class_array));
    sljit_emit_op1(c, SLJIT_MOV_U32, R0, 0, SLJIT_MEM | R1, l.obj_array_len);
    sljit_set_label(store, sljit_emit_label(c));
    sljit_emit_op2(c, SLJIT_OR, R0, 0, R0, 0, k_int_op(), k_int_w());
    self.store(ra, R0);
}

// The slow path unless object `obj`'s shape is the one entry `ic` (in its
// register) holds. Uses R0 and R3.
fn void Asm.guard_shape(&self, int obj, int ic, Jumps* miss = null) {
    Layout* l = self.lay;
    if (!miss) miss = &self.call;
    sljit_emit_op1(self.c, SLJIT_MOV_U32, R3, 0, SLJIT_MEM | obj, l.obj_shape);
    sljit_emit_op1(self.c, SLJIT_MOV_U32, R0, 0, SLJIT_MEM | ic, l.ic_shape);
    miss.add(sljit_emit_cmp(self.c, SLJIT_NOT_EQUAL, R3, 0, R0, 0));
}

// Store register `rv` into the slot at R0, owned by the object in R1, as the
// non-heap case of th_put_cached extended to objects: the old value must not
// be counted, and an object value needs no barrier work (not marking, and an
// owner that is not old). Uses R2 and R3.
fn void Asm.store_slot(&self, uint rv) {
    self.guard_old_value();
    self.store_value(rv);
}

// store_slot for a value that stays in register `rv`: what needs a count or a
// barrier takes the counted and traced store of th_store_slot_ref instead of
// the slow path. Uses R0 to R3.
fn void Asm.store_slot_counted(&self, uint rv) {
    Jumps counted;
    self.guard_old_value(&counted);
    self.store_value_counted(rv, &counted);
}

// store_value into the slot at R0 of the object in R1, where the store
// store_value declines (jumps to `counted`, which the caller may have added
// to) takes the counted and traced store of th_store_slot_ref. Uses R0 to R3.
fn void Asm.store_value_counted(&self, uint rv, Jumps* counted) {
    void* c = self.c;
    self.store_value(rv, counted);
    void* done = sljit_emit_jump(c, SLJIT_JUMP);
    counted.bind(sljit_emit_label(c));
    sljit_emit_op2(c, SLJIT_ADD, R3, 0, self.regs, 0, SLJIT_IMM, (long)rv * TVal::size);
    sljit_emit_op1(c, SLJIT_MOV, R2, 0, R0, 0);
    sljit_emit_op1(c, SLJIT_MOV, R0, 0, self.heap, 0);
    self.c_call(SLJIT_ARGS4WWWW, SLJIT_IMM, (long)(usz)&vm::jit_store_slot);
    sljit_set_label(done, sljit_emit_label(c));
}

// Jump to `miss` (the slow path by default) unless the value in the slot at R0
// can be overwritten without work: a number or other inert value, or an
// object, which `object_first` expects. Uses R3.
fn void Asm.guard_old_value(&self, Jumps* miss = null, bool object_first = false) {
    void* c = self.c;
    if (!miss) miss = &self.call;
    sljit_emit_op1(c, SLJIT_MOV, R3, 0, SLJIT_MEM | R0, 0);
    if (object_first) {
        // By the tag alone, the object's first: the heap values' tags run from the string's up.
        sljit_emit_op2(c, SLJIT_ASHR, R3, 0, R3, 0, SLJIT_IMM, 48);
        sljit_emit_op2(c, SLJIT_SUB, R3, 0, R3, 0, SLJIT_IMM, K_OBJ >> 48);
        void* object = sljit_emit_cmp(c, SLJIT_EQUAL, R3, 0, SLJIT_IMM, 0);
        sljit_emit_op2(c, SLJIT_ADD, R3, 0, R3, 0, SLJIT_IMM, (K_OBJ - K_STRING_START) >> 48);
        miss.add(sljit_emit_cmp(c, SLJIT_LESS, R3, 0, SLJIT_IMM, -(K_STRING_START >> 48)));
        sljit_set_label(object, sljit_emit_label(c));
        return;
    }
    void* old_ok = sljit_emit_cmp(c, SLJIT_LESS, R3, 0, SLJIT_IMM, K_STRING_START);
    sljit_emit_op2(c, SLJIT_XOR, R3, 0, R3, 0, k_obj_op(), k_obj_w());
    miss.add(sljit_emit_cmp(c, SLJIT_GREATER_EQUAL, R3, 0, span_op(), span_w()));
    sljit_set_label(old_ok, sljit_emit_label(c));
}

// Store register `rv` into the slot at R0 of the object in R1 when the value
// needs no count and no barrier work; jump to `miss` (the slow path by
// default) otherwise. Uses R2, R3.
fn void Asm.store_value(&self, uint rv, Jumps* miss = null) {
    self.load(R2, rv);
    self.store_value_r2(miss);
}

// store_value of the value already in R2, which `uncounted` says is an object or inert.
fn void Asm.store_value_r2(&self, Jumps* miss = null, bool uncounted = false) {
    void* c = self.c;
    Layout* l = self.lay;
    if (!miss) miss = &self.call;
    void* inert = sljit_emit_cmp(c, SLJIT_LESS, R2, 0, SLJIT_IMM, K_STRING_START);
    if (!uncounted) {
        sljit_emit_op2(c, SLJIT_XOR, R3, 0, R2, 0, k_obj_op(), k_obj_w());
        miss.add(sljit_emit_cmp(c, SLJIT_GREATER_EQUAL, R3, 0, span_op(), span_w()));
    }
    self.guard_not_marking_to(miss, R3);
    // Heap.write_barrier: only an old owner not yet in the remembered set that takes a young object
    // has to be remembered.
    sljit_emit_op1(c, SLJIT_MOV_U32, R3, 0, SLJIT_MEM | R1, l.obj_gc);
    sljit_emit_op2(c, SLJIT_AND, R3, 0, R3, 0, SLJIT_IMM, l.old_mask | l.remembered_mask);
    void* covered = sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R3, 0, SLJIT_IMM, l.old_mask);
    sljit_emit_op2(c, SLJIT_XOR, R3, 0, R2, 0, k_obj_op(), k_obj_w());
    sljit_emit_op1(c, SLJIT_MOV_U32, R3, 0, SLJIT_MEM | R3, l.obj_gc);
    sljit_emit_op2(c, SLJIT_AND, R3, 0, R3, 0, SLJIT_IMM, l.old_mask);
    miss.add(sljit_emit_cmp(c, SLJIT_EQUAL, R3, 0, SLJIT_IMM, 0));
    sljit_set_label(covered, sljit_emit_label(c));
    sljit_set_label(inert, sljit_emit_label(c));
    sljit_emit_op1(c, SLJIT_MOV, SLJIT_MEM | R0, 0, R2, 0);
}

// A cached overwrite of an existing own writable data property of the object
// R0 boxes, as th_put_cached: a plain object, the entry's key, shape and shape
// generation, no prototype owner and no absent-add entry. `allow_regexp` also
// admits a bare REGEXP receiver, whose own `lastIndex` is an ordinary data
// property: only its class is exotic, and the site entry still guards the key,
// shape, generation and writability before the slot is written.
fn void Asm.emit_put(&self, long ic, long key, int key_reg, uint rv, bool allow_regexp = false) {
    void* c = self.c;
    Layout* l = self.lay;
    bool setter = key_reg < 0 && !self.wide && (self.w.op == Opcode.PUTPROPC || self.w.op == Opcode.PUTTHISC);
    self.unbox_object(R1, R0);
    sljit_emit_op1(c, SLJIT_MOV_U32, R2, 0, SLJIT_MEM | R1, 0);
    sljit_emit_op2(c, SLJIT_AND, R3, 0, R2, 0, SLJIT_IMM, l.class_mask);
    if (allow_regexp) {
        void* plain = sljit_emit_cmp(c, SLJIT_EQUAL, R3, 0, SLJIT_IMM, l.class_object);
        long rx_exotic = l.class_mask | l.proxy_mask | l.module_ns_mask | l.deferred_ns_mask;
        sljit_emit_op2(c, SLJIT_AND, R3, 0, R2, 0, SLJIT_IMM, rx_exotic);
        self.call.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R3, 0, SLJIT_IMM, l.class_regexp));
        sljit_set_label(plain, sljit_emit_label(c));
    } else {
        self.call.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R3, 0, SLJIT_IMM, l.class_object));
    }
    long exotic = l.module_ns_mask;
    $if features::PROXY:
        exotic |= l.proxy_mask;
    $endif
    sljit_emit_op2(c, SLJIT_AND, R3, 0, R2, 0, SLJIT_IMM, exotic);
    self.call.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R3, 0, SLJIT_IMM, 0));
    sljit_emit_op1(c, SLJIT_MOV, R2, 0, SLJIT_IMM, ic);
    sljit_emit_op1(c, SLJIT_MOV_U32, R3, 0, SLJIT_MEM | R2, l.ic_idx);
    void* absent = sljit_emit_cmp(c, SLJIT_EQUAL, R3, 0, SLJIT_IMM, (long)hobject::IC_PROP_ABSENT);
    // A constant key the entry does not hold (an entry that never filled) is
    // stored by lookup too, which fills it when the receiver can be cached.
    Jumps miss;
    self.put_key_check(key, key_reg, key_reg < 0 ? &miss : &self.call);
    self.guard_shape(R1, R2, &miss);
    sljit_emit_op1(c, SLJIT_MOV_U8, R0, 0, SLJIT_MEM | R2, l.ic_has_proto);
    miss.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R0, 0, SLJIT_IMM, 0));
    // live_shape_generation: heap.shapes[shape_id].generation.
    sljit_emit_op1(c, SLJIT_MOV, R0, 0, SLJIT_MEM | self.heap, l.heap_shapes);
    sljit_emit_op1(c, SLJIT_MOV, R0, 0, mem_index(R0, R3), 3);
    sljit_emit_op1(c, SLJIT_MOV_U32, R0, 0, SLJIT_MEM | R0, l.shape_gen);
    sljit_emit_op1(c, SLJIT_MOV_U32, R3, 0, SLJIT_MEM | R2, l.ic_gen);
    miss.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R3, 0, R0, 0));
    sljit_emit_op1(c, SLJIT_MOV_U8, R0, 0, SLJIT_MEM | R2, l.ic_flags);
    sljit_emit_op2(c, SLJIT_AND, R0, 0, R0, 0, SLJIT_IMM, l.accessor_mask | l.writable_mask);
    miss.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R0, 0, SLJIT_IMM, l.writable_mask));
    sljit_emit_op1(c, SLJIT_MOV_U32, R3, 0, SLJIT_MEM | R2, l.ic_idx);
    self.prop_base(R0, R1);
    sljit_emit_op2(c, SLJIT_SHL, R3, 0, R3, 0, SLJIT_IMM, 3);
    sljit_emit_op2(c, SLJIT_ADD, R0, 0, R0, 0, R3, 0);
    self.store_slot_counted(rv);
    void* done = sljit_emit_jump(c, SLJIT_JUMP);
    sljit_set_label(absent, sljit_emit_label(c));
    self.emit_put_absent(ic, key, key_reg, rv, key_reg < 0 ? &miss : &self.call);
    void* absent_done = sljit_emit_jump(c, SLJIT_JUMP);
    // The entry does not fit the receiver: the store by lookup.
    miss.bind(sljit_emit_label(c));
    void* accessor = null;
    if (setter) {
        // An inherited setter the entry names is called natively (vm::jit_put_setter).
        sljit_emit_op1(c, SLJIT_MOV, R2, 0, SLJIT_IMM, ic);
        sljit_emit_op1(c, SLJIT_MOV_U8, R0, 0, SLJIT_MEM | R2, l.ic_flags);
        sljit_emit_op2(c, SLJIT_AND, R0, 0, R0, 0, SLJIT_IMM, l.accessor_mask);
        accessor = sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R0, 0, SLJIT_IMM, 0);
    }
    sljit_emit_op2(c, SLJIT_ADD, R3, 0, self.regs, 0, SLJIT_IMM, (long)rv * TVal::size);
    sljit_emit_op1(c, SLJIT_MOV, R0, 0, self.heap, 0);
    if (key_reg < 0) {
        sljit_emit_op1(c, SLJIT_MOV, SLJIT_MEM | self.heap, l.heap_site_key, SLJIT_IMM, key);
        self.c_call(SLJIT_ARGS4WWWW, SLJIT_IMM, (long)(usz)&vm::jit_put_site);
    } else {
        self.c_call(SLJIT_ARGS4WWWW, SLJIT_IMM, (long)(usz)&vm::jit_put_missed);
    }
    sljit_emit_op1(c, SLJIT_MOV_U8, R0, 0, R0, 0);
    self.call.add(sljit_emit_cmp(c, SLJIT_EQUAL, R0, 0, SLJIT_IMM, 0));
    if (setter) {
        void* stored = sljit_emit_jump(c, SLJIT_JUMP);
        sljit_set_label(accessor, sljit_emit_label(c));
        sljit_emit_op1(c, SLJIT_MOV, R1, 0, SLJIT_IMM, (long)(usz)self.f.code + (long)self.next * Instruction::size);
        sljit_emit_op1(c, SLJIT_MOV, R0, 0, self.ds, 0);
        self.c_call(SLJIT_ARGS2WWW, SLJIT_IMM, (long)(usz)&vm::jit_put_setter);
        self.call.add(sljit_emit_cmp(c, SLJIT_EQUAL, R0, 0, SLJIT_IMM, vm::JIT_CALL_SLOW));
        sljit_set_label(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R0, 0, SLJIT_IMM, 0), self.nonzero);
        sljit_emit_op1(c, SLJIT_MOV, self.regs, 0, SLJIT_MEM | self.ds, self.regs_off);
        sljit_set_label(stored, sljit_emit_label(c));
    }
    sljit_set_label(done, sljit_emit_label(c));
    sljit_set_label(absent_done, sljit_emit_label(c));
}

// The site key check of a store: the constant `key`, or the string in
// register `key_reg`, against the entry in R2. Uses R3.
fn void Asm.put_key_check(&self, long key, int key_reg, Jumps* to) {
    void* c = self.c;
    Layout* l = self.lay;
    if (key_reg >= 0) {
        self.load(R3, (uint)key_reg);
        sljit_emit_op2(c, SLJIT_XOR, R3, 0, R3, 0, SLJIT_IMM, K_STRING_START);
        to.add(sljit_emit_cmp(c, SLJIT_GREATER_EQUAL, R3, 0, span_op(), span_w()));
        to.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R3, 0, SLJIT_MEM | R2, l.ic_key));
    } else {
        to.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, SLJIT_MEM | R2, l.ic_key, SLJIT_IMM, key));
    }
}

// An absent-property add to the plain object in R1 through the entry in R2:
// the key check inline, the rest in the put-absent subroutine.
fn void Asm.emit_put_absent(&self, long ic, long key, int key_reg, uint rv, Jumps* key_miss) {
    void* c = self.c;
    self.put_key_check(key, key_reg, key_miss);
    sljit_emit_op2(c, SLJIT_ADD, R3, 0, self.regs, 0, SLJIT_IMM, (long)rv * TVal::size);
    self.subs.push({ .jump = sljit_emit_jump(c, SLJIT_FAST_CALL), .sub = PUT_ABSENT_SUB });
    self.call.add(sljit_emit_cmp(c, SLJIT_EQUAL, R0, 0, SLJIT_IMM, 0));
}

// The put-absent subroutine: R1 the receiver, R2 its site entry (whose key
// matched), R3 the address of the value. R0 is nonzero when the key was
// appended, 0 for the slow path. It is vm::jit_put_absent's common case
// inline: ic_matches_absent_put (shape, recycle epoch, extensible plain
// object, the recorded prototype chain under its epoch stamp), a value that needs
// no barrier work beyond the counted store, spare capacity and no hash table,
// and a receiver never observed as a prototype (which needs an epoch bump). Any other state
// calls that helper, which decides again; without `helper` it returns 0, having changed nothing.
fn void Asm.emit_put_absent_body(&self, bool helper = true) {
    void* c = self.c;
    Layout* l = self.lay;
    int m = SLJIT_MEM;
    int sp = m | reg_sp();
    Jumps fail;
    self.mov(sp, SUB_VALUE_OFF, R3, 0);
    // A plain object, extensible; a chain walk's objects are checked alike.
    sljit_emit_op1(c, SLJIT_MOV_U32, R0, 0, m | R1, 0);
    sljit_emit_op2(c, SLJIT_AND, R4, 0, R0, 0, SLJIT_IMM, l.class_mask | l.plain_exotic_mask);
    fail.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R4, 0, SLJIT_IMM, l.class_object));
    sljit_emit_op2(c, SLJIT_AND, R0, 0, R0, 0, SLJIT_IMM, l.extensible_mask);
    fail.add(sljit_emit_cmp(c, SLJIT_EQUAL, R0, 0, SLJIT_IMM, 0));
    sljit_emit_op1(c, SLJIT_MOV_U8, R0, 0, m | R2, l.ic_has_proto);
    fail.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R0, 0, SLJIT_IMM, 0));
    sljit_emit_op1(c, SLJIT_MOV_U32, R0, 0, m | R1, l.obj_shape);
    sljit_emit_op1(c, SLJIT_MOV_U32, R3, 0, m | R2, l.ic_shape);
    fail.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R0, 0, R3, 0));
    sljit_emit_op1(c, SLJIT_MOV_U32, R0, 0, m | self.heap, l.heap_epoch);
    sljit_emit_op1(c, SLJIT_MOV_U32, R3, 0, m | R2, l.ic_gen);
    fail.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R0, 0, R3, 0));
    // The chain: none for an entry without one, else the snapshot's first link under the
    // prototype epoch the entry is stamped with (ICChain.absent_epoch). A stale stamp takes the
    // helper, which walks the snapshot and stamps it again. A chain_len past IC_MAX_CHAIN, the
    // epoch payload, never matches.
    sljit_emit_op1(c, SLJIT_MOV, R4, 0, m | R1, l.obj_proto);
    sljit_emit_op1(c, SLJIT_MOV_U8, R0, 0, m | R2, l.ic_chain_len);
    fail.add(sljit_emit_cmp(c, SLJIT_GREATER, R0, 0, SLJIT_IMM, (long)hobject::IC_MAX_CHAIN));
    void* chained = sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R0, 0, SLJIT_IMM, 0);
    fail.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R4, 0, SLJIT_IMM, 0));
    void* unchained = sljit_emit_jump(c, SLJIT_JUMP);
    sljit_set_label(chained, sljit_emit_label(c));
    sljit_emit_op1(c, SLJIT_MOV, R3, 0, m | R2, l.ic_chain);
    fail.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R4, 0, m | R3, l.chain_proto0));
    sljit_emit_op1(c, SLJIT_MOV, R0, 0, m | R3, l.chain_absent_epoch);
    fail.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R0, 0, m | self.heap, l.heap_proto_epoch));
    sljit_set_label(unchained, sljit_emit_label(c));
    // Spare capacity, no hash table, not a prototype.
    sljit_emit_op1(c, SLJIT_MOV_U32, R0, 0, m | R1, l.obj_prop_count);
    sljit_emit_op1(c, SLJIT_MOV_U32, R3, 0, m | R1, l.obj_prop_capacity);
    fail.add(sljit_emit_cmp(c, SLJIT_GREATER_EQUAL, R0, 0, R3, 0));
    fail.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, m | R1, l.obj_prop_hash, SLJIT_IMM, 0));
    sljit_emit_op1(c, SLJIT_MOV_U32, R4, 0, m | R1, l.obj_gc);
    sljit_emit_op2(c, SLJIT_AND, R3, 0, R4, 0, SLJIT_IMM, l.proto_observed_mask);
    fail.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R3, 0, SLJIT_IMM, 0));
    // The value: inert, or an object while not marking into a young owner.
    self.mov(R3, 0, sp, SUB_VALUE_OFF);
    sljit_emit_op1(c, SLJIT_MOV, R3, 0, m | R3, 0);
    void* inert = sljit_emit_cmp(c, SLJIT_LESS, R3, 0, SLJIT_IMM, K_STRING_START);
    sljit_emit_op2(c, SLJIT_XOR, R0, 0, R3, 0, k_obj_op(), k_obj_w());
    fail.add(sljit_emit_cmp(c, SLJIT_GREATER_EQUAL, R0, 0, span_op(), span_w()));
    self.guard_not_marking_to(&fail, R0);
    sljit_emit_op2(c, SLJIT_AND, R0, 0, R4, 0, SLJIT_IMM, l.old_mask);
    fail.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R0, 0, SLJIT_IMM, 0));
    sljit_set_label(inert, sljit_emit_label(c));
    // Append: the slot at prop_count was never owned, so it needs no old-value work.
    self.prop_base(R0, R1);
    sljit_emit_op1(c, SLJIT_MOV_U32, R4, 0, m | R1, l.obj_prop_count);
    sljit_emit_op2(c, SLJIT_SHL, R4, 0, R4, 0, SLJIT_IMM, 3);
    sljit_emit_op2(c, SLJIT_ADD, R0, 0, R0, 0, R4, 0);
    sljit_emit_op1(c, SLJIT_MOV, m | R0, 0, R3, 0);
    sljit_emit_op1(c, SLJIT_MOV_U32, R4, 0, m | R1, l.obj_prop_count);
    sljit_emit_op2(c, SLJIT_ADD, R4, 0, R4, 0, SLJIT_IMM, 1);
    sljit_emit_op1(c, SLJIT_MOV_U32, m | R1, l.obj_prop_count, R4, 0);
    sljit_emit_op1(c, SLJIT_MOV_U32, R0, 0, m | R2, l.ic_absent_next);
    sljit_emit_op1(c, SLJIT_MOV_U32, m | R1, l.obj_shape, R0, 0);
    sljit_emit_op1(c, SLJIT_MOV, R0, 0, SLJIT_IMM, 1);
    void* done = sljit_emit_jump(c, SLJIT_JUMP);
    fail.bind(sljit_emit_label(c));
    if (helper) {
        self.mov(R3, 0, sp, SUB_VALUE_OFF);
        sljit_emit_op1(c, SLJIT_MOV, R0, 0, self.heap, 0);
        self.c_call(SLJIT_ARGS4WWWW, SLJIT_IMM, (long)(usz)&vm::jit_put_absent);
        sljit_emit_op1(c, SLJIT_MOV_U8, R0, 0, R0, 0);
    } else {
        sljit_emit_op1(c, SLJIT_MOV, R0, 0, SLJIT_IMM, 0);
    }
    sljit_set_label(done, sljit_emit_label(c));
}

// R0 = the address of element R3 (a fastint) of the dense part of the array
// in R1, as HObject.array_part; the slow path for a negative index or one
// past the dense part. Uses R2 and R3, through the shared subroutine.
fn void Asm.array_slot(&self) {
    void* c = self.c;
    self.subs.push({ .jump = sljit_emit_jump(c, SLJIT_FAST_CALL), .sub = ARRAY_SLOT_SUB });
    self.call.add(sljit_emit_cmp(c, SLJIT_EQUAL, R0, 0, SLJIT_IMM, 0));
}

// The array slot subroutine: array_slot's address in R0, or 0.
fn void Asm.emit_array_slot_body(&self) {
    void* c = self.c;
    Layout* l = self.lay;
    Jumps fail;
    sljit_emit_op2(c, SLJIT_SHL, R3, 0, R3, 0, SLJIT_IMM, 16);
    sljit_emit_op2(c, SLJIT_ASHR, R3, 0, R3, 0, SLJIT_IMM, 16);
    sljit_emit_op1(c, SLJIT_MOV_U32, R2, 0, SLJIT_MEM | R1, l.obj_array_size);
    // Unsigned, so a negative index fails too.
    fail.add(sljit_emit_cmp(c, SLJIT_GREATER_EQUAL, R3, 0, R2, 0));
    // The dense part follows the property values: in a block, or in the header of a literal, where
    // props points with no property slots before it.
    sljit_emit_op1(c, SLJIT_MOV, R0, 0, SLJIT_MEM | R1, l.obj_props);
    sljit_emit_op1(c, SLJIT_MOV_U32, R2, 0, SLJIT_MEM | R1, l.obj_prop_capacity);
    sljit_emit_op2(c, SLJIT_SHL, R2, 0, R2, 0, SLJIT_IMM, 3);
    sljit_emit_op2(c, SLJIT_ADD, R0, 0, R0, 0, R2, 0);
    sljit_emit_op2(c, SLJIT_SHL, R3, 0, R3, 0, SLJIT_IMM, 3);
    sljit_emit_op2(c, SLJIT_ADD, R0, 0, R0, 0, R3, 0);
    void* done = sljit_emit_jump(c, SLJIT_JUMP);
    fail.bind(sljit_emit_label(c));
    sljit_emit_op1(c, SLJIT_MOV, R0, 0, SLJIT_IMM, 0);
    sljit_set_label(done, sljit_emit_label(c));
}

// The slow path unless R1 is an array without the flags `extra`, as
// guard_array, except that a jump is returned for any other class, which the
// caller sends to the typed-array subroutine (which rejects the rest).
fn void* Asm.array_or_typed(&self, long extra) {
    void* c = self.c;
    Layout* l = self.lay;
    long mask = l.class_mask | extra;
    $if features::PROXY:
        mask |= l.proxy_mask;
    $endif
    sljit_emit_op1(c, SLJIT_MOV_U32, R2, 0, SLJIT_MEM | R1, 0);
    sljit_emit_op2(c, SLJIT_AND, R2, 0, R2, 0, SLJIT_IMM, mask);
    sljit_emit_op2(c, SLJIT_AND, R0, 0, R2, 0, SLJIT_IMM, l.class_mask);
    void* other = sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R0, 0, SLJIT_IMM, l.class_array);
    self.call.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R2, 0, SLJIT_IMM, l.class_array));
    return other;
}

// A double key in R3 whose value is an integer in [0, 2^31) names the same
// element as that integer (its ToString is the integer's), so it re-enters
// the element path `elem` as a fastint in R3; another double takes the slow
// path, and a key that is not a double falls through.
fn void Asm.index_from_double(&self, void* elem) {
    Jumps yes;
    Jumps no;
    self.call_test_sub(INDEX_SUB, &yes, &no);
    for (uint k = 0; k < yes.len; k++) sljit_set_label(yes.at[k], elem);
    no.bind(sljit_emit_label(self.c));
}

// The double index subroutine: R2 SUB_TRUE with the fastint in R3 for a
// double R3 holding an integer in [0, 2^31), SUB_FALSE for a key that is not
// a double, SUB_SLOW for any other double. Uses R0, FR0 and FR1.
fn void Asm.emit_index_body(&self) {
    void* c = self.c;
    Jumps slow;
    sljit_emit_op1(c, SLJIT_MOV, R2, 0, SLJIT_IMM, SUB_FALSE);
    void* done = sljit_emit_cmp(c, SLJIT_GREATER_EQUAL, R3, 0, k_int_op(), k_int_w());
    sljit_emit_fcopy(c, SLJIT_COPY_TO_F64, FR0, R3);
    sljit_emit_fop1(c, SLJIT_CONV_SW_FROM_F64, R0, 0, FR0, 0);
    slow.add(sljit_emit_cmp(c, SLJIT_GREATER_EQUAL, R0, 0, SLJIT_IMM, 1L << 31));
    sljit_emit_fop1(c, SLJIT_CONV_F64_FROM_SW, FR1, 0, R0, 0);
    slow.add(sljit_emit_fcmp(c, SLJIT_UNORDERED_OR_NOT_EQUAL, FR0, 0, FR1, 0));
    sljit_emit_op2(c, SLJIT_OR, R3, 0, R0, 0, k_int_op(), k_int_w());
    sljit_emit_op1(c, SLJIT_MOV, R2, 0, SLJIT_IMM, SUB_TRUE);
    void* joined = sljit_emit_jump(c, SLJIT_JUMP);
    slow.bind(sljit_emit_label(c));
    sljit_emit_op1(c, SLJIT_MOV, R2, 0, SLJIT_IMM, SUB_SLOW);
    sljit_set_label(joined, sljit_emit_label(c));
    sljit_set_label(done, sljit_emit_label(c));
}

// A read of a dense array element, index in R3, as th_getprop_array: a hole
// takes the slow path, which consults the prototype chain. Another class
// tries the typed-array subroutine (th_get_typed_element).
fn void Asm.emit_get_elem(&self, uint ra, uint rb) {
    void* c = self.c;
    self.load(R0, rb);
    self.unbox_object(R1, R0);
    void* other = self.array_or_typed(0);
    self.array_slot();
    sljit_emit_op1(c, SLJIT_MOV, R0, 0, SLJIT_MEM | R0, 0);
    self.packed_or_hole();
    self.publish(ra);
    $if features::BUFFERS:
        void* done = sljit_emit_jump(c, SLJIT_JUMP);
        sljit_set_label(other, sljit_emit_label(c));
        self.note_elem_class();
        self.subs.push({ .jump = sljit_emit_jump(c, SLJIT_FAST_CALL), .sub = TYPED_GET_SUB });
        self.call.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R2, 0, SLJIT_IMM, SUB_TRUE));
        // A number, which needs no publication.
        self.store(ra, R0);
        sljit_set_label(done, sljit_emit_label(c));
    $else
        self.call.add(other);
    $endif
}

// After array_slot and the element's load into R0, with the array in R1 and the index times eight in
// R3: the slow path for an `undefined` that is a hole rather than an element of a packed array.
// Uses R2.
fn void Asm.packed_or_hole(&self) {
    void* c = self.c;
    Layout* l = self.lay;
    void* value = sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R0, 0, SLJIT_IMM, K_UNDEF);
    sljit_emit_op1(c, SLJIT_MOV_U32, R2, 0, SLJIT_MEM | R1, l.obj_gc);
    sljit_emit_op2(c, SLJIT_AND, R2, 0, R2, 0, SLJIT_IMM, l.packed_mask);
    self.call.add(sljit_emit_cmp(c, SLJIT_EQUAL, R2, 0, SLJIT_IMM, 0));
    sljit_emit_op1(c, SLJIT_MOV_U32, R2, 0, SLJIT_MEM | R1, l.obj_array_len);
    sljit_emit_op2(c, SLJIT_SHL, R2, 0, R2, 0, SLJIT_IMM, 3);
    self.call.add(sljit_emit_cmp(c, SLJIT_GREATER_EQUAL, R3, 0, R2, 0));
    sljit_set_label(value, sljit_emit_label(c));
}

// Record the class flags array_or_typed left in R2, of a receiver that is not an array, in the
// instruction's ICEntry.elem_class: the typed array kind the optimizing tier specializes the
// access for (OptCg.emit_typed_elem).
fn void Asm.note_elem_class(&self) {
    CompiledFunction* f = self.f;
    if (f.ic_entries == null) return;
    hobject::ICEntry* entry = &((hobject::ICEntry*)f.ic_entries)[self.next - 1];
    sljit_emit_op1(self.c, SLJIT_MOV_U32, SLJIT_MEM, (long)(usz)&entry.fwd_callee, R2, 0);
}

// An overwrite of a dense array element, index in R3, as
// th_put_array_element; a hole or an undefined value takes the slow path.
// Another class tries the typed-array subroutine (th_put_typed_element).
fn void Asm.emit_put_elem(&self, uint ra, uint rv) {
    void* c = self.c;
    self.load(R0, ra);
    self.unbox_object(R1, R0);
    void* other = self.array_or_typed(self.lay.indexed_named_mask);
    self.array_slot();
    self.call.add(sljit_emit_cmp(c, SLJIT_EQUAL, SLJIT_MEM | R0, 0, SLJIT_IMM, K_UNDEF));
    self.load(R2, rv);
    self.call.add(sljit_emit_cmp(c, SLJIT_EQUAL, R2, 0, SLJIT_IMM, K_UNDEF));
    self.store_slot_counted(rv);
    $if features::BUFFERS:
        void* done = sljit_emit_jump(c, SLJIT_JUMP);
        sljit_set_label(other, sljit_emit_label(c));
        self.note_elem_class();
        self.load(R0, rv);
        self.subs.push({ .jump = sljit_emit_jump(c, SLJIT_FAST_CALL), .sub = TYPED_PUT_SUB });
        self.call.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R2, 0, SLJIT_IMM, SUB_TRUE));
        sljit_set_label(done, sljit_emit_label(c));
    $else
        self.call.add(other);
    $endif
}

// The store into an empty slot of a fresh fixed-shape object, as
// th_init_slot: a plain object that is not a proxy, slot `b` below its
// property count and still undefined; a heap value takes the counted store.
fn void Asm.emit_init_slot(&self, uint ra, uint b, uint rv) {
    void* c = self.c;
    Layout* l = self.lay;
    self.load(R0, ra);
    self.unbox_object(R1, R0);
    sljit_emit_op1(c, SLJIT_MOV_U32, R2, 0, SLJIT_MEM | R1, 0);
    sljit_emit_op2(c, SLJIT_AND, R2, 0, R2, 0, SLJIT_IMM, l.class_mask | l.proxy_mask);
    self.call.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R2, 0, SLJIT_IMM, l.class_object));
    sljit_emit_op1(c, SLJIT_MOV_U32, R2, 0, SLJIT_MEM | R1, l.obj_prop_count);
    self.call.add(sljit_emit_cmp(c, SLJIT_LESS_EQUAL, R2, 0, SLJIT_IMM, b));
    self.prop_base(R0, R1);
    sljit_emit_op2(c, SLJIT_ADD, R0, 0, R0, 0, SLJIT_IMM, (long)b * TVal::size);
    self.call.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, SLJIT_MEM | R0, 0, SLJIT_IMM, K_UNDEF));
    Jumps counted;
    self.store_value_counted(rv, &counted);
}

// One element kind the typed-array subroutines handle inline.
struct TypedKind {
    hobject::ObjClass cls;
    int shift;
    int mov;
}

fn bool TypedKind.is_float(&self) @inline => self.cls == hobject::ObjClass.FLOAT32ARRAY || self.cls == hobject::ObjClass.FLOAT64ARRAY;

const TypedKind[*] TYPED_KINDS = {
    { hobject::ObjClass.INT32ARRAY, 2, SLJIT_MOV_S32 },
    { hobject::ObjClass.FLOAT64ARRAY, 3, SLJIT_MOV },
    { hobject::ObjClass.UINT8ARRAY, 0, SLJIT_MOV_U8 },
    { hobject::ObjClass.FLOAT32ARRAY, 2, SLJIT_MOV_F64 | SLJIT_32 },
    { hobject::ObjClass.INT16ARRAY, 1, SLJIT_MOV_S16 },
    { hobject::ObjClass.UINT16ARRAY, 1, SLJIT_MOV_U16 },
    { hobject::ObjClass.INT8ARRAY, 0, SLJIT_MOV_S8 },
    { hobject::ObjClass.UINT32ARRAY, 2, SLJIT_MOV_U32 },
    { hobject::ObjClass.UINT8CLAMPEDARRAY, 0, SLJIT_MOV_U8 },
};

// The typed-array element subroutines, as th_get_typed_element and
// th_put_typed_element, for a fastint index into a fixed-length typed array:
// R1 the object, R3 the boxed index and, for a store, R0 the value. A read
// leaves the element in R0, boxed as ta_load_number does. R2 is SUB_TRUE
// when done and SUB_SLOW for the handler: another class, a proxy, a
// detached, resizable or (for a store) immutable buffer, an index out of
// range, Float16 and BigInt elements, a clamped store, and a store of a
// double into an integer kind (ToInt32) or of anything but a number.
fn void Asm.emit_typed_body(&self, bool put) {
$if features::BUFFERS:
    void* c = self.c;
    Layout* l = self.lay;
    int sp = SLJIT_MEM | reg_sp();
    Jumps fail;
    Jumps ok;
    if (put) sljit_emit_op1(c, SLJIT_MOV, sp, SUB_VALUE_OFF, R0, 0);
    // R0 = class << 1 | proxy bit.
    sljit_emit_op1(c, SLJIT_MOV_U32, R0, 0, SLJIT_MEM | R1, 0);
    sljit_emit_op2(c, SLJIT_LSHR, R0, 0, R0, 0, SLJIT_IMM, 15);
    sljit_emit_op2(c, SLJIT_AND, R0, 0, R0, 0, SLJIT_IMM, 0x7F);
    sljit_emit_op2(c, SLJIT_SUB, R2, 0, R0, 0, SLJIT_IMM, (long)hobject::ObjClass.INT8ARRAY.ordinal << 1);
    fail.add(sljit_emit_cmp(c, SLJIT_GREATER_EQUAL, R2, 0, SLJIT_IMM,
        (long)(hobject::ObjClass.BIGUINT64ARRAY.ordinal - hobject::ObjClass.INT8ARRAY.ordinal + 1) << 1));
    // Odd: a proxy, whose extra is not a view.
    sljit_emit_op2(c, SLJIT_AND, R2, 0, R0, 0, SLJIT_IMM, 1);
    fail.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R2, 0, SLJIT_IMM, 0));
    // th_typed_array_base.
    sljit_emit_op1(c, SLJIT_MOV, R4, 0, SLJIT_MEM | R1, l.view_buffer);
    fail.add(sljit_emit_cmp(c, SLJIT_EQUAL, R4, 0, SLJIT_IMM, 0));
    sljit_emit_op1(c, SLJIT_MOV_U8, R2, 0, SLJIT_MEM | R4, l.ab_resizable);
    fail.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R2, 0, SLJIT_IMM, 0));
    if (put) {
        sljit_emit_op1(c, SLJIT_MOV_U8, R2, 0, SLJIT_MEM | R4, l.ab_immutable);
        fail.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R2, 0, SLJIT_IMM, 0));
    }
    sljit_emit_op1(c, SLJIT_MOV, R4, 0, SLJIT_MEM | R4, l.ab_data);
    fail.add(sljit_emit_cmp(c, SLJIT_EQUAL, R4, 0, SLJIT_IMM, 0));
    sljit_emit_op1(c, SLJIT_MOV_U32, R2, 0, SLJIT_MEM | R1, l.view_offset);
    sljit_emit_op2(c, SLJIT_ADD, R4, 0, R4, 0, R2, 0);
    sljit_emit_op1(c, SLJIT_MOV_U32, R1, 0, SLJIT_MEM | R1, l.view_length);
    sljit_emit_op2(c, SLJIT_SHL, R3, 0, R3, 0, SLJIT_IMM, 16);
    sljit_emit_op2(c, SLJIT_ASHR, R3, 0, R3, 0, SLJIT_IMM, 16);
    void*[TYPED_KINDS.len] kind_at;
    foreach (k, kind : TYPED_KINDS) {
        kind_at[k] = sljit_emit_cmp(c, SLJIT_EQUAL, R0, 0, SLJIT_IMM, (long)kind.cls.ordinal << 1);
    }
    fail.add(sljit_emit_jump(c, SLJIT_JUMP));
    foreach (k, kind : TYPED_KINDS) {
        hobject::ObjClass cls = kind.cls;
        bool is_float = kind.is_float();
        if (put && cls == hobject::ObjClass.UINT8CLAMPEDARRAY) {
            sljit_set_label(kind_at[k], sljit_emit_label(c));
            fail.add(sljit_emit_jump(c, SLJIT_JUMP));
            continue;
        }
        sljit_set_label(kind_at[k], sljit_emit_label(c));
        // Unsigned, so a negative index fails too.
        sljit_emit_op2(c, SLJIT_LSHR, R2, 0, R1, 0, SLJIT_IMM, kind.shift);
        fail.add(sljit_emit_cmp(c, SLJIT_GREATER_EQUAL, R3, 0, R2, 0));
        int elem = mem_index(R4, R3);
        if (!put) {
            if (cls == hobject::ObjClass.FLOAT32ARRAY) {
                sljit_emit_fop1(c, SLJIT_MOV_F64 | SLJIT_32, FR0, 0, elem, kind.shift);
                sljit_emit_fop1(c, SLJIT_CONV_F64_FROM_F32, FR0, 0, FR0, 0);
                sljit_emit_fcopy(c, SLJIT_COPY_FROM_F64, FR0, R0);
            } else {
                sljit_emit_op1(c, kind.mov, R0, 0, elem, kind.shift);
            }
            if (is_float) {
                // TVal.set_number: a NaN whose bits would read as a tag.
                void* plain = sljit_emit_cmp(c, SLJIT_LESS, R0, 0, k_int_op(), k_int_w());
                sljit_emit_op1(c, SLJIT_MOV, R0, 0, SLJIT_IMM, CANONICAL_NAN);
                sljit_set_label(plain, sljit_emit_label(c));
                ok.add(sljit_emit_jump(c, SLJIT_JUMP));
                continue;
            }
            if (cls == hobject::ObjClass.UINT32ARRAY) {
                // ta_load_number: 2^31 and above reads as a double.
                void* small = sljit_emit_cmp(c, SLJIT_LESS, R0, 0, SLJIT_IMM, 1L << 31);
                sljit_emit_fop1(c, SLJIT_CONV_F64_FROM_SW, FR0, 0, R0, 0);
                sljit_emit_fcopy(c, SLJIT_COPY_FROM_F64, FR0, R0);
                ok.add(sljit_emit_jump(c, SLJIT_JUMP));
                sljit_set_label(small, sljit_emit_label(c));
            }
            sljit_emit_op2(c, SLJIT_AND, R0, 0, R0, 0, SLJIT_IMM, PAYLOAD_SPAN - 1);
            sljit_emit_op2(c, SLJIT_OR, R0, 0, R0, 0, k_int_op(), k_int_w());
            ok.add(sljit_emit_jump(c, SLJIT_JUMP));
            continue;
        }
        sljit_emit_op1(c, SLJIT_MOV, R0, 0, sp, SUB_VALUE_OFF);
        sljit_emit_op2(c, SLJIT_XOR, R2, 0, R0, 0, k_int_op(), k_int_w());
        if (!is_float) {
            // ta_store_int keeps the low bits of the fastint payload.
            fail.add(sljit_emit_cmp(c, SLJIT_GREATER_EQUAL, R2, 0, span_op(), span_w()));
            sljit_emit_op1(c, kind.mov, elem, kind.shift, R0, 0);
            ok.add(sljit_emit_jump(c, SLJIT_JUMP));
            continue;
        }
        int f32 = cls == hobject::ObjClass.FLOAT32ARRAY ? SLJIT_32 : 0;
        void* not_int = sljit_emit_cmp(c, SLJIT_GREATER_EQUAL, R2, 0, span_op(), span_w());
        sljit_emit_op2(c, SLJIT_SHL, R0, 0, R0, 0, SLJIT_IMM, 16);
        sljit_emit_op2(c, SLJIT_ASHR, R0, 0, R0, 0, SLJIT_IMM, 16);
        sljit_emit_fop1(c, SLJIT_CONV_F64_FROM_SW | f32, FR0, 0, R0, 0);
        void* stored = sljit_emit_jump(c, SLJIT_JUMP);
        sljit_set_label(not_int, sljit_emit_label(c));
        // A double, which ta_store_scalar narrows for Float32.
        fail.add(sljit_emit_cmp(c, SLJIT_GREATER_EQUAL, R0, 0, k_int_op(), k_int_w()));
        sljit_emit_fcopy(c, SLJIT_COPY_TO_F64, FR0, R0);
        if (f32 != 0) sljit_emit_fop1(c, SLJIT_CONV_F64_FROM_F32 | SLJIT_32, FR0, 0, FR0, 0);
        sljit_set_label(stored, sljit_emit_label(c));
        sljit_emit_fop1(c, SLJIT_MOV_F64 | f32, elem, kind.shift, FR0, 0);
        ok.add(sljit_emit_jump(c, SLJIT_JUMP));
    }
    fail.bind(sljit_emit_label(c));
    sljit_emit_op1(c, SLJIT_MOV, R2, 0, SLJIT_IMM, SUB_SLOW);
    void* out = sljit_emit_jump(c, SLJIT_JUMP);
    ok.bind(sljit_emit_label(c));
    sljit_emit_op1(c, SLJIT_MOV, R2, 0, SLJIT_IMM, SUB_TRUE);
    sljit_set_label(out, sljit_emit_label(c));
$endif
}

// R2 = the variable entry `vic`'s binding slot while the entry is valid, as
// th_var_ic_hit (and th_var_ic_moved when `scoped`); the slow path otherwise.
//
// An inlined body's scoped read passes the register of its callee closure, whose scope the entry
// must be filled for: the running activation's is the outermost caller's (closure_lex_env).
fn void Asm.var_slot(&self, long vic, bool scoped, uint closure_reg = uint::max, int closure = -1) {
    void* c = self.c;
    Layout* l = self.lay;
    // A re-armed entry runs the instruction again from here (emit_var_alt).
    if (scoped) self.poly_back = sljit_emit_label(c);
    sljit_emit_op1(c, SLJIT_MOV, R2, 0, SLJIT_IMM, vic);
    if (scoped) {
        if (closure_reg != uint::max) {
            self.closure_lex_env(closure_reg, closure);
        } else {
            self.reads_env = true;
            sljit_emit_op1(c, SLJIT_MOV, R1, 0, SLJIT_MEM | self.la, l.act_lex_env);
        }
        self.alt.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R1, 0, SLJIT_MEM | R2, l.vic_head));
    }
    sljit_emit_op1(c, SLJIT_MOV_U32, R0, 0, SLJIT_MEM | R2, l.vic_epoch);
    sljit_emit_op1(c, SLJIT_MOV_U32, R1, 0, SLJIT_MEM | self.heap, l.heap_epoch);
    self.call.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R0, 0, R1, 0));
    sljit_emit_op1(c, SLJIT_MOV, R0, 0, SLJIT_MEM | R2, l.vic_slot);
    self.call.add(sljit_emit_cmp(c, SLJIT_EQUAL, R0, 0, SLJIT_IMM, 0));
}

// GETGLOBAL as th_getglobal, GETVAR as th_getvar.
fn void Asm.emit_get_var(&self, uint ra, long vic, bool scoped, uint closure_reg = uint::max, int closure = -1) {
    void* c = self.c;
    self.var_slot(vic, scoped, closure_reg, closure);
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
    self.call.add(sljit_emit_cmp(c, SLJIT_LESS, R3, 0, span_op(), span_w()));
    sljit_set_label(plain, sljit_emit_label(c));
    self.store_slot_moved(rv);
    self.store(rv, SLJIT_IMM, K_UNDEF);
}

// R1 = capture record `index` of the running closure, as capture_refs_of; the
// slow path when the frame runs other code or the index is out of range.
// Uses R0 to R3, through the shared subroutine.
fn void Asm.capture_ref(&self, uint index) {
    void* c = self.c;
    self.reads_callee = true;
    sljit_emit_op1(c, SLJIT_MOV, R2, 0, SLJIT_IMM, index);
    self.subs.push({ .jump = sljit_emit_jump(c, SLJIT_FAST_CALL), .sub = CAPTURE_REF_SUB });
    self.call.add(sljit_emit_cmp(c, SLJIT_EQUAL, R1, 0, SLJIT_IMM, 0));
}

// The capture record subroutine: record R2 in R1, or 0.
fn void Asm.emit_capture_ref_body(&self) {
    void* c = self.c;
    Layout* l = self.lay;
    Jumps fail;
    sljit_emit_op1(c, SLJIT_MOV, R0, 0, SLJIT_MEM | self.la, l.act_tv_func);
    sljit_emit_op2(c, SLJIT_XOR, R3, 0, R0, 0, k_obj_op(), k_obj_w());
    fail.add(sljit_emit_cmp(c, SLJIT_GREATER_EQUAL, R3, 0, span_op(), span_w()));
    sljit_emit_op1(c, SLJIT_MOV, R0, 0, SLJIT_MEM | R3, l.fn_capture_refs);
    fail.add(sljit_emit_cmp(c, SLJIT_EQUAL, R0, 0, SLJIT_IMM, 0));
    sljit_emit_op1(c, SLJIT_MOV, R3, 0, SLJIT_MEM | R3, l.fn_comp_func);
    fail.add(sljit_emit_cmp(c, SLJIT_EQUAL, R3, 0, SLJIT_IMM, 0));
    fail.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R3, 0, SLJIT_MEM | self.la, l.act_func));
    sljit_emit_op1(c, SLJIT_MOV_U32, R3, 0, SLJIT_MEM | R3, l.cf_capture_count);
    fail.add(sljit_emit_cmp(c, SLJIT_LESS_EQUAL, R3, 0, R2, 0));
    sljit_emit_op2(c, SLJIT_MUL, R2, 0, R2, 0, SLJIT_IMM, (long)hobject::CaptureRef::size);
    sljit_emit_op2(c, SLJIT_ADD, R1, 0, R0, 0, R2, 0);
    void* done = sljit_emit_jump(c, SLJIT_JUMP);
    fail.bind(sljit_emit_label(c));
    sljit_emit_op1(c, SLJIT_MOV, R1, 0, SLJIT_IMM, 0);
    sljit_set_label(done, sljit_emit_label(c));
}

// GETCAP as th_getcap and capture_read_slot: a value snapshot, a cell, or an
// unshadowed binding outside its TDZ. A record that never resolved (a capture
// made before its binding existed) goes to the site's variable cache instead
// of straight to the thunk; emit_cap_var_alt settles it with what the thunk's
// own lookup recorded there.
fn void Asm.emit_get_cap(&self, uint ra, uint index) {
    self.emit_get_cap_value(index, self.f.var_ic_entries != null ? &self.alt : null);
    self.publish(ra);
}

// The value GETCAP reads, in R0; the slow path for anything else. An
// `unresolved` record leaves through that jump instead of the slow path.
fn void Asm.emit_get_cap_value(&self, uint index, Jumps* unresolved = null) {
    self.capture_ref(index);
    self.emit_cap_record_value(unresolved);
}

// The value GETCAP reads in an inlined body, in R0: capture `index` of the closure in register
// `callee_reg`, which the inline guard has checked to be a closure of the callee (`count` captures).
fn void Asm.emit_get_cap_value_of(&self, uint index, uint callee_reg, uint count, int closure = -1) {
    void* c = self.c;
    Layout* l = self.lay;
    if (closure >= 0) {
        if (closure != R3) sljit_emit_op1(c, SLJIT_MOV, R3, 0, closure, 0);
    } else {
        self.load(R3, callee_reg);
    }
    sljit_emit_op2(c, SLJIT_XOR, R3, 0, R3, 0, k_obj_op(), k_obj_w());
    sljit_emit_op1(c, SLJIT_MOV, R0, 0, SLJIT_MEM | R3, l.fn_capture_refs);
    self.call.add(sljit_emit_cmp(c, SLJIT_EQUAL, R0, 0, SLJIT_IMM, 0));
    sljit_emit_op1(c, SLJIT_MOV, R2, 0, SLJIT_IMM, index);
    self.call.add(sljit_emit_cmp(c, SLJIT_GREATER_EQUAL, R2, 0, SLJIT_IMM, count));
    sljit_emit_op2(c, SLJIT_MUL, R2, 0, R2, 0, SLJIT_IMM, (long)hobject::CaptureRef::size);
    sljit_emit_op2(c, SLJIT_ADD, R1, 0, R0, 0, R2, 0);
    self.emit_cap_record_value();
}

// The value of the capture record in R1, in R0: a value snapshot, a cell, or an unshadowed binding
// outside its TDZ; the slow path for anything else. A record with no owner leaves through
// `unresolved` when the caller has a path for it, which can only be a record created before its
// binding was declared.
fn void Asm.emit_cap_record_value(&self, Jumps* unresolved = null) {
    void* c = self.c;
    Layout* l = self.lay;
    Jumps loaded;
    sljit_emit_op1(c, SLJIT_MOV_U8, R2, 0, SLJIT_MEM | R1, l.cr_is_value);
    void* not_value = sljit_emit_cmp(c, SLJIT_EQUAL, R2, 0, SLJIT_IMM, 0);
    sljit_emit_op1(c, SLJIT_MOV, R0, 0, SLJIT_MEM | R1, 0);
    loaded.add(sljit_emit_jump(c, SLJIT_JUMP));
    sljit_set_label(not_value, sljit_emit_label(c));
    sljit_emit_op1(c, SLJIT_MOV, R3, 0, SLJIT_MEM | R1, 0);
    void* no_owner = sljit_emit_cmp(c, SLJIT_EQUAL, R3, 0, SLJIT_IMM, 0);
    if (unresolved != null) {
        unresolved.add(no_owner);
    } else {
        self.call.add(no_owner);
    }
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

// Count one execution of `op` in `counts` when --jit-count-ops asked for counts.
fn void Asm.count(&self, ulong* counts, Opcode op, long delta = 1) {
    if (!self.counting) return;
    long at = (long)(usz)&counts[op.ordinal];
    sljit_emit_op2(self.c, SLJIT_ADD, SLJIT_MEM, at, SLJIT_MEM, at, SLJIT_IMM, delta);
}

// The --jit-count-ops counts: inline completions against thunk calls of each
// access opcode, then the opcodes with the most thunk calls.
fn void baseline_print_counts(JitStats* st) {
    if (!st.count_ops) return;
    foreach (op : Opcode::values) {
        if (!is_access_op(op)) continue;
        ulong fast = st.fast_hits[op.ordinal];
        ulong slow = st.slow_calls[op.ordinal];
        ulong relay = st.relay_done[op.ordinal];
        if (fast + slow + relay == 0) continue;
        io::eprintfn("jit op %s: inline %d (polymorphic %d), relayed %d, thunk %d (%.1f%% inline)", op, fast,
                     st.poly_hits[op.ordinal], relay, slow, 100.0 * (double)fast / (double)(fast + slow + relay));
    }
    ulong slow_total;
    ulong relay_total;
    foreach (k, n : st.slow_calls) {
        slow_total += n;
        relay_total += st.relay_done[k];
    }
    io::eprintfn("jit thunk calls: %d to the operation function, %d relayed completions", slow_total, relay_total);
    bool[Opcode::values.len] shown;
    for (uint rank = 0; rank < 10; rank++) {
        int best = -1;
        foreach (k, n : st.slow_calls) {
            if (!shown[k] && n != 0 && (best < 0 || n > st.slow_calls[best])) best = (int)k;
        }
        if (best < 0) break;
        shown[best] = true;
        io::eprintfn("jit slow %d: %s %d (relayed %d)", rank + 1, Opcode::values[best], st.slow_calls[best],
                     st.relay_done[best]);
    }
}

