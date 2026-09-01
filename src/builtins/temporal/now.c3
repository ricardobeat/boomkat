// Temporal.Now bindings: the wall-clock entry points and system time zone
// resolution.
module boomkat::builtins;

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
// Phase 3 — Temporal.Now
// ============================================================================
//
// Six methods that read the host wall clock and produce a fresh Temporal
// value. The system time zone is read from the TZ environment variable (with
// UTC as a POSIX-safe fallback) via boomkat_system_tz_name; tests run under
// TZ=UTC by default. Each method accepts an optional time-zone argument that
// is coerced to a string and resolved through the standard offset/ISO/zone
// grammar used elsewhere; the resolved zone is either an offset (seconds east
// of UTC) or an IANA zone name recognised by the embedded tzdb.
//
// Civil-from-epoch uses the same path the ZDT toString does (tzdb lookup +
// civil_from_seconds), so the result agrees with what the rest of the engine
// would have produced for the same instant.




// Coerce the first argument to a string. Per ES2025 ToTemporalTimeZone, the
// argument first goes through ToPrimitive (string hint); only the result is
// then checked for being a string. Primitives that round-trip to themselves
// (null, boolean, number, bigint, symbol) are therefore NOT strings and
// must throw TypeError, not RangeError. Objects that yield a string via
// valueOf/toString continue to the RangeError check downstream.
//
// `*is_default` distinguishes the missing-argument case (true, caller falls
// back to system zone) from the explicit empty-string case (false, caller
// must surface a RangeError downstream).
//
// Returns true on success; returns false after throwing TypeError when the
// argument is present and the ToPrimitive result is not a string.
fn bool now_coerce_tz_string(BuiltinContext* ctx, String* out, bool* is_default) {
    *out = (String)"";
    *is_default = false;
    if (ctx.argc < 1) { *is_default = true; return true; }
    TVal* arg = arg_at(ctx, 0);
    if (arg.is_undefined()) { *is_default = true; return true; }
    // If the argument is already a string (and not a Symbol, which shares
    // the STRING tag), take it directly.
    if (arg.is_string()) {
        HString* hs = (HString*)arg.get_heapptr();
        if (hs.is_symbol()) {
            builtin_throw(ctx, ctx.heap.type_err_proto, "Time zone must be a string or Temporal.TimeZone");
            return false;
        }
        // C3 slice [:0] yields a 1-byte slice (the NUL terminator), so an
        // empty JS string would produce text.len == 1, defeating the
        // empty-string RangeError check downstream.  Leave *out as the
        // zero-length literal assigned above.
        if (hs.blen > 0) *out = (String)hs.get_cstr()[:hs.blen];
        return true;
    }
    // Per ES2025 ToTemporalTimeZoneSlotValue: only strings are accepted.
    // Objects (including those with toString) are not coerced; they are
    // rejected as TypeError unless they are a Temporal.TimeZone instance
    // (unsupported in this engine).  Non-string primitives (null, numbers,
    // booleans, BigInts) likewise get TypeError.
    builtin_throw(ctx, ctx.heap.type_err_proto, "Time zone must be a string or Temporal.TimeZone");
    return false;
}




