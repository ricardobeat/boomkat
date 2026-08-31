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
    if (a.len != b.len) return false;
    for (usz i = 0; i < a.len; i++) {
        char ca = a[i];
        char cb = b[i];
        // ASCII fast path. Both characters are in A-Z range only when the
        // upper-cased form differs; map both to lower for comparison.
        // For non-ASCII bytes we just compare directly — the spec only
        // requires the ASCII A-Z range to be case-insensitive, and any
        // non-ASCII byte can't be "iso8601" anyway.
        if (ca >= 'A' && ca <= 'Z') ca = (char)(ca + 32);
        if (cb >= 'A' && cb <= 'Z') cb = (char)(cb + 32);
        if (ca != cb) return false;
    }
    return true;
}

// What kind of UTC offset the parsed string carried, if any. The grammar
// disallows `Z` from several Temporal strings (PlainDate / PlainDateTime /
// PlainTime / PlainMonthDay), so the parser surfaces the distinction and the
// `*_from_arg` callers decide what to do with it.
enum OffsetKind : char {
    NONE,    // no offset/Z present
    NUMERIC, // ±HH[:MM[:SS[.frac]]]
    Z,       // Z or z designator
}

// Parsed ISO date/time. When `has_time` is set the caller validates the time
// fields again for its own type; date-only types drop them. `offset_kind` is
// the offset the string carried after the time component (if any).
struct ParsedIsoDateTime {
    long year;
    int  month;
    int  day;
    bool has_time;
    int  hour;
    int  minute;
    int  second;
    long nanos;       // 0..999_999_999 (leap-second :60 collapses to :59)
    OffsetKind offset_kind;
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
    // ISO 8601 permits either `.` or `,` as the decimal mark for a fractional
    // component (`±YYYYYY-MM-DDTHH:MM:SS,5` is valid). Treat them identically
    // here; the value is converted to nanoseconds.
    if (*i >= text.len) return false;
    char sep = text[*i];
    if (sep != '.' && sep != ',') return false;
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
// present at the first tier, must repeat at every tier. The fractional
// component, per ISO 8601, may only follow the seconds field; bare
// `HH:MM.frac` and `HH.frac` are not valid.
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

    bool got_s = false;
    if (digit_at(text, *i) >= 0) {
        if (sep) return false;                    // 12:3456
        if (!parse_two_digits(text, i, s)) return false;
        got_s = true;
    } else if (text[*i] == ':') {
        if (!sep) return false;                   // 1234:56
        *i += 1;
        if (!parse_two_digits(text, i, s)) return false;
        got_s = true;
    }
    if (got_s) {
        if (*i < text.len && (text[*i] == '.' || text[*i] == ',')) {
            if (!parse_fraction(text, i, nanos)) return false;
        } else if (digit_at(text, *i) >= 0 && *i < text.len) {
            return false;                         // trailing digits after seconds
        }
    } else if (*i < text.len && (text[*i] == '.' || text[*i] == ',')) {
        // Fractional minute or hour — invalid per ISO 8601.
        return false;
    }
    return true;
}

// `Z`/`z` or `±HH[:MM[:SS[.frac]]]`. No offset is also fine. If
// `out_offset_kind` is non-null it receives the kind of offset actually
// consumed (NONE if absent).
fn bool parse_offset(char[] text, usz* i, OffsetKind* out_offset_kind) {
    if (out_offset_kind != null) *out_offset_kind = OffsetKind.NONE;
    if (*i >= text.len) return true;
    if (text[*i] == 'Z' || text[*i] == 'z') {
        if (out_offset_kind != null) *out_offset_kind = OffsetKind.Z;
        *i += 1;
        return true;
    }
    if (text[*i] != '+' && text[*i] != '-') return true;
    *i += 1;
    int h, mi, s;
    bool has_s;
    long nanos;
    if (!parse_two_digits(text, i, &h)) return false;
    bool sep = false;
    if (*i < text.len && text[*i] == ':') { sep = true; *i += 1; }
    else if (digit_at(text, *i) < 0) {
        if (out_offset_kind != null) *out_offset_kind = OffsetKind.NUMERIC;
        return h <= 23;
    }
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
            if (*i < text.len && (text[*i] == '.' || text[*i] == ',')) {
                if (!parse_fraction(text, i, &nanos)) return false;
            } else if (digit_at(text, *i) >= 0 && *i < text.len) {
                return false;
            }
        }
    }
    if (out_offset_kind != null) *out_offset_kind = OffsetKind.NUMERIC;
    return h <= 23;
}

