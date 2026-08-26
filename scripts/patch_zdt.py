#!/usr/bin/env python3
"""Apply all ZonedDateTime fixes in one shot to avoid incremental corruption."""
import re

# ============================================================
# 1. Patch core.c3: add compare, round, getters, etc.
# ============================================================
with open('src/builtins/core.c3', 'r') as f:
    core = f.read()

# Add COMPARE after FROM
core = core.replace(
    '    TEMPORAL_ZONEDDATETIME_FROM {"from", 1, &builtin_temporal_zoneddatetime_from},',
    '    TEMPORAL_ZONEDDATETIME_FROM {"from", 1, &builtin_temporal_zoneddatetime_from},\n    TEMPORAL_ZONEDDATETIME_COMPARE {"compare", 2, &builtin_temporal_zoneddatetime_compare},',
)

# Add new methods after SINCE
new_methods = """    TEMPORAL_ZONEDDATETIME_PROTO_ROUND {"round", 1, &builtin_temporal_zoneddatetime_proto_round},
    TEMPORAL_ZONEDDATETIME_PROTO_WITHPLAIN_TIME {"withPlainTime", 0, &builtin_temporal_zoneddatetime_proto_withPlainTime},
    TEMPORAL_ZONEDDATETIME_PROTO_TOINSTANT {"toInstant", 0, &builtin_temporal_zoneddatetime_proto_toInstant},
    TEMPORAL_ZONEDDATETIME_PROTO_TOPLAINDATETIME {"toPlainDateTime", 0, &builtin_temporal_zoneddatetime_proto_toPlainDateTime},
    TEMPORAL_ZONEDDATETIME_PROTO_TOPLAINTIME {"toPlainTime", 0, &builtin_temporal_zoneddatetime_proto_toPlainTime},
    TEMPORAL_ZONEDDATETIME_PROTO_TOPLAINDATE {"toPlainDate", 0, &builtin_temporal_zoneddatetime_proto_toPlainDate},
    TEMPORAL_ZONEDDATETIME_PROTO_STARTOFDAY {"startOfDay", 0, &builtin_temporal_zoneddatetime_proto_startOfDay},
    TEMPORAL_ZONEDDATETIME_PROTO_GETTIMEZONETRANSITION {"getTimeZoneTransition", 1, &builtin_temporal_zoneddatetime_proto_getTimeZoneTransition},
    TEMPORAL_ZONEDDATETIME_PROTO_YEAR {"year", 0, &builtin_temporal_zoneddatetime_proto_year},
    TEMPORAL_ZONEDDATETIME_PROTO_MONTH {"month", 0, &builtin_temporal_zoneddatetime_proto_month},
    TEMPORAL_ZONEDDATETIME_PROTO_MONTHCODE {"monthCode", 0, &builtin_temporal_zoneddatetime_proto_monthCode},
    TEMPORAL_ZONEDDATETIME_PROTO_DAY {"day", 0, &builtin_temporal_zoneddatetime_proto_day},
    TEMPORAL_ZONEDDATETIME_PROTO_HOUR {"hour", 0, &builtin_temporal_zoneddatetime_proto_hour},
    TEMPORAL_ZONEDDATETIME_PROTO_MINUTE {"minute", 0, &builtin_temporal_zoneddatetime_proto_minute},
    TEMPORAL_ZONEDDATETIME_PROTO_SECOND {"second", 0, &builtin_temporal_zoneddatetime_proto_second},
    TEMPORAL_ZONEDDATETIME_PROTO_MILLISECOND {"millisecond", 0, &builtin_temporal_zoneddatetime_proto_millisecond},
    TEMPORAL_ZONEDDATETIME_PROTO_MICROSECOND {"microsecond", 0, &builtin_temporal_zoneddatetime_proto_microsecond},
    TEMPORAL_ZONEDDATETIME_PROTO_NANOSECOND {"nanosecond", 0, &builtin_temporal_zoneddatetime_proto_nanosecond},
    TEMPORAL_ZONEDDATETIME_PROTO_OFFSET {"offset", 0, &builtin_temporal_zoneddatetime_proto_offset},
    TEMPORAL_ZONEDDATETIME_PROTO_OFFSETNANOSECONDS {"offsetNanoseconds", 0, &builtin_temporal_zoneddatetime_proto_offsetNanoseconds},
    TEMPORAL_ZONEDDATETIME_PROTO_DAYOFWEEK {"dayOfWeek", 0, &builtin_temporal_zoneddatetime_proto_dayOfWeek},
    TEMPORAL_ZONEDDATETIME_PROTO_DAYOFYEAR {"dayOfYear", 0, &builtin_temporal_zoneddatetime_proto_dayOfYear},
    TEMPORAL_ZONEDDATETIME_PROTO_WEEKOFYEAR {"weekOfYear", 0, &builtin_temporal_zoneddatetime_proto_weekOfYear},
    TEMPORAL_ZONEDDATETIME_PROTO_YEAROFWEEK {"yearOfWeek", 0, &builtin_temporal_zoneddatetime_proto_yearOfWeek},
    TEMPORAL_ZONEDDATETIME_PROTO_DAYSINWEEK {"daysInWeek", 0, &builtin_temporal_zoneddatetime_proto_daysInWeek},
    TEMPORAL_ZONEDDATETIME_PROTO_DAYSINMONTH {"daysInMonth", 0, &builtin_temporal_zoneddatetime_proto_daysInMonth},
    TEMPORAL_ZONEDDATETIME_PROTO_DAYSINYEAR {"daysInYear", 0, &builtin_temporal_zoneddatetime_proto_daysInYear},
    TEMPORAL_ZONEDDATETIME_PROTO_MONTHSINYEAR {"monthsInYear", 0, &builtin_temporal_zoneddatetime_proto_monthsInYear},
    TEMPORAL_ZONEDDATETIME_PROTO_INLEAPYEAR {"inLeapYear", 0, &builtin_temporal_zoneddatetime_proto_inLeapYear},
    TEMPORAL_ZONEDDATETIME_PROTO_HOURSINDAY {"hoursInDay", 0, &builtin_temporal_zoneddatetime_proto_hoursInDay},
    TEMPORAL_ZONEDDATETIME_PROTO_ERA {"era", 0, &builtin_temporal_zoneddatetime_proto_era},
    TEMPORAL_ZONEDDATETIME_PROTO_ERAYEAR {"eraYear", 0, &builtin_temporal_zoneddatetime_proto_eraYear},"""

core = core.replace(
    '    TEMPORAL_ZONEDDATETIME_PROTO_SINCE {"since", 1, &builtin_temporal_zoneddatetime_proto_since},',
    '    TEMPORAL_ZONEDDATETIME_PROTO_SINCE {"since", 1, &builtin_temporal_zoneddatetime_proto_since},\n' + new_methods,
)

with open('src/builtins/core.c3', 'w') as f:
    f.write(core)
print("Patched core.c3")
