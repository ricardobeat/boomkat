# Engine throughput experiments

Baseline: `972c7f49`. Each retained improvement has its own commit, semantic
checks and alternating measurements against an immutable release binary.
Use C3 0.8.3 and the existing release configuration. Run timings outside the
filesystem sandbox, with no concurrent builds or test suites.

## 1. Date formatting — retained

Local formatting reuses the offset returned with the civil fields. This removes
one duplicate `localtime_r` call from `toString`, `toTimeString`, and local
`toLocale*` formatting. Every public operation still samples the host timezone;
there is no cache or new invalidation policy.

The initial assumption that Date dominates normal execution was false. Inside
the sandbox, repeated timezone lookup makes the original benchmark take about
2.7 seconds. Outside it, the subcases take 0–2 milliseconds each. The earlier
GC report's Date timing and its ES5 aggregate therefore describe sandboxed
execution, not ordinary desktop throughput. Per-case non-Date results remain
separate evidence.

Seven alternating pairs outside the sandbox, after warmup, using the unchanged
Date benchmark with only N raised from 2,000 to 100,000: median 0.7142 to 0.6780
seconds (5.1% less time). This is an amplified Date workload, not an engine-wide
speedup. Raw data: `benchmarks/engine-throughput/date/results.json`.

Validation: Rosetta 42/0; Date test262 591 pass, 3 skip, 0 fail. Baseline/candidate
formatting output matches for 583 dates in each of UTC, America/New_York,
Europe/Amsterdam, Asia/Kathmandu and Australia/Lord_Howe, including DST windows,
negative timestamps, TimeClip extremes and NaN.

## 2. Fixed-shape object literals — retained

The compiler selects a shared transition shape for unique non-index string
keys. `NEWOBJ_SHAPE` reserves the complete property storage once; `INIT_SLOT`
stores values through the existing ownership/barrier helper. All slots start
undefined, including those not yet evaluated when an initializer suspends or
calls user code. Methods, accessors, duplicate/computed keys, spread, prototype
syntax, wide operands and oversized shape IDs keep the general path.

Verified lifetime: `free_shape_slot` only reclaims private shapes. Transition
shapes own their keys and live until heap reset; reset also frees compiled
functions. This design needs no template objects or new root registry.

The first experiment removed key-load instructions entirely. It improved
throughput but raised the 100k scene's peak RSS from 198.5 to 268.9 MiB. Profiles
showed approximately 1.2 million extra positive-refcount strings; extra
collections did not release them. A key load also releases the previous owned
value in that register. The retained implementation replaces it with LDUNDEF,
preserving that ownership effect. An ASAN/GC_VERIFY test executes a reduced
renderer, forces collection, and asserts that string retention stays bounded.
The check passes with both NaN-boxed and NONANBOX values.

Five alternating pairs after warmup, outside the sandbox, against `30bff86a`.
Suite totals sum per-file medians; all outputs match after timing normalization.
Raw data: `benchmarks/engine-throughput/literals/results.json`.

| Workload | Baseline | Candidate | Runtime change |
|---|---:|---:|---:|
| ES5 (20 cases) | 1.7394 s | 1.6634 s | -4.4% |
| ES6 (8 cases) | 2.5852 s | 2.5790 s | -0.2% |
| Heavy VDOM | 2.9275 s | 2.6037 s | -11.1% |
| 100k scene / 3,000 frames | 1.8997 s | 1.7539 s | -7.7% |

Scene peak RSS falls from 198.5 to 196.9 MiB; heavy VDOM from 17.2 to 16.7 MiB.
Median worst frames: scene 2 → 2 ms; VDOM 12 → 11 ms. The ES6 aggregate is
approximately flat; destructuring improves 3.6%. Tiny per-case changes are not
attributed to this optimization.

Preliminary results are not the final benchmark dataset. Two apparent regressions in an earlier run (shape stress
and closure capture) disappeared in an eleven-pair recheck: +0.2% and +0.3%.
Neither workload executes a specialized literal.

Validation: Rosetta 42/0; local scripts and module/ancillary suites pass;
object-literal test262 1,170/0; 28 bytecode goldens; embedding API; 17 threaded
ASAN/GC_STRESS/GC_VERIFY checks before the ownership correction, followed by
fresh direct ASAN/GC_VERIFY tests in both value representations and a rerun of
object test262/local/goldens after the correction. The literal fixture also
checks dynamic compilation, initializer order, descriptors, mutation and
suspension, and agrees with Node (20,194 assertions).


## 3. Register-frame compaction — rejected after measurement

The experiment removed unused register positions before peephole optimization.
An explicit opcode operand table identified registers and contiguous call
windows; an injective, order-preserving mapping packed them into smaller frames.
Parameter positions and every ownership-releasing write stayed intact. Dynamic
scope, suspension, captures, observable arguments, complex parameters and
unsupported instructions excluded the function from compaction. This required
approximately 200 lines of compiler code without implementing general liveness
reuse.

