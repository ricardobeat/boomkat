module boomkat::builtins;
import boomkat::types;
import boomkat::heap;
import boomkat::hobject;
import boomkat::hstring;
import boomkat::vm;
import std::math;

struct IntlDecimal {
    StrBuf digits;
    long point;
    bool negative;
    bool nan;
    bool infinity;
    long exponent;
}

fn bool intl_decimal(BuiltinContext* ctx, TVal input, IntlDecimal* out, bool plural) {
    out.digits.init(ctx.heap);
    if (input.is_object()) {
        Vm* machine = (Vm*)ctx.vm;
        input = vm::to_primitive_value(machine, &input, 2);
        if (machine.throw_pending) {
            machine.throw_pending = false;
            ctx.should_throw = true;
            ctx.throw_value = machine.throw_value;
            return false;
        }
    }
    HString* text;
    char[] exact = {};
    if (!plural && input.is_bigint()) {
        text = builtin_to_string_vm(ctx, &input);
    } else {
        double n = builtin_to_number_vm(ctx, &input);
        if (ctx.should_throw) return false;
        out.negative = math::signbit(n) != 0;
        if (!plural && input.is_string() && !math::is_nan(n)) {
            HString* raw = (HString*)input.get_heapptr();
            uint start = 0;
            uint end = 0;
            for (uint i = 0; i < raw.blen;) {
                uint width;
                uint cp = decode_codepoint_at(raw.get_cstr(), i, raw.blen, &width);
                if (width == 0) break;
                if (!is_ecma_ws_codepoint(cp)) { if (end == 0) start = i; end = i + width; }
                i += width;
            }
            if (end > start) {
                char[] candidate = raw.get_cstr()[start:end - start];
                bool decimal = true;
                foreach (c : candidate) {
                    if (!locale_is_digit(c) && c != '.' && c != 'e' && c != 'E' && c != '+' && c != '-') decimal = false;
                }
                if (decimal) exact = candidate;
            }
        }
        out.nan = math::is_nan(n);
        out.infinity = math::is_inf(n) && exact.len == 0;
        if (out.nan || out.infinity) return true;
        text = builtin_number_to_hstring(ctx.heap, math::abs(n));
    }
    if (ctx.should_throw || text == null) return false;
    char[] source = exact.len > 0 ? exact : text.get_cstr()[:text.blen];
    usz i = 0;
    if (source.len > 0 && (source[0] == '-' || source[0] == '+')) { out.negative = source[0] == '-'; i++; }
    bool fractional = false;
    while (i < source.len && source[i] != 'e' && source[i] != 'E') {
        char c = source[i++];
        if (c == '.') { fractional = true; continue; }
        if (!out.digits.append_char(c)) return false;
        if (!fractional) out.point++;
    }
    if (i < source.len) {
        i++;
        bool minus = i < source.len && source[i] == '-';
        if (i < source.len && (source[i] == '+' || source[i] == '-')) i++;
        long exponent = 0;
        while (i < source.len) {
            if (exponent > (long)hstring::MAX_STRING_BYTES) { builtin_throw(ctx, ctx.heap.range_err_proto, "formatted number exceeds string limit"); return false; }
            exponent = exponent * 10 + source[i++] - '0';
        }
        out.point += minus ? -exponent : exponent;
    }
    usz leading = 0;
    while (leading + 1 < out.digits.len && out.digits.data[leading] == '0') leading++;
    if (leading > 0) {
        for (usz k = leading; k < out.digits.len; k++) out.digits.data[k - leading] = out.digits.data[k];
        out.digits.len -= leading;
        out.point -= (long)leading;
    }
    if (intl_zero(out)) out.point = 1;
    return true;
}

