// Intl.Collator (ECMA-402 §10) over the root collation (UCA 9.1, CLDR root).
// Opt-in: built only with -D INTL_COLLATOR, and no build target enables it.
//
// Limits of this implementation: no tailored collations (every collation
// resolves to "default"), no contractions (each code point's elements are
// looked up alone), and implicit weights for Han, Tangut, Nushu, Khitan,
// unassigned and private-use code points follow UCA 9.1 section 10.1 with
// ICU's explicit primaries, so orders among the implicit weights can differ.
module boomkat::builtins;
import boomkat::types;
import boomkat::heap;
import boomkat::hobject;
import boomkat::hstring;
import boomkat::unicode_bindings;


const String INTL_COLLATOR_CLASS @feat(INTL_COLLATOR) = "Intl.Collator";

// Sensitivity levels, lowest to highest (ECMA-402 §10.1.2 table).
const int COLL_BASE @feat(INTL_COLLATOR) = 0;
const int COLL_ACCENT @feat(INTL_COLLATOR) = 1;
const int COLL_CASE @feat(INTL_COLLATOR) = 2;
const int COLL_VARIANT @feat(INTL_COLLATOR) = 3;

// Weight levels passed to coll_next. LEVEL_CASE compares only the case bits of
// the tertiary weight, for sensitivity "case".
const int LEVEL_PRIMARY @feat(INTL_COLLATOR) = 1;
const int LEVEL_SECONDARY @feat(INTL_COLLATOR) = 2;
const int LEVEL_TERTIARY @feat(INTL_COLLATOR) = 3;
const int LEVEL_CASE @feat(INTL_COLLATOR) = 4;

// Implicit bases of the UCA 9.1 classes, indexed by INTL_COLL_IMPLICIT_CLASS.
// Each sits above every 16-bit explicit primary: 0 core Han, 1 other Han,
// 2 Tangut, 3 Nushu, 4 Khitan, 5 unassigned and private use.
const ulong[6] COLL_IMPLICIT_BASE @feat(INTL_COLLATOR) = { 0x1FB40, 0x1FB80, 0x1FB00, 0x1FB01, 0x1FB02, 0x1FBC0 };

// Most elements one code point contributes (the table's largest expansion).
const usz COLL_MAX_CES @feat(INTL_COLLATOR) = 18;

struct IntlCollatorState @feat(INTL_COLLATOR) {
    HObject* bound_compare; // read by the GC through intl_mark's offset-0 access
    bool us_locale;
    bool search;
    int sensitivity;
    bool ignore_punctuation;
    bool numeric;
    int case_first; // 0 false, 1 lower, 2 upper
    bool keep_numeric_ext;
    bool keep_case_first_ext;
}

// The table lookup for one code point. Explicit entries come from the bitmap
// rank, or the high list; everything else is an implicit class.
fn bool coll_explicit_index(uint cp, usz* index) @feat(INTL_COLLATOR) {
    if (cp < 0x20000) {
        usz word = cp / 64;
        ulong bit = 1UL << (cp % 64);
        if (!(INTL_COLL_BITS[word] & bit)) return false;
        *index = (usz)INTL_COLL_RANK[word] + (usz)(INTL_COLL_BITS[word] & (bit - 1)).popcount();
        return true;
    }
    usz low = 0;
    usz high = INTL_COLL_HIGH_CPS.len;
    while (low < high) {
        usz mid = low + (high - low) / 2;
        if (INTL_COLL_HIGH_CPS[mid] == cp) {
            *index = INTL_COLLATION_BITMAPPED + mid;
            return true;
        }
        if (INTL_COLL_HIGH_CPS[mid] < cp) {
            low = mid + 1;
        } else {
            high = mid;
        }
    }
    return false;
}

