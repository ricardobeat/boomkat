// Temporal.PlainYearMonth, and the operations PlainMonthDay shares with it: both store an ISO date
// whose day (year-month) or year (month-day) is the reference the calendar needs to tell apart
// what the other fields leave open.
module boomkat::builtins @feat(TEMPORAL);

import boomkat::types;
import boomkat::heap;
import boomkat::hobject;
import boomkat::hstring;
import boomkat::lib::temporal;

// ============================================================================
// Operations shared by PlainYearMonth and PlainMonthDay (`type` is YEAR_MONTH or MONTH_DAY)
// ============================================================================

// The receiver of a method of `type`, or null after throwing.
fn HObject* this_partial_date(BuiltinContext* ctx, temporal::FieldsType type) {
    String why = type == YEAR_MONTH ? "this is not a Temporal.PlainYearMonth" : "this is not a Temporal.PlainMonthDay";
    return brand_check(ctx, &ctx.this_val, fields_type_class(type), why) ? (HObject*)ctx.this_val.get_heapptr() : null;
}

// The constructors' tail: IsValidISODate over the arguments, then CreateTemporalYearMonth or
// CreateTemporalMonthDay.
fn void construct_partial_date(BuiltinContext* ctx, temporal::FieldsType type, temporal::CivilDate iso, temporal::CalendarId cal) {
    bool valid = iso.m >= 1 && iso.m <= 12 && iso.d >= 1 && iso.d <= temporal::days_in_month(iso.y, (int)iso.m)
        && (type == YEAR_MONTH ? temporal::is_valid_iso_yearmonth(iso.y, (int)iso.m)
                               : temporal::is_valid_iso_date(iso.y, (int)iso.m, (int)iso.d));
    if (!valid) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "the ISO date is invalid or out of range");
        return;
    }
    HObject*? obj = alloc_plain_date(ctx.heap, iso, cal, fields_type_class(type));
    if (catch obj) {
        builtin_throw(ctx, ctx.heap.err_proto, "alloc failed");
        return;
    }
    ctx.heap.set_prototype(obj, builtin_proto_from_new_target(ctx, fields_type_proto(ctx.heap, type)));
    ctx.result_object(obj);
}

// ToTemporalYearMonth and ToTemporalMonthDay: the ISO date and calendar of `item`, reading the
// overflow of `options`.
fn bool to_temporal_partial_date(BuiltinContext* ctx, temporal::FieldsType type, TVal* item, temporal::CivilDate* iso,
                                 temporal::CalendarId* cal, TVal* options = null) {
    temporal::OverflowKind overflow;
    if (item.is_object()) {
        HObject* o = (HObject*)item.get_heapptr();
        if (o.get_class() == fields_type_class(type)) {
            *iso = temporal_object_date(o);
            *cal = o.extra.temporal.calendar;
            return read_overflow(ctx, options, &overflow);
        }
        temporal::CalendarFields fields;
        return bag_calendar(ctx, o, cal)
            && prepare_calendar_fields(ctx, *cal, o, type == YEAR_MONTH ? YEAR_MONTH_FIELD_NAMES : DATE_FIELD_NAMES, 0, false, &fields)
            && read_overflow(ctx, options, &overflow)
            && @iso_date(ctx, temporal::calendar_from_fields(*cal, &fields, type, overflow), iso);
    }
    HString* s = item.is_string() ? (HString*)item.get_heapptr() : null;
    if (s == null || s.is_symbol()) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "a PlainYearMonth or PlainMonthDay needs a string or an object");
        return false;
    }
    char[] text = s.get_cstr()[:s.blen];
    temporal::ParsedIsoDateTime p;
    bool parsed = type == YEAR_MONTH ? temporal::parse_iso_yearmonth_string(text, &p)
        : temporal::parse_iso_monthday_string(text, &p) || temporal::parse_iso_date_string(text, &p);
    if (!parsed || p.offset_kind == temporal::OffsetKind.Z) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "invalid ISO year-month or month-day string");
        return false;
    }
    *cal = p.calendar;
    *iso = { p.year, p.month, p.day };
    if (!read_overflow(ctx, options, &overflow)) return false;
    if (type == MONTH_DAY && *cal == ISO8601) {
        iso.y = 1972;
        return true;
    }
    if (!(type == YEAR_MONTH ? temporal::is_valid_iso_yearmonth(iso.y, (int)iso.m) : temporal::is_valid_iso_date(iso.y, (int)iso.m, (int)iso.d))) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "the date is out of range");
        return false;
    }
    // Constraining stores the calendar's canonical reference day or year.
    temporal::CalendarFields fields = temporal::iso_date_to_fields(*cal, *iso, type);
    return @iso_date(ctx, temporal::calendar_from_fields(*cal, &fields, type, CONSTRAIN), iso);
}

