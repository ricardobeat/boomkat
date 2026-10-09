/* Link live ICU formatter paths into the engine without adding a JS API. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unicode/uloc.h>
#include <unicode/unumberformatter.h>
#include <unicode/unumberrangeformatter.h>
#include <unicode/upluralrules.h>
#include <unicode/uformattedvalue.h>
#include <unicode/ustring.h>
#ifdef BK_ICU_DATES
#include <unicode/udat.h>
#include <unicode/udateintervalformat.h>
#include <unicode/udatpg.h>
#endif

static void check(UErrorCode status) {
    if (U_FAILURE(status)) {
        fprintf(stderr, "ICU probe: %s\n", u_errorName(status));
        exit(1);
    }
}

static void show(const UChar *text, int32_t len) {
    char out[512];
    UErrorCode status = U_ZERO_ERROR;
    int32_t written;
    u_strToUTF8(out, sizeof out, &written, text, len, &status);
    check(status);
    printf("%.*s\n", written, out);
}

static void fields(const UFormattedValue *value) {
    UErrorCode status = U_ZERO_ERROR;
    UConstrainedFieldPosition *pos = ucfpos_open(&status);
    int count = 0;
    while (ufmtval_nextPosition(value, pos, &status)) count++;
    check(status);
    if (!count) { fprintf(stderr, "ICU probe: missing parts\n"); exit(1); }
    ucfpos_close(pos);
}

__attribute__((constructor)) static void boomkat_icu_size_probe(void) {
    if (!getenv("BK_ICU_SIZE_PROBE")) return;
    UErrorCode status = U_ZERO_ERROR;
    char locale[128];
    uloc_forLanguageTag("en-US", locale, sizeof locale, NULL, &status);
    check(status);
    const UChar skeleton[] = u"currency/USD precision-currency-standard rounding-mode-half-up";
    UNumberFormatter *fmt = unumf_openForSkeletonAndLocale(
        skeleton, -1, locale, &status);
    UFormattedNumber *number = unumf_openResult(&status);
    unumf_formatDecimal(fmt, "12345678901234567890.125", -1, number, &status);
    UChar text[256];
    int32_t len = unumf_resultToString(number, text, 256, &status);
    check(status);
    show(text, len);
    if (u_strcmp(text, u"$12,345,678,901,234,567,890.13") != 0) exit(1);
    fields(unumf_resultAsValue(number, &status));
    UNumberFormatter *plain = unumf_openForSkeletonAndLocale(u"", 0, locale, &status);
    unumf_formatDouble(plain, 1, number, &status);
    UPluralRules *rules = uplrules_openForType(locale, UPLURAL_TYPE_CARDINAL, &status);
    len = uplrules_selectFormatted(rules, number, text, 256, &status);
    check(status);
    show(text, len);
    if (u_strcmp(text, u"one") != 0) exit(1);
    UNumberRangeFormatter *range = unumrf_openForSkeletonWithCollapseAndIdentityFallback(
        u"", 0, UNUM_RANGE_COLLAPSE_AUTO,
        UNUM_IDENTITY_FALLBACK_APPROXIMATELY, locale, NULL, &status);
    UFormattedNumberRange *range_result = unumrf_openResult(&status);
    unumrf_formatDecimalRange(range, "1", -1, "3", -1, range_result, &status);
    const UChar *range_text = ufmtval_getString(
        unumrf_resultAsValue(range_result, &status), &len, &status);
    check(status);
    show(range_text, len);
    fields(unumrf_resultAsValue(range_result, &status));
    check(status);
    unumrf_closeResult(range_result);
    unumrf_close(range);
    uplrules_close(rules);
    unumf_close(plain);
    unumf_closeResult(number);
    unumf_close(fmt);
#ifdef BK_ICU_DATES
    /* Boomkat supplies the offset for an instant; ICU renders that offset. */
    const UChar zone[] = u"GMT+05:30";
    UDateTimePatternGenerator *patterns = udatpg_open(locale, &status);
    UChar pattern[128];
    int32_t pattern_len = udatpg_getBestPattern(patterns, u"yMMMdHm", -1,
                                               pattern, 128, &status);
    UDateFormat *date = udat_open(UDAT_PATTERN, UDAT_PATTERN, locale,
                                zone, -1, pattern, pattern_len, &status);
    UFieldPositionIterator *positions = ufieldpositer_open(&status);
    len = udat_formatForFields(date, 0, text, 256, positions, &status);
    check(status);
    show(text, len);
    UDateIntervalFormat *interval = udtitvfmt_open(locale, u"yMMMd", -1,
                                                zone, -1, &status);
    UFormattedDateInterval *interval_result = udtitvfmt_openResult(&status);
    udtitvfmt_formatToResult(interval, 0, 86400000, interval_result, &status);
    fields(udtitvfmt_resultAsValue(interval_result, &status));
    check(status);
    udtitvfmt_closeResult(interval_result);
    udtitvfmt_close(interval);
    ufieldpositer_close(positions);
    udat_close(date);
    udatpg_close(patterns);
#endif
    puts("ICU probe passed");
}
