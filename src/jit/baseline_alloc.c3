// Baseline tier allocation ops: NEWARR, NEWARR_CONST, NEWARR_FILL, NEWOBJ and NEWOBJ_SHAPE.
//
// A fresh ordinary object or short literal array is built inline. The pool's
// bump allocation and the accounting are one shared subroutine (ALLOC_SUB); the
// caller writes the header the allocator would (hobject::plain_object_flags and
// its siblings give both the same words). The inline path takes only the state
// in which Heap.adopt_object does no more than count and shade: the trigger
// spent only once a collection is requested or running, the memory-check
// budget not about to expire, a block left in the pool's current run and,
// while marking, room in the gray queue: a new object is shaded gray, as
// Heap.shade_new_header does, so its initializing stores need no barrier.
// Anything else calls the C helper that runs the threaded handler's body,
// which does the rest. Neither path collects: the trigger only requests a
// collection for the next safepoint.
module boomkat::jit @feat(SLJIT);

import boomkat::vm;
import boomkat::bytecode;
import boomkat::hobject;
import boomkat::types;
import boomkat::heap;
import boomkat::pagepool;

// Whether this build allocates through the plain pools this code mirrors.
fn bool inline_alloc_ok() @inline {
$if !types::USE_NANBOX || $feat(POOL_BYPASS) || $feat(GC_PROFILE) || env::ADDRESS_SANITIZER:
    return false;
$else
    return true;
$endif
}

// An inline object allocation: its pool, header words and slot fill.
struct InlineAlloc {
    long pool;           // offset of the ObjectPool in the Heap
    uint flags;
    uint gc;
    uint shape_id;
    uint prop_capacity;
    uint prop_count;
    uint array_size;
    uint array_used;     // elements copied from `copy_from`, a constant template's values
    long copy_from;
    uint array_inline;   // the inline literal array capacity, or 0 for an object
    long proto_off;      // the Heap field holding the prototype, or NEW_OBJECT_PROTO
    long fill_off;       // where the undefined slots start
    uint fill_count;
    NewSite* site;       // an armed site whose pool, gc and prop_capacity replace those above
}

// The prototype is in the frame's SUB_VALUE_OFF slot, saved across the pool subroutine.
const long PROTO_ON_STACK = -1;

// The allocation the current instruction makes, or false for one the helper keeps.
// The plain object an inlined constructor builds (heap.alloc_plain_object), with room for
// `capacity` properties (vm::constructor_inline_capacity).
fn InlineAlloc Asm.plain_object_plan(&self, uint capacity = hobject::INLINE_PROPS) {
    Layout* l = self.lay;
    hobject::ObjFlags flags = hobject::plain_object_flags(true);
    flags.temproot = true;
    uint shaped = capacity > hobject::INLINE_PROPS ? capacity - hobject::INLINE_PROPS : 0;
    long pool = shaped != 0 ? l.heap_pool_shaped + (long)(shaped - 1) * l.pool_size : l.heap_pool_plain;
    return { .pool = pool, .flags = (uint)flags, .gc = (uint)hobject::plain_object_gc(false, shaped),
             .prop_capacity = capacity, .proto_off = PROTO_ON_STACK };
}

