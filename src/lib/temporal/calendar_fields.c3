// Calendar Fields Records and the operations that turn them into ISO dates for every calendar,
// following the Temporal proposal's calendar field operations and the Intl era and monthCode
// proposal's NonISO operations.
module boomkat::lib::temporal;

// The fields of a Calendar Fields Record in the lexicographic order of their property keys,
// which is the order PrepareCalendarFields reads them in.
enum TemporalField : char {
    DAY,
    ERA,
    ERA_YEAR,
    HOUR,
    MICROSECOND,
    MILLISECOND,
    MINUTE,
    MONTH,
    MONTH_CODE,
    NANOSECOND,
    OFFSET,
    SECOND,
    TIME_ZONE,
    YEAR,
}

alias FieldSet = ushort;

fn FieldSet field_set(TemporalField... fields) @inline {
    FieldSet set;
    foreach (field : fields) set |= (FieldSet)1 << field.ordinal;
    return set;
}

// Faults of the field operations: FIELD_MISSING is a TypeError and FIELD_OUT_OF_RANGE a
// RangeError.
faultdef FIELD_MISSING, FIELD_OUT_OF_RANGE;

enum FieldsType : char {
    DATE,
    YEAR_MONTH,
    MONTH_DAY,
}

// A Calendar Fields Record: `set` names the fields that hold a value. A month code is stored as
// MonthCode.encode(), an era as its index in calendar_eras (-1 for a name the calendar lacks)
// and an offset in nanoseconds. The time zone is the caller's to keep.
struct CalendarFields {
    FieldSet set;
    long[TemporalField::values.len] value;
}

fn bool CalendarFields.has(&self, TemporalField field) @inline => (self.set & ((FieldSet)1 << field.ordinal)) != 0;
fn long CalendarFields.get(&self, TemporalField field) @inline => self.value[field.ordinal];

fn void CalendarFields.put(&self, TemporalField field, long value) @inline {
    self.value[field.ordinal] = value;
    self.set |= (FieldSet)1 << field.ordinal;
}

fn void CalendarFields.clear(&self, TemporalField field) @inline => self.set &= ~((FieldSet)1 << field.ordinal);

fn MonthCode CalendarFields.month_code(&self) => month_code_decode(self.get(MONTH_CODE));

fn long MonthCode.encode(self) => (long)self.number * 2 + (self.leap ? 1 : 0);
fn MonthCode month_code_decode(long value) => { (int)(value / 2), value % 2 == 1 };

// CalendarResolveFields: checks that `fields` identify a `type`, merges an era and era year
// into the year, and resolves a month code to the ordinal month when the year is known.
fn void? calendar_resolve_fields(CalendarId cal, CalendarFields* fields, FieldsType type) {
    bool needs_day = type != YEAR_MONTH;
    if (cal == ISO8601) {
        if (type != MONTH_DAY && !fields.has(YEAR)) return FIELD_MISSING~;
        if (needs_day && !fields.has(DAY)) return FIELD_MISSING~;
        if (!fields.has(MONTH) && !fields.has(MONTH_CODE)) return FIELD_MISSING~;
        if (!fields.has(MONTH_CODE)) return;
        MonthCode code = fields.month_code();
        if (code.leap || code.number > 12) return FIELD_OUT_OF_RANGE~;
        if (fields.has(MONTH) && fields.get(MONTH) != code.number) return FIELD_OUT_OF_RANGE~;
        fields.put(MONTH, code.number);
        return;
    }
    bool eras = calendar_supports_era(cal);
    bool needs_year = type != MONTH_DAY || !fields.has(MONTH_CODE) || fields.has(MONTH);
    if (needs_year && !fields.has(YEAR) && (!eras || !fields.has(ERA) || !fields.has(ERA_YEAR))) return FIELD_MISSING~;
    if (eras && fields.has(ERA) != fields.has(ERA_YEAR)) return FIELD_MISSING~;
    if (needs_day && !fields.has(DAY)) return FIELD_MISSING~;
    if (!fields.has(MONTH) && !fields.has(MONTH_CODE)) return FIELD_MISSING~;
    if (eras && fields.has(ERA_YEAR)) {
        int era = (int)fields.get(ERA);
        if (era < 0) return FIELD_OUT_OF_RANGE~;
        long year = calendar_era_arithmetic_year(cal, era, fields.get(ERA_YEAR));
        if (fields.has(YEAR) && fields.get(YEAR) != year) return FIELD_OUT_OF_RANGE~;
        fields.put(YEAR, year);
    }
    fields.clear(ERA);
    fields.clear(ERA_YEAR);
    if (!fields.has(MONTH_CODE)) return;
    MonthCode code = fields.month_code();
    if (!calendar_month_code_valid(cal, code)) return FIELD_OUT_OF_RANGE~;
    if (!fields.has(YEAR)) return;
    long year = fields.get(YEAR);
    if (!calendar_year_in_range(year)) return FIELD_OUT_OF_RANGE~;
    // The month code stays as given, so CalendarDateToISO can still reject one the year lacks.
    if (!calendar_year_has_month_code(cal, year, code)) code = calendar_constrain_month_code(cal, code);
    int month = calendar_month_code_to_ordinal(cal, year, code);
    if (fields.has(MONTH) && fields.get(MONTH) != month) return FIELD_OUT_OF_RANGE~;
    fields.put(MONTH, month);
}