fn bool intl_round_up(IntlDecimal* value, IntlNumberState* state, bool discarded, int half, bool odd) {
    if (!discarded) return false;
    switch (state.rounding_mode) {
        case 0: return !value.negative;
        case 1: return value.negative;
        case 2: return true;
        case 3: return false;
        default:
            if (half != 0) return half > 0;
            switch (state.rounding_mode) {
                case 4: return !value.negative;
                case 5: return value.negative;
                case 6: return true;
                case 7: return false;
                default: return odd;
            }
    }
}

fn bool intl_increment_round(IntlDecimal* value, IntlNumberState* state, long keep) {
    StrBuf quotient; quotient.init(value.digits.heap); defer quotient.free();
    int remainder = 0;
    for (long i = 0; i < keep; i++) {
        int digit = i < (long)value.digits.len ? value.digits.data[i] - '0' : 0;
        int n = remainder * 10 + digit;
        if (!quotient.append_char((char)('0' + n / state.rounding_increment))) return false;
        remainder = n % state.rounding_increment;
    }
    if (quotient.len == 0) quotient.append_char('0');
    bool tail = false;
    for (long i = math::max(keep, 0L); i < (long)value.digits.len; i++) if (value.digits.data[i] != '0') tail = true;
    int half = remainder * 2 - state.rounding_increment;
    if (half == -1 && keep >= 0 && keep < (long)value.digits.len) {
        char digit = value.digits.data[keep];
        half = digit < '5' ? -1 : digit > '5' ? 1 : 0;
        if (half == 0) {
            for (long i = keep + 1; i < (long)value.digits.len; i++) if (value.digits.data[i] != '0') half = 1;
        }
    } else if (half == 0 && tail) { half = 1; }
    bool up = intl_round_up(value, state, remainder != 0 || tail, half,
                            ((quotient.data[quotient.len - 1] - '0') % 2) != 0);
    if (up) {
        long i = (long)quotient.len - 1;
        while (i >= 0 && quotient.data[i] == '9') quotient.data[i--] = '0';
        if (i >= 0) { quotient.data[i]++; }
        else { quotient.data[0] = '1'; quotient.append_char('0'); }
    }
    int carry = 0;
    for (long i = (long)quotient.len - 1; i >= 0; i--) {
        int n = (quotient.data[i] - '0') * state.rounding_increment + carry;
        quotient.data[i] = (char)('0' + n % 10);
        carry = n / 10;
    }
    value.digits.len = 0;
    if (carry > 0) {
        char[8] prefix;
        int n = hstring::int_to_buf(carry, &prefix, 8);
        value.digits.append_bytes(prefix[:n]);
    }
    value.digits.append_bytes(quotient.bytes());
    value.point = (long)value.digits.len - state.max_fraction;
    usz leading = 0;
    while (leading + 1 < value.digits.len && value.digits.data[leading] == '0') leading++;
    for (usz i = leading; i < value.digits.len; i++) value.digits.data[i - leading] = value.digits.data[i];
    value.digits.len -= leading;
    value.point -= (long)leading;
    if (intl_zero(value)) value.point = 1;
    return !value.digits.failed && !quotient.failed;
}

// Decimal carry and directed rounding operate on digits, preserving arbitrary
// BigInt magnitudes and exact decimal-string inputs.
fn bool intl_round(IntlDecimal* value, IntlNumberState* state) {
    if (value.nan || value.infinity) return true;
    long keep = state.max_significant > 0 ? state.max_significant : value.point + state.max_fraction;
    if (state.rounding_increment > 1) return intl_increment_round(value, state, keep);
    if (keep >= (long)value.digits.len) return true;
    bool discarded = false;
    for (long i = math::max(keep, 0L); i < (long)value.digits.len; i++) if (value.digits.data[i] != '0') discarded = true;
    int half = -1;
    if (keep >= 0) {
        half = value.digits.data[keep] < '5' ? -1 : value.digits.data[keep] > '5' ? 1 : 0;
        if (half == 0) {
            for (long i = keep + 1; i < (long)value.digits.len; i++) if (value.digits.data[i] != '0') half = 1;
        }
    }
    bool odd = keep > 0 && ((value.digits.data[keep - 1] - '0') % 2) != 0;
    bool up = intl_round_up(value, state, discarded, half, odd);
    if (keep <= 0) {
        value.digits.len = 0;
        value.digits.append_char(up ? '1' : '0');
        value.point = up ? 1L - state.max_fraction : 1L;
        return !value.digits.failed;
    }
    value.digits.len = (usz)keep;
    if (!up) return true;
    long i = keep - 1;
    while (i >= 0 && value.digits.data[i] == '9') value.digits.data[i--] = '0';
    if (i >= 0) { value.digits.data[i]++; return true; }
    value.digits.data[0] = '1';
    value.point++;
    return value.digits.append_char('0');
}