fn bool Asm.inline_alloc_plan(&self, InlineAlloc* p) {
    Layout* l = self.lay;
    hobject::ObjFlags flags = hobject::plain_object_flags(true);
    switch (self.w.op) {
        case NEWOBJ:
            *p = { .pool = l.heap_pool_plain, .gc = (uint)hobject::plain_object_gc(false, 0),
                   .prop_capacity = hobject::INLINE_PROPS, .proto_off = l.heap_object_proto };
        case NEWOBJ_SHAPE:
            uint shape_id = self.w.get_bc();
            hobject::Shape* shape = self.hp.get_shape(shape_id);
            uint count = shape.offset + shape.own_count;
            // A shape wider than the inline layouts needs a property block.
            if (count > hobject::SHAPED_INLINE_MAX_PROPS) return false;
            uint capacity = hobject::shape_inline_capacity(count);
            bool compact = capacity == hobject::COMPACT_INLINE_PROPS;
            uint shaped = capacity > hobject::INLINE_PROPS ? capacity - hobject::INLINE_PROPS : 0;
            long pool = compact ? l.heap_pool_compact
                : shaped != 0 ? l.heap_pool_shaped + (long)(shaped - 1) * l.pool_size : l.heap_pool_plain;
            types::GcBits gc = hobject::plain_object_gc(compact, shaped);
            *p = { .pool = pool, .gc = (uint)gc, .shape_id = shape_id, .prop_capacity = capacity, .prop_count = count,
                   .proto_off = l.heap_object_proto, .fill_off = (long)gc.inline_words * 8, .fill_count = count };
        case NEWARR:
            uint capacity = self.w.get_bc();
            if (capacity == 0 || capacity > hobject::ARRAY_INLINE_MAX_CAPACITY) return false;
            flags = hobject::inline_array_flags(true);
            *p = { .pool = l.heap_pool_arrays + (long)(capacity - 1) * l.pool_size,
                   .gc = (uint)hobject::inline_array_gc(), .array_size = capacity, .array_inline = capacity,
                   .proto_off = l.heap_array_proto, .fill_off = l.obj_size_array, .fill_count = capacity };
        case NEWARR_CONST:
            // alloc_constant_array: an inline array holding the template's numbers.
            if (!self.consts_fixed || self.w.get_bc() >= self.f.const_count) return false;
            TVal* template = self.f.constants + self.w.get_bc();
            uint length = (uint)template[0].get_fastint();
            if (length == 0 || length > hobject::ARRAY_INLINE_MAX_CAPACITY) return false;
            flags = hobject::inline_array_flags(true);
            *p = { .pool = l.heap_pool_arrays + (long)(length - 1) * l.pool_size,
                   .gc = (uint)hobject::inline_array_gc(), .array_size = length, .array_used = length,
                   .copy_from = (long)(usz)(template + 1), .array_inline = length,
                   .proto_off = l.heap_array_proto };
        case NEWARR_FILL:
            // alloc_array_of: the elements come from registers B on (emit_fill_elements).
            uint length = self.w.c;
            if (length == 0 || length > hobject::ARRAY_INLINE_MAX_CAPACITY) return false;
            flags = hobject::inline_array_flags(true);
            *p = { .pool = l.heap_pool_arrays + (long)(length - 1) * l.pool_size,
                   .gc = (uint)hobject::inline_array_gc(), .array_size = length, .array_used = length,
                   .array_inline = length, .proto_off = l.heap_array_proto };
        default:
            return false;
    }
    // The allocator flags the new object a temporary root.
    flags.temproot = true;
    p.flags = (uint)flags;
    return true;
}

// Allocate and initialize the object `p` describes into R0, unboxed (the caller boxes it); the jumps
// in `slow` leave nothing changed. Uses R1 to R4.
fn void Asm.emit_inline_alloc(&self, InlineAlloc* p, Jumps* slow) {
    void* c = self.c;
    Layout* l = self.lay;
    int m = SLJIT_MEM;
    if (p.site != null) {
        sljit_emit_op1(c, SLJIT_MOV, R1, 0, SLJIT_MEM, (long)(usz)&p.site.pool);
        sljit_emit_op2(c, SLJIT_ADD, R1, 0, R1, 0, self.heap, 0);
    } else {
        sljit_emit_op2(c, SLJIT_ADD, R1, 0, self.heap, 0, SLJIT_IMM, p.pool);
    }
    self.subs.push({ .jump = sljit_emit_jump(c, SLJIT_FAST_CALL), .sub = ALLOC_SUB });
    slow.add(sljit_emit_cmp(c, SLJIT_EQUAL, R0, 0, SLJIT_IMM, 0));
    // HObject.init_header, with the GcBits ALLOC_SUB left in R1, then the prototype and the fill
    // the caller's allocator adds.
    sljit_emit_op1(c, SLJIT_MOV_U32, m | R0, 0, SLJIT_IMM, (long)p.flags);
    if (p.site != null) {
        sljit_emit_op1(c, SLJIT_MOV_U32, R2, 0, SLJIT_MEM, (long)(usz)&p.site.gc);
        sljit_emit_op2(c, SLJIT_OR, R1, 0, R1, 0, R2, 0);
        sljit_emit_op1(c, SLJIT_MOV_U32, m | R0, l.obj_gc, R1, 0);
        sljit_emit_op1(c, SLJIT_MOV_U32, R1, 0, SLJIT_MEM, (long)(usz)&p.site.capacity);
        sljit_emit_op1(c, SLJIT_MOV_U32, m | R0, l.obj_prop_capacity, R1, 0);
    } else {
        sljit_emit_op2(c, SLJIT_OR, R1, 0, R1, 0, SLJIT_IMM, (long)p.gc);
        sljit_emit_op1(c, SLJIT_MOV_U32, m | R0, l.obj_gc, R1, 0);
        sljit_emit_op1(c, SLJIT_MOV_U32, m | R0, l.obj_prop_capacity, SLJIT_IMM, (long)p.prop_capacity);
    }
    if (p.proto_off == PROTO_ON_STACK) {
        sljit_emit_op1(c, SLJIT_MOV, R1, 0, m | reg_sp(), SUB_VALUE_OFF);
    } else {
        sljit_emit_op1(c, SLJIT_MOV, R1, 0, m | self.heap, p.proto_off);
    }
    sljit_emit_op1(c, SLJIT_MOV, m | R0, l.obj_proto, R1, 0);
    sljit_emit_op1(c, SLJIT_MOV_U32, m | R0, l.obj_shape, SLJIT_IMM, (long)p.shape_id);
    sljit_emit_op1(c, SLJIT_MOV_U32, m | R0, l.obj_prop_count, SLJIT_IMM, (long)p.prop_count);
    sljit_emit_op1(c, SLJIT_MOV_U32, m | R0, l.obj_array_size, SLJIT_IMM, (long)p.array_size);
    sljit_emit_op1(c, SLJIT_MOV_U32, m | R0, l.obj_array_used, SLJIT_IMM, (long)p.array_used);
    // HObject.init_header: the inline slots, after the words GcBits.inline_words counts.
    sljit_emit_op2(c, SLJIT_ADD, R1, 0, R0, 0, SLJIT_IMM, (long)((types::GcBits)p.gc).inline_words * 8);
    sljit_emit_op1(c, SLJIT_MOV, m | R0, l.obj_props, R1, 0);
    sljit_emit_op1(c, SLJIT_MOV, m | R0, l.obj_prop_hash, SLJIT_IMM, 0);
    if (p.array_inline != 0) {
        sljit_emit_op1(c, SLJIT_MOV_U32, m | R0, l.obj_array_len, SLJIT_IMM, (long)p.array_used);
        sljit_emit_op1(c, SLJIT_MOV_U32, m | R0, l.obj_array_inline_cap, SLJIT_IMM, (long)p.array_inline);
    }
    if (p.copy_from != 0) {
        sljit_emit_op1(c, SLJIT_MOV, R1, 0, SLJIT_IMM, p.copy_from);
        for (uint k = 0; k < p.array_used; k++) {
            sljit_emit_op1(c, SLJIT_MOV, R2, 0, m | R1, (long)k * 8);
            sljit_emit_op1(c, SLJIT_MOV, m | R0, l.obj_size_array + (long)k * 8, R2, 0);
        }
    }
    if (p.fill_count != 0) {
        sljit_emit_op1(c, SLJIT_MOV, R1, 0, SLJIT_IMM, l.undefined_bits);
        for (uint k = 0; k < p.fill_count; k++) {
            sljit_emit_op1(c, SLJIT_MOV, m | R0, p.fill_off + (long)k * 8, R1, 0);
        }
    }
}

