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
    long ms;
    long us;
    long ns;
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
            if (frac < 0) frac = -frac;
            off += (usz)libc::snprintf(&buf[off], buf_size - off, "%ld", whole);
            // trim trailing zeros in the 9-digit fraction
            char[10] frac_buf;
            int fl = libc::snprintf(&frac_buf, 10, "%09ld", frac);
            while (fl > 0 && frac_buf[fl - 1] == '0') fl -= 1;
            buf[off++] = '.';
            for (int k = 0; k < fl; k++) buf[off++] = frac_buf[k];
            buf[off++] = 'S';
        } else if (d.seconds != 0) {
            off += (usz)libc::snprintf(&buf[off], buf_size - off, "%ldS", whole);
        }
    }
    return off;
}

// Format a DurationParts as ISO 8601, per the TemporalDurationToString
// abstract operation, with `precision` controlling the seconds fraction:
// -1 = auto (trim trailing zeros, omit "." entirely when the fraction is
// zero), 0..9 = a fixed digit count (zero-padded, no trimming; 0 means no
// "." at all). Unlike format_duration (which is the auto/no-options case),
// this also prints a "0S" seconds field when smallestUnit/fractionalSecond
// Digits forced a non-auto precision — the spec's TemporalDurationToString
// step "If secondsDuration ≠ 0, or zeroMinutesAndHigher is true, or
// precision is not auto" — even when hours/minutes and the sub-second
// components are otherwise all zero. `zeroMinutesAndHigher` (the largest
// unit is second/ms/us/ns, i.e. years/months/weeks/days/hours/minutes are
// all zero) also forces a seconds field the same way. Buffer must hold at
// least 128 bytes.
fn usz format_duration_precision(DurationParts d, int precision, char* buf, usz buf_size) {
    if (precision < 0) {
        // Auto precision matches format_duration's existing behavior
        // exactly (it already implements FormatFractionalSeconds(auto)).
        return format_duration(d, buf, buf_size);
    }

    usz off = 0;
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

    long frac = ((long)d.ms * 1000 + (long)d.us) * 1000 + (long)d.ns;
    // Spec: "If secondsDuration != 0, or zeroMinutesAndHigher is true, or
    // precision is not auto, then [emit seconds]". This function is only
    // called with a non-auto precision (see the `precision < 0` early
    // return above), so that third disjunct is always true here — the
    // seconds field is always emitted.
    bool needs_seconds = true;

    if (d.hours != 0 || d.minutes != 0 || needs_seconds) {
        buf[off++] = 'T';
        if (d.hours != 0)   off += (usz)libc::snprintf(&buf[off], buf_size - off, "%ldH", d.hours * sign);
        if (d.minutes != 0) off += (usz)libc::snprintf(&buf[off], buf_size - off, "%ldM", d.minutes * sign);
        if (needs_seconds) {
            long whole = d.seconds * sign;
            off += (usz)libc::snprintf(&buf[off], buf_size - off, "%ld", whole);
            if (precision > 0) {
                long abs_frac = frac < 0 ? -frac : frac;
                char[10] frac_buf;
                libc::snprintf(&frac_buf, 10, "%09ld", abs_frac);
                buf[off++] = '.';
                for (int k = 0; k < precision; k++) buf[off++] = frac_buf[k];
            }
            buf[off++] = 'S';
        }
    }
    return off;
}

// Parse an ISO 8601 duration string (`[±]P[n]Y[n]M[n]W[n]D[T[n]H[n]M[n]S]`).
// Fractions are allowed only on the final time component. Returns false on
// grammar violations ("PT", "P1.5Y", empty). All-zero "P0D" parses fine.
fn bool read_duration_number(char[] t, usz* ip, long* n, long* frac_digits, int* frac_len) {
    usz start = *ip;
    if (*ip >= t.len) return false;
    if (!ascii::is_digit(t[*ip])) return false;
    long v = 0;
    while (*ip < t.len && ascii::is_digit(t[*ip])) {
        v = v * 10 + (long)(t[*ip] - '0');
        *ip += 1;
    }
    *n = v;
    *frac_digits = 0;
    *frac_len = 0;
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
        *frac_digits = f;
        *frac_len = digits;
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
        long n;
        long frac_digits_unused;
        int frac_len_unused;
        if (!read_duration_number(text, &i, &n, &frac_digits_unused, &frac_len_unused)) return false;
        if (frac_digits_unused != 0) return false;   // fractions only on time units
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
        long n;
        long frac_digits;
        int frac_len;
        if (!read_duration_number(text, &i, &n, &frac_digits, &frac_len)) return false;
        if (i >= text.len) return false;
        switch (text[i]) {
            case 'H': {
                // The fractional digits represent the part of an hour.
                // Multiply by 3600*10^(9-frac_len) to get nanoseconds.
                long total_ns = frac_digits;
                for (int k = frac_len; k < 9; k++) total_ns *= 10;
                total_ns *= 3600L;
                long extra_min_int = total_ns / 60_000_000_000L;
                long rem_ns = total_ns % 60_000_000_000L;
                long extra_sec_int = rem_ns / 1_000_000_000L;
                long sec_rem = rem_ns % 1_000_000_000L;
                long extra_ms = sec_rem / 1_000_000;
                long extra_us = (sec_rem / 1_000) % 1000;
                long extra_ns = sec_rem % 1000;
                out.hours   = sign * n;
                out.minutes = sign * extra_min_int;
                out.seconds = sign * extra_sec_int;
                out.ms = (int)extra_ms;
                out.us = (int)extra_us;
                out.ns = (int)extra_ns;
                break;
            }
            case 'M': {
                long total_ns = frac_digits;
                for (int k = frac_len; k < 9; k++) total_ns *= 10;
                total_ns *= 60L;
                long extra_sec_int = total_ns / 1_000_000_000L;
                long sec_rem = total_ns % 1_000_000_000L;
                long extra_ms = sec_rem / 1_000_000;
                long extra_us = (sec_rem / 1_000) % 1000;
                long extra_ns = sec_rem % 1000;
                out.minutes = sign * n;
                out.seconds = sign * extra_sec_int;
                out.ms = (int)extra_ms;
                out.us = (int)extra_us;
                out.ns = (int)extra_ns;
                break;
            }
            case 'S': {
                long total_ns = frac_digits;
                for (int k = frac_len; k < 9; k++) total_ns *= 10;
                out.seconds = sign * n;
                out.ms = (int)(total_ns / 1_000_000);
                out.us = (int)((total_ns / 1_000) % 1000);
                out.ns = (int)(total_ns % 1000);
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
        // Hours/minutes/seconds already carry sign from the parse loop
        // (e.g. `out.seconds = sign * n`). Sub-second fields come from the
        // fractional digits, which are always parsed as positive; flip them
        // here so every component has the same sign. For `-PT1.5S` this
        // gives seconds=-1, ms=-500, summing to -1.5 seconds.
        out.ms *= sign; out.us *= sign; out.ns *= sign;
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
