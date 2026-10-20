// Unicode 17 default text boundaries (UAX #29) with UTF-16 result indices.
module boomkat::builtins;
import boomkat::types;
import boomkat::heap;
import boomkat::hobject;
import boomkat::hstring;
import boomkat::unicode_bindings;
import std::math;

struct IntlSegmentState {
    IntlPayloadHead head;
    HString* input;
    char[32] locale_tag;
    uint locale_len;
    int granularity;
    uint count;
    uint next;
}
struct SegmentPoint { uint byte_offset; uint index; bool word; }
struct SegmentChar { uint cp; uint g; uint w; uint s; uint indic; bool emoji; uint byte_offset; uint index; uint grapheme_ri; uint word_ri; }

fn uint segment_property(uint cp, SegmentRange[] table) {
    usz lo = 0; usz hi = table.len;
    while (lo < hi) {
        usz mid = lo + (hi - lo) / 2;
        if (cp < table[mid].first) { hi = mid; }
        else if (cp > table[mid].last) { lo = mid + 1; }
        else { return table[mid].value; }
    }
    return 0;
}
fn bool segment_control(uint p) => p == SEG_G_CR || p == SEG_G_LF || p == SEG_G_CONTROL;
fn bool segment_grapheme_break(SegmentChar[] chars, uint i) {
    uint a = chars[i - 1].g; uint b = chars[i].g;
    if (a == SEG_G_CR && b == SEG_G_LF) return false;
    if (segment_control(a) || segment_control(b)) return true;
    if (a == SEG_G_L && (b == SEG_G_L || b == SEG_G_V || b == SEG_G_LV || b == SEG_G_LVT)) return false;
    if ((a == SEG_G_LV || a == SEG_G_V) && (b == SEG_G_V || b == SEG_G_T)) return false;
    if ((a == SEG_G_LVT || a == SEG_G_T) && b == SEG_G_T) return false;
    if (b == SEG_G_EXTEND || b == SEG_G_ZWJ || b == SEG_G_SPACINGMARK || a == SEG_G_PREPEND) return false;
    if (chars[i].indic == SEG_I_CONSONANT) {
        uint j = i; bool linker = false;
        while (j > 0 && (chars[j - 1].indic == SEG_I_EXTEND || chars[j - 1].indic == SEG_I_LINKER)) {
            j--; linker = linker || chars[j].indic == SEG_I_LINKER;
        }
        if (linker && j > 0 && chars[j - 1].indic == SEG_I_CONSONANT) return false;
    }
    if (a == SEG_G_ZWJ && chars[i].emoji) {
        uint j = i - 1;
        while (j > 0 && chars[j - 1].g == SEG_G_EXTEND) j--;
        if (j > 0 && chars[j - 1].emoji) return false;
    }
    if (a == SEG_G_REGIONAL_INDICATOR && b == SEG_G_REGIONAL_INDICATOR) {
        if ((chars[i - 1].grapheme_ri & 1) != 0) return false;
    }
    return true;
}
fn bool segment_word_ignore(uint p) => p == SEG_W_EXTEND || p == SEG_W_FORMAT || p == SEG_W_ZWJ;
fn bool segment_word_letter(uint p) => p == SEG_W_ALETTER || p == SEG_W_HEBREW_LETTER;
fn bool segment_word_midletter(uint p) => p == SEG_W_MIDLETTER || p == SEG_W_MIDNUMLET || p == SEG_W_SINGLE_QUOTE;
fn bool segment_word_midnum(uint p) => p == SEG_W_MIDNUM || p == SEG_W_MIDNUMLET || p == SEG_W_SINGLE_QUOTE;
fn bool segment_word_core(uint p) => segment_word_letter(p) || p == SEG_W_NUMERIC || p == SEG_W_KATAKANA || p == SEG_W_EXTENDNUMLET;
fn bool segment_word_newline(uint p) => p == SEG_W_CR || p == SEG_W_LF || p == SEG_W_NEWLINE;
fn bool segment_word_break(SegmentChar[] chars, uint i) {
    uint a = chars[i - 1].w; uint b = chars[i].w;
    if (a == SEG_W_CR && b == SEG_W_LF) return false;
    if (segment_word_newline(a) || segment_word_newline(b)) return true;
    if (a == SEG_W_ZWJ && chars[i].emoji) return false;
    if (a == SEG_W_WSEGSPACE && b == SEG_W_WSEGSPACE) return false;
    if (segment_word_ignore(b)) return false;
    uint left = i;
    while (left > 0 && segment_word_ignore(chars[left - 1].w)) left--;
    if (left == 0) return true;
    a = chars[left - 1].w;
    uint prev = left - 1;
    while (prev > 0 && segment_word_ignore(chars[prev - 1].w)) prev--;
    uint p = prev > 0 ? chars[prev - 1].w : 0;
    uint after = i + 1;
    while (after < chars.len && segment_word_ignore(chars[after].w)) after++;
    uint c = after < chars.len ? chars[after].w : 0;
    if (segment_word_letter(a) && segment_word_letter(b)) return false;
    if (segment_word_letter(a) && segment_word_midletter(b) && segment_word_letter(c)) return false;
    if (segment_word_letter(p) && segment_word_midletter(a) && segment_word_letter(b)) return false;
    if (a == SEG_W_HEBREW_LETTER && b == SEG_W_SINGLE_QUOTE) return false;
    if (a == SEG_W_HEBREW_LETTER && b == SEG_W_DOUBLE_QUOTE && c == SEG_W_HEBREW_LETTER) return false;
    if (p == SEG_W_HEBREW_LETTER && a == SEG_W_DOUBLE_QUOTE && b == SEG_W_HEBREW_LETTER) return false;
    if (a == SEG_W_NUMERIC && b == SEG_W_NUMERIC) return false;
    if ((segment_word_letter(a) && b == SEG_W_NUMERIC) || (a == SEG_W_NUMERIC && segment_word_letter(b))) return false;
    if (a == SEG_W_NUMERIC && segment_word_midnum(b) && c == SEG_W_NUMERIC) return false;
    if (p == SEG_W_NUMERIC && segment_word_midnum(a) && b == SEG_W_NUMERIC) return false;
    if (a == SEG_W_KATAKANA && b == SEG_W_KATAKANA) return false;
    if ((segment_word_core(a) && b == SEG_W_EXTENDNUMLET) || (a == SEG_W_EXTENDNUMLET && segment_word_core(b))) return false;
    if (a == SEG_W_REGIONAL_INDICATOR && b == SEG_W_REGIONAL_INDICATOR) {
        if ((chars[left - 1].word_ri & 1) != 0) return false;
    }
    return true;
}
fn bool segment_sentence_ignore(uint p) => p == SEG_S_EXTEND || p == SEG_S_FORMAT;
fn bool segment_sentence_para(uint p) => p == SEG_S_CR || p == SEG_S_LF || p == SEG_S_SEP;
fn bool segment_sentence_term(uint p) => p == SEG_S_ATERM || p == SEG_S_STERM;
fn uint segment_sentence_prev(SegmentChar[] chars, uint pos) {
    while (pos > 0 && segment_sentence_ignore(chars[pos - 1].s)) pos--;
    return pos;
}
fn bool segment_sentence_break(SegmentChar[] chars, uint i) {
    uint a = chars[i - 1].s; uint b = chars[i].s;
    if (a == SEG_S_CR && b == SEG_S_LF) return false;
    if (segment_sentence_para(a)) return true;
    if (segment_sentence_ignore(b)) return false;
    uint left = segment_sentence_prev(chars, i);
    if (left == 0) return false;
    a = chars[left - 1].s;
    if (a == SEG_S_ATERM && b == SEG_S_NUMERIC) return false;
    uint prev = segment_sentence_prev(chars, left - 1);
    if (a == SEG_S_ATERM && b == SEG_S_UPPER && prev > 0 &&
        (chars[prev - 1].s == SEG_S_UPPER || chars[prev - 1].s == SEG_S_LOWER)) return false;
    uint j = left;
    while (j > 0 && chars[j - 1].s == SEG_S_SP) j = segment_sentence_prev(chars, j - 1);
    bool had_space = j != left;
    while (j > 0 && chars[j - 1].s == SEG_S_CLOSE) j = segment_sentence_prev(chars, j - 1);
    if (j == 0 || !segment_sentence_term(chars[j - 1].s)) return false;
    uint term = chars[j - 1].s;
    if (term == SEG_S_ATERM) {
        uint k = i;
        while (k < chars.len) {
            uint p = chars[k].s;
            if (p == SEG_S_LOWER) return false;
            if (p == SEG_S_OLETTER || p == SEG_S_UPPER || segment_sentence_para(p) || segment_sentence_term(p)) break;
            k++;
        }
    }
    if (b == SEG_S_SCONTINUE || segment_sentence_term(b)) return false;
    if ((!had_space && b == SEG_S_CLOSE) || b == SEG_S_SP || segment_sentence_para(b)) return false;
    return true;
}

