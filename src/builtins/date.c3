/// Date constructor and Date.prototype methods.
module tinyduck::builtins;
import tinyduck::types;
import std::math;
import tinyduck::env;

import tinyduck::heap;
import tinyduck::hstring;
import tinyduck::hobject;
import libc;

// ============================================================================
// Date constructor and methods (ES5 §15.9)
// ============================================================================

/// ECMAScript epoch: 1970-01-01 00:00:00 UTC.
const long EPOCH_YEAR = 1970;

/// Helper: get current time in milliseconds since epoch.
fn double date_now_ms() {
    long t = libc::time(null);
    return (double)t * 1000.0;
}

/// Helper: get the time value from a Date object, or NaN if not a Date.
fn double date_get_time_value(TVal* val) {
    if (val.is_object() && val.get_heapptr() != null) {
        HObject* obj = (HObject*)val.get_heapptr();
        if (obj.get_class() == hobject::ObjClass.DATE &&
            ((*obj.extra_ptr()).prim.primitive_value.is_number() || (*obj.extra_ptr()).prim.primitive_value.is_fastint())) {
            return (*obj.extra_ptr()).prim.primitive_value.get_number_or_fastint();
        }
    }
    return double::nan;
}

/// Helper: convert local time components to epoch ms using mktime.
fn double date_local_to_ms(long year, long month, long day,
                           long hour, long minute, long second, long ms) {
    Tm tm;
    tm.tm_sec   = (int)second;
    tm.tm_min   = (int)minute;
    tm.tm_hour  = (int)hour;
    tm.tm_mday  = (int)day;
    tm.tm_mon   = (int)month;
    tm.tm_year  = (int)year - 1900;
    tm.tm_wday  = 0;
    tm.tm_yday  = 0;
    tm.tm_isdst = -1;  // let mktime determine DST
    long epoch_sec = (long)libc::mktime(&tm);
    if (epoch_sec == -1) {
        // Use approximate computation as fallback
        // 86400 seconds per day, assume no DST issues
        // This is approximate but better than NaN
        long days = (year - 1970) * 365 + (year - 1969) / 4 - (year - 1901) / 100 + (year - 1601) / 400;
        // Add months
        long[12] days_in_months = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
        bool leap = (year % 4 == 0 && year % 100 != 0) || (year % 400 == 0);
        for (long m = 0; m < month; m++) {
            days += days_in_months[m];
            if (leap && m == 1) days++;
        }
        days += day - 1;
        epoch_sec = days * 86400 + hour * 3600 + minute * 60 + second;
    }
    return (double)epoch_sec * 1000.0 + (double)ms;
}

