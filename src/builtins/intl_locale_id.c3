// Unicode locale identifiers (UTS #35 §3, ECMA-402 §6.2): parsing,
// canonicalization (alias replacement, extension ordering) and the Add/Remove
// Likely Subtags algorithms. The tables come from intl_locale_data.c3.
module boomkat::builtins;

const usz LOCALE_VARIANT_CAP = 40;
const usz LOCALE_EXT_CAP = 256;

// A parsed identifier. Casing is canonical: language and variants lowercase,
// script titlecase, region uppercase. `ext` holds every extension and the
// private-use sequence as lowercase subtags joined by '-', without a leading
// separator.
struct LocaleId {
    char[8] language;
    usz language_len;
    char[4] script;
    usz script_len;
    char[3] region;
    usz region_len;
    char[LOCALE_VARIANT_CAP * 9] variants;
    usz[LOCALE_VARIANT_CAP] variant_len;
    usz variant_count;
    char[LOCALE_EXT_CAP] ext;
    usz ext_len;
}

// One Unicode extension keyword to set (or remove) when rebuilding `ext`.
struct LocaleKeyword {
    char[2] key;
    char[64] value;
    usz value_len;
    bool remove;
}

struct LocaleBuf {
    char[] data;
    usz len;
    bool overflow;
}

fn void LocaleBuf.add(&self, char[] s) {
    if (self.len + s.len > self.data.len) { self.overflow = true; return; }
    for (usz i = 0; i < s.len; i++) self.data[self.len + i] = s[i];
    self.len += s.len;
}

fn void LocaleBuf.add_char(&self, char c) {
    if (self.len + 1 > self.data.len) { self.overflow = true; return; }
    self.data[self.len++] = c;
}

fn char[] LocaleBuf.bytes(&self) {
    return self.data[:self.len];
}

fn char locale_lower(char c) {
    return (c >= 'A' && c <= 'Z') ? (char)(c + 32) : c;
}

fn char locale_upper(char c) {
    return (c >= 'a' && c <= 'z') ? (char)(c - 32) : c;
}

fn int locale_compare(char[] a, char[] b) {
    usz n = a.len < b.len ? a.len : b.len;
    for (usz i = 0; i < n; i++) {
        if (a[i] != b[i]) return a[i] < b[i] ? -1 : 1;
    }
    return a.len == b.len ? 0 : (a.len < b.len ? -1 : 1);
}

// Slicing a const array at a run-time offset yields zeroed bytes in c3c, so
// the pool is sliced through a pointer.
fn char[] locale_pool(ushort offset) {
    char* base = &INTL_LOCALE_POOL;
    usz end = offset;
    while (base[end] != 0) end++;
    return base[offset:end - offset];
}

fn char[] locale_script_at(usz index) {
    char* base = &INTL_LIKELY_SCRIPTS;
    return base[index * 4:4];
}

// Binary search in a table of sorted (key, value) pool-offset pairs.
fn bool locale_pairs_find(ushort[] table, char[] key, char[]* value) {
    usz low = 0;
    usz high = table.len / 2;
    while (low < high) {
        usz mid = (low + high) / 2;
        int order = locale_compare(locale_pool(table[mid * 2]), key);
        if (order == 0) { *value = locale_pool(table[mid * 2 + 1]); return true; }
        if (order < 0) { low = mid + 1; } else { high = mid; }
    }
    return false;
}

// Region codes pack as 0-999 for UN M49 numbers and 1000 + 26 * a + b for two
// letters, which keeps them sortable in one ushort.
fn int locale_region_pack(char[] region) {
    if (region.len == 3) return (region[0] - '0') * 100 + (region[1] - '0') * 10 + (region[2] - '0');
    return 1000 + (locale_upper(region[0]) - 'A') * 26 + (locale_upper(region[1]) - 'A');
}

fn usz locale_region_unpack(int code, char[3]* out) {
    if (code < 1000) {
        (*out)[0] = (char)('0' + code / 100);
        (*out)[1] = (char)('0' + code / 10 % 10);
        (*out)[2] = (char)('0' + code % 10);
        return 3;
    }
    (*out)[0] = (char)('A' + (code - 1000) / 26);
    (*out)[1] = (char)('A' + (code - 1000) % 26);
    return 2;
}

