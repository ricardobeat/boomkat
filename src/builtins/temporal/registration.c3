// Temporal namespace and prototype registration: the setUpTemporal*
// functions that install constructors, prototypes, and their property
// descriptors on the global object.
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



// The prototype-and-constructor pair every Temporal type needs.
//
// Each setUpTemporal* function opened with the same 34 lines: allocate the
// prototype, hang @@toStringTag on it, allocate the constructor, cross-link
// .constructor and .prototype, set .length and .name, and finally stash the
// prototype on the heap. Only four things varied -- the tag string, the
// constructor's builtin ordinal, its arity, and its name -- so this macro
// takes those four and the body installs the type's own members.
//
// The trailing @body block is what makes this a macro rather than a pair of
// helper functions: the ceremony brackets the member list, so a function
// would have to split into a "begin" and an "end" the caller is responsible
// for pairing. A `return false` inside the body returns from the calling
// setUpTemporal* function and skips the epilogue, which is exactly what the
// straight-line code did. (Control flow written in a macro's own statements
// cannot do this; a trailing @body block is inlined at the call site's own
// scope. See @bitop in src/vm/vm_execute.c3 for the same mechanism.)
macro bool @constructor_pair(Heap* heap, String $tag, TemporalBuiltin $ctor_builtin,
                             int $arity, String $name, HObject** out_proto;
                             @body(HObject* proto, HObject* ctor)) {
    HObject*? proto_raw = heap.alloc_object(hobject::ObjClass.OBJECT);
    if (catch err = proto_raw) return false;
    HObject* proto = proto_raw;
    heap.set_prototype(proto, heap.object_proto);

    HString* tag_key = ensure_tostringtag_symbol(heap);
    if (tag_key != null) {
        TVal tag_tv;
        tag_tv.set_string_borrowed(builtin_intern_string(heap, $tag));
        proto.put_prop(tag_key, tag_tv, hobject::PROP_FLAGS_NWC, heap);
    }

    HObject*? ctor_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
    if (catch err = ctor_raw) return false;
    HObject* ctor = ctor_raw;
    heap.set_prototype(ctor, heap.function_proto);
    ctor.flags.constructable = true;
    (*ctor.extra_ptr()).func.builtin_fn_index = (int)temporal_index($ctor_builtin);

    HString* constructor_key = (HString*)heap.strs[heap::BuiltinStr.CONSTRUCTOR];
    TVal constructor_tv;
    constructor_tv.set_object(ctor);
    proto.put_prop(constructor_key, constructor_tv, hobject::PROP_FLAGS_WC, heap);

    HString* prototype_key = (HString*)heap.strs[heap::BuiltinStr.PROTOTYPE];
    TVal proto_tv;
    proto_tv.set_object(proto);
    PropFlags proto_pflags;
    proto_pflags.writable = false;
    proto_pflags.enumerable = false;
    proto_pflags.configurable = false;
    proto_pflags.is_accessor = false;
    ctor.put_prop(prototype_key, proto_tv, proto_pflags, heap);

    HString* length_key = (HString*)heap.strs[heap::BuiltinStr.LENGTH];
    TVal length_tv;
    length_tv.set_fastint($arity);
    ctor.put_prop(length_key, length_tv, hobject::PROP_FLAGS_NWC, heap);

    set_func_ctor_name(ctor, heap, $name);

    @body(proto, ctor);

    *out_proto = proto;
    return true;
}

// ============================================================================
// Registration
// ============================================================================

