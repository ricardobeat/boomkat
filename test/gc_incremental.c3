// Exercise one-work-unit incremental transitions and string ownership.
module gc_incremental;

import boomkat::heap;
import boomkat::hobject;
import boomkat::types;
import boomkat::hstring;
import std::io;
import boomkat::compiler;
import boomkat::lexer;
import boomkat::vm;
import boomkat::bytecode;

struct AllocCounter { long live; }

struct RejectionProbe { HObject* next; uint calls; }

struct MicrotaskProbe { Heap* heap; HObject* result; bool survived; }

fn TVal microtask_probe_handler(void* vm_ptr, TVal handler, TVal* arg) {
    MicrotaskProbe* probe = (MicrotaskProbe*)vm_ptr;
    probe.result = probe.heap.alloc_object(ObjClass.OBJECT)!!;
    TVal result;
    result.set_object(probe.result);
    return result;
}

fn void microtask_probe_after(void* heap_ptr, void* vm_ptr, TVal result, TVal downstream) {
    Heap* h = (Heap*)heap_ptr;
    MicrotaskProbe* probe = (MicrotaskProbe*)vm_ptr;
    h.gc_begin_cycle(true);
    finish_cycle(h);
    probe.survived = result.get_heapptr() == (void*)probe.result &&
                     probe.result.flags.obj_class == ObjClass.OBJECT;
}

fn void test_microtask_result_root() {
    Heap* h = heap::create(null, null, null, null, null)!!;
    defer h.destroy();
    MicrotaskProbe probe = { .heap = h };
    h.call_handler_fn = &microtask_probe_handler;
    h.microtask_after_fn = &microtask_probe_after;
    HObject* downstream = h.alloc_object(ObjClass.OBJECT)!!;
    TVal undefined_value; undefined_value.set_undefined();
    TVal downstream_value; downstream_value.set_object(downstream);
    h.enqueue_microtask(undefined_value, undefined_value, downstream_value);
    h.drain_microtasks(&probe);
    assert(probe.survived);
}

fn void reentrant_rejection_tracker(void* heap_ptr, void* vm_ptr, TVal promise,
                                    TVal reason, void* udata) {
    Heap* h = (Heap*)heap_ptr;
    RejectionProbe* probe = (RejectionProbe*)udata;
    probe.calls++;
    if (probe.calls == 1) {
        h.track_rejection(probe.next);
        h.gc_begin_cycle(true);
        finish_cycle(h);
        assert(h.unhandled_count == 2);
    }
}

fn void test_reentrant_rejection_report() {
    Heap* h = heap::create(null, null, null, null, null)!!;
    defer h.destroy();
    HObject* first = h.alloc_object(ObjClass.PROMISE)!!;
    HObject* second = h.alloc_object(ObjClass.PROMISE)!!;
    (*first.extra_ptr()).promise.state = hobject::PROMISE_REJECTED;
    (*second.extra_ptr()).promise.state = hobject::PROMISE_REJECTED;
    ObjectRoot second_root;
    h.push_object_root(&second_root, second);
    RejectionProbe probe = { .next = second, .calls = 0 };
    h.set_rejection_tracker(&reentrant_rejection_tracker, &probe);
    h.track_rejection(first);
    h.drain_microtasks(null);
    assert(probe.calls == 1 && h.unhandled_count == 1);
    h.drain_microtasks(null);
    assert(probe.calls == 2 && h.unhandled_count == 0);
    h.pop_object_root(&second_root);
}

fn void* tracked_alloc(void* data, usz size) {
    void* ptr = heap::default_alloc(null, size);
    if (ptr != null) ((AllocCounter*)data).live++;
    return ptr;
}

fn void* tracked_realloc(void* data, void* ptr, usz size) {
    void* replacement = heap::default_realloc(null, ptr, size);
    if (ptr == null && replacement != null) ((AllocCounter*)data).live++;
    if (ptr != null && size == 0) ((AllocCounter*)data).live--;
    return replacement;
}

