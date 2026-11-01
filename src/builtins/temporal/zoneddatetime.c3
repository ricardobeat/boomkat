// Temporal.ZonedDateTime bindings: constructor, statics, getters, and
// prototype methods.
//
// This is where the instant axis and the local wall-clock axis meet, so it
// owns add_zoned_datetime (the spec's AddZonedDateTime) that Duration.total,
// Duration.compare and round() all share.
module boomkat::builtins @feat(TEMPORAL);

import boomkat::types;
import boomkat::heap;
import boomkat::hobject;
import boomkat::hbigint;
import boomkat::hstring;
import boomkat::env;
import boomkat::vm;
import boomkat::lib::temporal;
import libc;
import std::math;
import std::io;
import std::time;



// ============================================================================
// Temporal.ZonedDateTime
//
// The slots retain epoch nanoseconds, a time-zone object and a CalendarId.
// ============================================================================

fn HObject*? alloc_zoneddatetime(Heap* hp, hbigint::HBigInt* ns, HObject* tz, temporal::CalendarId calendar) {
    if (ns == null) return null;
    HObject*? raw = hp.alloc_object(hobject::ObjClass.TEMPORAL_ZONEDDATETIME);
    if (catch err = raw) return err~;
    HObject* obj = raw;

    ((types::HeapHeader*)ns).incref();
    ((types::HeapHeader*)tz).incref();
    obj.extra.temporal.big_ns = ns;
    obj.extra.temporal.timezone = tz;
    obj.extra.temporal.calendar = calendar;
    return obj;
}

// Temporal.ZonedDateTime(epochNanoseconds, timeZone[, calendar])
fn void builtin_temporal_zoneddatetime_ctor(BuiltinContext* ctx) {
    if (!ctx.is_constructor) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "Temporal.ZonedDateTime requires new");
        return;
    }
    if (ctx.argc < 2) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "Temporal.ZonedDateTime requires epochNanoseconds and timeZone args");
        return;
    }
    TVal* narg = arg_at(ctx, 0);
    bool ok;
    hbigint::HBigInt* b = builtin_to_bigint(ctx, narg, &ok);
    if (!ok) return;
    // Per spec step 3: `IsValidEpochNanoseconds` rejects values outside
    // ±100,000,000 days of 1970-01-01T00:00:00Z. The check needs the BigInt
    // in 128-bit form; BigInts larger than int128 are *always* outside the
    // range, so a BigInt that doesn't fit int128 also rejects.
    {
        bool fits = b.fits_int128();
        int128 ns128 = b.to_int128();
        int128 ns_limit = temporal::INSTANT_MAX_NS;
        if (!fits || ns128 > ns_limit || ns128 < -ns_limit) {
            ctx.heap.decref((types::HeapHeader*)b);
            builtin_throw(ctx, ctx.heap.range_err_proto, "Temporal.ZonedDateTime: epochNanoseconds outside valid range");
            return;
        }
    }

    // timeZone may be a string or a Temporal.TimeZone object.
    TVal* tzarg = arg_at(ctx, 1);
    HObject* tz;
    if (tzarg.is_object() && tzarg.get_heapptr() != null
        && ((HObject*)tzarg.get_heapptr()).get_class() == hobject::ObjClass.TEMPORAL_TIMEZONE) {
        tz = (HObject*)tzarg.get_heapptr();
    } else if (tzarg.is_string()) {
        // Symbols are string-tagged but cannot be a timezone.
        HString* tzs_str = builtin_to_string_vm(ctx, tzarg);
        if (ctx.should_throw) return;
        String s = tzs_str != null ? (String)tzs_str.token_text() : (String)"";
        // A bare timezone identifier is an offset or an IANA name. An ISO
        // date-time string is valid input to `Temporal.ZonedDateTime.from`
        // (extracting the offset/bracket zone) but not as a constructor
        // argument here, so reject it (test262 ZonedDateTime/timezone-iso-string).
        usz probe = 0;
        if (temporal::now_skip_iso_prefix((char[])s, &probe)) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "ISO date-time string is not a valid time zone identifier");
            return;
        }
        HObject* tz_o = resolve_tz_from_string(ctx, s);
        if (tz_o == null) return;
        tz = tz_o;
    } else {
        builtin_throw(ctx, ctx.heap.type_err_proto, "Temporal.ZonedDateTime requires a string or TimeZone object");
        return;
    }

    temporal::CalendarId calendar;
    if (!calendar_ctor_arg(ctx, arg_at(ctx, 2), &calendar)) return;
    HObject*? obj_o = alloc_zoneddatetime(ctx.heap, b, tz, calendar);
    if (catch err = obj_o) { builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return; }
    HObject* obj = obj_o;
    if (ctx.is_constructor) {
        ctx.heap.set_prototype(obj, builtin_proto_from_new_target(ctx, ctx.heap.temporal_zoneddatetime_proto));
    } else {
        ctx.heap.set_prototype(obj, ctx.heap.temporal_zoneddatetime_proto);
    }
    ctx.result_object(obj);
}

// Resolve a timezone string to a Temporal.TimeZone object. The string may be
// an IANA zone name, an offset like "+01:00", "Z", or a full ISO date-time
// with a bracketed zone annotation like "2021-08-19T17:30Z[UTC]" — in the
// last case, the bracketed annotation wins and any leading ISO prefix is
// validated and ignored. Empty strings, sub-minute offsets, bare date-times
// without a zone, unknown IANA names, and negative-zero years throw
// RangeError per spec.
fn HObject* resolve_tz_from_string(BuiltinContext* ctx, String s) {
    if (s.len == 0) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "empty time zone string");
        return null;
    }

    long off_sec = 0;
    bool off_known = false;
    String zone_name = (String)"";
    bool zone_known = false;
    bool is_z = false;
    // Reject bare sub-minute offsets like `+01:35:00.000000000` or
    // `-12:12:59.9`. The sub-minute `.` / `,` form is only valid inside
    // the date-time prefix of a ZonedDateTime ISO string (e.g. the
    // offset of `2021-08-19T17:30:45.123-12:12[+01:00]`), not as a
    // time-zone identifier on its own. The bracket path (e.g.
    // `2021-08-19T17:30-12:12[+01:46]`) is handled later.
    if (s.len > 0 && (s[0] == '+' || s[0] == '-')) {
        for (usz chk = 0; chk < s.len; chk++) {
            if (s[chk] == '.' || s[chk] == ',') {
                builtin_throw(ctx, ctx.heap.range_err_proto, "sub-minute time zone identifier is not allowed");
                return null;
            }
        }
        // Sub-minute `:SS` is also disallowed for bare-offset identifiers.
        int cs = 0;
        for (usz chk = 0; chk < s.len; chk++) {
            if (s[chk] == ':') cs++;
        }
        if (cs >= 2) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "sub-minute time zone identifier is not allowed");
            return null;
        }
    }
    if (!now_resolve_tz(ctx, s, &off_sec, &off_known, &zone_name, &zone_known, &is_z)) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "invalid time zone string");
        return null;
    }

    if (off_known) {
        if (is_z) {
            // Z designator (not +HH:MM) in a datetime string without bracket
            // annotation means the UTC time zone, not +00:00.
            HObject*? tz_o = alloc_timezone(ctx.heap, (String)"UTC");
            if (catch err = tz_o) { builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return null; }
            return tz_o;
        }
        // Canonicalize as a "+HH:MM" string for the TimeZone id.
        char[8] buf;
        long mag = off_sec < 0 ? -off_sec : off_sec;
        buf[0] = off_sec >= 0 ? '+' : '-';
        buf[1] = (char)('0' + (int)(mag / 3600 / 10));
        buf[2] = (char)('0' + (int)(mag / 3600 % 10));
        buf[3] = ':';
        buf[4] = (char)('0' + (int)((mag % 3600) / 60 / 10));
        buf[5] = (char)('0' + (int)((mag % 3600) / 60 % 10));
        buf[6] = 0;
        HObject*? tz_o = alloc_timezone(ctx.heap, (String)buf[:6]);
        if (catch err = tz_o) { builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return null; }
        return tz_o;
    }
    char[64] canon_buf;
    if (!temporal::tzdb_zone_exists_ci(zone_name, &canon_buf[0], 64)) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "Unknown time zone");
        return null;
    }
    // canon_buf is null-terminated. Convert to a C3 slice for alloc_timezone.
    usz n = 0;
    while (n < 64 && canon_buf[n] != 0) n += 1;
    char[] canon_slice = canon_buf[:n];
    HObject*? tz_o = alloc_timezone(ctx.heap, (String)canon_slice);
    if (catch err = tz_o) { builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return null; }
    return tz_o;
}

// Convert string or TimeZone to a TimeZone HObject. Per spec, anything that
// cannot be converted to a string (Symbols, plain objects without a useful
// toString) raises TypeError; unparseable offset strings raise RangeError.
// `ToTemporalTimeZone` also accepts a `Temporal.ZonedDateTime` and reads its
// [[TimeZone]] slot, so the engine unwraps that here.
fn HObject*? to_temporal_tz(BuiltinContext* ctx, TVal* arg) {
    if (arg.is_object() && arg.get_heapptr() != null) {
        HObject* o = (HObject*)arg.get_heapptr();
        if (o.get_class() == hobject::ObjClass.TEMPORAL_TIMEZONE) {
            return o;
        }
        if (o.get_class() == hobject::ObjClass.TEMPORAL_ZONEDDATETIME) {
            // ZDT.[[TimeZone]] is a TimeZone HObject stored in slot 1.
            HObject* tz = (HObject*)o.extra.temporal.timezone;
            if (tz == null) return null;
            ((types::HeapHeader*)tz).incref();
            return tz;
        }
    }
    if (arg.is_string()) {
        HString* hs = (HString*)arg.get_heapptr();
        // Symbols are string-tagged but cannot be converted via get_cstr().
        HString* s_str = builtin_to_string_vm(ctx, arg);
        if (ctx.should_throw) return null;
        String s = s_str != null ? (String)s_str.token_text() : (String)"";
        HObject* tz = resolve_tz_from_string(ctx, s);
        if (tz == null) return null;
        return tz;
    }
    builtin_throw(ctx, ctx.heap.type_err_proto, "time zone must be a string or Temporal.TimeZone object");
    return null;
}

