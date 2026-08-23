// BigInt constructor, static methods (asIntN / asUintN), and
// BigInt.prototype methods (toString / valueOf / toLocaleString).
//
// See plan 056.  BigInt values are fixed-width int128 boxes (see hbigint.c3);
// results outside ±(2^127 − 1) raise RangeError rather than wrapping, except
// asIntN / asUintN whose modular reduction is their specified behaviour.
module boomkat::builtins;

import boomkat::types;
import boomkat::env;
import boomkat::heap;
import boomkat::hobject;
import boomkat::hstring;
import boomkat::hbigint;
import boomkat::vm;
import std::math;
import libc;

// ============================================================================
// Result helper
// ============================================================================

// Box an int128 and store it into ctx.result.  Mirrors the object-result
// ownership pattern: hbigint_alloc yields refcount 1 (+temproot); set_bigint
// increfs; we drop the alloc's initial reference so the value is anchored
// solely by the result slot (which the CALL handler copies out with incref).
// On allocation failure, raises a RangeError.
fn void builtin_set_bigint_result(BuiltinContext* ctx, hbigint::HBigInt* box) {
    if (box == null) {
        arr_throw_range_error(ctx, "BigInt is too large to allocate");
        return;
    }
    ctx.result.set_bigint(box);
    ctx.heap.decref((types::HeapHeader*)box);
}

// ============================================================================
// ToBigInt (ES2020 §7.1.13)
// ============================================================================

// Convert a value to an int128 BigInt per ToBigInt.  On failure sets
// ctx.should_throw (TypeError / SyntaxError / RangeError) and returns 0.
// `ok` is set false on any thrown path.
fn hbigint::HBigInt* builtin_to_bigint(BuiltinContext* ctx, TVal* val, bool* ok) {
    *ok = true;
    switch (val.get_tag()) {
        case BIGINT:
            return val.get_bigint();
        case BOOLEAN: {
            hbigint::HBigInt*? b = hbigint::hbigint_from_slimb(ctx.heap,
                val.get_boolean() ? 1 : 0);
            if (catch b) { *ok = false; return null; }
            return b;
        }
        case STRING: {
            HString* s = (HString*)val.get_heapptr();
            if (s != null && s.is_symbol()) {
                *ok = false;
                arr_throw_type_error(ctx, "Cannot convert a Symbol value to a BigInt");
                return null;
            }
            // StringToBigInt (§7.1.14): whitespace-trimmed integer literal.
            hbigint::HBigInt*? r = vm::string_to_bigint(ctx.heap, s.get_data());
            if (catch r) {
                *ok = false;
                builtin_throw(ctx, ctx.heap.syntax_err_proto, "Cannot convert string to a BigInt");
                return null;
            }
            return r;
        }
        case NUMBER:
        case FASTINT:
            // ES2020 §7.1.13 ToBigInt(Number) → always TypeError.  (The BigInt
            // constructor's Number path is handled separately, before this.)
            *ok = false;
            arr_throw_type_error(ctx, "Cannot convert a Number to a BigInt");
            return null;
        case OBJECT: {
            // ToPrimitive(number) then recurse.
            if (ctx.vm != null) {
                TVal prim = vm::to_primitive_value((vm::Vm*)ctx.vm, val, 0);
                if (((vm::Vm*)ctx.vm).throw_pending) {
                    ((vm::Vm*)ctx.vm).throw_pending = false;
                    ctx.should_throw = true;
                    ctx.throw_value = ((vm::Vm*)ctx.vm).throw_value;
                    *ok = false;
                    return null;
                }
                if (!prim.is_object()) {
                    return builtin_to_bigint(ctx, &prim, ok);
                }
            }
            *ok = false;
            arr_throw_type_error(ctx, "Cannot convert object to a BigInt");
            return null;
        }
        default:
            // undefined, null, symbol
            *ok = false;
            arr_throw_type_error(ctx, "Cannot convert value to a BigInt");
            return null;
    }
}

// NumberToBigInt (ES2020 §7.1.13 step for Number): the number must be an
// integer. A non-integral or non-finite value faults BIGINT_SYNTAX; there is no
// magnitude limit, since every finite integral double is representable.
fn hbigint::HBigInt*? number_to_bigint(Heap* hp, double d) {
    if (math::is_nan(d) || math::is_inf(d)) return hbigint::BIGINT_SYNTAX~;
    if (d != math::trunc(d)) return hbigint::BIGINT_SYNTAX~;
    return hbigint::hbigint_from_double(hp, d);
}


// ============================================================================
// BigInt(value), ES2020 §20.2.1
// ============================================================================

