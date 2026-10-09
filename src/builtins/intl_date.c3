// English Gregorian formatting uses Temporal's timezone offsets and CLDR patterns.
module boomkat::builtins;
import boomkat::types;
import boomkat::heap;
import boomkat::hobject;
import boomkat::hstring;
import boomkat::env;
import boomkat::lib::temporal;
import std::math;

struct IntlDateState {
    HObject* bound_format;
    DateTimeFormatOpts fmt;
    int hour_cycle;
    int day_period;
    bool iso_calendar;
    bool us_locale;
    bool default_components;
    char[128] locale;
    usz locale_len;
    char[128] zone;
    usz zone_len;
    char[256] pattern;
    usz pattern_len;
    char[64] skeleton;
    usz skeleton_len;
}

fn void intl_date_mark(void* payload, Heap* hp, void* udata) {
    if (payload != null) hp.mark_hobject(((IntlDateState*)payload).bound_format);
}

fn long intl_date_class(Heap* hp) {
    for (uint i = 0; i < hp.host_class_count; i++) {
        if (hp.host_class_at(i).gc_mark == (void*)&intl_date_mark) return (long)i;
    }
    return -1;
}

fn IntlDateState* intl_date_receiver(BuiltinContext* ctx) {
    TVal receiver = ctx.regs[ctx.base_reg - 1];
    if (receiver.is_object()) {
        HObject* obj = (HObject*)receiver.get_heapptr();
        if (obj.get_class() == ObjClass.HOST && (long)(*obj.extra_ptr()).host.class_id == intl_date_class(ctx.heap)) {
            return (IntlDateState*)(*obj.extra_ptr()).host.payload;
        }
    }
    builtin_throw(ctx, ctx.heap.type_err_proto, "incompatible DateTimeFormat receiver");
    return null;
}

fn void intl_date_zone(BuiltinContext* ctx, HString* option, IntlDateState* state) {
    char[] zone;
    if (option == null) {
        char* system = boomkat_intl_system_tz_name();
        usz n = 0;
        if (system != null) while (system[n] != 0 && n < 127) n++;
        zone = n > 0 ? system[:n] : "UTC";
    } else { zone = option.get_cstr()[:option.blen]; }
    long offset;
    if (date_parse_offset_timezone(zone, &offset)) {
        state.fmt.tz_offset_sec = offset;
        state.fmt.tz_is_explicit = true;
        usz pos = 0;
        date_buf_push(state.zone[..], &pos, offset < 0 ? '-' : '+');
        long abs_offset = math::abs(offset);
        date_buf_append_num(state.zone[..], &pos, abs_offset / 3600, 2);
        date_buf_push(state.zone[..], &pos, ':');
        date_buf_append_num(state.zone[..], &pos, abs_offset / 60 % 60, 2);
        state.zone_len = pos;
        return;
    }
    if (locale_eq_ci(zone, "utc") || locale_eq_ci(zone, "gmt") || locale_eq_ci(zone, "etc/utc") ||
        locale_eq_ci(zone, "etc/gmt") || locale_eq_ci(zone, "etc/uct") || locale_eq_ci(zone, "uct") ||
        locale_eq_ci(zone, "universal") || locale_eq_ci(zone, "zulu") || locale_eq_ci(zone, "greenwich")) zone = "UTC";
    char[128] canonical;
    if (zone.len >= canonical.len || !temporal::tzdb_zone_exists_ci((String)zone, &canonical, canonical.len)) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "invalid time zone"); return;
    }
    usz n = 0;
    while (canonical[n] != 0) n++;
    zone = canonical[:n];
    foreach (link : INTL_ZONE_ALIASES) {
        if (mem_eq_bytes(zone, link.skeleton)) { zone = link.pattern; break; }
    }
    if (locale_eq_ci(zone, "etc/utc") || locale_eq_ci(zone, "etc/gmt")) zone = "UTC";
    for (usz i = 0; i < zone.len; i++) state.zone[i] = zone[i];
    state.zone_len = zone.len;
}

fn char[] intl_date_extension(char[] tag, char[] key) {
    char[][40] parts;
    int n = locale_split(tag, &parts);
    bool unicode = false;
    for (int i = 1; i < n; i++) {
        if (parts[i].len == 1) { unicode = parts[i][0] == 'u'; continue; }
        if (unicode && mem_eq_bytes(parts[i], key) && i + 1 < n && parts[i + 1].len > 2) return parts[i + 1];
    }
    return "";
}

fn char intl_date_field(char c) {
    switch (c) {
        case 'L': return 'M';
        case 'c': case 'e': return 'E';
        case 'K': case 'k': case 'H': return 'h';
        case 'b': case 'B': return 'a';
        case 'v': case 'V': case 'O': case 'X': case 'x': return 'z';
        default: return c;
    }
}

fn int intl_date_width(IntlDateState* state, char field) {
    DateTimeFormatOpts* f = &state.fmt;
    switch (intl_date_field(field)) {
        case 'E': return f.weekday == DTF_LONG ? 4 : f.weekday == DTF_NARROW ? 5 : 3;
        case 'G': return f.era == DTF_LONG ? 4 : f.era == DTF_NARROW ? 5 : 1;
        case 'y': return f.year == DTF_2DIGIT ? 2 : 1;
        case 'M': return f.month == DTF_LONG ? 4 : f.month == DTF_SHORT ? 3 : f.month == DTF_NARROW ? 5 : f.month == DTF_2DIGIT ? 2 : 1;
        case 'd': return f.day == DTF_2DIGIT ? 2 : 1;
        case 'h': return f.hour == DTF_2DIGIT || state.hour_cycle >= 23 ? 2 : 1;
        case 'm': return f.minute == DTF_2DIGIT ? 2 : 1;
        case 's': return f.second == DTF_2DIGIT ? 2 : 1;
        case 'S': return f.frac_digits;
        case 'a': return state.day_period == DTF_LONG ? 4 : state.day_period == DTF_NARROW ? 5 : 1;
        case 'z': return f.time_zone_name == 2 || f.time_zone_name == 4 || f.time_zone_name == 6 ? 4 : 1;
        default: return 1;
    }
}

