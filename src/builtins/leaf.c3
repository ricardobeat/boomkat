// Leaf entries: the common case of a builtin answered without a frame or a
// BuiltinContext. A leaf never coerces, throws, enters JavaScript or collects;
// it either stores the builtin's result into `dst` (a frame register) and
// returns true, or returns false having changed nothing, and the caller runs
// the builtin in full. Allocation only marks a collection due.
module boomkat::builtins;
import boomkat::types;
import boomkat::hstring;
import boomkat::heap;
import boomkat::hobject;
import std::math;

alias LeafFn = fn bool(Heap* h, TVal this_val, TVal* args, uint argc, TVal* dst);

LeafFn[Builtin::values.len] leaf_table @private;

// The leaf of builtin number `builtin`, or null.
fn LeafFn leaf_of(uint builtin) @inline => builtin < leaf_table.len ? leaf_table[builtin] : null;

fn void init_leaf_table() {
    foreach (i, &leaf : leaf_table) *leaf = leaf_entry((Builtin)i);
}

fn LeafFn leaf_entry(Builtin builtin) @private {
    switch (builtin) {
        case STRING_PROTO_CHARAT: return &leaf_char_at;
        case STRING_PROTO_CHARCODEAT: return &leaf_char_code_at;
        case STRING_FROMCHARCODE: return &leaf_from_char_code;
        case STRING_PROTO_INDEXOF: return &leaf_index_of;
        case STRING_PROTO_LASTINDEXOF: return &leaf_last_index_of;
        case STRING_PROTO_SUBSTRING: return &leaf_substring;
        case STRING_PROTO_SLICE: return &leaf_string_slice;
        case STRING_PROTO_TOUPPERCASE: return &leaf_to_upper_case;
        case STRING_PROTO_TOLOWERCASE: return &leaf_to_lower_case;
        case ARRAY_PROTO_PUSH: return &leaf_push;
        case ARRAY_PROTO_POP: return &leaf_pop;
        case ARRAY_ISARRAY: return &leaf_is_array;
        case PARSE_INT: return &leaf_parse_int;
        case PARSE_FLOAT: return &leaf_parse_float;
        case IS_NAN: return &leaf_is_nan;
        case MATH_ABS: return &leaf_math_abs;
        case MATH_FLOOR: return &leaf_math_floor;
        case MATH_CEIL: return &leaf_math_ceil;
        case MATH_ROUND: return &leaf_math_round;
        case MATH_SQRT: return &leaf_math_sqrt;
        case MATH_MIN: return &leaf_math_min;
        case MATH_MAX: return &leaf_math_max;
        case MATH_POW: return &leaf_math_pow;
        default: return null;
    }
}

macro HString* leaf_string(TVal v) @local {
    if (!v.is_string()) return null;
    HString* s = (HString*)v.get_heapptr();
    return s != null && !s.is_symbol() ? s : null;
}

macro bool leaf_number(TVal v, double* out) @local {
    if (v.is_fastint()) {
        *out = (double)v.get_fastint();
        return true;
    }
    if (!v.is_number()) return false;
    *out = v.get_number();
    return true;
}

// An integer argument in [lo, hi], absent meaning `absent`.
macro bool leaf_int(TVal* args, uint argc, uint i, long absent, long* out) @local {
    if (i >= argc || args[i].is_undefined()) {
        *out = absent;
        return true;
    }
    if (!args[i].is_fastint()) return false;
    *out = args[i].get_fastint();
    return true;
}

macro void leaf_set_string(Heap* h, TVal* dst, HString* s) @local => h.set_reg_string(dst, s);

// The cached one-unit string of `unit`.
macro bool leaf_unit(Heap* h, uint unit, TVal* dst) @local {
    if (unit >= heap::UNIT_STR_CACHE_SIZE || h.unit_strs[unit] == null) return false;
    h.set_reg_string(dst, h.unit_strs[unit]);
    return true;
}

// A number result: an integer one as a fastint, as the builtins' results are.
macro void leaf_set_number(TVal* dst, double d) @local {
    if (d == math::trunc(d) && math::abs(d) < 0x1p47 && !(d == 0 && math::signbit(d) != 0)) {
        dst.set_fastint((long)d);
    } else {
        dst.set_number(d);
    }
}

fn bool leaf_char_at(Heap* h, TVal this_val, TVal* args, uint argc, TVal* dst) {
    HString* s = leaf_string(this_val);
    long at;
    if (s == null || !leaf_int(args, argc, 0, 0, &at)) return false;
    if (at < 0 || at >= (long)s.unit_len()) {
        leaf_set_string(h, dst, h.str(heap::BuiltinStr.EMPTY));
        return true;
    }
    return leaf_unit(h, s.unit_at((uint)at), dst);
}

