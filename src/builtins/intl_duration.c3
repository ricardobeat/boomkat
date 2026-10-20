// Intl.DurationFormat (ECMA-402 §14) for English. Each displayed unit is
// rendered by the NumberFormat renderer; units that share the numeric clock
// ("1:02:03") form one list element and the elements are joined with the
// unit-list patterns of ListFormat.
module boomkat::builtins @feat(!NO_TEMPORAL);
import boomkat::types;
import boomkat::heap;
import boomkat::hobject;
import boomkat::hstring;
import boomkat::lib::temporal;
import std::math;

const usz DUR_UNIT_COUNT = 10;
const String[DUR_UNIT_COUNT] DUR_UNITS = {
    "years", "months", "weeks", "days", "hours", "minutes", "seconds", "milliseconds", "microseconds", "nanoseconds",
};
const char[][DUR_UNIT_COUNT] DUR_NUMBER_UNITS = {
    "year", "month", "week", "day", "hour", "minute", "second", "millisecond", "microsecond", "nanosecond",
};

const int DUR_STYLE_NUMERIC = 3;
const int DUR_STYLE_TWO_DIGIT = 4;
const int DUR_STYLE_FRACTIONAL = 5;

const int DUR_DISPLAY_AUTO = 0;
const int DUR_DISPLAY_ALWAYS = 1;

const int DUR_FIRST_CLOCK_UNIT = 4;
const int DUR_SECONDS = 6;

struct IntlDurationState {
    IntlPayloadHead head; // bound function slot read by intl_mark; unused by this service
    int locale; // index of the row in intl_row, 0 for English
    int label_mode; // see intl_label_mode
    bool us_locale;
    int numbering; // see intl_numbering_index
    bool numbering_ext; // the resolved locale keeps -u-nu-
    int style; // long, short, narrow, digital
    int[DUR_UNIT_COUNT] unit_style; // long, short, narrow, numeric, 2-digit, fractional
    int[DUR_UNIT_COUNT] unit_display; // auto, always
    int fractional_digits; // -1 when undefined
}

const String INTL_DURATION_CLASS = "Intl.DurationFormat";

fn IntlDurationState* intl_duration_receiver(BuiltinContext* ctx) {
    TVal v = ctx.regs[ctx.base_reg - 1];
    if (v.is_object()) {
        HObject* obj = (HObject*)v.get_heapptr();
        if (obj != null && obj.get_class() == ObjClass.HOST &&
            (long)(*obj.extra_ptr()).host.class_id == intl_class_named(ctx.heap, INTL_DURATION_CLASS)) {
            return (IntlDurationState*)(*obj.extra_ptr()).host.payload;
        }
    }
    builtin_throw(ctx, ctx.heap.type_err_proto, "incompatible Intl.DurationFormat receiver");
    return null;
}

