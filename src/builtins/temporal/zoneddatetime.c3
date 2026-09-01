// Temporal.ZonedDateTime bindings: constructor, statics, getters, and
// prototype methods.
//
// This is where the instant axis and the local wall-clock axis meet, so it
// owns add_zoned_datetime (the spec's AddZonedDateTime) that Duration.total,
// Duration.compare and round() all share.
module boomkat::builtins @feat(!NO_TEMPORAL);

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
// Phase 2 — Temporal.ZonedDateTime
//
// A ZonedDateTime is an Instant plus a TimeZone plus a calendar. The heap
// slots hold the TimeZone object (in `timezone`) and the iso8601 calendar
// string (in `calendar`); `big_ns` is the epoch-nanosecond BigInt.
// ============================================================================

fn HObject*? alloc_zoneddatetime(Heap* hp, hbigint::HBigInt* ns, HObject* tz, HString* calendar) {
    if (ns == null) return null;
    HObject*? raw = hp.alloc_object(hobject::ObjClass.TEMPORAL_ZONEDDATETIME);
    if (catch err = raw) return err~;
    HObject* obj = raw;

    ((types::HeapHeader*)ns).incref();
    ((types::HeapHeader*)tz).incref();
    if (calendar != null) { ((types::HeapHeader*)calendar).incref(); }
    obj.extra.temporal.big_ns = ns;
    obj.extra.temporal.timezone = tz;
    obj.extra.temporal.calendar = (HObject*)calendar;
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
        String s = tzs_str != null ? (String)tzs_str.get_cstr()[:tzs_str.blen] : (String)"";
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

    // calendar: defaults to iso8601; a supplied calendar must be a string
    // matching "iso8601"/"gregory"/"gregorian" (case-insensitive) or a
    // Temporal.Calendar object. Anything else throws TypeError; unknown
    // identifiers throw RangeError.
    HObject* calendar_obj = ctx.heap.temporal_iso_calendar;
    if (ctx.argc >= 3) {
        TVal* cal_arg = arg_at(ctx, 2);
        if (!cal_arg.is_undefined()) {
            if (!to_temporal_calendar_identifier(ctx, cal_arg, &calendar_obj)) return;
        }
    }
    // The slot stores the calendar id string; use a small HString per call so
    // we don't share the "iso8601" literal across distinct calendar objects.
    String cal_id = "iso8601";
    if (calendar_obj != ctx.heap.temporal_iso_calendar) {
        // Only "iso8601" exists right now; reaching here means an unrecognized
        // Calendar object was passed and slipped past calendar_from_arg.
        builtin_throw(ctx, ctx.heap.range_err_proto, "unknown calendar");
        return;
    }
    HString* calendar = builtin_intern_string(ctx.heap, cal_id);
    HObject*? obj_o = alloc_zoneddatetime(ctx.heap, b, tz, calendar);
    if (catch err = obj_o) { builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return; }
    HObject* obj = obj_o;
    if (ctx.is_constructor) {
        obj.prototype = builtin_proto_from_new_target(ctx, ctx.heap.temporal_zoneddatetime_proto);
    } else {
        obj.prototype = ctx.heap.temporal_zoneddatetime_proto;
    }
    ctx.result.set_object(obj);
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
    // Zone name path: must be a known IANA name (case-insensitive). An
    // unknown identifier is a RangeError per spec.
    if (off_known) {
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
        String s = s_str != null ? (String)s_str.get_cstr()[:s_str.blen] : (String)"";
        HObject* tz = resolve_tz_from_string(ctx, s);
        if (tz == null) return null;
        return tz;
    }
    builtin_throw(ctx, ctx.heap.type_err_proto, "time zone must be a string or Temporal.TimeZone object");
    return null;
}

// Validate the options bag for `Temporal.ZonedDateTime.from`. Reads three
// options:
//   * `disambiguation`: "compatible" | "earlier" | "later" | "reject"
//   * `offset`: "prefer" | "use" | "ignore" | "reject"
//   * `overflow`: "constrain" | "reject"
// Anything else throws RangeError; non-object primitives (null/true/number/
// Symbol/string/BigInt) throw TypeError. The spec calls GetOption on each
// key, which only succeeds when the option is a string member of the
// allowed set; reading happens before any algorithmic validation.
// Validate the `offset`, `disambiguation` and `overflow` options accepted by
// ZonedDateTime.from/with. Returns the resolved offset mode (-1 on error):
// 0 = default (prefer), 1 = use, 2 = ignore, 3 = prefer, 4 = reject.
// Reads must go through the Proxy-aware path so observers see the option
// gets in alphabetical order (disambiguation, offset, overflow).
fn int validate_zdt_from_options(BuiltinContext* ctx, temporal::OverflowKind* out_overflow) {
    *out_overflow = temporal::OverflowKind.CONSTRAIN;
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
        char[] dstr = ds.get_cstr()[:ds.blen];
        if (dstr != "compatible" && dstr != "earlier" && dstr != "later" && dstr != "reject") {
            builtin_throw(ctx, ctx.heap.range_err_proto, "invalid disambiguation");
            return -1;
        }
    }
    TVal offv = prop_or_undefined_pa(ctx, opts, "offset");
    if (ctx.should_throw) return -1;
    int offset_mode = 0;
    if (!offv.is_undefined()) {
        HString* os = builtin_to_string_vm(ctx, &offv);
        if (ctx.should_throw) return -1;
        char[] ostr = os.get_cstr()[:os.blen];
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
        char[] ostr2 = os2.get_cstr()[:os2.blen];
        if (ostr2 != "constrain" && ostr2 != "reject") {
            builtin_throw(ctx, ctx.heap.range_err_proto, "invalid overflow option");
            return -1;
        }
        *out_overflow = ostr2 == "reject" ? temporal::OverflowKind.REJECT : temporal::OverflowKind.CONSTRAIN;
    }
    return offset_mode;
}

// Validate that an explicit UTC offset agrees with the time zone's actual
// offset at the instant it produces, per GetEpochNanosecondsFor. `mode` is
// the offset option (0=default,1=use,2=ignore,3=prefer,4=reject). On
// disagreement, reject/default throw RangeError, prefer falls back to the
// zone's own offset, and use/ignore never throw (ignore ignores the provided
// offset entirely). Writes the chosen epoch back through `epoch_ns_128`.
fn bool zdt_check_offset_agreement(BuiltinContext* ctx, String zone_name, int128 wall_ns_128,
                                   long off_sec, int mode, int128* epoch_ns_128) {
    if (mode == 1 /* use */) return true;
    if (mode == 2 /* ignore */) {
        // Ignore the supplied offset: resolve the wall time by the zone.
        long wall_secs = (long)(wall_ns_128 / 1000000000);
        long zone_off = (long)temporal::tzdb_offset_for_zone_at(zone_name, wall_secs);
        *epoch_ns_128 = wall_ns_128 - (int128)zone_off * (int128)temporal::NS_PER_SEC;
        return true;
    }
    long epoch_secs = (long)(*epoch_ns_128 / 1000000000);
    long zone_off = (long)temporal::tzdb_offset_for_zone_at(zone_name, epoch_secs);
    if (zone_off == off_sec) return true;
    if (mode == 3 /* prefer */) {
        *epoch_ns_128 = wall_ns_128 - (int128)zone_off * (int128)temporal::NS_PER_SEC;
        return true;
    }
    builtin_throw(ctx, ctx.heap.range_err_proto, "invalid offset string");
    return false;
}

