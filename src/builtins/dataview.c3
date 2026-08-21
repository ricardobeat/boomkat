// DataView constructor and prototype (ES2015 §24.2), Stage 3 of plan 049.
// Reuses the ArrayBuffer/TypedArray view-linking primitives from
// arraybuffer.c3/typedarray.c3; this file only adds the byte-addressed
// get/set surface with an explicit littleEndian argument.
module boomkat::builtins;

import boomkat::types;
import std::io;
import boomkat::hstring;
import boomkat::heap;
import boomkat::hobject;
import boomkat::hbigint;
import boomkat::env;

fn bool is_dataview_obj(HObject* obj) {
    return obj != null && obj.flags.obj_class == hobject::ObjClass.DATAVIEW;
}

// Element byte width for the 8 DataView accessor kinds, keyed by the
// TypedArray ObjClass tags reused here to identify width/signedness/kind.
fn uint dv_elem_size(hobject::ObjClass cls) {
    switch (cls) {
        case hobject::ObjClass.INT8ARRAY:
        case hobject::ObjClass.UINT8ARRAY:
            return 1;
        case hobject::ObjClass.INT16ARRAY:
        case hobject::ObjClass.UINT16ARRAY:
        case hobject::ObjClass.FLOAT16ARRAY:
            return 2;
        case hobject::ObjClass.INT32ARRAY:
        case hobject::ObjClass.UINT32ARRAY:
        case hobject::ObjClass.FLOAT32ARRAY:
            return 4;
        case hobject::ObjClass.FLOAT64ARRAY:
        case hobject::ObjClass.BIGINT64ARRAY:
        case hobject::ObjClass.BIGUINT64ARRAY:
            return 8;
        default:
            return 1;
    }
}

// ============================================================================
// DataView(buffer, byteOffset=0, byteLength=undefined), ES2015 §24.2.2.1
// ============================================================================

