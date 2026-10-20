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
    int calendar_kind; // 0 for gregory and iso8601, else a CAL_* kind from intl_lunar.c3
    bool zh_names;      // Chinese calendar names come from zh rather than root
    bool us_locale;
    int row; // index in intl_row, 0 for English
    int numbering; // see intl_numbering_index
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
    usz n = intl_zone_canonical(zone, state.zone[..]);
    if (n == 0) { builtin_throw(ctx, ctx.heap.range_err_proto, "invalid time zone"); return; }
    state.zone_len = n;
}

// Writes the canonical spelling of a named zone into `out` and returns its
// length, or 0 when the zone is unknown.
fn usz intl_zone_canonical(char[] zone, char[] out) {
    if (locale_eq_ci(zone, "utc") || locale_eq_ci(zone, "gmt") || locale_eq_ci(zone, "etc/utc") ||
        locale_eq_ci(zone, "etc/gmt") || locale_eq_ci(zone, "etc/uct") || locale_eq_ci(zone, "uct") ||
        locale_eq_ci(zone, "universal") || locale_eq_ci(zone, "zulu") || locale_eq_ci(zone, "greenwich")) zone = "UTC";
    char[128] canonical;
    if (zone.len >= canonical.len || !temporal::tzdb_zone_exists_ci((String)zone, &canonical, canonical.len)) return 0;
    usz n = 0;
    while (canonical[n] != 0) n++;
    zone = canonical[:n];
    char[64] target;
    int target_index = intl_zone_alias((String)zone);
    if (target_index >= 0) zone = target[:temporal::tzdb_zone_name(target_index, &target[0])];
    if (locale_eq_ci(zone, "etc/utc") || locale_eq_ci(zone, "etc/gmt")) zone = "UTC";
    for (usz i = 0; i < zone.len; i++) out[i] = zone[i];
    return zone.len;
}

