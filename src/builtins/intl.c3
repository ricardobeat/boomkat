// English Intl services share decimal rounding and the engine's host-class
// lifecycle, so formatter state does not grow HObjectExtra.
module boomkat::builtins;
import boomkat::types;
import boomkat::heap;
import boomkat::hobject;
import boomkat::hstring;
import boomkat::env;
import std::math;

struct IntlNumberState {
    HObject* bound_format;
    bool plural;
    bool ordinal;
    bool us_locale;
    int grouping;
    int style; // decimal, percent, currency, unit
    int currency_display;
    bool accounting;
    char[3] currency;
    int unit;
    int denominator;
    int unit_display;
    int notation;
    int compact_display;
    int sign_display;
    int rounding_increment;
    int rounding_mode;
    int rounding_priority;
    bool strip_zero;
    int min_integer;
    int min_fraction;
    int max_fraction;
    int min_significant;
    int max_significant;
}

fn void intl_finalize(void* payload, void* udata) {
    Heap* hp = (Heap*)udata;
    if (payload != null) hp.free_func(hp.heap_udata, payload);
}

fn void intl_mark(void* payload, Heap* hp, void* udata) {
    if (payload != null) hp.mark_hobject(((IntlNumberState*)payload).bound_format);
}

fn bool intl_put(Heap* hp, HObject* obj, char[] name, TVal value, PropFlags flags = hobject::PROP_FLAGS_WEC) {
    HString* key = builtin_intern_string(hp, name);
    if (key == null) return false;
    obj.put_prop(key, value, flags, hp);
    return !hp.has_error;
}

fn bool intl_put_string(Heap* hp, HObject* obj, char[] name, char[] value, PropFlags flags = hobject::PROP_FLAGS_WEC) {
    HString* s = builtin_intern_string(hp, value);
    if (s == null) return false;
    TVal v; v.set_string_borrowed(s);
    return intl_put(hp, obj, name, v, flags);
}

fn void intl_put_int(Heap* hp, HObject* obj, char[] name, int value) {
    TVal v; v.set_fastint(value);
    (void)intl_put(hp, obj, name, v);
}

fn long intl_class(Heap* hp, bool plural) {
    char[] name = plural ? "Intl.PluralRules" : "Intl.NumberFormat";
    for (uint i = 0; i < hp.host_class_count; i++) {
        HostClassEntry* entry = hp.host_class_at(i);
        if (entry.finalizer != (void*)&intl_finalize) continue;
        HString* s = entry.name.borrow();
        if (s != null && mem_eq_bytes(s.get_cstr()[:s.blen], name)) return (long)i;
    }
    return -1;
}

fn IntlNumberState* intl_receiver(BuiltinContext* ctx, bool plural) {
    TVal v = ctx.regs[ctx.base_reg - 1];
    if (v.is_object()) {
        HObject* obj = (HObject*)v.get_heapptr();
        if (obj != null && obj.get_class() == ObjClass.HOST &&
            (long)(*obj.extra_ptr()).host.class_id == intl_class(ctx.heap, plural)) {
            return (IntlNumberState*)(*obj.extra_ptr()).host.payload;
        }
    }
    builtin_throw(ctx, ctx.heap.type_err_proto, "incompatible Intl receiver");
    return null;
}

fn HObject* intl_array(BuiltinContext* ctx) {
    HObject* obj = ctx.heap.alloc_object(ObjClass.ARRAY) ?? null;
    if (obj == null) {
        builtin_throw(ctx, ctx.heap.err_proto, "Intl allocation failed");
        return null;
    }
    ctx.heap.set_prototype(obj, ctx.heap.array_proto);
    array_set_length(obj, 0, ctx.heap);
    return obj;
}