fn bool intl_prepare(IntlDecimal* value, IntlNumberState* settings) {
    if (value.nan || value.infinity) return true;
    if (settings.style == 1) value.point += 2;
    if (intl_zero(value)) value.point = 1;
    if (settings.notation > 1 && !intl_zero(value)) {
        value.exponent = value.point - 1;
        if (settings.notation == 3) value.exponent = value.exponent >= 0 ? value.exponent / 3 * 3 : (value.exponent - 2) / 3 * 3;
    } else if (settings.notation == 1 && value.point > 3) {
        value.exponent = math::min((value.point - 1) / 3 * 3, 12L);
    }
    value.point -= value.exponent;
    if (settings.rounding_priority != 0) {
        long fraction = value.point + settings.max_fraction;
        bool significant = settings.rounding_priority == 1 ? settings.max_significant > fraction : settings.max_significant < fraction;
        if (significant) { settings.min_fraction = 0; }
        else { settings.max_significant = 0; }
    }
    if (!intl_round(value, settings)) return false;
    if (!intl_zero(value) && settings.notation > 0) {
        long threshold = settings.notation == 2 ? 1 : 3;
        if (value.point > threshold && (settings.notation != 1 || value.exponent < 12)) {
            long shift = settings.notation == 2 ? 1 : 3;
            value.exponent += shift;
            value.point -= shift;
        }
    }
    return true;
}

fn bool intl_zero(IntlDecimal* value) {
    foreach (c : value.digits.bytes()) if (c != '0') return false;
    return true;
}

fn bool intl_fixed(IntlDecimal* value, IntlNumberState* state, StrBuf* out) {
    if (value.nan) return out.append_bytes("NaN");
    if (value.infinity) return out.append_bytes("\u221e");
    long integer = math::max(value.point, 1L);
    integer = math::max(integer, (long)state.min_integer);
    long padding = integer - math::max(value.point, 1L);
    for (long i = 0; i < integer; i++) {
        long index = i - padding;
        char c = index >= 0 && value.point > 0 && index < (long)value.digits.len ? value.digits.data[index] : '0';
        if (!out.append_char(c)) return false;
    }
    long end = (long)value.digits.len;
    while (end > 0 && value.digits.data[end - 1] == '0') end--;
    long fraction = math::max(end - value.point, 0L);
    int min_fraction = state.min_fraction;
    if (state.max_significant > 0) {
        min_fraction = math::max(state.min_significant - (int)value.point, 0);
        if (intl_zero(value)) min_fraction = state.min_significant - 1;
    }
    fraction = math::max(fraction, (long)min_fraction);
    if (state.strip_zero && end <= value.point) fraction = 0;
    if (fraction == 0) return true;
    if (!out.append_char('.')) return false;
    for (long i = 0; i < fraction; i++) {
        long index = value.point + i;
        char c = index >= 0 && index < (long)value.digits.len ? value.digits.data[index] : '0';
        if (!out.append_char(c)) return false;
    }
    return true;
}

fn char[] intl_currency_symbol(IntlNumberState* state) {
    char[] c = state.currency[..];
    if (state.currency_display == 1) return c;
    int index = intl_currency_index(c);
    if (index < 0) return c;
    return intl_data_string(state.currency_display == 3 ? INTL_CURRENCIES[index].narrow : INTL_CURRENCIES[index].symbol);
}

