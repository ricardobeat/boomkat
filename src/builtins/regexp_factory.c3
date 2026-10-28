module boomkat::builtins @feat(!NO_REGEXP);

import boomkat::types;
import boomkat::bytecode;
import boomkat::heap;
import boomkat::hstring;
import boomkat::hobject;
import boomkat::re_bindings;

// Helper: create a RegExp HObject from a pattern string with JS flags.
// Used by matchAll for the non-RegExp arg path.
// Returns null on failure (allocation or compile error).
fn HObject* create_regexp_from_string(Heap* heap, HString* pattern, int js_flags) {
    // Compute engine flags from js_flags (only i, m, s, u, y, d, v affect compilation)
    int engine_flags = 0;
    if (js_flags & 2)   engine_flags |= re_bindings::RE_FLAG_IGNORECASE;
    if (js_flags & 4)   engine_flags |= re_bindings::RE_FLAG_MULTILINE;
    if (js_flags & 8)   engine_flags |= re_bindings::RE_FLAG_DOTALL;
    if (js_flags & 16)  engine_flags |= re_bindings::RE_FLAG_UNICODE;
    if (js_flags & 32)  engine_flags |= re_bindings::RE_FLAG_STICKY;
    if (js_flags & 64)  engine_flags |= re_bindings::RE_FLAG_INDICES;
    if (js_flags & 128) engine_flags |= re_bindings::RE_FLAG_UNICODE_SETS;

    // Compile the regexp from the pattern's CESU-8 text.
    StrBuf pattern_text;
    pattern_text.init(heap);
    defer pattern_text.free();
    char[] pattern_bytes = cesu8_text(&pattern_text, pattern);
    char[128] error_buf;
    void* compiled = re_bindings::re_compile(
        pattern_bytes.ptr, pattern_bytes.len,
        engine_flags, &error_buf, 128
    );
    if (compiled == null) return null;

    HObject*? obj_raw = heap.alloc_object(hobject::ObjClass.REGEXP);
    if (catch err = obj_raw) {
        re_bindings::re_free(compiled);
        return null;
    }
    HObject* obj = obj_raw;
    heap.set_prototype(obj, heap.regexp_proto);
    // Takes over re_compile's initial ref, released by re_free on finalize.
    (*obj.extra_ptr()).regexp.regexp_data = compiled;
    (*obj.extra_ptr()).regexp.flags = js_flags;

    // Store pattern string as primitive_value
    (*obj.extra_ptr()).prim.primitive_value.set_string(pattern);

    // Set lastIndex to 0
    HString* li_key = heap.str(heap::BuiltinStr.LAST_INDEX);
    TVal zero_tv; zero_tv.set_fastint(0);
    obj.put_prop(li_key, zero_tv, hobject::PROP_FLAGS_WEC, heap);

    return obj;

}
