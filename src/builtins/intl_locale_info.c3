// Locale facts behind Intl.Locale's getters and get* methods (ECMA-402 §14.3):
// the region that selects calendar, hour cycle and week data, and the lists
// those data produce. Tables come from intl_region_data.c3.
module boomkat::builtins;

enum LocaleRegionData : int {
    CALENDAR,
    TIME,
    WEEK,
}

// The code of region 001 (the world), which holds every table's defaults.
const uint LOCALE_WORLD = 1;

const usz LOCALE_NAMES_CAP = 24;

struct LocaleNames {
    char[][LOCALE_NAMES_CAP] items;
    usz count;
}

fn void LocaleNames.add(&self, char[] name) {
    if (self.count < LOCALE_NAMES_CAP) self.items[self.count++] = name;
}

// The nth name of a NUL-separated pool that starts with a NUL. The pools are
// sliced through a pointer: c3c reads zeros when a const array is sliced at a
// run-time offset.
fn char[] locale_pool_nth(char* pool, usz index) {
    usz pos = 1;
    for (; index > 0; index--) {
        while (pool[pos] != 0) pos++;
        pos++;
    }
    usz end = pos;
    while (pool[end] != 0) end++;
    return pool[pos:end - pos];
}

// Value for `key` in a table of sorted (key, value) pairs.
fn bool locale_pairs16_find(ushort[] pairs, uint key, uint* value) {
    usz low = 0;
    usz high = pairs.len / 2;
    while (low < high) {
        usz mid = (low + high) / 2;
        if (pairs[mid * 2] == key) { *value = pairs[mid * 2 + 1]; return true; }
        if (pairs[mid * 2] < key) { low = mid + 1; } else { high = mid; }
    }
    return false;
}

// Index of `key` in a sorted key array, or -1.
fn long locale_keys_find(uint[] keys, uint key) {
    usz low = 0;
    usz high = keys.len;
    while (low < high) {
        usz mid = (low + high) / 2;
        if (keys[mid] == key) return (long)mid;
        if (keys[mid] < key) { low = mid + 1; } else { high = mid; }
    }
    return -1;
}

fn long locale_keys16_find(ushort[] keys, uint key) {
    usz low = 0;
    usz high = keys.len;
    while (low < high) {
        usz mid = (low + high) / 2;
        if (keys[mid] == key) return (long)mid;
        if (keys[mid] < key) { low = mid + 1; } else { high = mid; }
    }
    return -1;
}

// The value of a -u- keyword in the identifier's extensions. A keyword with
// no value ("-u-kn") yields an empty slice.
fn bool LocaleId.keyword(&self, char[2] key, char[]* value) {
    if (self.ext_len == 0) return false;
    LocaleTokens tokens;
    tokens.split(self.extension());
    usz i = 0;
    while (i < tokens.count) {
        usz end = i + 1;
        while (end < tokens.count && tokens.len[end] != 1) end++;
        char singleton = tokens.at(i)[0];
        if (singleton == 'x') return false;
        if (singleton == 'u') {
            usz k = i + 1;
            while (k < end && tokens.len[k] != 2) k++;
            while (k < end) {
                char[] name = tokens.at(k);
                usz from = k + 1;
                usz to = from;
                while (to < end && tokens.len[to] != 2) to++;
                if (name[0] == key[0] && name[1] == key[1]) {
                    *value = to > from ? tokens.range(from, to) : (char[])"";
                    return true;
                }
                k = to;
            }
            return false;
        }
        i = end;
    }
    return false;
}

// The region a two-letter-prefixed subdivision ("usca", "gbzzzz") lies in.
fn bool locale_subdivision_region(char[] value, uint* code) {
    if (value.len < 2 || !locale_all_alpha(value[:2])) return false;
    *code = (uint)locale_region_pack(value[:2]);
    return true;
}

fn bool locale_region_has_data(LocaleRegionData kind, uint region) {
    uint ignored;
    switch (kind) {
        case CALENDAR: return locale_pairs16_find(INTL_CALENDAR_REGIONS[..], region, &ignored);
        case WEEK: return locale_pairs16_find(INTL_WEEK_REGIONS[..], region, &ignored);
        case TIME: return locale_keys_find(INTL_TIME_KEYS[..], region) >= 0;
    }
    return false;
}