fn void builtin_dataview(BuiltinContext* ctx) {
    if (!ctx.is_constructor) {
        arraybuffer_throw_type_error(ctx, "Constructor DataView requires 'new'");
        return;
    }

    TVal buf_arg; buf_arg.set_undefined();
    if (ctx.argc >= 1) buf_arg = ctx.regs[ctx.base_reg];
    if (!buf_arg.is_object() || buf_arg.get_heapptr() == null) {
        arraybuffer_throw_type_error(ctx, "DataView constructor requires an ArrayBuffer argument");
        return;
    }
    HObject* buf = (HObject*)buf_arg.get_heapptr();
    if (!is_any_arraybuffer_obj(buf)) {
        arraybuffer_throw_type_error(ctx, "DataView constructor requires an ArrayBuffer argument");
        return;
    }

    TVal off_arg; off_arg.set_undefined();
    if (ctx.argc >= 2) off_arg = ctx.regs[ctx.base_reg + 1];
    uint byte_offset = 0;
    if (!arraybuffer_to_index(ctx, &off_arg, &byte_offset)) return;

    // Buffer may have been detached before we get here only via a prior
    // statement; ToIndex above cannot itself detach (no valueOf on a plain
    // offset arg is required to reach the buffer), but re-check regardless.
    if (((*buf.extra_ptr()).ab.byte_length == 0xFFFFFFFFu)) {
        arraybuffer_throw_type_error(ctx, "DataView constructor: buffer is detached");
        return;
    }

    uint buf_len = (*buf.extra_ptr()).ab.byte_length;
    if (byte_offset > buf_len) {
        arraybuffer_throw_range_error(ctx, "DataView constructor: byteOffset out of range");
        return;
    }

    TVal len_arg; len_arg.set_undefined();
    if (ctx.argc >= 3) len_arg = ctx.regs[ctx.base_reg + 2];

    // Length-tracking DataView: no explicit length over a resizable buffer.
    bool length_tracking = len_arg.is_undefined() && (*buf.extra_ptr()).ab.resizable;

    uint view_len;
    if (len_arg.is_undefined()) {
        view_len = buf_len - byte_offset;
    } else {
        if (!arraybuffer_to_index(ctx, &len_arg, &view_len)) return;
        if (((*buf.extra_ptr()).ab.byte_length == 0xFFFFFFFFu)) {
            arraybuffer_throw_type_error(ctx, "DataView constructor: buffer is detached");
            return;
        }
        buf_len = (*buf.extra_ptr()).ab.byte_length;
        if (byte_offset > buf_len || view_len > buf_len - byte_offset) {
            arraybuffer_throw_range_error(ctx, "DataView constructor: byteLength out of range");
            return;
        }
    }

    // OrdinaryCreateFromConstructor (via new.target.prototype) can run
    // arbitrary user code, including detaching `buf`, so it must be
    // resolved before the view is linked, and the detach state re-checked
    // afterward, before the DataView instance is returned.
    HObject* instance_proto = typedarray_instance_proto(ctx, ctx.heap.dataview_proto);
    if (ctx.should_throw) return;

    if (((*buf.extra_ptr()).ab.byte_length == 0xFFFFFFFFu)) {
        arraybuffer_throw_type_error(ctx, "DataView constructor: buffer is detached");
        return;
    }

    // §25.3.2.1 steps 11-13: the prototype Get may also have RESIZED the
    // buffer; re-validate offset and (non-tracking) length against the
    // current byte length.
    buf_len = (*buf.extra_ptr()).ab.byte_length;
    if (byte_offset > buf_len) {
        arraybuffer_throw_range_error(ctx, "DataView constructor: byteOffset out of range");
        return;
    }
    if (!length_tracking && view_len > buf_len - byte_offset) {
        arraybuffer_throw_range_error(ctx, "DataView constructor: byteLength out of range");
        return;
    }

    HObject*? raw = ctx.heap.alloc_object(hobject::ObjClass.DATAVIEW);
    if (catch err = raw) {
        ctx.result.set_undefined();
        return;
    }
    HObject* obj = raw;
    obj.prototype = instance_proto;
    (*obj.extra_ptr()).view.byte_offset = byte_offset;
    (*obj.extra_ptr()).view.byte_length = view_len;
    (*obj.extra_ptr()).view.length_tracking = length_tracking;
    typedarray_link_view(buf, obj);

    ctx.result.set_object(obj);
}

// ============================================================================
// DataView.prototype accessors, ES2015 §24.2.4.1-3
// ============================================================================

fn void builtin_dataview_proto_buffer_get(BuiltinContext* ctx) {
    TVal this_val = ctx.this_val;
    if (!this_val.is_object() || !is_dataview_obj((HObject*)this_val.get_heapptr())) {
        arraybuffer_throw_type_error(ctx, "DataView.prototype.buffer called on incompatible receiver");
        return;
    }
    HObject* obj = (HObject*)this_val.get_heapptr();
    ctx.result.set_object((*obj.extra_ptr()).view.buffer);
}

fn void builtin_dataview_proto_bytelength_get(BuiltinContext* ctx) {
    TVal this_val = ctx.this_val;
    if (!this_val.is_object() || !is_dataview_obj((HObject*)this_val.get_heapptr())) {
        arraybuffer_throw_type_error(ctx, "DataView.prototype.byteLength called on incompatible receiver");
        return;
    }
    HObject* obj = (HObject*)this_val.get_heapptr();
    // §25.3.4.1: throw if detached or out of bounds (buffer shrank past view).
    if (view_is_out_of_bounds(obj)) {
        arraybuffer_throw_type_error(ctx, "DataView.prototype.byteLength: view is out of bounds");
        return;
    }
    ctx.result.set_fastint((long)view_effective_byte_length(obj));
}