// NEWARR_FILL's elements, registers B to B+C-1: each one an object, a string or another inert
// value other than undefined (which would make the array packed), checked before anything is
// allocated; a jump in `slow` leaves nothing changed.
fn void Asm.emit_fill_checks(&self, Jumps* slow) {
    void* c = self.c;
    Layout* l = self.lay;
    for (uint k = 0; k < self.w.c; k++) {
        self.load(R3, self.w.b + k);
        slow.add(sljit_emit_cmp(c, SLJIT_EQUAL, R3, 0, SLJIT_IMM, l.undefined_bits));
        void* inert = sljit_emit_cmp(c, SLJIT_LESS, R3, 0, SLJIT_IMM, K_STRING_START);
        sljit_emit_op2(c, SLJIT_XOR, R4, 0, R3, 0, SLJIT_IMM, K_STRING_START);
        void* string = sljit_emit_cmp(c, SLJIT_LESS, R4, 0, span_op(), span_w());
        sljit_emit_op2(c, SLJIT_XOR, R3, 0, R3, 0, k_obj_op(), k_obj_w());
        slow.add(sljit_emit_cmp(c, SLJIT_GREATER_EQUAL, R3, 0, span_op(), span_w()));
        sljit_set_label(inert, sljit_emit_label(c));
        sljit_set_label(string, sljit_emit_label(c));
    }
}

// Copy NEWARR_FILL's elements into the fresh array in R0, counting each string as
// Heap.init_slot_ref does; a pinned one is not. The array is young, and
// gray while marking, so the stores need no barrier. Uses R1, R3 and R4.
fn void Asm.emit_fill_elements(&self) {
    void* c = self.c;
    Layout* l = self.lay;
    int m = SLJIT_MEM;
    for (uint k = 0; k < self.w.c; k++) {
        self.load(R3, self.w.b + k);
        sljit_emit_op1(c, SLJIT_MOV, m | R0, l.obj_size_array + (long)k * 8, R3, 0);
        sljit_emit_op2(c, SLJIT_XOR, R4, 0, R3, 0, SLJIT_IMM, K_STRING_START);
        void* not_string = sljit_emit_cmp(c, SLJIT_GREATER_EQUAL, R4, 0, span_op(), span_w());
        sljit_emit_op1(c, SLJIT_MOV_U32, R1, 0, m | R4, l.str_refcount);
        void* pinned = sljit_emit_cmp(c, SLJIT_EQUAL | SLJIT_32, R1, 0, SLJIT_IMM, (long)types::STRING_PINNED_REFCOUNT);
        sljit_emit_op2(c, SLJIT_ADD, R1, 0, R1, 0, SLJIT_IMM, 1);
        sljit_emit_op1(c, SLJIT_MOV_U32, m | R4, l.str_refcount, R1, 0);
        self.emit_needs_teardown();
        sljit_set_label(not_string, sljit_emit_label(c));
        sljit_set_label(pinned, sljit_emit_label(c));
    }
}