// Locale-list traversal preserves HasProperty/Get ordering for proxies and
// sparse arrays. en and en-US share the only shipped number patterns.
fn HObject* intl_locales(BuiltinContext* ctx, TVal locales) {
    HObject* out = intl_array(ctx);
    if (out == null || locales.is_undefined()) return out;
    bool single = locales.is_string() && !((HString*)locales.get_heapptr()).is_symbol();
    HObject* list = null;
    ulong len = single ? 1 : 0;
    if (locales.is_null()) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "locales is null");
        return out;
    }
    if (locales.is_object()) {
        list = (HObject*)locales.get_heapptr();
        TVal? length = builtins_generic_get(list, ctx.heap.str(heap::BuiltinStr.LENGTH), ctx);
        if (ctx.should_throw) return out;
        if (try v = length) {
            double n = builtin_to_number_vm(ctx, &v);
            if (ctx.should_throw) return out;
            if (!math::is_nan(n) && n > 0) len = (ulong)math::min(math::floor(n), (double)types::MAX_SAFE_INT);
        }
    }
    uint count = 0;
    for (ulong i = 0; i < len; i++) {
        TVal value = locales;
        if (!single) {
            HString* key = ctx.heap.int_to_hstring((long)i);
            bool exists;
            if (!js_has_property(ctx.vm, ctx.heap, list, key, &exists)) { proxy_ctx_ok(ctx); return out; }
            if (!exists) continue;
            TVal? found = builtins_generic_get(list, key, ctx);
            if (ctx.should_throw) return out;
            if (try v = found) { value = v; } else { continue; }
        }
        if (!value.is_string() && !value.is_object()) {
            builtin_throw(ctx, ctx.heap.type_err_proto, "locale must be a string or object");
            return out;
        }
        HString* tag = builtin_to_string_vm(ctx, &value);
        if (ctx.should_throw || tag == null) return out;
        char[] text = tag.get_cstr()[:tag.blen];
        if (!locale_is_well_formed(text)) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "invalid language tag");
            return out;
        }
        char[][64] parts;
        int n = locale_split(text, &parts);
        if (n < 1 || !locale_eq_ci(parts[0], "en")) continue;
        StrBuf canonical; canonical.init(ctx.heap);
        defer canonical.free();
        for (int k = 0; k < n; k++) {
            if (k > 0) canonical.append_char('-');
            bool region = k == 1 && parts[k].len == 2;
            bool script = k == 1 && parts[k].len == 4;
            if (k == 2 && parts[1].len == 4 && parts[k].len == 2) region = true;
            foreach (j, c : parts[k]) {
                if (c >= 'A' && c <= 'Z') c += 'a' - 'A';
                if ((region || (script && j == 0)) && c >= 'a' && c <= 'z') c -= 'a' - 'A';
                canonical.append_char(c);
            }
        }
        HString* normalized = builtin_intern_string(ctx.heap, canonical.bytes());
        bool duplicate = false;
        for (uint k = 0; k < count; k++) {
            TVal? old = out.get_prop(ctx.heap.int_to_hstring(k), ctx.heap);
            if (try v = old) { if (v.get_heapptr() == normalized) duplicate = true; }
        }
        if (!duplicate) {
            TVal v; v.set_string_borrowed(normalized);
            array_set_elem(out, count++, v, ctx.heap);
        }
    }
    array_set_length(out, count, ctx.heap);
    return out;
}

fn HObject* intl_options(BuiltinContext* ctx, TVal options) {
    if (options.is_undefined()) return null;
    if (options.is_null()) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "options is null");
        return null;
    }
    HObject* object = to_object_wrapper(ctx.heap, options);
    if (object == null) builtin_throw(ctx, ctx.heap.err_proto, "Intl allocation failed");
    return object;
}

fn int intl_choice(BuiltinContext* ctx, HObject* opts, char[] key, char[][] values, int fallback = 0) {
    HString* s = date_get_raw_string_option(ctx, opts, key);
    if (ctx.should_throw || s == null) return fallback;
    foreach (i, value : values) {
        if (mem_eq_bytes(s.get_cstr()[:s.blen], value)) return (int)i;
    }
    builtin_throw(ctx, ctx.heap.range_err_proto, "invalid Intl option");
    return fallback;
}

fn TVal intl_option(BuiltinContext* ctx, HObject* opts, char[] key) {
    TVal value; value.set_undefined();
    if (opts == null) return value;
    TVal? found = builtins_generic_get(opts, builtin_intern_string(ctx.heap, key), ctx);
    if (try v = found) return v;
    return value;
}

fn int intl_digit(BuiltinContext* ctx, TVal v, int min, int max, int fallback) {
    if (v.is_undefined()) return fallback;
    double n = builtin_to_number_vm(ctx, &v);
    if (ctx.should_throw) return fallback;
    if (math::is_nan(n) || n < min || n > max) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "Intl digit option out of range");
        return fallback;
    }
    return (int)math::floor(n);
}

