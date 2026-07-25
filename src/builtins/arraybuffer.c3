/// ArrayBuffer constructor and prototype (ES2015 §24.1) — Stage 1 of plan 049.
/// TypedArray/DataView element access is out of scope here; this file only
/// implements the byte-buffer backing store and its public surface.
module duktape::builtins;

import duktape::types;
import std::io;
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
    builtin_throw_no_result_change(ctx, ctx.heap.type_err_proto, msg);
}

fn void arraybuffer_throw_range_error(BuiltinContext* ctx, char[] msg) {
    builtin_throw_no_result_change(ctx, ctx.heap.range_err_proto, msg);
}

/// True iff obj is a non-shared ArrayBuffer instance. ArrayBuffer.prototype
/// methods (byteLength/slice/resize/detach/…) require this — a SharedArrayBuffer
/// receiver must throw (it shares ObjClass.ARRAYBUFFER but has is_shared set).
fn bool is_arraybuffer_obj(HObject* obj) {
    return obj != null
        && obj.flags.obj_class == hobject::ObjClass.ARRAYBUFFER
        && !(*obj.extra_ptr()).ab.is_shared;
}

/// True iff obj is any ArrayBuffer instance, shared or not. Used by TypedArray
/// and DataView backing-store validation, which accept both.
fn bool is_any_arraybuffer_obj(HObject* obj) {
    return obj != null && obj.flags.obj_class == hobject::ObjClass.ARRAYBUFFER;
}

/// DetachArrayBuffer (ES2024 §25.1.3.5): free the backing store and mark the
/// buffer detached (engine convention: data==null, byte_length==0xFFFFFFFF).
/// A detached buffer reports byteLength 0 and every view sees it as detached.
/// The single detach primitive — ArrayBuffer.prototype.transfer and the
/// $262.detachArrayBuffer host hook both route through here.
fn void arraybuffer_detach(Heap* heap, HObject* obj) {
    if ((*obj.extra_ptr()).ab.data != null) {
        heap.free_func(heap.heap_udata, (*obj.extra_ptr()).ab.data);
        (*obj.extra_ptr()).ab.data = null;
    }
    (*obj.extra_ptr()).ab.byte_length = 0xFFFFFFFFu;
}

