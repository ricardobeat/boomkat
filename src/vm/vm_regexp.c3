module boomkat::vm @feat(!NO_REGEXP);

import boomkat::types;
import boomkat::bytecode;
import boomkat::heap;
import boomkat::hstring;
import boomkat::hobject;
import boomkat::builtins;
import boomkat::re_bindings;

// RETEST: `A = /lit/.test(B)` with the literal at constant C (see bytecode.c3).
// The fast path needs the literal's matcher in the per-function cache, which
// the generic path's NEWREGEXP fills on first execution.
fn void? vm_retest(Dispatch* ds, TVal* ra, TVal* rb, DecodedInsn insn) {
    Vm* vm = ds.vm;
    CompiledFunction* func = vm.current_func;
    uint k = insn.c;
    HString* s = builtins::regexp_plain_input(rb);
    if (s != null && func.regexp_cache != null && k < func.regexp_cache_count
        && func.regexp_cache[k].program != null && builtins::regexp_proto_pristine(vm.heap)) {
        int[2 * re_bindings::RE_MAX_CAPTURES] caps @noinit;
        re_bindings::ReInterrupt interrupt = { &heap::regexp_interrupt, vm.heap };
        int r = re_bindings::re_run(func.regexp_cache[k].program, s.data_ptr(), (int)s.unit_len(), 0, s.is_wide() ? 1 : 0,
                                    &caps, caps.len, &interrupt);
        if (vm.heap.uncatchable_throw) {
            if (!vm_throw_error(vm, vm.heap.err_proto, "interrupted", ds.act, &ds.curr_pc, &ds.needs_restart)) return VM_ERROR~;
            return;
        }
        vm.heap.set_reg_boolean(ra, r == re_bindings::RE_MATCH);
        return;
    }
    // Generic path: the RegExp object lives in A while its `test` runs.
    DecodedInsn create = { Opcode.NEWREGEXP, insn.a, k & 0xFF, k >> 8 };
    dispatch_objects(ds, Opcode.NEWREGEXP, ra, rb, null, create)!;
    if (!ra.is_object()) return;
    HObject* rx = (HObject*)ra.get_heapptr();
    TVal test_fn;
    test_fn.set_undefined();
    TVal res;
    res.set_undefined();
    if (builtins::js_get(vm, vm.heap, rx, (HString*)vm.heap.str_intern("test"), &test_fn)) {
        if (!builtins::is_callable_tval(test_fn)) {
            if (!vm_throw_error_fmt(vm, vm.heap.type_err_proto, "%s is not a function", "test",
                    ds.act, &ds.curr_pc, &ds.needs_restart)) {
                return VM_ERROR~;
            }
            return;
        }
        TVal arg = *rb;
        res = vm.heap.call_fn(vm, test_fn, &arg, 1, *ra);
    }
    if (vm.heap.has_error) {
        vm.heap.has_error = false;
        if (!vm_throw_value(vm, vm.heap.error_value, ds.act, &ds.curr_pc, &ds.needs_restart)) {
            vm.has_error = true;
            vm.heap.has_error = true;
            return VM_ERROR~;
        }
        return;
    }
    vm.heap.tval_copy_ref(ra, &res);
}

macro TVal? vm_new_regexp(Dispatch* ds, TVal* ra, DecodedInsn insn) {
    Vm* vm = ds.vm;
    // See NEWOBJ: clear ra before any allocation below.
    vm.heap.set_reg_undefined(ra);
    // A = dest register, BC = constant pool index of "/pattern/flags" string
    HObject* obj = regexp_literal_new(vm.heap, vm.current_func, ds.constants, insn.get_bc());
    if (obj != null) {
        vm.heap.set_reg_object(ra, obj);
        track_heap_store(ds.act, ra, (uint)insn.a);
    }
    return (TVal){};
}