fn char[] LocaleId.lang(&self) { return self.language[:self.language_len]; }
fn char[] LocaleId.scr(&self) { return self.script[:self.script_len]; }
fn char[] LocaleId.reg(&self) { return self.region[:self.region_len]; }
fn char[] LocaleId.variant(&self, usz i) { return self.variants[i * 9:self.variant_len[i]]; }
fn char[] LocaleId.extension(&self) { return self.ext[:self.ext_len]; }

fn void LocaleId.set_language(&self, char[] s) {
    foreach (i, c : s) self.language[i] = locale_lower(c);
    self.language_len = s.len;
}

fn void LocaleId.set_script(&self, char[] s) {
    foreach (i, c : s) self.script[i] = i == 0 ? locale_upper(c) : locale_lower(c);
    self.script_len = s.len;
}

fn void LocaleId.set_region(&self, char[] s) {
    foreach (i, c : s) self.region[i] = locale_upper(c);
    self.region_len = s.len;
}

fn bool LocaleId.has_variant(&self, char[] v) {
    for (usz i = 0; i < self.variant_count; i++) if (locale_equal_ci(self.variant(i), v)) return true;
    return false;
}

fn bool LocaleId.add_variant(&self, char[] v) {
    if (self.has_variant(v) || self.variant_count >= LOCALE_VARIANT_CAP) return false;
    usz i = self.variant_count++;
    for (usz j = 0; j < v.len; j++) self.variants[i * 9 + j] = locale_lower(v[j]);
    self.variant_len[i] = v.len;
    return true;
}

fn void LocaleId.remove_variant(&self, char[] v) {
    for (usz i = 0; i < self.variant_count; i++) {
        if (locale_compare(self.variant(i), v) != 0) continue;
        for (usz j = i; j + 1 < self.variant_count; j++) {
            for (usz k = 0; k < 9; k++) self.variants[j * 9 + k] = self.variants[(j + 1) * 9 + k];
            self.variant_len[j] = self.variant_len[j + 1];
        }
        self.variant_count--;
        return;
    }
}

// Orders the variants bytewise ascending.
fn void LocaleId.sort_variants(&self) {
    for (usz i = 1; i < self.variant_count; i++) {
        for (usz j = i; j > 0; j--) {
            if (locale_compare(self.variant(j - 1), self.variant(j)) <= 0) break;
            for (usz k = 0; k < 9; k++) {
                char t = self.variants[j * 9 + k];
                self.variants[j * 9 + k] = self.variants[(j - 1) * 9 + k];
                self.variants[(j - 1) * 9 + k] = t;
            }
            usz n = self.variant_len[j];
            self.variant_len[j] = self.variant_len[j - 1];
            self.variant_len[j - 1] = n;
        }
    }
}

fn bool locale_is_script(char[] s) { return s.len == 4 && locale_all_alpha(s); }

fn bool locale_is_region(char[] s) {
    return (s.len == 2 && locale_all_alpha(s)) || (s.len == 3 && locale_all_digit(s));
}

fn bool locale_is_variant(char[] s) {
    return (s.len >= 5 && s.len <= 8 && locale_all_alnum(s)) ||
           (s.len == 4 && locale_is_digit(s[0]) && locale_all_alnum(s));
}

// Parses a tag that locale_is_well_formed accepted. Returns false when the
// tag does not fit the fixed buffers.
fn bool LocaleId.parse(&self, char[] tag) {
    *self = {};
    char[][40] parts;
    int n = locale_split(tag, &parts);
    if (n < 1) return false;
    self.set_language(parts[0]);
    int i = 1;
    if (i < n && locale_is_script(parts[i])) { self.set_script(parts[i]); i++; }
    if (i < n && locale_is_region(parts[i])) { self.set_region(parts[i]); i++; }
    while (i < n && locale_is_variant(parts[i])) {
        if (self.variant_count >= LOCALE_VARIANT_CAP) return false;
        usz v = self.variant_count++;
        for (usz j = 0; j < parts[i].len; j++) self.variants[v * 9 + j] = locale_lower(parts[i][j]);
        self.variant_len[v] = parts[i].len;
        i++;
    }
    for (; i < n; i++) {
        if (self.ext_len + parts[i].len + 1 > LOCALE_EXT_CAP) return false;
        if (self.ext_len > 0) self.ext[self.ext_len++] = '-';
        foreach (c : parts[i]) self.ext[self.ext_len++] = locale_lower(c);
    }
    return true;
}

