// The Temporal builtins, as their own enum in their own file.
//
// These are declared here rather than in core.c3's Builtin enum for two
// reasons. They are a third of every builtin in the engine (277 of 847), so
// carrying them inline made that enum read as mostly-Temporal rather than as
// the engine's own surface. And keeping them separate means the whole group
// can be gated by a single attribute on the module line below, instead of one
// per member.
//
// Ordinals are shared with Builtin through a single index space:
// builtin_fn_index values below TEMPORAL_BASE name a Builtin, values from
// TEMPORAL_BASE up to TEMPORAL_BASE + TemporalBuiltin.LAST.ordinal name a
// TemporalBuiltin, and values at or above HOST_FN_BASE name a host function.
// That is safe because a builtin index is never serialized to bytecode or
// disk -- see the comment on Builtin -- so both enums may be renumbered
// freely as members are added.
//
// The dispatch table is populated by init_temporal_dispatch_table, which
// register_builtin_dispatch_tables calls explicitly. It is deliberately not
// an @init: foreign toolchain linkers may skip C3's startup sections, which
// is why the engine's own table is registered explicitly too.
//
// The whole file is gated on !NO_TEMPORAL, so one attribute on the module
// line below removes all 277 members, their handlers, and the registration
// below it. NO_TEMPORAL is a per-feature flag; build presets are feature
// lists in project.json, so nothing here knows what "slim" means.
module boomkat::builtins @feat(!NO_TEMPORAL);

