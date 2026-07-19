/// Date constructor and Date.prototype methods.
module duktape::builtins;
import duktape::types;
import std::math;
import std::io;
import duktape::env;
import duktape::vm;

import duktape::heap;
import duktape::hstring;
import duktape::hobject;
import std::time;

/// ES2015+ §21.4.1.14 MakeTime: ((h*msPerHour + m*msPerMinute) + s*msPerSecond) + milli,
/// evaluated in exact left-to-right IEEE-754 order. Implemented in a separate
/// C translation unit so it isn't affected by the engine-wide relaxed
/// fp-math build setting (which otherwise lets the optimizer reassociate
/// this chain and produce different rounding for huge operands).
extern fn double duktape_date_make_time(double hour, double minute, double second, double ms);

/// ES2015+ §21.4.1.15 MakeDate: day * msPerDay + timeWithinDay. Same
/// separate-translation-unit trick as duktape_date_make_time — otherwise the
/// multiply+add gets fused into a single-rounding FMA under relaxed fp-math.
extern fn double duktape_date_make_date(double day, double time_within_day);

// ============================================================================
// Date constructor and methods (ES5 §15.9)
// ============================================================================

/// ECMAScript epoch: 1970-01-01 00:00:00 UTC.
const long EPOCH_YEAR = 1970;

/// Helper: get current time in milliseconds since epoch.
fn double date_now_ms() {
    // time::now() is microseconds since the Unix epoch.
    return (double)((long)time::now()) / 1000.0;
}

/// Convert a Unix time (seconds since 1970-01-01 UTC, may be negative) into
/// proleptic-Gregorian UTC broken-down fields. Pure integer calendar math
/// (Howard Hinnant's days-from-civil), so it is reliable across the full
/// ECMAScript date range without relying on libc's historical tzdata — the
/// same rationale the surrounding code already applied to gmtime_r.
///
/// Outputs match the previous gmtime_r usage: `year` is the full year,
/// `month` is 0-based (0=January), `wday` is 0-based with 0=Sunday.
fn void civil_from_seconds(long secs, long* year, long* month, long* day,
                           long* wday, long* hour, long* minute, long* second) {
    // Split into whole days and the second-of-day, flooring toward -inf so
    // negative epoch times land on the correct civil day.
    long days = secs / 86400;
    long rem  = secs % 86400;
    if (rem < 0) { rem += 86400; days -= 1; }

    *hour   = rem / 3600;
    *minute = (rem % 3600) / 60;
    *second = rem % 60;

    // Day of week: 1970-01-01 was a Thursday (4). Euclidean mod keeps it 0..6.
    long w = (days % 7 + 4) % 7;
    if (w < 0) { w += 7; }
    *wday = w;

    // days-from-civil, inverted (Hinnant). Shift epoch to 0000-03-01.
    long z = days + 719468;
    long era = (z >= 0 ? z : z - 146096) / 146097;
    long doe = z - era * 146097;                       // [0, 146096]
    long yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;  // [0, 399]
    long y = yoe + era * 400;
    long doy = doe - (365 * yoe + yoe / 4 - yoe / 100); // [0, 365]
    long mp = (5 * doy + 2) / 153;                      // [0, 11] (Mar=0)
    long d = doy - (153 * mp + 2) / 5 + 1;              // [1, 31]
    long m = mp < 10 ? mp + 3 : mp - 9;                 // [1, 12]

    *year  = y + (m <= 2 ? 1 : 0);
    *month = m - 1;                                     // 0-based
    *day   = d;
}

/// Helper: get the time value from a Date object, or NaN if not a Date.
/// Kept for internal use (e.g. JSON serialization paths that don't need throw).
fn double date_get_time_value(TVal* val) {
    if (val.is_object() && val.get_heapptr() != null) {
        HObject* obj = (HObject*)val.get_heapptr();
        // Date.prototype is a DATE object but lacks the [[DateValue]] slot;
        // IS_DATE_PROTO flag distinguishes it. For non-Date-prototype DATE
        // objects, return the stored time value (NaN is a valid Date value).
        if (obj.get_class() == hobject::ObjClass.DATE && !obj.flags.is_date_proto &&
            ((*obj.extra_ptr()).prim.primitive_value.is_number() || (*obj.extra_ptr()).prim.primitive_value.is_fastint())) {
            return (*obj.extra_ptr()).prim.primitive_value.get_number_or_fastint();
        }
    }
    return double::nan;
}

/// ES5 §15.9.1.1 thisTimeValue(value): throw TypeError if not a Date object.
/// A Date instance always has a [[DateValue]] internal slot; Date.prototype
/// is a DATE object but does NOT have the slot, so the engine flags it via
/// the `is_date_proto` ObjClass flag below.
fn double date_this_time_value(BuiltinContext* ctx, TVal* val) {
    if (val.is_object() && val.get_heapptr() != null) {
        HObject* obj = (HObject*)val.get_heapptr();
        // Date.prototype is a DATE object that lacks [[DateValue]]; it carries
        // the IS_DATE_PROTO flag. All other DATE objects are real Date
        // instances and may hold NaN as their time value.
        if (obj.get_class() == hobject::ObjClass.DATE && !obj.flags.is_date_proto &&
            ((*obj.extra_ptr()).prim.primitive_value.is_number() || (*obj.extra_ptr()).prim.primitive_value.is_fastint())) {
            return (*obj.extra_ptr()).prim.primitive_value.get_number_or_fastint();
        }
    }
    // Throw TypeError
    HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
    if (catch err_k = err_raw) { return double::nan; }
    HObject* err = err_raw;
    err.prototype = ctx.heap.type_err_proto;
    HString* msg_str = builtin_intern_string(ctx.heap, "this is not a Date");
    TVal msg_tv; msg_tv.set_string(msg_str);
    err.put_prop(builtin_intern_string(ctx.heap, "message"), msg_tv, hobject::PROP_FLAGS_WC);
    ctx.should_throw = true;
    ctx.throw_value.set_object(err);
    return double::nan;  // caller should return after this
}

/// Helper: convert local time components to epoch ms.
/// Treats the fields as a UTC civil date/time first (which is reliable for
/// any year via the days-from-civil algorithm), then subtracts the local
/// timezone offset sampled at that instant. This keeps every local<->UTC
/// conversion in the module consistent with getTimezoneOffset(), instead of
/// relying on mktime — whose -1 error sentinel is ambiguous with a
/// legitimate result and whose historical-tzdata handling is unreliable far
/// from the present.
fn double date_local_to_ms(long year, long month, long day,
                           long hour, long minute, long second, long ms) {
    double utc_ms = date_utc_to_ms(year, month, day, hour, minute, second, ms);
    long t_sec = (long)(utc_ms / 1000.0);
    long offset = date_tz_offset_seconds(t_sec);
    return utc_ms - (double)offset * 1000.0;
}

/// Compute the local timezone offset (in seconds, UTC minus local) for the
/// given epoch time, i.e. how far local time is ahead of UTC. Reinterprets
/// the localtime_r broken-down fields as a proleptic-Gregorian civil date
/// (via the same days-from-civil algorithm as date_utc_to_ms) rather than
/// timegm, since timegm's -1 error sentinel is ambiguous with a legitimate
/// result and its own historical-tzdata handling is unreliable far from the
/// present. This is correct across month/year boundaries (unlike a raw
/// tm_mday subtraction, which breaks whenever local and UTC dates fall in
/// different months).
fn long date_tz_offset_seconds(long t_sec) {
    // Source the local broken-down time from std::time (which performs the
    // platform localtime_r lookup), then reinterpret those wall-clock fields
    // through the engine's own proleptic-Gregorian date_utc_to_ms — same
    // arithmetic as before, without a direct libc call.
    TzDateTime local = datetime::from_time((Time)(t_sec * 1_000_000)).to_local();
    double local_ms = date_utc_to_ms((long)local.year, (long)local.month.ordinal,
        (long)local.day, (long)local.hour, (long)local.min,
        (long)local.sec, 0);
    return (long)(local_ms / 1000.0) - t_sec;
}

/// Break a time value into local wall-clock components, applying the
/// timezone offset arithmetically via gmtime_r rather than relying on
/// localtime_r's tzdata lookup directly. gmtime_r's proleptic Gregorian
/// calendar is reliable across the full date range, unlike localtime_r's
/// historical DST database.
fn void date_break_time_local_fields(double time_val, long* year, long* month, long* day,
                                     long* wday, long* hour, long* minute, long* second) {
    long t_sec = (long)(time_val / 1000.0);
    long offset = date_tz_offset_seconds(t_sec);
    long local_sec = t_sec + offset;
    civil_from_seconds(local_sec, year, month, day, wday, hour, minute, second);
}

/// Format a Date as a string like "Mon Jan 01 2024 12:00:00 GMT+0000".
fn usz date_format_to_string(double time_val, char* buf, usz buf_size) {
    // For NaN, return "Invalid Date"
    if (math::is_nan(time_val)) {
        return (usz)(io::bprintf(buf[:buf_size], "Invalid Date") ?? buf[:0]).len;
    }
    long t_sec = (long)(time_val / 1000.0);
    long year_val, month, day, wday, hour, minute, second;
    date_break_time_local_fields(time_val, &year_val, &month, &day, &wday, &hour, &minute, &second);

    long tz_seconds = date_tz_offset_seconds(t_sec);
    char tz_sign = '+';
    int offs_hours = (int)(tz_seconds / 3600);
    int offs_mins = (int)((tz_seconds / 60) % 60);
    if (tz_seconds < 0) {
        tz_sign = '-';
        offs_hours = -offs_hours;
        offs_mins = -offs_mins;
    }

    // String constants for weekday/month names
    char* wday_name;
    switch (wday) {
        case 0: wday_name = "Sun"; break;
        case 1: wday_name = "Mon"; break;
        case 2: wday_name = "Tue"; break;
        case 3: wday_name = "Wed"; break;
        case 4: wday_name = "Thu"; break;
        case 5: wday_name = "Fri"; break;
        case 6: wday_name = "Sat"; break;
        default: wday_name = "???"; break;
    }
    char* mon_name;
    switch (month) {
        case 0: mon_name = "Jan"; break;
        case 1: mon_name = "Feb"; break;
        case 2: mon_name = "Mar"; break;
        case 3: mon_name = "Apr"; break;
        case 4: mon_name = "May"; break;
        case 5: mon_name = "Jun"; break;
        case 6: mon_name = "Jul"; break;
        case 7: mon_name = "Aug"; break;
        case 8: mon_name = "Sep"; break;
        case 9: mon_name = "Oct"; break;
        case 10: mon_name = "Nov"; break;
        case 11: mon_name = "Dec"; break;
        default: mon_name = "???"; break;
    }

    // ES6 §21.4.3.4 ToDateString: positive years use 4-digit zero-padded,
    // negative years in [-9999, 0) use "-%04d" (5 chars with sign + 4 digits).
    // For abs(year) >= 10000 use the full integer width (no padding).
    char[24] year_str;
    if (year_val < 0 && year_val > -10000) {
        (void)io::bprintf(&year_str, "-%04d", -year_val);
    } else if (year_val <= -10000) {
        (void)io::bprintf(&year_str, "%d", year_val);
    } else {
        (void)io::bprintf(&year_str, "%04d", year_val);
    }

    return (usz)(io::bprintf(buf[:buf_size], "%s %s %02d %s %02d:%02d:%02d GMT%c%02d%02d",
        (ZString)wday_name, (ZString)mon_name,
        (int)day, (ZString)&year_str[0],
        (int)hour, (int)minute, (int)second,
        tz_sign, offs_hours, offs_mins) ?? buf[:0]).len;
}

/// Format a Date as ISO 8601 string (used by toJSON).
/// Uses UTC components. Large years (>=10000 or <=-9999) use expanded format.
fn usz date_format_iso(double time_val, char* buf, usz buf_size) {
    if (math::is_nan(time_val)) {
        return (usz)(io::bprintf(buf[:buf_size], "null") ?? buf[:0]).len;
    }
    long year, month, day, wday, hour, min, sec;
    date_break_time_utc(time_val, &year, &month, &day, &wday, &hour, &min, &sec);
    int ms = (int)((long)time_val % 1000);
    if (ms < 0) ms += 1000;

    usz pos = 0;

    // Expanded format for large years: +YYYYYY or -YYYYYY
    if (year >= 10000 || year <= -9999) {
        long abs_year = (year < 0) ? -year : year;
        buf[pos++] = (year < 0) ? '-' : '+';
        // 6+ digit year
        buf[pos++] = (char)(abs_year / 100000 % 10 + '0');
        buf[pos++] = (char)(abs_year / 10000 % 10 + '0');
        buf[pos++] = (char)(abs_year / 1000 % 10 + '0');
        buf[pos++] = (char)(abs_year / 100 % 10 + '0');
        buf[pos++] = (char)(abs_year / 10 % 10 + '0');
        buf[pos++] = (char)(abs_year % 10 + '0');
    } else {
        // Standard 4-digit year
        buf[pos++] = (char)((long)year / 1000 + '0');
        buf[pos++] = (char)((long)year / 100 % 10 + '0');
        buf[pos++] = (char)((long)year / 10 % 10 + '0');
        buf[pos++] = (char)((long)year % 10 + '0');
    }

    // -MM-DDTHH:mm:ss.sssZ
    buf[pos++] = '-';
    buf[pos++] = (char)((month + 1) / 10 + '0');
    buf[pos++] = (char)((month + 1) % 10 + '0');
    buf[pos++] = '-';
    buf[pos++] = (char)(day / 10 + '0');
    buf[pos++] = (char)(day % 10 + '0');
    buf[pos++] = 'T';
    buf[pos++] = (char)(hour / 10 + '0');
    buf[pos++] = (char)(hour % 10 + '0');
    buf[pos++] = ':';
    buf[pos++] = (char)(min / 10 + '0');
    buf[pos++] = (char)(min % 10 + '0');
    buf[pos++] = ':';
    buf[pos++] = (char)(sec / 10 + '0');
    buf[pos++] = (char)(sec % 10 + '0');
    buf[pos++] = '.';
    buf[pos++] = (char)(ms / 100 + '0');
    buf[pos++] = (char)(ms / 10 % 10 + '0');
    buf[pos++] = (char)(ms % 10 + '0');
    buf[pos++] = 'Z';

    return pos;
}