fn bool setUpTemporalDuration(Heap* heap) {
    return @constructor_pair(heap, "Temporal.Duration", TemporalBuiltin.DURATION_CTOR,
                             0, "Duration", &heap.temporal_duration_proto;
                             HObject* proto, HObject* ctor) {
        {
            const uint[*] MEMBERS = {
                TEMPORAL_BASE + TemporalBuiltin.DURATION_PROTO_YEARS.ordinal,
                TEMPORAL_BASE + TemporalBuiltin.DURATION_PROTO_MONTHS.ordinal,
                TEMPORAL_BASE + TemporalBuiltin.DURATION_PROTO_WEEKS.ordinal,
                TEMPORAL_BASE + TemporalBuiltin.DURATION_PROTO_DAYS.ordinal,
                TEMPORAL_BASE + TemporalBuiltin.DURATION_PROTO_HOURS.ordinal,
                TEMPORAL_BASE + TemporalBuiltin.DURATION_PROTO_MINUTES.ordinal,
                TEMPORAL_BASE + TemporalBuiltin.DURATION_PROTO_SECONDS.ordinal,
                TEMPORAL_BASE + TemporalBuiltin.DURATION_PROTO_MILLISECONDS.ordinal,
                TEMPORAL_BASE + TemporalBuiltin.DURATION_PROTO_MICROSECONDS.ordinal,
                TEMPORAL_BASE + TemporalBuiltin.DURATION_PROTO_NANOSECONDS.ordinal,
                TEMPORAL_BASE + TemporalBuiltin.DURATION_PROTO_SIGN.ordinal,
                TEMPORAL_BASE + TemporalBuiltin.DURATION_PROTO_BLANK.ordinal,
            };
            if (!register_builtin_members(proto, heap, MEMBERS[..], GETTER)) return false;
        }
        {
            const uint[*] MEMBERS = {
                TEMPORAL_BASE + TemporalBuiltin.DURATION_PROTO_NEGATED.ordinal,
                TEMPORAL_BASE + TemporalBuiltin.DURATION_PROTO_ABS.ordinal,
                TEMPORAL_BASE + TemporalBuiltin.DURATION_PROTO_TOSTRING.ordinal,
                TEMPORAL_BASE + TemporalBuiltin.DURATION_PROTO_TOJSON.ordinal,
                TEMPORAL_BASE + TemporalBuiltin.DURATION_PROTO_TOLOCALESTRING.ordinal,
                TEMPORAL_BASE + TemporalBuiltin.DURATION_PROTO_VALUEOF.ordinal,
                TEMPORAL_BASE + TemporalBuiltin.DURATION_PROTO_ADD.ordinal,
                TEMPORAL_BASE + TemporalBuiltin.DURATION_PROTO_SUBTRACT.ordinal,
                TEMPORAL_BASE + TemporalBuiltin.DURATION_PROTO_WITH.ordinal,
                TEMPORAL_BASE + TemporalBuiltin.DURATION_PROTO_ROUND.ordinal,
                TEMPORAL_BASE + TemporalBuiltin.DURATION_PROTO_TOTAL.ordinal,
            };
            if (!register_builtin_members(proto, heap, MEMBERS[..])) return false;
        }
        {
            const uint[*] MEMBERS = {
                TEMPORAL_BASE + TemporalBuiltin.DURATION_FROM.ordinal,
                TEMPORAL_BASE + TemporalBuiltin.DURATION_COMPARE.ordinal,
            };
            if (!register_builtin_members(ctor, heap, MEMBERS[..])) return false;
        }
    };
}

