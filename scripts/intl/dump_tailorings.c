/* Collation tailorings from ICU, for scripts/generate_intl_collation.py.
 *
 *   cc dump_tailorings.c -I$ICU/include -L$ICU/lib -licuuc -licui18n -licudata
 *   ./a.out sets > tailoring_sets.txt
 *   ./a.out ces tailoring_universe.txt > tailorings.txt
 *   ./a.out digits > digits.txt
 *
 * "sets" prints, for the root collation and every tailoring ICU ships:
 *
 *   locale<TAB>locale id<TAB>collation type<TAB>tailoring id      (one per available locale and type)
 *   default<TAB>locale id<TAB>collation type                      (the type a locale uses without -u-co-)
 *   string<TAB>code points (hex, space separated)                 (NFD of a tailored string or contraction)
 *   key<TAB>tailoring id<TAB>code points                         (a contraction ICU stores in NFD form)
 *
 * The generator unions the strings into the universe file, one string per line in the
 * same hex form. "ces" then prints:
 *
 *   root<TAB>code points<TAB>CEs                  (every NFD-stable code point with root elements, and
 *                                                  every universe string, under the root collation)
 *   tailoring<TAB>id<TAB>settings                 (backwards, alternate, caseFirst, caseLevel, numeric,
 *                                                  variable top, reorder codes)
 *   entry<TAB>id<TAB>code points<TAB>CEs          (a universe string whose elements differ from root)
 *   lead<TAB>id<TAB>primary prefix<TAB>new lead   (a reordered tailoring's lead byte for a 16-bit prefix)
 *
 * "digits" prints digit<TAB>code point for the zero of every run of decimal digits.
 *
 * CEs are 64-bit ICU collation elements joined from the iterator's 32-bit halves, printed as
 * primary:secondary:tertiary hex triples separated by spaces. Code points whose root primary
 * starts with the unassigned-implicit lead byte FE are left out: the engine derives them.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unicode/ucol.h>
#include <unicode/ucoleitr.h>
#include <unicode/uset.h>
#include <unicode/uenum.h>
#include <unicode/unorm2.h>
#include <unicode/ures.h>
#include <unicode/utf16.h>
#include <unicode/uchar.h>
#include <unicode/ustring.h>

#define MAX_CES 256
#define MAX_TAILORINGS 512

typedef struct { uint32_t p; uint16_t s, t; } CE64;

static int ces_of(UCollator *c, const UChar *s, int32_t n, CE64 *out) {
    UErrorCode st = U_ZERO_ERROR;
    UCollationElements *e = ucol_openElements(c, s, n, &st);
    int k = 0;
    int32_t ce;
    while ((ce = ucol_next(e, &st)) != UCOL_NULLORDER) {
        uint32_t u = (uint32_t)ce;
        if ((u & 0xC0) == 0xC0 && k > 0) {
            /* Continuation: the low halves of the previous element. */
            out[k - 1].p |= u >> 16;
            out[k - 1].s |= (u >> 8) & 0xFF;
            out[k - 1].t |= u & 0x3F;
            continue;
        }
        if (k == MAX_CES) { fprintf(stderr, "too many CEs\n"); exit(2); }
        out[k].p = u & 0xFFFF0000;
        out[k].s = (uint16_t)(((u >> 8) & 0xFF) << 8);
        out[k].t = (uint16_t)((u & 0xFF) << 8);
        k++;
    }
    ucol_closeElements(e);
    return k;
}

static void print_ces(const CE64 *ces, int n) {
    for (int i = 0; i < n; i++) printf(i ? " %X:%X:%X" : "%X:%X:%X", ces[i].p, ces[i].s, ces[i].t);
}

static int same_ces(const CE64 *a, int an, const CE64 *b, int bn) {
    if (an != bn) return 0;
    for (int i = 0; i < an; i++) {
        if (a[i].p != b[i].p || a[i].s != b[i].s || a[i].t != b[i].t) return 0;
    }
    return 1;
}

static void print_cps(const UChar *s, int32_t n) {
    int32_t i = 0;
    int first = 1;
    while (i < n) {
        UChar32 c;
        U16_NEXT(s, i, n, c);
        printf(first ? "%X" : " %X", (unsigned)c);
        first = 0;
    }
}

