# Benchmarks — Boomkat

Performance benchmarks comparing boomkat against QuickJS and Node, with optional Duktape v2.7.0.

## Structure

```
benchmarks/
├── boomkat.c3             C3 CLI runner (compiled to out/boomkat)
├── bench_loop.js             Loop overhead (for/while)
├── bench_arithmetic.js       Arithmetic operations (+, -, *, /, %, bitwise)
├── bench_function_call.js    Function call overhead (empty, identity, 2-arg)
├── bench_recursion.js        Recursive function calls (Fibonacci)
├── bench_object.js           Object property operations (set, get, delete, nested)
├── bench_array.js            Array operations (push, index, pop, set)
├── bench_property_lookup.js  Prototype chain property lookup (depth 1-4)
├── bench_string.js           String operations (concat, compare)
└── bench_xxx.js              (add more as needed)
```

## Running

```bash
# Build boomkat
c3c build boomkat

# Default comparison: boomkat + QuickJS + Node (3 iterations)
just bench

# Include Duktape
just bench-all

# Choose the iteration count
just bench 5

# Exclude startup, compilation and teardown
just bench 3 execution
just bench-all 3 execution

# Generate JSON independently (progress goes to stderr)
python3 scripts/run_benchmarks.py 3 > out/bench_results.json
python3 scripts/run_benchmarks.py 3 --all > out/bench_results_all.json

# Render saved JSON, or read it from stdin
python3 scripts/render_benchmarks.py out/bench_results.json

# Measure a subset for a quick check
python3 scripts/run_benchmarks.py 1 --filter loop

# Run individual benchmarks as scripts
out/boomkat --script benchmarks/bench_loop.js
out/duktape benchmarks/bench_loop.js
```

## Interpreting Results

`just bench` saves JSON in `out/bench_results.json`; `just bench-all` saves
`out/bench_results_all.json`. The renderer shows mean milliseconds and ratios
of boomkat time to each comparison engine. Ratios above 1 mean boomkat is slower.

Each iteration spawns a fresh process. Wall time includes startup, compilation,
and execution. Boomkat is measured fresh on every invocation.
Third-party measurements are cached in `out/bench_cache_<engine>.json`.
The cache key includes the timing mode, engine binary, benchmark source, command, iterations,
and timeout. Use `just bench-clear` to force fresh measurements; cached cells
are marked with `*` in the table.
Node gets a `print()` shim and evaluates the benchmark with the Script goal.
Node must be on `PATH`; the recipes build QuickJS and Duktape as needed.

The default `wall` mode measures the full process lifecycle. `--mode execution`
in the JSON producer brackets the JavaScript body with `Date.now()`: startup,
compilation and teardown are excluded. It includes benchmark setup and any
`print()` calls inside the body. Each sample still runs in a fresh process, so
this mode does not warm up Node's JIT. Its millisecond clock can report zero for
very short workloads; ratios with a zero denominator appear as `—`.

The versioned JSON includes engine order, iteration count, timestamp, per-engine
samples, means, cache flags, and error/timeout results. Failed measurements have a null
mean and appear as `ERROR` or `TIMEOUT` in the table. Processes have a 120-second
timeout, configurable with `--timeout`. The shell entry point
`scripts/run_benchmarks.sh` forwards to the JSON producer.

## Size & Memory Benchmark

To compare binary sizes and peak memory usage:

```bash
just bench-sizes
```

This runs `scripts/run_sizes_bench.sh` which measures:
- **Binary size (KB)** — file size of each compiled engine
- **Peak RSS (KB)** — maximum resident set size when executing `benchmarks/memory_test.js` (a stress script that allocates many objects, arrays, and strings)

Results table:

| Engine                   | Binary (KB) | Peak RSS (KB) |
|--------------------------|-------------|---------------|
| boomkat                  | ...         | ...           |
| duktape (Duktape v2.7.0)   | ...         | ...           |
| qjs (QuickJS)            | ...         | ...           |

QuickJS is optional (skip row if not built). Ratios vs Duktape and QuickJS are printed at the bottom.