fn void builtin_bigint(BuiltinContext* ctx) {
    // BigInt is NOT a constructor: `new BigInt()` throws TypeError.
    if (ctx.is_constructor) {
        arr_throw_type_error(ctx, "BigInt is not a constructor");
        return;
    }
    if (ctx.argc == 0) {
        // ToBigInt(undefined) → TypeError.
        arr_throw_type_error(ctx, "Cannot convert undefined to a BigInt");
        return;
    }
    TVal* arg = &ctx.regs[ctx.base_reg];

    // ES2020 §20.2.1.1: if the (ToPrimitive'd) argument is a Number, use
    // NumberToBigInt (integral-only, else RangeError) rather than ToBigInt
    // (which would TypeError).  Resolve ToPrimitive(number) for objects first.
    TVal prim = *arg;
    if (arg.is_object() && ctx.vm != null) {
        prim = vm::to_primitive_value((vm::Vm*)ctx.vm, arg, 0);
        if (((vm::Vm*)ctx.vm).throw_pending) {
            ((vm::Vm*)ctx.vm).throw_pending = false;
            ctx.should_throw = true;
            ctx.throw_value = ((vm::Vm*)ctx.vm).throw_value;
            return;
        }
    }
    if (prim.is_number() || prim.is_fastint()) {
        hbigint::HBigInt*? r = number_to_bigint(ctx.heap, prim.get_number_or_fastint());
        if (catch excuse = r) {
            if (excuse == hbigint::BIGINT_OVERFLOW) {
                arr_throw_range_error(ctx, "BigInt is too large to allocate");
            } else {
                arr_throw_range_error(ctx, "The number is not a safe integer and cannot be converted to a BigInt");
            }
            return;
        }
        builtin_set_bigint_result(ctx, r);
        return;
    }

    bool ok;
    hbigint::HBigInt* v = builtin_to_bigint(ctx, &prim, &ok);
    if (!ok) return;
    builtin_set_bigint_result(ctx, v);
}

// ============================================================================
// BigInt.asIntN(bits, value) / BigInt.asUintN(bits, value), ES2020 §20.2.2
// ============================================================================

// Parse the `bits` argument: ToIndex (a non-negative integer).  On failure
// sets ctx.should_throw and returns false.
fn bool bigint_read_bits(BuiltinContext* ctx, uint* out_bits) {
    TVal undef; undef.set_undefined();
    TVal* bits_arg = ctx.argc > 0 ? &ctx.regs[ctx.base_reg] : &undef;
    double bits_d = builtin_to_integer_vm(ctx, bits_arg);
    if (ctx.should_throw) return false;
    if (bits_d < 0 || bits_d > 4294967295.0) {
        arr_throw_range_error(ctx, "Invalid bit count for BigInt.asIntN/asUintN");
        return false;
    }
    *out_bits = (uint)(long)bits_d;
    return true;
}

// asUintN(bits, x): x modulo 2^bits, read as unsigned. Exact at any width now
// that values are unbounded, so it can only fail on allocation.
fn void builtin_bigint_as_uintn(BuiltinContext* ctx) {
    bigint_as_common(ctx, false);
}

// asIntN(bits, x): x modulo 2^bits, read as signed.
fn void builtin_bigint_as_intn(BuiltinContext* ctx) {
    bigint_as_common(ctx, true);
}

// Shared body of asIntN / asUintN (ECMA-262 §21.2.2.1-2), which differ only in
// how the retained low bits are interpreted.
fn void bigint_as_common(BuiltinContext* ctx, bool is_signed) {
    uint bits;
    if (!bigint_read_bits(ctx, &bits)) return;
    TVal undef; undef.set_undefined();
    TVal* val_arg = ctx.argc > 1 ? &ctx.regs[ctx.base_reg + 1] : &undef;
    bool ok;
    hbigint::HBigInt* x = builtin_to_bigint(ctx, val_arg, &ok);
    if (!ok) return;

    hbigint::HBigInt*? r = hbigint::hbigint_as_n(ctx.heap, x, (ulong)bits, is_signed);
    if (catch r) {
        arr_throw_range_error(ctx, "BigInt is too large to allocate");
        return;
    }
    builtin_set_bigint_result(ctx, r);
}

// ============================================================================
// BigInt.prototype.toString([radix]) / valueOf(), ES2020 §20.2.3
// ============================================================================

// thisBigIntValue (ES2020 §20.2.3.4): unwrap a BigInt primitive.  On failure
// sets ctx.should_throw and returns false.
fn bool bigint_this_value(BuiltinContext* ctx, hbigint::HBigInt** out_val) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    if (this_val.is_bigint()) {
        *out_val = this_val.get_bigint();
        return true;
    }
    // A genuine BigInt wrapper (from Object(1n) / ToObject) has bigint_proto
    // as its [[Prototype]] and stores a BigInt in its primitive slot.  Requiring
    // the prototype match avoids treating a plain object like {x:1n} (whose
    // primitive-value union is not a valid TVal) as a wrapper.
    if (this_val.is_object() && this_val.get_heapptr() != null) {
        HObject* obj = (HObject*)this_val.get_heapptr();
        if (obj.prototype == ctx.heap.bigint_proto) {
            TVal prim = (*obj.extra_ptr()).prim.primitive_value;
            if (prim.is_bigint()) {
                *out_val = prim.get_bigint();
                return true;
            }
        }
    }
    builtin_throw_no_result_change(ctx, ctx.heap.type_err_proto,
        "BigInt.prototype method called on incompatible receiver");
    return false;
}