fn void partial_date_from(BuiltinContext* ctx, temporal::FieldsType type) {
    temporal::CivilDate iso;
    temporal::CalendarId cal;
    if (to_temporal_partial_date(ctx, type, arg_at(ctx, 0), &iso, &cal, arg_at(ctx, 1))) partial_date_result(ctx, type, iso, cal);
}

fn void partial_date_value_of(BuiltinContext* ctx, temporal::FieldsType type) {
    if (this_partial_date(ctx, type) == null) return;
    builtin_throw(ctx, ctx.heap.type_err_proto, "a PlainYearMonth or PlainMonthDay cannot be converted to a primitive");
}

// TemporalYearMonthToString and TemporalMonthDayToString.
fn void partial_date_to_string(BuiltinContext* ctx, temporal::FieldsType type) {
    HObject* obj = this_partial_date(ctx, type);
    ShowCalendar show;
    if (obj == null || !read_show_calendar_option(ctx, arg_at(ctx, 0), &show)) return;
    temporal::CalendarId cal = obj.extra.temporal.calendar;
    char[64] buf;
    usz len = temporal::format_civil_date(temporal_object_date(obj), &buf, 64);
    // The reference day or year is printed when the calendar needs it to read the date back.
    usz start = 0;
    if (cal == ISO8601 && show != ALWAYS && show != CRITICAL) {
        if (type == YEAR_MONTH) {
            len -= 3;
        } else {
            start = len - 5;
        }
    }
    append_calendar_annotation(&buf, &len, cal, show);
    ctx.result_string(builtin_intern_string(ctx.heap, buf[start..len - 1]));
}

// toJSON and toLocaleString format with the default options.
fn void partial_date_to_string_default(BuiltinContext* ctx, temporal::FieldsType type, bool locale) {
    if (locale) {
        if (this_partial_date(ctx, type) == null || temporal_locale_string(ctx, DTF_REQ_DATE)) return;
    }
    ctx.argc = 0;
    partial_date_to_string(ctx, type);
}

fn void partial_date_equals(BuiltinContext* ctx, temporal::FieldsType type) {
    HObject* obj = this_partial_date(ctx, type);
    temporal::CivilDate other;
    temporal::CalendarId cal;
    if (obj == null || !to_temporal_partial_date(ctx, type, arg_at(ctx, 0), &other, &cal)) return;
    ctx.result_boolean(cal == obj.extra.temporal.calendar && temporal::date_equals(temporal_object_date(obj), other));
}

fn void partial_date_with(BuiltinContext* ctx, temporal::FieldsType type) {
    HObject* obj = this_partial_date(ctx, type);
    if (obj == null) return;
    HObject* bag = partial_temporal_object(ctx, arg_at(ctx, 0));
    if (bag == null) return;
    temporal::CalendarId cal = obj.extra.temporal.calendar;
    temporal::CalendarFields partial;
    temporal::OverflowKind overflow;
    if (!prepare_calendar_fields(ctx, cal, bag, type == YEAR_MONTH ? YEAR_MONTH_FIELD_NAMES : DATE_FIELD_NAMES, 0, true, &partial)
        || !read_overflow(ctx, arg_at(ctx, 1), &overflow)) return;
    temporal::CalendarFields fields = temporal::calendar_merge_fields(cal, temporal::iso_date_to_fields(cal, temporal_object_date(obj), type), partial);
    temporal::CivilDate iso;
    if (@iso_date(ctx, temporal::calendar_from_fields(cal, &fields, type, overflow), &iso)) partial_date_result(ctx, type, iso, cal);
}

