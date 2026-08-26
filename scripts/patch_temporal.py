#!/usr/bin/env python3
"""Patch temporal.c3 with all ZonedDateTime fixes."""

with open('src/builtins/temporal.c3', 'r') as f:
    c = f.read()

# =====================================================================
# FIX 1: Constructor accepts string timezone
# =====================================================================
old_ctor = """// Temporal.ZonedDateTime(epochNanoseconds, timeZone[, calendar])
fn void builtin_temporal_zoneddatetime_ctor(BuiltinContext* ctx) {
    if (ctx.argc < 2) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "Temporal.ZonedDateTime requires epochNanoseconds and timeZone args");
        return;
    }
    TVal* narg = arg_at(ctx, 0);
    bool ok;
    hbigint::HBigInt* b = builtin_to_bigint(ctx, narg, &ok);
    if (!ok) return;

    // timeZone must be a Temporal.TimeZone object (spec allows a string, which
    // we resolve through the ctor for Phase 2).
    TVal* tzarg = arg_at(ctx, 1);
    HObject* tz;
    if (tzarg.is_object() && tzarg.get_heapptr() != null
        && ((HObject*)tzarg.get_heapptr()).get_class() == hobject::ObjClass.TEMPORAL_TIMEZONE) {
        tz = (HObject*)tzarg.get_heapptr();
    } else {
        builtin_throw(ctx, ctx.heap.type_err_proto, "Temporal.ZonedDateTime timeZone must be a Temporal.TimeZone");
        return;
    }

    // calendar: Phase 2 defaults to iso8601; a supplied calendar must already
    // be a Temporal.Calendar with id "iso8601".
    HString* calendar = builtin_intern_string(ctx.heap, "iso8601");
    HObject*? obj_o = alloc_zoneddatetime(ctx.heap, b, tz, calendar);
    if (catch err = obj_o) { builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return; }
    HObject* obj = obj_o;
    if (ctx.is_constructor) {
        obj.prototype = builtin_proto_from_new_target(ctx, ctx.heap.temporal_zoneddatetime_proto);
    } else {
        obj.prototype = ctx.heap.temporal_zoneddatetime_proto;
    }
    ctx.result.set_object(obj);
}"""

new_ctor = """// Temporal.ZonedDateTime(epochNanoseconds, timeZone[, calendar])
fn void builtin_temporal_zoneddatetime_ctor(BuiltinContext* ctx) {
    if (ctx.argc < 2) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "Temporal.ZonedDateTime requires epochNanoseconds and timeZone args");
        return;
    }
    TVal* narg = arg_at(ctx, 0);
    bool ok;
    hbigint::HBigInt* b = builtin_to_bigint(ctx, narg, &ok);
    if (!ok) return;

    // timeZone may be a string or a Temporal.TimeZone object.
    TVal* tzarg = arg_at(ctx, 1);
    HObject* tz;
    if (tzarg.is_object() && tzarg.get_heapptr() != null
        && ((HObject*)tzarg.get_heapptr()).get_class() == hobject::ObjClass.TEMPORAL_TIMEZONE) {
        tz = (HObject*)tzarg.get_heapptr();
    } else if (tzarg.is_string()) {
        HString* hs = (HString*)tzarg.get_heapptr();
        String s = (String)hs.get_cstr()[:hs.blen];
        if (!temporal::tzdb_zone_exists(s)) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "Unknown time zone");
            return;
        }
        HObject*? tz_o = alloc_timezone(ctx.heap, s);
        if (catch err = tz_o) { builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return; }
        tz = tz_o;
    } else {
        builtin_throw(ctx, ctx.heap.type_err_proto, "Temporal.ZonedDateTime requires a string or TimeZone object");
        return;
    }

    HString* calendar = builtin_intern_string(ctx.heap, "iso8601");
    HObject*? obj_o = alloc_zoneddatetime(ctx.heap, b, tz, calendar);
    if (catch err = obj_o) { builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return; }
    HObject* obj = obj_o;
    if (ctx.is_constructor) {
        obj.prototype = builtin_proto_from_new_target(ctx, ctx.heap.temporal_zoneddatetime_proto);
    } else {
        obj.prototype = ctx.heap.temporal_zoneddatetime_proto;
    }
    ctx.result.set_object(obj);
}"""