fn int intl_currency_digits(char[] code) {
    int index = intl_currency_index(code);
    return index < 0 ? 2 : (int)INTL_CURRENCIES[index].digits;
}

fn char[] intl_data_string(ushort offset) {
    usz end = offset;
    while (end < intl_english_strings.len && intl_english_strings[end] != 0) end++;
    return intl_english_strings[offset:end - offset];
}

fn int intl_currency_index(char[] code) {
    uint key = ((uint)code[0] << 16) | ((uint)code[1] << 8) | (uint)code[2];
    int low = 0;
    int high = (int)INTL_CURRENCIES.len;
    while (low < high) {
        int mid = low + (high - low) / 2;
        if (INTL_CURRENCIES[mid].code < key) { low = mid + 1; } else { high = mid; }
    }
    return low < (int)INTL_CURRENCIES.len && INTL_CURRENCIES[low].code == key ? low : -1;
}

fn int intl_unit_index(char[] unit) {
    foreach (i, entry : INTL_UNITS) if (mem_eq_bytes(unit, entry.name)) return (int)i;
    return -1;
}

fn bool intl_init_options(BuiltinContext* ctx, IntlNumberState* state, TVal locales, TVal options, bool plural) {
    *state = {};
    state.plural = plural;
    state.grouping = 1;
    state.us_locale = true;
    HObject* supported = intl_locales(ctx, locales);
    if (ctx.should_throw) return false;
    HObject* opts = intl_options(ctx, options);
    if (ctx.should_throw) return false;
    (void)intl_choice(ctx, opts, "localeMatcher", {"best fit", "lookup"});
    if (ctx.should_throw) return false;
    if (supported != null) {
        TVal? first = supported.get_prop(ctx.heap.int_to_hstring(0), ctx.heap);
        if (try v = first) {
            HString* tag = (HString*)v.get_heapptr();
            state.us_locale = tag.blen >= 5 && locale_eq_ci(tag.get_cstr()[:5], "en-us");
        }
    }
    int digits = 0;
    if (plural) {
        state.ordinal = intl_choice(ctx, opts, "type", {"cardinal", "ordinal"}) == 1;
        if (ctx.should_throw) return false;
        state.notation = intl_choice(ctx, opts, "notation", {"standard", "compact", "scientific", "engineering"});
        if (ctx.should_throw) return false;
        state.compact_display = intl_choice(ctx, opts, "compactDisplay", {"short", "long"});
    } else {
        HString* numbering = date_get_raw_string_option(ctx, opts, "numberingSystem");
        if (ctx.should_throw) return false;
        if (numbering != null && !date_is_unicode_type_subtag(numbering.get_cstr()[:numbering.blen])) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "invalid numbering system");
            return false;
        }
        state.style = intl_choice(ctx, opts, "style", {"decimal", "percent", "currency", "unit"});
        if (ctx.should_throw) return false;
        HString* currency = date_get_raw_string_option(ctx, opts, "currency");
        if (ctx.should_throw) return false;
        if (currency != null) {
            char[] code = currency.get_cstr()[:currency.blen];
            if (code.len != 3 || !locale_all_alpha(code)) {
                builtin_throw(ctx, ctx.heap.range_err_proto, "invalid currency code");
                return false;
            }
            foreach (i, c : code) state.currency[i] = c >= 'a' && c <= 'z' ? c - ('a' - 'A') : c;
        } else if (state.style == 2) {
            builtin_throw(ctx, ctx.heap.type_err_proto, "currency is required");
            return false;
        }
        state.currency_display = intl_choice(ctx, opts, "currencyDisplay", {"symbol", "code", "name", "narrowSymbol"});
        if (ctx.should_throw) return false;
        state.accounting = intl_choice(ctx, opts, "currencySign", {"standard", "accounting"}) == 1;
        if (ctx.should_throw) return false;
        HString* unit = date_get_raw_string_option(ctx, opts, "unit");
        if (ctx.should_throw) return false;
        state.unit = -1;
        state.denominator = -1;
        if (unit != null) {
            char[] text = unit.get_cstr()[:unit.blen];
            usz per = text.len;
            for (usz i = 0; i + 5 <= text.len; i++) {
                if (mem_eq_bytes(text[i:5], "-per-")) { per = i; break; }
            }
            state.unit = intl_unit_index(text[:per]);
            if (per < text.len) state.denominator = intl_unit_index(text[per + 5:text.len - per - 5]);
            if (state.unit < 0 || (per < text.len && state.denominator < 0)) {
                builtin_throw(ctx, ctx.heap.range_err_proto, "invalid unit");
                return false;
            }
        } else if (state.style == 3) {
            builtin_throw(ctx, ctx.heap.type_err_proto, "unit is required");
            return false;
        }
        state.unit_display = intl_choice(ctx, opts, "unitDisplay", {"short", "narrow", "long"});
        if (ctx.should_throw) return false;
        state.notation = intl_choice(ctx, opts, "notation", {"standard", "compact", "scientific", "engineering"});
        digits = state.style == 2 && state.notation == 0 ? intl_currency_digits(state.currency[..]) : 0;
    }
    if (ctx.should_throw) return false;
    state.min_integer = intl_digit(ctx, intl_option(ctx, opts, "minimumIntegerDigits"), 1, 21, 1);
    if (ctx.should_throw) return false;
    TVal min_frac = intl_option(ctx, opts, "minimumFractionDigits");
    if (ctx.should_throw) return false;
    TVal max_frac = intl_option(ctx, opts, "maximumFractionDigits");
    if (ctx.should_throw) return false;
    TVal min_sig = intl_option(ctx, opts, "minimumSignificantDigits");
    if (ctx.should_throw) return false;
    TVal max_sig = intl_option(ctx, opts, "maximumSignificantDigits");
    if (ctx.should_throw) return false;
    state.rounding_increment = intl_digit(ctx, intl_option(ctx, opts, "roundingIncrement"), 1, 5000, 1);
    if (ctx.should_throw) return false;
    int[*] increments = {1, 2, 5, 10, 20, 25, 50, 100, 200, 250, 500, 1000, 2000, 2500, 5000};
    bool valid_increment = false;
    foreach (increment : increments) if (increment == state.rounding_increment) valid_increment = true;
    if (!valid_increment) { builtin_throw(ctx, ctx.heap.range_err_proto, "invalid rounding increment"); return false; }
    state.rounding_mode = intl_choice(ctx, opts, "roundingMode", {"ceil", "floor", "expand", "trunc", "halfCeil", "halfFloor", "halfExpand", "halfTrunc", "halfEven"}, 6);
    if (ctx.should_throw) return false;
    state.rounding_priority = intl_choice(ctx, opts, "roundingPriority", {"auto", "morePrecision", "lessPrecision"});
    if (ctx.should_throw) return false;
    state.strip_zero = intl_choice(ctx, opts, "trailingZeroDisplay", {"auto", "stripIfInteger"}) == 1;
    if (ctx.should_throw) return false;
    bool significant = !min_sig.is_undefined() || !max_sig.is_undefined();
    bool fraction = !min_frac.is_undefined() || !max_frac.is_undefined();
    if (significant || state.rounding_priority != 0) {
        state.min_significant = intl_digit(ctx, min_sig, 1, 21, 1);
        if (ctx.should_throw) return false;
        state.max_significant = intl_digit(ctx, max_sig, state.min_significant, 21, 21);
    }
    if (!significant || state.rounding_priority != 0) {
        state.min_fraction = intl_digit(ctx, min_frac, 0, 100, digits);
        if (ctx.should_throw) return false;
        int default_max = state.rounding_increment != 1 ? digits : state.style == 1 ? 0 : state.style == 2 && state.notation == 0 ? digits : 3;
        state.max_fraction = intl_digit(ctx, max_frac, 0, 100, math::max(state.min_fraction, default_max));
        if (min_frac.is_undefined()) state.min_fraction = math::min(digits, state.max_fraction);
        if (state.min_fraction > state.max_fraction) builtin_throw(ctx, ctx.heap.range_err_proto, "minimumFractionDigits exceeds maximumFractionDigits");
    }
    if (ctx.should_throw) return false;
    if (state.rounding_priority == 0 && state.notation == 1 && !significant && !fraction) {
        state.min_fraction = 0;
        state.max_fraction = 0;
        state.min_significant = 1;
        state.max_significant = 2;
        state.rounding_priority = 1;
    }
    if (state.rounding_increment != 1) {
        if (state.max_significant != 0 || state.rounding_priority != 0) {
            builtin_throw(ctx, ctx.heap.type_err_proto, "roundingIncrement requires fraction precision");
            return false;
        }
        if (state.min_fraction != state.max_fraction) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "roundingIncrement requires equal fraction digits");
            return false;
        }
    }
    if (!plural) {
        state.compact_display = intl_choice(ctx, opts, "compactDisplay", {"short", "long"});
        if (ctx.should_throw) return false;
        state.grouping = state.notation == 1 ? 3 : 1;
        TVal grouping = intl_option(ctx, opts, "useGrouping");
        if (ctx.should_throw) return false;
        if (!grouping.is_undefined()) {
            if (!builtin_to_boolean(&grouping)) { state.grouping = 0; }
            else if (grouping.is_boolean()) { state.grouping = 2; }
            else {
                HString* s = builtin_to_string_vm(ctx, &grouping);
                if (ctx.should_throw) return false;
                char[] text = s.get_cstr()[:s.blen];
                if (mem_eq_bytes(text, "auto")) { state.grouping = 1; }
                else if (mem_eq_bytes(text, "always")) { state.grouping = 2; }
                else if (mem_eq_bytes(text, "min2")) { state.grouping = 3; }
                else if (!mem_eq_bytes(text, "true") && !mem_eq_bytes(text, "false")) {
                    builtin_throw(ctx, ctx.heap.range_err_proto, "invalid grouping option"); return false;
                }
            }
        }
        state.sign_display = intl_choice(ctx, opts, "signDisplay", {"auto", "never", "always", "exceptZero", "negative"});
    }
    return !ctx.should_throw;
}

