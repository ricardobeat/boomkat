# Four interpreter optimization experiments

The working engine applies only the GC64 candidate by user decision. These
isolated prototypes test threaded
multiplication, array literal construction, threaded fixed-slot initialization,
and collector clock/work batching. The production plan is
[098](../../../plans/098-measured-interpreter-optimizations.md).

## Method

- Baseline: the exact Git revision and binary hashes in [manifest.json](manifest.json).
  All Boomkat variants use the shipped `boomkat` release target (O2, small size,
  single module, relaxed floating point, threaded dispatch), plus the identical
  benchmark-only clock hook. QuickJS is the local `out/qjs` binary recorded there.
- Scene workloads: 10,000 nodes / 300 frames and 100,000 nodes / 3,000 frames.
  One warmup per engine, five measured runs per individual variant; seven for
  the combined confirmation. Engines run sequentially in rotated/reversed order.
- Frame timers: monotonic fractional milliseconds. Boomkat calls `clock::now()`
  through a temporary one-argument `Date.now` hook; QuickJS uses `performance.now`.
  Both use a small JS wrapper. No standard Date behavior is changed in the repo.
- A preallocated Float64Array records frame durations. Checksums validate the
  retained scene and final view; all compared engines produce matching checksums.
  Output processing happens after the frame loop. Wall time includes startup,
  scene construction, frame execution, validation, output, and teardown.
- Tables show medians across runs, including medians of each run's frame
  quantiles and peak RSS. The separate largest-observed column is the maximum
  across every measured frame. RSS comes from macOS `wait4`, in bytes.
- The wider suite has one warmup and three measured runs; the class follow-up
  has seven measured runs. Very short whole-process benchmarks include startup
  and scheduler noise. No builds or correctness suites run during measurements.
- An initial combined pass overlapped reproduction preparation and is excluded.
  The seven-run combined confirmation below replaces it.

## Individual experiments: 100k scene

| Variant | Wall (s) | Change | Frame p95 (ms) | Frame p99 (ms) | Median run max (ms) | Largest observed frame (ms) | Peak RSS (MiB) |
|---|---:|---:|---:|---:|---:|---:|---:|
| baseline | 1.6257 | +0.0% | 0.878 | 1.287 | 2.280 | 2.368 | 197.4 |
| mul | 1.6352 | +0.6% | 0.879 | 1.280 | 2.280 | 2.454 | 197.3 |
| arrays | 1.4406 | -11.4% | 0.766 | 1.248 | 2.126 | 2.367 | 165.2 |
| slots | 1.5948 | -1.9% | 0.875 | 1.267 | 2.335 | 2.439 | 197.4 |
| clock64 | 1.5062 | -7.4% | 0.739 | 1.044 | 1.818 | 1.828 | 197.4 |
| clock128 | 1.3918 | -14.4% | 0.437 | 0.885 | 1.597 | 1.674 | 386.0 |
| quickjs | 0.8574 | -47.3% | 0.255 | 0.277 | 0.331 | 0.352 | 72.6 |

`clock128` is rejected: its allocation-progress test fails and scene memory
nearly doubles. Its timing is shown to make the tradeoff explicit.

## Individual experiments: 10k scene

| Variant | Wall (s) | Change | Frame p95 (ms) | Frame p99 (ms) | Median run max (ms) | Largest observed frame (ms) | Peak RSS (MiB) |
|---|---:|---:|---:|---:|---:|---:|---:|
| baseline | 0.1355 | +0.0% | 0.668 | 0.727 | 0.754 | 0.807 | 26.4 |
| mul | 0.1357 | +0.2% | 0.669 | 0.738 | 0.755 | 0.902 | 26.4 |
| arrays | 0.1196 | -11.7% | 0.623 | 0.686 | 0.727 | 0.732 | 23.1 |
| slots | 0.1317 | -2.8% | 0.656 | 0.723 | 0.748 | 0.792 | 26.4 |
| clock64 | 0.1321 | -2.5% | 0.631 | 0.692 | 0.725 | 0.749 | 26.4 |
| clock128 | 0.1262 | -6.9% | 0.584 | 0.661 | 0.713 | 0.737 | 46.7 |
| quickjs | 0.0757 | -44.1% | 0.220 | 0.224 | 0.235 | 0.250 | 10.0 |