fn bool setUpTemporalPlainDate(Heap* heap) {
    return @constructor_pair(heap, "Temporal.PlainDate", TemporalBuiltin.PLAIN_DATE_CTOR,
                             3, "PlainDate", &heap.temporal_plain_date_proto;
                             HObject* proto, HObject* ctor) {
        {
            const uint[*] MEMBERS = {
                TEMPORAL_BASE + TemporalBuiltin.PLAIN_DATE_PROTO_YEAR.ordinal,
                TEMPORAL_BASE + TemporalBuiltin.PLAIN_DATE_PROTO_MONTH.ordinal,
                TEMPORAL_BASE + TemporalBuiltin.PLAIN_DATE_PROTO_DAY.ordinal,
                TEMPORAL_BASE + TemporalBuiltin.PLAIN_DATE_PROTO_DAYOFWEEK.ordinal,
                TEMPORAL_BASE + TemporalBuiltin.PLAIN_DATE_PROTO_DAYOFYEAR.ordinal,
                TEMPORAL_BASE + TemporalBuiltin.PLAIN_DATE_PROTO_MONTHCODE.ordinal,
                TEMPORAL_BASE + TemporalBuiltin.PLAIN_DATE_PROTO_INLEAPYEAR.ordinal,
                TEMPORAL_BASE + TemporalBuiltin.PLAIN_DATE_PROTO_CALENDARID.ordinal,
                TEMPORAL_BASE + TemporalBuiltin.PLAIN_DATE_PROTO_ERA.ordinal,
                TEMPORAL_BASE + TemporalBuiltin.PLAIN_DATE_PROTO_ERAYEAR.ordinal,
                TEMPORAL_BASE + TemporalBuiltin.PLAIN_DATE_PROTO_DAYSINMONTH.ordinal,
                TEMPORAL_BASE + TemporalBuiltin.PLAIN_DATE_PROTO_DAYSINWEEK.ordinal,
                TEMPORAL_BASE + TemporalBuiltin.PLAIN_DATE_PROTO_DAYSINYEAR.ordinal,
                TEMPORAL_BASE + TemporalBuiltin.PLAIN_DATE_PROTO_MONTHSINYEAR.ordinal,
                TEMPORAL_BASE + TemporalBuiltin.PLAIN_DATE_PROTO_WEEKOFYEAR.ordinal,
                TEMPORAL_BASE + TemporalBuiltin.PLAIN_DATE_PROTO_YEAROFWEEK.ordinal,
            };
            if (!register_builtin_members(proto, heap, MEMBERS[..], GETTER)) return false;
        }
        {
            const uint[*] MEMBERS = {
                TEMPORAL_BASE + TemporalBuiltin.PLAIN_DATE_PROTO_VALUEOF.ordinal,
                TEMPORAL_BASE + TemporalBuiltin.PLAIN_DATE_PROTO_TOSTRING.ordinal,
                TEMPORAL_BASE + TemporalBuiltin.PLAIN_DATE_PROTO_TOJSON.ordinal,
                TEMPORAL_BASE + TemporalBuiltin.PLAIN_DATE_PROTO_TOLOCALESTRING.ordinal,
                TEMPORAL_BASE + TemporalBuiltin.PLAIN_DATE_PROTO_EQUALS.ordinal,
                TEMPORAL_BASE + TemporalBuiltin.PLAIN_DATE_PROTO_WITH.ordinal,
                TEMPORAL_BASE + TemporalBuiltin.PLAIN_DATE_PROTO_ADD.ordinal,
                TEMPORAL_BASE + TemporalBuiltin.PLAIN_DATE_PROTO_SUBTRACT.ordinal,
                TEMPORAL_BASE + TemporalBuiltin.PLAIN_DATE_PROTO_UNTIL.ordinal,
                TEMPORAL_BASE + TemporalBuiltin.PLAIN_DATE_PROTO_SINCE.ordinal,
                TEMPORAL_BASE + TemporalBuiltin.PLAIN_DATE_PROTO_WITHCALENDAR.ordinal,
                TEMPORAL_BASE + TemporalBuiltin.PLAIN_DATE_PROTO_TOPLAINDATETIME.ordinal,
                TEMPORAL_BASE + TemporalBuiltin.PLAIN_DATE_PROTO_TOZONEDDATETIME.ordinal,
                TEMPORAL_BASE + TemporalBuiltin.PLAIN_DATE_PROTO_TOPLAINYEARMONTH.ordinal,
                TEMPORAL_BASE + TemporalBuiltin.PLAIN_DATE_PROTO_TOPLAINMONTHDAY.ordinal,
            };
            if (!register_builtin_members(proto, heap, MEMBERS[..])) return false;
        }

        {
            const uint[*] MEMBERS = {
                TEMPORAL_BASE + TemporalBuiltin.PLAIN_DATE_FROM.ordinal,
                TEMPORAL_BASE + TemporalBuiltin.PLAIN_DATE_COMPARE.ordinal,
            };
            if (!register_builtin_members(ctor, heap, MEMBERS[..])) return false;
        }
    };
}

fn bool setUpTemporalPlainTime(Heap* heap) {
    return @constructor_pair(heap, "Temporal.PlainTime", TemporalBuiltin.PLAIN_TIME_CTOR,
                             0, "PlainTime", &heap.temporal_plain_time_proto;
                             HObject* proto, HObject* ctor) {
        {
            const uint[*] MEMBERS = {
                TEMPORAL_BASE + TemporalBuiltin.PLAIN_TIME_PROTO_HOUR.ordinal,
                TEMPORAL_BASE + TemporalBuiltin.PLAIN_TIME_PROTO_MINUTE.ordinal,
                TEMPORAL_BASE + TemporalBuiltin.PLAIN_TIME_PROTO_SECOND.ordinal,
                TEMPORAL_BASE + TemporalBuiltin.PLAIN_TIME_PROTO_MILLISECOND.ordinal,
                TEMPORAL_BASE + TemporalBuiltin.PLAIN_TIME_PROTO_MICROSECOND.ordinal,
                TEMPORAL_BASE + TemporalBuiltin.PLAIN_TIME_PROTO_NANOSECOND.ordinal,
            };
            if (!register_builtin_members(proto, heap, MEMBERS[..], GETTER)) return false;
        }
        {
            const uint[*] MEMBERS = {
                TEMPORAL_BASE + TemporalBuiltin.PLAIN_TIME_PROTO_VALUEOF.ordinal,
                TEMPORAL_BASE + TemporalBuiltin.PLAIN_TIME_PROTO_TOSTRING.ordinal,
                TEMPORAL_BASE + TemporalBuiltin.PLAIN_TIME_PROTO_TOJSON.ordinal,
                TEMPORAL_BASE + TemporalBuiltin.PLAIN_TIME_PROTO_TOLOCALESTRING.ordinal,
                TEMPORAL_BASE + TemporalBuiltin.PLAIN_TIME_PROTO_EQUALS.ordinal,
                TEMPORAL_BASE + TemporalBuiltin.PLAIN_TIME_PROTO_WITH.ordinal,
                TEMPORAL_BASE + TemporalBuiltin.PLAIN_TIME_PROTO_ADD.ordinal,
                TEMPORAL_BASE + TemporalBuiltin.PLAIN_TIME_PROTO_SUBTRACT.ordinal,
                TEMPORAL_BASE + TemporalBuiltin.PLAIN_TIME_PROTO_UNTIL.ordinal,
                TEMPORAL_BASE + TemporalBuiltin.PLAIN_TIME_PROTO_SINCE.ordinal,
                TEMPORAL_BASE + TemporalBuiltin.PLAIN_TIME_PROTO_ROUND.ordinal,
            };
            if (!register_builtin_members(proto, heap, MEMBERS[..])) return false;
        }

        {
            const uint[*] MEMBERS = {
                TEMPORAL_BASE + TemporalBuiltin.PLAIN_TIME_FROM.ordinal,
                TEMPORAL_BASE + TemporalBuiltin.PLAIN_TIME_COMPARE.ordinal,
            };
            if (!register_builtin_members(ctor, heap, MEMBERS[..])) return false;
        }
    };
}