// GetTemporalDisambiguationOption, GetTemporalOffsetOption and GetTemporalOverflowOption,
// in observable property order. Offset mode 0 lets from() default to reject and with() to
// prefer; 1 is use, 2 ignore, 3 prefer and 4 reject. Returns -1 after throwing.
fn int validate_zdt_from_options(BuiltinContext* ctx, temporal::OverflowKind* out_overflow, int* out_disambiguation = null) {
    *out_overflow = temporal::OverflowKind.CONSTRAIN;
    if (out_disambiguation != null) *out_disambiguation = 0;
    if (ctx.argc < 2) return 0;
    TVal ov = ctx.regs[ctx.base_reg + 1];
    if (ov.is_undefined()) return 0;
    if (!ov.is_object() || ov.get_heapptr() == null) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "options must be an object");
        return -1;
    }
    HObject* opts = (HObject*)ov.get_heapptr();
    TVal dv = prop_or_undefined_pa(ctx, opts, "disambiguation");
    if (ctx.should_throw) return -1;
    if (!dv.is_undefined()) {
        HString* ds = builtin_to_string_vm(ctx, &dv);
        if (ctx.should_throw) return -1;
        char[] dstr = ds.token_text();
        if (dstr != "compatible" && dstr != "earlier" && dstr != "later" && dstr != "reject") {
            builtin_throw(ctx, ctx.heap.range_err_proto, "invalid disambiguation");
            return -1;
        }
        if (out_disambiguation != null) *out_disambiguation = dstr == "earlier" ? 1 : dstr == "later" ? 2 : dstr == "reject" ? 3 : 0;
    }
    TVal offv = prop_or_undefined_pa(ctx, opts, "offset");
    if (ctx.should_throw) return -1;
    int offset_mode = 0;
    if (!offv.is_undefined()) {
        HString* os = builtin_to_string_vm(ctx, &offv);
        if (ctx.should_throw) return -1;
        char[] ostr = os.token_text();
        if (ostr == "use") { offset_mode = 1; }
        else if (ostr == "ignore") { offset_mode = 2; }
        else if (ostr == "prefer") { offset_mode = 3; }
        else if (ostr == "reject") { offset_mode = 4; }
        else {
            builtin_throw(ctx, ctx.heap.range_err_proto, "invalid offset option");
            return -1;
        }
    }
    TVal ofv = prop_or_undefined_pa(ctx, opts, "overflow");
    if (ctx.should_throw) return -1;
    if (!ofv.is_undefined()) {
        HString* os2 = builtin_to_string_vm(ctx, &ofv);
        if (ctx.should_throw) return -1;
        char[] ostr2 = os2.token_text();
        if (ostr2 != "constrain" && ostr2 != "reject") {
            builtin_throw(ctx, ctx.heap.range_err_proto, "invalid overflow option");
            return -1;
        }
        *out_overflow = ostr2 == "reject" ? temporal::OverflowKind.REJECT : temporal::OverflowKind.CONSTRAIN;
    }
    return offset_mode;
}

// InterpretISODateTimeOffset: exact offsets select a candidate before disambiguation.
// String offsets with minute precision may match an IANA offset rounded to a minute.
fn bool zdt_check_offset_agreement(BuiltinContext* ctx, String zone, int128 wall_ns, long offset_ns,
                                   int mode, int128* epoch, int disambiguation = 0, bool match_minutes = false) {
    *epoch = wall_ns - offset_ns;
    if (mode == 1) return true;
    long wall = (long)(wall_ns / temporal::NS_PER_SEC);
    long frac = (long)(wall_ns % temporal::NS_PER_SEC);
    if (frac < 0) { wall--; frac += temporal::NS_PER_SEC; }
    if (mode != 2) {
        foreach (side : (int[]){ 1, 2 }) {
            int128 candidate = temporal::zdt_local_to_epoch_ns(zone, wall, frac, side);
            long seconds = (long)(candidate / temporal::NS_PER_SEC) - (candidate % temporal::NS_PER_SEC < 0 ? 1L : 0L);
            long off = temporal::tzdb_offset_for_zone_at(zone, seconds) * 1000000000L;
            long compared = off;
            if (match_minutes && temporal::tzdb_zone_exists(zone)) {
                compared = (off < 0 ? -1L : 1L) * ((math::abs(off) + 30000000000L) / 60000000000L) * 60000000000L;
            }
            if (wall_ns - candidate == off && compared == offset_ns) { *epoch = candidate; return true; }
        }
        if (mode != 3) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "offset does not match the time zone");
            return false;
        }
    }
    bool rejected = false;
    *epoch = temporal::zdt_local_to_epoch_ns(zone, wall, frac, disambiguation, &rejected);
    if (rejected) builtin_throw(ctx, ctx.heap.range_err_proto, "wall time is skipped or repeated");
    return !rejected;
}

// ToTemporalZonedDateTime: resolve the instant, time zone and calendar before allocation.
fn bool to_temporal_zoned_datetime(BuiltinContext* ctx, TVal* arg, int128* ns, HObject** zone,
                                    temporal::CalendarId* cal, bool read_options = false) {
    if (arg.is_object()) {
        HObject* o = (HObject*)arg.get_heapptr();
        temporal::OverflowKind overflow = temporal::OverflowKind.CONSTRAIN;
        if (o.get_class() == hobject::ObjClass.TEMPORAL_ZONEDDATETIME) {
            *ns = o.extra.temporal.big_ns.to_int128();
            *zone = o.extra.temporal.timezone;
            *cal = o.extra.temporal.calendar;
            return !read_options || validate_zdt_from_options(ctx, &overflow) >= 0;
        }
        temporal::CalendarFields fields;
        if (!bag_calendar(ctx, o, cal)
            || !prepare_calendar_fields(ctx, *cal, o, DATE_FIELD_NAMES | TIME_FIELD_NAMES | temporal::field_set(OFFSET, TIME_ZONE),
                                        temporal::field_set(TIME_ZONE), false, &fields, zone)) return false;
        int disambiguation = 0;
        int mode = read_options ? validate_zdt_from_options(ctx, &overflow, &disambiguation) : 0;
        if (mode < 0) return false;
        temporal::CivilDateTime dt;
        if (!interpret_datetime_fields(ctx, *cal, &fields, overflow, &dt)) return false;
        long wall = temporal::epoch_days_from_civil(dt.date.y, (int)dt.date.m, (int)dt.date.d) * 86400
            + dt.time.h * 3600 + dt.time.mi * 60 + dt.time.s;
        long frac = dt.time.ms * 1000000L + dt.time.us * 1000L + dt.time.ns;
        String name = timezone_name(*zone);
        int128 naive = (int128)wall * temporal::NS_PER_SEC + frac;
        if (fields.has(OFFSET)) {
            if (!zdt_check_offset_agreement(ctx, name, naive, fields.get(OFFSET), mode, ns, disambiguation)) return false;
        } else {
            bool rejected = false;
            *ns = temporal::zdt_local_to_epoch_ns(name, wall, frac, disambiguation, &rejected);
            if (rejected) { builtin_throw(ctx, ctx.heap.range_err_proto, "wall time is skipped or repeated"); return false; }
        }
    } else if (arg.is_string() && !((HString*)arg.get_heapptr()).is_symbol()) {
        HString* s = (HString*)arg.get_heapptr();
        if (s == null) { builtin_throw(ctx, ctx.heap.range_err_proto, "invalid string"); return false; }
        char[] text = s.token_text();
        temporal::ParsedIsoZonedDateTime p = { .year = 0, .month = 0, .day = 0, .hour = 0, .minute = 0, .second = 0, .nanos = 0, .offset_seconds = 0, .has_offset = false, .is_z = false };
        if (!temporal::parse_iso_zoneddatetime_string(text, &p)) {
                builtin_throw(ctx, ctx.heap.range_err_proto, "Temporal.ZonedDateTime.from: invalid ISO string");
            return false;
        }
        temporal::OverflowKind overflow;
        int disambiguation = 0;
        int mode = read_options ? validate_zdt_from_options(ctx, &overflow, &disambiguation) : 0;
        if (mode < 0) return false;
        if (mode != 1 && mode != 2 && !temporal::epoch_days_in_range(temporal::epoch_days_from_civil(p.year, p.month, p.day))) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "wall date is out of range"); return false;
        }
        HObject* tz = resolve_tz_from_string(ctx, (String)p.timezone);
        if (tz == null) return false;
        long wall = temporal::epoch_days_from_civil(p.year, p.month, p.day) * 86400
            + p.hour * 3600L + p.minute * 60L + p.second;
        int128 naive = (int128)wall * temporal::NS_PER_SEC + p.nanos;
        if (!p.has_time) {
            *ns = temporal::zdt_start_of_day_ns(timezone_name(tz), wall);
        } else if (p.is_z) {
            *ns = naive;
        } else if (p.has_offset) {
            long offset = p.offset_seconds * 1000000000L + p.offset_nanos;
            if (!zdt_check_offset_agreement(ctx, timezone_name(tz), naive, offset, mode, ns, disambiguation, p.offset_minutes)) return false;
        } else {
            bool rejected = false;
            *ns = temporal::zdt_local_to_epoch_ns(timezone_name(tz), wall, p.nanos, disambiguation, &rejected);
            if (rejected) { builtin_throw(ctx, ctx.heap.range_err_proto, "wall time is skipped or repeated"); return false; }
        }
        *zone = tz;
        *cal = p.calendar;
    } else {
        builtin_throw(ctx, ctx.heap.type_err_proto, "a ZonedDateTime needs a string or an object");
        return false;
    }
    if (!temporal::instant_in_range(*ns)) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "instant is out of range");
        return false;
    }
    return true;
}

fn void zdt_result(BuiltinContext* ctx, int128 ns, HObject* tz, temporal::CalendarId cal) {
    hbigint::HBigInt*? big = hbigint::hbigint_alloc(ctx.heap, ns);
    if (catch big) { builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return; }
    zdt_from_parts(ctx, big, tz, cal);
}

fn void builtin_temporal_zoneddatetime_from(BuiltinContext* ctx) {
    int128 ns;
    HObject* tz;
    temporal::CalendarId cal;
    if (to_temporal_zoned_datetime(ctx, arg_at(ctx, 0), &ns, &tz, &cal, true)) zdt_result(ctx, ns, tz, cal);
}

fn void builtin_temporal_zoneddatetime_compare(BuiltinContext* ctx) {
    int128 a, b;
    HObject* tz;
    temporal::CalendarId cal;
    if (!to_temporal_zoned_datetime(ctx, arg_at(ctx, 0), &a, &tz, &cal)
        || !to_temporal_zoned_datetime(ctx, arg_at(ctx, 1), &b, &tz, &cal)) return;
    ctx.result_fastint(a < b ? -1 : a > b ? 1 : 0);
}