// Writes the identifier as a BCP 47 tag.
fn void LocaleId.write(&self, LocaleBuf* out) {
    out.add(self.lang());
    if (self.script_len > 0) { out.add_char('-'); out.add(self.scr()); }
    if (self.region_len > 0) { out.add_char('-'); out.add(self.reg()); }
    for (usz i = 0; i < self.variant_count; i++) { out.add_char('-'); out.add(self.variant(i)); }
    if (self.ext_len > 0) { out.add_char('-'); out.add(self.extension()); }
}

// ---------------------------------------------------------------------------
// Likely subtags
// ---------------------------------------------------------------------------

fn uint locale_lang_pack(char[] lang) {
    uint v = 0;
    for (usz i = 0; i < 3; i++) v = v * 27 + (i < lang.len ? (uint)(locale_lower(lang[i]) - 96) : 0);
    return v;
}

fn usz locale_lang_unpack(uint v, char[8]* out) {
    char[3] letters;
    for (int i = 2; i >= 0; i--) { letters[i] = (char)(v % 27); v /= 27; }
    usz n = 0;
    for (usz i = 0; i < 3; i++) if (letters[i] != 0) (*out)[n++] = (char)(letters[i] + 96);
    return n;
}

// 1-based index of a script in the likely-subtags table, or 0.
fn uint locale_likely_script_index(char[] script) {
    for (usz i = 0; i + 4 <= INTL_LIKELY_SCRIPTS.len; i += 4) {
        if (locale_compare(locale_script_at(i / 4), script) == 0) return (uint)(i / 4) + 1;
    }
    return 0;
}

fn uint locale_likely_region_index(char[] region) {
    int code = locale_region_pack(region);
    for (usz i = 0; i < INTL_LIKELY_REGIONS.len; i++) if (INTL_LIKELY_REGIONS[i] == code) return (uint)i + 1;
    return 0;
}

// Looks up one key; `script` and `region` empty mean absent. Returns false
// when the table has no such entry (a script or region the table never names
// has no entry either).
fn bool locale_likely_find(char[] lang, char[] script, char[] region, uint* value) {
    uint s = 0;
    uint r = 0;
    if (script.len > 0) { s = locale_likely_script_index(script); if (s == 0) return false; }
    if (region.len > 0) { r = locale_likely_region_index(region); if (r == 0) return false; }
    uint key = (locale_lang_pack(lang) << 17) | (s << 9) | r;
    usz low = 0;
    usz high = INTL_LIKELY_KEYS.len;
    while (low < high) {
        usz mid = (low + high) / 2;
        if (INTL_LIKELY_KEYS[mid] == key) { *value = INTL_LIKELY_VALUES[mid]; return true; }
        if (INTL_LIKELY_KEYS[mid] < key) { low = mid + 1; } else { high = mid; }
    }
    return false;
}

// Add Likely Subtags (UTS #35 §4.3), looking up language_script_region,
// language_script, language_region, language and und_script in that order.
fn void LocaleId.maximize(&self) {
    bool und = locale_compare(self.lang(), "und") == 0;
    if (!und && self.script_len > 0 && self.region_len > 0) return;
    char[] lang = self.lang();
    uint value;
    bool found = false;
    if (self.script_len > 0 && self.region_len > 0) found = locale_likely_find(lang, self.scr(), self.reg(), &value);
    if (!found && self.script_len > 0) found = locale_likely_find(lang, self.scr(), "", &value);
    if (!found && self.region_len > 0) found = locale_likely_find(lang, "", self.reg(), &value);
    if (!found) found = locale_likely_find(lang, "", "", &value);
    if (!found && !und && self.script_len > 0) found = locale_likely_find("und", self.scr(), "", &value);
    if (!found) return;
    if (und) {
        char[8] l;
        usz n = locale_lang_unpack(value >> 17, &l);
        self.set_language(l[:n]);
    }
    uint s = (value >> 9) & 0xFF;
    uint r = value & 0x1FF;
    if (self.script_len == 0 && s > 0) self.set_script(locale_script_at((usz)s - 1));
    if (self.region_len == 0 && r > 0) {
        char[3] text;
        usz n = locale_region_unpack(INTL_LIKELY_REGIONS[r - 1], &text);
        self.set_region(text[:n]);
    }
}

