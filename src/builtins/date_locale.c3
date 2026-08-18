/// Options-bag handling for Date.prototype.toLocaleString and its date-only
/// and time-only siblings.
///
/// This is not ECMA-402. There is no locale database, no CLDR and no Intl
/// object, because a locale database is far more data than an engine aimed at
/// small devices can carry. What is here is the part of ECMA-402 §11.1.2
/// CreateDateTimeFormat that does not need one: the argument validation, the
/// order of the property Gets, and the resolution of components into a
/// concrete format. Everything then renders through a single fixed locale,
/// the en-US-like one the engine already produced before options existed.
///
/// So a caller gets real, checkable option semantics (a bad option value
/// throws, a getter observes the documented Get order, `timeZone: "UTC"`
/// shifts the clock) against one locale's spelling of the month names. What a
/// caller does not get is a different locale's spelling.
module boomkat::builtins;
import boomkat::types;
import std::math;
import std::io;
import boomkat::heap;
import boomkat::hstring;
import boomkat::hobject;

/// Room for the widest format this file can produce: a full weekday name, a
/// full month name, a year past the four-digit range with an era suffix, a
/// full time and a zone label.
const int DATE_LOCALE_BUF = 128;

// ============================================================================
// Option value encodings
// ============================================================================

/// A component's requested width. NONE means the caller did not ask for the
/// component, which is distinct from asking for it in its default width.
const int DTF_NONE    = 0;
const int DTF_NUMERIC = 1;
const int DTF_2DIGIT  = 2;
const int DTF_LONG    = 3;
const int DTF_SHORT   = 4;
const int DTF_NARROW  = 5;

/// dateStyle / timeStyle. NONE means absent.
const int DTS_NONE   = 0;
const int DTS_FULL   = 1;
const int DTS_LONG   = 2;
const int DTS_MEDIUM = 3;
const int DTS_SHORT  = 4;

/// `required` in ECMA-402 §11.1.2: which half of the format the calling method
/// is about. It governs the defaults and which of dateStyle/timeStyle the
/// method will accept, not which components a caller may name.
const int DTF_REQ_DATE = 0;
const int DTF_REQ_TIME = 1;
const int DTF_REQ_ANY  = 2;

/// The resolved format, the engine's stand-in for a DateTime Format Record.
struct DateTimeFormatOpts {
    int weekday;
    int era;
    int year;
    int month;
    int day;
    int hour;
    int minute;
    int second;
    /// Digits of sub-second precision to show, 1 to 3, or 0 for none.
    int frac_digits;
    int time_zone_name;
    int date_style;
    int time_style;
    /// Tri-state hour12: -1 absent, 0 false, 1 true. Absent means the fixed
    /// locale's own preference, which is the 12-hour clock.
    int hour12;
    /// Offset from UTC in seconds for the requested zone. When
    /// `tz_is_explicit` is false this is the host zone sampled at the instant
    /// being formatted, which is what the no-options output has always used.
    long tz_offset_sec;
    bool tz_is_explicit;
    /// Label for `timeZoneName`: "UTC" for the UTC zone, else a GMT+HHMM
    /// rendering of the offset. The long widths spell the UTC zone out in
    /// full and leave every other zone on its offset, which is all an engine
    /// without a zone database can name it.
    char[8] tz_label;
    usz tz_label_len;
    bool tz_is_utc;
}

// ============================================================================
// Language tag validation (ECMA-402 §6.2.1 IsWellFormedLanguageTag)
// ============================================================================

/// True for an ASCII letter.
fn bool locale_is_alpha(char c) {
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z');
}

/// True for an ASCII digit.
fn bool locale_is_digit(char c) {
    return c >= '0' && c <= '9';
}

/// True when every character of `s` is an ASCII letter.
fn bool locale_all_alpha(char[] s) {
    foreach (c : s) if (!locale_is_alpha(c)) return false;
    return s.len > 0;
}

/// True when every character of `s` is an ASCII digit.
fn bool locale_all_digit(char[] s) {
    foreach (c : s) if (!locale_is_digit(c)) return false;
    return s.len > 0;
}

/// True when every character of `s` is an ASCII letter or digit.
fn bool locale_all_alnum(char[] s) {
    foreach (c : s) if (!locale_is_alpha(c) && !locale_is_digit(c)) return false;
    return s.len > 0;
}

/// Split `s` on '-' into subtags. Returns the count, or -1 if any subtag is
/// empty, which catches a leading, trailing or doubled separator.
fn int locale_split(char[] s, char[][] out_parts) {
    int n = 0;
    usz start = 0;
    for (usz i = 0; i <= s.len; i++) {
        if (i == s.len || s[i] == '-') {
            if (i == start) return -1;
            if (n >= (int)out_parts.len) return -1;
            out_parts[n] = s[start..i - 1];
            n++;
            start = i + 1;
        }
    }
    return n;
}

/// Case-insensitive ASCII compare of a subtag against a lowercase literal.
fn bool locale_eq_ci(char[] s, char[] lit) {
    if (s.len != lit.len) return false;
    for (usz i = 0; i < s.len; i++) {
        char c = s[i];
        if (c >= 'A' && c <= 'Z') c = (char)(c + 32);
        if (c != lit[i]) return false;
    }
    return true;
}