// RegulateISODate and NonISOCalendarDateToISO over resolved fields, before the ISO limits check.
fn CivilDate? calendar_date_to_iso(CalendarId cal, CalendarFields* fields, OverflowKind overflow) {
    long year = fields.get(YEAR);
    if (!calendar_year_in_range(year)) return FIELD_OUT_OF_RANGE~;
    if (fields.has(MONTH_CODE) && overflow == REJECT && !calendar_year_has_month_code(cal, year, fields.month_code())) {
        return FIELD_OUT_OF_RANGE~;
    }
    int month = (int)regulate_field(fields.get(MONTH), calendar_months_in_year(cal, year), overflow)!;
    int day = (int)regulate_field(fields.get(DAY), calendar_days_in_month(cal, year, month), overflow)!;
    return civil_date_from_epoch_days(calendar_epoch_days(cal, year, month, day));
}

// A month or day above its largest value: clamped, or rejected.
fn long? regulate_field(long value, long max, OverflowKind overflow) @local {
    if (value <= max) return value;
    if (overflow == REJECT) return FIELD_OUT_OF_RANGE~;
    return max;
}

// CalendarMonthDayToISOReferenceDate over resolved fields.
fn CivilDate? calendar_month_day_to_iso(CalendarId cal, CalendarFields* fields, OverflowKind overflow) {
    long day = fields.get(DAY);
    if (cal == ISO8601) {
        long year = fields.has(YEAR) ? fields.get(YEAR) : 1972;
        int month = (int)regulate_field(fields.get(MONTH), 12, overflow)!;
        return { 1972, month, (int)regulate_field(day, days_in_month(year, month), overflow)! };
    }
    MonthCode code;
    int max_day;
    if (fields.has(YEAR)) {
        long year = fields.get(YEAR);
        if (!calendar_year_in_range(year)) return FIELD_OUT_OF_RANGE~;
        long last = calendar_year_start(cal, year + 1) - 1;
        if (!is_valid_iso_date_days(calendar_year_start(cal, year)) && !is_valid_iso_date_days(last)) return FIELD_OUT_OF_RANGE~;
        int month = (int)regulate_field(fields.get(MONTH), calendar_months_in_year(cal, year), overflow)!;
        if (fields.has(MONTH_CODE)) {
            code = fields.month_code();
            if (!calendar_year_has_month_code(cal, year, code)) {
                if (overflow == REJECT) return FIELD_OUT_OF_RANGE~;
                code = calendar_constrain_month_code(cal, code);
            }
        } else {
            code = calendar_date(cal, calendar_epoch_days(cal, year, month, 1)).month_code;
        }
        max_day = calendar_days_in_month(cal, year, month);
    } else {
        code = fields.month_code();
        max_day = cal == CHINESE || cal == DANGI ? 30 : calendar_month_code_max_days(cal, code);
    }
    int regulated = (int)regulate_field(day, max_day, overflow)!;
    if (!calendar_month_day_known(cal, code, regulated)) {
        if (overflow == REJECT) return FIELD_OUT_OF_RANGE~;
        code.leap = false;
    }
    return civil_date_from_epoch_days(calendar_month_day_reference(cal, code, regulated));
}