static int32_t parse_cps(char *line, UChar *out, int32_t cap) {
    int32_t n = 0;
    char *p = line;
    while (*p && *p != '\n') {
        char *end;
        unsigned long c = strtoul(p, &end, 16);
        if (end == p) break;
        if (n + 2 > cap) return -1;
        U16_APPEND_UNSAFE(out, n, (UChar32)c);
        p = end;
        while (*p == ' ') p++;
    }
    return n;
}

/* The collation type a locale uses without a keyword, from the collations/default resource. */
static void default_type(const char *loc, char *out, int cap) {
    UErrorCode st = U_ZERO_ERROR;
    UResourceBundle *b = ures_open(U_ICUDATA_NAME "-coll", loc, &st);
    UResourceBundle *colls = ures_getByKey(b, "collations", NULL, &st);
    int32_t len = 0;
    const UChar *v = ures_getStringByKey(colls, "default", &len, &st);
    if (U_SUCCESS(st)) {
        u_UCharsToChars(v, out, len);
        out[len] = 0;
    } else {
        snprintf(out, cap, "standard");
    }
    ures_close(colls);
    ures_close(b);
}

typedef struct { char id[160]; UCollator *coll; } Tailoring;
static Tailoring tailorings[MAX_TAILORINGS];
static int tailoring_count;

/* Identity of a tailoring: ICU's actual locale with its keyword, plus the attribute settings. */
static void tailoring_id(UCollator *c, char *out, int cap) {
    UErrorCode st = U_ZERO_ERROR;
    const char *actual = ucol_getLocaleByType(c, ULOC_ACTUAL_LOCALE, &st);
    int32_t codes[32];
    int32_t nc = ucol_getReorderCodes(c, codes, 32, &st);
    snprintf(out, cap, "%s|%d%d%d%d|%d|%X|%d", actual && *actual ? actual : "root",
             ucol_getAttribute(c, UCOL_FRENCH_COLLATION, &st) == UCOL_ON,
             ucol_getAttribute(c, UCOL_ALTERNATE_HANDLING, &st) == UCOL_SHIFTED,
             ucol_getAttribute(c, UCOL_CASE_LEVEL, &st) == UCOL_ON,
             ucol_getAttribute(c, UCOL_NUMERIC_COLLATION, &st) == UCOL_ON,
             (int)ucol_getAttribute(c, UCOL_CASE_FIRST, &st),
             (unsigned)ucol_getVariableTop(c, &st), (int)nc);
}

static int find_or_add(UCollator *c) {
    char id[160];
    tailoring_id(c, id, sizeof id);
    for (int i = 0; i < tailoring_count; i++) {
        if (strcmp(tailorings[i].id, id) == 0) { ucol_close(c); return i; }
    }
    if (tailoring_count == MAX_TAILORINGS) { fprintf(stderr, "too many tailorings\n"); exit(2); }
    snprintf(tailorings[tailoring_count].id, sizeof tailorings[0].id, "%s", id);
    tailorings[tailoring_count].coll = c;
    return tailoring_count++;
}

static void collect(int print_locales) {
    int n = ucol_countAvailable();
    for (int i = -1; i < n; i++) {
        const char *loc = i < 0 ? "root" : ucol_getAvailable(i);
        UErrorCode st = U_ZERO_ERROR;
        char def[32];
        default_type(loc, def, sizeof def);
        if (print_locales) printf("default\t%s\t%s\n", loc, def);
        UEnumeration *en = ucol_getKeywordValuesForLocale("collation", loc, 0, &st);
        const char *t;
        while ((t = uenum_next(en, NULL, &st))) {
            if (strncmp(t, "private-", 8) == 0) continue;
            char id[128];
            snprintf(id, sizeof id, "%s@collation=%s", loc, t);
            UErrorCode s2 = U_ZERO_ERROR;
            UCollator *c = ucol_open(id, &s2);
            if (U_FAILURE(s2)) continue;
            int k = find_or_add(c);
            if (print_locales) printf("locale\t%s\t%s\t%d\n", loc, t, k);
        }
        uenum_close(en);
    }
}