// RegionPreference (ECMA-402 §14.1.1): the "rg" override when the table has
// data for it, the region subtag, the "sd" subdivision's region, the region
// Add Likely Subtags yields, and finally 001.
fn uint locale_region_preference(LocaleId* id, LocaleRegionData kind) {
    char[] value;
    uint code;
    if (id.keyword("rg", &value) && locale_subdivision_region(value, &code) && locale_region_has_data(kind, code)) return code;
    if (id.region_len > 0) return (uint)locale_region_pack(id.reg());
    if (id.keyword("sd", &value) && locale_subdivision_region(value, &code)) return code;
    LocaleId likely = *id;
    likely.maximize();
    return likely.region_len > 0 ? (uint)locale_region_pack(likely.reg()) : LOCALE_WORLD;
}

fn void locale_list_names(char* lists, usz offset, char* pool, LocaleNames* out) {
    usz count = lists[offset];
    for (usz i = 0; i < count; i++) out.add(locale_pool_nth(pool, lists[offset + 1 + i]));
}

fn void locale_calendars(LocaleId* id, LocaleNames* out) {
    uint region = locale_region_preference(id, CALENDAR);
    uint offset;
    if (!locale_pairs16_find(INTL_CALENDAR_REGIONS[..], region, &offset)) {
        (void)locale_pairs16_find(INTL_CALENDAR_REGIONS[..], LOCALE_WORLD, &offset);
    }
    locale_list_names(&INTL_CALENDAR_LISTS, offset, &INTL_CALENDAR_NAMES, out);
}

// Collation types of the language; unknown languages get the root's.
fn void locale_collations(LocaleId* id, LocaleNames* out) {
    usz offset = INTL_COLLATION_ROOT;
    if (id.language_len <= 3) {
        long at = locale_keys16_find(INTL_COLLATION_LANGS[..], locale_lang_pack(id.lang()));
        if (at >= 0) offset = INTL_COLLATION_LANG_LISTS[at];
    }
    locale_list_names(&INTL_COLLATION_LISTS, offset, &INTL_COLLATION_TYPES, out);
}

const char[][4] LOCALE_HOUR_CYCLES = { "h11", "h12", "h23", "h24" };

// Hour cycles in preference order: the language_region entry when the table
// has one, else the region's, else 001's.
fn void locale_hour_cycles(LocaleId* id, LocaleNames* out) {
    uint region = locale_region_preference(id, TIME);
    long at = -1;
    if (id.language_len <= 3) at = locale_keys_find(INTL_TIME_KEYS[..], (locale_lang_pack(id.lang()) << 11) | region);
    if (at < 0) at = locale_keys_find(INTL_TIME_KEYS[..], region);
    if (at < 0) at = locale_keys_find(INTL_TIME_KEYS[..], LOCALE_WORLD);
    if (at < 0) return;
    uint value = INTL_TIME_VALUES[at];
    for (uint i = 0; i < (value & 7); i++) out.add(LOCALE_HOUR_CYCLES[(value >> (3 + 2 * i)) & 3]);
}

// The numbering system the locale's language and region default to.
fn char[] locale_default_numbering(LocaleId* id) {
    if (id.language_len <= 3) {
        uint lang = locale_lang_pack(id.lang()) << 11;
        long at = -1;
        if (id.region_len > 0) at = locale_keys_find(INTL_NUMBERING_KEYS[..], lang | (uint)locale_region_pack(id.reg()));
        if (at < 0) at = locale_keys_find(INTL_NUMBERING_KEYS[..], lang);
        if (at >= 0) {
            char* pool = &INTL_NUMBERING_NAMES;
            usz end = INTL_NUMBERING_VALUES[at];
            usz begin = end;
            while (pool[end] != 0) end++;
            return pool[begin:end - begin];
        }
    }
    return "latn";
}

// First day of the week (1 = Monday) and the weekend as a day bit mask
// (bit d - 1 for day d) of the preferred region.
fn void locale_week(LocaleId* id, uint* first_day, uint* weekend) {
    uint region = locale_region_preference(id, WEEK);
    uint packed;
    if (!locale_pairs16_find(INTL_WEEK_REGIONS[..], region, &packed)) {
        (void)locale_pairs16_find(INTL_WEEK_REGIONS[..], LOCALE_WORLD, &packed);
    }
    *first_day = packed & 7;
    *weekend = packed >> 3;
}

// The tzdb zone indices of a region: the half-open range of
// INTL_ZONE_REGION_ZONES.
fn bool locale_region_zones(uint region, usz* from, usz* to) {
    long at = locale_keys16_find(INTL_ZONE_REGIONS[..], region);
    if (at < 0) return false;
    *from = INTL_ZONE_REGION_AT[at];
    *to = INTL_ZONE_REGION_AT[at + 1];
    return true;
}

