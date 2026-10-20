// Intl.Collator (ECMA-402 §10) over the collations of ICU 78 / CLDR 48: the root order, every
// locale tailoring with each of its collation types, and the settings a tailoring carries
// (backwards secondary, caseFirst, alternate shifted, script reordering).
// Small builds use the root order; INTL_FULL adds locale tailorings.
//
// A string turns into collation elements in three steps: NFD, a longest-match lookup in the
// tailoring's chain of overlays (scripts/generate_intl_collation.py describes the tables), and
// numeric runs when numeric collation is on. Comparison follows ICU's
// CollationCompare::compareUpToQuaternary through the tertiary level.
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

// Bits of INTL_COLL_OVERLAY_FLAGS; caseFirst sits in bits 4-5.
const char COLL_FLAG_BACKWARDS @feat(INTL_COLLATOR) = 1;
const char COLL_FLAG_SHIFTED @feat(INTL_COLLATOR) = 2;
const char COLL_FLAG_CASE_LEVEL @feat(INTL_COLLATOR) = 4;
const char COLL_FLAG_NUMERIC @feat(INTL_COLLATOR) = 8;

// An element's primary is rank << 32 | a numeric sub-weight. ICU ends every string with a
// terminator whose weights sort below every real one.
const ulong COLL_END_PRIMARY @feat(INTL_COLLATOR) = 1UL << 32;
const ushort COLL_END_WEIGHT @feat(INTL_COLLATOR) = 0x0100;
const ushort COLL_COMMON_WEIGHT @feat(INTL_COLLATOR) = 0x0500;
const ushort COLL_NO_PARENT @feat(INTL_COLLATOR) = 0xFFFF;
// ICU splits a digit run into numbers of at most this many digits.
const usz COLL_NUMERIC_SEGMENT @feat(INTL_COLLATOR) = 254;

struct CollElement @feat(INTL_COLLATOR) {
    ulong primary;      // 0 for a primary-ignorable element
    ushort secondary;
    ushort tertiary;    // case bits in 0xC000
}

struct CollElements @feat(INTL_COLLATOR) {
    CollElement* items;
    usz len;
    usz cap;
}

fn bool CollElements.push(&self, ulong primary, ushort secondary, ushort tertiary) @feat(INTL_COLLATOR) {
    if (self.len == self.cap) {
        usz cap = self.cap == 0 ? 64 : self.cap * 2;
        CollElement* grown = (CollElement*)mem::realloc(self.items, (sz)(cap * CollElement::size));
        if (grown == null) return false;
        self.items = grown;
        self.cap = cap;
    }
    self.items[self.len++] = { primary, secondary, tertiary };
    return true;
}

fn void CollElements.free(&self) @feat(INTL_COLLATOR) {
    if (self.items != null) mem::free(self.items);
    self.items = null;
}

struct IntlCollatorState @feat(INTL_COLLATOR) {
    HObject* bound_compare; // read by the GC through intl_mark's offset-0 access
    char[96] locale;        // the resolved locale, with the extension keys it reports
    usz locale_len;
    ushort overlay;
    int collation;          // index into the type names, -1 for "default"
    bool search;
    int sensitivity;
    bool ignore_punctuation;
    bool numeric;
    int case_first;         // 0 false, 1 lower, 2 upper
}

// The string pools are sliced through pointers: a const array sliced at a runtime offset reads
// zeros under c3c 0.8.
fn char[] coll_pool_string(char* pool, usz at) @feat(INTL_COLLATOR) {
    usz end = at;
    while (pool[end] != 0) end++;
    return pool[at:end - at];
}

fn char[] coll_locale_name(usz index) @feat(INTL_COLLATOR) {
    return coll_pool_string(&INTL_COLL_LOCALE_NAMES, (usz)INTL_COLL_LOCALE_AT[index]);
}

fn char[] coll_type_name(usz index) @feat(INTL_COLLATOR) {
    return coll_pool_string(&INTL_COLL_TYPE_NAMES, (usz)INTL_COLL_TYPE_AT[index]);
}

fn uint coll_varint(usz* at) @feat(INTL_COLLATOR) {
    char* data = &INTL_COLL_DATA;
    uint value = 0;
    uint shift = 0;
    while (true) {
        char b = data[(*at)++];
        value |= (uint)(b & 0x7F) << shift;
        if ((b & 0x80) == 0) return value;
        shift += 7;
    }
}

// Applies a nonzero primary code: the zigzagged delta from the block's previous rank, plus 1.
fn uint coll_rank_step(uint rank, uint code) @feat(INTL_COLLATOR) {
    uint delta = code - 1;
    long step = (delta & 1) != 0 ? -(long)((delta + 1) >> 1) : (long)(delta >> 1);
    return (uint)((long)rank + step);
}

