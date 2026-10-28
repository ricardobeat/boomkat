# Shared JIT buffer and continuation workflows

Status: **COMPLETED — consolidated into [plan 113](113-fifty-thousand-octane.md), 2026-10-28.**

The scoped buffer and continuation implementation is complete. WIDE/high-register regions, environment-call chains, scanner specialization and broader guard/load elimination are carried into plan 113. Completion closes this document as a separate workstream; it does not assert that the broader optimizing tier or performance target has been achieved.

The original implementation notes, measurements and status statements below are historical evidence. Plan 113 owns the current priorities and acceptance criteria.

---

Follow-up implementation to plan 111, based on the shared-workflow profiles.
Implementation: rat `fa1e7f7a`. Baseline: rat `d569b9ed`. macOS arm64, C3 0.8.5, default 1 MiB code budget.

## Implemented

- SLJIT compiler-arena storage for jump fixups, in small bounded chunks. Expose
  `sljit_alloc_memory`; allocate only used records, free with the compiler.
  Up to 8192 fixups for regions dominated by sampled typed indexed operations;
  retain 2048 for generic bodies. No increase to the executable-code budget.
- Block-local ownership facts eliminate repeated refcount guards when both
  values require no ownership work, including permanently pinned strings.
  Calls, entries, and joins clear the facts.
- Named-property continuation first probes a validated own IC or the existing
  bounded megamorphic cache. It preserves accessor/proxy fallback and does not
  retarget IC owners embedded in live generated code. Includes primitive string
  length and ordinary prototype method reads.
- Resumable fixed-layout literal initialization, non-coercing string concat,
  and guarded builtin charCodeAt. Helpers report not-started, completed, or
  completed-with-poll, using the existing rooted/materialized continuation ABI.
  Overrides, fractional indexes, custom coercions and exotic objects fall back.

## Mini measurements

Three alternating baseline/final pairs per benchmark, medians of elapsed ms;
Crypto and Earley/Boyer sum their two phases. Runs retain benchmark assertions.
Builds, tests and sampling were kept out of timing runs. Small differences are
not evidence of a meaningful gain; Splay's small regression remains visible.

| Mini | Before ms | After ms | Change |
|---|---:|---:|---:|
| box2d | 225 | 224 | -0.4% |
| crypto | 246 | 246 | +0.0% |
| deltablue | 121 | 120 | -0.8% |
| earley-boyer | 176 | 174 | -1.1% |
| gbemu | 310 | 291 | -6.1% |
| mandreel | 800 | 686 | -14.2% |
| navier-stokes | 207 | 206 | -0.5% |
| pdfjs | 371 | 367 | -1.1% |
| raytrace | 169 | 166 | -1.8% |
| richards | 89 | 88 | -1.1% |
| splay | 109 | 112 | +2.8% |
| typescript | 1240 | 1233 | -0.6% |
| zlib | 4781 | 4259 | -10.9% |

The intermediate unrestricted-capacity variant slowed Gameboy and Navier.
Admitting larger generic bodies can displace the tighter loop tier; capacity
alone is not a profitability model. The final policy selects typed-heavy
regions rather than benchmark names. INIT_SLOT alone also slowed Splay; adding
string continuations closes another boundary, but is not yet a Splay win.
Unpaired exploratory timings are not used as evidence of speedup.

## Validation

- 25 focused fixtures in interpreter, JIT and JIT-stress: 75 passes.
- Full-feature local, Rosetta and modules differential runs: all match/status 0.
- Test262 expressions, statements and Array: all match/status 0.
- Embedding JIT API tests: PASS, including retirement, GC and interrupts.
- ASan: three new regressions plus Richards, DeltaBlue, Splay, Gameboy,
  Mandreel, zlib, TypeScript and PdfJS, all status 0.
- Default-feature local differential also matches, but both modes lack Intl
  and Temporal; the full-feature rerun above is the semantic gate.
- Final naming-only cleanup calls the ownership fact `unowned` rather than
  `nonstring`, since pinned strings also qualify. No behavior changes.

## Remaining work

This is not a completed optimizing tier or a 10x result. The next common
workflows remain fused global/environment call chains with correct `this`
semantics, mapped-arguments constructor forwarding, WIDE/high-register regions,
and guard/load reduction across blocks. charCodeAt currently resumes through a
runtime helper; scanner specialization should measure instruction and transition
costs before expanding it. CodeLoad/frontend and RegExp/library work are separate
from JS-generated-code coverage. Default code-budget policy is unchanged.

## Full Octane

Original upstream full suite, default settings, one process per build, baseline
then final; all benchmark validation passed. One run each is a smoke comparison,
not a statistically established aggregate gain. Higher scores are better.

| Result | Before | After | Change |
|---|---:|---:|---:|
| Richards | 3947 | 3986 | +1.0% |
| DeltaBlue | 2867 | 2926 | +2.1% |
| Crypto | 3043 | 3059 | +0.5% |
| RayTrace | 3022 | 3065 | +1.4% |
| EarleyBoyer | 3064 | 3077 | +0.4% |
| RegExp | 775 | 774 | -0.1% |
| Splay | 8891 | 9111 | +2.5% |
| SplayLatency | 22525 | 22052 | -2.1% |
| NavierStokes | 3940 | 3948 | +0.2% |
| PdfJS | 5197 | 5973 | +14.9% |
| Mandreel | 1924 | 1920 | -0.2% |
| MandreelLatency | 10909 | 11128 | +2.0% |
| Gameboy | 12171 | 11982 | -1.6% |
| CodeLoad | 27947 | 28398 | +1.6% |
| Box2D | 7264 | 6811 | -6.2% |
| zlib | 2892 | 2882 | -0.3% |
| Typescript | 21415 | 21600 | +0.9% |
| Score (version 9) | 5445 | 5495 | +0.9% |

Aggregate **5445 → 5495 (+0.9%)**. Mandreel and zlib mini gains do not
carry into full-suite scores here. This is consistent with compilation warmup
and shared-budget competition, but this run does not isolate the cause. A larger
global budget already failed to provide reliable broad gains in plan 111.
Profitability/admission and code lifetime need explicit whole-suite profiles
before changing defaults. Box2D falls 6.2% while PdfJS rises 14.9%; these
single-run changes need repeat measurements before attribution. Splay improves
in the full run despite its small mini regression.
