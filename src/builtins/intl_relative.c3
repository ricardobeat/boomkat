// Intl.RelativeTimeFormat (ECMA-402 §17) for English. The number part comes
// from the shared NumberFormat renderer, so grouping and fraction digits match
// Intl.NumberFormat with default options.
module boomkat::builtins;
import boomkat::types;
import boomkat::heap;
import boomkat::hobject;
import boomkat::hstring;
import std::math;

// `number` comes first so intl_mark and intl_finalize treat the payload as an
// IntlNumberState; its bound_format stays null.
struct IntlRelativeState {
    IntlNumberState number;
    int style;   // long, short, narrow
    bool auto_numeric;
}

// Each unit's CLDR en patterns per style (long, short, narrow). Suffixes carry
// their own separator because the narrow forms attach directly ("in 2h").
// An empty phrase means numeric "auto" falls back to the numeric pattern.
struct IntlRelativeUnit {
    String name;
    String[3] one;
    String[3] other;
    String[3] last;
    String[3] current;
    String[3] next;
}

const IntlRelativeUnit[*] INTL_RELATIVE_UNITS = {
    { "second", { " second", " sec.", "s" }, { " seconds", " sec.", "s" },
      { "", "", "" }, { "now", "now", "now" }, { "", "", "" } },
    { "minute", { " minute", " min.", "m" }, { " minutes", " min.", "m" },
      { "", "", "" }, { "this minute", "this minute", "this minute" }, { "", "", "" } },
    { "hour", { " hour", " hr.", "h" }, { " hours", " hr.", "h" },
      { "", "", "" }, { "this hour", "this hour", "this hour" }, { "", "", "" } },
    { "day", { " day", " day", "d" }, { " days", " days", "d" },
      { "yesterday", "yesterday", "yesterday" }, { "today", "today", "today" }, { "tomorrow", "tomorrow", "tomorrow" } },
    { "week", { " week", " wk.", "w" }, { " weeks", " wk.", "w" },
      { "last week", "last wk.", "last wk." }, { "this week", "this wk.", "this wk." }, { "next week", "next wk.", "next wk." } },
    { "month", { " month", " mo.", "mo" }, { " months", " mo.", "mo" },
      { "last month", "last mo.", "last mo." }, { "this month", "this mo.", "this mo." }, { "next month", "next mo.", "next mo." } },
    { "quarter", { " quarter", " qtr.", "q" }, { " quarters", " qtrs.", "q" },
      { "last quarter", "last qtr.", "last qtr." }, { "this quarter", "this qtr.", "this qtr." }, { "next quarter", "next qtr.", "next qtr." } },
    { "year", { " year", " yr.", "y" }, { " years", " yr.", "y" },
      { "last year", "last yr.", "last yr." }, { "this year", "this yr.", "this yr." }, { "next year", "next yr.", "next yr." } },
};

const String INTL_RELATIVE_CLASS = "Intl.RelativeTimeFormat";

fn IntlRelativeState* intl_relative_receiver(BuiltinContext* ctx) {
    TVal v = ctx.regs[ctx.base_reg - 1];
    if (v.is_object()) {
        HObject* obj = (HObject*)v.get_heapptr();
        if (obj != null && obj.get_class() == ObjClass.HOST &&
            (long)(*obj.extra_ptr()).host.class_id == intl_class_named(ctx.heap, INTL_RELATIVE_CLASS)) {
            return (IntlRelativeState*)(*obj.extra_ptr()).host.payload;
        }
    }
    builtin_throw(ctx, ctx.heap.type_err_proto, "incompatible Intl.RelativeTimeFormat receiver");
    return null;
}