fn void intl_construct(BuiltinContext* ctx, bool plural) {
    if (plural && !ctx.is_constructor) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "PluralRules requires new");
        return;
    }
    IntlNumberState settings;
    if (!intl_init_options(ctx, &settings, builtin_arg(ctx, 0), builtin_arg(ctx, 1), plural)) return;
    long id = intl_class(ctx.heap, plural);
    HObject* proto = builtin_proto_from_new_target(ctx, ctx.heap.host_class_at((uint)id).proto);
    if (ctx.should_throw) return;
    HObject* obj = ctx.heap.alloc_object(ObjClass.HOST) ?? null;
    if (obj == null) { builtin_throw(ctx, ctx.heap.err_proto, "Intl allocation failed"); return; }
    (*obj.extra_ptr()).host.class_id = (uint)id;
    IntlNumberState* state = (IntlNumberState*)ctx.heap.alloc_func(ctx.heap.heap_udata, IntlNumberState::size);
    if (state == null) { builtin_throw(ctx, ctx.heap.err_proto, "Intl allocation failed"); return; }
    *state = settings;
    (*obj.extra_ptr()).host.payload = state;
    ctx.heap.set_prototype(obj, proto);
    ctx.result_object(obj);
}

fn void builtin_intl_number_format(BuiltinContext* ctx) { intl_construct(ctx, false); }
fn void builtin_intl_plural_rules(BuiltinContext* ctx) { intl_construct(ctx, true); }

