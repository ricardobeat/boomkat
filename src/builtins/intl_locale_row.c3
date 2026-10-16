module boomkat::builtins;
import boomkat::heap;
import boomkat::hstring;

// Each compact style holds 12 magnitudes (10^3 .. 10^14) x 6 plural categories.
const usz INTL_COMPACT_STYLE = 72;
const usz INTL_COMPACT_ROW = 2 * INTL_COMPACT_STYLE;
// Plural category slots in a compact block, in CLDR order.
const usz INTL_CATEGORY_OTHER = 5;

struct LocaleCurrency {
    bool found;
    ushort symbol;
    ushort narrow;
    ushort one;
    ushort other;
}

fn usz intl_row_count() {
    $if $feat(INTL_LOCALES):
        return INTL_EXTRA_ROWS.len + 1;
    $else
        return 1;
    $endif
}

// Row 0 is English. The other rows exist only in a build with INTL_LOCALES.
fn IntlLocaleRow intl_row(usz index) {
    $if $feat(INTL_LOCALES):
        if (index > 0) return INTL_EXTRA_ROWS[index - 1];
    $endif
    return INTL_EN_ROW;
}

// The NUL-terminated string at `offset` in the row's pool, or in the shared pool when the
// offset has 0x8000 set. The pools are sliced through pointers: slicing a const array at a
// runtime offset reads zeros in c3c.
fn char[] intl_row_text(usz index, ushort offset) {
    char* pool = &INTL_EN_STRINGS;
    usz total = INTL_EN_STRINGS.len;
    usz start = offset;
    $if $feat(INTL_LOCALES):
        if (index > 0) {
            if ((offset & 0x8000) != 0) {
                pool = &INTL_SHARED_STRINGS;
                total = INTL_SHARED_STRINGS.len;
                start = (usz)(offset & 0x7FFF);
            } else {
                pool = &INTL_EXTRA_STRINGS;
                total = INTL_EXTRA_STRINGS.len;
                start += INTL_EXTRA_POOL_AT[index - 1];
            }
        }
    $endif
    usz end = start;
    while (end < total && pool[end] != 0) end++;
    return pool[start:end - start];
}

// The blocks of a date row, in the order scripts/generate_intl_locales.py writes them. The
// index argument to intl_row_date_text selects one entry within the block.
enum IntlDateField {
    MONTHS,       // 12 per width: wide, abbreviated, narrow
    DAYS,         // 7 per width: wide, abbreviated, narrow; Sunday first
    ERAS,         // 2 per width: abbreviated, wide, narrow; BC then AD
    AMPM,         // AM, PM
    AMPM_NARROW,  // A, P
    DATE_STYLES,  // full, long, medium, short
    TIME_STYLES,  // full, long, medium, short
    GLUES,        // date-time joins by date style: {1} is the date, {0} the time
    SKELETONS,    // one pattern per INTL_DATE_PATTERNS entry, in its order
}

// The text of one date row entry, or empty when the row has none, for row 0, and in builds
// without locale rows. Callers fall back to the English data on empty.
fn char[] intl_row_date_text(usz row, IntlDateField field, usz index) {
    $if $feat(INTL_LOCALES):
        if (row > 0) {
            ushort offset = INTL_EXTRA_DATES[(row - 1) * INTL_DATE_ROW_SIZE + INTL_DATE_FIELD_AT[field.ordinal] + index];
            if (offset != 0) return intl_row_text(row, offset);
        }
    $endif
    return "";
}

fn ushort intl_row_compact_word(usz index, usz i) {
    $if $feat(INTL_LOCALES):
        if (index > 0) return INTL_EXTRA_COMPACT[(index - 1) * INTL_COMPACT_ROW + i];
    $endif
    return INTL_EN_COMPACT[i];
}

fn ushort intl_row_unit_word(usz index, usz i) {
    $if $feat(INTL_LOCALES):
        if (index > 0) return INTL_EXTRA_UNITS[(index - 1) * INTL_UNIT_ROW_SIZE + i];
    $endif
    return INTL_EN_UNITS[i];
}

// Currency codes pack five bits per letter, A = 1.
fn ushort intl_pack_code(char[] code) {
    return (ushort)(((code[0] - 64) << 10) | ((code[1] - 64) << 5) | (code[2] - 64));
}