fn char intl_date_hour_symbol(IntlDateState* state) {
    return state.hour_cycle == 11 ? 'K' : state.hour_cycle == 12 ? 'h' : state.hour_cycle == 24 ? 'k' : 'H';
}

fn void intl_date_adjust_pattern(IntlDateState* state, char[] pattern, char[] output, usz* pos) {
    bool quote = false;
    for (usz i = 0; i < pattern.len;) {
        char c = pattern[i];
        if (c == '\'') { quote = !quote; date_buf_push(output, pos, c); i++; continue; }
        if (quote || !locale_is_alpha(c)) { date_buf_push(output, pos, c); i++; continue; }
        usz j = i + 1;
        while (j < pattern.len && pattern[j] == c) j++;
        int width = intl_date_width(state, c);
        if (intl_date_field(c) == 'h') c = intl_date_hour_symbol(state);
        if (c == 'a' && state.day_period != 0) c = 'B';
        if (intl_date_field(c) == 'z') {
            int zone_name = state.fmt.time_zone_name;
            c = zone_name == 3 || zone_name == 4 ? 'O' : zone_name >= 5 ? 'v' : 'z';
        }
        for (int k = 0; k < width; k++) date_buf_push(output, pos, c);
        i = j;
    }
}

fn void intl_date_pattern(IntlDateState* state) {
    DateTimeFormatOpts* f = &state.fmt;
    state.pattern_len = 0;
    state.skeleton_len = 0;
    char[128] date_pattern;
    usz date_len = 0;
    char[128] time_pattern;
    usz time_len = 0;
    if (f.date_style != 0 || f.time_style != 0) {
        if (f.date_style != 0) date_buf_append(date_pattern[..], &date_len, INTL_DATE_STYLES[3 + f.date_style]);
        if (f.time_style != 0) {
            char[] style = INTL_DATE_STYLES[f.time_style - 1];
            // The 24-hour counterpart has no day-period marker.
            for (usz i = 0; i < style.len; i++) {
                if (state.hour_cycle >= 23 && style[i] == 'a') continue;
                if (state.hour_cycle >= 23 && i + 3 < style.len && style[i] == 0xe2 && style[i + 1] == 0x80 && style[i + 2] == 0xaf && style[i + 3] == 'a') { i += 3; continue; }
                date_buf_push(time_pattern[..], &time_len, style[i]);
            }
        }
    } else {
        char[16] skeleton;
        usz sk_len = 0;
        if (f.era != 0) date_buf_push(skeleton[..], &sk_len, 'G');
        if (f.year != 0) date_buf_push(skeleton[..], &sk_len, 'y');
        if (f.month != 0) for (int i = 0; i < (f.month >= 3 ? 3 : 1); i++) date_buf_push(skeleton[..], &sk_len, 'M');
        if (f.weekday != 0) date_buf_push(skeleton[..], &sk_len, 'E');
        if (f.day != 0) date_buf_push(skeleton[..], &sk_len, 'd');
        foreach (entry : INTL_DATE_PATTERNS) {
            if (mem_eq_bytes(entry.skeleton, skeleton[:sk_len])) { date_buf_append(date_pattern[..], &date_len, entry.pattern); break; }
        }
        if (date_len == 0 && sk_len > 0) {
            if (f.weekday != 0) date_buf_append(date_pattern[..], &date_len, "E");
            if (f.month != 0) { if (date_len > 0) date_buf_append(date_pattern[..], &date_len, ", "); date_buf_append(date_pattern[..], &date_len, "M"); }
            if (f.day != 0) { if (date_len > 0) date_buf_append(date_pattern[..], &date_len, f.month >= 3 ? " " : "/"); date_buf_append(date_pattern[..], &date_len, "d"); }
            if (f.year != 0) { if (date_len > 0) date_buf_append(date_pattern[..], &date_len, f.month >= 3 ? ", " : "/"); date_buf_append(date_pattern[..], &date_len, "y"); }
            if (f.era != 0) { if (date_len > 0) date_buf_push(date_pattern[..], &date_len, ' '); date_buf_append(date_pattern[..], &date_len, "G"); }
        }
        date_buf_append(state.skeleton[..], &state.skeleton_len, skeleton[:sk_len]);
        if (f.hour != 0) date_buf_append(time_pattern[..], &time_len, "h");
        if (f.minute != 0) { if (time_len > 0) date_buf_push(time_pattern[..], &time_len, ':'); date_buf_push(time_pattern[..], &time_len, 'm'); }
        if (f.second != 0) { if (time_len > 0) date_buf_push(time_pattern[..], &time_len, ':'); date_buf_push(time_pattern[..], &time_len, 's'); }
        if (f.frac_digits != 0) { if (time_len > 0) date_buf_push(time_pattern[..], &time_len, '.'); date_buf_push(time_pattern[..], &time_len, 'S'); }
        if (state.day_period != 0 && (f.hour == 0 || state.hour_cycle < 23)) { if (time_len > 0) date_buf_push(time_pattern[..], &time_len, ' '); date_buf_push(time_pattern[..], &time_len, 'B'); }
        else if (f.hour != 0 && state.hour_cycle < 23) date_buf_append(time_pattern[..], &time_len, "\u202fa");
        if (f.time_zone_name != 0) { if (time_len > 0) date_buf_push(time_pattern[..], &time_len, ' '); date_buf_push(time_pattern[..], &time_len, 'z'); }
    }
    intl_date_adjust_pattern(state, date_pattern[:date_len], state.pattern[..], &state.pattern_len);
    if (date_len > 0 && time_len > 0) date_buf_append(state.pattern[..], &state.pattern_len, f.month == DTF_LONG && f.day != 0 ? " 'at' " : f.month == 0 && f.day == 0 && f.year == 0 ? " " : ", ");
    intl_date_adjust_pattern(state, time_pattern[:time_len], state.pattern[..], &state.pattern_len);
}