fn void builtin_intl_supported_locales(BuiltinContext* ctx) {
    HObject* locales = intl_locales(ctx, builtin_arg(ctx, 0));
    if (ctx.should_throw) return;
    HObject* opts = intl_options(ctx, builtin_arg(ctx, 1));
    if (ctx.should_throw) return;
    (void)intl_choice(ctx, opts, "localeMatcher", {"best fit", "lookup"});
    if (!ctx.should_throw) ctx.result_object(locales);
}

fn HObject* intl_resolved(BuiltinContext* ctx, IntlNumberState* state) {
    HObject* out = ctx.heap.alloc_object(ObjClass.OBJECT) ?? null;
    if (out == null) { builtin_throw(ctx, ctx.heap.err_proto, "Intl allocation failed"); return null; }
    ctx.heap.set_prototype(out, ctx.heap.object_proto);
    intl_put_string(ctx.heap, out, "locale", state.us_locale ? "en-US" : "en");
    if (state.plural) {
        intl_put_string(ctx.heap, out, "type", state.ordinal ? "ordinal" : "cardinal");
        char[][] notations = {"standard", "compact", "scientific", "engineering"};
        intl_put_string(ctx.heap, out, "notation", notations[state.notation]);
    } else {
        intl_put_string(ctx.heap, out, "numberingSystem", "latn");
        char[][] styles = {"decimal", "percent", "currency", "unit"};
        intl_put_string(ctx.heap, out, "style", styles[state.style]);
        if (state.style == 2) {
            intl_put_string(ctx.heap, out, "currency", state.currency[..]);
            char[][] displays = {"symbol", "code", "name", "narrowSymbol"};
            intl_put_string(ctx.heap, out, "currencyDisplay", displays[state.currency_display]);
            intl_put_string(ctx.heap, out, "currencySign", state.accounting ? "accounting" : "standard");
        }
        if (state.style == 3) {
            StrBuf unit; unit.init(ctx.heap); defer unit.free();
            unit.append_bytes(INTL_UNITS[state.unit].name);
            if (state.denominator >= 0) { unit.append_bytes("-per-"); unit.append_bytes(INTL_UNITS[state.denominator].name); }
            intl_put_string(ctx.heap, out, "unit", unit.bytes());
            char[][] displays = {"short", "narrow", "long"};
            intl_put_string(ctx.heap, out, "unitDisplay", displays[state.unit_display]);
        }
    }
    intl_put_int(ctx.heap, out, "minimumIntegerDigits", state.min_integer);
    if (state.max_significant == 0 || state.rounding_priority != 0) {
        intl_put_int(ctx.heap, out, "minimumFractionDigits", state.min_fraction);
        intl_put_int(ctx.heap, out, "maximumFractionDigits", state.max_fraction);
    }
    if (state.max_significant != 0) {
        intl_put_int(ctx.heap, out, "minimumSignificantDigits", state.min_significant);
        intl_put_int(ctx.heap, out, "maximumSignificantDigits", state.max_significant);
    }
    if (state.plural) {
        HObject* categories = intl_array(ctx);
        if (categories == null) return out;
        char[][] names = state.ordinal ? (char[][]){"one", "two", "few", "other"} : (char[][]){"one", "other"};
        foreach (i, name : names) {
            TVal v; v.set_string_borrowed(builtin_intern_string(ctx.heap, name));
            array_set_elem(categories, (uint)i, v, ctx.heap);
        }
        array_set_length(categories, (uint)names.len, ctx.heap);
        TVal v; v.set_object(categories);
        intl_put(ctx.heap, out, "pluralCategories", v);
    } else {
        if (state.grouping == 0) {
            TVal v; v.set_boolean(false); intl_put(ctx.heap, out, "useGrouping", v);
        } else {
            char[][] groups = {"", "auto", "always", "min2"};
            intl_put_string(ctx.heap, out, "useGrouping", groups[state.grouping]);
        }
        char[][] notations = {"standard", "compact", "scientific", "engineering"};
        intl_put_string(ctx.heap, out, "notation", notations[state.notation]);
    }
    if (state.notation == 1) intl_put_string(ctx.heap, out, "compactDisplay", state.compact_display == 0 ? "short" : "long");
    if (!state.plural) {
        char[][] signs = {"auto", "never", "always", "exceptZero", "negative"};
        intl_put_string(ctx.heap, out, "signDisplay", signs[state.sign_display]);
    }
    intl_put_int(ctx.heap, out, "roundingIncrement", state.rounding_increment);
    char[][] modes = {"ceil", "floor", "expand", "trunc", "halfCeil", "halfFloor", "halfExpand", "halfTrunc", "halfEven"};
    intl_put_string(ctx.heap, out, "roundingMode", modes[state.rounding_mode]);
    char[][] priorities = {"auto", "morePrecision", "lessPrecision"};
    intl_put_string(ctx.heap, out, "roundingPriority", priorities[state.rounding_priority]);
    intl_put_string(ctx.heap, out, "trailingZeroDisplay", state.strip_zero ? "stripIfInteger" : "auto");
    return out;
}