fn void builtin_temporal_zoneddatetime_from(BuiltinContext* ctx) {
    if (ctx.argc < 1) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "Temporal.ZonedDateTime.from requires an argument");
        return;
    }
    TVal* arg = arg_at(ctx, 0);

    // Per spec, a Symbol argument is a TypeError (not a RangeError from the
    // ISO parser). Other non-string non-object primitives also throw
    // TypeError. Empty string goes through the ISO parser as RangeError.
    if (arg.is_string()) {
        HString* argstr = (HString*)arg.get_heapptr();
        if (argstr != null && argstr.is_symbol()) {
            builtin_throw(ctx, ctx.heap.type_err_proto, "Temporal.ZonedDateTime.from: Symbol argument is not a valid string or property bag");
            return;
        }
    } else if (!arg.is_object() || arg.get_heapptr() == null) {
        // null, true, numbers, BigInts land here. Each throws TypeError.
        builtin_throw(ctx, ctx.heap.type_err_proto, "Temporal.ZonedDateTime.from: argument must be a string or object");
        return;
    }

    // String input: parse ISO ZonedDateTime string. Per spec, options are
    // validated AFTER string parsing succeeds (so a syntactically bad string
    // raises RangeError before any TypeError from the options check).
    if (arg.is_string()) {
        HString* s = (HString*)arg.get_heapptr();
        if (s == null) { builtin_throw(ctx, ctx.heap.range_err_proto, "invalid string"); return; }
        char[] text = s.get_cstr()[:s.blen];
        temporal::ParsedIsoZonedDateTime p = { .year = 0, .month = 0, .day = 0, .hour = 0, .minute = 0, .second = 0, .nanos = 0, .offset_seconds = 0, .has_offset = false, .is_z = false };
        if (!temporal::parse_iso_zoneddatetime_string(text, &p)) {
                builtin_throw(ctx, ctx.heap.range_err_proto, "Temporal.ZonedDateTime.from: invalid ISO string");
            return;
        }
        // Validate options for the string path. Returns the offset mode so
        // the wall-day range check can be skipped for `use`/`ignore`, where
        // the exact time is pinned and the wall instant need not be computed.
        temporal::OverflowKind _str_overflow;
        int offset_mode = validate_zdt_from_options(ctx, &_str_overflow);
        if (offset_mode < 0) return;
        // Resolve timezone from annotation or offset. If the bracket is an
        // offset like `+01:00` and there was NO explicit offset on the
        // date-time (i.e. the parser left offset_seconds at 0 without seeing
        // Z/±HH:MM), the bracket offset governs the wall-to-epoch arithmetic.
        // An explicit `Z`/`±HH:MM` between time and bracket wins per spec:
        // the bracket is only the zone identifier.
        HObject* tz;
        long bracket_off = 0;
        bool bracket_is_offset = false;
        String zname = "";
        if (p.timezone.len > 0) {
            char[] tz_id = p.timezone;
            String tzid_str = (String)tz_id;
            zname = tzid_str;
            usz j = 0;
            long off_check = 0;
            if (temporal::parse_offset_only(tzid_str, &j, &off_check) && j == tzid_str.len) {
                bracket_off = off_check;
                bracket_is_offset = true;
            }
            if (temporal::tzdb_zone_exists((String)tz_id)) {
                HObject*? tz_o = alloc_timezone(ctx.heap, (String)tz_id);
                if (catch err = tz_o) { builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return; }
                tz = tz_o;
            } else {
                HObject* tz_o = resolve_tz_from_string(ctx, (String)tz_id);
                if (tz_o == null) return;
                tz = tz_o;
            }
        } else {
            char[8] off_buf;
            long mag = p.offset_seconds < 0 ? -p.offset_seconds : p.offset_seconds;
            off_buf[0] = p.offset_seconds >= 0 ? '+' : '-';
            off_buf[1] = (char)('0' + (int)(mag / 3600 / 10));
            off_buf[2] = (char)('0' + (int)(mag / 3600 % 10));
            off_buf[3] = ':';
            off_buf[4] = (char)('0' + (int)((mag % 3600) / 60 / 10));
            off_buf[5] = (char)('0' + (int)((mag % 3600) / 60 % 10));
            off_buf[6] = 0;
            zname = (String)off_buf[:6];
            HObject*? tz_o = alloc_timezone(ctx.heap, (String)off_buf[:6]);
            if (catch err = tz_o) { builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return; }
            tz = tz_o;
        }
        long wall_secs = temporal::epoch_days_from_civil(p.year, p.month, p.day) * 86400
            + (long)p.hour * 3600 + (long)p.minute * 60 + (long)p.second;
        // CheckISODaysRange: the wall date must be within ±10^8 days of the
        // epoch (per spec, to keep the intermediate arithmetic representable).
        // Without this, `-271821-04-19T23:00-01:00[-01:00]` is silently
        // accepted even though the wall date is one day below the limit.
        // However, when the offset option is `use` or `ignore` the exact
        // instant is pinned by the explicit offset and the wall instant need
        // not be computed, so a wall date outside the limit is allowed.
        if (offset_mode != 1 && offset_mode != 2) {
            long wall_day = temporal::epoch_days_from_civil(p.year, p.month, p.day);
            if (!temporal::epoch_days_in_range(wall_day)) {
                builtin_throw(ctx, ctx.heap.range_err_proto, "Temporal.ZonedDateTime.from: ISO date outside the representable range");
                return;
            }
        }
        // When the bracket is an offset zone (e.g. `+01:00`) and no explicit
        // offset was given on the date-time, the bracket offset governs.
        // For an IANA zone with no explicit offset, offset_seconds=0 and
        // disambiguation picks the right wall instant.
        long effective_off = (bracket_is_offset && !p.has_offset) ? bracket_off : p.offset_seconds;
        // Build the instant as a BigInt so the range check survives at
        // ±10^8 days, where double precision (2^53) can't represent every
        // integer. Wall and offset are converted via int128 then to BigInt
        // so values near NS_MAX/NS_MIN don't round.
        int128 wall_ns_128 = (int128)wall_secs * (int128)temporal::NS_PER_SEC + (int128)p.nanos;
        int128 eff_off_128 = (int128)effective_off;
        int128 epoch_ns_128 = wall_ns_128 - eff_off_128 * (int128)temporal::NS_PER_SEC;
        // Instant range check: NS_MIN..NS_MAX is ±100,000,000 days * 86400e9 ns.
        {
            int128 ns_limit = temporal::INSTANT_MAX_NS;
            if (epoch_ns_128 > ns_limit || epoch_ns_128 < -ns_limit) {
                builtin_throw(ctx, ctx.heap.range_err_proto, "Temporal.ZonedDateTime.from: instant outside the representable range");
                return;
            }
        }
        // An explicit numeric offset (a `Z`/`±HH:MM` between time and bracket)
        // must agree with the zone's actual offset at the instant it produces,
        // per the offset option semantics (reject/default throw, use/ignore
        // pass, prefer falls back to the zone offset). `Z` pins the instant;
        // it is the bracket that is merely the zone identifier, so it is
        // excluded from this agreement check.
        if (p.has_offset && !p.is_z) {
            int128 agree_epoch = epoch_ns_128;
            if (!zdt_check_offset_agreement(ctx, zname, wall_ns_128, p.offset_seconds, offset_mode, &agree_epoch)) return;
            epoch_ns_128 = agree_epoch;
        }
        // Build the BigInt straight from the int128. Going via a double here
        // would discard every bit below 2^53, so an epoch instant such as
        // 2000-01-01T12:34:56.98765Z (946730096987650000 ns) came back as
        // ...987650048 and its `nanosecond` field read 48 instead of 0.
        hbigint::HBigInt*? big_o = hbigint::hbigint_alloc(ctx.heap, epoch_ns_128);
        if (catch err = big_o) { builtin_throw(ctx, ctx.heap.range_err_proto, "out of range"); return; }
        hbigint::HBigInt* epoch_ns = big_o;
        HString* cal = builtin_intern_string(ctx.heap, "iso8601");
        HObject*? obj_o = alloc_zoneddatetime(ctx.heap, epoch_ns, tz, cal);
        ctx.heap.decref((types::HeapHeader*)epoch_ns);
        if (catch err = obj_o) { builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return; }
        HObject* obj = obj_o;
        obj.prototype = ctx.heap.temporal_zoneddatetime_proto;
        ctx.result.set_object(obj);
        return;
    }

    // Object input. Options are read before the ZDT identity copy path; the
    // property-bag path reads them after the fields (order-of-operations).
    if (arg.is_object() && arg.get_heapptr() != null) {
        HObject* o = (HObject*)arg.get_heapptr();
        if (o.get_class() == hobject::ObjClass.TEMPORAL_ZONEDDATETIME) {
            temporal::OverflowKind om_overflow;
            int om = validate_zdt_from_options(ctx, &om_overflow);
            if (om < 0) return;
            // Per spec, a ZonedDateTime argument produces a copy rather
            // than the same instance. The shared sub-objects (time-zone,
            // calendar) are incref'd in `alloc_zoneddatetime` so this
            // copy keeps the original reachable through them.
            hbigint::HBigInt* src_ns = o.extra.temporal.big_ns;
            HObject* src_tz = o.extra.temporal.timezone;
            HString* src_cal = (HString*)o.extra.temporal.calendar;
            hbigint::HBigInt*? big_o = hbigint::hbigint_copy(ctx.heap, src_ns);
            if (catch err = big_o) {
                builtin_throw(ctx, ctx.heap.range_err_proto, "Instant copy failed");
                return;
            }
            HObject*? obj_o = alloc_zoneddatetime(ctx.heap, big_o, src_tz, src_cal);
            ctx.heap.decref((types::HeapHeader*)big_o);
            if (catch err = obj_o) { builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return; }
            HObject* obj = obj_o;
            obj.prototype = ctx.heap.temporal_zoneddatetime_proto;
            ctx.result.set_object(obj);
            return;
        }
        // Property bag. Read all fields in the spec's alphabetical order:
        // the unified reader resolves `timeZone` and validates `offset` at
        // their positions (offset between nanosecond and second, timeZone
        // between second and year) and requires the date fields. The
        // disambiguation/offset/overflow options are read AFTER the fields
        // per the order-of-operations fixture, before field validation so
        // `overflow: "reject"` is honored (test262 overflow-options.js,
        // calendarresolvefields-error-ordering.js).
        Vm* v = (Vm*)ctx.vm;
        temporal::CivilDateTime fields;
        temporal::CivilDateTime cur = { .date = { .y = 1970, .m = 1, .d = 1 }, .time = { .h = 0, .mi = 0, .s = 0, .ms = 0, .us = 0, .ns = 0 } };
        bool _zdt_have_mc;
        int _zdt_mci;
        TVal _zdt_mc_v;
        bool has_tz = false;
        HObject* tz = null;
        bool has_offset_prop = false;
        long off_sec = 0;
        if (!bag_to_datetime_fields_ex(ctx, o, TBM_ZDT, true, true, cur.date, cur.time, &fields,
                                       null, &_zdt_have_mc, &_zdt_mci, &_zdt_mc_v,
                                       &has_tz, &tz, &has_offset_prop, &off_sec)) {
            if (v.throw_pending) { ctx.should_throw = true; ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value); v.throw_pending = false; }
            return;
        }
        if (!has_tz) {
            builtin_throw(ctx, ctx.heap.type_err_proto, "Temporal.ZonedDateTime.from: property bag requires a timeZone property");
            return;
        }
        // If no `offset` was supplied but the time zone is an offset zone
        // (e.g. "+01:46"), use that offset to convert the wall time to UTC.
        // The agreement check below applies only when both an offset and an
        // offset-zone name were supplied; here they would necessarily agree.
        if (!has_offset_prop) {
            String tzid_str = timezone_name(tz);
            usz k = 0;
            long tz_off = 0;
            if (temporal::parse_offset_only((char[])tzid_str, &k, &tz_off) && k == tzid_str.len) {
                off_sec = tz_off;
                has_offset_prop = true;
            }
        }
        temporal::OverflowKind zdt_overflow;
        int zdt_offset_mode = 0;
        {
            temporal::OverflowKind ov_kind;
            int om_b = validate_zdt_from_options(ctx, &ov_kind);
            if (om_b < 0) return;
            zdt_overflow = ov_kind;
            zdt_offset_mode = om_b;
        }
        if (!check_iso_monthcode_suitability(ctx, _zdt_have_mc, _zdt_mci, _zdt_mc_v)) {
            if (v.throw_pending) { ctx.should_throw = true; ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value); v.throw_pending = false; }
            return;
        }
        temporal::CivilDate valid_d;
        if (!fields_to_valid_date(ctx, fields.date, zdt_overflow, &valid_d)) return;
        temporal::CivilTime valid_t;
        if (!fields_to_valid_time(ctx, fields.time, &valid_t, temporal::OverflowKind.REJECT, false)) return;
        long wall_secs = temporal::epoch_days_from_civil(valid_d.y, (int)valid_d.m, (int)valid_d.d) * 86400
            + (long)valid_t.h * 3600 + (long)valid_t.mi * 60 + (long)valid_t.s;
        long frac_ns = (long)valid_t.ms * 1000000 + (long)valid_t.us * 1000 + (long)valid_t.ns;
        // Combine in int128: double arithmetic here would drop every bit
        // below 2^53 and corrupt the sub-microsecond digits.
        int128 epoch_ns_128 = (int128)wall_secs * (int128)temporal::NS_PER_SEC + (int128)frac_ns
            - (int128)off_sec * (int128)temporal::NS_PER_SEC;
        // The supplied offset must agree with the time zone's actual offset
        // at the instant it produces, per the offset option semantics. When
        // the offset was synthesized from an offset-form zone id it agrees
        // trivially; an explicit property offset on an IANA zone is the real
        // check that can throw (see `offset-does-not-match-iana-time-zone`).
        if (has_offset_prop) {
            int128 agree_epoch = epoch_ns_128;
            String zname = timezone_name(tz);
            if (!zdt_check_offset_agreement(ctx, zname, epoch_ns_128 + (int128)off_sec * (int128)temporal::NS_PER_SEC,
                                            off_sec, zdt_offset_mode, &agree_epoch)) return;
            epoch_ns_128 = agree_epoch;
        }
        hbigint::HBigInt*? big_o = hbigint::hbigint_alloc(ctx.heap, epoch_ns_128);
        if (catch err = big_o) { builtin_throw(ctx, ctx.heap.range_err_proto, "out of range"); return; }
        hbigint::HBigInt* epoch_ns = big_o;
        HString* cal_str = builtin_intern_string(ctx.heap, "iso8601");
        HObject*? obj_o = alloc_zoneddatetime(ctx.heap, epoch_ns, tz, cal_str);
        ctx.heap.decref((types::HeapHeader*)epoch_ns);
        if (catch err = obj_o) { builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return; }
        HObject* zdt_obj = obj_o;
        zdt_obj.prototype = ctx.heap.temporal_zoneddatetime_proto;
        ctx.result.set_object(zdt_obj);
        return;
    }

    builtin_throw(ctx, ctx.heap.type_err_proto, "Temporal.ZonedDateTime.from: argument must be a string or object");
}

// Temporal.ZonedDateTime.compare(a, b)
fn void builtin_temporal_zoneddatetime_compare(BuiltinContext* ctx) {
    if (ctx.argc < 2) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "Temporal.ZonedDateTime.compare requires two arguments");
        return;
    }
    TVal* a_arg = arg_at(ctx, 0);
    TVal* b_arg = arg_at(ctx, 1);

    // Resolve a.
    hbigint::HBigInt* a_ns = null;
    if (a_arg.is_object() && a_arg.get_heapptr() != null
        && ((HObject*)a_arg.get_heapptr()).get_class() == hobject::ObjClass.TEMPORAL_ZONEDDATETIME) {
        a_ns = ((HObject*)a_arg.get_heapptr()).extra.temporal.big_ns;
    } else {
        // Reject non-string/non-object primitives (including Symbol) before
        // delegating to `from`, which would otherwise mishandle them.
        if (!a_arg.is_string() && !(a_arg.is_object() && a_arg.get_heapptr() != null)) {
            builtin_throw(ctx, ctx.heap.type_err_proto, "Temporal.ZonedDateTime.compare: argument must be a ZonedDateTime, string, or property bag");
            return;
        }
        // String path: reject Symbols (they would otherwise coerce to a
        // RangeError via the ISO parser; the spec wants a TypeError here).
        if (a_arg.is_string()) {
            HString* as = (HString*)a_arg.get_heapptr();
            if (as != null && as.is_symbol()) {
                builtin_throw(ctx, ctx.heap.type_err_proto, "Temporal.ZonedDateTime.compare: Symbol argument is not a ZonedDateTime");
                return;
            }
        }
        TVal saved_this = ctx.this_val;
        ctx.regs[ctx.base_reg + 0] = *a_arg;
        ctx.argc = 1;
        builtin_temporal_zoneddatetime_from(ctx);
        ctx.this_val = saved_this;
        ctx.argc = 2;
        if (ctx.should_throw) return;
        if (!ctx.result.is_object()) { builtin_throw(ctx, ctx.heap.type_err_proto, "not a ZonedDateTime"); return; }
        a_ns = ((HObject*)ctx.result.get_heapptr()).extra.temporal.big_ns;
    }

    // Resolve b.
    hbigint::HBigInt* b_ns = null;
    if (b_arg.is_object() && b_arg.get_heapptr() != null
        && ((HObject*)b_arg.get_heapptr()).get_class() == hobject::ObjClass.TEMPORAL_ZONEDDATETIME) {
        b_ns = ((HObject*)b_arg.get_heapptr()).extra.temporal.big_ns;
    } else {
        if (!b_arg.is_string() && !(b_arg.is_object() && b_arg.get_heapptr() != null)) {
            builtin_throw(ctx, ctx.heap.type_err_proto, "Temporal.ZonedDateTime.compare: argument must be a ZonedDateTime, string, or property bag");
            return;
        }
        if (b_arg.is_string()) {
            HString* bs = (HString*)b_arg.get_heapptr();
            if (bs != null && bs.is_symbol()) {
                builtin_throw(ctx, ctx.heap.type_err_proto, "Temporal.ZonedDateTime.compare: Symbol argument is not a ZonedDateTime");
                return;
            }
        }
        TVal saved_this = ctx.this_val;
        ctx.regs[ctx.base_reg + 0] = *b_arg;
        ctx.argc = 1;
        builtin_temporal_zoneddatetime_from(ctx);
        ctx.this_val = saved_this;
        ctx.argc = 2;
        if (ctx.should_throw) return;
        if (!ctx.result.is_object()) { builtin_throw(ctx, ctx.heap.type_err_proto, "not a ZonedDateTime"); return; }
        b_ns = ((HObject*)ctx.result.get_heapptr()).extra.temporal.big_ns;
    }

    ctx.result.set_fastint(instant_cmp_big(a_ns, b_ns));
}