fn bool setUpTemporalPlainDateTime(Heap* heap) {
    return @constructor_pair(heap, "Temporal.PlainDateTime", TemporalBuiltin.PLAIN_DATETIME_CTOR,
                             3, "PlainDateTime", &heap.temporal_plain_datetime_proto;
                             HObject* proto, HObject* ctor) {
        {
            const uint[*] MEMBERS = {
                TEMPORAL_BASE + TemporalBuiltin.PLAIN_DATETIME_PROTO_YEAR.ordinal,
                TEMPORAL_BASE + TemporalBuiltin.PLAIN_DATETIME_PROTO_MONTH.ordinal,
                TEMPORAL_BASE + TemporalBuiltin.PLAIN_DATETIME_PROTO_DAY.ordinal,
                TEMPORAL_BASE + TemporalBuiltin.PLAIN_DATETIME_PROTO_HOUR.ordinal,
                TEMPORAL_BASE + TemporalBuiltin.PLAIN_DATETIME_PROTO_MINUTE.ordinal,
                TEMPORAL_BASE + TemporalBuiltin.PLAIN_DATETIME_PROTO_SECOND.ordinal,
                TEMPORAL_BASE + TemporalBuiltin.PLAIN_DATETIME_PROTO_MILLISECOND.ordinal,
                TEMPORAL_BASE + TemporalBuiltin.PLAIN_DATETIME_PROTO_MICROSECOND.ordinal,
                TEMPORAL_BASE + TemporalBuiltin.PLAIN_DATETIME_PROTO_NANOSECOND.ordinal,
                TEMPORAL_BASE + TemporalBuiltin.PLAIN_DATETIME_PROTO_CALENDARID.ordinal,
                TEMPORAL_BASE + TemporalBuiltin.PLAIN_DATETIME_PROTO_DAYOFWEEK.ordinal,
                TEMPORAL_BASE + TemporalBuiltin.PLAIN_DATETIME_PROTO_DAYOFYEAR.ordinal,
                TEMPORAL_BASE + TemporalBuiltin.PLAIN_DATETIME_PROTO_MONTHCODE.ordinal,
                TEMPORAL_BASE + TemporalBuiltin.PLAIN_DATETIME_PROTO_ERA.ordinal,
                TEMPORAL_BASE + TemporalBuiltin.PLAIN_DATETIME_PROTO_ERAYEAR.ordinal,
                TEMPORAL_BASE + TemporalBuiltin.PLAIN_DATETIME_PROTO_INLEAPYEAR.ordinal,
                TEMPORAL_BASE + TemporalBuiltin.PLAIN_DATETIME_PROTO_DAYSINMONTH.ordinal,
                TEMPORAL_BASE + TemporalBuiltin.PLAIN_DATETIME_PROTO_DAYSINWEEK.ordinal,
                TEMPORAL_BASE + TemporalBuiltin.PLAIN_DATETIME_PROTO_DAYSINYEAR.ordinal,
                TEMPORAL_BASE + TemporalBuiltin.PLAIN_DATETIME_PROTO_MONTHSINYEAR.ordinal,
                TEMPORAL_BASE + TemporalBuiltin.PLAIN_DATETIME_PROTO_WEEKOFYEAR.ordinal,
                TEMPORAL_BASE + TemporalBuiltin.PLAIN_DATETIME_PROTO_YEAROFWEEK.ordinal,
            };
            if (!register_builtin_members(proto, heap, MEMBERS[..], GETTER)) return false;
        }
        {
            const uint[*] MEMBERS = {
                TEMPORAL_BASE + TemporalBuiltin.PLAIN_DATETIME_PROTO_VALUEOF.ordinal,
                TEMPORAL_BASE + TemporalBuiltin.PLAIN_DATETIME_PROTO_TOSTRING.ordinal,
                TEMPORAL_BASE + TemporalBuiltin.PLAIN_DATETIME_PROTO_TOJSON.ordinal,
                TEMPORAL_BASE + TemporalBuiltin.PLAIN_DATETIME_PROTO_TOLOCALESTRING.ordinal,
                TEMPORAL_BASE + TemporalBuiltin.PLAIN_DATETIME_PROTO_EQUALS.ordinal,
                TEMPORAL_BASE + TemporalBuiltin.PLAIN_DATETIME_PROTO_WITH.ordinal,
                TEMPORAL_BASE + TemporalBuiltin.PLAIN_DATETIME_PROTO_ADD.ordinal,
                TEMPORAL_BASE + TemporalBuiltin.PLAIN_DATETIME_PROTO_SUBTRACT.ordinal,
                TEMPORAL_BASE + TemporalBuiltin.PLAIN_DATETIME_PROTO_UNTIL.ordinal,
                TEMPORAL_BASE + TemporalBuiltin.PLAIN_DATETIME_PROTO_SINCE.ordinal,
                TEMPORAL_BASE + TemporalBuiltin.PLAIN_DATETIME_PROTO_WITHCALENDAR.ordinal,
                TEMPORAL_BASE + TemporalBuiltin.PLAIN_DATETIME_PROTO_ROUND.ordinal,
                TEMPORAL_BASE + TemporalBuiltin.PLAIN_DATETIME_PROTO_WITHPLAINTIME.ordinal,
                TEMPORAL_BASE + TemporalBuiltin.PLAIN_DATETIME_PROTO_TOZONEDDATETIME.ordinal,
                TEMPORAL_BASE + TemporalBuiltin.PLAIN_DATETIME_PROTO_TOPLAINDATE.ordinal,
                TEMPORAL_BASE + TemporalBuiltin.PLAIN_DATETIME_PROTO_TOPLAINTIME.ordinal,
            };
            if (!register_builtin_members(proto, heap, MEMBERS[..])) return false;
        }

        {
            const uint[*] MEMBERS = {
                TEMPORAL_BASE + TemporalBuiltin.PLAIN_DATETIME_FROM.ordinal,
                TEMPORAL_BASE + TemporalBuiltin.PLAIN_DATETIME_COMPARE.ordinal,
            };
            if (!register_builtin_members(ctor, heap, MEMBERS[..])) return false;
        }
    };
}

