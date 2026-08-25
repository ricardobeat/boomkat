// ISO 8601 date/time string parsing for Temporal value types, ported from the
// polyfill's parseDateTimeLike grammar (ISO 8601 plus Temporal annotations).
//
// Input side of the ISO 8601 round-trip: accepts extended and basic date forms
// (`2024-01-15`, `20240115`), an optional time-of-day with consistent
// separators (bare `HH`, `HHMM`, `HH:MM`, up to `HH:MM:SS.fffffffff`), an
// optional `Z` or `±HH:MM[:SS[.f]]` offset, and up to 9 trailing `[...]`
// annotations. Time-zone identifiers without `=` are grammar-checked and
// ignored (date-only types don't resolve them); `u-ca=` calendar keys are
// returned to the caller for resolution (only iso8601 exists here); unknown
// lower-case keys are tolerated per the spec, while critical annotations and
// keys containing uppercase letters are rejected. Trailing junk and inconsistent
// separators fail the parse; callers throw RangeError on false.
module boomkat::lib::temporal;

import std::math;
import std::core::ascii;
import std::core::string;

// ASCII case-insensitive equality, used to match the ISO calendar identifier
// ("iso8601") and its `u-ca=` annotation values. `String` is a distinct inline
// typedef, so the stdlib method needs an explicit cast.
fn bool ci_equals(char[] a, char[] b) {
    return ((String)a).compare_to_ignore_case((String)b) == 0;
}

// Parsed ISO date/time. When `has_time` is set the caller validates the time
// fields again for its own type; date-only types drop them.
struct ParsedIsoDateTime {
    long year;
    int  month;
    int  day;
    bool has_time;
    int  hour;
    int  minute;
    int  second;
    long nanos;       // 0..999_999_999 (leap-second :60 collapses to :59)
}

fn int digit_at(char[] text, usz i) {
    return (i < text.len && ascii::is_digit(text[i])) ? text[i] - '0' : -1;
}

fn bool parse_two_digits(char[] text, usz* i, int* out) {
    int a = digit_at(text, *i);
    int b = digit_at(text, *i + 1);
    if (a < 0 || b < 0) return false;
    *out = a * 10 + b;
    *i += 2;
    return true;
}

// Fraction after a decimal point: 1..9 digits, zero-padded to nanoseconds;
// a 10th digit is "too many decimals".
fn bool parse_fraction(char[] text, usz* i, long* nanos) {
    if (*i >= text.len || text[*i] != '.') return false;
    *i += 1;
    int digits = 0;
    long n = 0;
    while (digits < 9 && digit_at(text, *i) >= 0) {
        n = n * 10 + (long)digit_at(text, *i);
        *i += 1;
        digits += 1;
    }
    if (digits == 0) return false;
    if (digit_at(text, *i) >= 0) return false;
    while (digits < 9) { n *= 10; digits += 1; }
    *nanos = n;
    return true;
}

// Time-of-day: HH[:MM[:SS[.frac]]] or HHMM[SS[.frac]] — the separator, when
// present at the first tier, must repeat at every tier.
fn bool parse_time(char[] text, usz* i, int* h, int* mi, int* s, long* nanos) {
    if (!parse_two_digits(text, i, h)) return false;
    *mi = 0;
    *s = 0;
    *nanos = 0;

    if (*i >= text.len) return true;              // bare HH
    bool sep = false;
    if (text[*i] == ':') { sep = true; *i += 1; }
    else if (digit_at(text, *i) < 0) {
        return true;                              // bare HH followed by offset/Z
    }

    if (!parse_two_digits(text, i, mi)) return false;
    if (*i >= text.len) return true;              // HH:MM or HHMM

    if (digit_at(text, *i) >= 0) {
        if (sep) return false;                    // 12:3456
        if (!parse_two_digits(text, i, s)) return false;
    } else if (text[*i] == ':') {
        if (!sep) return false;                   // 1234:56
        *i += 1;
        if (!parse_two_digits(text, i, s)) return false;
    }
    if (*i < text.len && text[*i] == '.') {
        if (!parse_fraction(text, i, nanos)) return false;
    } else if (digit_at(text, *i) >= 0 && *i < text.len) {
        return false;                             // trailing digits after seconds
    }
    return true;
}