fn void builtin_bigint_proto_toString(BuiltinContext* ctx) {
    hbigint::HBigInt* v;
    if (!bigint_this_value(ctx, &v)) return;

    int radix = 10;
    bool radix_undefined = ctx.argc == 0 ||
        ctx.regs[ctx.base_reg].get_tag() == types::TValTag.UNDEFINED;
    if (!radix_undefined) {
        double radix_d = builtin_to_integer_vm(ctx, &ctx.regs[ctx.base_reg]);
        if (ctx.should_throw) { ctx.result.set_undefined(); return; }
        if (radix_d < 2 || radix_d > 36) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "radix must be an integer between 2 and 36");
            return;
        }
        radix = (int)(long)radix_d;
    }

    // A small value formats on the stack; a large one allocates exactly the
    // width its digits need.
    char[160] buf;
    usz need = hbigint::hbigint_string_cap(v, (uint)radix);
    char[] out;
    char* heap_buf = null;
    if (need <= buf.len) {
        out = buf[..];
    } else {
        void*? raw = ctx.heap.alloc(need);
        if (catch raw) {
            arr_throw_range_error(ctx, "BigInt is too large to allocate");
            return;
        }
        heap_buf = (char*)raw;
        out = heap_buf[0:need];
    }
    defer if (heap_buf != null) ctx.heap.free((void*)heap_buf);

    char[]? s = hbigint::hbigint_to_radix(ctx.heap, v, (uint)radix, out);
    if (catch s) {
        arr_throw_range_error(ctx, "BigInt is too large to allocate");
        return;
    }
    HString* hs = builtin_intern_string(ctx.heap, s);
    ctx.result.set_string(hs);
}

fn void builtin_bigint_proto_valueOf(BuiltinContext* ctx) {
    hbigint::HBigInt* v;
    if (!bigint_this_value(ctx, &v)) return;
    builtin_set_bigint_result(ctx, v);
}

// ============================================================================
// Registration
// ============================================================================

fn bool register_bigint_constructor(EnvRecord* global_env, Heap* heap) {
    // --- Prototype (a plain object holding the methods) ---
    HObject*? proto_raw = heap.alloc_object(hobject::ObjClass.OBJECT);
    if (catch proto_raw) return false;
    HObject* proto = proto_raw;
    proto.prototype = heap.object_proto;
    heap.bigint_proto = proto;

    if (!register_string_proto_method(proto, heap, "toString", Builtin.BIGINT_PROTO_TOSTRING.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "valueOf", Builtin.BIGINT_PROTO_VALUEOF.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "toLocaleString", Builtin.BIGINT_PROTO_TOSTRING.ordinal)) return false;

    // @@toStringTag = "BigInt" (non-writable, non-enumerable, configurable).
    HString* tag_key = ensure_tostringtag_symbol(heap);
    if (tag_key != null) {
        TVal tag_tv;
        tag_tv.set_string(builtin_intern_string(heap, "BigInt"));
        proto.put_prop(tag_key, tag_tv, hobject::PROP_FLAGS_NWC, heap);
    }

    // --- Constructor function object ---
    HObject*? ctor_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
    if (catch ctor_raw) return false;
    HObject* ctor = ctor_raw;
    (*ctor.extra_ptr()).func.builtin_fn_index = (int)Builtin.BIGINT.ordinal;
    ctor.flags.callable = true;
    // BigInt is not constructable with new, but must have [[Construct]] to be
    // detected by isConstructor(), the construct behavior throws TypeError.
    // Keep constructable = true (default) so Reflect.construct() works.
    ctor.prototype = heap.function_proto;

    // .constructor / .prototype cross-links.
    HString* constructor_key = (HString*)heap.strs[heap::BuiltinStr.CONSTRUCTOR];
    TVal ctor_tv; ctor_tv.set_object(ctor);
    proto.put_prop(constructor_key, ctor_tv, hobject::PROP_FLAGS_WC, heap);

    HString* prototype_key = (HString*)heap.strs[heap::BuiltinStr.PROTOTYPE];
    TVal proto_tv; proto_tv.set_object(proto);
    PropFlags proto_pflags;
    proto_pflags.writable = false;
    proto_pflags.enumerable = false;
    proto_pflags.configurable = false;
    proto_pflags.is_accessor = false;
    ctor.put_prop(prototype_key, proto_tv, proto_pflags, heap);

    // Static methods.
    if (!register_string_proto_method(ctor, heap, "asIntN", Builtin.BIGINT_AS_INTN.ordinal)) return false;
    if (!register_string_proto_method(ctor, heap, "asUintN", Builtin.BIGINT_AS_UINTN.ordinal)) return false;

    set_func_ctor_name_length(ctor, heap, "BigInt", 1);

    // Register BigInt globally as a non-enumerable binding.
    HString* key = heap.str_intern("BigInt");
    if (key == null) return false;
    TVal ctor_val; ctor_val.set_object(ctor);
    env::env_declare_nonenum(global_env, key, ctor_val);

    return true;
}