// The longest key found so far at one position, and where its elements start.
struct CollMatch @feat(INTL_COLLATOR) {
    usz len;
    usz at;
    uint rank;
    bool extendable;    // a discontiguous match may end on this key
}

// Looks for keys of overlay `overlay` that start at cps[pos] and beat `best`. The entries that
// share a first code point all sit in one block, so one block is scanned.
fn void coll_scan(usz overlay, uint* cps, usz n, usz pos, CollMatch* best) @feat(INTL_COLLATOR) {
    usz first = (usz)INTL_COLL_OVERLAY_BLOCKS[overlay];
    usz count = (usz)INTL_COLL_OVERLAY_COUNT[overlay];
    uint cp = cps[pos];
    usz low = first;
    usz high = first + count;
    while (low < high) {
        usz mid = low + (high - low) / 2;
        if (INTL_COLL_BLOCK_FIRST[mid] <= cp) {
            low = mid + 1;
        } else {
            high = mid;
        }
    }
    if (low == first) return;
    usz block = low - 1;
    usz at = (usz)INTL_COLL_BLOCK_AT[block];
    usz end = (usz)INTL_COLL_BLOCK_AT[block + 1];
    uint key = INTL_COLL_BLOCK_FIRST[block];
    uint rank = 0;
    while (at < end) {
        key += coll_varint(&at);
        if (key > cp) return;
        uint length_code = coll_varint(&at);
        usz extra = (usz)(length_code >> 1);
        bool match = key == cp && pos + 1 + extra <= n && 1 + extra > best.len;
        for (usz k = 0; k < extra; k++) {
            uint c = coll_varint(&at);
            if (match && cps[pos + 1 + k] != c) match = false;
        }
        if (match) *best = { 1 + extra, at, rank, (length_code & 1) != 0 };
        uint elements = coll_varint(&at);
        for (uint k = 0; k < elements; k++) {
            uint code = coll_varint(&at);
            if (code != 0) rank = coll_rank_step(rank, code);
            (void)coll_varint(&at);
        }
    }
}

// The longest key at cps[pos] in the overlay chain. A tie goes to the overlay nearest the
// tailoring.
fn void coll_chain_scan(ushort overlay, uint* cps, usz n, usz pos, CollMatch* best) @feat(INTL_COLLATOR) {
    for (ushort o = overlay; o != COLL_NO_PARENT; o = INTL_COLL_OVERLAY_PARENT[o]) {
        if ((usz)INTL_COLL_OVERLAY_MAXLEN[o] > best.len) coll_scan((usz)o, cps, n, pos, best);
    }
}

// Extends the match at cps[pos] across combining marks (UTS #10 S2.1.1-S2.1.3): each unblocked
// non-starter after it that completes a longer extendable key joins the match. A mark is blocked when a
// mark skipped before it has the same or a higher combining class. The joined marks move up next
// to the match, ahead of the skipped ones, so the caller steps over exactly best.len code points
// and the skipped marks keep their order.
fn void coll_discontiguous(ushort overlay, uint* cps, usz n, usz pos, CollMatch* best) @feat(INTL_COLLATOR) {
    usz end = pos + best.len;
    if (end >= n || unicode_bindings::unicode_combining_class(cps[end]) == 0) return;
    uint[INTL_COLL_MAX_KEY] key;
    usz key_len = best.len;
    if (key_len >= INTL_COLL_MAX_KEY) return;
    for (usz k = 0; k < key_len; k++) key[k] = cps[pos + k];
    int skipped_class = 0;
    for (usz j = end; j < n && key_len < INTL_COLL_MAX_KEY; j++) {
        int cc = unicode_bindings::unicode_combining_class(cps[j]);
        if (cc == 0) return;
        if (skipped_class >= cc) continue;
        key[key_len] = cps[j];
        CollMatch longer;
        coll_chain_scan(overlay, &key, key_len + 1, 0, &longer);
        if (longer.len != key_len + 1 || !longer.extendable) {
            skipped_class = cc;
            continue;
        }
        uint mark = cps[j];
        for (usz k = j; k > pos + key_len; k--) cps[k] = cps[k - 1];
        cps[pos + key_len] = mark;
        key_len++;
        *best = longer;
    }
}

// Appends the elements of the longest key at cps[pos] and returns how many code points it covers.
fn usz coll_lookup(ushort overlay, uint* cps, usz n, usz pos, CollElements* out, bool* ok) @feat(INTL_COLLATOR) {
    CollMatch best;
    coll_chain_scan(overlay, cps, n, pos, &best);
    if (best.len > 0) coll_discontiguous(overlay, cps, n, pos, &best);
    if (best.len == 0) {
        // Unassigned code points keep code point order above every assigned primary.
        ulong rank = (ulong)INTL_COLL_RANK_LOW + 1 + (ulong)cps[pos];
        if (!out.push(rank << 32, COLL_COMMON_WEIGHT, COLL_COMMON_WEIGHT)) *ok = false;
        return 1;
    }
    usz at = best.at;
    uint rank = best.rank;
    uint elements = coll_varint(&at);
    for (uint k = 0; k < elements; k++) {
        uint code = coll_varint(&at);
        ulong primary = 0;
        if (code != 0) {
            rank = coll_rank_step(rank, code);
            primary = (ulong)rank << 32;
        }
        uint weights = INTL_COLL_SECTER[coll_varint(&at)];
        if (!out.push(primary, (ushort)(weights >> 16), (ushort)(weights & 0xFFFF))) *ok = false;
    }
    return best.len;
}

