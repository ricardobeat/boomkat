// ISO 8601 string formatters and parsers for Temporal value types.
//
// Formatting: each function writes into a caller-owned buffer and returns the
// byte count; the caller hands the resulting bytes to the JS string machinery.
// Parsing: grammar check only, values land in the caller's record struct.
//
// The formatters are spec-locked: Temporal.PlainDate.prototype.toString
// must produce ISO 8601 extended years (with a leading sign for |year| >=
// 10000), and Temporal.Duration.prototype.toString renders each non-zero
// component in the fixed P[n]Y[n]M[n]W[n]DT[n]H[n]M[n]S order with the
// seconds fraction trimmed to the smallest non-zero digit.
module boomkat::lib::temporal;

import std::math;
import std::core::ascii;
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
    int month = (int)d.m;
    int day = (int)d.d;

    if (year < 0) {
        return (usz)libc::snprintf(buf, buf_size, "-%06ld-%02d-%02d", -year, month, day);
    } else if (year > 9999) {
        return (usz)libc::snprintf(buf, buf_size, "+%06ld-%02d-%02d", year, month, day);
    } else {
        return (usz)libc::snprintf(buf, buf_size, "%04ld-%02d-%02d", year, month, day);
    }
}

// Duration fields in the fixed ISO 8601 ordering. Date components are whole
// numbers; the time portion folds fractional seconds into ms/us/ns so the
// value type stays integer-only.
struct DurationParts {
    long years;
    long months;
    long weeks;
    long days;
    long hours;
    long minutes;
    long seconds;
    int  ms;
    int  us;
    int  ns;
}

// Format a DurationParts as ISO 8601. All zero -> "PT0S". The seconds field
// renders with a fraction trimmed to the smallest non-zero sub-second digit.
// Buffer must hold at least 128 bytes.
fn usz format_duration(DurationParts d, char* buf, usz buf_size) {
    usz off = 0;
    if (d.years == 0 && d.months == 0 && d.weeks == 0 && d.days == 0 &&
        d.hours == 0 && d.minutes == 0 && d.seconds == 0 && d.ms == 0 &&
        d.us == 0 && d.ns == 0) {
        return (usz)libc::snprintf(buf, buf_size, "PT0S");
    }

    long sign = 1;
    if (d.years < 0 || d.months < 0 || d.weeks < 0 || d.days < 0 ||
        d.hours < 0 || d.minutes < 0 || d.seconds < 0 || d.ms < 0 ||
        d.us < 0 || d.ns < 0) sign = -1;
    if (sign < 0) buf[off++] = '-';
    buf[off++] = 'P';

    if (d.years != 0)  off += (usz)libc::snprintf(&buf[off], buf_size - off, "%ldY",  d.years * sign);
    if (d.months != 0) off += (usz)libc::snprintf(&buf[off], buf_size - off, "%ldM",  d.months * sign);
    if (d.weeks != 0)  off += (usz)libc::snprintf(&buf[off], buf_size - off, "%ldW",  d.weeks * sign);
    if (d.days != 0)   off += (usz)libc::snprintf(&buf[off], buf_size - off, "%ldD",  d.days * sign);

    if (d.hours != 0 || d.minutes != 0 || d.seconds != 0 || d.ms != 0 || d.us != 0 || d.ns != 0) {
        buf[off++] = 'T';
        if (d.hours != 0)   off += (usz)libc::snprintf(&buf[off], buf_size - off, "%ldH", d.hours * sign);
        if (d.minutes != 0) off += (usz)libc::snprintf(&buf[off], buf_size - off, "%ldM", d.minutes * sign);
        long secs = d.seconds * sign;
        long whole = secs;
        if (d.ns != 0 || d.us != 0 || d.ms != 0) {
            long frac = ((long)d.ms * 1000 + (long)d.us) * 1000 + (long)d.ns;
            off += (usz)libc::snprintf(&buf[off], buf_size - off, "%ld", whole);
            // trim trailing zeros in the 9-digit fraction
            char[10] frac_buf;
            int fl = libc::snprintf(&frac_buf, 10, "%09ld", frac);
            while (fl > 0 && frac_buf[fl - 1] == '0') fl -= 1;
            buf[off++] = '.';
            for (int k = 0; k < fl; k++) buf[off++] = frac_buf[k];
            buf[off++] = 'S';
        } else {
            off += (usz)libc::snprintf(&buf[off], buf_size - off, "%ldS", whole);
        }
    }
    return off;
}

// Parse an ISO 8601 duration string (`[±]P[n]Y[n]M[n]W[n]D[T[n]H[n]M[n]S]`).
// Fractions are allowed only on the final time component. Returns false on
// grammar violations ("PT", "P1.5Y", empty). All-zero "P0D" parses fine.
fn bool read_duration_number(char[] t, usz* ip, long* n, long* frac_ns) {
    usz start = *ip;
    if (*ip >= t.len) return false;
    if (!ascii::is_digit(t[*ip])) return false;
    long v = 0;
    while (*ip < t.len && ascii::is_digit(t[*ip])) {
        v = v * 10 + (long)(t[*ip] - '0');
        *ip += 1;
    }
    *n = v;
    *frac_ns = 0;
    if (*ip < t.len && t[*ip] == '.') {
        *ip += 1;
        long f = 0;
        int digits = 0;
        while (digits < 9 && *ip < t.len && ascii::is_digit(t[*ip])) {
            f = f * 10 + (long)(t[*ip] - '0');
            *ip += 1;
            digits += 1;
        }
        if (digits == 0) return false;
        if (*ip < t.len && ascii::is_digit(t[*ip])) return false;
        while (digits < 9) { f *= 10; digits += 1; }
        *frac_ns = f;
    }
    return *ip > start;
}