c = c.replace(old_ctor, new_ctor)

# =====================================================================
# FIX 2: Replace from() to accept strings, bags, and ZDT instances
# =====================================================================
old_from = """fn void builtin_temporal_zoneddatetime_from(BuiltinContext* ctx) {
    // Phase 2: from() accepts the same (epochNanoseconds, timeZone) pair.
    builtin_temporal_zoneddatetime_ctor(ctx);
}"""

new_from = """// Resolve a timezone string to a Temporal.TimeZone object.
fn HObject* resolve_tz_from_string(BuiltinContext* ctx, String s) {
    if (s.len > 0 && (s[0] == 'Z' || s[0] == 'z' || s[0] == '+' || s[0] == '-')) {
        HObject*? tz_o = alloc_timezone(ctx.heap, s);
        if (catch err = tz_o) { builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return null; }
        return tz_o;
    }
    if (!temporal::tzdb_zone_exists(s)) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "Unknown time zone");
        return null;
    }
    HObject*? tz_o = alloc_timezone(ctx.heap, s);
    if (catch err = tz_o) { builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return null; }
    return tz_o;
}

// Convert string or TimeZone to a TimeZone HObject.
fn HObject*? to_temporal_tz(BuiltinContext* ctx, TVal* arg) {
    if (arg.is_object() && arg.get_heapptr() != null
        && ((HObject*)arg.get_heapptr()).get_class() == hobject::ObjClass.TEMPORAL_TIMEZONE) {
        return (HObject*)arg.get_heapptr();
    }
    if (arg.is_string()) {
        HString* hs = (HString*)arg.get_heapptr();
        String s = hs != null ? (String)hs.get_cstr()[:hs.blen] : (String)"";
        HObject* tz = resolve_tz_from_string(ctx, s);
        if (tz == null) return null~;
        return tz;
    }
    builtin_throw(ctx, ctx.heap.type_err_proto, "time zone must be a string or Temporal.TimeZone object");
    return null~;
}

fn void builtin_temporal_zoneddatetime_from(BuiltinContext* ctx) {
    if (ctx.argc < 1) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "Temporal.ZonedDateTime.from requires an argument");
        return;
    }
    TVal* arg = arg_at(ctx, 0);

    // String input: parse ISO ZonedDateTime string.
    if (arg.is_string()) {
        HString* s = (HString*)arg.get_heapptr();
        if (s == null) { builtin_throw(ctx, ctx.heap.range_err_proto, "invalid string"); return; }
        char[] text = s.get_cstr()[:s.blen];
        temporal::ParsedIsoZonedDateTime p;
        if (!temporal::parse_iso_zoneddatetime_string(text, &p)) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "Temporal.ZonedDateTime.from: invalid ISO string");
            return;
        }
        // Resolve timezone from annotation or offset.
        HObject* tz;
        if (p.timezone.len > 0) {
            char[] tz_id = p.timezone;
            if (!temporal::tzdb_zone_exists(tz_id)) {
                HObject* tz_o = resolve_tz_from_string(ctx, tz_id);
                if (tz_o == null) return;
                tz = tz_o;
            } else {
                HObject*? tz_o = alloc_timezone(ctx.heap, tz_id);
                if (catch err = tz_o) { builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return; }
                tz = tz_o;
            }
        } else {
            char[8] off_buf;
            long mag = p.offset_seconds < 0 ? -p.offset_seconds : p.offset_seconds;
            int sign = p.offset_seconds >= 0 ? 1 : -1;
            off_buf[0] = sign > 0 ? '+' : '-';
            off_buf[1] = (char)('0' + (int)(mag / 3600));
            off_buf[2] = ':';
            off_buf[3] = (char)('0' + (int)((mag % 3600) / 60 / 10));
            off_buf[4] = (char)('0' + (int)((mag % 3600) / 60 % 10));
            off_buf[5] = 0;
            HObject*? tz_o = alloc_timezone(ctx.heap, (String)off_buf[:5]);
            if (catch err = tz_o) { builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return; }
            tz = tz_o;
        }
        // Compute epoch ns from wall time and offset.
        long wall_secs = temporal::epoch_days_from_civil(p.year, p.month, p.day) * 86400
            + (long)p.hour * 3600 + (long)p.minute * 60 + (long)p.second;
        double naive_ns = (double)wall_secs * 1e9 + (double)p.nanos;
        double epoch_ns_d = naive_ns - (double)p.offset_seconds * 1e9;
        hbigint::HBigInt*? big_o = hbigint::hbigint_from_double(ctx.heap, epoch_ns_d);
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

    // Object input.
    if (arg.is_object() && arg.get_heapptr() != null) {
        HObject* o = (HObject*)arg.get_heapptr();
        if (o.get_class() == hobject::ObjClass.TEMPORAL_ZONEDDATETIME) {
            ctx.result.set_object(o);
            return;
        }
        // Property bag: read timeZone, calendar, date/time fields, offset.
        HObject* tz = null;
        TVal tz_v = prop_or_undefined_pa(ctx, o, "timeZone");
        if (!tz_v.is_undefined()) {
            HObject*? tz_o = to_temporal_tz(ctx, &tz_v);
            if (ctx.should_throw) return;
            if (tz_o == null) return;
            tz = tz_o!!;
        }
        if (tz == null) {
            builtin_throw(ctx, ctx.heap.type_err_proto, "Temporal.ZonedDateTime.from: property bag requires a timeZone property");
            return;
        }
        HObject* cal = ctx.heap.temporal_iso_calendar;
        TVal cal_v = prop_or_undefined_pa(ctx, o, "calendar");
        if (!cal_v.is_undefined()) {
            if (!calendar_from_arg(ctx, &cal_v, &cal)) return;
        }
        Vm* v = (Vm*)ctx.vm;
        temporal::CivilDateTime fields;
        temporal::CivilDateTime cur = { .date = { .y = 1970, .m = 1, .d = 1 }, .time = { .h = 0, .mi = 0, .s = 0, .ms = 0, .us = 0, .ns = 0 } };
        if (!bag_to_datetime_fields(ctx, o, false, cur.date, cur.time, &fields)) {
            if (v.throw_pending) { ctx.should_throw = true; ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value); v.throw_pending = false; }
            return;
        }
        temporal::CivilDate valid_d;
        if (!fields_to_valid_date(ctx, fields.date, temporal::OverflowKind.CONSTRAIN, &valid_d)) return;
        temporal::CivilTime valid_t;
        if (!fields_to_valid_time(ctx, fields.time, &valid_t)) return;

        // Read offset from bag, default to zone's current offset.
        long off_sec = 0;
        TVal offset_v = prop_or_undefined_pa(ctx, o, "offset");
        if (!offset_v.is_undefined()) {
            if (offset_v.is_string()) {
                HString* ohs = (HString*)offset_v.get_heapptr();
                char[] otxt = ohs != null ? (String)ohs.get_cstr()[:ohs.blen] : (String)"";
                usz pi = 0;
                if (!parse_offset_only(otxt, &pi, &off_sec) || pi != otxt.len) {
                    builtin_throw(ctx, ctx.heap.range_err_proto, "invalid offset string");
                    return;
                }
            }
        }
        String zone = timezone_name(tz);
        long wall_secs = temporal::epoch_days_from_civil(valid_d.y, (int)valid_d.m, (int)valid_d.d) * 86400
            + (long)valid_t.h * 3600 + (long)valid_t.mi * 60 + (long)valid_t.s;
        long frac_ns = (long)valid_t.ms * 1000000 + (long)valid_t.us * 1000 + (long)valid_t.ns;
        double naive_ns = (double)wall_secs * 1e9 + (double)frac_ns;
        double epoch_ns_d = naive_ns - (double)off_sec * 1e9;
        hbigint::HBigInt*? big_o = hbigint::hbigint_from_double(ctx.heap, epoch_ns_d);
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
}"""

