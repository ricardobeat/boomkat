/* The Umm al-Qura month lengths ICU ships, for scripts/generate_umalqura.py.
 *
 *   cc dump_umalqura.c -I$ICU/include -L$ICU/lib -licuuc -licui18n -licudata
 *   ./a.out > umalqura.txt
 *
 * Prints one line per Hijri year that ICU's islamic-umalqura calendar takes from the KACST
 * tables rather than the tabular fallback:
 *
 *   year<TAB>epoch day of 1 Muharram<TAB>twelve month lengths
 *
 * Epoch days count from 1970-01-01. The range is the one ICU's islamcal.cpp tabulates.
 */
#include <stdio.h>
#include <unicode/ucal.h>

enum { FIRST_YEAR = 1300, LAST_YEAR = 1600 };

static long epoch_day(UCalendar* cal, int year, int month, UErrorCode* status) {
    ucal_clear(cal);
    ucal_setDate(cal, year, month, 1, status);
    double ms = ucal_getMillis(cal, status);
    return (long)(ms / 86400000.0 + (ms < 0 ? -0.5 : 0.5));
}

int main(void) {
    UErrorCode status = U_ZERO_ERROR;
    UChar utc[] = { 'U', 'T', 'C', 0 };
    UCalendar* cal = ucal_open(utc, -1, "en@calendar=islamic-umalqura", UCAL_DEFAULT, &status);
    if (U_FAILURE(status)) {
        fprintf(stderr, "ucal_open: %s\n", u_errorName(status));
        return 1;
    }
    for (int year = FIRST_YEAR; year <= LAST_YEAR; year++) {
        long start = epoch_day(cal, year, 0, &status);
        printf("%d\t%ld\t", year, start);
        long month_start = start;
        for (int month = 0; month < 12; month++) {
            long next = month == 11 ? epoch_day(cal, year + 1, 0, &status) : epoch_day(cal, year, month + 1, &status);
            printf(month == 0 ? "%ld" : " %ld", next - month_start);
            month_start = next;
        }
        printf("\n");
    }
    ucal_close(cal);
    if (U_FAILURE(status)) {
        fprintf(stderr, "ucal: %s\n", u_errorName(status));
        return 1;
    }
    return 0;
}