fn bool leaf_char_code_at(Heap* h, TVal this_val, TVal* args, uint argc, TVal* dst) {
    HString* s = leaf_string(this_val);
    long at;
    if (s == null || !leaf_int(args, argc, 0, 0, &at)) return false;
    if (at < 0 || at >= (long)s.unit_len()) {
        dst.set_number(double::nan);
    } else {
        dst.set_fastint((long)s.unit_at((uint)at));
    }
    return true;
}

fn bool leaf_from_char_code(Heap* h, TVal this_val, TVal* args, uint argc, TVal* dst) {
    if (argc != 1 || !args[0].is_fastint()) return false;
    return leaf_unit(h, (uint)(args[0].get_fastint() & 0xFFFF), dst);
}

fn bool leaf_index_of(Heap* h, TVal this_val, TVal* args, uint argc, TVal* dst) {
    HString* s = leaf_string(this_val);
    HString* needle = argc > 0 ? leaf_string(args[0]) : null;
    long from;
    if (s == null || needle == null || !leaf_int(args, argc, 1, 0, &from)) return false;
    uint len = s.unit_len();
    uint at = from <= 0 ? 0 : (from >= (long)len ? len : (uint)from);
    dst.set_fastint((long)hstring::find_units(s, needle, at));
    return true;
}

fn bool leaf_last_index_of(Heap* h, TVal this_val, TVal* args, uint argc, TVal* dst) {
    HString* s = leaf_string(this_val);
    HString* needle = argc == 1 ? leaf_string(args[0]) : null;
    if (s == null || needle == null) return false;
    dst.set_fastint((long)hstring::rfind_units(s, needle, s.unit_len()));
    return true;
}

fn bool leaf_substring(Heap* h, TVal this_val, TVal* args, uint argc, TVal* dst) {
    HString* s = leaf_string(this_val);
    if (s == null) return false;
    long len = (long)s.unit_len();
    long start;
    long end;
    if (!leaf_int(args, argc, 0, 0, &start) || !leaf_int(args, argc, 1, len, &end)) return false;
    start = start < 0 ? 0 : (start > len ? len : start);
    end = end < 0 ? 0 : (end > len ? len : end);
    leaf_set_string(h, dst, h.str_slice(s, (uint)min(start, end), (uint)max(start, end)));
    return true;
}

fn bool leaf_string_slice(Heap* h, TVal this_val, TVal* args, uint argc, TVal* dst) {
    HString* s = leaf_string(this_val);
    if (s == null) return false;
    long len = (long)s.unit_len();
    long start;
    long end;
    if (!leaf_int(args, argc, 0, 0, &start) || !leaf_int(args, argc, 1, len, &end)) return false;
    if (start < 0) start += len;
    if (end < 0) end += len;
    start = start < 0 ? 0 : (start > len ? len : start);
    end = end < 0 ? 0 : (end > len ? len : end);
    leaf_set_string(h, dst, h.str_slice(s, (uint)start, (uint)(end < start ? start : end)));
    return true;
}

// The case mapping of a one-unit ASCII string, or of one that has no letter
// to map, which is the receiver itself.
macro bool leaf_ascii_case(Heap* h, TVal this_val, TVal* dst, bool upper) @local {
    HString* s = leaf_string(this_val);
    if (s == null || !s.is_ascii()) return false;
    uint len = s.unit_len();
    char[] text = s.latin1();
    char lo = upper ? 'a' : 'A';
    char hi = upper ? 'z' : 'Z';
    for (uint i = 0; i < len; i++) {
        char c = text[i];
        if (c < lo || c > hi) continue;
        if (len != 1) return false;
        return leaf_unit(h, upper ? c - 32 : c + 32, dst);
    }
    leaf_set_string(h, dst, s);
    return true;
}

fn bool leaf_to_upper_case(Heap* h, TVal this_val, TVal* args, uint argc, TVal* dst) => leaf_ascii_case(h, this_val, dst, true);
fn bool leaf_to_lower_case(Heap* h, TVal this_val, TVal* args, uint argc, TVal* dst) => leaf_ascii_case(h, this_val, dst, false);

// Whether `obj` is an ordinary extensible array with a writable length and
// only dense elements, whose length lives in the array itself.
fn bool leaf_plain_array(HObject* obj) @inline {
    return obj.get_class() == hobject::ObjClass.ARRAY && obj.prop_count == 0 && obj.flags.extensible
        && obj.flags.array_len_writable && !obj.flags.has_indexed_named_prop;
}

