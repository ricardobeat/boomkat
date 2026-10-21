// Intl.DisplayNames (ECMA-402 §12) in English. Languages, scripts, regions,
// variants, calendars and date-time fields come from one sorted table
// (intl_names_data.c3); currency names reuse the NumberFormat tables.
module boomkat::builtins;
import boomkat::types;
import boomkat::heap;
import boomkat::hobject;
import boomkat::hstring;

const String INTL_NAMES_CLASS = "Intl.DisplayNames";

enum IntlNamesType : int {
    LANGUAGE,
    REGION,
    SCRIPT,
    CURRENCY,
    CALENDAR,
    DATE_TIME_FIELD,
}

struct IntlNamesState {
    IntlPayloadHead head; // bound function slot read by intl_mark; unused by this service
    bool us_locale;
    int style; // long, short, narrow
    IntlNamesType type;
    int fallback; // code, none
    int language_display; // dialect, standard
}

fn IntlNamesState* intl_names_receiver(BuiltinContext* ctx) {
    TVal v = ctx.regs[ctx.base_reg - 1];
    if (v.is_object()) {
        HObject* obj = (HObject*)v.get_heapptr();
        if (intl_has_brand(ctx.heap, obj, INTL_NAMES_CLASS)) {
            return (IntlNamesState*)(*obj.extra_ptr()).host.payload;
        }
    }
    builtin_throw(ctx, ctx.heap.type_err_proto, "incompatible Intl.DisplayNames receiver");
    return null;
}

//the prototype is read from NewTarget before any option is touched.
fn void builtin_intl_display_names(BuiltinContext* ctx) {
    if (!ctx.is_constructor) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "DisplayNames requires new");
        return;
    }
    long id = intl_class_named(ctx.heap, INTL_NAMES_CLASS);
    HObject* proto = builtin_proto_from_new_target(ctx, ctx.heap.host_class_at((uint)id).proto);
    if (ctx.should_throw) return;
    IntlNamesState settings;
    HObject* supported = intl_locales(ctx, builtin_arg(ctx, 0));
    if (ctx.should_throw) return;
    HObject* opts = intl_options_object(ctx, builtin_arg(ctx, 1));
    if (ctx.should_throw) return;
    (void)intl_choice(ctx, opts, "localeMatcher", {"best fit", "lookup"});
    if (ctx.should_throw) return;
    TVal? first = supported.get_prop(ctx.heap.int_to_hstring(0), ctx.heap);
    if (try v = first) {
        HString* tag = (HString*)v.get_heapptr();
        settings.us_locale = tag.blen >= 5 && locale_eq_ci(tag.get_cstr()[:5], "en-us");
    }
    settings.style = intl_choice(ctx, opts, "style", {"narrow", "short", "long"}, 2);
    if (ctx.should_throw) return;
    // Table order is narrow, short, long; the state counts long, short, narrow.
    settings.style = 2 - settings.style;
    int type = intl_choice(ctx, opts, "type", {"language", "region", "script", "currency", "calendar", "dateTimeField"}, -1);
    if (ctx.should_throw) return;
    if (type < 0) { builtin_throw(ctx, ctx.heap.type_err_proto, "DisplayNames requires a type"); return; }
    settings.type = (IntlNamesType)type;
    settings.fallback = intl_choice(ctx, opts, "fallback", {"code", "none"});
    if (ctx.should_throw) return;
    settings.language_display = intl_choice(ctx, opts, "languageDisplay", {"dialect", "standard"});
    if (ctx.should_throw) return;
    HObject* obj = ctx.heap.alloc_object(ObjClass.HOST) ?? null;
    if (obj == null) { builtin_throw(ctx, ctx.heap.err_proto, "Intl allocation failed"); return; }
    (*obj.extra_ptr()).host.class_id = (uint)id;
    IntlNamesState* state = (IntlNamesState*)ctx.heap.alloc_func(ctx.heap.heap_udata, IntlNamesState::size);
    if (state == null) { builtin_throw(ctx, ctx.heap.err_proto, "Intl allocation failed"); return; }
    *state = settings;
    (*obj.extra_ptr()).host.payload = state;
    ctx.heap.set_prototype(obj, proto);
    ctx.result_object(obj);
}

