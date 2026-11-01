// Intl.Locale (ECMA-402 §14): a canonical Unicode locale identifier with
// getters for its subtags and extension keywords, Add/Remove Likely Subtags,
// and the region-dependent get* queries. The identifier is stored as its
// canonical string and parsed again by each accessor.
module boomkat::builtins;
import boomkat::types;
import boomkat::heap;
import boomkat::hobject;
import boomkat::hstring;
import boomkat::lib::temporal;

const usz LOCALE_TAG_CAP = 640;
const usz LOCALE_OPTION_CAP = 64;

const String INTL_LOCALE_CLASS = "Intl.Locale";

struct IntlLocaleState {
    IntlPayloadHead head; // bound function slot read by intl_mark; unused by this service
    usz len;
    char[LOCALE_TAG_CAP] tag;
}

fn IntlLocaleState* intl_locale_of(Heap* hp, TVal v) {
    if (!v.is_object()) return null;
    HObject* obj = (HObject*)v.get_heapptr();
    if (!intl_has_brand(hp, obj, INTL_LOCALE_CLASS)) return null;
    return (IntlLocaleState*)(*obj.extra_ptr()).host.payload;
}

fn IntlLocaleState* intl_locale_receiver(BuiltinContext* ctx) {
    IntlLocaleState* state = intl_locale_of(ctx.heap, ctx.regs[ctx.base_reg - 1]);
    if (state == null) builtin_throw(ctx, ctx.heap.type_err_proto, "incompatible Intl.Locale receiver");
    return state;
}

// An allocation failure or an identifier that does not fit the fixed buffers.
fn void intl_locale_fail(BuiltinContext* ctx) {
    builtin_throw(ctx, ctx.heap.range_err_proto, "invalid language tag");
}

// A `type` production (UTS #35): one or more 3-8 character alphanumeric
// subtags joined by '-'.
fn bool locale_is_type(char[] s) {
    usz start = 0;
    for (usz i = 0; i <= s.len; i++) {
        if (i < s.len && s[i] != '-') continue;
        usz n = i - start;
        if (n < 3 || n > 8 || !locale_all_alnum(s[start:n])) return false;
        start = i + 1;
    }
    return true;
}

fn bool locale_is_language(char[] s) {
    return (s.len == 2 || s.len == 3 || (s.len >= 5 && s.len <= 8)) && locale_all_alpha(s);
}

// GetOption with type string: copies the option's string value into `buf`.
// Returns false for an absent option, and when conversion threw (the caller
// checks ctx.should_throw).
fn bool intl_locale_option(BuiltinContext* ctx, HObject* opts, char[] key, char[] buf, usz* len) {
    TVal v = intl_option(ctx, opts, key);
    if (ctx.should_throw || v.is_undefined()) return false;
    HString* s = builtin_to_string_vm(ctx, &v);
    if (ctx.should_throw || s == null) return false;
    char[] bytes = s.token_text();
    if (bytes.len > buf.len) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "invalid Intl.Locale option");
        return false;
    }
    for (usz i = 0; i < bytes.len; i++) buf[i] = bytes[i];
    *len = bytes.len;
    return true;
}

fn void intl_locale_bad_option(BuiltinContext* ctx) {
    builtin_throw(ctx, ctx.heap.range_err_proto, "invalid Intl.Locale option");
}

struct LocaleKeywords {
    LocaleKeyword[8] items;
    usz count;
}

fn void LocaleKeywords.add(&self, char[2] key, char[] value) {
    LocaleKeyword* k = &self.items[self.count++];
    *k = {};
    k.key = key;
    foreach (i, c : value) k.value[i] = locale_lower(c);
    k.value_len = value.len;
}

// A keyword option whose value is a `type`.
fn void intl_locale_type_option(BuiltinContext* ctx, HObject* opts, char[] name, char[2] key, LocaleKeywords* out) {
    char[LOCALE_OPTION_CAP] buf;
    usz n;
    if (!intl_locale_option(ctx, opts, name, buf[..], &n)) return;
    if (!locale_is_type(buf[:n])) { intl_locale_bad_option(ctx); return; }
    out.add(key, buf[:n]);
}