Compiler instrumentation confirmed smaller frames: deep recursion 6 → 5;
two class functions 5 → 4 and 11 → 7; two scene functions 17 → 16 and 29 → 23;
one VDOM function 23 → 18. The value-stack-copy workload had no reduction.
Counts are recorded in `benchmarks/engine-throughput/frame-rejected/frame-stats.txt`.

Seven alternating pairs after warmup, outside the sandbox, against `d400a179`:

| Workload | Runtime change |
|---|---:|
| ES5 (20 cases, sum of medians) | -0.16% |
| ES6 (8 cases, sum of medians) | -0.42% |
| Heavy VDOM | -0.23% |
| 100k scene / 3,000 frames | -0.26% |

Peak RSS is effectively unchanged: VDOM 16.73 → 16.77 MiB and scene
196.94 → 196.92 MiB. A preliminary five-pair run likewise found no useful
gain. These measurements do not justify the extra compiler logic, so the pass
is not retained. General liveness-based register reuse remains untested.
Raw data: `benchmarks/engine-throughput/frame-rejected/results.json`.

The experimental binary passed Rosetta 42/0, local scripts 473/0 and modules
20/0. Its dedicated 1,014-assertion fixture also agreed with Node. These checks
establish basic semantic coverage; no fresh ASAN or test262 run was performed
for this rejected candidate.

## 4. GC throughput regression — threaded handlers

Measured September 28, 2026 with release builds from `git archive` for each
revision. Each workload had one warmup and six measured rounds with revision
order reversed on alternate rounds. Times include process startup and compile.
The four cases below show where the loss entered (median milliseconds):

| Revision | loop | property lookup | monomorphic IC | prototype IC |
|---|---:|---:|---:|---:|
| Before trace-only object reclamation (`963c77a9^`) | 31.3 | 40.0 | 74.1 | 112.3 |
| Trace-only reclamation (`963c77a9`) | 31.0 | 38.2 | 75.7 | 107.5 |
| Lazy sweep (`0eb7ed42`) | 31.1 | 38.4 | 75.6 | 107.2 |
| Generational barriers (`c9de382d`) | 31.4 | 39.0 | 75.5 | 107.6 |
| Generations and string ownership (`6820788d`) | 32.9 | 38.6 | 80.4 | 119.2 |
| Cooperative collector (`c529ab1c`) | 38.4 | 46.0 | 83.2 | 125.3 |
| Call pacing (`d32865d0`) | 38.3 | 46.2 | 83.1 | 122.8 |
| `4f1e9938` | 40.5 | 48.2 | 83.2 | 125.8 |

The generational/string-ownership commit adds register-release work to hot
arithmetic and property handlers. The cooperative commit adds incremental mark
publication checks to reads and a write barrier to global stores. Disassembly
of `th_putglobal` at `4f1e9938` shows five stack-save pairs and two calls even
for a numeric store. Its direct untraced-value path is a leaf handler with no
calls or stack saves. Traced stores and replacement of an owned string bail to
the switch, which applies the barrier and releases the string. Fast integer
global reads, object reads, cached property reads and addition avoid ownership
work when their operands permit it. Fast integer `INC`/`DEC` stays in threaded
dispatch; other types bail to the switch.

Five alternating pairs against `4f1e9938` with the 20 `bench_*.js` cases show
loop 40.7 → 28.2 ms (−30.7%), property lookup 48.3 → 36.3 ms (−25.0%),
monomorphic IC 83.3 → 72.2 ms (−13.4%) and prototype IC 127.7 → 103.3 ms
(−19.1%). The 19 cases excluding Date sum to 1.5929 → 1.5130 s (−5.0%);
scene churn is effectively flat. A separate five-pair comparison against
`963c77a9^` puts the same 19-case total at 1.5458 → 1.5150 s (−2.0%).
Eight alternating cross-engine pairs measure monomorphic IC at 71.8 ms here
versus 85.2 ms in QuickJS; prototype IC is 104.2 versus 104.7 ms, within
timing noise.
Recursion, deep recursion and value-stack copy still take about 6%, 6% and 10%
more than that pre-GC build, respectively; their remaining paths need a separate
investigation.

`just bench` caches Duktape and QuickJS results across runs, so its comparison
columns can combine measurements from different machine conditions. Clear the
caches with `just bench-clear` before a cross-engine run. Date formatting is
especially sensitive to sandboxed host timezone lookup: one fresh run measured
Date at 2.376 s in Boomkat, 9.754 s in Duktape and 2.375 s in QuickJS, while
the older cached Duktape and QuickJS values were 0.710 s and 0.013 s. Exclude
Date from the throughput total when evaluating the GC change.

Validation after the threaded-handler changes: Rosetta 42/0, local scripts
472/0, module entries 20/0, threaded ASAN/GC_STRESS/GC_VERIFY 17/0, and the
four prefix/postfix increment/decrement test262 directories 142/0. Boundary
checks cover fast integer overflow and BigInt/string fallback; the boundary
check and Rosetta 42/0 also pass in a NONANBOX build.