fn void builtin_dataview_proto_byteoffset_get(BuiltinContext* ctx) {
    TVal this_val = ctx.this_val;
    if (!this_val.is_object() || !is_dataview_obj((HObject*)this_val.get_heapptr())) {
        arraybuffer_throw_type_error(ctx, "DataView.prototype.byteOffset called on incompatible receiver");
        return;
    }
    HObject* obj = (HObject*)this_val.get_heapptr();
    // §25.3.4.2: throw if detached or out of bounds.
    if (view_is_out_of_bounds(obj)) {
        arraybuffer_throw_type_error(ctx, "DataView.prototype.byteOffset: view is out of bounds");
        return;
    }
    ctx.result.set_fastint((long)(*obj.extra_ptr()).view.byte_offset);
}

// ============================================================================
// Shared get/set core, §24.2.1.1 GetViewValue / §24.2.1.2 SetViewValue
// ============================================================================

// Load `elem_size` bytes at `p` as a little-endian unsigned integer (up to
// 8 bytes), then byte-swap into big-endian order when `!little_endian`.
fn ulong dv_load_raw(char* p, uint elem_size, bool little_endian) {
    ulong v = 0;
    if (little_endian) {
        for (uint i = 0; i < elem_size; i++) {
            v |= ((ulong)(char)p[i]) << (i * 8);
        }
    } else {
        for (uint i = 0; i < elem_size; i++) {
            v = (v << 8) | (ulong)(char)p[i];
        }
    }
    return v;
}

fn void dv_store_raw(char* p, uint elem_size, ulong v, bool little_endian) {
    if (little_endian) {
        for (uint i = 0; i < elem_size; i++) {
            p[i] = (char)((v >> (i * 8)) & 0xFF);
        }
    } else {
        for (uint i = 0; i < elem_size; i++) {
            p[elem_size - 1 - i] = (char)((v >> (i * 8)) & 0xFF);
        }
    }
}

fn void dv_get(BuiltinContext* ctx, hobject::ObjClass elem_class) {
    TVal this_val = ctx.this_val;
    if (!this_val.is_object() || !is_dataview_obj((HObject*)this_val.get_heapptr())) {
        arraybuffer_throw_type_error(ctx, "DataView getter called on incompatible receiver");
        return;
    }
    HObject* obj = (HObject*)this_val.get_heapptr();
    HObject* buf = (*obj.extra_ptr()).view.buffer;

    // Spec §24.2.1.1 GetViewValue: ToIndex(requestIndex) runs FIRST (step 4),
    // then the detach check (step 6-7). Do NOT check detach before ToIndex.
    TVal pos_arg; pos_arg.set_undefined();
    if (ctx.argc >= 1) pos_arg = ctx.regs[ctx.base_reg];
    uint pos = 0;
    if (!arraybuffer_to_index(ctx, &pos_arg, &pos)) return;

    // Detach / out-of-bounds check after ToIndex per spec step 6-7.
    if (view_is_out_of_bounds(obj)) {
        arraybuffer_throw_type_error(ctx, "DataView getter: view is out of bounds");
        return;
    }

    bool little_endian = false;
    if (ctx.argc >= 2) {
        little_endian = builtin_to_boolean(&ctx.regs[ctx.base_reg + 1]);
    }

    uint elem_size = dv_elem_size(elem_class);
    uint view_len = view_effective_byte_length(obj);
    if (pos + elem_size > view_len) {
        arraybuffer_throw_range_error(ctx, "DataView getter: offset out of bounds");
        return;
    }

    // Re-check detach: ToIndex(pos)/ToBoolean above cannot run user code that
    // detaches, but keep the check for defense-in-depth and future symmetry
    // with the setter path below.
    if (((*buf.extra_ptr()).ab.byte_length == 0xFFFFFFFFu)) {
        arraybuffer_throw_type_error(ctx, "DataView getter: buffer is detached");
        return;
    }

    char* p = (*buf.extra_ptr()).ab.data + (*obj.extra_ptr()).view.byte_offset + pos;
    ulong raw = dv_load_raw(p, elem_size, little_endian);

    switch (elem_class) {
        case hobject::ObjClass.INT8ARRAY:
            ctx.result.set_fastint((long)(ichar)(char)raw);
            return;
        case hobject::ObjClass.UINT8ARRAY:
            ctx.result.set_fastint((long)(raw & 0xFF));
            return;
        case hobject::ObjClass.INT16ARRAY:
            ctx.result.set_fastint((long)(short)(ushort)raw);
            return;
        case hobject::ObjClass.UINT16ARRAY:
            ctx.result.set_fastint((long)(raw & 0xFFFF));
            return;
        case hobject::ObjClass.INT32ARRAY:
            ctx.result.set_fastint((long)(int)(uint)raw);
            return;
        case hobject::ObjClass.UINT32ARRAY: {
            uint u = (uint)raw;
            if (u < 2147483648u) {
                ctx.result.set_fastint((long)u);
            } else {
                ctx.result.set_number((double)u);
            }
            return;
        }
        case hobject::ObjClass.FLOAT16ARRAY: {
            ushort bits = (ushort)raw;
            ctx.result.set_number(f16_to_double(bits));
            return;
        }
        case hobject::ObjClass.FLOAT32ARRAY: {
            uint bits = (uint)raw;
            float f;
            mem::copy(&f, &bits, (sz)(4));
            ctx.result.set_number((double)f);
            return;
        }
        case hobject::ObjClass.FLOAT64ARRAY: {
            double d;
            mem::copy(&d, &raw, (sz)(8));
            ctx.result.set_number(d);
            return;
        }
        case hobject::ObjClass.BIGINT64ARRAY: {
            int128 v = (int128)(long)raw;   // sign-extend the 64-bit value
            dv_set_bigint_result(ctx, v);
            return;
        }
        case hobject::ObjClass.BIGUINT64ARRAY: {
            int128 v = (int128)(uint128)raw; // zero-extend
            dv_set_bigint_result(ctx, v);
            return;
        }
        default:
            ctx.result.set_undefined();
            return;
    }
}