fn char[] intl_currency_name(IntlNumberState* state, bool one) {
    char[] c = state.currency[..];
    int index = intl_currency_index(c);
    if (index < 0) return c;
    return intl_data_string(one ? INTL_CURRENCIES[index].one : INTL_CURRENCIES[index].other);
}

fn bool intl_part(BuiltinContext* ctx, HObject* parts, StrBuf* result, char[] type, char[] text, uint* count) {
    if (!result.append_bytes(text)) return false;
    if (parts == null) return true;
    HObject* part = ctx.heap.alloc_object(ObjClass.OBJECT) ?? null;
    if (part == null) { result.failed = true; return false; }
    ctx.heap.set_prototype(part, ctx.heap.object_proto);
    if (!intl_put_string(ctx.heap, part, "type", type) || !intl_put_string(ctx.heap, part, "value", text)) { result.failed = true; return false; }
    TVal v; v.set_object(part);
    array_set_elem(parts, (*count)++, v, ctx.heap);
    return true;
}

fn void intl_render(BuiltinContext* ctx, IntlNumberState* state, TVal input, bool as_parts) {
    IntlDecimal value;
    defer value.digits.free();
    IntlNumberState effective = *state;
    if (!intl_decimal(ctx, input, &value, false) || !intl_prepare(&value, &effective)) {
        if (!ctx.should_throw) builtin_throw(ctx, ctx.heap.err_proto, "Intl allocation failed");
        return;
    }
    StrBuf fixed; fixed.init(ctx.heap);
    defer fixed.free();
    StrBuf result; result.init(ctx.heap);
    defer result.free();
    if (!intl_fixed(&value, &effective, &fixed)) { builtin_throw(ctx, ctx.heap.err_proto, "Intl allocation failed"); return; }
    HObject* parts = as_parts ? intl_array(ctx) : null;
    if (ctx.should_throw) return;
    uint count = 0;
    bool zero = !value.nan && !value.infinity && intl_zero(&value);
    bool minus = value.negative && !value.nan && state.sign_display != 1;
    if (state.sign_display == 3 || state.sign_display == 4) minus = minus && !zero;
    bool plus = !minus && (state.sign_display == 2 || (state.sign_display == 3 && !zero && !value.nan));
    bool accounting = minus && state.style == 2 && state.accounting && state.currency_display != 2;
    if (accounting) { intl_part(ctx, parts, &result, "literal", "(", &count); }
    else if (minus) { intl_part(ctx, parts, &result, "minusSign", "-", &count); }
    else if (plus) { intl_part(ctx, parts, &result, "plusSign", "+", &count); }
    if (state.style == 2 && state.currency_display != 2) {
        char[] symbol = intl_currency_symbol(state);
        intl_part(ctx, parts, &result, "currency", symbol, &count);
        if (locale_is_alpha(symbol[symbol.len - 1])) intl_part(ctx, parts, &result, "literal", "\u00a0", &count);
    }
    if (value.nan || value.infinity) {
        intl_part(ctx, parts, &result, value.nan ? "nan" : "infinity", fixed.bytes(), &count);
    } else {
        usz integer_len = 0;
        while (integer_len < fixed.len && fixed.data[integer_len] != '.') integer_len++;
        usz start = 0;
        while (start < integer_len) {
            usz n = integer_len - start;
            bool group = state.grouping != 0 && integer_len > (usz)(state.grouping == 3 ? 4 : 3);
            if (group) n = start == 0 ? (integer_len - 1) % 3 + 1 : 3;
            intl_part(ctx, parts, &result, "integer", fixed.data[start:n], &count);
            start += n;
            if (start < integer_len) intl_part(ctx, parts, &result, "group", ",", &count);
        }
        if (integer_len < fixed.len) {
            intl_part(ctx, parts, &result, "decimal", ".", &count);
            intl_part(ctx, parts, &result, "fraction", fixed.data[integer_len + 1:fixed.len - integer_len - 1], &count);
        }
    }
    if (!value.nan && !value.infinity && state.notation > 1) {
        intl_part(ctx, parts, &result, "exponentSeparator", "E", &count);
        if (value.exponent < 0) intl_part(ctx, parts, &result, "exponentMinusSign", "-", &count);
        char[24] exponent;
        int n = hstring::int_to_buf(math::abs(value.exponent), &exponent, 24);
        intl_part(ctx, parts, &result, "exponentInteger", exponent[:n], &count);
    }
    if (!value.nan && !value.infinity && state.notation == 1 && value.exponent > 0) {
        char[][] short_names = {"", "K", "M", "B", "T"};
        char[][] long_names = {"", "thousand", "million", "billion", "trillion"};
        if (state.compact_display == 1) intl_part(ctx, parts, &result, "literal", " ", &count);
        intl_part(ctx, parts, &result, "compact", state.compact_display == 0 ? short_names[value.exponent / 3] : long_names[value.exponent / 3], &count);
    }
    if (state.style == 1) intl_part(ctx, parts, &result, "percentSign", "%", &count);
    if (state.style == 2 && state.currency_display == 2) {
        intl_part(ctx, parts, &result, "literal", " ", &count);
        bool one = !value.nan && !value.infinity && mem_eq_bytes(fixed.bytes(), "1");
        intl_part(ctx, parts, &result, "currency", intl_currency_name(state, one), &count);
    }
    if (state.style == 3) {
        bool one = mem_eq_bytes(fixed.bytes(), "1");
        IntlUnitData unit = INTL_UNITS[state.unit];
        ushort offset = state.unit_display == 2 ? (one ? unit.one : unit.other) : state.unit_display == 0 ? (one ? unit.short_one : unit.short_other) : (one ? unit.narrow_one : unit.narrow_other);
        char[] pattern = intl_data_string(offset);
        StrBuf suffix; suffix.init(ctx.heap); defer suffix.free();
        suffix.append_bytes(pattern[3:pattern.len - 3]);
        if (state.denominator >= 0) {
            IntlUnitData denominator = INTL_UNITS[state.denominator];
            if (state.unit_display == 2) { suffix.append_bytes(" per "); } else { suffix.append_char('/'); }
            ushort d = state.unit_display == 2 ? denominator.one : denominator.narrow_one;
            char[] dp = intl_data_string(d);
            usz start = 3;
            while (start < dp.len && dp[start] == ' ') start++;
            suffix.append_bytes(dp[start:dp.len - start]);
        }
        usz start = 0;
        while (start < suffix.len && suffix.data[start] == ' ') start++;
        if (start > 0) intl_part(ctx, parts, &result, "literal", suffix.data[:start], &count);
        intl_part(ctx, parts, &result, "unit", suffix.data[start:suffix.len - start], &count);
    }
    if (accounting) intl_part(ctx, parts, &result, "literal", ")", &count);
    if (result.failed || ctx.heap.has_error) { builtin_throw(ctx, ctx.heap.err_proto, "Intl allocation failed"); return; }
    if (as_parts) {
        array_set_length(parts, count, ctx.heap);
        ctx.result_object(parts);
    } else { ctx.result_string(builtin_intern_string(ctx.heap, result.bytes())); }
}