fn void builtin_intl_names_resolved(BuiltinContext* ctx) {
    IntlNamesState* state = intl_names_receiver(ctx);
    if (state == null) return;
    HObject* out = ctx.heap.alloc_object(ObjClass.OBJECT) ?? null;
    if (out == null) { builtin_throw(ctx, ctx.heap.err_proto, "Intl allocation failed"); return; }
    ctx.heap.set_prototype(out, ctx.heap.object_proto);
    char[][] styles = {"long", "short", "narrow"};
    char[][] types = {"language", "region", "script", "currency", "calendar", "dateTimeField"};
    intl_put_string(ctx.heap, out, "locale", state.us_locale ? "en-US" : "en");
    intl_put_string(ctx.heap, out, "style", styles[state.style]);
    intl_put_string(ctx.heap, out, "type", types[state.type.ordinal]);
    intl_put_string(ctx.heap, out, "fallback", state.fallback == 0 ? "code" : "none");
    if (state.type == IntlNamesType.LANGUAGE) {
        intl_put_string(ctx.heap, out, "languageDisplay", state.language_display == 0 ? "dialect" : "standard");
    }
    if (ctx.heap.has_error) { builtin_throw(ctx, ctx.heap.err_proto, "Intl allocation failed"); return; }
    ctx.result_object(out);
}

// <0, 0 or >0 as the table key at `entry` sorts before, equal to or after
// `kind` followed by `key`.
fn int intl_names_compare(char* entry, char kind, char[] key) {
    int c = (int)entry[0] - (int)kind;
    if (c != 0) return c;
    for (usz i = 0; i < key.len; i++) {
        c = (int)entry[1 + i] - (int)key[i];
        if (c != 0) return c;
    }
    return (int)entry[1 + key.len];
}

// The English name for `kind` + `key`, or an empty slice. The tables are read
// through pointers: c3c reads zeros when a const array is sliced at a
// run-time offset.
fn char[] intl_names_find(char kind, char[] key) {
    char* keys = &INTL_NAME_KEYS;
    char* pool = &INTL_NAME_POOL;
    usz low = 0;
    usz high = INTL_NAME_KEY_AT.len;
    while (low < high) {
        usz mid = (low + high) / 2;
        int order = intl_names_compare(keys + INTL_NAME_KEY_AT[mid], kind, key);
        if (order == 0) {
            usz at = INTL_NAME_VALUE_AT[mid];
            usz end = at;
            while (pool[end] != 0) end++;
            return pool[at:end - at];
        }
        if (order < 0) { low = mid + 1; } else { high = mid; }
    }
    return {};
}

// The name in the requested style: short and narrow prefer the short table.
fn char[] intl_names_styled(IntlNamesState* state, char long_kind, char short_kind, char[] key) {
    if (state.style != 0) {
        char[] name = intl_names_find(short_kind, key);
        if (name.len > 0) return name;
    }
    return intl_names_find(long_kind, key);
}

fn bool intl_names_all(char[] s, bool alpha) {
    foreach (c : s) {
        bool letter = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z');
        bool digit = c >= '0' && c <= '9';
        if (alpha ? !letter : !digit) return false;
    }
    return true;
}

// unicode_language_id: language, script, region, variants.
fn bool intl_names_language_valid(char[] tag) {
    char[][40] parts;
    int n = locale_split(tag, &parts);
    if (n < 1) return false;
    int i = 0;
    char[] head = parts[0];
    bool alpha_head = intl_names_all(head, true);
    if (!alpha_head) return false;
    if (head.len != 2 && head.len != 3 && (head.len < 5 || head.len > 8)) return false;
    i++;
    if (i < n && parts[i].len == 4 && intl_names_all(parts[i], true)) i++;
    if (i < n && ((parts[i].len == 2 && intl_names_all(parts[i], true)) || (parts[i].len == 3 && intl_names_all(parts[i], false)))) i++;
    int variant_start = i;
    while (i < n && locale_is_variant(parts[i])) {
        for (int j = variant_start; j < i; j++) {
            if (locale_equal_ci(parts[j], parts[i])) return false;
        }
        i++;
    }
    return i == n;
}

fn bool intl_names_append_part(IntlNamesState* state, StrBuf* remainder, char[] name, char[] code) {
    if (name.len == 0) {
        if (state.fallback == 1) return false;
        name = code;
    }
    if (remainder.len > 0) remainder.append_bytes(", ");
    remainder.append_bytes(name);
    return true;
}

