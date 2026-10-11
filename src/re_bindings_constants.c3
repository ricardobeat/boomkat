module boomkat::re_bindings;

/* Constants matching re_wrapper.h */
const int RE_FLAG_IGNORECASE = 2;
const int RE_FLAG_MULTILINE  = 4;
const int RE_FLAG_DOTALL     = 8;
const int RE_FLAG_UNICODE    = 16;
const int RE_FLAG_STICKY     = 32;
const int RE_FLAG_INDICES    = 64;
const int RE_FLAG_UNICODE_SETS = 128;

const int RE_MATCH    = 1;

/* Must match libregexp/re_wrapper.h. The 256-slot stack buffer covers
 * realistic patterns; regexps with more captures heap-allocate in re_run.
 *
 * On a match, re_run fills caps_start/caps_end for every index it reports
 * through out_num_captures, writing -1 for groups that did not participate.
 * Callers therefore declare those arrays `@noinit` and read only the reported
 * range: zeroing 2 KiB per call showed up as ~10% of regexp-heavy benchmarks. */
const int RE_MAX_CAPTURES = 256;