fn bool setUpTemporalPlainYearMonth(Heap* heap) {
    return @constructor_pair(heap, "Temporal.PlainYearMonth", TemporalBuiltin.PLAIN_YEARMONTH_CTOR,
                             2, "PlainYearMonth", &heap.temporal_plain_yearmonth_proto;
                             HObject* proto, HObject* ctor) {
        if (!register_proto_getter_accessor(proto, heap, "year", temporal_index(TemporalBuiltin.PLAIN_YEARMONTH_PROTO_YEAR))) return false;
        if (!register_proto_getter_accessor(proto, heap, "month", temporal_index(TemporalBuiltin.PLAIN_YEARMONTH_PROTO_MONTH))) return false;
        if (!register_proto_getter_accessor(proto, heap, "monthCode", temporal_index(TemporalBuiltin.PLAIN_YEARMONTH_PROTO_MONTHCODE))) return false;
        if (!register_proto_getter_accessor(proto, heap, "daysInYear", temporal_index(TemporalBuiltin.PLAIN_YEARMONTH_PROTO_DAYSINYEAR))) return false;
        if (!register_proto_getter_accessor(proto, heap, "daysInMonth", temporal_index(TemporalBuiltin.PLAIN_YEARMONTH_PROTO_DAYSINMONTH))) return false;
        if (!register_proto_getter_accessor(proto, heap, "monthsInYear", temporal_index(TemporalBuiltin.PLAIN_YEARMONTH_PROTO_MONTHSINYEAR))) return false;
        if (!register_proto_getter_accessor(proto, heap, "inLeapYear", temporal_index(TemporalBuiltin.PLAIN_YEARMONTH_PROTO_INLEAPYEAR))) return false;
        if (!register_proto_getter_accessor(proto, heap, "era", temporal_index(TemporalBuiltin.PLAIN_YEARMONTH_PROTO_ERA))) return false;
        if (!register_proto_getter_accessor(proto, heap, "eraYear", temporal_index(TemporalBuiltin.PLAIN_YEARMONTH_PROTO_ERAYEAR))) return false;
        if (!register_proto_getter_accessor(proto, heap, "calendarId", temporal_index(TemporalBuiltin.PLAIN_YEARMONTH_PROTO_CALENDARID))) return false;
        if (!register_proto_method(proto, heap, "toString", temporal_index(TemporalBuiltin.PLAIN_YEARMONTH_PROTO_TOSTRING))) return false;
        if (!register_proto_method(proto, heap, "toJSON", temporal_index(TemporalBuiltin.PLAIN_YEARMONTH_PROTO_TOJSON))) return false;
        if (!register_proto_method(proto, heap, "toLocaleString", temporal_index(TemporalBuiltin.PLAIN_YEARMONTH_PROTO_TOLOCALESTRING))) return false;
        if (!register_proto_method(proto, heap, "valueOf", temporal_index(TemporalBuiltin.PLAIN_YEARMONTH_PROTO_VALUEOF))) return false;
        if (!register_proto_method(proto, heap, "with", temporal_index(TemporalBuiltin.PLAIN_YEARMONTH_PROTO_WITH))) return false;
        if (!register_proto_method(proto, heap, "equals", temporal_index(TemporalBuiltin.PLAIN_YEARMONTH_PROTO_EQUALS))) return false;
        if (!register_proto_method(proto, heap, "add", temporal_index(TemporalBuiltin.PLAIN_YEARMONTH_PROTO_ADD))) return false;
        if (!register_proto_method(proto, heap, "subtract", temporal_index(TemporalBuiltin.PLAIN_YEARMONTH_PROTO_SUBTRACT))) return false;
        if (!register_proto_method(proto, heap, "until", temporal_index(TemporalBuiltin.PLAIN_YEARMONTH_PROTO_UNTIL))) return false;
        if (!register_proto_method(proto, heap, "since", temporal_index(TemporalBuiltin.PLAIN_YEARMONTH_PROTO_SINCE))) return false;
        if (!register_proto_method(proto, heap, "toPlainDate", temporal_index(TemporalBuiltin.PLAIN_YEARMONTH_PROTO_TOPLAINDATE))) return false;

        {
            const uint[*] MEMBERS = {
                TEMPORAL_BASE + TemporalBuiltin.PLAIN_YEARMONTH_FROM.ordinal,
                TEMPORAL_BASE + TemporalBuiltin.PLAIN_YEARMONTH_COMPARE.ordinal,
            };
            if (!register_builtin_members(ctor, heap, MEMBERS[..])) return false;
        }
    };
}