fn bool intl_date_options(BuiltinContext* ctx, IntlDateState* state, TVal locales, TVal options, int required = DTF_REQ_ANY, int defaults = DTF_REQ_DATE) {
    *state = {};
    HObject* supported = intl_locales(ctx, locales);
    if (ctx.should_throw) return false;
    HObject* opts = intl_options(ctx, options);
    if (ctx.should_throw) return false;
    (void)intl_choice(ctx, opts, "localeMatcher", {"best fit", "lookup"});
    if (ctx.should_throw) return false;
    char[] tag = "en-US";
    if (array_get_length(supported, ctx.heap) > 0) {
        TVal first = array_get_elem(supported, 0, ctx.heap);
        HString* s = (HString*)first.get_heapptr();
        tag = s.get_cstr()[:s.blen];
    }
    state.us_locale = tag.len >= 5 && locale_eq_ci(tag[:5], "en-us");
    char[] hc_extension = intl_date_extension(tag, "hc");
    char[] ca_extension = intl_date_extension(tag, "ca");
    char[] nu_extension = intl_date_extension(tag, "nu");
    HString* calendar = date_get_raw_string_option(ctx, opts, "calendar");
    if (ctx.should_throw) return false;
    if (calendar != null && !date_is_unicode_type_subtag(calendar.get_cstr()[:calendar.blen])) { builtin_throw(ctx, ctx.heap.range_err_proto, "invalid calendar"); return false; }
    HString* numbering = date_get_raw_string_option(ctx, opts, "numberingSystem");
    if (ctx.should_throw) return false;
    if (numbering != null && !date_is_unicode_type_subtag(numbering.get_cstr()[:numbering.blen])) { builtin_throw(ctx, ctx.heap.range_err_proto, "invalid numbering system"); return false; }
    int hour12 = date_get_boolean_option(ctx, opts, "hour12");
    if (ctx.should_throw) return false;
    int hc = date_get_string_option(ctx, opts, "hourCycle", date_values_hour_cycle());
    if (ctx.should_throw) return false;
    state.hour_cycle = mem_eq_bytes(hc_extension, "h11") ? 11 : mem_eq_bytes(hc_extension, "h23") ? 23 : mem_eq_bytes(hc_extension, "h24") ? 24 : 12;
    if (hc != 0) state.hour_cycle = hc;
    if (hour12 >= 0) state.hour_cycle = hour12 == 1 ? 12 : 23;
    char[] ca_option = calendar == null ? "" : calendar.get_cstr()[:calendar.blen];
    bool supported_calendar = mem_eq_bytes(ca_option, "gregory") || mem_eq_bytes(ca_option, "iso8601");
    state.iso_calendar = supported_calendar ? mem_eq_bytes(ca_option, "iso8601") : mem_eq_bytes(ca_extension, "iso8601");
    date_buf_append(state.locale[..], &state.locale_len, state.us_locale ? "en-US" : "en");
    bool ca_keep = (!supported_calendar || mem_eq_bytes(ca_option, ca_extension)) && (mem_eq_bytes(ca_extension, "gregory") || mem_eq_bytes(ca_extension, "iso8601"));
    bool hc_keep = (hc == 0 || (hc == 11 && mem_eq_bytes(hc_extension, "h11")) || (hc == 12 && mem_eq_bytes(hc_extension, "h12")) || (hc == 23 && mem_eq_bytes(hc_extension, "h23")) || (hc == 24 && mem_eq_bytes(hc_extension, "h24"))) && hour12 < 0 && (mem_eq_bytes(hc_extension, "h11") || mem_eq_bytes(hc_extension, "h12") || mem_eq_bytes(hc_extension, "h23") || mem_eq_bytes(hc_extension, "h24"));
    bool nu_keep = (numbering == null || mem_eq_bytes(numbering.get_cstr()[:numbering.blen], "latn")) && mem_eq_bytes(nu_extension, "latn");
    if (ca_keep || hc_keep || nu_keep) {
        date_buf_append(state.locale[..], &state.locale_len, "-u");
        if (ca_keep) { date_buf_append(state.locale[..], &state.locale_len, "-ca-"); date_buf_append(state.locale[..], &state.locale_len, ca_extension); }
        if (hc_keep) { date_buf_append(state.locale[..], &state.locale_len, "-hc-"); date_buf_append(state.locale[..], &state.locale_len, hc_extension); }
        if (nu_keep) date_buf_append(state.locale[..], &state.locale_len, "-nu-latn");
    }
    HString* zone = date_get_raw_string_option(ctx, opts, "timeZone");
    if (ctx.should_throw) return false;
    intl_date_zone(ctx, zone, state);
    if (ctx.should_throw) return false;
    DateTimeFormatOpts* f = &state.fmt;
    f.hour12 = state.hour_cycle < 23 ? 1 : 0;
    f.weekday = date_get_string_option(ctx, opts, "weekday", date_values_narrow_short_long()); if (ctx.should_throw) return false;
    f.era = date_get_string_option(ctx, opts, "era", date_values_narrow_short_long()); if (ctx.should_throw) return false;
    f.year = date_get_string_option(ctx, opts, "year", date_values_numeric_2digit()); if (ctx.should_throw) return false;
    f.month = date_get_string_option(ctx, opts, "month", date_values_month()); if (ctx.should_throw) return false;
    f.day = date_get_string_option(ctx, opts, "day", date_values_numeric_2digit()); if (ctx.should_throw) return false;
    state.day_period = date_get_string_option(ctx, opts, "dayPeriod", date_values_narrow_short_long()); if (ctx.should_throw) return false;
    f.hour = date_get_string_option(ctx, opts, "hour", date_values_numeric_2digit()); if (ctx.should_throw) return false;
    f.minute = date_get_string_option(ctx, opts, "minute", date_values_numeric_2digit()); if (ctx.should_throw) return false;
    f.second = date_get_string_option(ctx, opts, "second", date_values_numeric_2digit()); if (ctx.should_throw) return false;
    f.frac_digits = date_get_number_option(ctx, opts, "fractionalSecondDigits", 1, 3); if (ctx.should_throw) return false;
    f.time_zone_name = date_get_string_option(ctx, opts, "timeZoneName", {{"short",1},{"long",2},{"shortOffset",3},{"longOffset",4},{"shortGeneric",5},{"longGeneric",6}}); if (ctx.should_throw) return false;
    bool explicit = f.weekday != 0 || f.era != 0 || f.year != 0 || f.month != 0 || f.day != 0 || state.day_period != 0 || f.hour != 0 || f.minute != 0 || f.second != 0 || f.frac_digits != 0 || f.time_zone_name != 0;
    (void)date_get_string_option(ctx, opts, "formatMatcher", date_values_format_matcher()); if (ctx.should_throw) return false;
    f.date_style = date_get_string_option(ctx, opts, "dateStyle", date_values_style()); if (ctx.should_throw) return false;
    f.time_style = date_get_string_option(ctx, opts, "timeStyle", date_values_style()); if (ctx.should_throw) return false;
    if (f.date_style != 0 || f.time_style != 0) {
        if (explicit || (required == DTF_REQ_DATE && f.time_style != 0) || (required == DTF_REQ_TIME && f.date_style != 0)) { builtin_throw(ctx, ctx.heap.type_err_proto, "style conflicts with date/time components"); return false; }
        date_expand_styles(f);
        if (f.time_style != 0) f.time_zone_name = f.time_style == DTS_FULL ? 2 : f.time_style == DTS_LONG ? 1 : 0;
    } else {
        bool date_fields = f.weekday != 0 || f.year != 0 || f.month != 0 || f.day != 0;
        bool time_fields = state.day_period != 0 || f.hour != 0 || f.minute != 0 || f.second != 0 || f.frac_digits != 0;
        bool need = required == DTF_REQ_DATE ? !date_fields : required == DTF_REQ_TIME ? !time_fields : !date_fields && !time_fields;
        state.default_components = need;
        if (need) {
            if (defaults != DTF_REQ_TIME) { f.year = DTF_NUMERIC; f.month = DTF_NUMERIC; f.day = DTF_NUMERIC; }
            if (defaults != DTF_REQ_DATE) { f.hour = DTF_NUMERIC; f.minute = DTF_NUMERIC; f.second = DTF_NUMERIC; }
        }
    }
    int clock_fields = (f.hour != 0 ? 1 : 0) + (f.minute != 0 ? 1 : 0) + (f.second != 0 ? 1 : 0);
    if (clock_fields > 1) { if (f.minute != 0) f.minute = DTF_2DIGIT; if (f.second != 0) f.second = DTF_2DIGIT; }
    else { if (f.minute != 0) f.minute = DTF_NUMERIC; if (f.second != 0) f.second = DTF_NUMERIC; }
    if (f.hour != 0 && state.hour_cycle >= 23) f.hour = DTF_2DIGIT;
    intl_date_pattern(state);
    return true;
}