// NEWREGEXP through vm::jit_alloc: false, with nothing done, when the object
// could not be made, which the instruction's generic path then reports.
fn bool alloc_newregexp(Dispatch* ds, Instruction insn) {
    HObject* obj = regexp_literal_new(ds.heap, ds.vm.current_func, ds.constants, insn.get_bc());
    if (obj == null) return false;
    TVal* ra = ds.regs_base + insn.a;
    ra.set_object(obj);
    track_heap_store(ds.act, ra, (uint)insn.a);
    return true;
}

// The site of the regexp literal whose "/pattern/flags" text is constant `k`,
// parsed and compiled on its first evaluation; null when the function keeps no
// sites or the text is not a literal's.
fn RegExpLiteral* regexp_literal_site(Heap* heap, CompiledFunction* func, TVal* constants, uint k) {
    if (func.regexp_cache == null || k >= func.regexp_cache_count) return null;
    RegExpLiteral* lit = &func.regexp_cache[k];
    if (lit.source != null) return lit;
    if (!constants[k].is_string()) return null;
    HString* raw = (HString*)constants[k].get_heapptr();
    uint len = raw.unit_len();
    // Flags are letters: the closing '/' is the last unit before them.
    uint end_slash = len - 1;
    while (end_slash > 0 && ((raw.unit_at(end_slash) | 0x20) >= 'a' && (raw.unit_at(end_slash) | 0x20) <= 'z')) {
        end_slash--;
    }
    if (end_slash == 0 || raw.unit_at(0) != '/' || raw.unit_at(end_slash) != '/') return null;
    int flags = 0;
    int js_flags = 0;
    for (uint i = end_slash + 1; i < len; i++) {
        switch (raw.unit_at(i)) {
            case 'g': js_flags |= 1;
            case 'i': js_flags |= 2; flags |= re_bindings::RE_FLAG_IGNORECASE;
            case 'm': js_flags |= 4; flags |= re_bindings::RE_FLAG_MULTILINE;
            case 's': js_flags |= 8; flags |= re_bindings::RE_FLAG_DOTALL;
            case 'u': js_flags |= 16; flags |= re_bindings::RE_FLAG_UNICODE;
            case 'y': js_flags |= 32; flags |= re_bindings::RE_FLAG_STICKY;
            case 'd': js_flags |= 64; flags |= re_bindings::RE_FLAG_INDICES;
            case 'v': js_flags |= 128; flags |= re_bindings::RE_FLAG_UNICODE_SETS;
        }
    }
    HString* source = heap.str_slice(raw, 1, end_slash);
    builtins::StrBuf text;
    text.init(heap);
    defer text.free();
    char[] bytes = builtins::cesu8_text(&text, source);
    char[128] error_buf;
    lit.program = re_bindings::re_compile(bytes.ptr, bytes.len, flags, &error_buf, 128);
    lit.flags = js_flags;
    lit.source = source;
    ((HeapHeader*)source).incref();
    return lit;
}

// A new RegExp object for the literal at constant `k` (ECMA-262 RegExpCreate:
// every evaluation creates one), or null when it could not be created.
fn HObject* regexp_literal_new(Heap* heap, CompiledFunction* func, TVal* constants, uint k) {
    RegExpLiteral* lit = regexp_literal_site(heap, func, constants, k);
    if (lit == null) return null;
    HObject*? made = heap.alloc_object(hobject::ObjClass.REGEXP);
    if (catch made) return null;
    HObject* obj = made;
    obj.prototype = heap.regexp_proto;
    re_bindings::re_ref(lit.program);
    (*obj.extra_ptr()).regexp.regexp_data = lit.program;
    (*obj.extra_ptr()).regexp.flags = lit.flags;
    (*obj.extra_ptr()).prim.primitive_value.set_string(lit.source);
    // A text that did not compile still makes a RegExp, so typeof works.
    if (lit.program != null) builtins::regexp_init_last_index(heap, obj);
    return obj;
}