fn void tracked_free(void* data, void* ptr) {
    if (ptr == null) return;
    ((AllocCounter*)data).live--;
    heap::default_free(null, ptr);
}

fn void finish_cycle(Heap* h) {
    uint steps = 0;
    while (h.gc_phase != heap::GcPhase.IDLE && steps++ < 1000000) h.gc_step(1, true);
    assert(h.gc_phase == heap::GcPhase.IDLE);
}

fn void test_root_insert() {
    Heap* h = heap::create(null, null, null, null, null)!!;
    defer h.destroy();
    HObject* value = h.alloc_object(ObjClass.OBJECT)!!;
    h.gc_begin_cycle(true);
    uint steps = 0;
    while (h.gc_root_stage <= 1 && steps++ < 1000) h.gc_step(1, true);
    assert(h.gc_phase == heap::GcPhase.MARK);
    ObjectRoot root;
    h.push_object_root(&root, value);
    finish_cycle(h);
    assert(h.live_obj_count == 1);
    h.pop_object_root(&root);
    h.gc_begin_cycle(true);
    finish_cycle(h);
    assert(h.live_obj_count == 0);
}

fn void test_black_owner_insert() {
    Heap* h = heap::create(null, null, null, null, null)!!;
    defer h.destroy();
    HObject* owner = h.alloc_object(ObjClass.OBJECT)!!;
    HObject* child = h.alloc_object(ObjClass.OBJECT)!!;
    HObject* filler = h.alloc_object(ObjClass.ARRAY)!!;
    for (uint i = 0; i < 128; i++) {
        TVal v; v.set_fastint((long)i);
        assert(filler.set_array_idx(i, v, h));
    }
    ObjectRoot filler_root;
    ObjectRoot owner_root;
    h.push_object_root(&filler_root, filler);
    h.push_object_root(&owner_root, owner);
    h.gc_begin_cycle(true);
    bool saw_owner = false;
    uint steps = 0;
    while (steps++ < 1000) {
        h.gc_step(1, true);
        if (h.gc_scan_object == owner) saw_owner = true;
        if (saw_owner && h.gc_scan_object != owner) break;
    }
    assert(saw_owner && h.gc_phase == heap::GcPhase.MARK);
    h.set_prototype(owner, child);
    finish_cycle(h);
    assert(owner.prototype == child && h.live_obj_count == 3);
    h.pop_object_root(&owner_root);
    h.pop_object_root(&filler_root);
}

fn void test_partial_object_teardown() {
    Heap* h = heap::create(null, null, null, null, null)!!;
    defer h.destroy();
    HObject* dead = h.alloc_object(ObjClass.ARRAY)!!;
    for (uint i = 0; i < 512; i++) {
        TVal v; v.set_fastint((long)i);
        assert(dead.set_array_idx(i, v, h));
    }
    h.gc_begin_cycle(true);
    uint steps = 0;
    while (h.gc_phase != heap::GcPhase.SWEEP && steps++ < 1000) h.gc_step(1, true);
    assert(h.gc_phase == heap::GcPhase.SWEEP);
    while (h.gc_free_object != dead && steps++ < 1000) h.gc_step(1, true);
    assert(h.gc_free_object == dead);
    h.gc_step(1, true);
    assert(h.gc_free_object == dead && h.gc_free_index > 0 && h.gc_free_index < 512);
    finish_cycle(h);
    assert(h.live_obj_count == 0);
}

