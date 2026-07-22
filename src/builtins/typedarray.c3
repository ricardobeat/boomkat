/// TypedArray constructors and element access (ES2015 §22.2) — Stage 2 of
/// plan 049. Buffer allocation reuses the ArrayBuffer primitives from
/// arraybuffer.c3; element read/write conversion lives in vm_property.c3.
module duktape::builtins;

import duktape::types;
import duktape::env;
import duktape::hstring;
import duktape::hobject;
import duktape::heap;
import duktape::hbigint;
import duktape::vm;
import std::io;
import std::math;

// ============================================================================
// TypedArray class descriptors — the single source of truth for "is this a
// typed array, and what is its element layout / content type?".
//
// Every TypedArray kind is one contiguous ObjClass run (INT8ARRAY ..
// BIGUINT64ARRAY); TA_INFO is indexed by (cls - INT8ARRAY). Adding a kind means
// adding its ObjClass (keeping the run contiguous) and one row here — no caller
// open-codes the ordinal range, so nothing else has to change.
// ============================================================================

struct TAInfo {
    char    elem_size;   // bytes per element
    char    elem_shift;  // log2(elem_size)
    bool    is_bigint;   // BigInt64/BigUint64 — content type "BigInt" (§ ContentType)
    char[]  name;        // constructor name for @@toStringTag / errors
}

const TAInfo[11] TA_INFO = {
    { 1, 0, false, "Int8Array"         },
    { 1, 0, false, "Uint8Array"        },
    { 1, 0, false, "Uint8ClampedArray" },
    { 2, 1, false, "Int16Array"        },
    { 2, 1, false, "Uint16Array"       },
    { 4, 2, false, "Int32Array"        },
    { 4, 2, false, "Uint32Array"       },
    { 4, 2, false, "Float32Array"      },
    { 8, 3, false, "Float64Array"      },
    { 8, 3, true,  "BigInt64Array"     },
    { 8, 3, true,  "BigUint64Array"    },
};

/// True iff `cls` is any of the TypedArray element kinds.
fn bool is_typed_array_class(hobject::ObjClass cls) {
    return cls >= hobject::ObjClass.INT8ARRAY && cls <= hobject::ObjClass.BIGUINT64ARRAY;
}

/// True iff `cls` is a BigInt-backed TypedArray (content type "BigInt").
/// Mixing BigInt and non-BigInt arrays in set()/construction throws TypeError.
fn bool is_bigint_typed_array_class(hobject::ObjClass cls) {
    return cls == hobject::ObjClass.BIGINT64ARRAY || cls == hobject::ObjClass.BIGUINT64ARRAY;
}

fn uint ta_elem_size(hobject::ObjClass cls) {
    return TA_INFO[(int)cls - (int)hobject::ObjClass.INT8ARRAY].elem_size;
}

fn uint ta_elem_shift(hobject::ObjClass cls) {
    return TA_INFO[(int)cls - (int)hobject::ObjClass.INT8ARRAY].elem_shift;
}

fn char[] ta_class_name(hobject::ObjClass cls) {
    if (!is_typed_array_class(cls)) return "";
    return TA_INFO[(int)cls - (int)hobject::ObjClass.INT8ARRAY].name;
}

/// ES2022 §7.1.21 CanonicalNumericIndexString — true iff `s` is "-0" or the
/// ToString of some number that round-trips back to the same text (e.g.
/// "1.5", "NaN", "Infinity"). Plain array-index integer strings ("0", "1",
/// ...) are handled separately via HString.is_arridx() and never reach here.
fn bool is_canonical_numeric_index(Heap* heap, HString* s, double* out) {
    char[] bytes = s.get_data();
    if (bytes.len == 2 && bytes[0] == '-' && bytes[1] == '0') {
        *out = -0.0;
        return true;
    }
    double d = vm::hstring_to_number(s);
    if (d != d) {
        // NaN parses only when the source text was literally "NaN".
        if (bytes.len == 3 && bytes[0] == 'N' && bytes[1] == 'a' && bytes[2] == 'N') {
            *out = d;
            return true;
        }
        return false;
    }
    HString* restr = builtin_number_to_hstring(heap, d);
    if (restr == null) return false;
    if (restr.blen != s.blen) return false;
    if (!mem::equals(restr.get_cstr(), s.get_cstr(), s.blen)) return false;
    *out = d;
    return true;
}

// ============================================================================
// Buffer allocation helper (shared with ArrayBuffer construction)
// ============================================================================

/// Allocate a fresh, zeroed ArrayBuffer object of `byte_length` bytes.
/// Returns null (without throwing) on allocation failure so the caller can
/// decide the exact error to raise.
fn HObject* typedarray_alloc_buffer(BuiltinContext* ctx, uint byte_length) {
    char* data = null;
    if (byte_length > 0) {
        data = (char*)ctx.heap.alloc_func(ctx.heap.heap_udata, (usz)byte_length);
        if (data == null) return null;
        mem::clear(data, (sz)((usz)byte_length));
    }
    HObject*? raw = ctx.heap.alloc_object(hobject::ObjClass.ARRAYBUFFER);
    if (catch err = raw) {
        if (data != null) ctx.heap.free_func(ctx.heap.heap_udata, data);
        return null;
    }
    HObject* buf = raw;
    buf.prototype = ctx.heap.arraybuffer_proto;
    (*buf.extra_ptr()).ab.data = data;
    (*buf.extra_ptr()).ab.byte_length = byte_length;
    (*buf.extra_ptr()).ab.views_head = null;
    return buf;
}

/// Link a freshly created view object into its buffer's views_head chain.
fn void typedarray_link_view(HObject* buf, HObject* view) {
    (*view.extra_ptr()).view.buffer = buf;
    (*view.extra_ptr()).view.next_view = (*buf.extra_ptr()).ab.views_head;
    (*buf.extra_ptr()).ab.views_head = view;
}