enum TemporalBuiltin : uint (String js_name, int js_arity, bool constructable, BuiltinFunc handler) {
    DURATION_CTOR {"Duration", 0, true, &builtin_temporal_duration_ctor},
    DURATION_FROM {"from", 1, false, &builtin_temporal_duration_from},
    DURATION_COMPARE {"compare", 2, false, &builtin_temporal_duration_compare},
    DURATION_PROTO_YEARS {"years", 0, false, &builtin_temporal_duration_getter},
    DURATION_PROTO_MONTHS {"months", 0, false, &builtin_temporal_duration_getter},
    DURATION_PROTO_WEEKS {"weeks", 0, false, &builtin_temporal_duration_getter},
    DURATION_PROTO_DAYS {"days", 0, false, &builtin_temporal_duration_getter},
    DURATION_PROTO_HOURS {"hours", 0, false, &builtin_temporal_duration_getter},
    DURATION_PROTO_MINUTES {"minutes", 0, false, &builtin_temporal_duration_getter},
    DURATION_PROTO_SECONDS {"seconds", 0, false, &builtin_temporal_duration_getter},
    DURATION_PROTO_MILLISECONDS {"milliseconds", 0, false, &builtin_temporal_duration_getter},
    DURATION_PROTO_MICROSECONDS {"microseconds", 0, false, &builtin_temporal_duration_getter},
    DURATION_PROTO_NANOSECONDS {"nanoseconds", 0, false, &builtin_temporal_duration_getter},
    DURATION_PROTO_SIGN {"sign", 0, false, &builtin_temporal_duration_proto_sign},
    DURATION_PROTO_BLANK {"blank", 0, false, &builtin_temporal_duration_proto_blank},
    DURATION_PROTO_NEGATED {"negated", 0, false, &builtin_temporal_duration_proto_negated},
    DURATION_PROTO_ABS {"abs", 0, false, &builtin_temporal_duration_proto_abs},
    DURATION_PROTO_TOSTRING {"toString", 0, false, &builtin_temporal_duration_proto_toString},
    DURATION_PROTO_TOJSON {"toJSON", 0, false, &builtin_temporal_duration_proto_toJSON},
    DURATION_PROTO_TOLOCALESTRING {"toLocaleString", 0, false, &builtin_temporal_duration_proto_toLocaleString},
    DURATION_PROTO_VALUEOF {"valueOf", 0, false, &builtin_temporal_duration_proto_valueOf},
    DURATION_PROTO_ADD {"add", 1, false, &builtin_temporal_duration_proto_add},
    DURATION_PROTO_SUBTRACT {"subtract", 1, false, &builtin_temporal_duration_proto_subtract},
    DURATION_PROTO_WITH {"with", 1, false, &builtin_temporal_duration_proto_with},
    DURATION_PROTO_ROUND {"round", 1, false, &builtin_temporal_duration_proto_round},
    DURATION_PROTO_TOTAL {"total", 1, false, &builtin_temporal_duration_proto_total},
    PLAIN_DATE_CTOR {"PlainDate", 3, true, &builtin_temporal_plain_date_ctor},
    PLAIN_DATE_FROM {"from", 1, false, &builtin_temporal_plain_date_from},
    PLAIN_DATE_COMPARE {"compare", 2, false, &builtin_temporal_plain_date_compare},
    PLAIN_DATE_PROTO_YEAR {"year", 0, false, &builtin_temporal_plain_date_proto_year},
    PLAIN_DATE_PROTO_MONTH {"month", 0, false, &builtin_temporal_plain_date_proto_month},
    PLAIN_DATE_PROTO_DAY {"day", 0, false, &builtin_temporal_plain_date_proto_day},
    PLAIN_DATE_PROTO_DAYOFWEEK {"dayOfWeek", 0, false, &builtin_temporal_plain_date_proto_dayOfWeek},
    PLAIN_DATE_PROTO_DAYOFYEAR {"dayOfYear", 0, false, &builtin_temporal_plain_date_proto_dayOfYear},
    PLAIN_DATE_PROTO_MONTHCODE {"monthCode", 0, false, &builtin_temporal_plain_date_proto_monthCode},
    PLAIN_DATE_PROTO_INLEAPYEAR {"inLeapYear", 0, false, &builtin_temporal_plain_date_proto_inLeapYear},
    PLAIN_DATE_PROTO_CALENDARID {"calendarId", 0, false, &builtin_temporal_plain_date_proto_calendarId},
    PLAIN_DATE_PROTO_CALENDAR {"calendar", 0, false, &builtin_temporal_plain_date_proto_calendar},
    PLAIN_DATE_PROTO_ERA {"era", 0, false, &builtin_temporal_plain_date_proto_era},
    PLAIN_DATE_PROTO_ERAYEAR {"eraYear", 0, false, &builtin_temporal_plain_date_proto_eraYear},
    PLAIN_DATE_PROTO_DAYSINMONTH {"daysInMonth", 0, false, &builtin_temporal_plain_date_proto_daysInMonth},
    PLAIN_DATE_PROTO_DAYSINWEEK {"daysInWeek", 0, false, &builtin_temporal_plain_date_proto_daysInWeek},
    PLAIN_DATE_PROTO_DAYSINYEAR {"daysInYear", 0, false, &builtin_temporal_plain_date_proto_daysInYear},
    PLAIN_DATE_PROTO_MONTHSINYEAR {"monthsInYear", 0, false, &builtin_temporal_plain_date_proto_monthsInYear},
    PLAIN_DATE_PROTO_WEEKOFYEAR {"weekOfYear", 0, false, &builtin_temporal_plain_date_proto_weekOfYear},
    PLAIN_DATE_PROTO_YEAROFWEEK {"yearOfWeek", 0, false, &builtin_temporal_plain_date_proto_yearOfWeek},
    PLAIN_DATE_PROTO_VALUEOF {"valueOf", 0, false, &builtin_temporal_plain_date_proto_valueOf},
    PLAIN_DATE_PROTO_TOSTRING {"toString", 0, false, &builtin_temporal_plain_date_proto_toString},
    PLAIN_DATE_PROTO_TOJSON {"toJSON", 0, false, &builtin_temporal_plain_date_proto_toJSON},
    PLAIN_DATE_PROTO_TOLOCALESTRING {"toLocaleString", 0, false, &builtin_temporal_plain_date_proto_toLocaleString},
    PLAIN_DATE_PROTO_EQUALS {"equals", 1, false, &builtin_temporal_plain_date_proto_equals},
    PLAIN_DATE_PROTO_WITH {"with", 1, false, &builtin_temporal_plain_date_proto_with},
    PLAIN_DATE_PROTO_ADD {"add", 1, false, &builtin_temporal_plain_date_proto_add},
    PLAIN_DATE_PROTO_SUBTRACT {"subtract", 1, false, &builtin_temporal_plain_date_proto_subtract},
    PLAIN_DATE_PROTO_UNTIL {"until", 1, false, &builtin_temporal_plain_date_proto_until},
    PLAIN_DATE_PROTO_SINCE {"since", 1, false, &builtin_temporal_plain_date_proto_since},
    PLAIN_DATE_PROTO_WITHCALENDAR {"withCalendar", 1, false, &builtin_temporal_plain_date_proto_withCalendar},
    PLAIN_DATE_PROTO_TOPLAINDATETIME {"toPlainDateTime", 0, false, &builtin_temporal_plain_date_proto_toPlainDateTime},
    PLAIN_DATE_PROTO_TOZONEDDATETIME {"toZonedDateTime", 1, false, &builtin_temporal_plain_date_proto_toZonedDateTime},
    PLAIN_DATE_PROTO_TOPLAINYEARMONTH {"toPlainYearMonth", 0, false, &builtin_temporal_plain_date_proto_toPlainYearMonth},
    PLAIN_DATE_PROTO_TOPLAINMONTHDAY {"toPlainMonthDay", 0, false, &builtin_temporal_plain_date_proto_toPlainMonthDay},
    PLAIN_TIME_CTOR {"PlainTime", 0, true, &builtin_temporal_plain_time_ctor},
    PLAIN_TIME_FROM {"from", 1, false, &builtin_temporal_plain_time_from},
    PLAIN_TIME_COMPARE {"compare", 2, false, &builtin_temporal_plain_time_compare},
    PLAIN_TIME_PROTO_HOUR {"hour", 0, false, &builtin_temporal_plain_time_getter},
    PLAIN_TIME_PROTO_MINUTE {"minute", 0, false, &builtin_temporal_plain_time_getter},
    PLAIN_TIME_PROTO_SECOND {"second", 0, false, &builtin_temporal_plain_time_getter},
    PLAIN_TIME_PROTO_MILLISECOND {"millisecond", 0, false, &builtin_temporal_plain_time_getter},
    PLAIN_TIME_PROTO_MICROSECOND {"microsecond", 0, false, &builtin_temporal_plain_time_getter},
    PLAIN_TIME_PROTO_NANOSECOND {"nanosecond", 0, false, &builtin_temporal_plain_time_getter},
    PLAIN_TIME_PROTO_VALUEOF {"valueOf", 0, false, &builtin_temporal_plain_time_proto_valueOf},
    PLAIN_TIME_PROTO_TOSTRING {"toString", 0, false, &builtin_temporal_plain_time_proto_toString},
    PLAIN_TIME_PROTO_TOJSON {"toJSON", 0, false, &builtin_temporal_plain_time_proto_toJSON},
    PLAIN_TIME_PROTO_TOLOCALESTRING {"toLocaleString", 0, false, &builtin_temporal_plain_time_proto_toLocaleString},
    PLAIN_TIME_PROTO_EQUALS {"equals", 1, false, &builtin_temporal_plain_time_proto_equals},
    PLAIN_TIME_PROTO_WITH {"with", 1, false, &builtin_temporal_plain_time_proto_with},
    PLAIN_TIME_PROTO_ADD {"add", 1, false, &builtin_temporal_plain_time_proto_add},
    PLAIN_TIME_PROTO_SUBTRACT {"subtract", 1, false, &builtin_temporal_plain_time_proto_subtract},
    PLAIN_TIME_PROTO_UNTIL {"until", 1, false, &builtin_temporal_plain_time_proto_until},
    PLAIN_TIME_PROTO_SINCE {"since", 1, false, &builtin_temporal_plain_time_proto_since},
    PLAIN_TIME_PROTO_ROUND {"round", 1, false, &builtin_temporal_plain_time_proto_round},
    PLAIN_DATETIME_CTOR {"PlainDateTime", 3, true, &builtin_temporal_plain_datetime_ctor},
    PLAIN_DATETIME_FROM {"from", 1, false, &builtin_temporal_plain_datetime_from},
    PLAIN_DATETIME_COMPARE {"compare", 2, false, &builtin_temporal_plain_datetime_compare},
    PLAIN_DATETIME_PROTO_YEAR {"year", 0, false, &builtin_temporal_plain_datetime_getter},
    PLAIN_DATETIME_PROTO_MONTH {"month", 0, false, &builtin_temporal_plain_datetime_getter},
    PLAIN_DATETIME_PROTO_DAY {"day", 0, false, &builtin_temporal_plain_datetime_getter},
    PLAIN_DATETIME_PROTO_HOUR {"hour", 0, false, &builtin_temporal_plain_datetime_getter},
    PLAIN_DATETIME_PROTO_MINUTE {"minute", 0, false, &builtin_temporal_plain_datetime_getter},
    PLAIN_DATETIME_PROTO_SECOND {"second", 0, false, &builtin_temporal_plain_datetime_getter},
    PLAIN_DATETIME_PROTO_MILLISECOND {"millisecond", 0, false, &builtin_temporal_plain_datetime_getter},
    PLAIN_DATETIME_PROTO_MICROSECOND {"microsecond", 0, false, &builtin_temporal_plain_datetime_getter},
    PLAIN_DATETIME_PROTO_NANOSECOND {"nanosecond", 0, false, &builtin_temporal_plain_datetime_getter},
    PLAIN_DATETIME_PROTO_CALENDAR {"calendar", 0, false, &builtin_temporal_plain_datetime_getter},
    PLAIN_DATETIME_PROTO_CALENDARID {"calendarId", 0, false, &builtin_temporal_plain_datetime_getter},
    PLAIN_DATETIME_PROTO_DAYOFWEEK {"dayOfWeek", 0, false, &builtin_temporal_plain_datetime_getter},
    PLAIN_DATETIME_PROTO_DAYOFYEAR {"dayOfYear", 0, false, &builtin_temporal_plain_datetime_getter},
    PLAIN_DATETIME_PROTO_WEEKOFYEAR {"weekOfYear", 0, false, &builtin_temporal_plain_datetime_getter},
    PLAIN_DATETIME_PROTO_YEAROFWEEK {"yearOfWeek", 0, false, &builtin_temporal_plain_datetime_getter},
    PLAIN_DATETIME_PROTO_DAYSINWEEK {"daysInWeek", 0, false, &builtin_temporal_plain_datetime_getter},
    PLAIN_DATETIME_PROTO_DAYSINMONTH {"daysInMonth", 0, false, &builtin_temporal_plain_datetime_getter},
    PLAIN_DATETIME_PROTO_DAYSINYEAR {"daysInYear", 0, false, &builtin_temporal_plain_datetime_getter},
    PLAIN_DATETIME_PROTO_MONTHSINYEAR {"monthsInYear", 0, false, &builtin_temporal_plain_datetime_getter},
    PLAIN_DATETIME_PROTO_ERA {"era", 0, false, &builtin_temporal_plain_datetime_getter},
    PLAIN_DATETIME_PROTO_ERAYEAR {"eraYear", 0, false, &builtin_temporal_plain_datetime_getter},
    PLAIN_DATETIME_PROTO_INLEAPYEAR {"inLeapYear", 0, false, &builtin_temporal_plain_datetime_getter},
    PLAIN_DATETIME_PROTO_MONTHCODE {"monthCode", 0, false, &builtin_temporal_plain_datetime_getter},
    PLAIN_DATETIME_PROTO_VALUEOF {"valueOf", 0, false, &builtin_temporal_plain_datetime_proto_valueOf},
    PLAIN_DATETIME_PROTO_TOSTRING {"toString", 0, false, &builtin_temporal_plain_datetime_proto_toString},
    PLAIN_DATETIME_PROTO_TOJSON {"toJSON", 0, false, &builtin_temporal_plain_datetime_proto_toJSON},
    PLAIN_DATETIME_PROTO_TOLOCALESTRING {"toLocaleString", 0, false, &builtin_temporal_plain_datetime_proto_toLocaleString},
    PLAIN_DATETIME_PROTO_EQUALS {"equals", 1, false, &builtin_temporal_plain_datetime_proto_equals},
    PLAIN_DATETIME_PROTO_WITH {"with", 1, false, &builtin_temporal_plain_datetime_proto_with},
    PLAIN_DATETIME_PROTO_ADD {"add", 1, false, &builtin_temporal_plain_datetime_proto_add},
    PLAIN_DATETIME_PROTO_SUBTRACT {"subtract", 1, false, &builtin_temporal_plain_datetime_proto_subtract},
    PLAIN_DATETIME_PROTO_UNTIL {"until", 1, false, &builtin_temporal_plain_datetime_proto_until},
    PLAIN_DATETIME_PROTO_SINCE {"since", 1, false, &builtin_temporal_plain_datetime_proto_since},
    PLAIN_DATETIME_PROTO_WITHCALENDAR {"withCalendar", 1, false, &builtin_temporal_plain_datetime_proto_withCalendar},
    PLAIN_DATETIME_PROTO_ROUND {"round", 1, false, &builtin_temporal_plain_datetime_proto_round},
    PLAIN_DATETIME_PROTO_WITHPLAINTIME {"withPlainTime", 0, false, &builtin_temporal_plain_datetime_proto_withPlainTime},
    PLAIN_DATETIME_PROTO_TOZONEDDATETIME {"toZonedDateTime", 1, false, &builtin_temporal_plain_datetime_proto_toZonedDateTime},
    PLAIN_DATETIME_PROTO_TOPLAINDATE {"toPlainDate", 0, false, &builtin_temporal_plain_datetime_proto_toPlainDate},
    PLAIN_DATETIME_PROTO_TOPLAINTIME {"toPlainTime", 0, false, &builtin_temporal_plain_datetime_proto_toPlainTime},
    PLAIN_YEARMONTH_CTOR {"PlainYearMonth", 2, true, &builtin_temporal_plain_yearmonth_ctor},
    PLAIN_YEARMONTH_FROM {"from", 1, false, &builtin_temporal_plain_yearmonth_from},
    PLAIN_YEARMONTH_COMPARE {"compare", 2, false, &builtin_temporal_plain_yearmonth_compare},
    PLAIN_YEARMONTH_PROTO_YEAR {"year", 0, false, &builtin_temporal_plain_yearmonth_proto_year},
    PLAIN_YEARMONTH_PROTO_MONTH {"month", 0, false, &builtin_temporal_plain_yearmonth_proto_month},
    PLAIN_YEARMONTH_PROTO_MONTHCODE {"monthCode", 0, false, &builtin_temporal_plain_yearmonth_proto_monthCode},
    PLAIN_YEARMONTH_PROTO_DAY {"day", 0, false, &builtin_temporal_plain_yearmonth_proto_day},
    PLAIN_YEARMONTH_PROTO_DAYSINMONTH {"daysInMonth", 0, false, &builtin_temporal_plain_yearmonth_proto_daysInMonth},
    PLAIN_YEARMONTH_PROTO_DAYSINYEAR {"daysInYear", 0, false, &builtin_temporal_plain_yearmonth_proto_daysInYear},
    PLAIN_YEARMONTH_PROTO_MONTHSINYEAR {"monthsInYear", 0, false, &builtin_temporal_plain_yearmonth_proto_monthsInYear},
    PLAIN_YEARMONTH_PROTO_INLEAPYEAR {"inLeapYear", 0, false, &builtin_temporal_plain_yearmonth_proto_inLeapYear},
    PLAIN_YEARMONTH_PROTO_CALENDARID {"calendarId", 0, false, &builtin_temporal_plain_yearmonth_proto_calendarId},
    PLAIN_YEARMONTH_PROTO_CALENDAR {"calendar", 0, false, &builtin_temporal_plain_yearmonth_proto_calendar},
    PLAIN_YEARMONTH_PROTO_ERA {"era", 0, false, &builtin_temporal_plain_yearmonth_proto_era},
    PLAIN_YEARMONTH_PROTO_ERAYEAR {"eraYear", 0, false, &builtin_temporal_plain_yearmonth_proto_eraYear},
    PLAIN_YEARMONTH_PROTO_DAYOFWEEK {"dayOfWeek", 0, false, &builtin_temporal_plain_yearmonth_proto_dayOfWeek},
    PLAIN_YEARMONTH_PROTO_DAYOFYEAR {"dayOfYear", 0, false, &builtin_temporal_plain_yearmonth_proto_dayOfYear},
    PLAIN_YEARMONTH_PROTO_WEEKOFYEAR {"weekOfYear", 0, false, &builtin_temporal_plain_yearmonth_proto_weekOfYear},
    PLAIN_YEARMONTH_PROTO_YEAROFWEEK {"yearOfWeek", 0, false, &builtin_temporal_plain_yearmonth_proto_yearOfWeek},
    PLAIN_YEARMONTH_PROTO_REFERENCEISOYEAR {"referenceISOYear", 0, false, &builtin_temporal_plain_yearmonth_proto_referenceISOYear},
    PLAIN_YEARMONTH_PROTO_DAYSINWEEK {"daysInWeek", 0, false, &builtin_temporal_plain_yearmonth_proto_daysInWeek},
    PLAIN_YEARMONTH_PROTO_VALUEOF {"valueOf", 0, false, &builtin_temporal_plain_yearmonth_proto_valueOf},
    PLAIN_YEARMONTH_PROTO_TOSTRING {"toString", 0, false, &builtin_temporal_plain_yearmonth_proto_toString},
    PLAIN_YEARMONTH_PROTO_TOJSON {"toJSON", 0, false, &builtin_temporal_plain_yearmonth_proto_toJSON},
    PLAIN_YEARMONTH_PROTO_TOLOCALESTRING {"toLocaleString", 0, false, &builtin_temporal_plain_yearmonth_proto_toLocaleString},
    PLAIN_YEARMONTH_PROTO_EQUALS {"equals", 1, false, &builtin_temporal_plain_yearmonth_proto_equals},
    PLAIN_YEARMONTH_PROTO_WITH {"with", 1, false, &builtin_temporal_plain_yearmonth_proto_with},
    PLAIN_YEARMONTH_PROTO_ADD {"add", 1, false, &builtin_temporal_plain_yearmonth_proto_add},
    PLAIN_YEARMONTH_PROTO_SUBTRACT {"subtract", 1, false, &builtin_temporal_plain_yearmonth_proto_subtract},
    PLAIN_YEARMONTH_PROTO_UNTIL {"until", 1, false, &builtin_temporal_plain_yearmonth_proto_until},
    PLAIN_YEARMONTH_PROTO_SINCE {"since", 1, false, &builtin_temporal_plain_yearmonth_proto_since},
    PLAIN_YEARMONTH_PROTO_TOPLAINDATE {"toPlainDate", 1, false, &builtin_temporal_plain_yearmonth_proto_toPlainDate},
    PLAIN_MONTHDAY_CTOR {"PlainMonthDay", 2, true, &builtin_temporal_plain_monthday_ctor},
    PLAIN_MONTHDAY_FROM {"from", 1, false, &builtin_temporal_plain_monthday_from},
    PLAIN_MONTHDAY_COMPARE {"compare", 2, false, &builtin_temporal_plain_monthday_compare},
    PLAIN_MONTHDAY_PROTO_YEAR {"year", 0, false, &builtin_temporal_plain_monthday_proto_year},
    PLAIN_MONTHDAY_PROTO_MONTH {"month", 0, false, &builtin_temporal_plain_monthday_proto_month},
    PLAIN_MONTHDAY_PROTO_MONTHCODE {"monthCode", 0, false, &builtin_temporal_plain_monthday_proto_monthCode},
    PLAIN_MONTHDAY_PROTO_DAY {"day", 0, false, &builtin_temporal_plain_monthday_proto_day},
    PLAIN_MONTHDAY_PROTO_CALENDARID {"calendarId", 0, false, &builtin_temporal_plain_monthday_proto_calendarId},
    PLAIN_MONTHDAY_PROTO_CALENDAR {"calendar", 0, false, &builtin_temporal_plain_monthday_proto_calendar},
    PLAIN_MONTHDAY_PROTO_ERA {"era", 0, false, &builtin_temporal_plain_monthday_proto_era},
    PLAIN_MONTHDAY_PROTO_ERAYEAR {"eraYear", 0, false, &builtin_temporal_plain_monthday_proto_eraYear},
    PLAIN_MONTHDAY_PROTO_INLEAPYEAR {"inLeapYear", 0, false, &builtin_temporal_plain_monthday_proto_inLeapYear},
    PLAIN_MONTHDAY_PROTO_DAYSINMONTH {"daysInMonth", 0, false, &builtin_temporal_plain_monthday_proto_daysInMonth},
    PLAIN_MONTHDAY_PROTO_DAYOFWEEK {"dayOfWeek", 0, false, &builtin_temporal_plain_monthday_proto_dayOfWeek},
    PLAIN_MONTHDAY_PROTO_DAYOFYEAR {"dayOfYear", 0, false, &builtin_temporal_plain_monthday_proto_dayOfYear},
    PLAIN_MONTHDAY_PROTO_DAYSINWEEK {"daysInWeek", 0, false, &builtin_temporal_plain_monthday_proto_daysInWeek},
    PLAIN_MONTHDAY_PROTO_DAYSINYEAR {"daysInYear", 0, false, &builtin_temporal_plain_monthday_proto_daysInYear},
    PLAIN_MONTHDAY_PROTO_MONTHSINYEAR {"monthsInYear", 0, false, &builtin_temporal_plain_monthday_proto_monthsInYear},
    PLAIN_MONTHDAY_PROTO_WEEKOFYEAR {"weekOfYear", 0, false, &builtin_temporal_plain_monthday_proto_weekOfYear},
    PLAIN_MONTHDAY_PROTO_YEAROFWEEK {"yearOfWeek", 0, false, &builtin_temporal_plain_monthday_proto_yearOfWeek},
    PLAIN_MONTHDAY_PROTO_REFERENCEISOYEAR {"referenceISOYear", 0, false, &builtin_temporal_plain_monthday_proto_referenceISOYear},
    PLAIN_MONTHDAY_PROTO_VALUEOF {"valueOf", 0, false, &builtin_temporal_plain_monthday_proto_valueOf},
    PLAIN_MONTHDAY_PROTO_TOSTRING {"toString", 0, false, &builtin_temporal_plain_monthday_proto_toString},
    PLAIN_MONTHDAY_PROTO_TOJSON {"toJSON", 0, false, &builtin_temporal_plain_monthday_proto_toJSON},
    PLAIN_MONTHDAY_PROTO_TOLOCALESTRING {"toLocaleString", 0, false, &builtin_temporal_plain_monthday_proto_toLocaleString},
    PLAIN_MONTHDAY_PROTO_EQUALS {"equals", 1, false, &builtin_temporal_plain_monthday_proto_equals},
    PLAIN_MONTHDAY_PROTO_WITH {"with", 1, false, &builtin_temporal_plain_monthday_proto_with},
    PLAIN_MONTHDAY_PROTO_UNTIL {"until", 1, false, &builtin_temporal_plain_monthday_proto_until},
    PLAIN_MONTHDAY_PROTO_SINCE {"since", 1, false, &builtin_temporal_plain_monthday_proto_since},
    PLAIN_MONTHDAY_PROTO_TOPLAINDATE {"toPlainDate", 1, false, &builtin_temporal_plain_monthday_proto_toPlainDate},
    INSTANT_CTOR {"Instant", 1, true, &builtin_temporal_instant_ctor},
    INSTANT_FROM {"from", 1, false, &builtin_temporal_instant_from},
    INSTANT_FROM_EPOCH_SECONDS {"fromEpochSeconds", 1, false, &builtin_temporal_instant_fromEpochSeconds},
    INSTANT_FROM_EPOCH_MILLISECONDS {"fromEpochMilliseconds", 1, false, &builtin_temporal_instant_fromEpochMilliseconds},
    INSTANT_FROM_EPOCH_MICROSECONDS {"fromEpochMicroseconds", 1, false, &builtin_temporal_instant_fromEpochMicroseconds},
    INSTANT_FROM_EPOCH_NANOSECONDS {"fromEpochNanoseconds", 1, false, &builtin_temporal_instant_fromEpochNanoseconds},
    INSTANT_COMPARE {"compare", 2, false, &builtin_temporal_instant_compare},
    INSTANT_PROTO_EPOCHSECONDS {"epochSeconds", 0, false, &builtin_temporal_instant_proto_epochSeconds},
    INSTANT_PROTO_EPOCHMILLISECONDS {"epochMilliseconds", 0, false, &builtin_temporal_instant_proto_epochMilliseconds},
    INSTANT_PROTO_EPOCHMICROSECONDS {"epochMicroseconds", 0, false, &builtin_temporal_instant_proto_epochMicroseconds},
    INSTANT_PROTO_EPOCHNANOSECONDS {"epochNanoseconds", 0, false, &builtin_temporal_instant_proto_epochNanoseconds},
    INSTANT_PROTO_TOSTRING {"toString", 0, false, &builtin_temporal_instant_proto_toString},
    INSTANT_PROTO_TOJSON {"toJSON", 0, false, &builtin_temporal_instant_proto_toJSON},
    INSTANT_PROTO_TOLOCALESTRING {"toLocaleString", 0, false, &builtin_temporal_instant_proto_toLocaleString},
    INSTANT_PROTO_VALUEOF {"valueOf", 0, false, &builtin_temporal_instant_proto_valueOf},
    INSTANT_PROTO_EQUALS {"equals", 1, false, &builtin_temporal_instant_proto_equals},
    INSTANT_PROTO_ADD {"add", 1, false, &builtin_temporal_instant_proto_add},
    INSTANT_PROTO_SUBTRACT {"subtract", 1, false, &builtin_temporal_instant_proto_subtract},
    INSTANT_PROTO_ROUND {"round", 1, false, &builtin_temporal_instant_proto_round},
    INSTANT_PROTO_SINCE {"since", 1, false, &builtin_temporal_instant_proto_since},
    INSTANT_PROTO_UNTIL {"until", 1, false, &builtin_temporal_instant_proto_until},
    INSTANT_PROTO_TOZONEDDATETIMEISO {"toZonedDateTimeISO", 1, false, &builtin_temporal_instant_proto_toZonedDateTimeISO},
    ZONEDDATETIME_CTOR {"ZonedDateTime", 2, true, &builtin_temporal_zoneddatetime_ctor},
    ZONEDDATETIME_FROM {"from", 1, false, &builtin_temporal_zoneddatetime_from},
    ZONEDDATETIME_COMPARE {"compare", 2, false, &builtin_temporal_zoneddatetime_compare},
    ZONEDDATETIME_PROTO_EPOCHSECONDS {"epochSeconds", 0, false, &builtin_temporal_zoneddatetime_proto_epochSeconds},
    ZONEDDATETIME_PROTO_EPOCHMILLISECONDS {"epochMilliseconds", 0, false, &builtin_temporal_zoneddatetime_proto_epochMilliseconds},
    ZONEDDATETIME_PROTO_EPOCHMICROSECONDS {"epochMicroseconds", 0, false, &builtin_temporal_zoneddatetime_proto_epochMicroseconds},
    ZONEDDATETIME_PROTO_EPOCHNANOSECONDS {"epochNanoseconds", 0, false, &builtin_temporal_zoneddatetime_proto_epochNanoseconds},
    ZONEDDATETIME_PROTO_WITH {"with", 1, false, &builtin_temporal_zoneddatetime_proto_with},
    ZONEDDATETIME_PROTO_TIMEZONEID {"timeZoneId", 0, false, &builtin_temporal_zoneddatetime_proto_timeZoneId},
    ZONEDDATETIME_PROTO_CALENDARID {"calendarId", 0, false, &builtin_temporal_zoneddatetime_proto_calendarId},
    ZONEDDATETIME_PROTO_TOSTRING {"toString", 0, false, &builtin_temporal_zoneddatetime_proto_toString},
    ZONEDDATETIME_PROTO_TOJSON {"toJSON", 0, false, &builtin_temporal_zoneddatetime_proto_toJSON},
    ZONEDDATETIME_PROTO_TOLOCALESTRING {"toLocaleString", 0, false, &builtin_temporal_zoneddatetime_proto_toLocaleString},
    ZONEDDATETIME_PROTO_EQUALS {"equals", 1, false, &builtin_temporal_zoneddatetime_proto_equals},
    ZONEDDATETIME_PROTO_WITHTIMEZONE {"withTimeZone", 1, false, &builtin_temporal_zoneddatetime_proto_withTimeZone},
    ZONEDDATETIME_PROTO_WITHCALENDAR {"withCalendar", 1, false, &builtin_temporal_zoneddatetime_proto_withCalendar},
    ZONEDDATETIME_PROTO_ADD {"add", 1, false, &builtin_temporal_zoneddatetime_proto_add},
    ZONEDDATETIME_PROTO_SUBTRACT {"subtract", 1, false, &builtin_temporal_zoneddatetime_proto_subtract},
    ZONEDDATETIME_PROTO_UNTIL {"until", 1, false, &builtin_temporal_zoneddatetime_proto_until},
    ZONEDDATETIME_PROTO_SINCE {"since", 1, false, &builtin_temporal_zoneddatetime_proto_since},
    ZONEDDATETIME_PROTO_ROUND {"round", 1, false, &builtin_temporal_zoneddatetime_proto_round},
    ZONEDDATETIME_PROTO_WITHPLAIN_TIME {"withPlainTime", 0, false, &builtin_temporal_zoneddatetime_proto_withPlainTime},
    ZONEDDATETIME_PROTO_TOINSTANT {"toInstant", 0, false, &builtin_temporal_zoneddatetime_proto_toInstant},
    ZONEDDATETIME_PROTO_TOPLAINDATETIME {"toPlainDateTime", 0, false, &builtin_temporal_zoneddatetime_proto_toPlainDateTime},
    ZONEDDATETIME_PROTO_TOPLAINTIME {"toPlainTime", 0, false, &builtin_temporal_zoneddatetime_proto_toPlainTime},
    ZONEDDATETIME_PROTO_TOPLAINDATE {"toPlainDate", 0, false, &builtin_temporal_zoneddatetime_proto_toPlainDate},
    ZONEDDATETIME_PROTO_STARTOFDAY {"startOfDay", 0, false, &builtin_temporal_zoneddatetime_proto_startOfDay},
    ZONEDDATETIME_PROTO_GETTIMEZONETRANSITION {"getTimeZoneTransition", 1, false, &builtin_temporal_zoneddatetime_proto_getTimeZoneTransition},
    ZONEDDATETIME_PROTO_YEAR {"year", 0, false, &builtin_temporal_zoneddatetime_proto_year},
    ZONEDDATETIME_PROTO_MONTH {"month", 0, false, &builtin_temporal_zoneddatetime_proto_month},
    ZONEDDATETIME_PROTO_MONTHCODE {"monthCode", 0, false, &builtin_temporal_zoneddatetime_proto_monthCode},
    ZONEDDATETIME_PROTO_DAY {"day", 0, false, &builtin_temporal_zoneddatetime_proto_day},
    ZONEDDATETIME_PROTO_HOUR {"hour", 0, false, &builtin_temporal_zoneddatetime_proto_hour},
    ZONEDDATETIME_PROTO_MINUTE {"minute", 0, false, &builtin_temporal_zoneddatetime_proto_minute},
    ZONEDDATETIME_PROTO_SECOND {"second", 0, false, &builtin_temporal_zoneddatetime_proto_second},
    ZONEDDATETIME_PROTO_MILLISECOND {"millisecond", 0, false, &builtin_temporal_zoneddatetime_proto_millisecond},
    ZONEDDATETIME_PROTO_MICROSECOND {"microsecond", 0, false, &builtin_temporal_zoneddatetime_proto_microsecond},
    ZONEDDATETIME_PROTO_NANOSECOND {"nanosecond", 0, false, &builtin_temporal_zoneddatetime_proto_nanosecond},
    ZONEDDATETIME_PROTO_OFFSET {"offset", 0, false, &builtin_temporal_zoneddatetime_proto_offset},
    ZONEDDATETIME_PROTO_OFFSETNANOSECONDS {"offsetNanoseconds", 0, false, &builtin_temporal_zoneddatetime_proto_offsetNanoseconds},
    ZONEDDATETIME_PROTO_DAYOFWEEK {"dayOfWeek", 0, false, &builtin_temporal_zoneddatetime_proto_dayOfWeek},
    ZONEDDATETIME_PROTO_DAYOFYEAR {"dayOfYear", 0, false, &builtin_temporal_zoneddatetime_proto_dayOfYear},
    ZONEDDATETIME_PROTO_WEEKOFYEAR {"weekOfYear", 0, false, &builtin_temporal_zoneddatetime_proto_weekOfYear},
    ZONEDDATETIME_PROTO_YEAROFWEEK {"yearOfWeek", 0, false, &builtin_temporal_zoneddatetime_proto_yearOfWeek},
    ZONEDDATETIME_PROTO_DAYSINWEEK {"daysInWeek", 0, false, &builtin_temporal_zoneddatetime_proto_daysInWeek},
    ZONEDDATETIME_PROTO_DAYSINMONTH {"daysInMonth", 0, false, &builtin_temporal_zoneddatetime_proto_daysInMonth},
    ZONEDDATETIME_PROTO_DAYSINYEAR {"daysInYear", 0, false, &builtin_temporal_zoneddatetime_proto_daysInYear},
    ZONEDDATETIME_PROTO_MONTHSINYEAR {"monthsInYear", 0, false, &builtin_temporal_zoneddatetime_proto_monthsInYear},
    ZONEDDATETIME_PROTO_INLEAPYEAR {"inLeapYear", 0, false, &builtin_temporal_zoneddatetime_proto_inLeapYear},
    ZONEDDATETIME_PROTO_HOURSINDAY {"hoursInDay", 0, false, &builtin_temporal_zoneddatetime_proto_hoursInDay},
    ZONEDDATETIME_PROTO_ERA {"era", 0, false, &builtin_temporal_zoneddatetime_proto_era},
    ZONEDDATETIME_PROTO_ERAYEAR {"eraYear", 0, false, &builtin_temporal_zoneddatetime_proto_eraYear},
    ZONEDDATETIME_PROTO_VALUEOF {"valueOf", 0, false, &builtin_temporal_zoneddatetime_proto_valueOf},
    NOW_INSTANT {"instant", 0, false, &builtin_temporal_now_instant},
    NOW_TIME_ZONE_ID {"timeZoneId", 0, false, &builtin_temporal_now_time_zone_id},
    NOW_PLAIN_DATE_ISO {"plainDateISO", 0, false, &builtin_temporal_now_plain_date_iso},
    NOW_PLAIN_DATE_TIME_ISO {"plainDateTimeISO", 0, false, &builtin_temporal_now_plain_date_time_iso},
    NOW_PLAIN_TIME_ISO {"plainTimeISO", 0, false, &builtin_temporal_now_plain_time_iso},
    NOW_ZONED_DATE_TIME_ISO {"zonedDateTimeISO", 0, false, &builtin_temporal_now_zoned_date_time_iso},
    LAST {"", -1, false, null}, // sentinel, one past the highest valid Temporal builtin
}