// The row's override for a currency, or `found` false when the row uses the English text.
fn LocaleCurrency intl_row_currency(usz index, ushort packed) {
    LocaleCurrency none;
    $if $feat(INTL_LOCALES):
        if (index > 0) {
            usz at = INTL_EXTRA_CURRENCY_AT[index - 1];
            usz count = INTL_EXTRA_CURRENCIES[at];
            for (usz k = 0; k < count; k++) {
                usz base = at + 1 + k * 5;
                if (INTL_EXTRA_CURRENCIES[base] == packed) {
                    return { true, INTL_EXTRA_CURRENCIES[base + 1], INTL_EXTRA_CURRENCIES[base + 2],
                             INTL_EXTRA_CURRENCIES[base + 3], INTL_EXTRA_CURRENCIES[base + 4] };
                }
            }
        }
    $endif
    return none;
}

// Writes `lang[-script][-region]` (empty parts skipped) into `buf`.
fn char[] intl_join_tag(char[] buf, char[] lang, char[] script, char[] region) {
    usz n = 0;
    foreach (c : lang) buf[n++] = c;
    if (script.len > 0) {
        buf[n++] = '-';
        foreach (c : script) buf[n++] = c;
    }
    if (region.len > 0) {
        buf[n++] = '-';
        foreach (c : region) buf[n++] = c;
    }
    return buf[:n];
}

// ASCII case-insensitive equality of two tags, both in canonical case.
fn bool intl_tag_eq(char[] a, char[] b) {
    if (a.len != b.len) return false;
    for (usz i = 0; i < a.len; i++) {
        char x = a[i] >= 'A' && a[i] <= 'Z' ? (char)(a[i] + 32) : a[i];
        char y = b[i] >= 'A' && b[i] <= 'Z' ? (char)(b[i] + 32) : b[i];
        if (x != y) return false;
    }
    return true;
}

// The maximized form of a row's tag, written into `buf`.
fn char[] intl_row_maximal(usz row, char[] buf) {
    LocaleId id;
    id.parse(intl_row_text(row, intl_row(row).tag));
    id.maximize();
    return intl_join_tag(buf, id.lang(), id.scr(), id.reg());
}

// The row for a tag, or -1. The tag itself is tried first, then the row whose
// maximized tag matches the request's, preferring the same region ("zh-TW" takes
// zh-Hant-TW over zh-Hant), then the requested tag's truncations down to the language.
fn int intl_row_for_tag(char[] tag) {
    LocaleId requested;
    if (!requested.parse(tag)) return -1;
    usz rows = intl_row_count();
    char[32][8] buffers;
    char[] lang = requested.lang();
    char[] script = requested.scr();
    char[] region = requested.reg();
    for (usz r = 0; r < rows; r++) {
        if (intl_tag_eq(intl_row_text(r, intl_row(r).tag), intl_join_tag(buffers[0][..], lang, script, region))) return (int)r;
    }
    LocaleId maximal = requested;
    maximal.maximize();
    char[] full = intl_join_tag(buffers[1][..], maximal.lang(), maximal.scr(), maximal.reg());
    // Pass 0 wants the same region, pass 1 any region, pass 2 only the language and script.
    for (int pass = 0; pass < 3; pass++) {
        for (usz r = 0; r < rows; r++) {
            LocaleId row_id;
            row_id.parse(intl_row_text(r, intl_row(r).tag));
            if (pass == 0 && region.len > 0 && !intl_tag_eq(row_id.reg(), region)) continue;
            row_id.maximize();
            if (pass == 2) {
                if (intl_tag_eq(intl_join_tag(buffers[2][..], row_id.lang(), row_id.scr(), ""),
                                intl_join_tag(buffers[3][..], maximal.lang(), maximal.scr(), ""))) return (int)r;
            } else if (intl_tag_eq(intl_join_tag(buffers[2][..], row_id.lang(), row_id.scr(), row_id.reg()), full)) {
                return (int)r;
            }
        }
    }
    char[][3] truncations = {
        intl_join_tag(buffers[4][..], lang, "", region),
        intl_join_tag(buffers[5][..], lang, script, ""),
        intl_join_tag(buffers[6][..], lang, "", ""),
    };
    foreach (form : truncations) {
        for (usz r = 0; r < rows; r++) {
            if (intl_tag_eq(intl_row_text(r, intl_row(r).tag), form)) return (int)r;
        }
    }
    return -1;
}

// A unit's pattern: kind 0 is the one form, 1 the other form, 2 the per-unit pattern
// ("{0}/h"), for width 0 units, 1 unitsShort or 2 unitsNarrow. Empty when absent.
fn char[] intl_unit_form(usz row, usz unit, usz width, usz kind) {
    return intl_row_text(row, intl_row_unit_word(row, (unit * 3 + width) * 3 + kind));
}

// The compound-per pattern for a width, such as "{0} per {1}" or "{0}/{1}".
fn char[] intl_unit_compound(usz row, usz width) {
    return intl_row_text(row, intl_row_unit_word(row, INTL_UNIT_COMPOUND_PER + width));
}