fn bool LocaleId.same_lsr(&self, LocaleId* other) {
    return locale_compare(self.lang(), other.lang()) == 0 && locale_compare(self.scr(), other.scr()) == 0 &&
           locale_compare(self.reg(), other.reg()) == 0;
}

// Remove Likely Subtags (UTS #35 §4.3): the shortest of language,
// language_region and language_script that maximizes back to the same triple.
fn void LocaleId.minimize(&self) {
    LocaleId max = *self;
    max.maximize();
    LocaleId trial = {};
    trial.set_language(max.lang());
    LocaleId probe = trial;
    probe.maximize();
    if (probe.same_lsr(&max)) { self.set_lsr(&trial); return; }
    if (max.region_len > 0) {
        trial.set_region(max.reg());
        probe = trial;
        probe.maximize();
        if (probe.same_lsr(&max)) { self.set_lsr(&trial); return; }
        trial.region_len = 0;
    }
    if (max.script_len > 0) {
        trial.set_script(max.scr());
        probe = trial;
        probe.maximize();
        if (probe.same_lsr(&max)) { self.set_lsr(&trial); return; }
    }
    self.set_lsr(&max);
}

fn void LocaleId.set_lsr(&self, LocaleId* from) {
    self.set_language(from.lang());
    self.set_script(from.scr());
    self.set_region(from.reg());
}

// ---------------------------------------------------------------------------
// Canonicalization
// ---------------------------------------------------------------------------

// Splits "a_b_c" in place into at most 4 slices.
fn int locale_split_underscore(char[] s, char[][] out) {
    int n = 0;
    usz start = 0;
    for (usz i = 0; i <= s.len; i++) {
        if (i == s.len || s[i] == '_') {
            if (n >= (int)out.len) return n;
            out[n++] = s[start..i - 1];
            start = i + 1;
        }
    }
    return n;
}

fn bool locale_equal_ci(char[] a, char[] b) {
    if (a.len != b.len) return false;
    for (usz i = 0; i < a.len; i++) if (locale_lower(a[i]) != locale_lower(b[i])) return false;
    return true;
}

// True when the identifier carries the subtag `sub` as its script, region or
// a variant.
fn bool LocaleId.has_subtag(&self, char[] sub) {
    if (locale_is_script(sub)) return locale_equal_ci(self.scr(), sub);
    if (locale_is_region(sub)) return locale_equal_ci(self.reg(), sub);
    return self.has_variant(sub);
}

// Applies a replacement such as "sr_Latn" or "und_alalc97": a language other
// than und replaces the language, and script and region fill in only where
// the identifier has none. Variants in the replacement are added.
fn void LocaleId.apply_replacement(&self, char[] replacement) {
    char[][8] parts;
    int n = locale_split_underscore(replacement, &parts);
    if (locale_compare(parts[0], "und") != 0) self.set_language(parts[0]);
    for (int i = 1; i < n; i++) {
        char[] p = parts[i];
        if (locale_is_script(p)) { if (self.script_len == 0) self.set_script(p); }
        else if (locale_is_region(p)) { if (self.region_len == 0) self.set_region(p); }
        else if (locale_is_variant(p)) { self.add_variant(p); }
    }
}

fn void LocaleId.alias_language(&self) {
    for (usz e = 0; e + 1 < INTL_LANGUAGE_COMPLEX_ALIASES.len; e += 2) {
        char[] key = locale_pool(INTL_LANGUAGE_COMPLEX_ALIASES[e]);
        char[][8] parts;
        int n = locale_split_underscore(key, &parts);
        if (locale_compare(parts[0], "und") != 0 && locale_compare(parts[0], self.lang()) != 0) continue;
        bool match = true;
        for (int i = 1; i < n && match; i++) match = self.has_subtag(parts[i]);
        if (!match) continue;
        for (int i = 1; i < n; i++) {
            if (locale_is_script(parts[i])) { self.script_len = 0; }
            else if (locale_is_region(parts[i])) { self.region_len = 0; }
            else { self.remove_variant(parts[i]); }
        }
        self.apply_replacement(locale_pool(INTL_LANGUAGE_COMPLEX_ALIASES[e + 1]));
        return;
    }
    char[] replacement;
    if (locale_pairs_find(INTL_LANGUAGE_ALIASES[..], self.lang(), &replacement)) self.apply_replacement(replacement);
}