// A keyword option restricted to a fixed set of values.
fn void intl_locale_choice_option(BuiltinContext* ctx, HObject* opts, char[] name, char[2] key, char[][] values, LocaleKeywords* out) {
    char[LOCALE_OPTION_CAP] buf;
    usz n;
    if (!intl_locale_option(ctx, opts, name, buf[..], &n)) return;
    foreach (value : values) {
        if (locale_compare(buf[:n], value) == 0) { out.add(key, value); return; }
    }
    intl_locale_bad_option(ctx);
}

const char[][8] LOCALE_WEEKDAYS = { "sun", "mon", "tue", "wed", "thu", "fri", "sat", "sun" };

// firstDayOfWeek takes a weekday number, 0 or 7 for Sunday, or any `type`.
fn void intl_locale_first_day_option(BuiltinContext* ctx, HObject* opts, LocaleKeywords* out) {
    char[LOCALE_OPTION_CAP] buf;
    usz n;
    if (!intl_locale_option(ctx, opts, "firstDayOfWeek", buf[..], &n)) return;
    if (n == 1 && buf[0] >= '0' && buf[0] <= '7') {
        out.add("fw", LOCALE_WEEKDAYS[buf[0] - '0']);
        return;
    }
    if (!locale_is_type(buf[:n])) { intl_locale_bad_option(ctx); return; }
    out.add("fw", buf[:n]);
}

fn void intl_locale_numeric_option(BuiltinContext* ctx, HObject* opts, LocaleKeywords* out) {
    TVal v = intl_option(ctx, opts, "numeric");
    if (ctx.should_throw || v.is_undefined()) return;
    out.add("kn", builtin_to_boolean(&v) ? "true" : "false");
}

// Replaces the identifier's subtags with the language, script, region and
// variants options (UpdateLanguageId).
fn void intl_locale_update_language_id(BuiltinContext* ctx, HObject* opts, LocaleId* id) {
    char[LOCALE_OPTION_CAP] buf;
    usz n;
    if (intl_locale_option(ctx, opts, "language", buf[..], &n)) {
        if (!locale_is_language(buf[:n])) { intl_locale_bad_option(ctx); return; }
        id.set_language(buf[:n]);
    }
    if (ctx.should_throw) return;
    if (intl_locale_option(ctx, opts, "script", buf[..], &n)) {
        if (!locale_is_script(buf[:n])) { intl_locale_bad_option(ctx); return; }
        id.set_script(buf[:n]);
    }
    if (ctx.should_throw) return;
    if (intl_locale_option(ctx, opts, "region", buf[..], &n)) {
        if (!locale_is_region(buf[:n])) { intl_locale_bad_option(ctx); return; }
        id.set_region(buf[:n]);
    }
    if (ctx.should_throw) return;
    if (intl_locale_option(ctx, opts, "variants", buf[..], &n)) {
        id.variant_count = 0;
        usz start = 0;
        for (usz i = 0; i <= n; i++) {
            if (i < n && buf[i] != '-') continue;
            char[] variant = buf[start:i - start];
            if (!locale_is_variant(variant) || !id.add_variant(variant)) { intl_locale_bad_option(ctx); return; }
            start = i + 1;
        }
    }
}

// Stores `id` as the object's canonical string.
fn bool intl_locale_store(IntlLocaleState* state, LocaleId* id) {
    LocaleBuf out = { state.tag[..], 0, false };
    id.write(&out);
    state.len = out.len;
    return !out.overflow;
}

fn HObject* intl_locale_create(BuiltinContext* ctx, HObject* proto, LocaleId* id) {
    long class_id = intl_class_named(ctx.heap, INTL_LOCALE_CLASS);
    IntlLocaleState settings = {};
    if (!intl_locale_store(&settings, id)) { intl_locale_fail(ctx); return null; }
    HObject* obj = ctx.heap.alloc_object(ObjClass.HOST) ?? null;
    if (obj == null) { builtin_throw(ctx, ctx.heap.err_proto, "Intl allocation failed"); return null; }
    (*obj.extra_ptr()).host.class_id = (uint)class_id;
    IntlLocaleState* state = (IntlLocaleState*)ctx.heap.alloc_func(ctx.heap.heap_udata, IntlLocaleState::size);
    if (state == null) { builtin_throw(ctx, ctx.heap.err_proto, "Intl allocation failed"); return null; }
    *state = settings;
    (*obj.extra_ptr()).host.payload = state;
    ctx.heap.set_prototype(obj, proto);
    return obj;
}

