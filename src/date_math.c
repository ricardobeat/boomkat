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

double boomkat_date_make_time(double hour, double minute, double second, double ms) {
    double hm = hour * 3600000.0 + minute * 60000.0;
    double hms = hm + second * 1000.0;
    return hms + ms;
}

double boomkat_date_make_date(double day, double time_within_day) {
    double day_ms = day * 86400000.0;
    return day_ms + time_within_day;
}