// heap::needs_teardown for the fresh object in R0, which now holds a counted string: the
// object's bit in its page's teardown bitmap. Uses R1 and R4.
fn void Asm.emit_needs_teardown(&self) {
    void* c = self.c;
    // The word: the page, plus the bitmap's offset, plus the granule over 64 words.
    sljit_emit_op2(c, SLJIT_AND, R1, 0, R0, 0, SLJIT_IMM, pagepool::PAGE_SIZE - 1);
    sljit_emit_op2(c, SLJIT_LSHR, R1, 0, R1, 0, SLJIT_IMM, pagepool::GRANULE_SHIFT + 6);
    sljit_emit_op2(c, SLJIT_SHL, R1, 0, R1, 0, SLJIT_IMM, 3);
    sljit_emit_op2(c, SLJIT_AND, R4, 0, R0, 0, SLJIT_IMM, -(long)pagepool::PAGE_SIZE);
    sljit_emit_op2(c, SLJIT_ADD, R1, 0, R1, 0, R4, 0);
    // The bit: the granule's low six bits.
    sljit_emit_op2(c, SLJIT_LSHR, R4, 0, R0, 0, SLJIT_IMM, pagepool::GRANULE_SHIFT);
    sljit_emit_op2(c, SLJIT_AND, R4, 0, R4, 0, SLJIT_IMM, 63);
    sljit_emit_op2(c, SLJIT_SHL, R4, 0, SLJIT_IMM, 1, R4, 0);
    long off = self.lay.page_teardown;
    sljit_emit_op2(c, SLJIT_OR, SLJIT_MEM | R1, off, SLJIT_MEM | R1, off, R4, 0);
}

