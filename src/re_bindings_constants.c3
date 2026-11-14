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
const int RE_NO_MATCH = 0;

const int RE_PREFILTER_NONE  = -1;
const int RE_PREFILTER_MATCH = -2;

/* Must match src/re_wrapper.h. A buffer of 2 * RE_MAX_CAPTURES ints holds
 * the bounds of every group the engine reports.
 *
 * On a match, re_run fills the bounds of every group of the pattern that fits,
 * writing -1 for groups that did not participate. Callers therefore declare
 * the buffer `@noinit` and read only the pattern's groups: zeroing 2 KiB per
 * call showed up as ~10% of regexp-heavy benchmarks. */
const int RE_MAX_CAPTURES = 256;

alias ReInterruptFn = fn int(void*);

struct ReInterrupt {
    ReInterruptFn poll;
    void* opaque;
}