// §14.1.2 GetDurationUnitOptions. `prev` is the style of the preceding clock
// unit, or -1 when none constrains this one.
fn bool intl_duration_unit_options(BuiltinContext* ctx, HObject* opts, IntlDurationState* state, int unit, int prev) {
    char[][5] all_styles = {"long", "short", "narrow", "numeric", "2-digit"};
    usz allowed = unit < DUR_FIRST_CLOCK_UNIT ? 3 : unit < 7 ? 5 : 4;
    int style = intl_choice(ctx, opts, DUR_UNITS[unit], all_styles[:allowed], -1);
    if (ctx.should_throw) return false;
    bool digital = state.style == 3;
    bool clock = unit >= DUR_FIRST_CLOCK_UNIT && unit <= DUR_SECONDS;
    int display_default = DUR_DISPLAY_ALWAYS;
    if (style < 0) {
        if (digital) {
            if (!clock) display_default = DUR_DISPLAY_AUTO;
            style = unit < DUR_FIRST_CLOCK_UNIT ? 1 : DUR_STYLE_NUMERIC;
        } else if (prev == DUR_STYLE_NUMERIC || prev == DUR_STYLE_TWO_DIGIT || prev == DUR_STYLE_FRACTIONAL) {
            if (!clock) display_default = DUR_DISPLAY_AUTO;
            style = DUR_STYLE_NUMERIC;
        } else {
            display_default = DUR_DISPLAY_AUTO;
            style = state.style;
        }
    }
    if (style == DUR_STYLE_NUMERIC && unit > DUR_SECONDS) {
        style = DUR_STYLE_FRACTIONAL;
        display_default = DUR_DISPLAY_AUTO;
    }
    int display = intl_choice(ctx, opts, DUR_UNITS_DISPLAY[unit], {"auto", "always"}, display_default);
    if (ctx.should_throw) return false;
    if (display == DUR_DISPLAY_ALWAYS && style == DUR_STYLE_FRACTIONAL) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "fractional units cannot be displayed always");
        return false;
    }
    if (prev == DUR_STYLE_FRACTIONAL && style != DUR_STYLE_FRACTIONAL) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "a unit after a fractional unit must be numeric");
        return false;
    }
    if (prev == DUR_STYLE_NUMERIC || prev == DUR_STYLE_TWO_DIGIT) {
        if (style < DUR_STYLE_NUMERIC) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "a unit after a numeric unit must be numeric");
            return false;
        }
        if (unit == 5 || unit == DUR_SECONDS) style = DUR_STYLE_TWO_DIGIT;
    }
    state.unit_style[unit] = style;
    state.unit_display[unit] = display;
    return true;
}

const String[DUR_UNIT_COUNT] DUR_UNITS_DISPLAY = {
    "yearsDisplay", "monthsDisplay", "weeksDisplay", "daysDisplay", "hoursDisplay", "minutesDisplay",
    "secondsDisplay", "millisecondsDisplay", "microsecondsDisplay", "nanosecondsDisplay",
};

// §14.1.1: the prototype is read from NewTarget before any option is touched.
fn void builtin_intl_duration_format(BuiltinContext* ctx) {
    if (!ctx.is_constructor) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "DurationFormat requires new");
        return;
    }
    long id = intl_class_named(ctx.heap, INTL_DURATION_CLASS);
    HObject* proto = builtin_proto_from_new_target(ctx, ctx.heap.host_class_at((uint)id).proto);
    if (ctx.should_throw) return;
    IntlDurationState settings;
    HObject* supported = intl_locales(ctx, builtin_arg(ctx, 0), false, true);
    if (ctx.should_throw) return;
    HObject* opts = intl_options_object(ctx, builtin_arg(ctx, 1));
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
    settings.locale = 0;
    if (try v = first) {
        HString* tag = (HString*)v.get_heapptr();
        first_tag = tag.get_cstr()[:tag.blen];
        settings.us_locale = tag.blen >= 5 && locale_eq_ci(tag.get_cstr()[:5], "en-us");
        int row = intl_row_for_tag(first_tag);
        settings.locale = row < 0 ? 0 : row;
        settings.label_mode = intl_label_mode(first_tag, row);
    }
    IntlNumbering resolved = intl_resolve_numbering(first_tag, numbering == null ? "" : numbering.get_cstr()[:numbering.blen], numbering != null);
    settings.numbering = intl_numbering_store(resolved.index);
    settings.numbering_ext = resolved.keep_extension;
    settings.style = intl_choice(ctx, opts, "style", {"long", "short", "narrow", "digital"}, 1);
    if (ctx.should_throw) return;
    int prev = -1;
    for (int unit = 0; unit < (int)DUR_UNIT_COUNT; unit++) {
        if (!intl_duration_unit_options(ctx, opts, &settings, unit, prev)) return;
        if (unit >= DUR_FIRST_CLOCK_UNIT && unit <= 8) prev = settings.unit_style[unit];
    }
    settings.fractional_digits = intl_digit(ctx, intl_option(ctx, opts, "fractionalDigits"), 0, 9, -1);
    if (ctx.should_throw) return;
    HObject* obj = ctx.heap.alloc_object(ObjClass.HOST) ?? null;
    if (obj == null) { builtin_throw(ctx, ctx.heap.err_proto, "Intl allocation failed"); return; }
    (*obj.extra_ptr()).host.class_id = (uint)id;
    IntlDurationState* state = (IntlDurationState*)ctx.heap.alloc_func(ctx.heap.heap_udata, IntlDurationState::size);
    if (state == null) { builtin_throw(ctx, ctx.heap.err_proto, "Intl allocation failed"); return; }
    *state = settings;
    (*obj.extra_ptr()).host.payload = state;
    ctx.heap.set_prototype(obj, proto);
    ctx.result_object(obj);
}

