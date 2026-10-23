# Allocation and conversion measurements

Baseline: `b6c17549d1beb0c33624a0290324f7625e0b6a3f`, C3 0.8.5,
LLVM 23.1.3, macOS ARM64. Default target: O3, no size optimization,
single module, relaxed floating point. The retained baseline executable is
`out/optimization-study/baseline-b6c17549`; hashes and compiler details are in
[results/baseline.json](results/baseline.json). Binaries are local artifacts,
not checked into git.

Coding was delegated in isolated worktrees without builds or tests. One reviewer
inspected the patches, built each candidate, checked focused semantics, and ran
sequential alternating A/B pairs against the retained baseline. A warm pair is
excluded; screens use three pairs and confirmations five. CPU time is primary;
wall time and peak RSS are retained. Reported percentages compare medians; these
short experiments establish local decisions, not statistical guarantees or
whole-engine speedups. A/A CPU variation was approximately 0.3%.

| Candidate | Observation | Decision |
|---|---|---|
| Builtin property capacity | PdfJS CPU -2.11% on five confirming pairs; startup inconclusive; +176 machine-code bytes | Keep |
| Function-name reuse | Closure-allocation CPU -4.69% on five confirming pairs; PdfJS neutral; one pointer per compiled template, +96 code bytes | Keep |
| ASCII host conversion | Repeated ASCII API reads CPU -94.73%; Unicode -0.86% on confirmation; +88 code bytes | Keep |
| Property-key constant placement | TypeScript +0.33%, PdfJS +0.48%, Richards +0.21% CPU; +648 code bytes | Reject |
| Lazy ordinary prototypes | Allocation-free raw slot reads and descriptor paths require broad materialization machinery | Reject at design review; no timed prototype |
| Adjacent string concatenations | Targeted triple concatenation CPU +2.50%; usual compiler output uses distinct destinations and misses the narrow guard | Reject |
| External bytecode-cache helper | Hot helper CPU +60.25%, wall +47.44% versus uncached compile-and-run for a self-contained 2,000-function module | Reject |
| Native interpreter ABI | Baseline arithmetic handler already carries pc, dispatch table, registers and cold state in x0–x3 and tail-dispatches without a spill frame | No justified code change |

The final combined build measured closure allocation CPU **-3.85%**, Richards
**-0.59%**, TypeScript **+0.16%**, and PdfJS **-2.96%**, each over five pairs.
The executable is **3,148,376 bytes**, unchanged from baseline. Its `__text`
section grew from 2,411,184 to 2,411,536 bytes (**+352 bytes**); page-rounded
segment size hides this change. Peak RSS was approximately unchanged.

The property-capacity gain repeated on PdfJS, but no startup benefit was
established. Code placement may contribute to small benchmark differences.
The ASCII result measures a tight native API loop, not typical application
execution. Native probes use the same O4/size-small static-library target for
both sides; CLI results use the default target above. The cache comparison uses
the same tiny compiler/runner on both sides; Python startup and hashing dominate
this module. It does not establish that application-managed caches are useless.
Full ropes were declined because flat string access, hashing, indexing, ownership
and host conversion would all need changes.

Focused validation passed seven existing fixtures on both NaN-boxed and alternate
value representations: computed and numeric function names, function properties,
bind prototypes, prototype chains, property descriptors, and heap-reset lifetime.
Native ASCII and Unicode probes check lengths, truncation, capacity zero/one,
terminators and buffer boundaries. The concatenation candidate passed two existing
identity/ownership fixtures before rejection. The cache helper passed cold, warm
and deliberately damaged-image checks. No full conformance sweep was run.

Function names are retained by the compiled template using the existing string
reference mechanism. Template destruction and heap reset already release the
associated heap state; portable images do not serialize the cached pointer.
Property reservation moves backing storage through the existing growth path and
preserves property insertion order. ASCII copies preserve the existing API's
termination and insufficient-capacity behavior.

## Reproduction

Run from the repository root, with a baseline and candidate built using matching
flags and no concurrent builds:

```sh
python3 test/benchmarks/allocation-study/measure.py \
  out/optimization-study/baseline-b6c17549 out/optimization-study/combined \
  test/benchmarks/allocation-study/closures.js \
  bench/mini/richards.js bench/mini/typescript.js bench/mini/pdfjs.js \
  --pairs 5 --out /tmp/combined.json
```

`--native` runs the public-C-API probe executable with text fixtures instead of
invoking the JavaScript CLI. Compile `host_strings.c` against matching static
libraries. `generate_module.py` generates a module of the same shape as the
startup experiment; original fixture hashes are retained in the measurements.
All raw samples and binary hashes are under `results/`. RSS uses the platform's
`wait4` units (bytes on the measured macOS host). Candidate patches remain on
isolated experiment branches; rejected implementations are excluded from the
engine changes.