//the prototype is read from NewTarget first, then the tag, then the
// options in the order below.
fn void builtin_intl_locale(BuiltinContext* ctx) {
    if (!ctx.is_constructor) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "Locale requires new");
        return;
    }
    long class_id = intl_class_named(ctx.heap, INTL_LOCALE_CLASS);
    HObject* proto = builtin_proto_from_new_target(ctx, ctx.heap.host_class_at((uint)class_id).proto);
    if (ctx.should_throw) return;
    TVal tag = builtin_arg(ctx, 0);
    if (!tag.is_string() && !tag.is_object()) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "locale tag must be a string or object");
        return;
    }
    char[LOCALE_TAG_CAP] text_buf;
    usz text_len;
    IntlLocaleState* source = intl_locale_of(ctx.heap, tag);
    if (source != null) {
        text_len = source.len;
        for (usz i = 0; i < text_len; i++) text_buf[i] = source.tag[i];
    } else {
        HString* s = builtin_to_string_vm(ctx, &tag);
        if (ctx.should_throw || s == null) return;
        char[] bytes = s.token_text();
        if (bytes.len > 120) { intl_locale_fail(ctx); return; }
        text_len = bytes.len;
        for (usz i = 0; i < text_len; i++) text_buf[i] = bytes[i];
    }
    HObject* opts = intl_options(ctx, builtin_arg(ctx, 1));
    if (ctx.should_throw) return;
    LocaleId id;
    if (!locale_is_well_formed(text_buf[:text_len]) || !id.parse(text_buf[:text_len])) { intl_locale_fail(ctx); return; }
    // The identifier is canonicalized before the options replace subtags, so
    // an alias in the tag resolves against the tag's own subtags.
    id.canonicalize_base();
    intl_locale_update_language_id(ctx, opts, &id);
    if (ctx.should_throw) return;
    LocaleKeywords keywords;
    intl_locale_type_option(ctx, opts, "calendar", "ca", &keywords);
    if (ctx.should_throw) return;
    intl_locale_type_option(ctx, opts, "collation", "co", &keywords);
    if (ctx.should_throw) return;
    intl_locale_first_day_option(ctx, opts, &keywords);
    if (ctx.should_throw) return;
    intl_locale_choice_option(ctx, opts, "hourCycle", "hc", {"h11", "h12", "h23", "h24"}, &keywords);
    if (ctx.should_throw) return;
    intl_locale_choice_option(ctx, opts, "caseFirst", "kf", {"upper", "lower", "false"}, &keywords);
    if (ctx.should_throw) return;
    intl_locale_numeric_option(ctx, opts, &keywords);
    if (ctx.should_throw) return;
    intl_locale_type_option(ctx, opts, "numberingSystem", "nu", &keywords);
    if (ctx.should_throw) return;
    id.canonicalize_base();
    if (!id.canonicalize_ext(keywords.items[:keywords.count])) { intl_locale_fail(ctx); return; }
    HObject* obj = intl_locale_create(ctx, proto, &id);
    if (obj != null) ctx.result_object(obj);
}

fn bool intl_locale_parse(BuiltinContext* ctx, IntlLocaleState* state, LocaleId* id) {
    if (id.parse(state.tag[:state.len])) return true;
    intl_locale_fail(ctx);
    return false;
}

fn void intl_locale_result_string(BuiltinContext* ctx, char[] value) {
    HString* s = builtin_intern_string(ctx.heap, value);
    if (s == null) { builtin_throw(ctx, ctx.heap.err_proto, "Intl allocation failed"); return; }
    ctx.result_string(s);
}

// An optional subtag: undefined when empty.
fn void intl_locale_result_optional(BuiltinContext* ctx, char[] value) {
    if (value.len == 0) { ctx.result_undefined(); return; }
    intl_locale_result_string(ctx, value);
}

