// PrepareCalendarFields: reading a property bag into a Calendar Fields Record, and the
// conversions of its fields. lib/temporal's calendar_fields.c3 resolves the record.
module boomkat::builtins @feat(!NO_TEMPORAL);

import boomkat::types;
import boomkat::heap;
import boomkat::hobject;
import boomkat::hstring;
import boomkat::vm;
import boomkat::lib::temporal;
import std::math;

// The property keys of temporal::TemporalField, in its order.
const String[*] TEMPORAL_FIELD_KEYS = {
    "day", "era", "eraYear", "hour", "microsecond", "millisecond", "minute", "month", "monthCode",
    "nanosecond", "offset", "second", "timeZone", "year",
};

const FieldSet DATE_FIELD_NAMES = (FieldSet)(1 << TemporalField.DAY.ordinal | 1 << TemporalField.MONTH.ordinal
    | 1 << TemporalField.MONTH_CODE.ordinal | 1 << TemporalField.YEAR.ordinal);
const FieldSet YEAR_MONTH_FIELD_NAMES = (FieldSet)(1 << TemporalField.MONTH.ordinal | 1 << TemporalField.MONTH_CODE.ordinal
    | 1 << TemporalField.YEAR.ordinal);
const FieldSet TIME_FIELD_NAMES = (FieldSet)(1 << TemporalField.HOUR.ordinal | 1 << TemporalField.MINUTE.ordinal
    | 1 << TemporalField.SECOND.ordinal | 1 << TemporalField.MILLISECOND.ordinal
    | 1 << TemporalField.MICROSECOND.ordinal | 1 << TemporalField.NANOSECOND.ordinal);

// PrepareCalendarFields. `partial` is the spec's requiredFieldNames of partial; otherwise a
// field in `required` must be present. A time zone field lands in `time_zone`.
fn bool prepare_calendar_fields(BuiltinContext* ctx, CalendarId cal, HObject* bag, FieldSet names, FieldSet required,
                                bool partial, CalendarFields* out, HObject** time_zone = null) {
    *out = {};
    if ((names & (1 << TemporalField.YEAR.ordinal)) != 0 && temporal::calendar_supports_era(cal)) {
        names |= temporal::field_set(ERA, ERA_YEAR);
    }
    foreach (field : TemporalField::values) {
        FieldSet bit = (FieldSet)1 << field.ordinal;
        if ((names & bit) == 0) continue;
        TVal value = prop_or_undefined_pa(ctx, bag, TEMPORAL_FIELD_KEYS[field.ordinal]);
        if (ctx.should_throw) return false;
        if (value.is_undefined()) {
            if (!partial && (required & bit) != 0) {
                builtin_throw(ctx, ctx.heap.type_err_proto, "a required property is missing");
                return false;
            }
            continue;
        }
        if (!prepare_field(ctx, cal, field, &value, out, time_zone)) return false;
    }
    if (partial && out.set == 0) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "the object has no recognized properties");
        return false;
    }
    return true;
}

fn bool prepare_field(BuiltinContext* ctx, CalendarId cal, TemporalField field, TVal* value,
                      CalendarFields* out, HObject** time_zone) @local {
    switch (field) {
        case ERA:
            HString* name = builtin_to_string_vm(ctx, value);
            if (ctx.should_throw) return false;
            out.put(ERA, temporal::calendar_era_index(cal, name.get_cstr()[:name.blen]));
        case MONTH_CODE:
            temporal::MonthCode code;
            if (!to_month_code(ctx, value, &code)) return false;
            out.put(MONTH_CODE, code.encode());
        case OFFSET:
            long seconds;
            if (!to_offset_seconds(ctx, value, &seconds)) return false;
            out.put(OFFSET, seconds);
        case TIME_ZONE:
            HObject*? tz = to_temporal_tz(ctx, value);
            if (catch tz) return false;
            if (ctx.should_throw || tz == null) return false;
            if (time_zone != null) *time_zone = tz;
            out.put(TIME_ZONE, 0);
        default:
            long n;
            if (!to_integer_field(ctx, value, &n)) return false;
            if ((field == DAY || field == MONTH) && n < 1) {
                builtin_throw(ctx, ctx.heap.range_err_proto, "day and month must be positive");
                return false;
            }
            out.put(field, n);
    }
    return true;
}