fn void builtin_intl_date_format(BuiltinContext* ctx) {
    IntlDateState settings;
    if (!intl_date_options(ctx, &settings, builtin_arg(ctx, 0), builtin_arg(ctx, 1))) return;
    long id = intl_date_class(ctx.heap);
    HObject* proto = builtin_proto_from_new_target(ctx, ctx.heap.host_class_at((uint)id).proto);
    if (ctx.should_throw) return;
    HObject* obj = ctx.heap.alloc_object(ObjClass.HOST) ?? null;
    if (obj == null) { builtin_throw(ctx, ctx.heap.err_proto, "Intl allocation failed"); return; }
    (*obj.extra_ptr()).host.class_id = (uint)id;
    IntlDateState* state = (IntlDateState*)ctx.heap.alloc_func(ctx.heap.heap_udata, IntlDateState::size);
    if (state == null) { builtin_throw(ctx, ctx.heap.err_proto, "Intl allocation failed"); return; }
    *state = settings;
    (*obj.extra_ptr()).host.payload = state;
    ctx.heap.set_prototype(obj, proto);
    ctx.result_object(obj);
}

fn void builtin_intl_date_resolved(BuiltinContext* ctx) {
    IntlDateState* state = intl_date_receiver(ctx);
    if (state == null) return;
    HObject* out = ctx.heap.alloc_object(ObjClass.OBJECT) ?? null;
    if (out == null) { builtin_throw(ctx, ctx.heap.err_proto, "Intl allocation failed"); return; }
    ctx.heap.set_prototype(out, ctx.heap.object_proto);
    intl_put_string(ctx.heap, out, "locale", state.locale[:state.locale_len]);
    intl_put_string(ctx.heap, out, "calendar", state.iso_calendar ? "iso8601" : "gregory");
    intl_put_string(ctx.heap, out, "numberingSystem", "latn");
    intl_put_string(ctx.heap, out, "timeZone", state.zone[:state.zone_len]);
    DateTimeFormatOpts* f = &state.fmt;
    if (f.hour != 0) {
        intl_put_string(ctx.heap, out, "hourCycle", state.hour_cycle == 11 ? "h11" : state.hour_cycle == 12 ? "h12" : state.hour_cycle == 24 ? "h24" : "h23");
        TVal v; v.set_boolean(state.hour_cycle < 23); intl_put(ctx.heap, out, "hour12", v);
    }
    if (f.date_style != 0 || f.time_style != 0) {
        char[][] styles = {"", "full", "long", "medium", "short"};
        if (f.date_style != 0) intl_put_string(ctx.heap, out, "dateStyle", styles[f.date_style]);
        if (f.time_style != 0) intl_put_string(ctx.heap, out, "timeStyle", styles[f.time_style]);
    } else {
        char[][] widths = {"", "numeric", "2-digit", "long", "short", "narrow"};
        int[9] values = {f.weekday, f.era, f.year, f.month, f.day, state.day_period, f.hour, f.minute, f.second};
        char[][] keys = {"weekday", "era", "year", "month", "day", "dayPeriod", "hour", "minute", "second"};
        foreach (i, value : values) if (value != 0) intl_put_string(ctx.heap, out, keys[i], widths[value]);
        if (f.frac_digits != 0) intl_put_int(ctx.heap, out, "fractionalSecondDigits", f.frac_digits);
        char[][] zones = {"", "short", "long", "shortOffset", "longOffset", "shortGeneric", "longGeneric"};
        if (f.time_zone_name != 0) intl_put_string(ctx.heap, out, "timeZoneName", zones[f.time_zone_name]);
    }
    ctx.result_object(out);
}

struct IntlDateFields {
    long year;
    long month;
    long day;
    long weekday;
    long hour;
    long minute;
    long second;
    long ms;
    long epoch_sec;
    long offset;
    int kind;
}