fn hbigint::HBigInt* zdt_value(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_ZONEDDATETIME, "this is not a Temporal.ZonedDateTime")) return null;
    HObject* obj = (HObject*)ctx.this_val.get_heapptr();
    return obj.extra.temporal.big_ns;
}

fn void builtin_temporal_zoneddatetime_proto_epochNanoseconds(BuiltinContext* ctx) {
    hbigint::HBigInt* b = zdt_value(ctx);
    if (b == null) return;
    ctx.result.set_bigint(b);
}

fn void builtin_temporal_zoneddatetime_proto_epochSeconds(BuiltinContext* ctx) {
    hbigint::HBigInt* b = zdt_value(ctx);
    if (b == null) return;
    double d;
    if (!bigint_to_epoch_number(b, &d, ctx)) return;
    ctx.result.set_number(math::floor(d / 1e9));
}

fn void builtin_temporal_zoneddatetime_proto_epochMilliseconds(BuiltinContext* ctx) {
    hbigint::HBigInt* b = zdt_value(ctx);
    if (b == null) return;
    double d;
    if (!bigint_to_epoch_number(b, &d, ctx)) return;
    ctx.result.set_number(math::floor(d / 1e6));
}

fn void builtin_temporal_zoneddatetime_proto_epochMicroseconds(BuiltinContext* ctx) {
    hbigint::HBigInt* b = zdt_value(ctx);
    if (b == null) return;
    double d;
    if (!bigint_to_epoch_number(b, &d, ctx)) return;
    ctx.result.set_number(math::floor(d / 1e3));
}

fn void builtin_temporal_zoneddatetime_proto_timeZoneId(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_ZONEDDATETIME, "this is not a Temporal.ZonedDateTime")) return;
    HObject* obj = (HObject*)ctx.this_val.get_heapptr();
    HObject* tz = obj.extra.temporal.timezone;
    if (tz == null) { ctx.result.set_string(builtin_intern_string(ctx.heap, "")); return; }
    HString* id = (HString*)tz.extra.temporal.calendar;
    ctx.result.set_string(id == null ? builtin_intern_string(ctx.heap, "") : id);
}

fn void builtin_temporal_zoneddatetime_proto_calendarId(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_ZONEDDATETIME, "this is not a Temporal.ZonedDateTime")) return;
    ctx.result.set_string(builtin_intern_string(ctx.heap, "iso8601"));
}


// Format a ZonedDateTime as an ISO string: wall time in the zone's current
// offset with fractional seconds, the ±HH:MM offset, and (unless drop_zone) the
// [Zone] bracket. `digits` is -1 for auto or 0..9. Reads epoch nanoseconds via
// to_int128 so sub-second precision survives beyond 2^53.
fn void zdt_iso_string(BuiltinContext* ctx, hbigint::HBigInt* b, HObject* tz, int digits, temporal::TemporalRoundMode rm, bool drop_zone,
                      int show_offset, int show_tz, int show_cal) {
    // show_offset: 1 = show, 0 = hide; show_tz: 1 = show, 0 = hide, 2 = the
    // `!` critical flag; show_cal: 0 = auto (omits ISO), 1 = always,
    // 2 = never, 3 = critical. The caller has already read and validated the
    // option strings; nothing is re-read here.
    long epoch_secs;
    long ns_rem;
    if (b.fits_int128()) {
        int128 total = b.to_int128();
        long sec_trunc = (long)(total / 1000000000);
        ns_rem = (long)(total - (int128)sec_trunc * 1000000000);
        if (ns_rem < 0) {
            sec_trunc -= 1;
            ns_rem += 1000000000;
        }
        epoch_secs = sec_trunc;
    } else {
        double s_d;
        if (!bigint_to_epoch_number(b, &s_d, ctx)) return;
        epoch_secs = (long)math::floor(s_d / 1e9);
        ns_rem = 0;
    }
    String zone = tz == null ? "" : timezone_name(tz);
    int off = 0;
    if (tz != null) off = temporal::tzdb_offset_for_zone_at(zone, epoch_secs);
    long local_secs = epoch_secs + off;

    // Round up to whole minute when smallestUnit == "minute" (digits == -10):
    // collapse seconds + ns to a multiple of 60s using `rm`. After rounding
    // the broken-down time's seconds/ms/us/ns are all zero.
    if (digits == -10) {
        long total_ns = local_secs * 1000000000 + ns_rem;
        long rounded_total_ns = temporal::round_long_ns(total_ns, 60 * temporal::NS_PER_SEC, rm);
        local_secs = rounded_total_ns / 1000000000;
        ns_rem = 0;
    } else if (digits >= 0 && ns_rem != 0) {
        // Round ns_rem to `digits` precision. If rounding pushes ns_rem over
        // a whole second, carry the extra second into local_secs before
        // recomputing the broken-down time.
        long divisor = 1;
        for (int i = 0; i < 9 - digits; i++) divisor *= 10;
        long v = (long)temporal::round_num_to_incr((double)ns_rem / (double)divisor, 1.0, rm);
        long new_ns_rem = v * divisor;
        if (new_ns_rem >= 1000000000) {
            local_secs += 1;
            new_ns_rem -= 1000000000;
        }
        ns_rem = new_ns_rem;
    }

    temporal::BrokenDownTime bd = temporal::civil_from_seconds(local_secs);
    char[64] buf;
    int n;
    // Year formatting per GetISOPartsFromEpoch: 0..9999 renders as a 4-digit
    // unsigned year; negative or >9999 renders as a 6-digit signed year.
    long y = bd.y;
    if (digits == -10) {
        if (y < 0) {
            n = libc::snprintf(&buf, 64, "-%06ld-%02ld-%02ldT%02ld:%02ld",
                -y, (long)bd.m + 1, (long)bd.d, (long)bd.h, (long)bd.mi);
        } else if (y > 9999) {
            n = libc::snprintf(&buf, 64, "+%06ld-%02ld-%02ldT%02ld:%02ld",
                y, (long)bd.m + 1, (long)bd.d, (long)bd.h, (long)bd.mi);
        } else {
            n = libc::snprintf(&buf, 64, "%04ld-%02ld-%02ldT%02ld:%02ld",
                y, (long)bd.m + 1, (long)bd.d, (long)bd.h, (long)bd.mi);
        }
    } else {
        if (y < 0) {
            n = libc::snprintf(&buf, 64, "-%06ld-%02ld-%02ldT%02ld:%02ld:%02ld",
                -y, (long)bd.m + 1, (long)bd.d, (long)bd.h, (long)bd.mi, (long)bd.s);
        } else if (y > 9999) {
            n = libc::snprintf(&buf, 64, "+%06ld-%02ld-%02ldT%02ld:%02ld:%02ld",
                y, (long)bd.m + 1, (long)bd.d, (long)bd.h, (long)bd.mi, (long)bd.s);
        } else {
            n = libc::snprintf(&buf, 64, "%04ld-%02ld-%02ldT%02ld:%02ld:%02ld",
                y, (long)bd.m + 1, (long)bd.d, (long)bd.h, (long)bd.mi, (long)bd.s);
        }
        n += temporal::format_fractional_seconds(&buf[n], ns_rem, digits, rm);
    }
    temporal::format_offset_seconds(&buf[n], off);
    if (show_offset == 1) n += 6;
    if (!drop_zone && zone.len > 0 && zone.ptr != null && show_tz > 0) {
        int zn = libc::snprintf(&buf[n], 64 - (usz)n, (show_tz == 2) ? "[!%s]" : "[%s]", (char*)zone.ptr);
        n += zn;
    }
    // Calendar name suffix per spec: auto omits for ISO, always and critical
    // include it (`critical` with `!`), never never adds it.
    bool include_cal = false;
    bool cal_critical = false;
    if (show_cal == 1) { include_cal = true; }
    else if (show_cal == 3) { include_cal = true; cal_critical = true; }
    // show_cal == 0 (auto) and show_cal == 2 (never) both leave include_cal false.
    if (include_cal && 64 - (usz)n > 12) {
        int zn = libc::snprintf(&buf[n], 64 - (usz)n, cal_critical ? "[!u-ca=iso8601]" : "[u-ca=iso8601]");
        n += zn;
    }
    ctx.result.set_string(builtin_intern_string(ctx.heap, buf[:n]));
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

        // Validate after all probes. Note: `timeZone` is intentionally
        // omitted from this list because the ZDT.toString spec doesn't
        // accept a `timeZone` option (the zone is the receiver's).
        if (cal_s != null) {
            char[] v = cal_s.get_cstr()[:cal_s.blen];
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
            char[] v = fd_s.get_cstr()[:fd_s.blen];
            if (v == "auto") { digits = -1; }
            else {
                builtin_throw(ctx, ctx.heap.range_err_proto, "fractionalSecondDigits must be an integer 0..9 or \"auto\"");
                return;
            }
        }
        if (off_s != null) {
            char[] v = off_s.get_cstr()[:off_s.blen];
            if (v != "auto" && v != "never") {
                builtin_throw(ctx, ctx.heap.range_err_proto, "invalid offset option");
                return;
            }
            show_offset = (v == "auto") ? 1 : 0;
        }
        if (rm_str != null) {
            char[] v = rm_str.get_cstr()[:rm_str.blen];
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
            char[] v = su_s.get_cstr()[:su_s.blen];
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
            char[] v = tzn_s.get_cstr()[:tzn_s.blen];
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
    zdt_iso_string(ctx, obj.extra.temporal.big_ns, obj.extra.temporal.timezone, digits, rm, false, show_offset, show_tz, show_cal);
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
    ctx.argc = 0;
    builtin_temporal_zoneddatetime_proto_toString(ctx);
}

fn void builtin_temporal_zoneddatetime_proto_equals(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_ZONEDDATETIME, "this is not a Temporal.ZonedDateTime")) return;
    if (ctx.argc < 1) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "equals requires an argument");
        return;
    }
    TVal* arg = arg_at(ctx, 0);
    // equals runs ToTemporalZonedDateTime, so strings and property bags
    // (with year / month / day / timeZone) are accepted. Non-Temporal,
    // non-string, non-object primitives throw TypeError.
    hbigint::HBigInt* b_ns = null;
    HObject* b_tz = null;
    if (arg.is_object() && arg.get_heapptr() != null
        && ((HObject*)arg.get_heapptr()).get_class() == hobject::ObjClass.TEMPORAL_ZONEDDATETIME) {
        HObject* b = (HObject*)arg.get_heapptr();
        b_ns = b.extra.temporal.big_ns;
        b_tz = b.extra.temporal.timezone;
    } else if (arg.is_string()) {
        HString* as = (HString*)arg.get_heapptr();
        if (as != null && as.is_symbol()) {
            builtin_throw(ctx, ctx.heap.type_err_proto, "argument is not a Temporal.ZonedDateTime");
            return;
        }
        TVal saved_this = ctx.this_val;
        ctx.regs[ctx.base_reg + 0] = *arg;
        ctx.argc = 1;
        builtin_temporal_zoneddatetime_from(ctx);
        ctx.this_val = saved_this;
        ctx.argc = 1;
        if (ctx.should_throw) return;
        if (!ctx.result.is_object()) { builtin_throw(ctx, ctx.heap.type_err_proto, "not a ZonedDateTime"); return; }
        HObject* b = (HObject*)ctx.result.get_heapptr();
        b_ns = b.extra.temporal.big_ns;
        b_tz = b.extra.temporal.timezone;
    } else if (arg.is_object() && arg.get_heapptr() != null) {
        // Property bag — delegate to from().
        TVal saved_this = ctx.this_val;
        ctx.regs[ctx.base_reg + 0] = *arg;
        ctx.argc = 1;
        builtin_temporal_zoneddatetime_from(ctx);
        ctx.this_val = saved_this;
        ctx.argc = 1;
        if (ctx.should_throw) return;
        if (!ctx.result.is_object()) { builtin_throw(ctx, ctx.heap.type_err_proto, "not a ZonedDateTime"); return; }
        HObject* b = (HObject*)ctx.result.get_heapptr();
        b_ns = b.extra.temporal.big_ns;
        b_tz = b.extra.temporal.timezone;
    } else {
        builtin_throw(ctx, ctx.heap.type_err_proto, "argument is not a Temporal.ZonedDateTime");
        return;
    }
    HObject* a = (HObject*)ctx.this_val.get_heapptr();
    // ZonedDateTime equality also requires the same time zone (calendar
    // is always iso8601, so it can be omitted from the check).
    String za = a.extra.temporal.timezone == null ? "" : timezone_name(a.extra.temporal.timezone);
    String zb = b_tz == null ? "" : timezone_name(b_tz);
    bool same_ns = b_ns != null && hbigint::hbigint_cmp(a.extra.temporal.big_ns, b_ns) == 0;
    ctx.result.set_boolean(same_ns && za == zb);
}

