// Baseline tier allocation ops: NEWARR, NEWARR_CONST, NEWOBJ and NEWOBJ_SHAPE.
//
// A fresh ordinary object or short literal array is built inline. The pool pop
// and the allocation accounting are one shared subroutine (ALLOC_SUB); the
// caller writes the header the allocator would (hobject::plain_object_flags and
// its siblings give both the same words). The inline path takes only the state
// in which Heap.adopt_object does no more than count: collection idle or
// sweeping (not marking, which shades the new object), the trigger and the
// memory-check budgets not about to expire, a page with a free or never-used
// block that is not the pool's last, and room in the young list. Anything else
// calls the C helper that runs the threaded handler's body, which does the
// rest. Neither path collects: the trigger only requests a collection for the
// next safepoint.
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
    long pool;           // offset of the PagePool in the Heap
    uint flags;
    uint gc;
    uint shape_id;
    uint prop_capacity;
    uint prop_count;
    uint array_size;
    uint array_inline;   // the inline literal array capacity, or 0 for an object
    long proto_off;      // the Heap field holding the prototype, or NEW_OBJECT_PROTO
    long fill_off;       // where the undefined slots start
    uint fill_count;
}

// The prototype is in the frame's SUB_VALUE_OFF slot, saved across the pool subroutine.
const long PROTO_ON_STACK = -1;

// The allocation the current instruction makes, or false for one the helper keeps.
// The plain object an inlined constructor builds (heap.alloc_plain_object).
fn InlineAlloc Asm.plain_object_plan(&self) {
    hobject::ObjFlags flags = hobject::plain_object_flags(true);
    flags.temproot = true;
    return { .pool = self.lay.heap_pool_plain, .flags = (uint)flags, .gc = (uint)hobject::plain_object_gc(false, 0),
             .prop_capacity = hobject::INLINE_PROPS, .proto_off = PROTO_ON_STACK };
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
    sljit_emit_op2(c, SLJIT_ADD, R1, 0, self.heap, 0, SLJIT_IMM, p.pool);
    self.subs.push({ .jump = sljit_emit_jump(c, SLJIT_FAST_CALL), .sub = ALLOC_SUB });
    slow.add(sljit_emit_cmp(c, SLJIT_EQUAL, R0, 0, SLJIT_IMM, 0));
    // HObject.init_header, then the prototype and the fill the caller's allocator adds.
    sljit_emit_op1(c, SLJIT_MOV_U32, m | R0, 0, SLJIT_IMM, (long)p.flags);
    sljit_emit_op1(c, SLJIT_MOV_U32, m | R0, l.obj_gc, SLJIT_IMM, (long)p.gc);
    if (p.proto_off == PROTO_ON_STACK) {
        sljit_emit_op1(c, SLJIT_MOV, R1, 0, m | reg_sp(), SUB_VALUE_OFF);
    } else {
        sljit_emit_op1(c, SLJIT_MOV, R1, 0, m | self.heap, p.proto_off);
    }
    sljit_emit_op1(c, SLJIT_MOV, m | R0, l.obj_proto, R1, 0);
    sljit_emit_op1(c, SLJIT_MOV_U32, m | R0, l.obj_shape, SLJIT_IMM, (long)p.shape_id);
    sljit_emit_op1(c, SLJIT_MOV_U32, m | R0, l.obj_prop_capacity, SLJIT_IMM, (long)p.prop_capacity);
    sljit_emit_op1(c, SLJIT_MOV_U32, m | R0, l.obj_prop_count, SLJIT_IMM, (long)p.prop_count);
    sljit_emit_op1(c, SLJIT_MOV_U32, m | R0, l.obj_array_size, SLJIT_IMM, (long)p.array_size);
    sljit_emit_op1(c, SLJIT_MOV_U32, m | R0, l.obj_array_used, SLJIT_IMM, 0);
    sljit_emit_op1(c, SLJIT_MOV, m | R0, l.obj_prop_alloc, SLJIT_IMM, 0);
    sljit_emit_op1(c, SLJIT_MOV, m | R0, l.obj_prop_hash, SLJIT_IMM, 0);
    if (p.array_inline != 0) {
        sljit_emit_op1(c, SLJIT_MOV_U32, m | R0, l.obj_array_len, SLJIT_IMM, 0);
        sljit_emit_op1(c, SLJIT_MOV_U32, m | R0, l.obj_array_inline_cap, SLJIT_IMM, (long)p.array_inline);
    }
    if (p.fill_count != 0) {
        sljit_emit_op1(c, SLJIT_MOV, R1, 0, SLJIT_IMM, l.undefined_bits);
        for (uint k = 0; k < p.fill_count; k++) {
            sljit_emit_op1(c, SLJIT_MOV, m | R0, p.fill_off + (long)k * 8, R1, 0);
        }
    }
}