fn void builtin_intl_number_format_get(BuiltinContext* ctx) {
    IntlNumberState* state = intl_receiver(ctx, false);
    if (state == null) return;
    if (state.bound_format == null) {
        HObject* bound = ctx.heap.alloc_object(ObjClass.FUNCTION) ?? null;
        if (bound == null) { builtin_throw(ctx, ctx.heap.err_proto, "Intl allocation failed"); return; }
        ctx.heap.set_prototype(bound, ctx.heap.function_proto);
        (*bound.extra_ptr()).func.builtin_fn_index = (int)Builtin.BOUND_CALL.ordinal;
        TVal target; target.set_lightfunc((void*)(usz)Builtin.INTL_NUMBER_FORMAT_CALL.ordinal);
        TVal receiver = ctx.regs[ctx.base_reg - 1];
        ctx.heap.tval_copy_ref(&(*bound.extra_ptr()).func.bound.target, &target);
        ctx.heap.tval_copy_ref(&(*bound.extra_ptr()).func.bound.this_arg, &receiver);
        bound.flags.is_bound = true;
        bound.flags.callable = true;
        bound.flags.constructable = false;
        set_func_ctor_name_length(bound, ctx.heap, "", 1);
        state.bound_format = bound;
        ctx.heap.write_barrier_ptr((HObject*)receiver.get_heapptr(), bound);
    }
    ctx.result_object(state.bound_format);
}