// The bump allocation and accounting of Heap.alloc_plain_object / Heap.alloc_inline_array
// as ObjectPool.alloc and Heap.adopt_object do them. In: R1 the ObjectPool. Out: R0 the block,
// counted, and R1 the bits shade_new_header adds to its GcBits word: while marking, the old bit,
// with the block marked in its page; or R0 0 with nothing changed. Uses R1 to R4.
fn void Asm.emit_alloc_body(&self) {
    void* c = self.c;
    Layout* l = self.lay;
    int m = SLJIT_MEM;
    int hp = m | self.heap;
    Jumps fail;
    // While marking, room in the gray queue for the new object.
    sljit_emit_op1(c, SLJIT_MOV_U8, R0, 0, hp, l.heap_gc_phase);
    void* not_marking = sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R0, 0, SLJIT_IMM, (long)heap::GcPhase.MARK.ordinal);
    sljit_emit_op1(c, SLJIT_MOV, R2, 0, hp, l.heap_gray_len);
    fail.add(sljit_emit_cmp(c, SLJIT_GREATER_EQUAL, R2, 0, hp, l.heap_gray_cap));
    sljit_set_label(not_marking, sljit_emit_label(c));
    // charge_allocation must not request a collection, unless one is requested or running
    // already, and the memory check must not fire.
    sljit_emit_op1(c, SLJIT_MOV, R2, 0, hp, l.heap_trigger);
    void* untriggered = sljit_emit_cmp(c, SLJIT_SIG_GREATER, R2, 0, SLJIT_IMM, 1);
    void* running = sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R0, 0, SLJIT_IMM, (long)heap::GcPhase.IDLE.ordinal);
    sljit_emit_op1(c, SLJIT_MOV_U8, R2, 0, hp, l.heap_gc_requested);
    fail.add(sljit_emit_cmp(c, SLJIT_EQUAL, R2, 0, SLJIT_IMM, 0));
    sljit_set_label(untriggered, sljit_emit_label(c));
    sljit_set_label(running, sljit_emit_label(c));
    sljit_emit_op1(c, SLJIT_MOV_U32, R3, 0, hp, l.heap_mem_budget);
    fail.add(sljit_emit_cmp(c, SLJIT_LESS_EQUAL, R3, 0, SLJIT_IMM, 1));
    // The block at the pool's bump pointer, when a whole one fits below its limit.
    sljit_emit_op1(c, SLJIT_MOV, R2, 0, m | R1, l.pool_bump);
    sljit_emit_op1(c, SLJIT_MOV, R3, 0, m | R1, l.pool_block_size);
    sljit_emit_op2(c, SLJIT_ADD, R3, 0, R2, 0, R3, 0);
    fail.add(sljit_emit_cmp(c, SLJIT_GREATER, R3, 0, m | R1, l.pool_limit));
    sljit_emit_op1(c, SLJIT_MOV, m | R1, l.pool_bump, R3, 0);
    // R2 is the block. Heap.adopt_object's counts.
    sljit_emit_op1(c, SLJIT_MOV, R4, 0, hp, l.heap_trigger);
    sljit_emit_op2(c, SLJIT_SUB, R4, 0, R4, 0, SLJIT_IMM, 1);
    sljit_emit_op1(c, SLJIT_MOV, hp, l.heap_trigger, R4, 0);
    sljit_emit_op1(c, SLJIT_MOV_U32, R4, 0, hp, l.heap_mem_budget);
    sljit_emit_op2(c, SLJIT_SUB, R4, 0, R4, 0, SLJIT_IMM, 1);
    sljit_emit_op1(c, SLJIT_MOV_U32, hp, l.heap_mem_budget, R4, 0);
    sljit_emit_op1(c, SLJIT_MOV_U32, R4, 0, hp, l.heap_live);
    sljit_emit_op2(c, SLJIT_ADD, R4, 0, R4, 0, SLJIT_IMM, 1);
    sljit_emit_op1(c, SLJIT_MOV_U32, hp, l.heap_live, R4, 0);
    // The debt of a cycle in progress (charge_allocation).
    sljit_emit_op1(c, SLJIT_MOV_U8, R4, 0, hp, l.heap_gc_phase);
    void* idle = sljit_emit_cmp(c, SLJIT_EQUAL, R4, 0, SLJIT_IMM, 0);
    sljit_emit_op1(c, SLJIT_MOV, R4, 0, hp, l.heap_alloc_since);
    sljit_emit_op2(c, SLJIT_ADD, R4, 0, R4, 0, SLJIT_IMM, 1);
    sljit_emit_op1(c, SLJIT_MOV, hp, l.heap_alloc_since, R4, 0);
    sljit_set_label(idle, sljit_emit_label(c));
    // shade_new_header: while marking, the block joins the gray queue (gray_push), is marked in
    // its page's bitmap for the cycle (Heap.gc_alloc_bitmap; the page has the cycle's epoch) and
    // is promoted.
    sljit_emit_op1(c, SLJIT_MOV, R1, 0, SLJIT_IMM, 0);
    sljit_emit_op1(c, SLJIT_MOV_U8, R4, 0, hp, l.heap_gc_phase);
    void* unshaded = sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R4, 0, SLJIT_IMM, (long)heap::GcPhase.MARK.ordinal);
    sljit_emit_op1(c, SLJIT_MOV, R3, 0, hp, l.heap_gray_items);
    sljit_emit_op1(c, SLJIT_MOV, R4, 0, hp, l.heap_gray_len);
    sljit_emit_op1(c, SLJIT_MOV, mem_index(R3, R4), 3, R2, 0);
    sljit_emit_op2(c, SLJIT_ADD, R4, 0, R4, 0, SLJIT_IMM, 1);
    sljit_emit_op1(c, SLJIT_MOV, hp, l.heap_gray_len, R4, 0);
    sljit_emit_op1(c, SLJIT_MOV_U32, R4, 0, hp, l.heap_marked_count);
    sljit_emit_op2(c, SLJIT_ADD, R4, 0, R4, 0, SLJIT_IMM, 1);
    sljit_emit_op1(c, SLJIT_MOV_U32, hp, l.heap_marked_count, R4, 0);
    sljit_emit_op1(c, SLJIT_MOV_U32, R4, 0, hp, l.heap_gray_count);
    sljit_emit_op2(c, SLJIT_ADD, R4, 0, R4, 0, SLJIT_IMM, 1);
    sljit_emit_op1(c, SLJIT_MOV_U32, hp, l.heap_gray_count, R4, 0);
    // The bitmap word: the page, plus the bitmap's offset, plus the granule over 64 words.
    sljit_emit_op2(c, SLJIT_AND, R3, 0, R2, 0, SLJIT_IMM, pagepool::PAGE_SIZE - 1);
    sljit_emit_op2(c, SLJIT_XOR, R4, 0, R2, 0, R3, 0);
    sljit_emit_op2(c, SLJIT_ADD, R4, 0, R4, 0, hp, l.heap_alloc_bitmap);
    sljit_emit_op2(c, SLJIT_LSHR, R3, 0, R3, 0, SLJIT_IMM, pagepool::GRANULE_SHIFT);
    sljit_emit_op2(c, SLJIT_LSHR, R0, 0, R3, 0, SLJIT_IMM, 6);
    sljit_emit_op2(c, SLJIT_SHL, R0, 0, R0, 0, SLJIT_IMM, 3);
    sljit_emit_op2(c, SLJIT_ADD, R4, 0, R4, 0, R0, 0);
    sljit_emit_op2(c, SLJIT_AND, R3, 0, R3, 0, SLJIT_IMM, 63);
    sljit_emit_op1(c, SLJIT_MOV, R0, 0, SLJIT_IMM, 1);
    sljit_emit_op2(c, SLJIT_SHL, R0, 0, R0, 0, R3, 0);
    sljit_emit_op2(c, SLJIT_OR, R0, 0, R0, 0, m | R4, 0);
    sljit_emit_op1(c, SLJIT_MOV, m | R4, 0, R0, 0);
    sljit_emit_op1(c, SLJIT_MOV, R1, 0, SLJIT_IMM, l.old_mask);
    sljit_set_label(unshaded, sljit_emit_label(c));
    sljit_emit_op1(c, SLJIT_MOV, R0, 0, R2, 0);
    void* done = sljit_emit_jump(c, SLJIT_JUMP);
    fail.bind(sljit_emit_label(c));
    sljit_emit_op1(c, SLJIT_MOV, R0, 0, SLJIT_IMM, 0);
    sljit_set_label(done, sljit_emit_label(c));
}