// this.with(temporalTimeLike[, options]) — overlay the given wall-clock fields
// onto the zone's local time and re-resolve the instant. Defaults:
// disambiguation "compatible", offset "prefer". Only the iso8601 calendar and
// the compatible/earlier/later disambiguation are implemented in Phase 2.
fn void builtin_temporal_zoneddatetime_proto_with(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_ZONEDDATETIME, "this is not a Temporal.ZonedDateTime")) return;
    if (ctx.argc < 1 || arg_at(ctx, 0) == null) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "with requires a fields bag");
        return;
    }
    TVal* arg = arg_at(ctx, 0);
    if (!arg.is_object() || arg.get_heapptr() == null) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "with requires an object");
        return;
    }
    HObject* bag = (HObject*)arg.get_heapptr();
    HObject* self = (HObject*)ctx.this_val.get_heapptr();
    String zone = timezone_name(self.extra.temporal.timezone);
    if (zone.len == 0) { builtin_throw(ctx, ctx.heap.range_err_proto, "zone missing"); return; }

    // RejectObjectWithCalendarOrTimeZone (spec step 4-5): throw TypeError
    // if the bag is a Temporal object or has "calendar"/"timeZone" Get-
    // probed properties. The bag reader below probes both (calendar, then
    // timeZone) and rejects on presence.
    if (!reject_temporal_object_bag(ctx, bag)) return;

    // Current wall time: epoch -> local via the offset in effect at the epoch.
    // Go through zdt_wall_fields, which splits the epoch in int128; routing
    // this through a double instead rounded away everything below 2^53, so
    // the carried-over sub-microsecond digits were lost for any field the
    // bag did not overwrite.
    long cwy, cwm, cwd; int cwh, cwmi, cws, cwms, cwus, cwns, cwoff;
    zdt_wall_fields(self, &cwy, &cwm, &cwd, &cwh, &cwmi, &cws, &cwms, &cwus, &cwns, &cwoff);
    temporal::CivilDateTime cur = {
        .date = { .y = cwy, .m = cwm, .d = cwd },
        .time = { .h = cwh, .mi = cwmi, .s = cws,
                  .ms = cwms, .us = cwus, .ns = cwns },
    };

    temporal::CivilDateTime fields;
    bool have_mc;
    int mci;
    TVal mc_v;
    bool found_any;
    bool has_offset_from_bag = false;
    long bag_offset_sec = 0;
    if (!bag_to_datetime_fields_ex(ctx, bag, TBM_ZDT_WITH, true, false, cur.date, cur.time, &fields,
                                &found_any, &have_mc, &mci, &mc_v, null, null, &has_offset_from_bag, &bag_offset_sec)) {
        return;
    }
    if (!found_any) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "at least one property must be provided");
        return;
    }

    temporal::OverflowKind overflow = temporal::OverflowKind.CONSTRAIN;
    if (ctx.argc >= 2) {
        TVal* ov = arg_at(ctx, 1);
        if (ov != null && !ov.is_undefined()) {
            if (!ov.is_object() || ov.get_heapptr() == null) {
                builtin_throw(ctx, ctx.heap.type_err_proto, "with options must be an object");
                return;
            }
            HObject* opts = (HObject*)ov.get_heapptr();
            // Spec order: disambiguation, offset, overflow.
            TVal disv = prop_or_undefined_pa(ctx, opts, "disambiguation");
            if (ctx.should_throw) return;
            if (!disv.is_undefined()) {
                HString* s = builtin_to_string_vm(ctx, &disv);
                if (ctx.should_throw) return;
                if (s == null) {
                    builtin_throw(ctx, ctx.heap.type_err_proto, "disambiguation option must be a string");
                    return;
                }
                char[] ostr = (String)s.get_cstr()[:s.blen];
                if (ostr != "compatible" && ostr != "earlier" && ostr != "later" && ostr != "reject") {
                    builtin_throw(ctx, ctx.heap.range_err_proto, "invalid disambiguation option");
                    return;
                }
            }
            TVal offv = prop_or_undefined_pa(ctx, opts, "offset");
            if (ctx.should_throw) return;
            if (!offv.is_undefined()) {
                HString* s = builtin_to_string_vm(ctx, &offv);
                if (ctx.should_throw) return;
                if (s == null) {
                    builtin_throw(ctx, ctx.heap.type_err_proto, "offset option must be a string");
                    return;
                }
                char[] ostr = (String)s.get_cstr()[:s.blen];
                if (ostr != "prefer" && ostr != "use" && ostr != "ignore" && ostr != "reject") {
                    builtin_throw(ctx, ctx.heap.range_err_proto, "invalid offset option");
                    return;
                }
            }
            TVal ovv = prop_or_undefined_pa(ctx, opts, "overflow");
            if (ctx.should_throw) return;
            if (!ovv.is_undefined()) {
                HString* s = builtin_to_string_vm(ctx, &ovv);
                if (ctx.should_throw) return;
                if (s == null) {
                    builtin_throw(ctx, ctx.heap.type_err_proto, "overflow option must be a string");
                    return;
                }
                char[] ostr = (String)s.get_cstr()[:s.blen];
                if (ostr == "reject") {
                    overflow = temporal::OverflowKind.REJECT;
                } else if (ostr != "constrain") {
                    builtin_throw(ctx, ctx.heap.range_err_proto, "invalid overflow option");
                    return;
                }
            }
        }
    }
    temporal::CivilDate valid_d;
    if (!check_iso_monthcode_suitability(ctx, have_mc, mci, mc_v)) return;
    if (!fields_to_valid_date(ctx, fields.date, overflow, &valid_d)) return;
    temporal::CivilTime valid_t;
    if (!fields_to_valid_time(ctx, fields.time, &valid_t, overflow, false)) return;

    // New wall time as naive UTC epoch nanos.
    long wall_secs = temporal::epoch_days_from_civil(valid_d.y, (int)valid_d.m, (int)valid_d.d) * 86400
        + (long)valid_t.h * 3600 + (long)valid_t.mi * 60 + (long)valid_t.s;
    long wfrac = (long)valid_t.ms * 1000000 + (long)valid_t.us * 1000 + (long)valid_t.ns;
    double naive_ns = (double)wall_secs * 1e9 + (double)wfrac;

    // Resolve the wall time to candidate instants (same logic as
    // getPossibleInstantsFor).
    int[8] cand;
    int nc = 0;
    // When the bag carried an explicit `offset` property, restrict the
    // candidate set to just that offset; per spec, `InterpretISODateTimeOffset`
    // uses the requested offset as the only acceptable UTC offset.
    if (has_offset_from_bag) {
        // Per spec, an explicit `offset` property in the bag makes the
        // disambiguation unambiguous: the only candidate instant is
        // `wall_time - offset`. A result that would fall outside the
        // representable epoch range is a RangeError.
        int128 explicit_epoch = (int128)wall_secs * (int128)temporal::NS_PER_SEC + (int128)wfrac
            - (int128)bag_offset_sec * (int128)temporal::NS_PER_SEC;
        int128 ns_limit = temporal::INSTANT_MAX_NS;
        if (explicit_epoch > ns_limit || explicit_epoch < -ns_limit) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "instant outside representable range");
            return;
        }
        hbigint::HBigInt*? big_o = hbigint::hbigint_alloc(ctx.heap, explicit_epoch);
        if (catch err = big_o) { builtin_throw(ctx, ctx.heap.range_err_proto, "alloc failed"); return; }
        ((types::HeapHeader*)self.extra.temporal.timezone).incref();
        zdt_from_parts(ctx, big_o, self.extra.temporal.timezone, (HString*)self.extra.temporal.calendar);
        return;
    } else {
        temporal::tz_cand_add(cand[..], &nc, temporal::tzdb_offset_for_zone_at(zone, wall_secs));
        temporal::TzdbTransition[] trans = temporal::tzdb_zone_transitions(zone);
        long window = 2 * 86400;
        for (usz i = 0; i < trans.len; i++) {
            if (trans[i].epoch_sec >= wall_secs - window && trans[i].epoch_sec <= wall_secs + window) {
                temporal::tz_cand_add(cand[..], &nc, trans[i].offset_sec);
            }
        }
        if (nc == 0) temporal::tz_cand_add(cand[..], &nc, 0);
    }
    double[4] hits;
    int nh = 0;
    for (int k = 0; k < nc; k++) {
        double e_ns = naive_ns - (double)cand[k] * 1e9;
        long e_sec = (long)math::floor(e_ns / 1e9);
        if (temporal::tzdb_offset_for_zone_at(zone, e_sec) != cand[k]) continue;
        bool dup = false;
        for (int j = 0; j < nh; j++) if (hits[j] == e_ns) { dup = true; break; }
        if (!dup && nh < 4) { hits[nh] = e_ns; nh++; }
    }
    for (int i = 0; i < nh; i++) {
        for (int j = i + 1; j < nh; j++) {
            if (hits[j] < hits[i]) { double t = hits[i]; hits[i] = hits[j]; hits[j] = t; }
        }
    }

    // Candidate selection above only needs second-level accuracy, so it can
    // run in doubles; but the final instant must be exact. Recover the chosen
    // candidate's offset (a whole number of seconds) and rebuild the epoch
    // nanos in int128, or the sub-microsecond digits are rounded away.
    long chosen_off;
    if (nh == 1 || nh == 2) {
        // Overlap: "earlier" and "compatible" pick the earlier instant, "later"
        // the later. (compatible normally prefers the offset matching the
        // current instant; for the common single-offset-change case the earlier
        // instant carries that offset.)
        chosen_off = (long)math::round((naive_ns - hits[0]) / 1e9);
    } else {
        // Gap: "compatible" shifts the wall time across the skipped hour,
        // relocating it to the instant whose local time is the post-gap offset.
        chosen_off = (long)temporal::tzdb_offset_for_zone_at(zone, wall_secs + 4 * 3600);
    }
    int128 chosen_128 = (int128)wall_secs * (int128)temporal::NS_PER_SEC + (int128)wfrac
        - (int128)chosen_off * (int128)temporal::NS_PER_SEC;

    // The resolved instant must fall within the representable epoch range
    // (±8.64e21 ns). The wall date can be a lone valid ISO date while its
    // UTC instant lands just past −271821-04-19T00:00 (below NS_MIN), so this
    // is a genuine second check after date/time validation.
    int128 ns_limit = temporal::INSTANT_MAX_NS;
    if (chosen_128 > ns_limit || chosen_128 < -ns_limit) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "instant outside representable range");
        return;
    }

    hbigint::HBigInt*? big_o = hbigint::hbigint_alloc(ctx.heap, chosen_128);
    if (catch err = big_o) { builtin_throw(ctx, ctx.heap.range_err_proto, "alloc failed"); return; }
    ((types::HeapHeader*)self.extra.temporal.timezone).incref();
    zdt_from_parts(ctx, big_o, self.extra.temporal.timezone, (HString*)self.extra.temporal.calendar);
}


// Convert a Duration's time components (hours..nanoseconds) to an
// epoch-nanosecond BigInt delta. Calendar units carry no fixed nanosecond
// length and are the caller's to resolve against a date.
fn bool duration_to_ns_delta(BuiltinContext* ctx, temporal::DurationParts dp, hbigint::HBigInt** out) {
    hbigint::HBigInt*? delta_o = hbigint::hbigint_from_slimb(ctx.heap, 0);
    if (catch err = delta_o) { builtin_throw(ctx, ctx.heap.range_err_proto, "alloc failed"); return false; }
    hbigint::HBigInt* delta = delta_o;
    long[6] parts;
    long[6] scales;
    parts[0] = dp.hours;   scales[0] = temporal::NS_PER_HOUR;
    parts[1] = dp.minutes; scales[1] = temporal::NS_PER_MIN;
    parts[2] = dp.seconds; scales[2] = temporal::NS_PER_SEC;
    parts[3] = (long)dp.ms;      scales[3] = temporal::NS_PER_MS;
    parts[4] = (long)dp.us;      scales[4] = 1000L;
    parts[5] = (long)dp.ns;      scales[5] = 1L;
    for (int k = 0; k < 6; k++) {
        if (parts[k] == 0) continue;
        hbigint::HBigInt*? part_o = hbigint::hbigint_alloc(ctx.heap, (int128)parts[k]);
        if (catch err = part_o) { ctx.heap.decref((types::HeapHeader*)delta); builtin_throw(ctx, ctx.heap.range_err_proto, "alloc failed"); return false; }
        hbigint::HBigInt* part = part_o;
        hbigint::HBigInt*? scale_o = hbigint::hbigint_alloc(ctx.heap, (int128)scales[k]);
        if (catch err = scale_o) {
            ctx.heap.decref((types::HeapHeader*)part);
            ctx.heap.decref((types::HeapHeader*)delta);
            builtin_throw(ctx, ctx.heap.range_err_proto, "alloc failed");
            return false;
        }
        hbigint::HBigInt* scale = scale_o;
        hbigint::HBigInt*? scaled = hbigint::hbigint_mul(ctx.heap, part, scale);
        ctx.heap.decref((types::HeapHeader*)part);
        ctx.heap.decref((types::HeapHeader*)scale);
        if (catch err = scaled) { ctx.heap.decref((types::HeapHeader*)delta); builtin_throw(ctx, ctx.heap.range_err_proto, "multiply failed"); return false; }
        hbigint::HBigInt*? new_delta = hbigint::hbigint_addsub(ctx.heap, delta, scaled, false);
        ctx.heap.decref((types::HeapHeader*)scaled);
        ctx.heap.decref((types::HeapHeader*)delta);
        if (catch err = new_delta) { builtin_throw(ctx, ctx.heap.range_err_proto, "addsub failed"); return false; }
        delta = new_delta;
    }
    *out = delta;
    return true;
}