// The value of a decimal digit (general category Nd), or -1.
fn int coll_digit(uint cp) @feat(INTL_COLLATOR) {
    if (cp < 0x30) return -1;
    usz low = 0;
    usz high = INTL_COLL_DIGIT_ZEROS.len;
    while (low < high) {
        usz mid = low + (high - low) / 2;
        if (INTL_COLL_DIGIT_ZEROS[mid] <= cp) {
            low = mid + 1;
        } else {
            high = mid;
        }
    }
    if (low == 0) return -1;
    uint zero = INTL_COLL_DIGIT_ZEROS[low - 1];
    return cp - zero < 10 ? (int)(cp - zero) : -1;
}

// Appends a digit run as numbers (ICU's appendNumericCEs): leading zeros drop, and each number of
// at most COLL_NUMERIC_SEGMENT digits sorts by length, then digit by digit, between the digit
// zero and digit one. Returns the run length.
fn usz coll_numeric(uint* cps, usz n, usz pos, CollElements* out, bool* ok) @feat(INTL_COLLATOR) {
    usz end = pos;
    while (end < n && coll_digit(cps[end]) >= 0) end++;
    ulong base = (ulong)INTL_COLL_DIGIT_RANK << 32;
    usz i = pos;
    while (i < end) {
        while (i < end - 1 && coll_digit(cps[i]) == 0) i++;
        usz len = end - i < COLL_NUMERIC_SEGMENT ? end - i : COLL_NUMERIC_SEGMENT;
        if (!out.push(base | (0x100 + (ulong)len), COLL_COMMON_WEIGHT, COLL_COMMON_WEIGHT)) *ok = false;
        for (usz k = 0; k < len; k++) {
            ulong digit = (ulong)coll_digit(cps[i + k]);
            if (!out.push(base | (digit + 1), COLL_COMMON_WEIGHT, COLL_COMMON_WEIGHT)) *ok = false;
        }
        i += len;
    }
    return end - pos;
}

// The collation elements of an NFD string, ending with the terminator. With alternate shifted,
// a variable element and the primary-ignorable elements after it are cleared: they would only
// count at the quaternary level, which ECMA-402 sensitivities never reach.
fn bool coll_elements(IntlCollatorState* state, uint* cps, usz n, CollElements* out) @feat(INTL_COLLATOR) {
    bool ok = true;
    usz pos = 0;
    while (pos < n && ok) {
        if (cps[pos] >= 0xD800 && cps[pos] <= 0xDFFF) cps[pos] = 0xFFFD;
        if (state.numeric && coll_digit(cps[pos]) >= 0) {
            pos += coll_numeric(cps, n, pos, out, &ok);
        } else {
            pos += coll_lookup(state.overlay, cps, n, pos, out, &ok);
        }
    }
    if (!ok || !out.push(COLL_END_PRIMARY, COLL_END_WEIGHT, COLL_END_WEIGHT)) return false;
    if (state.ignore_punctuation) {
        ulong merge = (ulong)INTL_COLL_MERGE_RANK << 32;
        ulong top = ((ulong)INTL_COLL_OVERLAY_VARIABLE[state.overlay] << 32) | 0xFFFFFFFF;
        bool after_variable = false;
        for (usz i = 0; i < out.len; i++) {
            CollElement* e = &out.items[i];
            if (e.primary > merge && e.primary <= top) {
                *e = {};
                after_variable = true;
            } else if (e.primary == 0 && after_variable) {
                *e = {};
            } else if (e.primary != 0) {
                after_variable = false;
            }
        }
    }
    return true;
}

// A primary moved by the tailoring's script reordering; the sub-weight stays.
fn ulong coll_reorder(ushort overlay, ulong primary) @feat(INTL_COLLATOR) {
    usz first = (usz)INTL_COLL_OVERLAY_RUNS[overlay];
    usz count = (usz)INTL_COLL_OVERLAY_RUN_COUNT[overlay];
    uint rank = (uint)(primary >> 32);
    for (usz r = first; r < first + count; r++) {
        if (rank >= INTL_COLL_REORDER_FROM[r] && rank - INTL_COLL_REORDER_FROM[r] < INTL_COLL_REORDER_COUNT[r]) {
            ulong moved = (ulong)(INTL_COLL_REORDER_TO[r] + (rank - INTL_COLL_REORDER_FROM[r]));
            return (moved << 32) | (primary & 0xFFFFFFFF);
        }
    }
    return primary;
}

