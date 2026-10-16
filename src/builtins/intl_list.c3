// Intl.ListFormat (ECMA-402 §13) for English. Each type/style pair has the CLDR
// en patterns for a two-element list and for the start, middle and end of a
// longer one.
module boomkat::builtins;
import boomkat::types;
import boomkat::heap;
import boomkat::hobject;
import boomkat::hstring;

struct IntlListState {
    IntlPayloadHead head; // bound function slot read by intl_mark; unused by this service
    bool us_locale;
    int type;  // conjunction, disjunction, unit
    int style; // long, short, narrow
}

struct IntlListPattern {
    String pair;
    String start;
    String middle;
    String end;
}

// Indexed [type * 3 + style].
const IntlListPattern[9] INTL_LIST_PATTERNS = {
    { " and ", ", ", ", ", ", and " },
    { " & ", ", ", ", ", ", & " },
    { ", ", ", ", ", ", ", " },
    { " or ", ", ", ", ", ", or " },
    { " or ", ", ", ", ", ", or " },
    { " or ", ", ", ", ", ", or " },
    { ", ", ", ", ", ", ", " },
    { ", ", ", ", ", ", ", " },
    { " ", " ", " ", " " },
};

const String INTL_LIST_CLASS = "Intl.ListFormat";

fn IntlListState* intl_list_receiver(BuiltinContext* ctx) {
    TVal v = ctx.regs[ctx.base_reg - 1];
    if (v.is_object()) {
        HObject* obj = (HObject*)v.get_heapptr();
        if (obj != null && obj.get_class() == ObjClass.HOST &&
            (long)(*obj.extra_ptr()).host.class_id == intl_class_named(ctx.heap, INTL_LIST_CLASS)) {
            return (IntlListState*)(*obj.extra_ptr()).host.payload;
        }
    }
    builtin_throw(ctx, ctx.heap.type_err_proto, "incompatible Intl.ListFormat receiver");
    return null;
}

// §13.1.1: the prototype is read from NewTarget before any option is touched.
fn void builtin_intl_list_format(BuiltinContext* ctx) {
    if (!ctx.is_constructor) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "ListFormat requires new");
        return;
    }
    long id = intl_class_named(ctx.heap, INTL_LIST_CLASS);
    HObject* proto = builtin_proto_from_new_target(ctx, ctx.heap.host_class_at((uint)id).proto);
    if (ctx.should_throw) return;
    IntlListState settings;
    HObject* supported = intl_locales(ctx, builtin_arg(ctx, 0));
    if (ctx.should_throw) return;
    HObject* opts = intl_options_object(ctx, builtin_arg(ctx, 1));
    if (ctx.should_throw) return;
    (void)intl_choice(ctx, opts, "localeMatcher", {"best fit", "lookup"});
    if (ctx.should_throw) return;
    TVal? first = supported.get_prop(ctx.heap.int_to_hstring(0), ctx.heap);
    if (try v = first) {
        HString* tag = (HString*)v.get_heapptr();
        settings.us_locale = tag.blen >= 5 && locale_eq_ci(tag.get_cstr()[:5], "en-us");
    }
    settings.type = intl_choice(ctx, opts, "type", {"conjunction", "disjunction", "unit"});
    if (ctx.should_throw) return;
    settings.style = intl_choice(ctx, opts, "style", {"long", "short", "narrow"});
    if (ctx.should_throw) return;
    HObject* obj = ctx.heap.alloc_object(ObjClass.HOST) ?? null;
    if (obj == null) { builtin_throw(ctx, ctx.heap.err_proto, "Intl allocation failed"); return; }
    (*obj.extra_ptr()).host.class_id = (uint)id;
    IntlListState* state = (IntlListState*)ctx.heap.alloc_func(ctx.heap.heap_udata, IntlListState::size);
    if (state == null) { builtin_throw(ctx, ctx.heap.err_proto, "Intl allocation failed"); return; }
    *state = settings;
    (*obj.extra_ptr()).host.payload = state;
    ctx.heap.set_prototype(obj, proto);
    ctx.result_object(obj);
}

fn void builtin_intl_list_resolved(BuiltinContext* ctx) {
    IntlListState* state = intl_list_receiver(ctx);
    if (state == null) return;
    HObject* out = ctx.heap.alloc_object(ObjClass.OBJECT) ?? null;
    if (out == null) { builtin_throw(ctx, ctx.heap.err_proto, "Intl allocation failed"); return; }
    ctx.heap.set_prototype(out, ctx.heap.object_proto);
    char[][] types = {"conjunction", "disjunction", "unit"};
    char[][] styles = {"long", "short", "narrow"};
    intl_put_string(ctx.heap, out, "locale", state.us_locale ? "en-US" : "en");
    intl_put_string(ctx.heap, out, "type", types[state.type]);
    intl_put_string(ctx.heap, out, "style", styles[state.style]);
    if (ctx.heap.has_error) { builtin_throw(ctx, ctx.heap.err_proto, "Intl allocation failed"); return; }
    ctx.result_object(out);
}