// Writes the collation elements of `cp` as keys: primary << 16 | secondary << 8 |
// tertiary. Variable elements are dropped when ignorePunctuation is set.
// Returns the count, at most COLL_MAX_CES.
fn usz coll_code_point_keys(uint cp, ulong* keys, bool ignore_punctuation) @feat(INTL_COLLATOR) {
    if (cp >= 0xD800 && cp <= 0xDFFF) cp = 0xFFFD;
    usz count = 0;
    usz index;
    if (coll_explicit_index(cp, &index)) {
        usz block = index / 32;
        usz start = INTL_COLL_BLOCK_AT[block];
        for (usz i = block * 32; i < index; i++) start += (usz)INTL_COLL_COUNT[i];
        usz n = (usz)INTL_COLL_COUNT[index];
        for (usz i = 0; i < n; i++) {
            uint ce = INTL_COLL_CES[start + i];
            ulong primary = (ulong)(ce >> 16);
            if (ignore_punctuation && primary <= INTL_COLL_VARIABLE_TOP) continue;
            keys[count++] = (primary << 16) | (ulong)(((ce >> 8) & 0xFF) << 8) | (ulong)(ce & 0xFF);
        }
        return count;
    }
    // Implicit weights (UCA 9.1 section 10.1): a class base plus the code point's
    // high bits, then the code point's low 15 bits with the top bit set.
    usz low = 0;
    usz high = INTL_COLL_IMPLICIT_FIRST.len;
    usz run = 0;
    bool found = false;
    while (low < high) {
        usz mid = low + (high - low) / 2;
        if (INTL_COLL_IMPLICIT_FIRST[mid] <= cp) {
            run = mid;
            found = true;
            low = mid + 1;
        } else {
            high = mid;
        }
    }
    usz cls = 5;
    if (found && cp <= INTL_COLL_IMPLICIT_LAST[run]) cls = (usz)INTL_COLL_IMPLICIT_CLASS[run];
    ulong primary = COLL_IMPLICIT_BASE[cls] + ((ulong)cp >> 15);
    keys[count++] = (primary << 16) | (5UL << 8) | 5UL;
    keys[count++] = (((ulong)cp & 0x7FFF) | 0x8000) << 16;
    return count;
}

// A stream of nonzero weights for one level, over the code points of a string.
struct CollIter @feat(INTL_COLLATOR) {
    uint* cps;
    usz len;
    usz pos;
    ulong[COLL_MAX_CES] keys;
    usz key_count;
    usz key_pos;
    bool ignore_punctuation;
    bool upper_first;
}

// The tertiary weight with its case bits ranked for caseFirst. The weight is
// never zero, so an ignorable tertiary is still skipped.
fn ulong coll_tertiary(ulong key, bool upper_first, bool case_only) @feat(INTL_COLLATOR) {
    ulong t = key & 0xFF;
    ulong rank = t >> 6;
    if (upper_first) {
        if (rank == 2) {
            rank = 0;
        } else if (rank == 0) {
            rank = 2;
        }
    }
    if (case_only) return rank + 1;
    return (rank << 8) | (t & 0x3F);
}

fn bool coll_next(CollIter* it, int level, ulong* weight) @feat(INTL_COLLATOR) {
    while (true) {
        if (it.key_pos == it.key_count) {
            if (it.pos == it.len) return false;
            it.key_count = coll_code_point_keys(it.cps[it.pos++], &it.keys, it.ignore_punctuation);
            it.key_pos = 0;
            continue;
        }
        ulong key = it.keys[it.key_pos++];
        ulong w = 0;
        switch (level) {
            case LEVEL_PRIMARY: w = key >> 16;
            case LEVEL_SECONDARY: w = (key >> 8) & 0xFF;
            case LEVEL_TERTIARY: if ((key & 0xFF) != 0) w = coll_tertiary(key, it.upper_first, false);
            // Case compares only elements with a primary, so combining marks do not count.
            case LEVEL_CASE: if ((key & 0xFF) != 0 && (key >> 16) != 0) w = coll_tertiary(key, it.upper_first, true);
        }
        if (w != 0) {
            *weight = w;
            return true;
        }
    }
}

// Compares two code point strings at the collator's sensitivity. Returns -1, 0
// or 1.
fn int coll_compare_cps(IntlCollatorState* state, uint* a, usz an, uint* b, usz bn) @feat(INTL_COLLATOR) {
    int[3] levels;
    usz count = 0;
    levels[count++] = LEVEL_PRIMARY;
    if (state.sensitivity == COLL_ACCENT || state.sensitivity == COLL_VARIANT) levels[count++] = LEVEL_SECONDARY;
    if (state.sensitivity == COLL_CASE) levels[count++] = LEVEL_CASE;
    if (state.sensitivity == COLL_VARIANT) levels[count++] = LEVEL_TERTIARY;
    for (usz l = 0; l < count; l++) {
        CollIter ia = { .cps = a, .len = an, .ignore_punctuation = state.ignore_punctuation, .upper_first = state.case_first == 2 };
        CollIter ib = { .cps = b, .len = bn, .ignore_punctuation = state.ignore_punctuation, .upper_first = state.case_first == 2 };
        while (true) {
            ulong wa;
            ulong wb;
            bool has_a = coll_next(&ia, levels[l], &wa);
            bool has_b = coll_next(&ib, levels[l], &wb);
            if (!has_a || !has_b) {
                if (has_a) return 1;
                if (has_b) return -1;
                break;
            }
            if (wa != wb) return wa < wb ? -1 : 1;
        }
    }
    return 0;
}