// Resolve a Temporal time-zone argument (a string per the spec). On success
// writes the offset in seconds; if the zone is an IANA name (in `*zone_name`)
// the caller looks it up via tzdb. `*offset_known` distinguishes the two: a
// fixed offset means the caller just adds it; an IANA name means the caller
// must query tzdb_offset_for_zone_at at the current instant.
//
// Throws RangeError on grammar failures (bare date-time, sub-minute offset,
// unknown IANA name, negative-zero year, etc.).
fn bool now_resolve_tz(BuiltinContext* ctx, String text, long* out_offset_sec,
                       bool* offset_known, String* out_zone_name, bool* out_zone_known,
                       bool* out_is_z) {
    *offset_known = false;
    *out_zone_known = false;
    *out_is_z = false;
    // Caller is responsible for handling the missing-argument case before
    // reaching here. An explicit empty string from the user is a RangeError.
    if (text.len == 0) return false;

    // The spec validates the ISO date prefix even when a bracket zone is
    // present: a negative-zero extended year like `-000000-10-31T17:45Z[UTC]`
    // must throw regardless of the bracket. So scan the date prefix first
    // and reject bad inputs before any zone resolution.
    usz prefix_end = 0;
    bool has_iso_prefix = temporal::now_skip_iso_prefix(text, &prefix_end);

    // Look for any bracketed zone annotation `[...]` (with no `=` inside).
    // If present, that wins regardless of any other text — the offset that
    // may sit between the time and the bracket is ignored, per the
    // "Time zone string determined from bracket name" spec test.
    usz i = 0;
    usz b_start = 0;
    usz b_len = 0;
    if (temporal::now_find_bracket_zone(text, &i, &b_start, &b_len)) {
        if (i != text.len) return false;
        if (!has_iso_prefix) return false;   // bracket requires a date-time prefix
        if (prefix_end > b_start) return false;  // bracket can't appear mid-date
        String bracket = (String)text[b_start..b_start + b_len - 1];
        // A bracket body can be an IANA name or a `±HH:MM` offset (UTC-offset
        // zone identifiers like `+01:46`). The bracket form disambiguates.
        // Sub-minute forms (`:SS` or `.frac`) are not valid time-zone
        // identifiers per spec; reject them.
        for (usz chk = 0; chk < bracket.len; chk++) {
            if (bracket[chk] == '.' || bracket[chk] == ',') return false;
        }
        // If the bracket starts with `+`/`-` and contains more than one
        // `:`, it is a sub-minute form (e.g. `+01:30:45`); reject.
        if (bracket.len > 0 && (bracket[0] == '+' || bracket[0] == '-')) {
            int colons = 0;
            for (usz chk = 0; chk < bracket.len; chk++) {
                if (bracket[chk] == ':') colons++;
            }
            if (colons >= 2) return false;
        }
        usz j = 0;
        long off_in = 0;
        if (temporal::parse_offset_only(bracket, &j, &off_in) && j == bracket.len) {
            *out_offset_sec = off_in;
            *offset_known = true;
            return true;
        }
        *out_zone_name = bracket;
        *out_zone_known = true;
        return true;
    }

    // ISO prefix without bracket: what's left must be either empty, "Z",
    // or a ±HH:MM offset. Anything else (e.g. bare date-time without zone,
    // or sub-minute offset like `2021-08-19T17:30-07:00:00.1`) is a
    // RangeError.
    if (has_iso_prefix) {
        long off = 0;
        if (prefix_end < text.len && temporal::parse_offset_only(text, &prefix_end, &off)) {
            if (prefix_end != text.len) return false;
            *out_is_z = (text[prefix_end - 1] == 'Z' || text[prefix_end - 1] == 'z');
            // Reject sub-minute offsets: scan the offset tail for `.` or `,`
            // (fractional separator) or for a third `:` (the seconds tier).
            // Walk backwards from `prefix_end` over the parsed offset to find
            // its start, then re-scan the offset itself for colons. Anything
            // beyond a single `:` in the offset means a `:SS` tier.
            int off_colons = 0;
            // The offset starts with `+`/`-`/`Z`; rewind over the digits
            // and `:`. Easier: re-parse from `prefix_end - off_len` to count.
            // We don't have off_len, so re-derive it: scan backward until we
            // hit a non-`+/-/Z/0-9/:` char.
            usz o_start = prefix_end;
            while (o_start > 0) {
                char c = text[o_start - 1];
                if (c == '+' || c == '-' || c == 'Z' || c == 'z') break;
                o_start -= 1;
            }
            for (usz j = o_start; j < prefix_end; j++) {
                if (text[j] == ':') off_colons++;
            }
            if (off_colons > 1) return false;
            *out_offset_sec = off;
            *offset_known = true;
            return true;
        }
        return false;
    }

    // Otherwise the input is a bare zone/offset token. A UTC-offset zone
    // identifier is minute precision only: `:SS` or a fractional part makes
    // it a sub-minute offset, which parse_offset_only accepts but which is
    // not a valid time-zone identifier.
    if (text.len > 0 && (text[0] == '+' || text[0] == '-')) {
        int colons = 0;
        for (usz chk = 0; chk < text.len; chk++) {
            if (text[chk] == '.' || text[chk] == ',') return false;
            if (text[chk] == ':') colons++;
        }
        if (colons > 1) return false;
    }
    usz saved = 0;
    long off2 = 0;
    if (temporal::parse_offset_only(text, &saved, &off2)) {
        if (saved != text.len) return false;
        *out_is_z = (text[0] == 'Z' || text[0] == 'z');
        *out_offset_sec = off2;
        *offset_known = true;
        return true;
    }

    // Bare IANA zone name; just hand it back. Caller validates against tzdb
    // (an unknown zone is a RangeError).
    *out_zone_name = text;
    *out_zone_known = true;
    return true;
}

