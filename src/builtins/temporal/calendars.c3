// The calendars of PlainDate, PlainDateTime, PlainYearMonth, PlainMonthDay and ZonedDateTime.
// Each object stores its ISO date and a CalendarId; the calendar only changes what the getters
// report and how fields and arithmetic resolve, through lib/temporal's calendar engine.
module boomkat::builtins @feat(TEMPORAL);

import boomkat::types;
import boomkat::heap;
import boomkat::hobject;
import boomkat::hstring;
import boomkat::lib::temporal;

fn bool temporal_has_calendar(HObject* o) {
    switch (o.get_class()) {
        case TEMPORAL_PLAIN_DATE:
        case TEMPORAL_PLAIN_DATETIME:
        case TEMPORAL_PLAIN_YEARMONTH:
        case TEMPORAL_PLAIN_MONTHDAY:
        case TEMPORAL_ZONEDDATETIME:
            return true;
        default:
            return false;
    }
}

fn HString* calendar_string_arg(BuiltinContext* ctx, TVal* tv) {
    if (tv.is_string()) {
        HString* s = (HString*)tv.get_heapptr();
        if (s != null && !s.is_symbol()) return s;
    }
    builtin_throw(ctx, ctx.heap.type_err_proto, "calendar must be a string");
    return null;
}

// CanonicalizeCalendar.
fn bool calendar_canonicalize(BuiltinContext* ctx, char[] text, temporal::CalendarId* out) {
    if (temporal::calendar_from_name(text, out)) return true;
    builtin_throw(ctx, ctx.heap.range_err_proto, "unknown calendar identifier");
    return false;
}

// The calendar argument of a constructor: ISO 8601 when undefined, else a calendar type.
fn bool calendar_ctor_arg(BuiltinContext* ctx, TVal* tv, temporal::CalendarId* out) {
    *out = ISO8601;
    if (tv.is_undefined()) return true;
    HString* s = calendar_string_arg(ctx, tv);
    return s != null && calendar_canonicalize(ctx, s.token_text(), out);
}

// ToTemporalCalendarIdentifier: a Temporal object's calendar, the calendar an ISO 8601 string
// names (ParseTemporalCalendarString), or a calendar type.
fn bool calendar_from_arg(BuiltinContext* ctx, TVal* tv, temporal::CalendarId* out) {
    if (tv.is_object() && tv.get_heapptr() != null && temporal_has_calendar((HObject*)tv.get_heapptr())) {
        *out = ((HObject*)tv.get_heapptr()).extra.temporal.calendar;
        return true;
    }
    HString* s = calendar_string_arg(ctx, tv);
    if (s == null) return false;
    char[] text = s.token_text();
    temporal::ParsedIsoDateTime p;
    if (temporal::parse_iso_date_string(text, &p) || temporal::parse_iso_yearmonth_string(text, &p)
        || temporal::parse_iso_monthday_string(text, &p) || temporal::parse_iso_time_string(text, &p)) {
        *out = p.calendar;
        return true;
    }
    return calendar_canonicalize(ctx, text, out);
}

// ============================================================================
// Getters
// ============================================================================

// The calendar getters the types with a calendar share. Each type declares its TemporalBuiltin
// getter entries in this order from its CALENDARID entry: PlainMonthDay has the first three,
// PlainYearMonth the first eleven (it registers no `day`), the others all of them.
enum CalendarField : char {
    CALENDAR_ID,
    MONTH_CODE,
    DAY,
    ERA,
    ERA_YEAR,
    YEAR,
    MONTH,
    DAYS_IN_YEAR,
    DAYS_IN_MONTH,
    MONTHS_IN_YEAR,
    IN_LEAP_YEAR,
    DAY_OF_WEEK,
    DAY_OF_YEAR,
    WEEK_OF_YEAR,
    YEAR_OF_WEEK,
    DAYS_IN_WEEK,
}

fn HString* month_code_string(Heap* hp, temporal::MonthCode code) {
    char[4] buf = { 'M', (char)('0' + code.number / 10), (char)('0' + code.number % 10), 'L' };
    return builtin_intern_string(hp, buf[:code.leap ? 4 : 3]);
}