// Box an int128 into an HBigInt and store it as the builtin result.
fn void dv_set_bigint_result(BuiltinContext* ctx, int128 v) {
    hbigint::HBigInt*? box = hbigint::hbigint_alloc(ctx.heap, v);
    if (catch box) { ctx.result.set_undefined(); return; }
    ctx.result.set_bigint(box);
}

fn void dv_set(BuiltinContext* ctx, hobject::ObjClass elem_class) {
    TVal this_val = ctx.this_val;
    if (!this_val.is_object() || !is_dataview_obj((HObject*)this_val.get_heapptr())) {
        arraybuffer_throw_type_error(ctx, "DataView setter called on incompatible receiver");
        return;
    }
    HObject* obj = (HObject*)this_val.get_heapptr();
    HObject* buf = (*obj.extra_ptr()).view.buffer;

    TVal pos_arg; pos_arg.set_undefined();
    if (ctx.argc >= 1) pos_arg = ctx.regs[ctx.base_reg];
    uint pos = 0;
    if (!arraybuffer_to_index(ctx, &pos_arg, &pos)) return;

    TVal val_arg; val_arg.set_undefined();
    if (ctx.argc >= 2) val_arg = ctx.regs[ctx.base_reg + 1];

    bool little_endian = false;
    if (ctx.argc >= 3) {
        little_endian = builtin_to_boolean(&ctx.regs[ctx.base_reg + 2]);
    }

    // Value conversion happens BEFORE the bounds and detach checks per spec,
    // user code (valueOf / Symbol.toPrimitive) may detach or resize the buffer
    // as a side effect. BigInt views use ToBigInt (§25.3.1.1 SetViewValue step 4
    // NumberToRawBytes vs BigIntToRawBytes), the rest use ToNumber.
    uint elem_size = dv_elem_size(elem_class);
    ulong raw = 0;
    bool is_big_dv = (elem_class == hobject::ObjClass.BIGINT64ARRAY
                      || elem_class == hobject::ObjClass.BIGUINT64ARRAY);
    if (is_big_dv) {
        bool ok;
        int128 bv = builtin_to_bigint(ctx, &val_arg, &ok);
        if (!ok || ctx.should_throw) return;
        raw = (ulong)(long)bv;   // low 64 bits (wrap mod 2^64)
    } else {
        double d = ta_val_to_number(&val_arg, ctx);
        if (ctx.should_throw) return;
        switch (elem_class) {
            case hobject::ObjClass.INT8ARRAY:
            case hobject::ObjClass.UINT8ARRAY: {
                long iv = double_to_int32(d);
                raw = (ulong)((char)(iv & 0xFF));
            }
            case hobject::ObjClass.INT16ARRAY:
            case hobject::ObjClass.UINT16ARRAY: {
                long iv = double_to_int32(d);
                raw = (ulong)((ushort)(iv & 0xFFFF));
            }
            case hobject::ObjClass.INT32ARRAY:
            case hobject::ObjClass.UINT32ARRAY: {
                long iv = double_to_int32(d);
                raw = (ulong)(uint)iv;
            }
            case hobject::ObjClass.FLOAT16ARRAY: {
                raw = (ulong)double_to_f16(d);
            }
            case hobject::ObjClass.FLOAT32ARRAY: {
                float f = (float)d;
                uint bits;
                mem::copy(&bits, &f, (sz)(4));
                raw = (ulong)bits;
            }
            case hobject::ObjClass.FLOAT64ARRAY: {
                mem::copy(&raw, &d, (sz)(8));
            }
            default:
                break;
        }
    }

    // DataView setters throw on detach/OOB even though value conversion
    // already ran (§24.2.1.2 steps 1-10 recheck ViewedArrayBuffer/bounds
    // after ToNumber/ToBigInt), unlike TypedArray element writes, which
    // silently no-op on a post-conversion OOB/detach.
    if (view_is_out_of_bounds(obj)) {
        arraybuffer_throw_type_error(ctx, "DataView setter: view is out of bounds");
        return;
    }
    uint view_len = view_effective_byte_length(obj);
    if (pos + elem_size > view_len) {
        arraybuffer_throw_range_error(ctx, "DataView setter: offset out of bounds");
        return;
    }

    char* p = (*buf.extra_ptr()).ab.data + (*obj.extra_ptr()).view.byte_offset + pos;
    dv_store_raw(p, elem_size, raw, little_endian);
    ctx.result.set_undefined();
}