fn uint coll_lower32(CollElement* e) @feat(INTL_COLLATOR) {
    return ((uint)e.secondary << 16) | (uint)e.tertiary;
}

// Compares two element lists, each ending with the terminator. Returns -1, 0 or 1.
fn int coll_compare_elements(IntlCollatorState* state, CollElement* a, CollElement* b) @feat(INTL_COLLATOR) {
    char flags = INTL_COLL_OVERLAY_FLAGS[state.overlay];
    int strength = state.sensitivity == COLL_ACCENT ? 2 : (state.sensitivity == COLL_VARIANT ? 3 : 1);
    bool case_level = state.sensitivity == COLL_CASE || (flags & COLL_FLAG_CASE_LEVEL) != 0;

    usz ia = 0;
    usz ib = 0;
    while (true) {
        ulong pa;
        ulong pb;
        do { pa = a[ia++].primary; } while (pa == 0);
        do { pb = b[ib++].primary; } while (pb == 0);
        if (pa != pb) {
            pa = coll_reorder(state.overlay, pa);
            pb = coll_reorder(state.overlay, pb);
            return pa < pb ? -1 : 1;
        }
        if (pa == COLL_END_PRIMARY) break;
    }

    if (strength >= 2) {
        if ((flags & COLL_FLAG_BACKWARDS) == 0) {
            ia = 0;
            ib = 0;
            while (true) {
                ushort sa;
                ushort sb;
                do { sa = a[ia++].secondary; } while (sa == 0);
                do { sb = b[ib++].secondary; } while (sb == 0);
                if (sa != sb) return sa < sb ? -1 : 1;
                if (sa == COLL_END_WEIGHT) break;
            }
        } else {
            // Backwards secondaries compare each segment between merge separators from its end.
            // Both strings have the same separators, or the primary level would have differed.
            ulong merge = (ulong)INTL_COLL_MERGE_RANK << 32;
            usz start_a = 0;
            usz start_b = 0;
            while (true) {
                usz limit_a = start_a;
                ulong p;
                while ((p = a[limit_a].primary) > merge || p == 0) limit_a++;
                usz limit_b = start_b;
                while (b[limit_b].primary > merge || b[limit_b].primary == 0) limit_b++;
                ia = limit_a;
                ib = limit_b;
                while (true) {
                    ushort sa = 0;
                    ushort sb = 0;
                    while (sa == 0 && ia > start_a) sa = a[--ia].secondary;
                    while (sb == 0 && ib > start_b) sb = b[--ib].secondary;
                    if (sa != sb) return sa < sb ? -1 : 1;
                    if (sa == 0) break;
                }
                if (p == COLL_END_PRIMARY) break;
                start_a = limit_a + 1;
                start_b = limit_b + 1;
            }
        }
    }

    if (case_level) {
        ia = 0;
        ib = 0;
        while (true) {
            uint la;
            uint lb;
            if (strength == 1) {
                // Primary strength skips the case of primary-ignorables, so "ä" stays equal to "a".
                do { la = coll_lower32(&a[ia]); ia++; } while (a[ia - 1].primary == 0 || la == 0);
                do { lb = coll_lower32(&b[ib]); ib++; } while (b[ib - 1].primary == 0 || lb == 0);
            } else {
                do { la = coll_lower32(&a[ia++]); } while (la <= 0xFFFF);
                do { lb = coll_lower32(&b[ib++]); } while (lb <= 0xFFFF);
            }
            uint ca = la & 0xC000;
            uint cb = lb & 0xC000;
            if (ca != cb) {
                if (state.case_first == 2) return ca < cb ? 1 : -1;
                return ca < cb ? -1 : 1;
            }
            if ((la >> 16) == COLL_END_WEIGHT) break;
        }
    }
    if (strength <= 2) return 0;

    // Without a case level, caseFirst keeps the case bits in the tertiary weight.
    bool with_case = !case_level && state.case_first != 0;
    uint mask = with_case ? 0xFF3F : 0x3F3F;
    bool upper_first = with_case && state.case_first == 2;
    ia = 0;
    ib = 0;
    while (true) {
        uint la;
        uint lb;
        uint ta;
        uint tb;
        do { la = coll_lower32(&a[ia++]); ta = la & mask; } while (ta == 0);
        do { lb = coll_lower32(&b[ib++]); tb = lb & mask; } while (tb == 0);
        if (ta != tb) {
            if (upper_first) {
                // The terminator stays lowest; a tertiary-only element keeps its case bits above
                // those of primary and secondary elements.
                if (ta > COLL_END_WEIGHT) ta = la > 0xFFFF ? ta ^ 0xC000 : ta + 0x4000;
                if (tb > COLL_END_WEIGHT) tb = lb > 0xFFFF ? tb ^ 0xC000 : tb + 0x4000;
            }
            return ta < tb ? -1 : 1;
        }
        if (ta == COLL_END_WEIGHT) break;
    }
    return 0;
}