fn void builtin_intl_number_format_call(BuiltinContext* ctx) {
    IntlNumberState* state = intl_receiver(ctx, false);
    if (state != null) intl_render(ctx, state, builtin_arg(ctx, 0), false);
}

fn void builtin_intl_number_parts(BuiltinContext* ctx) {
    IntlNumberState* state = intl_receiver(ctx, false);
    if (state != null) intl_render(ctx, state, builtin_arg(ctx, 0), true);
}

fn char[] intl_part_field(BuiltinContext* ctx, HObject* parts, uint index, char[] key) {
    TVal entry = array_get_elem(parts, index, ctx.heap);
    HObject* obj = (HObject*)entry.get_heapptr();
    TVal? value = obj.get_prop(builtin_intern_string(ctx.heap, key), ctx.heap);
    if (try v = value) {
        HString* s = (HString*)v.get_heapptr();
        return s.get_cstr()[:s.blen];
    }
    return "";
}

fn bool intl_same_part(BuiltinContext* ctx, HObject* a, uint ai, HObject* b, uint bi) {
    return mem_eq_bytes(intl_part_field(ctx, a, ai, "type"), intl_part_field(ctx, b, bi, "type")) &&
           mem_eq_bytes(intl_part_field(ctx, a, ai, "value"), intl_part_field(ctx, b, bi, "value"));
}

fn bool intl_range_copy(BuiltinContext* ctx, HObject* out, HObject* from, uint index, char[] source, uint* count, StrBuf* text) {
    TVal part = array_get_elem(from, index, ctx.heap);
    HObject* obj = (HObject*)part.get_heapptr();
    if (!intl_put_string(ctx.heap, obj, "source", source)) { text.failed = true; return false; }
    array_set_elem(out, (*count)++, part, ctx.heap);
    return text.append_bytes(intl_part_field(ctx, from, index, "value"));
}