// §17.1.1: the prototype is read from NewTarget before any option is touched.
fn void builtin_intl_relative_format(BuiltinContext* ctx) {
    if (!ctx.is_constructor) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "RelativeTimeFormat requires new");
        return;
    }
    long id = intl_class_named(ctx.heap, INTL_RELATIVE_CLASS);
    HObject* proto = builtin_proto_from_new_target(ctx, ctx.heap.host_class_at((uint)id).proto);
    if (ctx.should_throw) return;
    IntlRelativeState settings;
    IntlNumberState* number = &settings.number;
    number.grouping = 1;
    number.min_integer = 1;
    number.max_fraction = 3;
    number.rounding_increment = 1;
    number.rounding_mode = 6; // halfExpand
    number.unit = -1;
    number.denominator = -1;
    number.us_locale = true;
    HObject* supported = intl_locales(ctx, builtin_arg(ctx, 0), false, true);
    if (ctx.should_throw) return;
    HObject* opts = intl_options(ctx, builtin_arg(ctx, 1));
    if (ctx.should_throw) return;
    (void)intl_choice(ctx, opts, "localeMatcher", {"best fit", "lookup"});
    if (ctx.should_throw) return;
    HString* numbering = date_get_raw_string_option(ctx, opts, "numberingSystem");
    if (ctx.should_throw) return;
    if (numbering != null && !date_is_unicode_type_subtag(numbering.get_cstr()[:numbering.blen])) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "invalid numbering system");
        return;
    }
    TVal? first = supported.get_prop(ctx.heap.int_to_hstring(0), ctx.heap);
    char[] first_tag = "en-US";
    if (try v = first) {
        HString* tag = (HString*)v.get_heapptr();
        first_tag = tag.get_cstr()[:tag.blen];
        number.us_locale = tag.blen >= 5 && locale_eq_ci(tag.get_cstr()[:5], "en-us");
    }
    IntlNumbering resolved = intl_resolve_numbering(first_tag, numbering == null ? "" : numbering.get_cstr()[:numbering.blen], numbering != null);
    number.numbering = intl_numbering_store(resolved.index);
    number.numbering_ext = resolved.keep_extension;
    int row = intl_row_for_tag(first_tag);
    number.locale = row < 0 ? 0 : row;
    number.label_mode = intl_label_mode(first_tag, row);
    settings.style = intl_choice(ctx, opts, "style", {"long", "short", "narrow"});
    if (ctx.should_throw) return;
    settings.auto_numeric = intl_choice(ctx, opts, "numeric", {"always", "auto"}) == 1;
    if (ctx.should_throw) return;
    HObject* obj = ctx.heap.alloc_object(ObjClass.HOST) ?? null;
    if (obj == null) { builtin_throw(ctx, ctx.heap.err_proto, "Intl allocation failed"); return; }
    (*obj.extra_ptr()).host.class_id = (uint)id;
    IntlRelativeState* state = (IntlRelativeState*)ctx.heap.alloc_func(ctx.heap.heap_udata, IntlRelativeState::size);
    if (state == null) { builtin_throw(ctx, ctx.heap.err_proto, "Intl allocation failed"); return; }
    *state = settings;
    (*obj.extra_ptr()).host.payload = state;
    ctx.heap.set_prototype(obj, proto);
    ctx.result_object(obj);
}

fn void builtin_intl_relative_resolved(BuiltinContext* ctx) {
    IntlRelativeState* state = intl_relative_receiver(ctx);
    if (state == null) return;
    HObject* out = ctx.heap.alloc_object(ObjClass.OBJECT) ?? null;
    if (out == null) { builtin_throw(ctx, ctx.heap.err_proto, "Intl allocation failed"); return; }
    ctx.heap.set_prototype(out, ctx.heap.object_proto);
    char[][] styles = {"long", "short", "narrow"};
    char[48] locale_buffer;
    IntlNumbering numbering = { .index = intl_numbering_index(state.number.numbering), .keep_extension = state.number.numbering_ext };
    usz row = (usz)state.number.locale;
    char[32] label_buffer;
    char[] tag = row > 0 ? intl_row_label(row, state.number.label_mode, label_buffer[..]) : state.number.us_locale ? "en-US" : "en";
    intl_put_string(ctx.heap, out, "locale", intl_resolved_locale(tag, numbering, locale_buffer[..]));
    intl_put_string(ctx.heap, out, "style", styles[state.style]);
    intl_put_string(ctx.heap, out, "numeric", state.auto_numeric ? "auto" : "always");
    intl_put_string(ctx.heap, out, "numberingSystem", intl_digit_name(numbering.index));
    if (ctx.heap.has_error) { builtin_throw(ctx, ctx.heap.err_proto, "Intl allocation failed"); return; }
    ctx.result_object(out);
}