fn void builtin_dataview_get_int8(BuiltinContext* ctx)    { dv_get(ctx, hobject::ObjClass.INT8ARRAY); }
fn void builtin_dataview_get_uint8(BuiltinContext* ctx)   { dv_get(ctx, hobject::ObjClass.UINT8ARRAY); }
fn void builtin_dataview_get_int16(BuiltinContext* ctx)   { dv_get(ctx, hobject::ObjClass.INT16ARRAY); }
fn void builtin_dataview_get_uint16(BuiltinContext* ctx)  { dv_get(ctx, hobject::ObjClass.UINT16ARRAY); }
fn void builtin_dataview_get_int32(BuiltinContext* ctx)   { dv_get(ctx, hobject::ObjClass.INT32ARRAY); }
fn void builtin_dataview_get_uint32(BuiltinContext* ctx)  { dv_get(ctx, hobject::ObjClass.UINT32ARRAY); }
fn void builtin_dataview_get_float16(BuiltinContext* ctx) { dv_get(ctx, hobject::ObjClass.FLOAT16ARRAY); }
fn void builtin_dataview_get_float32(BuiltinContext* ctx) { dv_get(ctx, hobject::ObjClass.FLOAT32ARRAY); }
fn void builtin_dataview_get_float64(BuiltinContext* ctx) { dv_get(ctx, hobject::ObjClass.FLOAT64ARRAY); }