// ICU's LocaleDisplayNames: the dialect name when one exists, then the
// script, region and variants in parentheses.
fn bool intl_names_language(IntlNamesState* state, LocaleId* id, StrBuf* out) {
    char[96] key_buffer;
    bool has_script = id.script_len > 0;
    bool has_region = id.region_len > 0;
    char[] name = {};
    if (state.language_display == 0) {
        LocaleBuf key = { .data = key_buffer[..] };
        if (has_script && has_region) {
            key.add(id.lang()); key.add_char('-'); key.add(id.scr()); key.add_char('-'); key.add(id.reg());
            name = intl_names_styled(state, 'l', 'L', key.bytes());
            if (name.len > 0) { has_script = false; has_region = false; }
        }
        if (name.len == 0 && has_script) {
            key.len = 0;
            key.add(id.lang()); key.add_char('-'); key.add(id.scr());
            name = intl_names_styled(state, 'l', 'L', key.bytes());
            if (name.len > 0) has_script = false;
        }
        if (name.len == 0 && has_region) {
            key.len = 0;
            key.add(id.lang()); key.add_char('-'); key.add(id.reg());
            name = intl_names_styled(state, 'l', 'L', key.bytes());
            if (name.len > 0) has_region = false;
        }
    }
    if (name.len == 0) {
        name = intl_names_styled(state, 'l', 'L', id.lang());
        if (name.len == 0) {
            if (state.fallback == 1) return false;
            name = id.lang();
        }
    }
    StrBuf remainder; remainder.init(out.heap);
    defer remainder.free();
    if (has_script && !intl_names_append_part(state, &remainder, intl_names_styled(state, 's', 'S', id.scr()), id.scr())) return false;
    if (has_region && !intl_names_append_part(state, &remainder, intl_names_styled(state, 'r', 'R', id.reg()), id.reg())) return false;
    for (usz i = 0; i < id.variant_count; i++) {
        char[32] upper;
        char[] variant = id.variant(i);
        foreach (k, c : variant) upper[k] = c >= 'a' && c <= 'z' ? c - 32 : c;
        if (!intl_names_append_part(state, &remainder, intl_names_find('v', upper[:variant.len]), variant)) return false;
    }
    out.append_bytes(name);
    if (remainder.len > 0) {
        out.append_bytes(" (");
        out.append_bytes(remainder.bytes());
        out.append_char(')');
    }
    return !out.failed && !remainder.failed;
}

const String[12] INTL_NAMES_FIELDS = {
    "era", "year", "quarter", "month", "weekOfYear", "weekday", "day", "dayPeriod", "hour", "minute", "second", "timeZoneName",
};
const String[12] INTL_NAMES_FIELD_KEYS = {
    "era", "year", "quarter", "month", "week", "weekday", "day", "dayperiod", "hour", "minute", "second", "zone",
};

