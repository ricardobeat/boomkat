module duktape::vm;

import duktape::types;
import duktape::bytecode;
import duktape::heap;
import duktape::hstring;
import duktape::hbigint;
import duktape::hobject;
import duktape::env;
import duktape::builtins;
import duktape::re_bindings;
import duktape::dtoa_bindings;
import std::io;
import std::math;
import libc;

// ============================================================================
// Helpers
// ============================================================================

/// Convert a value known to be numeric (FASTINT or NUMBER) to double.
fn double tval_numeric_to_double(TVal* val) @inline {
    return val.is_fastint() ? (double)val.get_fastint() : val.get_number();
}

/// ECMAScript ToNumber — convert any TVal to its numeric double value.
/// Handles BOOLEAN→0/1, OBJECT→ToPrimitive→number, STRING→parse, etc.
fn double vm_to_number(Vm* vm, TVal* val) {
    switch (val.get_tag()) {
        case FASTINT: return (double)val.get_fastint();
        case NUMBER:  return val.get_number();
        case BOOLEAN: return val.get_boolean() ? 1.0 : 0.0;
        case UNDEFINED: return double::nan;
        case NULL_VAL:  return 0.0;
        case STRING: {
            HString* hstr = (HString*)val.get_heapptr();
            // ES6 §7.1.3: ToNumber(Symbol) throws TypeError
            if (hstr != null && hstr.is_symbol()) {
                vm_set_type_error(vm, "Cannot convert a Symbol value to a number");
                return double::nan;
            }
            return builtins::builtin_string_to_number(hstr);
        }
        case OBJECT: {
            TVal prim = to_primitive_value(vm, val);
            if (prim.get_tag() == OBJECT) return double::nan;
            return vm_to_number(vm, &prim);
        }
        default: return double::nan;
    }
}

/// ECMAScript ToInt32 — ES5 §9.5
/// Converts a double to int32 using modular arithmetic (mod 2^32).
/// Handles NaN → 0, Infinity → 0, and large values via floor-then-mod.
fn int toint32(double d) @inline {
    // Fast path: value already fits in int32
    int i = (int)d;
    if ((double)i == d) return i;
    // NaN / ±Infinity → 0
    if (math::is_nan(d) || !math::is_finite(d)) return 0;
    // Spec: posInt = sign(d) * floor(abs(d)); int32bit = posInt mod 2^32
    double abs_d = math::abs(d);
    double pos_int = math::floor(abs_d);
    if (d < 0.0) pos_int = -pos_int;
    double q = pos_int * (1.0 / 4294967296.0);
    q = math::floor(q);
    double r = pos_int - q * 4294967296.0;   // r in [0, 2^32)
    if (r >= 2147483648.0) r -= 4294967296.0;
    return (int)r;
}

/// Abstract Relational Comparison (ES2015 §7.2.11).
/// Returns tri-state: -1 = px < py, +1 = px > py, 0 = equal, and *is_undef=true
/// if either operand is NaN (undefined per spec). Coerces objects via
/// ToPrimitive("number") and, if both results are strings, uses lex compare.
/// Sets vm.throw_pending on ToPrimitive failure (caller must check + break).
fn int vm_relational_compare(Vm* vm, TVal* x, TVal* y, bool* is_undef) {
    *is_undef = false;
    TVal px = *x;
    TVal py = *y;
    if (px.get_tag() == OBJECT) {
        px = to_primitive_value(vm, x, 2);  // hint: number
        if (vm.throw_pending) return 0;
    }
    if (py.get_tag() == OBJECT) {
        py = to_primitive_value(vm, y, 2);
        if (vm.throw_pending) return 0;
    }
    // Both primitives now. If both strings → lex compare, else numeric.
    // Symbols are internally string-tagged but must go through ToNumber
    // (which throws per §7.1.3) instead of the lexical-compare fast path.
    if (px.is_string() && py.is_string()) {
        HString* sx = (HString*)px.get_heapptr();
        HString* sy = (HString*)py.get_heapptr();
        if (!(sx != null && sx.is_symbol()) && !(sy != null && sy.is_symbol())) {
            int c = hstring::hstring_compare(sx, sy);
            return c < 0 ? -1 : (c > 0 ? 1 : 0);
        }
    }

    // === BigInt relational comparison (ES2020 §7.2.13 by mathematical value) ===
    if (px.is_bigint() || py.is_bigint()) {
        int r = vm_bigint_relational(vm, &px, &py, is_undef);
        return r;
    }

    double dx = vm_to_number(vm, &px);
    if (vm.throw_pending) return 0;
    double dy = vm_to_number(vm, &py);
    if (vm.throw_pending) return 0;
    if (math::is_nan(dx) || math::is_nan(dy)) { *is_undef = true; return 0; }
    if (dx < dy) return -1;
    if (dx > dy) return 1;
    return 0;
}