/// Resolve the constructor's `.prototype` (falling back to the shared
/// %TypedArray%.prototype-derived per-class prototype) for `new.target`-style
/// prototype inheritance.
///
/// Unlike the general-purpose builtin_proto_from_new_target (which silently
/// treats an inaccessible/throwing "prototype" getter as absent), TypedArray
/// construction's GetPrototypeFromConstructor (ES2022 §9.1.15 step 3, via
/// AllocateTypedArray step 1) must propagate a thrown Get(constructor,
/// "prototype") abruptly. Sets ctx.should_throw and returns null on error.
fn HObject* typedarray_instance_proto(BuiltinContext* ctx, HObject* fallback_proto) {
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

/// Resolve the instance prototype for the per-class TypedArray() constructor
/// (ES2022 §22.2.5.1 step 3 AllocateTypedArray -> GetPrototypeFromConstructor).
///
/// This MUST be called only after all argument-processing steps that can
/// throw (ToIndex on a non-object first argument, ArrayBuffer/TypedArray/
/// iterable source validation, etc.) have already succeeded — AllocateTypedArray
/// runs strictly after argument processing in the spec, so a throwing/
/// observable custom `new.target.prototype` getter must never be invoked
/// before an earlier abrupt completion from argument processing.
fn HObject* typed_array_resolve_instance_proto(BuiltinContext* ctx) {
    Heap* heap = ctx.heap;
    // AllocateTypedArray's defaultProto (ES2022 §22.2.5.1 per-class TypedArray()
    // constructor step 3) is the specific subclass's own %XArray.prototype%, not
    // the shared abstract %TypedArray.prototype%.
    HObject* default_proto = heap.typedarray_proto;
    if (ctx.callee_obj != null) {
        HString* proto_key = (HString*)heap.strs[heap::BuiltinStr.PROTOTYPE];
        if (proto_key != null) {
            int pidx = ctx.callee_obj.find_prop_idx((void*)proto_key);
            if (pidx >= 0) {
                TVal pv = ctx.callee_obj.prop_values()[pidx];
                if (pv.is_object() && pv.get_heapptr() != null) {
                    default_proto = (HObject*)pv.get_heapptr();
                }
            }
        }
    }
    return typedarray_instance_proto(ctx, default_proto);
}

/// Store one converted element into `buf`'s backing store at element index
/// `idx` for typed array class `cls`. Assumes bounds have already been
/// validated (used during construction, where the buffer freshly allocated
/// is always large enough).
fn void typedarray_store_converted(HObject* buf, uint byte_offset, hobject::ObjClass cls, uint idx, TVal* val, BuiltinContext* ctx) {
    char* base = (*buf.extra_ptr()).ab.data;
    if (base == null) return;
    uint shift = ta_elem_shift(cls);
    char* p = base + byte_offset + (idx << shift);
    ta_write_element(p, cls, val, ctx);
}

/// Read element `idx` of a live TypedArray, re-deriving the backing pointer
/// from the buffer's CURRENT data (a resizable-buffer resize between calls may
/// have realloc'd it) and returning undefined when `idx` is not a valid integer
/// index (detached, out of bounds, or beyond the current length). Use this in
/// any loop that runs user code between element reads, instead of caching a
/// raw `base` pointer across the callback.
fn TVal ta_read_element_checked(Heap* heap, HObject* obj, uint idx) {
    TVal v;
    if (!ta_is_valid_integer_index(obj, (double)idx)) {
        v.set_undefined();
        return v;
    }
    HObject* buf = (*obj.extra_ptr()).view.buffer;
    char* base = (*buf.extra_ptr()).ab.data + (*obj.extra_ptr()).view.byte_offset;
    return ta_load_element(heap, base, obj.flags.obj_class, idx);
}

// ============================================================================
// Byte-level element load/store — shared by construction and the VM
// GETPROP/PUTPROP fast paths (vm_property.c3).
// ============================================================================

/// Load one element at byte pointer `p` (already offset into the backing
/// store) for typed array class `cls`, converting to a TVal per §22.2 read
/// rules (small int kinds -> fastint, wide/float kinds -> number).
fn TVal ta_load_element(Heap* heap, char* p, hobject::ObjClass cls, uint idx) {
    TVal out;
    uint shift = ta_elem_shift(cls);
    char* ep = p + (idx << shift);
    switch (cls) {
        case hobject::ObjClass.INT8ARRAY: {
            ichar v = *(ichar*)ep;
            out.set_fastint((long)v);
            break;
        }
        case hobject::ObjClass.UINT8ARRAY:
        case hobject::ObjClass.UINT8CLAMPEDARRAY: {
            char v = *(char*)ep;
            out.set_fastint((long)v);
            break;
        }
        case hobject::ObjClass.INT16ARRAY: {
            short v;
            mem::copy(&v, ep, (sz)(2));
            out.set_fastint((long)v);
            break;
        }
        case hobject::ObjClass.UINT16ARRAY: {
            ushort v;
            mem::copy(&v, ep, (sz)(2));
            out.set_fastint((long)v);
            break;
        }
        case hobject::ObjClass.INT32ARRAY: {
            int v;
            mem::copy(&v, ep, (sz)(4));
            out.set_fastint((long)v);
            break;
        }
        case hobject::ObjClass.UINT32ARRAY: {
            uint v;
            mem::copy(&v, ep, (sz)(4));
            if (v < 2147483648u) {
                out.set_fastint((long)v);
            } else {
                out.set_number((double)v);
            }
            break;
        }
        case hobject::ObjClass.FLOAT32ARRAY: {
            float v;
            mem::copy(&v, ep, (sz)(4));
            out.set_number((double)v);
            break;
        }
        case hobject::ObjClass.FLOAT64ARRAY: {
            double v;
            mem::copy(&v, ep, (sz)(8));
            out.set_number(v);
            break;
        }
        case hobject::ObjClass.BIGINT64ARRAY: {
            long v;
            mem::copy(&v, ep, (sz)(8));
            hbigint::HBigInt*? box = hbigint::hbigint_alloc(heap, (int128)v);
            if (catch box) { out.set_undefined(); break; }
            out.set_bigint(box);
            break;
        }
        case hobject::ObjClass.BIGUINT64ARRAY: {
            ulong v;
            mem::copy(&v, ep, (sz)(8));
            hbigint::HBigInt*? box = hbigint::hbigint_alloc(heap, (int128)(uint128)v);
            if (catch box) { out.set_undefined(); break; }
            out.set_bigint(box);
            break;
        }
        default:
            out.set_undefined();
            break;
    }
    return out;
}

/// ES2022 §7.1.11 ToUint8Clamp — NaN -> 0, clamp to [0,255], banker's
/// rounding (round half to even) on ties. Matches QuickJS JS_ToUint8ClampFree.
fn char ta_to_uint8_clamped(double d) {
    if (d != d) return 0; // NaN
    if (d <= 0.0) return 0;
    if (d >= 255.0) return 255;
    double fl = (double)(long)d;
    double diff = d - fl;
    if (diff < 0.5) return (char)(long)fl;
    if (diff > 0.5) return (char)((long)fl + 1);
    // Exactly .5 — round to even.
    long fli = (long)fl;
    if (fli % 2 == 0) return (char)fli;
    return (char)(fli + 1);
}

/// Convert `val` (already-available TVal) to a JS double per ToNumber,
/// using the VM when the value is an object. Used for element writes.
fn double ta_val_to_number(TVal* val, BuiltinContext* ctx) {
    if (val.is_fastint()) return (double)val.get_fastint();
    if (val.is_number()) return val.get_number();
    return builtin_to_number_vm(ctx, val);
}

/// Write one converted element at byte pointer `p` for class `cls`. Performs
/// the ToNumber/ToInt32/ToUint32/clamp conversion first (per spec, this may
/// run user code that detaches the buffer); the caller is responsible for
/// bounds/detach checking AFTER conversion and for skipping the store if so.
fn void ta_write_element(char* p, hobject::ObjClass cls, TVal* val, BuiltinContext* ctx) {
    switch (cls) {
        case hobject::ObjClass.INT8ARRAY:
        case hobject::ObjClass.UINT8ARRAY: {
            double d = ta_val_to_number(val, ctx);
            if (ctx.should_throw) return;
            long iv = double_to_int32(d);
            char b = (char)(iv & 0xFF);
            *(char*)p = b;
            break;
        }
        case hobject::ObjClass.UINT8CLAMPEDARRAY: {
            double d = ta_val_to_number(val, ctx);
            if (ctx.should_throw) return;
            *(char*)p = ta_to_uint8_clamped(d);
            break;
        }
        case hobject::ObjClass.INT16ARRAY:
        case hobject::ObjClass.UINT16ARRAY: {
            double d = ta_val_to_number(val, ctx);
            if (ctx.should_throw) return;
            long iv = double_to_int32(d);
            short sv = (short)(iv & 0xFFFF);
            mem::copy(p, &sv, (sz)(2));
            break;
        }
        case hobject::ObjClass.INT32ARRAY:
        case hobject::ObjClass.UINT32ARRAY: {
            double d = ta_val_to_number(val, ctx);
            if (ctx.should_throw) return;
            long iv = double_to_int32(d);
            int v32 = (int)iv;
            mem::copy(p, &v32, (sz)(4));
            break;
        }
        case hobject::ObjClass.FLOAT32ARRAY: {
            double d = ta_val_to_number(val, ctx);
            if (ctx.should_throw) return;
            float f = (float)d;
            mem::copy(p, &f, (sz)(4));
            break;
        }
        case hobject::ObjClass.FLOAT64ARRAY: {
            double d = ta_val_to_number(val, ctx);
            if (ctx.should_throw) return;
            mem::copy(p, &d, (sz)(8));
            break;
        }
        case hobject::ObjClass.BIGINT64ARRAY:
        case hobject::ObjClass.BIGUINT64ARRAY: {
            // §22.2 SetValueInBuffer for BigInt kinds: ToBigInt (throws
            // TypeError for Number/undefined/etc.), then store the low 64 bits
            // (two's complement wrap-around; BigInt64/BigUint64 share the store).
            bool ok;
            int128 bv = builtin_to_bigint(ctx, val, &ok);
            if (!ok || ctx.should_throw) return;
            long lo = (long)bv;   // low 64 bits, wrapping mod 2^64
            mem::copy(p, &lo, (sz)(8));
            break;
        }
        default:
            break;
    }
}

// A TypedArray element value after the spec's Numeric coercion, before it is
// stored: exactly one of `num`/`big64` is meaningful depending on `is_bigint`.
// Splitting coercion (may run user code / throw) from the store (needs a live
// buffer) lets callers coerce once, re-check detach, and only then write —
// without every method knowing the numeric-vs-BigInt distinction.
struct TAScalar {
    bool   is_bigint;
    double num;
    long   big64;
}

/// Coerce `val` to the element type of `cls` — ToBigInt for BigInt kinds,
/// ToNumber for the rest. May run user code and set ctx.should_throw.
fn TAScalar ta_coerce_element(hobject::ObjClass cls, TVal* val, BuiltinContext* ctx) {
    TAScalar s;
    if (is_bigint_typed_array_class(cls)) {
        s.is_bigint = true;
        bool ok;
        int128 bv = builtin_to_bigint(ctx, val, &ok);
        if (!ok || ctx.should_throw) return s;
        s.big64 = (long)bv;
    } else {
        s.is_bigint = false;
        s.num = ta_val_to_number(val, ctx);
    }
    return s;
}

/// Store a already-coerced scalar at byte pointer `p`. Never runs user code or
/// throws — safe to call after a post-coercion detach re-check.
fn void ta_store_scalar(char* p, hobject::ObjClass cls, TAScalar* s) {
    if (s.is_bigint) {
        mem::copy(p, &s.big64, (sz)(8));
        return;
    }
    switch (cls) {
        case hobject::ObjClass.INT8ARRAY:
        case hobject::ObjClass.UINT8ARRAY: {
            char b = (char)(double_to_int32(s.num) & 0xFF);
            *(char*)p = b;
        }
        case hobject::ObjClass.UINT8CLAMPEDARRAY:
            *(char*)p = ta_to_uint8_clamped(s.num);
        case hobject::ObjClass.INT16ARRAY:
        case hobject::ObjClass.UINT16ARRAY: {
            short sv = (short)(double_to_int32(s.num) & 0xFFFF);
            mem::copy(p, &sv, (sz)(2));
        }
        case hobject::ObjClass.INT32ARRAY:
        case hobject::ObjClass.UINT32ARRAY: {
            int v32 = (int)double_to_int32(s.num);
            mem::copy(p, &v32, (sz)(4));
        }
        case hobject::ObjClass.FLOAT32ARRAY: {
            float f = (float)s.num;
            mem::copy(p, &f, (sz)(4));
        }
        case hobject::ObjClass.FLOAT64ARRAY:
            mem::copy(p, &s.num, (sz)(8));
        default:
            break;
    }
}

/// ES2022 §7.1.6 ToInt32 core, applied to an already-computed double.
/// NaN/Infinity -> 0; otherwise truncate toward zero mod 2^32, reinterpreted
/// as signed 32-bit (sign bit set -> negative).
fn long double_to_int32(double d) {
    if (d != d) return 0; // NaN
    if (d == 1.0 / 0.0 || d == -1.0 / 0.0) return 0;
    double trunc = d < 0.0 ? -math::floor(-d) : math::floor(d);
    double m = trunc - math::floor(trunc / 4294967296.0) * 4294967296.0;
    if (m < 0) m += 4294967296.0;
    uint u = (uint)(ulong)m;
    return (long)(int)u;
}

// ============================================================================
// Shared constructor — dispatch on argv[0]
// ============================================================================

fn void typed_array_construct(BuiltinContext* ctx, hobject::ObjClass obj_class) {
    if (!ctx.is_constructor) {
        arraybuffer_throw_type_error(ctx, "Constructor TypedArray requires 'new'");
        return;
    }

    Heap* heap = ctx.heap;
    uint elem_size = ta_elem_size(obj_class);
    uint shift = ta_elem_shift(obj_class);

    TVal arg0; arg0.set_undefined();
    if (ctx.argc >= 1) arg0 = ctx.regs[ctx.base_reg];

    HObject* buf = null;
    uint byte_offset = 0;
    uint byte_length = 0;

    if (ctx.argc == 0 || !arg0.is_object()) {
        // --- Overload 1: no args / number-like ---
        uint len = 0;
        if (!arraybuffer_to_index(ctx, &arg0, &len)) return;
        uint total_bytes = len * elem_size;
        buf = typedarray_alloc_buffer(ctx, total_bytes);
        if (buf == null) {
            arraybuffer_throw_range_error(ctx, "Out of memory allocating TypedArray");
            return;
        }
        byte_offset = 0;
        byte_length = total_bytes;
    } else {
        HObject* arg_obj = (HObject*)arg0.get_heapptr();

        if (arg_obj != null && is_arraybuffer_obj(arg_obj)) {
            // --- Overload 5: ArrayBuffer shared view ---
            TVal off_arg; off_arg.set_undefined();
            if (ctx.argc >= 2) off_arg = ctx.regs[ctx.base_reg + 1];
            uint off = 0;
            if (!off_arg.is_undefined()) {
                if (!arraybuffer_to_index(ctx, &off_arg, &off)) return;
            }
            if (off % elem_size != 0) {
                arraybuffer_throw_range_error(ctx, "start offset must be a multiple of the element size");
                return;
            }
            uint buf_len = (*arg_obj.extra_ptr()).ab.byte_length;
            if (((*arg_obj.extra_ptr()).ab.byte_length == 0xFFFFFFFFu)) {
                arraybuffer_throw_type_error(ctx, "Cannot construct TypedArray on a detached ArrayBuffer");
                return;
            }
            if (off > buf_len) {
                arraybuffer_throw_range_error(ctx, "start offset out of bounds");
                return;
            }

            TVal len_arg; len_arg.set_undefined();
            if (ctx.argc >= 3) len_arg = ctx.regs[ctx.base_reg + 2];

            // Length-tracking view: no explicit length over a resizable buffer.
            bool length_tracking = len_arg.is_undefined()
                && (*arg_obj.extra_ptr()).ab.resizable;

            uint view_len_bytes;
            if (len_arg.is_undefined()) {
                uint remainder = buf_len - off;
                if (remainder % elem_size != 0 && !length_tracking) {
                    arraybuffer_throw_range_error(ctx, "buffer length minus byteOffset must be a multiple of the element size");
                    return;
                }
                view_len_bytes = remainder;
            } else {
                uint n = 0;
                if (!arraybuffer_to_index(ctx, &len_arg, &n)) return;
                // Spec step 9: after ToInteger(length), re-check if buffer is detached.
                if (((*arg_obj.extra_ptr()).ab.byte_length == 0xFFFFFFFFu)) {
                    arraybuffer_throw_type_error(ctx, "Cannot construct TypedArray on a detached ArrayBuffer");
                    return;
                }
                view_len_bytes = n * elem_size;
                if (off + view_len_bytes > buf_len) {
                    arraybuffer_throw_range_error(ctx, "length out of bounds");
                    return;
                }
            }

            HObject* instance_proto = typed_array_resolve_instance_proto(ctx);
            if (ctx.should_throw) return;

            HObject*? raw = heap.alloc_object(obj_class);
            if (catch err = raw) { ctx.result.set_undefined(); return; }
            HObject* obj = raw;
            obj.prototype = instance_proto;
            (*obj.extra_ptr()).view.byte_offset = off;
            (*obj.extra_ptr()).view.byte_length = view_len_bytes;
            (*obj.extra_ptr()).view.length_tracking = length_tracking;
            typedarray_link_view(arg_obj, obj);
            ctx.result.set_object(obj);
            return;
        }

        if (arg_obj != null && is_typed_array_class(arg_obj.flags.obj_class)) {
            // --- Overload 4: from another TypedArray ---
            hobject::ObjClass src_cls = arg_obj.flags.obj_class;
            HObject* src_buf = (*arg_obj.extra_ptr()).view.buffer;
            if (src_buf == null || ((*src_buf.extra_ptr()).ab.byte_length == 0xFFFFFFFFu)) {
                // Detached source: treat as zero-length.
                buf = typedarray_alloc_buffer(ctx, 0);
                if (buf == null) { ctx.result.set_undefined(); return; }
                byte_offset = 0;
                byte_length = 0;
            } else {
                uint count = ta_element_count(arg_obj);
                uint total_bytes = count * elem_size;
                buf = typedarray_alloc_buffer(ctx, total_bytes);
                if (buf == null) {
                    arraybuffer_throw_range_error(ctx, "Out of memory allocating TypedArray");
                    return;
                }
                byte_offset = 0;
                byte_length = total_bytes;

                char* src_base = (*src_buf.extra_ptr()).ab.data + (*arg_obj.extra_ptr()).view.byte_offset;
                if (src_cls == obj_class) {
                    if (total_bytes > 0) mem::copy((*buf.extra_ptr()).ab.data, src_base, (sz)((usz)total_bytes));
                } else {
                    for (uint i = 0; i < count; i++) {
                        TVal v = ta_load_element(ctx.heap, src_base, src_cls, i);
                        typedarray_store_converted(buf, 0, obj_class, i, &v, ctx);
                        if (ctx.should_throw) return;
                    }
                }
            }
        } else {
            // --- Overload 2/3: iterable or array-like object ---
            HString* iter_sym = ensure_iterator_symbol(heap);
            TVal iter_method; iter_method.set_undefined();
            bool has_iter = false;
            if (iter_sym != null && arg_obj != null) {
                // Use builtins_generic_get so that a throwing getter on @@iterator propagates.
                TVal? im = builtins_generic_get(arg_obj, iter_sym, ctx);
                if (ctx.should_throw) return;
                if (try v = im) {
                    if (!v.is_undefined() && !v.is_null()) {
                        iter_method = v;
                        has_iter = true;
                    }
                }
            }

            if (has_iter) {
                // Collect into a growing TVal buffer via the iterator protocol.
                bool callable = false;
                if (iter_method.is_lightfunc()) {
                    callable = true;
                } else if (iter_method.is_object() && iter_method.get_heapptr() != null) {
                    callable = ((HObject*)iter_method.get_heapptr()).is_callable();
                }
                if (!callable || heap.call_fn == null || ctx.vm == null) {
                    arraybuffer_throw_type_error(ctx, "TypedArray source is not iterable");
                    return;
                }
                TVal iterator = heap.call_fn(ctx.vm, iter_method, null, 0, arg0);
                if (ctx.heap.has_error) {
                    ctx.should_throw = true;
                    ctx.throw_value = ctx.heap.error_value;
                    ctx.heap.has_error = false;
                    return;
                }

                uint cap = 4;
                TVal* items = (TVal*)heap.alloc_func(heap.heap_udata, (usz)cap * TVal::size);
                if (items == null) { ctx.result.set_undefined(); return; }
                uint count = 0;

                HString* next_key = builtin_intern_string(heap, "next");
                HString* done_key = builtin_intern_string(heap, "done");
                HString* value_key = builtin_intern_string(heap, "value");

                while (true) {
                    if (!iterator.is_object() || iterator.get_heapptr() == null) break;
                    HObject* iter_obj = (HObject*)iterator.get_heapptr();
                    TVal? next_method_opt = iter_obj.get_prop_proto(next_key);
                    TVal next_method;
                    if (try nm = next_method_opt) { next_method = nm; } else { break; }
                    bool next_callable = false;
                    if (next_method.is_lightfunc()) {
                        next_callable = true;
                    } else if (next_method.is_object() && next_method.get_heapptr() != null) {
                        next_callable = ((HObject*)next_method.get_heapptr()).is_callable();
                    }
                    if (!next_callable) break;

                    TVal result = heap.call_fn(ctx.vm, next_method, null, 0, iterator);
                    if (ctx.heap.has_error) {
                        heap.free_func(heap.heap_udata, items);
                        ctx.should_throw = true;
                        ctx.throw_value = ctx.heap.error_value;
                        ctx.heap.has_error = false;
                        return;
                    }
                    if (!result.is_object() || result.get_heapptr() == null) break;
                    HObject* result_obj = (HObject*)result.get_heapptr();

                    TVal? done_opt = result_obj.get_prop_proto(done_key);
                    bool done = false;
                    if (try dv = done_opt) done = builtin_to_boolean(&dv);
                    if (done) break;

                    // Use builtins_generic_get so that throwing getters on .value propagate.
                    TVal? value_opt = builtins_generic_get(result_obj, value_key, ctx);
                    if (ctx.should_throw) {
                        heap.free_func(heap.heap_udata, items);
                        return;
                    }
                    TVal next_value; next_value.set_undefined();
                    if (try vv = value_opt) next_value = vv;

                    if (count == cap) {
                        uint new_cap = cap * 2;
                        TVal* new_items = (TVal*)heap.alloc_func(heap.heap_udata, (usz)new_cap * TVal::size);
                        if (new_items == null) { heap.free_func(heap.heap_udata, items); ctx.result.set_undefined(); return; }
                        mem::copy(new_items, items, (sz)((usz)count * TVal::size));
                        heap.free_func(heap.heap_udata, items);
                        items = new_items;
                        cap = new_cap;
                    }
                    items[count] = next_value;
                    count++;
                }

                uint total_bytes = count * elem_size;
                buf = typedarray_alloc_buffer(ctx, total_bytes);
                if (buf == null) {
                    heap.free_func(heap.heap_udata, items);
                    arraybuffer_throw_range_error(ctx, "Out of memory allocating TypedArray");
                    return;
                }
                byte_offset = 0;
                byte_length = total_bytes;
                for (uint i = 0; i < count; i++) {
                    typedarray_store_converted(buf, 0, obj_class, i, &items[i], ctx);
                    if (ctx.should_throw) { heap.free_func(heap.heap_udata, items); return; }
                }
                heap.free_func(heap.heap_udata, items);
            } else {
                // Array-like: read .length then Get(o, i) for i in [0, length).
                HString* length_key = (HString*)heap.strs[heap::BuiltinStr.LENGTH];
                TVal len_tv; len_tv.set_fastint(0);
                if (arg_obj != null) {
                    TVal? lv = builtins_generic_get(arg_obj, length_key, ctx);
                    if (ctx.should_throw) return;
                    if (try v = lv) len_tv = v;
                }
                double len_d = builtin_to_integer_vm(ctx, &len_tv);
                if (ctx.should_throw) return;
                if (len_d < 0.0) len_d = 0.0;
                if (len_d > 9007199254740991.0) {
                    arraybuffer_throw_range_error(ctx, "Invalid typed array length");
                    return;
                }
                uint count = (uint)len_d;

                uint total_bytes = count * elem_size;
                buf = typedarray_alloc_buffer(ctx, total_bytes);
                if (buf == null) {
                    arraybuffer_throw_range_error(ctx, "Out of memory allocating TypedArray");
                    return;
                }
                byte_offset = 0;
                byte_length = total_bytes;

                for (uint i = 0; i < count; i++) {
                    HString* idx_key = heap.int_to_hstring((long)i);
                    TVal elem; elem.set_undefined();
                    if (idx_key != null && arg_obj != null) {
                        TVal? ev = builtins_generic_get(arg_obj, idx_key, ctx);
                        if (ctx.should_throw) return;
                        if (try v = ev) elem = v;
                    }
                    typedarray_store_converted(buf, 0, obj_class, i, &elem, ctx);
                    if (ctx.should_throw) return;
                }
            }
        }
    }

    HObject* instance_proto = typed_array_resolve_instance_proto(ctx);
    if (ctx.should_throw) return;

    HObject*? raw = heap.alloc_object(obj_class);
    if (catch err = raw) { ctx.result.set_undefined(); return; }
    HObject* obj = raw;
    obj.prototype = instance_proto;
    (*obj.extra_ptr()).view.byte_offset = byte_offset;
    (*obj.extra_ptr()).view.byte_length = byte_length;
    typedarray_link_view(buf, obj);
    ctx.result.set_object(obj);
}

// ============================================================================
// Per-type constructors
// ============================================================================

fn void builtin_int8array(BuiltinContext* ctx) {
    typed_array_construct(ctx, hobject::ObjClass.INT8ARRAY);
}

fn void builtin_uint8array(BuiltinContext* ctx) {
    typed_array_construct(ctx, hobject::ObjClass.UINT8ARRAY);
}

fn void builtin_uint8clampedarray(BuiltinContext* ctx) {
    typed_array_construct(ctx, hobject::ObjClass.UINT8CLAMPEDARRAY);
}

fn void builtin_int16array(BuiltinContext* ctx) {
    typed_array_construct(ctx, hobject::ObjClass.INT16ARRAY);
}

fn void builtin_uint16array(BuiltinContext* ctx) {
    typed_array_construct(ctx, hobject::ObjClass.UINT16ARRAY);
}

fn void builtin_int32array(BuiltinContext* ctx) {
    typed_array_construct(ctx, hobject::ObjClass.INT32ARRAY);
}

fn void builtin_uint32array(BuiltinContext* ctx) {
    typed_array_construct(ctx, hobject::ObjClass.UINT32ARRAY);
}

fn void builtin_float32array(BuiltinContext* ctx) {
    typed_array_construct(ctx, hobject::ObjClass.FLOAT32ARRAY);
}

fn void builtin_float64array(BuiltinContext* ctx) {
    typed_array_construct(ctx, hobject::ObjClass.FLOAT64ARRAY);
}

fn void builtin_bigint64array(BuiltinContext* ctx) {
    typed_array_construct(ctx, hobject::ObjClass.BIGINT64ARRAY);
}

fn void builtin_biguint64array(BuiltinContext* ctx) {
    typed_array_construct(ctx, hobject::ObjClass.BIGUINT64ARRAY);
}

// ============================================================================
// %TypedArray%.prototype accessors — length / byteLength / byteOffset / buffer
// ============================================================================

/// Resolve `ctx.this_val` as a TypedArray instance, or return null.
fn HObject* ta_this_receiver(BuiltinContext* ctx) {
    if (!ctx.this_val.is_object() || ctx.this_val.get_heapptr() == null) return null;
    HObject* obj = (HObject*)ctx.this_val.get_heapptr();
    if (!is_typed_array_class(obj.flags.obj_class)) return null;
    return obj;
}

fn void builtin_typedarray_proto_length_get(BuiltinContext* ctx) {
    HObject* obj = ta_this_receiver(ctx);
    if (obj == null) {
        arraybuffer_throw_type_error(ctx, "TypedArray.prototype.length called on incompatible receiver");
        return;
    }
    ctx.result.set_fastint((long)ta_element_count(obj));
}

fn void builtin_typedarray_proto_bytelength_get(BuiltinContext* ctx) {
    HObject* obj = ta_this_receiver(ctx);
    if (obj == null) {
        arraybuffer_throw_type_error(ctx, "TypedArray.prototype.byteLength called on incompatible receiver");
        return;
    }
    ctx.result.set_fastint((long)view_effective_byte_length(obj));
}

fn void builtin_typedarray_proto_byteoffset_get(BuiltinContext* ctx) {
    HObject* obj = ta_this_receiver(ctx);
    if (obj == null) {
        arraybuffer_throw_type_error(ctx, "TypedArray.prototype.byteOffset called on incompatible receiver");
        return;
    }
    // Per §23.2.3.3: 0 when the view is out of bounds (or detached).
    if (view_is_out_of_bounds(obj)) {
        ctx.result.set_fastint(0);
        return;
    }
    ctx.result.set_fastint((long)(*obj.extra_ptr()).view.byte_offset);
}

fn void builtin_typedarray_proto_buffer_get(BuiltinContext* ctx) {
    HObject* obj = ta_this_receiver(ctx);
    if (obj == null) {
        arraybuffer_throw_type_error(ctx, "TypedArray.prototype.buffer called on incompatible receiver");
        return;
    }
    HObject* buf = (*obj.extra_ptr()).view.buffer;
    if (buf == null) {
        ctx.result.set_undefined();
        return;
    }
    ctx.result.set_object(buf);
}

/// [Symbol.toStringTag] getter — returns the class name for TA receivers,
/// undefined otherwise (per spec, this getter never throws).
fn void builtin_typedarray_proto_tostringtag_get(BuiltinContext* ctx) {
    HObject* obj = ta_this_receiver(ctx);
    if (obj == null) {
        ctx.result.set_undefined();
        return;
    }
    HString* name = builtin_intern_string(ctx.heap, ta_class_name(obj.flags.obj_class));
    if (name == null) {
        ctx.result.set_undefined();
        return;
    }
    ctx.result.set_string(name);
}

// ============================================================================
// Wave A: %TypedArray%.prototype methods (plan 049 stage 4)
// ============================================================================

/// Validate that ctx.this_val is a live (non-detached) TypedArray.
/// Returns the object on success, null + sets should_throw on failure.
fn HObject* ta_validate(BuiltinContext* ctx) {
    HObject* obj = ta_this_receiver(ctx);
    if (obj == null) {
        arraybuffer_throw_type_error(ctx, "TypedArray method called on incompatible receiver");
        return null;
    }
    // ValidateTypedArray (§23.2.4.4): reject a detached buffer OR a view that
    // has gone out of bounds because its resizable buffer shrank past it.
    if (view_is_out_of_bounds(obj)) {
        arraybuffer_throw_type_error(ctx, "Typed array is detached or out of bounds");
        return null;
    }
    return obj;
}

/// IsViewOutOfBounds (ES2024 §10.4.5): a view over a resizable buffer goes
/// out of bounds when the buffer shrinks past it. Covers both TypedArray and
/// DataView. Returns true if detached or out of bounds. Fixed (non-resizable)
/// buffers can never be OOB while live, so this collapses to a detach check.
fn bool view_is_out_of_bounds(HObject* obj) {
    HObject* buf = (*obj.extra_ptr()).view.buffer;
    if (buf == null) return true;
    uint buf_len = (*buf.extra_ptr()).ab.byte_length;
    if (buf_len == 0xFFFFFFFFu) return true; // detached
    if (!(*buf.extra_ptr()).ab.resizable) return false; // fixed: never OOB
    uint off = (*obj.extra_ptr()).view.byte_offset;
    if (off > buf_len) return true;
    if ((*obj.extra_ptr()).view.length_tracking) return false;
    return off + (*obj.extra_ptr()).view.byte_length > buf_len;
}

/// Effective byte length of a view given the CURRENT backing buffer length.
/// For length-tracking views this is recomputed from the buffer; for fixed
/// views it is the stored byte_length (0 when out of bounds). For TypedArrays
/// the tracking length is floored to a whole number of elements.
fn uint view_effective_byte_length(HObject* obj) {
    if (view_is_out_of_bounds(obj)) return 0;
    if (!(*obj.extra_ptr()).view.length_tracking) {
        return (*obj.extra_ptr()).view.byte_length;
    }
    HObject* buf = (*obj.extra_ptr()).view.buffer;
    uint buf_len = (*buf.extra_ptr()).ab.byte_length;
    uint off = (*obj.extra_ptr()).view.byte_offset;
    uint avail = buf_len - off; // off <= buf_len guaranteed by not-OOB
    if (is_typed_array_class(obj.flags.obj_class)) {
        uint shift = ta_elem_shift(obj.flags.obj_class);
        // floor to whole elements
        avail = (avail >> shift) << shift;
    }
    return avail;
}

/// Check detach status without throwing — inline guard after user-code calls.
/// Also true when a view over a resizable buffer has gone out of bounds, since
/// callers use this to reject element access on a no-longer-valid view.
fn bool ta_is_detached(HObject* obj) {
    return view_is_out_of_bounds(obj);
}

/// True only when the backing buffer is genuinely detached (freed), NOT merely
/// out of bounds after a shrink. Some spec algorithms (indexOf/lastIndexOf/
/// includes after fromIndex coercion) short-circuit on real detach but keep
/// iterating an OOB view, reading each index as undefined.
fn bool ta_buffer_truly_detached(HObject* obj) {
    HObject* buf = (*obj.extra_ptr()).view.buffer;
    if (buf == null) return true;
    return (*buf.extra_ptr()).ab.byte_length == 0xFFFFFFFFu;
}

/// Element count ([[ArrayLength]]) of a live TypedArray — 0 when detached
/// or out of bounds.
fn uint ta_element_count(HObject* obj) {
    uint shift = ta_elem_shift(obj.flags.obj_class);
    return view_effective_byte_length(obj) >> shift;
}

/// IsValidIntegerIndex (ES2022 §10.4.5.9): true iff `idx` is a non-negative
/// integer, the buffer is not detached, and idx < [[ArrayLength]].
fn bool ta_is_valid_integer_index(HObject* obj, double idx) {
    if (ta_is_detached(obj)) return false;
    if (idx != idx || idx < 0.0) return false;
    if (idx == 0.0 && 1.0 / idx < 0.0) return false; // -0
    if (idx != math::floor(idx)) return false;
    return idx < (double)ta_element_count(obj);
}

/// CanonicalNumericIndexString + integer-index classification for a String
/// property key on a TypedArray (ES2022 §10.4.5 IntegerIndexedObject match).
/// Returns true when `key` is a canonical numeric index string, with
/// `*out_num` set to the numeric value (any finite or infinite double,
/// possibly non-integer or negative) for further checks by the caller.
/// Returns false when `key` is not numeric-index-like at all (ordinary
/// property lookup should proceed as usual).
fn bool ta_key_numeric_index(Heap* heap, HString* key, double* out_num) {
    if (key.is_symbol()) return false;
    if (key.is_arridx()) {
        *out_num = (double)key.array_index();
        return true;
    }
    return is_canonical_numeric_index(heap, key, out_num);
}

/// Integer-Indexed exotic [[GetOwnProperty]] (ES2022 §10.4.5.1) for a String
/// key already known to be a canonical numeric index (`num`). Populates
/// `out` with a data-property descriptor (WEC) when the index is valid;
/// leaves `out.found = false` otherwise (still consumed the key — caller
/// must not fall back to ordinary lookup).
fn void ta_own_index_desc(Heap* heap, HObject* obj, double num, ProxyDesc* out) {
    *out = (ProxyDesc){};
    if (!ta_is_valid_integer_index(obj, num)) return;
    uint idx = (uint)(long)num;
    HObject* buf = (*obj.extra_ptr()).view.buffer;
    char* base = (*buf.extra_ptr()).ab.data + (*obj.extra_ptr()).view.byte_offset;
    out.found = true;
    out.has_value = true;
    out.value = ta_load_element(heap, base, obj.flags.obj_class, idx);
    out.has_writable = true; out.writable = true;
    out.has_enumerable = true; out.enumerable = true;
    out.has_configurable = true; out.configurable = true;
}

/// IntegerIndexedElementSet (ES2022 §10.4.5.10): ToNumber(value) first (may
/// run user code / throw), then silently no-op if OOB/detached afterwards.
/// `ctx` carries should_throw/throw_value for propagating ToNumber errors.
fn void ta_integer_indexed_element_set(BuiltinContext* ctx, HObject* obj, double num, TVal value) {
    hobject::ObjClass cls = obj.flags.obj_class;
    char[8] scratch;
    TVal converted = value;
    ta_write_element((char*)&scratch, cls, &converted, ctx);
    if (ctx.should_throw) return;
    if (!ta_is_valid_integer_index(obj, num)) return;
    uint idx = (uint)(long)num;
    HObject* buf = (*obj.extra_ptr()).view.buffer;
    char* base = (*buf.extra_ptr()).ab.data + (*obj.extra_ptr()).view.byte_offset;
    char* p = base + ((ulong)idx << ta_elem_shift(cls));
    ta_write_element(p, cls, &converted, ctx);
}

/// Normalize a relative index (ES2022 §23.2.4.1 ToIntegerOrInfinity + clamp).
fn uint ta_norm_index(double d, uint len) {
    if (d != d || d == 0.0) return 0;
    if (d < 0.0) {
        double v = (double)len + d;
        return v < 0.0 ? 0u : (uint)(long)v;
    }
    if (d >= (double)len) return len;
    return (uint)(long)d;
}

// ---- Iterator forwarders ----

/// %TypedArray%.prototype.values() — §23.2.3.32. Returns array iterator kind=0.
fn void builtin_ta_proto_values(BuiltinContext* ctx) {
    HObject* obj = ta_validate(ctx);
    if (obj == null) return;
    create_array_iterator(ctx, 0);
}

/// %TypedArray%.prototype.keys() — §23.2.3.16. Returns array iterator kind=1.
fn void builtin_ta_proto_keys(BuiltinContext* ctx) {
    HObject* obj = ta_validate(ctx);
    if (obj == null) return;
    create_array_iterator(ctx, 1);
}

/// %TypedArray%.prototype.entries() — §23.2.3.6. Returns array iterator kind=2.
fn void builtin_ta_proto_entries(BuiltinContext* ctx) {
    HObject* obj = ta_validate(ctx);
    if (obj == null) return;
    create_array_iterator(ctx, 2);
}

// ---- set ----

/// %TypedArray%.prototype.set(source [, offset]) — §23.2.3.24.
fn void builtin_ta_proto_set(BuiltinContext* ctx) {
    HObject* dst = ta_validate(ctx);
    if (dst == null) return;
    Heap* heap = ctx.heap;

    hobject::ObjClass dst_cls = dst.flags.obj_class;
    uint dst_shift = ta_elem_shift(dst_cls);
    HObject* dst_buf = (*dst.extra_ptr()).view.buffer;
    uint dst_byte_off = (*dst.extra_ptr()).view.byte_offset;
    uint dst_len = ta_element_count(dst);

    // Resolve offset argument
    TVal offset_arg; offset_arg.set_undefined();
    if (ctx.argc >= 2) offset_arg = ctx.regs[ctx.base_reg + 1];
    double off_d = builtin_to_integer_vm(ctx, &offset_arg);
    if (ctx.should_throw) return;
    if (off_d < 0.0) {
        arraybuffer_throw_range_error(ctx, "TypedArray.set: offset is negative");
        return;
    }
    // Clamp Infinity / very large doubles to a sentinel that exceeds any TypedArray
    // length, causing the range check below to fire.  Casting Infinity to uint is UB.
    uint target_offset = (off_d >= 4294967296.0) ? 0xFFFFFFFFu : (uint)(long)off_d;

    // Spec step 9: after ToInteger(offset), check if target buffer is detached.
    // valueOf() on the offset arg may have detached the buffer.
    if (ta_is_detached(dst)) {
        arraybuffer_throw_type_error(ctx, "TypedArray.set: target buffer is detached");
        return;
    }

    TVal source_arg; source_arg.set_undefined();
    if (ctx.argc >= 1) source_arg = ctx.regs[ctx.base_reg];

    if (source_arg.is_object() && source_arg.get_heapptr() != null) {
        HObject* src_obj = (HObject*)source_arg.get_heapptr();

        if (is_typed_array_class(src_obj.flags.obj_class)) {
            // TypedArray source path
            hobject::ObjClass src_cls = src_obj.flags.obj_class;
            HObject* src_buf = (*src_obj.extra_ptr()).view.buffer;
            if (src_buf == null || ((*src_buf.extra_ptr()).ab.byte_length == 0xFFFFFFFFu)) {
                arraybuffer_throw_type_error(ctx, "TypedArray.set: source buffer is detached");
                return;
            }
            uint src_len = ta_element_count(src_obj);
            uint src_byte_off = (*src_obj.extra_ptr()).view.byte_offset;

            // Use 64-bit addition to detect overflow of src_len + target_offset.
            if ((ulong)src_len + (ulong)target_offset > (ulong)dst_len) {
                arraybuffer_throw_range_error(ctx, "TypedArray.set: source is too large");
                return;
            }

            char* src_data = (*src_buf.extra_ptr()).ab.data + src_byte_off;
            char* dst_data = (*dst_buf.extra_ptr()).ab.data + dst_byte_off + (target_offset << dst_shift);

            if (src_cls == dst_cls) {
                // Same element type: memmove handles overlap (same buffer).
                uint byte_count = src_len << dst_shift;
                if (byte_count > 0) mem::move(dst_data, src_data, (sz)((usz)byte_count));
            } else if (src_buf == dst_buf) {
                // Cross-class, same buffer: copy elements via temporary scratch.
                uint scratch_bytes = src_len * TVal::size;
                TVal* scratch = (TVal*)heap.alloc_func(heap.heap_udata, (usz)scratch_bytes);
                if (scratch == null) {
                    arraybuffer_throw_range_error(ctx, "TypedArray.set: out of memory");
                    return;
                }
                for (uint i = 0; i < src_len; i++) {
                    scratch[i] = ta_load_element(ctx.heap, src_data, src_cls, i);
                }
                for (uint i = 0; i < src_len; i++) {
                    char* dp = (*dst_buf.extra_ptr()).ab.data + dst_byte_off + ((target_offset + i) << dst_shift);
                    ta_write_element(dp, dst_cls, &scratch[i], ctx);
                    if (ctx.should_throw) { heap.free_func(heap.heap_udata, scratch); return; }
                }
                heap.free_func(heap.heap_udata, scratch);
            } else {
                // Cross-class, different buffers: element loop.
                for (uint i = 0; i < src_len; i++) {
                    TVal v = ta_load_element(ctx.heap, src_data, src_cls, i);
                    char* dp = (*dst_buf.extra_ptr()).ab.data + dst_byte_off + ((target_offset + i) << dst_shift);
                    ta_write_element(dp, dst_cls, &v, ctx);
                    if (ctx.should_throw) return;
                    if (ta_is_detached(dst)) {
                        arraybuffer_throw_type_error(ctx, "TypedArray buffer detached during set");
                        return;
                    }
                }
            }
            ctx.result.set_undefined();
            return;
        }
    }

    // Array-like source path — spec step 14: Let src be ? ToObject(array).
    // Primitives are coerced to wrapper objects; null/undefined throw TypeError.
    if (source_arg.is_null() || source_arg.is_undefined()) {
        arraybuffer_throw_type_error(ctx, "TypedArray.set: cannot convert undefined or null to object");
        return;
    }
    HObject* src_arr = arr_to_object(source_arg, heap);
    if (src_arr == null) {
        arraybuffer_throw_type_error(ctx, "TypedArray.set: ToObject failed");
        return;
    }

    HString* length_key = (HString*)heap.strs[heap::BuiltinStr.LENGTH];
    TVal len_tv; len_tv.set_fastint(0);
    {
        TVal? lv = builtins_generic_get(src_arr, length_key, ctx);
        if (ctx.should_throw) return;
        if (try v = lv) len_tv = v;
    }
    double src_len_d = builtin_to_integer_vm(ctx, &len_tv);
    if (ctx.should_throw) return;
    if (src_len_d < 0.0) src_len_d = 0.0;
    // LengthOfArrayLike may return a very large number; cap to uint range.
    uint src_len = (src_len_d >= 4294967296.0) ? 0xFFFFFFFFu : (uint)(long)src_len_d;

    if ((ulong)src_len + (ulong)target_offset > (ulong)dst_len) {
        arraybuffer_throw_range_error(ctx, "TypedArray.set: source is too large");
        return;
    }

    // Detect exotic String wrapper created by ToObject from a string primitive.
    // Its indexed character properties are served lazily from the underlying
    // HString rather than being stored as named props; builtins_generic_get
    // would miss them.  We pull them out directly here.
    bool src_is_string_exotic = src_arr.flags.exotic_stringobj
        && (*src_arr.extra_ptr()).prim.primitive_value.is_string();
    HString* src_prim_str = null;
    if (src_is_string_exotic) {
        src_prim_str = (HString*)(*src_arr.extra_ptr()).prim.primitive_value.get_heapptr();
    }

    for (uint i = 0; i < src_len; i++) {
        TVal elem; elem.set_undefined();
        if (src_is_string_exotic && src_prim_str != null) {
            // Serve char at index i from the underlying string.
            char[] data = src_prim_str.get_data();
            usz byte_start = (usz)src_prim_str.char_offset_to_byte_offset(i);
            usz byte_end = (usz)src_prim_str.char_offset_to_byte_offset(i + 1);
            if (byte_start < byte_end) {
                usz copy_len = byte_end - byte_start;
                char[8] one;
                if (copy_len >= one.len) copy_len = one.len - 1;
                for (usz j = 0; j < copy_len; j++) { one[j] = data[byte_start + j]; }
                HString*? ch_raw = builtin_intern_string(heap, one[:copy_len]);
                if (try ch = ch_raw) { elem.set_string(ch); }
            }
        } else {
            HString* idx_key = heap.int_to_hstring((long)i);
            if (idx_key != null) {
                TVal? ev = builtins_generic_get(src_arr, idx_key, ctx);
                if (ctx.should_throw) return;
                if (try v = ev) elem = v;
            }
        }
        // Coerce first (ToNumber / ToBigInt — may run user code); then re-check
        // detach per spec §23.2.3.24 step 23a. If the buffer is detached we keep
        // iterating (to run all getters) but skip the store.
        TAScalar sv = ta_coerce_element(dst_cls, &elem, ctx);
        if (ctx.should_throw) return;
        // Re-derive the store pointer from the CURRENT buffer data (a resize in
        // a getter/valueOf may have realloc'd it) and skip the write when the
        // target index is no longer valid (detached or shrunk past it).
        if (ta_is_valid_integer_index(dst, (double)(target_offset + i))) {
            char* dp = (*dst_buf.extra_ptr()).ab.data + dst_byte_off + ((target_offset + i) << dst_shift);
            ta_store_scalar(dp, dst_cls, &sv);
        }
    }
    ctx.result.set_undefined();
}

// ---- subarray ----

/// %TypedArray%.prototype.subarray(begin, end) — §23.2.3.27.
/// Returns a new TA of the same class sharing the same ArrayBuffer.
fn void builtin_ta_proto_subarray(BuiltinContext* ctx) {
    // Spec §23.2.3.27: subarray validates receiver type but does NOT check detach
    // before ToInteger(begin)/ToInteger(end) — detach is only checked by the new
    // TA constructor (TypedArraySpeciesCreate step 4 → TypedArray(buf) step 11).
    HObject* obj = ta_this_receiver(ctx);
    if (obj == null) {
        arraybuffer_throw_type_error(ctx, "TypedArray method called on incompatible receiver");
        return;
    }
    Heap* heap = ctx.heap;

    hobject::ObjClass cls = obj.flags.obj_class;
    uint shift = ta_elem_shift(cls);
    HObject* buf = (*obj.extra_ptr()).view.buffer;
    uint byte_off = (*obj.extra_ptr()).view.byte_offset;
    // Effective element count — 0 when detached/out of bounds, and for a
    // length-tracking view reflects the current backing buffer length.
    uint len = ta_element_count(obj);

    TVal begin_arg; begin_arg.set_undefined();
    TVal end_arg;   end_arg.set_undefined();
    if (ctx.argc >= 1) begin_arg = ctx.regs[ctx.base_reg];
    if (ctx.argc >= 2) end_arg   = ctx.regs[ctx.base_reg + 1];

    double begin_d = builtin_to_integer_vm(ctx, &begin_arg);
    if (ctx.should_throw) return;
    double end_d;
    if (end_arg.is_undefined()) {
        end_d = (double)len;
    } else {
        end_d = builtin_to_integer_vm(ctx, &end_arg);
        if (ctx.should_throw) return;
    }

    uint begin_idx = ta_norm_index(begin_d, len);

    // §23.2.3.27: a length-tracking view with `end` omitted produces another
    // length-tracking view — newLength is undefined and species is called with
    // only (buffer, beginByteOffset).
    bool result_tracking = (*obj.extra_ptr()).view.length_tracking && end_arg.is_undefined();

    uint end_idx   = ta_norm_index(end_d, len);
    uint new_len   = end_idx > begin_idx ? end_idx - begin_idx : 0;

    uint new_byte_off = byte_off + (begin_idx << shift);
    uint new_byte_len = new_len << shift;

    // TypedArraySpeciesCreate(O, « buf, beginByteOffset, newLength »)
    // §23.2.3.27 step 13: look up constructor and @@species on O.
    HString* ctor_key = (HString*)heap.strs[heap::BuiltinStr.CONSTRUCTOR];
    TVal ctor_val;
    if (try c = builtins_generic_get(obj, ctor_key, ctx)) {
        ctor_val = c;
        if (ctx.should_throw) return;
    } else {
        return;
    }

    HObject* species_ctor = null;
    if (!ctor_val.is_undefined()) {
        if (!ctor_val.is_object() || ctor_val.get_heapptr() == null) {
            arraybuffer_throw_type_error(ctx, "TypedArray.subarray: constructor is not an object");
            return;
        }
        HObject* c_obj = (HObject*)ctor_val.get_heapptr();
        HString* species_sym = ensure_species_symbol(heap);
        if (species_sym != null) {
            TVal species_val;
            if (try s = builtins_generic_get(c_obj, species_sym, ctx)) {
                species_val = s;
                if (ctx.should_throw) return;
            } else {
                return;
            }
            if (!species_val.is_null() && !species_val.is_undefined()) {
                if (!species_val.is_object() || species_val.get_heapptr() == null ||
                    !((HObject*)species_val.get_heapptr()).is_callable()) {
                    arraybuffer_throw_type_error(ctx, "TypedArray.subarray: @@species is not a constructor");
                    return;
                }
                species_ctor = (HObject*)species_val.get_heapptr();
            }
        }
    }

    if (species_ctor != null) {
        // Call species_ctor(buf, beginByteOffset[, newLength]). A length-tracking
        // source with `end` omitted passes only 2 args (newLength is undefined).
        TVal[3] args;
        args[0].set_object(buf);
        args[1].set_fastint((long)new_byte_off);
        args[2].set_fastint((long)new_len);
        uint argc = result_tracking ? 2 : 3;
        TVal species_tv; species_tv.set_object(species_ctor);
        TVal result_tv = heap.construct_fn(ctx.vm, species_tv, &args[0], argc, species_tv);
        if (heap.has_error) {
            ctx.should_throw = true;
            ctx.throw_value = heap.error_value;
            heap.has_error = false;
            return;
        }
        if (!result_tv.is_object() || result_tv.get_heapptr() == null) {
            arraybuffer_throw_type_error(ctx, "TypedArray.subarray: species constructor did not return an object");
            return;
        }
        HObject* result_obj = (HObject*)result_tv.get_heapptr();
        if (!is_typed_array_class(result_obj.flags.obj_class)) {
            arraybuffer_throw_type_error(ctx, "TypedArray.subarray: species constructor did not return a TypedArray");
            return;
        }
        ctx.result.set_object(result_obj);
    } else {
        // Default: allocate same-class view sharing the same buffer.
        HObject*? raw = heap.alloc_object(cls);
        if (catch err = raw) { ctx.result.set_undefined(); return; }
        HObject* sub = raw;
        sub.prototype = obj.prototype != null ? obj.prototype : heap.typedarray_proto;
        (*sub.extra_ptr()).view.byte_offset = new_byte_off;
        (*sub.extra_ptr()).view.byte_length = new_byte_len;
        (*sub.extra_ptr()).view.length_tracking = result_tracking;
        typedarray_link_view(buf, sub);
        ctx.result.set_object(sub);
    }
}

// ---- fill ----

/// %TypedArray%.prototype.fill(value, start, end) — §23.2.3.9.
fn void builtin_ta_proto_fill(BuiltinContext* ctx) {
    HObject* obj = ta_validate(ctx);
    if (obj == null) return;
    Heap* heap = ctx.heap;

    hobject::ObjClass cls = obj.flags.obj_class;
    uint shift = ta_elem_shift(cls);
    HObject* buf = (*obj.extra_ptr()).view.buffer;
    uint byte_off = (*obj.extra_ptr()).view.byte_offset;
    uint len = ta_element_count(obj);

    TVal val_arg; val_arg.set_undefined();
    if (ctx.argc >= 1) val_arg = ctx.regs[ctx.base_reg];

    // Coerce the fill value exactly once up front (ToNumber, or ToBigInt for
    // BigInt arrays — §23.2.3.8 step 3); may run user code.
    TAScalar fill = ta_coerce_element(cls, &val_arg, ctx);
    if (ctx.should_throw) return;
    if (ta_is_detached(obj)) {
        arraybuffer_throw_type_error(ctx, "TypedArray buffer detached during fill");
        return;
    }

    TVal start_arg; start_arg.set_undefined();
    TVal end_arg;   end_arg.set_undefined();
    if (ctx.argc >= 2) start_arg = ctx.regs[ctx.base_reg + 1];
    if (ctx.argc >= 3) end_arg   = ctx.regs[ctx.base_reg + 2];

    double start_d = builtin_to_integer_vm(ctx, &start_arg);
    if (ctx.should_throw) return;
    double end_d;
    if (end_arg.is_undefined()) {
        end_d = (double)len;
    } else {
        end_d = builtin_to_integer_vm(ctx, &end_arg);
        if (ctx.should_throw) return;
    }

    // Detach check after all coercions (spec §23.2.3.7 step 14).
    if (ta_is_detached(obj)) {
        arraybuffer_throw_type_error(ctx, "TypedArray buffer detached during fill");
        return;
    }

    // Spec §23.2.3.11 step 10: after coercions (which may resize a resizable
    // buffer) re-derive the length and clamp the bounds to it, so a shrink turns
    // out-of-range writes into no-ops.
    len = ta_element_count(obj);

    uint k = ta_norm_index(start_d, len);
    uint final_k = ta_norm_index(end_d, len);

    if (k < final_k) {
        char* base = (*buf.extra_ptr()).ab.data + byte_off;
        if (!fill.is_bigint && (cls == hobject::ObjClass.UINT8ARRAY || cls == hobject::ObjClass.INT8ARRAY)) {
            // Single-byte fill: truncate to int8, then bulk memset.
            char fill_byte = (char)(double_to_int32(fill.num) & 0xFF);
            mem::set(base + k, (int)fill_byte, (sz)((usz)(final_k - k)));
        } else if (!fill.is_bigint && cls == hobject::ObjClass.UINT8CLAMPEDARRAY) {
            char clamped = ta_to_uint8_clamped(fill.num);
            mem::set(base + k, (int)clamped, (sz)((usz)(final_k - k)));
        } else {
            // General path (all wide numeric kinds + BigInt): store the
            // pre-coerced scalar; never throws or runs user code.
            for (uint i = k; i < final_k; i++) {
                char* p = base + (i << shift);
                ta_store_scalar(p, cls, &fill);
                if (ctx.should_throw) return;
            }
        }
    }

    *ctx.result = ctx.this_val;
}

// ---- copyWithin ----

/// %TypedArray%.prototype.copyWithin(target, start [, end]) — §23.2.3.6.
fn void builtin_ta_proto_copyWithin(BuiltinContext* ctx) {
    HObject* obj = ta_validate(ctx);
    if (obj == null) return;
    Heap* heap = ctx.heap;

    hobject::ObjClass cls = obj.flags.obj_class;
    uint shift = ta_elem_shift(cls);
    HObject* buf = (*obj.extra_ptr()).view.buffer;
    uint byte_off = (*obj.extra_ptr()).view.byte_offset;
    uint len = ta_element_count(obj);

    TVal target_arg; target_arg.set_undefined();
    TVal start_arg;  start_arg.set_undefined();
    TVal end_arg;    end_arg.set_undefined();
    if (ctx.argc >= 1) target_arg = ctx.regs[ctx.base_reg];
    if (ctx.argc >= 2) start_arg  = ctx.regs[ctx.base_reg + 1];
    if (ctx.argc >= 3) end_arg    = ctx.regs[ctx.base_reg + 2];

    double to_d    = builtin_to_integer_vm(ctx, &target_arg);
    if (ctx.should_throw) return;
    double from_d  = builtin_to_integer_vm(ctx, &start_arg);
    if (ctx.should_throw) return;
    double final_d;
    if (end_arg.is_undefined()) {
        final_d = (double)len;
    } else {
        final_d = builtin_to_integer_vm(ctx, &end_arg);
        if (ctx.should_throw) return;
    }

    // Re-check detach after argument coercions (may have run user code).
    if (ta_is_detached(obj)) {
        arraybuffer_throw_type_error(ctx, "TypedArray buffer detached during copyWithin");
        return;
    }

    uint to    = ta_norm_index(to_d, len);
    uint from  = ta_norm_index(from_d, len);
    uint final_end = ta_norm_index(final_d, len);

    uint count = final_end > from ? final_end - from : 0;
    uint room = len > to ? len - to : 0;
    if (count > room) count = room;

    // Spec §23.2.3.5 step 14: after coercions (which may resize a resizable
    // buffer) re-clamp the copy so it stays within the current element count.
    uint cur_len = ta_element_count(obj);
    if (to >= cur_len || from >= cur_len) {
        count = 0;
    } else {
        uint max_from_to = cur_len - to;
        uint max_from_src = cur_len - from;
        if (count > max_from_to) count = max_from_to;
        if (count > max_from_src) count = max_from_src;
    }

    if (count > 0) {
        char* base = (*buf.extra_ptr()).ab.data + byte_off;
        mem::move(base + (to << shift), base + (from << shift), (sz)((usz)(count << shift)));
    }

    *ctx.result = ctx.this_val;
}

// ---- slice ----

/// %TypedArray%.prototype.slice(start, end) — §23.2.3.25.
/// Returns a new same-class TA with a fresh copy of the slice.
fn void builtin_ta_proto_slice(BuiltinContext* ctx) {
    HObject* obj = ta_validate(ctx);
    if (obj == null) return;
    Heap* heap = ctx.heap;

    hobject::ObjClass cls = obj.flags.obj_class;
    uint shift = ta_elem_shift(cls);
    HObject* src_buf = (*obj.extra_ptr()).view.buffer;
    uint byte_off = (*obj.extra_ptr()).view.byte_offset;
    uint len = ta_element_count(obj);

    TVal start_arg; start_arg.set_undefined();
    TVal end_arg;   end_arg.set_undefined();
    if (ctx.argc >= 1) start_arg = ctx.regs[ctx.base_reg];
    if (ctx.argc >= 2) end_arg   = ctx.regs[ctx.base_reg + 1];

    double start_d = builtin_to_integer_vm(ctx, &start_arg);
    if (ctx.should_throw) return;
    double end_d;
    if (end_arg.is_undefined()) {
        end_d = (double)len;
    } else {
        end_d = builtin_to_integer_vm(ctx, &end_arg);
        if (ctx.should_throw) return;
    }

    uint k = ta_norm_index(start_d, len);
    uint final_k = ta_norm_index(end_d, len);
    uint count = final_k > k ? final_k - k : 0;

    // TypedArraySpeciesCreate to get the result TA (may invoke user code).
    HObject* result = ta_species_create(ctx, obj, count);
    if (result == null) return;

    // §23.2.3.26 step 14: after TypedArraySpeciesCreate (which may run user
    // code that resizes the source's backing buffer):
    //   a-b. If the source is now out of bounds, throw a TypeError.
    //   c-d. Otherwise clamp endIndex to the current length and re-derive the
    //        number of elements to copy. Elements beyond the shrunk source stay
    //        zero in the (zero-initialized) result.
    uint copy_count = count;
    if (count > 0) {
        if (ta_is_detached(obj)) {
            arraybuffer_throw_type_error(ctx, "TypedArray.slice: source buffer went out of bounds during species construction");
            return;
        }
        uint cur_len = ta_element_count(obj);
        uint end_index = final_k < cur_len ? final_k : cur_len;
        copy_count = end_index > k ? end_index - k : 0;
    }

    if (copy_count > 0) {
        hobject::ObjClass result_cls = result.flags.obj_class;
        HObject* result_buf = (*result.extra_ptr()).view.buffer;
        uint result_byte_off = (*result.extra_ptr()).view.byte_offset;
        char* src_data = (*src_buf.extra_ptr()).ab.data + byte_off + (k << shift);
        char* dst_data = (*result_buf.extra_ptr()).ab.data + result_byte_off;

        uint result_shift = ta_elem_shift(result_cls);
        if (result_cls == cls && result_buf != src_buf) {
            // Same element type, disjoint buffers: bulk copy is safe.
            mem::copy(dst_data, src_data, (sz)((usz)(copy_count << shift)));
        } else {
            // Either different types, or same buffer (shared between src and result
            // via species constructor): element-by-element copy per spec step 14g.
            // For same-buffer cases the spec requires reading each src element before
            // writing to dst (which may overlap), so element-by-element is required.
            for (uint i = 0; i < copy_count; i++) {
                TVal v = ta_load_element(ctx.heap, src_data, cls, i);
                char* dp = dst_data + (i << result_shift);
                ta_write_element(dp, result_cls, &v, ctx);
                if (ctx.should_throw) return;
            }
        }
    }

    ctx.result.set_object(result);
}

// ============================================================================
// Wave B: %TypedArray%.prototype methods (plan 049 stage 5)
// ============================================================================

/// Check that val is callable (object with callable flag). Throws TypeError if not.
fn bool ta_check_callback(TVal val, BuiltinContext* ctx) {
    if (val.is_object() && val.get_heapptr() != null && ((HObject*)val.get_heapptr()).is_callable()) {
        return true;
    }
    arraybuffer_throw_type_error(ctx, "TypedArray callback is not a function");
    return false;
}

/// Call callback(element, index, ta) with thisArg. Sets ctx.should_throw on error.
fn TVal ta_call_callback(BuiltinContext* ctx, TVal callback, TVal thisArg, TVal v, uint k, HObject* ta) {
    TVal[3] args;
    args[0] = v;
    TVal k_tv; k_tv.set_fastint((long)k);
    args[1] = k_tv;
    args[2].set_object((void*)ta);
    TVal res = ctx.heap.call_fn(ctx.vm, callback, &args[0], 3, thisArg);
    if (ctx.heap.has_error) {
        ctx.should_throw = true;
        ctx.throw_value = ctx.heap.error_value;
        ctx.heap.has_error = false;
    }
    return res;
}

/// TypedArraySpeciesCreate (ES §22.2.4.7): allocate a TypedArray for use as
/// the result of slice/map/filter/subarray, honouring `constructor[@@species]`
/// if present. Falls back to same-class allocation when species is absent.
/// Returns null and sets ctx.should_throw on error.
fn HObject* ta_species_create(BuiltinContext* ctx, HObject* exemplar, uint count) {
    hobject::ObjClass cls = exemplar.flags.obj_class;
    Heap* heap = ctx.heap;

    // Step 1: Get exemplar.constructor.
    HString* ctor_key = (HString*)heap.strs[heap::BuiltinStr.CONSTRUCTOR];
    TVal ctor_val;
    if (try c = builtins_generic_get(exemplar, ctor_key, ctx)) {
        ctor_val = c;
        if (ctx.should_throw) return null;
    } else {
        return null;
    }

    // Step 2: If constructor is undefined, use the default (same-class) path.
    if (ctor_val.is_undefined()) {
        return ta_alloc_same_class_from(ctx, exemplar, count);
    }

    // Step 3: constructor must be an Object.
    if (!ctor_val.is_object() || ctor_val.get_heapptr() == null) {
        arraybuffer_throw_type_error(ctx, "TypedArray species: constructor is not an object");
        return null;
    }
    HObject* c_obj = (HObject*)ctor_val.get_heapptr();

    // Step 4: Get constructor[@@species].
    HString* species_sym = ensure_species_symbol(heap);
    if (species_sym == null) {
        // No Symbol.species interned: fall back to same-class.
        return ta_alloc_same_class_from(ctx, exemplar, count);
    }

    TVal species_val;
    if (try s = builtins_generic_get(c_obj, species_sym, ctx)) {
        species_val = s;
        if (ctx.should_throw) return null;
    } else {
        return null;
    }

    // Step 5: If species is null or undefined, use default.
    if (species_val.is_null() || species_val.is_undefined()) {
        return ta_alloc_same_class_from(ctx, exemplar, count);
    }

    // Step 6: species must be a constructor (callable object).
    if (!species_val.is_object() || species_val.get_heapptr() == null) {
        arraybuffer_throw_type_error(ctx, "TypedArray species: @@species is not a constructor");
        return null;
    }
    HObject* species_obj = (HObject*)species_val.get_heapptr();
    if (!species_obj.is_callable()) {
        arraybuffer_throw_type_error(ctx, "TypedArray species: @@species is not a constructor");
        return null;
    }

    // Step 7: Call species constructor with count argument.
    TVal count_arg; count_arg.set_fastint((long)count);
    TVal result_tv = heap.construct_fn(ctx.vm, species_val, &count_arg, 1, species_val);
    if (heap.has_error) {
        ctx.should_throw = true;
        ctx.throw_value = heap.error_value;
        heap.has_error = false;
        return null;
    }

    // Step 8: Result must be a TypedArray object.
    if (!result_tv.is_object() || result_tv.get_heapptr() == null) {
        arraybuffer_throw_type_error(ctx, "TypedArray species: constructor did not return an object");
        return null;
    }
    HObject* result_obj = (HObject*)result_tv.get_heapptr();
    if (!is_typed_array_class(result_obj.flags.obj_class)) {
        arraybuffer_throw_type_error(ctx, "TypedArray species: constructor did not return a TypedArray");
        return null;
    }

    // Step 9: Result must have at least count elements and a live buffer.
    HObject* result_buf = (*result_obj.extra_ptr()).view.buffer;
    if (result_buf == null || ((*result_buf.extra_ptr()).ab.byte_length == 0xFFFFFFFFu)) {
        arraybuffer_throw_type_error(ctx, "TypedArray species: result buffer is detached");
        return null;
    }
    uint result_len = ta_element_count(result_obj);
    if (result_len < count) {
        arraybuffer_throw_type_error(ctx, "TypedArray species: result TypedArray is too small");
        return null;
    }

    return result_obj;
}

/// Allocate a new same-class TA of `length` elements (fresh zeroed buffer).
/// `src_proto` is the prototype of the source TA (so the result inherits the
/// same per-ctor prototype and instanceof checks work). Pass null to fall back
/// to the shared %TypedArray%.prototype.
fn HObject* ta_alloc_same_class(BuiltinContext* ctx, hobject::ObjClass cls, uint length) {
    uint shift = ta_elem_shift(cls);
    uint new_bytes = length << shift;
    HObject* new_buf = typedarray_alloc_buffer(ctx, new_bytes);
    if (new_buf == null) {
        arraybuffer_throw_range_error(ctx, "TypedArray: out of memory");
        return null;
    }
    HObject*? raw = ctx.heap.alloc_object(cls);
    if (catch err = raw) {
        arraybuffer_throw_range_error(ctx, "TypedArray: out of memory");
        return null;
    }
    HObject* result = raw;
    result.prototype = ctx.heap.typedarray_proto;
    (*result.extra_ptr()).view.byte_offset = 0;
    (*result.extra_ptr()).view.byte_length = new_bytes;
    typedarray_link_view(new_buf, result);
    return result;
}

/// Allocate same-class TA, inheriting the source object's prototype chain
/// so instanceof checks work (e.g., map on Uint8Array returns Uint8Array).
fn HObject* ta_alloc_same_class_from(BuiltinContext* ctx, HObject* src, uint length) {
    hobject::ObjClass cls = src.flags.obj_class;
    HObject* result = ta_alloc_same_class(ctx, cls, length);
    if (result != null && src.prototype != null) {
        result.prototype = src.prototype;
    }
    return result;
}

/// %TypedArray%.prototype.indexOf(searchElement, fromIndex=0) — §23.2.3.14.
/// NaN search always returns -1 (strict equality, NaN !== NaN).
fn void builtin_ta_proto_indexOf(BuiltinContext* ctx) {
    HObject* obj = ta_validate(ctx);
    if (obj == null) return;
    hobject::ObjClass cls = obj.flags.obj_class;
    uint shift = ta_elem_shift(cls);
    HObject* buf = (*obj.extra_ptr()).view.buffer;
    uint byte_off = (*obj.extra_ptr()).view.byte_offset;
    uint len = ta_element_count(obj);
    char* base = (*buf.extra_ptr()).ab.data + byte_off;

    // Spec: if len == 0 return -1 immediately, before evaluating fromIndex.
    if (len == 0) { ctx.result.set_fastint(-1); return; }

    TVal search_arg; search_arg.set_undefined();
    if (ctx.argc >= 1) search_arg = ctx.regs[ctx.base_reg];

    // fromIndex (ToIntegerOrInfinity) is evaluated before any comparison and
    // may throw — do it even when searchElement can't possibly match (§23.2.3.13).
    uint from = 0;
    if (ctx.argc >= 2) {
        TVal from_arg = ctx.regs[ctx.base_reg + 1];
        double from_d = ta_val_to_number(&from_arg, ctx);
        if (ctx.should_throw) return;
        // Spec §23.2.3.13: the length is captured BEFORE fromIndex coercion and
        // is NOT re-derived — a grow adds elements we never look at, and a shrink
        // makes the tail read as undefined (handled by ta_read_element_checked).
        // Only detach short-circuits to -1.
        if (ta_buffer_truly_detached(obj)) { ctx.result.set_fastint(-1); return; }
        if (from_d >= (double)len) { ctx.result.set_fastint(-1); return; }
        if (from_d < 0.0) {
            double v = (double)len + from_d;
            from = v < 0.0 ? 0u : (uint)(long)v;
        } else {
            from = (uint)(long)from_d;
        }
    }

    // Element comparison is IsStrictlyEqual on TVals (ta_load_element already
    // boxes BigInt kinds), so the same code path is correct for numeric and
    // BigInt arrays. A search value that can't === any element simply never
    // matches; NaN/-0/mismatched-type all fall out of strict_eq naturally.
    // Out-of-bounds indices (buffer shrank during fromIndex coercion) are NOT
    // present — skip them so a search for undefined never spuriously matches
    // (spec §23.2.3.13 accesses the element only via IsValidIntegerIndex).
    for (uint i = from; i < len; i++) {
        if (!ta_is_valid_integer_index(obj, (double)i)) continue;
        TVal elem = ta_read_element_checked(ctx.heap, obj, i);
        if (vm::strict_eq(&search_arg, &elem)) {
            ctx.result.set_fastint((long)i);
            return;
        }
    }
    ctx.result.set_fastint(-1);
}

/// %TypedArray%.prototype.lastIndexOf(searchElement, fromIndex=length-1) — §23.2.3.18.
fn void builtin_ta_proto_lastIndexOf(BuiltinContext* ctx) {
    HObject* obj = ta_validate(ctx);
    if (obj == null) return;
    hobject::ObjClass cls = obj.flags.obj_class;
    uint shift = ta_elem_shift(cls);
    HObject* buf = (*obj.extra_ptr()).view.buffer;
    uint byte_off = (*obj.extra_ptr()).view.byte_offset;
    uint len = ta_element_count(obj);
    char* base = (*buf.extra_ptr()).ab.data + byte_off;

    if (len == 0) { ctx.result.set_fastint(-1); return; }

    TVal search_arg; search_arg.set_undefined();
    if (ctx.argc >= 1) search_arg = ctx.regs[ctx.base_reg];

    // fromIndex (ToIntegerOrInfinity) is evaluated before comparison and may
    // throw, even when searchElement can't match (§23.2.3.17).
    long from = (long)len - 1;
    if (ctx.argc >= 2) {
        TVal from_arg = ctx.regs[ctx.base_reg + 1];
        double from_d = ta_val_to_number(&from_arg, ctx);
        if (ctx.should_throw) return;
        // Length is captured before fromIndex coercion and NOT re-derived (spec
        // §23.2.3.17); only detach short-circuits. Shrunk indices read undefined.
        if (ta_buffer_truly_detached(obj)) { ctx.result.set_fastint(-1); return; }
        if (from_d < 0.0) {
            from = (long)len + (long)from_d;
        } else {
            long fd = (long)from_d;
            from = fd < (long)len ? fd : (long)len - 1;
        }
    }

    // IsStrictlyEqual on TVals — correct for numeric and BigInt arrays alike.
    // Skip out-of-bounds indices (buffer shrank during fromIndex coercion) so a
    // search for undefined never matches a no-longer-present slot.
    for (long i = from; i >= 0; i--) {
        if (!ta_is_valid_integer_index(obj, (double)i)) continue;
        TVal elem = ta_read_element_checked(ctx.heap, obj, (uint)i);
        if (vm::strict_eq(&search_arg, &elem)) {
            ctx.result.set_fastint(i);
            return;
        }
    }
    ctx.result.set_fastint(-1);
}

/// %TypedArray%.prototype.includes(searchElement, fromIndex=0) — §23.2.3.13.
/// SameValueZero: NaN matches NaN, +0 matches -0.
fn void builtin_ta_proto_includes(BuiltinContext* ctx) {
    HObject* obj = ta_validate(ctx);
    if (obj == null) return;
    hobject::ObjClass cls = obj.flags.obj_class;
    uint shift = ta_elem_shift(cls);
    HObject* buf = (*obj.extra_ptr()).view.buffer;
    uint byte_off = (*obj.extra_ptr()).view.byte_offset;
    uint len = ta_element_count(obj);
    char* base = (*buf.extra_ptr()).ab.data + byte_off;

    // Spec: if len == 0 return false immediately, before evaluating fromIndex.
    if (len == 0) { ctx.result.set_boolean(false); return; }

    TVal search_arg; search_arg.set_undefined();
    if (ctx.argc >= 1) search_arg = ctx.regs[ctx.base_reg];

    // fromIndex (ToIntegerOrInfinity) is evaluated before comparison and may
    // throw, even when searchElement can't match (§23.2.3.14).
    uint from = 0;
    if (ctx.argc >= 2) {
        TVal from_arg = ctx.regs[ctx.base_reg + 1];
        double from_d = ta_val_to_number(&from_arg, ctx);
        if (ctx.should_throw) return;
        // Length captured before fromIndex coercion, NOT re-derived (spec
        // §23.2.3.14). A shrink turns tail elements into undefined, which
        // SameValueZero matches when searching for undefined.
        if (ta_buffer_truly_detached(obj)) { ctx.result.set_boolean(false); return; }
        if (from_d >= (double)len) { ctx.result.set_boolean(false); return; }
        if (from_d < 0.0) {
            double v = (double)len + from_d;
            from = v < 0.0 ? 0u : (uint)(long)v;
        } else {
            from = (uint)(long)from_d;
        }
    }

    // SameValueZero on TVals — NaN matches NaN, +0 matches -0, and BigInt
    // matches BigInt; the numeric/BigInt split is handled inside same_value_zero.
    for (uint i = from; i < len; i++) {
        TVal elem = ta_read_element_checked(ctx.heap, obj, i);
        if (same_value_zero(search_arg, elem)) { ctx.result.set_boolean(true); return; }
    }
    ctx.result.set_boolean(false);
}

/// %TypedArray%.prototype.join(separator=",") — §23.2.3.15.
fn void builtin_ta_proto_join(BuiltinContext* ctx) {
    HObject* obj = ta_validate(ctx);
    if (obj == null) return;
    Heap* heap = ctx.heap;
    hobject::ObjClass cls = obj.flags.obj_class;
    uint shift = ta_elem_shift(cls);
    HObject* buf = (*obj.extra_ptr()).view.buffer;
    uint byte_off = (*obj.extra_ptr()).view.byte_offset;
    uint len = ta_element_count(obj);
    char* base = (*buf.extra_ptr()).ab.data + byte_off;

    // Separator — ToString(separator) per spec, must propagate errors (e.g., throwing object).
    char[] sep = ",";
    HString* sep_hs = null;
    if (ctx.argc >= 1) {
        TVal sep_arg = ctx.regs[ctx.base_reg];
        if (!sep_arg.is_undefined()) {
            sep_hs = builtin_to_string_vm(ctx, &sep_arg);
            if (ctx.should_throw) { ctx.result.set_undefined(); return; }
            if (sep_hs != null) {
                ((types::HeapHeader*)sep_hs).incref();
                sep = sep_hs.get_data();
            }
        }
    }


    if (len == 0) {
        if (sep_hs != null) heap.decref((types::HeapHeader*)sep_hs);
        HString* empty = (HString*)heap.strs[heap::BuiltinStr.EMPTY];
        if (empty != null) ctx.result.set_string(empty);
        return;
    }

    // Collect element strings.
    HString*[64] stack_strs;
    HString** heap_strs = null;
    HString*[] elem_strs;
    if (len <= 64) {
        elem_strs = stack_strs[:len];
    } else {
        heap_strs = (HString**)heap.alloc_func(heap.heap_udata, HString*::size * len);
        if (heap_strs == null) {
            if (sep_hs != null) heap.decref((types::HeapHeader*)sep_hs);
            ctx.result.set_undefined();
            return;
        }
        elem_strs = heap_strs[:len];
    }

    usz total_len = 0;
    for (uint i = 0; i < len; i++) {
        // Iterate the ORIGINAL length (spec §23.2.3.16 step 4). A separator
        // coercion may have shrunk the buffer; indices now out of bounds read
        // as undefined and join them as the empty string.
        HString* es;
        if (ta_is_valid_integer_index(obj, (double)i)) {
            HObject* cur_buf = (*obj.extra_ptr()).view.buffer;
            char* cur_base = (*cur_buf.extra_ptr()).ab.data + byte_off;
            TVal elem = ta_load_element(ctx.heap, cur_base, cls, i);
            // ToString on the element TVal — numeric kinds format as numbers,
            // BigInt kinds as their decimal string (§builtin_to_string BIGINT case).
            es = builtin_to_string(heap, &elem);
        } else {
            es = (HString*)heap.strs[heap::BuiltinStr.EMPTY];
        }
        if (es == null) es = (HString*)heap.strs[heap::BuiltinStr.EMPTY];
        ((types::HeapHeader*)es).incref();
        elem_strs[i] = es;
        total_len += es.blen;
    }
    if (len > 1) total_len += sep.len * (usz)(len - 1);

    char* rbuf = (char*)heap.alloc_func(heap.heap_udata, total_len > 0 ? total_len : 1);
    if (rbuf == null) {
        if (sep_hs != null) heap.decref((types::HeapHeader*)sep_hs);
        for (uint i = 0; i < len; i++) heap.decref((types::HeapHeader*)elem_strs[i]);
        if (heap_strs != null) heap.free_func(heap.heap_udata, heap_strs);
        ctx.result.set_undefined();
        return;
    }

    usz off = 0;
    for (uint i = 0; i < len; i++) {
        if (i > 0 && sep.len > 0) {
            mem::copy(&rbuf[off], &sep[0], (sz)(sep.len));
            off += sep.len;
        }
        char[] ed = elem_strs[i].get_data();
        if (ed.len > 0) { mem::copy(&rbuf[off], &ed[0], (sz)(ed.len)); off += ed.len; }
        heap.decref((types::HeapHeader*)elem_strs[i]);
    }
    if (sep_hs != null) heap.decref((types::HeapHeader*)sep_hs);
    if (heap_strs != null) heap.free_func(heap.heap_udata, heap_strs);

    uint hash = heap.hash_string(rbuf[:total_len]);
    HString*? hs_raw = hstring::hstring_alloc(heap, rbuf[:total_len], hash);
    heap.free_func(heap.heap_udata, rbuf);
    if (catch err = hs_raw) { ctx.result.set_undefined(); return; }
    HString* hs = hs_raw;
    heap.str_table_insert(hs);
    ctx.result.set_string(hs);
}

/// %TypedArray%.prototype.forEach(callbackFn, thisArg?) — §23.2.3.12.
fn void builtin_ta_proto_forEach(BuiltinContext* ctx) {
    HObject* obj = ta_validate(ctx);
    if (obj == null) return;
    hobject::ObjClass cls = obj.flags.obj_class;
    uint shift = ta_elem_shift(cls);
    HObject* buf = (*obj.extra_ptr()).view.buffer;
    uint byte_off = (*obj.extra_ptr()).view.byte_offset;
    uint len = ta_element_count(obj);
    char* base = (*buf.extra_ptr()).ab.data + byte_off;

    TVal cb_val; cb_val.set_undefined();
    if (ctx.argc >= 1) cb_val = ctx.regs[ctx.base_reg];
    if (!ta_check_callback(cb_val, ctx)) return;
    TVal this_arg; this_arg.set_undefined();
    if (ctx.argc >= 2) this_arg = ctx.regs[ctx.base_reg + 1];

    for (uint i = 0; i < len; i++) {
        if (ctx.should_throw) { ctx.result.set_undefined(); return; }
        // Spec: a callback may have resized/detached the buffer; element reads at
        // now-invalid indices yield undefined (do NOT break — the loop runs for
        // the full original length). ta_read_element_checked re-derives the data
        // pointer each read so a realloc from a grow is followed correctly.
        TVal elem = ta_read_element_checked(ctx.heap, obj, i);
        ta_call_callback(ctx, cb_val, this_arg, elem, i, obj);
        if (ctx.should_throw) { ctx.result.set_undefined(); return; }
    }
    ctx.result.set_undefined();
}

/// %TypedArray%.prototype.every(callbackFn, thisArg?) — §23.2.3.7.
fn void builtin_ta_proto_every(BuiltinContext* ctx) {
    HObject* obj = ta_validate(ctx);
    if (obj == null) return;
    hobject::ObjClass cls = obj.flags.obj_class;
    uint shift = ta_elem_shift(cls);
    HObject* buf = (*obj.extra_ptr()).view.buffer;
    uint byte_off = (*obj.extra_ptr()).view.byte_offset;
    uint len = ta_element_count(obj);
    char* base = (*buf.extra_ptr()).ab.data + byte_off;

    TVal cb_val; cb_val.set_undefined();
    if (ctx.argc >= 1) cb_val = ctx.regs[ctx.base_reg];
    if (!ta_check_callback(cb_val, ctx)) return;
    TVal this_arg; this_arg.set_undefined();
    if (ctx.argc >= 2) this_arg = ctx.regs[ctx.base_reg + 1];

    for (uint i = 0; i < len; i++) {
        if (ctx.should_throw) { ctx.result.set_undefined(); return; }
        TVal elem;
        elem = ta_read_element_checked(ctx.heap, obj, i);
        TVal test = ta_call_callback(ctx, cb_val, this_arg, elem, i, obj);
        if (ctx.should_throw) { ctx.result.set_undefined(); return; }
        if (!builtin_to_boolean(&test)) {
            ctx.result.set_boolean(false);
            return;
        }
    }
    ctx.result.set_boolean(true);
}

/// %TypedArray%.prototype.some(callbackFn, thisArg?) — §23.2.3.28.
fn void builtin_ta_proto_some(BuiltinContext* ctx) {
    HObject* obj = ta_validate(ctx);
    if (obj == null) return;
    hobject::ObjClass cls = obj.flags.obj_class;
    uint shift = ta_elem_shift(cls);
    HObject* buf = (*obj.extra_ptr()).view.buffer;
    uint byte_off = (*obj.extra_ptr()).view.byte_offset;
    uint len = ta_element_count(obj);
    char* base = (*buf.extra_ptr()).ab.data + byte_off;

    TVal cb_val; cb_val.set_undefined();
    if (ctx.argc >= 1) cb_val = ctx.regs[ctx.base_reg];
    if (!ta_check_callback(cb_val, ctx)) return;
    TVal this_arg; this_arg.set_undefined();
    if (ctx.argc >= 2) this_arg = ctx.regs[ctx.base_reg + 1];

    for (uint i = 0; i < len; i++) {
        if (ctx.should_throw) { ctx.result.set_undefined(); return; }
        TVal elem;
        elem = ta_read_element_checked(ctx.heap, obj, i);
        TVal test = ta_call_callback(ctx, cb_val, this_arg, elem, i, obj);
        if (ctx.should_throw) { ctx.result.set_undefined(); return; }
        if (builtin_to_boolean(&test)) {
            ctx.result.set_boolean(true);
            return;
        }
    }
    ctx.result.set_boolean(false);
}

/// %TypedArray%.prototype.reduce(callbackFn, initialValue?) — §23.2.3.22.
fn void builtin_ta_proto_reduce(BuiltinContext* ctx) {
    HObject* obj = ta_validate(ctx);
    if (obj == null) return;
    hobject::ObjClass cls = obj.flags.obj_class;
    uint shift = ta_elem_shift(cls);
    HObject* buf = (*obj.extra_ptr()).view.buffer;
    uint byte_off = (*obj.extra_ptr()).view.byte_offset;
    uint len = ta_element_count(obj);
    char* base = (*buf.extra_ptr()).ab.data + byte_off;

    TVal cb_val; cb_val.set_undefined();
    if (ctx.argc >= 1) cb_val = ctx.regs[ctx.base_reg];
    if (!ta_check_callback(cb_val, ctx)) return;

    TVal acc;
    uint k = 0;
    if (ctx.argc >= 2) {
        acc = ctx.regs[ctx.base_reg + 1];
    } else {
        if (len == 0) {
            arraybuffer_throw_type_error(ctx, "Reduce of empty TypedArray with no initial value");
            return;
        }
        acc = ta_load_element(ctx.heap, base, cls, 0);
        k = 1;
    }

    TVal undef_this; undef_this.set_undefined();
    for (; k < len; k++) {
        if (ctx.should_throw) { ctx.result.set_undefined(); return; }
        TVal elem;
        elem = ta_read_element_checked(ctx.heap, obj, k);
        TVal[4] args;
        args[0] = acc;
        args[1] = elem;
        TVal k_tv; k_tv.set_fastint((long)k);
        args[2] = k_tv;
        args[3].set_object((void*)obj);
        acc = ctx.heap.call_fn(ctx.vm, cb_val, &args[0], 4, undef_this);
        if (ctx.heap.has_error) {
            ctx.should_throw = true;
            ctx.throw_value = ctx.heap.error_value;
            ctx.heap.has_error = false;
            ctx.result.set_undefined();
            return;
        }
    }
    (*ctx.result) = acc;
}

/// %TypedArray%.prototype.reduceRight(callbackFn, initialValue?) — §23.2.3.23.
fn void builtin_ta_proto_reduceRight(BuiltinContext* ctx) {
    HObject* obj = ta_validate(ctx);
    if (obj == null) return;
    hobject::ObjClass cls = obj.flags.obj_class;
    uint shift = ta_elem_shift(cls);
    HObject* buf = (*obj.extra_ptr()).view.buffer;
    uint byte_off = (*obj.extra_ptr()).view.byte_offset;
    uint len = ta_element_count(obj);
    char* base = (*buf.extra_ptr()).ab.data + byte_off;

    TVal cb_val; cb_val.set_undefined();
    if (ctx.argc >= 1) cb_val = ctx.regs[ctx.base_reg];
    if (!ta_check_callback(cb_val, ctx)) return;

    TVal acc;
    long k;
    if (ctx.argc >= 2) {
        acc = ctx.regs[ctx.base_reg + 1];
        k = (long)len - 1;
    } else {
        if (len == 0) {
            arraybuffer_throw_type_error(ctx, "Reduce of empty TypedArray with no initial value");
            return;
        }
        k = (long)len - 1;
        acc = ta_load_element(ctx.heap, base, cls, (uint)k);
        k--;
    }

    TVal undef_this; undef_this.set_undefined();
    for (; k >= 0; k--) {
        if (ctx.should_throw) { ctx.result.set_undefined(); return; }
        TVal elem;
        elem = ta_read_element_checked(ctx.heap, obj, (uint)k);
        TVal[4] args;
        args[0] = acc;
        args[1] = elem;
        TVal k_tv; k_tv.set_fastint(k);
        args[2] = k_tv;
        args[3].set_object((void*)obj);
        acc = ctx.heap.call_fn(ctx.vm, cb_val, &args[0], 4, undef_this);
        if (ctx.heap.has_error) {
            ctx.should_throw = true;
            ctx.throw_value = ctx.heap.error_value;
            ctx.heap.has_error = false;
            ctx.result.set_undefined();
            return;
        }
    }
    (*ctx.result) = acc;
}

/// %TypedArray%.prototype.map(callbackFn, thisArg?) — §23.2.3.19.
/// Allocates a fresh same-class TA; species is deferred.
fn void builtin_ta_proto_map(BuiltinContext* ctx) {
    HObject* obj = ta_validate(ctx);
    if (obj == null) return;
    Heap* heap = ctx.heap;
    hobject::ObjClass cls = obj.flags.obj_class;
    uint shift = ta_elem_shift(cls);
    HObject* buf = (*obj.extra_ptr()).view.buffer;
    uint byte_off = (*obj.extra_ptr()).view.byte_offset;
    uint len = ta_element_count(obj);
    char* base = (*buf.extra_ptr()).ab.data + byte_off;

    TVal cb_val; cb_val.set_undefined();
    if (ctx.argc >= 1) cb_val = ctx.regs[ctx.base_reg];
    if (!ta_check_callback(cb_val, ctx)) return;
    TVal this_arg; this_arg.set_undefined();
    if (ctx.argc >= 2) this_arg = ctx.regs[ctx.base_reg + 1];

    HObject* result = ta_species_create(ctx, obj, len);
    if (result == null) return;

    hobject::ObjClass result_cls = result.flags.obj_class;
    uint result_shift = ta_elem_shift(result_cls);
    HObject* res_buf = (*result.extra_ptr()).view.buffer;
    uint res_byte_off = (*result.extra_ptr()).view.byte_offset;
    char* res_base = (*res_buf.extra_ptr()).ab.data + res_byte_off;

    for (uint i = 0; i < len; i++) {
        if (ctx.should_throw) { ctx.result.set_undefined(); return; }
        TVal elem;
        elem = ta_read_element_checked(ctx.heap, obj, i);
        TVal mapped = ta_call_callback(ctx, cb_val, this_arg, elem, i, obj);
        if (ctx.should_throw) { ctx.result.set_undefined(); return; }
        char* dp = res_base + (i << result_shift);
        ta_write_element(dp, result_cls, &mapped, ctx);
        if (ctx.should_throw) { ctx.result.set_undefined(); return; }
    }
    ctx.result.set_object(result);
}

/// %TypedArray%.prototype.filter(callbackFn, thisArg?) — §23.2.3.9.
/// Collects matching values, then allocates same-class TA of that size.
fn void builtin_ta_proto_filter(BuiltinContext* ctx) {
    HObject* obj = ta_validate(ctx);
    if (obj == null) return;
    Heap* heap = ctx.heap;
    hobject::ObjClass cls = obj.flags.obj_class;
    uint shift = ta_elem_shift(cls);
    HObject* buf = (*obj.extra_ptr()).view.buffer;
    uint byte_off = (*obj.extra_ptr()).view.byte_offset;
    uint len = ta_element_count(obj);
    char* base = (*buf.extra_ptr()).ab.data + byte_off;

    TVal cb_val; cb_val.set_undefined();
    if (ctx.argc >= 1) cb_val = ctx.regs[ctx.base_reg];
    if (!ta_check_callback(cb_val, ctx)) return;
    TVal this_arg; this_arg.set_undefined();
    if (ctx.argc >= 2) this_arg = ctx.regs[ctx.base_reg + 1];

    // Collect passing values into scratch.
    TVal* scratch = (TVal*)heap.alloc_func(heap.heap_udata, len > 0 ? (usz)(len * TVal::size) : 1);
    if (scratch == null && len > 0) {
        arraybuffer_throw_range_error(ctx, "TypedArray.filter: out of memory");
        return;
    }
    uint count = 0;

    for (uint i = 0; i < len; i++) {
        if (ctx.should_throw) {
            if (scratch != null) heap.free_func(heap.heap_udata, scratch);
            ctx.result.set_undefined();
            return;
        }
        TVal elem;
        elem = ta_read_element_checked(ctx.heap, obj, i);
        TVal test = ta_call_callback(ctx, cb_val, this_arg, elem, i, obj);
        if (ctx.should_throw) {
            if (scratch != null) heap.free_func(heap.heap_udata, scratch);
            ctx.result.set_undefined();
            return;
        }
        if (builtin_to_boolean(&test)) {
            scratch[count] = elem;
            count++;
        }
    }

    HObject* result = ta_species_create(ctx, obj, count);
    if (result == null) {
        if (scratch != null) heap.free_func(heap.heap_udata, scratch);
        return;
    }

    hobject::ObjClass result_cls = result.flags.obj_class;
    uint result_shift = ta_elem_shift(result_cls);
    HObject* res_buf = (*result.extra_ptr()).view.buffer;
    uint res_byte_off = (*result.extra_ptr()).view.byte_offset;
    char* res_base = (*res_buf.extra_ptr()).ab.data + res_byte_off;

    for (uint i = 0; i < count; i++) {
        char* dp = res_base + (i << result_shift);
        ta_write_element(dp, result_cls, &scratch[i], ctx);
        if (ctx.should_throw) {
            heap.free_func(heap.heap_udata, scratch);
            ctx.result.set_undefined();
            return;
        }
    }
    if (scratch != null) heap.free_func(heap.heap_udata, scratch);
    ctx.result.set_object(result);
}

/// %TypedArray%.prototype.find(predicate, thisArg?) — §23.2.3.10.
fn void builtin_ta_proto_find(BuiltinContext* ctx) {
    HObject* obj = ta_validate(ctx);
    if (obj == null) return;
    hobject::ObjClass cls = obj.flags.obj_class;
    uint shift = ta_elem_shift(cls);
    HObject* buf = (*obj.extra_ptr()).view.buffer;
    uint byte_off = (*obj.extra_ptr()).view.byte_offset;
    uint len = ta_element_count(obj);
    char* base = (*buf.extra_ptr()).ab.data + byte_off;

    TVal cb_val; cb_val.set_undefined();
    if (ctx.argc >= 1) cb_val = ctx.regs[ctx.base_reg];
    if (!ta_check_callback(cb_val, ctx)) return;
    TVal this_arg; this_arg.set_undefined();
    if (ctx.argc >= 2) this_arg = ctx.regs[ctx.base_reg + 1];

    for (uint i = 0; i < len; i++) {
        if (ctx.should_throw) { ctx.result.set_undefined(); return; }
        TVal elem = ta_read_element_checked(ctx.heap, obj, i);
        TVal test = ta_call_callback(ctx, cb_val, this_arg, elem, i, obj);
        if (ctx.should_throw) { ctx.result.set_undefined(); return; }
        if (builtin_to_boolean(&test)) {
            (*ctx.result) = elem;
            return;
        }
    }
    ctx.result.set_undefined();
}

/// %TypedArray%.prototype.findIndex(predicate, thisArg?) — §23.2.3.11.
fn void builtin_ta_proto_findIndex(BuiltinContext* ctx) {
    HObject* obj = ta_validate(ctx);
    if (obj == null) return;
    hobject::ObjClass cls = obj.flags.obj_class;
    uint shift = ta_elem_shift(cls);
    HObject* buf = (*obj.extra_ptr()).view.buffer;
    uint byte_off = (*obj.extra_ptr()).view.byte_offset;
    uint len = ta_element_count(obj);
    char* base = (*buf.extra_ptr()).ab.data + byte_off;

    TVal cb_val; cb_val.set_undefined();
    if (ctx.argc >= 1) cb_val = ctx.regs[ctx.base_reg];
    if (!ta_check_callback(cb_val, ctx)) return;
    TVal this_arg; this_arg.set_undefined();
    if (ctx.argc >= 2) this_arg = ctx.regs[ctx.base_reg + 1];

    for (uint i = 0; i < len; i++) {
        if (ctx.should_throw) { ctx.result.set_undefined(); return; }
        TVal elem = ta_read_element_checked(ctx.heap, obj, i);
        TVal test = ta_call_callback(ctx, cb_val, this_arg, elem, i, obj);
        if (ctx.should_throw) { ctx.result.set_undefined(); return; }
        if (builtin_to_boolean(&test)) {
            ctx.result.set_fastint((long)i);
            return;
        }
    }
    ctx.result.set_fastint(-1);
}

/// %TypedArray%.prototype.findLast(predicate, thisArg?) — §23.2.3.12.
fn void builtin_ta_proto_findLast(BuiltinContext* ctx) {
    HObject* obj = ta_validate(ctx);
    if (obj == null) return;
    hobject::ObjClass cls = obj.flags.obj_class;
    uint shift = ta_elem_shift(cls);
    HObject* buf = (*obj.extra_ptr()).view.buffer;
    uint byte_off = (*obj.extra_ptr()).view.byte_offset;
    uint len = ta_element_count(obj);
    char* base = (*buf.extra_ptr()).ab.data + byte_off;

    TVal cb_val; cb_val.set_undefined();
    if (ctx.argc >= 1) cb_val = ctx.regs[ctx.base_reg];
    if (!ta_check_callback(cb_val, ctx)) return;
    TVal this_arg; this_arg.set_undefined();
    if (ctx.argc >= 2) this_arg = ctx.regs[ctx.base_reg + 1];

    for (long i = (long)len - 1; i >= 0; i--) {
        if (ctx.should_throw) { ctx.result.set_undefined(); return; }
        TVal elem = ta_read_element_checked(ctx.heap, obj, (uint)i);
        TVal test = ta_call_callback(ctx, cb_val, this_arg, elem, (uint)i, obj);
        if (ctx.should_throw) { ctx.result.set_undefined(); return; }
        if (builtin_to_boolean(&test)) {
            (*ctx.result) = elem;
            return;
        }
    }
    ctx.result.set_undefined();
}

/// %TypedArray%.prototype.findLastIndex(predicate, thisArg?) — §23.2.3.13.
fn void builtin_ta_proto_findLastIndex(BuiltinContext* ctx) {
    HObject* obj = ta_validate(ctx);
    if (obj == null) return;
    hobject::ObjClass cls = obj.flags.obj_class;
    uint shift = ta_elem_shift(cls);
    HObject* buf = (*obj.extra_ptr()).view.buffer;
    uint byte_off = (*obj.extra_ptr()).view.byte_offset;
    uint len = ta_element_count(obj);
    char* base = (*buf.extra_ptr()).ab.data + byte_off;

    TVal cb_val; cb_val.set_undefined();
    if (ctx.argc >= 1) cb_val = ctx.regs[ctx.base_reg];
    if (!ta_check_callback(cb_val, ctx)) return;
    TVal this_arg; this_arg.set_undefined();
    if (ctx.argc >= 2) this_arg = ctx.regs[ctx.base_reg + 1];

    for (long i = (long)len - 1; i >= 0; i--) {
        if (ctx.should_throw) { ctx.result.set_undefined(); return; }
        TVal elem = ta_read_element_checked(ctx.heap, obj, (uint)i);
        TVal test = ta_call_callback(ctx, cb_val, this_arg, elem, (uint)i, obj);
        if (ctx.should_throw) { ctx.result.set_undefined(); return; }
        if (builtin_to_boolean(&test)) {
            ctx.result.set_fastint(i);
            return;
        }
    }
    ctx.result.set_fastint(-1);
}

/// %TypedArray%.prototype.reverse() — §23.2.3.23. Mutates in place.
fn void builtin_ta_proto_reverse(BuiltinContext* ctx) {
    HObject* obj = ta_validate(ctx);
    if (obj == null) return;
    hobject::ObjClass cls = obj.flags.obj_class;
    uint elem_sz = ta_elem_size(cls);
    HObject* buf = (*obj.extra_ptr()).view.buffer;
    uint byte_off = (*obj.extra_ptr()).view.byte_offset;
    uint len = ta_element_count(obj);
    char* base = (*buf.extra_ptr()).ab.data + byte_off;

    // Swap element pairs using a byte-level buffer.
    char[8] tmp;
    uint lo = 0;
    uint hi = len > 0 ? len - 1 : 0;
    while (lo < hi) {
        char* lp = base + lo * elem_sz;
        char* hp = base + hi * elem_sz;
        mem::copy(&tmp[0], lp, (sz)((usz)elem_sz));
        mem::copy(lp, hp, (sz)((usz)elem_sz));
        mem::copy(hp, &tmp[0], (sz)((usz)elem_sz));
        lo++;
        hi--;
    }
    (*ctx.result) = ctx.this_val;
}

/// %TypedArray%.prototype.toReversed() — §23.2.3.30. Returns new reversed TA.
fn void builtin_ta_proto_toReversed(BuiltinContext* ctx) {
    HObject* obj = ta_validate(ctx);
    if (obj == null) return;
    hobject::ObjClass cls = obj.flags.obj_class;
    uint shift = ta_elem_shift(cls);
    uint elem_sz = ta_elem_size(cls);
    HObject* buf = (*obj.extra_ptr()).view.buffer;
    uint byte_off = (*obj.extra_ptr()).view.byte_offset;
    uint len = ta_element_count(obj);
    char* src = (*buf.extra_ptr()).ab.data + byte_off;

    HObject* result = ta_alloc_same_class_from(ctx, obj, len);
    if (result == null) return;

    HObject* res_buf = (*result.extra_ptr()).view.buffer;
    char* dst = (*res_buf.extra_ptr()).ab.data;

    for (uint i = 0; i < len; i++) {
        mem::copy(dst + i * elem_sz, src + (len - 1 - i) * elem_sz, (sz)((usz)elem_sz));
    }
    ctx.result.set_object(result);
}

/// %TypedArray%.prototype.at(index) — §23.2.3.1.
fn void builtin_ta_proto_at(BuiltinContext* ctx) {
    HObject* obj = ta_validate(ctx);
    if (obj == null) return;
    hobject::ObjClass cls = obj.flags.obj_class;
    uint shift = ta_elem_shift(cls);
    HObject* buf = (*obj.extra_ptr()).view.buffer;
    uint byte_off = (*obj.extra_ptr()).view.byte_offset;
    uint len = ta_element_count(obj);
    char* base = (*buf.extra_ptr()).ab.data + byte_off;

    TVal idx_arg; idx_arg.set_fastint(0);
    if (ctx.argc >= 1) idx_arg = ctx.regs[ctx.base_reg];
    double idx_d = ta_val_to_number(&idx_arg, ctx);
    if (ctx.should_throw) return;
    // ToIntegerOrInfinity
    if (idx_d != idx_d || idx_d == 0.0) idx_d = 0.0;
    long idx;
    if (idx_d >= 9007199254740991.0) {
        idx = (long)len;
    } else if (idx_d <= -9007199254740991.0) {
        ctx.result.set_undefined();
        return;
    } else {
        idx = (long)idx_d;
    }

    if (idx < 0) idx = (long)len + idx;
    if (idx < 0) { ctx.result.set_undefined(); return; }
    // Validate against the CURRENT length (the index coercion may have resized
    // the buffer) and read through the re-derived pointer. Negative indices are
    // still normalized against the pre-coercion length per spec §23.2.3.1.
    (*ctx.result) = ta_read_element_checked(ctx.heap, obj, (uint)idx);
}

/// Numeric comparator for TA sort (spec §23.2.3.29.1).
/// NaN sorts after finite values; -0 sorts before +0.
fn int ta_numeric_compare(double a, double b) {
    bool a_nan = (a != a);
    bool b_nan = (b != b);
    if (a_nan && b_nan) return 0;
    if (a_nan) return 1;
    if (b_nan) return -1;
    if (a < b) return -1;
    if (a > b) return 1;
    // a == b: distinguish -0 from +0 per spec step 9-11.
    // 1/(−0) = −∞, 1/(+0) = +∞
    if (a == 0.0 && b == 0.0) {
        double ia = 1.0 / a;
        double ib = 1.0 / b;
        if (ia < ib) return -1;  // a is -0 (ia=-inf), b is +0 (ib=+inf)
        if (ia > ib) return 1;
    }
    return 0;
}

/// Default TypedArray sort comparator (§23.2.3.29 CompareTypedArrayElements with
/// comparefn = undefined). Operates on element TVals so it is exact for numeric
/// and BigInt arrays alike (BigInt values never lose precision through a double).
fn int ta_default_compare(TVal* a, TVal* b) {
    if (a.is_bigint() && b.is_bigint()) {
        int128 av = a.get_bigint();
        int128 bv = b.get_bigint();
        if (av < bv) return -1;
        if (av > bv) return 1;
        return 0;
    }
    double ad = a.is_fastint() ? (double)a.get_fastint() : a.get_number();
    double bd = b.is_fastint() ? (double)b.get_fastint() : b.get_number();
    return ta_numeric_compare(ad, bd);
}

/// Insertion sort on a TVal[] slice — O(n²) but correct and stable for small n.
/// Elements are element TVals (BigInt kinds already boxed), so the algorithm is
/// element-type agnostic; only the leaf comparators know numeric vs BigInt.
fn void ta_insertion_sort(TVal[] arr, BuiltinContext* ctx, TVal comparefn, bool has_comparefn) {
    uint n = (uint)arr.len;
    for (uint i = 1; i < n; i++) {
        TVal key = arr[i];
        long j = (long)i - 1;
        while (j >= 0) {
            int cmp;
            if (has_comparefn && ctx.heap.call_fn != null && ctx.vm != null) {
                TVal[2] args; args[0] = arr[(uint)j]; args[1] = key;
                TVal this_val; this_val.set_undefined();
                TVal res = ctx.heap.call_fn(ctx.vm, comparefn, &args[0], 2, this_val);
                if (ctx.heap.has_error) {
                    ctx.should_throw = true;
                    ctx.throw_value = ctx.heap.error_value;
                    ctx.heap.has_error = false;
                    return;
                }
                double rd;
                if (res.is_fastint()) { rd = (double)res.get_fastint(); }
                else if (res.is_number()) { rd = res.get_number(); }
                else {
                    // ToNumber on the comparefn result (may call Symbol.toPrimitive).
                    rd = ta_val_to_number(&res, ctx);
                    if (ctx.should_throw) return;
                }
                cmp = rd < 0.0 ? -1 : (rd > 0.0 ? 1 : 0);
            } else {
                cmp = ta_default_compare(&arr[(uint)j], &key);
            }
            if (cmp <= 0) break;
            arr[(uint)(j + 1)] = arr[(uint)j];
            j--;
        }
        arr[(uint)(j + 1)] = key;
    }
}

/// %TypedArray%.prototype.sort(compareFn?) — §23.2.3.29.
fn void builtin_ta_proto_sort(BuiltinContext* ctx) {
    HObject* obj = ta_validate(ctx);
    if (obj == null) return;
    Heap* heap = ctx.heap;
    hobject::ObjClass cls = obj.flags.obj_class;
    uint shift = ta_elem_shift(cls);
    HObject* buf = (*obj.extra_ptr()).view.buffer;
    uint byte_off = (*obj.extra_ptr()).view.byte_offset;
    uint len = ta_element_count(obj);
    char* base = (*buf.extra_ptr()).ab.data + byte_off;

    bool has_comparefn = false;
    TVal comparefn; comparefn.set_undefined();
    if (ctx.argc >= 1) {
        TVal arg0 = ctx.regs[ctx.base_reg];
        if (!arg0.is_undefined()) {
            if (!arg0.is_object() || arg0.get_heapptr() == null ||
                !((HObject*)arg0.get_heapptr()).is_callable()) {
                arraybuffer_throw_type_error(ctx, "TypedArray.sort: comparefn is not a function or undefined");
                return;
            }
            comparefn = arg0;
            has_comparefn = true;
        }
    }

    if (len <= 1) { (*ctx.result) = ctx.this_val; return; }

    // Copy elements into a scratch TVal array, sort, write back. Element TVals
    // (BigInt kinds already boxed) make the sort element-type agnostic.
    TVal[512] stack_scratch;
    TVal[] scratch;
    TVal* heap_scratch = null;
    if (len <= 512) {
        scratch = stack_scratch[:len];
    } else {
        heap_scratch = (TVal*)heap.alloc_func(heap.heap_udata, (usz)len * TVal::size);
        if (heap_scratch == null) {
            arraybuffer_throw_range_error(ctx, "TypedArray.sort: out of memory");
            return;
        }
        scratch = heap_scratch[:len];
    }

    for (uint i = 0; i < len; i++) {
        scratch[i] = ta_load_element(ctx.heap, base, cls, i);
    }

    ta_insertion_sort(scratch, ctx, comparefn, has_comparefn);

    if (!ctx.should_throw && !ta_is_detached(obj)) {
        // Re-fetch base pointer: comparefn may have realloc'd if buffer grew, but
        // if it's been detached we skip the writeback (data pointer is null/freed).
        // A shrink may have reduced the element count — only write back the
        // elements that still fit in the current view (spec §23.2.3.30: writeback
        // is bounded by the length captured before sorting AND the live length).
        base = (*buf.extra_ptr()).ab.data + byte_off;
        uint writeback = ta_element_count(obj);
        if (writeback > len) writeback = len;
        for (uint i = 0; i < writeback; i++) {
            char* dp = base + (i << shift);
            ta_write_element(dp, cls, &scratch[i], ctx);
            if (ctx.should_throw) break;
        }
    }

    if (heap_scratch != null) heap.free_func(heap.heap_udata, heap_scratch);
    if (ctx.should_throw) { ctx.result.set_undefined(); return; }
    (*ctx.result) = ctx.this_val;
}

/// %TypedArray%.prototype.toSorted(compareFn?) — §23.2.3.32. Returns new sorted TA.
fn void builtin_ta_proto_toSorted(BuiltinContext* ctx) {
    HObject* obj = ta_validate(ctx);
    if (obj == null) return;
    Heap* heap = ctx.heap;
    hobject::ObjClass cls = obj.flags.obj_class;
    uint shift = ta_elem_shift(cls);
    HObject* buf = (*obj.extra_ptr()).view.buffer;
    uint byte_off = (*obj.extra_ptr()).view.byte_offset;
    uint len = ta_element_count(obj);
    char* src = (*buf.extra_ptr()).ab.data + byte_off;
    uint elem_sz = ta_elem_size(cls);

    bool has_comparefn = false;
    TVal comparefn; comparefn.set_undefined();
    if (ctx.argc >= 1) {
        TVal arg0 = ctx.regs[ctx.base_reg];
        if (!arg0.is_undefined()) {
            if (!arg0.is_object() || arg0.get_heapptr() == null ||
                !((HObject*)arg0.get_heapptr()).is_callable()) {
                arraybuffer_throw_type_error(ctx, "TypedArray.toSorted: comparefn is not a function or undefined");
                return;
            }
            comparefn = arg0;
            has_comparefn = true;
        }
    }

    HObject* result = ta_alloc_same_class_from(ctx, obj, len);
    if (result == null) return;

    HObject* res_buf = (*result.extra_ptr()).view.buffer;
    char* dst = (*res_buf.extra_ptr()).ab.data;

    // Copy source bytes into result, then sort result in place.
    if (len > 0) mem::copy(dst, src, (sz)((usz)(len * elem_sz)));

    if (len <= 1) { ctx.result.set_object(result); return; }

    TVal[512] stack_scratch;
    TVal[] scratch;
    TVal* heap_scratch = null;
    if (len <= 512) {
        scratch = stack_scratch[:len];
    } else {
        heap_scratch = (TVal*)heap.alloc_func(heap.heap_udata, (usz)len * TVal::size);
        if (heap_scratch == null) {
            arraybuffer_throw_range_error(ctx, "TypedArray.toSorted: out of memory");
            return;
        }
        scratch = heap_scratch[:len];
    }

    for (uint i = 0; i < len; i++) {
        scratch[i] = ta_load_element(ctx.heap, dst, cls, i);
    }

    ta_insertion_sort(scratch, ctx, comparefn, has_comparefn);

    if (!ctx.should_throw) {
        for (uint i = 0; i < len; i++) {
            char* dp = dst + (i << shift);
            ta_write_element(dp, cls, &scratch[i], ctx);
            if (ctx.should_throw) break;
        }
    }

    if (heap_scratch != null) heap.free_func(heap.heap_udata, heap_scratch);
    if (ctx.should_throw) { ctx.result.set_undefined(); return; }
    ctx.result.set_object(result);
}

/// %TypedArray%.prototype.with(index, value) — §23.2.3.33.
/// Returns a copy with a single element replaced.
fn void builtin_ta_proto_with(BuiltinContext* ctx) {
    HObject* obj = ta_validate(ctx);
    if (obj == null) return;
    Heap* heap = ctx.heap;
    hobject::ObjClass cls = obj.flags.obj_class;
    uint shift = ta_elem_shift(cls);
    uint elem_sz = ta_elem_size(cls);
    HObject* buf = (*obj.extra_ptr()).view.buffer;
    uint byte_off = (*obj.extra_ptr()).view.byte_offset;
    uint len = ta_element_count(obj);
    char* src = (*buf.extra_ptr()).ab.data + byte_off;

    // Get index
    double index_d = 0.0;
    if (ctx.argc > 0) {
        TVal* arg = &ctx.regs[ctx.base_reg];
        index_d = ta_val_to_number(arg, ctx);
        if (ctx.should_throw) return;
    }

    // Convert to integer (toIntegerOrInfinity)
    if (index_d != index_d || index_d == 0.0) {
        index_d = 0.0;
    }
    long actual_index;
    if (index_d >= 9007199254740991.0) {
        actual_index = (long)len;
    } else if (index_d <= -9007199254740991.0) {
        actual_index = -(long)len - 1;
    } else {
        actual_index = (long)index_d;
    }

    // Normalize negative index
    if (actual_index < 0) {
        actual_index = (long)len + actual_index;
    }

    // Coerce the value BEFORE the range check and the copy (§23.2.3.36 steps
    // 6-7: ToNumber/ToBigInt runs first and may execute user code that
    // mutates the source or throws; the RangeError comes after).
    TVal new_val; new_val.set_number(0.0);
    if (ctx.argc > 1) {
        new_val = ctx.regs[ctx.base_reg + 1];
    }
    TAScalar scalar = ta_coerce_element(cls, &new_val, ctx);
    if (ctx.should_throw) return;

    // Spec §23.2.3.35 step 8: validate the index against the CURRENT length
    // (the value coercion above may have resized the buffer via user code).
    // The result length, however, is the length captured BEFORE coercion (step
    // 3 / step 10 both use that `len`), so it is left unchanged here.
    if (actual_index < 0 || !ta_is_valid_integer_index(obj, (double)actual_index)) {
        arraybuffer_throw_range_error(ctx, "Invalid index for with()");
        return;
    }

    // Create new TypedArray
    HObject* result = ta_alloc_same_class_from(ctx, obj, len);
    if (result == null) return;

    HObject* res_buf = (*result.extra_ptr()).view.buffer;
    char* dst = (*res_buf.extra_ptr()).ab.data;

    // Re-derive the source pointer: the value coercion above may have run
    // user code that detached or resized the buffer.
    if (ta_is_detached(obj)) {
        arraybuffer_throw_type_error(ctx, "TypedArray buffer detached during with()");
        return;
    }
    src = (*buf.extra_ptr()).ab.data + byte_off;

    // Copy all elements
    if (len > 0) mem::copy(dst, src, (sz)((usz)(len * elem_sz)));

    // Set the modified element — only when the index falls within the result
    // (whose length is the pre-coercion `len`). If the buffer grew during
    // coercion, a now-valid index beyond `len` simply isn't reflected in the
    // shorter result copy (spec §23.2.3.35: the k-loop runs 0..len).
    if ((uint)actual_index < len) {
        char* dp = dst + ((uint)actual_index << shift);
        ta_store_scalar(dp, cls, &scalar);
    }

    ctx.result.set_object(result);
}

/// %TypedArray%.prototype.toString() — delegates to join with ",".
fn void builtin_ta_proto_toString(BuiltinContext* ctx) {
    // Reuse join with default comma separator (argc=0).
    builtin_ta_proto_join(ctx);
}

/// %TypedArray%.prototype.toLocaleString() — §23.2.3.28.
/// Calls toLocaleString() on each element (as a number object) and joins with
/// the locale-specific separator (defaults to ",").
fn void builtin_ta_proto_toLocaleString(BuiltinContext* ctx) {
    HObject* obj = ta_validate(ctx);
    if (obj == null) return;
    Heap* heap = ctx.heap;
    hobject::ObjClass cls = obj.flags.obj_class;
    uint shift = ta_elem_shift(cls);
    HObject* buf = (*obj.extra_ptr()).view.buffer;
    uint byte_off = (*obj.extra_ptr()).view.byte_offset;
    uint len = ta_element_count(obj);
    char* base = (*buf.extra_ptr()).ab.data + byte_off;

    if (len == 0) {
        HString* empty = (HString*)heap.strs[heap::BuiltinStr.EMPTY];
        if (empty != null) ctx.result.set_string(empty);
        return;
    }

    HString* toloc_key = builtin_intern_string(heap, "toLocaleString");
    HString* tostr_key = builtin_intern_string(heap, "toString");
    HString* sep_hs = null;
    char[] sep = ",";

    // Collect the element strings by invoking toLocaleString on each numeric value.
    HString*[64] stack_strs;
    HString** heap_strs = null;
    HString*[] elem_strs;
    if (len <= 64) {
        elem_strs = stack_strs[:len];
    } else {
        heap_strs = (HString**)heap.alloc_func(heap.heap_udata, HString*::size * len);
        if (heap_strs == null) { ctx.result.set_undefined(); return; }
        elem_strs = heap_strs[:len];
    }

    uint done = 0;
    for (uint i = 0; i < len; i++) {
        // A prior element's toLocaleString may have resized the buffer; re-derive
        // the pointer each read and yield undefined for now-out-of-bounds indices
        // (spec §23.2.3.30 reads via Get over the original length).
        TVal num_val = ta_read_element_checked(ctx.heap, obj, i);

        // Out-of-bounds index: element is undefined. Per spec the empty string is
        // used and toLocaleString is NOT invoked on it.
        if (num_val.is_undefined()) {
            HString* empty = (HString*)heap.strs[heap::BuiltinStr.EMPTY];
            ((types::HeapHeader*)empty).incref();
            elem_strs[done] = empty;
            done++;
            continue;
        }

        // Invoke toLocaleString on the numeric value — wrap it in a Number object,
        // look up toLocaleString on the Number prototype, and call it with num_val as this.
        TVal invoked; invoked.set_undefined();
        if (heap.call_fn != null && ctx.vm != null && toloc_key != null) {
            // Look up toLocaleString on the element's own prototype — BigInt
            // elements use BigInt.prototype, all others use Number.prototype.
            HObject* elem_proto = num_val.is_bigint() ? heap.bigint_proto : heap.number_proto;
            TVal? meth_opt;
            if (elem_proto != null) {
                meth_opt = builtins_generic_get(elem_proto, toloc_key, ctx);
            }
            if (ctx.should_throw) {
                for (uint j = 0; j < done; j++) heap.decref((types::HeapHeader*)elem_strs[j]);
                if (heap_strs != null) heap.free_func(heap.heap_udata, heap_strs);
                ctx.result.set_undefined();
                return;
            }
            if (try meth = meth_opt) {
                if (meth.is_object() && meth.get_heapptr() != null &&
                    ((HObject*)meth.get_heapptr()).is_callable()) {
                    invoked = heap.call_fn(ctx.vm, meth, null, 0, num_val);
                    if (heap.has_error) {
                        ctx.should_throw = true;
                        ctx.throw_value = heap.error_value;
                        heap.has_error = false;
                        for (uint j = 0; j < done; j++) heap.decref((types::HeapHeader*)elem_strs[j]);
                        if (heap_strs != null) heap.free_func(heap.heap_udata, heap_strs);
                        ctx.result.set_undefined();
                        return;
                    }
                }
            }
        }

        // ToString(invoked) — may call invoked.toString() if invoked is an object.
        HString* es = null;
        if (invoked.is_object() && invoked.get_heapptr() != null) {
            HObject* inv_obj = (HObject*)invoked.get_heapptr();
            // Try toString first, then valueOf per ToStrng -> ToPrimitive -> hint String.
            if (heap.call_fn != null && ctx.vm != null && tostr_key != null) {
                TVal? ts_opt = builtins_generic_get(inv_obj, tostr_key, ctx);
                if (ctx.should_throw) {
                    for (uint j = 0; j < done; j++) heap.decref((types::HeapHeader*)elem_strs[j]);
                    if (heap_strs != null) heap.free_func(heap.heap_udata, heap_strs);
                    ctx.result.set_undefined();
                    return;
                }
                if (try ts_meth = ts_opt) {
                    if (ts_meth.is_object() && ts_meth.get_heapptr() != null &&
                        ((HObject*)ts_meth.get_heapptr()).is_callable()) {
                        TVal ts_result = heap.call_fn(ctx.vm, ts_meth, null, 0, invoked);
                        if (heap.has_error) {
                            ctx.should_throw = true;
                            ctx.throw_value = heap.error_value;
                            heap.has_error = false;
                            for (uint j = 0; j < done; j++) heap.decref((types::HeapHeader*)elem_strs[j]);
                            if (heap_strs != null) heap.free_func(heap.heap_udata, heap_strs);
                            ctx.result.set_undefined();
                            return;
                        }
                        if (!ts_result.is_object()) {
                            es = builtin_to_string(heap, &ts_result);
                        }
                    }
                }
                // If toString not found or returned object, try valueOf.
                if (es == null) {
                    HString* valueof_key = builtin_intern_string(heap, "valueOf");
                    if (valueof_key != null) {
                        TVal? vo_opt = builtins_generic_get(inv_obj, valueof_key, ctx);
                        if (ctx.should_throw) {
                            for (uint j = 0; j < done; j++) heap.decref((types::HeapHeader*)elem_strs[j]);
                            if (heap_strs != null) heap.free_func(heap.heap_udata, heap_strs);
                            ctx.result.set_undefined();
                            return;
                        }
                        if (try vo_meth = vo_opt) {
                            if (vo_meth.is_object() && vo_meth.get_heapptr() != null &&
                                ((HObject*)vo_meth.get_heapptr()).is_callable()) {
                                TVal vo_result = heap.call_fn(ctx.vm, vo_meth, null, 0, invoked);
                                if (heap.has_error) {
                                    ctx.should_throw = true;
                                    ctx.throw_value = heap.error_value;
                                    heap.has_error = false;
                                    for (uint j = 0; j < done; j++) heap.decref((types::HeapHeader*)elem_strs[j]);
                                    if (heap_strs != null) heap.free_func(heap.heap_udata, heap_strs);
                                    ctx.result.set_undefined();
                                    return;
                                }
                                es = builtin_to_string(heap, &vo_result);
                            }
                        }
                    }
                }
            }
            if (es == null) es = builtin_to_string(heap, &invoked);
        } else {
            es = builtin_to_string(heap, &invoked);
        }
        if (es == null) es = (HString*)heap.strs[heap::BuiltinStr.EMPTY];
        ((types::HeapHeader*)es).incref();
        elem_strs[done] = es;
        done++;
    }

    // Compute the total length of all element strings plus separators.
    usz total_len = 0;
    for (uint i = 0; i < done; i++) total_len += elem_strs[i].blen;
    if (done > 1) total_len += sep.len * (usz)(done - 1);

    char* rbuf = (char*)heap.alloc_func(heap.heap_udata, total_len > 0 ? total_len : 1);
    if (rbuf == null) {
        for (uint i = 0; i < done; i++) heap.decref((types::HeapHeader*)elem_strs[i]);
        if (heap_strs != null) heap.free_func(heap.heap_udata, heap_strs);
        ctx.result.set_undefined();
        return;
    }

    usz off = 0;
    for (uint i = 0; i < done; i++) {
        if (i > 0 && sep.len > 0) {
            mem::copy(&rbuf[off], &sep[0], (sz)(sep.len));
            off += sep.len;
        }
        char[] ed = elem_strs[i].get_data();
        if (ed.len > 0) { mem::copy(&rbuf[off], &ed[0], (sz)(ed.len)); off += ed.len; }
        heap.decref((types::HeapHeader*)elem_strs[i]);
    }
    if (sep_hs != null) heap.decref((types::HeapHeader*)sep_hs);
    if (heap_strs != null) heap.free_func(heap.heap_udata, heap_strs);

    uint hash = heap.hash_string(rbuf[:total_len]);
    HString*? hs_raw = hstring::hstring_alloc(heap, rbuf[:total_len], hash);
    heap.free_func(heap.heap_udata, rbuf);
    if (catch err2 = hs_raw) { ctx.result.set_undefined(); return; }
    HString* result_hs = hs_raw;
    ctx.result.set_string(result_hs);
}

// ---- %TypedArray% intrinsic abstract constructor ----

/// %TypedArray% abstract constructor (§22.2.1) — always throws TypeError.
fn void builtin_typedarray_intrinsic(BuiltinContext* ctx) {
    arraybuffer_throw_type_error(ctx, "Abstract class TypedArray not directly constructable");
}

/// get %TypedArray%[@@species] — §22.2.2.4. Returns `this`.
fn void builtin_ta_species_get(BuiltinContext* ctx) {
    *ctx.result = ctx.this_val;
}

// ---- Static: %TypedArray%.of / %TypedArray%.from ----
// Installed on the %TypedArray% intrinsic; inherited by all 9 per-class ctors.

/// Resolve the ObjClass from a TypedArray per-class constructor (this_val).
/// Returns INT8ARRAY as default if this_val is not a recognisable TA ctor.
fn hobject::ObjClass ta_ctor_class(BuiltinContext* ctx) {
    if (!ctx.this_val.is_object() || ctx.this_val.get_heapptr() == null) {
        return hobject::ObjClass.INT8ARRAY;
    }
    HObject* ctor_obj = (HObject*)ctx.this_val.get_heapptr();
    // Look up the constructor's .prototype and infer class from its first TA instance.
    // Simpler: map via .name property on the constructor.
    HString* name_key = builtin_intern_string(ctx.heap, "name");
    if (name_key == null) return hobject::ObjClass.INT8ARRAY;
    TVal? name_tv = ctor_obj.get_prop(name_key);
    if (catch e = name_tv) return hobject::ObjClass.INT8ARRAY;
    TVal nv = name_tv;
    if (!nv.is_string() || nv.get_heapptr() == null) return hobject::ObjClass.INT8ARRAY;
    HString* name_hs = (HString*)nv.get_heapptr();
    char[] nm = name_hs.get_data();
    if (nm.len >= 5 && nm[0] == 'I' && nm[1] == 'n' && nm[2] == 't' && nm[3] == '8') return hobject::ObjClass.INT8ARRAY;
    if (nm.len >= 6 && nm[0] == 'U' && nm[1] == 'i' && nm[2] == 'n' && nm[3] == 't' && nm[4] == '8' && nm.len > 5 && nm[5] == 'C') return hobject::ObjClass.UINT8CLAMPEDARRAY;
    if (nm.len >= 6 && nm[0] == 'U' && nm[1] == 'i' && nm[2] == 'n' && nm[3] == 't' && nm[4] == '8') return hobject::ObjClass.UINT8ARRAY;
    if (nm.len >= 6 && nm[0] == 'I' && nm[1] == 'n' && nm[2] == 't' && nm[3] == '1' && nm[4] == '6') return hobject::ObjClass.INT16ARRAY;
    if (nm.len >= 7 && nm[0] == 'U' && nm[1] == 'i' && nm[2] == 'n' && nm[3] == 't' && nm[4] == '1' && nm[5] == '6') return hobject::ObjClass.UINT16ARRAY;
    if (nm.len >= 6 && nm[0] == 'I' && nm[1] == 'n' && nm[2] == 't' && nm[3] == '3' && nm[4] == '2') return hobject::ObjClass.INT32ARRAY;
    if (nm.len >= 7 && nm[0] == 'U' && nm[1] == 'i' && nm[2] == 'n' && nm[3] == 't' && nm[4] == '3' && nm[5] == '2') return hobject::ObjClass.UINT32ARRAY;
    if (nm.len >= 7 && nm[0] == 'F' && nm[1] == 'l' && nm[2] == 'o' && nm[3] == 'a' && nm[4] == 't' && nm[5] == '3' && nm[6] == '2') return hobject::ObjClass.FLOAT32ARRAY;
    if (nm.len >= 7 && nm[0] == 'F' && nm[1] == 'l' && nm[2] == 'o' && nm[3] == 'a' && nm[4] == 't' && nm[5] == '6' && nm[6] == '4') return hobject::ObjClass.FLOAT64ARRAY;
    return hobject::ObjClass.INT8ARRAY;
}

/// Helper: call `construct_fn(C, args, nargs)` and validate result is a TypedArray.
/// Sets ctx.should_throw on failure and returns null. On success returns the HObject*.
fn HObject* ta_typed_array_create(BuiltinContext* ctx, TVal* args, uint nargs) {
    Heap* heap = ctx.heap;
    if (heap.construct_fn == null || ctx.vm == null) {
        arraybuffer_throw_type_error(ctx, "TypedArrayCreate: no constructor available");
        return null;
    }
    // Copy the constructor TVal and vm pointer to locals before the call so the
    // compiler cannot optimise away the memory read across the construct_fn
    // invocation. Without this, O2 single-module inlining may cache ctx.this_val
    // in a register that gets clobbered by the callee.
    TVal ctor_val = ctx.this_val;
    void* vm_ptr  = ctx.vm;
    TVal result_tv = heap.construct_fn(vm_ptr, ctor_val, args, nargs, ctor_val);
    if (heap.has_error) {
        ctx.should_throw = true;
        ctx.throw_value = heap.error_value;
        heap.has_error = false;
        return null;
    }
    if (!result_tv.is_object() || result_tv.get_heapptr() == null) {
        arraybuffer_throw_type_error(ctx, "TypedArrayCreate: constructor did not return an object");
        return null;
    }
    HObject* result_obj = (HObject*)result_tv.get_heapptr();
    if (!is_typed_array_class(result_obj.flags.obj_class)) {
        arraybuffer_throw_type_error(ctx, "TypedArrayCreate: constructor did not return a TypedArray");
        return null;
    }
    // ES2022 §23.2.4.3 TypedArrayCreate step 4: when argumentList is
    // «length», validate the result's [[ArrayLength]] is at least the
    // requested length (a custom constructor may have ignored/shrunk it).
    if (nargs == 1 && (args[0].is_fastint() || args[0].is_number())) {
        double want = args[0].is_fastint() ? (double)args[0].get_fastint() : args[0].get_number();
        if ((double)ta_element_count(result_obj) < want) {
            arraybuffer_throw_type_error(ctx, "TypedArrayCreate: derived constructor created a TypedArray shorter than requested");
            return null;
        }
    }
    return result_obj;
}

/// Helper: check that ctx.this_val is a constructor; throw TypeError if not.
fn bool ta_require_constructor(BuiltinContext* ctx) {
    if (!ctx.this_val.is_object() || ctx.this_val.get_heapptr() == null ||
        !((HObject*)ctx.this_val.get_heapptr()).is_constructable()) {
        arraybuffer_throw_type_error(ctx, "TypedArray method requires a constructor as this value");
        return false;
    }
    return true;
}

/// %TypedArray%.of(...items) — §23.2.2.2.
/// Installed on %TypedArray% intrinsic; inherited by all 9 per-class ctors.
fn void builtin_ta_of(BuiltinContext* ctx) {
    Heap* heap = ctx.heap;

    // Step 3-4: C = this; if not a constructor, throw TypeError.
    if (!ta_require_constructor(ctx)) return;

    uint items_count = (uint)ctx.argc;

    // Step 5: targetObj = TypedArrayCreate(C, «len»).
    TVal len_arg; len_arg.set_fastint((long)items_count);
    HObject* result = ta_typed_array_create(ctx, &len_arg, 1);
    if (result == null) return;

    HObject* res_buf = (*result.extra_ptr()).view.buffer;
    hobject::ObjClass cls = result.flags.obj_class;
    uint shift = ta_elem_shift(cls);
    char* res_base = items_count > 0 ? (*res_buf.extra_ptr()).ab.data : null;

    for (uint i = 0; i < items_count; i++) {
        TVal item = ctx.regs[ctx.base_reg + (int)i];
        if (res_base != null && !ta_is_detached(result)) {
            char* dp = res_base + (i << shift);
            ta_write_element(dp, cls, &item, ctx);
        }
        if (ctx.should_throw) { ctx.result.set_undefined(); return; }
    }
    ctx.result.set_object(result);
}

/// %TypedArray%.from(source, mapFn?, thisArg?) — §23.2.2.1.
/// Installed on %TypedArray% intrinsic; inherited by all 9 per-class ctors.
fn void builtin_ta_from(BuiltinContext* ctx) @noinline {
    Heap* heap = ctx.heap;

    // Step 1-2: C = this; throw TypeError if not a constructor.
    if (!ta_require_constructor(ctx)) return;

    TVal source; source.set_undefined();
    if (ctx.argc >= 1) source = ctx.regs[ctx.base_reg];

    // Step 3-4: Validate mapFn before touching the source iterator.
    bool has_mapfn = false;
    TVal mapfn; mapfn.set_undefined();
    TVal map_this; map_this.set_undefined();
    if (ctx.argc >= 2) {
        mapfn = ctx.regs[ctx.base_reg + 1];
        if (!mapfn.is_undefined()) {
            // Spec step 3: if mapfn is not undefined, IsCallable must be true.
            bool mapfn_callable = mapfn.is_lightfunc() ||
                (mapfn.is_object() && mapfn.get_heapptr() != null &&
                 ((HObject*)mapfn.get_heapptr()).is_callable());
            if (!mapfn_callable) {
                arraybuffer_throw_type_error(ctx, "TypedArray.from: mapFn is not a function");
                return;
            }
            has_mapfn = true;
        }
    }
    if (ctx.argc >= 3) map_this = ctx.regs[ctx.base_reg + 2];

    // Step 5: usingIterator = GetMethod(source, @@iterator).
    HString* iter_sym = ensure_iterator_symbol(heap);
    TVal iter_method; iter_method.set_undefined();
    bool have_iter_method = false;

    if (iter_sym != null && !source.is_undefined() && !source.is_null()) {
        HObject* src_for_iter = null;
        if (source.is_object() && source.get_heapptr() != null) {
            src_for_iter = (HObject*)source.get_heapptr();
        }
        if (src_for_iter != null) {
            TVal? im = builtins_generic_get(src_for_iter, iter_sym, ctx);
            if (ctx.should_throw) { ctx.result.set_undefined(); return; }
            if (try imv = im) {
                if (!imv.is_undefined() && !imv.is_null()) {
                    iter_method = imv;
                    have_iter_method = true;
                }
            }
        }
    }

    if (have_iter_method) {
        // === Iterator path — spec steps 6-9 ===
        // Validate iterator method is callable.
        bool im_callable = iter_method.is_lightfunc() ||
            (iter_method.is_object() && iter_method.get_heapptr() != null &&
             ((HObject*)iter_method.get_heapptr()).is_callable());
        if (!im_callable || heap.call_fn == null || ctx.vm == null) {
            arraybuffer_throw_type_error(ctx, "TypedArray.from: @@iterator is not callable");
            ctx.result.set_undefined();
            return;
        }

        // Step 6a: Invoke @@iterator to get iterator object.
        TVal iterator = heap.call_fn(ctx.vm, iter_method, null, 0, source);
        if (heap.has_error) {
            ctx.should_throw = true;
            ctx.throw_value = heap.error_value;
            heap.has_error = false;
            ctx.result.set_undefined();
            return;
        }
        if (!iterator.is_object() || iterator.get_heapptr() == null) {
            arraybuffer_throw_type_error(ctx, "TypedArray.from: @@iterator did not return an object");
            ctx.result.set_undefined();
            return;
        }
        // Protect the iterator from GC: C-local TVal values are not GC roots.
        // GC triggered from inside alloc (non-safepoint) preserves temproot objects
        // across all sweep cycles, so set_temproot keeps the iterator alive for the
        // duration of this builtin.
        types::HeapHeader* iter_hdr = (types::HeapHeader*)iterator.get_heapptr();
        iter_hdr.set_temproot();

        // Collect all values from the iterator into a temporary list (IteratorToList).
        HString* next_key  = builtin_intern_string(heap, "next");
        HString* done_key  = builtin_intern_string(heap, "done");
        HString* value_key = builtin_intern_string(heap, "value");

        uint cap = 8;
        TVal* items = (TVal*)heap.alloc_func(heap.heap_udata, (usz)cap * TVal::size);
        if (items == null) { ctx.result.set_undefined(); return; }
        uint count = 0;

        while (true) {
            HObject* iter_obj = (HObject*)iterator.get_heapptr();

            TVal? next_method_opt = builtins_generic_get(iter_obj, next_key, ctx);
            if (ctx.should_throw) {
                heap.free_func(heap.heap_udata, items);
                ctx.result.set_undefined();
                return;
            }
            TVal next_method;
            if (try nm = next_method_opt) { next_method = nm; }
            else {
                heap.free_func(heap.heap_udata, items);
                arraybuffer_throw_type_error(ctx, "TypedArray.from: iterator has no next method");
                return;
            }
            bool nm_callable = next_method.is_lightfunc() ||
                (next_method.is_object() && next_method.get_heapptr() != null &&
                 ((HObject*)next_method.get_heapptr()).is_callable());
            if (!nm_callable) {
                heap.free_func(heap.heap_udata, items);
                arraybuffer_throw_type_error(ctx, "TypedArray.from: iterator.next is not callable");
                return;
            }

            TVal step_result = heap.call_fn(ctx.vm, next_method, null, 0, iterator);
            if (heap.has_error) {
                ctx.should_throw = true;
                ctx.throw_value = heap.error_value;
                heap.has_error = false;
                heap.free_func(heap.heap_udata, items);
                ctx.result.set_undefined();
                return;
            }
            if (!step_result.is_object() || step_result.get_heapptr() == null) {
                heap.free_func(heap.heap_udata, items);
                arraybuffer_throw_type_error(ctx, "TypedArray.from: iterator result is not an object");
                return;
            }
            HObject* result_obj = (HObject*)step_result.get_heapptr();

            TVal? done_opt = builtins_generic_get(result_obj, done_key, ctx);
            if (ctx.should_throw) {
                heap.free_func(heap.heap_udata, items);
                ctx.result.set_undefined();
                return;
            }
            bool done = false;
            if (try dv = done_opt) done = builtin_to_boolean(&dv);
            if (done) break;

            TVal? value_opt = builtins_generic_get(result_obj, value_key, ctx);
            if (ctx.should_throw) {
                heap.free_func(heap.heap_udata, items);
                ctx.result.set_undefined();
                return;
            }
            TVal next_value; next_value.set_undefined();
            if (try vv = value_opt) next_value = vv;

            if (count == cap) {
                uint new_cap = cap * 2;
                TVal* new_items = (TVal*)heap.alloc_func(heap.heap_udata, (usz)new_cap * TVal::size);
                if (new_items == null) {
                    heap.free_func(heap.heap_udata, items);
                    ctx.result.set_undefined();
                    return;
                }
                mem::copy(new_items, items, (sz)((usz)count * TVal::size));
                heap.free_func(heap.heap_udata, items);
                items = new_items;
                cap = new_cap;
            }
            items[count] = next_value;
            count++;
        }

        // Step 7: TypedArrayCreate(C, «count»).
        TVal len_arg; len_arg.set_fastint((long)count);
        HObject* target_obj = ta_typed_array_create(ctx, &len_arg, 1);
        if (target_obj == null) {
            heap.free_func(heap.heap_udata, items);
            return;
        }

        // Step 8: Write each collected value (with optional mapping).
        hobject::ObjClass res_cls = target_obj.flags.obj_class;
        uint res_shift = ta_elem_shift(res_cls);

        for (uint k = 0; k < count; k++) {
            TVal kvalue = items[k];
            TVal mapped = kvalue;
            if (has_mapfn && heap.call_fn != null && ctx.vm != null) {
                TVal[2] map_args;
                map_args[0] = kvalue;
                TVal k_tv; k_tv.set_fastint((long)k);
                map_args[1] = k_tv;
                mapped = heap.call_fn(ctx.vm, mapfn, &map_args[0], 2, map_this);
                if (heap.has_error) {
                    ctx.should_throw = true;
                    ctx.throw_value = heap.error_value;
                    heap.has_error = false;
                    heap.free_func(heap.heap_udata, items);
                    ctx.result.set_undefined();
                    return;
                }
            }

            // Write element only if not detached (mapper may have detached the buffer).
            if (!ta_is_detached(target_obj)) {
                HObject* res_buf2 = (*target_obj.extra_ptr()).view.buffer;
                char* res_base2 = (*res_buf2.extra_ptr()).ab.data + (*target_obj.extra_ptr()).view.byte_offset;
                char* dp = res_base2 + (k << res_shift);
                ta_write_element(dp, res_cls, &mapped, ctx);
                if (ctx.should_throw) {
                    heap.free_func(heap.heap_udata, items);
                    ctx.result.set_undefined();
                    return;
                }
            }
        }

        heap.free_func(heap.heap_udata, items);
        ctx.result.set_object(target_obj);
        return;
    }

    // === Array-like path — spec steps 10-17 ===
    HObject* src_obj = null;
    if (source.is_object() && source.get_heapptr() != null) {
        src_obj = (HObject*)source.get_heapptr();
    } else if (source.is_undefined() || source.is_null()) {
        arraybuffer_throw_type_error(ctx, "TypedArray.from: source is null or undefined");
        return;
    }

    // Get length from source.length.
    uint src_len = 0;
    if (src_obj != null) {
        HString* length_key = (HString*)heap.strs[heap::BuiltinStr.LENGTH];
        TVal? lv = builtins_generic_get(src_obj, length_key, ctx);
        if (ctx.should_throw) return;
        if (try ltv = lv) {
            double ld = ta_val_to_number(&ltv, ctx);
            if (ctx.should_throw) return;
            if (ld > 0.0 && ld < 4294967296.0) src_len = (uint)(long)ld;
        }
    }

    // TypedArrayCreate(C, «len»).
    TVal len_arg2; len_arg2.set_fastint((long)src_len);
    HObject* target_obj2 = ta_typed_array_create(ctx, &len_arg2, 1);
    if (target_obj2 == null) return;

    hobject::ObjClass res_cls2 = target_obj2.flags.obj_class;
    uint res_shift2 = ta_elem_shift(res_cls2);

    for (uint i = 0; i < src_len; i++) {
        TVal elem; elem.set_undefined();
        if (src_obj != null) {
            HString* idx_key = heap.int_to_hstring((long)i);
            if (idx_key != null) {
                TVal? ev = builtins_generic_get(src_obj, idx_key, ctx);
                if (ctx.should_throw) { ctx.result.set_undefined(); return; }
                if (try etv = ev) elem = etv;
            }
        }

        TVal final_elem = elem;
        if (has_mapfn && heap.call_fn != null && ctx.vm != null) {
            TVal[2] args2; args2[0] = elem;
            TVal k_tv2; k_tv2.set_fastint((long)i);
            args2[1] = k_tv2;
            final_elem = heap.call_fn(ctx.vm, mapfn, &args2[0], 2, map_this);
            if (heap.has_error) {
                ctx.should_throw = true;
                ctx.throw_value = heap.error_value;
                heap.has_error = false;
                ctx.result.set_undefined();
                return;
            }
        }

        // Write element only if buffer is not detached (mapper may detach).
        if (!ta_is_detached(target_obj2)) {
            HObject* res_buf3 = (*target_obj2.extra_ptr()).view.buffer;
            char* res_base3 = (*res_buf3.extra_ptr()).ab.data + (*target_obj2.extra_ptr()).view.byte_offset;
            char* dp2 = res_base3 + (i << res_shift2);
            ta_write_element(dp2, res_cls2, &final_elem, ctx);
            if (ctx.should_throw) { ctx.result.set_undefined(); return; }
        }
    }
    ctx.result.set_object(target_obj2);
}

// ============================================================================
// Uint8Array base64/hex (tc39 proposal-arraybuffer-base64)
// ============================================================================

const char B64_ALPHABET_BASE64 = 0;
const char B64_ALPHABET_BASE64URL = 1;

const char B64_LAST_LOOSE = 0;
const char B64_LAST_STRICT = 1;
const char B64_LAST_STOP_BEFORE_PARTIAL = 2;

const char B64_K_WS = 64; // ASCII whitespace sentinel in decode tables
const char B64_K_ER = 65; // illegal-character sentinel in decode tables

const char[64] B64_ENC = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
const char[64] B64URL_ENC = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
const char[16] HEX_DIGITS = "0123456789abcdef";

/// Map a Unicode codepoint to its base64 sextet value, or B64_K_WS for ASCII
/// whitespace, or B64_K_ER for any illegal character. Only ASCII codepoints
/// can be valid; any codepoint >= 128 is illegal (multi-byte input chars).
fn char b64_decode_char(uint cp, char alphabet) {
    if (cp >= 128) return B64_K_ER;
    // ECMAScript "ASCII whitespace": tab, LF, FF, CR, space.
    if (cp == 0x09 || cp == 0x0A || cp == 0x0C || cp == 0x0D || cp == 0x20) return B64_K_WS;
    if (cp >= 'A' && cp <= 'Z') return (char)(cp - 'A');
    if (cp >= 'a' && cp <= 'z') return (char)(cp - 'a' + 26);
    if (cp >= '0' && cp <= '9') return (char)(cp - '0' + 52);
    if (alphabet == B64_ALPHABET_BASE64URL) {
        if (cp == '-') return 62;
        if (cp == '_') return 63;
    } else {
        if (cp == '+') return 62;
        if (cp == '/') return 63;
    }
    return B64_K_ER;
}

/// hex nibble value for an ASCII codepoint, or -1 if not a hex digit.
fn int hex_decode_char(uint cp) {
    if (cp >= '0' && cp <= '9') return (int)(cp - '0');
    if (cp >= 'a' && cp <= 'f') return (int)(cp - 'a' + 10);
    if (cp >= 'A' && cp <= 'F') return (int)(cp - 'A' + 10);
    return -1;
}

/// Result of a base64/hex decode: bytes written to dst, chars read from src,
/// and whether an error occurred.
struct B64DecodeResult {
    uint read;
    uint written;
    bool err;
}

/// FromBase64 abstract operation (proposal-arraybuffer-base64). Decodes the
/// codepoint-indexed string `src` (length `src_len` in codepoints — equal to
/// UTF-16 units for the ASCII prefix that any valid input consists of) into
/// `dst` (capacity `max_len`). Faithful port of quickjs's from_base64.
fn B64DecodeResult from_base64(HString* src, uint src_len, char* dst, uint max_len,
                               char alphabet, char last_chunk) {
    B64DecodeResult r;
    r.read = 0; r.written = 0; r.err = false;

    uint read = 0;
    uint written = 0;
    uint acc = 0;
    int seen = 0;
    uint index = 0;

    if (max_len == 0) { r.read = 0; r.written = 0; return r; }

    for (;;) {
        if (seen == 0) {
            // Fast path: decode complete groups of 4 valid characters.
            while (index + 4 <= src_len && written + 3 <= max_len) {
                char v0 = b64_decode_char(src.char_at(index), alphabet);
                char v1 = b64_decode_char(src.char_at(index + 1), alphabet);
                char v2 = b64_decode_char(src.char_at(index + 2), alphabet);
                char v3 = b64_decode_char(src.char_at(index + 3), alphabet);
                if ((v0 | v1 | v2 | v3) >= 64) break;
                uint v = ((uint)v0 << 18) | ((uint)v1 << 12) | ((uint)v2 << 6) | (uint)v3;
                dst[written]     = (char)(v >> 16);
                dst[written + 1] = (char)(v >> 8);
                dst[written + 2] = (char)v;
                written += 3;
                index += 4;
            }
            read = index;
            if (written >= max_len) { r.read = read; r.written = written; return r; }
        }

        // Slow path: whitespace, padding, partial groups, capacity.
        while (index < src_len && b64_decode_char(src.char_at(index), alphabet) == B64_K_WS) index++;

        if (index == src_len) {
            if (seen > 0) {
                if (last_chunk == B64_LAST_STOP_BEFORE_PARTIAL) { r.read = read; r.written = written; return r; }
                if (last_chunk == B64_LAST_STRICT) { r.err = true; return r; }
                // loose
                if (seen == 1) { r.err = true; return r; }
                break;
            }
            r.read = src_len; r.written = written; return r;
        }

        uint ch = src.char_at(index++);

        if (ch == '=') {
            if (seen < 2) { r.err = true; return r; }
            while (index < src_len && b64_decode_char(src.char_at(index), alphabet) == B64_K_WS) index++;
            if (seen == 2) {
                if (index == src_len) {
                    if (last_chunk == B64_LAST_STOP_BEFORE_PARTIAL) { r.read = read; r.written = written; return r; }
                    r.err = true; return r;
                }
                if (src.char_at(index) == '=') {
                    index++;
                    while (index < src_len && b64_decode_char(src.char_at(index), alphabet) == B64_K_WS) index++;
                } else {
                    r.err = true; return r;
                }
            }
            // After padding, only whitespace is allowed.
            if (index != src_len) { r.err = true; return r; }
            if (last_chunk == B64_LAST_STRICT) {
                uint mask = (seen == 2) ? 0xF : 0x3;
                if (acc & mask) { r.err = true; return r; }
            }
            break;
        }

        char v = b64_decode_char(ch, alphabet);
        if (v >= 64) { r.err = true; return r; }

        // Check remaining capacity before committing to this group.
        uint remaining = max_len - written;
        if ((remaining == 1 && seen == 2) || (remaining == 2 && seen == 3)) {
            r.read = read; r.written = written; return r;
        }

        acc = (acc << 6) | (uint)v;
        seen++;

        if (seen == 4) {
            dst[written]     = (char)(acc >> 16);
            dst[written + 1] = (char)(acc >> 8);
            dst[written + 2] = (char)acc;
            written += 3;
            acc = 0;
            seen = 0;
            read = index;
            if (written >= max_len) { r.read = read; r.written = written; return r; }
        }
    }

    if (seen == 2) {
        dst[written++] = (char)(acc >> 4);
    } else if (seen == 3) {
        dst[written]     = (char)(acc >> 10);
        dst[written + 1] = (char)(acc >> 2);
        written += 2;
    }
    r.read = src_len; r.written = written; return r;
}

/// FromHex abstract operation. Decodes hex pairs from `src` into `dst`
/// (capacity `max_len`), writing bytes up to the first error. Odd total
/// length is an error (with no bytes written for the trailing odd char).
fn B64DecodeResult from_hex(HString* src, uint src_len, char* dst, uint max_len) {
    B64DecodeResult r;
    r.read = 0; r.written = 0; r.err = false;

    if ((src_len & 1) != 0) { r.err = true; return r; }

    uint written = 0;
    uint i = 0;
    while (i < src_len && written < max_len) {
        int hi = hex_decode_char(src.char_at(i));
        int lo = hex_decode_char(src.char_at(i + 1));
        if (hi < 0 || lo < 0) { r.err = true; return r; }
        dst[written++] = (char)((hi << 4) | lo);
        i += 2;
    }
    r.read = i; r.written = written;
    return r;
}

/// GetOptionsObject (proposal): undefined -> null (treat as empty), object ->
/// itself, otherwise throw TypeError. Returns the options object (or null for
/// undefined). Sets should_throw on error.
fn HObject* b64_get_options_object(BuiltinContext* ctx, TVal opt) {
    if (opt.is_undefined()) return null;
    if (opt.is_object() && opt.get_heapptr() != null) return (HObject*)opt.get_heapptr();
    arraybuffer_throw_type_error(ctx, "options must be an object or undefined");
    return null;
}

/// Read the "alphabet" option (default "base64"). Sets should_throw on error;
/// returns 0xFF sentinel then. Only genuine string primitives are accepted.
fn char b64_get_alphabet_option(BuiltinContext* ctx, HObject* opts) {
    if (opts == null) return B64_ALPHABET_BASE64;
    HString* key = builtin_intern_string(ctx.heap, "alphabet");
    TVal? v = builtins_generic_get(opts, key, ctx);
    if (ctx.should_throw) return 0xFF;
    TVal val;
    if (try tv = v) { val = tv; } else { ctx.should_throw = true; return 0xFF; }
    if (val.is_undefined()) return B64_ALPHABET_BASE64;
    if (!val.is_string() || ((HString*)val.get_heapptr()).is_symbol()) {
        arraybuffer_throw_type_error(ctx, "alphabet must be a string");
        return 0xFF;
    }
    HString* s = (HString*)val.get_heapptr();
    if (s.equals("base64")) return B64_ALPHABET_BASE64;
    if (s.equals("base64url")) return B64_ALPHABET_BASE64URL;
    arraybuffer_throw_type_error(ctx, "invalid alphabet");
    return 0xFF;
}

/// Read the "lastChunkHandling" option (default "loose"). Sets should_throw on
/// error; returns 0xFF sentinel then.
fn char b64_get_last_chunk_option(BuiltinContext* ctx, HObject* opts) {
    if (opts == null) return B64_LAST_LOOSE;
    HString* key = builtin_intern_string(ctx.heap, "lastChunkHandling");
    TVal? v = builtins_generic_get(opts, key, ctx);
    if (ctx.should_throw) return 0xFF;
    TVal val;
    if (try tv = v) { val = tv; } else { ctx.should_throw = true; return 0xFF; }
    if (val.is_undefined()) return B64_LAST_LOOSE;
    if (!val.is_string() || ((HString*)val.get_heapptr()).is_symbol()) {
        arraybuffer_throw_type_error(ctx, "lastChunkHandling must be a string");
        return 0xFF;
    }
    HString* s = (HString*)val.get_heapptr();
    if (s.equals("loose")) return B64_LAST_LOOSE;
    if (s.equals("strict")) return B64_LAST_STRICT;
    if (s.equals("stop-before-partial")) return B64_LAST_STOP_BEFORE_PARTIAL;
    arraybuffer_throw_type_error(ctx, "invalid lastChunkHandling");
    return 0xFF;
}

/// ValidateUint8Array: receiver must be a (possibly detached) Uint8Array.
/// Returns the object, or null + TypeError.
fn HObject* b64_validate_uint8array(BuiltinContext* ctx) {
    if (!ctx.this_val.is_object() || ctx.this_val.get_heapptr() == null) {
        arraybuffer_throw_type_error(ctx, "receiver is not a Uint8Array");
        return null;
    }
    HObject* obj = (HObject*)ctx.this_val.get_heapptr();
    if (obj.flags.obj_class != hobject::ObjClass.UINT8ARRAY) {
        arraybuffer_throw_type_error(ctx, "receiver is not a Uint8Array");
        return null;
    }
    return obj;
}

/// Read the string argument, requiring a genuine String primitive (no
/// coercion). Sets should_throw + returns null on non-string.
fn HString* b64_require_string_arg(BuiltinContext* ctx) {
    TVal arg;
    if (ctx.argc >= 1) { arg = ctx.regs[ctx.base_reg]; } else { arg.set_undefined(); }
    if (!arg.is_string() || ((HString*)arg.get_heapptr()).is_symbol()) {
        arraybuffer_throw_type_error(ctx, "argument must be a string");
        return null;
    }
    return (HString*)arg.get_heapptr();
}

/// Allocate a fresh Uint8Array of `length` bytes whose [[Prototype]] is
/// %Uint8Array.prototype% (used by fromBase64/fromHex — receiver is ignored).
fn HObject* b64_alloc_uint8array(BuiltinContext* ctx, uint length) {
    HObject* result = ta_alloc_same_class(ctx, hobject::ObjClass.UINT8ARRAY, length);
    if (result != null && ctx.heap.uint8array_proto != null) {
        result.prototype = ctx.heap.uint8array_proto;
    }
    return result;
}

/// Build a { read, written } result object with C_W_E data properties.
fn void b64_make_read_written(BuiltinContext* ctx, uint read, uint written) {
    HObject*? raw = ctx.heap.alloc_object(hobject::ObjClass.OBJECT);
    if (catch err = raw) { arraybuffer_throw_range_error(ctx, "out of memory"); return; }
    HObject* obj = raw;
    obj.prototype = ctx.heap.object_proto;
    HString* read_key = builtin_intern_string(ctx.heap, "read");
    HString* written_key = builtin_intern_string(ctx.heap, "written");
    TVal read_tv; read_tv.set_fastint((long)read);
    TVal written_tv; written_tv.set_fastint((long)written);
    obj.put_prop(read_key, read_tv, hobject::PROP_FLAGS_WEC);
    obj.put_prop(written_key, written_tv, hobject::PROP_FLAGS_WEC);
    ctx.result.set_object(obj);
}

/// Uint8Array.fromBase64(string [, options]) — receiver ignored.
fn void builtin_uint8array_from_base64(BuiltinContext* ctx) {
    HString* str = b64_require_string_arg(ctx);
    if (str == null) return;
    TVal opt; if (ctx.argc >= 2) { opt = ctx.regs[ctx.base_reg + 1]; } else { opt.set_undefined(); }
    HObject* opts = b64_get_options_object(ctx, opt);
    if (ctx.should_throw) return;
    char alphabet = b64_get_alphabet_option(ctx, opts);
    if (ctx.should_throw) return;
    char last_chunk = b64_get_last_chunk_option(ctx, opts);
    if (ctx.should_throw) return;

    uint str_len = str.char_length();
    uint out_cap = (str_len / 4) * 3 + 3;
    char* buf = (char*)ctx.heap.alloc_func(ctx.heap.heap_udata, (usz)(out_cap == 0 ? 1 : out_cap));
    if (buf == null) { arraybuffer_throw_range_error(ctx, "out of memory"); return; }

    B64DecodeResult res = from_base64(str, str_len, buf, out_cap, alphabet, last_chunk);
    if (res.err) {
        ctx.heap.free_func(ctx.heap.heap_udata, buf);
        builtin_throw(ctx, ctx.heap.syntax_err_proto, "invalid base64 string");
        return;
    }
    HObject* result = b64_alloc_uint8array(ctx, res.written);
    if (result == null) { ctx.heap.free_func(ctx.heap.heap_udata, buf); return; }
    if (res.written > 0) {
        HObject* rbuf = (*result.extra_ptr()).view.buffer;
        char* dst = (*rbuf.extra_ptr()).ab.data + (*result.extra_ptr()).view.byte_offset;
        mem::copy(dst, buf, (sz)((usz)res.written));
    }
    ctx.heap.free_func(ctx.heap.heap_udata, buf);
    ctx.result.set_object(result);
}

/// Uint8Array.fromHex(string) — receiver ignored.
fn void builtin_uint8array_from_hex(BuiltinContext* ctx) {
    HString* str = b64_require_string_arg(ctx);
    if (str == null) return;

    uint str_len = str.char_length();
    uint out_cap = str_len / 2 + 1;
    char* buf = (char*)ctx.heap.alloc_func(ctx.heap.heap_udata, (usz)out_cap);
    if (buf == null) { arraybuffer_throw_range_error(ctx, "out of memory"); return; }

    B64DecodeResult res = from_hex(str, str_len, buf, out_cap);
    if (res.err) {
        ctx.heap.free_func(ctx.heap.heap_udata, buf);
        builtin_throw(ctx, ctx.heap.syntax_err_proto, "invalid hex string");
        return;
    }
    HObject* result = b64_alloc_uint8array(ctx, res.written);
    if (result == null) { ctx.heap.free_func(ctx.heap.heap_udata, buf); return; }
    if (res.written > 0) {
        HObject* rbuf = (*result.extra_ptr()).view.buffer;
        char* dst = (*rbuf.extra_ptr()).ab.data + (*result.extra_ptr()).view.byte_offset;
        mem::copy(dst, buf, (sz)((usz)res.written));
    }
    ctx.heap.free_func(ctx.heap.heap_udata, buf);
    ctx.result.set_object(result);
}

/// Uint8Array.prototype.toBase64([options])
fn void builtin_uint8array_proto_to_base64(BuiltinContext* ctx) {
    HObject* obj = b64_validate_uint8array(ctx);
    if (obj == null) return;

    TVal opt; if (ctx.argc >= 1) { opt = ctx.regs[ctx.base_reg]; } else { opt.set_undefined(); }
    HObject* opts = b64_get_options_object(ctx, opt);
    if (ctx.should_throw) return;
    char alphabet = b64_get_alphabet_option(ctx, opts);
    if (ctx.should_throw) return;
    // omitPadding: ToBoolean (default false).
    bool omit_padding = false;
    if (opts != null) {
        HString* op_key = builtin_intern_string(ctx.heap, "omitPadding");
        TVal? opv = builtins_generic_get(opts, op_key, ctx);
        if (ctx.should_throw) return;
        if (try v = opv) omit_padding = builtin_to_boolean(&v);
    }

    // Re-check detach after option getters (which may detach the buffer).
    if (ta_is_detached(obj)) {
        arraybuffer_throw_type_error(ctx, "Uint8Array buffer is detached");
        return;
    }

    HObject* buf = (*obj.extra_ptr()).view.buffer;
    uint len = (*obj.extra_ptr()).view.byte_length;
    char* data = (*buf.extra_ptr()).ab.data + (*obj.extra_ptr()).view.byte_offset;

    char[64]* alpha = alphabet == B64_ALPHABET_BASE64URL ? &B64URL_ENC : &B64_ENC;
    uint out_len = 4 * ((len + 2) / 3);
    char* out = (char*)ctx.heap.alloc_func(ctx.heap.heap_udata, (usz)(out_len == 0 ? 1 : out_len));
    if (out == null) { arraybuffer_throw_range_error(ctx, "out of memory"); return; }

    uint i = 0;
    uint j = 0;
    while (i + 3 <= len) {
        uint v = ((uint)(char)data[i] << 16) | ((uint)(char)data[i + 1] << 8) | (uint)(char)data[i + 2];
        out[j]     = (*alpha)[(v >> 18) & 63];
        out[j + 1] = (*alpha)[(v >> 12) & 63];
        out[j + 2] = (*alpha)[(v >> 6) & 63];
        out[j + 3] = (*alpha)[v & 63];
        i += 3; j += 4;
    }
    uint rem = len - i;
    if (rem == 1) {
        uint v = (uint)(char)data[i] << 16;
        out[j++] = (*alpha)[(v >> 18) & 63];
        out[j++] = (*alpha)[(v >> 12) & 63];
        if (!omit_padding) { out[j++] = '='; out[j++] = '='; }
    } else if (rem == 2) {
        uint v = ((uint)(char)data[i] << 16) | ((uint)(char)data[i + 1] << 8);
        out[j++] = (*alpha)[(v >> 18) & 63];
        out[j++] = (*alpha)[(v >> 12) & 63];
        out[j++] = (*alpha)[(v >> 6) & 63];
        if (!omit_padding) { out[j++] = '='; }
    }

    HString* result = ctx.heap.str_intern(out[:j]);
    ctx.heap.free_func(ctx.heap.heap_udata, out);
    if (result == null) { arraybuffer_throw_range_error(ctx, "out of memory"); return; }
    ctx.result.set_string(result);
}

/// Uint8Array.prototype.toHex()
fn void builtin_uint8array_proto_to_hex(BuiltinContext* ctx) {
    HObject* obj = b64_validate_uint8array(ctx);
    if (obj == null) return;
    if (ta_is_detached(obj)) {
        arraybuffer_throw_type_error(ctx, "Uint8Array buffer is detached");
        return;
    }
    HObject* buf = (*obj.extra_ptr()).view.buffer;
    uint len = (*obj.extra_ptr()).view.byte_length;
    char* data = (*buf.extra_ptr()).ab.data + (*obj.extra_ptr()).view.byte_offset;

    uint out_len = len * 2;
    char* out = (char*)ctx.heap.alloc_func(ctx.heap.heap_udata, (usz)(out_len == 0 ? 1 : out_len));
    if (out == null) { arraybuffer_throw_range_error(ctx, "out of memory"); return; }
    for (uint i = 0; i < len; i++) {
        char b = data[i];
        out[i * 2]     = HEX_DIGITS[(b >> 4) & 0xF];
        out[i * 2 + 1] = HEX_DIGITS[b & 0xF];
    }
    HString* result = ctx.heap.str_intern(out[:out_len]);
    ctx.heap.free_func(ctx.heap.heap_udata, out);
    if (result == null) { arraybuffer_throw_range_error(ctx, "out of memory"); return; }
    ctx.result.set_string(result);
}

/// Uint8Array.prototype.setFromBase64(string [, options])
fn void builtin_uint8array_proto_set_from_base64(BuiltinContext* ctx) {
    HObject* obj = b64_validate_uint8array(ctx);
    if (obj == null) return;
    HString* str = b64_require_string_arg(ctx);
    if (str == null) return;
    TVal opt; if (ctx.argc >= 2) { opt = ctx.regs[ctx.base_reg + 1]; } else { opt.set_undefined(); }
    HObject* opts = b64_get_options_object(ctx, opt);
    if (ctx.should_throw) return;
    char alphabet = b64_get_alphabet_option(ctx, opts);
    if (ctx.should_throw) return;
    char last_chunk = b64_get_last_chunk_option(ctx, opts);
    if (ctx.should_throw) return;

    if (ta_is_detached(obj)) {
        arraybuffer_throw_type_error(ctx, "Uint8Array buffer is detached");
        return;
    }
    HObject* buf = (*obj.extra_ptr()).view.buffer;
    uint len = (*obj.extra_ptr()).view.byte_length;
    char* data = (*buf.extra_ptr()).ab.data + (*obj.extra_ptr()).view.byte_offset;

    uint str_len = str.char_length();
    B64DecodeResult res = from_base64(str, str_len, data, len, alphabet, last_chunk);
    if (res.err) {
        builtin_throw(ctx, ctx.heap.syntax_err_proto, "invalid base64 string");
        return;
    }
    b64_make_read_written(ctx, res.read, res.written);
}

/// Uint8Array.prototype.setFromHex(string)
fn void builtin_uint8array_proto_set_from_hex(BuiltinContext* ctx) {
    HObject* obj = b64_validate_uint8array(ctx);
    if (obj == null) return;
    HString* str = b64_require_string_arg(ctx);
    if (str == null) return;

    if (ta_is_detached(obj)) {
        arraybuffer_throw_type_error(ctx, "Uint8Array buffer is detached");
        return;
    }
    HObject* buf = (*obj.extra_ptr()).view.buffer;
    uint len = (*obj.extra_ptr()).view.byte_length;
    char* data = (*buf.extra_ptr()).ab.data + (*obj.extra_ptr()).view.byte_offset;

    uint str_len = str.char_length();
    B64DecodeResult res = from_hex(str, str_len, data, len);
    if (res.err) {
        builtin_throw(ctx, ctx.heap.syntax_err_proto, "invalid hex string");
        return;
    }
    b64_make_read_written(ctx, res.read, res.written);
}

// ============================================================================
// Registration
// ============================================================================

/// Register a %TypedArray%.prototype accessor getter (shared implementation
/// pattern with register_arraybuffer_accessor in arraybuffer.c3).
fn bool register_typedarray_accessor(HObject* proto, Heap* heap, char[] name, uint getter_index) {
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

/// Register a %TypedArray%.prototype Symbol-keyed accessor getter.
fn bool register_typedarray_symbol_accessor(HObject* proto, Heap* heap, HString* key, uint getter_index) {
    HObject*? func_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
    if (catch err = func_raw) return false;
    HObject* func_obj = func_raw;
    (*func_obj.extra_ptr()).func.builtin_fn_index = (int)getter_index;
    func_obj.flags.callable = true;
    func_obj.flags.constructable = false;
    func_obj.prototype = heap.function_proto;

    // Getter must have .length = 0 and .name as own configurable properties (§17 ECMA).
    HString* len_key = (HString*)heap.strs[heap::BuiltinStr.LENGTH];
    if (len_key != null) {
        TVal len_tv; len_tv.set_fastint(0);
        func_obj.put_prop(len_key, len_tv, hobject::PROP_FLAGS_NWC);
    }
    HString* name_key2 = builtin_intern_string(heap, "name");
    HString* name_val2 = builtin_intern_string(heap, "get [Symbol.toStringTag]");
    if (name_key2 != null && name_val2 != null) {
        TVal name_tv2; name_tv2.set_string(name_val2);
        func_obj.put_prop(name_key2, name_tv2, hobject::PROP_FLAGS_NWC);
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

/// Register a single typed array constructor globally.
fn bool register_ta_ctor(EnvRecord* global_env, Heap* heap, char[] name, uint fn_index, HObject* proto, uint bpe) {
    // Create constructor as a proper HObject (not lightfunc) so it's constructable
    HObject*? ctor_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
    if (catch err = ctor_raw) return false;
    HObject* ctor = ctor_raw;
    (*ctor.extra_ptr()).func.builtin_fn_index = (int)fn_index;
    ctor.flags.callable = true;
    ctor.flags.constructable = true;
    // [[Prototype]] of each per-class ctor is the %TypedArray% intrinsic (§22.2.2).
    ctor.prototype = heap.typedarray_intrinsic != null ? heap.typedarray_intrinsic : heap.function_proto;

    // Set .name
    HString* name_key = builtin_intern_string(heap, "name");
    HString* name_val = builtin_intern_string(heap, name);
    if (name_key != null && name_val != null) {
        TVal name_tv;
        name_tv.set_string(name_val);
        ctor.put_prop(name_key, name_tv, hobject::PROP_FLAGS_NWC);
    }

    // Set .length = 3 (buffer, byteOffset, length — the widest overload)
    HString* length_key = (HString*)heap.strs[heap::BuiltinStr.LENGTH];
    TVal length_tv;
    length_tv.set_fastint(3);
    ctor.put_prop(length_key, length_tv, hobject::PROP_FLAGS_NWC);

    // Per ES6 §22.2, each TypedArray constructor has its own .prototype that
    // inherits from the shared %TypedArray%.prototype. We set @@toStringTag on
    // that per-ctor prototype so Object.prototype.toString.call(instance)
    // returns "[object <Name>]" rather than "[object TypedArray]".
    HObject*? ctor_proto_raw = heap.alloc_object(hobject::ObjClass.OBJECT);
    if (catch err_cp = ctor_proto_raw) return false;
    HObject* ctor_proto = ctor_proto_raw;
    ctor_proto.prototype = proto;

    // Wire .prototype
    HString* prototype_key = (HString*)heap.strs[heap::BuiltinStr.PROTOTYPE];
    TVal proto_tv;
    proto_tv.set_object(ctor_proto);
    PropFlags proto_pflags;
    proto_pflags.writable = false;
    proto_pflags.enumerable = false;
    proto_pflags.configurable = false;
    proto_pflags.is_accessor = false;
    ctor.put_prop(prototype_key, proto_tv, proto_pflags);

    // .constructor back-reference on the per-ctor prototype.
    HString* constructor_key = (HString*)heap.strs[heap::BuiltinStr.CONSTRUCTOR];
    TVal ctor_val_tv; ctor_val_tv.set_object(ctor);
    ctor_proto.put_prop(constructor_key, ctor_val_tv, hobject::PROP_FLAGS_WC);

    // BYTES_PER_ELEMENT on both constructor and per-class prototype.
    // Attributes: {writable:false, enumerable:false, configurable:false}.
    {
        HString* bpe_key = builtin_intern_string(heap, "BYTES_PER_ELEMENT");
        if (bpe_key != null) {
            PropFlags bpe_pflags;
            bpe_pflags.writable = false;
            bpe_pflags.enumerable = false;
            bpe_pflags.configurable = false;
            bpe_pflags.is_accessor = false;
            TVal bpe_tv;
            bpe_tv.set_fastint((long)bpe);
            ctor.put_prop(bpe_key, bpe_tv, bpe_pflags);
            ctor_proto.put_prop(bpe_key, bpe_tv, bpe_pflags);
        }
    }

    // Register globally
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
    TVal val;
    val.set_object(ctor);
    env::env_declare_nonenum(global_env, key, val);

    // Uint8Array base64/hex methods (tc39 proposal-arraybuffer-base64) live only
    // on %Uint8Array% and %Uint8Array.prototype%, not the shared %TypedArray%.
    if (name == "Uint8Array") {
        heap.uint8array_proto = ctor_proto;
        if (!register_string_proto_method(ctor, heap, "fromBase64", Builtin.UINT8ARRAY_FROM_BASE64.ordinal)) return false;
        if (!register_string_proto_method(ctor, heap, "fromHex",    Builtin.UINT8ARRAY_FROM_HEX.ordinal))    return false;
        if (!register_string_proto_method(ctor_proto, heap, "toBase64",      Builtin.UINT8ARRAY_PROTO_TO_BASE64.ordinal))      return false;
        if (!register_string_proto_method(ctor_proto, heap, "toHex",         Builtin.UINT8ARRAY_PROTO_TO_HEX.ordinal))         return false;
        if (!register_string_proto_method(ctor_proto, heap, "setFromBase64", Builtin.UINT8ARRAY_PROTO_SET_FROM_BASE64.ordinal)) return false;
        if (!register_string_proto_method(ctor_proto, heap, "setFromHex",    Builtin.UINT8ARRAY_PROTO_SET_FROM_HEX.ordinal))    return false;
    }
    return true;
}

/// Register all TypedArray constructors.
fn bool register_typed_array_constructors(EnvRecord* global_env, Heap* heap) {
    // Create a shared %TypedArray%.prototype
    HObject*? proto_raw = heap.alloc_object(hobject::ObjClass.OBJECT);
    if (catch err = proto_raw) return false;
    HObject* proto = proto_raw;
    proto.prototype = heap.object_proto;
    heap.typedarray_proto = proto;

    // Create the %TypedArray% intrinsic abstract constructor (§22.2.1).
    // Its [[Prototype]] is Function.prototype; its .prototype is typedarray_proto.
    HObject*? intr_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
    if (catch err = intr_raw) return false;
    HObject* intrinsic = intr_raw;
    (*intrinsic.extra_ptr()).func.builtin_fn_index = (int)Builtin.TYPEDARRAY_INTRINSIC.ordinal;
    intrinsic.flags.callable = true;
    intrinsic.flags.constructable = true;
    intrinsic.prototype = heap.function_proto;
    heap.typedarray_intrinsic = intrinsic;

    // intrinsic.prototype = typedarray_proto
    {
        HString* prototype_key = (HString*)heap.strs[heap::BuiltinStr.PROTOTYPE];
        TVal proto_tv;
        proto_tv.set_object(proto);
        PropFlags proto_pflags;
        proto_pflags.writable = false;
        proto_pflags.enumerable = false;
        proto_pflags.configurable = false;
        proto_pflags.is_accessor = false;
        intrinsic.put_prop(prototype_key, proto_tv, proto_pflags);
    }

    // typedarray_proto.constructor = intrinsic
    {
        HString* constructor_key = (HString*)heap.strs[heap::BuiltinStr.CONSTRUCTOR];
        TVal intr_tv;
        intr_tv.set_object(intrinsic);
        proto.put_prop(constructor_key, intr_tv, hobject::PROP_FLAGS_WC);
    }

    set_func_ctor_name_length(intrinsic, heap, "TypedArray", 0);

    // Shared prototype accessors (length/byteLength/byteOffset/buffer).
    if (!register_typedarray_accessor(proto, heap, "length", Builtin.TYPEDARRAY_PROTO_LENGTH_GET.ordinal)) return false;
    if (!register_typedarray_accessor(proto, heap, "byteLength", Builtin.TYPEDARRAY_PROTO_BYTELENGTH_GET.ordinal)) return false;
    if (!register_typedarray_accessor(proto, heap, "byteOffset", Builtin.TYPEDARRAY_PROTO_BYTEOFFSET_GET.ordinal)) return false;
    if (!register_typedarray_accessor(proto, heap, "buffer", Builtin.TYPEDARRAY_PROTO_BUFFER_GET.ordinal)) return false;

    // [Symbol.toStringTag] getter on the shared prototype: returns the
    // per-instance class name, or undefined for non-TA receivers.
    HString* tag_key = ensure_tostringtag_symbol(heap);
    if (tag_key != null) {
        if (!register_typedarray_symbol_accessor(proto, heap, tag_key, Builtin.TYPEDARRAY_PROTO_TOSTRINGTAG_GET.ordinal)) return false;
    }

    // Wave A prototype methods (plan 049 stage 4)
    if (!register_string_proto_method(proto, heap, "values",      Builtin.TA_PROTO_VALUES.ordinal))      return false;
    if (!register_string_proto_method(proto, heap, "keys",        Builtin.TA_PROTO_KEYS.ordinal))        return false;
    if (!register_string_proto_method(proto, heap, "entries",     Builtin.TA_PROTO_ENTRIES.ordinal))     return false;
    if (!register_string_proto_method(proto, heap, "set",         Builtin.TA_PROTO_SET.ordinal))         return false;
    if (!register_string_proto_method(proto, heap, "subarray",    Builtin.TA_PROTO_SUBARRAY.ordinal))    return false;
    if (!register_string_proto_method(proto, heap, "fill",        Builtin.TA_PROTO_FILL.ordinal))        return false;
    if (!register_string_proto_method(proto, heap, "copyWithin",  Builtin.TA_PROTO_COPYWITHIN.ordinal))  return false;
    if (!register_string_proto_method(proto, heap, "slice",       Builtin.TA_PROTO_SLICE.ordinal))       return false;

    // Wave B prototype methods (plan 049 stage 5)
    if (!register_string_proto_method(proto, heap, "indexOf",         Builtin.TA_PROTO_INDEX_OF.ordinal))        return false;
    if (!register_string_proto_method(proto, heap, "lastIndexOf",     Builtin.TA_PROTO_LAST_INDEX_OF.ordinal))   return false;
    if (!register_string_proto_method(proto, heap, "includes",        Builtin.TA_PROTO_INCLUDES.ordinal))        return false;
    if (!register_string_proto_method(proto, heap, "join",            Builtin.TA_PROTO_JOIN.ordinal))            return false;
    if (!register_string_proto_method(proto, heap, "forEach",         Builtin.TA_PROTO_FOR_EACH.ordinal))        return false;
    if (!register_string_proto_method(proto, heap, "every",           Builtin.TA_PROTO_EVERY.ordinal))           return false;
    if (!register_string_proto_method(proto, heap, "some",            Builtin.TA_PROTO_SOME.ordinal))            return false;
    if (!register_string_proto_method(proto, heap, "reduce",          Builtin.TA_PROTO_REDUCE.ordinal))          return false;
    if (!register_string_proto_method(proto, heap, "reduceRight",     Builtin.TA_PROTO_REDUCE_RIGHT.ordinal))    return false;
    if (!register_string_proto_method(proto, heap, "map",             Builtin.TA_PROTO_MAP.ordinal))             return false;
    if (!register_string_proto_method(proto, heap, "filter",          Builtin.TA_PROTO_FILTER.ordinal))          return false;
    if (!register_string_proto_method(proto, heap, "find",            Builtin.TA_PROTO_FIND.ordinal))            return false;
    if (!register_string_proto_method(proto, heap, "findIndex",       Builtin.TA_PROTO_FIND_INDEX.ordinal))      return false;
    if (!register_string_proto_method(proto, heap, "findLast",        Builtin.TA_PROTO_FIND_LAST.ordinal))       return false;
    if (!register_string_proto_method(proto, heap, "findLastIndex",   Builtin.TA_PROTO_FIND_LAST_INDEX.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "reverse",         Builtin.TA_PROTO_REVERSE.ordinal))         return false;
    if (!register_string_proto_method(proto, heap, "toReversed",      Builtin.TA_PROTO_TO_REVERSED.ordinal))     return false;
    if (!register_string_proto_method(proto, heap, "at",              Builtin.TA_PROTO_AT.ordinal))              return false;
    if (!register_string_proto_method(proto, heap, "sort",            Builtin.TA_PROTO_SORT.ordinal))            return false;
    if (!register_string_proto_method(proto, heap, "toSorted",        Builtin.TA_PROTO_TO_SORTED.ordinal))       return false;
    if (!register_string_proto_method(proto, heap, "with",            Builtin.TA_PROTO_WITH.ordinal))            return false;
    // toString must be the same function object as Array.prototype.toString (§22.2.3.28).
    {
        HString* tostr_key = builtin_intern_string(heap, "toString");
        if (tostr_key != null && heap.array_proto != null) {
            TVal? arr_tostr = heap.array_proto.get_prop(tostr_key);
            if (try atv = arr_tostr) {
                proto.put_prop(tostr_key, atv, hobject::PROP_FLAGS_WC);
            } else {
                if (!register_string_proto_method(proto, heap, "toString", Builtin.TA_PROTO_TO_STRING.ordinal)) return false;
            }
        } else {
            if (!register_string_proto_method(proto, heap, "toString", Builtin.TA_PROTO_TO_STRING.ordinal)) return false;
        }
    }
    if (!register_string_proto_method(proto, heap, "toLocaleString",  Builtin.TA_PROTO_TO_LOCALE_STRING.ordinal)) return false;

    // %TypedArray%.prototype[@@iterator] = %TypedArray%.prototype.values (same object).
    // The spec says the @@iterator property must be the same function as .values.
    {
        HString* iter_sym = ensure_iterator_symbol(heap);
        if (iter_sym != null) {
            HString* values_key = builtin_intern_string(heap, "values");
            if (values_key != null) {
                TVal? values_tv = proto.get_prop(values_key);
                if (try vtv = values_tv) {
                    proto.put_prop(iter_sym, vtv, hobject::PROP_FLAGS_WC);
                }
            }
        }
    }

    // Register each typed array constructor
    if (!register_ta_ctor(global_env, heap, "Int8Array",               Builtin.INT8ARRAY.ordinal,              proto, 1)) return false;
    if (!register_ta_ctor(global_env, heap, "Uint8Array",              Builtin.UINT8ARRAY.ordinal,             proto, 1)) return false;
    if (!register_ta_ctor(global_env, heap, "Uint8ClampedArray",       Builtin.UINT8CLAMPEDARRAY.ordinal,      proto, 1)) return false;
    if (!register_ta_ctor(global_env, heap, "Int16Array",              Builtin.INT16ARRAY.ordinal,             proto, 2)) return false;
    if (!register_ta_ctor(global_env, heap, "Uint16Array",             Builtin.UINT16ARRAY.ordinal,            proto, 2)) return false;
    if (!register_ta_ctor(global_env, heap, "Int32Array",              Builtin.INT32ARRAY.ordinal,             proto, 4)) return false;
    if (!register_ta_ctor(global_env, heap, "Uint32Array",             Builtin.UINT32ARRAY.ordinal,            proto, 4)) return false;
    if (!register_ta_ctor(global_env, heap, "Float32Array",            Builtin.FLOAT32ARRAY.ordinal,           proto, 4)) return false;
    if (!register_ta_ctor(global_env, heap, "Float64Array",            Builtin.FLOAT64ARRAY.ordinal,           proto, 8)) return false;
    if (!register_ta_ctor(global_env, heap, "BigInt64Array",           Builtin.BIGINT64ARRAY.ordinal,          proto, 8)) return false;
    if (!register_ta_ctor(global_env, heap, "BigUint64Array",          Builtin.BIGUINT64ARRAY.ordinal,         proto, 8)) return false;

    // Install of/from on the %TypedArray% intrinsic so all 9 per-class ctors
    // inherit them via [[Prototype]] chain (§22.2.2.1, §22.2.2.2).
    if (!register_string_proto_method(intrinsic, heap, "of",   Builtin.TA_OF.ordinal))   return false;
    if (!register_string_proto_method(intrinsic, heap, "from", Builtin.TA_FROM.ordinal)) return false;

    // %TypedArray%[@@species] — getter that returns `this` (§22.2.2.4).
    {
        HString* species_sym = ensure_species_symbol(heap);
        if (species_sym != null) {
            HObject*? getter_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
            if (try getter = getter_raw) {
                getter.flags.callable = true;
                getter.flags.constructable = false;
                getter.prototype = heap.function_proto;
                (*getter.extra_ptr()).func.builtin_fn_index = (int)Builtin.TA_SPECIES_GET.ordinal;
                // Set getter.name = "get [Symbol.species]"
                HString* gname_key = builtin_intern_string(heap, "name");
                HString* gname_val = builtin_intern_string(heap, "get [Symbol.species]");
                if (gname_key != null && gname_val != null) {
                    TVal gname_tv; gname_tv.set_string(gname_val);
                    getter.put_prop(gname_key, gname_tv, hobject::PROP_FLAGS_NWC);
                }
                HString* glen_key = (HString*)heap.strs[heap::BuiltinStr.LENGTH];
                if (glen_key != null) {
                    TVal glen_tv; glen_tv.set_fastint(0);
                    getter.put_prop(glen_key, glen_tv, hobject::PROP_FLAGS_NWC);
                }
                TVal getter_tv; getter_tv.set_object(getter);
                TVal undef; undef.set_undefined();
                PropFlags acc_flags;
                acc_flags.writable = false;
                acc_flags.enumerable = false;
                acc_flags.configurable = true;
                acc_flags.is_accessor = true;
                intrinsic.put_prop(species_sym, hobject::hobject_create_accessors(heap, getter_tv, undef), acc_flags);
            }
        }
    }

    return true;
}