fn hbigint::HBigInt* zdt_value(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_ZONEDDATETIME, "this is not a Temporal.ZonedDateTime")) return null;
    HObject* obj = (HObject*)ctx.this_val.get_heapptr();
    return obj.extra.temporal.big_ns;
}

fn void builtin_temporal_zoneddatetime_proto_epochNanoseconds(BuiltinContext* ctx) {
    hbigint::HBigInt* b = zdt_value(ctx);
    if (b == null) return;
    ctx.result_bigint(b);
}

fn void builtin_temporal_zoneddatetime_proto_epochSeconds(BuiltinContext* ctx) {
    hbigint::HBigInt* b = zdt_value(ctx);
    if (b == null) return;
    double d;
    if (!bigint_to_epoch_number(b, &d, ctx)) return;
    ctx.result_number(math::floor(d / 1e9));
}

fn void builtin_temporal_zoneddatetime_proto_epochMilliseconds(BuiltinContext* ctx) {
    hbigint::HBigInt* b = zdt_value(ctx);
    if (b == null) return;
    double d;
    if (!bigint_to_epoch_number(b, &d, ctx)) return;
    ctx.result_number(math::floor(d / 1e6));
}

fn void builtin_temporal_zoneddatetime_proto_epochMicroseconds(BuiltinContext* ctx) {
    hbigint::HBigInt* b = zdt_value(ctx);
    if (b == null) return;
    double d;
    if (!bigint_to_epoch_number(b, &d, ctx)) return;
    ctx.result_number(math::floor(d / 1e3));
}

fn void builtin_temporal_zoneddatetime_proto_timeZoneId(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_ZONEDDATETIME, "this is not a Temporal.ZonedDateTime")) return;
    HObject* obj = (HObject*)ctx.this_val.get_heapptr();
    HObject* tz = obj.extra.temporal.timezone;
    if (tz == null) { ctx.result_string(builtin_intern_string(ctx.heap, "")); return; }
    HString* id = tz.extra.temporal.identifier.borrow();
    ctx.result_string(id == null ? builtin_intern_string(ctx.heap, "") : id);
}


// Format a ZonedDateTime as an ISO string: wall time in the zone's current
// offset with fractional seconds, the ±HH:MM offset, and (unless drop_zone) the
// [Zone] bracket. `digits` is -1 for auto or 0..9. Reads epoch nanoseconds via
// to_int128 so sub-second precision survives beyond 2^53.
fn void zdt_iso_string(BuiltinContext* ctx, hbigint::HBigInt* b, HObject* tz, int digits, temporal::TemporalRoundMode rm, bool drop_zone,
                      int show_offset, int show_tz, int show_cal, temporal::CalendarId cal) {
    // show_offset: 1 = show, 0 = hide; show_tz: 1 = show, 0 = hide, 2 = the
    // `!` critical flag; show_cal: 0 = auto (omits ISO), 1 = always,
    // 2 = never, 3 = critical. The caller has already read and validated the
    // option strings; nothing is re-read here.
    int128 total = b.to_int128();
    long epoch_secs = (long)(total / temporal::NS_PER_SEC);
    long ns_rem = (long)(total % temporal::NS_PER_SEC);
    if (ns_rem < 0) { epoch_secs--; ns_rem += temporal::NS_PER_SEC; }
    String zone = tz == null ? "" : timezone_name(tz);
    int off = tz == null ? 0 : temporal::tzdb_offset_for_zone_at(zone, epoch_secs);
    long local_secs = epoch_secs + off;
    long increment = digits == -10 ? 60 * temporal::NS_PER_SEC : 1;
    if (digits >= 0) for (int i = digits; i < 9; i++) increment *= 10;
    if (increment > 1) {
        long day = temporal::cal_floor_div(local_secs, 86400) * 86400;
        int128 time = (int128)(local_secs - day) * temporal::NS_PER_SEC + ns_rem;
        int128 naive = (int128)day * temporal::NS_PER_SEC + temporal::round_long_ns_128(time, (int128)increment, rm);
        if (!zdt_check_offset_agreement(ctx, zone, naive, (long)off * 1000000000L, 3, &total)) return;
        epoch_secs = (long)(total / temporal::NS_PER_SEC);
        ns_rem = (long)(total % temporal::NS_PER_SEC);
        if (ns_rem < 0) { epoch_secs--; ns_rem += temporal::NS_PER_SEC; }
        off = temporal::tzdb_offset_for_zone_at(zone, epoch_secs);
        local_secs = epoch_secs + off;
    }

    temporal::BrokenDownTime bd = temporal::civil_from_seconds(local_secs);
    char[192] buf;
    int n;
    // Year formatting per GetISOPartsFromEpoch: 0..9999 renders as a 4-digit
    // unsigned year; negative or >9999 renders as a 6-digit signed year.
    long y = bd.y;
    if (digits == -10) {
        if (y < 0) {
            n = libc::snprintf(&buf, buf.len, "-%06ld-%02ld-%02ldT%02ld:%02ld",
                -y, (long)bd.m + 1, (long)bd.d, (long)bd.h, (long)bd.mi);
        } else if (y > 9999) {
            n = libc::snprintf(&buf, buf.len, "+%06ld-%02ld-%02ldT%02ld:%02ld",
                y, (long)bd.m + 1, (long)bd.d, (long)bd.h, (long)bd.mi);
        } else {
            n = libc::snprintf(&buf, buf.len, "%04ld-%02ld-%02ldT%02ld:%02ld",
                y, (long)bd.m + 1, (long)bd.d, (long)bd.h, (long)bd.mi);
        }
    } else {
        if (y < 0) {
            n = libc::snprintf(&buf, buf.len, "-%06ld-%02ld-%02ldT%02ld:%02ld:%02ld",
                -y, (long)bd.m + 1, (long)bd.d, (long)bd.h, (long)bd.mi, (long)bd.s);
        } else if (y > 9999) {
            n = libc::snprintf(&buf, buf.len, "+%06ld-%02ld-%02ldT%02ld:%02ld:%02ld",
                y, (long)bd.m + 1, (long)bd.d, (long)bd.h, (long)bd.mi, (long)bd.s);
        } else {
            n = libc::snprintf(&buf, buf.len, "%04ld-%02ld-%02ldT%02ld:%02ld:%02ld",
                y, (long)bd.m + 1, (long)bd.d, (long)bd.h, (long)bd.mi, (long)bd.s);
        }
        n += temporal::format_fractional_seconds(&buf[n], ns_rem, digits, rm);
    }
    long minute_offset = (off < 0 ? -1L : 1L) * ((math::abs((long)off) + 30) / 60) * 60;
    temporal::format_offset_seconds(&buf[n], (int)minute_offset);
    if (show_offset == 1) n += 6;
    if (!drop_zone && zone.len > 0 && zone.ptr != null && show_tz > 0) {
        int zn = libc::snprintf(&buf[n], buf.len - (usz)n, (show_tz == 2) ? "[!%s]" : "[%s]", (char*)zone.ptr);
        n += zn;
    }
    usz len = (usz)n;
    append_calendar_annotation(&buf, &len, cal, (ShowCalendar)show_cal);
    ctx.result_string(builtin_intern_string(ctx.heap, buf[:len]));
}

