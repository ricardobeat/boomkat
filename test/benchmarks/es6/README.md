# ES6+ benchmarks

This corpus exercises lexical bindings, closures, classes, iterators,
destructuring, and other modern JavaScript paths. It compares boomkat,
QuickJS, and Node. Duktape supports ES5.1 and cannot run these workloads.

```sh
# Mean fresh-process wall time (3 iterations)
just bench-es6
just bench-es6 5

# JavaScript execution time, excluding startup, compilation and teardown
just bench-es6 3 execution

# Generate JSON independently, optionally selecting a subset
bash scripts/run_bench_es6.sh 3 --mode execution --filter class > out/bench_results_es6.json
python3 scripts/render_benchmarks.py out/bench_results_es6.json
```

The recipe saves measurements in `out/bench_results_es6.json` and renders the
same table as `just bench`. JSON includes the suite and timing mode, individual
samples, mean milliseconds, and failures. QuickJS and Node measurements are
cached by engine binary, source, command, iteration count, timeout, and timing
mode. Boomkat runs fresh. `just bench-clear` clears third-party caches for both
corpora.

Execution mode brackets the script body with `Date.now()` and has millisecond
resolution. It includes workload setup and script output. Every sample runs in
a fresh process, without a separate JIT warmup. The wall mode includes the full
process lifecycle. Both modes report means; ratios above 1 mean boomkat is
slower than the comparison engine.