c = c.replace(old_from, new_from)

# =====================================================================
# FIX 3: Replace equals() to check calendar too
# =====================================================================
old_equals = """fn void builtin_temporal_zoneddatetime_proto_equals(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_ZONEDDATETIME, "this is not a Temporal.ZonedDateTime")) return;
    if (ctx.argc < 1) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "equals requires an argument");
        return;
    }
    TVal* arg = arg_at(ctx, 0);
    if (!arg.is_object() || arg.get_heapptr() == null
        || ((HObject*)arg.get_heapptr()).get_class() != hobject::ObjClass.TEMPORAL_ZONEDDATETIME) {
        ctx.result.set_boolean(false);
        return;
    }
    HObject* a = (HObject*)ctx.this_val.get_heapptr();
    HObject* bb = (HObject*)arg.get_heapptr();
    // ZonedDateTime equality also requires the same time zone and calendar.
    String za = a.extra.temporal.timezone == null ? "" : timezone_name(a.extra.temporal.timezone);
    String zb = bb.extra.temporal.timezone == null ? "" : timezone_name(bb.extra.temporal.timezone);
    bool same_ns = hbigint::hbigint_cmp(a.extra.temporal.big_ns, bb.extra.temporal.big_ns) == 0;
    ctx.result.set_boolean(same_ns && za == zb);
}"""