// Array.prototype.push of one present value onto a plain array whose next
// slot is a hole of the dense part (or past it), with no prototype that could
// hold an element. The new length, or -1 having done nothing.
fn long array_push_dense(Heap* h, HObject* obj, TVal v) {
    if (!leaf_plain_array(obj) || v.is_undefined()) return -1;
    uint len = *obj.array_len_ptr();
    if (len >= 0x1000000u) return -1;
    if (len < obj.array_size) {
        hobject::PropValue* dense = obj.array_part();
        if (dense == null || !dense[len].get().is_undefined()) return -1;
    } else if (obj.array_size != 0 && obj.array_part() == null) {
        return -1;
    }
    HObject* array_proto = h.array_proto;
    HObject* object_proto = h.object_proto;
    if (array_proto == null || object_proto == null || obj.prototype != array_proto
        || array_proto.get_class() != hobject::ObjClass.ARRAY
        || object_proto.get_class() != hobject::ObjClass.OBJECT
        || array_proto.prototype != object_proto || object_proto.prototype != null
        || array_proto.flags.has_indexed_named_prop || array_proto.array_used > 0
        || object_proto.flags.has_indexed_named_prop || object_proto.array_used > 0) return -1;
    if (!obj.set_array_idx(len, v, h)) return -1;
    *obj.array_len_ptr() = len + 1;
    return (long)len + 1;
}

fn bool leaf_push(Heap* h, TVal this_val, TVal* args, uint argc, TVal* dst) {
    if (argc != 1 || !this_val.is_object()) return false;
    long len = array_push_dense(h, (HObject*)this_val.get_heapptr(), args[0]);
    if (len < 0) return false;
    dst.set_fastint(len);
    return true;
}

// Array.prototype.pop of a present last element of the dense part.
fn bool leaf_pop(Heap* h, TVal this_val, TVal* args, uint argc, TVal* dst) {
    if (!this_val.is_object()) return false;
    HObject* obj = (HObject*)this_val.get_heapptr();
    if (!leaf_plain_array(obj) || obj.array_part() == null) return false;
    uint len = *obj.array_len_ptr();
    if (len == 0 || len > obj.array_size) return false;
    TVal elem = obj.array_part()[len - 1].get();
    if (elem.is_undefined()) return false;
    // The popped value keeps the slot's count until the register takes it.
    if (elem.is_heap_allocated() && elem.get_heapptr() != null) ((types::HeapHeader*)elem.get_heapptr()).incref();
    TVal hole;
    hole.set_undefined();
    obj.set_array_idx(len - 1, hole, h);
    *obj.array_len_ptr() = len - 1;
    h.move_tval_ref(dst, &elem);
    return true;
}

fn bool leaf_is_array(Heap* h, TVal this_val, TVal* args, uint argc, TVal* dst) {
    if (argc == 0) return false;
    if (args[0].is_object()) {
        HObject* obj = (HObject*)args[0].get_heapptr();
        if (obj == null || obj.flags.exotic_proxyobj) return false;
        dst.set_boolean(obj.get_class() == hobject::ObjClass.ARRAY);
    } else {
        dst.set_boolean(false);
    }
    return true;
}

// parseInt of a number whose decimal string has no exponent: its integer part.
fn bool leaf_parse_int(Heap* h, TVal this_val, TVal* args, uint argc, TVal* dst) {
    if (argc != 1) return false;
    TVal x = args[0];
    if (x.is_fastint()) {
        *dst = x;
        return true;
    }
    if (!x.is_number()) return false;
    double d = x.get_number();
    double size = math::abs(d);
    if (!(size >= 1e-6 && size < 0x1p53)) return false;
    double whole = math::trunc(d);
    if (whole != 0 && size < 0x1p31) {
        dst.set_fastint((long)whole);
    } else {
        dst.set_number(whole);
    }
    return true;
}

const double[23] LEAF_POW10 = { 1e0, 1e1, 1e2, 1e3, 1e4, 1e5, 1e6, 1e7, 1e8, 1e9, 1e10, 1e11,
    1e12, 1e13, 1e14, 1e15, 1e16, 1e17, 1e18, 1e19, 1e20, 1e21, 1e22 };