/// ECMAScript truthiness.
macro bool is_truthy(TVal* val) {
$if types::USE_NANBOX:
    ulong tag = val.bits >> 48;
    // Falsy primitives: undefined, null, false
    if (tag == types::TAG_UNDEFINED ||
        tag == types::TAG_NULL_VAL ||
        val.bits == (types::TAG_BOOLEAN << 48)) {
        return false;
    }
    // Fastint: sign-extend 48-bit payload, check != 0
    if (tag == types::TAG_FASTINT) {
        long fi = ((long)(val.bits & types::NANBOX_PAYLOAD_MASK) << 16) >> 16;
        return fi != 0;
    }
    // Number (double): 0.0 and NaN are falsy
    if (types::nanbox_is_double(val.bits)) {
        double d = bitcast(val.bits, double);
        return d != 0.0 && !math::is_nan(d);
    }
    // String: empty string is falsy
    if (tag == types::TAG_STRING) {
        HString* s = (HString*)(val.bits & types::NANBOX_PAYLOAD_MASK);
        return s.blen > 0;
    }
    // Objects, lightfuncs, etc. are always truthy
    return true;
$else
    switch (val.get_tag()) {
        case UNDEFINED: return false;
        case NULL_VAL:  return false;
        case BOOLEAN:   return val.get_boolean();
        case NUMBER:    return val.get_number() != 0.0 && !math::is_nan(val.get_number());
        case FASTINT:   return val.get_fastint() != 0;
        case STRING:    return ((HString*)val.get_heapptr()).blen > 0;
        case OBJECT:    return true;
        case LIGHTFUNC: return true;
        default:        return true;
    }
$endif
}

/// Ensure the value stack has room for `needed` more slots.
/// Fast path uses pointer comparison (no division).
fn bool ensure_valstack(Vm* vm, uint needed) @inline {
    // Fast path: check if top + needed fits within allocated end
    if (vm.valstack_top + needed <= vm.valstack_end) {
        return true;
    }
    return ensure_valstack_grow(vm, needed);
}

/// Slow path: grow the value stack.
fn bool ensure_valstack_grow(Vm* vm, uint needed) {
    TVal* old_base = vm.valstack;
    uint used = (uint)((usz)vm.valstack_top - (usz)vm.valstack) / TVal::size;
    uint new_size = vm.valstack_size;
    while (new_size < used + needed) {
        new_size *= 2;
    }
    void* new_raw = vm.heap.realloc_func(vm.heap.heap_udata, vm.valstack, (usz)new_size * TVal::size);
    if (new_raw == null) {
        return false;
    }
    TVal* new_base = (TVal*)new_raw;
    long diff = (char*)new_base - (char*)old_base;

    vm.valstack = new_base;
    vm.valstack_size = new_size;
    vm.valstack_top = (TVal*)((char*)vm.valstack_top + diff);
    vm.valstack_end = (TVal*)((char*)new_base + (usz)(new_size * TVal::size));
    vm.valstack_bottom = (TVal*)((char*)vm.valstack_bottom + diff);

    // Relocate all activation bottom/retval pointers (they point into the old buffer)
    for (uint i = 0; i < vm.activation_count; i++) {
        Activation* a = &vm.activations[i];
        a.bottom = (TVal*)((char*)a.bottom + diff);
        if (a.retval != null) {
            a.retval = (TVal*)((char*)a.retval + diff);
        }
    }

    // Update heap's valstack GC root pointers (base may have moved)
    vm.heap.valstack_base = vm.valstack;
    // valstack_top_ptr still points to vm.valstack_top (stable struct field)

    return true;
}

/// Get the current activation. Returns null if no activations.
fn Activation* curr_act(Vm* vm) @inline {
    if (vm.activation_count == 0) return null;
    assert(vm.activation_count <= MAX_CALLS);
    return &vm.activations[vm.activation_count - 1];
}

/// Get valstack_bottom as TVal*
fn TVal* valstack_bottom_ptr(Vm* vm) @inline {
    return curr_act(vm).bottom;
}

/// Convert a TVal to an interned string key for property access.
/// Uses a single tag extraction via switch to avoid redundant checks.
/// ES5 §11.8.7 / ES7 §12.2.1: ToPropertyKey — unwraps wrapper objects.
fn void* get_prop_key(Vm* vm, TVal* val) {
    Heap* h = vm.heap;
    switch (val.get_tag()) {
        case STRING: {
            HString* s = (HString*)val.get_heapptr();
            if (!s.flags.is_interned) return h.ensure_interned(s);
            return s;
        }
        case FASTINT:
            if (try s = vm_fastint_to_string(vm, val.get_fastint())) return s;
            return null;
        case NUMBER:
            if (try s = vm_number_to_string(vm, val.get_number())) return s;
            return null;
        case BOOLEAN:
            if (val.get_boolean()) return h.strs[heap::BuiltinStr.TRUE];
            return h.strs[heap::BuiltinStr.FALSE];
        case UNDEFINED: return h.strs[heap::BuiltinStr.UNDEFINED];
        case NULL_VAL:  return h.strs[heap::BuiltinStr.NULL_STR];
        case OBJECT: {
            // Full ToPrimitive (hint "string") for object keys — calls toString/valueOf,
            // Symbol.toPrimitive, etc. Sets throw_pending on failure (§7.1.1.1 step 6).
            TVal prim = to_primitive_value(vm, val, 1);
            if (vm != null && vm.throw_pending) return null;
            if (prim.get_tag() != OBJECT) {
                TVal tmp = prim;
                return get_prop_key(vm, &tmp);
            }
            if (vm != null) vm_set_toprimitive_error(vm);
            return null;
        }
        default:        return h.strs[heap::BuiltinStr.UNDEFINED];
    }
}