/// Format a Date as a string like "Mon Jan 01 2024 12:00:00 GMT+0000".
fn usz date_format_to_string(double time_val, char* buf, usz buf_size) {
    // For NaN, return "Invalid Date"
    if (math::is_nan(time_val)) {
        return (usz)libc::snprintf(buf, buf_size, "Invalid Date");
    }
    long t_sec = (long)(time_val / 1000.0);
    Tm result;
    libc::localtime_r(&t_sec, &result);
    Tm* tm = &result;

    // Compute timezone offset by comparing localtime with a gmtime conversion
    // Use mktime on the local tm to get epoch, then compare with raw input
    long local_as_epoch = (long)libc::mktime(tm);
    // If mktime fails, local_as_epoch could be -1
    if (local_as_epoch == -1) local_as_epoch = t_sec;
    long tz_seconds = local_as_epoch - t_sec;
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
    switch (tm.tm_wday) {
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
    switch (tm.tm_mon) {
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

    return (usz)libc::snprintf(buf, buf_size, "%s %s %02d %04d %02d:%02d:%02d GMT%c%02d%02d",
        wday_name, mon_name,
        tm.tm_mday, tm.tm_year + 1900,
        tm.tm_hour, tm.tm_min, tm.tm_sec,
        tz_sign, offs_hours, offs_mins);
}

/// Format a Date as ISO 8601 string (used by toJSON).
fn usz date_format_iso(double time_val, char* buf, usz buf_size) {
    if (math::is_nan(time_val)) {
        return (usz)libc::snprintf(buf, buf_size, "null");
    }
    long t_sec = (long)(time_val / 1000.0);
    Tm result;
    libc::localtime_r(&t_sec, &result);
    Tm* tm = &result;

    // Compute timezone offset
    long local_as_epoch = (long)libc::mktime(tm);
    if (local_as_epoch == -1) local_as_epoch = t_sec;
    long tz_seconds = local_as_epoch - t_sec;
    char tz_sign = '+';
    int offs_hours = (int)(tz_seconds / 3600);
    int offs_mins = (int)((tz_seconds / 60) % 60);
    if (tz_seconds < 0) {
        tz_sign = '-';
        offs_hours = -offs_hours;
        offs_mins = -offs_mins;
    }
    int ms = (int)((long)time_val % 1000);
    if (ms < 0) ms += 1000;

    return (usz)libc::snprintf(buf, buf_size,
        "%04d-%02d-%02dT%02d:%02d:%02d.%03d%c%02d:%02d",
        tm.tm_year + 1900, tm.tm_mon + 1, tm.tm_mday,
        tm.tm_hour, tm.tm_min, tm.tm_sec, ms,
        tz_sign, offs_hours, offs_mins);
}

/// Parse an ISO 8601 date string into milliseconds since epoch.
/// Supported formats: "YYYY-MM-DDTHH:mm:ss.sssZ", "YYYY-MM-DDTHH:mm:ssZ",
/// "YYYY-MM-DD". Returns NaN on parse failure.
fn double date_parse_iso_str(char* str, usz len) {
    // Minimum: "YYYY-MM-DD" = 10 chars
    if (len < 10) return double::nan;

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

    // Expect '-'
    if (pos >= len || str[pos] != '-') return double::nan;
    pos++;

    // Parse month (2 digits)
    long month = 0;
    usz month_start = pos;
    while (pos < len && str[pos] >= '0' && str[pos] <= '9') {
        month = month * 10 + (long)(str[pos] - '0');
        pos++;
    }
    if (pos - month_start != 2) return double::nan;

    // Expect '-'
    if (pos >= len || str[pos] != '-') return double::nan;
    pos++;

    // Parse day (2 digits)
    long day = 0;
    usz day_start = pos;
    while (pos < len && str[pos] >= '0' && str[pos] <= '9') {
        day = day * 10 + (long)(str[pos] - '0');
        pos++;
    }
    if (pos - day_start != 2) return double::nan;

    long hour = 0;
    long minute = 0;
    long second = 0;
    long millis = 0;

    // Optional time part: 'T' or space
    if (pos < len && (str[pos] == 'T' || str[pos] == ' ')) {
        pos++;

        // Parse hour (2 digits)
        usz hour_start = pos;
        while (pos < len && str[pos] >= '0' && str[pos] <= '9') {
            hour = hour * 10 + (long)(str[pos] - '0');
            pos++;
        }
        if (pos - hour_start != 2) return double::nan;

        if (pos >= len || str[pos] != ':') return double::nan;
        pos++;

        // Parse minute (2 digits)
        usz min_start = pos;
        while (pos < len && str[pos] >= '0' && str[pos] <= '9') {
            minute = minute * 10 + (long)(str[pos] - '0');
            pos++;
        }
        if (pos - min_start != 2) return double::nan;

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

    // Optional timezone designator
    if (pos < len && str[pos] == 'Z') {
        // UTC timezone — use date_utc_to_ms
        pos++;
        return date_utc_to_ms(year, month - 1, day, hour, minute, second, millis);
    } else if (pos + 5 < len && (str[pos] == '+' || str[pos] == '-')) {
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
        return local_ms - (double)offset_ms;
    }

    // Use date_local_to_ms for local time
    return date_local_to_ms(year, month - 1, day, hour, minute, second, millis);
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

        double time_val;
        if (ctx.argc == 0) {
            time_val = now;
        } else if (ctx.argc == 1) {
            TVal* arg = &ctx.regs[ctx.base_reg];
            if (arg.is_string()) {
                // Parse string: try ISO 8601 first, then as number
                HString* s = (HString*)arg.get_heapptr();
                char* str = s.get_cstr();
                usz slen = s.blen;
                time_val = date_parse_iso_str(str, slen);
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
            } else {
                time_val = now;
            }
        } else {
            // Multiple args: Date(year, month[, day, hour, minute, second, ms])
            TVal* year_arg  = &ctx.regs[ctx.base_reg];
            TVal* month_arg = &ctx.regs[ctx.base_reg + 1];
            double year  = year_arg.get_number_or_fastint();
            double month = month_arg.get_number_or_fastint();
            double day   = (ctx.argc > 2) ? ctx.regs[ctx.base_reg + 2].get_number_or_fastint() : 1.0;
            double hour  = (ctx.argc > 3) ? ctx.regs[ctx.base_reg + 3].get_number_or_fastint() : 0.0;
            double min   = (ctx.argc > 4) ? ctx.regs[ctx.base_reg + 4].get_number_or_fastint() : 0.0;
            double sec   = (ctx.argc > 5) ? ctx.regs[ctx.base_reg + 5].get_number_or_fastint() : 0.0;
            double ms    = (ctx.argc > 6) ? ctx.regs[ctx.base_reg + 6].get_number_or_fastint() : 0.0;

            // Year < 100 means 1900 + year
            if (year >= 0 && year < 100) year += 1900;

            time_val = date_local_to_ms((long)year, (long)month, (long)day,
                                        (long)hour, (long)min, (long)sec, (long)ms);
        }

        (*obj.extra_ptr()).prim.primitive_value.set_number(time_val);

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

/// Date.UTC(year, month[, day, hour, minute, second, ms]) — ES5 §15.9.4.3
fn void builtin_date_utc(BuiltinContext* ctx) {
    if (ctx.argc < 2) {
        ctx.result.set_number(double::nan);
        return;
    }
    TVal* year_arg  = &ctx.regs[ctx.base_reg];
    TVal* month_arg = &ctx.regs[ctx.base_reg + 1];
    double year  = year_arg.get_number_or_fastint();
    double month = month_arg.get_number_or_fastint();
    double day   = (ctx.argc > 2) ? ctx.regs[ctx.base_reg + 2].get_number_or_fastint() : 1.0;
    double hour  = (ctx.argc > 3) ? ctx.regs[ctx.base_reg + 3].get_number_or_fastint() : 0.0;
    double min   = (ctx.argc > 4) ? ctx.regs[ctx.base_reg + 4].get_number_or_fastint() : 0.0;
    double sec   = (ctx.argc > 5) ? ctx.regs[ctx.base_reg + 5].get_number_or_fastint() : 0.0;
    double ms    = (ctx.argc > 6) ? ctx.regs[ctx.base_reg + 6].get_number_or_fastint() : 0.0;

    if (year >= 0 && year < 100) year += 1900;

    // For Date.UTC, the time is in UTC. We compute days from epoch using
    // simple calendar math (no timezone offset).
    long y = (long)year;
    long m = (long)month;
    // Adjust year: treat Jan and Feb as months 13,14 of previous year
    if (m < 2) { y--; m += 12; }
    // Computations using the formula
    long era = (y >= 0 ? y : y - 399) / 400;
    long yoe = y - era * 400;  // [0, 399]
    long doy = (153 * (m - 2) + 2) / 5 + (long)day - 1;  // day of year
    long doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    long epoch_day = (era * 146097 + (long)doe - 719468);
    double t = (double)epoch_day * 86400000.0;
    t += (double)hour * 3600000.0 + (double)min * 60000.0 + (double)sec * 1000.0 + (double)ms;
    ctx.result.set_number(t);
}

/// Date.parse(string) — ES5 §15.9.4.2 (simplified)
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
    // For non-numeric strings, try parsing as date string via libc
    // For now, return NaN (Date.parse is notoriously complex)
    // Full implementation would use a proper date parser
    ctx.result.set_number(double::nan);
}

/// Date.prototype.toString() — ES5 §15.9.5.2
fn void builtin_date_proto_toString(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    double time_val = date_get_time_value(&this_val);
    char[128] buf;
    usz len = date_format_to_string(time_val, &buf, 128);
    HString* result = builtin_intern_string(ctx.heap, buf[:len]);
    ctx.result.set_string(result);
}

/// Date.prototype.toDateString() — ES5 §15.9.5.3
/// Returns the date portion: "Mon Jan 01 2024"
fn void builtin_date_proto_toDateString(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    double time_val = date_get_time_value(&this_val);
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
    usz len = (usz)libc::snprintf(&buf, types::FORMAT_BUF, "%s %s %02d %04d",
        wday_name, mon_name, (int)day, (int)year);
    HString* result = builtin_intern_string(ctx.heap, buf[:len]);
    ctx.result.set_string(result);
}

/// Date.prototype.toTimeString() — ES5 §15.9.5.4
/// Returns the time portion: "12:00:00 GMT+0000"
fn void builtin_date_proto_toTimeString(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    double time_val = date_get_time_value(&this_val);
    if (math::is_nan(time_val)) {
        HString* inv = builtin_intern_string(ctx.heap, "Invalid Date");
        ctx.result.set_string(inv);
        return;
    }
    long t_sec = (long)(time_val / 1000.0);
    Tm tm_result;
    libc::localtime_r(&t_sec, &tm_result);
    Tm* tm = &tm_result;

    // Compute timezone offset
    long local_as_epoch = (long)libc::mktime(tm);
    if (local_as_epoch == -1) local_as_epoch = t_sec;
    long tz_seconds = local_as_epoch - t_sec;
    char tz_sign = '+';
    int offs_hours = (int)(tz_seconds / 3600);
    int offs_mins = (int)((tz_seconds / 60) % 60);
    if (tz_seconds < 0) {
        tz_sign = '-';
        offs_hours = -offs_hours;
        offs_mins = -offs_mins;
    }

    char[types::FORMAT_BUF] buf;
    usz len = (usz)libc::snprintf(&buf, types::FORMAT_BUF, "%02d:%02d:%02d GMT%c%02d%02d",
        tm.tm_hour, tm.tm_min, tm.tm_sec,
        tz_sign, offs_hours, offs_mins);
    HString* result = builtin_intern_string(ctx.heap, buf[:len]);
    ctx.result.set_string(result);
}

/// Date.prototype.toJSON(key) — ES5 §15.9.5.44
fn void builtin_date_proto_toJSON(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    double time_val = date_get_time_value(&this_val);
    if (math::is_nan(time_val)) {
        ctx.result.set_null();
        return;
    }
    char[128] buf;
    usz len = date_format_iso(time_val, &buf, 128);
    HString* result = builtin_intern_string(ctx.heap, buf[:len]);
    ctx.result.set_string(result);
}

/// Date.prototype.data.valueOf() — ES5 §15.9.5.8
fn void builtin_date_proto_valueOf(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    double time_val = date_get_time_value(&this_val);
    ctx.result.set_number(time_val);
}

/// Date.prototype.getTime() — ES5 §15.9.5.9
fn void builtin_date_proto_getTime(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    double time_val = date_get_time_value(&this_val);
    ctx.result.set_number(time_val);
}

/// Helper: break a time value into local time components via localtime_r.
fn void date_break_time(double time_val, long* year, long* month, long* day,
                        long* wday, long* hour, long* minute, long* second) {
    if (math::is_nan(time_val)) {
        *year = *month = *day = *wday = *hour = *minute = *second = 0;
        return;
    }
    long t_sec = (long)(time_val / 1000.0);
    Tm result;
    libc::localtime_r(&t_sec, &result);
    *year   = (long)(result.tm_year) + 1900L;
    *month  = (long)(result.tm_mon);
    *day    = (long)(result.tm_mday);
    *wday   = (long)(result.tm_wday);
    *hour   = result.tm_hour;
    *minute = result.tm_min;
    *second = result.tm_sec;
}

/// Date.prototype.getFullYear() — ES5 §15.9.5.10
fn void builtin_date_proto_getFullYear(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    double tv = date_get_time_value(&this_val);
    if (math::is_nan(tv)) { ctx.result.set_number(double::nan); return; }
    long year, month, day, wday, hour, min, sec;
    date_break_time(tv, &year, &month, &day, &wday, &hour, &min, &sec);
    ctx.result.set_fastint(year);
}

/// Date.prototype.getMonth() — ES5 §15.9.5.12
fn void builtin_date_proto_getMonth(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    double tv = date_get_time_value(&this_val);
    if (math::is_nan(tv)) { ctx.result.set_number(double::nan); return; }
    long year, month, day, wday, hour, min, sec;
    date_break_time(tv, &year, &month, &day, &wday, &hour, &min, &sec);
    ctx.result.set_fastint(month);
}

/// Date.prototype.getDate() — ES5 §15.9.5.14
fn void builtin_date_proto_getDate(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    double tv = date_get_time_value(&this_val);
    if (math::is_nan(tv)) { ctx.result.set_number(double::nan); return; }
    long year, month, day, wday, hour, min, sec;
    date_break_time(tv, &year, &month, &day, &wday, &hour, &min, &sec);
    ctx.result.set_fastint(day);
}

/// Date.prototype.getDay() — ES5 §15.9.5.16
fn void builtin_date_proto_getDay(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    double tv = date_get_time_value(&this_val);
    if (math::is_nan(tv)) { ctx.result.set_number(double::nan); return; }
    long year, month, day, wday, hour, min, sec;
    date_break_time(tv, &year, &month, &day, &wday, &hour, &min, &sec);
    ctx.result.set_fastint(wday);
}

/// Date.prototype.getHours() — ES5 §15.9.5.18
fn void builtin_date_proto_getHours(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    double tv = date_get_time_value(&this_val);
    if (math::is_nan(tv)) { ctx.result.set_number(double::nan); return; }
    long year, month, day, wday, hour, min, sec;
    date_break_time(tv, &year, &month, &day, &wday, &hour, &min, &sec);
    ctx.result.set_fastint(hour);
}

/// Date.prototype.getMinutes() — ES5 §15.9.5.20
fn void builtin_date_proto_getMinutes(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    double tv = date_get_time_value(&this_val);
    if (math::is_nan(tv)) { ctx.result.set_number(double::nan); return; }
    long year, month, day, wday, hour, min, sec;
    date_break_time(tv, &year, &month, &day, &wday, &hour, &min, &sec);
    ctx.result.set_fastint(min);
}

/// Date.prototype.getSeconds() — ES5 §15.9.5.22
fn void builtin_date_proto_getSeconds(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    double tv = date_get_time_value(&this_val);
    if (math::is_nan(tv)) { ctx.result.set_number(double::nan); return; }
    long year, month, day, wday, hour, min, sec;
    date_break_time(tv, &year, &month, &day, &wday, &hour, &min, &sec);
    ctx.result.set_fastint(sec);
}

/// Date.prototype.getMilliseconds() — ES5 §15.9.5.24
fn void builtin_date_proto_getMilliseconds(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    double tv = date_get_time_value(&this_val);
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
    Tm result;
    libc::gmtime_r(&t_sec, &result);
    *year   = (long)(result.tm_year) + 1900L;
    *month  = (long)(result.tm_mon);
    *day    = (long)(result.tm_mday);
    *wday   = (long)(result.tm_wday);
    *hour   = result.tm_hour;
    *minute = result.tm_min;
    *second = result.tm_sec;
}

/// Helper: convert UTC time components to epoch ms (no timezone adjustment).
fn double date_utc_to_ms(long year, long month, long day,
                         long hour, long minute, long second, long ms) {
    long y = year;
    long m = month + 1;  // JS months are 0-based, calculation uses 1-based
    if (m < 3) { y--; m += 12; }
    long era = (y >= 0 ? y : y - 399) / 400;
    long yoe = y - era * 400;
    long doy = (153 * (m - 3) + 2) / 5 + day - 1;
    long doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    long epoch_day = era * 146097 + doe - 719468;
    double t = (double)epoch_day * 86400000.0;
    t += (double)hour * 3600000.0 + (double)minute * 60000.0 + (double)second * 1000.0 + (double)ms;
    return t;
}

/// Helper: TimeClip — clamp time value to ±8.64e15 ms per ES5 §15.9.1.14.
fn double date_time_clip(double t) {
    if (math::is_nan(t)) return t;
    if (t > 8.64e15 || t < -8.64e15) return double::nan;
    return t;
}

/// Helper: set the ms value on a Date object.
fn void date_set_ms(HObject* obj, double new_ms) {
    (*obj.extra_ptr()).prim.primitive_value.set_number(new_ms);
}

/// Date.prototype.getTimezoneOffset() — ES5 §15.9.5.26
fn void builtin_date_proto_getTimezoneOffset(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    double tv = date_get_time_value(&this_val);
    if (math::is_nan(tv)) { ctx.result.set_number(double::nan); return; }
    // local and UTC components
    long ly, lm, ld, lwday, lh, lmin, lsec;
    long uy, um, ud, uwday, uh, umin, usec;
    date_break_time(tv, &ly, &lm, &ld, &lwday, &lh, &lmin, &lsec);
    date_break_time_utc(tv, &uy, &um, &ud, &uwday, &uh, &umin, &usec);
    double local_ms = date_local_to_ms(ly, lm, ld, lh, lmin, lsec, 0);
    double utc_ms   = date_utc_to_ms(uy, um, ud, uh, umin, usec, 0);
    long offset = (long)((local_ms - utc_ms) / 60000.0);
    ctx.result.set_fastint(offset);
}

/// Date.prototype.getUTCFullYear() — ES5 §15.9.5.41
fn void builtin_date_proto_getUTCFullYear(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    double tv = date_get_time_value(&this_val);
    if (math::is_nan(tv)) { ctx.result.set_number(double::nan); return; }
    long year, month, day, wday, hour, min, sec;
    date_break_time_utc(tv, &year, &month, &day, &wday, &hour, &min, &sec);
    ctx.result.set_fastint(year);
}

/// Date.prototype.getUTCMonth() — ES5 §15.9.5.42
fn void builtin_date_proto_getUTCMonth(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    double tv = date_get_time_value(&this_val);
    if (math::is_nan(tv)) { ctx.result.set_number(double::nan); return; }
    long year, month, day, wday, hour, min, sec;
    date_break_time_utc(tv, &year, &month, &day, &wday, &hour, &min, &sec);
    ctx.result.set_fastint(month);
}

/// Date.prototype.getUTCDate() — ES5 §15.9.5.43
fn void builtin_date_proto_getUTCDate(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    double tv = date_get_time_value(&this_val);
    if (math::is_nan(tv)) { ctx.result.set_number(double::nan); return; }
    long year, month, day, wday, hour, min, sec;
    date_break_time_utc(tv, &year, &month, &day, &wday, &hour, &min, &sec);
    ctx.result.set_fastint(day);
}

/// Date.prototype.getUTCDay() — ES5 §15.9.5.44
fn void builtin_date_proto_getUTCDay(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    double tv = date_get_time_value(&this_val);
    if (math::is_nan(tv)) { ctx.result.set_number(double::nan); return; }
    long year, month, day, wday, hour, min, sec;
    date_break_time_utc(tv, &year, &month, &day, &wday, &hour, &min, &sec);
    ctx.result.set_fastint(wday);
}

/// Date.prototype.getUTCHours() — ES5 §15.9.5.45
fn void builtin_date_proto_getUTCHours(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    double tv = date_get_time_value(&this_val);
    if (math::is_nan(tv)) { ctx.result.set_number(double::nan); return; }
    long year, month, day, wday, hour, min, sec;
    date_break_time_utc(tv, &year, &month, &day, &wday, &hour, &min, &sec);
    ctx.result.set_fastint(hour);
}

/// Date.prototype.getUTCMinutes() — ES5 §15.9.5.46
fn void builtin_date_proto_getUTCMinutes(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    double tv = date_get_time_value(&this_val);
    if (math::is_nan(tv)) { ctx.result.set_number(double::nan); return; }
    long year, month, day, wday, hour, min, sec;
    date_break_time_utc(tv, &year, &month, &day, &wday, &hour, &min, &sec);
    ctx.result.set_fastint(min);
}

/// Date.prototype.getUTCSeconds() — ES5 §15.9.5.47
fn void builtin_date_proto_getUTCSeconds(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    double tv = date_get_time_value(&this_val);
    if (math::is_nan(tv)) { ctx.result.set_number(double::nan); return; }
    long year, month, day, wday, hour, min, sec;
    date_break_time_utc(tv, &year, &month, &day, &wday, &hour, &min, &sec);
    ctx.result.set_fastint(sec);
}

/// Date.prototype.getUTCMilliseconds() — ES5 §15.9.5.48
fn void builtin_date_proto_getUTCMilliseconds(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    double tv = date_get_time_value(&this_val);
    if (math::is_nan(tv)) { ctx.result.set_number(double::nan); return; }
    long ms = (long)tv % 1000;
    if (ms < 0) ms += 1000;
    ctx.result.set_fastint(ms);
}

/// Date.prototype.setTime(time) — ES5 §15.9.5.27
fn void builtin_date_proto_setTime(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    if (!this_val.is_object() || this_val.get_heapptr() == null) { ctx.result.set_number(double::nan); return; }
    HObject* obj = (HObject*)this_val.get_heapptr();
    if (obj.get_class() != hobject::ObjClass.DATE) { ctx.result.set_number(double::nan); return; }
    double t = (ctx.argc > 0) ? ctx.regs[ctx.base_reg].get_number_or_fastint() : double::nan;
    double clipped = date_time_clip(t);
    date_set_ms(obj, clipped);
    ctx.result.set_number(clipped);
}

/// Date.prototype.setMilliseconds(ms) — ES5 §15.9.5.28
fn void builtin_date_proto_setMilliseconds(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    if (!this_val.is_object() || this_val.get_heapptr() == null) { ctx.result.set_number(double::nan); return; }
    HObject* obj = (HObject*)this_val.get_heapptr();
    if (obj.get_class() != hobject::ObjClass.DATE) { ctx.result.set_number(double::nan); return; }
    double tv = date_get_time_value(&this_val);
    if (math::is_nan(tv)) { ctx.result.set_number(double::nan); return; }
    double ms = (ctx.argc > 0) ? ctx.regs[ctx.base_reg].get_number_or_fastint() : double::nan;
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
    if (!this_val.is_object() || this_val.get_heapptr() == null) { ctx.result.set_number(double::nan); return; }
    HObject* obj = (HObject*)this_val.get_heapptr();
    if (obj.get_class() != hobject::ObjClass.DATE) { ctx.result.set_number(double::nan); return; }
    double tv = date_get_time_value(&this_val);
    if (math::is_nan(tv)) { ctx.result.set_number(double::nan); return; }
    double sec_arg = (ctx.argc > 0) ? ctx.regs[ctx.base_reg].get_number_or_fastint() : double::nan;
    double ms_arg  = (ctx.argc > 1) ? ctx.regs[ctx.base_reg + 1].get_number_or_fastint() : (long)tv % 1000;
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
    if (!this_val.is_object() || this_val.get_heapptr() == null) { ctx.result.set_number(double::nan); return; }
    HObject* obj = (HObject*)this_val.get_heapptr();
    if (obj.get_class() != hobject::ObjClass.DATE) { ctx.result.set_number(double::nan); return; }
    double tv = date_get_time_value(&this_val);
    if (math::is_nan(tv)) { ctx.result.set_number(double::nan); return; }
    double min_arg = (ctx.argc > 0) ? ctx.regs[ctx.base_reg].get_number_or_fastint() : double::nan;
    long sec_cur = (long)tv / 1000 % 60; if (sec_cur < 0) sec_cur += 60;
    long ms_cur  = (long)tv % 1000; if (ms_cur < 0) ms_cur += 1000;
    double sec_arg = (ctx.argc > 1) ? ctx.regs[ctx.base_reg + 1].get_number_or_fastint() : (double)sec_cur;
    double ms_arg  = (ctx.argc > 2) ? ctx.regs[ctx.base_reg + 2].get_number_or_fastint() : (double)ms_cur;
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
    if (!this_val.is_object() || this_val.get_heapptr() == null) { ctx.result.set_number(double::nan); return; }
    HObject* obj = (HObject*)this_val.get_heapptr();
    if (obj.get_class() != hobject::ObjClass.DATE) { ctx.result.set_number(double::nan); return; }
    double tv = date_get_time_value(&this_val);
    if (math::is_nan(tv)) { ctx.result.set_number(double::nan); return; }
    double hour_arg = (ctx.argc > 0) ? ctx.regs[ctx.base_reg].get_number_or_fastint() : double::nan;
    long min_cur = (long)tv / 60000 % 60; if (min_cur < 0) min_cur += 60;
    long sec_cur = (long)tv / 1000 % 60; if (sec_cur < 0) sec_cur += 60;
    long ms_cur  = (long)tv % 1000; if (ms_cur < 0) ms_cur += 1000;
    double min_arg = (ctx.argc > 1) ? ctx.regs[ctx.base_reg + 1].get_number_or_fastint() : (double)min_cur;
    double sec_arg = (ctx.argc > 2) ? ctx.regs[ctx.base_reg + 2].get_number_or_fastint() : (double)sec_cur;
    double ms_arg  = (ctx.argc > 3) ? ctx.regs[ctx.base_reg + 3].get_number_or_fastint() : (double)ms_cur;
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
    if (!this_val.is_object() || this_val.get_heapptr() == null) { ctx.result.set_number(double::nan); return; }
    HObject* obj = (HObject*)this_val.get_heapptr();
    if (obj.get_class() != hobject::ObjClass.DATE) { ctx.result.set_number(double::nan); return; }
    double tv = date_get_time_value(&this_val);
    if (math::is_nan(tv)) { ctx.result.set_number(double::nan); return; }
    double date_arg = (ctx.argc > 0) ? ctx.regs[ctx.base_reg].get_number_or_fastint() : double::nan;
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
    if (!this_val.is_object() || this_val.get_heapptr() == null) { ctx.result.set_number(double::nan); return; }
    HObject* obj = (HObject*)this_val.get_heapptr();
    if (obj.get_class() != hobject::ObjClass.DATE) { ctx.result.set_number(double::nan); return; }
    double tv = date_get_time_value(&this_val);
    if (math::is_nan(tv)) { ctx.result.set_number(double::nan); return; }
    double month_arg = (ctx.argc > 0) ? ctx.regs[ctx.base_reg].get_number_or_fastint() : double::nan;
    long year, month, day, wday, hour, min, sec;
    date_break_time(tv, &year, &month, &day, &wday, &hour, &min, &sec);
    double date_arg = (ctx.argc > 1) ? ctx.regs[ctx.base_reg + 1].get_number_or_fastint() : (double)day;
    if (math::is_nan(month_arg)) { date_set_ms(obj, double::nan); ctx.result.set_number(double::nan); return; }
    double new_ms = date_local_to_ms(year, (long)month_arg, (long)date_arg, hour, min, sec, (long)tv % 1000);
    double clipped = date_time_clip(new_ms);
    date_set_ms(obj, clipped);
    ctx.result.set_number(clipped);
}

/// Date.prototype.setFullYear(year[, month[, date]]) — ES5 §15.9.5.40
fn void builtin_date_proto_setFullYear(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    if (!this_val.is_object() || this_val.get_heapptr() == null) { ctx.result.set_number(double::nan); return; }
    HObject* obj = (HObject*)this_val.get_heapptr();
    if (obj.get_class() != hobject::ObjClass.DATE) { ctx.result.set_number(double::nan); return; }
    double tv = date_get_time_value(&this_val);
    double year_arg = (ctx.argc > 0) ? ctx.regs[ctx.base_reg].get_number_or_fastint() : double::nan;
    if (math::is_nan(year_arg)) { date_set_ms(obj, double::nan); ctx.result.set_number(double::nan); return; }
    long y, m, d, wday, h, min, s;
    if (math::is_nan(tv)) { y = 1970; m = 0; d = 1; h = 0; min = 0; s = 0; }
    else { date_break_time(tv, &y, &m, &d, &wday, &h, &min, &s); }
    double month_arg = (ctx.argc > 1) ? ctx.regs[ctx.base_reg + 1].get_number_or_fastint() : (double)m;
    double date_arg  = (ctx.argc > 2) ? ctx.regs[ctx.base_reg + 2].get_number_or_fastint() : (double)d;
    double new_ms = date_local_to_ms((long)year_arg, (long)month_arg, (long)date_arg, h, min, s, math::is_nan(tv) ? 0 : (long)tv % 1000);
    double clipped = date_time_clip(new_ms);
    date_set_ms(obj, clipped);
    ctx.result.set_number(clipped);
}

/// Date.prototype.setUTCMilliseconds(ms) — ES5 §15.9.5.49
fn void builtin_date_proto_setUTCMilliseconds(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    if (!this_val.is_object() || this_val.get_heapptr() == null) { ctx.result.set_number(double::nan); return; }
    HObject* obj = (HObject*)this_val.get_heapptr();
    if (obj.get_class() != hobject::ObjClass.DATE) { ctx.result.set_number(double::nan); return; }
    double tv = date_get_time_value(&this_val);
    if (math::is_nan(tv)) { ctx.result.set_number(double::nan); return; }
    double ms = (ctx.argc > 0) ? ctx.regs[ctx.base_reg].get_number_or_fastint() : double::nan;
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
    if (!this_val.is_object() || this_val.get_heapptr() == null) { ctx.result.set_number(double::nan); return; }
    HObject* obj = (HObject*)this_val.get_heapptr();
    if (obj.get_class() != hobject::ObjClass.DATE) { ctx.result.set_number(double::nan); return; }
    double tv = date_get_time_value(&this_val);
    if (math::is_nan(tv)) { ctx.result.set_number(double::nan); return; }
    double sec_arg = (ctx.argc > 0) ? ctx.regs[ctx.base_reg].get_number_or_fastint() : double::nan;
    double ms_arg  = (ctx.argc > 1) ? ctx.regs[ctx.base_reg + 1].get_number_or_fastint() : (long)tv % 1000;
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
    if (!this_val.is_object() || this_val.get_heapptr() == null) { ctx.result.set_number(double::nan); return; }
    HObject* obj = (HObject*)this_val.get_heapptr();
    if (obj.get_class() != hobject::ObjClass.DATE) { ctx.result.set_number(double::nan); return; }
    double tv = date_get_time_value(&this_val);
    if (math::is_nan(tv)) { ctx.result.set_number(double::nan); return; }
    double min_arg = (ctx.argc > 0) ? ctx.regs[ctx.base_reg].get_number_or_fastint() : double::nan;
    long sec_cur = (long)tv / 1000 % 60; if (sec_cur < 0) sec_cur += 60;
    long ms_cur  = (long)tv % 1000; if (ms_cur < 0) ms_cur += 1000;
    double sec_arg = (ctx.argc > 1) ? ctx.regs[ctx.base_reg + 1].get_number_or_fastint() : (double)sec_cur;
    double ms_arg  = (ctx.argc > 2) ? ctx.regs[ctx.base_reg + 2].get_number_or_fastint() : (double)ms_cur;
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
    if (!this_val.is_object() || this_val.get_heapptr() == null) { ctx.result.set_number(double::nan); return; }
    HObject* obj = (HObject*)this_val.get_heapptr();
    if (obj.get_class() != hobject::ObjClass.DATE) { ctx.result.set_number(double::nan); return; }
    double tv = date_get_time_value(&this_val);
    if (math::is_nan(tv)) { ctx.result.set_number(double::nan); return; }
    double hour_arg = (ctx.argc > 0) ? ctx.regs[ctx.base_reg].get_number_or_fastint() : double::nan;
    long min_cur = (long)tv / 60000 % 60; if (min_cur < 0) min_cur += 60;
    long sec_cur = (long)tv / 1000 % 60; if (sec_cur < 0) sec_cur += 60;
    long ms_cur  = (long)tv % 1000; if (ms_cur < 0) ms_cur += 1000;
    double min_arg = (ctx.argc > 1) ? ctx.regs[ctx.base_reg + 1].get_number_or_fastint() : (double)min_cur;
    double sec_arg = (ctx.argc > 2) ? ctx.regs[ctx.base_reg + 2].get_number_or_fastint() : (double)sec_cur;
    double ms_arg  = (ctx.argc > 3) ? ctx.regs[ctx.base_reg + 3].get_number_or_fastint() : (double)ms_cur;
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
    if (!this_val.is_object() || this_val.get_heapptr() == null) { ctx.result.set_number(double::nan); return; }
    HObject* obj = (HObject*)this_val.get_heapptr();
    if (obj.get_class() != hobject::ObjClass.DATE) { ctx.result.set_number(double::nan); return; }
    double tv = date_get_time_value(&this_val);
    if (math::is_nan(tv)) { ctx.result.set_number(double::nan); return; }
    double date_arg = (ctx.argc > 0) ? ctx.regs[ctx.base_reg].get_number_or_fastint() : double::nan;
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
    if (!this_val.is_object() || this_val.get_heapptr() == null) { ctx.result.set_number(double::nan); return; }
    HObject* obj = (HObject*)this_val.get_heapptr();
    if (obj.get_class() != hobject::ObjClass.DATE) { ctx.result.set_number(double::nan); return; }
    double tv = date_get_time_value(&this_val);
    if (math::is_nan(tv)) { ctx.result.set_number(double::nan); return; }
    double month_arg = (ctx.argc > 0) ? ctx.regs[ctx.base_reg].get_number_or_fastint() : double::nan;
    long year, month, day, wday, hour, min, sec;
    date_break_time_utc(tv, &year, &month, &day, &wday, &hour, &min, &sec);
    double date_arg = (ctx.argc > 1) ? ctx.regs[ctx.base_reg + 1].get_number_or_fastint() : (double)day;
    if (math::is_nan(month_arg)) { date_set_ms(obj, double::nan); ctx.result.set_number(double::nan); return; }
    double new_ms = date_utc_to_ms(year, (long)month_arg, (long)date_arg, hour, min, sec, (long)tv % 1000);
    double clipped = date_time_clip(new_ms);
    date_set_ms(obj, clipped);
    ctx.result.set_number(clipped);
}

/// Date.prototype.setUTCFullYear(year[, month[, date]]) — ES5 §15.9.5.55
fn void builtin_date_proto_setUTCFullYear(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    if (!this_val.is_object() || this_val.get_heapptr() == null) { ctx.result.set_number(double::nan); return; }
    HObject* obj = (HObject*)this_val.get_heapptr();
    if (obj.get_class() != hobject::ObjClass.DATE) { ctx.result.set_number(double::nan); return; }
    double tv = date_get_time_value(&this_val);
    double year_arg = (ctx.argc > 0) ? ctx.regs[ctx.base_reg].get_number_or_fastint() : double::nan;
    if (math::is_nan(year_arg)) { date_set_ms(obj, double::nan); ctx.result.set_number(double::nan); return; }
    long y, m, d, wday, h, min, s;
    if (math::is_nan(tv)) { y = 1970; m = 0; d = 1; h = 0; min = 0; s = 0; }
    else { date_break_time_utc(tv, &y, &m, &d, &wday, &h, &min, &s); }
    double month_arg = (ctx.argc > 1) ? ctx.regs[ctx.base_reg + 1].get_number_or_fastint() : (double)m;
    double date_arg  = (ctx.argc > 2) ? ctx.regs[ctx.base_reg + 2].get_number_or_fastint() : (double)d;
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

/// Helper: pad integer to 4 digits
fn void date_pad4(char* buf, long val) {
    buf[0] = (char)(val / 1000 + 48);
    buf[1] = (char)(val / 100 % 10 + 48);
    buf[2] = (char)(val / 10 % 10 + 48);
    buf[3] = (char)(val % 10 + 48);
}

/// Date.prototype.toISOString() — ES5 §15.9.5.41
fn void builtin_date_proto_toISOString(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    double tv = date_get_time_value(&this_val);
    if (math::is_nan(tv)) { ctx.result.set_string(builtin_intern_string(ctx.heap, "Invalid Date")); return; }
    long year, month, day, wday, hour, min, sec;
    date_break_time_utc(tv, &year, &month, &day, &wday, &hour, &min, &sec);
    long ms = (long)tv % 1000; if (ms < 0) ms += 1000;
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

/// Date.prototype.toUTCString() — ES5 §15.9.5.44
fn void builtin_date_proto_toUTCString(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    double tv = date_get_time_value(&this_val);
    if (math::is_nan(tv)) { ctx.result.set_string(builtin_intern_string(ctx.heap, "Invalid Date")); return; }
    long year, month, day, wday, hour, min, sec;
    date_break_time_utc(tv, &year, &month, &day, &wday, &hour, &min, &sec);
    char[7][] day_names = { "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };
    char[7][] mon_names = { "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
    char[types::FORMAT_BUF] buf;
    // "Thu, 01 Jan 1970 00:00:00 GMT"
    buf[0] = day_names[wday][0]; buf[1] = day_names[wday][1]; buf[2] = day_names[wday][2];
    buf[3] = ','; buf[4] = ' ';
    date_pad2(&buf[5], day);
    buf[7] = ' ';
    buf[8] = mon_names[month][0]; buf[9] = mon_names[month][1]; buf[10] = mon_names[month][2];
    buf[11] = ' ';
    date_pad4(&buf[12], year);
    buf[16] = ' ';
    date_pad2(&buf[17], hour);
    buf[19] = ':';
    date_pad2(&buf[20], min);
    buf[22] = ':';
    date_pad2(&buf[23], sec);
    buf[25] = ' '; buf[26] = 'G'; buf[27] = 'M'; buf[28] = 'T';
    ctx.result.set_string(builtin_intern_string(ctx.heap, buf[0:29]));
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
    heap.date_proto = proto;

    // Set .constructor to Date lightfunc
    HString* constructor_key = (HString*)heap.strs[heap::BuiltinStr.CONSTRUCTOR];
    TVal constructor_tv;
    constructor_tv.set_lightfunc((void*)(usz)BUILTIN_DATE);
    proto.put_prop(constructor_key, constructor_tv, hobject::PROP_FLAGS_WC);

    // Add Date.prototype.toString()
    if (!register_string_proto_method(proto, heap, "toString", BUILTIN_DATE_PROTO_TOSTRING)) return false;

    // Add Date.prototype.toJSON()
    if (!register_string_proto_method(proto, heap, "toJSON", BUILTIN_DATE_PROTO_TOJSON)) return false;

    // Add Date.prototype.data.valueOf()
    if (!register_string_proto_method(proto, heap, "valueOf", BUILTIN_DATE_PROTO_VALUEOF)) return false;

    // Add Date.prototype.getTime()
    if (!register_string_proto_method(proto, heap, "getTime", BUILTIN_DATE_PROTO_GETTIME)) return false;

    // Add Date.prototype.getFullYear()
    if (!register_string_proto_method(proto, heap, "getFullYear", BUILTIN_DATE_PROTO_GETFULLYEAR)) return false;

    // Add Date.prototype.getMonth()
    if (!register_string_proto_method(proto, heap, "getMonth", BUILTIN_DATE_PROTO_GETMONTH)) return false;

    // Add Date.prototype.getDate()
    if (!register_string_proto_method(proto, heap, "getDate", BUILTIN_DATE_PROTO_GETDATE)) return false;

    // Add Date.prototype.getDay()
    if (!register_string_proto_method(proto, heap, "getDay", BUILTIN_DATE_PROTO_GETDAY)) return false;

    // Add Date.prototype.getHours()
    if (!register_string_proto_method(proto, heap, "getHours", BUILTIN_DATE_PROTO_GETHOURS)) return false;

    // Add Date.prototype.getMinutes()
    if (!register_string_proto_method(proto, heap, "getMinutes", BUILTIN_DATE_PROTO_GETMINUTES)) return false;

    // Add Date.prototype.getSeconds()
    if (!register_string_proto_method(proto, heap, "getSeconds", BUILTIN_DATE_PROTO_GETSECONDS)) return false;

    // Add Date.prototype.getMilliseconds()
    if (!register_string_proto_method(proto, heap, "getMilliseconds", BUILTIN_DATE_PROTO_GETMILLISECONDS)) return false;

    // Add Date.prototype.getTimezoneOffset()
    if (!register_string_proto_method(proto, heap, "getTimezoneOffset", BUILTIN_DATE_PROTO_GETTIMEZONEOFFSET)) return false;

    // Add Date.prototype.getUTCFullYear()
    if (!register_string_proto_method(proto, heap, "getUTCFullYear", BUILTIN_DATE_PROTO_GETUTCFULLYEAR)) return false;

    // Add Date.prototype.getUTCMonth()
    if (!register_string_proto_method(proto, heap, "getUTCMonth", BUILTIN_DATE_PROTO_GETUTCMONTH)) return false;

    // Add Date.prototype.getUTCDate()
    if (!register_string_proto_method(proto, heap, "getUTCDate", BUILTIN_DATE_PROTO_GETUTCDATE)) return false;

    // Add Date.prototype.getUTCDay()
    if (!register_string_proto_method(proto, heap, "getUTCDay", BUILTIN_DATE_PROTO_GETUTCDAY)) return false;

    // Add Date.prototype.getUTCHours()
    if (!register_string_proto_method(proto, heap, "getUTCHours", BUILTIN_DATE_PROTO_GETUTCHOURS)) return false;

    // Add Date.prototype.getUTCMinutes()
    if (!register_string_proto_method(proto, heap, "getUTCMinutes", BUILTIN_DATE_PROTO_GETUTCMINUTES)) return false;

    // Add Date.prototype.getUTCSeconds()
    if (!register_string_proto_method(proto, heap, "getUTCSeconds", BUILTIN_DATE_PROTO_GETUTCSECONDS)) return false;

    // Add Date.prototype.getUTCMilliseconds()
    if (!register_string_proto_method(proto, heap, "getUTCMilliseconds", BUILTIN_DATE_PROTO_GETUTCMILLISECONDS)) return false;

    // Add Date.prototype.setTime()
    if (!register_string_proto_method(proto, heap, "setTime", BUILTIN_DATE_PROTO_SETTIME)) return false;

    // Add Date.prototype.setMilliseconds()
    if (!register_string_proto_method(proto, heap, "setMilliseconds", BUILTIN_DATE_PROTO_SETMILLISECONDS)) return false;

    // Add Date.prototype.setSeconds()
    if (!register_string_proto_method(proto, heap, "setSeconds", BUILTIN_DATE_PROTO_SETSECONDS)) return false;

    // Add Date.prototype.setMinutes()
    if (!register_string_proto_method(proto, heap, "setMinutes", BUILTIN_DATE_PROTO_SETMINUTES)) return false;

    // Add Date.prototype.setHours()
    if (!register_string_proto_method(proto, heap, "setHours", BUILTIN_DATE_PROTO_SETHOURS)) return false;

    // Add Date.prototype.setDate()
    if (!register_string_proto_method(proto, heap, "setDate", BUILTIN_DATE_PROTO_SETDATE)) return false;

    // Add Date.prototype.setMonth()
    if (!register_string_proto_method(proto, heap, "setMonth", BUILTIN_DATE_PROTO_SETMONTH)) return false;

    // Add Date.prototype.setFullYear()
    if (!register_string_proto_method(proto, heap, "setFullYear", BUILTIN_DATE_PROTO_SETFULLYEAR)) return false;

    // Add Date.prototype.setUTCMilliseconds()
    if (!register_string_proto_method(proto, heap, "setUTCMilliseconds", BUILTIN_DATE_PROTO_SETUTCMILLISECONDS)) return false;

    // Add Date.prototype.setUTCSeconds()
    if (!register_string_proto_method(proto, heap, "setUTCSeconds", BUILTIN_DATE_PROTO_SETUTCSECONDS)) return false;

    // Add Date.prototype.setUTCMinutes()
    if (!register_string_proto_method(proto, heap, "setUTCMinutes", BUILTIN_DATE_PROTO_SETUTCMINUTES)) return false;

    // Add Date.prototype.setUTCHours()
    if (!register_string_proto_method(proto, heap, "setUTCHours", BUILTIN_DATE_PROTO_SETUTCHOURS)) return false;

    // Add Date.prototype.setUTCDate()
    if (!register_string_proto_method(proto, heap, "setUTCDate", BUILTIN_DATE_PROTO_SETUTCDATE)) return false;

    // Add Date.prototype.setUTCMonth()
    if (!register_string_proto_method(proto, heap, "setUTCMonth", BUILTIN_DATE_PROTO_SETUTCMONTH)) return false;

    // Add Date.prototype.setUTCFullYear()
    if (!register_string_proto_method(proto, heap, "setUTCFullYear", BUILTIN_DATE_PROTO_SETUTCFULLYEAR)) return false;

    // Add Date.prototype.toISOString()
    if (!register_string_proto_method(proto, heap, "toISOString", BUILTIN_DATE_PROTO_TOISOSTRING)) return false;

    // Add Date.prototype.toUTCString()
    if (!register_string_proto_method(proto, heap, "toUTCString", BUILTIN_DATE_PROTO_TOUTCSTRING)) return false;

    // Add Date.prototype.toGMTString() (alias for toUTCString)
    if (!register_string_proto_method(proto, heap, "toGMTString", BUILTIN_DATE_PROTO_TOGMTSTRING)) return false;

    // Add Date.prototype.toDateString() — ES5 §15.9.5.3
    if (!register_string_proto_method(proto, heap, "toDateString", BUILTIN_DATE_PROTO_TODATESTRING)) return false;

    // Add Date.prototype.toTimeString() — ES5 §15.9.5.4
    if (!register_string_proto_method(proto, heap, "toTimeString", BUILTIN_DATE_PROTO_TOTIMESTRING)) return false;

    // Register Date as a global constructor (proper function object for static methods)
    HObject*? date_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
    if (catch err = date_raw) return false;
    HObject* date_obj = date_raw;
    (*date_obj.extra_ptr()).func.builtin_fn_index = (int)BUILTIN_DATE;

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
    if (!register_string_proto_method(date_obj, heap, "now", BUILTIN_DATE_NOW)) return false;

    // Add Date.UTC() static method
    if (!register_string_proto_method(date_obj, heap, "UTC", BUILTIN_DATE_UTC)) return false;

    // Add Date.parse() static method
    if (!register_string_proto_method(date_obj, heap, "parse", BUILTIN_DATE_PARSE)) return false;

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