fn int intl_date_kind(TVal input) {
    if (!input.is_object()) return 0;
    ObjClass cl = ((HObject*)input.get_heapptr()).get_class();
    switch (cl) {
        case TEMPORAL_INSTANT: case TEMPORAL_PLAIN_DATE: case TEMPORAL_PLAIN_DATETIME:
        case TEMPORAL_PLAIN_TIME: case TEMPORAL_PLAIN_YEARMONTH: case TEMPORAL_PLAIN_MONTHDAY:
        case TEMPORAL_ZONEDDATETIME: return (int)cl.ordinal;
        default: return 0;
    }
}

fn bool intl_date_fields(BuiltinContext* ctx, IntlDateState* state, TVal input, IntlDateFields* out) {
    double time;
    int kind = intl_date_kind(input);
    out.kind = kind;
    if (kind != 0) {
        HObject* object = (HObject*)input.get_heapptr();
        HObjectTemporal* slots = &(*object.extra_ptr()).temporal;
        if (kind == (int)ObjClass.TEMPORAL_ZONEDDATETIME.ordinal) {
            builtin_throw(ctx, ctx.heap.type_err_proto, "ZonedDateTime cannot be formatted by DateTimeFormat"); return false;
        }
        if (kind == (int)ObjClass.TEMPORAL_INSTANT.ordinal) {
            int128 nanos = slots.big_ns.to_int128();
            int128 millis = nanos / 1000000;
            if (nanos % 1000000 < 0) millis--;
            time = (double)millis;
            if (state.default_components) {
                state.fmt.hour = DTF_NUMERIC; state.fmt.minute = DTF_2DIGIT; state.fmt.second = DTF_2DIGIT;
                intl_date_pattern(state);
            }
        } else {
            bool plain_time = kind == (int)ObjClass.TEMPORAL_PLAIN_TIME.ordinal;
            bool datetime = kind == (int)ObjClass.TEMPORAL_PLAIN_DATETIME.ordinal;
            bool year_month = kind == (int)ObjClass.TEMPORAL_PLAIN_YEARMONTH.ordinal;
            bool month_day = kind == (int)ObjClass.TEMPORAL_PLAIN_MONTHDAY.ordinal;
            out.year = plain_time ? 1970 : slots.long_a;
            out.month = plain_time ? 0 : slots.long_b - 1;
            out.day = plain_time ? 1 : slots.long_c;
            out.hour = plain_time ? slots.long_a : datetime ? slots.long_d : 12;
            out.minute = plain_time ? slots.long_b : datetime ? slots.long_e : 0;
            out.second = plain_time ? slots.long_c : datetime ? slots.long_f : 0;
            out.ms = plain_time ? slots.long_d : datetime ? slots.long_g : 0;
            out.epoch_sec = temporal::epoch_days_from_civil(out.year, (int)out.month + 1, (int)out.day) * 86400 + out.hour * 3600 + out.minute * 60 + out.second;
            out.weekday = temporal::civil_from_seconds(out.epoch_sec).wday;
            DateTimeFormatOpts* f = &state.fmt;
            if (state.default_components) {
                f.year = plain_time || month_day ? 0 : DTF_NUMERIC;
                f.month = plain_time ? 0 : DTF_NUMERIC;
                f.day = plain_time || year_month ? 0 : DTF_NUMERIC;
                if (plain_time || datetime) { f.hour = DTF_NUMERIC; f.minute = DTF_2DIGIT; f.second = DTF_2DIGIT; }
            }
            if (plain_time) { f.weekday = 0; f.era = 0; f.year = 0; f.month = 0; f.day = 0; }
            if (year_month) { f.day = 0; f.weekday = 0; }
            if (month_day) { f.year = 0; f.era = 0; f.weekday = 0; }
            if (!plain_time && !datetime) { f.hour = 0; f.minute = 0; f.second = 0; f.frac_digits = 0; state.day_period = 0; }
            f.time_zone_name = 0;
            if (f.weekday == 0 && f.era == 0 && f.year == 0 && f.month == 0 && f.day == 0 && f.hour == 0 && f.minute == 0 && f.second == 0 && f.frac_digits == 0 && state.day_period == 0) {
                builtin_throw(ctx, ctx.heap.type_err_proto, "formatter has no fields for this Temporal type"); return false;
            }
            f.date_style = 0; f.time_style = 0;
            intl_date_pattern(state);
            return true;
        }
    } else if (input.is_undefined()) { time = date_now_ms(); }
    else { time = builtin_to_number_vm(ctx, &input); }
    if (ctx.should_throw) return false;
    if (math::is_nan(time) || math::is_inf(time) || math::abs(time) > 8640000000000000.0) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "invalid time value"); return false;
    }
    time = math::trunc(time);
    out.epoch_sec = date_ms_to_sec(time);
    out.offset = state.fmt.tz_is_explicit ? state.fmt.tz_offset_sec : temporal::tzdb_offset_for_zone_at((String)state.zone[:state.zone_len], out.epoch_sec);
    temporal::BrokenDownTime dt = temporal::civil_from_seconds(out.epoch_sec + out.offset);
    out.year = dt.y; out.month = dt.m; out.day = dt.d; out.weekday = dt.wday;
    out.hour = dt.h; out.minute = dt.mi; out.second = dt.s;
    out.ms = date_floor_mod_field(time, 1, 1000);
    return true;
}

fn char[] intl_date_data_string(ushort offset) {
    usz end = offset;
    while (intl_date_strings[end] != 0) end++;
    return intl_date_strings[offset:end - offset];
}