fn void intl_range(BuiltinContext* ctx, bool as_parts) {
    IntlNumberState* state = intl_receiver(ctx, false);
    if (state == null) return;
    TVal a = builtin_arg(ctx, 0);
    TVal b = builtin_arg(ctx, 1);
    if (a.is_undefined() || b.is_undefined()) { builtin_throw(ctx, ctx.heap.type_err_proto, "formatRange requires two values"); return; }
    TVal first; first.set_undefined();
    TVal second; second.set_undefined();
    defer ctx.heap.decref_tval(&first);
    defer ctx.heap.decref_tval(&second);
    BuiltinContext inner = *ctx;
    inner.result = result_slot(&first);
    intl_render(&inner, state, a, true);
    if (inner.should_throw) { ctx.should_throw = true; ctx.throw_value = inner.throw_value; return; }
    inner.result = result_slot(&second);
    intl_render(&inner, state, b, true);
    if (inner.should_throw) { ctx.should_throw = true; ctx.throw_value = inner.throw_value; return; }
    HObject* ap = (HObject*)first.get_heapptr();
    HObject* bp = (HObject*)second.get_heapptr();
    uint alen = (uint)array_get_length(ap, ctx.heap);
    uint blen = (uint)array_get_length(bp, ctx.heap);
    bool same = alen == blen;
    for (uint i = 0; i < alen; i++) {
        if (mem_eq_bytes(intl_part_field(ctx, ap, i, "type"), "nan")) { builtin_throw(ctx, ctx.heap.range_err_proto, "formatRange cannot accept NaN"); return; }
        if (same && !intl_same_part(ctx, ap, i, bp, i)) same = false;
    }
    for (uint i = 0; i < blen; i++) {
        if (mem_eq_bytes(intl_part_field(ctx, bp, i, "type"), "nan")) { builtin_throw(ctx, ctx.heap.range_err_proto, "formatRange cannot accept NaN"); return; }
    }
    HObject* out = intl_array(ctx);
    if (out == null) return;
    StrBuf text; text.init(ctx.heap); defer text.free();
    uint count = 0;
    if (same) {
        intl_part(ctx, out, &text, "approximatelySign", "~", &count);
        TVal prefix = array_get_elem(out, 0, ctx.heap);
        intl_put_string(ctx.heap, (HObject*)prefix.get_heapptr(), "source", "shared");
        for (uint i = 0; i < alen; i++) intl_range_copy(ctx, out, ap, i, "shared", &count, &text);
    } else {
        uint prefix = 0;
        uint suffix = 0;
        // Currency symbols collapse for fractional ranges; integer currency
        // ranges repeat symbols and use the spaced CLDR separator.
        if (state.style == 2 && state.min_fraction > 0) {
            while (prefix < alen && prefix < blen && intl_same_part(ctx, ap, prefix, bp, prefix) &&
                   !mem_eq_bytes(intl_part_field(ctx, ap, prefix, "type"), "integer")) prefix++;
        }
        if (state.style == 3 || state.notation != 0 || state.currency_display == 2) {
            while (suffix + prefix < alen && suffix + prefix < blen &&
                   intl_same_part(ctx, ap, alen - suffix - 1, bp, blen - suffix - 1)) {
                char[] type = intl_part_field(ctx, ap, alen - suffix - 1, "type");
                if (mem_eq_bytes(type, "integer") || mem_eq_bytes(type, "fraction") || mem_eq_bytes(type, "decimal")) break;
                suffix++;
            }
        }
        for (uint i = 0; i < prefix; i++) intl_range_copy(ctx, out, ap, i, "shared", &count, &text);
        for (uint i = prefix; i < alen - suffix; i++) intl_range_copy(ctx, out, ap, i, "startRange", &count, &text);
        intl_part(ctx, out, &text, "literal", state.style == 2 && state.min_fraction == 0 ? " \u2013 " : "\u2013", &count);
        TVal separator = array_get_elem(out, count - 1, ctx.heap);
        intl_put_string(ctx.heap, (HObject*)separator.get_heapptr(), "source", "shared");
        for (uint i = prefix; i < blen - suffix; i++) intl_range_copy(ctx, out, bp, i, "endRange", &count, &text);
        for (uint i = alen - suffix; i < alen; i++) intl_range_copy(ctx, out, ap, i, "shared", &count, &text);
    }
    if (text.failed || ctx.heap.has_error) { builtin_throw(ctx, ctx.heap.err_proto, "Intl allocation failed"); return; }
    array_set_length(out, count, ctx.heap);
    if (as_parts) { ctx.result_object(out); } else { ctx.result_string(builtin_intern_string(ctx.heap, text.bytes())); }
}

fn void builtin_intl_number_range(BuiltinContext* ctx) { intl_range(ctx, false); }
fn void builtin_intl_number_range_parts(BuiltinContext* ctx) { intl_range(ctx, true); }