fn void builtin_temporal_zoneddatetime_proto_toString(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_ZONEDDATETIME, "this is not a Temporal.ZonedDateTime")) return;
    HObject* obj = (HObject*)ctx.this_val.get_heapptr();
    int digits;
    temporal::TemporalRoundMode rm;
    // Display flags for offset / timeZoneName / calendarName. Defaults match
    // the spec: offset and timeZoneName show, calendarName shows only when
    // non-ISO ("auto"). Set from the validated option strings below.
    int show_offset = 1; // 1 = show, 0 = hide
    int show_tz = 1;     // 1 = show, 0 = hide, 2 = critical flag
    int show_cal = 0;    // 0 = auto, 1 = always, 2 = never, 3 = critical
    // Probe all seven ZDT.toString options in alphabetical order:
    // calendarName, fractionalSecondDigits, offset, roundingMode,
    // smallestUnit, timeZoneName, timeZone. The order-of-operations
    // fixture asserts each `get options.X` / `get options.X.toString` /
    // `call options.X.toString` triple in that order, so ToString the
    // value right after the get. Validate only after all reads succeed —
    // matches the spec's `Read options / Validate` split.
    if (ctx.argc >= 1 && !ctx.regs[ctx.base_reg].is_undefined()) {
        TVal ov = ctx.regs[ctx.base_reg];
        if (!ov.is_object() || ov.get_heapptr() == null) {
            builtin_throw(ctx, ctx.heap.type_err_proto, "options must be an object");
            return;
        }
        HObject* opts = (HObject*)ov.get_heapptr();
        HString* cal_s = null;
        HString* fd_s = null;
        HString* off_s = null;
        HString* rm_str = null;
        HString* su_s = null;
        HString* tzn_s = null;
        bool fd_is_number = false;
        double fd_num = 0;

        // calendarName
        TVal cn = prop_or_undefined_pa(ctx, opts, "calendarName");
        if (ctx.should_throw) return;
        if (!cn.is_undefined()) {
            cal_s = builtin_to_string_vm(ctx, &cn);
            if (ctx.should_throw) return;
        }

        // fractionalSecondDigits
        {
            TVal fd = prop_or_undefined_pa(ctx, opts, "fractionalSecondDigits");
            if (ctx.should_throw) return;
            if (!fd.is_undefined()) {
                // GetStringOrNumberOption uses a Number numerically and never
                // stringifies it; only non-Numbers take the string path,
                // where "auto" is the sole valid value.
                if (fd.is_numeric()) {
                    fd_is_number = true;
                    fd_num = fd.get_number_or_fastint();
                } else {
                    fd_s = builtin_to_string_vm(ctx, &fd);
                    if (ctx.should_throw) return;
                }
            }
        }

        // offset
        {
            TVal offv = prop_or_undefined_pa(ctx, opts, "offset");
            if (ctx.should_throw) return;
            if (!offv.is_undefined()) {
                off_s = builtin_to_string_vm(ctx, &offv);
                if (ctx.should_throw) return;
            }
        }

        // roundingMode
        {
            TVal rmod = prop_or_undefined_pa(ctx, opts, "roundingMode");
            if (ctx.should_throw) return;
            if (!rmod.is_undefined()) {
                rm_str = builtin_to_string_vm(ctx, &rmod);
                if (ctx.should_throw) return;
            }
        }

        // smallestUnit (default: no rounding; sentinel handled below).
        digits = -1;
        rm = temporal::TemporalRoundMode.TRUNC;
        {
            TVal su = prop_or_undefined_pa(ctx, opts, "smallestUnit");
            if (ctx.should_throw) return;
            if (!su.is_undefined()) {
                su_s = builtin_to_string_vm(ctx, &su);
                if (ctx.should_throw) return;
            }
        }

        // timeZoneName
        {
            TVal tzn = prop_or_undefined_pa(ctx, opts, "timeZoneName");
            if (ctx.should_throw) return;
            if (!tzn.is_undefined()) {
                tzn_s = builtin_to_string_vm(ctx, &tzn);
                if (ctx.should_throw) return;
            }
        }

        // Validate after all probes. `timeZone` is intentionally omitted from
        // this list because the ZDT.toString spec doesn't accept a `timeZone`
        // option (the zone is the receiver's).
        if (cal_s != null) {
            char[] v = cal_s.token_text();
            if (v != "auto" && v != "always" && v != "never" && v != "critical") {
                builtin_throw(ctx, ctx.heap.range_err_proto, "invalid calendarName");
                return;
            }
            if (v == "always") { show_cal = 1; }
            else if (v == "never") { show_cal = 2; }
            else if (v == "critical") { show_cal = 3; }
        }
        // fractionalSecondDigits: "auto" or a non-negative integer 0..9. When the
        // value was wrapped by the toPrimitiveObserver the coerced string is
        // already the digit text (e.g. "2" or "auto"); don't re-read the
        // bag to honour propertyBagObserver's "one get per option" rule.
        if (fd_is_number) {
            // Per spec, GetStringOrNumberOption floors non-integer values.
            double dv = math::floor(fd_num);
            if (math::is_nan(fd_num) || dv < 0 || dv > 9) {
                builtin_throw(ctx, ctx.heap.range_err_proto, "fractionalSecondDigits must be an integer 0..9 or \"auto\"");
                return;
            }
            digits = (int)dv;
        } else if (fd_s != null) {
            char[] v = fd_s.token_text();
            if (v == "auto") { digits = -1; }
            else {
                builtin_throw(ctx, ctx.heap.range_err_proto, "fractionalSecondDigits must be an integer 0..9 or \"auto\"");
                return;
            }
        }
        if (off_s != null) {
            char[] v = off_s.token_text();
            if (v != "auto" && v != "never") {
                builtin_throw(ctx, ctx.heap.range_err_proto, "invalid offset option");
                return;
            }
            show_offset = (v == "auto") ? 1 : 0;
        }
        if (rm_str != null) {
            char[] v = rm_str.token_text();
            if (v != "ceil" && v != "floor" && v != "expand" && v != "trunc"
                && v != "halfCeil" && v != "halfFloor" && v != "halfExpand"
                && v != "halfTrunc" && v != "halfEven") {
                builtin_throw(ctx, ctx.heap.range_err_proto, "invalid roundingMode");
                return;
            }
            // Map strings to temporal::TemporalRoundMode. The default before this
            // block was TRUNC; any explicit value overrides.
            if (v == "ceil") { rm = temporal::TemporalRoundMode.CEIL; }
            else if (v == "floor") { rm = temporal::TemporalRoundMode.FLOOR; }
            else if (v == "expand") { rm = temporal::TemporalRoundMode.EXPAND; }
            else if (v == "trunc") { rm = temporal::TemporalRoundMode.TRUNC; }
            else if (v == "halfCeil") { rm = temporal::TemporalRoundMode.HALF_CEIL; }
            else if (v == "halfFloor") { rm = temporal::TemporalRoundMode.HALF_FLOOR; }
            else if (v == "halfExpand") { rm = temporal::TemporalRoundMode.HALF_EXPAND; }
            else if (v == "halfTrunc") { rm = temporal::TemporalRoundMode.HALF_TRUNC; }
            else if (v == "halfEven") { rm = temporal::TemporalRoundMode.HALF_EVEN; }
        }
        if (su_s != null) {
            char[] v = su_s.token_text();
            // Sentinel -10: round to minute, no fractional part.
            if (v == "minute" || v == "minutes") { digits = -10; }
            else if (v == "second" || v == "seconds") { digits = 0; }
            else if (v == "millisecond" || v == "milliseconds") { digits = 3; }
            else if (v == "microsecond" || v == "microseconds") { digits = 6; }
            else if (v == "nanosecond" || v == "nanoseconds") { digits = 9; }
            else {
                builtin_throw(ctx, ctx.heap.range_err_proto, "invalid smallestUnit");
                return;
            }
        }
        if (tzn_s != null) {
            char[] v = tzn_s.token_text();
            if (v != "auto" && v != "never" && v != "critical") {
                builtin_throw(ctx, ctx.heap.range_err_proto, "invalid timeZoneName option");
                return;
            }
            if (v == "never") { show_tz = 0; }
            else if (v == "critical") { show_tz = 2; }
        }
    } else {
        digits = -1;
        rm = temporal::TemporalRoundMode.TRUNC;
    }
    zdt_iso_string(ctx, obj.extra.temporal.big_ns, obj.extra.temporal.timezone, digits, rm, false, show_offset, show_tz, show_cal, obj.extra.temporal.calendar);
}

fn void builtin_temporal_zoneddatetime_proto_toJSON(BuiltinContext* ctx) {
    // toJSON delegates to toString: auto precision, full output including [Zone].
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_ZONEDDATETIME, "this is not a Temporal.ZonedDateTime")) return;
    HObject* obj = (HObject*)ctx.this_val.get_heapptr();
    ctx.argc = 0;
    builtin_temporal_zoneddatetime_proto_toString(ctx);
}

fn void builtin_temporal_zoneddatetime_proto_toLocaleString(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_ZONEDDATETIME, "this is not a Temporal.ZonedDateTime")) return;
    $if $feat(INTL) && !$feat(NO_INTL_DATE):
        IntlDateState state;
        if (!intl_date_options(ctx, &state, builtin_arg(ctx, 0), builtin_arg(ctx, 1), DTF_REQ_ANY, DTF_REQ_ANY, true)) return;
        HObject* self = (HObject*)ctx.this_val.get_heapptr();
        if (self.extra.temporal.calendar != temporal::CalendarId.ISO8601 && self.extra.temporal.calendar != state.calendar) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "calendar does not match the locale"); return;
        }
        HString* zone = builtin_intern_string(ctx.heap, timezone_name(self.extra.temporal.timezone));
        intl_date_zone(ctx, zone, &state);
        if (ctx.should_throw) return;
        if (state.default_components && state.fmt.time_zone_name == 0) state.fmt.time_zone_name = 1;
        intl_date_pattern(&state);
        intl_date_result(ctx, &state, ctx.this_val, false);
    $else
        ctx.argc = 0;
        builtin_temporal_zoneddatetime_proto_toString(ctx);
    $endif
}

fn void builtin_temporal_zoneddatetime_proto_equals(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_ZONEDDATETIME, "this is not a Temporal.ZonedDateTime")) return;
    int128 ns;
    HObject* tz;
    temporal::CalendarId cal;
    if (!to_temporal_zoned_datetime(ctx, arg_at(ctx, 0), &ns, &tz, &cal)) return;
    HObject* self = (HObject*)ctx.this_val.get_heapptr();
    bool same_zone = timezone_name(tz) == timezone_name(self.extra.temporal.timezone);
    $if $feat(INTL) && !$feat(NO_INTL_DATE):
        char[128] one, two;
        usz n1 = intl_zone_canonical(timezone_name(tz), one[..]);
        usz n2 = intl_zone_canonical(timezone_name(self.extra.temporal.timezone), two[..]);
        same_zone = same_zone || (n1 > 0 && n1 == n2 && mem_eq_bytes(one[:n1], two[:n2]));
    $endif
    ctx.result_boolean(ns == self.extra.temporal.big_ns.to_int128() && cal == self.extra.temporal.calendar && same_zone);
}

// CalendarMergeFields overlays a partial record before resolving its ISO date and instant.
fn void builtin_temporal_zoneddatetime_proto_with(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_ZONEDDATETIME, "this is not a Temporal.ZonedDateTime")) return;
    HObject* bag = partial_temporal_object(ctx, arg_at(ctx, 0));
    if (bag == null) return;
    HObject* self = (HObject*)ctx.this_val.get_heapptr();
    temporal::CalendarId cal = self.extra.temporal.calendar;
    temporal::CivilDateTime wall = zdt_wall_datetime(self);
    temporal::CalendarFields fields = temporal::iso_date_to_fields(cal, wall.date, DATE);
    fields.put(HOUR, wall.time.h); fields.put(MINUTE, wall.time.mi); fields.put(SECOND, wall.time.s);
    fields.put(MILLISECOND, wall.time.ms); fields.put(MICROSECOND, wall.time.us); fields.put(NANOSECOND, wall.time.ns);
    String zone = timezone_name(self.extra.temporal.timezone);
    int128 epoch = self.extra.temporal.big_ns.to_int128();
    long epoch_seconds = (long)(epoch / temporal::NS_PER_SEC) - (epoch % temporal::NS_PER_SEC < 0 ? 1L : 0L);
    long off = temporal::tzdb_offset_for_zone_at(zone, epoch_seconds);
    fields.put(OFFSET, off * 1000000000L);
    temporal::CalendarFields partial;
    if (!prepare_calendar_fields(ctx, cal, bag, DATE_FIELD_NAMES | TIME_FIELD_NAMES | temporal::field_set(OFFSET), 0, true, &partial)) return;
    fields = temporal::calendar_merge_fields(cal, fields, partial);
    temporal::OverflowKind overflow;
    int disambiguation = 0;
    int mode = validate_zdt_from_options(ctx, &overflow, &disambiguation);
    if (mode < 0 || !interpret_datetime_fields(ctx, cal, &fields, overflow, &wall)) return;
    long seconds = temporal::epoch_days_from_civil(wall.date.y, (int)wall.date.m, (int)wall.date.d) * 86400
        + wall.time.h * 3600 + wall.time.mi * 60 + wall.time.s;
    int128 naive = (int128)seconds * temporal::NS_PER_SEC + (int128)(wall.time.ms * 1000000L + wall.time.us * 1000L + wall.time.ns);
    int128 ns;
    if (!zdt_check_offset_agreement(ctx, zone, naive, fields.get(OFFSET), mode == 0 ? 3 : mode, &ns, disambiguation)) return;
    if (!temporal::instant_in_range(ns)) { builtin_throw(ctx, ctx.heap.range_err_proto, "instant is out of range"); return; }
    zdt_result(ctx, ns, self.extra.temporal.timezone, cal);
}