fn IntlSegmentState* intl_segment_receiver(BuiltinContext* ctx, char[] name) {
    TVal v = ctx.regs[ctx.base_reg - 1];
    if (v.is_object()) {
        HObject* obj = (HObject*)v.get_heapptr();
        if (obj.get_class() == ObjClass.HOST && (long)(*obj.extra_ptr()).host.class_id == intl_class_named(ctx.heap, name)) {
            return (IntlSegmentState*)(*obj.extra_ptr()).host.payload;
        }
    }
    builtin_throw(ctx, ctx.heap.type_err_proto, "incompatible Segmenter receiver");
    return null;
}
fn HObject* intl_segment_object(BuiltinContext* ctx, char[] name, usz extra = 0) {
    long id = intl_class_named(ctx.heap, name);
    HObject* obj = ctx.heap.alloc_object(ObjClass.HOST) ?? null;
    if (obj == null) { builtin_throw(ctx, ctx.heap.err_proto, "Segmenter allocation failed"); return null; }
    (*obj.extra_ptr()).host.class_id = (uint)id;
    void* state = ctx.heap.alloc_func(ctx.heap.heap_udata, IntlSegmentState::size + extra);
    if (state == null) { builtin_throw(ctx, ctx.heap.err_proto, "Segmenter allocation failed"); return null; }
    *(IntlSegmentState*)state = {};
    (*obj.extra_ptr()).host.payload = state;
    ctx.heap.set_prototype(obj, ctx.heap.host_class_at((uint)id).proto);
    return obj;
}
fn bool segment_locale_supported(LocaleId* id) {
    uint value;
    return locale_likely_find(id.lang(), "", "", &value);
}
fn HObject* intl_segment_locales(BuiltinContext* ctx) {
    HObject* requested = intl_locales(ctx, builtin_arg(ctx, 0), IntlLocaleFilter.ALL);
    if (ctx.should_throw) return null;
    HObject* result = intl_array(ctx);
    if (result == null) return null;
    uint count = 0;
    for (uint i = 0; ; i++) {
        TVal? entry = requested.get_prop(ctx.heap.int_to_hstring(i), ctx.heap);
        if (catch entry) break;
        HString* tag = (HString*)entry.get_heapptr();
        LocaleId id; id.parse(tag.get_cstr()[:tag.blen]);
        if (segment_locale_supported(&id)) array_set_elem(result, count++, entry, ctx.heap);
    }
    array_set_length(result, count, ctx.heap);
    return result;
}
fn void builtin_intl_segment_supported(BuiltinContext* ctx) {
    HObject* result = intl_segment_locales(ctx);
    if (ctx.should_throw || result == null) return;
    HObject* opts = intl_options(ctx, builtin_arg(ctx, 1));
    if (ctx.should_throw) return;
    (void)intl_choice(ctx, opts, "localeMatcher", {"best fit", "lookup"});
    if (!ctx.should_throw) ctx.result_object(result);
}
fn void builtin_intl_segmenter(BuiltinContext* ctx) {
    if (!ctx.is_constructor) { builtin_throw(ctx, ctx.heap.type_err_proto, "Segmenter requires new"); return; }
    HObject* proto = builtin_proto_from_new_target(ctx, ctx.heap.host_class_at((uint)intl_class_named(ctx.heap, "Intl.Segmenter")).proto);
    if (ctx.should_throw) return;
    IntlSegmentState settings;
    HObject* locales = intl_segment_locales(ctx);
    if (ctx.should_throw) return;
    TVal opt = builtin_arg(ctx, 1);
    if (!opt.is_undefined() && !opt.is_object()) { builtin_throw(ctx, ctx.heap.type_err_proto, "options must be an object"); return; }
    HObject* opts = intl_options_object(ctx, opt);
    if (ctx.should_throw) return;
    (void)intl_choice(ctx, opts, "localeMatcher", {"best fit", "lookup"});
    if (ctx.should_throw) return;
    settings.locale_tag[0] = 'e'; settings.locale_tag[1] = 'n'; settings.locale_len = 2;
    TVal? first = locales.get_prop(ctx.heap.int_to_hstring(0), ctx.heap);
    if (try v = first) {
        HString* tag = (HString*)v.get_heapptr();
        LocaleId id; id.parse(tag.get_cstr()[:tag.blen]);
        id.ext_len = 0; id.variant_count = 0;
        LocaleBuf buffer = {settings.locale_tag[..], 0, false}; id.write(&buffer);
        settings.locale_len = (uint)buffer.len;
    }
    settings.granularity = intl_choice(ctx, opts, "granularity", {"grapheme", "word", "sentence"});
    if (ctx.should_throw) return;
    HObject* obj = intl_segment_object(ctx, "Intl.Segmenter");
    if (obj == null) return;
    *(IntlSegmentState*)(*obj.extra_ptr()).host.payload = settings;
    ctx.heap.set_prototype(obj, proto);
    ctx.result_object(obj);
}
fn void builtin_intl_segment_resolved(BuiltinContext* ctx) {
    IntlSegmentState* state = intl_segment_receiver(ctx, "Intl.Segmenter");
    if (state == null) return;
    HObject* out = ctx.heap.alloc_object(ObjClass.OBJECT) ?? null;
    if (out == null) { builtin_throw(ctx, ctx.heap.err_proto, "Segmenter allocation failed"); return; }
    ctx.heap.set_prototype(out, ctx.heap.object_proto);
    char[][] granularities = {"grapheme", "word", "sentence"};
    intl_put_string(ctx.heap, out, "locale", state.locale_tag[:state.locale_len]);
    intl_put_string(ctx.heap, out, "granularity", granularities[state.granularity]);
    ctx.result_object(out);
}