fn void test_slot_shift_behind_cursor() {
    Heap* h = heap::create(null, null, null, null, null)!!;
    defer h.destroy();
    HObject* owner = h.alloc_object(ObjClass.OBJECT)!!;
    HObject* first = h.alloc_object(ObjClass.OBJECT)!!;
    HObject* moved = h.alloc_object(ObjClass.OBJECT)!!;
    HObject* last = h.alloc_object(ObjClass.OBJECT)!!;
    HString* key0 = h.str_intern("shift0");
    HString* key1 = h.str_intern("shift1");
    HString* key2 = h.str_intern("shift2");
    TVal value;
    value.set_object(first);
    assert(owner.put_prop(key0, value, hobject::PROP_FLAGS_WEC, h));
    value.set_object(moved);
    assert(owner.put_prop(key1, value, hobject::PROP_FLAGS_WEC, h));
    value.set_object(last);
    assert(owner.put_prop(key2, value, hobject::PROP_FLAGS_WEC, h));
    ObjectRoot root;
    h.push_object_root(&root, owner);
    h.gc_begin_cycle(true);
    uint steps = 0;
    while (!(h.gc_scan_object == owner && h.gc_scan_stage == 1 && h.gc_scan_index == 1)
        && steps++ < 1000) h.gc_step(1, true);
    assert(h.gc_phase == heap::GcPhase.MARK && steps < 1000);
    assert(owner.delete_prop(key0, h));
    finish_cycle(h);
    assert(owner.prop_count == 2);
    assert(owner.prop_values()[0].get().get_heapptr() == (void*)moved);
    assert(moved.flags.obj_class == ObjClass.OBJECT);
    h.pop_object_root(&root);
}

fn void test_generator_scan_and_release() {
    Heap* h = heap::create(null, null, null, null, null)!!;
    defer h.destroy();
    HObject* gen = h.alloc_object(ObjClass.GENERATOR)!!;
    GeneratorState* gs = h.alloc_generator_state();
    assert(gs != null);
    gs.num_regs = 128;
    gs.saved_regs = (TVal*)h.alloc_func(h.heap_udata, (usz)gs.num_regs * TVal::size);
    assert(gs.saved_regs != null);
    for (uint i = 0; i < gs.num_regs; i++) gs.saved_regs[i].set_undefined();
    HObject* held = h.alloc_object(ObjClass.OBJECT)!!;
    gs.saved_regs[127].set_object(held);
    (*gen.extra_ptr()).gen.generator_data = (void*)gs;
    heap::gs_acquire(gs);
    ObjectRoot root;
    h.push_object_root(&root, gen);
    h.gc_begin_cycle(true);
    uint steps = 0;
    while (!(h.gc_scan_generator == gs && h.gc_generator_cursor.index > 0)
        && steps++ < 2000) h.gc_step(1, true);
    assert(h.gc_phase == heap::GcPhase.MARK && steps < 2000);
    finish_cycle(h);
    assert(held.flags.obj_class == ObjClass.OBJECT);
    h.pop_object_root(&root);
    h.gc_begin_cycle(true);
    finish_cycle(h);
    assert(h.generator_states == null);
}

fn void test_host_scope_after_cursor() {
    Heap* h = heap::create(null, null, null, null, null)!!;
    defer h.destroy();
    HObject* child = h.alloc_object(ObjClass.OBJECT)!!;
    long depth = h.host_scope_push();
    assert(depth >= 0);
    HObject* backing = h.host_scopes[(uint)depth].values;
    HObject* filler = h.alloc_object(ObjClass.ARRAY)!!;
    HObject* tail = h.alloc_object(ObjClass.ARRAY)!!;
    for (uint i = 0; i < 128; i++) {
        TVal v; v.set_fastint((long)i);
        assert(filler.set_array_idx(i, v, h));
        assert(tail.set_array_idx(i, v, h));
    }
    ObjectRoot filler_root;
    h.push_object_root(&filler_root, filler);
    h.gc_begin_cycle(true);
    bool saw_backing = false;
    bool tail_rooted = false;
    ObjectRoot tail_root;
    uint steps = 0;
    while (steps++ < 2000) {
        h.gc_step(1, true);
        if (h.gc_scan_object == backing) {
            saw_backing = true;
            if (!tail_rooted) {
                h.push_object_root(&tail_root, tail);
                tail_rooted = true;
            }
        }
        if (saw_backing && h.gc_scan_object != backing && h.gc_root_stage > 17) break;
    }
    assert(saw_backing && h.gc_phase == heap::GcPhase.MARK);
    TVal value; value.set_object(child);
    assert(h.host_scope_set((uint)depth, 0, value));
    finish_cycle(h);
    TVal read; read.set_undefined();
    assert(h.host_scope_get((uint)depth, 0, &read));
    assert(read.get_heapptr() == (void*)child && child.flags.obj_class == ObjClass.OBJECT);
    h.host_scope_pop();
    h.pop_object_root(&tail_root);
    h.pop_object_root(&filler_root);
    h.gc_begin_cycle(true);
    finish_cycle(h);
    assert(h.live_obj_count == 0);
}