// Build a ZonedDateTime and consume the caller's reference to its epoch nanoseconds.
fn void zdt_from_parts(BuiltinContext* ctx, hbigint::HBigInt* ns, HObject* tz, temporal::CalendarId cal) {
    if (ns == null) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "ZonedDateTime: resulting instant outside valid epoch-nanoseconds range");
        return;
    }
    HObject*? obj_o = alloc_zoneddatetime(ctx.heap, ns, tz, cal);
    if (catch err = obj_o) { ctx.heap.decref((types::HeapHeader*)ns); builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return; }
    HObject* obj = obj_o;
    ctx.heap.decref((types::HeapHeader*)ns);
    ctx.heap.set_prototype(obj, ctx.heap.temporal_zoneddatetime_proto);
    ctx.result_object(obj);
}

// this.withTimeZone(timeZone) — same instant, different zone.
fn void builtin_temporal_zoneddatetime_proto_withTimeZone(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_ZONEDDATETIME, "this is not a Temporal.ZonedDateTime")) return;
    if (ctx.argc < 1) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "withTimeZone requires a Temporal.TimeZone");
        return;
    }
    TVal* arg = arg_at(ctx, 0);
    // Per spec, withTimeZone accepts either a TimeZone object or a string
    // / ISO-string time-zone identifier. Earlier builds rejected strings
    // outright, but test262 (e.g. `disregard-time-zone-ids-if-exact-
    // times-are-equal.js`) calls `zdt.withTimeZone("+05:30")`.
    HObject* new_tz_obj;
    if (arg.is_object() && arg.get_heapptr() != null
        && ((HObject*)arg.get_heapptr()).get_class() == hobject::ObjClass.TEMPORAL_TIMEZONE) {
        new_tz_obj = (HObject*)arg.get_heapptr();
    } else if (try maybe_tz = to_temporal_tz(ctx, arg)) {
        if (ctx.should_throw) return;
        new_tz_obj = maybe_tz;
    } else {
        return;
    }
    HObject* self = (HObject*)ctx.this_val.get_heapptr();
    ((types::HeapHeader*)self.extra.temporal.big_ns).incref();
    zdt_from_parts(ctx, self.extra.temporal.big_ns, new_tz_obj, self.extra.temporal.calendar);
}

fn void builtin_temporal_zoneddatetime_proto_withCalendar(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_ZONEDDATETIME, "this is not a Temporal.ZonedDateTime")) return;
    if (ctx.argc < 1 || ctx.regs[ctx.base_reg].is_undefined()) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "withCalendar requires a calendar");
        return;
    }
    TVal* arg = arg_at(ctx, 0);
    temporal::CalendarId cal;
    if (!calendar_from_arg(ctx, arg, &cal)) return;
    HObject* self = (HObject*)ctx.this_val.get_heapptr();
    ((types::HeapHeader*)self.extra.temporal.big_ns).incref();
    ((types::HeapHeader*)self.extra.temporal.timezone).incref();
    zdt_from_parts(ctx, self.extra.temporal.big_ns, self.extra.temporal.timezone, cal);
}

fn void builtin_temporal_zoneddatetime_proto_add(BuiltinContext* ctx) {
    zdt_add_sub(ctx, false);
}

fn void builtin_temporal_zoneddatetime_proto_subtract(BuiltinContext* ctx) {
    zdt_add_sub(ctx, true);
}

// this.add(duration) / this.subtract(duration) — add the Duration's time delta
// to the underlying instant, keeping the zone and calendar.
// Spec AddZonedDateTime: add a duration to an instant in a time zone.
//
// The two halves of a duration move on different axes, which is the whole
// point of the zoned case. Years/months/weeks/days are *calendar* units: they
// shift the local wall-clock date, which is then re-resolved against the zone,
// so a "day" across a DST boundary is 23 or 25 hours rather than a fixed 24.
// Hours and below are an exact elapsed-nanosecond shift on the instant, which
// no offset transition affects.
//
// Returns false on overflow of the representable instant range. `zone` may be
// empty for a fixed-offset (UTC) zone, in which case the local axis and the
// instant axis coincide and every day is exactly 24 hours.
fn bool add_zoned_datetime(HObject* zdt, temporal::DurationParts dp, long sign,
                           temporal::OverflowKind overflow, int128* out) {
    long wy, wm, wd; int wh, wmi, ws, wms, wus, wns, woff;
    zdt_wall_fields(zdt, &wy, &wm, &wd, &wh, &wmi, &ws, &wms, &wus, &wns, &woff);

    hbigint::HBigInt* base_big = (hbigint::HBigInt*)zdt.extra.temporal.big_ns;
    int128 base = base_big.to_int128();

    if (dp.years != 0 || dp.months != 0 || dp.weeks != 0 || dp.days != 0) {
        temporal::CivilDate? added = temporal::calendar_add(zdt.extra.temporal.calendar, { wy, wm, wd },
            sign * dp.years, sign * dp.months, sign * dp.weeks, sign * dp.days, overflow);
        if (catch added) return false;
        temporal::CivilDate d = added;
        if (!temporal::is_valid_iso_datetime(d.y, (int)d.m, (int)d.d, wh, wmi, ws, wms, wus, wns)) return false;

        long wall_secs = temporal::epoch_days_from_civil(d.y, (int)d.m, (int)d.d) * 86400
            + (long)wh * 3600 + (long)wmi * 60 + (long)ws;
        long wall_frac = (long)wms * 1000000 + (long)wus * 1000 + (long)wns;
        String zone = zdt.extra.temporal.timezone == null ? "" : timezone_name(zdt.extra.temporal.timezone);
        base = temporal::zdt_local_to_epoch_ns(zone, wall_secs, wall_frac);
    }

    // Time units: an exact shift on the instant axis.
    int128 time_ns = temporal::duration_time_part_ns(dp);

    int128 result = base + (int128)sign * time_ns;
    if (!temporal::instant_in_range(result)) return false;
    *out = result;
    return true;
}

fn void zdt_add_sub(BuiltinContext* ctx, bool subtract) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_ZONEDDATETIME, "this is not a Temporal.ZonedDateTime")) return;
    temporal::DurationParts dp;
    temporal::OverflowKind overflow;
    if (!duration_from_arg(ctx, arg_at(ctx, 0), &dp) || !read_overflow(ctx, arg_at(ctx, 1), &overflow)) return;
    HObject* self = (HObject*)ctx.this_val.get_heapptr();
    int128 ns;
    if (!add_zoned_datetime(self, dp, subtract ? -1 : 1, overflow, &ns)) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "duration produces an out-of-range date or instant"); return;
    }
    zdt_result(ctx, ns, self.extra.temporal.timezone, self.extra.temporal.calendar);
}

// this.until(other) / this.since(other) — the difference as a Duration, in the
// units named by the options bag. Defaults to hours.
fn void builtin_temporal_zoneddatetime_proto_until(BuiltinContext* ctx) {
    zdt_until_since(ctx, true);
}

fn void builtin_temporal_zoneddatetime_proto_since(BuiltinContext* ctx) {
    zdt_until_since(ctx, false);
}

fn void zdt_until_since(BuiltinContext* ctx, bool until) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_ZONEDDATETIME, "this is not a Temporal.ZonedDateTime")) return;
    HObject* self = (HObject*)ctx.this_val.get_heapptr();
    int128 ns;
    HObject* tz;
    temporal::CalendarId cal;
    if (!to_temporal_zoned_datetime(ctx, arg_at(ctx, 0), &ns, &tz, &cal)) return;
    if (cal != self.extra.temporal.calendar) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "calendars must match"); return;
    }
    DiffSettings ds;
    if (!read_diff_settings(ctx, 1, temporal::TemporalUnit.YEAR, temporal::TemporalUnit.NANOSECOND,
                            temporal::TemporalUnit.HOUR, temporal::TemporalUnit.NANOSECOND, !until, &ds)) return;
    ds.is_zoned = true;
    ds.calendar = cal;
    if (temporal::is_date_unit(ds.largest)) {
        String za = timezone_name(self.extra.temporal.timezone);
        String zb = timezone_name(tz);
        bool same = za == zb;
        $if $feat(INTL) && !$feat(NO_INTL_DATE):
            if (!same) {
                char[128] canonical_a, canonical_b;
                usz na = intl_zone_canonical((char[])za, canonical_a[..]);
                usz nb = intl_zone_canonical((char[])zb, canonical_b[..]);
                same = na > 0 && na == nb && canonical_a[:na] == canonical_b[:nb];
            }
        $endif
        if (!same) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "cannot compute calendar units across different time zones");
            return;
        }
    }
    if (ns == self.extra.temporal.big_ns.to_int128()) {
        temporal::DurationParts zero;
        @temporal_result(ctx, alloc_duration(ctx.heap, zero), ctx.heap.temporal_duration_proto);
        return;
    }
    temporal::DurationParts elapsed;
    temporal::decompose_ns_128(ns - self.extra.temporal.big_ns.to_int128(), temporal::TemporalUnit.HOUR, &elapsed);
    temporal::DurationParts result;
    if (!duration_zoned_round(ctx, self, elapsed, ds, &result)) return;
    if (!until) result = result.negate();
    @temporal_result(ctx, alloc_duration(ctx.heap, result), ctx.heap.temporal_duration_proto);
}


// =====================================================================
// ZonedDateTime wall-clock fields
// =====================================================================

fn temporal::CivilDateTime zdt_wall_datetime(HObject* zdt) {
    long wy, wm, wd; int wh, wmi, ws, wms, wus, wns, off;
    zdt_wall_fields(zdt, &wy, &wm, &wd, &wh, &wmi, &ws, &wms, &wus, &wns, &off);
    return { .date = { wy, wm, wd }, .time = { wh, wmi, ws, wms, wus, wns } };
}

fn temporal::CivilDate zdt_wall_date(HObject* zdt) => zdt_wall_datetime(zdt).date;

