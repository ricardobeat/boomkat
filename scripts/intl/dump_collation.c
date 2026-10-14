/* Root collation elements for every code point, from ICU's tertiary-strength
 * root collator. Prints one line per entry:
 *
 *   explicit<TAB>code point (hex)<TAB>32-bit CE (hex), ...
 *   implicit<TAB>first code point<TAB>last code point<TAB>class (0-5)
 *   variable<TAB>top primary (hex)
 *
 * Code points in a UCA 9.1 implicit class (section 10.1) are printed as runs
 * with their class, not as CE lists: 0 core Han (base FB40), 1 other Han
 * (FB80), 2 Tangut (FB00), 3 Nushu (FB01), 4 Khitan (FB02), 5 unassigned and
 * private use (FBC0). Hangul syllables are skipped; NFD decomposes them before
 * lookup. ICU's 32-bit CE packs primary in bits 16-31, secondary in 8-15 and
 * tertiary in 0-7.
 *
 *   cc dump_collation.c -I$ICU/include -L$ICU/lib -licuuc -licui18n -licudata
 *   ./a.out > collation.txt
 */
#include <stdio.h>
#include <unicode/ucol.h>
#include <unicode/ucoleitr.h>
#include <unicode/uchar.h>
#include <unicode/utf16.h>

#define MAX_CES 64

static int implicit_class(UChar32 cp) {
    if (cp >= 0xAC00 && cp <= 0xD7A3) return -2;
    if (u_hasBinaryProperty(cp, UCHAR_UNIFIED_IDEOGRAPH))
        return ((cp >= 0x4E00 && cp <= 0x9FFF) || (cp >= 0xF900 && cp <= 0xFAFF) ||
                (cp >= 0x20000 && cp <= 0x2A6DF) || (cp >= 0x2A700 && cp <= 0x2EBE0) ||
                (cp >= 0x2F800 && cp <= 0x2FA1F) || (cp >= 0x30000 && cp <= 0x3134A)) ? 0 : 1;
    if (cp >= 0x17000 && cp <= 0x187F7) return 2;
    if (cp >= 0x18D00 && cp <= 0x18D08) return 2;
    if (cp >= 0x1B170 && cp <= 0x1B2FB) return 3;
    if (cp >= 0x18B00 && cp <= 0x18CD5) return 4;
    if (u_charType(cp) == U_UNASSIGNED) return 5;
    if ((cp >= 0xE000 && cp <= 0xF8FF) || (cp >= 0xF0000 && cp <= 0x10FFFD)) return 5;
    return -1;
}

int main(void) {
    UErrorCode st = U_ZERO_ERROR;
    UCollator *c = ucol_open("root", &st);
    if (U_FAILURE(st)) return 1;
    ucol_setStrength(c, UCOL_TERTIARY);
    int run_class = -1;
    UChar32 run_first = 0, run_last = 0;
    for (UChar32 cp = 0; cp <= 0x10FFFF; cp++) {
        if (cp >= 0xD800 && cp <= 0xDFFF) continue;
        int cls = implicit_class(cp);
        if (cls == -2) continue;
        if (cls >= 0) {
            if (run_class == cls && run_last == cp - 1) {
                run_last = cp;
            } else {
                if (run_class >= 0) printf("implicit\t%X\t%X\t%d\n", (unsigned)run_first, (unsigned)run_last, run_class);
                run_class = cls; run_first = run_last = cp;
            }
            continue;
        }
        if (run_class >= 0) {
            printf("implicit\t%X\t%X\t%d\n", (unsigned)run_first, (unsigned)run_last, run_class);
            run_class = -1;
        }
        UChar buf[2];
        int32_t n = 0;
        U16_APPEND_UNSAFE(buf, n, cp);
        UCollationElements *e = ucol_openElements(c, buf, n, &st);
        int32_t ces[MAX_CES];
        int k = 0;
        int32_t ce;
        while ((ce = ucol_next(e, &st)) != UCOL_NULLORDER) {
            if (k < MAX_CES) ces[k] = ce;
            k++;
        }
        ucol_closeElements(e);
        if (k == 0) continue;
        if (k > MAX_CES) return 2;
        printf("explicit\t%X\t", (unsigned)cp);
        for (int i = 0; i < k; i++) printf(i ? ",%X" : "%X", (unsigned)ces[i]);
        printf("\n");
    }
    if (run_class >= 0) printf("implicit\t%X\t%X\t%d\n", (unsigned)run_first, (unsigned)run_last, run_class);
    printf("variable\t%X\n", (unsigned)ucol_getVariableTop(c, &st) >> 16);
    ucol_close(c);
    return 0;
}