// ToIntegerWithTruncation, saturated where no field value is valid so the long cannot overflow.
fn bool to_integer_field(BuiltinContext* ctx, TVal* value, long* out) {
    double d = builtin_to_number_vm(ctx, value);
    if (ctx.should_throw) return false;
    if (math::is_nan(d) || math::is_inf(d)) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "the value is not a finite number");
        return false;
    }
    d = math::trunc(d);
    *out = d > 1e15 ? 1_000_000_000_000_000 : d < -1e15 ? -1_000_000_000_000_000 : (long)d;
    return true;
}

// ParseMonthCode: "M01" to "M99" with an optional "L", or "M00L".
fn bool to_month_code(BuiltinContext* ctx, TVal* value, temporal::MonthCode* out) {
    HString* s = to_primitive_string(ctx, value, "monthCode must be a string");
    if (s == null) return false;
    char[] text = s.get_cstr()[:s.blen];
    bool leap = text.len == 4 && text[3] == 'L';
    if ((text.len != 3 && !leap) || text[0] != 'M' || !text[1].is_digit() || !text[2].is_digit()
        || (text[1] == '0' && text[2] == '0' && !leap)) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "invalid monthCode");
        return false;
    }
    *out = { (text[1] - '0') * 10 + text[2] - '0', leap };
    return true;
}

// ToOffsetString, as whole seconds.
fn bool to_offset_seconds(BuiltinContext* ctx, TVal* value, long* out) {
    HString* s = to_primitive_string(ctx, value, "offset must be a string");
    if (s == null) return false;
    char[] text = s.get_cstr()[:s.blen];
    usz pos = 0;
    if (!temporal::parse_offset_only(text, &pos, out) || pos != text.len) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "invalid offset string");
        return false;
    }
    return true;
}

// ToPrimitive(value, string), which must give a String; null after throwing.
fn HString* to_primitive_string(BuiltinContext* ctx, TVal* value, String message) @local {
    TVal prim = *value;
    if (value.is_object()) {
        Vm* v = (Vm*)ctx.vm;
        prim = vm::to_primitive_value(v, value, 1);
        if (v.throw_pending) {
            ctx.should_throw = true;
            ctx.throw_value = v.throw_value;
            v.throw_pending = false;
            return null;
        }
    }
    if (!prim.is_string() || ((HString*)prim.get_heapptr()).is_symbol()) {
        builtin_throw(ctx, ctx.heap.type_err_proto, message);
        return null;
    }
    return (HString*)prim.get_heapptr();
}

// GetTemporalCalendarIdentifierWithISODefault for a bag that is not a Temporal object.
fn bool bag_calendar(BuiltinContext* ctx, HObject* bag, CalendarId* out) {
    TVal value = prop_or_undefined_pa(ctx, bag, "calendar");
    if (ctx.should_throw) return false;
    *out = ISO8601;
    return value.is_undefined() || calendar_from_arg(ctx, &value, out);
}

// IsPartialTemporalObject, throwing the TypeError for false: the bag of a with() call.
fn HObject* partial_temporal_object(BuiltinContext* ctx, TVal* value) {
    if (!value.is_object() || temporal_has_calendar((HObject*)value.get_heapptr())
        || ((HObject*)value.get_heapptr()).get_class() == hobject::ObjClass.TEMPORAL_PLAIN_TIME) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "with() needs a plain object of fields");
        return null;
    }
    HObject* bag = (HObject*)value.get_heapptr();
    foreach (key : (String[]){ "calendar", "timeZone" }) {
        TVal probe = prop_or_undefined_pa(ctx, bag, key);
        if (ctx.should_throw) return null;
        if (!probe.is_undefined()) {
            builtin_throw(ctx, ctx.heap.type_err_proto, "with() does not accept a calendar or timeZone property");
            return null;
        }
    }
    return bag;
}

// Throws the error of a field operation's fault.
fn void throw_field_fault(BuiltinContext* ctx, fault f) {
    if (f == temporal::FIELD_MISSING) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "the fields do not identify a date");
    } else {
        builtin_throw(ctx, ctx.heap.range_err_proto, "the fields do not form a valid date");
    }
}

// The ISO date a field operation returns, or false after throwing its fault.
macro bool @iso_date(BuiltinContext* ctx, #operation, temporal::CivilDate* out) {
    temporal::CivilDate? date = #operation;
    if (catch f = date) {
        throw_field_fault(ctx, f);
        return false;
    }
    *out = date;
    return true;
}
