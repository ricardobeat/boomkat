# Benchmarks

Runnable JavaScript benchmark cases for Boomkat, grouped by workload:

- `bench_*.js` — language and runtime performance cases.
- `mem_*.js`, `memory_test.js` — memory and allocation workloads.
- `gc_*.js` — garbage collector workloads.
- `es6/bench_*.js` — ES6 feature benchmarks.
- `json_serialize_payloads.js`, `vdom_test.js` — larger application-style workloads.

The benchmark runner and result tools live in the repository's `scripts/` directory:
`run_benchmarks.py`, `render_benchmarks.py`, `run_sizes_bench.sh`, and related helpers.
