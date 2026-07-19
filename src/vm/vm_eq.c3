module duktape::vm;

import duktape::types;
import duktape::hstring;
import duktape::hbigint;
import std::math;

fn bool abstract_eq(Vm* vm, TVal* a, TVal* b) {
    // Same type -> strict equality
    if (a.get_tag() == b.get_tag()) {
        return strict_eq(a, b);
    }

    // null/undefined pair
    if ((a.is_null() && b.is_undefined()) ||
        (a.is_undefined() && b.is_null())) {
        return true;
    }

    // NUMBER/FASTINT: treat as same "numeric" type
    if (a.is_number() && b.is_fastint()) {
        return a.get_number() == (double)b.get_fastint();
    }
    if (a.is_fastint() && b.is_number()) {
        return (double)a.get_fastint() == b.get_number();
    }

    // Boolean -> ToNumber
    if (a.is_boolean()) {
        TVal a_num;
        a_num.set_number(a.get_boolean() ? 1.0 : 0.0);
        return abstract_eq(vm, &a_num, b);
    }
    if (b.is_boolean()) {
        TVal b_num;
        b_num.set_number(b.get_boolean() ? 1.0 : 0.0);
        return abstract_eq(vm, a, &b_num);
    }

    // String + Number -> ToNumber(string)
    if (a.is_string() && (b.is_number() || b.is_fastint())) {
        double num = hstring_to_number((HString*)a.get_heapptr());
        if (b.is_fastint()) return num == (double)b.get_fastint();
        return num == b.get_number();
    }
    if (b.is_string() && (a.is_number() || a.is_fastint())) {
        double num = hstring_to_number((HString*)b.get_heapptr());
        if (a.is_fastint()) return (double)a.get_fastint() == num;
        return a.get_number() == num;
    }

    // BigInt + Number (ES2020 §7.2.15 step 6/7): compare by mathematical value.
    if (a.is_bigint() && (b.is_number() || b.is_fastint())) {
        return vm_bigint_cmp_number(a.get_bigint(), b.get_number_or_fastint()) == 0;
    }
    if (b.is_bigint() && (a.is_number() || a.is_fastint())) {
        return vm_bigint_cmp_number(b.get_bigint(), a.get_number_or_fastint()) == 0;
    }
    // BigInt + String: parse the string as a BigInt; if it fails, not equal.
    if (a.is_bigint() && b.is_string()) {
        return bigint_string_eq(a.get_bigint(), (HString*)b.get_heapptr());
    }
    if (b.is_bigint() && a.is_string()) {
        return bigint_string_eq(b.get_bigint(), (HString*)a.get_heapptr());
    }

    // Object + Boolean/Number/String/BigInt -> ToPrimitive
    if (a.is_object() && (b.is_boolean() || b.is_number() || b.is_fastint() || b.is_string() || b.is_bigint())) {
        TVal prim = to_primitive_value(vm, a);
        if (!prim.is_object()) {
            return abstract_eq(vm, &prim, b);
        }
        return false;
    }
    if (b.is_object() && (a.is_boolean() || a.is_number() || a.is_fastint() || a.is_string() || a.is_bigint())) {
        TVal prim = to_primitive_value(vm, b);
        if (!prim.is_object()) {
            return abstract_eq(vm, a, &prim);
        }
        return false;
    }

    return false;
}

/// Compare a BigInt value against a string via StringToBigInt (ES2020
/// §7.1.14).  Returns true iff the string parses to a BigInt equal to `big`.
/// A string that fails to parse compares unequal (StringToBigInt → NaN).
fn bool bigint_string_eq(int128 big, HString* s) {
    if (s == null) return false;
    int128? parsed = string_to_bigint(s.get_data());
    if (catch parsed) return false;
    return parsed == big;
}

/// StringToBigInt: trim ECMAScript whitespace, accept an optional leading
/// sign for decimal, or a `0x`/`0o`/`0b` prefix (no sign).  The empty (or
/// all-whitespace) string is 0n.  Faults on any invalid character or overflow.
fn int128? string_to_bigint(char[] raw) {
    usz lo = 0;
    usz hi = raw.len;
    while (lo < hi && is_ecma_whitespace(raw[lo])) lo++;
    while (hi > lo && is_ecma_whitespace(raw[hi - 1])) hi--;
    if (lo == hi) return (int128)0;   // empty → 0n
    char[] t = raw[lo..hi - 1];

    bool neg = false;
    usz i = 0;
    if (t[0] == '+' || t[0] == '-') {
        neg = t[0] == '-';
        i = 1;
    }
    uint radix = 10;
    if (i == 0 && t.len >= 2 && t[0] == '0') {
        char p = t[1];
        if (p == 'x' || p == 'X') { radix = 16; i = 2; }
        else if (p == 'o' || p == 'O') { radix = 8; i = 2; }
        else if (p == 'b' || p == 'B') { radix = 2; i = 2; }
    }
    if (i >= t.len) return hbigint::BIGINT_SYNTAX~;
    // StringToBigInt does not permit `_` separators.
    foreach (char c : t[i..]) {
        if (c == '_') return hbigint::BIGINT_SYNTAX~;
    }
    int128 mag = hbigint::parse_int128_radix(t[i..], radix)!;
    return neg ? hbigint::bigint_neg(mag)! : mag;
}

/// Strict equality check (same as SEQ).
fn bool strict_eq(TVal* a, TVal* b) @inline {
    if (a.get_tag() == b.get_tag()) {
        switch (a.get_tag()) {
            case UNDEFINED: return true;
            case NULL_VAL:  return true;
            case BOOLEAN:   return a.get_boolean() == b.get_boolean();
            case NUMBER:
                if (math::is_nan(a.get_number()) && math::is_nan(b.get_number())) return false;
                return a.get_number() == b.get_number();
            case FASTINT:   return a.get_fastint() == b.get_fastint();
            case STRING: {
                HString* sa = (HString*)a.get_heapptr();
                HString* sb = (HString*)b.get_heapptr();
                return sa != null && sb != null && sa.equals_hstring(sb);
            }
            case OBJECT:    return a.get_heapptr() == b.get_heapptr();
            case BIGINT:    return a.get_bigint() == b.get_bigint();
            default:        return false;
        }
    }
    // NUMBER and FASTINT are the same ES type
    if (a.is_number() && b.is_fastint()) {
        return a.get_number() == (double)b.get_fastint();
    }
    if (a.is_fastint() && b.is_number()) {
        return (double)a.get_fastint() == b.get_number();
    }
    return false;
}