## Clock-polling control: 100k scene

`clockpoll128` keeps 32-unit work batches and checks the clock every 128 units.
`clock64` changes the work batch to 64 and checks time every batch. Both keep
the existing work allowance and nominal 500 microsecond slice limit. The
control does not support attributing the work-batch gain to clock polling alone.

| Variant | Wall (s) | Change | Frame p95 (ms) | Frame p99 (ms) | Median run max (ms) | Largest observed frame (ms) | Peak RSS (MiB) |
|---|---:|---:|---:|---:|---:|---:|---:|
| baseline | 1.6237 | +0.0% | 0.881 | 1.304 | 2.395 | 2.505 | 197.4 |
| clock64 | 1.5078 | -7.1% | 0.741 | 1.028 | 1.811 | 1.833 | 197.4 |
| clockpoll128 | 1.6423 | +1.1% | 0.885 | 1.291 | 2.351 | 2.585 | 197.3 |
| quickjs | 0.8598 | -47.1% | 0.258 | 0.279 | 0.320 | 0.325 | 72.6 |

## Combined confirmation

`combined` contains arrays + slots + clock64. Multiplication is excluded.
Independent gains must not be added together; these are separate measurements.

### 100k scene

| Variant | Wall (s) | Change | Frame p95 (ms) | Frame p99 (ms) | Median run max (ms) | Largest observed frame (ms) | Peak RSS (MiB) |
|---|---:|---:|---:|---:|---:|---:|---:|
| baseline | 1.6203 | +0.0% | 0.881 | 1.301 | 2.363 | 2.579 | 197.4 |
| combined | 1.3041 | -19.5% | 0.583 | 0.920 | 1.481 | 1.545 | 165.1 |
| quickjs | 0.8584 | -47.0% | 0.258 | 0.278 | 0.319 | 0.328 | 72.6 |

### 10k scene

| Variant | Wall (s) | Change | Frame p95 (ms) | Frame p99 (ms) | Median run max (ms) | Largest observed frame (ms) | Peak RSS (MiB) |
|---|---:|---:|---:|---:|---:|---:|---:|
| baseline | 0.1377 | +0.0% | 0.701 | 0.743 | 0.748 | 0.881 | 26.4 |
| combined | 0.1156 | -16.0% | 0.595 | 0.631 | 0.677 | 0.709 | 23.1 |
| quickjs | 0.0756 | -45.1% | 0.219 | 0.224 | 0.228 | 0.284 | 10.0 |

## Wider workloads

Each cell is median wall milliseconds; percentages are relative to the baseline
in this run. Full per-run wall time and RSS are in [broad-results.json](broad-results.json).

| Workload | Baseline ms | MUL | Arrays | Slots | GC64 | Combined | QuickJS ms |
|---|---:|---:|---:|---:|---:|---:|---:|
| bench_loop | 28.0 | +0.5% | +0.3% | -0.4% | +0.4% | +0.3% | 25.4 |
| bench_function_call | 49.4 | +2.1% | +1.2% | +0.8% | +0.2% | -0.2% | 31.6 |
| bench_array | 13.8 | +1.9% | +2.2% | +2.4% | +1.4% | +1.5% | 7.2 |
| bench_object | 66.2 | +0.4% | +1.3% | +1.3% | -0.7% | +1.0% | 36.9 |
| bench_recursion | 50.7 | +3.8% | -0.9% | -2.8% | +0.1% | -1.9% | 29.5 |
| es6/bench_class | 663.0 | -0.2% | +1.2% | +2.9% | +1.3% | +2.2% | 274.3 |
| es6/bench_destructuring | 581.6 | +1.3% | -7.4% | -0.1% | -2.3% | -9.2% | 236.7 |
| es6/bench_spread_rest | 235.8 | +0.7% | +0.3% | +0.7% | -0.7% | +0.9% | 179.9 |
| es6/bench_forof | 215.4 | -0.1% | +0.4% | +0.3% | -2.3% | -0.7% | 50.8 |
| bench_gc_large_container | 241.6 | +0.7% | +0.9% | -5.1% | -2.6% | -8.0% | 147.1 |
| bench_gc_native_reentry | 18.9 | +0.2% | +2.1% | -0.5% | +0.4% | -0.6% | 11.0 |