// §17.5.2 PartitionRelativeTimePattern. The number is formatted from its
// magnitude; the pattern ("in …" or "… ago") carries the sign, and -0 is past.
// The category index of a plural category name, in the order the row cells use.
fn usz intl_relative_category(char[] category) {
    if (mem_eq_bytes(category, "zero")) return 0;
    if (mem_eq_bytes(category, "one")) return 1;
    if (mem_eq_bytes(category, "two")) return 2;
    if (mem_eq_bytes(category, "few")) return 3;
    if (mem_eq_bytes(category, "many")) return 4;
    return 5;
}

// The row's pattern for one unit, style, direction and category. A category the row lacks uses its
// "other" pattern. Empty when the row has no pattern for the unit.
fn char[] intl_relative_pattern(usz row, usz unit, int style, bool past, char[] category) {
    usz base = (unit * 3 + (usz)style) * INTL_RELATIVE_CELLS + 3 + (past ? (usz)6 : (usz)0);
    char[] text = intl_relative_cell(row, base + intl_relative_category(category));
    return text.len > 0 ? text : intl_relative_cell(row, base + 5);
}

// The index of "{0}" in a CLDR relative-time pattern, or -1 when there is none.
fn int intl_relative_slot(char[] pattern) {
    for (usz i = 0; i + 3 <= pattern.len; i++) {
        if (pattern[i] == '{' && pattern[i + 1] == '0' && pattern[i + 2] == '}') return (int)i;
    }
    return -1;
}

fn void intl_relative_render(BuiltinContext* ctx, bool as_parts) {
    IntlRelativeState* state = intl_relative_receiver(ctx);
    if (state == null) return;
    TVal value_arg = builtin_arg(ctx, 0);
    double value = builtin_to_number_vm(ctx, &value_arg);
    if (ctx.should_throw) return;
    TVal unit_arg = builtin_arg(ctx, 1);
    HString* unit_str = builtin_to_string_vm(ctx, &unit_arg);
    if (ctx.should_throw || unit_str == null) return;
    if (math::is_nan(value) || math::is_inf(value)) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "relative time value must be finite");
        return;
    }
    char[] name = unit_str.get_cstr()[:unit_str.blen];
    if (name.len > 1 && name[^1] == 's') name = name[:name.len - 1];
    int index = -1;
    foreach (i, entry : INTL_RELATIVE_UNITS) if (mem_eq_bytes(name, entry.name)) index = (int)i;
    if (index < 0) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "invalid relative time unit");
        return;
    }
    IntlRelativeUnit* unit = &INTL_RELATIVE_UNITS[index];
    int style = state.style;
    usz row = (usz)state.number.locale;
    HObject* parts = as_parts ? intl_array(ctx) : null;
    if (ctx.should_throw) return;
    uint count = 0;
    StrBuf result; result.init(ctx.heap);
    defer result.free();
    if (state.auto_numeric && (value == -1 || value == 0 || value == 1)) {
        // ToString(-0) is "0", so -0 selects the "this" phrase too. A row without a phrase falls
        // through to the numeric pattern.
        char[] phrase;
        if (row > 0) {
            usz base = ((usz)index * 3 + (usz)style) * INTL_RELATIVE_CELLS;
            phrase = intl_relative_cell(row, base + (usz)(value == -1 ? 0 : value == 0 ? 1 : 2));
        } else {
            phrase = value == -1 ? unit.last[style] : value == 0 ? unit.current[style] : unit.next[style];
        }
        if (phrase.len > 0) {
            intl_part(ctx, parts, &result, "literal", phrase, &count);
            intl_relative_finish(ctx, parts, count, &result);
            return;
        }
    }
    bool past = value < 0 || (value == 0 && math::signbit(value));
    TVal magnitude; magnitude.set_number(math::abs(value));
    IntlNumberState plural = state.number;
    plural.plural = true;
    char[] category = intl_select(ctx, &plural, magnitude);
    if (ctx.should_throw) return;
    // A row pattern is split at its {0}. English, and any row without a pattern, builds "in 2 days"
    // or "2 days ago" from the English unit table.
    StrBuf english; english.init(ctx.heap);
    defer english.free();
    char[] prefix;
    char[] suffix;
    char[] pattern = row > 0 ? intl_relative_pattern(row, (usz)index, style, past, category) : "";
    int slot = pattern.len > 0 ? intl_relative_slot(pattern) : -1;
    if (slot >= 0) {
        usz at = (usz)slot;
        prefix = pattern[:at];
        suffix = pattern[at + 3 : pattern.len - (at + 3)];
    } else {
        prefix = past ? "" : "in ";
        english.append_bytes(mem_eq_bytes(category, "one") ? unit.one[style] : unit.other[style]);
        if (past) english.append_bytes(" ago");
        suffix = english.bytes();
    }
    if (prefix.len > 0) intl_part(ctx, parts, &result, "literal", prefix, &count);
    uint number_start = count;
    if (!intl_format_number(ctx, &state.number, magnitude, parts, &count, &result)) return;
    if (parts != null) {
        HString* unit_name = builtin_intern_string(ctx.heap, unit.name);
        TVal unit_value; unit_value.set_string_borrowed(unit_name);
        for (uint i = number_start; i < count; i++) {
            TVal? part = parts.get_prop(ctx.heap.int_to_hstring(i), ctx.heap);
            if (try p = part) (void)intl_put(ctx.heap, (HObject*)p.get_heapptr(), "unit", unit_value);
        }
    }
    if (suffix.len > 0) intl_part(ctx, parts, &result, "literal", suffix, &count);
    intl_relative_finish(ctx, parts, count, &result);
}