fn void intl_locale_keyword_getter(BuiltinContext* ctx, char[2] key) {
    IntlLocaleState* state = intl_locale_receiver(ctx);
    if (state == null) return;
    LocaleId id;
    if (!intl_locale_parse(ctx, state, &id)) return;
    char[] value;
    if (!id.keyword(key, &value)) { ctx.result_undefined(); return; }
    intl_locale_result_string(ctx, value);
}

fn void builtin_intl_locale_language(BuiltinContext* ctx) {
    IntlLocaleState* state = intl_locale_receiver(ctx);
    if (state == null) return;
    LocaleId id;
    if (!intl_locale_parse(ctx, state, &id)) return;
    intl_locale_result_string(ctx, id.lang());
}

fn void builtin_intl_locale_script(BuiltinContext* ctx) {
    IntlLocaleState* state = intl_locale_receiver(ctx);
    if (state == null) return;
    LocaleId id;
    if (!intl_locale_parse(ctx, state, &id)) return;
    intl_locale_result_optional(ctx, id.scr());
}

fn void builtin_intl_locale_region(BuiltinContext* ctx) {
    IntlLocaleState* state = intl_locale_receiver(ctx);
    if (state == null) return;
    LocaleId id;
    if (!intl_locale_parse(ctx, state, &id)) return;
    intl_locale_result_optional(ctx, id.reg());
}

// The variants joined by '-', the part of the base name after the region.
fn usz locale_write_variants(LocaleId* id, LocaleBuf* out) {
    for (usz i = 0; i < id.variant_count; i++) {
        if (i > 0) out.add_char('-');
        out.add(id.variant(i));
    }
    return out.len;
}

fn void builtin_intl_locale_variants(BuiltinContext* ctx) {
    IntlLocaleState* state = intl_locale_receiver(ctx);
    if (state == null) return;
    LocaleId id;
    if (!intl_locale_parse(ctx, state, &id)) return;
    char[LOCALE_VARIANT_CAP * 10] buf;
    LocaleBuf out = { buf[..], 0, false };
    locale_write_variants(&id, &out);
    intl_locale_result_optional(ctx, out.bytes());
}

fn void builtin_intl_locale_base_name(BuiltinContext* ctx) {
    IntlLocaleState* state = intl_locale_receiver(ctx);
    if (state == null) return;
    LocaleId id;
    if (!intl_locale_parse(ctx, state, &id)) return;
    id.ext_len = 0;
    char[LOCALE_TAG_CAP] buf;
    LocaleBuf out = { buf[..], 0, false };
    id.write(&out);
    intl_locale_result_string(ctx, out.bytes());
}

fn void builtin_intl_locale_calendar(BuiltinContext* ctx) { intl_locale_keyword_getter(ctx, "ca"); }
fn void builtin_intl_locale_collation(BuiltinContext* ctx) { intl_locale_keyword_getter(ctx, "co"); }
fn void builtin_intl_locale_hour_cycle(BuiltinContext* ctx) { intl_locale_keyword_getter(ctx, "hc"); }
fn void builtin_intl_locale_case_first(BuiltinContext* ctx) { intl_locale_keyword_getter(ctx, "kf"); }
fn void builtin_intl_locale_numbering_system(BuiltinContext* ctx) { intl_locale_keyword_getter(ctx, "nu"); }
fn void builtin_intl_locale_first_day_of_week(BuiltinContext* ctx) { intl_locale_keyword_getter(ctx, "fw"); }

fn void builtin_intl_locale_numeric(BuiltinContext* ctx) {
    IntlLocaleState* state = intl_locale_receiver(ctx);
    if (state == null) return;
    LocaleId id;
    if (!intl_locale_parse(ctx, state, &id)) return;
    char[] value;
    ctx.result_boolean(id.keyword("kn", &value) && (value.len == 0 || locale_compare(value, "true") == 0));
}

fn void builtin_intl_locale_to_string(BuiltinContext* ctx) {
    IntlLocaleState* state = intl_locale_receiver(ctx);
    if (state == null) return;
    intl_locale_result_string(ctx, state.tag[:state.len]);
}