/// ECMA-402 §6.2.1 IsWellFormedLanguageTag, checking the `unicode_locale_id`
/// nonterminal of UTS #35 Part 1 Annex C.
///
/// Accepts a `unicode_language_id` (language, optional script, optional
/// region, any number of variants) followed by any number of singleton
/// extensions and an optional "-x-" private use sequence. Rejects the
/// backwards-compatibility grandfathered and "i-" tags, duplicate variant
/// subtags, and duplicate extension singletons, all of which §6.2.1 calls out
/// by name.
fn bool locale_is_well_formed(char[] tag) {
    if (tag.len == 0 || tag.len > 120) return false;
    char[][40] parts_buf;
    int n = locale_split(tag, &parts_buf);
    if (n < 1) return false;
    char[][] parts = parts_buf[:n];

    // A tag that is nothing but a private use sequence ("x-foo") is a
    // unicode_locale_id only via unicode_language_id, which requires a
    // language subtag, so it is not well formed here.
    int i = 0;

    // unicode_language_subtag: 2-3 or 5-8 alpha. The 4-alpha case is reserved
    // and the 1-alpha case is the legacy "i-klingon" form; both are rejected.
    char[] lang = parts[0];
    if (!locale_all_alpha(lang)) return false;
    if (lang.len < 2 || lang.len > 8 || lang.len == 4) return false;
    i = 1;

    // unicode_script_subtag: 4 alpha.
    if (i < n && parts[i].len == 4 && locale_all_alpha(parts[i])) i++;

    // unicode_region_subtag: 2 alpha or 3 digit.
    if (i < n) {
        char[] p = parts[i];
        if ((p.len == 2 && locale_all_alpha(p)) || (p.len == 3 && locale_all_digit(p))) i++;
    }

    // unicode_variant_subtag: 5-8 alphanum, or 4 chars starting with a digit.
    // §6.2.1 rejects a tag whose variants contain a duplicate.
    int variant_start = i;
    while (i < n) {
        char[] p = parts[i];
        bool is_variant = (p.len >= 5 && p.len <= 8 && locale_all_alnum(p)) ||
                          (p.len == 4 && locale_is_digit(p[0]) && locale_all_alnum(p));
        if (!is_variant) break;
        for (int j = variant_start; j < i; j++) {
            if (locale_eq_ci(parts[j], p)) return false;
        }
        i++;
    }

    // Extensions: a singleton subtag (one alphanum that is not "x") followed
    // by at least one 2-8 alphanum subtag. A singleton may not repeat.
    char[8] seen_singletons;
    int seen_count = 0;
    while (i < n) {
        char[] p = parts[i];
        if (p.len != 1) return false;
        char sing = p[0];
        if (sing >= 'A' && sing <= 'Z') sing = (char)(sing + 32);
        if (!locale_is_alpha(sing) && !locale_is_digit(sing)) return false;
        i++;
        if (sing == 'x') {
            // pu_extensions: one or more 1-8 alphanum subtags, to the end.
            if (i >= n) return false;
            while (i < n) {
                if (parts[i].len < 1 || parts[i].len > 8 || !locale_all_alnum(parts[i])) return false;
                i++;
            }
            return true;
        }
        for (int j = 0; j < seen_count; j++) {
            if (seen_singletons[j] == sing) return false;
        }
        if (seen_count < 8) { seen_singletons[seen_count] = sing; seen_count++; }
        // The "t" transformed extension may lead with a language id; every
        // extension form still reduces to 2-8 alphanum subtags here.
        int ext_subtags = 0;
        while (i < n && parts[i].len >= 2 && parts[i].len <= 8 && locale_all_alnum(parts[i])) {
            ext_subtags++;
            i++;
        }
        if (ext_subtags == 0) return false;
    }
    return true;
}

// ============================================================================
// locales argument (ECMA-402 §9.2.1 CanonicalizeLocaleList)
// ============================================================================

/// ECMA-402 §9.2.1 CanonicalizeLocaleList, run for its effects and its throws.
///
/// The resulting list is discarded: with one built-in locale there is nothing
/// to match against, and §9.2.7 ResolveLocale is free to fall back to the
/// default locale for any request. Validation still has to happen, because a
/// structurally invalid tag is a RangeError that callers do observe, and the
/// element Gets are visible to a Proxy or an accessor.
fn void date_canonicalize_locale_list(BuiltinContext* ctx, TVal* locales) {
    if (locales.is_undefined()) return;

    // A String is treated as a one-element list rather than being iterated as
    // an array of characters.
    if (locales.is_string()) {
        HString* tag = (HString*)locales.get_heapptr();
        if (tag == null) return;
        if (!locale_is_well_formed(tag.get_cstr()[:tag.blen])) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "invalid language tag");
        }
        return;
    }

    // ToObject: a primitive other than a String has no elements to speak of,
    // but null and undefined still have to throw a TypeError.
    if (locales.is_null()) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "locales is null");
        return;
    }
    if (!locales.is_object() || locales.get_heapptr() == null) {
        // Numbers, booleans and symbols box into objects with no index
        // properties, so the list comes out empty. Symbols throw on ToObject
        // in neither direction here; length is simply absent.
        return;
    }

    HObject* obj = (HObject*)locales.get_heapptr();
    HString* len_key = ctx.heap.str(heap::BuiltinStr.LENGTH);
    TVal? len_prop = builtins_generic_get(obj, len_key, ctx);
    if (ctx.should_throw) return;
    double len_num = 0.0;
    if (try lv = len_prop) {
        len_num = builtin_to_number_vm(ctx, &lv);
        if (ctx.should_throw) return;
    }
    if (math::is_nan(len_num) || len_num <= 0.0) return;
    if (len_num > 4294967295.0) len_num = 4294967295.0;
    long len = (long)len_num;

    for (long k = 0; k < len; k++) {
        HString* idx_key = ctx.heap.int_to_hstring(k);
        if (idx_key == null) continue;
        bool exists;
        if (!js_has_property(ctx.vm, ctx.heap, obj, idx_key, &exists)) {
            proxy_ctx_ok(ctx);
            return;
        }
        if (!exists) continue;
        TVal? elem_prop = builtins_generic_get(obj, idx_key, ctx);
        if (ctx.should_throw) return;
        TVal elem;
        if (try ev = elem_prop) { elem = ev; } else { continue; }
        // §9.2.1: an element that is neither a String nor an Object is a
        // TypeError, which is what keeps NaN from being read as the tag "nan".
        if (!elem.is_string() && !elem.is_object()) {
            builtin_throw(ctx, ctx.heap.type_err_proto, "locale must be a string or object");
            return;
        }
        HString* tag = builtin_to_string_vm(ctx, &elem);
        if (ctx.should_throw) return;
        if (tag == null) continue;
        if (!locale_is_well_formed(tag.get_cstr()[:tag.blen])) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "invalid language tag");
            return;
        }
    }
}

