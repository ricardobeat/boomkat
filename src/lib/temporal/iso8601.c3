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
// value type stays integer-only.  Sub-second fields use double so that
// values exceeding int64 range (e.g. microseconds: 4.5e21 from a property
// bag) survive round-tripping through DurationParts without overflow.

// A DurationParts reduced to the canonical shape the ISO 8601 duration
// formatters need: every field is a non-negative magnitude, `negative`
// carries the single sign for the whole value, and the sub-second columns
// have been folded into `seconds` + a 0..999999999 nanosecond remainder.
//
// The sub-second fold is required by the spec: Temporal.Duration's ms/us/ns
// fields are unbounded (`new Temporal.Duration(0,0,0,0,0,0,0, 999, 999999,
// 999999999)` is a valid duration of 2.998998999 seconds), so a formatter
// cannot treat `ms*10^6 + us*10^3 + ns` as a nine-digit fraction. Units at
// or above `seconds` never carry into each other -- `{days:1, seconds:1}`
// formats as "P1DT1S", not "PT25H" -- so the fold stops at the seconds
// column.
struct NormalizedDuration {
    bool negative;
    long years;
    long months;
    long weeks;
    long days;
    long hours;
    long minutes;
    long seconds;
    long frac_ns;   // 0 .. 999_999_999
}

// Reduce a raw DurationParts to its canonical formatting shape.
//
// A well-formed Duration has all fields sharing one sign, but intermediate
// values (notably the rebalanced result of Duration.prototype.toString's
// rounding path) can pair a positive date part with a negative time part.
// Deriving the sign by scanning for "any negative field" would then negate
// the wrong columns and emit a doubly-signed string like "-P-1DT1H0S". So
// the sign is taken from the value as a whole: the date part decides, and
// the time part only gets a say when every date field is zero.
fn NormalizedDuration normalize_duration(DurationParts d) {
    // Fold ms/us/ns into a single signed nanosecond count, then into whole
    // seconds plus a remainder. int128 keeps `ms` near LONG_MAX from
    // overflowing the 10^6 scale-up.
    int128 total_ns = (int128)d.ms * 1_000_000 + (int128)d.us * 1_000 + (int128)d.ns;
    int128 carry_secs = total_ns / 1_000_000_000;
    int128 rem_ns = total_ns % 1_000_000_000;
    int128 secs = (int128)d.seconds + carry_secs;

    // C3 truncates division toward zero, so `rem_ns` and `secs` can end up
    // with opposite signs (e.g. seconds=1, ns=-1500000000 gives secs=0,
    // rem=-500000000). Borrow one second so the remainder matches the
    // seconds column's sign and stays a pure magnitude below.
    if (rem_ns > 0 && secs < 0) { secs += 1; rem_ns -= 1_000_000_000; }
    else if (rem_ns < 0 && secs > 0) { secs -= 1; rem_ns += 1_000_000_000; }

    bool neg;
    if (d.years != 0 || d.months != 0 || d.weeks != 0 || d.days != 0) {
        neg = d.years < 0 || d.months < 0 || d.weeks < 0 || d.days < 0;
    } else if (d.hours != 0 || d.minutes != 0) {
        neg = d.hours < 0 || d.minutes < 0;
    } else {
        neg = secs < 0 || rem_ns < 0;
    }

    return {
        .negative = neg,
        .years    = math::abs(d.years),
        .months   = math::abs(d.months),
        .weeks    = math::abs(d.weeks),
        .days     = math::abs(d.days),
        .hours    = math::abs(d.hours),
        .minutes  = math::abs(d.minutes),
        .seconds  = (long)math::abs(secs),
        .frac_ns  = (long)math::abs(rem_ns),
    };
}