fn IntlCollatorState* intl_collator_receiver(BuiltinContext* ctx) @feat(INTL_COLLATOR) {
    TVal v = ctx.regs[ctx.base_reg - 1];
    if (v.is_object()) {
        HObject* obj = (HObject*)v.get_heapptr();
        if (obj != null && obj.get_class() == ObjClass.HOST &&
            (long)(*obj.extra_ptr()).host.class_id == intl_class_named(ctx.heap, INTL_COLLATOR_CLASS)) {
            return (IntlCollatorState*)(*obj.extra_ptr()).host.payload;
        }
    }
    builtin_throw(ctx, ctx.heap.type_err_proto, "incompatible Intl.Collator receiver");
    return null;
}

// Unicode type grammar for the "collation" option: 3-8 alphanumerics per
// subtag, subtags joined by "-".
fn bool coll_type_valid(char[] s) @feat(INTL_COLLATOR) {
    if (s.len == 0) return false;
    usz segment = 0;
    foreach (c : s) {
        if (c == '-') {
            if (segment < 3 || segment > 8) return false;
            segment = 0;
        } else if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')) {
            segment++;
        } else {
            return false;
        }
    }
    return segment >= 3 && segment <= 8;
}

// §10.1.2 InitializeCollator. Options are read in ECMA-402 order; the locale
// extension keys kf and kn fill in caseFirst and numeric when no option is given.
fn void builtin_intl_collator(BuiltinContext* ctx) @feat(INTL_COLLATOR) {
    long id = intl_class_named(ctx.heap, INTL_COLLATOR_CLASS);
    HObject* proto = builtin_proto_from_new_target(ctx, ctx.heap.host_class_at((uint)id).proto);
    if (ctx.should_throw) return;
    IntlCollatorState settings = {};
    HObject* supported = intl_locales(ctx, builtin_arg(ctx, 0));
    if (ctx.should_throw) return;
    HObject* opts = intl_options_object(ctx, builtin_arg(ctx, 1));
    if (ctx.should_throw) return;
    (void)intl_choice(ctx, opts, "localeMatcher", {"best fit", "lookup"});
    if (ctx.should_throw) return;

    char[] tag = "en-US";
    settings.us_locale = true;
    if (supported != null) {
        TVal? first = supported.get_prop(ctx.heap.int_to_hstring(0), ctx.heap);
        if (try v = first) {
            HString* s = (HString*)v.get_heapptr();
            tag = s.get_cstr()[:s.blen];
            settings.us_locale = s.blen >= 5 && locale_eq_ci(s.get_cstr()[:5], "en-us");
        }
    }
    LocaleId locale_id;
    char[] kn_value;
    char[] kf_value;
    bool has_tag_ext = locale_id.parse(tag);
    bool tag_numeric = false;
    int tag_case_first = -1;
    if (has_tag_ext && locale_id.keyword("kn", &kn_value)) {
        tag_numeric = kn_value.len == 0 || locale_compare(kn_value, "true") == 0;
        settings.keep_numeric_ext = true;
    }
    if (has_tag_ext && locale_id.keyword("kf", &kf_value)) {
        if (locale_compare(kf_value, "upper") == 0) {
            tag_case_first = 2;
        } else if (locale_compare(kf_value, "lower") == 0) {
            tag_case_first = 1;
        } else if (locale_compare(kf_value, "false") == 0) {
            tag_case_first = 0;
        }
    }

    // "collation" must have the type grammar; the value only matters for tailored
    // collations, which this implementation does not have.
    TVal collation = intl_option(ctx, opts, "collation");
    if (ctx.should_throw) return;
    if (!collation.is_undefined()) {
        HString* cs = builtin_to_string_vm(ctx, &collation);
        if (ctx.should_throw || cs == null) return;
        if (!coll_type_valid(cs.get_cstr()[:cs.blen])) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "invalid collation");
            return;
        }
    }

    TVal numeric = intl_option(ctx, opts, "numeric");
    if (ctx.should_throw) return;
    settings.numeric = tag_numeric;
    if (!numeric.is_undefined()) {
        settings.numeric = builtin_to_boolean(&numeric);
        settings.keep_numeric_ext = settings.keep_numeric_ext && settings.numeric == tag_numeric;
    }

    // caseFirst: 0 false, 1 lower, 2 upper.
    int case_option = intl_choice(ctx, opts, "caseFirst", {"upper", "lower", "false"}, -1);
    if (ctx.should_throw) return;
    settings.case_first = tag_case_first < 0 ? 0 : tag_case_first;
    if (case_option >= 0) {
        settings.case_first = case_option == 0 ? 2 : (case_option == 1 ? 1 : 0);
        settings.keep_case_first_ext = tag_case_first >= 0 && settings.case_first == tag_case_first;
    } else {
        settings.keep_case_first_ext = tag_case_first >= 0;
    }

    int usage = intl_choice(ctx, opts, "usage", {"sort", "search"});
    if (ctx.should_throw) return;
    settings.search = usage == 1;

    settings.sensitivity = intl_choice(ctx, opts, "sensitivity", {"base", "accent", "case", "variant"}, COLL_VARIANT);
    if (ctx.should_throw) return;

    TVal ignore = intl_option(ctx, opts, "ignorePunctuation");
    if (ctx.should_throw) return;
    settings.ignore_punctuation = !ignore.is_undefined() && builtin_to_boolean(&ignore);

    HObject* obj = ctx.heap.alloc_object(ObjClass.HOST) ?? null;
    if (obj == null) { builtin_throw(ctx, ctx.heap.err_proto, "Intl allocation failed"); return; }
    IntlCollatorState* state = (IntlCollatorState*)ctx.heap.alloc_func(ctx.heap.heap_udata, IntlCollatorState::size);
    if (state == null) { builtin_throw(ctx, ctx.heap.err_proto, "Intl allocation failed"); return; }
    *state = settings;
    (*obj.extra_ptr()).host.class_id = (uint)id;
    (*obj.extra_ptr()).host.payload = state;
    ctx.heap.set_prototype(obj, proto);
    ctx.result_object(obj);
}

