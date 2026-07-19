/// ArrayBuffer constructor and prototype (ES2015 §24.1) — Stage 1 of plan 049.
/// TypedArray/DataView element access is out of scope here; this file only
/// implements the byte-buffer backing store and its public surface.
module duktape::builtins;

import duktape::types;
import libc;
import duktape::hstring;
import duktape::heap;
import duktape::hobject;
import duktape::env;

/// ES2022 §7.1.22 ToIndex, specialized to the [0, INT32_MAX] range this
/// engine caps buffer lengths at (mirrors QuickJS's int cap).
/// Returns false (and sets ctx.should_throw) on failure.
fn bool arraybuffer_to_index(BuiltinContext* ctx, TVal* val, uint* out_len) {
    *out_len = 0;
    if (val.is_fastint()) {
        long v = val.get_fastint();
        if (v < 0) {
            arraybuffer_throw_range_error(ctx, "Invalid array buffer length");
            return false;
        }
        if (v > 2147483647) {
            arraybuffer_throw_range_error(ctx, "Invalid array buffer length");
            return false;
        }
        *out_len = (uint)v;
        return true;
    }

    double d = builtin_to_integer_vm(ctx, val);
    if (ctx.should_throw) return false;
    if (d != d) { *out_len = 0; return true; } // NaN -> 0 per ToIndex(ToIntegerOrInfinity)
    if (d < 0.0) {
        arraybuffer_throw_range_error(ctx, "Invalid array buffer length");
        return false;
    }
    if (d > 2147483647.0) {
        arraybuffer_throw_range_error(ctx, "Invalid array buffer length");
        return false;
    }
    *out_len = (uint)d;
    return true;
}

/// ES2022 §7.1.22 ToIndex proper (range [0, 2^53-1], no engine-specific cap).
/// Used by the ArrayBuffer(length) constructor, which must perform ToIndex
/// (steps 1-5 of the runtime semantics) before AllocateArrayBuffer's
/// OrdinaryCreateFromConstructor (step 6 -> §24.1.1.1 step 1) — while the
/// engine's own too-large-to-allocate uint32 cap plays the role of
/// CreateByteDataBlock's allocation failure and must be checked only *after*
/// the instance prototype has been resolved (see
/// data-allocation-after-object-creation.js: a throwing new.target.prototype
/// getter must win over the RangeError from an unrepresentable length).
/// Returns false (and sets ctx.should_throw) only for genuine ToIndex
/// failures (negative or >2^53-1); NaN coerces to 0.
fn bool arraybuffer_to_index_wide(BuiltinContext* ctx, TVal* val, double* out_len) {
    *out_len = 0.0;
    if (val.is_fastint()) {
        long v = val.get_fastint();
        if (v < 0) {
            arraybuffer_throw_range_error(ctx, "Invalid array buffer length");
            return false;
        }
        *out_len = (double)v;
        return true;
    }

    double d = builtin_to_integer_vm(ctx, val);
    if (ctx.should_throw) return false;
    if (d != d) { *out_len = 0.0; return true; } // NaN -> 0 per ToIndex(ToIntegerOrInfinity)
    if (d < 0.0) {
        arraybuffer_throw_range_error(ctx, "Invalid array buffer length");
        return false;
    }
    if (d > 9007199254740991.0) { // 2^53 - 1
        arraybuffer_throw_range_error(ctx, "Invalid array buffer length");
        return false;
    }
    *out_len = d;
    return true;
}

fn void arraybuffer_throw_type_error(BuiltinContext* ctx, char[] msg) {
    HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
    if (try err = err_raw) {
        err.prototype = ctx.heap.type_err_proto;
        HString* msg_str = builtin_intern_string(ctx.heap, msg);
        if (msg_str != null) {
            TVal msg_val;
            msg_val.set_string(msg_str);
            HString* msg_key = builtin_intern_string(ctx.heap, "message");
            err.put_prop(msg_key, msg_val, hobject::PROP_FLAGS_WC);
        }
        ctx.should_throw = true;
        ctx.throw_value.set_object(err);
    }
}

