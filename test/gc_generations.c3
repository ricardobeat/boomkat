// Exercise collection transitions directly so callback promotion and
// remembered-owner lifetime do not depend on a JavaScript allocation cadence.
module gc_generations;

import boomkat::heap;
import boomkat::hobject;
import boomkat::types;
import boomkat::hstring;
import std::io;
import boomkat::compiler;
import boomkat::lexer;
import boomkat::vm;
import boomkat::bytecode;

fn int main() {
    Heap* h = heap::create(null, null, null, null, null)!!;
    defer h.destroy();
    HObject* owner = h.alloc_object(ObjClass.OBJECT)!!;
    h.register_gc_root((HeapHeader*)owner);
    h.mark_and_sweep(true, true);
    h.finish_sweep(true);
    assert(owner.gc.old);

    h.native_frame_depth = 1;
    HObject* child = h.alloc_object(ObjClass.OBJECT)!!;
    h.set_prototype(owner, child);
    h.mark_and_sweep(true, true);
    h.finish_sweep(false);
    assert(!child.gc.old);
    assert(owner.gc.remembered);

    h.mark_and_sweep(true, false);
    assert(h.gc_minor);
    assert(!child.gc.old);
    assert(owner.gc.remembered);

    h.native_frame_depth = 0;
    h.mark_and_sweep(true, false);
    h.finish_sweep(true);
    assert(child.gc.old);
    assert(!owner.gc.remembered);

    child = h.alloc_object(ObjClass.OBJECT)!!;
    h.set_prototype(owner, child);
    h.gc_roots.clear();
    h.mark_and_sweep(true, true);
    h.finish_sweep(true);
    assert(h.live_obj_count == 0);
    assert(h.remembered.len() == 0);
    {
        ObjectRoot scoped;
        HObject* local = h.alloc_object(ObjClass.OBJECT)!!;
        h.push_object_root(&scoped, local);
        defer h.pop_object_root(&scoped);
        h.mark_and_sweep(true, true);
        h.finish_sweep(true);
        assert(local.gc.old);
        assert(h.live_obj_count == 1);
    }
    h.mark_and_sweep(true, true);
    h.finish_sweep(true);
    assert(h.live_obj_count == 0);
    check_string_owners(h);
    check_register_string_owners();
    io::printfn("gc-generations: callback major, minor, promotion and dead owners passed");
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