fn void intl_date_zone_text(IntlDateState* state, IntlDateFields* dt, char[] buf, usz* pos, bool long_name, bool generic, bool offset_only) {
    char[] zone = state.zone[:state.zone_len];
    if (mem_eq_bytes(zone, "UTC") && !offset_only) {
        date_buf_append(buf, pos, generic ? "GMT" : long_name ? "Coordinated Universal Time" : "UTC"); return;
    }
    if (!offset_only && !state.fmt.tz_is_explicit) {
        // January/July offsets identify the standard/daylight spelling for
        // common seasonal zones, including southern-hemisphere transitions.
        long jan = temporal::epoch_days_from_civil(dt.year, 1, 15) * 86400;
        long jul = temporal::epoch_days_from_civil(dt.year, 7, 15) * 86400;
        long standard = math::min((long)temporal::tzdb_offset_for_zone_at((String)zone, jan), (long)temporal::tzdb_offset_for_zone_at((String)zone, jul));
        bool daylight = dt.offset > standard;
        foreach (entry : INTL_ZONE_NAMES) {
            if (!mem_eq_bytes(intl_date_data_string(entry.zone), zone) || dt.epoch_sec < entry.from_sec || dt.epoch_sec >= entry.until_sec) continue;
            ushort offset = generic ? (long_name ? entry.generic : entry.short_generic) : daylight ? (long_name ? entry.daylight : entry.short_daylight) : (long_name ? entry.standard : entry.short_standard);
            char[] text = intl_date_data_string(offset);
            if (text.len > 0) { date_buf_append(buf, pos, text); return; }
            break;
        }
    }
    date_buf_append(buf, pos, "GMT");
    if (dt.offset == 0) return;
    date_buf_push(buf, pos, dt.offset < 0 ? '-' : '+');
    long abs_offset = math::abs(dt.offset);
    date_buf_append_num(buf, pos, abs_offset / 3600, long_name ? 2 : 1);
    if (long_name || abs_offset % 3600 != 0) {
        date_buf_push(buf, pos, ':'); date_buf_append_num(buf, pos, abs_offset / 60 % 60, 2);
    }
    if (abs_offset % 60 != 0) { date_buf_push(buf, pos, ':'); date_buf_append_num(buf, pos, abs_offset % 60, 2); }
}

fn char[] intl_date_type(char symbol) {
    switch (intl_date_field(symbol)) {
        case 'G': return "era";
        case 'y': return "year";
        case 'M': return "month";
        case 'd': return "day";
        case 'E': return "weekday";
        case 'h': return "hour";
        case 'm': return "minute";
        case 's': return "second";
        case 'S': return "fractionalSecond";
        case 'a': return "dayPeriod";
        case 'z': return "timeZoneName";
        default: return "literal";
    }
}

fn bool intl_date_part(BuiltinContext* ctx, HObject* parts, StrBuf* text, char[] type, char[] value, uint* count, char[] source = "") {
    if (!intl_part(ctx, parts, text, type, value, count)) return false;
    if (parts != null && source.len > 0) {
        TVal part = array_get_elem(parts, *count - 1, ctx.heap);
        if (!intl_put_string(ctx.heap, (HObject*)part.get_heapptr(), "source", source)) { text.failed = true; return false; }
    }
    return true;
}

fn void intl_date_emit(BuiltinContext* ctx, IntlDateState* state, IntlDateFields* dt, char[] pattern, HObject* parts, StrBuf* text, uint* count, char[] source = "") {
    char[256] literal;
    usz literal_len = 0;
    bool quote = false;
    for (usz i = 0; i <= pattern.len;) {
        char c = i < pattern.len ? pattern[i] : 0;
        if (c == '\'') {
            if (i + 1 < pattern.len && pattern[i + 1] == '\'') { date_buf_push(literal[..], &literal_len, '\''); i += 2; continue; }
            quote = !quote; i++; continue;
        }
        if (i < pattern.len && (quote || !locale_is_alpha(c))) { date_buf_push(literal[..], &literal_len, c); i++; continue; }
        if (literal_len > 0) {
            if (!intl_date_part(ctx, parts, text, "literal", literal[:literal_len], count, source)) return;
            literal_len = 0;
        }
        if (i == pattern.len) break;
        usz j = i + 1;
        while (j < pattern.len && pattern[j] == c) j++;
        int width = (int)(j - i);
        char[128] buf;
        usz len = 0;
        switch (intl_date_field(c)) {
            case 'y': {
                long shown = dt.year > 0 ? dt.year : 1 - dt.year;
                date_buf_append_num(buf[..], &len, width == 2 ? shown % 100 : shown, width == 2 ? 2 : 1);
            }
            case 'M': {
                if (width < 3) { date_buf_append_num(buf[..], &len, dt.month + 1, width); }
                else { char[] name = width == 3 ? date_month_short(dt.month) : date_month_long(dt.month); date_buf_append(buf[..], &len, width == 5 ? name[:1] : name); }
            }
            case 'd': date_buf_append_num(buf[..], &len, dt.day, width);
            case 'E': { char[] name = width < 4 ? date_weekday_short(dt.weekday) : date_weekday_long(dt.weekday); date_buf_append(buf[..], &len, width == 5 ? name[:1] : name); }
            case 'G': date_buf_append(buf[..], &len, dt.year > 0 ? (width == 4 ? "Anno Domini" : width == 5 ? "A" : "AD") : (width == 4 ? "Before Christ" : width == 5 ? "B" : "BC"));
            case 'h': {
                long hour = dt.hour;
                if (c == 'h' || c == 'K') { hour %= 12; if (c == 'h' && hour == 0) hour = 12; }
                if (c == 'k' && hour == 0) hour = 24;
                date_buf_append_num(buf[..], &len, hour, width);
            }
            case 'm': date_buf_append_num(buf[..], &len, dt.minute, width);
            case 's': date_buf_append_num(buf[..], &len, dt.second, width);
            case 'S': { long ms = dt.ms; for (int k = width; k < 3; k++) ms /= 10; date_buf_append_num(buf[..], &len, ms, width); }
            case 'a': {
                if (c != 'B') { date_buf_append(buf[..], &len, dt.hour < 12 ? "AM" : "PM"); }
                else {
                    bool noon = dt.hour == 12 && dt.minute == 0 && dt.second == 0 && dt.ms == 0;
                    date_buf_append(buf[..], &len, noon ? (width == 5 ? "n" : "noon") : dt.hour >= 6 && dt.hour < 12 ? "in the morning" : dt.hour >= 12 && dt.hour < 18 ? "in the afternoon" : dt.hour >= 18 && dt.hour < 21 ? "in the evening" : "at night");
                }
            }
            case 'z': intl_date_zone_text(state, dt, buf[..], &len, width >= 4, c == 'v', c == 'O');
            default: for (int k = 0; k < width; k++) date_buf_push(buf[..], &len, c);
        }
        if (!intl_date_part(ctx, parts, text, intl_date_type(c), buf[:len], count, source)) return;
        i = j;
    }
}