// Add or Remove Likely Subtags over the language, script and region; the
// variants and extensions are kept.
fn void intl_locale_likely(BuiltinContext* ctx, bool maximize) {
    IntlLocaleState* state = intl_locale_receiver(ctx);
    if (state == null) return;
    LocaleId id;
    if (!intl_locale_parse(ctx, state, &id)) return;
    if (maximize) { id.maximize(); } else { id.minimize(); }
    long class_id = intl_class_named(ctx.heap, INTL_LOCALE_CLASS);
    HObject* obj = intl_locale_create(ctx, ctx.heap.host_class_at((uint)class_id).proto, &id);
    if (obj != null) ctx.result_object(obj);
}

fn void builtin_intl_locale_maximize(BuiltinContext* ctx) { intl_locale_likely(ctx, true); }
fn void builtin_intl_locale_minimize(BuiltinContext* ctx) { intl_locale_likely(ctx, false); }

// A keyword value, or the names `list` computes when the keyword is absent.
fn void intl_locale_result_names(BuiltinContext* ctx, LocaleNames* names) {
    HObject* out = intl_array(ctx);
    if (out == null) return;
    for (usz i = 0; i < names.count; i++) {
        HString* s = builtin_intern_string(ctx.heap, names.items[i]);
        if (s == null) { builtin_throw(ctx, ctx.heap.err_proto, "Intl allocation failed"); return; }
        TVal v; v.set_string_borrowed(s);
        array_set_elem(out, (uint)i, v, ctx.heap);
    }
    array_set_length(out, (uint)names.count, ctx.heap);
    ctx.result_object(out);
}

fn void builtin_intl_locale_get_calendars(BuiltinContext* ctx) {
    IntlLocaleState* state = intl_locale_receiver(ctx);
    if (state == null) return;
    LocaleId id;
    if (!intl_locale_parse(ctx, state, &id)) return;
    LocaleNames names;
    char[] value;
    if (id.keyword("ca", &value)) { names.add(value); } else { locale_calendars(&id, &names); }
    intl_locale_result_names(ctx, &names);
}

fn void builtin_intl_locale_get_collations(BuiltinContext* ctx) {
    IntlLocaleState* state = intl_locale_receiver(ctx);
    if (state == null) return;
    LocaleId id;
    if (!intl_locale_parse(ctx, state, &id)) return;
    LocaleNames names;
    char[] value;
    if (id.keyword("co", &value)) { names.add(value); } else { locale_collations(&id, &names); }
    intl_locale_result_names(ctx, &names);
}

fn void builtin_intl_locale_get_hour_cycles(BuiltinContext* ctx) {
    IntlLocaleState* state = intl_locale_receiver(ctx);
    if (state == null) return;
    LocaleId id;
    if (!intl_locale_parse(ctx, state, &id)) return;
    LocaleNames names;
    char[] value;
    if (id.keyword("hc", &value)) { names.add(value); } else { locale_hour_cycles(&id, &names); }
    intl_locale_result_names(ctx, &names);
}

fn void builtin_intl_locale_get_numbering_systems(BuiltinContext* ctx) {
    IntlLocaleState* state = intl_locale_receiver(ctx);
    if (state == null) return;
    LocaleId id;
    if (!intl_locale_parse(ctx, state, &id)) return;
    LocaleNames names;
    char[] value;
    if (id.keyword("nu", &value)) { names.add(value); } else { names.add(locale_default_numbering(&id)); }
    intl_locale_result_names(ctx, &names);
}

fn void builtin_intl_locale_get_time_zones(BuiltinContext* ctx) {
    IntlLocaleState* state = intl_locale_receiver(ctx);
    if (state == null) return;
    LocaleId id;
    if (!intl_locale_parse(ctx, state, &id)) return;
    if (id.region_len == 0) { ctx.result_undefined(); return; }
    HObject* out = intl_array(ctx);
    if (out == null) return;
    usz from;
    usz to;
    uint count = 0;
    if (locale_region_zones((uint)locale_region_pack(id.reg()), &from, &to)) {
        for (usz i = from; i < to; i++) {
            char[64] name;
            usz n = temporal::tzdb_zone_name((int)INTL_ZONE_REGION_ZONES[i], &name[0]);
            HString* s = builtin_intern_string(ctx.heap, name[:n]);
            if (s == null) { builtin_throw(ctx, ctx.heap.err_proto, "Intl allocation failed"); return; }
            TVal v; v.set_string_borrowed(s);
            array_set_elem(out, count++, v, ctx.heap);
        }
    }
    array_set_length(out, count, ctx.heap);
    ctx.result_object(out);
}