// Get the offset (seconds east of UTC) for the given zone name at the given
// epoch second. Returns true on success; on unknown zone returns false with
// a RangeError thrown. Case-insensitive: "Utc" and "UTC" both resolve.
fn bool now_offset_for(BuiltinContext* ctx, String zone_name, long epoch_sec, long* out_off) {
    char[64] tmp;
    int sec = temporal::tzdb_offset_for_zone_ci(zone_name, epoch_sec, &tmp, 64);
    if (sec < 0) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "Unknown time zone");
        return false;
    }
    *out_off = (long)sec;
    return true;
}

// Resolve the offset to apply to the current instant for the given time-zone
// argument. If `text` is empty AND `is_default` is true, the system zone
// (from TZ) is used. An explicit empty string (`is_default` false) is a
// RangeError per ES2025 ToTemporalTimeZone. Otherwise `text` is parsed as
// offset, IANA name, or ISO-with-bracket form.
fn bool now_resolve_current_offset(BuiltinContext* ctx, String text, bool is_default, long epoch_sec, long* out_off) {
    if (text.len == 0 && is_default) {
        char* sys_c = boomkat_system_tz_name();
        usz sys_n = 0;
        while (sys_c[sys_n] != 0) sys_n++;
        return now_offset_for(ctx, (String)sys_c[:sys_n], epoch_sec, out_off);
    }
    if (text.len == 0) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "Empty time zone string");
        return false;
    }
    long off = 0;
    bool off_known = false;
    String zone = (String)"";
    bool zone_known = false;
    bool unused_is_z = false;
    if (!now_resolve_tz(ctx, text, &off, &off_known, &zone, &zone_known, &unused_is_z)) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "Invalid time zone");
        return false;
    }
    if (off_known) { *out_off = off; return true; }
    return now_offset_for(ctx, zone, epoch_sec, out_off);
}

// Resolve the canonical (case-folded) name of `zone` and its offset at
// `epoch_sec`. Returns true on success, writes canonical name into
// `canonical_buf` (for `timeZoneId` to report) and offset into `*out_off`.
// Throws RangeError on unknown zone.
fn bool now_resolve_canonical_zone(BuiltinContext* ctx, String zone, long epoch_sec,
                                    char* canonical_buf, usz buf_cap, long* out_off) {
    int sec = temporal::tzdb_offset_for_zone_ci(zone, epoch_sec, canonical_buf, buf_cap);
    if (sec < 0) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "Unknown time zone");
        return false;
    }
    *out_off = (long)sec;
    return true;
}

// Temporal.Now.instant() — current moment as an Instant.
fn void builtin_temporal_now_instant(BuiltinContext* ctx) {
    int128 ns = temporal::now_epoch_nanoseconds();
    hbigint::HBigInt*? b_o = hbigint::hbigint_alloc(ctx.heap, ns);
    if (catch err = b_o) {
        builtin_throw(ctx, ctx.heap.err_proto, "Temporal.Now.instant: alloc failed");
        return;
    }
    hbigint::HBigInt* b = b_o;
    HObject*? obj_o = alloc_instant(ctx.heap, b);
    if (catch err2 = obj_o) {
        ctx.heap.decref((types::HeapHeader*)b);
        builtin_throw(ctx, ctx.heap.err_proto, "Temporal.Now.instant: alloc failed");
        return;
    }
    HObject* obj = obj_o;
    obj.prototype = ctx.heap.temporal_instant_proto;
    ctx.result.set_object(obj);
}