fn void test_vm_call_churn_progress() {
    Heap* h = heap::create(null, null, null, null, null)!!;
    defer h.destroy();
    Vm* machine = vm::vm_create(h)!!;
    defer vm::vm_destroy(machine);
    char[] source = "function f(n) { if (n === 0) return 1; "
        "try { return f(n - 1); } finally {} } "
        "for (var i = 0; i < 1000; i++) f(3);";
    Lexer lex = lexer::lexer_init(source, h, "gc-call-churn.js");
    defer lex.free_arena();
    CompiledFunction* function = compiler::compile(&lex, h)!!;
    h.gc_begin_cycle(true);
    machine.execute(function)!!;
    assert(h.gc_phase != heap::GcPhase.MARK || h.marked_obj_count > 0);
    finish_cycle(h);
    assert(h.gc_phase == heap::GcPhase.IDLE);
}

fn void test_allocation_only_loop_progress() {
    Heap* h = heap::create(null, null, null, null, null)!!;
    defer h.destroy();
    Vm* machine = vm::vm_create(h)!!;
    defer vm::vm_destroy(machine);
    char[] source = "var sink; for (var i = 0; i < 120000; i++) "
        "sink = { value: i };";
    Lexer lex = lexer::lexer_init(source, h, "gc-allocation-loop.js");
    defer lex.free_arena();
    CompiledFunction* function = compiler::compile(&lex, h)!!;
    // The loop has no calls, so only allocation pacing and backward branches
    // can advance the collector while old sink values become unreachable.
    for (uint epoch = 0; epoch < 6; epoch++) {
        machine.execute(function)!!;
        assert(h.live_obj_count < 250000);
    }
    assert(h.peak_live_obj_count < 350000);
}

fn void test_phase_teardown() {
    for (uint mode = 0; mode < 3; mode++) {
        AllocCounter counter;
        Heap* h = heap::create(&tracked_alloc, &tracked_realloc, &tracked_free, &counter, null)!!;
        HObject* dead = h.alloc_object(ObjClass.ARRAY)!!;
        for (uint i = 0; i < 256; i++) {
            TVal v; v.set_fastint((long)i);
            assert(dead.set_array_idx(i, v, h));
        }
        h.gc_begin_cycle(true);
        if (mode == 0) {
            h.gc_step(1, true);
            assert(h.gc_phase == heap::GcPhase.MARK);
        } else {
            uint steps = 0;
            while (h.gc_free_object != dead && steps++ < 2000) h.gc_step(1, true);
            assert(h.gc_free_object == dead);
            h.gc_step(1, true);
            assert(h.gc_free_index > 0 && h.gc_free_index < 256);
        }
        if (mode == 2) {
            h.destroy();
        } else {
            h.reset();
            assert(h.gc_phase == heap::GcPhase.IDLE);
            HObject* survivor = h.alloc_object(ObjClass.OBJECT)!!;
            ObjectRoot root;
            h.push_object_root(&root, survivor);
            h.gc_begin_cycle(true);
            finish_cycle(h);
            assert(h.live_obj_count == 1);
            h.pop_object_root(&root);
            h.destroy();
        }
        assert(counter.live == 0);
    }
}

