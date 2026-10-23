# CodeLoad: eval compilation and loading costs

Measured on Apple Silicon/macOS with C3 0.8.5, `boomkat-full-icu`, O3,
`optsize=none`, threaded dispatch, full ICU. Engine and benchmark hashes,
individual samples, rejected experiments and validation logs are in
[results.json](results.json).

## Integrated result

Three alternating runs per engine, using the unchanged javascript-zoo
`bench/code-load.js`, after integrating main's allocation improvements:

| Engine/source | CodeLoad median |
|---|---:|
| Original `b6c17549` | 15,334 |
| Current-main baseline `9f087b30` | 15,294 |
| Integrated candidate `ed45a57b` | 29,174 |
| QuickJS | 27,602 |

The combined improvement is measured directly: **+90.7% against current main**,
with the candidate **5.7% ahead of QuickJS** in this batch. Three-pair screening
establishes the large gain; it does not establish statistical significance for
small differences.

Equal-work measurements use 1,000 salted Closure loads and 100 salted jQuery
loads, with three alternating pairs against current main:

| Workload | Baseline ms | Candidate ms | Baseline peak RSS | Candidate peak RSS |
|---|---:|---:|---:|---:|
| Closure | 646 | 306 | 220.3 MB | 181.7 MB |
| jQuery | 1,358 | 768 | 255.6 MB | 193.6 MB |

These are decimal MB. Fixed-work RSS falls **17.5% / 24.2%**. The timed CodeLoad
suite performs more loads in the faster engine: median peak RSS increases from
536.1 MB to 840.0 MB. Do not describe the fixed-work saving as a reduction in
the timed suite's peak memory.

## What changed

Each retained implementation has its own commit and saved preceding binary:

- `6d15e44c`: scan ASCII identifier bytes directly; keep Unicode/escape handling.
- `4371eb70`: reuse the literal-prefix search position during regexp execution;
  retain the exact starting position for sticky regexps.
- `43a31bd9`: omit regexp cache tables when a function has no regexp literal.
- `2c50857d`: validate eval source eagerly, retain source-backed ordinary function
  templates, and generate/optimize their bodies on first call. Direct IIFEs stay
  eager. Captures retain the existing environment path. Modules, contextual
  TS/JSX/private code, complex parameters, named function expressions, methods, generators, async functions
  and inspection builds keep their existing compilation paths.
- `799fe313`: specialize keyword comparisons with a C3 compile-time loop.
- `f4ae9050`: handle unambiguous punctuation before multi-character lookahead.
- `ed45a57b`: integrate current main and preserve its cached closure-name owner
  when a deferred template materializes.

Ordinary scripts stay eager. Applying lazy compilation generally caused runtime
regressions: unavailable outer binding information prevented existing capture
and global-name optimizations. Keeping deferral in eval units resolved those
regressions without retaining a full AST or adding another capture representation.
The new regression covers pre-call metadata, source lifetime, nested captures,
native callbacks, accessors, constructors, strictness and eager syntax errors.

## Rejected alternatives

- Smaller initial compiler buffers: neutral Closure time, slower jQuery, little
  fixed-work memory benefit.
- One allocation for liveness records: no repeatable gain, jQuery slower.
- One combined successor-union/comparison loop: slower in both workloads.
- Deferring every ordinary body: reparsing immediately executed wrappers repeats
  frontend work. Leaf-only deferral helped; recognizing direct IIFEs did better.
- Eager bytecode generation with first-call `finish()`: retaining compiler contexts
  was slower and used **8–10x** the memory of source-backed deferral. At 300 Closure
  loads: 92 → 140 ms, 59.8 → 611.1 MB. At 30 jQuery loads: 228 → 261 ms,
  65.2 → 527.0 MB. This implementation was removed.

## Regression checks and limits

A complete 15-benchmark Octane screen on the general-lazy prototype identified
EarleyBoyer, Box2D, Gameboy and TypeScript regressions. The retained eval-only
policy, integrated with current main, was rechecked with three alternating pairs:

| Benchmark | Current main | Candidate | Change |
|---|---:|---:|---:|
| EarleyBoyer | 3,292 | 3,299 | +0.2% |
| Box2D | 5,808 | 5,774 | −0.6% |
| Gameboy | 11,540 | 11,530 | −0.1% |
| TypeScript | 18,853 | 19,796 | +5.0% |

A single final Splay sanity run measured 7,848 / 7,791 / 7,807 for main,
candidate and QuickJS. Differences below 1% are inconclusive; this does not
replace the earlier repeated GC/Splay study or establish a new QuickJS win.
The full Octane aggregate was not recomputed for the final policy.

JSC's lead is largely independent of JIT for this benchmark: three-run medians
were 100,952 normally and 94,509 with `useJIT=false`. Disabling its parser cache
also reduced the interpreter score to roughly 79,000. The current result still
has substantial distance to JSC; it does not demonstrate parity.

## Reproduce

Keep binaries from the same target, compile flags and machine. Do not run builds,
other benchmark batches or validation concurrently with timing measurements.

```sh
python3 test/benchmarks/eval-lazy/measure.py \
  /path/to/baseline-full-icu /path/to/candidate-full-icu \
  --bench-dir /path/to/javascript-zoo/bench --pairs 3 --out /tmp/eval-pairs.json
```

The script creates temporary equal-work drivers from the unchanged benchmark,
records binary/source hashes, alternates engine order, and reports both score
and process peak RSS. Validation is performed once on the integrated source;
see the captured local, GC-stress and test262 results in `results.json`.

Final integrated validation passed: **53,264 test262 tests, zero failures or
compile errors**, 659 local scripts, 32 module fixtures, 39 private-field cases,
46 GC-stress cases, and the deferred-eval regression under GC stress. No test262
exclusions changed. The full gate ran once after integration (1m33s).
