/* Per-locale facts that ICU exposes only through its API: the collation types
 * a locale offers, its default numbering system, and which scripts are written
 * right to left. Reads one locale ID per line on stdin and writes
 *
 *   collation<TAB>locale<TAB>type,type,...     (BCP 47 types, ICU order)
 *   numbering<TAB>locale<TAB>system
 *   rtl<TAB>Script
 *
 *   cc dump_locale_info.c -I$ICU/include -L$ICU/lib -licuuc -licui18n -licudata
 *   cut -f1 likely_subtags.txt | grep -v _ | ./a.out > locale_info.txt
 */
#include <stdio.h>
#include <string.h>
#include <unicode/ucol.h>
#include <unicode/uenum.h>
#include <unicode/uloc.h>
#include <unicode/unumsys.h>
#include <unicode/uscript.h>

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

int main(void) {
    char loc[64];
    while (fgets(loc, sizeof loc, stdin)) {
        loc[strcspn(loc, "\r\n")] = 0;
        if (!loc[0]) continue;
        collations(loc);
        numbering(loc);
    }
    for (int s = 0; s < USCRIPT_CODE_LIMIT; s++) {
        if (uscript_isRightToLeft((UScriptCode)s)) printf("rtl\t%s\n", uscript_getShortName((UScriptCode)s));
    }
    return 0;
}