The mixed-iteration benchmark's median RSS rises from 59.8 MiB to 62.7 MiB
with GC64, including the combined candidate. GC64 therefore needs an explicit
memory acceptance decision; stable scene RSS alone does not establish it.

### Class follow-up

| Variant | Median wall (ms) | Change |
|---|---:|---:|
| baseline | 667.74 | +0.0% |
| arrays | 675.03 | +1.1% |
| slots | 676.00 | +1.2% |
| combined | 687.04 | +2.9% |

## Validation

- Baseline and the five initial variants: Rosetta **42/42** and targeted
  multiplication, array, fixed-shape, string-ownership, and GC-root checks pass.
- The polling-only control and combined candidate pass Rosetta **42/42**;
  the control passes the custom repro and the combined candidate passes all
  four targeted repros.
- Arrays, slots, GC64, and the polling-only control pass the existing
  `test_gc_incremental` target with **ASAN, GC_VERIFY, POOL_BYPASS, and
  THREADED_DISPATCH**. The combined candidate has targeted release validation;
  a combined ASAN build and narrow test262 runs remain production gates.
- GC128 fails `test_allocation_only_loop_progress` at
  `assert(h.live_obj_count < 250000)`. This is an allocation-progress bound,
  not a reported ASAN memory-safety error.
- [checks.json](checks.json), [gc-checks.json](gc-checks.json), and
  [combined-checks.json](combined-checks.json) preserve test output.
- No full test262 run. Prototypes are evidence for the plan, not shipping changes.

## Reproduce

Use Python 3.12+, the recorded C3 compiler, and the same local QuickJS binary.
Choose a new directory; preparation refuses an existing path. The patches
reproduce all measured C3 sources byte-for-byte in a separate checked copy.

```sh
python3 benchmarks/engine-throughput/four-experiments/prepare.py /tmp/boomkat-four-repro
export BOOMKAT_EXPERIMENT_DIR=/tmp/boomkat-four-repro
for variant in baseline mul arrays slots clock64 clock128 clockpoll128 combined; do
    just --justfile "$BOOMKAT_EXPERIMENT_DIR/$variant/justfile" --working-directory "$BOOMKAT_EXPERIMENT_DIR/$variant" build boomkat
done
python3 benchmarks/engine-throughput/four-experiments/run_scene.py
python3 benchmarks/engine-throughput/four-experiments/run_scene.py --variants baseline clock64 clockpoll128 quickjs --output clock-control-results.json
python3 benchmarks/engine-throughput/four-experiments/run_scene.py --variants baseline combined quickjs --runs 7 --output combined-confirmation.json
python3 benchmarks/engine-throughput/four-experiments/run_broad.py --variants baseline mul arrays slots clock64 combined quickjs
python3 benchmarks/engine-throughput/four-experiments/run_broad.py --variants baseline arrays slots combined --runs 7 --files es6/bench_class --output class-confirmation.json
```

Do not run builds, suites, or benchmark processes concurrently. The longer
research scripts are separate from `just bench-vdom`, whose recipe is unchanged.
Per-run summaries are JSON; compressed `*-frames.json.gz` files retain every
frame sample. Prototype patches in [patches](patches/) exclude the clock hook,
which is supplied as its own **benchmark-only** patch and must not be shipped.