// ============================================================================
// Reading the options bag (ECMA-402 §9.2.11 GetOption)
// ============================================================================

/// One row of the option tables: the property name and the values it accepts,
/// each paired with the code it resolves to.
struct DateOptionValue {
    char[] name;
    int code;
}

/// ECMA-402 §9.2.11 GetOption with type string.
///
/// Gets the property, coerces to String, and matches it against `values`. A
/// value outside the list is a RangeError. Returns `DTF_NONE`-shaped 0 when
/// the property is absent, which every caller reads as "not requested".
fn int date_get_string_option(BuiltinContext* ctx, HObject* opts, char[] key,
                              DateOptionValue[] values) {
    if (opts == null) return 0;
    HString* k = builtin_intern_string(ctx.heap, key);
    TVal? prop = builtins_generic_get(opts, k, ctx);
    if (ctx.should_throw) return 0;
    TVal v;
    if (try pv = prop) { v = pv; } else { return 0; }
    if (v.is_undefined()) return 0;
    HString* s = builtin_to_string_vm(ctx, &v);
    if (ctx.should_throw) return 0;
    if (s != null) {
        char[] sv = s.get_cstr()[:s.blen];
        foreach (cand : values) {
            if (cand.name.len == sv.len && (sv.len == 0 || mem_eq_bytes(cand.name, sv))) {
                return cand.code;
            }
        }
    }
    builtin_throw(ctx, ctx.heap.range_err_proto, "invalid option value");
    return 0;
}

/// Byte-wise equality for two same-length slices.
fn bool mem_eq_bytes(char[] a, char[] b) {
    if (a.len != b.len) return false;
    for (usz i = 0; i < a.len; i++) if (a[i] != b[i]) return false;
    return true;
}

/// ECMA-402 §9.2.11 GetOption with type boolean: no value list, ToBoolean
/// rather than ToString, so it never throws for a bad value. Returns -1 when
/// the property is absent.
fn int date_get_boolean_option(BuiltinContext* ctx, HObject* opts, char[] key) {
    if (opts == null) return -1;
    HString* k = builtin_intern_string(ctx.heap, key);
    TVal? prop = builtins_generic_get(opts, k, ctx);
    if (ctx.should_throw) return -1;
    TVal v;
    if (try pv = prop) { v = pv; } else { return -1; }
    if (v.is_undefined()) return -1;
    return builtin_to_boolean(&v) ? 1 : 0;
}

/// Get a property and coerce it to a String, for options whose value space is
/// open (`timeZone`, `calendar`). Returns null when absent.
fn HString* date_get_raw_string_option(BuiltinContext* ctx, HObject* opts, char[] key) {
    if (opts == null) return null;
    HString* k = builtin_intern_string(ctx.heap, key);
    TVal? prop = builtins_generic_get(opts, k, ctx);
    if (ctx.should_throw) return null;
    TVal v;
    if (try pv = prop) { v = pv; } else { return null; }
    if (v.is_undefined()) return null;
    HString* s = builtin_to_string_vm(ctx, &v);
    if (ctx.should_throw) return null;
    return s;
}

// ============================================================================
// timeZone
// ============================================================================

/// Parse the UTC offset forms ECMA-402 §11.1.2 accepts for `timeZone`:
/// "+HH", "+HH:MM", "+HHMM" and the '-' and U+2212 signed equivalents.
/// Writes the offset in seconds and returns true on a match.
fn bool date_parse_offset_timezone(char[] s, long* out_sec) {
    if (s.len < 2) return false;
    long sign = 1;
    usz i = 0;
    if (s[0] == '+') {
        sign = 1; i = 1;
    } else if (s[0] == '-') {
        sign = -1; i = 1;
    } else {
        return false;
    }

    usz rest = s.len - i;
    long hh;
    long mm = 0;
    if (rest == 2) {
        if (!locale_all_digit(s[i..i + 1])) return false;
        hh = (long)(s[i] - '0') * 10 + (long)(s[i + 1] - '0');
    } else if (rest == 5 && s[i + 2] == ':') {
        if (!locale_all_digit(s[i..i + 1]) || !locale_all_digit(s[i + 3..i + 4])) return false;
        hh = (long)(s[i] - '0') * 10 + (long)(s[i + 1] - '0');
        mm = (long)(s[i + 3] - '0') * 10 + (long)(s[i + 4] - '0');
    } else if (rest == 4) {
        if (!locale_all_digit(s[i..i + 3])) return false;
        hh = (long)(s[i] - '0') * 10 + (long)(s[i + 1] - '0');
        mm = (long)(s[i + 2] - '0') * 10 + (long)(s[i + 3] - '0');
    } else {
        return false;
    }
    if (hh > 23 || mm > 59) return false;
    *out_sec = sign * (hh * 3600 + mm * 60);
    return true;
}