fn void arraybuffer_throw_range_error(BuiltinContext* ctx, char[] msg) {
    HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
    if (try err = err_raw) {
        err.prototype = ctx.heap.range_err_proto;
        HString* msg_str = builtin_intern_string(ctx.heap, msg);
        if (msg_str != null) {
            TVal msg_val;
            msg_val.set_string(msg_str);
            HString* msg_key = builtin_intern_string(ctx.heap, "message");
            err.put_prop(msg_key, msg_val, hobject::PROP_FLAGS_WC);
        }
        ctx.should_throw = true;
        ctx.throw_value.set_object(err);
    }
}

/// True iff obj is an ArrayBuffer instance (used by isView negatively and
/// by slice/detach to validate the receiver).
fn bool is_arraybuffer_obj(HObject* obj) {
    return obj != null && obj.flags.obj_class == hobject::ObjClass.ARRAYBUFFER;
}

/// True iff cls is one of the buffer-view classes (TypedArray or DataView).
fn bool is_bufferview_class(hobject::ObjClass cls) {
    return cls == hobject::ObjClass.DATAVIEW
        || (cls >= hobject::ObjClass.INT8ARRAY && cls <= hobject::ObjClass.FLOAT64ARRAY);
}

/// GetPrototypeFromConstructor (ES2022 §9.1.15) for ArrayBuffer's
/// OrdinaryCreateFromConstructor (§24.1.1.1 AllocateArrayBuffer step 1). Unlike
/// the general-purpose builtin_proto_from_new_target (which silently treats a
/// throwing "prototype" getter as absent), this must propagate the throw —
/// AllocateArrayBuffer's ReturnIfAbrupt(obj) happens before the Data Block is
/// allocated. Sets ctx.should_throw and returns null on error.
fn HObject* arraybuffer_instance_proto(BuiltinContext* ctx, HObject* fallback_proto) {
    HObject* nt = ctx.new_target;
    if (nt == null) return fallback_proto;
    HString* proto_key = (HString*)ctx.heap.strs[heap::BuiltinStr.PROTOTYPE];
    if (proto_key == null) return fallback_proto;
    TVal? proto_tv = builtins_generic_get(nt, proto_key, ctx);
    if (ctx.should_throw) return null;
    if (try ptv = proto_tv) {
        if (ptv.is_object() && ptv.get_heapptr() != null) {
            return (HObject*)ptv.get_heapptr();
        }
    }
    return fallback_proto;
}

// ============================================================================
// ArrayBuffer(length) constructor — ES2015 §24.1.2.1
// ============================================================================

fn void builtin_arraybuffer(BuiltinContext* ctx) {
    if (!ctx.is_constructor) {
        arraybuffer_throw_type_error(ctx, "Constructor ArrayBuffer requires 'new'");
        return;
    }

    TVal len_arg;
    len_arg.set_undefined();
    if (ctx.argc >= 1) len_arg = ctx.regs[ctx.base_reg];

    double byte_length_wide = 0.0;
    if (!arraybuffer_to_index_wide(ctx, &len_arg, &byte_length_wide)) {
        return;
    }

    HObject* instance_proto = arraybuffer_instance_proto(ctx, ctx.heap.arraybuffer_proto);
    if (ctx.should_throw) return;

    HObject*? raw = ctx.heap.alloc_object(hobject::ObjClass.ARRAYBUFFER);
    if (catch err = raw) {
        ctx.result.set_undefined();
        return;
    }
    HObject* obj = raw;
    obj.prototype = instance_proto;
    (*obj.extra_ptr()).ab.data = null;
    (*obj.extra_ptr()).ab.byte_length = 0;
    (*obj.extra_ptr()).ab.views_head = null;

    uint byte_length = 0;
    if (byte_length_wide > 2147483647.0) {
        arraybuffer_throw_range_error(ctx, "Invalid array buffer length");
        return;
    }
    byte_length = (uint)byte_length_wide;

    char* data = null;
    if (byte_length > 0) {
        data = (char*)ctx.heap.alloc_func(ctx.heap.heap_udata, (usz)byte_length);
        if (data == null) {
            arraybuffer_throw_range_error(ctx, "Out of memory allocating ArrayBuffer");
            return;
        }
        mem::clear(data, (sz)((usz)byte_length));
    }
    (*obj.extra_ptr()).ab.data = data;
    (*obj.extra_ptr()).ab.byte_length = byte_length;

    ctx.result.set_object(obj);
}

// ============================================================================
// ArrayBuffer.prototype.byteLength getter — ES2015 §24.1.4.1
// ============================================================================