fn void calendar_field_result(BuiltinContext* ctx, temporal::CalendarId cal, temporal::CivilDate iso, CalendarField field) {
    switch (field) {
        case CALENDAR_ID:
            ctx.result_string(builtin_intern_string(ctx.heap, temporal::calendar_name(cal)));
            return;
        case DAY_OF_WEEK:
            ctx.result_fastint(temporal::iso_day_of_week(temporal::epoch_days_from_civil(iso.y, (int)iso.m, (int)iso.d)));
            return;
        case DAYS_IN_WEEK:
            ctx.result_fastint(7);
            return;
        case WEEK_OF_YEAR:
        case YEAR_OF_WEEK:
            // Only ISO 8601 numbers its weeks.
            if (cal != ISO8601) {
                ctx.result_undefined();
                return;
            }
            long week_year;
            long week = temporal::iso_week_of_year(iso, &week_year);
            ctx.result_fastint(field == WEEK_OF_YEAR ? week : week_year);
            return;
        default:
            break;
    }
    temporal::CalendarDate c = temporal::calendar_iso_date(cal, iso);
    switch (field) {
        case MONTH_CODE: ctx.result_string(month_code_string(ctx.heap, c.month_code));
        case DAY: ctx.result_fastint(c.day);
        case ERA:
            if (c.era < 0) {
                ctx.result_undefined();
            } else {
                ctx.result_string(builtin_intern_string(ctx.heap, temporal::calendar_eras(cal)[c.era].name));
            }
        case ERA_YEAR:
            if (c.era < 0) {
                ctx.result_undefined();
            } else {
                ctx.result_fastint(c.era_year);
            }
        case YEAR: ctx.result_fastint(c.year);
        case MONTH: ctx.result_fastint(c.month);
        case DAYS_IN_YEAR: ctx.result_fastint(c.days_in_year);
        case DAYS_IN_MONTH: ctx.result_fastint(c.days_in_month);
        case MONTHS_IN_YEAR: ctx.result_fastint(c.months_in_year);
        case IN_LEAP_YEAR: ctx.result_boolean(c.in_leap_year);
        case DAY_OF_YEAR: ctx.result_fastint(c.day_of_year);
        default: unreachable();
    }
}

macro bool @calendar_getter_block(TemporalBuiltin id, TemporalBuiltin $first, TemporalBuiltin $last, ObjClass $klass, ObjClass* klass, CalendarField* field) {
    if (id.ordinal < $first.ordinal || id.ordinal > $last.ordinal) return false;
    *klass = $klass;
    *field = (CalendarField)(id.ordinal - $first.ordinal);
    return true;
}

