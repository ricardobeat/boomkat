// Time-zone support for Temporal. The tz database lookup itself is in
// lib/temporal/tzdb.c3; this file holds the small amount of glue the Temporal
// builtins need on top of it.
//
// There is no Temporal.TimeZone: the proposal removed it, and time zones are
// IANA name strings. Nothing here is a builtin -- a ZonedDateTime carries its
// zone and calls these directly, so none of it needs a `this`, a brand check,
// or argument coercion.
module boomkat::builtins @feat(TEMPORAL);

import boomkat::types;
import boomkat::heap;
import boomkat::hobject;
import boomkat::hbigint;
import boomkat::hstring;
import boomkat::lib::temporal;
import std::math;

// A zone is stored as a heap object holding just its IANA name, so a
// ZonedDateTime can reference one and keep it alive through GC.
fn HObject*? alloc_timezone(Heap* hp, String zone_name) {
    HObject*? raw = hp.alloc_object(hobject::ObjClass.TEMPORAL_TIMEZONE);
    if (catch err = raw) return err~;
    HObject* obj = raw;
    HString* str = builtin_intern_string(hp, zone_name);
    obj.extra.temporal.identifier.set(hp, str);
    obj.extra.temporal.timezone = null;
    return obj;
}

// The IANA zone name held by such an object.
fn String timezone_name(HObject* obj) {
    HString* str = obj.extra.temporal.identifier.borrow();
    if (str == null) return "";
    return (String)str.get_cstr()[:str.blen];
}

// Find the next (or previous) offset transition in `zone` relative to
// `start_sec`, writing its epoch second to `out`. Returns false when the zone
// has no transition in that direction, which is the caller's `null`.
//
// Only a CHANGE of offset counts as a transition; the lookups skip rule
// boundaries that preserve it.
//
// `sub_second` says the starting instant lies strictly between `start_sec` and
// the following second, which places a transition exactly at `start_sec`
// behind it in both directions.
fn bool tz_find_transition(String zone, long start_sec, bool sub_second, bool next, long* out) {
    long t = !next && !sub_second ? start_sec - 1 : start_sec;
    if (next) {
        int offset_after;
        return temporal::tzdb_next_transition(zone, t, out, &offset_after);
    }
    return temporal::tzdb_prev_transition(zone, t, out);
}
