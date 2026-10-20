/* Extracts CLDR's likely-subtags table through ICU's public API.
 *
 * ICU keeps the table as a compiled trie, so the explicit entries are
 * recovered by probing: an entry is emitted only where ICU's answer differs
 * from the one the lookup order below derives from the entries already
 * emitted. The engine runs the same lookup order, so the emitted list
 * reproduces uloc_addLikelySubtags for every language/script/region input.
 *
 * Lookup order (the one ICU applies): L_S_R, L_S, L_R, L, und_S.
 *
 *   cc dump_likely_subtags.c -I$ICU/include -L$ICU/lib -licuuc -licudata
 *   ./a.out likely_extra_languages.txt > likely_subtags.txt
 *
 * Output lines: "key<TAB>language_Script_REGION" with key one of
 * L, L_S, L_R, L_S_R, with L = und for the script and region keys.
 * Entries are sorted by key.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unicode/uloc.h>
#include <unicode/uscript.h>

typedef struct { char key[32]; char lang[9], script[5], region[4]; } Entry;
static Entry *entries; static int count, cap;

static char *regions[2000]; static int nregions;

/* A language is kept when it has two letters (ISO 639-1), ICU ships locale
 * data for it, or it is named in the extras file given as argv[1] (the
 * replacement languages of CLDR's language aliases, which canonicalization can
 * produce, plus aae). The CLDR table lists thousands of further ISO 639-3
 * languages that a small-footprint engine leaves out; those maximize to
 * themselves. */
static char extras[512][9]; static int nextras;
static void load_extras(const char *path) {
    FILE *f = fopen(path, "r");
    if (!f) return;
    char line[16];
    while (nextras < 512 && fgets(line, sizeof line, f)) {
        line[strcspn(line, "\r\n")] = 0;
        if (line[0]) strcpy(extras[nextras++], line);
    }
    fclose(f);
}
static int kept(const char *l) {
    if (strlen(l) == 2) return 1;
    for (int i = 0; i < nextras; i++) if (!strcmp(extras[i], l)) return 1;
    for (int i = 0, n = uloc_countAvailable(); i < n; i++) {
        char buf[16]; UErrorCode st = U_ZERO_ERROR;
        uloc_getLanguage(uloc_getAvailable(i), buf, sizeof buf, &st);
        if (!strcmp(buf, l)) return 1;
    }
    return 0;
}
static char *scripts[400]; static int nscripts;

static void join(char *out, const char *l, const char *s, const char *r) {
    strcpy(out, l);
    if (s[0]) { strcat(out, "_"); strcat(out, s); }
    if (r[0]) { strcat(out, "_"); strcat(out, r); }
}

#define BUCKETS (1 << 16)
static int buckets[BUCKETS];

static unsigned hash(const char *s) {
    unsigned h = 2166136261u;
    for (; *s; s++) h = (h ^ (unsigned char)*s) * 16777619u;
    return h & (BUCKETS - 1);
}

static int find(const char *key) {
    for (unsigned h = hash(key); buckets[h]; h = (h + 1) & (BUCKETS - 1))
        if (!strcmp(entries[buckets[h] - 1].key, key)) return buckets[h] - 1;
    return -1;
}

/* The engine's lookup for (l, s, r) over the emitted entries; returns the
 * filled-in triple. */
static void lookup(const char *l, const char *s, const char *r, char *ol, char *os, char *orr) {
    char key[40];
    int hit = -1;
    if (s[0] && r[0]) { join(key, l, s, r); hit = find(key); }
    if (hit < 0 && s[0]) { join(key, l, s, ""); hit = find(key); }
    if (hit < 0 && r[0]) { join(key, l, "", r); hit = find(key); }
    if (hit < 0) { join(key, l, "", ""); hit = find(key); }
    if (hit < 0 && s[0] && strcmp(l, "und")) { join(key, "und", s, ""); hit = find(key); }
    strcpy(ol, l); strcpy(os, s); strcpy(orr, r);
    if (hit >= 0) {
        if (!strcmp(l, "und")) strcpy(ol, entries[hit].lang);
        if (!s[0]) strcpy(os, entries[hit].script);
        if (!r[0]) strcpy(orr, entries[hit].region);
    }
}

static int icu_max(const char *l, const char *s, const char *r, char *ol, char *os, char *orr) {
    char in[40], out[64]; UErrorCode st = U_ZERO_ERROR;
    join(in, l, s, r);
    uloc_addLikelySubtags(in, out, sizeof out, &st);
    if (U_FAILURE(st)) return 0;
    char lb[16] = "", sb[16] = "", rb[16] = "";
    int32_t n = uloc_getLanguage(out, lb, sizeof lb, &st); (void)n;
    uloc_getScript(out, sb, sizeof sb, &st);
    uloc_getCountry(out, rb, sizeof rb, &st);
    strcpy(ol, lb[0] ? lb : "und"); strcpy(os, sb); strcpy(orr, rb);
    return 1;
}