fn SegmentPoint* intl_segment_points(IntlSegmentState* state) => (SegmentPoint*)((char*)state + IntlSegmentState::size);

fn void builtin_intl_segment_call(BuiltinContext* ctx) {
    IntlSegmentState* segmenter = intl_segment_receiver(ctx, "Intl.Segmenter");
    if (segmenter == null) return;
    TVal arg = builtin_arg(ctx, 0);
    HString* input = builtin_to_string_vm(ctx, &arg);
    if (ctx.should_throw || input == null) return;
    // The holder makes the string visible to both GC and host-object refcount tracing.
    HObject* holder = ctx.heap.alloc_object(ObjClass.OBJECT) ?? null;
    if (holder == null) { builtin_throw(ctx, ctx.heap.err_proto, "Segmenter allocation failed"); return; }
    TVal value; value.set_string_borrowed(input); intl_put(ctx.heap, holder, "input", value);
    char[] bytes = input.get_cstr()[:input.blen];
    uint n = 0; uint offset = 0;
    while (offset < bytes.len) { offset += hstring::advance_string_index_byte_len(bytes, offset, true); n++; }
    SegmentChar* raw = (SegmentChar*)ctx.heap.alloc_func(ctx.heap.heap_udata, ((usz)n + 1) * SegmentChar::size);
    if (raw == null) { builtin_throw(ctx, ctx.heap.err_proto, "Segmenter allocation failed"); return; }
    defer ctx.heap.free_func(ctx.heap.heap_udata, raw);
    SegmentChar[] chars = raw[:n];
    offset = 0; uint index = 0;
    for (uint i = 0; i < n; i++) {
        uint size = hstring::advance_string_index_byte_len(bytes, offset, true);
        uint cp = hstring::decode_codepoint(bytes, offset);
        if (hstring::is_high_surrogate(cp) && size > 3) cp = hstring::surrogates_to_codepoint(cp, hstring::decode_codepoint(bytes, offset + 3));
        uint g = segment_property(cp, SEG_G_RANGES[..]);
        if (cp >= 0xAC00 && cp <= 0xD7A3) g = (cp - 0xAC00) % 28 == 0 ? SEG_G_LV : SEG_G_LVT;
        chars[i] = {cp, g, segment_property(cp, SEG_W_RANGES[..]), segment_property(cp, SEG_S_RANGES[..]),
                    segment_property(cp, SEG_I_RANGES[..]), segment_property(cp, SEG_E_RANGES[..]) != 0, offset, index, 0, 0};
        chars[i].grapheme_ri = g == SEG_G_REGIONAL_INDICATOR ? (i > 0 ? chars[i - 1].grapheme_ri : 0) + 1 : 0;
        uint previous_ri = i > 0 ? chars[i - 1].word_ri : 0;
        chars[i].word_ri = chars[i].w == SEG_W_REGIONAL_INDICATOR ? previous_ri + 1 : segment_word_ignore(chars[i].w) ? previous_ri : 0;
        offset += size; index += cp >= 0x10000 ? 2 : 1;
    }
    uint count = n > 0 ? 1 : 0;
    for (uint i = 1; i < n; i++) {
        bool boundary = segmenter.granularity == 0 ? segment_grapheme_break(chars, i) :
                        segmenter.granularity == 1 ? segment_word_break(chars, i) : segment_sentence_break(chars, i);
        if (boundary) count++;
    }
    HObject* obj = intl_segment_object(ctx, "Intl.Segments", ((usz)count + 1) * SegmentPoint::size);
    if (obj == null) return;
    IntlSegmentState* state = (IntlSegmentState*)(*obj.extra_ptr()).host.payload;
    state.head.bound = holder; state.input = input; state.granularity = segmenter.granularity; state.count = count;
    ctx.heap.write_barrier_ptr(obj, holder);
    SegmentPoint* points = intl_segment_points(state);
    uint current = 0; points[0] = {};
    for (uint i = 0; i < n; i++) {
        bool boundary = i > 0 && (state.granularity == 0 ? segment_grapheme_break(chars, i) :
                        state.granularity == 1 ? segment_word_break(chars, i) : segment_sentence_break(chars, i));
        if (boundary) { current++; points[current] = {chars[i].byte_offset, chars[i].index, false}; }
        uint w = chars[i].w; uint cp = chars[i].cp;
        // These scripts have letters outside the Word_Break ALetter class.
        if (segment_word_letter(w) || w == SEG_W_NUMERIC || w == SEG_W_KATAKANA ||
            (cp >= 128 && unicode_bindings::unicode_is_identifier_start(cp) != 0)) points[current].word = true;
    }
    points[count] = {(uint)bytes.len, index, false};
    ctx.result_object(obj);
}
fn HObject* intl_segment_data(BuiltinContext* ctx, IntlSegmentState* state, uint i) {
    SegmentPoint* points = intl_segment_points(state);
    HObject* obj = ctx.heap.alloc_object(ObjClass.OBJECT) ?? null;
    if (obj == null) { builtin_throw(ctx, ctx.heap.err_proto, "Segmenter allocation failed"); return null; }
    ctx.heap.set_prototype(obj, ctx.heap.object_proto);
    uint start = points[i].byte_offset; uint end = points[i + 1].byte_offset;
    intl_put_string(ctx.heap, obj, "segment", state.input.get_cstr()[start:end - start]);
    intl_put_int(ctx.heap, obj, "index", (int)points[i].index);
    TVal v; v.set_string_borrowed(state.input); intl_put(ctx.heap, obj, "input", v);
    if (state.granularity == 1) { v.set_boolean(points[i].word); intl_put(ctx.heap, obj, "isWordLike", v); }
    return obj;
}
fn void builtin_intl_segment_containing(BuiltinContext* ctx) {
    IntlSegmentState* state = intl_segment_receiver(ctx, "Intl.Segments");
    if (state == null) return;
    TVal arg = builtin_arg(ctx, 0);
    double index = builtin_to_number_vm(ctx, &arg);
    if (ctx.should_throw) return;
    if (math::is_nan(index)) index = 0;
    index = math::trunc(index);
    SegmentPoint* points = intl_segment_points(state);
    if (index < 0 || index >= points[state.count].index) { ctx.result_undefined(); return; }
    uint lo = 0; uint hi = state.count;
    while (lo + 1 < hi) { uint mid = lo + (hi - lo) / 2; if (points[mid].index <= index) { lo = mid; } else { hi = mid; } }
    HObject* obj = intl_segment_data(ctx, state, lo);
    if (obj != null) ctx.result_object(obj);
}
fn void builtin_intl_segment_iterator(BuiltinContext* ctx) {
    IntlSegmentState* state = intl_segment_receiver(ctx, "Intl.Segments");
    if (state == null) return;
    HObject* obj = intl_segment_object(ctx, "Intl.SegmentIterator");
    if (obj == null) return;
    HObject* segments = (HObject*)ctx.regs[ctx.base_reg - 1].get_heapptr();
    ((IntlSegmentState*)(*obj.extra_ptr()).host.payload).head.bound = segments;
    ctx.heap.write_barrier_ptr(obj, segments);
    ctx.result_object(obj);
}
fn void builtin_intl_segment_next(BuiltinContext* ctx) {
    IntlSegmentState* iterator = intl_segment_receiver(ctx, "Intl.SegmentIterator");
    if (iterator == null) return;
    IntlSegmentState* state = (IntlSegmentState*)(*iterator.head.bound.extra_ptr()).host.payload;
    TVal value; value.set_undefined();
    bool done = iterator.next >= state.count;
    if (!done) {
        HObject* obj = intl_segment_data(ctx, state, iterator.next++);
        if (obj == null) return;
        value.set_object(obj);
    }
    builtin_iterator_result(ctx, &value, done);
}
fn bool register_intl_segmenter(HObject* ns, Heap* hp) {
    char[][] names = {"Intl.Segmenter", "Intl.Segments", "Intl.SegmentIterator"};
    HObject*[3] protos;
    for (uint i = 0; i < 3; i++) {
        protos[i] = hp.alloc_object(ObjClass.OBJECT) ?? null;
        if (protos[i] == null) return false;
        hp.set_prototype(protos[i], i == 2 ? hp.iterator_proto : hp.object_proto);
        HString* name = builtin_intern_string(hp, names[i]);
        if (hp.register_host_class((void*)&intl_finalize, (void*)&intl_mark, hp, name, protos[i]) < 0) return false;
    }
    HObject* ctor = hp.alloc_object(ObjClass.FUNCTION) ?? null;
    if (ctor == null) return false;
    hp.set_prototype(ctor, hp.function_proto);
    (*ctor.extra_ptr()).func.builtin_fn_index = (int)Builtin.INTL_SEGMENTER.ordinal;
    ctor.flags.callable = true; ctor.flags.constructable = true;
    set_func_ctor_name_length(ctor, hp, "Segmenter", 0);
    TVal v; v.set_object(protos[0]); intl_put(hp, ctor, "prototype", v, (PropFlags){});
    v.set_object(ctor); intl_put(hp, protos[0], "constructor", v, hobject::PROP_FLAGS_WC); intl_put(hp, ns, "Segmenter", v, hobject::PROP_FLAGS_WC);
    v.set_string_borrowed(builtin_intern_string(hp, "Intl.Segmenter"));
    protos[0].put_prop(ensure_tostringtag_symbol(hp), v, hobject::PROP_FLAGS_NWC, hp);
    v.set_string_borrowed(builtin_intern_string(hp, "Segmenter String Iterator"));
    protos[2].put_prop(ensure_tostringtag_symbol(hp), v, hobject::PROP_FLAGS_NWC, hp);
    if (!register_string_proto_method(ctor, hp, "supportedLocalesOf", Builtin.INTL_SEGMENT_SUPPORTED.ordinal)) return false;
    if (!register_string_proto_method(protos[0], hp, "resolvedOptions", Builtin.INTL_SEGMENT_RESOLVED.ordinal)) return false;
    if (!register_string_proto_method(protos[0], hp, "segment", Builtin.INTL_SEGMENT_CALL.ordinal)) return false;
    if (!register_string_proto_method(protos[1], hp, "containing", Builtin.INTL_SEGMENT_CONTAINING.ordinal)) return false;
    if (!register_string_proto_method(protos[2], hp, "next", Builtin.INTL_SEGMENT_NEXT.ordinal)) return false;
    HObject* iter = hp.alloc_object(ObjClass.FUNCTION) ?? null;
    if (iter == null) return false;
    hp.set_prototype(iter, hp.function_proto); iter.flags.callable = true;
    (*iter.extra_ptr()).func.builtin_fn_index = (int)Builtin.INTL_SEGMENT_ITERATOR.ordinal;
    set_func_ctor_name_length(iter, hp, "[Symbol.iterator]", 0);
    v.set_object(iter); protos[1].put_prop(ensure_iterator_symbol(hp), v, hobject::PROP_FLAGS_WC, hp);
    return !hp.has_error;
}