fn void builtin_intl_number_resolved(BuiltinContext* ctx) {
    IntlNumberState* state = intl_receiver(ctx, false);
    if (state != null) ctx.result_object(intl_resolved(ctx, state));
}

fn void builtin_intl_plural_resolved(BuiltinContext* ctx) {
    IntlNumberState* state = intl_receiver(ctx, true);
    if (state != null) ctx.result_object(intl_resolved(ctx, state));
}

fn bool register_intl(EnvRecord* global_env, Heap* hp) {
    HObject* ns = hp.alloc_object(ObjClass.OBJECT) ?? null;
    if (ns == null) return false;
    hp.set_prototype(ns, hp.object_proto);
    TVal tag; tag.set_string_borrowed(builtin_intern_string(hp, "Intl"));
    ns.put_prop(ensure_tostringtag_symbol(hp), tag, hobject::PROP_FLAGS_NWC, hp);
    for (int i = 0; i < 2; i++) {
        bool plural = i == 1;
        char[] name = plural ? "PluralRules" : "NumberFormat";
        char[] class_name = plural ? "Intl.PluralRules" : "Intl.NumberFormat";
        HObject* proto = hp.alloc_object(ObjClass.OBJECT) ?? null;
        HObject* ctor = hp.alloc_object(ObjClass.FUNCTION) ?? null;
        if (proto == null || ctor == null) return false;
        hp.set_prototype(proto, hp.object_proto);
        hp.set_prototype(ctor, hp.function_proto);
        (*ctor.extra_ptr()).func.builtin_fn_index = (int)(plural ? Builtin.INTL_PLURAL_RULES.ordinal : Builtin.INTL_NUMBER_FORMAT.ordinal);
        ctor.flags.callable = true;
        ctor.flags.constructable = true;
        set_func_ctor_name_length(ctor, hp, name, 0);
        TVal v; v.set_object(proto);
        intl_put(hp, ctor, "prototype", v, (PropFlags){});
        v.set_object(ctor);
        intl_put(hp, proto, "constructor", v, hobject::PROP_FLAGS_WC);
        intl_put(hp, ns, name, v, hobject::PROP_FLAGS_WC);
        tag.set_string_borrowed(builtin_intern_string(hp, class_name));
        proto.put_prop(ensure_tostringtag_symbol(hp), tag, hobject::PROP_FLAGS_NWC, hp);
        if (hp.register_host_class((void*)&intl_finalize, (void*)&intl_mark, hp,
                                  builtin_intern_string(hp, class_name), proto) < 0) return false;
        if (!register_string_proto_method(ctor, hp, "supportedLocalesOf", Builtin.INTL_SUPPORTED_LOCALES.ordinal)) return false;
        if (!register_string_proto_method(proto, hp, "resolvedOptions", plural ? Builtin.INTL_PLURAL_RESOLVED.ordinal : Builtin.INTL_NUMBER_RESOLVED.ordinal)) return false;
        if (plural) {
            if (!register_string_proto_method(proto, hp, "select", Builtin.INTL_PLURAL_SELECT.ordinal)) return false;
            if (!register_string_proto_method(proto, hp, "selectRange", Builtin.INTL_PLURAL_RANGE.ordinal)) return false;
        } else {
            if (!register_proto_getter_accessor(proto, hp, "format", Builtin.INTL_NUMBER_FORMAT_GET.ordinal)) return false;
            TVal? accessor = proto.get_prop(builtin_intern_string(hp, "format"), hp);
            if (try access_value = accessor) {
                TVal getter = hobject::hobject_access_getter(access_value);
                set_func_ctor_name((HObject*)getter.get_heapptr(), hp, "get format");
            }
            if (!register_string_proto_method(proto, hp, "formatToParts", Builtin.INTL_NUMBER_PARTS.ordinal)) return false;
            if (!register_string_proto_method(proto, hp, "formatRange", Builtin.INTL_NUMBER_RANGE.ordinal)) return false;
            if (!register_string_proto_method(proto, hp, "formatRangeToParts", Builtin.INTL_NUMBER_RANGE_PARTS.ordinal)) return false;
        }
    }
    $if !$feat(NO_INTL_DATE):
        if (!register_intl_date(ns, hp)) return false;
    $endif
    TVal v; v.set_object(ns);
    env::env_declare_nonenum(global_env, builtin_intern_string(hp, "Intl"), v);
    return true;
}
