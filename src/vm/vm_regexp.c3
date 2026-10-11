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
        int r = re_bindings::re_run(func.regexp_cache[k], s.get_cstr(), (int)s.blen, 0, (int)s.is_ascii(),
                                    &out_start, &out_end, &out_num, &caps_start, &caps_end, 0);
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
            char[] raw = raw_hs.get_data();
            usz len = raw.len;

            // Parse "/pattern/flags" by finding the closing '/'
            // Flags are only letters, so scan backwards past them
            usz end_slash = len - 1;
            while (end_slash > 0 &&
                   ((raw[end_slash] >= 'a' && raw[end_slash] <= 'z') ||
                    (raw[end_slash] >= 'A' && raw[end_slash] <= 'Z'))) {
                end_slash--;
            }

            if (end_slash > 0 && raw[0] == '/' && raw[end_slash] == '/') {
                char[] pattern_data = raw[1..end_slash - 1];
                char[] flag_data = {};
                if (end_slash + 1 < len) {
                    flag_data = raw[end_slash + 1..len - 1];
                }

                // Convert JS flags to libregexp flag bits
                int flags = 0;
                int js_flags = 0;  // 1=g, 2=i, 4=m, 8=s, 16=u, 32=y, 64=d, 128=v
                for (usz i = 0; i < flag_data.len; i++) {
                    char f = flag_data[i];
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

                // Compile the regexp. A literal's pattern and flags are
                // fixed, so cache the compiled (refcounted) bytecode on
                // the CompiledFunction keyed by this literal's constant
                // index. On a cache hit we take a fresh reference and skip
                // re_compile entirely; QuickJS likewise compiles a literal
                // once. Each per-evaluation RegExp object is still a fresh
                // object (ES §22.2.3.2) that drops its ref on finalize.
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
                    // Allocate a heap buffer so patterns of any length are
                    // supported (the old 256-byte stack buffer truncated
                    // patterns longer than 255 chars).
                    usz plen = pattern_data.len;
                    char* pattern_buf_heap = (char*)alloc::malloc_try(mem, (sz)(plen + 1)) ?? null;
                    if (pattern_buf_heap != null) {
                        mem::copy(pattern_buf_heap, pattern_data.ptr, (sz)(plen));
                        pattern_buf_heap[plen] = 0;
                    }
                    char[128] error_buf;
                    compiled = (pattern_buf_heap != null)
                        ? re_bindings::re_compile(pattern_buf_heap, plen, flags, &error_buf, 128)
                        : null;
                    if (pattern_buf_heap != null) mem::free(pattern_buf_heap);

                    // Store in the per-literal cache and take an extra ref
                    // for the cache to hold (the object below owns the
                    // ref returned by re_compile). Freed when the function
                    // is freed.
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
                        // Holds one reference: re_compile's initial one, or
                        // the fresh re_ref taken when `from_cache` gave
                        // us the literal cache's shared bytecode.
                        (*obj.extra_ptr()).regexp.regexp_data = compiled;
                        (*obj.extra_ptr()).regexp.flags = js_flags;
                        // Store pattern string as primitive_value
                        HString* pattern_hs = intern_string(vm, pattern_data);
                        (*obj.extra_ptr()).prim.primitive_value.set_string(pattern_hs);
                        // Set lastIndex (ES5 §15.10.7), the only own data property
                        HString* lastindex_key = vm.heap.str(heap::BuiltinStr.LAST_INDEX);
                        TVal lastindex_tv;
                        lastindex_tv.set_fastint(0);
                        obj.put_prop(lastindex_key, lastindex_tv, hobject::PROP_FLAGS_WENC, ds.vm.heap);
                        vm.heap.set_reg_object(ra, obj);
                        track_heap_store(ds.act, ra, (uint)insn.a);
                    } else {
                        // If alloc failed, free the compiled regexp
                        re_bindings::re_free(compiled);
                        vm.heap.set_reg_undefined(ra);
                    }
                } else {
                    // re_compile failed, but still create an empty regexp object
                    // so typeof works correctly
                    HObject*? obj_raw = vm.heap.alloc_object(hobject::ObjClass.REGEXP);
                    if (try obj = obj_raw) {
                        obj.prototype = vm.heap.regexp_proto;
                        (*obj.extra_ptr()).regexp.regexp_data = null;
                        (*obj.extra_ptr()).regexp.flags = js_flags;
                        HString* pattern_hs = intern_string(vm, pattern_data);
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