fn char[] intl_date_extension(char[] tag, char[] key) {
    char[][40] parts;
    int n = locale_split(tag, &parts);
    bool unicode = false;
    for (int i = 1; i < n; i++) {
        if (parts[i].len == 1) { unicode = parts[i][0] == 'u'; continue; }
        if (unicode && mem_eq_bytes(parts[i], key) && i + 1 < n && parts[i + 1].len > 2) {
            // A type can span several subtags (islamic-civil); keys are two characters long.
            int last = i + 1;
            while (last + 1 < n && parts[last + 1].len > 2) last++;
            usz start = (usz)((uptr)parts[i + 1].ptr - (uptr)tag.ptr);
            usz end = (usz)((uptr)parts[last].ptr - (uptr)tag.ptr) + parts[last].len;
            return tag[start:end - start];
        }
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
        // A single M in a locale pattern is the month number, even where the option asks for names ("9月").
        if (state.row > 0 && intl_date_field(c) == 'M' && j - i == 1 && (state.fmt.month == DTF_LONG || state.fmt.month == DTF_SHORT || state.fmt.month == DTF_NARROW)) width = 1;
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

// The row's text for a date field, or the English text when the row has none.
fn char[] intl_date_text(IntlDateState* state, IntlDateField field, usz index, char[] english) {
    char[] text = intl_row_date_text((usz)state.row, field, index);
    return text.len > 0 ? text : english;
}

// The locale's preferred hour cycle (CLDR's first allowed cycle for its region), as 11, 12, 23 or
// 24. With twelve set, the first 12-hour cycle the locale lists (hourCycle12), else 12.
fn int intl_locale_hour_cycle(char[] tag, bool twelve) {
    LocaleId id;
    if (!id.parse(tag)) return 12;
    LocaleNames cycles;
    locale_hour_cycles(&id, &cycles);
    foreach (cycle : cycles.items[:cycles.count]) {
        if (twelve && !(mem_eq_bytes(cycle, "h11") || mem_eq_bytes(cycle, "h12"))) continue;
        return mem_eq_bytes(cycle, "h11") ? 11 : mem_eq_bytes(cycle, "h23") ? 23 : mem_eq_bytes(cycle, "h24") ? 24 : 12;
    }
    return twelve ? 12 : 23;
}

// Names by width: a month or weekday name in full, abbreviated or narrow form. Row 0 uses the
// English tables; other rows use their own names.
fn char[] intl_date_month_name(IntlDateState* state, long month, int width) {
    if (state.row > 0) {
        usz block = width == 3 ? 1 : width == 5 ? 2 : 0;
        char[] name = intl_row_date_text((usz)state.row, IntlDateField.MONTHS, block * 12 + (usz)month);
        if (name.len > 0) return name;
    }
    char[] name = width == 3 ? date_month_short(month) : date_month_long(month);
    return width == 5 ? name[:1] : name;
}

fn char[] intl_date_weekday_name(IntlDateState* state, long weekday, int width) {
    if (state.row > 0) {
        usz block = width == 4 ? 0 : width == 5 ? 2 : 1;
        char[] name = intl_row_date_text((usz)state.row, IntlDateField.DAYS, block * 7 + (usz)weekday);
        if (name.len > 0) return name;
    }
    char[] name = width < 4 ? date_weekday_short(weekday) : date_weekday_long(weekday);
    return width == 5 ? name[:1] : name;
}

// Era names are stored abbreviated, wide, narrow, each as BC then AD.
fn char[] intl_date_era_name(IntlDateState* state, long year, int width) {
    usz era = year > 0 ? 1 : 0;
    if (state.calendar_kind == CAL_HEBREW) return width == 4 ? "Anno Mundi" : "AM";
    if (state.calendar_kind == CAL_ISLAMIC_CIVIL) {
        if (width == 4) return era == 0 ? "Anno Hegirae" : "Before Hijrah";
        return era == 0 ? "AH" : "BH";
    }
    if (state.row > 0) {
        usz block = width == 4 ? 1 : width == 5 ? 2 : 0;
        char[] name = intl_row_date_text((usz)state.row, IntlDateField.ERAS, block * 2 + era);
        if (name.len > 0) return name;
    }
    if (era == 1) return width == 4 ? "Anno Domini" : width == 5 ? "A" : "AD";
    return width == 4 ? "Before Christ" : width == 5 ? "B" : "BC";
}

fn char[] intl_date_day_period_name(IntlDateState* state, long hour, int width) {
    usz half = hour < 12 ? 0 : 1;
    if (state.row > 0) {
        char[] name = intl_row_date_text((usz)state.row, width == 5 ? IntlDateField.AMPM_NARROW : IntlDateField.AMPM, half);
        if (name.len > 0) return name;
    }
    return half == 0 ? "AM" : "PM";
}

// The index in INTL_DATE_PATTERNS of the English availableFormats entry with this skeleton, or -1.
fn int intl_date_skeleton_index(char[] skeleton) {
    foreach (i, entry : INTL_DATE_PATTERNS) {
        if (mem_eq_bytes(intl_date_data_string(entry.skeleton), skeleton)) return (int)i;
    }
    return -1;
}

// The decimal separator for fractional seconds: the row's, else the numbering system's.
fn char[] intl_date_decimal(IntlDateState* state) {
    if (state.row > 0) return intl_row_text((usz)state.row, intl_row((usz)state.row).decimal);
    return mem_eq_bytes(intl_digit_name(intl_numbering_index(state.numbering)), "arab") ? "٫" : ".";
}

// Builds the pattern from the styles or the fields. Locale rows supply the patterns, names and
// glue; the English tables cover what a row lacks.
fn void intl_date_pattern(IntlDateState* state) {
    DateTimeFormatOpts* f = &state.fmt;
    usz row = (usz)state.row;
    state.pattern_len = 0;
    state.skeleton_len = 0;
    char[128] date_pattern;
    usz date_len = 0;
    char[128] time_pattern;
    usz time_len = 0;
    char[256] combined;
    usz combined_len = 0;
    if (f.date_style != 0 || f.time_style != 0) {
        if (f.date_style != 0) date_buf_append(date_pattern[..], &date_len, intl_date_text(state, IntlDateField.DATE_STYLES, (usz)(f.date_style - 1), intl_date_data_string(INTL_DATE_STYLES[3 + f.date_style])));
        if (f.time_style != 0) {
            char[] style = intl_date_text(state, IntlDateField.TIME_STYLES, (usz)(f.time_style - 1), intl_date_data_string(INTL_DATE_STYLES[f.time_style - 1]));
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
        int date_match = intl_date_skeleton_index(skeleton[:sk_len]);
        if (date_match >= 0) date_buf_append(date_pattern[..], &date_len, intl_row_date_text(row, IntlDateField.SKELETONS, (usz)date_match));
        if (date_len == 0 && date_match >= 0) date_buf_append(date_pattern[..], &date_len, intl_date_data_string(INTL_DATE_PATTERNS[date_match].pattern));
        if (date_len == 0 && sk_len > 0) {
            if (f.weekday != 0) date_buf_append(date_pattern[..], &date_len, "E");
            if (f.month != 0) { if (date_len > 0) date_buf_append(date_pattern[..], &date_len, ", "); date_buf_append(date_pattern[..], &date_len, "M"); }
            if (f.day != 0) { if (date_len > 0) date_buf_append(date_pattern[..], &date_len, f.month >= 3 ? " " : "/"); date_buf_append(date_pattern[..], &date_len, "d"); }
            if (f.year != 0) { if (date_len > 0) date_buf_append(date_pattern[..], &date_len, f.month >= 3 ? ", " : "/"); date_buf_append(date_pattern[..], &date_len, "y"); }
            if (f.era != 0) { if (date_len > 0) date_buf_push(date_pattern[..], &date_len, ' '); date_buf_append(date_pattern[..], &date_len, "G"); }
        }
        date_buf_append(state.skeleton[..], &state.skeleton_len, skeleton[:sk_len]);
        // A time skeleton the locale lists (hms, Hm, ...) supplies the whole clock with its own day period.
        char[16] time_skeleton;
        usz tsk_len = 0;
        if (f.hour != 0) date_buf_push(time_skeleton[..], &tsk_len, state.hour_cycle >= 23 ? 'H' : 'h');
        if (f.minute != 0) date_buf_push(time_skeleton[..], &tsk_len, 'm');
        if (f.second != 0) date_buf_push(time_skeleton[..], &tsk_len, 's');
        int time_match = f.frac_digits == 0 && tsk_len > 0 ? intl_date_skeleton_index(time_skeleton[:tsk_len]) : -1;
        char[] row_time = time_match >= 0 ? intl_row_date_text(row, IntlDateField.SKELETONS, (usz)time_match) : "";
        if (row_time.len > 0) {
            date_buf_append(time_pattern[..], &time_len, row_time);
        } else {
            if (f.hour != 0) date_buf_append(time_pattern[..], &time_len, "h");
            if (f.minute != 0) { if (time_len > 0) date_buf_push(time_pattern[..], &time_len, ':'); date_buf_push(time_pattern[..], &time_len, 'm'); }
            if (f.second != 0) { if (time_len > 0) date_buf_push(time_pattern[..], &time_len, ':'); date_buf_push(time_pattern[..], &time_len, 's'); }
            if (f.frac_digits != 0) { if (time_len > 0) date_buf_append(time_pattern[..], &time_len, intl_date_decimal(state)); date_buf_push(time_pattern[..], &time_len, 'S'); }
            if (f.hour != 0 && state.hour_cycle < 23 && state.day_period == 0) date_buf_append(time_pattern[..], &time_len, " a");
        }
        if (state.day_period != 0 && (f.hour == 0 || state.hour_cycle < 23)) { if (time_len > 0) date_buf_push(time_pattern[..], &time_len, ' '); date_buf_push(time_pattern[..], &time_len, 'B'); }
        if (f.time_zone_name != 0) { if (time_len > 0) date_buf_push(time_pattern[..], &time_len, ' '); date_buf_push(time_pattern[..], &time_len, 'z'); }
    }
    if (date_len > 0 && time_len > 0) {
        if (row > 0 && f.date_style != 0 && f.time_style != 0) {
            // The row's glue for the date style, with {1} the date and {0} the time.
            char[] glue = intl_row_date_text(row, IntlDateField.GLUES, (usz)(f.date_style - 1));
            for (usz i = 0; i < glue.len;) {
                if (i + 2 < glue.len && glue[i] == '{' && glue[i + 2] == '}' && glue[i + 1] == '1') { date_buf_append(combined[..], &combined_len, date_pattern[:date_len]); i += 3; continue; }
                if (i + 2 < glue.len && glue[i] == '{' && glue[i + 2] == '}' && glue[i + 1] == '0') { date_buf_append(combined[..], &combined_len, time_pattern[:time_len]); i += 3; continue; }
                date_buf_push(combined[..], &combined_len, glue[i]);
                i++;
            }
        } else {
            date_buf_append(combined[..], &combined_len, date_pattern[:date_len]);
            date_buf_append(combined[..], &combined_len, f.month == DTF_LONG && f.day != 0 ? " 'at' " : f.month == 0 && f.day == 0 && f.year == 0 ? " " : ", ");
            date_buf_append(combined[..], &combined_len, time_pattern[:time_len]);
        }
    } else if (date_len > 0) {
        date_buf_append(combined[..], &combined_len, date_pattern[:date_len]);
    } else {
        date_buf_append(combined[..], &combined_len, time_pattern[:time_len]);
    }
    intl_date_adjust_pattern(state, combined[:combined_len], state.pattern[..], &state.pattern_len);
}

fn bool intl_date_options(BuiltinContext* ctx, IntlDateState* state, TVal locales, TVal options, int required = DTF_REQ_ANY, int defaults = DTF_REQ_DATE) {
    *state = {};
    HObject* supported = intl_locales(ctx, locales, IntlLocaleFilter.ROWS);
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
    state.row = intl_row_for_tag(tag);
    if (state.row < 0) state.row = 0;
    state.us_locale = tag.len >= 5 && locale_eq_ci(tag[:5], "en-us");
    char[] hc_extension = intl_date_extension(tag, "hc");
    char[] ca_extension = intl_date_extension(tag, "ca");
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
    state.hour_cycle = mem_eq_bytes(hc_extension, "h11") ? 11 : mem_eq_bytes(hc_extension, "h23") ? 23 : mem_eq_bytes(hc_extension, "h24") ? 24 : mem_eq_bytes(hc_extension, "h12") ? 12 : intl_locale_hour_cycle(tag, false);
    if (hc != 0) state.hour_cycle = hc;
    if (hour12 >= 0) state.hour_cycle = hour12 == 1 ? intl_locale_hour_cycle(tag, true) : 23;
    // The option is ASCII case-insensitive, so it is lowercased before it is compared with the names.
    char[64] ca_buf;
    usz ca_len = 0;
    if (calendar != null && calendar.blen <= ca_buf.len) {
        char[] raw = calendar.get_cstr()[:calendar.blen];
        for (usz k = 0; k < raw.len; k++) {
            char ch = raw[k];
            ca_buf[k] = ch >= 'A' && ch <= 'Z' ? (char)(ch + 32) : ch;
        }
        ca_len = raw.len;
    }
    char[] ca_option = ca_buf[:ca_len];
    int calendar_option = intl_calendar_kind(ca_option);
    bool supported_calendar = mem_eq_bytes(ca_option, "gregory") || mem_eq_bytes(ca_option, "iso8601") || calendar_option != 0;
    state.iso_calendar = supported_calendar ? mem_eq_bytes(ca_option, "iso8601") : mem_eq_bytes(ca_extension, "iso8601");
    state.calendar_kind = supported_calendar ? calendar_option : intl_calendar_kind(ca_extension);
    state.zh_names = tag.len >= 2 && locale_eq_ci(tag[:2], "zh");
    if (state.row > 0) {
        char[32] label_buffer;
        date_buf_append(state.locale[..], &state.locale_len, intl_row_label((usz)state.row, intl_label_mode(tag, state.row), label_buffer[..]));
    } else {
        date_buf_append(state.locale[..], &state.locale_len, state.us_locale ? "en-US" : "en");
    }
    bool ca_keep = (!supported_calendar || mem_eq_bytes(ca_option, ca_extension)) && (mem_eq_bytes(ca_extension, "gregory") || mem_eq_bytes(ca_extension, "iso8601") || intl_calendar_kind(ca_extension) != 0);
    bool hc_keep = (hc == 0 || (hc == 11 && mem_eq_bytes(hc_extension, "h11")) || (hc == 12 && mem_eq_bytes(hc_extension, "h12")) || (hc == 23 && mem_eq_bytes(hc_extension, "h23")) || (hc == 24 && mem_eq_bytes(hc_extension, "h24"))) && hour12 < 0 && (mem_eq_bytes(hc_extension, "h11") || mem_eq_bytes(hc_extension, "h12") || mem_eq_bytes(hc_extension, "h23") || mem_eq_bytes(hc_extension, "h24"));
    IntlNumbering resolved_numbering = intl_resolve_numbering(tag, numbering == null ? "" : numbering.get_cstr()[:numbering.blen], numbering != null);
    state.numbering = intl_numbering_store(resolved_numbering.index);
    bool nu_keep = resolved_numbering.keep_extension;
    if (ca_keep || hc_keep || nu_keep) {
        date_buf_append(state.locale[..], &state.locale_len, "-u");
        if (ca_keep) { date_buf_append(state.locale[..], &state.locale_len, "-ca-"); date_buf_append(state.locale[..], &state.locale_len, ca_extension); }
        if (hc_keep) { date_buf_append(state.locale[..], &state.locale_len, "-hc-"); date_buf_append(state.locale[..], &state.locale_len, hc_extension); }
        if (nu_keep) { date_buf_append(state.locale[..], &state.locale_len, "-nu-"); date_buf_append(state.locale[..], &state.locale_len, intl_digit_name(resolved_numbering.index)); }
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
    intl_put_string(ctx.heap, out, "calendar", state.calendar_kind != 0 ? intl_calendar_name(state.calendar_kind) : state.iso_calendar ? "iso8601" : "gregory");
    intl_put_string(ctx.heap, out, "numberingSystem", intl_digit_name(intl_numbering_index(state.numbering)));
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
    long year;          // related year for the lunisolar calendars
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
    bool leap;
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
    if (state.calendar_kind != 0) {
        temporal::CalendarId cal = state.calendar_kind == CAL_ISLAMIC_CIVIL ? ISLAMIC_CIVIL
            : state.calendar_kind == CAL_HEBREW ? HEBREW : state.calendar_kind == CAL_DANGI ? DANGI : CHINESE;
        temporal::CalendarDate c = temporal::calendar_date(cal, temporal::cal_floor_div(out.epoch_sec + out.offset, 86400));
        out.year = c.year;
        out.day = c.day;
        // Hebrew month names depend on the year being leap; Chinese ones on the leap month.
        if (cal == HEBREW) {
            out.month = (long)c.month - 1;
            out.leap = c.in_leap_year;
        } else if (cal == ISLAMIC_CIVIL) {
            out.month = (long)c.month - 1;
        } else {
            out.month = (long)c.month_code.number - 1;
            out.leap = c.month_code.leap;
        }
    }
    out.hour = dt.h; out.minute = dt.mi; out.second = dt.s;
    out.ms = date_floor_mod_field(time, 1, 1000);
    return true;
}

fn char[] intl_date_data_string(ushort offset) {
    usz end = offset;
    while (intl_date_strings[end] != 0) end++;
    return intl_date_strings[offset:end - offset];
}

// The tzdb zone `zone` links to in CLDR, or -1.
fn int intl_zone_alias(String zone) {
    int index = temporal::tzdb_zone_index(zone);
    if (index < 0) return -1;
    usz low = 0;
    usz high = INTL_ZONE_ALIASES.len / 2;
    while (low < high) {
        usz mid = low + (high - low) / 2;
        if (INTL_ZONE_ALIASES[2 * mid] < (ushort)index) { low = mid + 1; } else { high = mid; }
    }
    if (low < INTL_ZONE_ALIASES.len / 2 && INTL_ZONE_ALIASES[2 * low] == (ushort)index) return INTL_ZONE_ALIASES[2 * low + 1];
    return -1;
}

// The six display-name offsets (generic, standard, daylight, then the short
// forms) for `zone` at `epoch_sec`, read from the zone's period records in
// INTL_ZONE_PERIODS. Each record is a little-endian ushort holding a name
// tuple index, with bit 15 set when a 32-bit end of the period follows; the
// last record has no end.
fn bool intl_zone_names(char[] zone, long epoch_sec, ushort[6]* names) {
    int index = temporal::tzdb_zone_index((String)zone);
    if (index < 0) return false;
    usz pos = INTL_ZONE_AT[index];
    usz end = INTL_ZONE_AT[index + 1];
    while (pos < end) {
        uint head = INTL_ZONE_PERIODS[pos] | (uint)INTL_ZONE_PERIODS[pos + 1] << 8;
        pos += 2;
        long until = 0x7FFFFFFFFFFFFFFF;
        if (head & 0x8000) {
            until = (long)(INTL_ZONE_PERIODS[pos] | (uint)INTL_ZONE_PERIODS[pos + 1] << 8 | (uint)INTL_ZONE_PERIODS[pos + 2] << 16 | (uint)INTL_ZONE_PERIODS[pos + 3] << 24);
            pos += 4;
        }
        if (epoch_sec >= until) continue;
        for (usz i = 0; i < 6; i++) (*names)[i] = INTL_ZONE_META[(usz)(head & 0x7FFF) * 6 + i];
        return true;
    }
    return false;
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
        ushort[6] names;
        if (intl_zone_names(zone, dt.epoch_sec, &names)) {
            ushort offset = generic ? (long_name ? names[0] : names[3]) : daylight ? (long_name ? names[2] : names[5]) : (long_name ? names[1] : names[4]);
            char[] text = intl_date_data_string(offset);
            if (text.len > 0) { date_buf_append(buf, pos, text); return; }
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
        if (c == 'y' && (state.calendar_kind == CAL_CHINESE || state.calendar_kind == CAL_DANGI)) {
            if (!intl_lunar_year_parts(ctx, state, dt, parts, text, count, source)) return;
            i = j;
            continue;
        }
        char[128] buf;
        usz len = 0;
        bool numeric = false;
        switch (intl_date_field(c)) {
            case 'y': {
                long shown = dt.year > 0 ? dt.year : 1 - dt.year;
                date_buf_append_num(buf[..], &len, width == 2 ? shown % 100 : shown, width == 2 ? 2 : 1);
                numeric = true;
            }
            case 'M': {
                if (state.calendar_kind != 0) { intl_lunar_month_text(state, dt, width, buf[..], &len); }
                else if (width < 3) { date_buf_append_num(buf[..], &len, dt.month + 1, width); numeric = true; }
                else { date_buf_append(buf[..], &len, intl_date_month_name(state, dt.month, width)); }
            }
            case 'd': { date_buf_append_num(buf[..], &len, dt.day, width); numeric = true; }
            case 'E': date_buf_append(buf[..], &len, intl_date_weekday_name(state, dt.weekday, width));
            case 'G': date_buf_append(buf[..], &len, intl_date_era_name(state, dt.year, width));
            case 'h': {
                long hour = dt.hour;
                if (c == 'h' || c == 'K') { hour %= 12; if (c == 'h' && hour == 0) hour = 12; }
                if (c == 'k' && hour == 0) hour = 24;
                date_buf_append_num(buf[..], &len, hour, width);
                numeric = true;
            }
            case 'm': { date_buf_append_num(buf[..], &len, dt.minute, width); numeric = true; }
            case 's': { date_buf_append_num(buf[..], &len, dt.second, width); numeric = true; }
            case 'S': { long ms = dt.ms; for (int k = width; k < 3; k++) ms /= 10; date_buf_append_num(buf[..], &len, ms, width); numeric = true; }
            case 'a': {
                if (c != 'B' || state.row > 0) { date_buf_append(buf[..], &len, intl_date_day_period_name(state, dt.hour, width)); }
                else {
                    bool noon = dt.hour == 12 && dt.minute == 0 && dt.second == 0 && dt.ms == 0;
                    date_buf_append(buf[..], &len, noon ? (width == 5 ? "n" : "noon") : dt.hour >= 6 && dt.hour < 12 ? "in the morning" : dt.hour >= 12 && dt.hour < 18 ? "in the afternoon" : dt.hour >= 18 && dt.hour < 21 ? "in the evening" : "at night");
                }
            }
            case 'z': intl_date_zone_text(state, dt, buf[..], &len, width >= 4, c == 'v', c == 'O');
            default: for (int k = 0; k < width; k++) date_buf_push(buf[..], &len, c);
        }
        usz system = intl_numbering_index(state.numbering);
        if (numeric && system != INTL_DIGIT_LATN) {
            char[128] mapped;
            usz n = intl_map_digits(system, buf[:len], mapped[..]);
            if (!intl_date_part(ctx, parts, text, intl_date_type(c), mapped[:n], count, source)) return;
        } else if (!intl_date_part(ctx, parts, text, intl_date_type(c), buf[:len], count, source)) {
            return;
        }
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
            foreach (entry : INTL_DATE_INTERVALS) if (mem_eq_bytes(intl_date_data_string(entry.skeleton), state.skeleton[:state.skeleton_len]) && entry.field == field) { interval = intl_date_data_string(entry.pattern); break; }
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
    if (!register_string_proto_method(ctor, hp, "supportedLocalesOf", Builtin.INTL_SUPPORTED_LOCALES_ROWS.ordinal)) return false;
    if (!register_string_proto_method(proto, hp, "resolvedOptions", Builtin.INTL_DATE_RESOLVED.ordinal)) return false;
    if (!register_proto_getter_accessor(proto, hp, "format", Builtin.INTL_DATE_FORMAT_GET.ordinal)) return false;
    TVal? accessor = proto.get_prop(builtin_intern_string(hp, "format"), hp);
    if (try value = accessor) set_func_ctor_name((HObject*)hobject::hobject_access_getter(value).get_heapptr(), hp, "get format");
    if (!register_string_proto_method(proto, hp, "formatToParts", Builtin.INTL_DATE_PARTS.ordinal)) return false;
    if (!register_string_proto_method(proto, hp, "formatRange", Builtin.INTL_DATE_RANGE.ordinal)) return false;
    if (!register_string_proto_method(proto, hp, "formatRangeToParts", Builtin.INTL_DATE_RANGE_PARTS.ordinal)) return false;
    return true;
}