// Absolute builtin index for a Temporal builtin, as stored in
// HObjectFunction.builtin_fn_index and passed to dispatch_builtin.
macro uint temporal_index(TemporalBuiltin b) { return TEMPORAL_BASE + b.ordinal; }

// Number of Temporal dispatch slots, and so how far past TEMPORAL_BASE the
// shared dispatch table must reach. Paired with the !TEMPORAL definition in
// enum_absent.c3, which reports zero.
const uint TEMPORAL_COUNT = TemporalBuiltin.LAST.ordinal;

// Fills this enum's range of the shared dispatch table. Called explicitly by
// init_builtin_dispatch_table rather than being its own @init, so that a
// linker which drops startup sections cannot leave Temporal unregistered
// while the engine's own builtins work.
fn void init_temporal_dispatch_table() {
    $foreach $b : TemporalBuiltin::values:
        $if $b != TemporalBuiltin.LAST:
            builtin_dispatch_table[TEMPORAL_BASE + $b.ordinal] = $b.handler;
        $endif
    $endforeach
}

// .name/.length metadata for an absolute index in Temporal's range.
fn BuiltinMeta temporal_get_metadata(uint idx) {
    uint local = idx - TEMPORAL_BASE;
    if (local >= TemporalBuiltin.LAST.ordinal) return { "", -1 };
    TemporalBuiltin b = (TemporalBuiltin)local;
    return { b.js_name, b.js_arity };
}

// True when an absolute index in Temporal's range names a constructor.
fn bool temporal_is_constructor(uint idx) {
    uint local = idx - TEMPORAL_BASE;
    if (local >= TemporalBuiltin.LAST.ordinal) return false;
    return ((TemporalBuiltin)local).constructable;
}
