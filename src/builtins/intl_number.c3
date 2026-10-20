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
    long magnitude; // compact notation: the power of ten whose pattern applies, 0 for none
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
    value.magnitude = 0;
    if (settings.notation > 1 && !intl_zero(value)) {
        value.exponent = value.point - 1;
        if (settings.notation == 3) value.exponent = value.exponent >= 0 ? value.exponent / 3 * 3 : (value.exponent - 2) / 3 * 3;
    } else if (settings.notation == 1 && !intl_zero(value)) {
        value.magnitude = intl_compact_magnitude(settings, value.point - 1);
        if (value.magnitude > 0) value.exponent = intl_compact_exponent(settings, value.magnitude);
    }
    value.point -= value.exponent;
    if (settings.rounding_priority != 0) {
        long fraction = value.point + settings.max_fraction;
        bool significant = settings.rounding_priority == 1 ? settings.max_significant > fraction : settings.max_significant < fraction;
        if (significant) { settings.min_fraction = 0; }
        else { settings.max_significant = 0; }
    }
    if (!intl_round(value, settings)) return false;
    if (intl_zero(value)) return true;
    if (settings.notation == 2 && value.point > 1) {
        value.exponent += 1;
        value.point -= 1;
    } else if (settings.notation == 3 && value.point > 3) {
        value.exponent += 3;
        value.point -= 3;
    } else if (settings.notation == 1) {
        // Rounding can carry into the next magnitude (999950 -> 1000K -> 1M); the
        // carried value takes that magnitude's pattern.
        long magnitude = intl_compact_magnitude(settings, value.point - 1 + value.exponent);
        if (magnitude > value.magnitude) {
            long exponent = intl_compact_exponent(settings, magnitude);
            value.point -= exponent - value.exponent;
            value.exponent = exponent;
            value.magnitude = magnitude;
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

// The row's symbol for a currency, or the English one when the row has no override.
fn char[] intl_currency_symbol(IntlNumberState* state) {
    char[] c = state.currency[..];
    if (state.currency_display == 1) return c;
    int index = intl_currency_index(c);
    if (index < 0) return c;
    LocaleCurrency local = intl_row_currency((usz)state.locale, intl_pack_code(c));
    ushort override = state.currency_display == 3 ? local.narrow : local.symbol;
    if (override != 0) return intl_row_text((usz)state.locale, override);
    char flags = INTL_CURRENCY_FLAGS[index];
    ushort symbol = 0;
    if (!(flags & 4)) symbol = intl_sparse(INTL_CURRENCY_SYMBOL_BITS[..], INTL_CURRENCY_SYMBOL_RANK[..], INTL_CURRENCY_SYMBOL_NAMES[..], (usz)index);
    if (state.currency_display == 3 && !(flags & 8)) {
        return intl_data_string(intl_sparse(INTL_CURRENCY_NARROW_BITS[..], INTL_CURRENCY_NARROW_RANK[..], INTL_CURRENCY_NARROW_NAMES[..], (usz)index));
    }
    return flags & 4 ? c : intl_data_string(symbol);
}

// The currency's name for the plural form `one` or other; a plural that is the
// English singular plus "s" is built in `scratch`.
fn char[] intl_currency_name(IntlNumberState* state, bool one, char[] scratch) {
    char[] c = state.currency[..];
    int index = intl_currency_index(c);
    if (index < 0) return c;
    LocaleCurrency local = intl_row_currency((usz)state.locale, intl_pack_code(c));
    ushort override = one ? local.one : local.other;
    if (override != 0) return intl_row_text((usz)state.locale, override);
    char[] singular = intl_data_string(INTL_CURRENCY_ONE[index]);
    if (one) return singular;
    if (!(INTL_CURRENCY_FLAGS[index] & 16)) {
        return intl_data_string(intl_sparse(INTL_CURRENCY_PLURAL_BITS[..], INTL_CURRENCY_PLURAL_RANK[..], INTL_CURRENCY_PLURAL_NAMES[..], (usz)index));
    }
    for (usz i = 0; i < singular.len; i++) scratch[i] = singular[i];
    scratch[singular.len] = 's';
    return scratch[:singular.len + 1];
}

// A numeric part: the ASCII digits become the state's numbering system.
fn bool intl_digit_part(BuiltinContext* ctx, IntlNumberState* state, HObject* parts, StrBuf* result, char[] type, char[] text, uint* count) {
    usz system = intl_numbering_index(state.numbering);
    if (system == INTL_DIGIT_LATN) return intl_part(ctx, parts, result, type, text, count);
    StrBuf mapped; mapped.init(ctx.heap);
    defer mapped.free();
    for (usz i = 0; i < text.len; i += 32) {
        char[32] chunk_in;
        char[128] chunk_out;
        usz n = text.len - i < 32 ? text.len - i : 32;
        foreach (k, c : text[i:n]) chunk_in[k] = c;
        mapped.append_bytes(chunk_out[:intl_map_digits(system, chunk_in[:n], chunk_out[..])]);
    }
    if (mapped.failed) { result.failed = true; return false; }
    return intl_part(ctx, parts, result, type, mapped.bytes(), count);
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

// The state of one formatting call. `count` is the next index in `parts`.
struct IntlOutput {
    BuiltinContext* ctx;
    IntlNumberState* state;
    HObject* parts;
    uint* count;
    StrBuf* result;
    usz row;
    char[] fixed;            // rounded digits with '.' and no sign
    bool nan;
    bool infinity;
    char[] grouping_pattern; // positive subpattern of the decimal pattern, for group sizes
    char[] currency;         // the text that replaces ¤
}

fn bool out_part(IntlOutput* o, char[] type, char[] text) {
    return intl_part(o.ctx, o.parts, o.result, type, text, o.count);
}

// Bytes that start a whitespace-like run, which stays literal when it bounds an affix.
fn usz intl_space_len(char[] text, usz i) {
    if (text[i] == ' ') return 1;
    if ((uint)(char)text[i] == 0xC2 && i + 1 < text.len && (uint)(char)text[i + 1] == 0xA0) return 2;
    if ((uint)(char)text[i] == 0xE2 && i + 2 < text.len && (uint)(char)text[i + 1] == 0x80 && (uint)(char)text[i + 2] == 0x8F) return 3;
    return 0;
}

// Splits an affix so its leading and trailing spaces are literal and the rest is `type`.
fn bool intl_emit_affix(IntlOutput* o, char[] text, char[] type) {
    usz start = 0;
    usz end = text.len;
    while (start < end) {
        usz n = intl_space_len(text, start);
        if (n == 0) break;
        if (!out_part(o, "literal", text[start:n])) return false;
        start += n;
    }
    usz trailing = end;
    while (trailing > start) {
        usz before = trailing - 1;
        if (text[before] == ' ') { trailing = before; continue; }
        if (before >= 1 && (uint)(char)text[before - 1] == 0xC2 && (uint)(char)text[before] == 0xA0) { trailing = before - 1; continue; }
        break;
    }
    if (trailing > start && !out_part(o, type, text[start:trailing - start])) return false;
    if (trailing < end && !out_part(o, "literal", text[trailing:end - trailing])) return false;
    return true;
}

// Emits the decimal digits: integer groups, decimal separator and fraction, or the NaN/infinity symbol.
fn bool intl_emit_core(IntlOutput* o) {
    IntlLocaleRow row = intl_row(o.row);
    if (o.nan) return out_part(o, "nan", intl_row_text(o.row, row.nan));
    if (o.infinity) return out_part(o, "infinity", intl_row_text(o.row, row.infinity));
    usz dot = 0;
    while (dot < o.fixed.len && o.fixed[dot] != '.') dot++;
    char[] integer = o.fixed[0:dot];
    usz primary = 3;
    usz secondary = 3;
    bool grouped = o.state.grouping != 0 && intl_group_sizes(o.grouping_pattern, &primary, &secondary);
    usz need = primary + (o.state.grouping == 2 ? 1 : o.state.grouping == 3 ? 2 : (usz)(char)row.min_grouping);
    if (!grouped || integer.len < need) {
        if (!intl_digit_part(o.ctx, o.state, o.parts, o.result, "integer", integer, o.count)) return false;
    } else {
        usz top = integer.len - primary;
        usz first = top % secondary;
        if (first == 0) first = secondary;
        if (!intl_digit_part(o.ctx, o.state, o.parts, o.result, "integer", integer[0:first], o.count)) return false;
        usz pos = first;
        char[] group = intl_row_text(o.row, row.group);
        while (pos < top) {
            if (!out_part(o, "group", group)) return false;
            if (!intl_digit_part(o.ctx, o.state, o.parts, o.result, "integer", integer[pos:secondary], o.count)) return false;
            pos += secondary;
        }
        if (!out_part(o, "group", group)) return false;
        if (!intl_digit_part(o.ctx, o.state, o.parts, o.result, "integer", integer[top:primary], o.count)) return false;
    }
    if (dot < o.fixed.len) {
        if (!out_part(o, "decimal", intl_row_text(o.row, row.decimal))) return false;
        if (!intl_digit_part(o.ctx, o.state, o.parts, o.result, "fraction", o.fixed[dot + 1:o.fixed.len - dot - 1], o.count)) return false;
    }
    return true;
}

// Primary and secondary group sizes of a pattern's integer part; false when it has no grouping separator.
fn bool intl_group_sizes(char[] pattern, usz* primary, usz* secondary) {
    usz start = 0;
    while (start < pattern.len && pattern[start] != '#' && pattern[start] != '0') start++;
    usz end = start;
    while (end < pattern.len && (pattern[end] == '#' || pattern[end] == '0' || pattern[end] == ',')) end++;
    usz last = end;
    usz prev = end;
    for (usz i = start; i < end; i++) {
        if (pattern[i] == ',') { prev = last; last = i; }
    }
    if (last == end) return false;
    *primary = end - last - 1;
    *secondary = prev != end ? last - prev - 1 : *primary;
    return true;
}

// True when a pattern token that is not literal text starts at `i`.
fn bool intl_pattern_special(char[] pattern, usz i) {
    char c = pattern[i];
    if (c == ';' || c == '\'' || c == '#' || c == '0' || c == '-' || c == '+' || c == '%') return true;
    if (i + 1 < pattern.len && (uint)(char)c == 0xC2 && (uint)(char)pattern[i + 1] == 0xA4) return true;
    return i + 2 < pattern.len && (uint)(char)c == 0xE2 && (uint)(char)pattern[i + 1] == 0x80 && (uint)(char)pattern[i + 2] == 0xB0;
}

// The affix text with its quoting removed: 'x' is x and '' is a quote.
fn char[] intl_unquote(char[] text, StrBuf* out) {
    usz i = 0;
    while (i < text.len) {
        if (text[i] == '\'') {
            if (i + 1 < text.len && text[i + 1] == '\'') {
                out.append_char('\'');
                i += 2;
                continue;
            }
            // A quoted run is literal up to the closing quote.
            i++;
            while (i < text.len && text[i] != '\'') { out.append_char(text[i]); i++; }
            i++;
            continue;
        }
        out.append_char(text[i]);
        i++;
    }
    return out.bytes();
}

// Emits a CLDR number pattern. The first digit placeholder takes the core; ¤ takes
// the currency text, % and ‰ the row's symbols, and quoted text is literal.
fn bool intl_emit_pattern(IntlOutput* o, char[] pattern) {
    IntlLocaleRow row = intl_row(o.row);
    bool core_done = false;
    usz i = 0;
    while (i < pattern.len) {
        char c = pattern[i];
        if (c == ';') break;
        if (c == '\'') {
            if (i + 1 < pattern.len && pattern[i + 1] == '\'') {
                if (!out_part(o, "literal", "'")) return false;
                i += 2;
                continue;
            }
            usz end = i + 1;
            while (end < pattern.len && pattern[end] != '\'') end++;
            if (!out_part(o, "literal", pattern[i + 1:end - i - 1])) return false;
            i = end + 1;
            continue;
        }
        if (c == '#' || c == '0') {
            if (!core_done && !intl_emit_core(o)) return false;
            core_done = true;
            while (i < pattern.len && (pattern[i] == '#' || pattern[i] == '0' || pattern[i] == ',' || pattern[i] == '.')) i++;
            continue;
        }
        if (c == '-') { if (!out_part(o, "minusSign", intl_row_text(o.row, row.minus))) return false; i++; continue; }
        if (c == '+') { if (!out_part(o, "plusSign", intl_row_text(o.row, row.plus))) return false; i++; continue; }
        if (c == '%') { if (!out_part(o, "percentSign", intl_row_text(o.row, row.percent))) return false; i++; continue; }
        if (i + 1 < pattern.len && (uint)(char)c == 0xC2 && (uint)(char)pattern[i + 1] == 0xA4) {
            // A space is inserted between a digit and an alphabetic symbol edge, as the pattern
            // leaves no literal between them.
            char[] symbol = o.currency;
            bool before = i > 0 && (pattern[i - 1] == '#' || pattern[i - 1] == '0');
            bool after = i + 2 < pattern.len && (pattern[i + 2] == '#' || pattern[i + 2] == '0');
            if (before && symbol.len > 0 && locale_is_alpha(symbol[0]) && !out_part(o, "literal", " ")) return false;
            if (!out_part(o, "currency", symbol)) return false;
            if (after && symbol.len > 0 && locale_is_alpha(symbol[symbol.len - 1]) && !out_part(o, "literal", " ")) return false;
            i += 2;
            continue;
        }
        if (i + 2 < pattern.len && (uint)(char)c == 0xE2 && (uint)(char)pattern[i + 1] == 0x80 && (uint)(char)pattern[i + 2] == 0xB0) {
            if (!out_part(o, "perMille", intl_row_text(o.row, row.per_mille))) return false;
            i += 3;
            continue;
        }
        usz end = i + 1;
        while (end < pattern.len && !intl_pattern_special(pattern, end)) end++;
        if (!out_part(o, "literal", pattern[i:end - i])) return false;
        i = end;
    }
    return true;
}

// Slot of a plural category in a compact block: zero, one, two, few, many, other.
fn usz intl_category_slot(char[] name) {
    if (mem_eq_bytes(name, "zero")) return 0;
    if (mem_eq_bytes(name, "one")) return 1;
    if (mem_eq_bytes(name, "two")) return 2;
    if (mem_eq_bytes(name, "few")) return 3;
    if (mem_eq_bytes(name, "many")) return 4;
    return 5;
}

// The compact pattern of a magnitude for a plural slot, falling back to "other".
// An empty result means the row has no compact form at that magnitude.
fn char[] intl_compact_text(usz row, long magnitude, usz slot, bool long_style) {
    usz base = (usz)(magnitude - 3) * 6 + (long_style ? INTL_COMPACT_STYLE : 0);
    char[] text = intl_row_text(row, intl_row_compact_word(row, base + slot));
    if (text.len == 0 && slot != INTL_CATEGORY_OTHER) text = intl_row_text(row, intl_row_compact_word(row, base + INTL_CATEGORY_OTHER));
    return text;
}

// The magnitude whose compact pattern a value of 10^exponent uses, or 0 for none. A
// pattern of zeros alone ("0" for 10^3 in ja) leaves the number unscaled, as in ICU.
// Magnitudes past 10^14 use the 10^14 pattern and keep the remaining zeros in the mantissa.
fn long intl_compact_magnitude(IntlNumberState* settings, long exponent) {
    if (exponent < 3) return 0;
    long magnitude = math::min(exponent, 14L);
    char[] text = intl_compact_text((usz)settings.locale, magnitude, INTL_CATEGORY_OTHER, settings.compact_display == 1);
    foreach (c : text) if (c != '0' && c != '#') return magnitude;
    return 0;
}

// The power of ten a compact magnitude divides by: the pattern's zeros are the
// digits left before the affix.
fn long intl_compact_exponent(IntlNumberState* settings, long magnitude) {
    char[] text = intl_compact_text((usz)settings.locale, magnitude, INTL_CATEGORY_OTHER, settings.compact_display == 1);
    long zeros = 0;
    foreach (c : text) if (c == '0') zeros++;
    return magnitude - zeros + 1;
}

// The unit pattern for a width: 0 units, 1 unitsShort, 2 unitsNarrow. Long display
// reads "units"; short and narrow read their own widths.
const usz[3] INTL_UNIT_WIDTH = { 1, 2, 0 };

// The name a unit pattern wraps around its {0}: the text after the placeholder, or
// before it when nothing follows, with the spaces around it removed.
fn char[] intl_bare_name(char[] pattern) {
    usz at = 0;
    while (at + 2 < pattern.len && !(pattern[at] == '{' && pattern[at + 1] == '0' && pattern[at + 2] == '}')) at++;
    if (at + 2 >= pattern.len) return pattern;
    char[] after = pattern[at + 3:pattern.len - (at + 3)];
    while (after.len > 0 && after[0] == ' ') after = after[1:after.len - 1];
    while (after.len > 0 && after[after.len - 1] == ' ') after = after[0:after.len - 1];
    if (after.len > 0) return after;
    char[] before = pattern[0:at];
    while (before.len > 0 && before[before.len - 1] == ' ') before = before[0:before.len - 1];
    return before;
}

// Writes `template` with {0} and {1} replaced by `a` and `b`.
fn void intl_fill(char[] template, char[] a, char[] b, StrBuf* out) {
    usz i = 0;
    while (i < template.len) {
        if (i + 2 < template.len && template[i] == '{' && template[i + 2] == '}' && (template[i + 1] == '0' || template[i + 1] == '1')) {
            out.append_bytes(template[i + 1] == '0' ? a : b);
            i += 3;
            continue;
        }
        out.append_char(template[i]);
        i++;
    }
}

// The index into INTL_UNIT_COMPOUND_PAIRS' compounds for a numerator and denominator, or -1.
fn int intl_unit_compound_index(usz unit, usz denominator) {
    for (usz i = 0; i < INTL_UNIT_COMPOUND_PAIRS.len; i += 3) {
        if (INTL_UNIT_COMPOUND_PAIRS[i] == unit && INTL_UNIT_COMPOUND_PAIRS[i + 1] == denominator) return (int)INTL_UNIT_COMPOUND_PAIRS[i + 2];
    }
    return -1;
}

// The text a range pattern puts between its two values ("{0} - {1}" gives " - "), or empty
// when the pattern does not have both placeholders in order.
fn char[] intl_range_separator(char[] pattern) {
    usz start = 0;
    while (start + 2 < pattern.len && !(pattern[start] == '{' && pattern[start + 1] == '0' && pattern[start + 2] == '}')) start++;
    if (start + 2 >= pattern.len) return pattern[0:0];
    usz at = start + 3;
    while (at + 2 < pattern.len && !(pattern[at] == '{' && pattern[at + 1] == '1' && pattern[at + 2] == '}')) at++;
    if (at + 2 >= pattern.len) return pattern[0:0];
    return pattern[start + 3:at - (start + 3)];
}

// The range separator text without the spaces its pattern put around the dash.
fn char[] intl_trim_spaces(char[] s) {
    usz a = 0;
    usz b = s.len;
    while (a < b && s[a] == ' ') a++;
    while (b > a && s[b - 1] == ' ') b--;
    return s[a:b - a];
}

// The unit template for the number's plural form, written to `out`. The numerator keeps
// its own pattern ("{0} km"). Long units wrap it in the denominator's per-unit pattern
// ("{0} per hour"); otherwise the numerator and the denominator's bare name are joined by
// the compound per pattern ("{0}/{1}").
fn char[] intl_unit_template(BuiltinContext* ctx, IntlNumberState* state, bool one, StrBuf* out) {
    usz row = (usz)state.locale;
    usz width = INTL_UNIT_WIDTH[state.unit_display];
    char[] numerator = intl_unit_form(row, (usz)state.unit, width, one ? 0 : 1);
    if (state.denominator < 0) return numerator;
    // A compound unit ICU names directly ("時速 {0} キロメートル") uses that phrase. English keeps
    // the per-unit forms, which its golden output pins.
    if (row != 0) {
        int compound = intl_unit_compound_index((usz)state.unit, (usz)state.denominator);
        if (compound >= 0) {
            char[] phrase = intl_row_text(row, intl_row_unit_word(row, INTL_UNIT_COMPOUND_BASE + ((usz)compound * 3 + width) * 2 + (usz)(one ? 0 : 1)));
            if (phrase.len > 0) {
                out.append_bytes(phrase);
                return out.bytes();
            }
        }
    }
    // Long units phrase the denominator with their per-unit pattern ("per {0}"); short and
    // narrow units join the numerator and the denominator's short name with the compound.
    char[] per = width == 0 ? intl_unit_form(row, (usz)state.denominator, 0, 2) : "";
    if (per.len > 0) {
        intl_fill(per, numerator, "", out);
        return out.bytes();
    }
    // The denominator's singular name comes from the narrow form for short and narrow units,
    // which is "h" where unitsShort says "Std."; long units use their own name.
    char[] denominator = intl_unit_form(row, (usz)state.denominator, width == 0 ? 0 : 2, 0);
    if (denominator.len == 0) denominator = intl_unit_form(row, (usz)state.denominator, 1, 0);
    if (denominator.len == 0) denominator = intl_unit_form(row, (usz)state.denominator, 0, 0);
    intl_fill(intl_unit_compound(row, width), numerator, intl_bare_name(denominator), out);
    return out.bytes();
}

// The part of a decimal pattern before ';', and the part after it (empty when there is none).
fn char[] intl_positive_part(char[] pattern) {
    foreach (i, c : pattern) if (c == ';') return pattern[0:i];
    return pattern;
}

fn char[] intl_negative_part(char[] pattern) {
    foreach (i, c : pattern) if (c == ';') return pattern[i + 1:pattern.len - i - 1];
    return pattern[0:0];
}

// Appends the formatted number to `result` and, when `parts` is non-null,
// its parts from index `*count`. Returns false after throwing.
fn bool intl_format_number(BuiltinContext* ctx, IntlNumberState* state, TVal input, HObject* parts, uint* count, StrBuf* result) {
    IntlDecimal value;
    defer value.digits.free();
    IntlNumberState effective = *state;
    if (!intl_decimal(ctx, input, &value, false) || !intl_prepare(&value, &effective)) {
        if (!ctx.should_throw) builtin_throw(ctx, ctx.heap.err_proto, "Intl allocation failed");
        return false;
    }
    StrBuf fixed; fixed.init(ctx.heap);
    defer fixed.free();
    if (!intl_fixed(&value, &effective, &fixed)) { builtin_throw(ctx, ctx.heap.err_proto, "Intl allocation failed"); return false; }
    usz row = (usz)state.locale;
    IntlLocaleRow locale = intl_row(row);
    bool zero = !value.nan && !value.infinity && intl_zero(&value);
    bool minus = value.negative && !value.nan && state.sign_display != 1;
    if (state.sign_display == 3 || state.sign_display == 4) minus = minus && !zero;
    bool plus = !minus && (state.sign_display == 2 || (state.sign_display == 3 && !zero && !value.nan));
    bool accounting = minus && state.style == 2 && state.accounting && state.currency_display != 2;

    StrBuf unit_scratch; unit_scratch.init(ctx.heap);
    defer unit_scratch.free();
    char[] full = intl_row_text(row, locale.decimal_pattern);
    if (state.style == 2 && state.currency_display != 2) {
        full = intl_row_text(row, state.accounting ? locale.accounting_pattern : locale.currency_pattern);
    } else if (state.style == 1) {
        full = intl_row_text(row, locale.percent_pattern);
    }
    char[] positive = intl_positive_part(full);
    char[] negative = intl_negative_part(full);
    bool parens = accounting && negative.len > 0;
    if (parens) positive = negative;

    IntlOutput o = {
        .ctx = ctx, .state = state, .parts = parts, .count = count, .result = result, .row = row,
        .fixed = fixed.bytes(), .nan = value.nan, .infinity = value.infinity,
        .grouping_pattern = intl_positive_part(intl_row_text(row, locale.decimal_pattern)),
        .currency = state.style == 2 ? intl_currency_symbol(state) : fixed.bytes()[0:0],
    };
    // Unit patterns place the sign after their prefix ("每小時-987公里"), so they emit it below.
    if (minus && !parens && state.style != 3) { if (!out_part(&o, "minusSign", intl_row_text(row, locale.minus))) return false; }
    else if (plus && !parens && state.style != 3) { if (!out_part(&o, "plusSign", intl_row_text(row, locale.plus))) return false; }

    PluralOperands ops = intl_plural_operands(fixed.bytes(), (ulong)value.magnitude);
    bool numeric = !value.nan && !value.infinity;
    if (numeric && state.notation > 1) {
        // Scientific notation: the mantissa and the exponent, with no affixes.
        if (!intl_emit_core(&o)) return false;
        if (!out_part(&o, "exponentSeparator", intl_row_text(row, locale.exponential))) return false;
        if (value.exponent < 0 && !out_part(&o, "exponentMinusSign", intl_row_text(row, locale.minus))) return false;
        char[24] exponent;
        int n = hstring::int_to_buf(math::abs(value.exponent), &exponent, 24);
        if (!intl_digit_part(ctx, state, parts, result, "exponentInteger", exponent[:n], count)) return false;
        if (state.style == 1 && !out_part(&o, "percentSign", intl_row_text(row, locale.percent))) return false;
    } else if (state.style == 3) {
        bool one = numeric && mem_eq_bytes(intl_plural_category(intl_row_text(row, locale.cardinal), &ops), "one");
        StrBuf unquoted; unquoted.init(ctx.heap);
        defer unquoted.free();
        char[] template = intl_unquote(intl_unit_template(ctx, state, one, &unit_scratch), &unquoted);
        usz at = 0;
        while (at + 2 < template.len && !(template[at] == '{' && template[at + 1] == '0' && template[at + 2] == '}')) at++;
        if (!intl_emit_affix(&o, template[0:at], "unit")) return false;
        if (minus && !parens) { if (!out_part(&o, "minusSign", intl_row_text(row, locale.minus))) return false; }
        else if (plus && !parens) { if (!out_part(&o, "plusSign", intl_row_text(row, locale.plus))) return false; }
        if (!intl_emit_core(&o)) return false;
        if (at + 3 <= template.len && !intl_emit_affix(&o, template[at + 3:template.len - (at + 3)], "unit")) return false;
    } else if (numeric && state.notation == 1 && value.magnitude > 0) {
        char[] category = intl_plural_category(intl_row_text(row, locale.cardinal), &ops);
        StrBuf unquoted; unquoted.init(ctx.heap);
        defer unquoted.free();
        char[] text = intl_unquote(intl_compact_text(row, value.magnitude, intl_category_slot(category), state.compact_display == 1), &unquoted);
        usz at = 0;
        while (at < text.len && text[at] != '0') at++;
        usz last = text.len;
        while (last > at && text[last - 1] != '0') last--;
        if (!intl_emit_affix(&o, text[0:at], "compact")) return false;
        if (!intl_emit_core(&o)) return false;
        if (last < text.len && !intl_emit_affix(&o, text[last:text.len - last], "compact")) return false;
    } else {
        if (!intl_emit_pattern(&o, positive)) return false;
        if (state.style == 2 && state.currency_display == 2) {
            if (!out_part(&o, "literal", " ")) return false;
            char[96] name_scratch;
            if (!out_part(&o, "currency", intl_currency_name(state, numeric && mem_eq_bytes(intl_plural_category(intl_row_text(row, locale.cardinal), &ops), "one"), name_scratch[..]))) return false;
        }
    }
    if (result.failed || ctx.heap.has_error) { builtin_throw(ctx, ctx.heap.err_proto, "Intl allocation failed"); return false; }
    return true;
}

fn void intl_render(BuiltinContext* ctx, IntlNumberState* state, TVal input, bool as_parts) {
    StrBuf result; result.init(ctx.heap);
    defer result.free();
    HObject* parts = as_parts ? intl_array(ctx) : null;
    if (ctx.should_throw) return;
    uint count = 0;
    if (!intl_format_number(ctx, state, input, parts, &count, &result)) return;
    if (as_parts) {
        array_set_length(parts, count, ctx.heap);
        ctx.result_object(parts);
    } else { ctx.result_string(builtin_intern_string(ctx.heap, result.bytes())); }
}

fn void builtin_intl_number_format_get(BuiltinContext* ctx) {
    HObject* actual;
    IntlNumberState* state = intl_receiver(ctx, false, true, &actual);
    if (state == null) return;
    if (state.bound_format == null) {
        HObject* bound = ctx.heap.alloc_object(ObjClass.FUNCTION) ?? null;
        if (bound == null) { builtin_throw(ctx, ctx.heap.err_proto, "Intl allocation failed"); return; }
        ctx.heap.set_prototype(bound, ctx.heap.function_proto);
        (*bound.extra_ptr()).func.builtin_fn_index = (int)Builtin.BOUND_CALL.ordinal;
        TVal target; target.set_lightfunc((void*)(usz)Builtin.INTL_NUMBER_FORMAT_CALL.ordinal);
        TVal receiver; receiver.set_object(actual);
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
        // A trailing currency symbol ("3 – 5 €") is shared across the range; a leading one repeats.
        bool trailing_currency = state.style == 2 && alen > 0 && mem_eq_bytes(intl_part_field(ctx, ap, alen - 1, "type"), "currency");
        if (trailing_currency || state.style == 3 || state.notation != 0 || state.currency_display == 2) {
            while (suffix + prefix < alen && suffix + prefix < blen &&
                   intl_same_part(ctx, ap, alen - suffix - 1, bp, blen - suffix - 1)) {
                char[] type = intl_part_field(ctx, ap, alen - suffix - 1, "type");
                if (mem_eq_bytes(type, "integer") || mem_eq_bytes(type, "fraction") || mem_eq_bytes(type, "decimal")) break;
                suffix++;
            }
        }
        for (uint i = 0; i < prefix; i++) intl_range_copy(ctx, out, ap, i, "shared", &count, &text);
        for (uint i = prefix; i < alen - suffix; i++) intl_range_copy(ctx, out, ap, i, "startRange", &count, &text);
        // The row's range pattern ("{0} - {1}") supplies the separator text; without one, the
        // dash is spaced for integer currency ranges.
        char[] range_pattern = intl_row_text((usz)state.locale, intl_row((usz)state.locale).range);
        // Integer currency ranges space the dash whatever the pattern's spacing ("3 – 5 €").
        char[] dash = intl_range_separator(range_pattern);
        if (dash.len == 0) dash = "\u2013";
        char[32] spaced;
        if (state.style == 2 && state.min_fraction == 0) {
            dash = intl_trim_spaces(dash);
            spaced[0] = ' ';
            for (usz k = 0; k < dash.len; k++) spaced[1 + k] = dash[k];
            spaced[1 + dash.len] = ' ';
            dash = spaced[0:dash.len + 2];
        }
        intl_part(ctx, out, &text, "literal", dash, &count);
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
    // Compact selection reads n, i, v and f from the unscaled number and takes the magnitude as e,
    // so 1000000 under fr compact is "many" (i = 1000000, e = 6) rather than the "one" of 1.
    IntlNumberState standard = *state;
    standard.notation = 0;
    IntlDecimal plain;
    defer plain.digits.free();
    if (!intl_decimal(ctx, input, &plain, true) || !intl_prepare(&plain, &standard)) return "other";
    StrBuf fixed; fixed.init(ctx.heap);
    defer fixed.free();
    if (!intl_fixed(&plain, &standard, &fixed)) { builtin_throw(ctx, ctx.heap.err_proto, "Intl allocation failed"); return "other"; }
    PluralOperands ops = intl_plural_operands(fixed.bytes(), (ulong)value.magnitude);
    IntlLocaleRow locale = intl_row((usz)state.locale);
    return intl_plural_category(intl_row_text((usz)state.locale, state.ordinal ? locale.ordinal : locale.cardinal), &ops);
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