// Temporal.Now.timeZoneId() — IANA name of the system zone (TZ env var,
// or "UTC" if unset).
fn void builtin_temporal_now_time_zone_id(BuiltinContext* ctx) {
    char* sys_c = boomkat_system_tz_name();
    usz sys_n = 0;
    while (sys_c[sys_n] != 0) sys_n++;
    ctx.result.set_string(builtin_intern_string(ctx.heap, (String)sys_c[:sys_n]));
}

// Build a PlainDate from a year/month/day.
fn HObject*? now_make_plain_date(BuiltinContext* ctx, long y, long m, long d) {
    temporal::CivilDate cd = { .y = y, .m = m, .d = d };
    return alloc_plain_date(ctx.heap, cd, ctx.heap.temporal_iso_calendar);
}

// Build a PlainDateTime from year/month/day/hour/minute/second.
fn HObject*? now_make_plain_datetime(BuiltinContext* ctx, long y, long m, long d,
                                      long h, long mi, long s) {
    temporal::CivilDateTime dt;
    dt.date.y = y; dt.date.m = m; dt.date.d = d;
    dt.time.h = h; dt.time.mi = mi; dt.time.s = s;
    dt.time.ms = 0; dt.time.us = 0; dt.time.ns = 0;
    return alloc_plain_datetime(ctx.heap, dt, ctx.heap.temporal_iso_calendar);
}

// Build a PlainTime from hour/minute/second.
fn HObject*? now_make_plain_time(BuiltinContext* ctx, long h, long mi, long s) {
    temporal::CivilTime ct;
    ct.h = h; ct.mi = mi; ct.s = s;
    ct.ms = 0; ct.us = 0; ct.ns = 0;
    return alloc_plain_time(ctx.heap, ct);
}

// Build a ZonedDateTime from the current instant + the supplied time-zone
// argument (or system zone). The argument follows ToTemporalTimeZone's grammar.
fn void builtin_temporal_now_zoned_date_time_iso(BuiltinContext* ctx) {
    String text = (String)"";
    bool is_default = false;
    if (!now_coerce_tz_string(ctx, &text, &is_default)) return;
    long epoch_secs = temporal::now_epoch_seconds();
    long off = 0;
    if (!now_resolve_current_offset(ctx, text, is_default, epoch_secs, &off)) return;

    // Determine the zone to attach to the ZDT. For an offset, build an
    // offset-only zone name ("+HH:MM" / "Z"); for an IANA name, resolve
    // case-insensitively so "Utc" reports as "UTC". The default case
    // (no argument supplied) skips resolve_tz: an empty explicit string
    // is a RangeError, already thrown upstream.
    long off2 = 0;
    bool off_known = false;
    String zone = (String)"";
    bool zone_known = false;
    bool unused_is_z = false;
    if (!is_default) {
        if (!now_resolve_tz(ctx, text, &off2, &off_known, &zone, &zone_known, &unused_is_z)) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "Invalid time zone");
            return;
        }
    }
    char[64] canonical_buf;
    usz canonical_len = 0;
    if (off_known) {
        // Format as "+HH:MM". The spec writes the zero offset as "UTC"
        // (not "Z") when the zone is attached to a ZonedDateTime so that the
        // resulting timeZoneId is canonical across test262 subtests.
        if (off2 == 0) {
            canonical_buf[0] = 'U';
            canonical_buf[1] = 'T';
            canonical_buf[2] = 'C';
            canonical_len = 3;
        } else {
            bool neg = off2 < 0;
            long a = neg ? -off2 : off2;
            long h = a / 3600;
            long mi = (a % 3600) / 60;
            int n = libc::snprintf(&canonical_buf, 64, "%s%02ld:%02ld", neg ? "-" : "+", h, mi);
            canonical_len = (usz)n;
        }
    } else if (zone_known) {
        long dummy_off = 0;
        if (!now_resolve_canonical_zone(ctx, zone, epoch_secs, &canonical_buf, 64, &dummy_off)) return;
        canonical_len = 0;
        while (canonical_buf[canonical_len] != 0) canonical_len += 1;
    } else {
        char* sys_c = boomkat_system_tz_name();
        usz sys_n = 0;
        while (sys_c[sys_n] != 0) sys_n += 1;
        long dummy_off = 0;
        if (!now_resolve_canonical_zone(ctx, (String)sys_c[:sys_n], epoch_secs, &canonical_buf, 64, &dummy_off)) return;
        canonical_len = 0;
        while (canonical_buf[canonical_len] != 0) canonical_len += 1;
    }
    String zone_id = (String)canonical_buf[:canonical_len];

    int128 ns = temporal::now_epoch_nanoseconds();
    hbigint::HBigInt*? b_o = hbigint::hbigint_alloc(ctx.heap, ns);
    if (catch err = b_o) {
        builtin_throw(ctx, ctx.heap.err_proto, "alloc failed");
        return;
    }
    hbigint::HBigInt* b = b_o;
    HObject*? tz_o = alloc_timezone(ctx.heap, zone_id);
    if (catch err2 = tz_o) {
        ctx.heap.decref((types::HeapHeader*)b);
        builtin_throw(ctx, ctx.heap.err_proto, "alloc failed");
        return;
    }
    HObject* tz_obj = tz_o;
    HString* cal_str = builtin_intern_string(ctx.heap, "iso8601");
    HObject*? zdt_o = alloc_zoneddatetime(ctx.heap, b, tz_obj, cal_str);
    if (catch err3 = zdt_o) {
        ctx.heap.decref((types::HeapHeader*)b);
        ctx.heap.decref((types::HeapHeader*)tz_obj);
        builtin_throw(ctx, ctx.heap.err_proto, "alloc failed");
        return;
    }
    HObject* zdt = zdt_o;
    zdt.prototype = ctx.heap.temporal_zoneddatetime_proto;
    ctx.result.set_object(zdt);
}