new_equals = """fn void builtin_temporal_zoneddatetime_proto_equals(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_ZONEDDATETIME, "this is not a Temporal.ZonedDateTime")) return;
    if (ctx.argc < 1) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "equals requires an argument");
        return;
    }
    TVal* arg = arg_at(ctx, 0);
    if (!arg.is_object() || arg.get_heapptr() == null
        || ((HObject*)arg.get_heapptr()).get_class() != hobject::ObjClass.TEMPORAL_ZONEDDATETIME) {
        ctx.result.set_boolean(false);
        return;
    }
    HObject* a = (HObject*)ctx.this_val.get_heapptr();
    HObject* bb = (HObject*)arg.get_heapptr();
    String za = a.extra.temporal.timezone == null ? "" : timezone_name(a.extra.temporal.timezone);
    String zb = bb.extra.temporal.timezone == null ? "" : timezone_name(bb.extra.temporal.timezone);
    bool same_ns = hbigint::hbigint_cmp(a.extra.temporal.big_ns, bb.extra.temporal.big_ns) == 0;
    // Also compare calendar IDs.
    HString* ca = (HString*)a.extra.temporal.calendar;
    HString* cb = (HString*)bb.extra.temporal.calendar;
    bool same_cal = (ca == cb) || (ca != null && cb != null && ca.blen == cb.blen);
    if (same_cal && ca != null && cb != null) {
        same_cal = ca.get_cstr()[:ca.blen] == cb.get_cstr()[:cb.blen];
    }
    ctx.result.set_boolean(same_ns && za == zb && same_cal);
}"""

c = c.replace(old_equals, new_equals)

# =====================================================================
# FIX 4: Replace toString to handle options properly (not just pass through
#         to_string_precision which expects the first option to be a bag)
# =====================================================================
old_toString = """fn void builtin_temporal_zoneddatetime_proto_toString(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_ZONEDDATETIME, "this is not a Temporal.ZonedDateTime")) return;
    HObject* obj = (HObject*)ctx.this_val.get_heapptr();
    int digits;
    if (!to_string_precision(ctx, 0, &digits)) return;
    zdt_iso_string(ctx, obj.extra.temporal.big_ns, obj.extra.temporal.timezone, digits, false);
}"""

