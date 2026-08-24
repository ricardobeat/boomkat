// ISO 8601 string formatters for Temporal value types. Output side only:
// each function writes into a caller-owned buffer and returns the byte
// count. The caller hands the resulting bytes to the JS string machinery.
//
// The formatters are spec-locked: Temporal.PlainDate.prototype.toString
// must produce ISO 8601 extended years (with a leading sign for |year| >=
// 10000), the time-of-day separators are fixed, and sub-second precision
// is rendered at the smallest unit that carries a non-zero value.
module boomkat::lib::temporal;

import std::math;
import libc;

// Minimum buffer size to format any CivilDate: sign (1) + 6 digits + 2
// separators + 2 + 2 + 1 NUL = 14. The PlainDate builtin uses a 32-byte
// buffer for safety.
const int ISO8601_DATE_BUFSIZE = 14;

// Format a CivilDate as ISO 8601 (`YYYY-MM-DD`, `+YYYYYY-MM-DD`, or
// `-YYYYYY-MM-DD`). Writes the bytes into `buf` (must hold at least
// ISO8601_DATE_BUFSIZE bytes), returns the byte count, no NUL terminator.
fn usz format_civil_date(CivilDate d, char* buf, usz buf_size) {
    long year = d.y;
    int month = d.m;
    int day = d.d;

    if (year < 0) {
        return (usz)libc::snprintf(buf, buf_size, "-%06ld-%02d-%02d", -year, month, day);
    } else if (year > 9999) {
        return (usz)libc::snprintf(buf, buf_size, "+%06ld-%02d-%02d", year, month, day);
    } else {
        return (usz)libc::snprintf(buf, buf_size, "%04ld-%02d-%02d", year, month, day);
    }
}