/// Look up a property on an object, walking the prototype chain.
/// Returns the .prototype object for a constructor lightfunc, or null for non-constructor lightfuncs.
fn HObject* lightfunc_get_proto(Vm* vm, uint fn_idx) {
    switch (fn_idx) {
        case builtins::Builtin.ERROR.ordinal:           return vm.heap.err_proto;
        case builtins::Builtin.TYPE_ERROR.ordinal:      return vm.heap.type_err_proto;
        case builtins::Builtin.RANGE_ERROR.ordinal:     return vm.heap.range_err_proto;
        case builtins::Builtin.REFERENCE_ERROR.ordinal: return vm.heap.ref_err_proto;
        case builtins::Builtin.SYNTAX_ERROR.ordinal:    return vm.heap.syntax_err_proto;
        case builtins::Builtin.EVAL_ERROR.ordinal:      return vm.heap.eval_err_proto;
        case builtins::Builtin.BOOLEAN.ordinal:         return vm.heap.bool_proto;
        case builtins::Builtin.STRING.ordinal:          return vm.heap.string_proto;
        case builtins::Builtin.NUMBER.ordinal:          return vm.heap.number_proto;
        case builtins::Builtin.OBJECT.ordinal:          return vm.heap.object_proto;
        case builtins::Builtin.ARRAY.ordinal:           return vm.heap.array_proto;
        case builtins::Builtin.FUNCTION.ordinal:        return vm.heap.function_proto;
        case builtins::Builtin.DATE.ordinal:            return vm.heap.date_proto;
        case builtins::Builtin.REGEXP.ordinal:          return vm.heap.regexp_proto;
        case builtins::Builtin.MAP.ordinal:             return vm.heap.map_proto;
        case builtins::Builtin.SET.ordinal:             return vm.heap.set_proto;
        case builtins::Builtin.WEAKMAP.ordinal:         return vm.heap.weakmap_proto;
        case builtins::Builtin.WEAKSET.ordinal:         return vm.heap.weakset_proto;
        case builtins::Builtin.SYMBOL.ordinal:          return vm.heap.symbol_proto;
        case builtins::Builtin.PROMISE.ordinal:         return vm.heap.promise_proto;
        case builtins::Builtin.GENERATOR_FUNCTION.ordinal: return vm.heap.generator_proto;
        case builtins::Builtin.URI_ERROR.ordinal: return vm.heap.uri_err_proto;
        case builtins::Builtin.AGGREGATE_ERROR.ordinal: return vm.heap.aggregate_err_proto;
        default: return null;
    }
}

/// True when the builtin behind `fn_idx` is a constructor. Builtin FUNCTION
/// objects are allocated with flags.constructable=true by default, so the flag
/// cannot distinguish `new DataView(...)` from `new String.prototype.charAt` —
/// classify by function index instead: the lightfunc constructor table plus the
/// constructors installed as full HObjects (typed arrays, ArrayBuffer,
/// DataView, Proxy).
fn bool builtin_fn_is_constructor(Vm* vm, uint fn_idx) {
    if (lightfunc_get_proto(vm, fn_idx) != null) return true;
    switch (fn_idx) {
        case builtins::Builtin.INT8ARRAY.ordinal:
        case builtins::Builtin.UINT8ARRAY.ordinal:
        case builtins::Builtin.UINT8CLAMPEDARRAY.ordinal:
        case builtins::Builtin.INT16ARRAY.ordinal:
        case builtins::Builtin.UINT16ARRAY.ordinal:
        case builtins::Builtin.INT32ARRAY.ordinal:
        case builtins::Builtin.UINT32ARRAY.ordinal:
        case builtins::Builtin.FLOAT32ARRAY.ordinal:
        case builtins::Builtin.FLOAT64ARRAY.ordinal:
        case builtins::Builtin.ARRAYBUFFER.ordinal:
        case builtins::Builtin.DATAVIEW.ordinal:
        case builtins::Builtin.PROXY.ordinal:
            return true;
        case builtins::Builtin.PROXY_CALL.ordinal:
            // Callable proxy trampoline: constructability mirrors the proxy
            // target and is checked via flags.constructable before dispatch.
            return true;
        case builtins::Builtin.ASYNC_FUNCTION.ordinal:
            // %AsyncFunction% / %AsyncGeneratorFunction% intrinsic constructor.
            return true;
        default:
            return false;
    }
}