// §13.5.1 StringListFromIterable. Each element is stored in `store` as a
// four-byte length followed by its bytes. A non-string element closes the
// iterator before the TypeError propagates.
fn bool intl_list_collect(BuiltinContext* ctx, TVal iterable, StrBuf* store, uint* count) {
    *count = 0;
    if (iterable.is_undefined()) return true;
    HObject* source = iterable.is_object() ? (HObject*)iterable.get_heapptr() : to_object_wrapper(ctx.heap, iterable);
    if (source == null) { builtin_throw(ctx, ctx.heap.err_proto, "Intl allocation failed"); return false; }
    HObject* iterator;
    TVal next;
    if (!iterhelper_get_iterator(ctx, source, &iterator, &next)) {
        if (!ctx.should_throw) builtin_throw(ctx, ctx.heap.type_err_proto, "list is not iterable");
        return false;
    }
    while (true) {
        TVal value;
        bool done;
        if (!iterhelper_step_value(ctx, iterator, next, &value, &done)) return done;
        if (!value.is_string() || ((HString*)value.get_heapptr()).is_symbol()) {
            builtin_throw(ctx, ctx.heap.type_err_proto, "list elements must be strings");
            iterhelper_iterator_close(ctx, iterator, true);
            return false;
        }
        HString* s = (HString*)value.get_heapptr();
        uint len = s.blen;
        char[4] prefix = { (char)len, (char)(len >> 8), (char)(len >> 16), (char)(len >> 24) };
        store.append_bytes(prefix[..]);
        store.append_bytes(s.get_cstr()[:len]);
        (*count)++;
    }
}

// §13.5.2 CreatePartsFromList. Elements are "element" parts and the pattern
// text between them is "literal".
fn void intl_list_render(BuiltinContext* ctx, bool as_parts) {
    IntlListState* state = intl_list_receiver(ctx);
    if (state == null) return;
    StrBuf store; store.init(ctx.heap);
    defer store.free();
    uint n;
    if (!intl_list_collect(ctx, builtin_arg(ctx, 0), &store, &n)) return;
    if (store.failed) { builtin_throw(ctx, ctx.heap.err_proto, "Intl allocation failed"); return; }
    IntlListPattern* pattern = &INTL_LIST_PATTERNS[state.type * 3 + state.style];
    HObject* parts = as_parts ? intl_array(ctx) : null;
    if (ctx.should_throw) return;
    uint count = 0;
    StrBuf result; result.init(ctx.heap);
    defer result.free();
    char[] bytes = store.bytes();
    usz pos = 0;
    for (uint i = 0; i < n; i++) {
        uint len = (uint)bytes[pos] | ((uint)bytes[pos + 1] << 8) | ((uint)bytes[pos + 2] << 16) | ((uint)bytes[pos + 3] << 24);
        pos += 4;
        if (i > 0) {
            String sep = n == 2 ? pattern.pair : i == 1 ? pattern.start : i == n - 1 ? pattern.end : pattern.middle;
            intl_part(ctx, parts, &result, "literal", sep, &count);
        }
        intl_part(ctx, parts, &result, "element", bytes[pos:len], &count);
        pos += len;
    }
    if (result.failed || ctx.heap.has_error) { builtin_throw(ctx, ctx.heap.err_proto, "Intl allocation failed"); return; }
    if (parts != null) {
        array_set_length(parts, count, ctx.heap);
        ctx.result_object(parts);
    } else {
        ctx.result_string(builtin_intern_string(ctx.heap, result.bytes()));
    }
}

fn void builtin_intl_list_format_call(BuiltinContext* ctx) { intl_list_render(ctx, false); }
fn void builtin_intl_list_parts(BuiltinContext* ctx) { intl_list_render(ctx, true); }

fn bool register_intl_list(HObject* ns, Heap* hp) {
    HObject* proto = hp.alloc_object(ObjClass.OBJECT) ?? null;
    HObject* ctor = hp.alloc_object(ObjClass.FUNCTION) ?? null;
    if (proto == null || ctor == null) return false;
    hp.set_prototype(proto, hp.object_proto); hp.set_prototype(ctor, hp.function_proto);
    (*ctor.extra_ptr()).func.builtin_fn_index = (int)Builtin.INTL_LIST_FORMAT.ordinal;
    ctor.flags.callable = true; ctor.flags.constructable = true;
    set_func_ctor_name_length(ctor, hp, "ListFormat", 0);
    TVal v; v.set_object(proto); intl_put(hp, ctor, "prototype", v, (PropFlags){});
    v.set_object(ctor); intl_put(hp, proto, "constructor", v, hobject::PROP_FLAGS_WC); intl_put(hp, ns, "ListFormat", v, hobject::PROP_FLAGS_WC);
    HString* tag = builtin_intern_string(hp, INTL_LIST_CLASS); v.set_string_borrowed(tag);
    proto.put_prop(ensure_tostringtag_symbol(hp), v, hobject::PROP_FLAGS_NWC, hp);
    if (hp.register_host_class((void*)&intl_finalize, (void*)&intl_mark, hp, tag, proto) < 0) return false;
    if (!register_string_proto_method(ctor, hp, "supportedLocalesOf", Builtin.INTL_SUPPORTED_LOCALES.ordinal)) return false;
    if (!register_string_proto_method(proto, hp, "resolvedOptions", Builtin.INTL_LIST_RESOLVED.ordinal)) return false;
    if (!register_string_proto_method(proto, hp, "format", Builtin.INTL_LIST_FORMAT_CALL.ordinal)) return false;
    if (!register_string_proto_method(proto, hp, "formatToParts", Builtin.INTL_LIST_PARTS.ordinal)) return false;
    return true;
}