fn void builtin_arraybuffer_proto_bytelength_get(BuiltinContext* ctx) {
    TVal this_val = ctx.this_val;
    if (!this_val.is_object() || this_val.get_heapptr() == null) {
        arraybuffer_throw_type_error(ctx, "ArrayBuffer.prototype.byteLength called on non-object");
        return;
    }
    HObject* obj = (HObject*)this_val.get_heapptr();
    if (!is_arraybuffer_obj(obj)) {
        arraybuffer_throw_type_error(ctx, "ArrayBuffer.prototype.byteLength called on incompatible receiver");
        return;
    }
    if (((*obj.extra_ptr()).ab.byte_length == 0xFFFFFFFFu)) {
        ctx.result.set_fastint(0);
        return;
    }
    ctx.result.set_fastint((long)(*obj.extra_ptr()).ab.byte_length);
}

// ============================================================================
// ArrayBuffer.prototype.detached getter (stage 6 spec addition, but the
// primitive underneath — data==null — already models detach precisely).
// ============================================================================

fn void builtin_arraybuffer_proto_detached_get(BuiltinContext* ctx) {
    TVal this_val = ctx.this_val;
    if (!this_val.is_object() || this_val.get_heapptr() == null) {
        arraybuffer_throw_type_error(ctx, "ArrayBuffer.prototype.detached called on non-object");
        return;
    }
    HObject* obj = (HObject*)this_val.get_heapptr();
    if (!is_arraybuffer_obj(obj)) {
        arraybuffer_throw_type_error(ctx, "ArrayBuffer.prototype.detached called on incompatible receiver");
        return;
    }
    ctx.result.set_boolean(((*obj.extra_ptr()).ab.byte_length == 0xFFFFFFFFu));
}

// ============================================================================
// ArrayBuffer.prototype.slice(start, end) — ES2015 §24.1.4.3
// ============================================================================