// The script's writing direction, from the script the identifier maximizes to.
fn bool locale_is_rtl(LocaleId* id) {
    LocaleId likely = *id;
    likely.maximize();
    if (likely.script_len != 4) return false;
    char* scripts = INTL_RTL_SCRIPTS.ptr;
    for (usz i = 0; i + 4 <= INTL_RTL_SCRIPTS.len; i += 4) {
        if (locale_compare(scripts[i:4], likely.scr()) == 0) return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// Numbering systems (ECMA-402 §9.1.1 "nu" key)
// ---------------------------------------------------------------------------

const usz INTL_DIGIT_COUNT = INTL_DIGIT_NAME_AT.len;

fn char[] intl_digit_name(usz index) {
    char* pool = &INTL_DIGIT_NAMES;
    usz at = INTL_DIGIT_NAME_AT[index];
    usz end = at;
    while (pool[end] != 0) end++;
    return pool[at:end - at];
}

// Index of a numbering system NumberFormat renders, or -1.
fn long intl_digit_system(char[] name) {
    for (usz i = 0; i < INTL_DIGIT_COUNT; i++) {
        if (locale_compare(intl_digit_name(i), name) == 0) return (long)i;
    }
    return -1;
}

// The numbering system recorded in a service state: 0 is the default (latn),
// anything else is the system's index plus one.
fn usz intl_numbering_index(int stored) {
    return stored == 0 ? INTL_DIGIT_LATN : (usz)(stored - 1);
}

fn int intl_numbering_store(usz index) {
    return index == INTL_DIGIT_LATN ? 0 : (int)index + 1;
}

struct IntlNumbering {
    usz index;
    bool keep_extension; // the resolved locale keeps -u-nu-
}

// ResolveLocale for the "nu" key: the tag's keyword when its system is
// supported, replaced by a supported "numberingSystem" option. The keyword
// stays in the resolved locale only when the option does not override it.
// The option overrides a -u-nu- in the tag, which overrides the locale's default.
fn IntlNumbering intl_resolve_numbering(char[] tag, char[] option, bool has_option) {
    IntlNumbering result = { .index = INTL_DIGIT_LATN };
    long from_tag = -1;
    LocaleId id;
    char[] value;
    bool parsed = id.parse(tag);
    if (parsed && id.keyword("nu", &value)) from_tag = intl_digit_system(value);
    if (from_tag >= 0) {
        result.index = (usz)from_tag;
        result.keep_extension = true;
    } else if (parsed) {
        long from_locale = intl_digit_system(locale_default_numbering(&id));
        if (from_locale >= 0) result.index = (usz)from_locale;
    }
    long from_option = has_option ? intl_digit_system(option) : -1;
    if (from_option >= 0 && from_option != from_tag) {
        result.index = (usz)from_option;
        result.keep_extension = false;
    }
    return result;
}

// Replaces the ASCII digits of `src` with the system's digits.
fn usz intl_map_digits(usz system, char[] src, char[] dst) {
    uint zero = INTL_DIGIT_ZEROS[system];
    usz n = 0;
    foreach (c : src) {
        if (c < '0' || c > '9') { dst[n++] = c; continue; }
        uint cp = system == INTL_DIGIT_SCATTERED ? INTL_SCATTERED_DIGITS[c - '0'] : zero + (uint)(c - '0');
        if (cp < 0x800) {
            dst[n++] = (char)(0xC0 | (cp >> 6));
            dst[n++] = (char)(0x80 | (cp & 0x3F));
        } else if (cp < 0x10000) {
            dst[n++] = (char)(0xE0 | (cp >> 12));
            dst[n++] = (char)(0x80 | ((cp >> 6) & 0x3F));
            dst[n++] = (char)(0x80 | (cp & 0x3F));
        } else {
            dst[n++] = (char)(0xF0 | (cp >> 18));
            dst[n++] = (char)(0x80 | ((cp >> 12) & 0x3F));
            dst[n++] = (char)(0x80 | ((cp >> 6) & 0x3F));
            dst[n++] = (char)(0x80 | (cp & 0x3F));
        }
    }
    return n;
}

// The resolved locale: the language tag plus -u-nu- when the keyword is kept.
fn char[] intl_resolved_locale(char[] base, IntlNumbering numbering, char[] buffer) {
    usz n = 0;
    foreach (c : base) buffer[n++] = c;
    if (numbering.keep_extension) {
        foreach (c : "-u-nu-") buffer[n++] = c;
        foreach (c : intl_digit_name(numbering.index)) buffer[n++] = c;
    }
    return buffer[:n];
}