// Build a ZonedDateTime from an epoch-ns BigInt, a TimeZone object, and the
// zone's calendar String, setting the correct prototype.
fn void zdt_from_parts(BuiltinContext* ctx, hbigint::HBigInt* ns, HObject* tz, HString* cal) {
    if (ns == null) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "ZonedDateTime: resulting instant outside valid epoch-nanoseconds range");
        return;
    }
    HObject*? obj_o = alloc_zoneddatetime(ctx.heap, ns, tz, cal);
    if (catch err = obj_o) { ctx.heap.decref((types::HeapHeader*)ns); builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return; }
    HObject* obj = obj_o;
    ctx.heap.decref((types::HeapHeader*)ns);
    obj.prototype = ctx.heap.temporal_zoneddatetime_proto;
    ctx.result.set_object(obj);
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
    zdt_from_parts(ctx, self.extra.temporal.big_ns, new_tz_obj, (HString*)self.extra.temporal.calendar);
}

// this.withCalendar(calendar) — Phase 2 accepts only the iso8601 calendar;
// a non-iso8601 or non-Calendar argument throws.
fn void builtin_temporal_zoneddatetime_proto_withCalendar(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_ZONEDDATETIME, "this is not a Temporal.ZonedDateTime")) return;
    if (ctx.argc < 1 || ctx.regs[ctx.base_reg].is_undefined()) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "withCalendar requires a calendar");
        return;
    }
    TVal* arg = arg_at(ctx, 0);
    HObject* cal = null;
    if (!calendar_from_arg(ctx, arg, &cal)) return;
    HObject* self = (HObject*)ctx.this_val.get_heapptr();
    ((types::HeapHeader*)self.extra.temporal.big_ns).incref();
    ((types::HeapHeader*)self.extra.temporal.timezone).incref();
    zdt_from_parts(ctx, self.extra.temporal.big_ns, self.extra.temporal.timezone, (HString*)cal);
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
        temporal::CivilDate d = { .y = wy, .m = wm, .d = wd };
        if (dp.years != 0)  d = temporal::add_months(d, sign * dp.years * 12, overflow);
        if (dp.months != 0) d = temporal::add_months(d, sign * dp.months, overflow);
        if (temporal::add_months_rejected(d)) return false;
        long day_shift = sign * (dp.weeks * 7 + dp.days);
        if (day_shift != 0) d = temporal::add_days(d, day_shift);
        if (!temporal::is_valid_iso_date(d.y, (int)d.m, (int)d.d)) return false;

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
    if (ctx.argc < 1) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "requires a Temporal.Duration");
        return;
    }
    TVal* arg = arg_at(ctx, 0);
    // Per spec, the duration argument is coerced via `ToTemporalDuration`,
    // which accepts a Duration, a duration string, or a property bag.
    // Primitive non-string types (number, boolean, BigInt, null, Symbol)
    // throw TypeError.
    temporal::DurationParts d_in;
    if (!duration_from_arg(ctx, arg, &d_in)) return;
    // ZDT.add/subtract reads the overflow option (default `reject`) before
    // any calendar arithmetic — see GetTemporalOverflowOption in the spec.
    // The order-of-operations tests wrap `options` in a Proxy and expect to
    // see the `get options.overflow` log line after the duration fields.
    temporal::OverflowKind overflow;
    if (!read_overflow_option(ctx, 1, &overflow)) return;
    HObject* self = (HObject*)ctx.this_val.get_heapptr();
    temporal::DurationParts dp = d_in;
    long sign = subtract ? -1 : 1;

    hbigint::HBigInt* base = self.extra.temporal.big_ns;
    ((types::HeapHeader*)base).incref();

    // Years, months, weeks and days move the wall-clock date, so they are
    // applied on the local axis and re-resolved against the zone; a day across
    // a DST boundary is then a calendar day rather than a fixed 24 hours.
    if (dp.years != 0 || dp.months != 0 || dp.weeks != 0 || dp.days != 0) {
        long wy, wm, wd; int wh, wmi, ws, wms, wus, wns, woff;
        zdt_wall_fields(self, &wy, &wm, &wd, &wh, &wmi, &ws, &wms, &wus, &wns, &woff);
        temporal::CivilDate d = { .y = wy, .m = wm, .d = wd };
        if (dp.years != 0)  d = temporal::add_months(d, sign * dp.years * 12, overflow);
        if (dp.months != 0) d = temporal::add_months(d, sign * dp.months, overflow);
        if (temporal::add_months_rejected(d)) {
            ctx.heap.decref((types::HeapHeader*)base);
            builtin_throw(ctx, ctx.heap.range_err_proto, "ZonedDateTime: date overflow with overflow:reject");
            return;
        }
        long day_shift = sign * (dp.weeks * 7 + dp.days);
        if (day_shift != 0) d = temporal::add_days(d, day_shift);

        long wall_secs = temporal::epoch_days_from_civil(d.y, (int)d.m, (int)d.d) * 86400
            + (long)wh * 3600 + (long)wmi * 60 + (long)ws;
        long wall_frac = (long)wms * 1000000 + (long)wus * 1000 + (long)wns;
        String zone = self.extra.temporal.timezone == null ? "" : timezone_name(self.extra.temporal.timezone);
        int128 moved = temporal::zdt_local_to_epoch_ns(zone, wall_secs, wall_frac);

        hbigint::HBigInt*? moved_o = hbigint::hbigint_alloc(ctx.heap, moved);
        ctx.heap.decref((types::HeapHeader*)base);
        if (catch err = moved_o) { builtin_throw(ctx, ctx.heap.range_err_proto, "alloc failed"); return; }
        base = moved_o;
    }

    // The time components are an exact elapsed-nanosecond shift on the instant.
    temporal::DurationParts time_only = {};
    time_only.hours = dp.hours;
    time_only.minutes = dp.minutes;
    time_only.seconds = dp.seconds;
    time_only.ms = dp.ms;
    time_only.us = dp.us;
    time_only.ns = dp.ns;
    hbigint::HBigInt* delta;
    if (!duration_to_ns_delta(ctx, time_only, &delta)) {
        ctx.heap.decref((types::HeapHeader*)base);
        return;
    }
    hbigint::HBigInt*? result;
    if (subtract) {
        result = instant_sub_big(base, delta, ctx.heap);
    } else {
        result = instant_add_big(base, delta, ctx.heap);
    }
    ctx.heap.decref((types::HeapHeader*)delta);
    ctx.heap.decref((types::HeapHeader*)base);
    if (catch err = result) { builtin_throw(ctx, ctx.heap.range_err_proto, "failed"); return; }
    ((types::HeapHeader*)self.extra.temporal.timezone).incref();
    zdt_from_parts(ctx, result, self.extra.temporal.timezone, (HString*)self.extra.temporal.calendar);
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
    if (ctx.argc < 1) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "requires a Temporal.ZonedDateTime");
        return;
    }
    TVal* arg = arg_at(ctx, 0);
    HObject* self = (HObject*)ctx.this_val.get_heapptr();
    HObject* other;
    ushort original_argc = ctx.argc;

    // Convert argument to a ZonedDateTime via Temporal.ZonedDateTime.from.
    // Strings and property bags are accepted; primitives other than string
    // throw (Symbol → TypeError, others too).
    if (arg.is_object() && arg.get_heapptr() != null
        && ((HObject*)arg.get_heapptr()).get_class() == hobject::ObjClass.TEMPORAL_ZONEDDATETIME) {
        other = (HObject*)arg.get_heapptr();
    } else {
        if (arg.is_string()) {
            HString* as = (HString*)arg.get_heapptr();
            if (as != null && as.is_symbol()) {
                builtin_throw(ctx, ctx.heap.type_err_proto, "Temporal.ZonedDateTime.until/since: Symbol argument is not a ZonedDateTime");
                return;
            }
        } else if (!arg.is_object() || arg.get_heapptr() == null) {
            builtin_throw(ctx, ctx.heap.type_err_proto, "Temporal.ZonedDateTime.until/since: argument must be a ZonedDateTime, string, or property bag");
            return;
        }
        TVal saved_this = ctx.this_val;
        ctx.regs[ctx.base_reg + 0] = *arg;
        ctx.argc = 1;
        builtin_temporal_zoneddatetime_from(ctx);
        ctx.this_val = saved_this;
        // Restore argc so `read_diff_settings` sees the user's options arg at
        // index 1 (or no options if the caller passed only one arg).
        ctx.argc = original_argc;
        if (ctx.should_throw) return;
        if (!ctx.result.is_object()) {
            builtin_throw(ctx, ctx.heap.type_err_proto, "Temporal.ZonedDateTime.until/since: argument is not a ZonedDateTime");
            return;
        }
        other = (HObject*)ctx.result.get_heapptr();
    }

    DiffSettings ds;
    if (!read_diff_settings(ctx, 1, temporal::TemporalUnit.YEAR, temporal::TemporalUnit.NANOSECOND,
                            temporal::TemporalUnit.HOUR, temporal::TemporalUnit.NANOSECOND, !until, &ds)) return;
    ds.is_zoned = true;

    // Both zones must agree for a calendar-unit difference to mean anything:
    // the wall-clock breakdown below is only defined against a single zone.
    if (temporal::is_cal_unit(ds.largest) || ds.largest == temporal::TemporalUnit.DAY) {
        String za = self.extra.temporal.timezone == null ? "" : timezone_name(self.extra.temporal.timezone);
        String zb = other.extra.temporal.timezone == null ? "" : timezone_name(other.extra.temporal.timezone);
        if (za != zb) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "cannot compute calendar units across different time zones");
            return;
        }
    }

    hbigint::HBigInt* a;
    hbigint::HBigInt* b;
    if (until) { a = other.extra.temporal.big_ns; b = self.extra.temporal.big_ns; }
    else       { a = self.extra.temporal.big_ns;  b = other.extra.temporal.big_ns; }

    // Time-only largestUnit: difference on the exact epoch axis, round to the
    // smallest-unit increment, split by largestUnit. The difference is taken
    // in the other-minus-self direction (rounding origin = receiver) and
    // negated at the end for `since`, matching the calendar path below.
    if (!temporal::is_cal_unit(ds.largest) && ds.largest != temporal::TemporalUnit.DAY) {
        assert(self.extra.temporal.big_ns.fits_int128() && other.extra.temporal.big_ns.fits_int128(),
               "ZonedDateTime epochNanoseconds out of int128 range");
        int128 self_ns = self.extra.temporal.big_ns.to_int128();
        int128 other_ns = other.extra.temporal.big_ns.to_int128();
        int128 total = other_ns - self_ns;
        int128 incr_ns = (int128)(temporal::unit_ns_divisor(ds.smallest) * (long)ds.increment);
        if (incr_ns > 1) total = temporal::round_long_ns_128(total, incr_ns, ds.mode);
        temporal::DurationParts dp;
        temporal::decompose_ns_128(total, ds.largest, &dp);
        if (!until) {
            dp.hours = -dp.hours;
            dp.minutes = -dp.minutes;
            dp.seconds = -dp.seconds;
            dp.ms = -dp.ms;
            dp.us = -dp.us;
            dp.ns = -dp.ns;
        }
        HObject*? dur_o = alloc_duration(ctx.heap, dp);
        if (catch err = dur_o) { builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return; }
        HObject* dur = dur_o;
        dur.prototype = ctx.heap.temporal_duration_proto;
        ctx.result.set_object(dur);
        return;
    }

    // Calendar-unit path: difference the wall-clock dates, then carry whatever
    // time is left over. Working on the local axis keeps a DST day one calendar
    // day even though it is not 24 hours of elapsed time.
    //
    // The spec's NudgeToCalendarUnit uses the receiver as the rounding origin
    // regardless of until/since, and flips the sign at the end for `since`.
    // Mirror that here: `start = self` always (so the year/month lengths are
    // measured at `self`), `end = other` always, and negate the resulting
    // duration when this is a `since` call.
    HObject* from = self;
    HObject* to   = other;
    long fy, fm, fd; int fh, fmi, fs, fms, fus, fns, foff;
    long ty, tm, td; int th, tmi, ts, tms, tus, tns, toff;
    zdt_wall_fields(from, &fy, &fm, &fd, &fh, &fmi, &fs, &fms, &fus, &fns, &foff);
    zdt_wall_fields(to, &ty, &tm, &td, &th, &tmi, &ts, &tms, &tus, &tns, &toff);

    temporal::CivilDateTime start_dt = {
        .date = { .y = fy, .m = fm, .d = fd },
        .time = { .h = fh, .mi = fmi, .s = fs, .ms = fms, .us = fus, .ns = fns },
    };
    temporal::CivilDateTime end_dt = {
        .date = { .y = ty, .m = tm, .d = td },
        .time = { .h = th, .mi = tmi, .s = ts, .ms = tms, .us = tus, .ns = tns },
    };

    temporal::DurationParts dp;
    if (!datetime_difference(ctx, start_dt, end_dt, ds, &dp)) return;

    if (!until) {
        // `since` negates the result. read_diff_settings already negated
        // the rounding mode (ceil ↔ floor, halfCeil ↔ halfFloor), so the
        // sign of the integer fields flips here.
        dp.years = -dp.years;
        dp.months = -dp.months;
        dp.weeks = -dp.weeks;
        dp.days = -dp.days;
        dp.hours = -dp.hours;
        dp.minutes = -dp.minutes;
        dp.seconds = -dp.seconds;
        dp.ms = -dp.ms;
        dp.us = -dp.us;
        dp.ns = -dp.ns;
    }

    HObject*? dur_o = alloc_duration(ctx.heap, dp);
    if (catch err = dur_o) { builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return; }
    HObject* dur = dur_o;
    dur.prototype = ctx.heap.temporal_duration_proto;
    ctx.result.set_object(dur);
}