fn TVal get_prop_with_proto(HObject* obj, void* key) {
    TVal? result = obj.get_prop_proto(key);
    if (try v = result) {
        return v;
    }
    TVal undef;
    undef.set_undefined();
    return undef;
}

// ============================================================================
// String helpers
// ============================================================================

/// Intern a raw byte slice into the VM's string table.
fn HString* intern_string(Vm* vm, char[] data) {
    return vm.heap.str_intern(data);
}

/// Return the interned typeof string for a TVal per ES spec.
fn HString* typeof_string(Vm* vm, TVal* val) {
    Heap* h = vm.heap;
    switch (val.get_tag()) {
        case UNDEFINED: return (HString*)h.strs[heap::BuiltinStr.UNDEFINED];
        case NULL_VAL:  return (HString*)h.strs[heap::BuiltinStr.OBJECT];
        case BOOLEAN:   return (HString*)h.strs[heap::BuiltinStr.BOOLEAN];
        case NUMBER:    return (HString*)h.strs[heap::BuiltinStr.NUMBER];
        case FASTINT:   return (HString*)h.strs[heap::BuiltinStr.NUMBER];
        case STRING:
            HString* hstr = (HString*)val.get_heapptr();
            if (hstr != null && hstr.is_symbol()) {
                return (HString*)h.strs[heap::BuiltinStr.SYMBOL];
            }
            return (HString*)h.strs[heap::BuiltinStr.STRING];
        case OBJECT:
            HObject* hobj = (HObject*)val.get_heapptr();
            if (hobj != null && hobj.is_callable()) {
                return (HString*)h.strs[heap::BuiltinStr.FUNCTION];
            }
            return (HString*)h.strs[heap::BuiltinStr.OBJECT];
        case LIGHTFUNC: return (HString*)h.strs[heap::BuiltinStr.FUNCTION];
        case BIGINT:    return (HString*)h.strs[heap::BuiltinStr.BIGINT];
        default:        return (HString*)h.strs[heap::BuiltinStr.UNDEFINED];
    }
}

// int_to_buf is defined in duktape::hstring and available via the module import.

/// Convert a double to an interned HString* using shortest round-trip formatting.
fn HString*? vm_number_to_string(Vm* vm, double val) {
    // ES5 §9.8.1: ToString(Infinity) = "Infinity", ToString(NaN) = "NaN"
    if (math::is_nan(val)) {
        return (HString*)vm.heap.strs[heap::BuiltinStr.NAN_STR];
    }
    if (math::is_inf(val)) {
        return (HString*)((val > 0.0)
            ? vm.heap.strs[heap::BuiltinStr.POSITIVE_INFINITY]
            : vm.heap.strs[heap::BuiltinStr.NEGATIVE_INFINITY]);
    }

    // ES5 §9.8.1: ToString(number) — -0 must produce "0", not "-0"
    if (val == 0.0) {
        return vm.heap.str_intern("0");
    }

    // ES5 §9.8.1 steps 5-7: integers with |val| < 10^21 use decimal notation
    if (val == math::trunc(val) && val > -1e21 && val < 1e21) {
        char[64] ibuf;
        int ilen = libc::snprintf(&ibuf, 64, "%.0f", val);
        if (ilen >= 0 && ilen < 64) {
            return vm.heap.str_intern(ibuf[:ilen]);
        }
    }

    // ES2015 §7.1.12.1 ToString(Number): QuickJS js_dtoa in FREE mode emits
    // the shortest round-trip decimal in spec format (decimal for 1e-6..1e21,
    // exponential outside, correct rounding — a truncate-and-retry loop can't
    // produce e.g. "7.300000000000001" from "7.3000000000000007").
    char[64] buf;
    char[dtoa_bindings::DTOA_FORMAT_TMP_SIZE] tmp;
    int len = dtoa_bindings::duktape_js_dtoa(&buf, val, 10, 0,
        dtoa_bindings::JS_DTOA_FORMAT_FREE, &tmp);
    if (len <= 0 || len >= 64) {
        return null;
    }
    return vm.heap.str_intern(buf[:len]);
}

/// Convert a BigInt's int128 value to an interned decimal HString*.
/// (BigInt.prototype.toString handles non-decimal radices separately.)
fn HString*? vm_bigint_to_string(Vm* vm, int128 val) {
    char[48] buf;
    char[] s = hbigint::int128_to_decimal(val, buf[..]);
    return vm.heap.str_intern(s);
}

/// Convert a FASTINT to an interned HString* using the small-integer cache
/// for values 0–255, or fast int-to-string conversion for larger values.
fn HString*? vm_fastint_to_string(Vm* vm, long val) {
    HString* s = vm.heap.int_to_hstring(val);
    if (s == null) return null;
    return s;
}

