#!/usr/bin/env python3
"""Add ZonedDateTime parser to parse.c3 and update annotation calls."""

with open('src/lib/temporal/parse.c3', 'r') as f:
    content = f.read()

# 1. Update parse_annotations signature to include timezone output
content = content.replace(
    'fn bool parse_annotations(char[] text, usz* i, usz* out_cal_start, usz* out_cal_len) {',
    'fn bool parse_annotations(char[] text, usz* i, usz* out_cal_start, usz* out_cal_len, usz* out_tz_start, usz* out_tz_len) {',
)

# 2. Add tz_seen and tz initialization inside parse_annotations
content = content.replace(
    '    int count = 0;\n    int tz_count = 0;\n    bool cal_seen = false;\n    *out_cal_start = 0;\n    *out_cal_len = 0;',
    '    int count = 0;\n    int tz_count = 0;\n    bool cal_seen = false;\n    bool tz_seen = false;\n    *out_cal_start = 0;\n    *out_cal_len = 0;\n    *out_tz_start = 0;\n    *out_tz_len = 0;',
)

# 3. Add tz extraction in the timezone annotation branch
old_tz_branch = """        } else {
            // Time-zone identifier annotation: at most one occurrence.
            tz_count += 1;
            if (tz_count > 1) return false;
            if (critical) return false;   // a critical annotation must be a key/value pair
        }"""
new_tz_branch = """        } else {
            // Time-zone identifier annotation: at most one occurrence.
            tz_count += 1;
            if (tz_count > 1) return false;
            if (critical) return false;   // a critical annotation must be a key/value pair
            if (!tz_seen) { *out_tz_start = key_start; *out_tz_len = key_end - key_start; tz_seen = true; }
        }"""
content = content.replace(old_tz_branch, new_tz_branch)

# 4. Update ALL callers of parse_annotations to pass the new params
# Pattern: parse_annotations(text, &i, &cal_start, &cal_len)
old_call = 'parse_annotations(text, &i, &cal_start, &cal_len)'
new_call = '{ usz _tz0 = 0; usz _tz1 = 0; parse_annotations(text, &i, &cal_start, &cal_len, &_tz0, &_tz1) }'
content = content.replace(old_call, new_call)

# 5. Append ZonedDateTime parser at the end
zdt_parser = """

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

    // --- Time separator (T or space) ---
    if (i >= len || (text[i] != 'T' && text[i] != 't' && text[i] != ' ')) return false;
    i += 1;

    if (!parse_time(text, &i, &out.hour, &out.minute, &out.second, &out.nanos)) return false;
    if (out.hour == 24) {
        if (out.minute != 0 || out.second != 0 || out.nanos != 0) return false;
        out.hour = 0;
    }
    if (out.minute > 59) return false;
    if (out.second > 60) return false;
    if (out.second == 60) out.second = 59;

    // --- Offset: required for ZonedDateTime ---
    if (i >= len) return false;
    if (text[i] == 'Z' || text[i] == 'z') {
        out.offset_seconds = 0;
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
        }
        if (oh > 23) return false;
        long off = (long)oh * 3600 + (long)omi * 60;
        out.offset_seconds = negative ? -off : off;
    } else {
        return false;
    }

    // --- Annotations ---
    out.timezone = text[0..0];  // empty by default
    if (i < len) {
        if (text[i] != '[') return false;
        usz cal_start, cal_len, tz_start, tz_len;
        if (!parse_annotations(text, &i, &cal_start, &cal_len, &tz_start, &tz_len)) return false;
        if (cal_len != 0) {
            char[] cal = text[cal_start..cal_start + cal_len];
            if (!ci_equals(cal, "iso8601")) return false;
        }
        if (tz_len != 0) {
            out.timezone = text[tz_start..tz_start + tz_len];
        }
        if (i != len) return false;
    }
    return true;
}
"""

content += zdt_parser

with open('src/lib/temporal/parse.c3', 'w') as f:
    f.write(content)
print("Patched parse.c3")