// toPlainDate(item): the day (of a year-month) or year (of a month-day) comes from `item`.
fn void partial_date_to_plain_date(BuiltinContext* ctx, temporal::FieldsType type) {
    HObject* obj = this_partial_date(ctx, type);
    if (obj == null) return;
    TVal* item = arg_at(ctx, 0);
    if (!item.is_object()) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "toPlainDate needs an object");
        return;
    }
    temporal::CalendarId cal = obj.extra.temporal.calendar;
    temporal::CalendarFields input;
    if (!prepare_calendar_fields(ctx, cal, (HObject*)item.get_heapptr(), temporal::field_set(type == YEAR_MONTH ? DAY : YEAR), 0, false, &input)) return;
    temporal::CalendarFields fields = temporal::calendar_merge_fields(cal, temporal::iso_date_to_fields(cal, temporal_object_date(obj), type), input);
    temporal::CivilDate iso;
    if (@iso_date(ctx, temporal::calendar_date_from_fields(cal, &fields, CONSTRAIN), &iso)) plain_date_result(ctx, iso, cal);
}

// ============================================================================
// Temporal.PlainYearMonth
// ============================================================================

fn void builtin_temporal_plain_yearmonth_ctor(BuiltinContext* ctx) {
    if (!ctx.is_constructor) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "Temporal.PlainYearMonth requires new");
        return;
    }
    temporal::CivilDate iso = { .d = 1 };
    temporal::CalendarId cal;
    if (!to_integer_field(ctx, arg_at(ctx, 0), &iso.y) || !to_integer_field(ctx, arg_at(ctx, 1), &iso.m)
        || !calendar_ctor_arg(ctx, arg_at(ctx, 2), &cal)
        || (!arg_at(ctx, 3).is_undefined() && !to_integer_field(ctx, arg_at(ctx, 3), &iso.d))) return;
    construct_partial_date(ctx, YEAR_MONTH, iso, cal);
}

fn void builtin_temporal_plain_yearmonth_from(BuiltinContext* ctx) => partial_date_from(ctx, YEAR_MONTH);

fn void builtin_temporal_plain_yearmonth_compare(BuiltinContext* ctx) {
    temporal::CivilDate one, two;
    temporal::CalendarId cal;
    if (!to_temporal_partial_date(ctx, YEAR_MONTH, arg_at(ctx, 0), &one, &cal) || !to_temporal_partial_date(ctx, YEAR_MONTH, arg_at(ctx, 1), &two, &cal)) return;
    ctx.result_fastint(temporal::date_compare(one, two));
}

fn void builtin_temporal_plain_yearmonth_proto_valueOf(BuiltinContext* ctx) => partial_date_value_of(ctx, YEAR_MONTH);
fn void builtin_temporal_plain_yearmonth_proto_toString(BuiltinContext* ctx) => partial_date_to_string(ctx, YEAR_MONTH);
fn void builtin_temporal_plain_yearmonth_proto_toJSON(BuiltinContext* ctx) => partial_date_to_string_default(ctx, YEAR_MONTH, false);
fn void builtin_temporal_plain_yearmonth_proto_toLocaleString(BuiltinContext* ctx) => partial_date_to_string_default(ctx, YEAR_MONTH, true);
fn void builtin_temporal_plain_yearmonth_proto_equals(BuiltinContext* ctx) => partial_date_equals(ctx, YEAR_MONTH);
fn void builtin_temporal_plain_yearmonth_proto_with(BuiltinContext* ctx) => partial_date_with(ctx, YEAR_MONTH);
fn void builtin_temporal_plain_yearmonth_proto_toPlainDate(BuiltinContext* ctx) => partial_date_to_plain_date(ctx, YEAR_MONTH);

