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

// Where re_literal's literal sits in a match.
const int RE_LIT_REQUIRED = 0;
const int RE_LIT_PREFIX   = 1;
const int RE_LIT_AT       = 2;
const int RE_LIT_AT_ZERO  = 3;

/* Must match src/re_wrapper.h. A buffer of 2 * RE_MAX_CAPTURES ints holds
 * the bounds of every group the engine reports.
 *
 * On a match, re_run fills the bounds of every group of the pattern that fits,
 * writing -1 for groups that did not participate. Callers therefore declare
 * the buffer `@noinit` and read only the pattern's groups: zeroing 2 KiB per
 * call showed up as ~10% of regexp-heavy benchmarks. */
const int RE_MAX_CAPTURES = 256;

alias ReInterruptFn = fn int(void*);

// The arguments of a compiled body (re_jit::ReJitFn): the subject, the
// position to start at, the capture buffer, which holds 2 * capture_count
// ints, and the interrupt. The body keeps the rest of the run in its frame.
struct ReCall {
    char* data;
    uint len;
    uint start;
    int* caps;
    ReInterrupt* interrupt;
}

// The groups, group 0 included, whose bounds the capture buffer of a call
// from generated code holds (Heap.regexp_caps).
const int RE_CALL_GROUPS = 16;

struct ReInterrupt {
    ReInterruptFn poll;
    void* opaque;
}