fn void builtin_arraybuffer_proto_slice(BuiltinContext* ctx) {
    TVal this_val = ctx.this_val;
    if (!this_val.is_object() || this_val.get_heapptr() == null) {
        arraybuffer_throw_type_error(ctx, "ArrayBuffer.prototype.slice called on non-object");
        return;
    }
    HObject* obj = (HObject*)this_val.get_heapptr();
    if (!is_arraybuffer_obj(obj)) {
        arraybuffer_throw_type_error(ctx, "ArrayBuffer.prototype.slice called on incompatible receiver");
        return;
    }
    if (((*obj.extra_ptr()).ab.byte_length == 0xFFFFFFFFu)) {
        arraybuffer_throw_type_error(ctx, "ArrayBuffer.prototype.slice: buffer is detached");
        return;
    }

    long len = (long)(*obj.extra_ptr()).ab.byte_length;

    TVal start_arg; start_arg.set_undefined();
    TVal end_arg;   end_arg.set_undefined();
    if (ctx.argc >= 1) start_arg = ctx.regs[ctx.base_reg];
    if (ctx.argc >= 2) end_arg   = ctx.regs[ctx.base_reg + 1];

    long rel_start = 0;
    if (!start_arg.is_undefined()) {
        double d = builtin_to_integer_vm(ctx, &start_arg);
        if (ctx.should_throw) return;
        rel_start = (long)d;
    }
    long start_idx;
    if (rel_start < 0) {
        start_idx = len + rel_start;
        if (start_idx < 0) start_idx = 0;
    } else {
        start_idx = rel_start;
        if (start_idx > len) start_idx = len;
    }

    long rel_end = len;
    if (!end_arg.is_undefined()) {
        double d = builtin_to_integer_vm(ctx, &end_arg);
        if (ctx.should_throw) return;
        rel_end = (long)d;
    }
    long end_idx;
    if (rel_end < 0) {
        end_idx = len + rel_end;
        if (end_idx < 0) end_idx = 0;
    } else {
        end_idx = rel_end;
        if (end_idx > len) end_idx = len;
    }

    long new_len = end_idx - start_idx;
    if (new_len < 0) new_len = 0;

    // SpeciesConstructor(O, ArrayBuffer) — ES2015 §24.1.4.3 step 12.
    HString* ctor_key = (HString*)ctx.heap.strs[heap::BuiltinStr.CONSTRUCTOR];
    TVal ctor_val;
    if (try c = builtins_generic_get(obj, ctor_key, ctx)) {
        ctor_val = c;
        if (ctx.should_throw) return;
    } else {
        return;
    }

    bool use_species = false;
    HObject* species_ctor = null;
    if (!ctor_val.is_undefined()) {
        if (!ctor_val.is_object() || ctor_val.get_heapptr() == null) {
            arraybuffer_throw_type_error(ctx, "ArrayBuffer.prototype.slice: constructor is not an object");
            return;
        }
        HObject* c_obj = (HObject*)ctor_val.get_heapptr();
        HString* species_sym = ensure_species_symbol(ctx.heap);
        if (species_sym != null) {
            TVal species_val;
            if (try s = builtins_generic_get(c_obj, species_sym, ctx)) {
                species_val = s;
                if (ctx.should_throw) return;
            } else {
                return;
            }
            if (!species_val.is_undefined() && !species_val.is_null()) {
                if (species_val.is_object() && species_val.get_heapptr() != null) {
                    HObject* s_obj = (HObject*)species_val.get_heapptr();
                    if (s_obj.is_callable()) {
                        species_ctor = s_obj;
                        use_species = true;
                    }
                }
                if (!use_species) {
                    arraybuffer_throw_type_error(ctx, "ArrayBuffer.prototype.slice: species result is not a constructor");
                    return;
                }
            }
        }
    }

    HObject* new_buf = null;
    if (use_species && species_ctor != null) {
        TVal ctor_tv; ctor_tv.set_object(species_ctor);
        TVal len_arg; len_arg.set_fastint(new_len);
        TVal result_tv = ctx.heap.construct_fn(ctx.vm, ctor_tv, &len_arg, 1, ctor_tv);
        if (ctx.heap.has_error) {
            ctx.should_throw = true;
            ctx.throw_value = ctx.heap.error_value;
            ctx.heap.has_error = false;
            return;
        }
        if (!result_tv.is_object() || result_tv.get_heapptr() == null) {
            arraybuffer_throw_type_error(ctx, "ArrayBuffer.prototype.slice: species constructor did not return an object");
            return;
        }
        new_buf = (HObject*)result_tv.get_heapptr();
        if (!is_arraybuffer_obj(new_buf)) {
            arraybuffer_throw_type_error(ctx, "ArrayBuffer.prototype.slice: species constructor did not return an ArrayBuffer");
            return;
        }
        if (new_buf == obj) {
            arraybuffer_throw_type_error(ctx, "ArrayBuffer.prototype.slice: species constructor returned the same buffer");
            return;
        }
        if ((long)(*new_buf.extra_ptr()).ab.byte_length < new_len) {
            arraybuffer_throw_type_error(ctx, "ArrayBuffer.prototype.slice: new buffer too small");
            return;
        }
    } else {
        HObject*? new_raw = ctx.heap.alloc_object(hobject::ObjClass.ARRAYBUFFER);
        if (catch err = new_raw) {
            ctx.result.set_undefined();
            return;
        }
        new_buf = new_raw;
        new_buf.prototype = ctx.heap.arraybuffer_proto;
        char* new_data = null;
        if (new_len > 0) {
            new_data = (char*)ctx.heap.alloc_func(ctx.heap.heap_udata, (usz)new_len);
            if (new_data != null) mem::clear(new_data, (sz)((usz)new_len));
        }
        (*new_buf.extra_ptr()).ab.data = new_data;
        (*new_buf.extra_ptr()).ab.byte_length = (uint)new_len;
        
        (*new_buf.extra_ptr()).ab.views_head = null;
    }

    // Re-check detach AFTER any user-observable species construction (the
    // species constructor is arbitrary user code that may detach `obj`).
    if (((*obj.extra_ptr()).ab.byte_length == 0xFFFFFFFFu)) {
        arraybuffer_throw_type_error(ctx, "ArrayBuffer.prototype.slice: source buffer detached during species construction");
        return;
    }

    if (new_len > 0 && (*new_buf.extra_ptr()).ab.data != null) {
        mem::copy((*new_buf.extra_ptr()).ab.data, (*obj.extra_ptr()).ab.data + start_idx, (sz)((usz)new_len));
    }

    ctx.result.set_object(new_buf);
}

// ============================================================================
// ArrayBuffer.isView(v) — ES2015 §24.1.3.1
// ============================================================================