// `Z`/`z` or `±HH[:MM[:SS[.frac]]]`. No offset is also fine.
fn bool parse_offset(char[] text, usz* i) {
    if (*i >= text.len) return true;
    if (text[*i] == 'Z' || text[*i] == 'z') { *i += 1; return true; }
    if (text[*i] != '+' && text[*i] != '-') return true;
    *i += 1;
    int h, mi, s;
    bool has_s;
    long nanos;
    if (!parse_two_digits(text, i, &h)) return false;
    bool sep = false;
    if (*i < text.len && text[*i] == ':') { sep = true; *i += 1; }
    else if (digit_at(text, *i) < 0) return true;  // ±HH
    if (!parse_two_digits(text, i, &mi)) return false;
    has_s = false;
    if (*i < text.len) {
        if (digit_at(text, *i) >= 0) {
            if (sep) return false;
            if (!parse_two_digits(text, i, &s)) return false;
            has_s = true;
        } else if (text[*i] == ':') {
            if (!sep) return false;
            *i += 1;
            if (!parse_two_digits(text, i, &s)) return false;
            has_s = true;
        }
        if (has_s) {
            if (*i < text.len && text[*i] == '.') {
                if (!parse_fraction(text, i, &nanos)) return false;
            } else if (digit_at(text, *i) >= 0 && *i < text.len) {
                return false;
            }
        }
    }
    return h <= 23;
}

// A trailing `[...]` annotation block. `out_cal_start/len` receive the first
// calendar annotation's value range (for CallerCalendar resolution); every
// `u-ca=` value keeps the same syntax but only the first is returned.
fn bool parse_annotations(char[] text, usz* i, usz* out_cal_start, usz* out_cal_len) {
    int count = 0;
    int tz_count = 0;
    bool cal_seen = false;
    *out_cal_start = 0;
    *out_cal_len = 0;
    while (*i < text.len) {
        if (text[*i] != '[') return false;
        if (count >= 9) return false;
        *i += 1;
        bool critical = false;
        if (*i < text.len && text[*i] == '!') { critical = true; *i += 1; }

        usz key_start = *i;
        while (*i < text.len && text[*i] != '=' && text[*i] != ']') {
            char c = text[*i];
            bool ok = ascii::is_lower(c) || ascii::is_digit(c) ||
                      c == '-' || c == '_' || c == '+' || c == '.' || c == '/';
            if (!ok) return false;
            *i += 1;
        }
        usz key_end = *i;
        if (key_end == key_start) return false;

        if (*i < text.len && text[*i] == '=') {
            *i += 1;
            // Only u-ca is a recognized key; unknown lower-case keys are
            // tolerated per the spec's annotation grammar.
            bool is_uca = (key_end - key_start) == 4 && text[key_start..key_end] == "u-ca";
            usz v_start = *i;
            while (*i < text.len && text[*i] != ']') {
                char c = text[*i];
                bool ok = ascii::is_lower(c) || ascii::is_upper(c) ||
                          ascii::is_digit(c) || c == '-';
                if (!ok) return false;
                *i += 1;
            }
            if (*i == v_start) return false;
            if (is_uca) {
                if (!cal_seen) { *out_cal_start = v_start; *out_cal_len = *i - v_start; }
                cal_seen = true;
            }
        } else {
            // Time-zone identifier annotation: at most one occurrence.
            tz_count += 1;
            if (tz_count > 1) return false;
            if (critical) return false;   // a critical annotation must be a key/value pair
        }
        if (*i >= text.len || text[*i] != ']') return false;
        *i += 1;
        count += 1;
    }
    return true;
}

