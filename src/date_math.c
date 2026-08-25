/*
 * date_math.c — exact IEEE-754 MakeTime/MakeDate arithmetic for Date.UTC and
 * the Date constructor.
 *
 * The rest of the engine is compiled with relaxed floating-point math
 * (allows LLVM to reassociate/contract FP operations for speed, including
 * fusing a multiply+add into a single fused-multiply-add with one rounding
 * step), but ES2015+ §21.4.1.14 MakeTime and §21.4.1.15 MakeDate require
 * each arithmetic step to be rounded separately, in a fixed left-to-right
 * order:
 *   MakeTime: ((h * msPerHour + m * msPerMinute) + s * msPerSecond) + milli
 *   MakeDate: day * msPerDay + time
 * For huge operands (near the double precision limit), FMA contraction or
 * reassociation changes the rounded result. Doing this arithmetic in a
 * separate translation unit, with contraction explicitly disabled and each
 * step materialized in its own statement, keeps it exact without disabling
 * relaxed FP math engine-wide.
 */
#pragma STDC FP_CONTRACT OFF
#include <stdlib.h>

double boomkat_date_make_time(double hour, double minute, double second, double ms) {
    double hm = hour * 3600000.0 + minute * 60000.0;
    double hms = hm + second * 1000.0;
    return hms + ms;
}

double boomkat_date_make_date(double day, double time_within_day) {
    double day_ms = day * 86400000.0;
    return day_ms + time_within_day;
}

/*
 * boomkat_system_tz_name — Temporal.Now.timeZoneId() source. Reads the TZ
 * environment variable (POSIX-set; Linux/macOS/BusyBox set it from
 * /etc/localtime or the user override). Returns a static-lifetime C string;
 * the caller treats it as opaque and only feeds it to intern_string.
 *
 * POSIX leaves "TZ unset" implementation-defined, so on unset or empty we
 * fall back to "UTC" — guaranteed present in the embedded tzdb and the spec's
 * canonical default for a host that has no configured zone. The fallback
 * matches the engine's test262 worker behavior, which runs under TZ=UTC.
 */
const char* boomkat_system_tz_name(void) {
    const char* tz = getenv("TZ");
    if (tz == NULL || tz[0] == '\0') return "UTC";
    return tz;
}