// Compares two NFD code point strings under the collator. Returns -1, 0 or 1, or 2 when
// allocation fails.
fn int coll_compare_cps(IntlCollatorState* state, uint* a, usz an, uint* b, usz bn) @feat(INTL_COLLATOR) {
    CollElements ea;
    CollElements eb;
    defer {
        ea.free();
        eb.free();
    }
    if (!coll_elements(state, a, an, &ea) || !coll_elements(state, b, bn, &eb)) return 2;
    return coll_compare_elements(state, ea.items, eb.items);
}

fn IntlCollatorState* intl_collator_receiver(BuiltinContext* ctx) @feat(INTL_COLLATOR) {
    TVal v = ctx.regs[ctx.base_reg - 1];
    if (v.is_object()) {
        HObject* obj = (HObject*)v.get_heapptr();
        if (intl_has_brand(ctx.heap, obj, INTL_COLLATOR_CLASS)) {
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

fn int coll_locale_exact(char[] tag) @feat(INTL_COLLATOR) {
    for (usz i = 0; i < INTL_COLL_LOCALE_AT.len; i++) {
        if (intl_tag_eq(coll_locale_name(i), tag)) return (int)i;
    }
    return -1;
}

// The collation locale a language tag uses, or -1 when only root applies. The tag itself is
// tried first; a tag without a script then tries its likely script ("zh-TW" takes zh-Hant-TW);
// then the truncations down to the language.
fn int coll_locale_for(char[] tag) @feat(INTL_COLLATOR) {
    LocaleId id;
    if (!id.parse(tag)) return -1;
    char[] lang = id.lang();
    char[] script = id.scr();
    char[] region = id.reg();
    if (locale_equal_ci(lang, "und")) return -1;
    char[48][5] buffers;
    int found = coll_locale_exact(intl_join_tag(buffers[0][..], lang, script, region));
    if (found >= 0) return found;
    if (script.len == 0) {
        LocaleId maximal = id;
        maximal.maximize();
        if (region.len > 0) {
            found = coll_locale_exact(intl_join_tag(buffers[1][..], lang, maximal.scr(), region));
            if (found >= 0) return found;
        }
        found = coll_locale_exact(intl_join_tag(buffers[2][..], lang, maximal.scr(), ""));
        if (found >= 0) return found;
    }
    if (region.len > 0 && script.len > 0) {
        found = coll_locale_exact(intl_join_tag(buffers[3][..], lang, script, ""));
        if (found >= 0) return found;
    }
    return coll_locale_exact(intl_join_tag(buffers[4][..], lang, "", ""));
}

// Whether the Collator supports a tag: a locale row, or a collation tailoring.
fn bool coll_locale_supported(char[] tag) @feat(INTL_COLLATOR) {
    return intl_row_for_tag(tag) >= 0 || coll_locale_for(tag) >= 0;
}

// The overlay a collation locale uses for a type, or -1 when it does not have the type.
fn int coll_locale_overlay(usz locale, usz type) @feat(INTL_COLLATOR) {
    for (usz i = (usz)INTL_COLL_LOCALE_PAIRS_AT[locale]; i < (usz)INTL_COLL_LOCALE_PAIRS_AT[locale + 1]; i++) {
        ushort pair = INTL_COLL_LOCALE_PAIRS[i];
        if ((usz)(pair >> 10) == type) return (int)(pair & 0x3FF);
    }
    return -1;
}

// The type index of a collation name a locale can select (not "standard" or "search"), or -1.
fn int coll_selectable_type(char[] name) @feat(INTL_COLLATOR) {
    for (usz i = 0; i < INTL_COLL_TYPE_AT.len; i++) {
        if (i == INTL_COLL_TYPE_STANDARD || i == INTL_COLL_TYPE_SEARCH) continue;
        if (mem_eq_bytes(coll_type_name(i), name)) return (int)i;
    }
    return -1;
}

// The types Intl.supportedValuesOf("collation") reports, in sorted order.
fn usz coll_selectable_type_count() @feat(INTL_COLLATOR) {
    return INTL_COLL_TYPE_AT.len - 2;
}

fn char[] coll_selectable_type_name(usz index) @feat(INTL_COLLATOR) {
    usz i = 0;
    for (usz t = 0; t < INTL_COLL_TYPE_AT.len; t++) {
        if (t == INTL_COLL_TYPE_STANDARD || t == INTL_COLL_TYPE_SEARCH) continue;
        if (i++ == index) return coll_type_name(t);
    }
    return "";
}

// The resolved locale's base: the matching locale row's label, or else the collation locale,
// without a script the request did not name.
fn char[] coll_locale_label(char[] tag, int coll_locale, char[] buf) @feat(INTL_COLLATOR) {
    int row = intl_row_for_tag(tag);
    if (row >= 0) return intl_row_label((usz)row, intl_label_mode(tag, row), buf);
    LocaleId requested;
    requested.parse(tag);
    LocaleId found;
    found.parse(coll_locale_name((usz)coll_locale));
    char[] script = requested.scr().len == 0 ? (char[])"" : found.scr();
    return intl_join_tag(buf, found.lang(), script, found.reg());
}

// §10.1.2 InitializeCollator. Options are read in ECMA-402 order; the locale
// extension keys co, kf and kn fill in collation, caseFirst and numeric when
// no option replaces them. Returns false after throwing.
fn bool coll_initialize(BuiltinContext* ctx, TVal locales, TVal options, IntlCollatorState* out) @feat(INTL_COLLATOR) {
    IntlCollatorState settings = { .collation = -1 };
    HObject* supported = intl_locales(ctx, locales, IntlLocaleFilter.COLLATION);
    if (ctx.should_throw) return false;
    HObject* opts = intl_options_object(ctx, options);
    if (ctx.should_throw) return false;

    int usage = intl_choice(ctx, opts, "usage", {"sort", "search"});
    if (ctx.should_throw) return false;
    settings.search = usage == 1;
    (void)intl_choice(ctx, opts, "localeMatcher", {"best fit", "lookup"});
    if (ctx.should_throw) return false;

    // "collation" must have the type grammar; a value the locale does not have is ignored.
    TVal collation = intl_option(ctx, opts, "collation");
    if (ctx.should_throw) return false;
    char[16] collation_buf;
    char[] collation_option;
    bool has_collation_option = false;
    if (!collation.is_undefined()) {
        HString* cs = builtin_to_string_vm(ctx, &collation);
        if (ctx.should_throw || cs == null) return false;
        char[] text = cs.get_cstr()[:cs.blen];
        if (!coll_type_valid(text)) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "invalid collation");
            return false;
        }
        if (text.len <= collation_buf.len) {
            collation_buf[:text.len] = text[..];
            collation_option = collation_buf[:text.len];
            has_collation_option = true;
        }
    }

    TVal numeric = intl_option(ctx, opts, "numeric");
    if (ctx.should_throw) return false;
    // caseFirst: 0 false, 1 lower, 2 upper.
    int case_option = intl_choice(ctx, opts, "caseFirst", {"upper", "lower", "false"}, -1);
    if (ctx.should_throw) return false;

    char[] tag = "en-US";
    if (supported != null) {
        TVal? first = supported.get_prop(ctx.heap.int_to_hstring(0), ctx.heap);
        if (try v = first) {
            HString* s = (HString*)v.get_heapptr();
            tag = s.get_cstr()[:s.blen];
        }
    }
    LocaleId locale_id;
    bool has_tag_ext = locale_id.parse(tag);
    char[48] base_buf;
    char[] base = intl_join_tag(base_buf[..], locale_id.lang(), locale_id.scr(), locale_id.reg());
    int coll_locale = coll_locale_for(base);
    usz table_locale = coll_locale >= 0 ? (usz)coll_locale : (usz)coll_locale_exact("und");
    int default_overlay = coll_locale_overlay(table_locale, (usz)INTL_COLL_LOCALE_DEFAULT[table_locale]);

    // ResolveLocale: an extension value the locale supports applies, and stays in the resolved
    // locale unless a different supported option value replaces it.
    bool keep_co = false;
    bool keep_kn = false;
    bool keep_kf = false;
    char[] ext_value;
    if (has_tag_ext && locale_id.keyword("co", &ext_value)) {
        int type = coll_selectable_type(ext_value);
        if (type >= 0 && coll_locale_overlay(table_locale, (usz)type) >= 0) {
            settings.collation = type;
            keep_co = true;
        }
    }
    if (has_collation_option) {
        int type = coll_selectable_type(collation_option);
        if (type >= 0 && coll_locale_overlay(table_locale, (usz)type) >= 0 && type != settings.collation) {
            settings.collation = type;
            keep_co = false;
        }
    }
    // A search collator uses the locale's search tailoring; its collation reports "default".
    int overlay = default_overlay;
    if (settings.search) {
        overlay = coll_locale_overlay(table_locale, INTL_COLL_TYPE_SEARCH);
        settings.collation = -1;
        keep_co = false;
    } else if (settings.collation >= 0) {
        overlay = coll_locale_overlay(table_locale, (usz)settings.collation);
    }
    settings.overlay = (ushort)(overlay < 0 ? default_overlay : overlay);
    // The numeric and caseFirst defaults are the chosen tailoring's own: a type such as eor or
    // emoji does not inherit the locale's standard settings.
    char flags_default = INTL_COLL_OVERLAY_FLAGS[settings.overlay];
    settings.numeric = (flags_default & COLL_FLAG_NUMERIC) != 0;
    if (has_tag_ext && locale_id.keyword("kn", &ext_value)) {
        if (ext_value.len == 0 || locale_compare(ext_value, "true") == 0) {
            settings.numeric = true;
            keep_kn = true;
        } else if (locale_compare(ext_value, "false") == 0) {
            settings.numeric = false;
            keep_kn = true;
        }
    }
    if (!numeric.is_undefined()) {
        bool value = builtin_to_boolean(&numeric);
        if (value != settings.numeric) keep_kn = false;
        settings.numeric = value;
    }
    settings.case_first = (int)((flags_default >> 4) & 3);
    if (has_tag_ext && locale_id.keyword("kf", &ext_value)) {
        int value = -1;
        if (locale_compare(ext_value, "upper") == 0) {
            value = 2;
        } else if (locale_compare(ext_value, "lower") == 0) {
            value = 1;
        } else if (locale_compare(ext_value, "false") == 0) {
            value = 0;
        }
        if (value >= 0) {
            settings.case_first = value;
            keep_kf = true;
        }
    }
    if (case_option >= 0) {
        int value = case_option == 0 ? 2 : (case_option == 1 ? 1 : 0);
        if (value != settings.case_first) keep_kf = false;
        settings.case_first = value;
    }


    settings.sensitivity = intl_choice(ctx, opts, "sensitivity", {"base", "accent", "case", "variant"}, COLL_VARIANT);
    if (ctx.should_throw) return false;

    TVal ignore = intl_option(ctx, opts, "ignorePunctuation");
    if (ctx.should_throw) return false;
    settings.ignore_punctuation = ignore.is_undefined()
        ? (INTL_COLL_OVERLAY_FLAGS[settings.overlay] & COLL_FLAG_SHIFTED) != 0
        : builtin_to_boolean(&ignore);

    char[48] label_buf;
    LocaleBuf locale = { .data = settings.locale[..] };
    locale.add(coll_locale >= 0 || intl_row_for_tag(base) >= 0 ? coll_locale_label(base, coll_locale, label_buf[..]) : base);
    if (keep_co || keep_kf || keep_kn) locale.add("-u");
    if (keep_co) { locale.add("-co-"); locale.add(coll_type_name((usz)settings.collation)); }
    if (keep_kf) {
        char[][3] case_firsts = {"false", "lower", "upper"};
        locale.add("-kf-");
        locale.add(case_firsts[settings.case_first]);
    }
    if (keep_kn) { locale.add("-kn"); if (!settings.numeric) locale.add("-false"); }
    settings.locale_len = locale.len;
    *out = settings;
    return true;
}

fn void builtin_intl_collator(BuiltinContext* ctx) @feat(INTL_COLLATOR) {
    long id = intl_class_named(ctx.heap, INTL_COLLATOR_CLASS);
    HObject* proto = builtin_proto_from_new_target(ctx, ctx.heap.host_class_at((uint)id).proto);
    if (ctx.should_throw) return;
    IntlCollatorState settings;
    if (!coll_initialize(ctx, builtin_arg(ctx, 0), builtin_arg(ctx, 1), &settings)) return;

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
    char[][4] sensitivities = {"base", "accent", "case", "variant"};
    char[][3] case_firsts = {"false", "lower", "upper"};
    intl_put_string(ctx.heap, out, "locale", state.locale[:state.locale_len]);
    intl_put_string(ctx.heap, out, "usage", state.search ? "search" : "sort");
    intl_put_string(ctx.heap, out, "sensitivity", sensitivities[state.sensitivity]);
    TVal ignore; ignore.set_boolean(state.ignore_punctuation);
    intl_put(ctx.heap, out, "ignorePunctuation", ignore);
    intl_put_string(ctx.heap, out, "collation", state.collation < 0 ? "default" : coll_type_name((usz)state.collation));
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

// Compares two strings under a collator: -1, 0 or 1, or 2 after throwing for a failed allocation.
fn int coll_compare_strings(BuiltinContext* ctx, IntlCollatorState* state, HString* a_str, HString* b_str) @feat(INTL_COLLATOR) {
    int a_len = 0;
    int b_len = 0;
    uint* a = coll_decode_nfd(a_str, &a_len);
    uint* b = coll_decode_nfd(b_str, &b_len);
    defer {
        if (a != null) mem::free(a);
        if (b != null) mem::free(b);
    }
    int result = a == null || b == null ? 2 : coll_compare_cps(state, a, (usz)a_len, b, (usz)b_len);
    if (result == 2) builtin_throw(ctx, ctx.heap.err_proto, "Intl allocation failed");
    return result;
}

// The collator localeCompare uses when it gets neither locales nor options. The default locale
// is fixed, so it resolves once.
IntlCollatorState coll_default_state @feat(INTL_COLLATOR);
bool coll_default_ready @feat(INTL_COLLATOR);

// String.prototype.localeCompare (ECMA-402 §19.1.1): compares as the compare function of
// new Intl.Collator(locales, options) would, the arguments after `that` being locales and options.
fn void coll_locale_compare(BuiltinContext* ctx, HString* s, HString* that) @feat(INTL_COLLATOR) {
    TVal locales = builtin_arg(ctx, 1);
    TVal options = builtin_arg(ctx, 2);
    IntlCollatorState local;
    IntlCollatorState* state = &local;
    if (locales.is_undefined() && options.is_undefined()) {
        if (!coll_default_ready) {
            if (!coll_initialize(ctx, locales, options, &coll_default_state)) return;
            coll_default_ready = true;
        }
        state = &coll_default_state;
    } else if (!coll_initialize(ctx, locales, options, &local)) {
        return;
    }
    int result = coll_compare_strings(ctx, state, s, that);
    if (result != 2) ctx.result_number((double)result);
}

fn void builtin_intl_collator_compare_call(BuiltinContext* ctx) @feat(INTL_COLLATOR) {
    IntlCollatorState* state = intl_collator_receiver(ctx);
    if (state == null) return;
    HString* a_str = builtin_to_string_vm(ctx, &ctx.regs[ctx.base_reg]);
    if (ctx.should_throw || a_str == null) { ctx.result_undefined(); return; }
    HString* b_str = builtin_to_string_vm(ctx, &ctx.regs[ctx.base_reg + 1]);
    if (ctx.should_throw || b_str == null) { ctx.result_undefined(); return; }
    int result = coll_compare_strings(ctx, state, a_str, b_str);
    if (result != 2) ctx.result_number((double)result);
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
        TVal target; target.set_builtin(ctx.heap, Builtin.INTL_COLLATOR_COMPARE_CALL.ordinal);
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

fn void builtin_intl_collator_supported_locales(BuiltinContext* ctx) @feat(INTL_COLLATOR) {
    HObject* locales = intl_locales(ctx, builtin_arg(ctx, 0), IntlLocaleFilter.COLLATION);
    if (ctx.should_throw) return;
    HObject* opts = intl_options(ctx, builtin_arg(ctx, 1));
    if (ctx.should_throw) return;
    (void)intl_choice(ctx, opts, "localeMatcher", {"best fit", "lookup"});
    if (!ctx.should_throw) ctx.result_object(locales);
}

fn bool register_intl_collator(HObject* ns, Heap* hp) @feat(INTL_COLLATOR) {
    HObject* proto = hp.alloc_object(ObjClass.OBJECT) ?? null;
    HObject* ctor = hp.alloc_object(ObjClass.FUNCTION) ?? null;
    if (proto == null || ctor == null) return false;
    hp.named_intrinsic("Intl.Collator", proto);
    hp.set_prototype(proto, hp.object_proto); hp.set_prototype(ctor, hp.function_proto);
    (*ctor.extra_ptr()).func.builtin_fn_index = (int)Builtin.INTL_COLLATOR.ordinal;
    ctor.flags.callable = true; ctor.flags.constructable = true;
    set_func_ctor_name_length(ctor, hp, "Collator", 0);
    TVal v; v.set_object(proto); intl_put(hp, ctor, "prototype", v, (PropFlags){});
    v.set_object(ctor); intl_put(hp, proto, "constructor", v, hobject::PROP_FLAGS_WC); intl_put(hp, ns, "Collator", v, hobject::PROP_FLAGS_WC);
    HString* tag = builtin_intern_string(hp, INTL_COLLATOR_CLASS); v.set_string_borrowed(tag);
    proto.put_prop(ensure_tostringtag_symbol(hp), v, hobject::PROP_FLAGS_NWC, hp);
    if (hp.register_host_class((void*)&intl_finalize, (void*)&intl_mark, hp, tag, proto) < 0) return false;
    if (!register_string_proto_method(ctor, hp, "supportedLocalesOf", Builtin.INTL_COLLATOR_SUPPORTED_LOCALES.ordinal)) return false;
    if (!register_string_proto_method(proto, hp, "resolvedOptions", Builtin.INTL_COLLATOR_RESOLVED.ordinal)) return false;
    if (!register_proto_getter_accessor(proto, hp, "compare", Builtin.INTL_COLLATOR_COMPARE_GET.ordinal)) return false;
    TVal? accessor = proto.get_prop(builtin_intern_string(hp, "compare"), hp);
    if (try value = accessor) set_func_ctor_name((HObject*)hobject::hobject_access_getter(value).get_heapptr(), hp, "get compare");
    return true;
}