// =====================================================================
// ZonedDateTime: missing getter and method implementations
// =====================================================================

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

fn void builtin_temporal_zoneddatetime_proto_year(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_ZONEDDATETIME, "this is not a Temporal.ZonedDateTime")) return;
    HObject* obj = (HObject*)ctx.this_val.get_heapptr();
    long wy, wm, wd; int wh, wmi, ws, wms, wus, wns, off;
    zdt_wall_fields(obj, &wy, &wm, &wd, &wh, &wmi, &ws, &wms, &wus, &wns, &off);
    ctx.result.set_fastint(wy);
}

fn void builtin_temporal_zoneddatetime_proto_month(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_ZONEDDATETIME, "this is not a Temporal.ZonedDateTime")) return;
    HObject* obj = (HObject*)ctx.this_val.get_heapptr();
    long wy, wm, wd; int wh, wmi, ws, wms, wus, wns, off;
    zdt_wall_fields(obj, &wy, &wm, &wd, &wh, &wmi, &ws, &wms, &wus, &wns, &off);
    ctx.result.set_fastint(wm);
}

fn void builtin_temporal_zoneddatetime_proto_monthCode(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_ZONEDDATETIME, "this is not a Temporal.ZonedDateTime")) return;
    HObject* obj = (HObject*)ctx.this_val.get_heapptr();
    long wy, wm, wd; int wh, wmi, ws, wms, wus, wns, off;
    zdt_wall_fields(obj, &wy, &wm, &wd, &wh, &wmi, &ws, &wms, &wus, &wns, &off);
    char[4] buf;
    buf[0] = 'M';
    buf[1] = (char)('0' + (int)(wm / 10));
    buf[2] = (char)('0' + (int)(wm % 10));
    buf[3] = 0;
    ctx.result.set_string(builtin_intern_string(ctx.heap, buf[:3]));
}

fn void builtin_temporal_zoneddatetime_proto_day(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_ZONEDDATETIME, "this is not a Temporal.ZonedDateTime")) return;
    HObject* obj = (HObject*)ctx.this_val.get_heapptr();
    long wy, wm, wd; int wh, wmi, ws, wms, wus, wns, off;
    zdt_wall_fields(obj, &wy, &wm, &wd, &wh, &wmi, &ws, &wms, &wus, &wns, &off);
    ctx.result.set_fastint(wd);
}

fn void builtin_temporal_zoneddatetime_proto_hour(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_ZONEDDATETIME, "this is not a Temporal.ZonedDateTime")) return;
    HObject* obj = (HObject*)ctx.this_val.get_heapptr();
    long wy, wm, wd; int wh, wmi, ws, wms, wus, wns, off;
    zdt_wall_fields(obj, &wy, &wm, &wd, &wh, &wmi, &ws, &wms, &wus, &wns, &off);
    ctx.result.set_fastint(wh);
}

fn void builtin_temporal_zoneddatetime_proto_minute(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_ZONEDDATETIME, "this is not a Temporal.ZonedDateTime")) return;
    HObject* obj = (HObject*)ctx.this_val.get_heapptr();
    long wy, wm, wd; int wh, wmi, ws, wms, wus, wns, off;
    zdt_wall_fields(obj, &wy, &wm, &wd, &wh, &wmi, &ws, &wms, &wus, &wns, &off);
    ctx.result.set_fastint(wmi);
}

fn void builtin_temporal_zoneddatetime_proto_second(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_ZONEDDATETIME, "this is not a Temporal.ZonedDateTime")) return;
    HObject* obj = (HObject*)ctx.this_val.get_heapptr();
    long wy, wm, wd; int wh, wmi, ws, wms, wus, wns, off;
    zdt_wall_fields(obj, &wy, &wm, &wd, &wh, &wmi, &ws, &wms, &wus, &wns, &off);
    ctx.result.set_fastint(ws);
}

fn void builtin_temporal_zoneddatetime_proto_millisecond(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_ZONEDDATETIME, "this is not a Temporal.ZonedDateTime")) return;
    HObject* obj = (HObject*)ctx.this_val.get_heapptr();
    long wy, wm, wd; int wh, wmi, ws, wms, wus, wns, off;
    zdt_wall_fields(obj, &wy, &wm, &wd, &wh, &wmi, &ws, &wms, &wus, &wns, &off);
    ctx.result.set_fastint(wms);
}

fn void builtin_temporal_zoneddatetime_proto_microsecond(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_ZONEDDATETIME, "this is not a Temporal.ZonedDateTime")) return;
    HObject* obj = (HObject*)ctx.this_val.get_heapptr();
    long wy, wm, wd; int wh, wmi, ws, wms, wus, wns, off;
    zdt_wall_fields(obj, &wy, &wm, &wd, &wh, &wmi, &ws, &wms, &wus, &wns, &off);
    ctx.result.set_fastint(wus);
}

fn void builtin_temporal_zoneddatetime_proto_nanosecond(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_ZONEDDATETIME, "this is not a Temporal.ZonedDateTime")) return;
    HObject* obj = (HObject*)ctx.this_val.get_heapptr();
    long wy, wm, wd; int wh, wmi, ws, wms, wus, wns, off;
    zdt_wall_fields(obj, &wy, &wm, &wd, &wh, &wmi, &ws, &wms, &wus, &wns, &off);
    ctx.result.set_fastint(wns);
}

fn void builtin_temporal_zoneddatetime_proto_offset(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_ZONEDDATETIME, "this is not a Temporal.ZonedDateTime")) return;
    HObject* obj = (HObject*)ctx.this_val.get_heapptr();
    long wy, wm, wd; int wh, wmi, ws, wms, wus, wns, off;
    zdt_wall_fields(obj, &wy, &wm, &wd, &wh, &wmi, &ws, &wms, &wus, &wns, &off);
    char[7] buf;
    temporal::format_offset_seconds(&buf[0], off);
    buf[6] = 0;
    ctx.result.set_string(builtin_intern_string(ctx.heap, buf[:6]));
}

fn void builtin_temporal_zoneddatetime_proto_offsetNanoseconds(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_ZONEDDATETIME, "this is not a Temporal.ZonedDateTime")) return;
    HObject* obj = (HObject*)ctx.this_val.get_heapptr();
    long wy, wm, wd; int wh, wmi, ws, wms, wus, wns, off;
    zdt_wall_fields(obj, &wy, &wm, &wd, &wh, &wmi, &ws, &wms, &wus, &wns, &off);
    ctx.result.set_number((double)off * 1e9);
}

fn void builtin_temporal_zoneddatetime_proto_dayOfWeek(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_ZONEDDATETIME, "this is not a Temporal.ZonedDateTime")) return;
    HObject* obj = (HObject*)ctx.this_val.get_heapptr();
    long wy, wm, wd; int wh, wmi, ws, wms, wus, wns, off;
    zdt_wall_fields(obj, &wy, &wm, &wd, &wh, &wmi, &ws, &wms, &wus, &wns, &off);
    long epoch_d = temporal::epoch_days_from_civil(wy, (int)wm, (int)wd);
    long dow = ((epoch_d + 10) % 7) + 1;
    if (dow <= 0) dow += 7;
    ctx.result.set_fastint(dow);
}

fn void builtin_temporal_zoneddatetime_proto_dayOfYear(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_ZONEDDATETIME, "this is not a Temporal.ZonedDateTime")) return;
    HObject* obj = (HObject*)ctx.this_val.get_heapptr();
    long wy, wm, wd; int wh, wmi, ws, wms, wus, wns, off;
    zdt_wall_fields(obj, &wy, &wm, &wd, &wh, &wmi, &ws, &wms, &wus, &wns, &off);
    long jan1 = temporal::epoch_days_from_civil(wy, 1, 1);
    long cur = temporal::epoch_days_from_civil(wy, (int)wm, (int)wd);
    ctx.result.set_fastint(cur - jan1 + 1);
}

fn void builtin_temporal_zoneddatetime_proto_weekOfYear(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_ZONEDDATETIME, "this is not a Temporal.ZonedDateTime")) return;
    HObject* obj = (HObject*)ctx.this_val.get_heapptr();
    long wy, wm, wd; int wh, wmi, ws, wms, wus, wns, off;
    zdt_wall_fields(obj, &wy, &wm, &wd, &wh, &wmi, &ws, &wms, &wus, &wns, &off);
    long doy = temporal::epoch_days_from_civil(wy, (int)wm, (int)wd) -
               temporal::epoch_days_from_civil(wy, 1, 1) + 1;
    long dow = ((temporal::epoch_days_from_civil(wy, (int)wm, (int)wd) % 7) + 4) % 7;
    if (dow <= 0) dow += 7;
    long week = (doy - dow + 10) / 7;
    if (week < 1) {
        week = temporal::iso_weeks_in_year(wy - 1);
    } else if (week > temporal::iso_weeks_in_year(wy)) {
        week = 1;
    }
    ctx.result.set_fastint(week);
}

fn void builtin_temporal_zoneddatetime_proto_yearOfWeek(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_ZONEDDATETIME, "this is not a Temporal.ZonedDateTime")) return;
    HObject* obj = (HObject*)ctx.this_val.get_heapptr();
    long wy, wm, wd; int wh, wmi, ws, wms, wus, wns, off;
    zdt_wall_fields(obj, &wy, &wm, &wd, &wh, &wmi, &ws, &wms, &wus, &wns, &off);
    long doy = temporal::epoch_days_from_civil(wy, (int)wm, (int)wd) -
               temporal::epoch_days_from_civil(wy, 1, 1) + 1;
    long dow = ((temporal::epoch_days_from_civil(wy, (int)wm, (int)wd) % 7) + 4) % 7;
    if (dow <= 0) dow += 7;
    long week = (doy - dow + 10) / 7;
    long week_year = wy;
    if (week < 1) { week_year = wy - 1; }
    else if (week > temporal::iso_weeks_in_year(wy)) { week_year = wy + 1; }
    ctx.result.set_fastint(week_year);
}

fn void builtin_temporal_zoneddatetime_proto_daysInWeek(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_ZONEDDATETIME, "this is not a Temporal.ZonedDateTime")) return;
    ctx.result.set_fastint(7);
}

fn void builtin_temporal_zoneddatetime_proto_daysInMonth(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_ZONEDDATETIME, "this is not a Temporal.ZonedDateTime")) return;
    HObject* obj = (HObject*)ctx.this_val.get_heapptr();
    long wy, wm, wd; int wh, wmi, ws, wms, wus, wns, off;
    zdt_wall_fields(obj, &wy, &wm, &wd, &wh, &wmi, &ws, &wms, &wus, &wns, &off);
    ctx.result.set_fastint(temporal::days_in_month(wy, (int)wm));
}

fn void builtin_temporal_zoneddatetime_proto_daysInYear(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_ZONEDDATETIME, "this is not a Temporal.ZonedDateTime")) return;
    HObject* obj = (HObject*)ctx.this_val.get_heapptr();
    long wy, wm, wd; int wh, wmi, ws, wms, wus, wns, off;
    zdt_wall_fields(obj, &wy, &wm, &wd, &wh, &wmi, &ws, &wms, &wus, &wns, &off);
    long jan1 = temporal::epoch_days_from_civil(wy, 1, 1);
    long dec31 = temporal::epoch_days_from_civil(wy, 12, 31);
    ctx.result.set_fastint(dec31 - jan1 + 1);
}

fn void builtin_temporal_zoneddatetime_proto_monthsInYear(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_ZONEDDATETIME, "this is not a Temporal.ZonedDateTime")) return;
    ctx.result.set_fastint(12);
}