// A trailing `[...]` annotation block. `out_cal_start/len` receive the first
// calendar annotation's value range (for CallerCalendar resolution). Per ISO
// 8601 / Temporal grammar:
//   * annotation keys are lowercase-only (uppercase → RangeError)
//   * an unknown key with the critical flag is a syntax error
//   * more than one u-ca= annotation is rejected if any annotation in the
//     sequence carries the critical flag (else the second is silently dropped)
//   * more than one time-zone annotation is a syntax error unconditionally
// `allow_sub_minute_tz`: when true (default for Instant / DateTime /
// Duration parsers), the bracket may contain a `±HH:MM:SS.fffffffff`
// sub-minute offset. ZonedDateTime passes `false` to enforce its narrower
// grammar (no sub-minute time-zone identifiers).
fn bool parse_annotations(char[] text, usz* i, usz* out_cal_start, usz* out_cal_len, usz* out_tz_start, usz* out_tz_len, bool allow_sub_minute_tz = true) {
    int count = 0;
    int tz_count = 0;
    bool cal_seen = false;
    bool tz_seen = false;
    bool critical_seen = false;
    *out_cal_start = 0;
    *out_cal_len = 0;
    if (out_tz_start != null) *out_tz_start = 0;
    if (out_tz_len != null) *out_tz_len = 0;
    while (*i < text.len) {
        if (text[*i] != '[') return false;
        if (count >= 9) return false;
        *i += 1;
        bool critical = false;
        if (*i < text.len && text[*i] == '!') { critical = true; *i += 1; critical_seen = true; }

        usz key_start = *i;
        while (*i < text.len && text[*i] != '=' && text[*i] != ']') {
            char c = text[*i];
            // Annotation content is parsed either as `key=value` (keys are
            // letters/digits/`-_+./`) or as a bare time-zone identifier. The
            // time-zone case additionally allows `:` so that UTC-offset
            // annotations like `[+01:30]` parse as well as IANA names like
            // `[America/Vienna]`.
            bool ok = ascii::is_lower(c) || ascii::is_upper(c) || ascii::is_digit(c) ||
                      c == '-' || c == '_' || c == '+' || c == '.' || c == '/' || c == ':';
            if (!ok) return false;
            *i += 1;
        }
        usz key_end = *i;
        if (key_end == key_start) return false;

        if (*i < text.len && text[*i] == '=') {
            *i += 1;
            // ISO 8601 §3.8 / Temporal grammar: annotation keys in `key=value`
            // form must be all lowercase. A capitalized or mixed-case key
            // (recognized or not) is a syntax error. Bare time-zone
            // identifiers like `[UTC]` are read below without this rule,
            // since time-zone names are case-sensitive in IANA / tz database.
            for (usz k = key_start; k < key_end; k++) {
                if (ascii::is_upper(text[k])) return false;
                // `:` is allowed only in bare time-zone annotations, not in
                // `key=value` keys.
                if (text[k] == ':') return false;
            }
            // Only u-ca is a recognized key; unknown lower-case keys are
            // tolerated per the spec's annotation grammar. Match the key
            // prefix (4 chars, before the `=` separator) so a key like
            // `u-ca=...` is recognized even when `key_end` includes the
            // separator.
            bool is_uca = (key_end - key_start) >= 4 && text[key_start..key_start + 3] == "u-ca";
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
                // Per spec: a second u-ca= is a syntax error only when the
                // critical flag appears anywhere in the sequence (this entry
                // or a sibling). Without any critical flag the second
                // occurrence is silently dropped, leaving the first value
                // in `out_cal_start/len`.
                if (cal_seen && (critical || critical_seen)) return false;
                if (!cal_seen) { *out_cal_start = v_start; *out_cal_len = *i - v_start; }
                cal_seen = true;
            } else {
                // Unknown key: a critical flag forces a syntax error,
                // otherwise the annotation is tolerated.
                if (critical) return false;
            }
        } else {
            // Time-zone identifier annotation: at most one occurrence.
            tz_count += 1;
            if (tz_count > 1) return false;
            // Per ISO 8601 / Temporal grammar `TimeZoneAnnotation`, the
            // content of a bracketed time-zone identifier is a
            // `TimeZoneIdentifier`: either an IANA name (`Alpha …`) or
            // a `UTCOffset[~SubMinutePrecision]`. The latter permits
            // `±HH`, `±HHMM`, `±HH:MM`, or — when sub-minute precision
            // is allowed — `±HH:MM:SS[.fffffffff]`. A trailing-zero
            // fraction (e.g. `+01:35:00.000000000`) is a syntax error,
            // so reject fractions whose last digit is zero. ZDT forbids
            // sub-minute time-zone identifiers per its narrower grammar,
            // so when `!allow_sub_minute_tz` we reject anything past
            // minutes (a second `:`, a `.`, or a `,`).
            if (key_end - key_start >= 1 && (text[key_start] == '+' || text[key_start] == '-')) {
                usz colon_count = 0;
                usz dot_pos = 0;
                bool has_dot = false;
                for (usz k = key_start; k < key_end; k++) {
                    char c = text[k];
                    if (c == ':') {
                        colon_count += 1;
                        if (colon_count > 2) return false;
                    } else if (c == '.') {
                        if (has_dot) return false;
                        has_dot = true;
                        dot_pos = k;
                    } else if (c == ',') {
                        return false;
                    }
                }
                usz main_end = has_dot ? dot_pos : key_end;
                usz tz_len = main_end - key_start;
                if (colon_count == 0 && tz_len > 5) return false;
                if (!allow_sub_minute_tz) {
                    if (colon_count >= 2) return false;
                    if (has_dot) return false;
                }
                // Trailing-zero check on the fraction: if the fraction
                // exists, the last fraction digit must be non-zero.
                if (has_dot) {
                    if (text[key_end - 1] == '0') return false;
                }
            }
            // Critical flag is tolerated (has no effect for ZonedDateTime).
            if (!tz_seen && out_tz_start != null) {
                *out_tz_start = key_start;
                *out_tz_len = key_end - key_start;
                tz_seen = true;
            }
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
    if (out.month < 1 || out.month > 12) return false;
    if (date_sep) {
        if (i >= len || text[i] != '-') return false;
        i += 1;
    }
    if (!parse_two_digits(text, &i, &out.day)) return false;
    if (out.day < 1 || out.day > days_in_month(out.year, out.month)) return false;

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
        if (out.hour > 23) return false;
        if (out.minute > 59) return false;
        if (out.second > 60) return false;
        if (out.second == 60) out.second = 59;
        if (!parse_offset(text, &i, &out.offset_kind)) return false;
    }

    // --- Annotations ---
    if (i < len) {
        if (text[i] != '[') return false;
        usz cal_start, cal_len;
        if (!parse_annotations(text, &i, &cal_start, &cal_len, null, null)) return false;
        if (cal_len != 0) {
            char[] cal = text[cal_start:cal_len];
            if (!ci_equals(cal, "iso8601")) return false;
        }
        if (i != len) return false;
    }
    return true;
}