/// Parse an ISO 8601 date string into milliseconds since epoch.
/// Supported formats: "YYYY-MM-DDTHH:mm:ss.sssZ", "YYYY-MM-DDTHH:mm:ssZ",
/// "YYYY-MM-DDTHH:mm:ss.sss", "YYYY-MM-DDTHH:mm:ss", "YYYY-MM-DDTHH:mm",
/// "YYYY-MM-DD", "YYYY-MM", "YYYY". Returns NaN on parse failure.
fn double date_parse_iso_str(char* str, usz len) {
    // Minimum: "YYYY" = 4 chars
    if (len < 4) return double::nan;

    // Parse year
    long year = 0;
    usz pos = 0;
    bool has_sign = false;
    if (str[pos] == '+' || str[pos] == '-') { has_sign = true; pos++; }
    usz year_start_pos = pos;
    while (pos < len && str[pos] >= '0' && str[pos] <= '9') {
        year = year * 10 + (long)(str[pos] - '0');
        pos++;
    }
    usz year_digits = pos - year_start_pos;
    // Year must have at least 4 digits
    if (year_digits < 4) return double::nan;
    // Handle leading sign
    if (has_sign && str[0] == '-') year = -year;
    // -000000 is invalid (negative zero year) per ES2015
    if (has_sign && year == 0 && str[0] == '-') return double::nan;

    long month = 1;  // default
    long day = 1;    // default

    // Optional: '-' + month (2 digits)
    if (pos < len && str[pos] == '-') {
        pos++;
        month = 0;
        usz month_start = pos;
        while (pos < len && str[pos] >= '0' && str[pos] <= '9') {
            month = month * 10 + (long)(str[pos] - '0');
            pos++;
        }
        if (pos - month_start != 2) return double::nan;

        // Optional: '-' + day (2 digits)
        if (pos < len && str[pos] == '-') {
            pos++;
            day = 0;
            usz day_start = pos;
            while (pos < len && str[pos] >= '0' && str[pos] <= '9') {
                day = day * 10 + (long)(str[pos] - '0');
                pos++;
            }
            if (pos - day_start != 2) return double::nan;
        }
    }

    long hour = 0;
    long minute = 0;
    long second = 0;
    long millis = 0;
    bool has_time_part = false;

    // Optional time part: 'T' or space
    if (pos < len && (str[pos] == 'T' || str[pos] == ' ')) {
        has_time_part = true;
        pos++;

        // Parse hour (2 digits)
        usz hour_start = pos;
        while (pos < len && str[pos] >= '0' && str[pos] <= '9') {
            hour = hour * 10 + (long)(str[pos] - '0');
            pos++;
        }
        if (pos - hour_start != 2) return double::nan;

        // Optional ':' + minute
        if (pos < len && str[pos] == ':') {
            pos++;

            // Parse minute (2 digits)
            usz min_start = pos;
            while (pos < len && str[pos] >= '0' && str[pos] <= '9') {
                minute = minute * 10 + (long)(str[pos] - '0');
                pos++;
            }
            if (pos - min_start != 2) return double::nan;

            // Optional ':' + second
            if (pos < len && str[pos] == ':') {
                pos++;

                // Parse second (2 digits)
                usz sec_start = pos;
                while (pos < len && str[pos] >= '0' && str[pos] <= '9') {
                    second = second * 10 + (long)(str[pos] - '0');
                    pos++;
                }
                if (pos - sec_start != 2) return double::nan;

                // Optional fractional seconds
                if (pos < len && str[pos] == '.') {
                    pos++;
                    long frac = 0;
                    uint frac_digits = 0;
                    while (pos < len && str[pos] >= '0' && str[pos] <= '9' && frac_digits < 3) {
                        frac = frac * 10 + (long)(str[pos] - '0');
                        frac_digits++;
                        pos++;
                    }
                    // Consume remaining digits beyond 3
                    while (pos < len && str[pos] >= '0' && str[pos] <= '9') pos++;
                    // Normalize to milliseconds
                    while (frac_digits < 3) { frac *= 10; frac_digits++; }
                    millis = frac;
                }
            }
        }
    }

    // Optional timezone designator
    if (pos < len && str[pos] == 'Z') {
        // UTC timezone — use date_utc_to_ms
        pos++;
        return date_time_clip(date_utc_to_ms(year, month - 1, day, hour, minute, second, millis));
    } else if (pos + 5 <= len && (str[pos] == '+' || str[pos] == '-')) {
        // Parse timezone offset: +HH:MM or -HH:MM
        bool neg = (str[pos] == '-');
        pos++;
        long tz_hour = 0;
        for (uint i = 0; i < 2 && pos < len && str[pos] >= '0' && str[pos] <= '9'; i++) {
            tz_hour = tz_hour * 10 + (long)(str[pos] - '0');
            pos++;
        }
        if (pos < len && str[pos] == ':') pos++;
        long tz_min = 0;
        for (uint i = 0; i < 2 && pos < len && str[pos] >= '0' && str[pos] <= '9'; i++) {
            tz_min = tz_min * 10 + (long)(str[pos] - '0');
            pos++;
        }
        long offset_ms = (tz_hour * 60 + tz_min) * 60000;
        if (neg) offset_ms = -offset_ms;
        // Convert to UTC: local = utc + offset, so utc = local - offset
        double local_ms = date_local_to_ms(year, month - 1, day, hour, minute, second, millis);
        return date_time_clip(local_ms - (double)offset_ms);
    }

    // No timezone specified: per ES2016+ §21.4.1.15, date-time forms are
    // local time, but date-only forms are UTC.
    if (has_time_part) {
        return date_time_clip(date_local_to_ms(year, month - 1, day, hour, minute, second, millis));
    }
    return date_time_clip(date_utc_to_ms(year, month - 1, day, hour, minute, second, millis));
}

/// Helper: match a 3-letter month name, return 0-based month index or -1.
fn long date_parse_month_name(char* s, usz len, usz pos) {
    if (pos + 3 > len) return -1;
    if (s[pos] == 'J' && s[pos+1] == 'a' && s[pos+2] == 'n') return 0;
    if (s[pos] == 'F' && s[pos+1] == 'e' && s[pos+2] == 'b') return 1;
    if (s[pos] == 'M' && s[pos+1] == 'a' && s[pos+2] == 'r') return 2;
    if (s[pos] == 'A' && s[pos+1] == 'p' && s[pos+2] == 'r') return 3;
    if (s[pos] == 'M' && s[pos+1] == 'a' && s[pos+2] == 'y') return 4;
    if (s[pos] == 'J' && s[pos+1] == 'u' && s[pos+2] == 'n') return 5;
    if (s[pos] == 'J' && s[pos+1] == 'u' && s[pos+2] == 'l') return 6;
    if (s[pos] == 'A' && s[pos+1] == 'u' && s[pos+2] == 'g') return 7;
    if (s[pos] == 'S' && s[pos+1] == 'e' && s[pos+2] == 'p') return 8;
    if (s[pos] == 'O' && s[pos+1] == 'c' && s[pos+2] == 't') return 9;
    if (s[pos] == 'N' && s[pos+1] == 'o' && s[pos+2] == 'v') return 10;
    if (s[pos] == 'D' && s[pos+1] == 'e' && s[pos+2] == 'c') return 11;
    return -1;
}

/// Parse a toString/toUTCString format date string.
/// Formats: "Thu Jan 01 1970 01:00:00 GMT+0000" (toString)
///          "Thu, 01 Jan 1970 00:00:00 GMT" (toUTCString)
/// Returns NaN on failure.
fn double date_parse_locale_str(char* str, usz len) {
    if (len < 20) return double::nan;
    usz pos = 0;

    // Skip day-of-week name (3 chars)
    if (pos + 3 > len) return double::nan;
    pos += 3;

    // Skip optional comma and space (toUTCString: "Thu, 01...")
    if (pos < len && str[pos] == ',') pos++;
    if (pos < len && str[pos] == ' ') pos++;

    long month = -1;
    long day = 0;

    // Detect format: if next char is a digit, it's toUTCString (day before month)
    // If next char is a letter, it's toString (month before day)
    if (pos < len && str[pos] >= '0' && str[pos] <= '9') {
        // toUTCString format: "Thu, 01 Jan 1970 00:00:00 GMT"
        // Parse day number (1-2 digits)
        while (pos < len && str[pos] >= '0' && str[pos] <= '9') {
            day = day * 10 + (long)(str[pos] - '0');
            pos++;
        }
        // Expect space
        if (pos >= len || str[pos] != ' ') return double::nan;
        pos++;
        // Parse month name
        month = date_parse_month_name(str, len, pos);
        if (month < 0) return double::nan;
        pos += 3;
    } else if (pos < len && str[pos] >= 'A' && str[pos] <= 'Z') {
        // toString format: "Thu Jan 01 1970 01:00:00 GMT+0000"
        // Parse month name first
        month = date_parse_month_name(str, len, pos);
        if (month < 0) return double::nan;
        pos += 3;
        // Expect space
        if (pos >= len || str[pos] != ' ') return double::nan;
        pos++;
        // Parse day number (1-2 digits)
        while (pos < len && str[pos] >= '0' && str[pos] <= '9') {
            day = day * 10 + (long)(str[pos] - '0');
            pos++;
        }
    } else {
        return double::nan;
    }

    // Expect space
    if (pos >= len || str[pos] != ' ') return double::nan;
    pos++;

    // Parse year (4 digits)
    if (pos + 4 > len) return double::nan;
    long year = 0;
    for (uint i = 0; i < 4; i++) {
        if (str[pos] < '0' || str[pos] > '9') return double::nan;
        year = year * 10 + (long)(str[pos] - '0');
        pos++;
    }

    // Expect space
    if (pos >= len || str[pos] != ' ') return double::nan;
    pos++;

    // Parse time: HH:MM:SS
    if (pos + 8 > len) return double::nan;
    long hour = 0;
    long minute = 0;
    long second = 0;
    if (str[pos] < '0' || str[pos] > '9') return double::nan;
    hour = (long)(str[pos] - '0') * 10 + (long)(str[pos+1] - '0');
    if (str[pos+2] != ':') return double::nan;
    minute = (long)(str[pos+3] - '0') * 10 + (long)(str[pos+4] - '0');
    if (str[pos+5] != ':') return double::nan;
    second = (long)(str[pos+6] - '0') * 10 + (long)(str[pos+7] - '0');
    pos += 8;

    // Expect space
    if (pos >= len || str[pos] != ' ') return double::nan;
    pos++;

    // Parse timezone: "GMT", "GMT+HHMM", "GMT-HHMM"
    if (pos + 3 > len) return double::nan;
    if (str[pos] != 'G' || str[pos+1] != 'M' || str[pos+2] != 'T') return double::nan;
    pos += 3;

    long tz_offset_min = 0;  // default UTC
    if (pos < len && (str[pos] == '+' || str[pos] == '-')) {
        bool neg = (str[pos] == '-');
        pos++;
        if (pos + 4 > len) return double::nan;
        long tz_h = (long)(str[pos] - '0') * 10 + (long)(str[pos+1] - '0');
        long tz_m = (long)(str[pos+2] - '0') * 10 + (long)(str[pos+3] - '0');
        tz_offset_min = tz_h * 60 + tz_m;
        if (neg) tz_offset_min = -tz_offset_min;
    }

    // Convert to UTC: the parsed time is in local time, offset is local-UTC
    // utc = local - offset
    double local_ms = date_utc_to_ms(year, month, day, hour, minute, second, 0);
    double utc_ms = local_ms - (double)tz_offset_min * 60000.0;
    return utc_ms;
}

/// Date() as function — returns current date-time string (ES5 §15.9.2.1).
fn void builtin_date(BuiltinContext* ctx) {
    double now = date_now_ms();
    if (ctx.is_constructor) {
        // new Date(...) — create Date object
        HObject*? obj_raw = ctx.heap.alloc_object(hobject::ObjClass.DATE);
        if (catch err = obj_raw) {
            ctx.result.set_undefined();
            return;
        }
        HObject* obj = obj_raw;
        obj.prototype = builtin_proto_from_new_target(ctx, ctx.heap.date_proto);

        double time_val;
        if (ctx.argc == 0) {
            time_val = now;
        } else if (ctx.argc == 1) {
            TVal* arg = &ctx.regs[ctx.base_reg];
            if (arg.is_string()) {
                // Parse string: try ISO 8601 first, then locale format, then as number
                HString* s = (HString*)arg.get_heapptr();
                char* str = s.get_cstr();
                usz slen = s.blen;
                time_val = date_parse_iso_str(str, slen);
                if (math::is_nan(time_val)) {
                    // Try locale format (toString/toUTCString)
                    time_val = date_parse_locale_str(str, slen);
                }
                if (math::is_nan(time_val)) {
                    // Try as numeric string
                    double num_val = builtin_string_to_number(s);
                    if (!math::is_nan(num_val)) {
                        time_val = num_val;
                    } else {
                        time_val = now;
                    }
                }
            } else if (arg.is_number() || arg.is_fastint()) {
                time_val = arg.get_number_or_fastint();
            } else if (arg.is_undefined() || arg.is_null()) {
                time_val = now;
            } else if (arg.is_object() && arg.get_heapptr() != null) {
                // ES6 §20.3.2.2 step 3.a: when value is a Date object, use
                // thisTimeValue(value) — read [[DateValue]] directly without
                // calling valueOf/toString. Note: Date.prototype is a DATE
                // object that lacks [[DateValue]]; date_this_time_value throws
                // TypeError for it, which matches ES6 step 3.a.i.
                HObject* arg_obj = (HObject*)arg.get_heapptr();
                if (arg_obj.get_class() == hobject::ObjClass.DATE) {
                    time_val = date_this_time_value(ctx, arg);
                    if (ctx.should_throw) { return; }
                } else {
                    // Non-Date object: ES6 §20.3.2.2 step 3.b.i: v = ToPrimitive(value)
                    // (default hint). If Type(v) is String, parse it as a date
                    // string; otherwise tv = ToNumber(v).
                    Vm* v = (Vm*)ctx.vm;
                    TVal prim = vm::to_primitive_value(v, arg);
                    if (v.throw_pending) {
                        ctx.should_throw = true;
                        ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value);
                        v.throw_pending = false;
                        return;
                    }
                    if (prim.is_string() && prim.get_heapptr() != null &&
                        !((HString*)prim.get_heapptr()).is_symbol()) {
                        HString* s = (HString*)prim.get_heapptr();
                        char* str = s.get_cstr();
                        usz slen = s.blen;
                        time_val = date_parse_iso_str(str, slen);
                        if (math::is_nan(time_val)) {
                            time_val = date_parse_locale_str(str, slen);
                        }
                        if (math::is_nan(time_val)) {
                            double num_val = builtin_string_to_number(s);
                            time_val = num_val;
                        }
                    } else {
                        time_val = vm::vm_to_number(v, &prim);
                        if (v.throw_pending) {
                            ctx.should_throw = true;
                            ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value);
                            v.throw_pending = false;
                            return;
                        }
                    }
                }
            } else {
                // Other primitive (boolean, symbol): call ToNumber
                Vm* v = (Vm*)ctx.vm;
                time_val = vm::vm_to_number(v, arg);
                if (v.throw_pending) {
                    ctx.should_throw = true;
                    ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value);
                    v.throw_pending = false;
                    return;
                }
            }
        } else {
            // Multiple args: Date(year, month[, day, hour, minute, second, ms])
            // ES5 §15.9.3.1: call ToNumber on each argument (must call valueOf)
            Vm* v = (Vm*)ctx.vm;
            TVal* year_arg  = &ctx.regs[ctx.base_reg];
            TVal* month_arg = &ctx.regs[ctx.base_reg + 1];
            double year  = vm::vm_to_number(v, year_arg);
            if (v.throw_pending) {
                ctx.should_throw = true;
                ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value);
                v.throw_pending = false;
                return;
            }
            double month = vm::vm_to_number(v, month_arg);
            if (v.throw_pending) {
                ctx.should_throw = true;
                ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value);
                v.throw_pending = false;
                return;
            }
            double day = 1.0;
            if (ctx.argc > 2) {
                day = vm::vm_to_number(v, &ctx.regs[ctx.base_reg + 2]);
                if (v.throw_pending) {
                    ctx.should_throw = true;
                    ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value);
                    v.throw_pending = false;
                    return;
                }
            }
            double hour = 0.0;
            if (ctx.argc > 3) {
                hour = vm::vm_to_number(v, &ctx.regs[ctx.base_reg + 3]);
                if (v.throw_pending) {
                    ctx.should_throw = true;
                    ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value);
                    v.throw_pending = false;
                    return;
                }
            }
            double min = 0.0;
            if (ctx.argc > 4) {
                min = vm::vm_to_number(v, &ctx.regs[ctx.base_reg + 4]);
                if (v.throw_pending) {
                    ctx.should_throw = true;
                    ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value);
                    v.throw_pending = false;
                    return;
                }
            }
            double sec = 0.0;
            if (ctx.argc > 5) {
                sec = vm::vm_to_number(v, &ctx.regs[ctx.base_reg + 5]);
                if (v.throw_pending) {
                    ctx.should_throw = true;
                    ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value);
                    v.throw_pending = false;
                    return;
                }
            }
            double ms = 0.0;
            if (ctx.argc > 6) {
                ms = vm::vm_to_number(v, &ctx.regs[ctx.base_reg + 6]);
                if (v.throw_pending) {
                    ctx.should_throw = true;
                    ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value);
                    v.throw_pending = false;
                    return;
                }
            }

            // Year < 100 means 1900 + year
            if (year >= 0 && year < 100) year += 1900;

            // NaN propagation: if any argument is NaN, result is NaN
            if (math::is_nan(year) || math::is_nan(month) ||
                math::is_nan(day) || math::is_nan(hour) ||
                math::is_nan(min) || math::is_nan(sec) || math::is_nan(ms)) {
                time_val = double::nan;
            } else {
                time_val = date_local_to_ms((long)year, (long)month, (long)day,
                                            (long)hour, (long)min, (long)sec, (long)ms);
            }
        }

        (*obj.extra_ptr()).prim.primitive_value.set_number(date_time_clip(time_val));

        ctx.result.set_object(obj);
    } else {
        // Date() as function — return string of current time
        char[128] buf;
        usz len = date_format_to_string(now, &buf, 128);
        HString* result = builtin_intern_string(ctx.heap, buf[:len]);
        ctx.result.set_string(result);
    }
}