// The pool pop and accounting of Heap.alloc_plain_object / Heap.alloc_inline_array
// as PagePool.alloc_uninit and Heap.adopt_object do them. In: R1 the PagePool.
// Out: R0 the block, registered in the young list and counted, or 0 with
// nothing changed. Uses R1 to R4.
fn void Asm.emit_alloc_body(&self) {
    void* c = self.c;
    Layout* l = self.lay;
    int m = SLJIT_MEM;
    int hp = m | self.heap;
    Jumps fail;
    // Not marking: the allocation would have to shade the new object.
    sljit_emit_op1(c, SLJIT_MOV_U8, R0, 0, hp, l.heap_gc_phase);
    fail.add(sljit_emit_cmp(c, SLJIT_EQUAL, R0, 0, SLJIT_IMM, (long)heap::GcPhase.MARK.ordinal));
    // charge_allocation and the memory check must not fire.
    sljit_emit_op1(c, SLJIT_MOV, R2, 0, hp, l.heap_trigger);
    fail.add(sljit_emit_cmp(c, SLJIT_SIG_LESS_EQUAL, R2, 0, SLJIT_IMM, 1));
    sljit_emit_op1(c, SLJIT_MOV_U32, R3, 0, hp, l.heap_mem_budget);
    fail.add(sljit_emit_cmp(c, SLJIT_LESS_EQUAL, R3, 0, SLJIT_IMM, 1));
    // The oldest page with room, which must keep room: the C code unlinks a page once it fills.
    sljit_emit_op1(c, SLJIT_MOV, R3, 0, m | R1, l.pool_avail_head);
    fail.add(sljit_emit_cmp(c, SLJIT_EQUAL, R3, 0, SLJIT_IMM, 0));
    sljit_emit_op1(c, SLJIT_MOV_U32, R4, 0, m | R3, l.page_used);
    sljit_emit_op2(c, SLJIT_ADD, R4, 0, R4, 0, SLJIT_IMM, 1);
    sljit_emit_op1(c, SLJIT_MOV_U32, R0, 0, m | R1, l.pool_capacity);
    fail.add(sljit_emit_cmp(c, SLJIT_GREATER_EQUAL, R4, 0, R0, 0));
    // Room in the young list.
    sljit_emit_op1(c, SLJIT_MOV, R0, 0, hp, l.heap_young_size);
    fail.add(sljit_emit_cmp(c, SLJIT_GREATER_EQUAL, R0, 0, hp, l.heap_young_cap));
    // The block: the page's freelist head, else its next never-used one.
    sljit_emit_op1(c, SLJIT_MOV, R2, 0, m | R3, l.page_freelist);
    void* bump = sljit_emit_cmp(c, SLJIT_EQUAL, R2, 0, SLJIT_IMM, 0);
    sljit_emit_op1(c, SLJIT_MOV, R0, 0, m | R2, 0);
    sljit_emit_op1(c, SLJIT_MOV, m | R3, l.page_freelist, R0, 0);
    void* got = sljit_emit_jump(c, SLJIT_JUMP);
    sljit_set_label(bump, sljit_emit_label(c));
    sljit_emit_op1(c, SLJIT_MOV, R2, 0, m | R3, l.page_bump);
    fail.add(sljit_emit_cmp(c, SLJIT_EQUAL, R2, 0, SLJIT_IMM, 0));
    // The next bump pointer is null once no further block fits in the page.
    sljit_emit_op1(c, SLJIT_MOV, R1, 0, m | R1, l.pool_block_size);
    sljit_emit_op2(c, SLJIT_ADD, R0, 0, R2, 0, R1, 0);
    sljit_emit_op2(c, SLJIT_ADD, R1, 0, R0, 0, R1, 0);
    sljit_emit_op2(c, SLJIT_ADD, R4, 0, R3, 0, SLJIT_IMM, pagepool::PAGE_SIZE);
    void* fits = sljit_emit_cmp(c, SLJIT_LESS_EQUAL, R1, 0, R4, 0);
    sljit_emit_op1(c, SLJIT_MOV, R0, 0, SLJIT_IMM, 0);
    sljit_set_label(fits, sljit_emit_label(c));
    sljit_emit_op1(c, SLJIT_MOV, m | R3, l.page_bump, R0, 0);
    sljit_set_label(got, sljit_emit_label(c));
    // R2 is the block, R3 its page. Commit: the page's count, then Heap.adopt_object's.
    sljit_emit_op1(c, SLJIT_MOV_U32, R4, 0, m | R3, l.page_used);
    sljit_emit_op2(c, SLJIT_ADD, R4, 0, R4, 0, SLJIT_IMM, 1);
    sljit_emit_op1(c, SLJIT_MOV_U32, m | R3, l.page_used, R4, 0);
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
    // register_allocation: append to the young list.
    sljit_emit_op1(c, SLJIT_MOV, R3, 0, hp, l.heap_young_entries);
    sljit_emit_op1(c, SLJIT_MOV, R4, 0, hp, l.heap_young_size);
    sljit_emit_op1(c, SLJIT_MOV, mem_index(R3, R4), 3, R2, 0);
    sljit_emit_op2(c, SLJIT_ADD, R4, 0, R4, 0, SLJIT_IMM, 1);
    sljit_emit_op1(c, SLJIT_MOV, hp, l.heap_young_size, R4, 0);
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
        self.emit_inline_alloc(&plan, &slow);
        // The boxed object into the result register, which holds no count to release.
        sljit_emit_op2(c, SLJIT_OR, R0, 0, R0, 0, SLJIT_IMM, K_OBJ);
        self.store(ra, R0);
        self.track_heap_store(ra);
        done = sljit_emit_jump(c, SLJIT_JUMP);
        slow.bind(sljit_emit_label(c));
    }
    sljit_emit_op2(c, SLJIT_ADD, R1, 0, self.code, 0, SLJIT_IMM, (long)self.next * Instruction::size);
    sljit_emit_op1(c, SLJIT_MOV, R0, 0, self.ds, 0);
    sljit_emit_icall(c, SLJIT_CALL, SLJIT_ARGS2WWW, SLJIT_IMM, (long)(usz)&vm::jit_alloc);
    sljit_emit_op1(c, SLJIT_MOV_U8, R0, 0, R0, 0);
    self.call.add(sljit_emit_cmp(c, SLJIT_EQUAL, R0, 0, SLJIT_IMM, 0));
    if (done != null) sljit_set_label(done, sljit_emit_label(c));
    return true;
}