static void print_set_strings(const UNormalizer2 *nfd, USet *set) {
    int32_t items = uset_getItemCount(set);
    for (int32_t i = 0; i < items; i++) {
        UErrorCode st = U_ZERO_ERROR;
        UChar32 start, end;
        UChar str[256];
        int32_t len = uset_getItem(set, i, &start, &end, str, 256, &st);
        if (len == 0) {
            for (UChar32 c = start; c <= end; c++) {
                UChar buf[2], norm[64];
                int32_t n = 0;
                U16_APPEND_UNSAFE(buf, n, c);
                UErrorCode s3 = U_ZERO_ERROR;
                int32_t m = unorm2_normalize(nfd, buf, n, norm, 64, &s3);
                printf("string\t"); print_cps(norm, m); printf("\n");
            }
        } else {
            UChar norm[512];
            UErrorCode s3 = U_ZERO_ERROR;
            int32_t m = unorm2_normalize(nfd, str, len, norm, 512, &s3);
            printf("string\t"); print_cps(norm, m); printf("\n");
        }
    }
}

/* The contractions a tailoring's suffix tries hold as NFD strings. Only these can extend a
 * discontiguous match: a canonical-closure contraction is stored precomposed, and NFD text never
 * reaches it. */
static void print_nfd_keys(const UNormalizer2 *nfd, int t, USet *set) {
    int32_t items = uset_getItemCount(set);
    for (int32_t i = 0; i < items; i++) {
        UErrorCode st = U_ZERO_ERROR;
        UChar32 start, end;
        UChar str[256];
        int32_t len = uset_getItem(set, i, &start, &end, str, 256, &st);
        if (len <= 0) continue;
        UErrorCode s3 = U_ZERO_ERROR;
        if (!unorm2_isNormalized(nfd, str, len, &s3)) continue;
        printf("key\t%d\t", t); print_cps(str, len); printf("\n");
    }
}

static int sets_mode(void) {
    UErrorCode st = U_ZERO_ERROR;
    const UNormalizer2 *nfd = unorm2_getNFDInstance(&st);
    collect(1);
    for (int i = 0; i < tailoring_count; i++) {
        UErrorCode s2 = U_ZERO_ERROR;
        USet *tailored = ucol_getTailoredSet(tailorings[i].coll, &s2);
        USet *contractions = uset_openEmpty();
        ucol_getContractionsAndExpansions(tailorings[i].coll, contractions, NULL, 1, &s2);
        print_set_strings(nfd, tailored);
        print_set_strings(nfd, contractions);
        USet *keys = uset_openEmpty();
        ucol_getContractionsAndExpansions(tailorings[i].coll, keys, NULL, 0, &s2);
        print_nfd_keys(nfd, i, keys);
        uset_close(keys);
        uset_close(tailored);
        uset_close(contractions);
    }
    return 0;
}