fn void builtin_intl_duration_resolved(BuiltinContext* ctx) {
    IntlDurationState* state = intl_duration_receiver(ctx);
    if (state == null) return;
    HObject* out = ctx.heap.alloc_object(ObjClass.OBJECT) ?? null;
    if (out == null) { builtin_throw(ctx, ctx.heap.err_proto, "Intl allocation failed"); return; }
    ctx.heap.set_prototype(out, ctx.heap.object_proto);
    char[][] styles = {"long", "short", "narrow", "digital"};
    char[][] unit_styles = {"long", "short", "narrow", "numeric", "2-digit", "numeric"};
    char[][] displays = {"auto", "always"};
    char[48] locale_buffer;
    IntlNumbering numbering = { .index = intl_numbering_index(state.numbering), .keep_extension = state.numbering_ext };
    usz row = (usz)state.locale;
    char[32] label_buffer;
    char[] tag = row > 0 ? intl_row_label(row, state.label_mode, label_buffer[..]) : state.us_locale ? "en-US" : "en";
    intl_put_string(ctx.heap, out, "locale", intl_resolved_locale(tag, numbering, locale_buffer[..]));
    intl_put_string(ctx.heap, out, "numberingSystem", intl_digit_name(numbering.index));
    intl_put_string(ctx.heap, out, "style", styles[state.style]);
    for (usz unit = 0; unit < DUR_UNIT_COUNT; unit++) {
        intl_put_string(ctx.heap, out, DUR_UNITS[unit], unit_styles[state.unit_style[unit]]);
        intl_put_string(ctx.heap, out, DUR_UNITS_DISPLAY[unit], displays[state.unit_display[unit]]);
    }
    if (state.fractional_digits >= 0) intl_put_int(ctx.heap, out, "fractionalDigits", state.fractional_digits);
    if (ctx.heap.has_error) { builtin_throw(ctx, ctx.heap.err_proto, "Intl allocation failed"); return; }
    ctx.result_object(out);
}

// One displayed unit: its decimal text (a slice of the shared store) and the
// number settings that render it.
struct IntlDurationEntry {
    IntlNumberState number;
    int unit;
    usz offset;
    usz length;
    bool joins; // continues the previous element with a ":" separator
}

fn bool intl_duration_append(StrBuf* out, int128 magnitude) {
    char[48] digits;
    usz n = 0;
    if (magnitude == 0) digits[n++] = '0';
    while (magnitude > 0) {
        digits[n++] = (char)('0' + (int)(magnitude % 10));
        magnitude /= 10;
    }
    while (n > 0) {
        if (!out.append_char(digits[--n])) return false;
    }
    return true;
}

// The magnitude of a field; the sub-second fields are doubles.
fn int128 intl_duration_field(DurationParts* d, int unit) {
    switch (unit) {
        case 0: return (int128)math::abs(d.years);
        case 1: return (int128)math::abs(d.months);
        case 2: return (int128)math::abs(d.weeks);
        case 3: return (int128)math::abs(d.days);
        case 4: return (int128)math::abs(d.hours);
        case 5: return (int128)math::abs(d.minutes);
        case 6: return (int128)math::abs(d.seconds);
        case 7: return (int128)math::abs(d.ms);
        case 8: return (int128)math::abs(d.us);
        default: return (int128)math::abs(d.ns);
    }
}

// Nanoseconds in the field and everything below it (seconds and smaller).
fn int128 intl_duration_tail_ns(DurationParts* d, int unit) {
    int128 total = 0;
    int128 scale = 1;
    for (int u = 9; u >= unit; u--) {
        total += intl_duration_field(d, u) * scale;
        scale *= 1000;
    }
    return total;
}