// Parse a full Temporal ISO string into `out`. Grammar violations return
// false; the caller translates to RangeError. The time-zone count is limited
// to one occurrence (duplicates are invalid per ISO 8601 annotations).
fn bool parse_iso_date_string(char[] text, ParsedIsoDateTime* out) {
    usz len = text.len;
    usz i = 0;

    // --- Year ---
    long sign = 1;
    bool signed_year = false;
    if (i < len && (text[i] == '+' || text[i] == '-')) {
        if (text[i] == '-') sign = -1;
        signed_year = true;
        i += 1;
    }
    // An unsigned year is exactly 4 digits (extended or basic `YYYYMMDD`);
    // a signed year may be 4 or 6 digits (DateExtendedYear). Reading no more
    // than these keeps a basic date's month/day from being mistaken for year
    // digits.
    usz y_start = i;
    while (digit_at(text, i) >= 0 && (i - y_start) < (usz)(signed_year ? 6 : 4)) i += 1;
    usz y_digits = i - y_start;
    if (y_digits != 4 && !(signed_year && y_digits == 6)) return false;
    long y = 0;
    for (usz k = y_start; k < i; k++) y = y * 10 + (long)digit_at(text, k);
    if (sign < 0 && y == 0) return false;
    out.year = sign * y;

    // --- Month / day ---
    bool date_sep = false;
    if (i < len && text[i] == '-') { date_sep = true; i += 1; }
    if (!parse_two_digits(text, &i, &out.month)) return false;
    if (date_sep) {
        if (i >= len || text[i] != '-') return false;
        i += 1;
    }
    if (!parse_two_digits(text, &i, &out.day)) return false;

    out.has_time = false;
    out.hour = 0;
    out.minute = 0;
    out.second = 0;
    out.nanos = 0;

    // --- Optional time ---
    if (i < len && (text[i] == 'T' || text[i] == 't' || text[i] == ' ')) {
        i += 1;
        if (!parse_time(text, &i, &out.hour, &out.minute, &out.second, &out.nanos)) return false;
        out.has_time = true;
        if (out.hour == 24) {
            // 24:00:00 is the only valid 24 reading; it names the next day.
            if (out.minute != 0 || out.second != 0 || out.nanos != 0) return false;
            out.hour = 0;
        }
        if (out.minute > 59) return false;
        if (out.second > 60) return false;
        if (out.second == 60) out.second = 59;
        if (!parse_offset(text, &i)) return false;
    }

    // --- Annotations ---
    if (i < len) {
        if (text[i] != '[') return false;
        usz cal_start, cal_len;
        if (!parse_annotations(text, &i, &cal_start, &cal_len)) return false;
        if (cal_len != 0) {
            // The only built-in calendar is iso8601 (ASCII case-insensitive).
            char[] cal = text[cal_start..cal_start + cal_len];
            if (!ci_equals(cal, "iso8601")) return false;
        }
        if (i != len) return false;
    }
    return true;
}