fn char[] intl_select(BuiltinContext* ctx, IntlNumberState* state, TVal input) {
    IntlDecimal value;
    defer value.digits.free();
    IntlNumberState effective = *state;
    if (!intl_decimal(ctx, input, &value, true) || !intl_prepare(&value, &effective)) return "other";
    if (value.nan || value.infinity) return "other";
    StrBuf fixed; fixed.init(ctx.heap);
    defer fixed.free();
    if (!intl_fixed(&value, &effective, &fixed)) { builtin_throw(ctx, ctx.heap.err_proto, "Intl allocation failed"); return "other"; }
    if (!state.ordinal) {
        usz start = 0;
        while (start + 1 < fixed.len && fixed.data[start] == '0') start++;
        return mem_eq_bytes(fixed.data[start:fixed.len - start], "1") ? "one" : "other";
    }
    int mod100 = 0;
    bool fractional = false;
    foreach (c : fixed.bytes()) {
        if (c == '.') { fractional = true; continue; }
        if (fractional) { if (c != '0') return "other"; }
        else { mod100 = (mod100 * 10 + c - '0') % 100; }
    }
    if (mod100 >= 11 && mod100 <= 13) return "other";
    switch (mod100 % 10) {
        case 1: return "one";
        case 2: return "two";
        case 3: return "few";
        default: return "other";
    }
}

fn void builtin_intl_plural_select(BuiltinContext* ctx) {
    IntlNumberState* state = intl_receiver(ctx, true);
    if (state == null) return;
    char[] category = intl_select(ctx, state, builtin_arg(ctx, 0));
    if (!ctx.should_throw) ctx.result_string(builtin_intern_string(ctx.heap, category));
}

fn void builtin_intl_plural_range(BuiltinContext* ctx) {
    IntlNumberState* state = intl_receiver(ctx, true);
    if (state == null) return;
    TVal start = builtin_arg(ctx, 0);
    TVal end = builtin_arg(ctx, 1);
    if (start.is_undefined() || end.is_undefined()) { builtin_throw(ctx, ctx.heap.type_err_proto, "selectRange requires two values"); return; }
    double a = builtin_to_number_vm(ctx, &start);
    if (ctx.should_throw) return;
    double b = builtin_to_number_vm(ctx, &end);
    if (ctx.should_throw) return;
    if (math::is_nan(a) || math::is_nan(b)) { builtin_throw(ctx, ctx.heap.range_err_proto, "selectRange cannot accept NaN"); return; }
    ctx.result_string(builtin_intern_string(ctx.heap, "other"));
}

fn void builtin_number_proto_toLocaleString(BuiltinContext* ctx) {
    $if $feat(NO_INTL):
        // Locale arguments are separate from Number.prototype.toString's radix.
        ushort argc = ctx.argc; ctx.argc = 0;
        builtin_number_proto_toString(ctx);
        ctx.argc = argc;
    $else
        double number;
        if (!this_number_value(ctx, &number)) { builtin_throw(ctx, ctx.heap.type_err_proto, "incompatible Number receiver"); return; }
        IntlNumberState state;
        if (!intl_init_options(ctx, &state, builtin_arg(ctx, 0), builtin_arg(ctx, 1), false)) return;
        TVal value; value.set_number(number);
        intl_render(ctx, &state, value, false);
    $endif
}

fn void builtin_bigint_proto_toLocaleString(BuiltinContext* ctx) {
    TVal value = ctx.regs[ctx.base_reg - 1];
    if (value.is_object()) {
        HObject* obj = (HObject*)value.get_heapptr();
        if (obj.prototype == ctx.heap.bigint_proto) value = (*obj.extra_ptr()).prim.primitive_value;
    }
    if (!value.is_bigint()) { builtin_throw(ctx, ctx.heap.type_err_proto, "incompatible BigInt receiver"); return; }
    $if $feat(NO_INTL):
        ctx.result_string(builtin_to_string_vm(ctx, &value));
    $else
        IntlNumberState state;
        if (!intl_init_options(ctx, &state, builtin_arg(ctx, 0), builtin_arg(ctx, 1), false)) return;
        intl_render(ctx, &state, value, false);
    $endif
}