fn bool setUpTemporalPlainMonthDay(Heap* heap) {
    return @constructor_pair(heap, "Temporal.PlainMonthDay", TemporalBuiltin.PLAIN_MONTHDAY_CTOR,
                             2, "PlainMonthDay", &heap.temporal_plain_monthday_proto;
                             HObject* proto, HObject* ctor) {
        if (!register_proto_getter_accessor(proto, heap, "monthCode", temporal_index(TemporalBuiltin.PLAIN_MONTHDAY_PROTO_MONTHCODE))) return false;
        if (!register_proto_getter_accessor(proto, heap, "day", temporal_index(TemporalBuiltin.PLAIN_MONTHDAY_PROTO_DAY))) return false;
        if (!register_proto_getter_accessor(proto, heap, "calendarId", temporal_index(TemporalBuiltin.PLAIN_MONTHDAY_PROTO_CALENDARID))) return false;
        if (!register_proto_method(proto, heap, "valueOf", temporal_index(TemporalBuiltin.PLAIN_MONTHDAY_PROTO_VALUEOF))) return false;
        if (!register_proto_method(proto, heap, "toString", temporal_index(TemporalBuiltin.PLAIN_MONTHDAY_PROTO_TOSTRING))) return false;
        if (!register_proto_method(proto, heap, "toJSON", temporal_index(TemporalBuiltin.PLAIN_MONTHDAY_PROTO_TOJSON))) return false;
        if (!register_proto_method(proto, heap, "toLocaleString", temporal_index(TemporalBuiltin.PLAIN_MONTHDAY_PROTO_TOLOCALESTRING))) return false;
        if (!register_proto_method(proto, heap, "equals", temporal_index(TemporalBuiltin.PLAIN_MONTHDAY_PROTO_EQUALS))) return false;
        if (!register_proto_method(proto, heap, "with", temporal_index(TemporalBuiltin.PLAIN_MONTHDAY_PROTO_WITH))) return false;
        if (!register_proto_method(proto, heap, "toPlainDate", temporal_index(TemporalBuiltin.PLAIN_MONTHDAY_PROTO_TOPLAINDATE))) return false;

        if (!register_proto_method(ctor, heap, "from", temporal_index(TemporalBuiltin.PLAIN_MONTHDAY_FROM))) return false;
    };
}