/// Convert a TVal to an interned HString*.
fn HString*? vm_to_string(Vm* vm, TVal* val) {
    Heap* h = vm.heap;
    switch (val.get_tag()) {
        case STRING: {
            HString* hstr = (HString*)val.get_heapptr();
            // ES6 §7.1.12: ToString(Symbol) throws TypeError
            if (hstr != null && hstr.is_symbol()) {
                vm_set_type_error(vm, "Cannot convert a Symbol value to a string");
                return null;
            }
            return hstr;
        }
        case NUMBER:
            return vm_number_to_string(vm, val.get_number());
        case FASTINT:
            return vm_fastint_to_string(vm, val.get_fastint());
        case BIGINT:
            return vm_bigint_to_string(vm, val.get_bigint());
        case BOOLEAN:
            if (val.get_boolean()) {
                return (HString*)h.strs[heap::BuiltinStr.TRUE];
            }
            return (HString*)h.strs[heap::BuiltinStr.FALSE];
        case UNDEFINED:
            return (HString*)h.strs[heap::BuiltinStr.UNDEFINED];
        case NULL_VAL:
            return (HString*)h.strs[heap::BuiltinStr.NULL_STR];
        case OBJECT: {
            // ES2015 §7.1.12 ToString(argument): let primValue be
            // ? ToPrimitive(argument, string); return ? ToString(primValue).
            // Delegates to to_primitive_value's generic-object path (hint
            // "string") rather than a standalone toString()-only lookup, so
            // getter-defined toString/valueOf (Object.defineProperty
            // accessors) and the toString-then-valueOf fallback order are
            // both honored — not just a plain data-property toString.
            if (vm != null && vm.heap.call_fn != null && val.get_heapptr() != null) {
                TVal prim = to_primitive_value(vm, val, 1);
                if (vm.throw_pending) return null;
                if (prim.get_tag() != OBJECT) {
                    if (try result_str = vm_to_string(vm, &prim)) {
                        return result_str;
                    }
                    return null;
                }
            }
            return (HString*)h.strs[heap::BuiltinStr.OBJECT_OBJECT];
        }
        case LIGHTFUNC: {
            // ES2019 §19.2.3.5: ToString on a built-in function must return a
            // NativeFunction string. Invoke Function.prototype.toString with
            // the lightfunc as `this` so the existing builtin handles naming.
            if (vm != null && vm.heap.call_fn != null) {
                HString* to_str_key = (HString*)h.strs[heap::BuiltinStr.TO_STRING];
                if (to_str_key != null) {
                    TVal lf_tv = *val;
                    // Lightfuncs inherit from Function.prototype; get toString there.
                    if (h.function_proto != null) {
                        if (try toString_fn = h.function_proto.get_prop(to_str_key)) {
                            if (toString_fn.is_lightfunc()) {
                                TVal result = h.call_fn(vm, toString_fn, null, 0, lf_tv);
                                if (!vm_check_call_fn_error(vm)) {
                                    if (try rs = vm_to_string(vm, &result)) return rs;
                                }
                                // If the call failed, clear error and fall through to fallback.
                                vm.heap.has_error = false;
                            }
                        }
                    }
                }
            }
            return (HString*)h.strs[heap::BuiltinStr.FUNCTION_STR];
        }
        default:
            return (HString*)h.strs[heap::BuiltinStr.UNDEFINED];
    }
}

/// Returns true for ECMAScript white-space and line-terminator characters
/// (ASCII subset: Tab, VT, FF, Space, NBSP, LF, CR).
fn bool is_ecma_whitespace(char c) @inline {
    return c == 0x09 || c == 0x0B || c == 0x0C
        || c == 0x20 || c == 0xA0
        || c == 0x0A || c == 0x0D;
}