// Temporal.Now.plainDateISO([timeZone]) — current date in `timeZone`.
fn void builtin_temporal_now_plain_date_iso(BuiltinContext* ctx) {
    String text = (String)"";
    bool is_default = false;
    if (!now_coerce_tz_string(ctx, &text, &is_default)) return;
    long epoch_secs = temporal::now_epoch_seconds();
    long off = 0;
    if (!now_resolve_current_offset(ctx, text, is_default, epoch_secs, &off)) return;
    temporal::BrokenDownTime bd = temporal::civil_from_seconds(epoch_secs + off);
    HObject*? obj_o = now_make_plain_date(ctx, bd.y, (long)bd.m + 1, (long)bd.d);
    if (catch err2 = obj_o) {
        builtin_throw(ctx, ctx.heap.err_proto, "alloc failed");
        return;
    }
    HObject* obj = obj_o;
    obj.prototype = ctx.heap.temporal_plain_date_proto;
    ctx.result.set_object(obj);
}

// Temporal.Now.plainDateTimeISO([timeZone]) — current date + time.
fn void builtin_temporal_now_plain_date_time_iso(BuiltinContext* ctx) {
    String text = (String)"";
    bool is_default = false;
    if (!now_coerce_tz_string(ctx, &text, &is_default)) return;
    long epoch_secs = temporal::now_epoch_seconds();
    long off = 0;
    if (!now_resolve_current_offset(ctx, text, is_default, epoch_secs, &off)) return;
    temporal::BrokenDownTime bd = temporal::civil_from_seconds(epoch_secs + off);
    HObject*? obj_o = now_make_plain_datetime(ctx, bd.y, (long)bd.m + 1, (long)bd.d,
                                               (long)bd.h, (long)bd.mi, (long)bd.s);
    if (catch err2 = obj_o) {
        builtin_throw(ctx, ctx.heap.err_proto, "alloc failed");
        return;
    }
    HObject* obj = obj_o;
    obj.prototype = ctx.heap.temporal_plain_datetime_proto;
    ctx.result.set_object(obj);
}