// A direct call to vm::jit_alloc; a failed allocation takes the thunk, which
// repeats it and reports the failure. With the inline path first, the call is
// also that path's slow path.
fn bool Asm.emit_alloc(&self) {
    void* c = self.c;
    if (self.wide) return false;
    switch (self.w.op) {
        case NEWARR:
        case NEWARR_CONST:
        case NEWARR_FILL:
        case NEWOBJ:
        case NEWOBJ_SHAPE:
            break;
        default:
            return false;
    }
    Jumps slow;
    void* done = null;
    InlineAlloc plan;
    uint ra = self.w.a;
    if (inline_alloc_ok() && self.inline_alloc_plan(&plan)) {
        bool fill = self.w.op == Opcode.NEWARR_FILL;
        if (fill) self.emit_fill_checks(&slow);
        self.emit_inline_alloc(&plan, &slow);
        if (fill) self.emit_fill_elements();
        // The boxed object into the result register, which holds no count to release.
        sljit_emit_op2(c, SLJIT_OR, R0, 0, R0, 0, k_obj_op(), k_obj_w());
        self.store(ra, R0);
        self.track_heap_store(ra);
        done = sljit_emit_jump(c, SLJIT_JUMP);
        slow.bind(sljit_emit_label(c));
    }
    sljit_emit_op1(c, SLJIT_MOV, R1, 0, SLJIT_IMM, (long)(usz)self.f.code + (long)self.next * Instruction::size);
    sljit_emit_op1(c, SLJIT_MOV, R0, 0, self.ds, 0);
    self.c_call(SLJIT_ARGS2WWW, SLJIT_IMM, (long)(usz)&vm::jit_alloc);
    sljit_emit_op1(c, SLJIT_MOV_U8, R0, 0, R0, 0);
    self.call.add(sljit_emit_cmp(c, SLJIT_EQUAL, R0, 0, SLJIT_IMM, 0));
    if (done != null) sljit_set_label(done, sljit_emit_label(c));
    return true;
}