/// ECMAScript ToNumber for strings (§7.1.3.1).
///
/// Converts an HString* to a double, trimming ECMAScript whitespace and
/// parsing numeric literals (decimal, hex, Infinity).  Returns NaN when
/// the string does not represent a valid numeric literal.
fn double hstring_to_number(HString* hstr) {
    char* cstr = hstr.get_cstr();
    uint blen = hstr.blen;

    // --- skip leading ECMAScript whitespace (CESU-8 aware) ---
    uint start = 0;
    while (start < blen) {
        uint seq_len = 0;
        uint cp = builtins::decode_codepoint_at(cstr, start, blen, &seq_len);
        if (seq_len == 0 || !builtins::is_ecma_ws_codepoint(cp)) break;
        start += seq_len;
    }

    // Empty or all-whitespace -> +0
    if (start == blen) {
        return 0.0;
    }

    char* p = cstr + start;

    // --- Infinity / -Infinity / +Infinity ---
    if (libc::strcmp((ZString)p, "Infinity") == 0)   return double::inf;
    if (libc::strcmp((ZString)p, "+Infinity") == 0)  return double::inf;
    if (libc::strcmp((ZString)p, "-Infinity") == 0)  return -double::inf;

    // --- Hex integer literal (0x...) ---
    if (p[0] == '0' && (p[1] == 'x' || p[1] == 'X')) {
        uint j = 2;
        // Require at least one hex digit (ES2015 §7.1.3.1)
        if (p[j] == 0 || !((p[j] >= '0' && p[j] <= '9') || (p[j] >= 'a' && p[j] <= 'f') || (p[j] >= 'A' && p[j] <= 'F'))) {
            return double::nan;
        }
        ulong val = 0;
        while (p[j] != 0) {
            char c = p[j];
            uint digit;
            if      (c >= '0' && c <= '9') { digit = (uint)(c - '0'); }
            else if (c >= 'a' && c <= 'f') { digit = (uint)(c - 'a' + 10); }
            else if (c >= 'A' && c <= 'F') { digit = (uint)(c - 'A' + 10); }
            else { break; }   // non-hex terminates the literal

            val = (val << 4) | digit;
            j++;
        }
        // Trailing must be whitespace
        while (p[j] != 0) {
            if (!is_ecma_whitespace(p[j])) return double::nan;
            j++;
        }
        return (double)val;
    }

    // --- Decimal via libc::strtod ---
    char* endptr;
    double result = libc::strtod(p, &endptr);

    // Nothing was consumed -> NaN
    if (endptr == p) {
        return double::nan;
    }

    // strtod accepts case-insensitive "infinity" but ES requires exact case
    if (result == double::inf || result == -double::inf) {
        if (libc::strcmp((ZString)p, "Infinity") != 0 &&
            libc::strcmp((ZString)p, "+Infinity") != 0 &&
            libc::strcmp((ZString)p, "-Infinity") != 0) {
            return double::nan;
        }
    }

    // Trailing characters must be whitespace only
    while (*endptr != 0) {
        if (!is_ecma_whitespace(*endptr)) {
            return double::nan;
        }
        endptr++;
    }

    return result;
}

/// Extract [[PrimitiveValue]] from Boolean/Number/String wrapper objects.
/// After calling vm_to_number, check and throw if ToPrimitive failed.
/// Returns false if a throw was initiated (caller should break out of handler).
fn bool vm_check_to_number_throw(Vm* vm, Activation* act, Instruction** curr_pc, bool* needs_restart) {
    if (vm.throw_pending) {
        vm.throw_pending = false;
        return vm_throw_value(vm, vm.throw_value, act, curr_pc, needs_restart);
    }
    return true;
}

/// Helper: create a TypeError and set vm.throw_pending for deferred throw.
/// The opcode handler must check vm.throw_pending and call vm_throw_value.
fn void vm_set_toprimitive_error(Vm* vm) {
    HObject*? err_raw = vm.heap.alloc_object(hobject::ObjClass.ERROR);
    if (try err = err_raw) {
        err.prototype = vm.heap.type_err_proto;
        HString* msg_str = intern_string(vm, "Cannot convert object to primitive value");
        if (msg_str != null) {
            TVal msg_val;
            msg_val.set_string(msg_str);
            HString* msg_key = intern_string(vm, "message");
            if (msg_key != null) {
                err.put_prop(msg_key, msg_val, hobject::PROP_FLAGS_WEC);
            }
        }
        TVal err_val;
        err_val.set_object(err);
        vm.heap.tval_copy_ref(&vm.throw_value, &err_val);
    }
    vm.throw_pending = true;
}

/// Helper: create a TypeError with a custom message and set vm.throw_pending.
fn void vm_set_type_error(Vm* vm, char[] msg) {
    HObject*? err_raw = vm.heap.alloc_object(hobject::ObjClass.ERROR);
    if (try err = err_raw) {
        err.prototype = vm.heap.type_err_proto;
        HString* msg_str = intern_string(vm, msg);
        if (msg_str != null) {
            TVal msg_val;
            msg_val.set_string(msg_str);
            HString* msg_key = intern_string(vm, "message");
            if (msg_key != null) {
                err.put_prop(msg_key, msg_val, hobject::PROP_FLAGS_WEC);
            }
        }
        TVal err_val;
        err_val.set_object(err);
        vm.heap.tval_copy_ref(&vm.throw_value, &err_val);
    }
    vm.throw_pending = true;
}

/// Helper: create a RangeError with a custom message and set vm.throw_pending.
fn void vm_set_range_error(Vm* vm, char[] msg) {
    HObject*? err_raw = vm.heap.alloc_object(hobject::ObjClass.ERROR);
    if (try err = err_raw) {
        err.prototype = vm.heap.range_err_proto;
        HString* msg_str = intern_string(vm, msg);
        if (msg_str != null) {
            TVal msg_val;
            msg_val.set_string(msg_str);
            HString* msg_key = intern_string(vm, "message");
            if (msg_key != null) {
                err.put_prop(msg_key, msg_val, hobject::PROP_FLAGS_WEC);
            }
        }
        TVal err_val;
        err_val.set_object(err);
        vm.heap.tval_copy_ref(&vm.throw_value, &err_val);
    }
    vm.throw_pending = true;
}