// Temporal.Now.plainTimeISO([timeZone]) — current wall-clock time.
fn void builtin_temporal_now_plain_time_iso(BuiltinContext* ctx) {
    String text = (String)"";
    bool is_default = false;
    if (!now_coerce_tz_string(ctx, &text, &is_default)) return;
    long epoch_secs = temporal::now_epoch_seconds();
    long off = 0;
    if (!now_resolve_current_offset(ctx, text, is_default, epoch_secs, &off)) return;
    temporal::BrokenDownTime bd = temporal::civil_from_seconds(epoch_secs + off);
    HObject*? obj_o = now_make_plain_time(ctx, (long)bd.h, (long)bd.mi, (long)bd.s);
    if (catch err2 = obj_o) {
        builtin_throw(ctx, ctx.heap.err_proto, "alloc failed");
        return;
    }
    HObject* obj = obj_o;
    obj.prototype = ctx.heap.temporal_plain_time_proto;
    ctx.result.set_object(obj);
}

// Build the Temporal.Now singleton with its six functions attached.
// Temporal.Now is not callable and not constructable (per spec §Temporal.Now
// abstract operation #1 and #2). The Symbol.toStringTag property carries
// "Temporal.Now"; the six methods are writable, non-enumerable, configurable
// per ES2025 §17.
fn HObject*? build_temporal_now(Heap* heap) {
    HObject*? raw = heap.alloc_object(hobject::ObjClass.OBJECT);
    if (catch err = raw) return err~;
    HObject* now = raw;
    now.prototype = heap.object_proto;

    HString* tag_key = ensure_tostringtag_symbol(heap);
    if (tag_key != null) {
        TVal tag_tv;
        tag_tv.set_string(builtin_intern_string(heap, "Temporal.Now"));
        now.put_prop(tag_key, tag_tv, hobject::PROP_FLAGS_NWC, heap);
    }

    HString* key;
    TVal fn_tv;
    HObject* fn_obj;

    key = heap.str_intern("instant");
    if (key == null) return null;
    fn_obj = alloc_builtin_fn(heap, temporal_index(TemporalBuiltin.NOW_INSTANT), "instant", 0);
    if (fn_obj == null) return null;
    fn_tv.set_object(fn_obj);
    now.put_prop(key, fn_tv, hobject::PROP_FLAGS_WC, heap);

    key = heap.str_intern("timeZoneId");
    if (key == null) return null;
    fn_obj = alloc_builtin_fn(heap, temporal_index(TemporalBuiltin.NOW_TIME_ZONE_ID), "timeZoneId", 0);
    if (fn_obj == null) return null;
    fn_tv.set_object(fn_obj);
    now.put_prop(key, fn_tv, hobject::PROP_FLAGS_WC, heap);

    key = heap.str_intern("plainDateISO");
    if (key == null) return null;
    fn_obj = alloc_builtin_fn(heap, temporal_index(TemporalBuiltin.NOW_PLAIN_DATE_ISO), "plainDateISO", 0);
    if (fn_obj == null) return null;
    fn_tv.set_object(fn_obj);
    now.put_prop(key, fn_tv, hobject::PROP_FLAGS_WC, heap);

    key = heap.str_intern("plainDateTimeISO");
    if (key == null) return null;
    fn_obj = alloc_builtin_fn(heap, temporal_index(TemporalBuiltin.NOW_PLAIN_DATE_TIME_ISO), "plainDateTimeISO", 0);
    if (fn_obj == null) return null;
    fn_tv.set_object(fn_obj);
    now.put_prop(key, fn_tv, hobject::PROP_FLAGS_WC, heap);

    key = heap.str_intern("plainTimeISO");
    if (key == null) return null;
    fn_obj = alloc_builtin_fn(heap, temporal_index(TemporalBuiltin.NOW_PLAIN_TIME_ISO), "plainTimeISO", 0);
    if (fn_obj == null) return null;
    fn_tv.set_object(fn_obj);
    now.put_prop(key, fn_tv, hobject::PROP_FLAGS_WC, heap);

    key = heap.str_intern("zonedDateTimeISO");
    if (key == null) return null;
    fn_obj = alloc_builtin_fn(heap, temporal_index(TemporalBuiltin.NOW_ZONED_DATE_TIME_ISO), "zonedDateTimeISO", 0);
    if (fn_obj == null) return null;
    fn_tv.set_object(fn_obj);
    now.put_prop(key, fn_tv, hobject::PROP_FLAGS_WC, heap);

    return now;
}