// NEW_OBJ of a simple constructor (CompiledFunction.classify_simple_constructor) built without a
// call: the object and its stores in line, as vm::jit_new_simple builds them. What the constructor
// is, which argument each store reads and where the stores leave the shape are in the site's
// NewSite, which jit_new_simple arms, so the code needs no feedback from before it was compiled:
// a site whose first construction comes after the function was compiled takes it as well. Every
// jump in `miss` leaves nothing changed and takes that helper. A site armed for a constructor
// with a body to run (NEW_SITE_CALLS) leaves the object in the call's receiver slot and enters the
// constructor's call entry (CALL_CONSTRUCT); `generic` is where that call declines to. Null, with
// nothing emitted, when this build does not allocate inline or the code has no room for the site.
fn NewSite* Asm.emit_new_inline(&self, Jumps* miss, Jumps* generic) {
    if (self.wide || !inline_alloc_ok() || self.new_sites == null || self.new_site_next >= self.new_site_count) return null;
    Heap* h = self.hp;
    void* c = self.c;
    Layout* l = self.lay;
    CallLayout* k = call_layout();
    int m = SLJIT_MEM;
    NewSite* site = &self.new_sites[self.new_site_next++];
    foreach (&slot : site.arg) *slot = NEW_ARG_NONE;
    // The callee: a constructable closure of the armed function, as emit_check_callee tests it.
    self.load(R1, self.w.b);
    sljit_emit_op2(c, SLJIT_XOR, R0, 0, R1, 0, k_obj_op(), k_obj_w());
    miss.add(sljit_emit_cmp(c, SLJIT_GREATER_EQUAL, R0, 0, span_op(), span_w()));
    miss.add(sljit_emit_cmp(c, SLJIT_EQUAL, R0, 0, SLJIT_IMM, 0));
    hobject::ObjFlags ctor_bit;
    ctor_bit.constructable = true;
    sljit_emit_op1(c, SLJIT_MOV_U32, R4, 0, m | R0, 0);
    sljit_emit_op2(c, SLJIT_AND, R4, 0, R4, 0, SLJIT_IMM, k.fn_mask | (long)(uint)ctor_bit);
    miss.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R4, 0, SLJIT_IMM, k.fn_want | (long)(uint)ctor_bit));
    sljit_emit_op1(c, SLJIT_MOV_S32, R4, 0, m | R0, k.fn_builtin);
    miss.add(sljit_emit_cmp(c, SLJIT_SIG_GREATER_EQUAL, R4, 0, SLJIT_IMM, 0));
    // An unarmed site holds no function, which no closure has.
    sljit_emit_op1(c, SLJIT_MOV, R4, 0, m | R0, l.fn_comp_func);
    miss.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R4, 0, SLJIT_MEM, (long)(usz)&site.cf));
    // The armed state: the constructor's shape, the epochs, and the prototype in its slot.
    sljit_emit_op1(c, SLJIT_MOV_U32, R3, 0, m | R0, l.obj_shape);
    miss.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL | SLJIT_32, R3, 0, SLJIT_MEM, (long)(usz)&site.ctor_shape));
    sljit_emit_op1(c, SLJIT_MOV, R3, 0, m | self.heap, (long)((char*)&h.prototype_epoch - (char*)h));
    miss.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R3, 0, SLJIT_MEM, (long)(usz)&site.epoch));
    sljit_emit_op1(c, SLJIT_MOV_U32, R3, 0, m | self.heap, l.heap_epoch);
    miss.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL | SLJIT_32, R3, 0, SLJIT_MEM, (long)(usz)&site.recycle));
    // Heap.set_prototype also walks the other realms when there are any.
    miss.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, m | self.heap, l.heap_realms, SLJIT_IMM, 0));
    self.prop_base(R1, R0);
    sljit_emit_op1(c, SLJIT_MOV, R3, 0, SLJIT_MEM, (long)(usz)&site.proto_off);
    sljit_emit_op2(c, SLJIT_ADD, R1, 0, R1, 0, R3, 0);
    sljit_emit_op1(c, SLJIT_MOV, R1, 0, m | R1, 0);
    // An unarmed site holds 0, which no prototype boxes to.
    miss.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R1, 0, SLJIT_MEM, (long)(usz)&site.proto_bits));
    sljit_emit_op2(c, SLJIT_XOR, R2, 0, R1, 0, k_obj_op(), k_obj_w());
    sljit_emit_op1(c, SLJIT_MOV_U32, R3, 0, m | R2, l.obj_shape);
    miss.add(sljit_emit_cmp(c, SLJIT_NOT_EQUAL | SLJIT_32, R3, 0, SLJIT_MEM, (long)(usz)&site.proto_shape));
    sljit_emit_op1(c, SLJIT_MOV, m | reg_sp(), SUB_VALUE_OFF, R2, 0);
    // Each argument a store reads is an inert value, an object or a string, which only needs a
    // count (checked before anything is allocated). R2 is the argument window.
    sljit_emit_op2(c, SLJIT_ADD, R2, 0, self.regs, 0, SLJIT_IMM, (long)(self.w.b + 2) * TVal::size);
    for (uint j = 0; j < hobject::INLINE_PROPS; j++) {
        sljit_emit_op1(c, SLJIT_MOV_U32, R1, 0, SLJIT_MEM, (long)(usz)&site.arg[j]);
        void* skip = sljit_emit_cmp(c, SLJIT_GREATER_EQUAL | SLJIT_32, R1, 0, SLJIT_IMM, (long)NEW_ARG_UNDEF);
        sljit_emit_op1(c, SLJIT_MOV, R3, 0, mem_index(R2, R1), 3);
        void* inert = sljit_emit_cmp(c, SLJIT_LESS, R3, 0, SLJIT_IMM, K_STRING_START);
        sljit_emit_op2(c, SLJIT_XOR, R4, 0, R3, 0, SLJIT_IMM, K_STRING_START);
        void* string = sljit_emit_cmp(c, SLJIT_LESS, R4, 0, span_op(), span_w());
        sljit_emit_op2(c, SLJIT_XOR, R3, 0, R3, 0, k_obj_op(), k_obj_w());
        miss.add(sljit_emit_cmp(c, SLJIT_GREATER_EQUAL, R3, 0, span_op(), span_w()));
        sljit_set_label(inert, sljit_emit_label(c));
        sljit_set_label(string, sljit_emit_label(c));
        sljit_set_label(skip, sljit_emit_label(c));
    }
    InlineAlloc plan = self.plain_object_plan();
    plan.site = site;
    self.emit_inline_alloc(&plan, miss);
    void* replays = sljit_emit_cmp(c, SLJIT_NOT_EQUAL | SLJIT_32, SLJIT_MEM, (long)(usz)&site.count, SLJIT_IMM, (long)NEW_SITE_CALLS);
    sljit_emit_op2(c, SLJIT_OR, R0, 0, R0, 0, k_obj_op(), k_obj_w());
    self.store(self.w.b + 1, R0);
    self.track_heap_store(self.w.b + 1);
    self.emit_direct_call(generic);
    void* called = sljit_emit_jump(c, SLJIT_JUMP);
    sljit_set_label(replays, sljit_emit_label(c));
    // The stores, the slots a store names (a slot past the last is NEW_ARG_NONE), then the
    // count and the shape they lead to.
    long base = (long)hobject::plain_object_gc(false, 0).inline_words * 8;
    sljit_emit_op2(c, SLJIT_ADD, R2, 0, self.regs, 0, SLJIT_IMM, (long)(self.w.b + 2) * TVal::size);
    Jumps stored;
    for (uint j = 0; j < hobject::INLINE_PROPS; j++) {
        sljit_emit_op1(c, SLJIT_MOV_U32, R1, 0, SLJIT_MEM, (long)(usz)&site.arg[j]);
        stored.add(sljit_emit_cmp(c, SLJIT_EQUAL | SLJIT_32, R1, 0, SLJIT_IMM, (long)NEW_ARG_NONE));
        void* given = sljit_emit_cmp(c, SLJIT_NOT_EQUAL | SLJIT_32, R1, 0, SLJIT_IMM, (long)NEW_ARG_UNDEF);
        sljit_emit_op1(c, SLJIT_MOV, R3, 0, SLJIT_IMM, l.undefined_bits);
        void* have = sljit_emit_jump(c, SLJIT_JUMP);
        sljit_set_label(given, sljit_emit_label(c));
        sljit_emit_op1(c, SLJIT_MOV, R3, 0, mem_index(R2, R1), 3);
        sljit_set_label(have, sljit_emit_label(c));
        sljit_emit_op1(c, SLJIT_MOV, m | R0, base + (long)j * 8, R3, 0);
        // A string the slot holds is counted, as TVal.incref_if_heap does; a pinned one is not.
        sljit_emit_op2(c, SLJIT_XOR, R4, 0, R3, 0, SLJIT_IMM, K_STRING_START);
        void* not_string = sljit_emit_cmp(c, SLJIT_GREATER_EQUAL, R4, 0, span_op(), span_w());
        sljit_emit_op1(c, SLJIT_MOV_U32, R1, 0, m | R4, l.str_refcount);
        void* pinned = sljit_emit_cmp(c, SLJIT_EQUAL | SLJIT_32, R1, 0, SLJIT_IMM, (long)types::STRING_PINNED_REFCOUNT);
        sljit_emit_op2(c, SLJIT_ADD, R1, 0, R1, 0, SLJIT_IMM, 1);
        sljit_emit_op1(c, SLJIT_MOV_U32, m | R4, l.str_refcount, R1, 0);
        self.emit_needs_teardown();
        sljit_set_label(not_string, sljit_emit_label(c));
        sljit_set_label(pinned, sljit_emit_label(c));
    }
    stored.bind(sljit_emit_label(c));
    sljit_emit_op1(c, SLJIT_MOV_U32, R1, 0, SLJIT_MEM, (long)(usz)&site.count);
    sljit_emit_op1(c, SLJIT_MOV_U32, m | R0, l.obj_prop_count, R1, 0);
    sljit_emit_op1(c, SLJIT_MOV_U32, R1, 0, SLJIT_MEM, (long)(usz)&site.final_shape);
    sljit_emit_op1(c, SLJIT_MOV_U32, m | R0, l.obj_shape, R1, 0);
    sljit_emit_op2(c, SLJIT_OR, R0, 0, R0, 0, k_obj_op(), k_obj_w());
    self.store(self.w.a, R0);
    self.track_heap_store(self.w.a);
    self.count(&self.stats.fast_hits[0], self.w.op);
    sljit_set_label(called, sljit_emit_label(c));
    return site;
}