fn bool setUpTemporalNamespace(EnvRecord* global_env, Heap* heap) {
    if (!setUpTemporalInstant(heap)) return false;
    if (!setUpTemporalZonedDateTime(heap)) return false;
    HObject*? ns_raw = heap.alloc_object(hobject::ObjClass.OBJECT);
    if (catch err = ns_raw) return false;
    HObject* ns = ns_raw;
    heap.set_prototype(ns, heap.object_proto);

    HString* tag_key = ensure_tostringtag_symbol(heap);
    if (tag_key != null) {
        TVal tag_tv;
        tag_tv.set_string_borrowed(builtin_intern_string(heap, "Temporal"));
        ns.put_prop(tag_key, tag_tv, hobject::PROP_FLAGS_NWC, heap);
    }

    // getOwnPropertyNames for the namespace must include every public name,
    // even the types that have not landed yet; they surface as undefined
    // values (non-enumerable) so no test observes a gap.
    char[][] stub_names = {};
    for (uint k = 0; k < stub_names.len; k++) {
        HString* key = heap.str_intern(stub_names[k]);
        if (key == null) return false;
        TVal undef;
        undef.set_undefined();
        ns.put_prop(key, undef, hobject::PROP_FLAGS_NWC, heap);
    }
    // Temporal.Now object (Phase 3): non-constructable namespace with the six
    // current-clock methods attached. Build before wiring so a failure is
    // surfaced up here rather than as a missing property later.
    HObject*? now_obj_o = build_temporal_now(heap);
    if (catch err_n = now_obj_o) return false;
    HObject* now_obj = now_obj_o;
    HString* now_key = heap.str_intern("Now");
    if (now_key == null) return false;
    TVal now_tv;
    now_tv.set_object(now_obj);
    ns.put_prop(now_key, now_tv, hobject::PROP_FLAGS_WC, heap);

    // Real constructors: PlainDate, Calendar, Duration, PlainTime, PlainDateTime,
    // PlainYearMonth, PlainMonthDay.
    // The namespace wiring walks back through each prototype's .constructor property.
    HString* ctor_key = (HString*)heap.strs[heap::BuiltinStr.CONSTRUCTOR];
    TVal undef;
    undef.set_undefined();

    // Temporal.Calendar and Temporal.TimeZone are deliberately NOT exposed:
    // the proposal removed both in favour of calendar/timeZone string IDs
    // (staging/Temporal/removed-methods). Their prototypes and builtins remain
    // registered because the engine still uses them internally -- ZonedDateTime
    // reaches the timezone prototype's transition helpers directly.

    HString* pd_prop_key = builtin_intern_string(heap, "PlainDate");
    TVal ctor_tv = heap.temporal_plain_date_proto.get_prop((void*)ctor_key, heap) ?? undef;
    if (ctor_tv.is_object() && ctor_tv.get_heapptr() != null) {
        ns.put_prop(pd_prop_key, ctor_tv, hobject::PROP_FLAGS_WC, heap);
    }

    HString* dur_key = builtin_intern_string(heap, "Duration");
    TVal dur_ctor = heap.temporal_duration_proto.get_prop((void*)ctor_key, heap) ?? undef;
    if (dur_ctor.is_object() && dur_ctor.get_heapptr() != null) {
        ns.put_prop(dur_key, dur_ctor, hobject::PROP_FLAGS_WC, heap);
    }

    HString* pt_key = builtin_intern_string(heap, "PlainTime");
    TVal pt_ctor = heap.temporal_plain_time_proto.get_prop((void*)ctor_key, heap) ?? undef;
    if (pt_ctor.is_object() && pt_ctor.get_heapptr() != null) {
        ns.put_prop(pt_key, pt_ctor, hobject::PROP_FLAGS_WC, heap);
    }

    HString* pdt_key = builtin_intern_string(heap, "PlainDateTime");
    TVal pdt_ctor = heap.temporal_plain_datetime_proto.get_prop((void*)ctor_key, heap) ?? undef;
    if (pdt_ctor.is_object() && pdt_ctor.get_heapptr() != null) {
        ns.put_prop(pdt_key, pdt_ctor, hobject::PROP_FLAGS_WC, heap);
    }

    HString* pym_key = builtin_intern_string(heap, "PlainYearMonth");
    TVal pym_ctor = heap.temporal_plain_yearmonth_proto.get_prop((void*)ctor_key, heap) ?? undef;
    if (pym_ctor.is_object() && pym_ctor.get_heapptr() != null) {
        ns.put_prop(pym_key, pym_ctor, hobject::PROP_FLAGS_WC, heap);
    }

    HString* pmd_key = builtin_intern_string(heap, "PlainMonthDay");
    TVal pmd_ctor = heap.temporal_plain_monthday_proto.get_prop((void*)ctor_key, heap) ?? undef;
    if (pmd_ctor.is_object() && pmd_ctor.get_heapptr() != null) {
        ns.put_prop(pmd_key, pmd_ctor, hobject::PROP_FLAGS_WC, heap);
    }

    HString* inst_key = builtin_intern_string(heap, "Instant");
    TVal inst_ctor = heap.temporal_instant_proto.get_prop((void*)ctor_key, heap) ?? undef;
    if (inst_ctor.is_object() && inst_ctor.get_heapptr() != null) {
        ns.put_prop(inst_key, inst_ctor, hobject::PROP_FLAGS_WC, heap);
    }

    HString* zdt_key = builtin_intern_string(heap, "ZonedDateTime");
    TVal zdt_ctor = heap.temporal_zoneddatetime_proto.get_prop((void*)ctor_key, heap) ?? undef;
    if (zdt_ctor.is_object() && zdt_ctor.get_heapptr() != null) {
        ns.put_prop(zdt_key, zdt_ctor, hobject::PROP_FLAGS_WC, heap);
    }

    TVal ns_tv;
    ns_tv.set_object(ns);
    HString* t_key = heap.str_intern("Temporal");
    if (t_key == null) return false;
    env::env_declare_nonenum(global_env, t_key, ns_tv);

    return true;
}