fn void builtin_temporal_calendar_getter(BuiltinContext* ctx) {
    TemporalBuiltin id = (TemporalBuiltin)((uint)(*(ctx.callee_obj.extra_ptr())).func.builtin_fn_index - TEMPORAL_BASE);
    $assert TemporalBuiltin.PLAIN_DATE_PROTO_DAYSINWEEK.ordinal - TemporalBuiltin.PLAIN_DATE_PROTO_CALENDARID.ordinal == CalendarField.DAYS_IN_WEEK.ordinal;
    $assert TemporalBuiltin.PLAIN_DATETIME_PROTO_DAYSINWEEK.ordinal - TemporalBuiltin.PLAIN_DATETIME_PROTO_CALENDARID.ordinal == CalendarField.DAYS_IN_WEEK.ordinal;
    $assert TemporalBuiltin.ZONEDDATETIME_PROTO_DAYSINWEEK.ordinal - TemporalBuiltin.ZONEDDATETIME_PROTO_CALENDARID.ordinal == CalendarField.DAYS_IN_WEEK.ordinal;
    $assert TemporalBuiltin.PLAIN_YEARMONTH_PROTO_INLEAPYEAR.ordinal - TemporalBuiltin.PLAIN_YEARMONTH_PROTO_CALENDARID.ordinal == CalendarField.IN_LEAP_YEAR.ordinal;
    $assert TemporalBuiltin.PLAIN_MONTHDAY_PROTO_DAY.ordinal - TemporalBuiltin.PLAIN_MONTHDAY_PROTO_CALENDARID.ordinal == CalendarField.DAY.ordinal;
    ObjClass klass;
    CalendarField field;
    if (!@calendar_getter_block(id, TemporalBuiltin.PLAIN_DATE_PROTO_CALENDARID, TemporalBuiltin.PLAIN_DATE_PROTO_DAYSINWEEK, TEMPORAL_PLAIN_DATE, &klass, &field)
        && !@calendar_getter_block(id, TemporalBuiltin.PLAIN_DATETIME_PROTO_CALENDARID, TemporalBuiltin.PLAIN_DATETIME_PROTO_DAYSINWEEK, TEMPORAL_PLAIN_DATETIME, &klass, &field)
        && !@calendar_getter_block(id, TemporalBuiltin.ZONEDDATETIME_PROTO_CALENDARID, TemporalBuiltin.ZONEDDATETIME_PROTO_DAYSINWEEK, TEMPORAL_ZONEDDATETIME, &klass, &field)
        && !@calendar_getter_block(id, TemporalBuiltin.PLAIN_YEARMONTH_PROTO_CALENDARID, TemporalBuiltin.PLAIN_YEARMONTH_PROTO_INLEAPYEAR, TEMPORAL_PLAIN_YEARMONTH, &klass, &field)) {
        @calendar_getter_block(id, TemporalBuiltin.PLAIN_MONTHDAY_PROTO_CALENDARID, TemporalBuiltin.PLAIN_MONTHDAY_PROTO_DAY, TEMPORAL_PLAIN_MONTHDAY, &klass, &field);
    }
    if (!brand_check(ctx, &ctx.this_val, klass, "invalid receiver for a Temporal calendar getter")) return;
    HObject* obj = (HObject*)ctx.this_val.get_heapptr();
    temporal::CivilDate iso = klass == TEMPORAL_ZONEDDATETIME ? zdt_wall_date(obj) : temporal_object_date(obj);
    calendar_field_result(ctx, obj.extra.temporal.calendar, iso, field);
}

// The ISO date a PlainDate, PlainDateTime, PlainYearMonth or PlainMonthDay stores.
fn temporal::CivilDate temporal_object_date(HObject* obj) @inline {
    return { obj.extra.temporal.long_a, obj.extra.temporal.long_b, obj.extra.temporal.long_c };
}

// ============================================================================
// toString
// ============================================================================

enum ShowCalendar : char {
    AUTO,
    ALWAYS,
    NEVER,
    CRITICAL,
}

// GetTemporalShowCalendarNameOption.
fn bool read_show_calendar(BuiltinContext* ctx, HObject* opts, ShowCalendar* out) {
    *out = AUTO;
    TVal v = prop_or_undefined_pa(ctx, opts, "calendarName");
    if (ctx.should_throw) return false;
    if (v.is_undefined()) return true;
    HString* s = builtin_to_string_vm(ctx, &v);
    if (ctx.should_throw) return false;
    switch (s.token_text()) {
        case "auto": return true;
        case "always": *out = ALWAYS;
        case "never": *out = NEVER;
        case "critical": *out = CRITICAL;
        default:
            builtin_throw(ctx, ctx.heap.range_err_proto, "invalid calendarName option");
            return false;
    }
    return true;
}

// The calendarName option of an options argument that may be undefined (GetOptionsObject).
fn bool read_show_calendar_option(BuiltinContext* ctx, TVal* options, ShowCalendar* out) {
    *out = AUTO;
    if (options.is_undefined()) return true;
    if (!options.is_object() || options.get_heapptr() == null) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "options must be an object");
        return false;
    }
    return read_show_calendar(ctx, (HObject*)options.get_heapptr(), out);
}

// FormatCalendarAnnotation, appended to `buf` at `*len`; it takes at most 26 bytes.
fn void append_calendar_annotation(char* buf, usz* len, temporal::CalendarId cal, ShowCalendar show) {
    if (show == NEVER || (show == AUTO && cal == ISO8601)) return;
    String text = show == CRITICAL ? "[!u-ca=" : "[u-ca=";
    String name = temporal::calendar_name(cal);
    buf[*len:text.len] = text[..];
    *len += text.len;
    buf[*len:name.len] = name[..];
    *len += name.len;
    buf[(*len)++] = ']';
}