/// Date.now() — ES5 §15.9.4.4
fn void builtin_date_now(BuiltinContext* ctx) {
    ctx.result.set_number(date_now_ms());
}

/// Date.UTC(year[, month[, day, hour, minute, second, ms]]) — ES2017+ §20.3.3.4
/// (month and later arguments default to 0/1 like the Date constructor;
/// pre-ES2017 engines coerced a missing month to NaN, but that was fixed by
/// https://github.com/tc39/ecma262/pull/642).
fn void builtin_date_utc(BuiltinContext* ctx) {
    if (ctx.argc < 1) {
        ctx.result.set_number(double::nan);
        return;
    }
    // ES5 §15.9.4.3: call ToNumber on each argument (must call valueOf)
    Vm* v = (Vm*)ctx.vm;
    TVal* year_arg  = &ctx.regs[ctx.base_reg];
    double year  = vm::vm_to_number(v, year_arg);
    if (v.throw_pending) {
        ctx.should_throw = true;
        ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value);
        v.throw_pending = false;
        return;
    }
    double month = 0.0;
    if (ctx.argc > 1) {
        month = vm::vm_to_number(v, &ctx.regs[ctx.base_reg + 1]);
        if (v.throw_pending) {
            ctx.should_throw = true;
            ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value);
            v.throw_pending = false;
            return;
        }
    }
    double day = 1.0;
    if (ctx.argc > 2) {
        day = vm::vm_to_number(v, &ctx.regs[ctx.base_reg + 2]);
        if (v.throw_pending) {
            ctx.should_throw = true;
            ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value);
            v.throw_pending = false;
            return;
        }
    }
    double hour = 0.0;
    if (ctx.argc > 3) {
        hour = vm::vm_to_number(v, &ctx.regs[ctx.base_reg + 3]);
        if (v.throw_pending) {
            ctx.should_throw = true;
            ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value);
            v.throw_pending = false;
            return;
        }
    }
    double min = 0.0;
    if (ctx.argc > 4) {
        min = vm::vm_to_number(v, &ctx.regs[ctx.base_reg + 4]);
        if (v.throw_pending) {
            ctx.should_throw = true;
            ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value);
            v.throw_pending = false;
            return;
        }
    }
    double sec = 0.0;
    if (ctx.argc > 5) {
        sec = vm::vm_to_number(v, &ctx.regs[ctx.base_reg + 5]);
        if (v.throw_pending) {
            ctx.should_throw = true;
            ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value);
            v.throw_pending = false;
            return;
        }
    }
    double ms = 0.0;
    if (ctx.argc > 6) {
        ms = vm::vm_to_number(v, &ctx.regs[ctx.base_reg + 6]);
        if (v.throw_pending) {
            ctx.should_throw = true;
            ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value);
            v.throw_pending = false;
            return;
        }
    }

    // Per ES6 §21.4.1.15 (MakeDay) and §21.4.1.14 (MakeTime): if any of the
    // year, month, date, hour, minute, second, or ms values is not finite
    // (i.e., NaN or ±Infinity), the result is NaN. ES5 §15.9.4.3 only
    // mentions NaN, but ES6 §20.3.3.4 step 7 requires the same isFinite check
    // for the spec-defined MakeDay/MakeTime operations.
    if (!math::is_finite(year) || !math::is_finite(month) ||
        !math::is_finite(day) || !math::is_finite(hour) ||
        !math::is_finite(min) || !math::is_finite(sec) || !math::is_finite(ms)) {
        ctx.result.set_number(double::nan);
        return;
    }

    // Per ES6 §20.3.3.4 Date.UTC, MakeDay/MakeTime each apply ToInteger to
    // their respective inputs (§21.4.1.14, §21.4.1.15). ToInteger(x) is
    // trunc(x) toward zero for finite x. Done after is_finite check so we
    // don't UB on ±Infinity. Step 8: if 0 ≤ ToInteger(y) ≤ 99, yr is
    // 1900+ToInteger(y); otherwise yr is ToInteger(y).
    long year_int = (long)math::trunc(year);
    if (year_int >= 0 && year_int <= 99) {
        year = (double)year_int + 1900.0;
    } else {
        year = (double)year_int;
    }
    month = (double)(long)math::trunc(month);
    day = (double)(long)math::trunc(day);
    // hour/min/sec/ms feed only MakeTime, whose inputs may be far outside the
    // range of a 64-bit integer (ES2015+ §21.4.1.14); ToInteger must stay in
    // double domain here rather than narrowing through (long), which would
    // silently wrap/clamp for huge magnitudes.
    hour = math::trunc(hour);
    min = math::trunc(min);
    sec = math::trunc(sec);
    ms = math::trunc(ms);

    // For Date.UTC, the time is in UTC. We compute days from epoch using
    // simple calendar math (no timezone offset). month may overflow [0,11];
    // carry into year first (mirrors date_utc_to_ms's normalization).
    long month_floor_div = (long)month >= 0 ? (long)month / 12 : ((long)month - 11) / 12;
    long y = (long)year + month_floor_div;
    long m = (long)month - month_floor_div * 12;  // now in [0, 11]
    // Adjust year: treat Jan and Feb as months 13,14 of previous year
    if (m < 2) { y--; m += 12; }
    // Computations using the formula
    long era = (y >= 0 ? y : y - 399) / 400;
    long yoe = y - era * 400;  // [0, 399]
    long doy = (153 * (m - 2) + 2) / 5 + (long)day - 1;  // day of year
    long doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    long epoch_day = (era * 146097 + (long)doe - 719468);
    double maketime = duktape_date_make_time(hour, min, sec, ms);
    double t = duktape_date_make_date((double)epoch_day, maketime);
    ctx.result.set_number(date_time_clip(t));
}

/// Date.parse(string) — ES5 §15.9.4.2
fn void builtin_date_parse(BuiltinContext* ctx) {
    if (ctx.argc < 1) {
        ctx.result.set_number(double::nan);
        return;
    }
    TVal* arg = &ctx.regs[ctx.base_reg];
    HString* s;
    if (arg.is_string()) {
        s = (HString*)arg.get_heapptr();
    } else {
        s = builtin_to_string(ctx.heap, arg);
    }
    if (s == null || s.blen == 0) {
        ctx.result.set_number(double::nan);
        return;
    }
    // Try numeric parsing first (milliseconds)
    double num_val = builtin_string_to_number(s);
    if (!math::is_nan(num_val)) {
        ctx.result.set_number(num_val);
        return;
    }
    // Try parsing as ISO 8601 date string
    char* str = s.get_cstr();
    usz slen = s.blen;
    double date_val = date_parse_iso_str(str, slen);
    if (math::is_nan(date_val)) {
        // Try toString/toUTCString locale format
        date_val = date_parse_locale_str(str, slen);
    }
    ctx.result.set_number(date_val);
}

/// Date.prototype.toString() — ES5 §15.9.5.2
fn void builtin_date_proto_toString(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    double time_val = date_this_time_value(ctx, &this_val);
    if (ctx.should_throw) return;
    char[128] buf;
    usz len = date_format_to_string(time_val, &buf, 128);
    HString* result = builtin_intern_string(ctx.heap, buf[:len]);
    ctx.result.set_string(result);
}

/// Date.prototype.toLocaleString() — ES5 §15.9.5.5
/// Falls back to toString() (no locale-specific formatting).
fn void builtin_date_proto_toLocaleString(BuiltinContext* ctx) {
    builtin_date_proto_toString(ctx);
}

/// Date.prototype.toLocaleDateString() — ES5 §15.9.5.6
/// Returns the date portion only (YYYY-MM-DD style).
fn void builtin_date_proto_toLocaleDateString(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    double time_val = date_this_time_value(ctx, &this_val);
    if (ctx.should_throw) return;
    if (math::is_nan(time_val)) {
        HString* inv = builtin_intern_string(ctx.heap, "Invalid Date");
        ctx.result.set_string(inv);
        return;
    }
    long year, month, day, wday, hour, min, sec;
    date_break_time(time_val, &year, &month, &day, &wday, &hour, &min, &sec);
    char[types::FORMAT_BUF] buf;
    usz len = (usz)(io::bprintf(&buf, "%04d-%02d-%02d", (int)year, (int)(month + 1), (int)day) ?? buf[:0]).len;
    HString* result = builtin_intern_string(ctx.heap, buf[:len]);
    ctx.result.set_string(result);
}

/// Date.prototype.toLocaleTimeString() — ES5 §15.9.5.7
/// Returns the time portion only (HH:MM:SS style).
fn void builtin_date_proto_toLocaleTimeString(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    double time_val = date_this_time_value(ctx, &this_val);
    if (ctx.should_throw) return;
    if (math::is_nan(time_val)) {
        HString* inv = builtin_intern_string(ctx.heap, "Invalid Date");
        ctx.result.set_string(inv);
        return;
    }
    long year, month, day, wday, hour, min, sec;
    date_break_time(time_val, &year, &month, &day, &wday, &hour, &min, &sec);
    char[types::FORMAT_BUF] buf;
    usz len = (usz)(io::bprintf(&buf, "%02d:%02d:%02d", (int)hour, (int)min, (int)sec) ?? buf[:0]).len;
    HString* result = builtin_intern_string(ctx.heap, buf[:len]);
    ctx.result.set_string(result);
}

/// Date.prototype.toDateString() — ES5 §15.9.5.3
/// Returns the date portion: "Mon Jan 01 2024"
fn void builtin_date_proto_toDateString(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    double time_val = date_this_time_value(ctx, &this_val);
    if (ctx.should_throw) return;
    if (math::is_nan(time_val)) {
        HString* inv = builtin_intern_string(ctx.heap, "Invalid Date");
        ctx.result.set_string(inv);
        return;
    }
    long year, month, day, wday, hour, min, sec;
    date_break_time(time_val, &year, &month, &day, &wday, &hour, &min, &sec);
    char* wday_name;
    switch (wday) {
        case 0: wday_name = "Sun"; break;
        case 1: wday_name = "Mon"; break;
        case 2: wday_name = "Tue"; break;
        case 3: wday_name = "Wed"; break;
        case 4: wday_name = "Thu"; break;
        case 5: wday_name = "Fri"; break;
        case 6: wday_name = "Sat"; break;
        default: wday_name = "???"; break;
    }
    char* mon_name;
    switch (month) {
        case 0: mon_name = "Jan"; break;
        case 1: mon_name = "Feb"; break;
        case 2: mon_name = "Mar"; break;
        case 3: mon_name = "Apr"; break;
        case 4: mon_name = "May"; break;
        case 5: mon_name = "Jun"; break;
        case 6: mon_name = "Jul"; break;
        case 7: mon_name = "Aug"; break;
        case 8: mon_name = "Sep"; break;
        case 9: mon_name = "Oct"; break;
        case 10: mon_name = "Nov"; break;
        case 11: mon_name = "Dec"; break;
        default: mon_name = "???"; break;
    }
    char[types::FORMAT_BUF] buf;
    // ES6 §21.4.3.4 ToDateString year format: 4-digit zero-padded positive;
    // "-%04d" for negative year in [-9999, 0); full integer for |y| >= 10000.
    // We write the year into a temp buffer first to support all forms, then
    // copy into buf. Use bprintf with the appropriate width format.
    char[24] year_str;
    if (year < 0 && year > -10000) {
        (void)io::bprintf(&year_str, "-%04d", -year);
    } else if (year <= -10000) {
        (void)io::bprintf(&year_str, "%d", year);
    } else {
        (void)io::bprintf(&year_str, "%04d", year);
    }
    usz len = (usz)(io::bprintf(&buf, "%s %s %02d %s",
        (ZString)wday_name, (ZString)mon_name, (int)day, (ZString)&year_str[0]) ?? buf[:0]).len;
    HString* result = builtin_intern_string(ctx.heap, buf[:len]);
    ctx.result.set_string(result);
}