// Intl.DisplayNames.prototype.of
fn void builtin_intl_names_of(BuiltinContext* ctx) {
    IntlNamesState* state = intl_names_receiver(ctx);
    if (state == null) return;
    TVal code_arg = builtin_arg(ctx, 0);
    HString* code_str = builtin_to_string_vm(ctx, &code_arg);
    if (ctx.should_throw || code_str == null) return;
    char[] code = code_str.get_cstr()[:code_str.blen];
    StrBuf result; result.init(ctx.heap);
    defer result.free();
    char[64] canonical;
    char[] shown = {}; // the code echoed when fallback is "code"
    bool found = false;
    switch (state.type) {
        case LANGUAGE: {
            LocaleId id;
            if (!intl_names_language_valid(code) || !id.parse(code)) {
                builtin_throw(ctx, ctx.heap.range_err_proto, "invalid language tag");
                return;
            }
            id.canonicalize_base();
            LocaleBuf out_tag = { .data = canonical[..] };
            id.write(&out_tag);
            shown = out_tag.bytes();
            found = intl_names_language(state, &id, &result);
            if (!found) result.len = 0;
        }
        case REGION: {
            bool valid = (code.len == 2 && intl_names_all(code, true)) || (code.len == 3 && intl_names_all(code, false));
            if (!valid) { builtin_throw(ctx, ctx.heap.range_err_proto, "invalid region code"); return; }
            foreach (i, c : code) canonical[i] = c >= 'a' && c <= 'z' ? c - 32 : c;
            shown = canonical[:code.len];
            char[] name = intl_names_styled(state, 'r', 'R', shown);
            found = name.len > 0;
            if (found) result.append_bytes(name);
        }
        case SCRIPT: {
            if (code.len != 4 || !intl_names_all(code, true)) { builtin_throw(ctx, ctx.heap.range_err_proto, "invalid script code"); return; }
            foreach (i, c : code) {
                bool lower = c >= 'a' && c <= 'z';
                bool upper = c >= 'A' && c <= 'Z';
                canonical[i] = i == 0 ? (lower ? c - 32 : c) : (upper ? c + 32 : c);
            }
            shown = canonical[:4];
            char[] name = intl_names_styled(state, 's', 'S', shown);
            found = name.len > 0;
            if (found) result.append_bytes(name);
        }
        case CURRENCY: {
            if (code.len != 3 || !intl_names_all(code, true)) { builtin_throw(ctx, ctx.heap.range_err_proto, "invalid currency code"); return; }
            foreach (i, c : code) canonical[i] = c >= 'a' && c <= 'z' ? c - 32 : c;
            shown = canonical[:3];
            if (intl_currency_index(shown) >= 0) {
                IntlNumberState currency = {};
                foreach (i, c : shown) currency.currency[i] = c;
                char[96] scratch;
                found = true;
                if (state.style == 0) {
                    result.append_bytes(intl_currency_name(&currency, true, scratch[..]));
                } else {
                    currency.currency_display = state.style == 1 ? 0 : 3;
                    result.append_bytes(intl_currency_symbol(&currency));
                }
            }
        }
        case CALENDAR: {
            bool valid = code.len >= 3;
            usz segment = 0;
            foreach (i, c : code) {
                bool alnum = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9');
                if (c == '-') {
                    if (segment < 3 || segment > 8) valid = false;
                    segment = 0;
                } else if (!alnum) {
                    valid = false;
                } else {
                    segment++;
                }
            }
            if (segment < 3 || segment > 8) valid = false;
            if (!valid) { builtin_throw(ctx, ctx.heap.range_err_proto, "invalid calendar type"); return; }
            char[96] tag_buffer;
            LocaleBuf tag = { .data = tag_buffer[..] };
            tag.add("und-u-ca-"); tag.add(code);
            LocaleId id;
            char[] value;
            if (!id.parse(tag.bytes()) || !id.canonicalize_ext() || !id.keyword("ca", &value)) {
                builtin_throw(ctx, ctx.heap.range_err_proto, "invalid calendar type");
                return;
            }
            foreach (i, c : value) canonical[i] = c;
            shown = canonical[:value.len];
            char[] name = intl_names_find('c', shown);
            found = name.len > 0;
            if (found) result.append_bytes(name);
        }
        case DATE_TIME_FIELD: {
            int field = -1;
            foreach (i, name : INTL_NAMES_FIELDS) if (mem_eq_bytes(code, name)) field = (int)i;
            if (field < 0) { builtin_throw(ctx, ctx.heap.range_err_proto, "invalid date-time field"); return; }
            LocaleBuf key = { .data = canonical[..] };
            key.add(INTL_NAMES_FIELD_KEYS[field]);
            if (state.style == 1) key.add("-short");
            if (state.style == 2) key.add("-narrow");
            result.append_bytes(intl_names_find('f', key.bytes()));
            found = result.len > 0;
            shown = code;
        }
    }
    if (result.failed || ctx.heap.has_error) { builtin_throw(ctx, ctx.heap.err_proto, "Intl allocation failed"); return; }
    if (found) {
        ctx.result_string(builtin_intern_string(ctx.heap, result.bytes()));
    } else if (state.fallback == 0) {
        ctx.result_string(builtin_intern_string(ctx.heap, shown));
    } else {
        ctx.result_undefined();
    }
}

fn bool register_intl_display_names(HObject* ns, Heap* hp) {
    HObject* proto = hp.alloc_object(ObjClass.OBJECT) ?? null;
    HObject* ctor = hp.alloc_object(ObjClass.FUNCTION) ?? null;
    if (proto == null || ctor == null) return false;
    hp.named_intrinsic("Intl.DisplayNames", proto);
    hp.set_prototype(proto, hp.object_proto); hp.set_prototype(ctor, hp.function_proto);
    (*ctor.extra_ptr()).func.builtin_fn_index = (int)Builtin.INTL_DISPLAY_NAMES.ordinal;
    ctor.flags.callable = true; ctor.flags.constructable = true;
    set_func_ctor_name_length(ctor, hp, "DisplayNames", 2);
    TVal v; v.set_object(proto); intl_put(hp, ctor, "prototype", v, (PropFlags){});
    v.set_object(ctor); intl_put(hp, proto, "constructor", v, hobject::PROP_FLAGS_WC); intl_put(hp, ns, "DisplayNames", v, hobject::PROP_FLAGS_WC);
    HString* tag = builtin_intern_string(hp, INTL_NAMES_CLASS); v.set_string_borrowed(tag);
    proto.put_prop(ensure_tostringtag_symbol(hp), v, hobject::PROP_FLAGS_NWC, hp);
    if (hp.register_host_class((void*)&intl_finalize, (void*)&intl_mark, hp, tag, proto) < 0) return false;
    if (!register_string_proto_method(ctor, hp, "supportedLocalesOf", Builtin.INTL_SUPPORTED_LOCALES.ordinal)) return false;
    if (!register_string_proto_method(proto, hp, "resolvedOptions", Builtin.INTL_NAMES_RESOLVED.ordinal)) return false;
    if (!register_string_proto_method(proto, hp, "of", Builtin.INTL_NAMES_OF.ordinal)) return false;
    return true;
}