fn void intl_relative_finish(BuiltinContext* ctx, HObject* parts, uint count, StrBuf* result) {
    if (result.failed || ctx.heap.has_error) { builtin_throw(ctx, ctx.heap.err_proto, "Intl allocation failed"); return; }
    if (parts != null) {
        array_set_length(parts, count, ctx.heap);
        ctx.result_object(parts);
    } else {
        ctx.result_string(builtin_intern_string(ctx.heap, result.bytes()));
    }
}

fn void builtin_intl_relative_format_call(BuiltinContext* ctx) { intl_relative_render(ctx, false); }
fn void builtin_intl_relative_parts(BuiltinContext* ctx) { intl_relative_render(ctx, true); }

fn bool register_intl_relative(HObject* ns, Heap* hp) {
    HObject* proto = hp.alloc_object(ObjClass.OBJECT) ?? null;
    HObject* ctor = hp.alloc_object(ObjClass.FUNCTION) ?? null;
    if (proto == null || ctor == null) return false;
    hp.set_prototype(proto, hp.object_proto); hp.set_prototype(ctor, hp.function_proto);
    (*ctor.extra_ptr()).func.builtin_fn_index = (int)Builtin.INTL_RELATIVE_FORMAT.ordinal;
    ctor.flags.callable = true; ctor.flags.constructable = true;
    set_func_ctor_name_length(ctor, hp, "RelativeTimeFormat", 0);
    TVal v; v.set_object(proto); intl_put(hp, ctor, "prototype", v, (PropFlags){});
    v.set_object(ctor); intl_put(hp, proto, "constructor", v, hobject::PROP_FLAGS_WC); intl_put(hp, ns, "RelativeTimeFormat", v, hobject::PROP_FLAGS_WC);
    HString* tag = builtin_intern_string(hp, INTL_RELATIVE_CLASS); v.set_string_borrowed(tag);
    proto.put_prop(ensure_tostringtag_symbol(hp), v, hobject::PROP_FLAGS_NWC, hp);
    if (hp.register_host_class((void*)&intl_finalize, (void*)&intl_mark, hp, tag, proto) < 0) return false;
    if (!register_string_proto_method(ctor, hp, "supportedLocalesOf", Builtin.INTL_SUPPORTED_LOCALES_ROWS.ordinal)) return false;
    if (!register_string_proto_method(proto, hp, "resolvedOptions", Builtin.INTL_RELATIVE_RESOLVED.ordinal)) return false;
    if (!register_string_proto_method(proto, hp, "format", Builtin.INTL_RELATIVE_FORMAT_CALL.ordinal)) return false;
    if (!register_string_proto_method(proto, hp, "formatToParts", Builtin.INTL_RELATIVE_PARTS.ordinal)) return false;
    return true;
}