/// True iff cls is one of the buffer-view classes (TypedArray or DataView).
fn bool is_bufferview_class(hobject::ObjClass cls) {
    return cls == hobject::ObjClass.DATAVIEW
        || is_typed_array_class(cls);
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

    // ES2024 §25.1.3.1: GetArrayBufferMaxByteLengthOption — read the
    // {maxByteLength} option from the second argument if it is an object.
    // A present, non-undefined maxByteLength makes the buffer resizable.
    bool has_max = false;
    double max_wide = 0.0;
    if (ctx.argc >= 2) {
        TVal opt = ctx.regs[ctx.base_reg + 1];
        if (opt.is_object() && opt.get_heapptr() != null) {
            HObject* opt_obj = (HObject*)opt.get_heapptr();
            HString* mbl_key = builtin_intern_string(ctx.heap, "maxByteLength");
            if (try mv = builtins_generic_get(opt_obj, mbl_key, ctx)) {
                if (ctx.should_throw) return;
                if (!mv.is_undefined()) {
                    if (!arraybuffer_to_index_wide(ctx, &mv, &max_wide)) return;
                    has_max = true;
                }
            } else {
                return;
            }
        }
    }

    // AllocateArrayBuffer (§25.1.3.1) step 1: byteLength must not exceed
    // maxByteLength. This RangeError is raised BEFORE OrdinaryCreateFrom
    // Constructor (step 3) resolves new.target.prototype, so a throwing
    // "prototype" getter must not preempt it. Compare in wide (double) space:
    // the engine's INT32 allocation cap is a separate, LATER failure (see
    // data-allocation-after-object-creation.js) that must lose to the getter.
    uint max_byte_length = 0;
    if (has_max) {
        if (max_wide > 2147483647.0) {
            arraybuffer_throw_range_error(ctx, "Invalid array buffer maxByteLength");
            return;
        }
        max_byte_length = (uint)max_wide;
        if (byte_length_wide > max_wide) {
            arraybuffer_throw_range_error(ctx, "ArrayBuffer length exceeds maxByteLength");
            return;
        }
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

    // CreateByteDataBlock: the engine's uint32 cap plays the role of an
    // allocation failure — checked only after the instance prototype resolved.
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
    (*obj.extra_ptr()).ab.resizable = has_max;
    (*obj.extra_ptr()).ab.max_byte_length = max_byte_length;

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
// ArrayBuffer.prototype.resizable getter — ES2024 §25.1.6.4
// ============================================================================

fn void builtin_arraybuffer_proto_resizable_get(BuiltinContext* ctx) {
    TVal this_val = ctx.this_val;
    if (!this_val.is_object() || this_val.get_heapptr() == null) {
        arraybuffer_throw_type_error(ctx, "ArrayBuffer.prototype.resizable called on non-object");
        return;
    }
    HObject* obj = (HObject*)this_val.get_heapptr();
    if (!is_arraybuffer_obj(obj)) {
        arraybuffer_throw_type_error(ctx, "ArrayBuffer.prototype.resizable called on incompatible receiver");
        return;
    }
    ctx.result.set_boolean((*obj.extra_ptr()).ab.resizable);
}

// ============================================================================
// ArrayBuffer.prototype.maxByteLength getter — ES2024 §25.1.6.3
// ============================================================================

fn void builtin_arraybuffer_proto_maxbytelength_get(BuiltinContext* ctx) {
    TVal this_val = ctx.this_val;
    if (!this_val.is_object() || this_val.get_heapptr() == null) {
        arraybuffer_throw_type_error(ctx, "ArrayBuffer.prototype.maxByteLength called on non-object");
        return;
    }
    HObject* obj = (HObject*)this_val.get_heapptr();
    if (!is_arraybuffer_obj(obj)) {
        arraybuffer_throw_type_error(ctx, "ArrayBuffer.prototype.maxByteLength called on incompatible receiver");
        return;
    }
    // Detached buffer: 0. Non-resizable: byteLength (spec §25.1.6.3).
    if (((*obj.extra_ptr()).ab.byte_length == 0xFFFFFFFFu)) {
        ctx.result.set_fastint(0);
        return;
    }
    if ((*obj.extra_ptr()).ab.resizable) {
        ctx.result.set_fastint((long)(*obj.extra_ptr()).ab.max_byte_length);
    } else {
        ctx.result.set_fastint((long)(*obj.extra_ptr()).ab.byte_length);
    }
}

// ============================================================================
// ArrayBuffer.prototype.resize(newLength) — ES2024 §25.1.6.9
// ============================================================================

fn void builtin_arraybuffer_proto_resize(BuiltinContext* ctx) {
    TVal this_val = ctx.this_val;
    if (!this_val.is_object() || this_val.get_heapptr() == null) {
        arraybuffer_throw_type_error(ctx, "ArrayBuffer.prototype.resize called on non-object");
        return;
    }
    HObject* obj = (HObject*)this_val.get_heapptr();
    if (!is_arraybuffer_obj(obj)) {
        arraybuffer_throw_type_error(ctx, "ArrayBuffer.prototype.resize called on incompatible receiver");
        return;
    }
    if (!(*obj.extra_ptr()).ab.resizable) {
        arraybuffer_throw_type_error(ctx, "ArrayBuffer.prototype.resize: buffer is not resizable");
        return;
    }

    TVal len_arg; len_arg.set_undefined();
    if (ctx.argc >= 1) len_arg = ctx.regs[ctx.base_reg];
    uint new_len = 0;
    // ToIndex (may run user code that detaches the buffer).
    if (!arraybuffer_to_index(ctx, &len_arg, &new_len)) return;

    // §25.1.6.9 step: throw if detached (after ToIndex).
    if (((*obj.extra_ptr()).ab.byte_length == 0xFFFFFFFFu)) {
        arraybuffer_throw_type_error(ctx, "ArrayBuffer.prototype.resize: buffer is detached");
        return;
    }
    if (new_len > (*obj.extra_ptr()).ab.max_byte_length) {
        arraybuffer_throw_range_error(ctx, "ArrayBuffer.prototype.resize: length exceeds maxByteLength");
        return;
    }

    uint old_len = (*obj.extra_ptr()).ab.byte_length;
    char* old_data = (*obj.extra_ptr()).ab.data;
    // Reallocate the backing store to the new length. Grow zero-fills the tail.
    char* new_data = null;
    if (new_len > 0) {
        new_data = (char*)ctx.heap.alloc_func(ctx.heap.heap_udata, (usz)new_len);
        if (new_data == null) {
            arraybuffer_throw_range_error(ctx, "Out of memory resizing ArrayBuffer");
            return;
        }
        mem::clear(new_data, (sz)((usz)new_len));
        if (old_data != null && old_len > 0) {
            uint copy_len = old_len < new_len ? old_len : new_len;
            mem::copy(new_data, old_data, (sz)((usz)copy_len));
        }
    }
    if (old_data != null) {
        ctx.heap.free_func(ctx.heap.heap_udata, old_data);
    }
    (*obj.extra_ptr()).ab.data = new_data;
    (*obj.extra_ptr()).ab.byte_length = new_len;

    ctx.result.set_undefined();
}

// ============================================================================
// ArrayBuffer.prototype.transfer([newLength]) — ES2024 §25.1.6.7
// ArrayBuffer.prototype.transferToFixedLength([newLength]) — ES2024 §25.1.6.8
//
// ArrayBufferCopyAndDetach: moves the backing store into a fresh ArrayBuffer,
// then detaches the source. `preserve_resizable` keeps the source's resizability
// and maxByteLength (transfer); transferToFixedLength always produces a
// fixed-length buffer.
// ============================================================================

fn void arraybuffer_transfer_impl(BuiltinContext* ctx, bool preserve_resizable) {
    TVal this_val = ctx.this_val;
    if (!this_val.is_object() || this_val.get_heapptr() == null) {
        arraybuffer_throw_type_error(ctx, "ArrayBuffer.prototype.transfer called on non-object");
        return;
    }
    HObject* obj = (HObject*)this_val.get_heapptr();
    if (!is_arraybuffer_obj(obj)) {
        arraybuffer_throw_type_error(ctx, "ArrayBuffer.prototype.transfer called on incompatible receiver");
        return;
    }
    // Step 4: IsDetachedBuffer(O) — throw TypeError.
    if (((*obj.extra_ptr()).ab.byte_length == 0xFFFFFFFFu)) {
        arraybuffer_throw_type_error(ctx, "ArrayBuffer.prototype.transfer: buffer is detached");
        return;
    }

    // Steps 5-6: newLength defaults to the current byteLength; otherwise
    // ToIntegerOrInfinity (may run user code that detaches the buffer).
    bool has_new_length = ctx.argc >= 1 && !ctx.regs[ctx.base_reg].is_undefined();
    uint new_len;
    if (!has_new_length) {
        new_len = (*obj.extra_ptr()).ab.byte_length;
    } else {
        TVal len_arg = ctx.regs[ctx.base_reg];
        double d = builtin_to_integer_vm(ctx, &len_arg);
        if (ctx.should_throw) return;
        // Step 7 constructs a new ArrayBuffer of newByteLength, whose allocation
        // performs ToIndex — negative or > 2^53-1 lengths are RangeErrors, and
        // the engine's uint32 allocation cap plays the CreateByteDataBlock role.
        if (d != d) {
            new_len = 0; // NaN -> 0
        } else if (d < 0.0 || d > 2147483647.0) {
            arraybuffer_throw_range_error(ctx, "Invalid array buffer length");
            return;
        } else {
            new_len = (uint)d;
        }
        // ToIntegerOrInfinity may have detached the source (step 6 side effects
        // precede the detach in step 14; re-validate before the copy).
        if (((*obj.extra_ptr()).ab.byte_length == 0xFFFFFFFFu)) {
            arraybuffer_throw_type_error(ctx, "ArrayBuffer.prototype.transfer: buffer detached during length coercion");
            return;
        }
    }

    // The destination preserves resizability/maxByteLength only for transfer;
    // transferToFixedLength (and a non-resizable source) yields a fixed buffer.
    bool dest_resizable = preserve_resizable && (*obj.extra_ptr()).ab.resizable;
    uint dest_max = dest_resizable ? (*obj.extra_ptr()).ab.max_byte_length : new_len;
    if (dest_resizable && new_len > dest_max) {
        arraybuffer_throw_range_error(ctx, "ArrayBuffer length exceeds maxByteLength");
        return;
    }

    // Step 7 allocates the destination via %ArrayBuffer% using the source's
    // constructor realm; here the plain instance prototype suffices.
    HObject*? new_raw = ctx.heap.alloc_object(hobject::ObjClass.ARRAYBUFFER);
    if (catch err = new_raw) {
        arraybuffer_throw_range_error(ctx, "Out of memory allocating ArrayBuffer");
        return;
    }
    HObject* new_buf = new_raw;
    new_buf.prototype = ctx.heap.arraybuffer_proto;
    (*new_buf.extra_ptr()).ab.views_head = null;

    char* new_data = null;
    if (new_len > 0) {
        new_data = (char*)ctx.heap.alloc_func(ctx.heap.heap_udata, (usz)new_len);
        if (new_data == null) {
            arraybuffer_throw_range_error(ctx, "Out of memory allocating ArrayBuffer");
            return;
        }
        mem::clear(new_data, (sz)((usz)new_len));
        // Step 9-12: copy min(newByteLength, sourceByteLength) bytes.
        uint src_len = (*obj.extra_ptr()).ab.byte_length;
        char* src_data = (*obj.extra_ptr()).ab.data;
        if (src_data != null && src_len > 0) {
            uint copy_len = src_len < new_len ? src_len : new_len;
            mem::copy(new_data, src_data, (sz)((usz)copy_len));
        }
    }
    (*new_buf.extra_ptr()).ab.data = new_data;
    (*new_buf.extra_ptr()).ab.byte_length = new_len;
    (*new_buf.extra_ptr()).ab.resizable = dest_resizable;
    (*new_buf.extra_ptr()).ab.max_byte_length = dest_max;

    // Step 14: DetachArrayBuffer(O) — free the source's backing store.
    arraybuffer_detach(ctx.heap, obj);

    ctx.result.set_object(new_buf);
}

fn void builtin_arraybuffer_proto_transfer(BuiltinContext* ctx) {
    arraybuffer_transfer_impl(ctx, true);
}

fn void builtin_arraybuffer_proto_transfer_to_fixed_length(BuiltinContext* ctx) {
    arraybuffer_transfer_impl(ctx, false);
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
    // Only an ordinary (non-shared) ArrayBuffer can be detached; is_arraybuffer_obj
    // already rejects SharedArrayBuffers, which are never detachable.
    if (!is_arraybuffer_obj(obj)) {
        arraybuffer_throw_type_error(ctx, "detachArrayBuffer requires an ArrayBuffer argument");
        return;
    }
    arraybuffer_detach(ctx.heap, obj);
    ctx.result.set_undefined();
}

// ============================================================================
// SharedArrayBuffer (ES2024 §25.2) — single-agent variant.
// Shares ObjClass.ARRAYBUFFER with a distinguishing `is_shared` flag; SABs can
// never be detached, and "growable" SABs grow in place and never shrink.
// ============================================================================

/// True iff obj is a SharedArrayBuffer instance.
fn bool is_shared_arraybuffer_obj(HObject* obj) {
    return obj != null
        && obj.flags.obj_class == hobject::ObjClass.ARRAYBUFFER
        && (*obj.extra_ptr()).ab.is_shared;
}

/// SharedArrayBuffer(length [, options]) constructor — ES2024 §25.2.2.1.
fn void builtin_sharedarraybuffer(BuiltinContext* ctx) {
    if (!ctx.is_constructor) {
        arraybuffer_throw_type_error(ctx, "Constructor SharedArrayBuffer requires 'new'");
        return;
    }

    TVal len_arg;
    len_arg.set_undefined();
    if (ctx.argc >= 1) len_arg = ctx.regs[ctx.base_reg];

    double byte_length_wide = 0.0;
    if (!arraybuffer_to_index_wide(ctx, &len_arg, &byte_length_wide)) {
        return;
    }

    // GetArrayBufferMaxByteLengthOption — a present, non-undefined maxByteLength
    // makes the shared buffer growable.
    bool has_max = false;
    double max_wide = 0.0;
    if (ctx.argc >= 2) {
        TVal opt = ctx.regs[ctx.base_reg + 1];
        if (opt.is_object() && opt.get_heapptr() != null) {
            HObject* opt_obj = (HObject*)opt.get_heapptr();
            HString* mbl_key = builtin_intern_string(ctx.heap, "maxByteLength");
            if (try mv = builtins_generic_get(opt_obj, mbl_key, ctx)) {
                if (ctx.should_throw) return;
                if (!mv.is_undefined()) {
                    if (!arraybuffer_to_index_wide(ctx, &mv, &max_wide)) return;
                    has_max = true;
                }
            } else {
                return;
            }
        }
    }

    uint max_byte_length = 0;
    if (has_max) {
        if (max_wide > 2147483647.0) {
            arraybuffer_throw_range_error(ctx, "Invalid shared array buffer maxByteLength");
            return;
        }
        max_byte_length = (uint)max_wide;
        if (byte_length_wide > max_wide) {
            arraybuffer_throw_range_error(ctx, "SharedArrayBuffer length exceeds maxByteLength");
            return;
        }
    }

    HObject* instance_proto = arraybuffer_instance_proto(ctx, ctx.heap.sharedarraybuffer_proto);
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
        arraybuffer_throw_range_error(ctx, "Invalid shared array buffer length");
        return;
    }
    byte_length = (uint)byte_length_wide;

    // For growable SABs, allocate the full maxByteLength up front so the backing
    // pointer is stable across grow() (grow-in-place, views never see a realloc).
    uint alloc_len = has_max ? max_byte_length : byte_length;
    char* data = null;
    if (alloc_len > 0) {
        data = (char*)ctx.heap.alloc_func(ctx.heap.heap_udata, (usz)alloc_len);
        if (data == null) {
            arraybuffer_throw_range_error(ctx, "Out of memory allocating SharedArrayBuffer");
            return;
        }
        mem::clear(data, (sz)((usz)alloc_len));
    }
    (*obj.extra_ptr()).ab.data = data;
    (*obj.extra_ptr()).ab.byte_length = byte_length;
    (*obj.extra_ptr()).ab.resizable = has_max;
    (*obj.extra_ptr()).ab.max_byte_length = max_byte_length;
    (*obj.extra_ptr()).ab.is_shared = true;

    ctx.result.set_object(obj);
}

/// Shared receiver validation for SharedArrayBuffer.prototype methods.
fn HObject* sab_this(BuiltinContext* ctx, char[] method) {
    TVal this_val = ctx.this_val;
    if (!this_val.is_object() || this_val.get_heapptr() == null) {
        arraybuffer_throw_type_error(ctx, "SharedArrayBuffer.prototype method called on non-object");
        return null;
    }
    HObject* obj = (HObject*)this_val.get_heapptr();
    if (!is_shared_arraybuffer_obj(obj)) {
        arraybuffer_throw_type_error(ctx, "SharedArrayBuffer.prototype method called on incompatible receiver");
        return null;
    }
    return obj;
}

/// SharedArrayBuffer.prototype.byteLength getter — ES2024 §25.2.4.1.
fn void builtin_sharedarraybuffer_proto_bytelength_get(BuiltinContext* ctx) {
    HObject* obj = sab_this(ctx, "byteLength");
    if (obj == null) return;
    ctx.result.set_fastint((long)(*obj.extra_ptr()).ab.byte_length);
}

/// SharedArrayBuffer.prototype.growable getter — ES2024 §25.2.4.2.
fn void builtin_sharedarraybuffer_proto_growable_get(BuiltinContext* ctx) {
    HObject* obj = sab_this(ctx, "growable");
    if (obj == null) return;
    ctx.result.set_boolean((*obj.extra_ptr()).ab.resizable);
}

/// SharedArrayBuffer.prototype.maxByteLength getter — ES2024 §25.2.4.4.
fn void builtin_sharedarraybuffer_proto_maxbytelength_get(BuiltinContext* ctx) {
    HObject* obj = sab_this(ctx, "maxByteLength");
    if (obj == null) return;
    if ((*obj.extra_ptr()).ab.resizable) {
        ctx.result.set_fastint((long)(*obj.extra_ptr()).ab.max_byte_length);
    } else {
        ctx.result.set_fastint((long)(*obj.extra_ptr()).ab.byte_length);
    }
}

/// SharedArrayBuffer.prototype.grow(newLength) — ES2024 §25.2.4.3.
/// Growable SABs grow in place (backing store pre-allocated to maxByteLength)
/// and never shrink.
fn void builtin_sharedarraybuffer_proto_grow(BuiltinContext* ctx) {
    HObject* obj = sab_this(ctx, "grow");
    if (obj == null) return;
    if (!(*obj.extra_ptr()).ab.resizable) {
        arraybuffer_throw_type_error(ctx, "SharedArrayBuffer.prototype.grow: buffer is not growable");
        return;
    }

    TVal len_arg; len_arg.set_undefined();
    if (ctx.argc >= 1) len_arg = ctx.regs[ctx.base_reg];
    uint new_len = 0;
    // ToIndex (may run user code).
    if (!arraybuffer_to_index(ctx, &len_arg, &new_len)) return;

    if (new_len > (*obj.extra_ptr()).ab.max_byte_length) {
        arraybuffer_throw_range_error(ctx, "SharedArrayBuffer.prototype.grow: length exceeds maxByteLength");
        return;
    }
    // Never shrink (§25.2.4.3: newByteLength >= current byteLength).
    if (new_len < (*obj.extra_ptr()).ab.byte_length) {
        arraybuffer_throw_range_error(ctx, "SharedArrayBuffer.prototype.grow: cannot shrink");
        return;
    }
    // Grow in place: the store is already maxByteLength bytes, zero-filled.
    (*obj.extra_ptr()).ab.byte_length = new_len;
    ctx.result.set_undefined();
}

/// SharedArrayBuffer.prototype.slice(start, end) — ES2024 §25.2.4.5.
/// Always produces a (non-shared? no — shared) SharedArrayBuffer via species.
fn void builtin_sharedarraybuffer_proto_slice(BuiltinContext* ctx) {
    HObject* obj = sab_this(ctx, "slice");
    if (obj == null) return;

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

    // SpeciesConstructor(O, %SharedArrayBuffer%).
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
            arraybuffer_throw_type_error(ctx, "SharedArrayBuffer.prototype.slice: constructor is not an object");
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
                    arraybuffer_throw_type_error(ctx, "SharedArrayBuffer.prototype.slice: species result is not a constructor");
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
            arraybuffer_throw_type_error(ctx, "SharedArrayBuffer.prototype.slice: species constructor did not return an object");
            return;
        }
        new_buf = (HObject*)result_tv.get_heapptr();
        if (!is_shared_arraybuffer_obj(new_buf)) {
            arraybuffer_throw_type_error(ctx, "SharedArrayBuffer.prototype.slice: species constructor did not return a SharedArrayBuffer");
            return;
        }
        if (new_buf == obj) {
            arraybuffer_throw_type_error(ctx, "SharedArrayBuffer.prototype.slice: species constructor returned the same buffer");
            return;
        }
        if ((long)(*new_buf.extra_ptr()).ab.byte_length < new_len) {
            arraybuffer_throw_type_error(ctx, "SharedArrayBuffer.prototype.slice: new buffer too small");
            return;
        }
    } else {
        HObject*? new_raw = ctx.heap.alloc_object(hobject::ObjClass.ARRAYBUFFER);
        if (catch err = new_raw) {
            ctx.result.set_undefined();
            return;
        }
        new_buf = new_raw;
        new_buf.prototype = ctx.heap.sharedarraybuffer_proto;
        char* new_data = null;
        if (new_len > 0) {
            new_data = (char*)ctx.heap.alloc_func(ctx.heap.heap_udata, (usz)new_len);
            if (new_data != null) mem::clear(new_data, (sz)((usz)new_len));
        }
        (*new_buf.extra_ptr()).ab.data = new_data;
        (*new_buf.extra_ptr()).ab.byte_length = (uint)new_len;
        (*new_buf.extra_ptr()).ab.views_head = null;
        (*new_buf.extra_ptr()).ab.is_shared = true;
    }

    if (new_len > 0 && (*new_buf.extra_ptr()).ab.data != null) {
        mem::copy((*new_buf.extra_ptr()).ab.data, (*obj.extra_ptr()).ab.data + start_idx, (sz)((usz)new_len));
    }

    ctx.result.set_object(new_buf);
}