/// Check if call_fn caused an unhandled throw inside the called function.
/// When call_fn invokes a compiled JS function that throws and no catcher
/// is found, vm.has_error is set and vm.return_val contains the thrown error.
/// This helper propagates that error into the deferred throw mechanism so
/// the outer opcode handler can properly propagate it.
/// Returns true if an error was detected (caller should return early).
fn bool vm_check_call_fn_error(Vm* vm) @inline {
    // vm.has_error is cleared at the call_fn/construct_fn boundary (to keep
    // it from leaking across into the caller's own VM opcode dispatch);
    // heap.has_error is the persistent flag callers should observe.
    if (vm.has_error || vm.heap.has_error) {
        vm.heap.tval_copy_ref(&vm.throw_value, &vm.return_val);
        vm.throw_pending = true;
        vm.has_error = false;
        vm.heap.has_error = false;
        return true;
    }
    return false;
}

/// ES5 §9.1 ToPrimitive — hint "string" for +, "number" for arithmetic.
/// Calls Symbol.toPrimitive first (ES6 §7.1.1), then valueOf/toString.
/// Sets vm.throw_pending if both valueOf and toString return non-primitives.
/// hint: 0 = default, 1 = string, 2 = number
fn TVal to_primitive_value(Vm* vm, TVal* val, int hint = 0) {
    if (val.is_object() && val.get_heapptr() != null) {
        HObject* obj = (HObject*)val.get_heapptr();
        hobject::ObjClass cls = obj.get_class();
        // Fast path: wrapper objects unwrap directly
        if (cls == hobject::ObjClass.BOOLEAN &&
            (*obj.extra_ptr()).prim.primitive_value.is_boolean()) {
            TVal result;
            result.set_boolean((*obj.extra_ptr()).prim.primitive_value.get_boolean());
            return result;
        }
        if (cls == hobject::ObjClass.NUMBER &&
            ((*obj.extra_ptr()).prim.primitive_value.is_number() || (*obj.extra_ptr()).prim.primitive_value.is_fastint())) {
            TVal result;
            result.set_number((*obj.extra_ptr()).prim.primitive_value.get_number_or_fastint());
            return result;
        }
        if (cls == hobject::ObjClass.STRING &&
            (*obj.extra_ptr()).prim.primitive_value.is_string()) {
            TVal result;
            result.set_string((*obj.extra_ptr()).prim.primitive_value.get_heapptr());
            return result;
        }
        // Fast path: Symbol wrapper → unwrap directly. Symbol.prototype[@@toPrimitive]
        // ignores its hint and always returns [[SymbolData]] unwrapped, so skipping
        // straight to the primitive is equivalent to calling it — but ONLY while
        // that well-known method is still the original built-in. If it has been
        // redefined/deleted, ToPrimitive must fall through to the exotic-method
        // check below (which sees it's gone) and then to OrdinaryToPrimitive,
        // which for hint "string" tries toString() (≠ the raw symbol) first.
        if (cls == hobject::ObjClass.SYMBOL &&
            (*obj.extra_ptr()).prim.primitive_value.is_string()
            && vm != null && builtins::symbol_proto_toprimitive_is_original(vm.heap)) {
            HString* s = (HString*)(*obj.extra_ptr()).prim.primitive_value.get_heapptr();
            if (s != null && s.is_symbol()) {
                TVal result;
                result.set_string(s);
                return result;
            }
        }
        // Check Symbol.toPrimitive (ES6 §7.1.1)
        if (vm != null && vm.heap.call_fn != null && vm.heap.toprimitive_symbol != null) {
            Heap* h = vm.heap;
            HString* toprim_key = h.toprimitive_symbol;
            // Use find_accessor_proto to properly invoke getters (Object.defineProperty)
            hobject::AccessorResult acc = obj.find_accessor_proto(toprim_key, true);
            TVal toprim_fn;
            if (acc.found) {
                // Getter-defined Symbol.toPrimitive: invoke the getter
                TVal getter_this;
                getter_this.set_object(acc.this_obj);
                toprim_fn = h.call_fn(vm, acc.accessor_fn, null, 0, getter_this);
                if (vm_check_call_fn_error(vm)) return *val;
            } else {
                // Data property: try get_prop_proto as fallback
                TVal? toprim_val = obj.get_prop_proto(toprim_key);
                if (try tv = toprim_val) {
                    toprim_fn = tv;
                } else {
                    toprim_fn.set_undefined();
                }
            }
            bool toprim_callable = toprim_fn.is_lightfunc() ||
                (toprim_fn.is_object() && toprim_fn.get_heapptr() != null && ((HObject*)toprim_fn.get_heapptr()).is_callable());
            if (toprim_callable) {
                // Call Symbol.toPrimitive(obj, hint) — use "default" for general ToPrimitive,
                // but "string" for + operator (ES5 §11.6.1).
                HString* hint_str = (hint == 1)
                    ? intern_string(vm, "string")
                    : ((hint == 2)
                        ? intern_string(vm, "number")
                        : intern_string(vm, "default"));
                TVal hint_val;
                hint_val.set_string(hint_str);
                TVal[1] hint_args;
                hint_args[0] = hint_val;
                TVal prim = h.call_fn(vm, toprim_fn, &hint_args[0], 1, *val);
                if (vm_check_call_fn_error(vm)) return *val;
                if (!prim.is_object()) return prim;
                // ES6 §7.1.1 step 6.d: result is Object → TypeError
                // Signal caller via throw_pending (checked after return)
                vm_set_toprimitive_error(vm);
                return *val;
            } else if (!toprim_fn.is_undefined() && !toprim_fn.is_null()) {
                // ES6 §7.1.1 step 5a / §7.3.13 Call: exoticToPrim is present
                // but not callable — Call(exoticToPrim, ...) throws TypeError.
                vm_set_type_error(vm, "Symbol.toPrimitive is not a function");
                return *val;
            }
        }
        // Generic objects: call valueOf(), then toString()
        // ES5 §9.1: hint "string" → toString first, then valueOf;
        //           hint "number" (default) → valueOf first, then toString.
        // Date objects override [[DefaultValue]] to always use "string" hint.
        if (vm != null && vm.heap.call_fn != null) {
            Heap* h = vm.heap;
            bool is_date = (cls == hobject::ObjClass.DATE);
            // Date always uses toString first; other objects depend on hint.
            bool use_string_first = is_date || (hint == 1);
            HString* first_key = use_string_first
                ? (HString*)h.strs[heap::BuiltinStr.TO_STRING]
                : (HString*)h.strs[heap::BuiltinStr.VALUE_OF];
            HString* second_key = use_string_first
                ? (HString*)h.strs[heap::BuiltinStr.VALUE_OF]
                : (HString*)h.strs[heap::BuiltinStr.TO_STRING];
            // Helper to resolve and call a toString/valueOf method, handling both
            // data properties and accessor (getter) properties in the prototype chain.
            // Uses get_prop_or_accessor_proto so that accessor getters are invoked first
            // (needed for ToPrimitive on objects with getter-defined toString/valueOf).
            if (first_key != null) {
                TVal first_fn;
                bool first_found = false;
                hobject::PropLookupResult first_res = obj.get_prop_or_accessor_proto((void*)first_key, true);
                if (first_res.kind == hobject::PropLookupKind.PROP_DATA) {
                    first_fn = first_res.data_val;
                    first_found = true;
                } else if (first_res.kind == hobject::PropLookupKind.PROP_ACCESSOR) {
                    TVal getter_this;
                    getter_this.set_object(first_res.acc.this_obj);
                    first_fn = h.call_fn(vm, first_res.acc.accessor_fn, null, 0, getter_this);
                    if (vm_check_call_fn_error(vm)) return *val;
                    first_found = true;
                }
                if (first_found) {
                    if (first_fn.is_lightfunc() || (first_fn.is_object() && first_fn.get_heapptr() != null && ((HObject*)first_fn.get_heapptr()).is_callable())) {
                        TVal prim = h.call_fn(vm, first_fn, null, 0, *val);
                        if (vm_check_call_fn_error(vm)) return *val;
                        if (!prim.is_object()) return prim;
                    }
                }
            }
            if (second_key != null) {
                TVal second_fn;
                bool second_found = false;
                hobject::PropLookupResult second_res = obj.get_prop_or_accessor_proto((void*)second_key, true);
                if (second_res.kind == hobject::PropLookupKind.PROP_DATA) {
                    second_fn = second_res.data_val;
                    second_found = true;
                } else if (second_res.kind == hobject::PropLookupKind.PROP_ACCESSOR) {
                    TVal getter_this;
                    getter_this.set_object(second_res.acc.this_obj);
                    second_fn = h.call_fn(vm, second_res.acc.accessor_fn, null, 0, getter_this);
                    if (vm_check_call_fn_error(vm)) return *val;
                    second_found = true;
                }
                if (second_found) {
                    if (second_fn.is_lightfunc() || (second_fn.is_object() && second_fn.get_heapptr() != null && ((HObject*)second_fn.get_heapptr()).is_callable())) {
                        TVal prim = h.call_fn(vm, second_fn, null, 0, *val);
                        if (vm_check_call_fn_error(vm)) return *val;
                        if (!prim.is_object()) return prim;
                    }
                }
            }
            // ES5 §8.12.8 step 7: neither valueOf nor toString returned a primitive
            vm_set_toprimitive_error(vm);
        }
    }
    return *val;
}