fn bool intl_duration_negative(DurationParts* d) {
    return d.years < 0 || d.months < 0 || d.weeks < 0 || d.days < 0 || d.hours < 0 || d.minutes < 0 ||
           d.seconds < 0 || d.ms < 0 || d.us < 0 || d.ns < 0;
}

// §14.5.1 PartitionDurationFormatPattern.
fn void intl_duration_render(BuiltinContext* ctx, bool as_parts) {
    IntlDurationState* state = intl_duration_receiver(ctx);
    if (state == null) return;
    DurationParts duration;
    if (!duration_record_from_arg(ctx, arg_at(ctx, 0), &duration)) return;
    bool negative = intl_duration_negative(&duration);
    StrBuf store; store.init(ctx.heap);
    defer store.free();
    IntlDurationEntry[DUR_UNIT_COUNT] entries;
    usz count = 0;
    usz groups = 0;
    bool need_separator = false;
    bool first = true;
    for (int unit = 0; unit < (int)DUR_UNIT_COUNT; unit++) {
        int style = state.unit_style[unit];
        bool fold = unit >= DUR_SECONDS && unit < 9 && state.unit_style[unit + 1] == DUR_STYLE_FRACTIONAL;
        int128 value = intl_duration_field(&duration, unit);
        int exponent = 9 - 3 * (unit - DUR_SECONDS);
        if (fold) value = intl_duration_tail_ns(&duration, unit);
        bool required = false;
        if (unit == 5 && need_separator) {
            required = state.unit_display[DUR_SECONDS] == DUR_DISPLAY_ALWAYS || intl_duration_tail_ns(&duration, DUR_SECONDS) != 0;
        }
        if (value != 0 || state.unit_display[unit] != DUR_DISPLAY_AUTO || required) {
            IntlDurationEntry* entry = &entries[count++];
            *entry = {};
            entry.unit = unit;
            entry.offset = store.len;
            IntlNumberState* nf = &entry.number;
            nf.grouping = 1;
            nf.us_locale = state.us_locale;
            nf.locale = state.locale;
            nf.numbering = state.numbering;
            nf.min_integer = 1;
            nf.max_fraction = 3;
            nf.rounding_increment = 1;
            nf.rounding_mode = 6;
            nf.unit = -1;
            nf.denominator = -1;
            if (first && negative) store.append_char('-');
            if (fold) {
                int128 scale = 1;
                for (int i = 0; i < exponent; i++) scale *= 10;
                intl_duration_append(&store, value / scale);
                store.append_char('.');
                int128 rest = value % scale;
                for (int128 pad = scale / 10; pad > 0; pad /= 10) {
                    store.append_char((char)('0' + (int)(rest / pad % 10)));
                }
                nf.max_fraction = state.fractional_digits >= 0 ? state.fractional_digits : 9;
                nf.min_fraction = state.fractional_digits >= 0 ? state.fractional_digits : 0;
                nf.rounding_mode = 3;
            } else {
                intl_duration_append(&store, value);
            }
            entry.length = store.len - entry.offset;
            nf.sign_display = first ? 0 : 1;
            first = false;
            if (style == DUR_STYLE_TWO_DIGIT) nf.min_integer = 2;
            if (style < DUR_STYLE_NUMERIC) {
                nf.style = 3;
                nf.unit = intl_unit_index(DUR_NUMBER_UNITS[unit]);
                nf.unit_display = style == 0 ? 2 : style == 1 ? 0 : 1;
            } else {
                nf.grouping = 0;
            }
            entry.joins = need_separator;
            if (!need_separator) {
                groups++;
                if (style >= DUR_STYLE_NUMERIC) need_separator = true;
            }
        }
        if (fold) break;
    }
    if (store.failed) { builtin_throw(ctx, ctx.heap.err_proto, "Intl allocation failed"); return; }
    IntlListPattern pattern = intl_list_pattern((usz)state.locale, 6 + (usz)(state.style == 3 ? 1 : state.style));
    HObject* parts = as_parts ? intl_array(ctx) : null;
    if (ctx.should_throw) return;
    uint part_count = 0;
    StrBuf result; result.init(ctx.heap);
    defer result.free();
    char[] text = store.bytes();
    usz group = 0;
    for (usz i = 0; i < count; i++) {
        IntlDurationEntry* entry = &entries[i];
        if (entry.joins) {
            intl_part(ctx, parts, &result, "literal", ":", &part_count);
        } else {
            if (group > 0) {
                String sep = groups == 2 ? pattern.pair : group == 1 ? pattern.start : group == groups - 1 ? pattern.end : pattern.middle;
                intl_part(ctx, parts, &result, "literal", sep, &part_count);
            }
            group++;
        }
        HString* digits = builtin_intern_string(ctx.heap, text[entry.offset:entry.length]);
        TVal input; input.set_string_borrowed(digits);
        uint start = part_count;
        if (!intl_format_number(ctx, &entry.number, input, parts, &part_count, &result)) return;
        if (parts != null) {
            HString* name = builtin_intern_string(ctx.heap, DUR_NUMBER_UNITS[entry.unit]);
            TVal unit_value; unit_value.set_string_borrowed(name);
            for (uint k = start; k < part_count; k++) {
                TVal? part = parts.get_prop(ctx.heap.int_to_hstring(k), ctx.heap);
                if (try p = part) (void)intl_put(ctx.heap, (HObject*)p.get_heapptr(), "unit", unit_value);
            }
        }
    }
    if (result.failed || ctx.heap.has_error) { builtin_throw(ctx, ctx.heap.err_proto, "Intl allocation failed"); return; }
    if (parts != null) {
        array_set_length(parts, part_count, ctx.heap);
        ctx.result_object(parts);
    } else {
        ctx.result_string(builtin_intern_string(ctx.heap, result.bytes()));
    }
}