fn bool parse_duration(char[] text, DurationParts* out) {
    out.years = 0; out.months = 0; out.weeks = 0; out.days = 0;
    out.hours = 0; out.minutes = 0; out.seconds = 0;
    out.ms = 0; out.us = 0; out.ns = 0;

    usz i = 0;
    long sign = 1;
    if (i < text.len && (text[i] == '+' || text[i] == '-')) {
        if (text[i] == '-') sign = -1;
        i += 1;
    }
    if (i >= text.len || text[i] != 'P') return false;
    i += 1;

    bool time_part = false;
    bool has_date = false;

    while (i < text.len && !time_part) {
        if (text[i] == 'T') {
            time_part = true;
            i += 1;
            if (i >= text.len) return false;   // "PxT" dangling
            break;
        }
        long n, frac;
        if (!read_duration_number(text, &i, &n, &frac)) return false;
        if (frac != 0) return false;           // fractions only on time units
        if (i >= text.len) return false;
        switch (text[i]) {
            case 'Y': out.years = n; break;
            case 'M': out.months = n; break;
            case 'W': out.weeks = n; break;
            case 'D': out.days = n; break;
            default: return false;
        }
        has_date = true;
        i += 1;
    }

    bool any_time = false;
    while (i < text.len) {
        long n, frac;
        if (!read_duration_number(text, &i, &n, &frac)) return false;
        if (i >= text.len) return false;
        switch (text[i]) {
            case 'H': out.hours = sign * n; if (frac != 0) return false; break;
            case 'M': out.minutes = sign * n; if (frac != 0) return false; break;
            case 'S': {
                out.seconds = sign * n;
                out.ms = (int)(frac / 1_000_000);
                out.us = (int)((frac / 1000) % 1000);
                out.ns = (int)(frac % 1000);
                break;
            }
            default: return false;
        }
        any_time = true;
        i += 1;
    }

    if (!has_date && !any_time) return false;       // "P" alone
    if (time_part && !any_time) return false;  // "PT" alone
    if (sign < 0) {
        out.years *= sign; out.months *= sign; out.weeks *= sign; out.days *= sign;
    }
    return true;
}

// Minimum buffer size to format any CivilTime: hours (2) + : + minutes (2)
// + : + seconds (2) + . + 9-digit fraction + 1 = 19. The PlainTime builtin
// uses a 32-byte buffer.
const int ISO8601_TIME_BUFSIZE = 19;

// Format a CivilTime as ISO 8601 wall-clock time (`HH:MM:SS[.ffff...]`).
// Trailing-zero trimming matches the spec's smallestUnit / fraction digits
// options: if `truncate_nanos` is non-null, the sub-second fraction is
// rendered only down to that digit count (round-to-nearest, ties to even
// not required for PlainTime's fixed-precision surface). `ns_digits` is
// the count of fractional digits to render (0..9); pass -1 for "round-trip
// smallest non-zero".
fn usz format_civil_time(CivilTime t, char* buf, usz buf_size, int ns_digits) {
    int h  = (int)t.h;
    int mi = (int)t.mi;
    int s  = (int)t.s;
    int ms = (int)t.ms;
    int us = (int)t.us;
    int ns = (int)t.ns;

    if (ns_digits < 0) {
        // Trim trailing zeros to the smallest non-zero digit. Spec: omit the
        // decimal point entirely when the fractional part is zero.
        if (ms == 0 && us == 0 && ns == 0) {
            ns_digits = 0;
        } else if (ns != 0) {
            ns_digits = 9;
        } else if (us != 0) {
            ns_digits = 6;
        } else {
            ns_digits = 3;
        }
    }
    if (ns_digits == 0) {
        return (usz)libc::snprintf(buf, buf_size, "%02d:%02d:%02d", h, mi, s);
    }

    long frac = ((long)ms * 1000 + (long)us) * 1000 + (long)ns;
    char[10] frac_buf;
    libc::snprintf(&frac_buf, 10, "%09ld", frac);
    int trim_to = ns_digits;
    if (trim_to > 9) trim_to = 9;
    // When the caller asks for a specific number of fractional digits (the
    // fractionalSecondDigits option), honor it exactly: round by truncating
    // past `trim_to`. When ns_digits was auto-derived (the trim trail) only
    // drop trailing zeros.
    int cut = trim_to;
    frac_buf[cut] = '\0';
    return (usz)libc::snprintf(buf, buf_size, "%02d:%02d:%02d.%s", h, mi, s, &frac_buf);
}

// Format a CivilDateTime as `YYYY-MM-DDTHH:MM:SS[.ffff...]` (or with the
// extended-year leading sign for |year| >= 10000). `ns_digits` follows
// the same convention as format_civil_time.
fn usz format_civil_datetime(CivilDateTime dt, char* buf, usz buf_size, int ns_digits) {
    char[ISO8601_DATE_BUFSIZE + 1] date_buf;
    usz date_len = format_civil_date(dt.date, &date_buf, ISO8601_DATE_BUFSIZE);
    // date_len <= 13; copy into buf then append time
    for (usz k = 0; k < date_len; k++) buf[k] = date_buf[k];
    usz off = date_len;
    buf[off++] = 'T';
    char[ISO8601_TIME_BUFSIZE + 1] time_buf;
    usz time_len = format_civil_time(dt.time, &time_buf, ISO8601_TIME_BUFSIZE, ns_digits);
    for (usz k = 0; k < time_len && (off + k) < buf_size; k++) buf[off + k] = time_buf[k];
    off += time_len;
    return off;
}