fn HObject* intl_locale_object(BuiltinContext* ctx) {
    HObject* obj = ctx.heap.alloc_object(ObjClass.OBJECT) ?? null;
    if (obj == null) { builtin_throw(ctx, ctx.heap.err_proto, "Intl allocation failed"); return null; }
    ctx.heap.set_prototype(obj, ctx.heap.object_proto);
    return obj;
}

fn void builtin_intl_locale_get_text_info(BuiltinContext* ctx) {
    IntlLocaleState* state = intl_locale_receiver(ctx);
    if (state == null) return;
    LocaleId id;
    if (!intl_locale_parse(ctx, state, &id)) return;
    HObject* out = intl_locale_object(ctx);
    if (out == null) return;
    // The key is always present; its value is undefined when the script's
    // direction is unknown.
    char[] direction = locale_text_direction(&id);
    if (direction.len != 0) {
        intl_put_string(ctx.heap, out, "direction", direction);
    } else {
        TVal value; value.set_undefined();
        intl_put(ctx.heap, out, "direction", value);
    }
    if (ctx.heap.has_error) { builtin_throw(ctx, ctx.heap.err_proto, "Intl allocation failed"); return; }
    ctx.result_object(out);
}

fn void builtin_intl_locale_get_week_info(BuiltinContext* ctx) {
    IntlLocaleState* state = intl_locale_receiver(ctx);
    if (state == null) return;
    LocaleId id;
    if (!intl_locale_parse(ctx, state, &id)) return;
    uint first_day;
    uint weekend;
    locale_week(&id, &first_day, &weekend);
    char[] value;
    if (id.keyword("fw", &value)) {
        for (uint d = 1; d <= 7; d++) {
            if (locale_compare(value, LOCALE_WEEKDAYS[d % 7]) == 0) first_day = d;
        }
    }
    HObject* out = intl_locale_object(ctx);
    HObject* days = out == null ? null : intl_array(ctx);
    if (days == null) return;
    uint count = 0;
    for (uint d = 1; d <= 7; d++) {
        if ((weekend & (1u << (d - 1))) == 0) continue;
        TVal v; v.set_fastint((long)d);
        array_set_elem(days, count++, v, ctx.heap);
    }
    array_set_length(days, count, ctx.heap);
    intl_put_int(ctx.heap, out, "firstDay", (int)first_day);
    TVal list; list.set_object(days);
    (void)intl_put(ctx.heap, out, "weekend", list);
    if (ctx.heap.has_error) { builtin_throw(ctx, ctx.heap.err_proto, "Intl allocation failed"); return; }
    ctx.result_object(out);
}

fn bool intl_register_getter(HObject* proto, Heap* hp, char[] name, uint builtin) {
    if (!register_proto_getter_accessor(proto, hp, name, builtin)) return false;
    TVal? accessor = proto.get_prop(builtin_intern_string(hp, name), hp);
    if (try access_value = accessor) {
        TVal getter = hobject::hobject_access_getter(access_value);
        char[80] full = "get ";
        foreach (i, c : name) full[4 + i] = c;
        set_func_ctor_name((HObject*)getter.get_heapptr(), hp, full[:4 + name.len]);
    }
    return true;
}