/// Resolve the `timeZone` option into a fixed offset.
///
/// ECMA-402 §11.1.2 rejects a zone the implementation does not have with a
/// RangeError, and that is what happens here for every named zone except
/// "UTC" and its aliases. Resolving "America/Sao_Paulo" needs the IANA
/// database this engine deliberately does not carry, and the alternative to
/// throwing is silently formatting the wrong instant, so it throws.
///
/// Accepted: "UTC", "GMT", "Etc/UTC", "Etc/GMT", "Universal", "Zulu", "Z"
/// (all case-insensitive, all offset zero) and the numeric offset forms.
fn void date_resolve_timezone(BuiltinContext* ctx, HObject* opts, DateTimeFormatOpts* fmt) {
    HString* tz = date_get_raw_string_option(ctx, opts, "timeZone");
    if (ctx.should_throw) return;
    if (tz == null) {
        fmt.tz_is_explicit = false;
        return;
    }
    char[] s = tz.get_cstr()[:tz.blen];

    if (locale_eq_ci(s, "utc") || locale_eq_ci(s, "gmt") || locale_eq_ci(s, "etc/utc") ||
        locale_eq_ci(s, "etc/gmt") || locale_eq_ci(s, "universal") || locale_eq_ci(s, "zulu") ||
        locale_eq_ci(s, "z")) {
        fmt.tz_is_explicit = true;
        fmt.tz_offset_sec = 0;
        fmt.tz_label[0] = 'U'; fmt.tz_label[1] = 'T'; fmt.tz_label[2] = 'C';
        fmt.tz_label_len = 3;
        fmt.tz_is_utc = true;
        return;
    }

    long off;
    if (date_parse_offset_timezone(s, &off)) {
        fmt.tz_is_explicit = true;
        fmt.tz_offset_sec = off;
        date_write_gmt_offset_label(fmt, off);
        return;
    }

    builtin_throw(ctx, ctx.heap.range_err_proto, "unsupported time zone");
}

/// Render an offset as the "GMT+HHMM" label `timeZoneName` shows, or the
/// bare "UTC" when the offset is zero.
fn void date_write_gmt_offset_label(DateTimeFormatOpts* fmt, long off_sec) {
    if (off_sec == 0) {
        fmt.tz_label[0] = 'U'; fmt.tz_label[1] = 'T'; fmt.tz_label[2] = 'C';
        fmt.tz_label_len = 3;
        fmt.tz_is_utc = true;
        return;
    }
    fmt.tz_is_utc = false;
    long a = off_sec < 0 ? -off_sec : off_sec;
    long hh = a / 3600;
    long mm = (a % 3600) / 60;
    fmt.tz_label[0] = 'G'; fmt.tz_label[1] = 'M'; fmt.tz_label[2] = 'T';
    fmt.tz_label[3] = off_sec < 0 ? '-' : '+';
    fmt.tz_label[4] = (char)('0' + (hh / 10));
    fmt.tz_label[5] = (char)('0' + (hh % 10));
    fmt.tz_label[6] = (char)('0' + (mm / 10));
    fmt.tz_label[7] = (char)('0' + (mm % 10));
    fmt.tz_label_len = 8;
}

// ============================================================================
// Resolving the whole bag (ECMA-402 §11.1.2 CreateDateTimeFormat)
// ============================================================================

/// The value lists of ECMA-402 Table 16, plus the dateStyle/timeStyle list.
fn DateOptionValue[] date_values_narrow_short_long() {
    static DateOptionValue[3] v = {
        { "narrow", DTF_NARROW }, { "short", DTF_SHORT }, { "long", DTF_LONG },
    };
    return v[..];
}

fn DateOptionValue[] date_values_numeric_2digit() {
    static DateOptionValue[2] v = {
        { "2-digit", DTF_2DIGIT }, { "numeric", DTF_NUMERIC },
    };
    return v[..];
}

fn DateOptionValue[] date_values_month() {
    static DateOptionValue[5] v = {
        { "2-digit", DTF_2DIGIT }, { "numeric", DTF_NUMERIC },
        { "narrow", DTF_NARROW }, { "short", DTF_SHORT }, { "long", DTF_LONG },
    };
    return v[..];
}

fn DateOptionValue[] date_values_timezonename() {
    static DateOptionValue[6] v = {
        { "short", DTF_SHORT }, { "long", DTF_LONG },
        { "shortOffset", DTF_SHORT }, { "longOffset", DTF_LONG },
        { "shortGeneric", DTF_SHORT }, { "longGeneric", DTF_LONG },
    };
    return v[..];
}

fn DateOptionValue[] date_values_style() {
    static DateOptionValue[4] v = {
        { "full", DTS_FULL }, { "long", DTS_LONG },
        { "medium", DTS_MEDIUM }, { "short", DTS_SHORT },
    };
    return v[..];
}

fn DateOptionValue[] date_values_locale_matcher() {
    static DateOptionValue[2] v = { { "lookup", 1 }, { "best fit", 2 } };
    return v[..];
}