/// Date.prototype.toTimeString() — ES5 §15.9.5.4
/// Returns the time portion: "12:00:00 GMT+0000"
fn void builtin_date_proto_toTimeString(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    double time_val = date_this_time_value(ctx, &this_val);
    if (ctx.should_throw) return;
    if (math::is_nan(time_val)) {
        HString* inv = builtin_intern_string(ctx.heap, "Invalid Date");
        ctx.result.set_string(inv);
        return;
    }
    long t_sec = (long)(time_val / 1000.0);
    long year, month, day, wday, hour, minute, second;
    date_break_time_local_fields(time_val, &year, &month, &day, &wday, &hour, &minute, &second);

    long tz_seconds = date_tz_offset_seconds(t_sec);
    char tz_sign = '+';
    int offs_hours = (int)(tz_seconds / 3600);
    int offs_mins = (int)((tz_seconds / 60) % 60);
    if (tz_seconds < 0) {
        tz_sign = '-';
        offs_hours = -offs_hours;
        offs_mins = -offs_mins;
    }

    char[types::FORMAT_BUF] buf;
    usz len = (usz)(io::bprintf(&buf, "%02d:%02d:%02d GMT%c%02d%02d",
        (int)hour, (int)minute, (int)second,
        tz_sign, offs_hours, offs_mins) ?? buf[:0]).len;
    HString* result = builtin_intern_string(ctx.heap, buf[:len]);
    ctx.result.set_string(result);
}

/// Date.prototype.toJSON(key) — ES5 §15.9.5.44
///
/// ES2015 §20.4.4.28:
/// 1. Let O be ? ToObject(this value).
/// 2. Let tv be ? ToPrimitive(O, hint Number).
/// 3. If Type(tv) is Number and tv is not finite, return null.
/// 4. Return ? Invoke(O, "toISOString").
///
/// For Date objects, ToPrimitive returns the internal [[DateValue]] (a Number).
/// For plain objects, ToPrimitive calls valueOf/toString and returns a String
/// (e.g. "[object Object]"), so Type(tv) is NOT Number → step 3 is skipped →
/// step 4 calls toISOString.
fn void builtin_date_proto_toJSON(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];

    // Step 1: Let O be ? ToObject(this value). null/undefined throw
    // TypeError; other primitives are boxed into their wrapper object.
    if (!this_val.is_object() || this_val.get_heapptr() == null) {
        if (this_val.is_null() || this_val.is_undefined()) {
            builtin_throw(ctx, ctx.heap.type_err_proto,
                "Date.prototype.toJSON called on null or undefined");
            return;
        }
        if (!builtin_to_object(ctx, this_val)) {
            builtin_throw(ctx, ctx.heap.type_err_proto,
                "Date.prototype.toJSON: cannot convert to object");
            return;
        }
        this_val = *ctx.result;
    }
    TVal object_val = this_val;

    // Steps 2–3: Compute ToPrimitive(O, hint Number), then check
    // "Type(tv) is Number and tv is not finite" → return null.
    HObject* obj = (HObject*)this_val.get_heapptr();
    if (obj.get_class() == hobject::ObjClass.DATE) {
        // Date object: ToPrimitive returns the internal time value.
        double time_val;
        if ((*obj.extra_ptr()).prim.primitive_value.is_number() ||
            (*obj.extra_ptr()).prim.primitive_value.is_fastint()) {
            time_val = (*obj.extra_ptr()).prim.primitive_value.get_number_or_fastint();
        } else {
            time_val = double::nan;
        }
        // Step 3: If Type(tv) is Number and not finite → return null.
        if (math::is_nan(time_val) || !math::is_finite(time_val)) {
            ctx.result.set_null();
            return;
        }
        // Step 4: Fall through to Invoke(O, "toISOString") below.
    } else {
        // Non-Date object: call ToPrimitive via to_primitive_value.
        // For plain objects, valueOf returns self (not primitive),
        // then toString returns "[object Object]" (a String, NOT a Number),
        // so Type(tv) is String → step 3 is skipped → Invoke in step 4.
        // For objects with custom valueOf returning NaN/Infinity,
        // the result IS a Number type and not finite → return null.
        Vm* v = (Vm*)ctx.vm;
        // Step 2: ToPrimitive(O, hint Number).
        TVal prim = vm::to_primitive_value(v, &this_val, 2);
        if (v.throw_pending) {
            ctx.should_throw = true;
            ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value);
            v.throw_pending = false;
            return;
        }
        // Check Type(tv) is Number and not finite.
        if ((prim.is_number() || prim.is_fastint()) &&
            (math::is_nan(prim.get_number_or_fastint()) || !math::is_finite(prim.get_number_or_fastint()))) {
            ctx.result.set_null();
            return;
        }
    }

    // Step 4: Return ? Invoke(O, "toISOString")
    // Look up "toISOString" on O, then call it with O as the receiver.
    // If the property is missing or not callable, Invoke throws TypeError.
    // Per ES6 §7.3.1 GetV, accessor properties must invoke their getter; use
    // find_accessor_proto to handle both data and accessor (getter-defined)
    // properties correctly.
    HString* toiso_key = builtin_intern_string(ctx.heap, "toISOString");
    hobject::AccessorResult acc = obj.find_accessor_proto(toiso_key, true);
    TVal toiso_fn;
    TVal call_this = object_val;
    bool found = acc.found;
    if (acc.found) {
        // Accessor found: invoke the getter with the owning object as `this`
        // to get the actual toISOString function (per ES6 §7.3.1 GetV).
        Vm* v = (Vm*)ctx.vm;
        TVal getter_this;
        getter_this.set_object(acc.this_obj);
        toiso_fn = ctx.heap.call_fn(v, acc.accessor_fn, null, 0, getter_this);
        if (ctx.heap.has_error) {
            ctx.should_throw = true;
            ctx.throw_value = ctx.heap.error_value;
            ctx.heap.has_error = false;
            return;
        }
        // For an accessor on the prototype chain, Invoke's "this" must be O,
        // not the object that owns the accessor. acc.this_obj is the owner.
        call_this = object_val;
    } else {
        // Data property or no property: fall back to get_prop_proto.
        TVal? toiso_val = obj.get_prop_proto(toiso_key);
        if (try tv = toiso_val) {
            toiso_fn = tv;
            found = true;
        } else {
            toiso_fn.set_undefined();
        }
    }
    if (found) {
        bool callable = false;
        if (toiso_fn.is_object() && toiso_fn.get_heapptr() != null) {
            HObject* fn_hobj = (HObject*)toiso_fn.get_heapptr();
            callable = fn_hobj.is_callable();
        } else if (toiso_fn.is_lightfunc()) {
            callable = true;
        }
        if (callable) {
            Vm* v = (Vm*)ctx.vm;
            // Invoke calls with empty arguments list (per spec).
            TVal result = ctx.heap.call_fn(v, toiso_fn, null, 0, call_this);
            if (ctx.heap.has_error) {
                ctx.should_throw = true;
                ctx.throw_value = ctx.heap.error_value;
                ctx.heap.has_error = false;
                return;
            }
            ctx.heap.tval_copy_ref(ctx.result, &result);
            return;
        }
    }

    // Invoke(O, "toISOString") — property missing or not callable → TypeError
    builtin_throw(ctx, ctx.heap.type_err_proto, "toISOString is not a function");
}

/// Date.prototype.data.valueOf() — ES5 §15.9.5.8
fn void builtin_date_proto_valueOf(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    double time_val = date_this_time_value(ctx, &this_val);
    if (ctx.should_throw) return;
    ctx.result.set_number(time_val);
}

/// Date.prototype[Symbol.toPrimitive](hint) — ES2023 §21.4.4.45
/// Converts a Date to a primitive. hint "string"/"default" → try toString first;
/// hint "number" → try valueOf first. Non-object this or unknown hint → TypeError.
fn void builtin_date_proto_toPrimitive(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];

    // Step 1: If Type(this) is not Object, throw TypeError.
    if (!this_val.is_object() || this_val.get_heapptr() == null) {
        builtin_throw(ctx, ctx.heap.type_err_proto,
            "Date.prototype[Symbol.toPrimitive] called on non-object");
        return;
    }
    HObject* this_obj = (HObject*)this_val.get_heapptr();

    // Step 2: Determine tryFirst from the hint argument.
    TVal hint_tv = (ctx.argc > 0) ? builtin_arg(ctx, 0) : (TVal){};
    // tryFirst: true = "string" order (toString, valueOf), false = "number" order (valueOf, toString)
    bool try_string_first;
    if (ctx.argc > 0 && hint_tv.is_string() && hint_tv.get_heapptr() != null) {
        HString* hint_str = (HString*)hint_tv.get_heapptr();
        if (hint_str.equals("string") || hint_str.equals("default")) {
            try_string_first = true;
        } else if (hint_str.equals("number")) {
            try_string_first = false;
        } else {
            builtin_throw(ctx, ctx.heap.type_err_proto,
                "Invalid hint for Date[Symbol.toPrimitive]");
            return;
        }
    } else {
        builtin_throw(ctx, ctx.heap.type_err_proto,
            "Invalid hint for Date[Symbol.toPrimitive]");
        return;
    }

    // Step 3: OrdinaryToPrimitive(O, tryFirst).
    // Try two method names in order; skip non-callable; return first non-Object result.
    char[][2] method_order;
    if (try_string_first) {
        method_order = { "toString", "valueOf" };
    } else {
        method_order = { "valueOf", "toString" };
    }

    Vm* v = (Vm*)ctx.vm;
    for (int i = 0; i < 2; i++) {
        char[] method_name = method_order[i];
        HString* key = builtin_intern_string(ctx.heap, method_name);
        if (key == null) continue;

        // Get the method via accessor-aware lookup (handles getter-defined props).
        TVal method_fn;
        bool found = false;
        hobject::AccessorResult acc = this_obj.find_accessor_proto(key, true);
        if (acc.found) {
            // Invoke the getter to obtain the method value.
            TVal getter_this;
            getter_this.set_object(acc.this_obj);
            method_fn = ctx.heap.call_fn(v, acc.accessor_fn, null, 0, getter_this);
            if (ctx.heap.has_error) {
                ctx.should_throw = true;
                ctx.throw_value = ctx.heap.error_value;
                ctx.heap.has_error = false;
                return;
            }
            found = true;
        } else {
            TVal? mv = this_obj.get_prop_proto(key);
            if (try tv = mv) {
                method_fn = tv;
                found = true;
            }
        }
        if (!found) continue;

        // IsCallable check.
        bool callable = false;
        if (method_fn.is_lightfunc()) {
            callable = true;
        } else if (method_fn.is_object() && method_fn.get_heapptr() != null) {
            callable = ((HObject*)method_fn.get_heapptr()).is_callable();
        }
        if (!callable) continue;

        // Call the method with this as receiver, no arguments.
        TVal result = ctx.heap.call_fn(v, method_fn, null, 0, this_val);
        if (ctx.heap.has_error) {
            ctx.should_throw = true;
            ctx.throw_value = ctx.heap.error_value;
            ctx.heap.has_error = false;
            return;
        }

        // If result is not Object, return it as the primitive.
        if (!result.is_object()) {
            ctx.heap.tval_copy_ref(ctx.result, &result);
            return;
        }
        // Result is an Object — try the next method.
    }

    // No method produced a primitive → TypeError.
    builtin_throw(ctx, ctx.heap.type_err_proto,
        "Cannot convert Date to primitive");
}

/// Date.prototype.getTime() — ES5 §15.9.5.9
fn void builtin_date_proto_getTime(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    double time_val = date_this_time_value(ctx, &this_val);
    if (ctx.should_throw) return;
    ctx.result.set_number(time_val);
}

/// Helper: break a time value into local time components via localtime_r.
fn void date_break_time(double time_val, long* year, long* month, long* day,
                        long* wday, long* hour, long* minute, long* second) {
    if (math::is_nan(time_val)) {
        *year = *month = *day = *wday = *hour = *minute = *second = 0;
        return;
    }
    date_break_time_local_fields(time_val, year, month, day, wday, hour, minute, second);
}

/// Date.prototype.getFullYear() — ES5 §15.9.5.10
fn void builtin_date_proto_getFullYear(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    double tv = date_this_time_value(ctx, &this_val);
    if (ctx.should_throw) return;
    if (math::is_nan(tv)) { ctx.result.set_number(double::nan); return; }
    long year, month, day, wday, hour, min, sec;
    date_break_time(tv, &year, &month, &day, &wday, &hour, &min, &sec);
    ctx.result.set_fastint(year);
}

/// Date.prototype.getMonth() — ES5 §15.9.5.12
fn void builtin_date_proto_getMonth(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    double tv = date_this_time_value(ctx, &this_val);
    if (ctx.should_throw) return;
    if (math::is_nan(tv)) { ctx.result.set_number(double::nan); return; }
    long year, month, day, wday, hour, min, sec;
    date_break_time(tv, &year, &month, &day, &wday, &hour, &min, &sec);
    ctx.result.set_fastint(month);
}

/// Date.prototype.getDate() — ES5 §15.9.5.14
fn void builtin_date_proto_getDate(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    double tv = date_this_time_value(ctx, &this_val);
    if (ctx.should_throw) return;
    if (math::is_nan(tv)) { ctx.result.set_number(double::nan); return; }
    long year, month, day, wday, hour, min, sec;
    date_break_time(tv, &year, &month, &day, &wday, &hour, &min, &sec);
    ctx.result.set_fastint(day);
}

/// Date.prototype.getDay() — ES5 §15.9.5.16
fn void builtin_date_proto_getDay(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    double tv = date_this_time_value(ctx, &this_val);
    if (ctx.should_throw) return;
    if (math::is_nan(tv)) { ctx.result.set_number(double::nan); return; }
    long year, month, day, wday, hour, min, sec;
    date_break_time(tv, &year, &month, &day, &wday, &hour, &min, &sec);
    ctx.result.set_fastint(wday);
}

/// Date.prototype.getHours() — ES5 §15.9.5.18
fn void builtin_date_proto_getHours(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    double tv = date_this_time_value(ctx, &this_val);
    if (ctx.should_throw) return;
    if (math::is_nan(tv)) { ctx.result.set_number(double::nan); return; }
    long year, month, day, wday, hour, min, sec;
    date_break_time(tv, &year, &month, &day, &wday, &hour, &min, &sec);
    ctx.result.set_fastint(hour);
}