fn void intl_date_result(BuiltinContext* ctx, IntlDateState* state, TVal input, bool as_parts) {
    IntlDateState effective = *state;
    state = &effective;
    IntlDateFields dt;
    if (!intl_date_fields(ctx, state, input, &dt)) return;
    StrBuf text; text.init(ctx.heap); defer text.free();
    HObject* parts = as_parts ? intl_array(ctx) : null;
    if (ctx.should_throw) return;
    uint count = 0;
    intl_date_emit(ctx, state, &dt, state.pattern[:state.pattern_len], parts, &text, &count);
    if (text.failed || ctx.heap.has_error) { builtin_throw(ctx, ctx.heap.err_proto, "Intl allocation failed"); return; }
    if (as_parts) { array_set_length(parts, count, ctx.heap); ctx.result_object(parts); }
    else { ctx.result_string(builtin_intern_string(ctx.heap, text.bytes())); }
}

fn void builtin_intl_date_format_get(BuiltinContext* ctx) {
    IntlDateState* state = intl_date_receiver(ctx);
    if (state == null) return;
    if (state.bound_format == null) {
        HObject* bound = ctx.heap.alloc_object(ObjClass.FUNCTION) ?? null;
        if (bound == null) { builtin_throw(ctx, ctx.heap.err_proto, "Intl allocation failed"); return; }
        ctx.heap.set_prototype(bound, ctx.heap.function_proto);
        (*bound.extra_ptr()).func.builtin_fn_index = (int)Builtin.BOUND_CALL.ordinal;
        TVal target; target.set_lightfunc((void*)(usz)Builtin.INTL_DATE_FORMAT_CALL.ordinal);
        TVal receiver = ctx.regs[ctx.base_reg - 1];
        ctx.heap.tval_copy_ref(&(*bound.extra_ptr()).func.bound.target, &target);
        ctx.heap.tval_copy_ref(&(*bound.extra_ptr()).func.bound.this_arg, &receiver);
        bound.flags.is_bound = true; bound.flags.callable = true; bound.flags.constructable = false;
        set_func_ctor_name_length(bound, ctx.heap, "", 1);
        state.bound_format = bound;
        ctx.heap.write_barrier_ptr((HObject*)receiver.get_heapptr(), bound);
    }
    ctx.result_object(state.bound_format);
}

fn void builtin_intl_date_format_call(BuiltinContext* ctx) {
    IntlDateState* state = intl_date_receiver(ctx);
    if (state != null) intl_date_result(ctx, state, builtin_arg(ctx, 0), false);
}
fn void builtin_intl_date_parts(BuiltinContext* ctx) {
    IntlDateState* state = intl_date_receiver(ctx);
    if (state != null) intl_date_result(ctx, state, builtin_arg(ctx, 0), true);
}

