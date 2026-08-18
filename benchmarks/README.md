# Benchmarks — Boomkat

Simple performance benchmarks comparing boomkat against original Duktape v2.7.0.

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
# Build the C3 CLI runner
c3c build boomkat

# Run the full comparison
scripts/run_benchmarks.sh [iterations]

# Run individual benchmarks
out/boomkat benchmarks/bench_loop.js      # C3 port
out/duktape benchmarks/bench_loop.js      # Original Duktape
```

## Interpreting Results

The comparison script reports:
- **C3 Port (ms)** — average compile + execute time for the C3 port
- **Duktape (ms)** — average time for original Duktape
- **Ratio** — C3 / Duktape (higher = C3 is slower relative to Duktape)

A ratio of ~5x means the C3 port is about 5× slower than the optimized C implementation.

## Notes

- Each benchmark iteration spawns a fresh process for all engines (C3, Duktape, QuickJS)
- Timing includes both compilation and execution (actual workload dominates)
- The `duktape` binary is built from Duktape v2.7.0 source

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
| boomkat (C3 port)     | ...         | ...           |
| duktape (Duktape v2.7.0)   | ...         | ...           |
| qjs (QuickJS)            | ...         | ...           |

QuickJS is optional (skip row if not built). Ratios vs Duktape and QuickJS are printed at the bottom.

