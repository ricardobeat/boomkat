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