fn void builtin_dataview_set_int8(BuiltinContext* ctx)    { dv_set(ctx, hobject::ObjClass.INT8ARRAY); }
fn void builtin_dataview_set_uint8(BuiltinContext* ctx)   { dv_set(ctx, hobject::ObjClass.UINT8ARRAY); }
fn void builtin_dataview_set_int16(BuiltinContext* ctx)   { dv_set(ctx, hobject::ObjClass.INT16ARRAY); }
fn void builtin_dataview_set_uint16(BuiltinContext* ctx)  { dv_set(ctx, hobject::ObjClass.UINT16ARRAY); }
fn void builtin_dataview_set_int32(BuiltinContext* ctx)   { dv_set(ctx, hobject::ObjClass.INT32ARRAY); }
fn void builtin_dataview_set_uint32(BuiltinContext* ctx)  { dv_set(ctx, hobject::ObjClass.UINT32ARRAY); }
fn void builtin_dataview_set_float16(BuiltinContext* ctx) { dv_set(ctx, hobject::ObjClass.FLOAT16ARRAY); }
fn void builtin_dataview_set_float32(BuiltinContext* ctx) { dv_set(ctx, hobject::ObjClass.FLOAT32ARRAY); }
fn void builtin_dataview_set_float64(BuiltinContext* ctx) { dv_set(ctx, hobject::ObjClass.FLOAT64ARRAY); }

// ============================================================================
// getBigInt64/getBigUint64/setBigInt64/setBigUint64 (§25.3.4), read/write an
// 8-byte two's-complement i64 (little/big-endian) as a BigInt, sharing the
// dv_get/dv_set machinery with the numeric views.
// ============================================================================

fn void builtin_dataview_get_bigint64(BuiltinContext* ctx)  { dv_get(ctx, hobject::ObjClass.BIGINT64ARRAY); }
fn void builtin_dataview_get_biguint64(BuiltinContext* ctx) { dv_get(ctx, hobject::ObjClass.BIGUINT64ARRAY); }
fn void builtin_dataview_set_bigint64(BuiltinContext* ctx)  { dv_set(ctx, hobject::ObjClass.BIGINT64ARRAY); }
fn void builtin_dataview_set_biguint64(BuiltinContext* ctx) { dv_set(ctx, hobject::ObjClass.BIGUINT64ARRAY); }

// ============================================================================
// Registration
// ============================================================================

// Register a DataView.prototype accessor getter (buffer/byteLength/byteOffset).
fn bool register_dataview_accessor(HObject* proto, Heap* heap, char[] name, uint getter_index) {
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
        HString* name_prop_key = heap.str(heap::BuiltinStr.NAME);
        func_obj.put_prop(name_prop_key, name_tv, hobject::PROP_FLAGS_NWC, heap);
    }
    HString* length_key = (HString*)heap.strs[heap::BuiltinStr.LENGTH];
    if (length_key != null) {
        TVal len_tv;
        len_tv.set_fastint(0);
        func_obj.put_prop(length_key, len_tv, hobject::PROP_FLAGS_NWC, heap);
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
    proto.put_prop(key, hobject::hobject_create_accessors(heap, getter_tv, undef), acc_flags, heap);
    return true;
}