// Parse a year-month string (`YYYY-MM`, optional basic `YYYYMM`, optional
// `±YYYYYY-MM`). The day field is left at 1 by default. Used by
// Temporal.PlainYearMonth.from when the input is a string.
fn bool parse_iso_yearmonth_string(char[] text, ParsedIsoDateTime* out) {
    usz len = text.len;
    usz i = 0;

    long sign = 1;
    bool signed_year = false;
    if (i < len && (text[i] == '+' || text[i] == '-')) {
        if (text[i] == '-') sign = -1;
        signed_year = true;
        i += 1;
    }
    usz y_start = i;
    while (i < len && digit_at(text, i) >= 0 && (i - y_start) < (usz)(signed_year ? 6 : 4)) i += 1;
    usz y_digits = i - y_start;
    if (y_digits != 4 && !(signed_year && y_digits == 6)) return false;
    long y = 0;
    for (usz k = y_start; k < i; k++) y = y * 10 + (long)digit_at(text, k);
    if (sign < 0 && y == 0) return false;
    out.year = sign * y;

    bool date_sep = false;
    if (i < len && text[i] == '-') { date_sep = true; i += 1; }
    if (!parse_two_digits(text, &i, &out.month)) return false;
    if (date_sep && i < len && digit_at(text, i) >= 0) return false;  // YYYY-MM-DD is a date string, not year-month
    if (i < len) {
        if (text[i] != '[') return false;
        usz cal_start, cal_len;
        if (!parse_annotations(text, &i, &cal_start, &cal_len)) return false;
        if (cal_len != 0) {
            char[] cal = text[cal_start..cal_start + cal_len];
            if (!ci_equals(cal, "iso8601")) return false;
        }
        if (i != len) return false;
    }
    out.day = 1;
    out.has_time = false;
    out.hour = 0;
    out.minute = 0;
    out.second = 0;
    out.nanos = 0;
    return true;
}

// Parse a month-day string (`--MM-DD` per ISO 8601, or bare `MM-DD`).
// The `--` prefix is the standard ISO 8601 "no year" marker for month-day
// strings. The year field is left at 0; the reference year default in the
// caller (1972) fills it in.
fn bool parse_iso_monthday_string(char[] text, ParsedIsoDateTime* out) {
    usz len = text.len;
    usz i = 0;

    // Optional `--` prefix marks a year-less month-day string.
    bool has_year_omitted = false;
    if (i + 1 < len && text[i] == '-' && text[i + 1] == '-') {
        has_year_omitted = true;
        i += 2;
    }

    usz m_start = i;
    while (i < len && digit_at(text, i) >= 0 && (i - m_start) < 2) i += 1;
    if (i - m_start != 2) return false;
    long m = (long)digit_at(text, m_start) * 10 + (long)digit_at(text, m_start + 1);
    out.month = (int)m;

    if (i >= len || text[i] != '-') return false;
    i += 1;
    if (!parse_two_digits(text, &i, &out.day)) return false;
    if (i < len) {
        if (text[i] != '[') return false;
        usz cal_start, cal_len;
        if (!parse_annotations(text, &i, &cal_start, &cal_len)) return false;
        if (cal_len != 0) {
            char[] cal = text[cal_start..cal_start + cal_len];
            if (!ci_equals(cal, "iso8601")) return false;
        }
        if (i != len) return false;
    }
    out.year = 0;
    out.has_time = false;
    out.hour = 0;
    out.minute = 0;
    out.second = 0;
    out.nanos = 0;
    (void)has_year_omitted;
    return true;
}

// Parse a time-only ISO 8601 string (`HH[:MM[:SS[.frac]]]`, optional `Z` or
// `±HH:MM` offset). Used by Temporal.PlainTime.from when the input is a bare
// time string. Returns false on grammar violations.
fn bool parse_iso_time_string(char[] text, ParsedIsoDateTime* out) {
    usz i = 0;
    if (!parse_time(text, &i, &out.hour, &out.minute, &out.second, &out.nanos)) return false;
    out.has_time = true;
    if (out.hour == 24) {
        if (out.minute != 0 || out.second != 0 || out.nanos != 0) return false;
        out.hour = 0;
    }
    if (out.minute > 59) return false;
    if (out.second > 60) return false;
    if (out.second == 60) out.second = 59;
    if (!parse_offset(text, &i)) return false;
    if (i < text.len) {
        if (text[i] != '[') return false;
        usz cal_start, cal_len;
        if (!parse_annotations(text, &i, &cal_start, &cal_len)) return false;
        if (cal_len != 0) {
            char[] cal = text[cal_start..cal_start + cal_len];
            if (!ci_equals(cal, "iso8601")) return false;
        }
        if (i != text.len) return false;
    }
    out.year = 0;
    out.month = 1;
    out.day = 1;
    return true;
}