// Helper: resolve wall-time fields from epoch-ns + timezone.
//
// ZonedDateTime construction rejects epochNanoseconds outside +-10^8 days
// (see builtin_temporal_instant_ctor), so big_ns always fits int128 here.
fn void zdt_wall_fields(HObject* zdt, long* wy, long* wm, long* wd,
                         int* wh, int* wmi, int* ws, int* wms, int* wus, int* wns, int* off_sec) {
    hbigint::HBigInt* b = zdt.extra.temporal.big_ns;
    HObject* tz = zdt.extra.temporal.timezone;
    assert(b.fits_int128(), "ZonedDateTime epochNanoseconds out of int128 range");
    int128 total = b.to_int128();
    long epoch_secs = (long)(total / 1000000000);
    long ns_rem = (long)(total - (int128)epoch_secs * 1000000000);
    // Floor toward -inf so a negative epoch carries its sub-second part as
    // a positive remainder on the previous civil second (per
    // GetISOPartsFromEpoch).
    if (ns_rem < 0) {
        epoch_secs -= 1;
        ns_rem += 1000000000;
    }
    String zone = (tz != null) ? timezone_name(tz) : (String)"";
    int off = 0;
    if (zone.len > 0 && zone.ptr != null) off = temporal::tzdb_offset_for_zone_at(zone, epoch_secs);
    long local_secs = epoch_secs + off;
    temporal::BrokenDownTime bd = temporal::civil_from_seconds(local_secs);
    *wy = bd.y;
    *wm = bd.m + 1;
    *wd = bd.d;
    *wh = bd.h;
    *wmi = bd.mi;
    *ws = bd.s;
    *wms = (int)(ns_rem / 1000000);
    *wus = (int)((ns_rem % 1000000) / 1000);
    *wns = (int)(ns_rem % 1000);
    *off_sec = off;
}

fn void builtin_temporal_zoneddatetime_proto_hour(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_ZONEDDATETIME, "this is not a Temporal.ZonedDateTime")) return;
    HObject* obj = (HObject*)ctx.this_val.get_heapptr();
    long wy, wm, wd; int wh, wmi, ws, wms, wus, wns, off;
    zdt_wall_fields(obj, &wy, &wm, &wd, &wh, &wmi, &ws, &wms, &wus, &wns, &off);
    ctx.result_fastint(wh);
}

fn void builtin_temporal_zoneddatetime_proto_minute(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_ZONEDDATETIME, "this is not a Temporal.ZonedDateTime")) return;
    HObject* obj = (HObject*)ctx.this_val.get_heapptr();
    long wy, wm, wd; int wh, wmi, ws, wms, wus, wns, off;
    zdt_wall_fields(obj, &wy, &wm, &wd, &wh, &wmi, &ws, &wms, &wus, &wns, &off);
    ctx.result_fastint(wmi);
}

fn void builtin_temporal_zoneddatetime_proto_second(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_ZONEDDATETIME, "this is not a Temporal.ZonedDateTime")) return;
    HObject* obj = (HObject*)ctx.this_val.get_heapptr();
    long wy, wm, wd; int wh, wmi, ws, wms, wus, wns, off;
    zdt_wall_fields(obj, &wy, &wm, &wd, &wh, &wmi, &ws, &wms, &wus, &wns, &off);
    ctx.result_fastint(ws);
}

fn void builtin_temporal_zoneddatetime_proto_millisecond(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_ZONEDDATETIME, "this is not a Temporal.ZonedDateTime")) return;
    HObject* obj = (HObject*)ctx.this_val.get_heapptr();
    long wy, wm, wd; int wh, wmi, ws, wms, wus, wns, off;
    zdt_wall_fields(obj, &wy, &wm, &wd, &wh, &wmi, &ws, &wms, &wus, &wns, &off);
    ctx.result_fastint(wms);
}

fn void builtin_temporal_zoneddatetime_proto_microsecond(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_ZONEDDATETIME, "this is not a Temporal.ZonedDateTime")) return;
    HObject* obj = (HObject*)ctx.this_val.get_heapptr();
    long wy, wm, wd; int wh, wmi, ws, wms, wus, wns, off;
    zdt_wall_fields(obj, &wy, &wm, &wd, &wh, &wmi, &ws, &wms, &wus, &wns, &off);
    ctx.result_fastint(wus);
}

fn void builtin_temporal_zoneddatetime_proto_nanosecond(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_ZONEDDATETIME, "this is not a Temporal.ZonedDateTime")) return;
    HObject* obj = (HObject*)ctx.this_val.get_heapptr();
    long wy, wm, wd; int wh, wmi, ws, wms, wus, wns, off;
    zdt_wall_fields(obj, &wy, &wm, &wd, &wh, &wmi, &ws, &wms, &wus, &wns, &off);
    ctx.result_fastint(wns);
}

fn void builtin_temporal_zoneddatetime_proto_offset(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_ZONEDDATETIME, "this is not a Temporal.ZonedDateTime")) return;
    HObject* obj = (HObject*)ctx.this_val.get_heapptr();
    long wy, wm, wd; int wh, wmi, ws, wms, wus, wns, off;
    zdt_wall_fields(obj, &wy, &wm, &wd, &wh, &wmi, &ws, &wms, &wus, &wns, &off);
    char[10] buf;
    temporal::format_offset_seconds(&buf[0], off);
    ctx.result_string(builtin_intern_string(ctx.heap, buf[:off % 60 == 0 ? 6 : 9]));
}

fn void builtin_temporal_zoneddatetime_proto_offsetNanoseconds(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_ZONEDDATETIME, "this is not a Temporal.ZonedDateTime")) return;
    HObject* obj = (HObject*)ctx.this_val.get_heapptr();
    long wy, wm, wd; int wh, wmi, ws, wms, wus, wns, off;
    zdt_wall_fields(obj, &wy, &wm, &wd, &wh, &wmi, &ws, &wms, &wus, &wns, &off);
    ctx.result_number((double)off * 1e9);
}

fn void builtin_temporal_zoneddatetime_proto_hoursInDay(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_ZONEDDATETIME, "this is not a Temporal.ZonedDateTime")) return;
    HObject* obj = (HObject*)ctx.this_val.get_heapptr();
    long wy, wm, wd; int wh, wmi, ws, wms, wus, wns, off;
    zdt_wall_fields(obj, &wy, &wm, &wd, &wh, &wmi, &ws, &wms, &wus, &wns, &off);
    String zone = obj.extra.temporal.timezone == null ? "" : timezone_name(obj.extra.temporal.timezone);
    // Per spec: compute GetStartOfDay for today and tomorrow. Either
    // endpoint outside the Instant range throws (test262 hoursInDay/
    // next-day-out-of-range and hoursInDay/get-start-of-day-throws).
    temporal::CivilDate today = { .y = wy, .m = wm, .d = wd };
    temporal::CivilDate tomorrow = temporal::add_days(today, 1);
    long today_secs = temporal::epoch_days_from_civil(today.y, (int)today.m, (int)today.d) * 86400;
    long tomorrow_secs = temporal::epoch_days_from_civil(tomorrow.y, (int)tomorrow.m, (int)tomorrow.d) * 86400;
    int128 today_ns = temporal::zdt_start_of_day_ns(zone, today_secs);
    int128 tomorrow_ns = temporal::zdt_start_of_day_ns(zone, tomorrow_secs);
    if (!temporal::instant_in_range(today_ns) || !temporal::instant_in_range(tomorrow_ns)) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "hoursInDay boundary is outside the valid time range");
        return;
    }
    int128 diff_ns = tomorrow_ns - today_ns;
    double hours = (double)diff_ns / 3_600_000_000_000.0;
    ctx.result_number(hours);
}

fn void builtin_temporal_zoneddatetime_proto_toInstant(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_ZONEDDATETIME, "this is not a Temporal.ZonedDateTime")) return;
    HObject* obj = (HObject*)ctx.this_val.get_heapptr();
    hbigint::HBigInt* b = obj.extra.temporal.big_ns;
    ((types::HeapHeader*)b).incref();
    HObject*? inst_o = alloc_instant(ctx.heap, b);
    ctx.heap.decref((types::HeapHeader*)b);
    if (catch err = inst_o) { builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return; }
    HObject* inst = inst_o;
    ctx.heap.set_prototype(inst, ctx.heap.temporal_instant_proto);
    ctx.result_object(inst);
}

fn void builtin_temporal_zoneddatetime_proto_toPlainDateTime(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_ZONEDDATETIME, "this is not a Temporal.ZonedDateTime")) return;
    HObject* obj = (HObject*)ctx.this_val.get_heapptr();
    long wy, wm, wd; int wh, wmi, ws, wms, wus, wns, off;
    zdt_wall_fields(obj, &wy, &wm, &wd, &wh, &wmi, &ws, &wms, &wus, &wns, &off);
    temporal::CivilDateTime wall_dt;
    wall_dt.date = { .y = wy, .m = wm, .d = wd };
    wall_dt.time = { .h = wh, .mi = wmi, .s = ws, .ms = wms, .us = wus, .ns = wns };
    HObject*? pdt_o = alloc_plain_datetime(ctx.heap, wall_dt, obj.extra.temporal.calendar);
    if (catch err = pdt_o) { builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return; }
    HObject* pdt = pdt_o;
    ctx.heap.set_prototype(pdt, ctx.heap.temporal_plain_datetime_proto);
    ctx.result_object(pdt);
}

fn void builtin_temporal_zoneddatetime_proto_toPlainTime(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_ZONEDDATETIME, "this is not a Temporal.ZonedDateTime")) return;
    HObject* obj = (HObject*)ctx.this_val.get_heapptr();
    long wy, wm, wd; int wh, wmi, ws, wms, wus, wns, off;
    zdt_wall_fields(obj, &wy, &wm, &wd, &wh, &wmi, &ws, &wms, &wus, &wns, &off);
    temporal::CivilTime t;
    t.h = wh; t.mi = wmi; t.s = ws; t.ms = wms; t.us = wus; t.ns = wns;
    HObject*? pt_o = alloc_plain_time(ctx.heap, t);
    if (catch err = pt_o) { builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return; }
    HObject* pt = pt_o;
    ctx.heap.set_prototype(pt, ctx.heap.temporal_plain_time_proto);
    ctx.result_object(pt);
}

fn void builtin_temporal_zoneddatetime_proto_toPlainDate(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_ZONEDDATETIME, "this is not a Temporal.ZonedDateTime")) return;
    HObject* obj = (HObject*)ctx.this_val.get_heapptr();
    long wy, wm, wd; int wh, wmi, ws, wms, wus, wns, off;
    zdt_wall_fields(obj, &wy, &wm, &wd, &wh, &wmi, &ws, &wms, &wus, &wns, &off);
    temporal::CivilDate d;
    d.y = wy; d.m = wm; d.d = wd;
    HObject*? pd_o = alloc_plain_date(ctx.heap, d, obj.extra.temporal.calendar);
    if (catch err = pd_o) { builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return; }
    HObject* pd = pd_o;
    ctx.heap.set_prototype(pd, ctx.heap.temporal_plain_date_proto);
    ctx.result_object(pd);
}