// Territory aliases with several replacements take the region the language
// and script maximize to when it is on the list, and the first otherwise.
fn void LocaleId.alias_region(&self) {
    if (self.region_len == 0) return;
    int code = locale_region_pack(self.reg());
    usz low = 0;
    usz high = INTL_REGION_ALIASES.len / 2;
    while (low < high) {
        usz mid = (low + high) / 2;
        int key = (int)INTL_REGION_ALIASES[mid * 2];
        if (key != code) {
            if (key < code) { low = mid + 1; } else { high = mid; }
            continue;
        }
        uint value = INTL_REGION_ALIASES[mid * 2 + 1];
        if (value < 0x8000) {
            char[3] text;
            usz n = locale_region_unpack((int)value, &text);
            self.set_region(text[:n]);
            return;
        }
        char[] list = locale_pool((ushort)(value - 0x8000));
        LocaleId likely = {};
        likely.set_language(self.lang());
        if (self.script_len > 0) likely.set_script(self.scr());
        likely.maximize();
        char[] first = list[:2];
        usz start = 0;
        for (usz i = 0; i <= list.len; i++) {
            if (i < list.len && list[i] != ' ') continue;
            char[] candidate = list[start..i - 1];
            if (start == 0) first = candidate;
            if (locale_compare(candidate, likely.reg()) == 0) { self.set_region(candidate); return; }
            start = i + 1;
        }
        self.set_region(first);
        return;
    }
}

fn void LocaleId.alias_script_and_variants(&self) {
    char[] replacement;
    if (self.script_len > 0 && locale_pairs_find(INTL_SCRIPT_ALIASES[..], self.scr(), &replacement)) self.set_script(replacement);
    LocaleId source = *self;
    self.variant_count = 0;
    for (usz i = 0; i < source.variant_count; i++) {
        char[] v = source.variant(i);
        if (locale_pairs_find(INTL_VARIANT_ALIASES[..], v, &replacement)) v = replacement;
        self.add_variant(v);
    }
}

// CanonicalizeUnicodeLocaleId for the language, script, region and variants.
fn void LocaleId.canonicalize_base(&self) {
    self.alias_language();
    self.alias_script_and_variants();
    self.alias_region();
    self.sort_variants();
}

// ---------------------------------------------------------------------------
// Extensions
// ---------------------------------------------------------------------------

const usz LOCALE_TOKEN_CAP = 48;

struct LocaleTokens {
    char[] text;
    usz[LOCALE_TOKEN_CAP] start;
    usz[LOCALE_TOKEN_CAP] len;
    usz count;
}

fn void LocaleTokens.split(&self, char[] text) {
    self.text = text;
    self.count = 0;
    usz begin = 0;
    for (usz i = 0; i <= text.len; i++) {
        if (i < text.len && text[i] != '-') continue;
        if (self.count < LOCALE_TOKEN_CAP) {
            self.start[self.count] = begin;
            self.len[self.count] = i - begin;
            self.count++;
        }
        begin = i + 1;
    }
}

fn char[] LocaleTokens.at(&self, usz i) { return self.text[self.start[i]:self.len[i]]; }

// Tokens [from, to) as one string, still joined by '-' in the source.
fn char[] LocaleTokens.range(&self, usz from, usz to) {
    return self.text[self.start[from]..self.start[to - 1] + self.len[to - 1] - 1];
}

struct LocaleField {
    char[2] key;
    char[] value; // empty for an attribute-less or "true" keyword
}

const usz LOCALE_FIELD_CAP = 24;

struct LocaleFields {
    LocaleField[LOCALE_FIELD_CAP] items;
    usz count;
}

// Adds a field unless its key is already present (the first occurrence wins).
fn bool LocaleFields.add(&self, char[] key, char[] value) {
    for (usz i = 0; i < self.count; i++) {
        if (self.items[i].key[0] == key[0] && self.items[i].key[1] == key[1]) return false;
    }
    if (self.count >= LOCALE_FIELD_CAP) return false;
    self.items[self.count].key = { key[0], key[1] };
    self.items[self.count].value = value;
    self.count++;
    return true;
}

fn void LocaleFields.sort(&self) {
    for (usz i = 1; i < self.count; i++) {
        for (usz j = i; j > 0; j--) {
            LocaleField* a = &self.items[j - 1];
            LocaleField* b = &self.items[j];
            if (locale_compare(a.key[:2], b.key[:2]) <= 0) break;
            LocaleField t = *a;
            *a = *b;
            *b = t;
        }
    }
}