fn void builtin_intl_collator_resolved(BuiltinContext* ctx) @feat(INTL_COLLATOR) {
    IntlCollatorState* state = intl_collator_receiver(ctx);
    if (state == null) return;
    HObject* out = ctx.heap.alloc_object(ObjClass.OBJECT) ?? null;
    if (out == null) { builtin_throw(ctx, ctx.heap.err_proto, "Intl allocation failed"); return; }
    ctx.heap.set_prototype(out, ctx.heap.object_proto);
    char[][] sensitivities = {"base", "accent", "case", "variant"};
    char[][] case_firsts = {"false", "lower", "upper"};
    // The resolved locale keeps only the extension keys whose values it reports.
    char[64] buffer;
    LocaleBuf locale = { .data = buffer[..] };
    locale.add(state.us_locale ? "en-US" : "en");
    if (state.keep_case_first_ext || state.keep_numeric_ext) locale.add("-u");
    if (state.keep_case_first_ext) { locale.add("-kf"); if (state.case_first != 0) { locale.add_char('-'); locale.add(case_firsts[state.case_first]); } }
    if (state.keep_numeric_ext) { locale.add("-kn"); if (!state.numeric) locale.add("-false"); }
    intl_put_string(ctx.heap, out, "locale", locale.bytes());
    intl_put_string(ctx.heap, out, "usage", state.search ? "search" : "sort");
    intl_put_string(ctx.heap, out, "sensitivity", sensitivities[state.sensitivity]);
    TVal ignore; ignore.set_boolean(state.ignore_punctuation);
    intl_put(ctx.heap, out, "ignorePunctuation", ignore);
    intl_put_string(ctx.heap, out, "collation", "default");
    TVal numeric; numeric.set_boolean(state.numeric);
    intl_put(ctx.heap, out, "numeric", numeric);
    intl_put_string(ctx.heap, out, "caseFirst", case_firsts[state.case_first]);
    if (ctx.heap.has_error) { builtin_throw(ctx, ctx.heap.err_proto, "Intl allocation failed"); return; }
    ctx.result_object(out);
}

// The NFD code points of `s` in a buffer the caller frees. Canonically
// equivalent strings collate equal, so each operand is decomposed first.
// Strings are CESU-8, so surrogate pairs are combined while decoding.
fn uint* coll_decode_nfd(HString* s, int* out_len) @feat(INTL_COLLATOR) {
    uint n = 0;
    uint* cps = cesu8_to_codepoints(s.get_cstr(), s.blen, &n);
    if (cps == null) return null;
    if (n == 0) {
        *out_len = 0;
        return cps;
    }
    int nfd_len = 0;
    uint* nfd = unicode_bindings::unicode_normalize_simple(cps, (int)n, unicode_bindings::UNICODE_NFD, &nfd_len);
    mem::free(cps);
    *out_len = nfd_len;
    return nfd;
}