static void add(const char *l, const char *s, const char *r, const char *vl, const char *vs, const char *vr) {
    if (count == cap) { cap = cap ? cap * 2 : 256; entries = realloc(entries, cap * sizeof *entries); }
    Entry *e = &entries[count++];
    join(e->key, l, s, r);
    strcpy(e->lang, vl); strcpy(e->script, vs); strcpy(e->region, vr);
    unsigned h = hash(e->key);
    while (buckets[h]) h = (h + 1) & (BUCKETS - 1);
    buckets[h] = count;
}

/* Emits an entry for (l, s, r) when the engine's current answer differs
 * from ICU's. */
static void probe(const char *l, const char *s, const char *r) {
    char il[16], is[16], ir[16], el[16], es[16], er[16];
    if (!icu_max(l, s, r, il, is, ir)) return;
    lookup(l, s, r, el, es, er);
    if (strcmp(il, el) || strcmp(is, es) || strcmp(ir, er)) add(l, s, r, il, is, ir);
}

static int cmp(const void *a, const void *b) { return strcmp(((const Entry *)a)->key, ((const Entry *)b)->key); }

int main(int argc, char **argv) {
    UErrorCode st = U_ZERO_ERROR;
    if (argc > 1) load_extras(argv[1]);
    for (int c = 0; c < USCRIPT_CODE_LIMIT; c++) {
        const char *n = uscript_getShortName((UScriptCode)c);
        if (n && strlen(n) == 4 && strcmp(n, "Zzzz") && strcmp(n, "Zyyy") && strcmp(n, "Zinh")) {
            int dup = 0; for (int i = 0; i < nscripts; i++) if (!strcmp(scripts[i], n)) dup = 1;
            if (!dup) scripts[nscripts++] = strdup(n);
        }
    }
    const char *const *cs = uloc_getISOCountries();
    for (; *cs; cs++) regions[nregions++] = strdup(*cs);
    /* The UN M49 macroregions CLDR uses. */
    static const char *const m49[] = {"001", "002", "003", "005", "009", "011", "013", "014", "015", "017",
        "018", "019", "021", "029", "030", "034", "035", "039", "053", "054", "057", "061", "142", "143",
        "145", "150", "151", "154", "155", "202", "419"};
    for (size_t i = 0; i < sizeof m49 / sizeof *m49; i++) regions[nregions++] = strdup(m49[i]);
    (void)st;
    /* Languages: every two- and three-letter code. */
    for (int len = 2; len <= 3; len++) {
        int total = 1; for (int i = 0; i < len; i++) total *= 26;
        for (int n = 0; n < total; n++) {
            char l[4] = {0}; int v = n;
            for (int i = len - 1; i >= 0; i--) { l[i] = 'a' + v % 26; v /= 26; }
            char il[16], is[16], ir[16];
            if (!icu_max(l, "", "", il, is, ir)) continue;
            /* A different language back is an alias (iw -> he); canonical tags never carry those. */
            if (is[0] && ir[0] && !strcmp(il, l) && kept(l)) add(l, "", "", il, is, ir);
        }
    }
    int nlang = count;
    /* und, und_S, und_R, und_S_R. */
    {
        char il[16], is[16], ir[16];
        if (icu_max("und", "", "", il, is, ir)) add("und", "", "", il, is, ir);
    }
    for (int s = 0; s < nscripts; s++) probe("und", scripts[s], "");
    for (int r = 0; r < nregions; r++) probe("und", "", regions[r]);
    for (int s = 0; s < nscripts; s++) for (int r = 0; r < nregions; r++) probe("und", scripts[s], regions[r]);
    /* A language an und_* entry names needs its own entry too, so that the
     * identifier it maximizes to also minimizes back (und_CW -> pap_Latn_CW). */
    int named = count;
    for (int i = nlang; i < named; i++) {
        char l[16]; strcpy(l, entries[i].lang);
        char il[16], is[16], ir[16];
        if (strcmp(l, "und") && find(l) < 0 && icu_max(l, "", "", il, is, ir) && !strcmp(il, l)) add(l, "", "", il, is, ir);
    }
    /* L_R and L_S for every language that has an entry. */
    int total_entries = count;
    for (int i = 0; i < total_entries; i++) {
        if (strchr(entries[i].key, '_') || !strcmp(entries[i].key, "und")) continue;
        char l[16]; strcpy(l, entries[i].key);
        for (int r = 0; r < nregions; r++) probe(l, "", regions[r]);
        for (int s = 0; s < nscripts; s++) probe(l, scripts[s], "");
    }
    qsort(entries, count, sizeof *entries, cmp);
    for (int i = 0; i < count; i++)
        printf("%s\t%s_%s_%s\n", entries[i].key, entries[i].lang, entries[i].script, entries[i].region);
    return 0;
}