// ============================================================================
// Phase 2 — setUpTemporal* registration functions
// ============================================================================

fn bool setUpTemporalInstant(Heap* heap) {
    return @constructor_pair(heap, "Temporal.Instant", TemporalBuiltin.INSTANT_CTOR,
                             1, "Instant", &heap.temporal_instant_proto;
                             HObject* proto, HObject* ctor) {
        {
            const uint[*] MEMBERS = {
                TEMPORAL_BASE + TemporalBuiltin.INSTANT_PROTO_EPOCHMILLISECONDS.ordinal,
                TEMPORAL_BASE + TemporalBuiltin.INSTANT_PROTO_EPOCHNANOSECONDS.ordinal,
            };
            if (!register_builtin_members(proto, heap, MEMBERS[..], GETTER)) return false;
        }
        {
            const uint[*] MEMBERS = {
                TEMPORAL_BASE + TemporalBuiltin.INSTANT_PROTO_TOSTRING.ordinal,
                TEMPORAL_BASE + TemporalBuiltin.INSTANT_PROTO_TOJSON.ordinal,
                TEMPORAL_BASE + TemporalBuiltin.INSTANT_PROTO_TOLOCALESTRING.ordinal,
                TEMPORAL_BASE + TemporalBuiltin.INSTANT_PROTO_VALUEOF.ordinal,
                TEMPORAL_BASE + TemporalBuiltin.INSTANT_PROTO_EQUALS.ordinal,
                TEMPORAL_BASE + TemporalBuiltin.INSTANT_PROTO_ADD.ordinal,
                TEMPORAL_BASE + TemporalBuiltin.INSTANT_PROTO_SUBTRACT.ordinal,
                TEMPORAL_BASE + TemporalBuiltin.INSTANT_PROTO_ROUND.ordinal,
                TEMPORAL_BASE + TemporalBuiltin.INSTANT_PROTO_SINCE.ordinal,
                TEMPORAL_BASE + TemporalBuiltin.INSTANT_PROTO_UNTIL.ordinal,
                TEMPORAL_BASE + TemporalBuiltin.INSTANT_PROTO_TOZONEDDATETIMEISO.ordinal,
            };
            if (!register_builtin_members(proto, heap, MEMBERS[..])) return false;
        }
        {
            const uint[*] MEMBERS = {
                TEMPORAL_BASE + TemporalBuiltin.INSTANT_FROM.ordinal,
                TEMPORAL_BASE + TemporalBuiltin.INSTANT_FROM_EPOCH_MILLISECONDS.ordinal,
                TEMPORAL_BASE + TemporalBuiltin.INSTANT_FROM_EPOCH_NANOSECONDS.ordinal,
                TEMPORAL_BASE + TemporalBuiltin.INSTANT_COMPARE.ordinal,
            };
            if (!register_builtin_members(ctor, heap, MEMBERS[..])) return false;
        }
    };
}