/// Date.prototype.getMinutes() — ES5 §15.9.5.20
fn void builtin_date_proto_getMinutes(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    double tv = date_this_time_value(ctx, &this_val);
    if (ctx.should_throw) return;
    if (math::is_nan(tv)) { ctx.result.set_number(double::nan); return; }
    long year, month, day, wday, hour, min, sec;
    date_break_time(tv, &year, &month, &day, &wday, &hour, &min, &sec);
    ctx.result.set_fastint(min);
}

/// Date.prototype.getSeconds() — ES5 §15.9.5.22
fn void builtin_date_proto_getSeconds(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    double tv = date_this_time_value(ctx, &this_val);
    if (ctx.should_throw) return;
    if (math::is_nan(tv)) { ctx.result.set_number(double::nan); return; }
    long year, month, day, wday, hour, min, sec;
    date_break_time(tv, &year, &month, &day, &wday, &hour, &min, &sec);
    ctx.result.set_fastint(sec);
}

/// Date.prototype.getMilliseconds() — ES5 §15.9.5.24
fn void builtin_date_proto_getMilliseconds(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    double tv = date_this_time_value(ctx, &this_val);
    if (ctx.should_throw) return;
    if (math::is_nan(tv)) { ctx.result.set_number(double::nan); return; }
    long ms = (long)tv % 1000;
    if (ms < 0) ms += 1000;
    ctx.result.set_fastint(ms);
}

/// Helper: break a time value into UTC time components via gmtime_r.
fn void date_break_time_utc(double time_val, long* year, long* month, long* day,
                            long* wday, long* hour, long* minute, long* second) {
    if (math::is_nan(time_val)) {
        *year = *month = *day = *wday = *hour = *minute = *second = 0;
        return;
    }
    long t_sec = (long)(time_val / 1000.0);
    civil_from_seconds(t_sec, year, month, day, wday, hour, minute, second);
}

/// Helper: convert UTC time components to epoch ms (no timezone adjustment).
/// month may be any integer (not just [0,11]); overflow/underflow carries
/// into year first, per MakeDay's YearFromTime/MonthFromTime semantics.
fn double date_utc_to_ms(long year, long month, long day,
                         long hour, long minute, long second, long ms) {
    // floor(month / 12), computed via truncating division (C3's default for
    // integers): shifting a negative numerator down by 11 before truncating
    // matches floor division exactly, since month is always > -12*N-11 for
    // the shifted value to stay in the same truncation "cell".
    long month_floor_div = month >= 0 ? month / 12 : (month - 11) / 12;
    long y = year + month_floor_div;
    long m = month - month_floor_div * 12;  // now in [0, 11]
    if (m < 2) { y--; m += 12; }
    long era = (y >= 0 ? y : y - 399) / 400;
    long yoe = y - era * 400;
    long doy = (153 * (m - 2) + 2) / 5 + day - 1;
    long doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    long epoch_day = era * 146097 + doe - 719468;
    double maketime = duktape_date_make_time((double)hour, (double)minute, (double)second, (double)ms);
    return duktape_date_make_date((double)epoch_day, maketime);
}

/// Helper: TimeClip — clamp time value to ±8.64e15 ms per ES5 §15.9.1.14.
fn double date_time_clip(double t) {
    if (!math::is_finite(t)) return double::nan;
    if (math::abs(t) > 8.64e15) return double::nan;
    // ToInteger: sign(t) * floor(abs(t))
    double clipped = t < 0 ? -math::floor(-t) : math::floor(t);
    return clipped + 0.0;  // converts -0 to +0
}

/// Helper: set the ms value on a Date object.
fn void date_set_ms(HObject* obj, double new_ms) {
    (*obj.extra_ptr()).prim.primitive_value.set_number(new_ms);
}

/// Date.prototype.getTimezoneOffset() — ES5 §15.9.5.26
fn void builtin_date_proto_getTimezoneOffset(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    double tv = date_this_time_value(ctx, &this_val);
    if (ctx.should_throw) return;
    if (math::is_nan(tv)) { ctx.result.set_number(double::nan); return; }
    long t_sec = (long)(tv / 1000.0);
    long offset = date_tz_offset_seconds(t_sec);
    ctx.result.set_fastint(-offset / 60);
}

/// Date.prototype.getUTCFullYear() — ES5 §15.9.5.41
fn void builtin_date_proto_getUTCFullYear(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    double tv = date_this_time_value(ctx, &this_val);
    if (ctx.should_throw) return;
    if (math::is_nan(tv)) { ctx.result.set_number(double::nan); return; }
    long year, month, day, wday, hour, min, sec;
    date_break_time_utc(tv, &year, &month, &day, &wday, &hour, &min, &sec);
    ctx.result.set_fastint(year);
}

/// Date.prototype.getUTCMonth() — ES5 §15.9.5.42
fn void builtin_date_proto_getUTCMonth(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    double tv = date_this_time_value(ctx, &this_val);
    if (ctx.should_throw) return;
    if (math::is_nan(tv)) { ctx.result.set_number(double::nan); return; }
    long year, month, day, wday, hour, min, sec;
    date_break_time_utc(tv, &year, &month, &day, &wday, &hour, &min, &sec);
    ctx.result.set_fastint(month);
}

/// Date.prototype.getUTCDate() — ES5 §15.9.5.43
fn void builtin_date_proto_getUTCDate(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    double tv = date_this_time_value(ctx, &this_val);
    if (ctx.should_throw) return;
    if (math::is_nan(tv)) { ctx.result.set_number(double::nan); return; }
    long year, month, day, wday, hour, min, sec;
    date_break_time_utc(tv, &year, &month, &day, &wday, &hour, &min, &sec);
    ctx.result.set_fastint(day);
}

/// Date.prototype.getUTCDay() — ES5 §15.9.5.44
fn void builtin_date_proto_getUTCDay(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    double tv = date_this_time_value(ctx, &this_val);
    if (ctx.should_throw) return;
    if (math::is_nan(tv)) { ctx.result.set_number(double::nan); return; }
    long year, month, day, wday, hour, min, sec;
    date_break_time_utc(tv, &year, &month, &day, &wday, &hour, &min, &sec);
    ctx.result.set_fastint(wday);
}

/// Date.prototype.getUTCHours() — ES5 §15.9.5.45
fn void builtin_date_proto_getUTCHours(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    double tv = date_this_time_value(ctx, &this_val);
    if (ctx.should_throw) return;
    if (math::is_nan(tv)) { ctx.result.set_number(double::nan); return; }
    long year, month, day, wday, hour, min, sec;
    date_break_time_utc(tv, &year, &month, &day, &wday, &hour, &min, &sec);
    ctx.result.set_fastint(hour);
}

/// Date.prototype.getUTCMinutes() — ES5 §15.9.5.46
fn void builtin_date_proto_getUTCMinutes(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    double tv = date_this_time_value(ctx, &this_val);
    if (ctx.should_throw) return;
    if (math::is_nan(tv)) { ctx.result.set_number(double::nan); return; }
    long year, month, day, wday, hour, min, sec;
    date_break_time_utc(tv, &year, &month, &day, &wday, &hour, &min, &sec);
    ctx.result.set_fastint(min);
}

/// Date.prototype.getUTCSeconds() — ES5 §15.9.5.47
fn void builtin_date_proto_getUTCSeconds(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    double tv = date_this_time_value(ctx, &this_val);
    if (ctx.should_throw) return;
    if (math::is_nan(tv)) { ctx.result.set_number(double::nan); return; }
    long year, month, day, wday, hour, min, sec;
    date_break_time_utc(tv, &year, &month, &day, &wday, &hour, &min, &sec);
    ctx.result.set_fastint(sec);
}

/// Date.prototype.getUTCMilliseconds() — ES5 §15.9.5.48
fn void builtin_date_proto_getUTCMilliseconds(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    double tv = date_this_time_value(ctx, &this_val);
    if (ctx.should_throw) return;
    if (math::is_nan(tv)) { ctx.result.set_number(double::nan); return; }
    long ms = (long)tv % 1000;
    if (ms < 0) ms += 1000;
    ctx.result.set_fastint(ms);
}

/// Date.prototype.setTime(time) — ES5 §15.9.5.27
fn void builtin_date_proto_setTime(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    double tv = date_this_time_value(ctx, &this_val);
    if (ctx.should_throw) return;
    HObject* obj = (HObject*)this_val.get_heapptr();
    // ES5 §15.9.5.27: ToNumber on argument FIRST, before any NaN check
    Vm* v = (Vm*)ctx.vm;
    double t = double::nan;
    if (ctx.argc > 0) {
        t = vm::vm_to_number(v, &ctx.regs[ctx.base_reg]);
        if (v.throw_pending) {
            ctx.should_throw = true;
            ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value);
            v.throw_pending = false;
            return;
        }
    }
    double clipped = date_time_clip(t);
    date_set_ms(obj, clipped);
    ctx.result.set_number(clipped);
}

/// Date.prototype.setMilliseconds(ms) — ES5 §15.9.5.28
fn void builtin_date_proto_setMilliseconds(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    double tv = date_this_time_value(ctx, &this_val);
    if (ctx.should_throw) return;
    HObject* obj = (HObject*)this_val.get_heapptr();
    // ES5 §15.9.5.28: ToNumber on argument BEFORE NaN check on t
    Vm* v = (Vm*)ctx.vm;
    double ms = double::nan;
    if (ctx.argc > 0) {
        ms = vm::vm_to_number(v, &ctx.regs[ctx.base_reg]);
        if (v.throw_pending) {
            ctx.should_throw = true;
            ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value);
            v.throw_pending = false;
            return;
        }
    }
    if (math::is_nan(tv)) { ctx.result.set_number(double::nan); return; }
    if (math::is_nan(ms)) { date_set_ms(obj, double::nan); ctx.result.set_number(double::nan); return; }
    long year, month, day, wday, hour, min, sec;
    date_break_time(tv, &year, &month, &day, &wday, &hour, &min, &sec);
    double new_ms = date_local_to_ms(year, month, day, hour, min, sec, (long)ms);
    double clipped = date_time_clip(new_ms);
    date_set_ms(obj, clipped);
    ctx.result.set_number(clipped);
}

/// Date.prototype.setSeconds(sec[, ms]) — ES5 §15.9.5.29
fn void builtin_date_proto_setSeconds(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    double tv = date_this_time_value(ctx, &this_val);
    if (ctx.should_throw) return;
    HObject* obj = (HObject*)this_val.get_heapptr();
    // ES5 §15.9.5.29: ToNumber on ALL present arguments BEFORE NaN check on t
    Vm* v = (Vm*)ctx.vm;
    double sec_arg = double::nan;
    if (ctx.argc > 0) {
        sec_arg = vm::vm_to_number(v, &ctx.regs[ctx.base_reg]);
        if (v.throw_pending) {
            ctx.should_throw = true;
            ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value);
            v.throw_pending = false;
            return;
        }
    }
    double ms_arg = double::nan;
    if (ctx.argc > 1) {
        ms_arg = vm::vm_to_number(v, &ctx.regs[ctx.base_reg + 1]);
        if (v.throw_pending) {
            ctx.should_throw = true;
            ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value);
            v.throw_pending = false;
            return;
        }
    }
    if (math::is_nan(tv)) { ctx.result.set_number(double::nan); return; }
    // Use current ms if not provided (check argc, not NaN — NaN from ToNumber must be used)
    if (ctx.argc <= 1) { ms_arg = (double)((long)tv % 1000); if (ms_arg < 0) ms_arg += 1000; }
    // If a provided arg is NaN from ToNumber, result is NaN
    if (math::is_nan(ms_arg)) { date_set_ms(obj, double::nan); ctx.result.set_number(double::nan); return; }
    if (math::is_nan(sec_arg)) { date_set_ms(obj, double::nan); ctx.result.set_number(double::nan); return; }
    long year, month, day, wday, hour, min, sec;
    date_break_time(tv, &year, &month, &day, &wday, &hour, &min, &sec);
    double new_ms = date_local_to_ms(year, month, day, hour, min, (long)sec_arg, (long)ms_arg);
    double clipped = date_time_clip(new_ms);
    date_set_ms(obj, clipped);
    ctx.result.set_number(clipped);
}

/// Date.prototype.setMinutes(min[, sec[, ms]]) — ES5 §15.9.5.30
fn void builtin_date_proto_setMinutes(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    double tv = date_this_time_value(ctx, &this_val);
    if (ctx.should_throw) return;
    HObject* obj = (HObject*)this_val.get_heapptr();
    // ES5 §15.9.5.30: ToNumber on ALL present arguments BEFORE NaN check on t
    Vm* v = (Vm*)ctx.vm;
    double min_arg = double::nan;
    if (ctx.argc > 0) {
        min_arg = vm::vm_to_number(v, &ctx.regs[ctx.base_reg]);
        if (v.throw_pending) {
            ctx.should_throw = true;
            ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value);
            v.throw_pending = false;
            return;
        }
    }
    double sec_arg = double::nan;
    if (ctx.argc > 1) {
        sec_arg = vm::vm_to_number(v, &ctx.regs[ctx.base_reg + 1]);
        if (v.throw_pending) {
            ctx.should_throw = true;
            ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value);
            v.throw_pending = false;
            return;
        }
    }
    double ms_arg = double::nan;
    if (ctx.argc > 2) {
        ms_arg = vm::vm_to_number(v, &ctx.regs[ctx.base_reg + 2]);
        if (v.throw_pending) {
            ctx.should_throw = true;
            ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value);
            v.throw_pending = false;
            return;
        }
    }
    if (math::is_nan(tv)) { ctx.result.set_number(double::nan); return; }
    // Use current values if not provided (check argc, not NaN — NaN from ToNumber must be used)
    long sec_cur = (long)tv / 1000 % 60; if (sec_cur < 0) sec_cur += 60;
    long ms_cur  = (long)tv % 1000; if (ms_cur < 0) ms_cur += 1000;
    if (ctx.argc <= 1) { sec_arg = (double)sec_cur; }
    if (ctx.argc <= 2) { ms_arg = (double)ms_cur; }
    // If a provided arg is NaN from ToNumber, result is NaN
    if (math::is_nan(ms_arg)) { date_set_ms(obj, double::nan); ctx.result.set_number(double::nan); return; }
    if (math::is_nan(sec_arg)) { date_set_ms(obj, double::nan); ctx.result.set_number(double::nan); return; }
    if (math::is_nan(min_arg)) { date_set_ms(obj, double::nan); ctx.result.set_number(double::nan); return; }
    long year, month, day, wday, hour, min, sec;
    date_break_time(tv, &year, &month, &day, &wday, &hour, &min, &sec);
    double new_ms = date_local_to_ms(year, month, day, hour, (long)min_arg, (long)sec_arg, (long)ms_arg);
    double clipped = date_time_clip(new_ms);
    date_set_ms(obj, clipped);
    ctx.result.set_number(clipped);
}