fn void builtin_arraybuffer_isview(BuiltinContext* ctx) {
    TVal arg; arg.set_undefined();
    if (ctx.argc >= 1) arg = ctx.regs[ctx.base_reg];
    bool result = false;
    if (arg.is_object() && arg.get_heapptr() != null) {
        HObject* obj = (HObject*)arg.get_heapptr();
        result = is_bufferview_class(obj.flags.obj_class);
    }
    ctx.result.set_boolean(result);
}

// ============================================================================
// ArrayBuffer[Symbol.species] getter — returns `this`.
// ============================================================================

fn void builtin_arraybuffer_species_get(BuiltinContext* ctx) {
    *ctx.result = ctx.this_val;
}

// ============================================================================
// __detachArrayBuffer(buf) — hidden test262 primitive ($262.detachArrayBuffer)
// ============================================================================

fn void builtin_detach_arraybuffer(BuiltinContext* ctx) {
    TVal arg; arg.set_undefined();
    if (ctx.argc >= 1) arg = ctx.regs[ctx.base_reg];
    if (!arg.is_object() || arg.get_heapptr() == null) {
        arraybuffer_throw_type_error(ctx, "__detachArrayBuffer requires an ArrayBuffer argument");
        return;
    }
    HObject* obj = (HObject*)arg.get_heapptr();
    if (!is_arraybuffer_obj(obj)) {
        arraybuffer_throw_type_error(ctx, "__detachArrayBuffer requires an ArrayBuffer argument");
        return;
    }
    if ((*obj.extra_ptr()).ab.data != null) {
        ctx.heap.free_func(ctx.heap.heap_udata, (*obj.extra_ptr()).ab.data);
        (*obj.extra_ptr()).ab.data = null;
    }
    (*obj.extra_ptr()).ab.byte_length = 0xFFFFFFFFu;
    ctx.result.set_undefined();
}

// ============================================================================
// Registration
// ============================================================================

/// Register an ArrayBuffer.prototype accessor getter (byteLength/detached).
fn bool register_arraybuffer_accessor(HObject* proto, Heap* heap, char[] name, uint getter_index) {
    uint hash = heap.hash_string(name);
    HString* existing = heap.str_table_lookup(name, hash);
    HString* key;
    if (existing != null) {
        key = existing;
    } else {
        HString*? new_key = hstring::hstring_alloc(heap, name, hash);
        if (catch err = new_key) return false;
        heap.str_table_insert(new_key);
        key = new_key;
    }

    HObject*? func_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
    if (catch err = func_raw) return false;
    HObject* func_obj = func_raw;
    (*func_obj.extra_ptr()).func.builtin_fn_index = (int)getter_index;
    func_obj.flags.callable = true;
    func_obj.flags.constructable = false;
    func_obj.prototype = heap.function_proto;

    char[64] name_buf;
    libc::snprintf(&name_buf, 64, "get %s", name.ptr);
    usz total_len = libc::strlen((ZString)&name_buf);
    HString* fn_name = builtin_intern_string(heap, name_buf[:total_len]);
    if (fn_name != null) {
        TVal name_tv;
        name_tv.set_string(fn_name);
        HString* name_prop_key = builtin_intern_string(heap, "name");
        func_obj.put_prop(name_prop_key, name_tv, hobject::PROP_FLAGS_NWC);
    }
    HString* length_key = (HString*)heap.strs[heap::BuiltinStr.LENGTH];
    if (length_key != null) {
        TVal len_tv;
        len_tv.set_fastint(0);
        func_obj.put_prop(length_key, len_tv, hobject::PROP_FLAGS_NWC);
    }

    TVal getter_tv;
    getter_tv.set_object(func_obj);
    TVal undef;
    undef.set_undefined();
    hobject::PropFlags acc_flags;
    acc_flags.writable = false;
    acc_flags.enumerable = false;
    acc_flags.configurable = true;
    acc_flags.is_accessor = true;
    proto.put_prop(key, hobject::hobject_create_accessors(heap, getter_tv, undef), acc_flags);
    return true;
}