// Parse a year-month string (`YYYY-MM`, optional basic `YYYYMM`, optional
// `±YYYYYY-MM`). Used by Temporal.PlainYearMonth.from when the input is a
// string. Per the Temporal grammar `TemporalYearMonthString` (an extension
// of `AnnotatedDateTime[~Zoned]` for year-month contexts), the optional
// `-DD` day, the optional `T<time>` and the optional `±HH:MM` offset are
// all accepted and discarded — only year and month are kept. PlainYearMonth
// never permits a `Z` designator (it is grammar-forbidden); the caller
// rejects `offset_kind == Z` after a successful parse.
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

    // Month. Optional `-` separator disambiguates `YYYY-MM` (extended)
    // from `YYYYMM` (basic). Per the grammar's `monthpart` (`0[1-9]|1[0-2]`),
    // only 01..12 are valid; anything else is a parse failure (not a
    // constrain-time clamp).
    bool date_sep = false;
    if (i < len && text[i] == '-') { date_sep = true; i += 1; }
    if (!parse_two_digits(text, &i, &out.month)) return false;
    if (out.month < 1 || out.month > 12) return false;

    // Optional day. Two forms:
    //   * Extended: `-DD` immediately following.
    //   * Basic:    `DD` (two more digits) immediately following, but
    //     only when what follows is a `T`/`t` time designator, an
    //     annotation bracket, or end-of-string. A bare `YYYYMMDD` with
    //     no further grammar continuation is rejected.
    // `had_day` distinguishes the short `TemporalYearMonthString` form
    // (bare `YYYY-MM`, which per the grammar never carries a time
    // component) from the full `AnnotatedDateTime` fallback (which
    // requires a day and may carry `T<time>` + offset).
    bool had_day = false;
    if (date_sep) {
        if (i < len && text[i] == '-' && digit_at(text, i + 1) >= 0) {
            i += 1;
            int _d;
            if (!parse_two_digits(text, &i, &_d)) return false;
            had_day = true;
        }
    } else if (i + 1 < len && digit_at(text, i) >= 0 && digit_at(text, i + 1) >= 0
               && (i + 2 >= len
                   || text[i + 2] == 'T' || text[i + 2] == 't'
                   || text[i + 2] == ' ' || text[i + 2] == '[')) {
        int _d;
        if (!parse_two_digits(text, &i, &_d)) return false;
        had_day = true;
    }

    // Optional `T<time>` and `±HH:MM` offset, all discarded. `Z` is
    // forbidden by the grammar; we propagate `offset_kind == Z` and let
    // the caller throw RangeError. Only reachable when a day was present:
    // the short year-month form (no day) never carries a time component.
    if (had_day && i < len && (text[i] == 'T' || text[i] == 't' || text[i] == ' ')) {
        i += 1;
        int _h, _mi, _s;
        long _n;
        if (!parse_time(text, &i, &_h, &_mi, &_s, &_n)) return false;
        if (_h == 24) {
            if (_mi != 0 || _s != 0 || _n != 0) return false;
        }
        if (_mi > 59) return false;
        if (_s > 60) return false;
        if (!parse_offset(text, &i, &out.offset_kind)) return false;
    }

    if (i < len) {
        if (text[i] != '[') return false;
        usz cal_start, cal_len;
        if (!parse_annotations(text, &i, &cal_start, &cal_len, null, null)) return false;
        if (cal_len != 0) {
            char[] cal = text[cal_start:cal_len];
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

// Parse a month-day string (`--MM-DD` per ISO 8601, or bare `MM-DD`). Used
// by Temporal.PlainMonthDay.from when the input is a bare month-day string;
// the full `YYYY-MM-DDT…` form is parsed by `parse_iso_date_string` instead.
// The year field is left at 0; the reference year default in the caller
// (1972) fills it in.
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
    if (out.month < 1 || out.month > 12) return false;

    if (i >= len) return false;
    if (text[i] == '-') {
        i += 1;
        if (!parse_two_digits(text, &i, &out.day)) return false;
    } else {
        // Compact MMDD format (no separator between month and day).
        if (!parse_two_digits(text, &i, &out.day)) return false;
    }
    // Reference year 1972 for leap-year day-count (Feb 29 is valid).
    if (out.day < 1 || out.day > days_in_month(1972, out.month)) return false;
    if (i < len) {
        if (text[i] != '[') return false;
        usz cal_start, cal_len;
        if (!parse_annotations(text, &i, &cal_start, &cal_len, null, null)) return false;
        if (cal_len != 0) {
            char[] cal = text[cal_start:cal_len];
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

fn bool is_ambiguous_plain_time_string(char[] text) {
    usz end = text.len;
    for (usz k = 0; k < text.len; k++) {
        if (text[k] == '[') { end = k; break; }
    }
    char[] s = text[:end];
    // YYYY-MM: 4 digits, '-', 2 digits
    if (s.len == 7 && ascii::is_digit(s[0]) && ascii::is_digit(s[1]) && ascii::is_digit(s[2]) && ascii::is_digit(s[3]) &&
        s[4] == '-' && ascii::is_digit(s[5]) && ascii::is_digit(s[6])) {
        int m = (int)(s[5] - '0') * 10 + (int)(s[6] - '0');
        if (m >= 1 && m <= 12) return true;
    }
    // YYYYMM: 6 digits
    if (s.len == 6 && ascii::is_digit(s[0]) && ascii::is_digit(s[1]) && ascii::is_digit(s[2]) &&
        ascii::is_digit(s[3]) && ascii::is_digit(s[4]) && ascii::is_digit(s[5])) {
        int m = (int)(s[4] - '0') * 10 + (int)(s[5] - '0');
        if (m >= 1 && m <= 12) return true;
    }
    // MM-DD: 2 digits, '-', 2 digits
    if (s.len == 5 && ascii::is_digit(s[0]) && ascii::is_digit(s[1]) && s[2] == '-' &&
        ascii::is_digit(s[3]) && ascii::is_digit(s[4])) {
        int m = (int)(s[0] - '0') * 10 + (int)(s[1] - '0');
        int d = (int)(s[3] - '0') * 10 + (int)(s[4] - '0');
        if (m >= 1 && m <= 12 && d >= 1 && d <= 31) return true;
    }
    // MMDD: 4 digits
    if (s.len == 4 && ascii::is_digit(s[0]) && ascii::is_digit(s[1]) &&
        ascii::is_digit(s[2]) && ascii::is_digit(s[3])) {
        int m = (int)(s[0] - '0') * 10 + (int)(s[1] - '0');
        int d = (int)(s[2] - '0') * 10 + (int)(s[3] - '0');
        int[13] max_days = { 0, 31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
        if (m >= 1 && m <= 12 && d >= 1 && d <= max_days[m]) return true;
    }
    return false;
}

// Parse a time-only ISO 8601 string (optional `T`/`t` time designator, then
// `HH[:MM[:SS[.frac]]]`, optional `±HH:MM` offset). Used by
// Temporal.PlainTime.from when the input is a bare time string. Per the
// grammar `AnnotatedTime`, the `Z` designator is forbidden — only a numeric
// UTC offset may follow the time component; the offset itself is silently
// discarded by the caller.
fn bool parse_iso_time_string(char[] text, ParsedIsoDateTime* out) {
    usz i = 0;
    bool has_t = false;
    // Optional `T`/`t` designator before the time component (per the
    // grammar's first alternative `TimeDesignator Time …`).
    if (i < text.len && (text[i] == 'T' || text[i] == 't')) {
        has_t = true;
        i += 1;
    }
    if (!has_t && is_ambiguous_plain_time_string(text)) return false;
    if (!parse_time(text, &i, &out.hour, &out.minute, &out.second, &out.nanos)) return false;
    out.has_time = true;
    if (out.hour == 24) {
        if (out.minute != 0 || out.second != 0 || out.nanos != 0) return false;
        out.hour = 0;
    }
    if (out.hour > 23) return false;
    if (out.minute > 59) return false;
    if (out.second > 60) return false;
    if (out.second == 60) out.second = 59;
    if (!parse_offset(text, &i, &out.offset_kind)) return false;
    if (i < text.len) {
        if (text[i] != '[') return false;
        usz cal_start, cal_len;
        if (!parse_annotations(text, &i, &cal_start, &cal_len, null, null)) return false;
        if (i != text.len) return false;
    }
    out.year = 0;
    out.month = 1;
    out.day = 1;
    return true;
}

// Result of `parse_iso_instant_string`. The caller computes the UTC ns from
// these fields: `epoch_days * 86400 * 1e9 + sec_of_day * 1e9 + (nanos -
// offset_nanos) - offset_seconds * 1e9`. The `offset_nanos` field carries the
// sub-minute fractional part of the parsed offset (0 when none).
struct ParsedIsoInstant {
    long y;
    int  m;
    int  d;
    int  hour;
    int  minute;
    int  second;
    long nanos;
    long offset_seconds;
    long offset_nanos;
}

// Parse a full date+time ISO string with a mandatory `Z` or offset. Plain
// date or plain time without an offset is rejected — an Instant must be a
// moment. Used by ToTemporalInstant for Instant.since/Instant.until.
fn bool parse_iso_instant_string(char[] text, ParsedIsoInstant* out) {
    usz len = text.len;
    usz i = 0;

    // --- Date: year / month / day (extended form `YYYY-MM-DD` or basic
    // `YYYYMMDD`; signed `±YYYYYY-MM-DD` accepted) ---
    long sign = 1;
    bool signed_year = false;
    if (i < len && (text[i] == '+' || text[i] == '-')) {
        if (text[i] == '-') sign = -1;
        signed_year = true;
        i += 1;
    }
    usz y_start = i;
    while (digit_at(text, i) >= 0 && (i - y_start) < (usz)(signed_year ? 6 : 4)) i += 1;
    usz y_digits = i - y_start;
    if (y_digits != 4 && !(signed_year && y_digits == 6)) return false;
    long y = 0;
    for (usz k = y_start; k < i; k++) y = y * 10 + (long)digit_at(text, k);
    if (sign < 0 && y == 0) return false;
    out.y = sign * y;

    bool date_sep = false;
    if (i < len && text[i] == '-') { date_sep = true; i += 1; }
    int month;
    if (!parse_two_digits(text, &i, &month)) return false;
    if (month < 1 || month > 12) return false;
    // Day: extended form requires another '-' before the two digits, basic
    // form requires the next two chars to be digits.
    if (i < len && text[i] == '-') {
        if (!date_sep) return false;
        i += 1;
    } else {
        if (date_sep) return false;
        // Basic form: require two more digits, no separator before time.
        if (!parse_two_digits(text, &i, &month)) return false; // would re-read; bail
        // Actually, rewind and parse the day as the next two digits.
        i -= 2;
    }
    int day;
    if (!parse_two_digits(text, &i, &day)) return false;

    // --- Time separator (T or space) ---
    if (i >= len || (text[i] != 'T' && text[i] != 't' && text[i] != ' ')) return false;
    i += 1;

    int hour, mi, s;
    long nanos;
    if (!parse_time(text, &i, &hour, &mi, &s, &nanos)) return false;
    if (hour == 24) {
        if (mi != 0 || s != 0 || nanos != 0) return false;
        hour = 0;
    }
    if (hour > 23) return false;
    if (mi > 59) return false;
    if (s > 60) return false;
    if (s == 60) s = 59;

    // --- Offset: required for an Instant ---
    if (i >= len) return false;
    long off_sec = 0;
    long off_nanos = 0;
    if (text[i] == 'Z' || text[i] == 'z') {
        i += 1;
    } else if (text[i] == '+' || text[i] == '-') {
        bool negative = (text[i] == '-');
        i += 1;
        int oh;
        int omi = 0;
        if (!parse_two_digits(text, &i, &oh)) return false;
        bool sep = false;
        if (i < len && text[i] == ':') { sep = true; i += 1; }
        else if (digit_at(text, i) < 0) { /* ±HH, no minutes */ }
        if (digit_at(text, i) >= 0) {
            if (!parse_two_digits(text, &i, &omi)) return false;
            long extra_sec = 0;
            // optional :SS[.frac] in extended offset form (±HH:MM:SS.fff)
            if (i < len && text[i] == ':' && sep) {
                i += 1;
                int os;
                if (!parse_two_digits(text, &i, &os)) return false;
                if (i < len && (text[i] == '.' || text[i] == ',')) {
                    if (!parse_fraction(text, &i, &off_nanos)) return false;
                }
                extra_sec = (long)os;
            } else if (i < len && (text[i] == '.' || text[i] == ',') && !sep) {
                // basic offset form ±HHMM.frac or ±HH.frac — sub-minute only
                // after HHMM; an HH-only basic offset cannot carry a fraction.
                i += 1;
                if (!parse_fraction(text, &i, &off_nanos)) return false;
            } else if (!sep && i < len && digit_at(text, i) >= 0) {
                // basic offset form ±HHMMSS.frac — SS attached directly.
                int os;
                if (!parse_two_digits(text, &i, &os)) return false;
                if (i < len && (text[i] == '.' || text[i] == ',')) {
                    if (!parse_fraction(text, &i, &off_nanos)) return false;
                }
                extra_sec = (long)os;
            }
            if (oh > 23) return false;
            long off = (long)oh * 3600 + (long)omi * 60 + extra_sec;
            off_sec = negative ? -off : off;
        } else {
            if (oh > 23) return false;
            long off = (long)oh * 3600;
            off_sec = negative ? -off : off;
        }
    } else {
        return false;
    }

    if (i < len) {
        if (text[i] != '[') return false;
        usz cal_start, cal_len;
        // A time-zone annotation's identifier follows `TimeZoneIdentifier`,
        // whose UTC offset form never carries sub-minute precision. Instant
        // accepts sub-minute in the date-time *offset*, but not in the
        // bracketed zone annotation.
        if (!parse_annotations(text, &i, &cal_start, &cal_len, null, null, false)) return false;
        // Instant has no calendar component, so any u-ca= annotation (including
        // critical or non-iso8601) is silently ignored. parse_annotations has
        // already enforced the uppercase-rejection and critical-unknown-key
        // rules for grammar validity; only the calendar value is left to the
        // caller, and the Instant caller ignores it.
        if (i != len) return false;
    }

    out.m = month;
    out.d = day;
    out.hour = hour;
    out.minute = mi;
    out.second = s;
    out.nanos = nanos;
    out.offset_seconds = off_sec;
    out.offset_nanos = off_nanos;
    return true;
}

// Result of parse_iso_zoneddatetime_string.
struct ParsedIsoZonedDateTime {
    long year;
    int  month;
    int  day;
    int  hour;
    int  minute;
    int  second;
    long nanos;
    long offset_seconds;
    // Time zone identifier from bracket annotation. Empty if no annotation.
    char[] timezone;
    // True iff the date-time portion carried an explicit offset (`Z`/`±HH:MM`).
    // Bracket-offset arithmetic only applies when this is false.
    bool has_offset;
    // True iff the offset was the `Z` designator (not `±HH:MM`). Used to
    // skip the offset-vs-bracket agreement check: Z is exact-time, not wall.
    bool is_z;
}

// Parse a ZonedDateTime ISO string: date + time + mandatory offset + optional
// time zone annotation.
fn bool parse_iso_zoneddatetime_string(char[] text, ParsedIsoZonedDateTime* out) {
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

    // --- Time separator (T or space): optional when the bracket annotation
    // follows directly after the date. Per spec `TemporalZonedDateTimeString`
    // is `DateTime[+Z, ?TimeRequired] TimeZoneAnnotation Annotations_opt`,
    // so a bare date like `1970-01-01[UTC]` is a valid ZDT (midnight at
    // the bracketed zone).
    bool has_time = false;
    if (i < len && (text[i] == 'T' || text[i] == 't' || text[i] == ' ')) {
        i += 1;
        has_time = true;
    } else if (i >= len || text[i] != '[') {
        // No `T` and no immediate bracket — reject.
        return false;
    }
    if (has_time) {
        if (!parse_time(text, &i, &out.hour, &out.minute, &out.second, &out.nanos)) return false;
        if (out.hour == 24) {
            if (out.minute != 0 || out.second != 0 || out.nanos != 0) return false;
            out.hour = 0;
        }
        if (out.hour > 23) return false;
        if (out.minute > 59) return false;
        if (out.second > 60) return false;
        if (out.second == 60) out.second = 59;
    } else {
        // No time: default to midnight.
        out.hour = 0;
        out.minute = 0;
        out.second = 0;
        out.nanos = 0;
    }

    // --- Offset: optional for ZonedDateTime when a bracket annotation follows ---
    // If next char is '[', there's no offset — just a time zone annotation.
    if (i >= len) return false;
    bool has_offset = false;
    bool is_z = false;
    if (text[i] == 'Z' || text[i] == 'z') {
        out.offset_seconds = 0;
        i += 1;
        has_offset = true;
        is_z = true;
    } else if (text[i] == '+' || text[i] == '-') {
        bool negative = (text[i] == '-');
        i += 1;
        int oh;
        int omi = 0;
        if (!parse_two_digits(text, &i, &oh)) return false;
        bool sep = false;
        if (i < len && text[i] == ':') {
            // Extended form: minutes are in `+HH:MM`. The next token must
            // be exactly two digits; any other character means we're done.
            sep = true;
            i += 1;
            if (i + 1 >= len || digit_at(text, i) < 0 || digit_at(text, i + 1) < 0) return false;
            if (!parse_two_digits(text, &i, &omi)) return false;
        } else if (digit_at(text, i) >= 0) {
            // Basic-form ±HHMM...: could be ±HHMM or ±HHMMSS.
            usz j = i;
            while (j < len && digit_at(text, j) >= 0) j += 1;
            usz digs = j - i;
            if (digs == 2) {
                if (!parse_two_digits(text, &i, &omi)) return false;
            } else if (digs == 4) {
                if (!parse_two_digits(text, &i, &omi)) return false;
                int osec_b;
                if (!parse_two_digits(text, &i, &osec_b)) return false;
                if (osec_b > 59) return false;
                // Optional fraction after basic-form seconds: `+HHMMSS,5`.
                if (i < len && (text[i] == '.' || text[i] == ',')) {
                    i += 1;
                    usz fstart = i;
                    while (i < len && digit_at(text, i) >= 0) i += 1;
                    usz fdigs = i - fstart;
                    if (fdigs == 0 || fdigs > 9) return false;
                    long frac = 0;
                    for (usz k = fstart; k < i; k++) frac = frac * 10 + (long)digit_at(text, k);
                    long mult = 1;
                    for (usz k = 0; k < (9 - fdigs); k++) mult *= 10;
                    out.nanos = frac * mult;
                }
            } else {
                return false;
            }
        }
        // Extended form `+HH:MM[:SS[.frac]]`: only when we used a `:` separator
        // above; basic-form `+HHMM` is handled in the previous branch and
        // can't be followed by an extended `:SS` segment.
        int osec = 0;
        long ofrac_ns = 0;
        if (sep && i < len && text[i] == ':') {
            i += 1;
            if (!parse_two_digits(text, &i, &osec)) return false;
            if (osec > 59) return false;
            if (i < len && (text[i] == '.' || text[i] == ',')) {
                i += 1;
                usz fstart = i;
                while (i < len && digit_at(text, i) >= 0) i += 1;
                usz fdigs = i - fstart;
                if (fdigs == 0 || fdigs > 9) return false;
                long frac = 0;
                for (usz k = fstart; k < i; k++) frac = frac * 10 + (long)digit_at(text, k);
                long mult = 1;
                for (usz k = 0; k < (9 - fdigs); k++) mult *= 10;
                ofrac_ns = frac * mult;
            }
        }
        if (oh > 23) return false;
        long off = (long)oh * 3600 + (long)omi * 60 + (long)osec;
        out.offset_seconds = negative ? -off : off;
        out.nanos += ofrac_ns;       // sub-minute fractional offset contributed here
        has_offset = true;
    } else if (text[i] == '[') {
        // No offset — will be disambiguated from the time zone annotation.
        out.offset_seconds = 0;
    } else {
        return false;
    }

    // --- Annotations (required) ---
    // ZonedDateTime requires a `[TimeZoneIdentifier]` annotation per the spec
    // grammar (TemporalZonedDateTimeString). An offset alone (e.g. `Z` or
    // `+01:00` with no bracket) is not a valid ZDT string; the test262 case
    // `zoneddatetime-string.js` rejects e.g. `1970-01-01T00:00Z` with
    // RangeError precisely because no zone annotation was supplied.
    if (i >= len || text[i] != '[') return false;
    usz cal_start, cal_len, tz_start, tz_len;
    if (!parse_annotations(text, &i, &cal_start, &cal_len, &tz_start, &tz_len, false)) return false;
    if (tz_len == 0) return false;
    if (cal_len != 0) {
        char[] cal = text[cal_start:cal_len];
        if (!ci_equals(cal, "iso8601")) return false;
    }
    out.timezone = text[tz_start:tz_len];
    out.has_offset = has_offset;
    out.is_z = is_z;
    if (i != len) return false;
    return true;
}