/// Date.prototype.setHours(hour[, min[, sec[, ms]]]) — ES5 §15.9.5.31
fn void builtin_date_proto_setHours(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    double tv = date_this_time_value(ctx, &this_val);
    if (ctx.should_throw) return;
    HObject* obj = (HObject*)this_val.get_heapptr();
    // ES5 §15.9.5.31: ToNumber on ALL present arguments BEFORE NaN check on t
    Vm* v = (Vm*)ctx.vm;
    double hour_arg = double::nan;
    if (ctx.argc > 0) {
        hour_arg = vm::vm_to_number(v, &ctx.regs[ctx.base_reg]);
        if (v.throw_pending) {
            ctx.should_throw = true;
            ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value);
            v.throw_pending = false;
            return;
        }
    }
    double min_arg = double::nan;
    if (ctx.argc > 1) {
        min_arg = vm::vm_to_number(v, &ctx.regs[ctx.base_reg + 1]);
        if (v.throw_pending) {
            ctx.should_throw = true;
            ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value);
            v.throw_pending = false;
            return;
        }
    }
    double sec_arg = double::nan;
    if (ctx.argc > 2) {
        sec_arg = vm::vm_to_number(v, &ctx.regs[ctx.base_reg + 2]);
        if (v.throw_pending) {
            ctx.should_throw = true;
            ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value);
            v.throw_pending = false;
            return;
        }
    }
    double ms_arg = double::nan;
    if (ctx.argc > 3) {
        ms_arg = vm::vm_to_number(v, &ctx.regs[ctx.base_reg + 3]);
        if (v.throw_pending) {
            ctx.should_throw = true;
            ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value);
            v.throw_pending = false;
            return;
        }
    }
    if (math::is_nan(tv)) { ctx.result.set_number(double::nan); return; }
    // Use current values if not provided (check argc, not NaN — NaN from ToNumber must be used)
    long min_cur = (long)tv / 60000 % 60; if (min_cur < 0) min_cur += 60;
    long sec_cur = (long)tv / 1000 % 60; if (sec_cur < 0) sec_cur += 60;
    long ms_cur  = (long)tv % 1000; if (ms_cur < 0) ms_cur += 1000;
    if (ctx.argc <= 1) { min_arg = (double)min_cur; }
    if (ctx.argc <= 2) { sec_arg = (double)sec_cur; }
    if (ctx.argc <= 3) { ms_arg = (double)ms_cur; }
    // If a provided arg is NaN from ToNumber, result is NaN
    if (math::is_nan(ms_arg)) { date_set_ms(obj, double::nan); ctx.result.set_number(double::nan); return; }
    if (math::is_nan(sec_arg)) { date_set_ms(obj, double::nan); ctx.result.set_number(double::nan); return; }
    if (math::is_nan(min_arg)) { date_set_ms(obj, double::nan); ctx.result.set_number(double::nan); return; }
    if (math::is_nan(hour_arg)) { date_set_ms(obj, double::nan); ctx.result.set_number(double::nan); return; }
    long year, month, day, wday, hour, min, sec;
    date_break_time(tv, &year, &month, &day, &wday, &hour, &min, &sec);
    double new_ms = date_local_to_ms(year, month, day, (long)hour_arg, (long)min_arg, (long)sec_arg, (long)ms_arg);
    double clipped = date_time_clip(new_ms);
    date_set_ms(obj, clipped);
    ctx.result.set_number(clipped);
}

/// Date.prototype.setDate(date) — ES5 §15.9.5.32
fn void builtin_date_proto_setDate(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    double tv = date_this_time_value(ctx, &this_val);
    if (ctx.should_throw) return;
    HObject* obj = (HObject*)this_val.get_heapptr();
    // ES5 §15.9.5.32: ToNumber on argument BEFORE NaN check on t
    Vm* v = (Vm*)ctx.vm;
    double date_arg = double::nan;
    if (ctx.argc > 0) {
        date_arg = vm::vm_to_number(v, &ctx.regs[ctx.base_reg]);
        if (v.throw_pending) {
            ctx.should_throw = true;
            ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value);
            v.throw_pending = false;
            return;
        }
    }
    if (math::is_nan(tv)) { ctx.result.set_number(double::nan); return; }
    if (math::is_nan(date_arg)) { date_set_ms(obj, double::nan); ctx.result.set_number(double::nan); return; }
    long year, month, day, wday, hour, min, sec;
    date_break_time(tv, &year, &month, &day, &wday, &hour, &min, &sec);
    double new_ms = date_local_to_ms(year, month, (long)date_arg, hour, min, sec, (long)tv % 1000);
    double clipped = date_time_clip(new_ms);
    date_set_ms(obj, clipped);
    ctx.result.set_number(clipped);
}

/// Date.prototype.setMonth(month[, date]) — ES5 §15.9.5.33
fn void builtin_date_proto_setMonth(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    double tv = date_this_time_value(ctx, &this_val);
    if (ctx.should_throw) return;
    HObject* obj = (HObject*)this_val.get_heapptr();
    // ES5 §15.9.5.33: ToNumber on ALL present arguments BEFORE NaN check on t
    Vm* v = (Vm*)ctx.vm;
    double month_arg = double::nan;
    if (ctx.argc > 0) {
        month_arg = vm::vm_to_number(v, &ctx.regs[ctx.base_reg]);
        if (v.throw_pending) {
            ctx.should_throw = true;
            ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value);
            v.throw_pending = false;
            return;
        }
    }
    double date_arg = double::nan;
    if (ctx.argc > 1) {
        date_arg = vm::vm_to_number(v, &ctx.regs[ctx.base_reg + 1]);
        if (v.throw_pending) {
            ctx.should_throw = true;
            ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value);
            v.throw_pending = false;
            return;
        }
    }
    long year, month, day, wday, hour, min, sec;
    if (!math::is_nan(tv)) { date_break_time(tv, &year, &month, &day, &wday, &hour, &min, &sec); }
    else { year = 1970; month = 0; day = 1; hour = 0; min = 0; sec = 0; }
    if (math::is_nan(tv)) { ctx.result.set_number(double::nan); return; }
    // Use current date if not provided (check argc, not NaN — NaN from ToNumber must be used)
    if (ctx.argc <= 1) { date_arg = (double)day; }
    // If a provided arg is NaN from ToNumber, result is NaN
    if (math::is_nan(date_arg)) { date_set_ms(obj, double::nan); ctx.result.set_number(double::nan); return; }
    if (math::is_nan(month_arg)) { date_set_ms(obj, double::nan); ctx.result.set_number(double::nan); return; }
    double new_ms = date_local_to_ms(year, (long)month_arg, (long)date_arg, hour, min, sec, (long)tv % 1000);
    double clipped = date_time_clip(new_ms);
    date_set_ms(obj, clipped);
    ctx.result.set_number(clipped);
}

/// Date.prototype.setFullYear(year[, month[, date]]) — ES5 §15.9.5.40
fn void builtin_date_proto_setFullYear(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    double tv = date_this_time_value(ctx, &this_val);
    if (ctx.should_throw) return;
    HObject* obj = (HObject*)this_val.get_heapptr();
    // ES5 §15.9.5.40: ToNumber on ALL present arguments BEFORE NaN check on t
    Vm* v = (Vm*)ctx.vm;
    double year_arg = double::nan;
    if (ctx.argc > 0) {
        year_arg = vm::vm_to_number(v, &ctx.regs[ctx.base_reg]);
        if (v.throw_pending) {
            ctx.should_throw = true;
            ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value);
            v.throw_pending = false;
            return;
        }
    }
    double month_arg = double::nan;
    if (ctx.argc > 1) {
        month_arg = vm::vm_to_number(v, &ctx.regs[ctx.base_reg + 1]);
        if (v.throw_pending) {
            ctx.should_throw = true;
            ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value);
            v.throw_pending = false;
            return;
        }
    }
    double date_arg = double::nan;
    if (ctx.argc > 2) {
        date_arg = vm::vm_to_number(v, &ctx.regs[ctx.base_reg + 2]);
        if (v.throw_pending) {
            ctx.should_throw = true;
            ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value);
            v.throw_pending = false;
            return;
        }
    }
    if (math::is_nan(year_arg)) { date_set_ms(obj, double::nan); ctx.result.set_number(double::nan); return; }
    long y, m, d, wday, h, min, s;
    if (math::is_nan(tv)) { y = 1970; m = 0; d = 1; h = 0; min = 0; s = 0; }
    else { date_break_time(tv, &y, &m, &d, &wday, &h, &min, &s); }
    // Use current values if not provided (check argc, not NaN — NaN from ToNumber must be used)
    if (ctx.argc <= 1) { month_arg = (double)m; }
    if (ctx.argc <= 2) { date_arg = (double)d; }
    // If a provided arg is NaN from ToNumber, result is NaN
    if (math::is_nan(date_arg)) { date_set_ms(obj, double::nan); ctx.result.set_number(double::nan); return; }
    if (math::is_nan(month_arg)) { date_set_ms(obj, double::nan); ctx.result.set_number(double::nan); return; }
    double new_ms = date_local_to_ms((long)year_arg, (long)month_arg, (long)date_arg, h, min, s, math::is_nan(tv) ? 0 : (long)tv % 1000);
    double clipped = date_time_clip(new_ms);
    date_set_ms(obj, clipped);
    ctx.result.set_number(clipped);
}

/// Date.prototype.setUTCMilliseconds(ms) — ES5 §15.9.5.49
fn void builtin_date_proto_setUTCMilliseconds(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    double tv = date_this_time_value(ctx, &this_val);
    if (ctx.should_throw) return;
    HObject* obj = (HObject*)this_val.get_heapptr();
    // ES5 §15.9.5.49: ToNumber on argument BEFORE NaN check on t
    Vm* v = (Vm*)ctx.vm;
    double ms = double::nan;
    if (ctx.argc > 0) {
        ms = vm::vm_to_number(v, &ctx.regs[ctx.base_reg]);
        if (v.throw_pending) {
            ctx.should_throw = true;
            ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value);
            v.throw_pending = false;
            return;
        }
    }
    if (math::is_nan(tv)) { ctx.result.set_number(double::nan); return; }
    if (math::is_nan(ms)) { date_set_ms(obj, double::nan); ctx.result.set_number(double::nan); return; }
    long year, month, day, wday, hour, min, sec;
    date_break_time_utc(tv, &year, &month, &day, &wday, &hour, &min, &sec);
    double new_ms = date_utc_to_ms(year, month, day, hour, min, sec, (long)ms);
    double clipped = date_time_clip(new_ms);
    date_set_ms(obj, clipped);
    ctx.result.set_number(clipped);
}

/// Date.prototype.setUTCSeconds(sec[, ms]) — ES5 §15.9.5.50
fn void builtin_date_proto_setUTCSeconds(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    double tv = date_this_time_value(ctx, &this_val);
    if (ctx.should_throw) return;
    HObject* obj = (HObject*)this_val.get_heapptr();
    // ES5 §15.9.5.50: ToNumber on ALL present arguments BEFORE NaN check on t
    Vm* v = (Vm*)ctx.vm;
    double sec_arg = double::nan;
    if (ctx.argc > 0) {
        sec_arg = vm::vm_to_number(v, &ctx.regs[ctx.base_reg]);
        if (v.throw_pending) {
            ctx.should_throw = true;
            ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value);
            v.throw_pending = false;
            return;
        }
    }
    double ms_arg = double::nan;
    if (ctx.argc > 1) {
        ms_arg = vm::vm_to_number(v, &ctx.regs[ctx.base_reg + 1]);
        if (v.throw_pending) {
            ctx.should_throw = true;
            ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value);
            v.throw_pending = false;
            return;
        }
    }
    if (math::is_nan(tv)) { ctx.result.set_number(double::nan); return; }
    // Use current ms if not provided (check argc, not NaN — NaN from ToNumber must be used)
    if (ctx.argc <= 1) { ms_arg = (double)((long)tv % 1000); if (ms_arg < 0) ms_arg += 1000; }
    // If a provided arg is NaN from ToNumber, result is NaN
    if (math::is_nan(ms_arg)) { date_set_ms(obj, double::nan); ctx.result.set_number(double::nan); return; }
    if (math::is_nan(sec_arg)) { date_set_ms(obj, double::nan); ctx.result.set_number(double::nan); return; }
    long year, month, day, wday, hour, min, sec;
    date_break_time_utc(tv, &year, &month, &day, &wday, &hour, &min, &sec);
    double new_ms = date_utc_to_ms(year, month, day, hour, min, (long)sec_arg, (long)ms_arg);
    double clipped = date_time_clip(new_ms);
    date_set_ms(obj, clipped);
    ctx.result.set_number(clipped);
}

/// Date.prototype.setUTCMinutes(min[, sec[, ms]]) — ES5 §15.9.5.51
fn void builtin_date_proto_setUTCMinutes(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    double tv = date_this_time_value(ctx, &this_val);
    if (ctx.should_throw) return;
    HObject* obj = (HObject*)this_val.get_heapptr();
    // ES5 §15.9.5.51: ToNumber on ALL present arguments BEFORE NaN check on t
    Vm* v = (Vm*)ctx.vm;
    double min_arg = double::nan;
    if (ctx.argc > 0) {
        min_arg = vm::vm_to_number(v, &ctx.regs[ctx.base_reg]);
        if (v.throw_pending) {
            ctx.should_throw = true;
            ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value);
            v.throw_pending = false;
            return;
        }
    }
    double sec_arg = double::nan;
    if (ctx.argc > 1) {
        sec_arg = vm::vm_to_number(v, &ctx.regs[ctx.base_reg + 1]);
        if (v.throw_pending) {
            ctx.should_throw = true;
            ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value);
            v.throw_pending = false;
            return;
        }
    }
    double ms_arg = double::nan;
    if (ctx.argc > 2) {
        ms_arg = vm::vm_to_number(v, &ctx.regs[ctx.base_reg + 2]);
        if (v.throw_pending) {
            ctx.should_throw = true;
            ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value);
            v.throw_pending = false;
            return;
        }
    }
    if (math::is_nan(tv)) { ctx.result.set_number(double::nan); return; }
    // Use current values if not provided (check argc, not NaN — NaN from ToNumber must be used)
    long sec_cur = (long)tv / 1000 % 60; if (sec_cur < 0) sec_cur += 60;
    long ms_cur  = (long)tv % 1000; if (ms_cur < 0) ms_cur += 1000;
    if (ctx.argc <= 1) { sec_arg = (double)sec_cur; }
    if (ctx.argc <= 2) { ms_arg = (double)ms_cur; }
    // If a provided arg is NaN from ToNumber, result is NaN
    if (math::is_nan(ms_arg)) { date_set_ms(obj, double::nan); ctx.result.set_number(double::nan); return; }
    if (math::is_nan(sec_arg)) { date_set_ms(obj, double::nan); ctx.result.set_number(double::nan); return; }
    if (math::is_nan(min_arg)) { date_set_ms(obj, double::nan); ctx.result.set_number(double::nan); return; }
    long year, month, day, wday, hour, min, sec;
    date_break_time_utc(tv, &year, &month, &day, &wday, &hour, &min, &sec);
    double new_ms = date_utc_to_ms(year, month, day, hour, (long)min_arg, (long)sec_arg, (long)ms_arg);
    double clipped = date_time_clip(new_ms);
    date_set_ms(obj, clipped);
    ctx.result.set_number(clipped);
}

