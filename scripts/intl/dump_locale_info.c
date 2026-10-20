/* Per-locale facts that ICU exposes only through its API: the collation types
 * a locale offers, its default numbering system, and which scripts are written
 * right to left. Reads one locale ID per line on stdin, adds every locale ICU
 * ships data for, and writes
 *
 *   collation<TAB>locale<TAB>type,type,...     (BCP 47 types, ICU order)
 *   numbering<TAB>locale<TAB>system
 *   rtl<TAB>Script
 *   digits<TAB>system<TAB>code point of the zero digit   (decimal systems whose digits are contiguous)
 *   scattered<TAB>system<TAB>ten code points             (decimal systems whose digits are not)
 *
 *   cc dump_locale_info.c -I$ICU/include -L$ICU/lib -licuuc -licui18n -licudata
 *   cut -f1 likely_subtags.txt | grep -v _ | ./a.out | sort -u > locale_info.txt
 */
#include <stdio.h>
#include <string.h>
#include <unicode/ucol.h>
#include <unicode/uenum.h>
#include <unicode/uloc.h>
#include <unicode/unumsys.h>
#include <unicode/uscript.h>
#include <unicode/utf16.h>

static void collations(const char *loc) {
    UErrorCode st = U_ZERO_ERROR;
    UEnumeration *e = ucol_getKeywordValuesForLocale("collation", loc, 0, &st);
    if (U_FAILURE(st) || !e) return;
    char line[512] = "";
    const char *v;
    int32_t len;
    while ((v = uenum_next(e, &len, &st)) != NULL && U_SUCCESS(st)) {
        const char *bcp = uloc_toUnicodeLocaleType("collation", v);
        if (!bcp || !strcmp(bcp, "standard") || !strcmp(bcp, "search")) continue;
        if (line[0]) strcat(line, ",");
        strcat(line, bcp);
    }
    uenum_close(e);
    printf("collation\t%s\t%s\n", loc, line);
}

static void numbering(const char *loc) {
    UErrorCode st = U_ZERO_ERROR;
    UNumberingSystem *ns = unumsys_open(loc, &st);
    if (U_FAILURE(st) || !ns) return;
    printf("numbering\t%s\t%s\n", loc, unumsys_getName(ns));
    unumsys_close(ns);
}

/* Every decimal numbering system with ten consecutive digit code points. */
static void digit_systems(void) {
    UErrorCode st = U_ZERO_ERROR;
    UEnumeration *e = unumsys_openAvailableNames(&st);
    if (U_FAILURE(st) || !e) return;
    const char *name;
    int32_t len;
    while ((name = uenum_next(e, &len, &st)) != NULL && U_SUCCESS(st)) {
        UNumberingSystem *ns = unumsys_openByName(name, &st);
        if (U_FAILURE(st) || !ns) { st = U_ZERO_ERROR; continue; }
        if (!unumsys_isAlgorithmic(ns) && unumsys_getRadix(ns) == 10) {
            UChar desc[32];
            int32_t n = unumsys_getDescription(ns, desc, 32, &st);
            UChar32 zero = -1, prev = -1;
            int count = 0, contiguous = 1;
            for (int32_t i = 0; i < n;) {
                UChar32 c;
                U16_NEXT(desc, i, n, c);
                if (count == 0) zero = c; else if (c != prev + 1) contiguous = 0;
                prev = c;
                count++;
            }
            if (count == 10 && contiguous) printf("digits\t%s\t%d\n", name, (int)zero);
            else if (count == 10) { printf("scattered\t%s", name); for (int32_t i = 0; i < n;) { UChar32 c; U16_NEXT(desc, i, n, c); printf("\t%d", (int)c); } printf("\n"); }
        }
        unumsys_close(ns);
    }
    uenum_close(e);
}

int main(void) {
    char loc[64];
    while (fgets(loc, sizeof loc, stdin)) {
        loc[strcspn(loc, "\r\n")] = 0;
        if (!loc[0]) continue;
        collations(loc);
        numbering(loc);
    }
    /* Every locale ICU ships data for, regions included. */
    for (int32_t i = 0; i < uloc_countAvailable(); i++) {
        const char *loc = uloc_getAvailable(i);
        if (!strchr(loc, '@')) { collations(loc); numbering(loc); }
    }
    for (int s = 0; s < USCRIPT_CODE_LIMIT; s++) {
        if (uscript_isRightToLeft((UScriptCode)s)) printf("rtl\t%s\n", uscript_getShortName((UScriptCode)s));
    }
    digit_systems();
    return 0;
}
