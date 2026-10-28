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
    if (rb.is_string() && func.regexp_cache != null && k < func.regexp_cache_count
        && func.regexp_cache[k] != null && builtins::regexp_proto_pristine(vm.heap)) {
        HString* s = (HString*)rb.get_heapptr();
        int out_start; int out_end; int out_num;
        int[re_bindings::RE_MAX_CAPTURES] caps_start @noinit;
        int[re_bindings::RE_MAX_CAPTURES] caps_end @noinit;
        re_bindings::ReInterrupt interrupt = { &heap::regexp_interrupt, vm.heap };
        int r = re_bindings::re_run_interruptible(func.regexp_cache[k], s.data_ptr(), (int)s.unit_len(), 0, s.is_wide() ? 1 : 0,
                                    &out_start, &out_end, &out_num, &caps_start, &caps_end, 0, &interrupt);
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
    uint bc = insn.get_bc();
    if (bc < vm.current_func.const_count) {
        TVal raw_tv = ds.constants[bc];
        if (raw_tv.is_string()) {
            HString* raw_hs = (HString*)raw_tv.get_heapptr();
            uint len = raw_hs.unit_len();

            // Parse "/pattern/flags" by finding the closing '/'
            // Flags are only letters, so scan backwards past them
            uint end_slash = len - 1;
            while (end_slash > 0 &&
                   ((raw_hs.unit_at(end_slash) >= 'a' && raw_hs.unit_at(end_slash) <= 'z') ||
                    (raw_hs.unit_at(end_slash) >= 'A' && raw_hs.unit_at(end_slash) <= 'Z'))) {
                end_slash--;
            }

            if (end_slash > 0 && raw_hs.unit_at(0) == '/' && raw_hs.unit_at(end_slash) == '/') {
                HString* pattern_hs = vm.heap.str_slice(raw_hs, 1, end_slash);

                // Convert JS flags to libregexp flag bits
                int flags = 0;
                int js_flags = 0;  // 1=g, 2=i, 4=m, 8=s, 16=u, 32=y, 64=d, 128=v
                for (uint i = end_slash + 1; i < len; i++) {
                    uint f = raw_hs.unit_at(i);
                    if (f == 'g') {
                        js_flags |= 1;
                    } else if (f == 'i') {
                        flags |= re_bindings::RE_FLAG_IGNORECASE;
                        js_flags |= 2;
                    } else if (f == 'm') {
                        flags |= re_bindings::RE_FLAG_MULTILINE;
                        js_flags |= 4;
                    } else if (f == 's') {
                        flags |= re_bindings::RE_FLAG_DOTALL;
                        js_flags |= 8;
                    } else if (f == 'u') {
                        flags |= re_bindings::RE_FLAG_UNICODE;
                        js_flags |= 16;
                    } else if (f == 'y') {
                        flags |= re_bindings::RE_FLAG_STICKY;
                        js_flags |= 32;
                    } else if (f == 'd') {
                        flags |= re_bindings::RE_FLAG_INDICES;
                        js_flags |= 64;
                    } else if (f == 'v') {
                        flags |= re_bindings::RE_FLAG_UNICODE_SETS;
                        js_flags |= 128;
                    }
                }

                // A literal's pattern and flags are fixed, so the compiled
                // (refcounted) bytecode is cached on the CompiledFunction by
                // constant index. A hit takes a new ref and skips re_compile.
                // Each evaluation still creates a new RegExp object (ECMA-262
                // RegExpCreate) that drops its ref on finalize.
                void* compiled = null;
                bool from_cache = false;
                CompiledFunction* cur_func = vm.current_func;
                if (cur_func.regexp_cache != null && bc < cur_func.regexp_cache_count) {
                    void* cached = cur_func.regexp_cache[bc];
                    if (cached != null) {
                        re_bindings::re_ref(cached);
                        compiled = cached;
                        from_cache = true;
                    }
                }

                if (!from_cache) {
                    builtins::StrBuf pattern_text;
                    pattern_text.init(vm.heap);
                    defer pattern_text.free();
                    char[] pattern_bytes = builtins::cesu8_text(&pattern_text, pattern_hs);
                    char[128] error_buf;
                    compiled = re_bindings::re_compile(pattern_bytes.ptr, pattern_bytes.len, flags, &error_buf, 128);

                    // The cache takes its own ref; the object below keeps
                    // re_compile's. The cache ref is freed with the function.
                    if (compiled != null && cur_func.regexp_cache != null
                        && bc < cur_func.regexp_cache_count) {
                        re_bindings::re_ref(compiled);
                        cur_func.regexp_cache[bc] = compiled;
                    }
                }

                if (compiled != null) {
                    HObject*? obj_raw = vm.heap.alloc_object(hobject::ObjClass.REGEXP);
                    if (try obj = obj_raw) {
                        obj.prototype = vm.heap.regexp_proto;
                        // Owns one ref: re_compile's, or the one taken on a cache hit.
                        (*obj.extra_ptr()).regexp.regexp_data = compiled;
                        (*obj.extra_ptr()).regexp.flags = js_flags;
                        (*obj.extra_ptr()).prim.primitive_value.set_string(pattern_hs);
                        // Set lastIndex, the only own data property (ECMA-262 RegExpAlloc)
                        HString* lastindex_key = vm.heap.str(heap::BuiltinStr.LAST_INDEX);
                        TVal lastindex_tv;
                        lastindex_tv.set_fastint(0);
                        obj.put_prop(lastindex_key, lastindex_tv, hobject::PROP_FLAGS_WENC, ds.vm.heap);
                        vm.heap.set_reg_object(ra, obj);
                        track_heap_store(ds.act, ra, (uint)insn.a);
                    } else {
                        re_bindings::re_free(compiled);
                        vm.heap.set_reg_undefined(ra);
                    }
                } else {
                    // re_compile failed: still create an empty RegExp so typeof works
                    HObject*? obj_raw = vm.heap.alloc_object(hobject::ObjClass.REGEXP);
                    if (try obj = obj_raw) {
                        obj.prototype = vm.heap.regexp_proto;
                        (*obj.extra_ptr()).regexp.regexp_data = null;
                        (*obj.extra_ptr()).regexp.flags = js_flags;
                        (*obj.extra_ptr()).prim.primitive_value.set_string(pattern_hs);
                        vm.heap.set_reg_object(ra, obj);
                        track_heap_store(ds.act, ra, (uint)insn.a);
                    } else {
                        vm.heap.set_reg_undefined(ra);
                    }
                }
            } else {
                vm.heap.set_reg_undefined(ra);
            }
        } else {
            vm.heap.set_reg_undefined(ra);
        }
    } else {
        vm.heap.set_reg_undefined(ra);
    }
    return (TVal){};
}
