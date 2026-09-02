// Time-zone support for Temporal. The tz database lookup itself is in
// lib/temporal/tzdb.c3; this file holds the small amount of glue the Temporal
// builtins need on top of it.
//
// There is no Temporal.TimeZone: the proposal removed it, and time zones are
// IANA name strings. Nothing here is a builtin -- a ZonedDateTime carries its
// zone and calls these directly, so none of it needs a `this`, a brand check,
// or argument coercion.
module boomkat::builtins @feat(!NO_TEMPORAL);

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
    // The name goes in the calendar slot: HObjectTemporal has no separate
    // string slot, and a calendar and a zone never coexist on one instance.
    obj.extra.temporal.calendar = (HObject*)str;
    obj.extra.temporal.timezone = null;
    return obj;
}

// The IANA zone name held by such an object.
fn String timezone_name(HObject* obj) {
    HString* str = (HString*)obj.extra.temporal.calendar;
    if (str == null) return "";
    return (String)str.get_cstr()[:str.blen];
}

// Find the next (or previous) offset transition in `zone` relative to
// `start_sec`, writing its epoch second to `out`. Returns false when the zone
// has no transition in that direction, which is the caller's `null`.
//
// A tzdb entry that repeats the offset already in effect is not a transition:
// what is observable is a CHANGE of offset, and the table records rule
// boundaries that sometimes preserve it.
//
// `sub_second` says the starting instant lies strictly between `start_sec` and
// the following second, which places a transition exactly at `start_sec`
// behind it in both directions.
fn bool tz_find_transition(String zone, long start_sec, bool sub_second, bool next, long* out) {
    temporal::TzdbTransition[] trans = temporal::tzdb_zone_transitions(zone);
    int prev_off = temporal::tzdb_zone_initial_offset(zone);
    bool found = false;
    for (usz i = 0; i < trans.len; i++) {
        if (trans[i].offset_sec == prev_off) continue;
        prev_off = trans[i].offset_sec;
        long at = trans[i].epoch_sec;
        bool after = at > start_sec || (at == start_sec && sub_second);
        if (next) {
            // Transitions are in ascending order, so the first one past the
            // start is the answer.
            if (after) { *out = at; return true; }
        } else if (!after) {
            // Keep overwriting to end with the latest one before the start.
            *out = at;
            found = true;
        }
    }
    return found;
}
