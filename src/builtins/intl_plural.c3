module boomkat::builtins;

// CLDR plural operands of a formatted decimal. `int_digits` is the integer part
// without leading zeros and `frac` the visible fraction digits, trailing zeros
// included, so `v` is frac.len.
struct PluralOperands {
    char[] int_digits;
    char[] frac;
    bool fractional; // some visible fraction digit is non-zero, so n is not an integer
    ulong exponent;  // the compact notation exponent `e`, 0 without compact notation
}

// A parsed operand value. `ok` is false when the value does not fit in 18 digits.
struct PluralValue {
    bool ok;
    ulong value;
}

struct PluralScanner {
    char[] src;
    usz pos;
}

fn void plural_skip(PluralScanner* s) {
    while (s.pos < s.src.len && s.src[s.pos] == ' ') s.pos++;
}

// True when the next token is `word` followed by a space or the end; consumes it.
fn bool plural_word(PluralScanner* s, char[] word) {
    plural_skip(s);
    if (s.pos + word.len > s.src.len || !mem_eq_bytes(s.src[s.pos:word.len], word)) return false;
    usz end = s.pos + word.len;
    if (end < s.src.len && s.src[end] != ' ') return false;
    s.pos = end;
    return true;
}

fn bool plural_accept(PluralScanner* s, char[] token) {
    plural_skip(s);
    if (s.pos + token.len > s.src.len || !mem_eq_bytes(s.src[s.pos:token.len], token)) return false;
    s.pos += token.len;
    return true;
}

fn PluralValue plural_number(PluralScanner* s) {
    plural_skip(s);
    ulong value = 0;
    usz digits = 0;
    while (s.pos < s.src.len && locale_is_digit(s.src[s.pos])) {
        if (digits < 18) value = value * 10 + (ulong)(s.src[s.pos] - '0');
        digits++;
        s.pos++;
    }
    return { digits > 0 && digits <= 18, value };
}

// The value of an integer operand under `%`, or of the digits themselves.
fn PluralValue plural_digits_value(char[] digits) {
    ulong value = 0;
    if (digits.len > 18) return { false, 0 };
    foreach (c : digits) value = value * 10 + (ulong)(c - '0');
    return { true, value };
}

fn PluralValue plural_operand(char name, PluralOperands* o, bool* fractional, ulong modulus) {
    char[] digits = o.int_digits;
    switch (name) {
        case 'n':
        case 'i':
            *fractional = name == 'n' && o.fractional;
            if (modulus == 0) return plural_digits_value(digits);
            // Streaming the digits keeps the remainder exact for any length of integer.
            ulong rem = 0;
            foreach (c : digits) rem = (rem * 10 + (ulong)(c - '0')) % modulus;
            return { true, rem };
        case 'v':
            return { true, (ulong)o.frac.len };
        case 'e':
        case 'c':
            return { true, o.exponent };
        case 'f':
            return plural_digits_value(o.frac);
        case 't':
        case 'w':
            usz end = o.frac.len;
            while (end > 0 && o.frac[end - 1] == '0') end--;
            return plural_digits_value(o.frac[:end]);
        default:
            return { true, 0 };
    }
}

// One `<operand> [% m] (= | !=) range_list` or `<operand> [% m] (in | within | not in | not within) range_list`.
fn bool plural_relation(PluralScanner* s, PluralOperands* o) {
    plural_skip(s);
    if (s.pos >= s.src.len) return false;
    char name = s.src[s.pos++];
    ulong modulus = 0;
    if (plural_accept(s, "%")) modulus = plural_number(s).value;
    bool negate = false;
    bool within = false;
    if (plural_accept(s, "!=")) {
        negate = true;
    } else if (plural_accept(s, "=")) {
        negate = false;
    } else if (plural_word(s, "not")) {
        negate = true;
        within = plural_word(s, "within");
        if (!within && !plural_word(s, "in")) return false;
    } else if (plural_word(s, "within")) {
        within = true;
    } else if (!plural_word(s, "in")) {
        return false;
    }
    bool fractional = false;
    PluralValue operand = plural_operand(name, o, &fractional, modulus);
    bool matched = false;
    // Ranges cover integers only; `within` also covers the fractions between them.
    while (true) {
        PluralValue low = plural_number(s);
        PluralValue high = low;
        if (plural_accept(s, "..") || plural_accept(s, "~")) high = plural_number(s);
        if (operand.ok && low.ok && high.ok) {
            if (fractional) {
                if (within && operand.value >= low.value && operand.value < high.value) matched = true;
            } else if (operand.value >= low.value && operand.value <= high.value) {
                matched = true;
            }
        }
        if (!plural_accept(s, ",")) break;
    }
    return matched != negate;
}

fn bool plural_and(PluralScanner* s, PluralOperands* o) {
    bool result = plural_relation(s, o);
    while (plural_word(s, "and")) {
        bool next = plural_relation(s, o);
        result = result && next;
    }
    return result;
}

fn bool plural_condition(PluralScanner* s, PluralOperands* o) {
    bool result = plural_and(s, o);
    while (plural_word(s, "or")) {
        bool next = plural_and(s, o);
        result = result || next;
    }
    return result;
}

// The category of `rules` ("one: i = 1 and v = 0; few: …") that matches the operands, or "other".
fn char[] intl_plural_category(char[] rules, PluralOperands* o) {
    usz start = 0;
    while (start < rules.len) {
        usz end = start;
        while (end < rules.len && rules[end] != ';') end++;
        usz colon = start;
        while (colon < end && rules[colon] != ':') colon++;
        PluralScanner s = { rules[colon + 1:end - colon - 1], 0 };
        if (plural_condition(&s, o)) return rules[start:colon - start];
        start = end + 1;
    }
    return "other";
}

// The category names of `rules` in order, then "other", written to `names`. Returns the count.
fn usz intl_plural_category_names(char[] rules, char[][] names) {
    usz count = 0;
    usz start = 0;
    while (start < rules.len) {
        usz end = start;
        while (end < rules.len && rules[end] != ';') end++;
        usz colon = start;
        while (colon < end && rules[colon] != ':') colon++;
        names[count++] = rules[start:colon - start];
        start = end + 1;
    }
    names[count++] = "other";
    return count;
}

// Splits the decimal text of a formatted number into the operands CLDR rules read.
fn PluralOperands intl_plural_operands(char[] fixed, ulong exponent) {
    usz dot = 0;
    while (dot < fixed.len && fixed[dot] != '.') dot++;
    char[] integer = fixed[0:dot];
    char[] frac = dot < fixed.len ? fixed[dot + 1:fixed.len - dot - 1] : fixed[0:0];
    bool fractional = false;
    foreach (c : frac) if (c != '0') fractional = true;
    usz start = 0;
    while (start + 1 < integer.len && integer[start] == '0') start++;
    return { integer[start:integer.len - start], frac, fractional, exponent };
}