// Write the fractional-seconds digits for `frac_ns` (a 0..999999999
// magnitude) into `buf`, including the leading '.', and return the bytes
// written. `precision` is -1 for "auto" (render the nine digits with
// trailing zeros trimmed, and emit nothing at all when the fraction is
// zero) or 0..9 for a fixed, zero-padded digit count (0 emits nothing).
//
// The nine digits are produced by hand rather than through snprintf's
// "%09ld": a caller-supplied value above 999999999 would render as ten
// digits and overrun a nine-digit stack buffer. Normalization guarantees
// the range, and building the digits directly keeps that guarantee local.
fn usz write_fraction(long frac_ns, int precision, char* buf) @local {
    if (precision == 0) return 0;
    char[9] digits;
    long v = frac_ns;
    for (int k = 8; k >= 0; k--) { digits[k] = (char)('0' + (v % 10)); v /= 10; }

    int count = precision;
    if (precision < 0) {
        count = 9;
        while (count > 0 && digits[count - 1] == '0') count -= 1;
        if (count == 0) return 0;   // auto: no fraction at all
    }
    usz off = 0;
    buf[off++] = '.';
    for (int k = 0; k < count; k++) buf[off++] = digits[k];
    return off;
}

// Format a DurationParts as ISO 8601. All zero -> "PT0S". The seconds field
// renders with a fraction trimmed to the smallest non-zero sub-second digit.
// Buffer must hold at least 128 bytes.
fn usz format_duration(DurationParts d, char* buf, usz buf_size) {
    return format_duration_precision(d, -1, buf, buf_size);
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
    NormalizedDuration n = normalize_duration(d);

    // An all-zero duration is "PT0S" at auto precision; a fixed precision
    // still renders the padded fraction ("PT0.000S" for 3 digits).
    bool all_zero = n.years == 0 && n.months == 0 && n.weeks == 0 && n.days == 0 &&
        n.hours == 0 && n.minutes == 0 && n.seconds == 0 && n.frac_ns == 0;
    if (all_zero && precision < 0) {
        return (usz)libc::snprintf(buf, buf_size, "PT0S");
    }

    usz off = 0;
    if (n.negative) buf[off++] = '-';
    buf[off++] = 'P';

    if (n.years != 0)  off += (usz)libc::snprintf(&buf[off], buf_size - off, "%ldY", n.years);
    if (n.months != 0) off += (usz)libc::snprintf(&buf[off], buf_size - off, "%ldM", n.months);
    if (n.weeks != 0)  off += (usz)libc::snprintf(&buf[off], buf_size - off, "%ldW", n.weeks);
    if (n.days != 0)   off += (usz)libc::snprintf(&buf[off], buf_size - off, "%ldD", n.days);

    // TemporalDurationToString emits the seconds field when the seconds
    // column is non-zero, when no unit above `seconds` is present (so the
    // string cannot be empty after "P"), or whenever a fixed precision was
    // requested.
    bool zero_minutes_and_higher = n.years == 0 && n.months == 0 && n.weeks == 0 &&
        n.days == 0 && n.hours == 0 && n.minutes == 0;
    bool needs_seconds = n.seconds != 0 || n.frac_ns != 0 || zero_minutes_and_higher ||
        precision >= 0;

    if (n.hours != 0 || n.minutes != 0 || needs_seconds) {
        buf[off++] = 'T';
        if (n.hours != 0)   off += (usz)libc::snprintf(&buf[off], buf_size - off, "%ldH", n.hours);
        if (n.minutes != 0) off += (usz)libc::snprintf(&buf[off], buf_size - off, "%ldM", n.minutes);
        if (needs_seconds) {
            off += (usz)libc::snprintf(&buf[off], buf_size - off, "%ld", n.seconds);
            off += write_fraction(n.frac_ns, precision, &buf[off]);
            buf[off++] = 'S';
        }
    }
    return off;
}

// Scale a parsed fraction to nanoseconds. `digits` is the literal value of
// the fractional digits and `len` how many there were, so "5" (len 1) is
// 5*10^8 ns and "000000001" (len 9) is 1 ns.
fn long fraction_to_ns(long digits, int len) @local {
    long ns = digits;
    for (int k = len; k < 9; k++) ns *= 10;
    return ns;
}