// Create DataView.prototype and register the DataView constructor globally.
fn bool register_dataview(EnvRecord* global_env, Heap* heap) {
    HObject*? proto_raw = heap.alloc_object(hobject::ObjClass.OBJECT);
    if (catch err = proto_raw) return false;
    HObject* proto = proto_raw;
    proto.prototype = heap.object_proto;
    heap.dataview_proto = proto;

    HObject*? ctor_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
    if (catch err = ctor_raw) return false;
    HObject* ctor = ctor_raw;
    (*ctor.extra_ptr()).func.builtin_fn_index = (int)Builtin.DATAVIEW.ordinal;
    ctor.flags.callable = true;
    ctor.flags.constructable = true;
    ctor.prototype = heap.function_proto;

    // .constructor on the prototype
    HString* constructor_key = (HString*)heap.strs[heap::BuiltinStr.CONSTRUCTOR];
    TVal constructor_tv;
    constructor_tv.set_object(ctor);
    proto.put_prop(constructor_key, constructor_tv, hobject::PROP_FLAGS_WC, heap);

    // .prototype on the constructor (non-writable, non-enumerable, non-configurable)
    HString* prototype_key = (HString*)heap.strs[heap::BuiltinStr.PROTOTYPE];
    TVal proto_tv;
    proto_tv.set_object(proto);
    PropFlags proto_pflags;
    proto_pflags.writable = false;
    proto_pflags.enumerable = false;
    proto_pflags.configurable = false;
    proto_pflags.is_accessor = false;
    ctor.put_prop(prototype_key, proto_tv, proto_pflags, heap);

    // Accessors
    if (!register_dataview_accessor(proto, heap, "buffer", Builtin.DATAVIEW_PROTO_BUFFER_GET.ordinal)) return false;
    if (!register_dataview_accessor(proto, heap, "byteLength", Builtin.DATAVIEW_PROTO_BYTELENGTH_GET.ordinal)) return false;
    if (!register_dataview_accessor(proto, heap, "byteOffset", Builtin.DATAVIEW_PROTO_BYTEOFFSET_GET.ordinal)) return false;

    // get/set methods
    if (!register_string_proto_method(proto, heap, "getInt8", Builtin.DATAVIEW_GET_INT8.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "getUint8", Builtin.DATAVIEW_GET_UINT8.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "getInt16", Builtin.DATAVIEW_GET_INT16.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "getUint16", Builtin.DATAVIEW_GET_UINT16.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "getInt32", Builtin.DATAVIEW_GET_INT32.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "getUint32", Builtin.DATAVIEW_GET_UINT32.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "getFloat16", Builtin.DATAVIEW_GET_FLOAT16.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "getFloat32", Builtin.DATAVIEW_GET_FLOAT32.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "getFloat64", Builtin.DATAVIEW_GET_FLOAT64.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "setInt8", Builtin.DATAVIEW_SET_INT8.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "setUint8", Builtin.DATAVIEW_SET_UINT8.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "setInt16", Builtin.DATAVIEW_SET_INT16.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "setUint16", Builtin.DATAVIEW_SET_UINT16.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "setInt32", Builtin.DATAVIEW_SET_INT32.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "setUint32", Builtin.DATAVIEW_SET_UINT32.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "setFloat16", Builtin.DATAVIEW_SET_FLOAT16.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "setFloat32", Builtin.DATAVIEW_SET_FLOAT32.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "setFloat64", Builtin.DATAVIEW_SET_FLOAT64.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "getBigInt64", Builtin.DATAVIEW_GET_BIGINT64.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "getBigUint64", Builtin.DATAVIEW_GET_BIGUINT64.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "setBigInt64", Builtin.DATAVIEW_SET_BIGINT64.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "setBigUint64", Builtin.DATAVIEW_SET_BIGUINT64.ordinal)) return false;

    // @@toStringTag
    HString* tag_key = ensure_tostringtag_symbol(heap);
    if (tag_key != null) {
        TVal tag_tv;
        tag_tv.set_string(builtin_intern_string(heap, "DataView"));
        proto.put_prop(tag_key, tag_tv, hobject::PROP_FLAGS_NWC, heap);
    }

    set_func_ctor_name_length(ctor, heap, "DataView", 1);

    HString* ctor_key = heap.str_intern("DataView");
    if (ctor_key == null) return false;
    TVal ctor_val;
    ctor_val.set_object(ctor);
    env::env_declare_nonenum(global_env, ctor_key, ctor_val);

    return true;
}