fn void builtin_intl_duration_format_call(BuiltinContext* ctx) { intl_duration_render(ctx, false); }
fn void builtin_intl_duration_parts(BuiltinContext* ctx) { intl_duration_render(ctx, true); }

fn bool register_intl_duration(HObject* ns, Heap* hp) {
    HObject* proto = hp.alloc_object(ObjClass.OBJECT) ?? null;
    HObject* ctor = hp.alloc_object(ObjClass.FUNCTION) ?? null;
    if (proto == null || ctor == null) return false;
    hp.set_prototype(proto, hp.object_proto); hp.set_prototype(ctor, hp.function_proto);
    (*ctor.extra_ptr()).func.builtin_fn_index = (int)Builtin.INTL_DURATION_FORMAT.ordinal;
    ctor.flags.callable = true; ctor.flags.constructable = true;
    set_func_ctor_name_length(ctor, hp, "DurationFormat", 0);
    TVal v; v.set_object(proto); intl_put(hp, ctor, "prototype", v, (PropFlags){});
    v.set_object(ctor); intl_put(hp, proto, "constructor", v, hobject::PROP_FLAGS_WC); intl_put(hp, ns, "DurationFormat", v, hobject::PROP_FLAGS_WC);
    HString* tag = builtin_intern_string(hp, INTL_DURATION_CLASS); v.set_string_borrowed(tag);
    proto.put_prop(ensure_tostringtag_symbol(hp), v, hobject::PROP_FLAGS_NWC, hp);
    if (hp.register_host_class((void*)&intl_finalize, (void*)&intl_mark, hp, tag, proto) < 0) return false;
    if (!register_string_proto_method(ctor, hp, "supportedLocalesOf", Builtin.INTL_SUPPORTED_LOCALES_ROWS.ordinal)) return false;
    if (!register_string_proto_method(proto, hp, "resolvedOptions", Builtin.INTL_DURATION_RESOLVED.ordinal)) return false;
    if (!register_string_proto_method(proto, hp, "format", Builtin.INTL_DURATION_FORMAT_CALL.ordinal)) return false;
    if (!register_string_proto_method(proto, hp, "formatToParts", Builtin.INTL_DURATION_PARTS.ordinal)) return false;
    return true;
}