fn int main() {
    test_microtask_result_root();
    test_reentrant_rejection_report();
    test_root_insert();
    test_black_owner_insert();
    test_slot_shift_behind_cursor();
    test_generator_scan_and_release();
    test_host_scope_after_cursor();
    test_vm_call_churn_progress();
    test_allocation_only_loop_progress();
    test_phase_teardown();
    test_partial_object_teardown();
    {
        Heap* h = heap::create(null, null, null, null, null)!!;
        defer h.destroy();
        ObjectRoot scoped;
        HObject* local = h.alloc_object(ObjClass.OBJECT)!!;
        h.push_object_root(&scoped, local);
        defer h.pop_object_root(&scoped);
        h.gc_begin_cycle(true);
        finish_cycle(h);
        assert(h.live_obj_count == 1);
        check_string_owners(h);
    }
    check_register_string_owners();
    io::printfn("gc-incremental: root insertion, object barrier, bounded teardown and strings passed");
    return 0;
}


// Ownership remains balanced across shape copies and same-value replacement.
fn void check_string_owners(Heap* h) {
    HString* key = h.str_intern("owned-shape-key");
    uint table_refs = key.refcount;
    {
        HObject* obj = h.alloc_object(ObjClass.OBJECT)!!;
        ObjectRoot scoped;
        h.push_object_root(&scoped, obj);
        defer h.pop_object_root(&scoped);
        assert(obj.put_prop(key, types::make_undefined(), hobject::PROP_FLAGS_WEC, h));
        uint shared_refs = key.refcount;
        assert(shared_refs > table_refs);
        obj.make_shape_private(h);
        assert(key.refcount == shared_refs + 1);
        // Replacing a private shape acquires and releases one independent copy.
        obj.make_shape_private(h);
        assert(key.refcount == shared_refs + 1);
        assert(obj.delete_prop(key, h));
        assert(key.refcount == shared_refs);
    }
    // The first few named slots live in the object header. Reclamation must
    // release their string owners even without an external property block.
    HString* inline_string = hstring::hstring_alloc(h, "inline-owned", 0)!!;
    TVal inline_value;
    inline_value.set_string(inline_string);
    HObject* inline_obj = h.alloc_object(ObjClass.OBJECT)!!;
    HString* inline_key = h.str_intern("inline-key");
    assert(inline_obj.put_prop(inline_key, inline_value, hobject::PROP_FLAGS_WEC, h));
    assert(inline_obj.prop_alloc == null && inline_string.refcount == 2);
    h.gc_begin_cycle(true);
    finish_cycle(h);
    assert(inline_string.refcount == 1);
    h.decref_tval(&inline_value);
    inline_value.set_undefined();
    // No intern-table owner: the slot is this string's sole reference.
    HString* value = hstring::hstring_alloc(h, "same-string", 0)!!;
    TVal slot;
    slot.set_string(value);
    assert(value.refcount == 1);
    h.set_reg_string(&slot, value);
    assert(value.refcount == 1);
    assert(value.equals("same-string"));
    h.decref_tval(&slot);
    slot.set_undefined();
    io::printfn("string-owners: private shapes and aliased replacement passed");
}

// Primitive register overwrites must release strings during execution.
fn void check_register_string_owners() {
    Heap* h = heap::create(null, null, null, null, null)!!;
    defer h.destroy();
    Vm* machine = vm::vm_create(h)!!;
    defer vm::vm_destroy(machine);
    char[] source = "var callback = String.prototype.repeat.bind('x', 2048); "
        "for (var i = 0; i < 1000; i++) { "
        "var value = 'a'.replace(/a/, callback); "
        "if (value.length !== 2048) throw new Error('length'); "
        "var parsed = JSON.parse('[\"' + 'j'.repeat(2048) + '\"]'); "
        "if (parsed[0].length !== 2048) throw new Error('JSON length'); }";
    Lexer lex = lexer::lexer_init(source, h, "string-owners.js");
    defer lex.free_arena();
    CompiledFunction* function = compiler::compile(&lex, h)!!;
    machine.execute(function)!!;
    h.mark_and_sweep(true, true);
    h.finish_sweep(true);
    uint retained = 0;
    for (uint i = 0; i < h.large_string_count; i++) {
        if (h.large_strings[i].blen == 2048) retained++;
    }
    // The globals retain one replacement string and one parsed string.
    assert(retained <= 2);
    io::printfn("string-owners: callback results and register reuse stay bounded");
}