fn bool locale_is_tkey(char[] s) {
    return s.len == 2 && locale_is_alpha(s[0]) && locale_is_digit(s[1]);
}

// Looks up "key:value" in a keyword alias table.
fn char[] locale_keyword_alias(ushort[] table, char[] key, char[] value) {
    char[64] probe;
    if (value.len + 3 > probe.len) return value;
    probe[0] = key[0];
    probe[1] = key[1];
    probe[2] = ':';
    foreach (i, c : value) probe[3 + i] = c;
    char[] replacement;
    if (locale_pairs_find(table, probe[:value.len + 3], &replacement)) return replacement;
    return value;
}

// The canonical value of a -u- keyword: aliases replaced and "true" dropped.
fn char[] locale_u_value(char[] key, char[] value) {
    char[] canonical = locale_keyword_alias(INTL_KEYWORD_ALIASES[..], key, value);
    if (key[0] == 's' && key[1] == 'd' || key[0] == 'r' && key[1] == 'g') {
        char[] replacement;
        if (locale_pairs_find(INTL_SUBDIVISION_ALIASES[..], canonical, &replacement)) canonical = replacement;
    }
    return locale_compare(canonical, "true") == 0 ? "" : canonical;
}

// Canonical form of a -u- block's subtags in `tokens` [from, to), with the
// keyword `overrides` applied. Attributes are sorted and deduplicated,
// keywords are sorted by key with the first occurrence of a key winning.
fn void locale_canon_u(LocaleTokens* tokens, usz from, usz to, LocaleKeyword[] overrides, LocaleBuf* out) {
    usz i = from;
    char[][LOCALE_TOKEN_CAP] attributes;
    usz attribute_count = 0;
    while (i < to && tokens.len[i] != 2) {
        char[] a = tokens.at(i++);
        bool seen = false;
        for (usz k = 0; k < attribute_count; k++) if (locale_compare(attributes[k], a) == 0) seen = true;
        if (!seen) attributes[attribute_count++] = a;
    }
    for (usz x = 1; x < attribute_count; x++) {
        for (usz y = x; y > 0 && locale_compare(attributes[y - 1], attributes[y]) > 0; y--) {
            char[] t = attributes[y];
            attributes[y] = attributes[y - 1];
            attributes[y - 1] = t;
        }
    }
    LocaleFields fields;
    fields.count = 0;
    while (i < to) {
        char[] key = tokens.at(i++);
        usz value_from = i;
        while (i < to && tokens.len[i] != 2) i++;
        char[] value = i > value_from ? locale_u_value(key, tokens.range(value_from, i)) : "";
        fields.add(key, value);
    }
    foreach (&o : overrides) {
        if (o.key[0] == 0) continue;
        bool found = false;
        for (usz k = 0; k < fields.count; k++) {
            LocaleField* f = &fields.items[k];
            if (f.key[0] != o.key[0] || f.key[1] != o.key[1]) continue;
            found = true;
            if (o.remove) {
                for (usz m = k; m + 1 < fields.count; m++) fields.items[m] = fields.items[m + 1];
                fields.count--;
            } else {
                f.value = locale_u_value(o.key[:2], o.value[:o.value_len]);
            }
            break;
        }
        if (!found && !o.remove) fields.add(o.key[:2], locale_u_value(o.key[:2], o.value[:o.value_len]));
    }
    fields.sort();
    if (attribute_count == 0 && fields.count == 0) return;
    out.add_char('u');
    for (usz k = 0; k < attribute_count; k++) { out.add_char('-'); out.add(attributes[k]); }
    for (usz k = 0; k < fields.count; k++) {
        out.add_char('-');
        out.add(fields.items[k].key[:2]);
        if (fields.items[k].value.len > 0) { out.add_char('-'); out.add(fields.items[k].value); }
    }
}