fn bool is_valid_iso_date_days(long epoch_days) @local {
    CivilDate d = civil_date_from_epoch_days(epoch_days);
    return is_valid_iso_date(d.y, (int)d.m, (int)d.d);
}

fn FieldSet calendar_field_keys_to_ignore(CalendarId cal, FieldSet keys) {
    FieldSet ignored = keys;
    FieldSet months = field_set(MONTH, MONTH_CODE);
    FieldSet years = field_set(ERA, ERA_YEAR, YEAR);
    if ((keys & months) != 0) ignored |= months;
    if (calendar_supports_era(cal) && (keys & years) != 0) ignored |= years;
    if (calendar_has_mid_year_eras(cal) && (keys & (months | field_set(DAY))) != 0) ignored |= field_set(ERA, ERA_YEAR);
    return ignored;
}

fn CalendarFields calendar_merge_fields(CalendarId cal, CalendarFields fields, CalendarFields additional) {
    CalendarFields merged = fields;
    merged.set = (fields.set & ~calendar_field_keys_to_ignore(cal, additional.set)) | additional.set;
    foreach (field : TemporalField::values) {
        if (additional.has(field)) merged.value[field.ordinal] = additional.get(field);
    }
    return merged;
}

fn CalendarFields iso_date_to_fields(CalendarId cal, CivilDate iso, FieldsType type) {
    CalendarDate date = calendar_iso_date(cal, iso);
    CalendarFields fields;
    fields.put(MONTH_CODE, date.month_code.encode());
    if (type != YEAR_MONTH) fields.put(DAY, date.day);
    if (type != MONTH_DAY) fields.put(YEAR, date.year);
    return fields;
}

fn CivilDate? calendar_date_from_fields(CalendarId cal, CalendarFields* fields, OverflowKind overflow) {
    calendar_resolve_fields(cal, fields, DATE)!;
    CivilDate date = calendar_date_to_iso(cal, fields, overflow)!;
    if (!is_valid_iso_date(date.y, (int)date.m, (int)date.d)) return FIELD_OUT_OF_RANGE~;
    return date;
}

// CalendarYearMonthFromFields: the first day of the month.
fn CivilDate? calendar_year_month_from_fields(CalendarId cal, CalendarFields* fields, OverflowKind overflow) {
    calendar_resolve_fields(cal, fields, YEAR_MONTH)!;
    fields.put(DAY, 1);
    CivilDate date = calendar_date_to_iso(cal, fields, overflow)!;
    if (!is_valid_iso_yearmonth(date.y, (int)date.m)) return FIELD_OUT_OF_RANGE~;
    return date;
}

fn CivilDate? calendar_month_day_from_fields(CalendarId cal, CalendarFields* fields, OverflowKind overflow) {
    calendar_resolve_fields(cal, fields, MONTH_DAY)!;
    return calendar_month_day_to_iso(cal, fields, overflow);
}

// The ISO date of a `type` made of `fields`: CalendarDateFromFields, CalendarYearMonthFromFields
// or CalendarMonthDayFromFields.
fn CivilDate? calendar_from_fields(CalendarId cal, CalendarFields* fields, FieldsType type, OverflowKind overflow) {
    switch (type) {
        case DATE: return calendar_date_from_fields(cal, fields, overflow);
        case YEAR_MONTH: return calendar_year_month_from_fields(cal, fields, overflow);
        case MONTH_DAY: return calendar_month_day_from_fields(cal, fields, overflow);
    }
}