// parseFloat of a number, or of a string that is wholly `-?digits[.digits]`
// with at most 15 digits: both the digits and the power of ten are exact, so
// one division rounds correctly.
fn bool leaf_parse_float(Heap* h, TVal this_val, TVal* args, uint argc, TVal* dst) {
    if (argc != 1) return false;
    TVal x = args[0];
    if (x.is_fastint()) {
        *dst = x;
        return true;
    }
    if (x.is_number()) {
        double d = x.get_number();
        if (d == 0) d = 0;
        dst.set_number(d);
        return true;
    }
    HString* s = leaf_string(x);
    if (s == null || !s.is_ascii()) return false;
    char[] text = s.latin1();
    uint len = s.unit_len();
    uint i = 0;
    bool negative = len > 0 && text[0] == '-';
    if (negative) i++;
    ulong mantissa = 0;
    uint digits = 0;
    int scale = -1;
    for (; i < len; i++) {
        char c = text[i];
        if (c == '.' && scale < 0) {
            scale = 0;
            continue;
        }
        if (c < '0' || c > '9') return false;
        mantissa = mantissa * 10 + (ulong)(c - '0');
        if (++digits > 15) return false;
        if (scale >= 0) scale++;
    }
    if (digits == 0) return false;
    double d = (double)mantissa;
    if (scale > 0) d /= LEAF_POW10[scale];
    if (negative) d = -d;
    leaf_set_number(dst, d);
    return true;
}

fn bool leaf_is_nan(Heap* h, TVal this_val, TVal* args, uint argc, TVal* dst) {
    double d;
    if (argc == 0 || !leaf_number(args[0], &d)) return false;
    dst.set_boolean(math::is_nan(d));
    return true;
}

enum LeafMath : char @local { ABS, FLOOR, CEIL, SQRT }

fn bool leaf_math1(TVal* args, uint argc, TVal* dst, LeafMath op) @local {
    double x;
    if (argc != 1 || !leaf_number(args[0], &x)) return false;
    switch (op) {
        case ABS: x = math::abs(x);
        case FLOOR: x = math::floor(x);
        case CEIL: x = math::ceil(x);
        case SQRT: x = math::sqrt(x);
    }
    leaf_set_number(dst, x);
    return true;
}

fn bool leaf_math_abs(Heap* h, TVal this_val, TVal* args, uint argc, TVal* dst) => leaf_math1(args, argc, dst, ABS);
fn bool leaf_math_floor(Heap* h, TVal this_val, TVal* args, uint argc, TVal* dst) => leaf_math1(args, argc, dst, FLOOR);
fn bool leaf_math_ceil(Heap* h, TVal this_val, TVal* args, uint argc, TVal* dst) => leaf_math1(args, argc, dst, CEIL);
fn bool leaf_math_sqrt(Heap* h, TVal this_val, TVal* args, uint argc, TVal* dst) => leaf_math1(args, argc, dst, SQRT);
// Math.round: the nearest integer, a half rounding up, keeping a negative zero.
fn bool leaf_math_round(Heap* h, TVal this_val, TVal* args, uint argc, TVal* dst) {
    double x;
    if (argc != 1 || !leaf_number(args[0], &x)) return false;
    double r = math::floor(x);
    if (x - r >= 0.5) r += 1;
    if (r == 0 && (x < 0 || math::signbit(x) != 0)) r = -0.0;
    leaf_set_number(dst, math::is_nan(x) || math::is_inf(x) ? x : r);
    return true;
}

// Math.min / max of two numbers; a NaN or a pair of zeros keeps the general path.
macro bool leaf_min_max(TVal* args, uint argc, TVal* dst, bool max) @local {
    double a;
    double b;
    if (argc != 2 || !leaf_number(args[0], &a) || !leaf_number(args[1], &b)) return false;
    if (math::is_nan(a) || math::is_nan(b) || (a == 0 && b == 0)) return false;
    leaf_set_number(dst, max ? (a > b ? a : b) : (a < b ? a : b));
    return true;
}

fn bool leaf_math_min(Heap* h, TVal this_val, TVal* args, uint argc, TVal* dst) => leaf_min_max(args, argc, dst, false);
fn bool leaf_math_max(Heap* h, TVal this_val, TVal* args, uint argc, TVal* dst) => leaf_min_max(args, argc, dst, true);

fn bool leaf_math_pow(Heap* h, TVal this_val, TVal* args, uint argc, TVal* dst) {
    double a;
    double b;
    if (argc != 2 || !leaf_number(args[0], &a) || !leaf_number(args[1], &b)) return false;
    // C's pow answers 1 where JavaScript answers NaN.
    if (math::is_nan(b) || ((a == 1 || a == -1) && math::is_inf(b))) return false;
    leaf_set_number(dst, math::pow(a, b));
    return true;
}
