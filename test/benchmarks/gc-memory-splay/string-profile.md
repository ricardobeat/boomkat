# String benchmark regression profile

The regression starts with `e14a5e03`, the bounded short-concatenation cache.
The string-comparison loop is unchanged; the extra time is in concatenation.
Measurements compare the saved production binaries from `5ba4bee8`,
`e14a5e03`, and the current `90075d64` source. The baseline and first-cache
binaries both use O2/small, so the initial regression precedes the O3 change.

One warmup and nine rotating rounds on the original 250,000-iteration loops
give these fresh-process median wall times. Each isolated phase includes
startup and teardown, so the phase times should not be summed.

| Workload | Starting build (ms) | First cache (ms) | Current (ms) |
|---|---:|---:|---:|
| whole | 22.47 | 29.07 | 25.00 |
| concat | 18.65 | 25.24 | 20.97 |
| comparison | 6.97 | 6.84 | 6.92 |

The concatenation expression is `result = s + " " + i`:

1. The starting build allocates the temporary prefix `"Hello, World! "` and
   appends the integer digits into its spare capacity. The register is the
   prefix's sole owner, so the append succeeds.
2. The cache shares that prefix and owns a reference to it. The append now sees
   two owners and checks the following destination binding to establish whether
   mutation is safe. That binding holds the previous completed result, so the
   ownership check fails on every iteration.
3. The completed label changes with `i`. It misses the short-result cache on
   every iteration, after comparing its bytes with the previous cached label.
   The cache then replaces that entry and updates reference counts.
4. Later operand-identity caching and direct threaded publication recover much
   of the first cache's overhead, but the failed append and unique-result
   cache probes remain.

Diagnostic counters from isolated GC_PROFILE builds confirm the concatenation
phase's behavior. These instrumented builds were used for counts, not timing:

| Counter | Starting build | First cache | Current |
|---|---:|---:|---:|
| Successful in-place appends | 250,000 | 0 | 0 |
| Lower-level cache checks | 0 | 500,000 | 250,001 |
| Lower-level cache hits | 0 | 249,999 | 0 |
| Operand-identity cache hits | 0 | 0 | 249,999 |
| Actual string allocations, including startup | 250,547 | 250,548 | 250,548 |

The allocation count stays almost identical: sharing the prefix saves one
allocation per iteration, while losing the append introduces one completed-label
allocation per iteration. The remaining regression is extra checks, cache
comparisons, entry replacement, and reference-count work.

CPU samples of the amplified concatenation loop put approximately 10% of current
samples in the bytewise `mem::equals` loops and 8% in `concat_binding_owns` plus
its property lookup. Disassembly confirms the anonymous hot code is the
byte-comparison loop. Both paths are absent from the baseline's hot path.
The comparison-only profile stays in the ordinary equality and loop handlers.
GC counter totals are the same in all three builds: 539 object allocations and
one cycle. This points to concat cache behavior, rather than collection pacing.

The concrete optimization target is cache admission for one-off formatted
integer results, alongside avoiding futile ownership lookups for cached prefixes.
Repeated immutable string-pair sharing is the behavior that benefits Splay.

[Raw timings, counters, binary hashes and CPU summaries](string-profile.json).
Full sampler output and instrumented source archives remain under
`out/gcmem-results/string-profile/`. Production code and binaries were unchanged
by this investigation.