fn void builtin_temporal_zoneddatetime_proto_inLeapYear(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_ZONEDDATETIME, "this is not a Temporal.ZonedDateTime")) return;
    HObject* obj = (HObject*)ctx.this_val.get_heapptr();
    long wy, wm, wd; int wh, wmi, ws, wms, wus, wns, off;
    zdt_wall_fields(obj, &wy, &wm, &wd, &wh, &wmi, &ws, &wms, &wus, &wns, &off);
    ctx.result.set_boolean(temporal::is_leap_year(wy));
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
    int off_start = off;
    int off_end = off;
    if (zone.len > 0 && zone.ptr != null) {
        usz zone_j = 0;
        long zone_off = 0;
        bool zone_is_offset = temporal::parse_offset_only((char[])zone, &zone_j, &zone_off) && zone_j == zone.len;
        if (!zone_is_offset) {
            // For an IANA zone the offset can change across the day boundary;
            // read each side's offset independently so a DST gap shows as
            // 23 hours and a fall-back as 25.
            long today_epoch = today_secs - off;
            long tomorrow_epoch = tomorrow_secs - off;
            off_start = temporal::tzdb_offset_for_zone_at(zone, today_epoch);
            off_end = temporal::tzdb_offset_for_zone_at(zone, tomorrow_epoch);
        }
    }
    int128 today_ns = (int128)today_secs * (int128)temporal::NS_PER_SEC - (int128)off_start * (int128)temporal::NS_PER_SEC;
    int128 tomorrow_ns = (int128)tomorrow_secs * (int128)temporal::NS_PER_SEC - (int128)off_end * (int128)temporal::NS_PER_SEC;
    if (!temporal::instant_in_range(today_ns) || !temporal::instant_in_range(tomorrow_ns)) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "hoursInDay boundary is outside the valid time range");
        return;
    }
    int128 diff_ns = tomorrow_ns - today_ns;
    double hours = (double)diff_ns / 3_600_000_000_000.0;
    ctx.result.set_number(hours);
}

fn void builtin_temporal_zoneddatetime_proto_era(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_ZONEDDATETIME, "this is not a Temporal.ZonedDateTime")) return;
    // The ISO calendar has no eras, so this returns undefined.
    ctx.result.set_undefined();
}

fn void builtin_temporal_zoneddatetime_proto_eraYear(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_ZONEDDATETIME, "this is not a Temporal.ZonedDateTime")) return;
    // The ISO calendar has no eras, so this returns undefined.
    ctx.result.set_undefined();
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
    inst.prototype = ctx.heap.temporal_instant_proto;
    ctx.result.set_object(inst);
}

fn void builtin_temporal_zoneddatetime_proto_toPlainDateTime(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_ZONEDDATETIME, "this is not a Temporal.ZonedDateTime")) return;
    HObject* obj = (HObject*)ctx.this_val.get_heapptr();
    long wy, wm, wd; int wh, wmi, ws, wms, wus, wns, off;
    zdt_wall_fields(obj, &wy, &wm, &wd, &wh, &wmi, &ws, &wms, &wus, &wns, &off);
    temporal::CivilDateTime wall_dt;
    wall_dt.date = { .y = wy, .m = wm, .d = wd };
    wall_dt.time = { .h = wh, .mi = wmi, .s = ws, .ms = wms, .us = wus, .ns = wns };
    HObject*? pdt_o = alloc_plain_datetime(ctx.heap, wall_dt, ctx.heap.temporal_iso_calendar);
    if (catch err = pdt_o) { builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return; }
    HObject* pdt = pdt_o;
    pdt.prototype = ctx.heap.temporal_plain_datetime_proto;
    ctx.result.set_object(pdt);
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
    pt.prototype = ctx.heap.temporal_plain_time_proto;
    ctx.result.set_object(pt);
}

fn void builtin_temporal_zoneddatetime_proto_toPlainDate(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_ZONEDDATETIME, "this is not a Temporal.ZonedDateTime")) return;
    HObject* obj = (HObject*)ctx.this_val.get_heapptr();
    long wy, wm, wd; int wh, wmi, ws, wms, wus, wns, off;
    zdt_wall_fields(obj, &wy, &wm, &wd, &wh, &wmi, &ws, &wms, &wus, &wns, &off);
    temporal::CivilDate d;
    d.y = wy; d.m = wm; d.d = wd;
    HObject*? pd_o = alloc_plain_date(ctx.heap, d, ctx.heap.temporal_iso_calendar);
    if (catch err = pd_o) { builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return; }
    HObject* pd = pd_o;
    pd.prototype = ctx.heap.temporal_plain_date_proto;
    ctx.result.set_object(pd);
}

fn void builtin_temporal_zoneddatetime_proto_startOfDay(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_ZONEDDATETIME, "this is not a Temporal.ZonedDateTime")) return;
    HObject* obj = (HObject*)ctx.this_val.get_heapptr();
    long wy, wm, wd; int wh, wmi, ws, wms, wus, wns, off;
    zdt_wall_fields(obj, &wy, &wm, &wd, &wh, &wmi, &ws, &wms, &wus, &wns, &off);
    long day_secs = temporal::epoch_days_from_civil(wy, (int)wm, (int)wd) * 86400;
    int128 epoch_ns_128 = (int128)day_secs * (int128)temporal::NS_PER_SEC
        - (int128)off * (int128)temporal::NS_PER_SEC;
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
    zdt_from_parts(ctx, big_o, obj.extra.temporal.timezone, (HString*)obj.extra.temporal.calendar);
}

fn void builtin_temporal_zoneddatetime_proto_getTimeZoneTransition(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_ZONEDDATETIME, "this is not a Temporal.ZonedDateTime")) return;
    if (ctx.argc < 1) { builtin_throw(ctx, ctx.heap.type_err_proto, "getTimeZoneTransition requires a direction argument"); return; }
    HObject* obj = (HObject*)ctx.this_val.get_heapptr();
    HObject* tz = obj.extra.temporal.timezone;
    if (tz == null) { ctx.result.set_undefined(); return; }
    // Create an Instant from this ZDT's epoch ns.
    hbigint::HBigInt* b = obj.extra.temporal.big_ns;
    ((types::HeapHeader*)b).incref();
    HObject*? inst_o = alloc_instant(ctx.heap, b);
    ctx.heap.decref((types::HeapHeader*)b);
    if (catch err = inst_o) { builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return; }
    HObject* inst = inst_o;
    inst.prototype = ctx.heap.temporal_instant_proto;
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
        if (ds != null) dir = (String)ds.get_cstr()[:ds.blen];
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
        dir = (String)ds.get_cstr()[:ds.blen];
    } else {
        builtin_throw(ctx, ctx.heap.type_err_proto, "direction must be a string or object");
        return;
    }
    if (dir != "next" && dir != "previous") {
        builtin_throw(ctx, ctx.heap.range_err_proto, "invalid direction");
        return;
    }
    // Delegate to TimeZone method.
    TVal saved_this = ctx.this_val;
    TVal inst_tv;
    inst_tv.set_object(inst);
    ctx.this_val.set_object(tz);
    ctx.regs[ctx.base_reg + 0] = inst_tv;
    ctx.argc = 1;
    if (dir == "next") {
        builtin_temporal_timezone_proto_getNextTransition(ctx);
    } else {
        builtin_temporal_timezone_proto_getPreviousTransition(ctx);
    }
    ctx.this_val = saved_this;
    if (ctx.result.is_object() && ctx.result.get_heapptr() != null) {
        HObject* res_inst = (HObject*)ctx.result.get_heapptr();
        if (res_inst.get_class() == hobject::ObjClass.TEMPORAL_INSTANT) {
            hbigint::HBigInt* trans_ns = res_inst.extra.temporal.big_ns;
            ((types::HeapHeader*)trans_ns).incref();
            ((types::HeapHeader*)tz).incref();
            zdt_from_parts(ctx, trans_ns, tz, (HString*)obj.extra.temporal.calendar);
        }
    }
}

fn void builtin_temporal_zoneddatetime_proto_valueOf(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_ZONEDDATETIME, "this is not a Temporal.ZonedDateTime")) return;
    builtin_throw(ctx, ctx.heap.type_err_proto, "Temporal.ZonedDateTime cannot be converted to a primitive value");
}