// The first day of the month of a PlainYearMonth's ISO date, in its calendar.
fn bool year_month_first_day(BuiltinContext* ctx, temporal::CalendarId cal, temporal::CivilDate iso, temporal::CivilDate* out) {
    temporal::CalendarFields fields = temporal::iso_date_to_fields(cal, iso, YEAR_MONTH);
    fields.put(DAY, 1);
    return @iso_date(ctx, temporal::calendar_date_from_fields(cal, &fields, CONSTRAIN), out);
}

fn void builtin_temporal_plain_yearmonth_proto_add(BuiltinContext* ctx) => plain_yearmonth_add(ctx, 1);
fn void builtin_temporal_plain_yearmonth_proto_subtract(BuiltinContext* ctx) => plain_yearmonth_add(ctx, -1);

// AddDurationToYearMonth.
fn void plain_yearmonth_add(BuiltinContext* ctx, long sign) {
    HObject* obj = this_partial_date(ctx, YEAR_MONTH);
    if (obj == null) return;
    temporal::DurationParts dur;
    temporal::OverflowKind overflow;
    if (!duration_record_from_arg(ctx, arg_at(ctx, 0), &dur) || !read_overflow(ctx, arg_at(ctx, 1), &overflow)) return;
    if (dur.weeks != 0 || dur.days != 0 || temporal::duration_time_part_ns(dur) != 0) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "a PlainYearMonth can only add years and months");
        return;
    }
    temporal::CalendarId cal = obj.extra.temporal.calendar;
    temporal::CivilDate date;
    if (!year_month_first_day(ctx, cal, temporal_object_date(obj), &date)
        || !@iso_date(ctx, temporal::calendar_add(cal, date, sign * dur.years, sign * dur.months, 0, 0, overflow), &date)) return;
    temporal::CalendarFields fields = temporal::iso_date_to_fields(cal, date, YEAR_MONTH);
    if (@iso_date(ctx, temporal::calendar_year_month_from_fields(cal, &fields, overflow), &date)) partial_date_result(ctx, YEAR_MONTH, date, cal);
}

fn void builtin_temporal_plain_yearmonth_proto_until(BuiltinContext* ctx) => plain_yearmonth_until_since(ctx, false);
fn void builtin_temporal_plain_yearmonth_proto_since(BuiltinContext* ctx) => plain_yearmonth_until_since(ctx, true);

// DifferenceTemporalPlainYearMonth; `flipped` is since, which negates the rounding mode and the result.
fn void plain_yearmonth_until_since(BuiltinContext* ctx, bool flipped) {
    HObject* obj = this_partial_date(ctx, YEAR_MONTH);
    if (obj == null) return;
    temporal::CivilDate other;
    DiffSettings ds;
    if (!to_temporal_partial_date(ctx, YEAR_MONTH, arg_at(ctx, 0), &other, &ds.calendar)) return;
    if (ds.calendar != obj.extra.temporal.calendar) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "calendars do not match");
        return;
    }
    if (!read_diff_settings(ctx, 1, temporal::TemporalUnit.YEAR, temporal::TemporalUnit.MONTH,
                            temporal::TemporalUnit.YEAR, temporal::TemporalUnit.MONTH, flipped, &ds)) return;
    temporal::DurationParts dur;
    temporal::CivilDate this_date = temporal_object_date(obj);
    if (!temporal::date_equals(this_date, other)) {
        temporal::CivilDate start, end;
        if (!year_month_first_day(ctx, ds.calendar, this_date, &start) || !year_month_first_day(ctx, ds.calendar, other, &end)
            || !datetime_difference(ctx, { .date = start }, { .date = end }, ds, &dur)) return;
    }
    if (flipped) dur = dur.negate();
    @temporal_result(ctx, alloc_duration(ctx.heap, dur), ctx.heap.temporal_duration_proto);
}