fn DateOptionValue[] date_values_format_matcher() {
    static DateOptionValue[2] v = { { "basic", 1 }, { "best fit", 2 } };
    return v[..];
}

fn DateOptionValue[] date_values_hour_cycle() {
    static DateOptionValue[4] v = {
        { "h11", 11 }, { "h12", 12 }, { "h23", 23 }, { "h24", 24 },
    };
    return v[..];
}

/// ECMA-402 §11.1.2 CreateDateTimeFormat, minus everything that needs locale
/// data. Validates `locales`, then reads the options bag in the order the
/// spec lists so an accessor on the bag observes the documented sequence:
/// localeMatcher, calendar, numberingSystem, hour12, hourCycle, timeZone, the
/// Table 16 component rows in table order, formatMatcher, dateStyle,
/// timeStyle.
///
/// `required` is DTF_REQ_DATE for toLocaleDateString, DTF_REQ_TIME for
/// toLocaleTimeString, DTF_REQ_ANY for toLocaleString. `defaults` follows the
/// same split: it decides which components appear when the caller named none.
fn void date_resolve_options(BuiltinContext* ctx, TVal* locales, TVal* options,
                             int required, DateTimeFormatOpts* fmt) {
    *fmt = {};
    fmt.hour12 = -1;
    fmt.date_style = DTS_NONE;
    fmt.time_style = DTS_NONE;

    // §9.2.8 step 1: CanonicalizeLocaleList runs before the options bag is
    // even coerced, so a bad tag throws ahead of any Get on options.
    date_canonicalize_locale_list(ctx, locales);
    if (ctx.should_throw) return;

    // §9.2.10 CoerceOptionsToObject: undefined becomes an empty object, and a
    // primitive boxes rather than throwing. A null options bag is a TypeError
    // because ToObject(null) throws.
    HObject* opts = null;
    if (options != null && !options.is_undefined()) {
        if (options.is_null()) {
            builtin_throw(ctx, ctx.heap.type_err_proto, "options is null");
            return;
        }
        if (options.is_object() && options.get_heapptr() != null) {
            opts = (HObject*)options.get_heapptr();
        }
        // A boxed primitive carries none of these properties, so leaving
        // `opts` null gives the same answer as boxing it would.
    }

    (void)date_get_string_option(ctx, opts, "localeMatcher", date_values_locale_matcher());
    if (ctx.should_throw) return;

    // calendar and numberingSystem are the ResolutionOptionDescriptors of
    // §11.2.3: read, checked for being a well-formed Unicode type subtag, and
    // then resolved against locale data this engine does not have. Only
    // "gregory" and "latn" are available, and §9.2.7 ResolveLocale falls back
    // to them silently for anything else, so the value is read for its Get
    // and its shape check and then dropped.
    HString* cal = date_get_raw_string_option(ctx, opts, "calendar");
    if (ctx.should_throw) return;
    if (cal != null && !date_is_unicode_type_subtag(cal.get_cstr()[:cal.blen])) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "invalid calendar");
        return;
    }
    HString* nu = date_get_raw_string_option(ctx, opts, "numberingSystem");
    if (ctx.should_throw) return;
    if (nu != null && !date_is_unicode_type_subtag(nu.get_cstr()[:nu.blen])) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "invalid numberingSystem");
        return;
    }

    fmt.hour12 = date_get_boolean_option(ctx, opts, "hour12");
    if (ctx.should_throw) return;

    int hc = date_get_string_option(ctx, opts, "hourCycle", date_values_hour_cycle());
    if (ctx.should_throw) return;
    // §11.1.2: an explicit hour12 wins over hourCycle.
    if (fmt.hour12 < 0 && hc != 0) {
        fmt.hour12 = (hc == 11 || hc == 12) ? 1 : 0;
    }

    date_resolve_timezone(ctx, opts, fmt);
    if (ctx.should_throw) return;

    // Table 16 rows, in table order.
    fmt.weekday = date_get_string_option(ctx, opts, "weekday", date_values_narrow_short_long());
    if (ctx.should_throw) return;
    fmt.era = date_get_string_option(ctx, opts, "era", date_values_narrow_short_long());
    if (ctx.should_throw) return;
    fmt.year = date_get_string_option(ctx, opts, "year", date_values_numeric_2digit());
    if (ctx.should_throw) return;
    fmt.month = date_get_string_option(ctx, opts, "month", date_values_month());
    if (ctx.should_throw) return;
    fmt.day = date_get_string_option(ctx, opts, "day", date_values_numeric_2digit());
    if (ctx.should_throw) return;
    // dayPeriod resolves to a standalone "in the morning" style phrase that
    // needs locale data; it is read for its Get and its RangeError, then the
    // am/pm marker the hour12 clock already prints stands in for it.
    (void)date_get_string_option(ctx, opts, "dayPeriod", date_values_narrow_short_long());
    if (ctx.should_throw) return;
    fmt.hour = date_get_string_option(ctx, opts, "hour", date_values_numeric_2digit());
    if (ctx.should_throw) return;
    fmt.minute = date_get_string_option(ctx, opts, "minute", date_values_numeric_2digit());
    if (ctx.should_throw) return;
    fmt.second = date_get_string_option(ctx, opts, "second", date_values_numeric_2digit());
    if (ctx.should_throw) return;
    fmt.frac_digits = date_get_number_option(ctx, opts, "fractionalSecondDigits", 1, 3);
    if (ctx.should_throw) return;
    fmt.time_zone_name = date_get_string_option(ctx, opts, "timeZoneName", date_values_timezonename());
    if (ctx.should_throw) return;

    bool has_explicit = fmt.weekday != 0 || fmt.era != 0 || fmt.year != 0 ||
                        fmt.month != 0 || fmt.day != 0 || fmt.hour != 0 ||
                        fmt.minute != 0 || fmt.second != 0 || fmt.frac_digits != 0 ||
                        fmt.time_zone_name != 0;

    (void)date_get_string_option(ctx, opts, "formatMatcher", date_values_format_matcher());
    if (ctx.should_throw) return;

    fmt.date_style = date_get_string_option(ctx, opts, "dateStyle", date_values_style());
    if (ctx.should_throw) return;
    fmt.time_style = date_get_string_option(ctx, opts, "timeStyle", date_values_style());
    if (ctx.should_throw) return;

    if (fmt.date_style != DTS_NONE || fmt.time_style != DTS_NONE) {
        // §11.1.2: a style and an explicit component together is a TypeError,
        // as is a style the calling method has no room for.
        if (has_explicit) {
            builtin_throw(ctx, ctx.heap.type_err_proto,
                "dateStyle/timeStyle cannot be combined with component options");
            return;
        }
        if (required == DTF_REQ_DATE && fmt.time_style != DTS_NONE) {
            builtin_throw(ctx, ctx.heap.type_err_proto, "timeStyle is not valid here");
            return;
        }
        if (required == DTF_REQ_TIME && fmt.date_style != DTS_NONE) {
            builtin_throw(ctx, ctx.heap.type_err_proto, "dateStyle is not valid here");
            return;
        }
        date_expand_styles(fmt);
        return;
    }

    // §11.1.2 needDefaults: with no component named for the half of the
    // format this method covers, that half falls back to all-numeric.
    bool need_defaults = true;
    if (required == DTF_REQ_DATE || required == DTF_REQ_ANY) {
        if (fmt.weekday != 0 || fmt.year != 0 || fmt.month != 0 || fmt.day != 0) {
            need_defaults = false;
        }
    }
    if (required == DTF_REQ_TIME || required == DTF_REQ_ANY) {
        if (fmt.hour != 0 || fmt.minute != 0 || fmt.second != 0 || fmt.frac_digits != 0) {
            need_defaults = false;
        }
    }
    // `defaults` decides which half is filled in when the caller named
    // nothing. It does not restrict what the caller may name: §20.4.2 passes
    // date/date and still formats an explicitly requested hour, so a
    // component from the other half stays.
    if (need_defaults) {
        if (required == DTF_REQ_DATE || required == DTF_REQ_ANY) {
            fmt.year = DTF_NUMERIC;
            fmt.month = DTF_NUMERIC;
            fmt.day = DTF_NUMERIC;
        }
        if (required == DTF_REQ_TIME || required == DTF_REQ_ANY) {
            fmt.hour = DTF_NUMERIC;
            fmt.minute = DTF_NUMERIC;
            fmt.second = DTF_NUMERIC;
        }
    }
}