// Canonical form of a -t- block: the tlang canonicalized and lowercased, then
// the tfields sorted by key with deprecated values replaced.
fn void locale_canon_t(LocaleTokens* tokens, usz from, usz to, LocaleBuf* out) {
    usz i = from;
    usz lang_end = from;
    while (lang_end < to && !locale_is_tkey(tokens.at(lang_end))) lang_end++;
    out.add_char('t');
    if (lang_end > from) {
        LocaleId id;
        if (id.parse(tokens.range(from, lang_end))) {
            id.canonicalize_base();
            char[LOCALE_EXT_CAP] scratch;
            LocaleBuf text = { scratch[..], 0, false };
            id.write(&text);
            out.add_char('-');
            foreach (c : text.bytes()) out.add_char(locale_lower(c));
        }
    }
    i = lang_end;
    LocaleFields fields;
    fields.count = 0;
    while (i < to) {
        char[] key = tokens.at(i++);
        usz value_from = i;
        while (i < to && !locale_is_tkey(tokens.at(i))) i++;
        char[] value = tokens.range(value_from, i);
        fields.add(key, locale_keyword_alias(INTL_TFIELD_ALIASES[..], key, value));
    }
    fields.sort();
    for (usz k = 0; k < fields.count; k++) {
        out.add_char('-');
        out.add(fields.items[k].key[:2]);
        out.add_char('-');
        out.add(fields.items[k].value);
    }
}

// Rebuilds `ext` in canonical order: extensions by singleton, private use
// last. Returns false when the result does not fit.
fn bool LocaleId.canonicalize_ext(&self, LocaleKeyword[] overrides = {}) {
    char[LOCALE_EXT_CAP] copy;
    foreach (i, c : self.extension()) copy[i] = c;
    LocaleTokens tokens;
    tokens.split(copy[:self.ext_len]);
    if (self.ext_len == 0) tokens.count = 0;

    char[LOCALE_EXT_CAP * 2] scratch;
    LocaleBuf segments = { scratch[..], 0, false };
    usz[24] seg_start;
    usz[24] seg_len;
    char[24] seg_sing;
    usz seg_count = 0;
    usz private_from = tokens.count;
    bool has_u = false;

    usz i = 0;
    while (i < tokens.count) {
        char sing = tokens.at(i)[0];
        usz end = i + 1;
        while (end < tokens.count && tokens.len[end] != 1) end++;
        if (sing == 'x') { private_from = i; break; }
        if (sing == 'u') has_u = true;
        if (seg_count < 24) {
            seg_start[seg_count] = segments.len;
            seg_sing[seg_count] = sing;
            if (sing == 'u') { locale_canon_u(&tokens, i + 1, end, overrides, &segments); }
            else if (sing == 't') { locale_canon_t(&tokens, i + 1, end, &segments); }
            else { segments.add(tokens.range(i, end)); }
            seg_len[seg_count] = segments.len - seg_start[seg_count];
            seg_count++;
        }
        i = end;
    }
    if (!has_u) {
        // Keywords requested for a tag without a -u- block start one.
        LocaleTokens none;
        none.count = 0;
        usz before = segments.len;
        locale_canon_u(&none, 0, 0, overrides, &segments);
        if (segments.len > before && seg_count < 24) {
            seg_start[seg_count] = before;
            seg_sing[seg_count] = 'u';
            seg_len[seg_count] = segments.len - before;
            seg_count++;
        }
    }
    if (segments.overflow) return false;

    // Order the blocks by singleton; digits sort before letters.
    usz[24] order;
    for (usz k = 0; k < seg_count; k++) order[k] = k;
    for (usz x = 1; x < seg_count; x++) {
        for (usz y = x; y > 0 && seg_sing[order[y - 1]] > seg_sing[order[y]]; y--) {
            usz t = order[y];
            order[y] = order[y - 1];
            order[y - 1] = t;
        }
    }
    char[LOCALE_EXT_CAP] result;
    LocaleBuf out = { result[..], 0, false };
    for (usz k = 0; k < seg_count; k++) {
        if (k > 0) out.add_char('-');
        out.add(scratch[seg_start[order[k]]:seg_len[order[k]]]);
    }
    if (private_from < tokens.count) {
        if (out.len > 0) out.add_char('-');
        out.add(tokens.range(private_from, tokens.count));
    }
    if (out.overflow) return false;
    foreach (k, c : out.bytes()) self.ext[k] = c;
    self.ext_len = out.len;
    return true;
}

// CanonicalizeUnicodeLocaleId (ECMA-402 §6.2.1).
fn bool LocaleId.canonicalize(&self) {
    self.canonicalize_base();
    return self.canonicalize_ext();
}