fn void builtin_temporal_zoneddatetime_proto_startOfDay(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_ZONEDDATETIME, "this is not a Temporal.ZonedDateTime")) return;
    HObject* obj = (HObject*)ctx.this_val.get_heapptr();
    long wy, wm, wd; int wh, wmi, ws, wms, wus, wns, off;
    zdt_wall_fields(obj, &wy, &wm, &wd, &wh, &wmi, &ws, &wms, &wus, &wns, &off);
    long day_secs = temporal::epoch_days_from_civil(wy, (int)wm, (int)wd) * 86400;
    int128 epoch_ns_128 = temporal::zdt_start_of_day_ns(timezone_name(obj.extra.temporal.timezone), day_secs);
    // The Instant range is symmetric at the boundaries (-1e8 days). For wall
    // dates whose midnight lands outside, the spec's GetStartOfDay throws
    // (test262 startOfDay/throws-if-epoch-nanoseconds-outside-valid-limits).
    if (!temporal::instant_in_range(epoch_ns_128)) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "start of day is outside the valid time range");
        return;
    }
    hbigint::HBigInt*? big_o = hbigint::hbigint_alloc(ctx.heap, epoch_ns_128);
    if (catch err = big_o) { builtin_throw(ctx, ctx.heap.range_err_proto, "out of range"); return; }
    ((types::HeapHeader*)obj.extra.temporal.timezone).incref();
    zdt_from_parts(ctx, big_o, obj.extra.temporal.timezone, obj.extra.temporal.calendar);
}

fn void builtin_temporal_zoneddatetime_proto_getTimeZoneTransition(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_ZONEDDATETIME, "this is not a Temporal.ZonedDateTime")) return;
    if (ctx.argc < 1) { builtin_throw(ctx, ctx.heap.type_err_proto, "getTimeZoneTransition requires a direction argument"); return; }
    HObject* obj = (HObject*)ctx.this_val.get_heapptr();
    HObject* tz = obj.extra.temporal.timezone;
    if (tz == null) { ctx.result_undefined(); return; }
    // Read direction: a plain string, or a `direction` property on an
    // options bag (GetDirectionOption — Proxy-aware so observers see
    // `get ...direction` / toString). Only this property is read; the
    // other bag fields (year/month/day/...) are ignored per spec.
    TVal* dir_arg = arg_at(ctx, 0);
    String dir = "next";
    TVal dir_tv;
    dir_tv.set_undefined();
    if (dir_arg.is_string()) {
        HString* ds = (HString*)dir_arg.get_heapptr();
        // ToString(Symbol) throws TypeError; a Symbol-typed argument must not
        // be treated as a direction name.
        if (ds != null && ds.is_symbol()) {
            builtin_throw(ctx, ctx.heap.type_err_proto, "Cannot convert a Symbol value to a string");
            return;
        }
        if (ds != null) dir = (String)ds.token_text();
    } else if (dir_arg.is_object() && dir_arg.get_heapptr() != null) {
        HObject* dbag = (HObject*)dir_arg.get_heapptr();
        dir_tv = prop_or_undefined_pa(ctx, dbag, "direction");
        if (ctx.should_throw) return;
        if (dir_tv.is_undefined()) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "direction property is required");
            return;
        }
        HString* ds = builtin_to_string_vm(ctx, &dir_tv);
        if (ctx.should_throw) return;
        if (ds == null) {
            builtin_throw(ctx, ctx.heap.type_err_proto, "direction must be a string");
            return;
        }
        dir = (String)ds.token_text();
    } else {
        builtin_throw(ctx, ctx.heap.type_err_proto, "direction must be a string or object");
        return;
    }
    if (dir != "next" && dir != "previous") {
        builtin_throw(ctx, ctx.heap.range_err_proto, "invalid direction");
        return;
    }
    // Search the zone's transition table directly. The epoch second of this
    // ZonedDateTime is the start; a non-zero sub-second part places a
    // transition landing exactly on that second behind the start.
    int128 total = obj.extra.temporal.big_ns.to_int128();
    long start_sec = (long)(total / temporal::NS_PER_SEC);
    long remainder = (long)(total % temporal::NS_PER_SEC);
    if (remainder < 0) { start_sec--; remainder += temporal::NS_PER_SEC; }
    bool sub_second = remainder != 0;

    long at_sec;
    if (!tz_find_transition(timezone_name(tz), start_sec, sub_second, dir == "next", &at_sec)) {
        ctx.result_null();
        return;
    }

    if (!temporal::instant_in_range((int128)at_sec * temporal::NS_PER_SEC)) { ctx.result_null(); return; }
    // The result is a ZonedDateTime at the transition, in the same zone and
    // calendar as the receiver.
    hbigint::HBigInt*? trans_ns = hbigint::hbigint_alloc(ctx.heap, (int128)at_sec * temporal::NS_PER_SEC);
    if (catch err = trans_ns) { builtin_throw(ctx, ctx.heap.range_err_proto, "alloc failed"); return; }
    ((types::HeapHeader*)tz).incref();
    zdt_from_parts(ctx, trans_ns, tz, obj.extra.temporal.calendar);
}

fn void builtin_temporal_zoneddatetime_proto_valueOf(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_ZONEDDATETIME, "this is not a Temporal.ZonedDateTime")) return;
    builtin_throw(ctx, ctx.heap.type_err_proto, "Temporal.ZonedDateTime cannot be converted to a primitive value");
}

fn void builtin_temporal_zoneddatetime_proto_withPlainTime(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_ZONEDDATETIME, "this is not a Temporal.ZonedDateTime")) return;
    HObject* self = (HObject*)ctx.this_val.get_heapptr();
    temporal::CivilDate date = zdt_wall_date(self);
    long wall = temporal::epoch_days_from_civil(date.y, (int)date.m, (int)date.d) * 86400;
    String zone = timezone_name(self.extra.temporal.timezone);
    int128 ns;
    if (arg_at(ctx, 0).is_undefined()) { ns = temporal::zdt_start_of_day_ns(zone, wall); }
    else {
        HObject*? time_o = plain_time_from_arg(ctx, arg_at(ctx, 0));
        if (ctx.should_throw) return;
        temporal::CivilTime time = plain_time_value(time_o!!);
        wall += time.h * 3600 + time.mi * 60 + time.s;
        ns = temporal::zdt_local_to_epoch_ns(zone, wall, time.ms * 1000000L + time.us * 1000L + time.ns);
    }
    if (!temporal::instant_in_range(ns)) { builtin_throw(ctx, ctx.heap.range_err_proto, "instant is out of range"); return; }
    zdt_result(ctx, ns, self.extra.temporal.timezone, self.extra.temporal.calendar);
}

fn void builtin_temporal_zoneddatetime_proto_round(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_ZONEDDATETIME, "this is not a Temporal.ZonedDateTime")) return;
    if (ctx.argc < 1) { builtin_throw(ctx, ctx.heap.type_err_proto, "round requires an options argument"); return; }
    TVal* arg = arg_at(ctx, 0);
    HObject* obj = (HObject*)ctx.this_val.get_heapptr();

    temporal::TemporalUnit smallest_unit;
    double rounding_increment = 1;
    temporal::TemporalRoundMode rounding_mode = temporal::TemporalRoundMode.HALF_EXPAND;

    if (arg.is_string()) {
        HString* s = builtin_to_string_vm(ctx, arg);
        if (ctx.should_throw) return;
        if (!temporal::parse_unit_str(s.token_text(), &smallest_unit) || smallest_unit < temporal::TemporalUnit.DAY) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "invalid smallestUnit for round");
            return;
        }
    } else if (arg.is_object() && arg.get_heapptr() != null) {
        HObject* opts = (HObject*)arg.get_heapptr();
        TVal ri_v = prop_or_undefined_pa(ctx, opts, "roundingIncrement");
        if (ctx.should_throw) return;
        if (!ri_v.is_undefined()) {
            Vm* v = (Vm*)ctx.vm;
            double ri_val = vm::vm_to_number(v, &ri_v);
            if (v.throw_pending) { ctx.should_throw = true; ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value); v.throw_pending = false; return; }
            if (math::is_nan(ri_val) || math::is_inf(ri_val)) {
                builtin_throw(ctx, ctx.heap.range_err_proto, "roundingIncrement must be a positive integer");
                return;
            }
            rounding_increment = math::floor(ri_val);
            if (rounding_increment < 1) {
                builtin_throw(ctx, ctx.heap.range_err_proto, "roundingIncrement must be a positive integer");
                return;
            }
        }

        TVal rm_v = prop_or_undefined_pa(ctx, opts, "roundingMode");
        if (ctx.should_throw) return;
        if (!rm_v.is_undefined()) {
            HString* rm_str = builtin_to_string_vm(ctx, &rm_v);
            if (ctx.should_throw) return;
            if (!temporal::parse_rm_str(rm_str.token_text(), &rounding_mode)) {
                builtin_throw(ctx, ctx.heap.range_err_proto, "invalid roundingMode");
                return;
            }
        }

        TVal su_v = prop_or_undefined_pa(ctx, opts, "smallestUnit");
        if (ctx.should_throw) return;
        if (su_v.is_undefined()) { builtin_throw(ctx, ctx.heap.range_err_proto, "round requires a smallestUnit option"); return; }
        HString* su_str = builtin_to_string_vm(ctx, &su_v);
        if (ctx.should_throw) return;
        if (!temporal::parse_unit_str(su_str.token_text(), &smallest_unit) || smallest_unit < temporal::TemporalUnit.DAY) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "invalid smallestUnit for round");
            return;
        }
    } else {
        builtin_throw(ctx, ctx.heap.type_err_proto, "round options must be an object");
        return;
    }

    if (smallest_unit == temporal::TemporalUnit.DAY && rounding_increment != 1) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "roundingIncrement is out of range");
        return;
    }
    if (!validate_rounding_increment(ctx, smallest_unit, rounding_increment)) return;

    long wy, wm, wd; int wh, wmi, ws, wms, wus, wns, woff;
    zdt_wall_fields(obj, &wy, &wm, &wd, &wh, &wmi, &ws, &wms, &wus, &wns, &woff);

    String zone = timezone_name(obj.extra.temporal.timezone);
    int128 current = obj.extra.temporal.big_ns.to_int128();
    long day = temporal::epoch_days_from_civil(wy, (int)wm, (int)wd) * 86400;
    int128 rounded;
    if (smallest_unit == temporal::TemporalUnit.DAY) {
        int128 start = temporal::zdt_start_of_day_ns(zone, day);
        int128 end = temporal::zdt_start_of_day_ns(zone, day + 86400);
        if (!temporal::instant_in_range(start) || !temporal::instant_in_range(end) || end <= start) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "day boundary is out of range"); return;
        }
        // A backwards transition can put this date after the next date's first midnight.
        int128 elapsed = current - start;
        if (elapsed >= end - start) elapsed = end - start - 1;
        rounded = start + temporal::round_long_ns_128(elapsed, end - start, rounding_mode);
    } else {
        temporal::CivilDateTime wall = zdt_wall_datetime(obj);
        long time = wall.time.h * 3600000000000L + wall.time.mi * 60000000000L + wall.time.s * 1000000000L
            + wall.time.ms * 1000000L + wall.time.us * 1000L + wall.time.ns;
        int128 increment = (int128)temporal::unit_ns_divisor(smallest_unit) * (int128)rounding_increment;
        int128 naive = (int128)day * temporal::NS_PER_SEC + temporal::round_long_ns_128((int128)time, increment, rounding_mode);
        if (!zdt_check_offset_agreement(ctx, zone, naive, (long)woff * 1000000000L, 3, &rounded)) return;
    }
    if (!temporal::instant_in_range(rounded)) { builtin_throw(ctx, ctx.heap.range_err_proto, "instant is out of range"); return; }
    zdt_result(ctx, rounded, obj.extra.temporal.timezone, obj.extra.temporal.calendar);
}