/// SharedArrayBuffer[Symbol.species] getter — returns `this`.
fn void builtin_sharedarraybuffer_species_get(BuiltinContext* ctx) {
    *ctx.result = ctx.this_val;
}

// ============================================================================
// Registration
// ============================================================================

/// Register an ArrayBuffer.prototype accessor getter (byteLength/detached).
fn bool register_arraybuffer_accessor(HObject* proto, Heap* heap, char[] name, uint getter_index) {
    HString* key = heap.str_intern(name);
    if (key == null) return false;

    HObject*? func_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
    if (catch err = func_raw) return false;
    HObject* func_obj = func_raw;
    (*func_obj.extra_ptr()).func.builtin_fn_index = (int)getter_index;
    func_obj.flags.callable = true;
    func_obj.flags.constructable = false;
    func_obj.prototype = heap.function_proto;

    char[64] name_buf;
    usz total_len = (usz)(io::bprintf(&name_buf, "get %s", (String)name) ?? name_buf[:0]).len;
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
    ctor.prototype = heap.function_proto;
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
    if (!register_arraybuffer_accessor(proto, heap, "resizable", Builtin.ARRAYBUFFER_PROTO_RESIZABLE_GET.ordinal)) return false;
    if (!register_arraybuffer_accessor(proto, heap, "maxByteLength", Builtin.ARRAYBUFFER_PROTO_MAXBYTELENGTH_GET.ordinal)) return false;

    // Methods
    if (!register_string_proto_method(proto, heap, "slice", Builtin.ARRAYBUFFER_PROTO_SLICE.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "resize", Builtin.ARRAYBUFFER_PROTO_RESIZE.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "transfer", Builtin.ARRAYBUFFER_PROTO_TRANSFER.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "transferToFixedLength", Builtin.ARRAYBUFFER_PROTO_TRANSFER_TO_FIXED_LENGTH.ordinal)) return false;

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

    HString* ctor_key = heap.str_intern("ArrayBuffer");
    if (ctor_key == null) return false;
    TVal ctor_val;
    ctor_val.set_object(ctor);
    env::env_declare_nonenum(global_env, ctor_key, ctor_val);

    return true;
}