fn void intl_date_range(BuiltinContext* ctx, bool as_parts) {
    IntlDateState* state = intl_date_receiver(ctx);
    if (state == null) return;
    TVal a = builtin_arg(ctx, 0);
    TVal b = builtin_arg(ctx, 1);
    if (a.is_undefined() || b.is_undefined()) { builtin_throw(ctx, ctx.heap.type_err_proto, "formatRange requires two dates"); return; }
    int ak = intl_date_kind(a);
    int bk = intl_date_kind(b);
    if (ak == 0) { double n = builtin_to_number_vm(ctx, &a); if (ctx.should_throw) return; a.set_number(n); }
    if (bk == 0) { double n = builtin_to_number_vm(ctx, &b); if (ctx.should_throw) return; b.set_number(n); }
    if (ak != bk) { builtin_throw(ctx, ctx.heap.type_err_proto, "range endpoints have different Temporal types"); return; }
    IntlDateState effective = *state;
    state = &effective;
    IntlDateFields first;
    IntlDateFields second;
    if (!intl_date_fields(ctx, state, a, &first) || !intl_date_fields(ctx, state, b, &second)) return;
    StrBuf text; text.init(ctx.heap); defer text.free();
    StrBuf other; other.init(ctx.heap); defer other.free();
    uint count = 0;
    intl_date_emit(ctx, state, &first, state.pattern[:state.pattern_len], null, &text, &count);
    intl_date_emit(ctx, state, &second, state.pattern[:state.pattern_len], null, &other, &count);
    bool same = mem_eq_bytes(text.bytes(), other.bytes());
    text.len = 0; count = 0;
    HObject* parts = as_parts ? intl_array(ctx) : null;
    if (ctx.should_throw) return;
    if (same) { intl_date_emit(ctx, state, &first, state.pattern[:state.pattern_len], parts, &text, &count, "shared"); }
    else {
        // Numeric dates repeat both endpoints; spelled-out dates share a
        // month/year suffix when CLDR supplies an interval pattern.
        char field = first.year != second.year ? 'y' : first.month != second.month ? 'M' : first.day != second.day ? 'd' : first.hour != second.hour ? 'h' : first.minute != second.minute ? 'm' : 's';
        char[] interval = "";
        if (state.fmt.hour == 0 && state.fmt.minute == 0 && state.fmt.second == 0 && state.fmt.frac_digits == 0) {
            foreach (entry : INTL_DATE_INTERVALS) if (mem_eq_bytes(entry.skeleton, state.skeleton[:state.skeleton_len]) && entry.field == field) { interval = entry.pattern; break; }
        }
        if (interval.len == 0) {
            usz time_start = 0;
            bool same_date = first.year == second.year && first.month == second.month && first.day == second.day;
            if (same_date && (state.fmt.year != 0 || state.fmt.month != 0 || state.fmt.day != 0 || state.fmt.weekday != 0)) {
                bool quoted = false;
                for (usz i = 0; i < state.pattern_len; i++) {
                    char c = state.pattern[i];
                    if (c == '\'') quoted = !quoted;
                    if (!quoted && (intl_date_field(c) == 'h' || c == 'm' || c == 's' || c == 'S' || c == 'B')) { time_start = i; break; }
                }
            }
            if (time_start > 0) intl_date_emit(ctx, state, &first, state.pattern[:time_start], parts, &text, &count, "shared");
            char[] endpoint_pattern = state.pattern[time_start:state.pattern_len - time_start];
            intl_date_emit(ctx, state, &first, endpoint_pattern, parts, &text, &count, "startRange");
            if (!intl_date_part(ctx, parts, &text, "literal", "\u2009\u2013\u2009", &count, "shared")) { builtin_throw(ctx, ctx.heap.err_proto, "Intl allocation failed"); return; }
            intl_date_emit(ctx, state, &second, endpoint_pattern, parts, &text, &count, "endRange");
        } else {
            char[256] adjusted;
            usz len = 0;
            intl_date_adjust_pattern(state, interval, adjusted[..], &len);
            char[128] left;
            usz left_len = 0;
            char[128] right;
            usz right_len = 0;
            bool end = false;
            bool[128] seen;
            for (usz i = 0; i < len;) {
                char c = adjusted[i];
                usz j = i + 1;
                if (locale_is_alpha(c)) {
                    while (j < len && adjusted[j] == c) j++;
                    char key = intl_date_field(c);
                    if (seen[key]) end = true;
                    seen[key] = true;
                }
                if (end) { date_buf_append(right[..], &right_len, adjusted[i:j-i]); }
                else { date_buf_append(left[..], &left_len, adjusted[i:j-i]); }
                i = j;
            }
            uint start = count;
            intl_date_emit(ctx, state, &first, left[:left_len], parts, &text, &count, "startRange");
            uint split = count;
            intl_date_emit(ctx, state, &second, right[:right_len], parts, &text, &count, "endRange");
            if (parts != null) {
                for (uint i = start; i < count; i++) {
                    TVal p = array_get_elem(parts, i, ctx.heap);
                    HObject* obj = (HObject*)p.get_heapptr();
                    char[] type = intl_part_field(ctx, parts, i, "type");
                    bool shared = false;
                    if (mem_eq_bytes(type, "literal")) { shared = i == split - 1; }
                    else {
                        bool both = false;
                        for (uint j = i < split ? split : start; j < (i < split ? count : split); j++) {
                            if (mem_eq_bytes(type, intl_part_field(ctx, parts, j, "type"))) both = true;
                        }
                        shared = !both;
                    }
                    if (shared) intl_put_string(ctx.heap, obj, "source", "shared");
                }
                for (uint i = start; i < count; i++) {
                    if (!mem_eq_bytes(intl_part_field(ctx, parts, i, "type"), "literal")) continue;
                    bool adjacent = (i > start && mem_eq_bytes(intl_part_field(ctx, parts, i - 1, "source"), "shared")) ||
                                    (i + 1 < count && mem_eq_bytes(intl_part_field(ctx, parts, i + 1, "source"), "shared"));
                    if (adjacent) { TVal p = array_get_elem(parts, i, ctx.heap); intl_put_string(ctx.heap, (HObject*)p.get_heapptr(), "source", "shared"); }
                }
            }
        }
    }
    if (text.failed || ctx.heap.has_error) { builtin_throw(ctx, ctx.heap.err_proto, "Intl allocation failed"); return; }
    if (parts != null) { array_set_length(parts, count, ctx.heap); ctx.result_object(parts); }
    else { ctx.result_string(builtin_intern_string(ctx.heap, text.bytes())); }
}
fn void builtin_intl_date_range(BuiltinContext* ctx) { intl_date_range(ctx, false); }
fn void builtin_intl_date_range_parts(BuiltinContext* ctx) { intl_date_range(ctx, true); }

fn bool register_intl_date(HObject* ns, Heap* hp) {
    HObject* proto = hp.alloc_object(ObjClass.OBJECT) ?? null;
    HObject* ctor = hp.alloc_object(ObjClass.FUNCTION) ?? null;
    if (proto == null || ctor == null) return false;
    hp.set_prototype(proto, hp.object_proto); hp.set_prototype(ctor, hp.function_proto);
    (*ctor.extra_ptr()).func.builtin_fn_index = (int)Builtin.INTL_DATE_FORMAT.ordinal;
    ctor.flags.callable = true; ctor.flags.constructable = true;
    set_func_ctor_name_length(ctor, hp, "DateTimeFormat", 0);
    TVal v; v.set_object(proto); intl_put(hp, ctor, "prototype", v, (PropFlags){});
    v.set_object(ctor); intl_put(hp, proto, "constructor", v, hobject::PROP_FLAGS_WC); intl_put(hp, ns, "DateTimeFormat", v, hobject::PROP_FLAGS_WC);
    HString* tag = builtin_intern_string(hp, "Intl.DateTimeFormat"); v.set_string_borrowed(tag);
    proto.put_prop(ensure_tostringtag_symbol(hp), v, hobject::PROP_FLAGS_NWC, hp);
    if (hp.register_host_class((void*)&intl_finalize, (void*)&intl_date_mark, hp, tag, proto) < 0) return false;
    if (!register_string_proto_method(ctor, hp, "supportedLocalesOf", Builtin.INTL_SUPPORTED_LOCALES.ordinal)) return false;
    if (!register_string_proto_method(proto, hp, "resolvedOptions", Builtin.INTL_DATE_RESOLVED.ordinal)) return false;
    if (!register_proto_getter_accessor(proto, hp, "format", Builtin.INTL_DATE_FORMAT_GET.ordinal)) return false;
    TVal? accessor = proto.get_prop(builtin_intern_string(hp, "format"), hp);
    if (try value = accessor) set_func_ctor_name((HObject*)hobject::hobject_access_getter(value).get_heapptr(), hp, "get format");
    if (!register_string_proto_method(proto, hp, "formatToParts", Builtin.INTL_DATE_PARTS.ordinal)) return false;
    if (!register_string_proto_method(proto, hp, "formatRange", Builtin.INTL_DATE_RANGE.ordinal)) return false;
    if (!register_string_proto_method(proto, hp, "formatRangeToParts", Builtin.INTL_DATE_RANGE_PARTS.ordinal)) return false;
    return true;
}