fn bool setUpTemporalZonedDateTime(Heap* heap) {
    return @constructor_pair(heap, "Temporal.ZonedDateTime", TemporalBuiltin.ZONEDDATETIME_CTOR,
                             2, "ZonedDateTime", &heap.temporal_zoneddatetime_proto;
                             HObject* proto, HObject* ctor) {
        if (!register_proto_getter_accessor(proto, heap, "epochMilliseconds", temporal_index(TemporalBuiltin.ZONEDDATETIME_PROTO_EPOCHMILLISECONDS))) return false;
        if (!register_proto_getter_accessor(proto, heap, "epochNanoseconds", temporal_index(TemporalBuiltin.ZONEDDATETIME_PROTO_EPOCHNANOSECONDS))) return false;
        if (!register_proto_getter_accessor(proto, heap, "timeZoneId", temporal_index(TemporalBuiltin.ZONEDDATETIME_PROTO_TIMEZONEID))) return false;
        if (!register_proto_getter_accessor(proto, heap, "calendarId", temporal_index(TemporalBuiltin.ZONEDDATETIME_PROTO_CALENDARID))) return false;
        if (!register_proto_method(proto, heap, "with", temporal_index(TemporalBuiltin.ZONEDDATETIME_PROTO_WITH))) return false;
        if (!register_proto_method(proto, heap, "toString", temporal_index(TemporalBuiltin.ZONEDDATETIME_PROTO_TOSTRING))) return false;
        if (!register_proto_method(proto, heap, "toJSON", temporal_index(TemporalBuiltin.ZONEDDATETIME_PROTO_TOJSON))) return false;
        if (!register_proto_method(proto, heap, "toLocaleString", temporal_index(TemporalBuiltin.ZONEDDATETIME_PROTO_TOLOCALESTRING))) return false;
        if (!register_proto_method(proto, heap, "equals", temporal_index(TemporalBuiltin.ZONEDDATETIME_PROTO_EQUALS))) return false;
        if (!register_proto_method(proto, heap, "withTimeZone", temporal_index(TemporalBuiltin.ZONEDDATETIME_PROTO_WITHTIMEZONE))) return false;
        if (!register_proto_method(proto, heap, "withCalendar", temporal_index(TemporalBuiltin.ZONEDDATETIME_PROTO_WITHCALENDAR))) return false;
        if (!register_proto_method(proto, heap, "add", temporal_index(TemporalBuiltin.ZONEDDATETIME_PROTO_ADD))) return false;
        if (!register_proto_method(proto, heap, "subtract", temporal_index(TemporalBuiltin.ZONEDDATETIME_PROTO_SUBTRACT))) return false;
        if (!register_proto_method(proto, heap, "until", temporal_index(TemporalBuiltin.ZONEDDATETIME_PROTO_UNTIL))) return false;
        if (!register_proto_method(proto, heap, "since", temporal_index(TemporalBuiltin.ZONEDDATETIME_PROTO_SINCE))) return false;
        if (!register_proto_method(ctor, heap, "from", temporal_index(TemporalBuiltin.ZONEDDATETIME_FROM))) return false;
        if (!register_proto_method(ctor, heap, "compare", temporal_index(TemporalBuiltin.ZONEDDATETIME_COMPARE))) return false;
        // New getters.
        if (!register_proto_getter_accessor(proto, heap, "year", temporal_index(TemporalBuiltin.ZONEDDATETIME_PROTO_YEAR))) return false;
        if (!register_proto_getter_accessor(proto, heap, "month", temporal_index(TemporalBuiltin.ZONEDDATETIME_PROTO_MONTH))) return false;
        if (!register_proto_getter_accessor(proto, heap, "monthCode", temporal_index(TemporalBuiltin.ZONEDDATETIME_PROTO_MONTHCODE))) return false;
        if (!register_proto_getter_accessor(proto, heap, "day", temporal_index(TemporalBuiltin.ZONEDDATETIME_PROTO_DAY))) return false;
        if (!register_proto_getter_accessor(proto, heap, "hour", temporal_index(TemporalBuiltin.ZONEDDATETIME_PROTO_HOUR))) return false;
        if (!register_proto_getter_accessor(proto, heap, "minute", temporal_index(TemporalBuiltin.ZONEDDATETIME_PROTO_MINUTE))) return false;
        if (!register_proto_getter_accessor(proto, heap, "second", temporal_index(TemporalBuiltin.ZONEDDATETIME_PROTO_SECOND))) return false;
        if (!register_proto_getter_accessor(proto, heap, "millisecond", temporal_index(TemporalBuiltin.ZONEDDATETIME_PROTO_MILLISECOND))) return false;
        if (!register_proto_getter_accessor(proto, heap, "microsecond", temporal_index(TemporalBuiltin.ZONEDDATETIME_PROTO_MICROSECOND))) return false;
        if (!register_proto_getter_accessor(proto, heap, "nanosecond", temporal_index(TemporalBuiltin.ZONEDDATETIME_PROTO_NANOSECOND))) return false;
        if (!register_proto_getter_accessor(proto, heap, "offset", temporal_index(TemporalBuiltin.ZONEDDATETIME_PROTO_OFFSET))) return false;
        if (!register_proto_getter_accessor(proto, heap, "offsetNanoseconds", temporal_index(TemporalBuiltin.ZONEDDATETIME_PROTO_OFFSETNANOSECONDS))) return false;
        if (!register_proto_getter_accessor(proto, heap, "dayOfWeek", temporal_index(TemporalBuiltin.ZONEDDATETIME_PROTO_DAYOFWEEK))) return false;
        if (!register_proto_getter_accessor(proto, heap, "dayOfYear", temporal_index(TemporalBuiltin.ZONEDDATETIME_PROTO_DAYOFYEAR))) return false;
        if (!register_proto_getter_accessor(proto, heap, "weekOfYear", temporal_index(TemporalBuiltin.ZONEDDATETIME_PROTO_WEEKOFYEAR))) return false;
        if (!register_proto_getter_accessor(proto, heap, "yearOfWeek", temporal_index(TemporalBuiltin.ZONEDDATETIME_PROTO_YEAROFWEEK))) return false;
        if (!register_proto_getter_accessor(proto, heap, "daysInWeek", temporal_index(TemporalBuiltin.ZONEDDATETIME_PROTO_DAYSINWEEK))) return false;
        if (!register_proto_getter_accessor(proto, heap, "daysInMonth", temporal_index(TemporalBuiltin.ZONEDDATETIME_PROTO_DAYSINMONTH))) return false;
        if (!register_proto_getter_accessor(proto, heap, "daysInYear", temporal_index(TemporalBuiltin.ZONEDDATETIME_PROTO_DAYSINYEAR))) return false;
        if (!register_proto_getter_accessor(proto, heap, "monthsInYear", temporal_index(TemporalBuiltin.ZONEDDATETIME_PROTO_MONTHSINYEAR))) return false;
        if (!register_proto_getter_accessor(proto, heap, "inLeapYear", temporal_index(TemporalBuiltin.ZONEDDATETIME_PROTO_INLEAPYEAR))) return false;
        if (!register_proto_getter_accessor(proto, heap, "hoursInDay", temporal_index(TemporalBuiltin.ZONEDDATETIME_PROTO_HOURSINDAY))) return false;
        if (!register_proto_getter_accessor(proto, heap, "era", temporal_index(TemporalBuiltin.ZONEDDATETIME_PROTO_ERA))) return false;
        if (!register_proto_getter_accessor(proto, heap, "eraYear", temporal_index(TemporalBuiltin.ZONEDDATETIME_PROTO_ERAYEAR))) return false;
        // New methods.
        if (!register_proto_method(proto, heap, "round", temporal_index(TemporalBuiltin.ZONEDDATETIME_PROTO_ROUND))) return false;
        if (!register_proto_method(proto, heap, "withPlainTime", temporal_index(TemporalBuiltin.ZONEDDATETIME_PROTO_WITHPLAIN_TIME))) return false;
        if (!register_proto_method(proto, heap, "toInstant", temporal_index(TemporalBuiltin.ZONEDDATETIME_PROTO_TOINSTANT))) return false;
        if (!register_proto_method(proto, heap, "toPlainDateTime", temporal_index(TemporalBuiltin.ZONEDDATETIME_PROTO_TOPLAINDATETIME))) return false;
        if (!register_proto_method(proto, heap, "toPlainTime", temporal_index(TemporalBuiltin.ZONEDDATETIME_PROTO_TOPLAINTIME))) return false;
        if (!register_proto_method(proto, heap, "toPlainDate", temporal_index(TemporalBuiltin.ZONEDDATETIME_PROTO_TOPLAINDATE))) return false;
        if (!register_proto_method(proto, heap, "startOfDay", temporal_index(TemporalBuiltin.ZONEDDATETIME_PROTO_STARTOFDAY))) return false;
        if (!register_proto_method(proto, heap, "getTimeZoneTransition", temporal_index(TemporalBuiltin.ZONEDDATETIME_PROTO_GETTIMEZONETRANSITION))) return false;
        if (!register_proto_method(proto, heap, "valueOf", temporal_index(TemporalBuiltin.ZONEDDATETIME_PROTO_VALUEOF))) return false;
    };
}