// Distribute a sub-unit nanosecond count across the seconds/ms/us/ns
// columns of `out`, adding the whole-seconds carry to whatever the caller
// already stored in `out.seconds`. `sign` applies to the seconds carry
// only; the sub-second columns are left positive and negated as a group
// once parsing finishes.
fn void split_subseconds(long total_ns, long sign, DurationParts* out) @local {
    out.seconds += sign * (total_ns / 1_000_000_000L);
    long rem = total_ns % 1_000_000_000L;
    out.ms = (double)(rem / 1_000_000);
    out.us = (double)((rem / 1_000) % 1000);
    out.ns = (double)(rem % 1000);
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
        long d = (long)(t[*ip] - '0');
        if (v > 9007199254740991L / 10L || (v == 9007199254740991L / 10L && d > 9007199254740991L % 10L)) return false;
        v = v * 10 + d;
        *ip += 1;
    }
    *n = v;
    *frac_digits = 0;
    *frac_len = 0;
    if (*ip < t.len && (t[*ip] == '.' || t[*ip] == ',')) {
        char sep = t[*ip];
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
        // ISO 8601 lets either '.' or ',' be the decimal mark in extended
        // form; ',' only counts when there is no '.' elsewhere, but a
        // single-component token can't have one anyway.
        (void)sep;
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
    if (i >= text.len || ascii::to_upper(text[i]) != 'P') return false;
    i += 1;

    bool time_part = false;
    bool has_date = false;

    while (i < text.len && !time_part) {
        if (ascii::to_upper(text[i]) == 'T') {
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
        switch (ascii::to_upper(text[i])) {
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
    // The time grammar is `[n]H[n]M[n]S`: each designator appears at most
    // once and only in that order, and a fraction is allowed only on the
    // final component present (`DurationTimeComponent` in the spec, where
    // the fractional variants are all string-final). `seen_rank` tracks the
    // highest designator consumed so far so "PT1S1H" and "PT1H1H" are
    // rejected instead of silently overwriting a field.
    int seen_rank = 0;   // 1 = H, 2 = M, 3 = S
    while (i < text.len) {
        long n;
        long frac_digits;
        int frac_len;
        if (!read_duration_number(text, &i, &n, &frac_digits, &frac_len)) return false;
        if (i >= text.len) return false;
        int rank;
        char d = ascii::to_upper(text[i]);
        switch (d) {
            case 'H': rank = 1;
            case 'M': rank = 2;
            case 'S': rank = 3;
            default: return false;
        }
        if (rank <= seen_rank) return false;   // out of order or repeated
        seen_rank = rank;
        // A fractional component must be the last thing in the string.
        if (frac_len != 0 && i + 1 != text.len) return false;
        // The fraction is a part of the unit just consumed; scale it to
        // nanoseconds and let it cascade down into the smaller columns.
        // `split_subseconds` writes the whole-seconds carry and the ms/us/ns
        // columns; the caller adds `sign * n` for the unit's own integer
        // part. Sub-second columns stay positive here and are negated once,
        // together, by the `sign < 0` block below the loop.
        long total_ns = fraction_to_ns(frac_digits, frac_len);
        switch (d) {
            case 'H':
                total_ns *= 3600L;
                out.hours   = sign * n;
                out.minutes = sign * (total_ns / 60_000_000_000L);
                split_subseconds(total_ns % 60_000_000_000L, sign, out);
            case 'M':
                total_ns *= 60L;
                out.minutes = sign * n;
                split_subseconds(total_ns, sign, out);
            case 'S':
                out.seconds = sign * n;
                split_subseconds(total_ns, sign, out);
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

    // Special sentinel values for smallestUnit precision:
    // -11 = hour only (HH), -12 = minute precision (HH:MM)
    if (ns_digits == -11) {
        return (usz)libc::snprintf(buf, buf_size, "%02d", h);
    }
    if (ns_digits == -12) {
        return (usz)libc::snprintf(buf, buf_size, "%02d:%02d", h, mi);
    }
    bool auto_digits = ns_digits < 0;
    if (ns_digits < 0) {
        // Auto: use full 9-digit precision, then trim trailing zeros.
        if (ms == 0 && us == 0 && ns == 0) {
            ns_digits = 0;
        } else {
            ns_digits = 9;
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
    if (auto_digits) {
        // In auto mode, trim trailing zeros.
        while (cut > 0 && frac_buf[cut - 1] == '0') cut--;
    }
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
    // ns_digits == -10 means day precision: date only, no time component.
    if (ns_digits == -10) {
        return off;
    }
    buf[off++] = 'T';
    char[ISO8601_TIME_BUFSIZE + 1] time_buf;
    usz time_len = format_civil_time(dt.time, &time_buf, ISO8601_TIME_BUFSIZE, ns_digits);
    for (usz k = 0; k < time_len && (off + k) < buf_size; k++) buf[off + k] = time_buf[k];
    off += time_len;
    return off;
}