new_toString = """fn void builtin_temporal_zoneddatetime_proto_toString(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_ZONEDDATETIME, "this is not a Temporal.ZonedDateTime")) return;
    // Validate options bag type: must be object or undefined.
    if (ctx.argc >= 1) {
        TVal ov = ctx.regs[ctx.base_reg + 0];
        if (!ov.is_undefined()) {
            if (!ov.is_object() || ov.get_heapptr() == null) {
                builtin_throw(ctx, ctx.heap.type_err_proto, "options must be an object");
                return;
            }
        }
    }
    HObject* obj = (HObject*)ctx.this_val.get_heapptr();
    int digits;
    if (!to_string_precision(ctx, 0, &digits)) return;
    zdt_iso_string(ctx, obj.extra.temporal.big_ns, obj.extra.temporal.timezone, digits, false);
}"""

c = c.replace(old_toString, new_toString)

# =====================================================================
# FIX 5: Replace until_since to support options
# =====================================================================
old_until_since = """fn void zdt_until_since(BuiltinContext* ctx, bool until) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_ZONEDDATETIME, "this is not a Temporal.ZonedDateTime")) return;
    if (ctx.argc < 1) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "requires a Temporal.ZonedDateTime");
        return;
    }
    TVal* arg = arg_at(ctx, 0);
    if (!arg.is_object() || arg.get_heapptr() == null
        || ((HObject*)arg.get_heapptr()).get_class() != hobject::ObjClass.TEMPORAL_ZONEDDATETIME) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "argument is not a Temporal.ZonedDateTime");
        return;
    }
    HObject* self = (HObject*)ctx.this_val.get_heapptr();
    HObject* other = (HObject*)arg.get_heapptr();
    hbigint::HBigInt* a;
    hbigint::HBigInt* b;
    if (until) { a = other.extra.temporal.big_ns; b = self.extra.temporal.big_ns; }
    else       { a = self.extra.temporal.big_ns;  b = other.extra.temporal.big_ns; }
    HObject* dur;
    if (!instant_ns_diff_duration(ctx, a, b, 1000000000L, &dur)) return;
    dur.prototype = ctx.heap.temporal_duration_proto;
    ctx.result.set_object(dur);
}"""

new_until_since = """fn void zdt_until_since(BuiltinContext* ctx, bool until) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_ZONEDDATETIME, "this is not a Temporal.ZonedDateTime")) return;
    if (ctx.argc < 1) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "requires a Temporal.ZonedDateTime");
        return;
    }
    TVal* arg = arg_at(ctx, 0);
    // ToTemporalZonedDateTime: accept string, bag, or ZDT instance.
    HObject* other = null;
    if (arg.is_object() && arg.get_heapptr() != null
        && ((HObject*)arg.get_heapptr()).get_class() == hobject::ObjClass.TEMPORAL_ZONEDDATETIME) {
        other = (HObject*)arg.get_heapptr();
    } else if (arg.is_string() || (arg.is_object() && arg.get_heapptr() != null)) {
        // Use from() to convert.
        TVal saved_this = ctx.this_val;
        int saved_argc = ctx.argc;
        ctx.regs[ctx.base_reg + 0] = *arg;
        ctx.argc = 1;
        builtin_temporal_zoneddatetime_from(ctx);
        ctx.this_val = saved_this;
        ctx.argc = saved_argc;
        if (ctx.should_throw) return;
        if (!ctx.result.is_object()) {
            builtin_throw(ctx, ctx.heap.type_err_proto, "not a ZonedDateTime");
            return;
        }
        other = (HObject*)ctx.result.get_heapptr();
    } else {
        builtin_throw(ctx, ctx.heap.type_err_proto, "argument is not a Temporal.ZonedDateTime");
        return;
    }
    // Read options bag.
    temporal::DifferenceUnit largest = temporal::DifferenceUnit.SECONDS;
    if (ctx.argc >= 2) {
        if (!read_diff_options(ctx, 1, temporal::DifferenceUnit.HOURS, &largest, true)) return;
    }
    HObject* self = (HObject*)ctx.this_val.get_heapptr();
    hbigint::HBigInt* a;
    hbigint::HBigInt* b;
    if (until) { a = other.extra.temporal.big_ns; b = self.extra.temporal.big_ns; }
    else       { a = self.extra.temporal.big_ns;  b = other.extra.temporal.big_ns; }

    // Convert DifferenceUnit to largest_unit_ns for instant diff.
    long largest_unit_ns = 1000000000L;
    if (largest == temporal::DifferenceUnit.YEARS || largest == temporal::DifferenceUnit.MONTHS
        || largest == temporal::DifferenceUnit.WEEKS || largest == temporal::DifferenceUnit.DAYS) {
        largest_unit_ns = 86400000000000L;  // 1 day in ns — balance to days.
    } else if (largest == temporal::DifferenceUnit.HOURS) {
        largest_unit_ns = 3600000000000L;
    } else if (largest == temporal::DifferenceUnit.MINUTES) {
        largest_unit_ns = 60000000000L;
    } else {
        largest_unit_ns = 1000000000L;
    }

    HObject* dur;
    if (!instant_ns_diff_duration(ctx, a, b, largest_unit_ns, &dur)) return;
    dur.prototype = ctx.heap.temporal_duration_proto;
    ctx.result.set_object(dur);
}"""