/// ECMA-402 §9.2.11 GetNumberOption: Get, ToNumber, then a range check that
/// throws RangeError outside [min, max]. Returns 0 when absent.
fn int date_get_number_option(BuiltinContext* ctx, HObject* opts, char[] key, int min, int max) {
    if (opts == null) return 0;
    HString* k = builtin_intern_string(ctx.heap, key);
    TVal? prop = builtins_generic_get(opts, k, ctx);
    if (ctx.should_throw) return 0;
    TVal v;
    if (try pv = prop) { v = pv; } else { return 0; }
    if (v.is_undefined()) return 0;
    double d = builtin_to_number_vm(ctx, &v);
    if (ctx.should_throw) return 0;
    if (math::is_nan(d) || d < (double)min || d > (double)max) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "option value out of range");
        return 0;
    }
    return (int)math::floor(d);
}

/// True for a Unicode `type` subtag: one or more 3-8 alphanum subtags.
/// §9.2.8 throws RangeError for a calendar or numberingSystem that does not
/// match this shape, before any question of whether the value is supported.
fn bool date_is_unicode_type_subtag(char[] s) {
    if (s.len == 0) return false;
    char[][8] parts_buf;
    int n = locale_split(s, &parts_buf);
    if (n < 1) return false;
    for (int i = 0; i < n; i++) {
        char[] p = parts_buf[i];
        if (p.len < 3 || p.len > 8 || !locale_all_alnum(p)) return false;
    }
    return true;
}