// Compares two strings at the collator's sensitivity.
fn void builtin_intl_collator_compare_call(BuiltinContext* ctx) @feat(INTL_COLLATOR) {
    IntlCollatorState* state = intl_collator_receiver(ctx);
    if (state == null) return;
    HString* a_str = builtin_to_string_vm(ctx, &ctx.regs[ctx.base_reg]);
    if (ctx.should_throw || a_str == null) { ctx.result_undefined(); return; }
    HString* b_str = builtin_to_string_vm(ctx, &ctx.regs[ctx.base_reg + 1]);
    if (ctx.should_throw || b_str == null) { ctx.result_undefined(); return; }
    int a_len = 0;
    int b_len = 0;
    uint* a = coll_decode_nfd(a_str, &a_len);
    uint* b = coll_decode_nfd(b_str, &b_len);
    defer {
        if (a != null) mem::free(a);
        if (b != null) mem::free(b);
    }
    if (a == null || b == null) { builtin_throw(ctx, ctx.heap.err_proto, "Intl allocation failed"); return; }
    ctx.result_number((double)coll_compare_cps(state, a, (usz)a_len, b, (usz)b_len));
}

// The bound `compare` getter: the same function for every read of one instance.
fn void builtin_intl_collator_compare_get(BuiltinContext* ctx) @feat(INTL_COLLATOR) {
    IntlCollatorState* state = intl_collator_receiver(ctx);
    if (state == null) return;
    if (state.bound_compare == null) {
        HObject* bound = ctx.heap.alloc_object(ObjClass.FUNCTION) ?? null;
        if (bound == null) { builtin_throw(ctx, ctx.heap.err_proto, "Intl allocation failed"); return; }
        ctx.heap.set_prototype(bound, ctx.heap.function_proto);
        (*bound.extra_ptr()).func.builtin_fn_index = (int)Builtin.BOUND_CALL.ordinal;
        TVal target; target.set_lightfunc((void*)(usz)Builtin.INTL_COLLATOR_COMPARE_CALL.ordinal);
        TVal receiver = ctx.regs[ctx.base_reg - 1];
        ctx.heap.tval_copy_ref(&(*bound.extra_ptr()).func.bound.target, &target);
        ctx.heap.tval_copy_ref(&(*bound.extra_ptr()).func.bound.this_arg, &receiver);
        bound.flags.is_bound = true; bound.flags.callable = true; bound.flags.constructable = false;
        set_func_ctor_name_length(bound, ctx.heap, "", 2);
        state.bound_compare = bound;
        ctx.heap.write_barrier_ptr((HObject*)receiver.get_heapptr(), bound);
    }
    ctx.result_object(state.bound_compare);
}

fn bool register_intl_collator(HObject* ns, Heap* hp) @feat(INTL_COLLATOR) {
    HObject* proto = hp.alloc_object(ObjClass.OBJECT) ?? null;
    HObject* ctor = hp.alloc_object(ObjClass.FUNCTION) ?? null;
    if (proto == null || ctor == null) return false;
    hp.set_prototype(proto, hp.object_proto); hp.set_prototype(ctor, hp.function_proto);
    (*ctor.extra_ptr()).func.builtin_fn_index = (int)Builtin.INTL_COLLATOR.ordinal;
    ctor.flags.callable = true; ctor.flags.constructable = true;
    set_func_ctor_name_length(ctor, hp, "Collator", 0);
    TVal v; v.set_object(proto); intl_put(hp, ctor, "prototype", v, (PropFlags){});
    v.set_object(ctor); intl_put(hp, proto, "constructor", v, hobject::PROP_FLAGS_WC); intl_put(hp, ns, "Collator", v, hobject::PROP_FLAGS_WC);
    HString* tag = builtin_intern_string(hp, INTL_COLLATOR_CLASS); v.set_string_borrowed(tag);
    proto.put_prop(ensure_tostringtag_symbol(hp), v, hobject::PROP_FLAGS_NWC, hp);
    if (hp.register_host_class((void*)&intl_finalize, (void*)&intl_mark, hp, tag, proto) < 0) return false;
    if (!register_string_proto_method(ctor, hp, "supportedLocalesOf", Builtin.INTL_SUPPORTED_LOCALES.ordinal)) return false;
    if (!register_string_proto_method(proto, hp, "resolvedOptions", Builtin.INTL_COLLATOR_RESOLVED.ordinal)) return false;
    if (!register_proto_getter_accessor(proto, hp, "compare", Builtin.INTL_COLLATOR_COMPARE_GET.ordinal)) return false;
    TVal? accessor = proto.get_prop(builtin_intern_string(hp, "compare"), hp);
    if (try value = accessor) set_func_ctor_name((HObject*)hobject::hobject_access_getter(value).get_heapptr(), hp, "get compare");
    return true;
}