c = c.replace(old_until_since, new_until_since)

# =====================================================================
# FIX 6: Add compare function after from
# =====================================================================
compare_func = """

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
    } else if (a_arg.is_string() || (a_arg.is_object() && a_arg.get_heapptr() != null)) {
        TVal saved_this = ctx.this_val;
        ctx.regs[ctx.base_reg + 0] = *a_arg;
        ctx.argc = 1;
        builtin_temporal_zoneddatetime_from(ctx);
        ctx.this_val = saved_this;
        ctx.argc = 2;
        if (ctx.should_throw) return;
        if (!ctx.result.is_object()) { builtin_throw(ctx, ctx.heap.type_err_proto, "not a ZonedDateTime"); return; }
        a_ns = ((HObject*)ctx.result.get_heapptr()).extra.temporal.big_ns;
    } else {
        builtin_throw(ctx, ctx.heap.type_err_proto, "Temporal.ZonedDateTime.compare requires ZonedDateTime arguments");
        return;
    }

    // Resolve b.
    hbigint::HBigInt* b_ns = null;
    if (b_arg.is_object() && b_arg.get_heapptr() != null
        && ((HObject*)b_arg.get_heapptr()).get_class() == hobject::ObjClass.TEMPORAL_ZONEDDATETIME) {
        b_ns = ((HObject*)b_arg.get_heapptr()).extra.temporal.big_ns;
    } else if (b_arg.is_string() || (b_arg.is_object() && b_arg.get_heapptr() != null)) {
        TVal saved_this = ctx.this_val;
        ctx.regs[ctx.base_reg + 0] = *b_arg;
        ctx.argc = 1;
        builtin_temporal_zoneddatetime_from(ctx);
        ctx.this_val = saved_this;
        ctx.argc = 2;
        if (ctx.should_throw) return;
        if (!ctx.result.is_object()) { builtin_throw(ctx, ctx.heap.type_err_proto, "not a ZonedDateTime"); return; }
        b_ns = ((HObject*)ctx.result.get_heapptr()).extra.temporal.big_ns;
    } else {
        builtin_throw(ctx, ctx.heap.type_err_proto, "Temporal.ZonedDateTime.compare requires ZonedDateTime arguments");
        return;
    }

    ctx.result.set_fastint(temporal::instant_cmp(a_ns, b_ns));
}
"""

# Insert after from() function
c = c.replace(
    '    builtin_throw(ctx, ctx.heap.type_err_proto, "Temporal.ZonedDateTime.from: argument must be a string or object");\n}',
    '    builtin_throw(ctx, ctx.heap.type_err_proto, "Temporal.ZonedDateTime.from: argument must be a string or object");\n}' + compare_func,
)

# =====================================================================
# Write
# =====================================================================
with open('src/builtins/temporal.c3', 'w') as f:
    f.write(c)

print(f"Patched temporal.c3 ({len(c)} bytes)")