static int ces_mode(const char *universe_path) {
    UErrorCode st = U_ZERO_ERROR;
    const UNormalizer2 *nfd = unorm2_getNFDInstance(&st);
    collect(0);
    UCollator *root = ucol_open("root", &st);
    static CE64 a[MAX_CES], b[MAX_CES];

    /* Root elements of every code point an NFD string can contain. */
    for (UChar32 c = 0; c <= 0x10FFFF; c++) {
        if (c >= 0xD800 && c <= 0xDFFF) continue;
        if (c >= 0xAC00 && c <= 0xD7A3) continue;
        UChar buf[2];
        int32_t n = 0;
        U16_APPEND_UNSAFE(buf, n, c);
        UErrorCode s2 = U_ZERO_ERROR;
        if (!unorm2_isNormalized(nfd, buf, n, &s2)) continue;
        int k = ces_of(root, buf, n, a);
        if (k > 0 && (a[0].p >> 24) == 0xFE) continue;
        printf("root\t%X\t", (unsigned)c); print_ces(a, k); printf("\n");
    }

    FILE *f = fopen(universe_path, "r");
    if (!f) { perror(universe_path); return 1; }
    static char line[8192];
    static UChar strs[400000][24];
    static int32_t lens[400000];
    int count = 0;
    while (fgets(line, sizeof line, f)) {
        int32_t n = parse_cps(line, strs[count], 24);
        if (n <= 0) continue;
        lens[count++] = n;
        if (count == 400000) { fprintf(stderr, "universe too large\n"); return 2; }
    }
    fclose(f);
    for (int i = 0; i < count; i++) {
        int32_t cps = u_countChar32(strs[i], lens[i]);
        if (cps < 2) continue;
        int k = ces_of(root, strs[i], lens[i], a);
        printf("root\t"); print_cps(strs[i], lens[i]); printf("\t"); print_ces(a, k); printf("\n");
    }

    for (int t = 0; t < tailoring_count; t++) {
        UCollator *c = tailorings[t].coll;
        UErrorCode s2 = U_ZERO_ERROR;
        int32_t codes[32];
        int32_t nc = ucol_getReorderCodes(c, codes, 32, &s2);
        printf("tailoring\t%d\t%d\t%d\t%d\t%d\t%d\t%X\t", t,
               ucol_getAttribute(c, UCOL_FRENCH_COLLATION, &s2) == UCOL_ON,
               ucol_getAttribute(c, UCOL_ALTERNATE_HANDLING, &s2) == UCOL_SHIFTED,
               (int)ucol_getAttribute(c, UCOL_CASE_FIRST, &s2) == UCOL_UPPER_FIRST ? 2
                   : ucol_getAttribute(c, UCOL_CASE_FIRST, &s2) == UCOL_LOWER_FIRST ? 1 : 0,
               ucol_getAttribute(c, UCOL_CASE_LEVEL, &s2) == UCOL_ON,
               ucol_getAttribute(c, UCOL_NUMERIC_COLLATION, &s2) == UCOL_ON,
               (unsigned)ucol_getVariableTop(c, &s2));
        for (int i = 0; i < nc; i++) printf(i ? " %d" : "%d", (int)codes[i]);
        printf("\t%s\n", tailorings[t].id);
        for (int i = 0; i < count; i++) {
            int ka = ces_of(c, strs[i], lens[i], a);
            int kb = ces_of(root, strs[i], lens[i], b);
            if (same_ces(a, ka, b, kb)) continue;
            printf("entry\t%d\t", t); print_cps(strs[i], lens[i]); printf("\t"); print_ces(a, ka); printf("\n");
        }
        if (nc > 0) {
            /* Sample the lead byte of a primary-strength sort key for each 16-bit primary prefix. */
            UErrorCode s3 = U_ZERO_ERROR;
            UCollator *probe = ucol_clone(c, &s3);
            ucol_setAttribute(probe, UCOL_STRENGTH, UCOL_PRIMARY, &s3);
            ucol_setAttribute(probe, UCOL_ALTERNATE_HANDLING, UCOL_NON_IGNORABLE, &s3);
            ucol_setAttribute(probe, UCOL_NUMERIC_COLLATION, UCOL_OFF, &s3);
            static unsigned char seen[65536];
            memset(seen, 0, sizeof seen);
            for (int pass = 0; pass < 2; pass++) {
                int limit = pass == 0 ? 0x110000 : count;
                for (int i = 0; i < limit; i++) {
                    UChar buf[24];
                    int32_t n = 0;
                    if (pass == 0) {
                        if ((i >= 0xD800 && i <= 0xDFFF) || (i >= 0xAC00 && i <= 0xD7A3)) continue;
                        U16_APPEND_UNSAFE(buf, n, (UChar32)i);
                    } else {
                        memcpy(buf, strs[i], lens[i] * sizeof(UChar));
                        n = lens[i];
                    }
                    int k = ces_of(c, buf, n, a);
                    int j = 0;
                    while (j < k && a[j].p == 0) j++;
                    if (j == k) continue;
                    unsigned prefix = a[j].p >> 16;
                    if (seen[prefix]) continue;
                    seen[prefix] = 1;
                    uint8_t key[16];
                    int32_t kl = ucol_getSortKey(probe, buf + 0, n, key, 16);
                    if (kl < 1) continue;
                    printf("lead\t%d\t%X\t%X\n", t, prefix, key[0]);
                }
            }
            ucol_close(probe);
        }
    }
    return 0;
}

/* The zero of every run of decimal digits (general category Nd), which numeric collation reads. */
static int digits_mode(void) {
    for (UChar32 c = 0; c <= 0x10FFFF; c++) {
        if (u_charType(c) == U_DECIMAL_DIGIT_NUMBER && u_charDigitValue(c) == 0) printf("digit\t%X\n", (unsigned)c);
    }
    return 0;
}

int main(int argc, char **argv) {
    if (argc >= 2 && strcmp(argv[1], "sets") == 0) return sets_mode();
    if (argc >= 2 && strcmp(argv[1], "digits") == 0) return digits_mode();
    if (argc >= 3 && strcmp(argv[1], "ces") == 0) return ces_mode(argv[2]);
    fprintf(stderr, "usage: %s sets | digits | ces <universe file>\n", argv[0]);
    return 1;
}