fn void builtin_temporal_zoneddatetime_proto_withPlainTime(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_ZONEDDATETIME, "this is not a Temporal.ZonedDateTime")) return;
    HObject* obj = (HObject*)ctx.this_val.get_heapptr();
    long wy, wm, wd; int wh, wmi, ws, wms, wus, wns, off;
    zdt_wall_fields(obj, &wy, &wm, &wd, &wh, &wmi, &ws, &wms, &wus, &wns, &off);
    temporal::CivilTime new_time;
    new_time.h = 0; new_time.mi = 0; new_time.s = 0;
    new_time.ms = 0; new_time.us = 0; new_time.ns = 0;
    if (ctx.argc >= 1) {
        TVal* arg = arg_at(ctx, 0);
        if (!arg.is_undefined()) {
            if (arg.is_object() && arg.get_heapptr() != null) {
                HObject* bag = (HObject*)arg.get_heapptr();
                if (!bag_to_time_fields(ctx, bag, false, new_time, &new_time, true)) {
                    Vm* v = (Vm*)ctx.vm;
                    if (v.throw_pending) { ctx.should_throw = true; ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value); v.throw_pending = false; }
                    return;
                }
                // ToTemporalTime regulates the bag's fields with the default
                // constrain overflow, which clamps out-of-range values and
                // collapses a leap 60 to 59 (a bag cannot carry a leap second).
                temporal::CivilTime valid_t;
                if (!fields_to_valid_time(ctx, new_time, &valid_t, temporal::OverflowKind.CONSTRAIN, false)) return;
                new_time = valid_t;
            } else if (arg.is_string()) {
                HString* s = (HString*)arg.get_heapptr();
                if (s == null) { builtin_throw(ctx, ctx.heap.type_err_proto, "withPlainTime: invalid string"); return; }
                if (s.is_symbol()) {
                    builtin_throw(ctx, ctx.heap.type_err_proto, "withPlainTime: symbol cannot be converted");
                    return;
                }
                char[] text = s.get_cstr()[:s.blen];
                temporal::ParsedIsoDateTime p;
                bool ok = temporal::parse_iso_time_string(text, &p);
                if (!ok) {
                    ok = temporal::parse_iso_date_string(text, &p);
                    if (!ok || !p.has_time) {
                        builtin_throw(ctx, ctx.heap.range_err_proto, "withPlainTime: invalid ISO time string");
                        return;
                    }
                }
                if (p.offset_kind == temporal::OffsetKind.Z) {
                    builtin_throw(ctx, ctx.heap.range_err_proto, "withPlainTime: Z designator not valid");
                    return;
                }
                new_time.h = p.hour; new_time.mi = p.minute; new_time.s = p.second;
                new_time.ms = (int)(p.nanos / 1_000_000);
                new_time.us = (int)((p.nanos / 1000) % 1000);
                new_time.ns = (int)(p.nanos % 1000);
                if (!temporal::is_valid_time((int)new_time.h, (int)new_time.mi, (int)new_time.s, (int)new_time.ms, (int)new_time.us, (int)new_time.ns)) {
                    builtin_throw(ctx, ctx.heap.range_err_proto, "withPlainTime: time is out of range");
                    return;
                }
            } else {
                builtin_throw(ctx, ctx.heap.type_err_proto, "withPlainTime: argument must be undefined, string, or object");
                return;
            }
        }
    }
    long day_secs = temporal::epoch_days_from_civil(wy, (int)wm, (int)wd) * 86400
        + (long)new_time.h * 3600 + (long)new_time.mi * 60 + (long)new_time.s;
    long frac_ns = (long)new_time.ms * 1000000 + (long)new_time.us * 1000 + (long)new_time.ns;
    int128 epoch_ns_128 = (int128)day_secs * (int128)temporal::NS_PER_SEC + (int128)frac_ns
        - (int128)off * (int128)temporal::NS_PER_SEC;
    // The combined date+time instant must sit within the representable epoch
    // range; a wall date at the upper edge combined with a later time-of-day,
    // or an early date with an offset, can push the instant past ±8.64e21.
    int128 ns_limit = temporal::INSTANT_MAX_NS;
    if (epoch_ns_128 > ns_limit || epoch_ns_128 < -ns_limit) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "instant outside representable range");
        return;
    }
    hbigint::HBigInt*? big_o = hbigint::hbigint_alloc(ctx.heap, epoch_ns_128);
    if (catch err = big_o) { builtin_throw(ctx, ctx.heap.range_err_proto, "out of range"); return; }
    ((types::HeapHeader*)obj.extra.temporal.timezone).incref();
    zdt_from_parts(ctx, big_o, obj.extra.temporal.timezone, (HString*)obj.extra.temporal.calendar);
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
        if (!temporal::parse_unit_str(s.get_cstr()[:s.blen], &smallest_unit) || smallest_unit < temporal::TemporalUnit.DAY) {
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
            if (!temporal::parse_rm_str(rm_str.get_cstr()[:rm_str.blen], &rounding_mode)) {
                builtin_throw(ctx, ctx.heap.range_err_proto, "invalid roundingMode");
                return;
            }
        }

        TVal su_v = prop_or_undefined_pa(ctx, opts, "smallestUnit");
        if (ctx.should_throw) return;
        if (su_v.is_undefined()) { builtin_throw(ctx, ctx.heap.range_err_proto, "round requires a smallestUnit option"); return; }
        HString* su_str = builtin_to_string_vm(ctx, &su_v);
        if (ctx.should_throw) return;
        if (!temporal::parse_unit_str(su_str.get_cstr()[:su_str.blen], &smallest_unit) || smallest_unit < temporal::TemporalUnit.DAY) {
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

    hbigint::HBigInt* b = obj.extra.temporal.big_ns;
    long epoch_secs;
    long ns_rem;
    if (b.fits_int128()) {
        int128 total = b.to_int128();
        epoch_secs = (long)(total / 1000000000);
        ns_rem = (long)(total - (int128)epoch_secs * 1000000000);
    } else {
        double s_d;
        if (!bigint_to_epoch_number(b, &s_d, ctx)) return;
        epoch_secs = (long)math::floor(s_d / 1e9);
        ns_rem = 0;
    }

    long result_secs;
    long result_ns;

    if (smallest_unit == temporal::TemporalUnit.DAY) {
        // roundingIncrement is fixed at 1 for "day" (checked above), so this
        // rounds to the nearer local calendar-day boundary.
        long local_secs = epoch_secs + woff;
        long day_secs = temporal::epoch_days_from_civil(wy, (int)wm, (int)wd) * 86400;
        // Validate day boundaries: GetStartOfDay converts midnight local to
        // UTC via startNs = day_secs - woff.  Both the current day's start
        // and the next day's start must lie in the representable range.
        int128 start_ns = ((int128)day_secs - (int128)woff) * 1000000000;
        int128 end_ns = ((int128)day_secs + 86400 - (int128)woff) * 1000000000;
        int128 ns_limit = temporal::INSTANT_MAX_NS;
        if (start_ns <= -ns_limit || start_ns >= ns_limit || end_ns <= -ns_limit || end_ns >= ns_limit) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "rounding pushed the datetime out of range");
            return;
        }
        double day_frac = (double)(local_secs - day_secs) + (double)ns_rem / 1e9;
        double rounded_days = temporal::round_num_to_incr(day_frac / 86400.0, 1, rounding_mode);
        result_secs = day_secs + (long)rounded_days * 86400 - woff;
        result_ns = 0;
    } else {
        long divisor = temporal::unit_ns_divisor(smallest_unit);
        long incr_ns = divisor * (long)rounding_increment;
        // The spec rounds the nanoseconds within the local calendar day
        // (always non-negative), not the epoch nanoseconds.  Compute the
        // day start in local-ns, then round the offset from it.
        long day_start_secs = temporal::epoch_days_from_civil(wy, (int)wm, (int)wd) * 86400;
        int128 local_ns = (int128)(epoch_secs + woff) * 1000000000 + (int128)ns_rem;
        int128 day_start_ns = (int128)day_start_secs * 1000000000;
        int128 ns_in_day = local_ns - day_start_ns;
        int128 incr = (int128)incr_ns;
        int128 q = ns_in_day / incr;
        int128 r = ns_in_day - q * incr;
        if (r != 0) {
            switch (rounding_mode) {
                case temporal::TemporalRoundMode.TRUNC:
                case temporal::TemporalRoundMode.FLOOR: break;
                case temporal::TemporalRoundMode.EXPAND:
                case temporal::TemporalRoundMode.CEIL: q += 1; break;
                default: {
                    int128 twice = r * 2;
                    if (twice > incr) {
                        q += 1;
                    } else if (twice == incr) {
                        switch (rounding_mode) {
                            case temporal::TemporalRoundMode.HALF_TRUNC:
                            case temporal::TemporalRoundMode.HALF_FLOOR: break;
                            case temporal::TemporalRoundMode.HALF_EXPAND:
                            case temporal::TemporalRoundMode.HALF_CEIL: q += 1; break;
                            case temporal::TemporalRoundMode.HALF_EVEN: if ((q & 1) != 0) q += 1; break;
                            default: break;
                        }
                    }
                    break;
                }
            }
        }
        int128 rounded_ns_in_day = q * incr;
        int128 result_local_ns = day_start_ns + rounded_ns_in_day;
        int128 total_i128 = result_local_ns - (int128)woff * 1000000000;
        int128 ns_limit = temporal::INSTANT_MAX_NS;
        if (total_i128 >= ns_limit || total_i128 <= -ns_limit) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "rounding pushed the datetime out of range");
            return;
        }
        hbigint::HBigInt*? big_o = hbigint::hbigint_alloc(ctx.heap, total_i128);
        if (catch err = big_o) { builtin_throw(ctx, ctx.heap.range_err_proto, "out of range"); return; }
        ((types::HeapHeader*)obj.extra.temporal.timezone).incref();
        zdt_from_parts(ctx, big_o, obj.extra.temporal.timezone, (HString*)obj.extra.temporal.calendar);
        return;
    }

    // Combine result_secs and result_ns as a BigInt to avoid the 2^53
    // ceiling on double precision. `(double)result_secs * 1e9` rounds
    // values past ~1973 by 1 ns or more.
    int128 total_i128 = (int128)result_secs * 1000000000 + (int128)result_ns;
    int128 ns_limit = temporal::INSTANT_MAX_NS;
    if (total_i128 >= ns_limit || total_i128 <= -ns_limit) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "rounding pushed the datetime out of range");
        return;
    }
    hbigint::HBigInt*? big_o = hbigint::hbigint_alloc(ctx.heap, total_i128);
    if (catch err = big_o) { builtin_throw(ctx, ctx.heap.range_err_proto, "out of range"); return; }
    ((types::HeapHeader*)obj.extra.temporal.timezone).incref();
    zdt_from_parts(ctx, big_o, obj.extra.temporal.timezone, (HString*)obj.extra.temporal.calendar);
}

fn bool setUpTemporalZonedDateTime(Heap* heap) {
    HObject*? proto_raw = heap.alloc_object(hobject::ObjClass.OBJECT);
    if (catch err = proto_raw) return false;
    HObject* proto = proto_raw;
    proto.prototype = heap.object_proto;

    HString* tag_key = ensure_tostringtag_symbol(heap);
    if (tag_key != null) {
        TVal tag_tv;
        tag_tv.set_string(builtin_intern_string(heap, "Temporal.ZonedDateTime"));
        proto.put_prop(tag_key, tag_tv, hobject::PROP_FLAGS_NWC, heap);
    }

    HObject*? ctor_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
    if (catch err = ctor_raw) return false;
    HObject* ctor = ctor_raw;
    ctor.prototype = heap.function_proto;
    ctor.flags.constructable = true;
    (*ctor.extra_ptr()).func.builtin_fn_index = (int)temporal_index(TemporalBuiltin.ZONEDDATETIME_CTOR);

    HString* constructor_key = (HString*)heap.strs[heap::BuiltinStr.CONSTRUCTOR];
    TVal constructor_tv;
    constructor_tv.set_object(ctor);
    proto.put_prop(constructor_key, constructor_tv, hobject::PROP_FLAGS_WC, heap);

    TVal proto_tv;
    proto_tv.set_object(proto);
    PropFlags proto_pflags;
    proto_pflags.writable = false;
    proto_pflags.enumerable = false;
    proto_pflags.configurable = false;
    proto_pflags.is_accessor = false;
    HString* prototype_key = (HString*)heap.strs[heap::BuiltinStr.PROTOTYPE];
    ctor.put_prop(prototype_key, proto_tv, proto_pflags, heap);

    TVal len_tv;
    len_tv.set_fastint(2);
    HString* length_key = (HString*)heap.strs[heap::BuiltinStr.LENGTH];
    ctor.put_prop(length_key, len_tv, hobject::PROP_FLAGS_NWC, heap);

    set_func_ctor_name(ctor, heap, "ZonedDateTime");

    if (!register_proto_getter_accessor(proto, heap, "epochSeconds", temporal_index(TemporalBuiltin.ZONEDDATETIME_PROTO_EPOCHSECONDS))) return false;
    if (!register_proto_getter_accessor(proto, heap, "epochMilliseconds", temporal_index(TemporalBuiltin.ZONEDDATETIME_PROTO_EPOCHMILLISECONDS))) return false;
    if (!register_proto_getter_accessor(proto, heap, "epochMicroseconds", temporal_index(TemporalBuiltin.ZONEDDATETIME_PROTO_EPOCHMICROSECONDS))) return false;
    if (!register_proto_getter_accessor(proto, heap, "epochNanoseconds", temporal_index(TemporalBuiltin.ZONEDDATETIME_PROTO_EPOCHNANOSECONDS))) return false;
    if (!register_proto_getter_accessor(proto, heap, "timeZoneId", temporal_index(TemporalBuiltin.ZONEDDATETIME_PROTO_TIMEZONEID))) return false;
    if (!register_proto_getter_accessor(proto, heap, "calendarId", temporal_index(TemporalBuiltin.ZONEDDATETIME_PROTO_CALENDARID))) return false;
    if (!register_string_proto_method(proto, heap, "with", temporal_index(TemporalBuiltin.ZONEDDATETIME_PROTO_WITH))) return false;
    if (!register_string_proto_method(proto, heap, "toString", temporal_index(TemporalBuiltin.ZONEDDATETIME_PROTO_TOSTRING))) return false;
    if (!register_string_proto_method(proto, heap, "toJSON", temporal_index(TemporalBuiltin.ZONEDDATETIME_PROTO_TOJSON))) return false;
    if (!register_string_proto_method(proto, heap, "toLocaleString", temporal_index(TemporalBuiltin.ZONEDDATETIME_PROTO_TOLOCALESTRING))) return false;
    if (!register_string_proto_method(proto, heap, "equals", temporal_index(TemporalBuiltin.ZONEDDATETIME_PROTO_EQUALS))) return false;
    if (!register_string_proto_method(proto, heap, "withTimeZone", temporal_index(TemporalBuiltin.ZONEDDATETIME_PROTO_WITHTIMEZONE))) return false;
    if (!register_string_proto_method(proto, heap, "withCalendar", temporal_index(TemporalBuiltin.ZONEDDATETIME_PROTO_WITHCALENDAR))) return false;
    if (!register_string_proto_method(proto, heap, "add", temporal_index(TemporalBuiltin.ZONEDDATETIME_PROTO_ADD))) return false;
    if (!register_string_proto_method(proto, heap, "subtract", temporal_index(TemporalBuiltin.ZONEDDATETIME_PROTO_SUBTRACT))) return false;
    if (!register_string_proto_method(proto, heap, "until", temporal_index(TemporalBuiltin.ZONEDDATETIME_PROTO_UNTIL))) return false;
    if (!register_string_proto_method(proto, heap, "since", temporal_index(TemporalBuiltin.ZONEDDATETIME_PROTO_SINCE))) return false;
    if (!register_string_proto_method(ctor, heap, "from", temporal_index(TemporalBuiltin.ZONEDDATETIME_FROM))) return false;
    if (!register_string_proto_method(ctor, heap, "compare", temporal_index(TemporalBuiltin.ZONEDDATETIME_COMPARE))) return false;
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
    if (!register_string_proto_method(proto, heap, "round", temporal_index(TemporalBuiltin.ZONEDDATETIME_PROTO_ROUND))) return false;
    if (!register_string_proto_method(proto, heap, "withPlainTime", temporal_index(TemporalBuiltin.ZONEDDATETIME_PROTO_WITHPLAIN_TIME))) return false;
    if (!register_string_proto_method(proto, heap, "toInstant", temporal_index(TemporalBuiltin.ZONEDDATETIME_PROTO_TOINSTANT))) return false;
    if (!register_string_proto_method(proto, heap, "toPlainDateTime", temporal_index(TemporalBuiltin.ZONEDDATETIME_PROTO_TOPLAINDATETIME))) return false;
    if (!register_string_proto_method(proto, heap, "toPlainTime", temporal_index(TemporalBuiltin.ZONEDDATETIME_PROTO_TOPLAINTIME))) return false;
    if (!register_string_proto_method(proto, heap, "toPlainDate", temporal_index(TemporalBuiltin.ZONEDDATETIME_PROTO_TOPLAINDATE))) return false;
    if (!register_string_proto_method(proto, heap, "startOfDay", temporal_index(TemporalBuiltin.ZONEDDATETIME_PROTO_STARTOFDAY))) return false;
    if (!register_string_proto_method(proto, heap, "getTimeZoneTransition", temporal_index(TemporalBuiltin.ZONEDDATETIME_PROTO_GETTIMEZONETRANSITION))) return false;
    if (!register_string_proto_method(proto, heap, "valueOf", temporal_index(TemporalBuiltin.ZONEDDATETIME_PROTO_VALUEOF))) return false;

    heap.temporal_zoneddatetime_proto = proto;
    return true;
}