fn bool register_intl_locale(HObject* ns, Heap* hp) {
    HObject* proto = hp.alloc_object(ObjClass.OBJECT) ?? null;
    HObject* ctor = hp.alloc_object(ObjClass.FUNCTION) ?? null;
    if (proto == null || ctor == null) return false;
    hp.named_intrinsic("Intl.Locale", proto);
    hp.set_prototype(proto, hp.object_proto); hp.set_prototype(ctor, hp.function_proto);
    (*ctor.extra_ptr()).func.builtin_fn_index = (int)Builtin.INTL_LOCALE.ordinal;
    ctor.flags.callable = true; ctor.flags.constructable = true;
    set_func_ctor_name_length(ctor, hp, "Locale", 1);
    TVal v; v.set_object(proto); intl_put(hp, ctor, "prototype", v, (PropFlags){});
    v.set_object(ctor); intl_put(hp, proto, "constructor", v, hobject::PROP_FLAGS_WC); intl_put(hp, ns, "Locale", v, hobject::PROP_FLAGS_WC);
    HString* tag = builtin_intern_string(hp, INTL_LOCALE_CLASS); v.set_string_borrowed(tag);
    proto.put_prop(ensure_tostringtag_symbol(hp), v, hobject::PROP_FLAGS_NWC, hp);
    if (hp.register_host_class((void*)&intl_finalize, (void*)&intl_mark, hp, tag, proto) < 0) return false;
    if (!register_string_proto_method(proto, hp, "maximize", Builtin.INTL_LOCALE_MAXIMIZE.ordinal)) return false;
    if (!register_string_proto_method(proto, hp, "minimize", Builtin.INTL_LOCALE_MINIMIZE.ordinal)) return false;
    if (!register_string_proto_method(proto, hp, "toString", Builtin.INTL_LOCALE_TO_STRING.ordinal)) return false;
    if (!register_string_proto_method(proto, hp, "getCalendars", Builtin.INTL_LOCALE_GET_CALENDARS.ordinal)) return false;
    if (!register_string_proto_method(proto, hp, "getCollations", Builtin.INTL_LOCALE_GET_COLLATIONS.ordinal)) return false;
    if (!register_string_proto_method(proto, hp, "getHourCycles", Builtin.INTL_LOCALE_GET_HOUR_CYCLES.ordinal)) return false;
    if (!register_string_proto_method(proto, hp, "getNumberingSystems", Builtin.INTL_LOCALE_GET_NUMBERING_SYSTEMS.ordinal)) return false;
    if (!register_string_proto_method(proto, hp, "getTimeZones", Builtin.INTL_LOCALE_GET_TIME_ZONES.ordinal)) return false;
    if (!register_string_proto_method(proto, hp, "getTextInfo", Builtin.INTL_LOCALE_GET_TEXT_INFO.ordinal)) return false;
    if (!register_string_proto_method(proto, hp, "getWeekInfo", Builtin.INTL_LOCALE_GET_WEEK_INFO.ordinal)) return false;
    if (!intl_register_getter(proto, hp, "baseName", Builtin.INTL_LOCALE_BASE_NAME.ordinal)) return false;
    if (!intl_register_getter(proto, hp, "calendar", Builtin.INTL_LOCALE_CALENDAR.ordinal)) return false;
    if (!intl_register_getter(proto, hp, "caseFirst", Builtin.INTL_LOCALE_CASE_FIRST.ordinal)) return false;
    if (!intl_register_getter(proto, hp, "collation", Builtin.INTL_LOCALE_COLLATION.ordinal)) return false;
    if (!intl_register_getter(proto, hp, "firstDayOfWeek", Builtin.INTL_LOCALE_FIRST_DAY_OF_WEEK.ordinal)) return false;
    if (!intl_register_getter(proto, hp, "hourCycle", Builtin.INTL_LOCALE_HOUR_CYCLE.ordinal)) return false;
    if (!intl_register_getter(proto, hp, "language", Builtin.INTL_LOCALE_LANGUAGE.ordinal)) return false;
    if (!intl_register_getter(proto, hp, "numberingSystem", Builtin.INTL_LOCALE_NUMBERING_SYSTEM.ordinal)) return false;
    if (!intl_register_getter(proto, hp, "numeric", Builtin.INTL_LOCALE_NUMERIC.ordinal)) return false;
    if (!intl_register_getter(proto, hp, "region", Builtin.INTL_LOCALE_REGION.ordinal)) return false;
    if (!intl_register_getter(proto, hp, "script", Builtin.INTL_LOCALE_SCRIPT.ordinal)) return false;
    if (!intl_register_getter(proto, hp, "variants", Builtin.INTL_LOCALE_VARIANTS.ordinal)) return false;
    return true;
}