/// Create ArrayBuffer.prototype and register the ArrayBuffer constructor globally.
fn bool register_arraybuffer(EnvRecord* global_env, Heap* heap) {
    HObject*? proto_raw = heap.alloc_object(hobject::ObjClass.OBJECT);
    if (catch err = proto_raw) return false;
    HObject* proto = proto_raw;
    proto.prototype = heap.object_proto;
    heap.arraybuffer_proto = proto;

    HObject*? ctor_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
    if (catch err = ctor_raw) return false;
    HObject* ctor = ctor_raw;
    (*ctor.extra_ptr()).func.builtin_fn_index = (int)Builtin.ARRAYBUFFER.ordinal;

    // .constructor on the prototype
    HString* constructor_key = (HString*)heap.strs[heap::BuiltinStr.CONSTRUCTOR];
    TVal constructor_tv;
    constructor_tv.set_object(ctor);
    proto.put_prop(constructor_key, constructor_tv, hobject::PROP_FLAGS_WC);

    // .prototype on the constructor (non-writable, non-enumerable, non-configurable)
    HString* prototype_key = (HString*)heap.strs[heap::BuiltinStr.PROTOTYPE];
    TVal proto_tv;
    proto_tv.set_object(proto);
    PropFlags proto_pflags;
    proto_pflags.writable = false;
    proto_pflags.enumerable = false;
    proto_pflags.configurable = false;
    proto_pflags.is_accessor = false;
    ctor.put_prop(prototype_key, proto_tv, proto_pflags);

    // Accessors
    if (!register_arraybuffer_accessor(proto, heap, "byteLength", Builtin.ARRAYBUFFER_PROTO_BYTELENGTH_GET.ordinal)) return false;
    if (!register_arraybuffer_accessor(proto, heap, "detached", Builtin.ARRAYBUFFER_PROTO_DETACHED_GET.ordinal)) return false;

    // Methods
    if (!register_string_proto_method(proto, heap, "slice", Builtin.ARRAYBUFFER_PROTO_SLICE.ordinal)) return false;

    // @@toStringTag
    HString* tag_key = ensure_tostringtag_symbol(heap);
    if (tag_key != null) {
        TVal tag_tv;
        tag_tv.set_string(builtin_intern_string(heap, "ArrayBuffer"));
        proto.put_prop(tag_key, tag_tv, hobject::PROP_FLAGS_NWC);
    }

    // Static ArrayBuffer.isView — proper HObject so .length/.name are accessible.
    if (!register_string_proto_method(ctor, heap, "isView", Builtin.ARRAYBUFFER_ISVIEW.ordinal)) return false;

    // Static @@species accessor (returns `this` constructor).
    HString* species_sym = ensure_species_symbol(heap);
    if (species_sym != null) {
        HObject*? getter_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
        if (try getter = getter_raw) {
            getter.flags.callable = true;
            getter.flags.constructable = false;
            getter.prototype = heap.function_proto;
            (*getter.extra_ptr()).func.builtin_fn_index = (int)Builtin.ARRAYBUFFER_SPECIES_GET.ordinal;

            HString* getter_name = builtin_intern_string(heap, "get [Symbol.species]");
            if (getter_name != null) {
                TVal name_tv; name_tv.set_string(getter_name);
                getter.put_prop((void*)builtin_intern_string(heap, "name"), name_tv, hobject::PROP_FLAGS_NWC);
            }
            HString* len_key_sp = (HString*)heap.strs[heap::BuiltinStr.LENGTH];
            TVal zero_tv; zero_tv.set_fastint(0);
            getter.put_prop(len_key_sp, zero_tv, hobject::PROP_FLAGS_NWC);

            TVal getter_tv;
            getter_tv.set_object(getter);
            TVal undef;
            undef.set_undefined();
            hobject::PropFlags acc_flags;
            acc_flags.writable = false;
            acc_flags.enumerable = false;
            acc_flags.configurable = true;
            acc_flags.is_accessor = true;
            ctor.put_prop(species_sym, hobject::hobject_create_accessors(heap, getter_tv, undef), acc_flags);
        }
    }

    set_func_ctor_name_length(ctor, heap, "ArrayBuffer", 1);

    uint hash = heap.hash_string("ArrayBuffer");
    HString* existing = heap.str_table_lookup("ArrayBuffer", hash);
    HString* ctor_key;
    if (existing != null) {
        ctor_key = existing;
    } else {
        HString*? new_key = hstring::hstring_alloc(heap, "ArrayBuffer", hash);
        if (catch err = new_key) return false;
        heap.str_table_insert(new_key);
        ctor_key = new_key;
    }
    TVal ctor_val;
    ctor_val.set_object(ctor);
    env::env_declare_nonenum(global_env, ctor_key, ctor_val);

    return true;
}