/// ECMA-402 §11.5.1 DateTimeStyleFormat, resolved against the one locale this
/// engine has. The component widths per style follow the en-US CLDR patterns:
/// full carries the weekday and the spelled-out month, long drops the
/// weekday, medium abbreviates the month, and short goes all-numeric with a
/// two-digit year. Times gain the zone label at long and full, and drop
/// seconds at short.
fn void date_expand_styles(DateTimeFormatOpts* fmt) {
    switch (fmt.date_style) {
        case DTS_FULL:
            fmt.weekday = DTF_LONG; fmt.year = DTF_NUMERIC;
            fmt.month = DTF_LONG; fmt.day = DTF_NUMERIC;
        case DTS_LONG:
            fmt.year = DTF_NUMERIC; fmt.month = DTF_LONG; fmt.day = DTF_NUMERIC;
        case DTS_MEDIUM:
            fmt.year = DTF_NUMERIC; fmt.month = DTF_SHORT; fmt.day = DTF_NUMERIC;
        case DTS_SHORT:
            fmt.year = DTF_2DIGIT; fmt.month = DTF_NUMERIC; fmt.day = DTF_NUMERIC;
        default:
            break;
    }
    switch (fmt.time_style) {
        case DTS_FULL:
            fmt.hour = DTF_NUMERIC; fmt.minute = DTF_2DIGIT; fmt.second = DTF_2DIGIT;
            fmt.time_zone_name = DTF_LONG;
        case DTS_LONG:
            fmt.hour = DTF_NUMERIC; fmt.minute = DTF_2DIGIT; fmt.second = DTF_2DIGIT;
            fmt.time_zone_name = DTF_SHORT;
        case DTS_MEDIUM:
            fmt.hour = DTF_NUMERIC; fmt.minute = DTF_2DIGIT; fmt.second = DTF_2DIGIT;
        case DTS_SHORT:
            fmt.hour = DTF_NUMERIC; fmt.minute = DTF_2DIGIT;
        default:
            break;
    }
}

// ============================================================================
// Rendering
// ============================================================================

/// Full month names, indexed 0-11.
fn char[] date_month_long(long m) {
    switch (m) {
        case 0:  return "January";
        case 1:  return "February";
        case 2:  return "March";
        case 3:  return "April";
        case 4:  return "May";
        case 5:  return "June";
        case 6:  return "July";
        case 7:  return "August";
        case 8:  return "September";
        case 9:  return "October";
        case 10: return "November";
        default: return "December";
    }
}

/// Abbreviated month names, indexed 0-11.
fn char[] date_month_short(long m) {
    switch (m) {
        case 0:  return "Jan";
        case 1:  return "Feb";
        case 2:  return "Mar";
        case 3:  return "Apr";
        case 4:  return "May";
        case 5:  return "Jun";
        case 6:  return "Jul";
        case 7:  return "Aug";
        case 8:  return "Sep";
        case 9:  return "Oct";
        case 10: return "Nov";
        default: return "Dec";
    }
}

/// Full weekday names, indexed 0-6 with 0 = Sunday.
fn char[] date_weekday_long(long w) {
    switch (w) {
        case 0:  return "Sunday";
        case 1:  return "Monday";
        case 2:  return "Tuesday";
        case 3:  return "Wednesday";
        case 4:  return "Thursday";
        case 5:  return "Friday";
        default: return "Saturday";
    }
}

/// Abbreviated weekday names, indexed 0-6 with 0 = Sunday.
fn char[] date_weekday_short(long w) {
    switch (w) {
        case 0:  return "Sun";
        case 1:  return "Mon";
        case 2:  return "Tue";
        case 3:  return "Wed";
        case 4:  return "Thu";
        case 5:  return "Fri";
        default: return "Sat";
    }
}

/// Append `s` to `buf` at `*pos`, stopping at the buffer end.
fn void date_buf_append(char[] buf, usz* pos, char[] s) {
    foreach (c : s) {
        if (*pos >= buf.len) return;
        buf[*pos] = c;
        (*pos)++;
    }
}

/// Append a single character.
fn void date_buf_push(char[] buf, usz* pos, char c) {
    if (*pos >= buf.len) return;
    buf[*pos] = c;
    (*pos)++;
}

/// Append a non-negative integer in decimal, zero-padded to at least
/// `min_digits`.
fn void date_buf_append_num(char[] buf, usz* pos, long v, int min_digits) {
    char[24] tmp;
    int n = 0;
    bool neg = v < 0;
    ulong a = neg ? (ulong)(-v) : (ulong)v;
    if (a == 0) { tmp[0] = '0'; n = 1; }
    while (a > 0) { tmp[n] = (char)('0' + (a % 10)); n++; a /= 10; }
    if (neg) date_buf_push(buf, pos, '-');
    for (int i = n; i < min_digits; i++) date_buf_push(buf, pos, '0');
    for (int i = n - 1; i >= 0; i--) date_buf_push(buf, pos, tmp[i]);
}

/// Render the date half into `buf`, returning true if it wrote anything.
///
/// The layout is the one en-US uses: a spelled-out month leads
/// ("January 15, 2024", with the weekday ahead of it when asked for) and a
/// numeric month goes month-first and slash-separated ("1/15/2024").
fn bool date_render_date_part(DateTimeFormatOpts* fmt, char[] buf, usz* pos,
                              long year, long month, long day, long wday) {
    bool spelled = fmt.month == DTF_LONG || fmt.month == DTF_SHORT || fmt.month == DTF_NARROW;
    bool wrote = false;

    if (fmt.weekday != DTF_NONE) {
        switch (fmt.weekday) {
            case DTF_LONG:   date_buf_append(buf, pos, date_weekday_long(wday));
            case DTF_SHORT:  date_buf_append(buf, pos, date_weekday_short(wday));
            default:         date_buf_push(buf, pos, date_weekday_long(wday)[0]);
        }
        wrote = true;
        if (fmt.month != DTF_NONE || fmt.day != DTF_NONE || fmt.year != DTF_NONE) {
            date_buf_append(buf, pos, ", ");
        }
    }

    // The era suffix ("AD"/"BC") trails the year, so only the year's own
    // rendering below needs to know about it.
    if (spelled) {
        if (fmt.month != DTF_NONE) {
            switch (fmt.month) {
                case DTF_LONG:   date_buf_append(buf, pos, date_month_long(month));
                case DTF_SHORT:  date_buf_append(buf, pos, date_month_short(month));
                default:         date_buf_push(buf, pos, date_month_long(month)[0]);
            }
            wrote = true;
        }
        if (fmt.day != DTF_NONE) {
            if (wrote) date_buf_push(buf, pos, ' ');
            date_buf_append_num(buf, pos, day, fmt.day == DTF_2DIGIT ? 2 : 1);
            wrote = true;
        }
        if (fmt.year != DTF_NONE) {
            if (wrote) date_buf_append(buf, pos, ", ");
            date_render_year(fmt, buf, pos, year);
            wrote = true;
        }
    } else {
        bool first = true;
        if (fmt.month != DTF_NONE) {
            date_buf_append_num(buf, pos, month + 1, fmt.month == DTF_2DIGIT ? 2 : 1);
            first = false;
            wrote = true;
        }
        if (fmt.day != DTF_NONE) {
            if (!first) date_buf_push(buf, pos, '/');
            date_buf_append_num(buf, pos, day, fmt.day == DTF_2DIGIT ? 2 : 1);
            first = false;
            wrote = true;
        }
        if (fmt.year != DTF_NONE) {
            if (!first) date_buf_push(buf, pos, '/');
            date_render_year(fmt, buf, pos, year);
            wrote = true;
        }
    }
    return wrote;
}