/// Create SharedArrayBuffer.prototype and register the constructor globally.
fn bool register_sharedarraybuffer(EnvRecord* global_env, Heap* heap) {
    HObject*? proto_raw = heap.alloc_object(hobject::ObjClass.OBJECT);
    if (catch err = proto_raw) return false;
    HObject* proto = proto_raw;
    proto.prototype = heap.object_proto;
    heap.sharedarraybuffer_proto = proto;

    HObject*? ctor_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
    if (catch err = ctor_raw) return false;
    HObject* ctor = ctor_raw;
    ctor.prototype = heap.function_proto;
    (*ctor.extra_ptr()).func.builtin_fn_index = (int)Builtin.SHAREDARRAYBUFFER.ordinal;

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
    if (!register_arraybuffer_accessor(proto, heap, "byteLength", Builtin.SHAREDARRAYBUFFER_PROTO_BYTELENGTH_GET.ordinal)) return false;
    if (!register_arraybuffer_accessor(proto, heap, "growable", Builtin.SHAREDARRAYBUFFER_PROTO_GROWABLE_GET.ordinal)) return false;
    if (!register_arraybuffer_accessor(proto, heap, "maxByteLength", Builtin.SHAREDARRAYBUFFER_PROTO_MAXBYTELENGTH_GET.ordinal)) return false;

    // Methods
    if (!register_string_proto_method(proto, heap, "slice", Builtin.SHAREDARRAYBUFFER_PROTO_SLICE.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "grow", Builtin.SHAREDARRAYBUFFER_PROTO_GROW.ordinal)) return false;

    // @@toStringTag
    HString* tag_key = ensure_tostringtag_symbol(heap);
    if (tag_key != null) {
        TVal tag_tv;
        tag_tv.set_string(builtin_intern_string(heap, "SharedArrayBuffer"));
        proto.put_prop(tag_key, tag_tv, hobject::PROP_FLAGS_NWC);
    }

    // Static @@species accessor (returns `this` constructor).
    HString* species_sym = ensure_species_symbol(heap);
    if (species_sym != null) {
        HObject*? getter_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
        if (try getter = getter_raw) {
            getter.flags.callable = true;
            getter.flags.constructable = false;
            getter.prototype = heap.function_proto;
            (*getter.extra_ptr()).func.builtin_fn_index = (int)Builtin.SHAREDARRAYBUFFER_SPECIES_GET.ordinal;

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

    set_func_ctor_name_length(ctor, heap, "SharedArrayBuffer", 1);

    HString* ctor_key = heap.str_intern("SharedArrayBuffer");
    if (ctor_key == null) return false;
    TVal ctor_val;
    ctor_val.set_object(ctor);
    env::env_declare_nonenum(global_env, ctor_key, ctor_val);

    return true;
}