/// Date.prototype.setUTCHours(hour[, min[, sec[, ms]]]) — ES5 §15.9.5.52
fn void builtin_date_proto_setUTCHours(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    double tv = date_this_time_value(ctx, &this_val);
    if (ctx.should_throw) return;
    HObject* obj = (HObject*)this_val.get_heapptr();
    // ES5 §15.9.5.52: ToNumber on ALL present arguments BEFORE NaN check on t
    Vm* v = (Vm*)ctx.vm;
    double hour_arg = double::nan;
    if (ctx.argc > 0) {
        hour_arg = vm::vm_to_number(v, &ctx.regs[ctx.base_reg]);
        if (v.throw_pending) {
            ctx.should_throw = true;
            ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value);
            v.throw_pending = false;
            return;
        }
    }
    double min_arg = double::nan;
    if (ctx.argc > 1) {
        min_arg = vm::vm_to_number(v, &ctx.regs[ctx.base_reg + 1]);
        if (v.throw_pending) {
            ctx.should_throw = true;
            ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value);
            v.throw_pending = false;
            return;
        }
    }
    double sec_arg = double::nan;
    if (ctx.argc > 2) {
        sec_arg = vm::vm_to_number(v, &ctx.regs[ctx.base_reg + 2]);
        if (v.throw_pending) {
            ctx.should_throw = true;
            ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value);
            v.throw_pending = false;
            return;
        }
    }
    double ms_arg = double::nan;
    if (ctx.argc > 3) {
        ms_arg = vm::vm_to_number(v, &ctx.regs[ctx.base_reg + 3]);
        if (v.throw_pending) {
            ctx.should_throw = true;
            ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value);
            v.throw_pending = false;
            return;
        }
    }
    if (math::is_nan(tv)) { ctx.result.set_number(double::nan); return; }
    // Use current values if not provided (check argc, not NaN — NaN from ToNumber must be used)
    long min_cur = (long)tv / 60000 % 60; if (min_cur < 0) min_cur += 60;
    long sec_cur = (long)tv / 1000 % 60; if (sec_cur < 0) sec_cur += 60;
    long ms_cur  = (long)tv % 1000; if (ms_cur < 0) ms_cur += 1000;
    if (ctx.argc <= 1) { min_arg = (double)min_cur; }
    if (ctx.argc <= 2) { sec_arg = (double)sec_cur; }
    if (ctx.argc <= 3) { ms_arg = (double)ms_cur; }
    // If a provided arg is NaN from ToNumber, result is NaN
    if (math::is_nan(ms_arg)) { date_set_ms(obj, double::nan); ctx.result.set_number(double::nan); return; }
    if (math::is_nan(sec_arg)) { date_set_ms(obj, double::nan); ctx.result.set_number(double::nan); return; }
    if (math::is_nan(min_arg)) { date_set_ms(obj, double::nan); ctx.result.set_number(double::nan); return; }
    if (math::is_nan(hour_arg)) { date_set_ms(obj, double::nan); ctx.result.set_number(double::nan); return; }
    long year, month, day, wday, hour, min, sec;
    date_break_time_utc(tv, &year, &month, &day, &wday, &hour, &min, &sec);
    double new_ms = date_utc_to_ms(year, month, day, (long)hour_arg, (long)min_arg, (long)sec_arg, (long)ms_arg);
    double clipped = date_time_clip(new_ms);
    date_set_ms(obj, clipped);
    ctx.result.set_number(clipped);
}

/// Date.prototype.setUTCDate(date) — ES5 §15.9.5.53
fn void builtin_date_proto_setUTCDate(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    double tv = date_this_time_value(ctx, &this_val);
    if (ctx.should_throw) return;
    HObject* obj = (HObject*)this_val.get_heapptr();
    // ES5 §15.9.5.53: ToNumber on argument BEFORE NaN check on t
    Vm* v = (Vm*)ctx.vm;
    double date_arg = double::nan;
    if (ctx.argc > 0) {
        date_arg = vm::vm_to_number(v, &ctx.regs[ctx.base_reg]);
        if (v.throw_pending) {
            ctx.should_throw = true;
            ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value);
            v.throw_pending = false;
            return;
        }
    }
    if (math::is_nan(tv)) { ctx.result.set_number(double::nan); return; }
    if (math::is_nan(date_arg)) { date_set_ms(obj, double::nan); ctx.result.set_number(double::nan); return; }
    long year, month, day, wday, hour, min, sec;
    date_break_time_utc(tv, &year, &month, &day, &wday, &hour, &min, &sec);
    double new_ms = date_utc_to_ms(year, month, (long)date_arg, hour, min, sec, (long)tv % 1000);
    double clipped = date_time_clip(new_ms);
    date_set_ms(obj, clipped);
    ctx.result.set_number(clipped);
}

/// Date.prototype.setUTCMonth(month[, date]) — ES5 §15.9.5.54
fn void builtin_date_proto_setUTCMonth(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    double tv = date_this_time_value(ctx, &this_val);
    if (ctx.should_throw) return;
    HObject* obj = (HObject*)this_val.get_heapptr();
    // ES5 §15.9.5.54: ToNumber on ALL present arguments BEFORE NaN check on t
    Vm* v = (Vm*)ctx.vm;
    double month_arg = double::nan;
    if (ctx.argc > 0) {
        month_arg = vm::vm_to_number(v, &ctx.regs[ctx.base_reg]);
        if (v.throw_pending) {
            ctx.should_throw = true;
            ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value);
            v.throw_pending = false;
            return;
        }
    }
    double date_arg = double::nan;
    if (ctx.argc > 1) {
        date_arg = vm::vm_to_number(v, &ctx.regs[ctx.base_reg + 1]);
        if (v.throw_pending) {
            ctx.should_throw = true;
            ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value);
            v.throw_pending = false;
            return;
        }
    }
    long year, month, day, wday, hour, min, sec;
    if (!math::is_nan(tv)) { date_break_time_utc(tv, &year, &month, &day, &wday, &hour, &min, &sec); }
    else { year = 1970; month = 0; day = 1; hour = 0; min = 0; sec = 0; }
    if (math::is_nan(tv)) { ctx.result.set_number(double::nan); return; }
    // Use current date if not provided (check argc, not NaN — NaN from ToNumber must be used)
    if (ctx.argc <= 1) { date_arg = (double)day; }
    // If a provided arg is NaN from ToNumber, result is NaN
    if (math::is_nan(date_arg)) { date_set_ms(obj, double::nan); ctx.result.set_number(double::nan); return; }
    if (math::is_nan(month_arg)) { date_set_ms(obj, double::nan); ctx.result.set_number(double::nan); return; }
    double new_ms = date_utc_to_ms(year, (long)month_arg, (long)date_arg, hour, min, sec, (long)tv % 1000);
    double clipped = date_time_clip(new_ms);
    date_set_ms(obj, clipped);
    ctx.result.set_number(clipped);
}

/// Date.prototype.setUTCFullYear(year[, month[, date]]) — ES5 §15.9.5.55
fn void builtin_date_proto_setUTCFullYear(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    double tv = date_this_time_value(ctx, &this_val);
    if (ctx.should_throw) return;
    HObject* obj = (HObject*)this_val.get_heapptr();
    // ES5 §15.9.5.55: ToNumber on ALL present arguments BEFORE NaN check on t
    Vm* v = (Vm*)ctx.vm;
    double year_arg = double::nan;
    if (ctx.argc > 0) {
        year_arg = vm::vm_to_number(v, &ctx.regs[ctx.base_reg]);
        if (v.throw_pending) {
            ctx.should_throw = true;
            ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value);
            v.throw_pending = false;
            return;
        }
    }
    double month_arg = double::nan;
    if (ctx.argc > 1) {
        month_arg = vm::vm_to_number(v, &ctx.regs[ctx.base_reg + 1]);
        if (v.throw_pending) {
            ctx.should_throw = true;
            ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value);
            v.throw_pending = false;
            return;
        }
    }
    double date_arg = double::nan;
    if (ctx.argc > 2) {
        date_arg = vm::vm_to_number(v, &ctx.regs[ctx.base_reg + 2]);
        if (v.throw_pending) {
            ctx.should_throw = true;
            ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value);
            v.throw_pending = false;
            return;
        }
    }
    if (math::is_nan(year_arg)) { date_set_ms(obj, double::nan); ctx.result.set_number(double::nan); return; }
    long y, m, d, wday, h, min, s;
    if (math::is_nan(tv)) { y = 1970; m = 0; d = 1; h = 0; min = 0; s = 0; }
    else { date_break_time_utc(tv, &y, &m, &d, &wday, &h, &min, &s); }
    // Use current values if not provided (check argc, not NaN — NaN from ToNumber must be used)
    if (ctx.argc <= 1) { month_arg = (double)m; }
    if (ctx.argc <= 2) { date_arg = (double)d; }
    // If a provided arg is NaN from ToNumber, result is NaN
    if (math::is_nan(date_arg)) { date_set_ms(obj, double::nan); ctx.result.set_number(double::nan); return; }
    if (math::is_nan(month_arg)) { date_set_ms(obj, double::nan); ctx.result.set_number(double::nan); return; }
    double new_ms = date_utc_to_ms((long)year_arg, (long)month_arg, (long)date_arg, h, min, s, math::is_nan(tv) ? 0 : (long)tv % 1000);
    double clipped = date_time_clip(new_ms);
    date_set_ms(obj, clipped);
    ctx.result.set_number(clipped);
}

/// Helper: pad integer to 2 digits
fn void date_pad2(char* buf, long val) {
    if (val < 10) { buf[0] = '0'; buf[1] = (char)(val + 48); }
    else { buf[0] = (char)(val / 10 + 48); buf[1] = (char)(val % 10 + 48); }
}

/// Helper: pad |val| (positive) to 4 digits, buf[0..3].
/// Callers handle sign separately. For dates, val is always 0..9999 here.
fn void date_pad4(char* buf, long val) {
    buf[0] = (char)(val / 1000 % 10 + 48);
    buf[1] = (char)(val / 100 % 10 + 48);
    buf[2] = (char)(val / 10 % 10 + 48);
    buf[3] = (char)(val % 10 + 48);
}

/// Date.prototype.toISOString() — ES5 §15.9.5.43
/// Returns a string in ISO 8601 format: "YYYY-MM-DDTHH:mm:ss.sssZ".
/// Throws RangeError if the date value is NaN.
fn void builtin_date_proto_toISOString(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    double tv = date_this_time_value(ctx, &this_val);
    if (ctx.should_throw) return;
    if (math::is_nan(tv)) {
        // Throw RangeError per ES5 §15.9.5.43
        builtin_throw(ctx, ctx.heap.range_err_proto, "Invalid Date");
        return;
    }
    long year, month, day, wday, hour, min, sec;
    date_break_time_utc(tv, &year, &month, &day, &wday, &hour, &min, &sec);
    long ms = (long)tv % 1000; if (ms < 0) ms += 1000;

    // Expanded format for large years (>=10000 or <=-9999): +YYYYYY or -YYYYYY
    if (year >= 10000 || year <= -9999) {
        char[27] buf;
        long abs_year = (year < 0) ? -year : year;
        buf[0] = (year < 0) ? '-' : '+';
        buf[1] = (char)(abs_year / 100000 % 10 + 48);
        buf[2] = (char)(abs_year / 10000 % 10 + 48);
        buf[3] = (char)(abs_year / 1000 % 10 + 48);
        buf[4] = (char)(abs_year / 100 % 10 + 48);
        buf[5] = (char)(abs_year / 10 % 10 + 48);
        buf[6] = (char)(abs_year % 10 + 48);
        buf[7] = '-';
        date_pad2(&buf[8], month + 1);
        buf[10] = '-';
        date_pad2(&buf[11], day);
        buf[13] = 'T';
        date_pad2(&buf[14], hour);
        buf[16] = ':';
        date_pad2(&buf[17], min);
        buf[19] = ':';
        date_pad2(&buf[20], sec);
        buf[22] = '.';
        buf[23] = (char)(ms / 100 + 48);
        buf[24] = (char)(ms / 10 % 10 + 48);
        buf[25] = (char)(ms % 10 + 48);
        buf[26] = 'Z';
        ctx.result.set_string(builtin_intern_string(ctx.heap, buf[0:27]));
    } else if (year < 0) {
        // Negative year within standard range: -YYYY-MM-DDTHH:mm:ss.sssZ (25 bytes)
        char[25] buf;
        buf[0] = '-';
        long neg_year = -year;
        buf[1] = (char)(neg_year / 1000 + 48);
        buf[2] = (char)(neg_year / 100 % 10 + 48);
        buf[3] = (char)(neg_year / 10 % 10 + 48);
        buf[4] = (char)(neg_year % 10 + 48);
        buf[5] = '-';
        date_pad2(&buf[6], month + 1);
        buf[8] = '-';
        date_pad2(&buf[9], day);
        buf[11] = 'T';
        date_pad2(&buf[12], hour);
        buf[14] = ':';
        date_pad2(&buf[15], min);
        buf[17] = ':';
        date_pad2(&buf[18], sec);
        buf[20] = '.';
        buf[21] = (char)(ms / 100 + 48);
        buf[22] = (char)(ms / 10 % 10 + 48);
        buf[23] = (char)(ms % 10 + 48);
        buf[24] = 'Z';
        ctx.result.set_string(builtin_intern_string(ctx.heap, buf[0:25]));
    } else {
        // Standard format: YYYY-MM-DDTHH:mm:ss.sssZ (24 bytes)
        char[24] buf;
        date_pad4(&buf[0], year);
        buf[4] = '-';
        date_pad2(&buf[5], month + 1);
        buf[7] = '-';
        date_pad2(&buf[8], day);
        buf[10] = 'T';
        date_pad2(&buf[11], hour);
        buf[13] = ':';
        date_pad2(&buf[14], min);
        buf[16] = ':';
        date_pad2(&buf[17], sec);
        buf[19] = '.';
        buf[20] = (char)(ms / 100 + 48);
        buf[21] = (char)(ms / 10 % 10 + 48);
        buf[22] = (char)(ms % 10 + 48);
        buf[23] = 'Z';
        ctx.result.set_string(builtin_intern_string(ctx.heap, buf[0:24]));
    }
}