/// Render the year, honouring the "2-digit" width and appending the era when
/// `era` was requested. A non-positive proleptic year is shown as its BC
/// equivalent, so year 0 prints as "1 BC".
fn void date_render_year(DateTimeFormatOpts* fmt, char[] buf, usz* pos, long year) {
    long shown = year;
    bool bc = false;
    if (fmt.era != DTF_NONE && year <= 0) {
        shown = 1 - year;
        bc = true;
    }
    if (fmt.year == DTF_2DIGIT) {
        long yy = shown % 100;
        if (yy < 0) yy += 100;
        date_buf_append_num(buf, pos, yy, 2);
    } else {
        date_buf_append_num(buf, pos, shown, 1);
    }
    if (fmt.era != DTF_NONE) {
        switch (fmt.era) {
            case DTF_LONG:
                date_buf_append(buf, pos, bc ? " Before Christ" : " Anno Domini");
            case DTF_NARROW:
                date_buf_append(buf, pos, bc ? " B" : " A");
            default:
                date_buf_append(buf, pos, bc ? " BC" : " AD");
        }
    }
}

/// Render the time half into `buf`, returning true if it wrote anything.
fn bool date_render_time_part(DateTimeFormatOpts* fmt, char[] buf, usz* pos,
                              long hour, long minute, long second, long ms) {
    bool wrote = false;
    // The fixed locale's clock is 12-hour, which `hour12: false` and the
    // h23/h24 hour cycles override.
    bool use_12 = fmt.hour12 != 0;
    long h = hour;
    bool pm = false;
    if (use_12 && fmt.hour != DTF_NONE) {
        pm = hour >= 12;
        h = hour % 12;
        if (h == 0) h = 12;
    }

    if (fmt.hour != DTF_NONE) {
        // The 24-hour clock is always two digits, which is what makes "00:05"
        // read as a time rather than as the number 5 past zero. The 12-hour
        // clock has the am/pm marker to disambiguate it, so there the
        // requested width stands.
        int hour_digits = use_12 ? (fmt.hour == DTF_2DIGIT ? 2 : 1) : 2;
        date_buf_append_num(buf, pos, h, hour_digits);
        wrote = true;
    }
    // Minutes and seconds are padded whenever they share the format with
    // another clock field, because "4:5:6" is not a time. Asked for on their
    // own they are a bare number, and the requested width does not override
    // that: a lone `minute: "2-digit"` still renders as "5".
    int clock_fields = 0;
    if (fmt.hour != DTF_NONE) clock_fields++;
    if (fmt.minute != DTF_NONE) clock_fields++;
    if (fmt.second != DTF_NONE) clock_fields++;
    int sub_digits = clock_fields > 1 ? 2 : 1;

    if (fmt.minute != DTF_NONE) {
        if (wrote) date_buf_push(buf, pos, ':');
        date_buf_append_num(buf, pos, minute, sub_digits);
        wrote = true;
    }
    if (fmt.second != DTF_NONE) {
        if (wrote) date_buf_push(buf, pos, ':');
        date_buf_append_num(buf, pos, second, sub_digits);
        wrote = true;
    }
    if (fmt.frac_digits > 0) {
        // Sub-second digits attach to the seconds with a decimal point, and
        // stand alone as a bare truncated number when no seconds were asked
        // for: `{fractionalSecondDigits: 2}` on .123 gives "12".
        if (wrote) date_buf_push(buf, pos, '.');
        long scaled = ms;
        for (int i = fmt.frac_digits; i < 3; i++) scaled /= 10;
        date_buf_append_num(buf, pos, scaled, fmt.frac_digits);
        wrote = true;
    }
    if (use_12 && fmt.hour != DTF_NONE) {
        date_buf_append(buf, pos, pm ? " PM" : " AM");
    }
    if (fmt.time_zone_name != DTF_NONE) {
        if (wrote) date_buf_push(buf, pos, ' ');
        if (fmt.time_zone_name == DTF_LONG && fmt.tz_is_utc) {
            date_buf_append(buf, pos, "Coordinated Universal Time");
        } else {
            date_buf_append(buf, pos, fmt.tz_label[:fmt.tz_label_len]);
        }
        wrote = true;
    }
    return wrote;
}