/// Date.prototype.toUTCString() — ES5 §15.9.5.44
fn void builtin_date_proto_toUTCString(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    double tv = date_this_time_value(ctx, &this_val);
    if (ctx.should_throw) return;
    if (math::is_nan(tv)) { ctx.result.set_string(builtin_intern_string(ctx.heap, "Invalid Date")); return; }
    long year, month, day, wday, hour, min, sec;
    date_break_time_utc(tv, &year, &month, &day, &wday, &hour, &min, &sec);
    char[7][] day_names = { "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };
    char[12][] mon_names = { "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
    // ES6 §21.4.3.4 ToDateString year format: 4-digit zero-padded positive;
    // "-%04d" for negative year in [-9999, 0); full integer for |y| >= 10000.
    char[24] year_str;
    if (year < 0 && year > -10000) {
        (void)io::bprintf(&year_str, "-%04d", -year);
    } else if (year <= -10000) {
        (void)io::bprintf(&year_str, "%d", year);
    } else {
        (void)io::bprintf(&year_str, "%04d", year);
    }
    char[types::FORMAT_BUF] buf;
    // "Thu, 01 Jan 1970 00:00:00 GMT" / "Thu, 01 Jan -0001 00:00:00 GMT"
    usz len = (usz)(io::bprintf(&buf, "%.3s, %02d %.3s %s %02d:%02d:%02d GMT",
        (ZString)&day_names[wday][0], (int)day, (ZString)&mon_names[month][0],
        (ZString)&year_str[0], (int)hour, (int)min, (int)sec) ?? buf[:0]).len;
    ctx.result.set_string(builtin_intern_string(ctx.heap, buf[:len]));
}

// ============================================================================
// Date constructor registration
// ============================================================================

/// Create Date.prototype and register the Date constructor globally.
fn bool register_date_constructor(EnvRecord* global_env, Heap* heap) {
    // Create Date.prototype
    HObject*? proto_raw = heap.alloc_object(hobject::ObjClass.DATE);
    if (catch err = proto_raw) return false;
    HObject* proto = proto_raw;
    proto.prototype = null;  // Will be Object.prototype
    // Initialize primitive_value to NaN so Date.prototype is not treated as
    // a valid Date instance by thisTimeValue (it has class DATE but no
    // [[DateValue]] internal slot per ES2015 §20.4.3.1).
    (*proto.extra_ptr()).prim.primitive_value.set_number(double::nan);
    // Date.prototype is a DATE object that does NOT have a [[DateValue]] slot
    // (ES5 §15.9.1.1, §15.9.4). Flag it so thisTimeValue throws TypeError
    // when called with Date.prototype as `this` — while a real Date instance
    // holding NaN as its time value still returns NaN from getDate/etc.
    proto.flags.is_date_proto = true;
    heap.date_proto = proto;

    // .constructor is wired below (after the constructor HObject exists) to
    // point at the function object itself, not a lightfunc — see below.

    // Add Date.prototype.toString()
    if (!register_string_proto_method(proto, heap, "toString", Builtin.DATE_PROTO_TOSTRING.ordinal)) return false;

    // Add Date.prototype.toJSON()
    if (!register_string_proto_method(proto, heap, "toJSON", Builtin.DATE_PROTO_TOJSON.ordinal)) return false;

    // Add Date.prototype.data.valueOf()
    if (!register_string_proto_method(proto, heap, "valueOf", Builtin.DATE_PROTO_VALUEOF.ordinal)) return false;

    // Add Date.prototype[Symbol.toPrimitive] — ES2023 §21.4.4.45.
    // Property descriptor: writable:false, enumerable:false, configurable:true.
    {
        HString* toprim_key = ensure_toprimitive_symbol(heap);
        if (toprim_key != null) {
            TVal toprim_tv;
            toprim_tv.set_lightfunc((void*)(usz)Builtin.DATE_PROTO_TOPRIMITIVE.ordinal);
            PropFlags tp_flags;
            tp_flags.writable = false;
            tp_flags.enumerable = false;
            tp_flags.configurable = true;
            tp_flags.is_accessor = false;
            proto.put_prop(toprim_key, toprim_tv, tp_flags);
        }
    }

    // Add Date.prototype.getTime()
    if (!register_string_proto_method(proto, heap, "getTime", Builtin.DATE_PROTO_GETTIME.ordinal)) return false;

    // Add Date.prototype.getFullYear()
    if (!register_string_proto_method(proto, heap, "getFullYear", Builtin.DATE_PROTO_GETFULLYEAR.ordinal)) return false;

    // Add Date.prototype.getMonth()
    if (!register_string_proto_method(proto, heap, "getMonth", Builtin.DATE_PROTO_GETMONTH.ordinal)) return false;

    // Add Date.prototype.getDate()
    if (!register_string_proto_method(proto, heap, "getDate", Builtin.DATE_PROTO_GETDATE.ordinal)) return false;

    // Add Date.prototype.getDay()
    if (!register_string_proto_method(proto, heap, "getDay", Builtin.DATE_PROTO_GETDAY.ordinal)) return false;

    // Add Date.prototype.getHours()
    if (!register_string_proto_method(proto, heap, "getHours", Builtin.DATE_PROTO_GETHOURS.ordinal)) return false;

    // Add Date.prototype.getMinutes()
    if (!register_string_proto_method(proto, heap, "getMinutes", Builtin.DATE_PROTO_GETMINUTES.ordinal)) return false;

    // Add Date.prototype.getSeconds()
    if (!register_string_proto_method(proto, heap, "getSeconds", Builtin.DATE_PROTO_GETSECONDS.ordinal)) return false;

    // Add Date.prototype.getMilliseconds()
    if (!register_string_proto_method(proto, heap, "getMilliseconds", Builtin.DATE_PROTO_GETMILLISECONDS.ordinal)) return false;

    // Add Date.prototype.getTimezoneOffset()
    if (!register_string_proto_method(proto, heap, "getTimezoneOffset", Builtin.DATE_PROTO_GETTIMEZONEOFFSET.ordinal)) return false;

    // Add Date.prototype.getUTCFullYear()
    if (!register_string_proto_method(proto, heap, "getUTCFullYear", Builtin.DATE_PROTO_GETUTCFULLYEAR.ordinal)) return false;

    // Add Date.prototype.getUTCMonth()
    if (!register_string_proto_method(proto, heap, "getUTCMonth", Builtin.DATE_PROTO_GETUTCMONTH.ordinal)) return false;

    // Add Date.prototype.getUTCDate()
    if (!register_string_proto_method(proto, heap, "getUTCDate", Builtin.DATE_PROTO_GETUTCDATE.ordinal)) return false;

    // Add Date.prototype.getUTCDay()
    if (!register_string_proto_method(proto, heap, "getUTCDay", Builtin.DATE_PROTO_GETUTCDAY.ordinal)) return false;

    // Add Date.prototype.getUTCHours()
    if (!register_string_proto_method(proto, heap, "getUTCHours", Builtin.DATE_PROTO_GETUTCHOURS.ordinal)) return false;

    // Add Date.prototype.getUTCMinutes()
    if (!register_string_proto_method(proto, heap, "getUTCMinutes", Builtin.DATE_PROTO_GETUTCMINUTES.ordinal)) return false;

    // Add Date.prototype.getUTCSeconds()
    if (!register_string_proto_method(proto, heap, "getUTCSeconds", Builtin.DATE_PROTO_GETUTCSECONDS.ordinal)) return false;

    // Add Date.prototype.getUTCMilliseconds()
    if (!register_string_proto_method(proto, heap, "getUTCMilliseconds", Builtin.DATE_PROTO_GETUTCMILLISECONDS.ordinal)) return false;

    // Add Date.prototype.setTime()
    if (!register_string_proto_method(proto, heap, "setTime", Builtin.DATE_PROTO_SETTIME.ordinal)) return false;

    // Add Date.prototype.setMilliseconds()
    if (!register_string_proto_method(proto, heap, "setMilliseconds", Builtin.DATE_PROTO_SETMILLISECONDS.ordinal)) return false;

    // Add Date.prototype.setSeconds()
    if (!register_string_proto_method(proto, heap, "setSeconds", Builtin.DATE_PROTO_SETSECONDS.ordinal)) return false;

    // Add Date.prototype.setMinutes()
    if (!register_string_proto_method(proto, heap, "setMinutes", Builtin.DATE_PROTO_SETMINUTES.ordinal)) return false;

    // Add Date.prototype.setHours()
    if (!register_string_proto_method(proto, heap, "setHours", Builtin.DATE_PROTO_SETHOURS.ordinal)) return false;

    // Add Date.prototype.setDate()
    if (!register_string_proto_method(proto, heap, "setDate", Builtin.DATE_PROTO_SETDATE.ordinal)) return false;

    // Add Date.prototype.setMonth()
    if (!register_string_proto_method(proto, heap, "setMonth", Builtin.DATE_PROTO_SETMONTH.ordinal)) return false;

    // Add Date.prototype.setFullYear()
    if (!register_string_proto_method(proto, heap, "setFullYear", Builtin.DATE_PROTO_SETFULLYEAR.ordinal)) return false;

    // Add Date.prototype.setUTCMilliseconds()
    if (!register_string_proto_method(proto, heap, "setUTCMilliseconds", Builtin.DATE_PROTO_SETUTCMILLISECONDS.ordinal)) return false;

    // Add Date.prototype.setUTCSeconds()
    if (!register_string_proto_method(proto, heap, "setUTCSeconds", Builtin.DATE_PROTO_SETUTCSECONDS.ordinal)) return false;

    // Add Date.prototype.setUTCMinutes()
    if (!register_string_proto_method(proto, heap, "setUTCMinutes", Builtin.DATE_PROTO_SETUTCMINUTES.ordinal)) return false;

    // Add Date.prototype.setUTCHours()
    if (!register_string_proto_method(proto, heap, "setUTCHours", Builtin.DATE_PROTO_SETUTCHOURS.ordinal)) return false;

    // Add Date.prototype.setUTCDate()
    if (!register_string_proto_method(proto, heap, "setUTCDate", Builtin.DATE_PROTO_SETUTCDATE.ordinal)) return false;

    // Add Date.prototype.setUTCMonth()
    if (!register_string_proto_method(proto, heap, "setUTCMonth", Builtin.DATE_PROTO_SETUTCMONTH.ordinal)) return false;

    // Add Date.prototype.setUTCFullYear()
    if (!register_string_proto_method(proto, heap, "setUTCFullYear", Builtin.DATE_PROTO_SETUTCFULLYEAR.ordinal)) return false;

    // Add Date.prototype.toISOString()
    if (!register_string_proto_method(proto, heap, "toISOString", Builtin.DATE_PROTO_TOISOSTRING.ordinal)) return false;

    // Add Date.prototype.toUTCString()
    if (!register_string_proto_method(proto, heap, "toUTCString", Builtin.DATE_PROTO_TOUTCSTRING.ordinal)) return false;

    // Add Date.prototype.toLocaleString() — ES5 §15.9.5.5
    if (!register_string_proto_method(proto, heap, "toLocaleString", Builtin.DATE_PROTO_TOLOCALESTRING.ordinal)) return false;

    // Add Date.prototype.toLocaleDateString() — ES5 §15.9.5.6
    if (!register_string_proto_method(proto, heap, "toLocaleDateString", Builtin.DATE_PROTO_TOLOCALEDATESTRING.ordinal)) return false;

    // Add Date.prototype.toLocaleTimeString() — ES5 §15.9.5.7
    if (!register_string_proto_method(proto, heap, "toLocaleTimeString", Builtin.DATE_PROTO_TOLOCALETIMESTRING.ordinal)) return false;

    // Add Date.prototype.toDateString() — ES5 §15.9.5.3
    if (!register_string_proto_method(proto, heap, "toDateString", Builtin.DATE_PROTO_TODATESTRING.ordinal)) return false;

    // Add Date.prototype.toTimeString() — ES5 §15.9.5.4
    if (!register_string_proto_method(proto, heap, "toTimeString", Builtin.DATE_PROTO_TOTIMESTRING.ordinal)) return false;

    // Register Date as a global constructor (proper function object for static methods)
    HObject*? date_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
    if (catch err = date_raw) return false;
    HObject* date_obj = date_raw;
    (*date_obj.extra_ptr()).func.builtin_fn_index = (int)Builtin.DATE.ordinal;

    // Set .constructor to the Date constructor object itself (function object),
    // matching how Function.prototype.constructor is wired. Using a lightfunc
    // here would create a separate identity from `Date`, breaking
    // `new Date().constructor === Date`.
    HString* constructor_key = (HString*)heap.strs[heap::BuiltinStr.CONSTRUCTOR];
    TVal constructor_tv;
    constructor_tv.set_object(date_obj);
    proto.put_prop(constructor_key, constructor_tv, hobject::PROP_FLAGS_WC);

    // Set Date.prototype on the constructor
    HString* prototype_key = (HString*)heap.strs[heap::BuiltinStr.PROTOTYPE];
    TVal proto_tv;
    proto_tv.set_object(proto);
    PropFlags proto_pflags;
    proto_pflags.writable = false;
    proto_pflags.enumerable = false;
    proto_pflags.configurable = false;
    proto_pflags.is_accessor = false;
    date_obj.put_prop(prototype_key, proto_tv, proto_pflags);

    // Add Date.now() static method
    if (!register_string_proto_method(date_obj, heap, "now", Builtin.DATE_NOW.ordinal)) return false;

    // Add Date.UTC() static method
    if (!register_string_proto_method(date_obj, heap, "UTC", Builtin.DATE_UTC.ordinal)) return false;

    // Add Date.parse() static method
    if (!register_string_proto_method(date_obj, heap, "parse", Builtin.DATE_PARSE.ordinal)) return false;

    // Register Date constructor globally as an OBJECT
    uint hash = heap.hash_string("Date");
    HString* existing = heap.str_table_lookup("Date", hash);
    HString* date_key;
    if (existing != null) {
        date_key = existing;
    } else {
        HString*? new_key = hstring::hstring_alloc(heap, "Date", hash);
        if (catch err = new_key) return false;
        heap.str_table_insert(new_key);
        date_key = new_key;
    }
    TVal date_val;
    date_val.set_object(date_obj);
    set_func_ctor_name_length(date_obj, heap, "Date", 7);
    env::env_declare_nonenum(global_env, date_key, date_val);

    return true;
}
